const std = @import("std");
const scene = @import("scene.zig");
/// Stable command names accepted by the CLI.
pub const Command = enum { help, doctor, shots, prepare, preview, render, benchmark, reference, @"validate-gpu", @"validate-export" };
/// Final output formats. Images remain full precision until their encode stage.
pub const Format = enum { png, exr, prores, h264 };
/// Parsed overrides own no strings. Their lifetime follows the input arguments.
pub const Options = struct {
    command: Command = .help,
    shot: scene.Shot = .wide,
    scenePath: ?[]const u8 = null,
    output: ?[]const u8 = null,
    format: Format = .png,
    width: ?u32 = null,
    height: ?u32 = null,
    samples: ?u32 = null,
    fps: ?u32 = null,
    frames: ?u32 = null,
    time: f64 = 0,
    /// Preview internal render size as a percentage of the output size.
    scale: u32 = 75,
    json: bool = false,
    noAnimation: bool = false,
    resumeFrames: bool = false,
    all: bool = false,
    seconds: f64 = 60,
    /// Reject unknown flags and missing values. Apply numeric bounds in scene validation.
    pub fn parse(args: []const [:0]const u8) !Options {
        var out: Options = .{};
        if (args.len < 2) return out;
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) return out;
        out.command = std.meta.stringToEnum(Command, args[1]) orelse return error.UnknownCommand;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const key = args[i];
            if (std.mem.eql(u8, key, "--json")) {
                out.json = true;
                continue;
            }
            if (std.mem.eql(u8, key, "--no-animation")) {
                out.noAnimation = true;
                continue;
            }
            if (std.mem.eql(u8, key, "--resume")) {
                out.resumeFrames = true;
                continue;
            }
            if (std.mem.eql(u8, key, "--all")) {
                out.all = true;
                continue;
            }
            if (i + 1 >= args.len) return error.MissingValue;
            i += 1;
            const value = args[i];
            if (std.mem.eql(u8, key, "--shot")) out.shot = std.meta.stringToEnum(scene.Shot, value) orelse return error.InvalidShot else if (std.mem.eql(u8, key, "--scene")) out.scenePath = value else if (std.mem.eql(u8, key, "--output")) out.output = value else if (std.mem.eql(u8, key, "--format")) out.format = std.meta.stringToEnum(Format, value) orelse return error.InvalidFormat else if (std.mem.eql(u8, key, "--width")) out.width = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--height")) out.height = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--samples")) out.samples = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--fps")) out.fps = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--frames")) out.frames = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--time")) out.time = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--seconds")) out.seconds = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--scale")) out.scale = try std.fmt.parseInt(u32, value, 10) else return error.UnknownOption;
        }
        if (!std.math.isFinite(out.time) or @abs(out.time) > 86400 or !std.math.isFinite(out.seconds) or out.seconds < 1 or out.seconds > 3600) return error.InvalidOptions;
        if (out.frames) |frames| if (frames == 0 or frames > 216000) return error.InvalidOptions;
        if (out.scale < 50 or out.scale > 100) return error.InvalidOptions;
        return out;
    }
    /// Load the owned immutable scene in the supplied arena. No global I/O is used.
    pub fn loadScene(self: Options, allocator: std.mem.Allocator, io: std.Io) !scene.Scene {
        var result = scene.Scene.preset(self.shot);
        if (self.scenePath) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
            defer allocator.free(bytes);
            const parsed = try std.json.parseFromSlice(scene.Scene, allocator, bytes, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            result = parsed.value;
        }
        if (self.width) |value| result.quality.width = value;
        if (self.height) |value| result.quality.height = value;
        if (self.samples) |value| {
            result.quality.minSamples = value;
            result.quality.maxSamples = value;
        }
        if (self.fps) |value| result.timing.fps = value;
        try result.validate();
        return result;
    }
};
test "CLI rejects invalid flags and values" {
    try std.testing.expectError(error.MissingValue, Options.parse(&.{ "bSim", "render", "--shot" }));
    try std.testing.expectError(error.UnknownOption, Options.parse(&.{ "bSim", "render", "--thermals-off", "true" }));
    try std.testing.expectError(error.InvalidOptions, Options.parse(&.{ "bSim", "render", "--time", "nan" }));
    try std.testing.expectError(error.InvalidOptions, Options.parse(&.{ "bSim", "preview", "--scale", "40" }));
    const preview = try Options.parse(&.{ "bSim", "preview", "--scale", "50" });
    try std.testing.expectEqual(@as(u32, 50), preview.scale);
}
