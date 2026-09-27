const std = @import("std");
const optics = @import("optics.zig");
const Scene = @import("scene.zig").Scene;
const Format = @import("cli.zig").Format;
extern fn bsWritePng(path: [*:0]const u8, width: u32, height: u32, rgba: [*]const u16) c_int;
extern fn bsWriteExr(path: [*:0]const u8, width: u32, height: u32, rgba: [*]const f32) c_int;
/// Atomically publish a complete encoded image. The caller retains pixel ownership.
pub fn image(allocator: std.mem.Allocator, io: std.Io, scene: Scene, format: Format, path: []const u8, pixels: []const f32) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    const temporary = try std.fmt.allocPrintSentinel(allocator, "{s}.partial", .{path}, 0);
    defer allocator.free(temporary);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch |err| {
        if (err != error.FileNotFound) std.debug.print("cleanup: {s}\n", .{@errorName(err)});
    };
    if (format == .exr) {
        if (bsWriteExr(temporary, scene.quality.width, scene.quality.height, pixels.ptr) != 0) return error.ExrEncodeFailed;
    } else if (format == .png) {
        const copy = try allocator.dupe(f32, pixels);
        defer allocator.free(copy);
        try optics.flare(allocator, copy, scene.quality.width, scene.quality.height, scene.optics.flare, scene.optics.flareRadius);
        const finished = try allocator.alloc(u16, pixels.len);
        defer allocator.free(finished);
        optics.display16(copy, finished, scene.optics.exposure);
        if (bsWritePng(temporary, scene.quality.width, scene.quality.height, finished.ptr) != 0) return error.PngEncodeFailed;
    } else return error.InvalidImageFormat;
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}
/// Atomic text metadata with no partially completed final filename.
pub fn text(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.partial", .{path});
    defer allocator.free(temp);
    errdefer std.Io.Dir.cwd().deleteFile(io, temp) catch |err| {
        if (err != error.FileNotFound) std.debug.print("cleanup: {s}\n", .{@errorName(err)});
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
}
