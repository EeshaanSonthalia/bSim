const std = @import("std");
const gpu = @import("gpu.zig");
const Scene = @import("scene.zig").Scene;
const output = @import("output.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
/// Renderer identity participates in every cache and resume key.
pub const version = "bSim-0.1.0-kerr-inverse-radius-v1";
const Header = extern struct { magic: [8]u8 = "BSIMMAP1".*, sceneHash: [32]u8, payloadHash: [32]u8, width: u32, height: u32 };
/// Compute a deterministic scene, shader, and time key. Caller owns no allocation.
pub fn key(allocator: std.mem.Allocator, scene: Scene, time: f64, shader: []const u8) ![32]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .version = version, .scene = scene, .time = time }, .{});
    defer allocator.free(bytes);
    var hash = Sha256.init(.{});
    hash.update(bytes);
    hash.update(shader);
    return hash.finalResult();
}
/// Return the owned on-disk filename for a lens map.
pub fn path(allocator: std.mem.Allocator, digest: [32]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".cache/lensing/{s}.map", .{std.fmt.bytesToHex(digest, .lower)});
}
/// Read a checked cache. Corrupt entries are treated as misses, never as valid geometry.
pub fn load(allocator: std.mem.Allocator, io: std.Io, filename: []const u8, digest: [32]u8, scene: Scene, maps: []gpu.Map) !bool {
    const expected = @sizeOf(Header) + std.mem.sliceAsBytes(maps).len;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(expected + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    if (bytes.len != expected) return false;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic, "BSIMMAP1") or !std.mem.eql(u8, &header.sceneHash, &digest) or header.width != scene.quality.width or header.height != scene.quality.height) return false;
    var actual: [32]u8 = undefined;
    Sha256.hash(bytes[@sizeOf(Header)..], &actual, .{});
    if (!std.mem.eql(u8, &actual, &header.payloadHash)) return false;
    @memcpy(std.mem.sliceAsBytes(maps), bytes[@sizeOf(Header)..]);
    return true;
}
/// Write one checked lens map with an atomic final rename.
pub fn save(allocator: std.mem.Allocator, io: std.Io, filename: []const u8, digest: [32]u8, scene: Scene, maps: []const gpu.Map) !void {
    try std.Io.Dir.cwd().createDirPath(io, ".cache/lensing");
    const temp = try std.fmt.allocPrint(allocator, "{s}.partial", .{filename});
    defer allocator.free(temp);
    var header: Header = .{ .sceneHash = digest, .payloadHash = undefined, .width = scene.quality.width, .height = scene.quality.height };
    Sha256.hash(std.mem.sliceAsBytes(maps), &header.payloadHash, .{});
    errdefer std.Io.Dir.cwd().deleteFile(io, temp) catch |err| {
        if (err != error.FileNotFound) std.debug.print("cache cleanup: {s}\n", .{@errorName(err)});
    };
    {
        const file = try std.Io.Dir.cwd().createFile(io, temp, .{});
        defer file.close(io);
        var buffer: [65536]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(std.mem.asBytes(&header));
        try writer.interface.writeAll(std.mem.sliceAsBytes(maps));
        try writer.interface.flush();
    }
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), filename, io);
}
