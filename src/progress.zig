const std = @import("std");
const thermal = @import("thermal.zig");
/// Compact terminal presentation and structured events share these stage names.
pub const Stage = enum { preparing, rendering, encoding, cooling, complete };
/// Caller owns the presentation lifetime and must call finish on every exit path.
pub const Progress = struct {
    io: std.Io,
    json: bool,
    animated: bool,
    color: bool,
    start: f64,
    last: f64 = 0,
    lastStage: ?Stage = null,
    /// Initialize output behavior from injected environment and options.
    pub fn init(io: std.Io, json: bool, noAnimation: bool, noColor: bool) !Progress {
        return .{ .io = io, .json = json, .animated = !json and !noAnimation and try std.Io.File.stdout().isTty(io), .color = !noColor, .start = thermal.bsMonotonicTime() };
    }
    /// Emit progress at at most ten updates per second, except stage transitions.
    pub fn event(self: *Progress, stage: Stage, done: u64, total: u64) !void {
        const now = thermal.bsMonotonicTime();
        if (now - self.last < 0.1 and self.lastStage == stage and done != total) return;
        if (!self.animated and !self.json and self.lastStage == stage and done != total) return;
        self.last = now;
        self.lastStage = stage;
        var bytes: [1024]u8 = undefined;
        var output = std.Io.File.stdout().writer(self.io, &bytes);
        const elapsed = now - self.start;
        const eta = if (done > 0 and total > done) elapsed * @as(f64, @floatFromInt(total - done)) / @as(f64, @floatFromInt(done)) else 0;
        if (self.json) {
            try std.json.Stringify.value(.{ .event = @tagName(stage), .completed = done, .total = total, .elapsedSeconds = elapsed, .etaSeconds = eta }, .{}, &output.interface);
            try output.interface.writeByte('\n');
        } else {
            if (self.animated) try output.interface.writeAll("\r\x1b[2K\x1b[?25l");
            if (self.color and self.animated) try output.interface.writeAll("\x1b[38;2;245;245;245m");
            try output.interface.print("  {s}  ", .{@tagName(stage)});
            if (self.color and self.animated) try output.interface.writeAll("\x1b[38;2;212;212;212m");
            try output.interface.print("{d}/{d}  {d:.1}s", .{ done, total, elapsed });
            if (eta > 0) try output.interface.print("  ~{d:.0}s left", .{eta});
            if (self.color and self.animated) try output.interface.writeAll("\x1b[0m");
            if (!self.animated) try output.interface.writeByte('\n');
        }
        try output.interface.flush();
    }
    /// Restore the cursor after success, cancellation, or failure.
    pub fn finish(self: *Progress) void {
        if (self.animated) std.Io.File.stdout().writeStreamingAll(self.io, "\x1b[0m\x1b[?25h\n") catch |err| std.debug.print("terminal restore: {s}\n", .{@errorName(err)});
    }
};
