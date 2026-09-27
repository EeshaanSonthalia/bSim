const std = @import("std");
const App = @import("application.zig").App;
const cli = @import("cli.zig");
const gpu = @import("gpu.zig");
const Timing = @import("scene.zig").Timing;
const thermal = @import("thermal.zig");

const Window = opaque {};
const Event = extern struct { flags: u32, width: u32, height: u32, ready: u32, seekTime: f64 };
const Presentation = extern struct { frames: u64, fps: f64, p99Milliseconds: f64, gpuSeconds: f64 };
extern fn bsWindowCreate(context: *gpu.Context, duration: f64) ?*Window;
extern fn bsWindowDestroy(window: *Window) void;
extern fn bsWindowPoll(window: *Window, time: f64) Event;
extern fn bsWindowSetDuration(window: *Window, duration: f64) void;
extern fn bsWindowPresent(window: *Window, context: *gpu.Context, params: *const gpu.Params) c_int;
extern fn bsWindowResetStats(window: *Window) void;
extern fn bsWindowStats(window: *Window) Presentation;
extern fn bsWindowSetCooling(window: *Window, cooling: c_int) void;
/// Window event bits. Values must match native/window.h.
const Flag = struct {
    const close: u32 = 1;
    const pause: u32 = 2;
    const restart: u32 = 4;
    const reload: u32 = 8;
    const seek: u32 = 32;
    const scaleUp: u32 = 64;
    const scaleDown: u32 = 128;
    const stepBack: u32 = 256;
    const stepForward: u32 = 512;
};
const minimumScale: f64 = 0.5;
const maximumScale: f64 = 1;
const scaleStep: f64 = 0.05;
const minimumInternalSize: u32 = 16;
const maximumInternalWidth: u32 = 3840;
const maximumInternalHeight: u32 = 2160;
const tilePixels: usize = 8192;
const idleMilliseconds = 20;
const coolingMilliseconds = 100;
const driftLimitSeconds: f64 = 1;
/// Play one shot in a window. Frames stream from the prepared disk cache.
pub fn run(app: *App, options: cli.Options) !void {
    const io = app.io;
    var scene = try options.loadScene(app.allocator, io);
    var scale = @min(maximumScale, @max(minimumScale, @as(f64, @floatFromInt(options.scale)) / 100));
    var frameIndex = frameOf(options.time, scene.timing);
    var duration = scene.timing.duration;
    var width: u32 = 0;
    var height: u32 = 0;
    var maps: []gpu.Map = &.{};
    defer if (maps.len > 0) app.allocator.free(maps);
    var playing = true;
    var dirty = true;
    var prepared = false;
    var loadTried = false;
    var traceOffset: usize = 0;
    var cooling = false;
    const window = bsWindowCreate(app.context, duration) orelse return error.WindowFailure;
    defer bsWindowDestroy(window);
    defer {
        const stats = bsWindowStats(window);
        std.debug.print("preview {d}x{d} internal, {d} presented frames, {d:.1} fps, p99 {d:.1} ms, gpu {d:.2} s\n", .{ width, height, stats.frames, stats.fps, stats.p99Milliseconds, stats.gpuSeconds });
    }
    var anchor = thermal.bsMonotonicTime();
    while (true) {
        if (thermal.bsIsCancelled() != 0) return error.Cancelled;
        try io.checkCancel();
        const fps: f64 = @floatFromInt(scene.timing.fps);
        const frames = frameCount(scene.timing);
        const time = @as(f64, @floatFromInt(frameIndex)) / fps;
        const event = bsWindowPoll(window, time);
        if (event.flags & Flag.close != 0) break;
        if (event.flags & Flag.pause != 0) playing = !playing;
        if (event.flags & Flag.restart != 0) {
            frameIndex = 0;
            playing = true;
            anchor = thermal.bsMonotonicTime();
            reset(&prepared, &loadTried, &traceOffset);
            dirty = true;
            bsWindowResetStats(window);
        }
        if (event.flags & Flag.reload != 0) {
            if (options.loadScene(app.allocator, io)) |reloaded| {
                scene = reloaded;
                if (scene.timing.duration != duration) {
                    duration = scene.timing.duration;
                    bsWindowSetDuration(window, duration);
                }
                frameIndex = @min(frameIndex, frameCount(scene.timing) - 1);
                reset(&prepared, &loadTried, &traceOffset);
                dirty = true;
            } else |failure| std.debug.print("reload: {s}\n", .{@errorName(failure)});
        }
        if (event.flags & Flag.seek != 0) {
            frameIndex = frameOf(event.seekTime, scene.timing);
            reset(&prepared, &loadTried, &traceOffset);
            dirty = true;
        }
        if (event.flags & Flag.stepBack != 0) {
            const total = frameCount(scene.timing);
            frameIndex = if (frameIndex == 0) total - 1 else frameIndex - 1;
            playing = false;
            reset(&prepared, &loadTried, &traceOffset);
            dirty = true;
        }
        if (event.flags & Flag.stepForward != 0) {
            frameIndex = (frameIndex + 1) % frameCount(scene.timing);
            playing = false;
            reset(&prepared, &loadTried, &traceOffset);
            dirty = true;
        }
        if (event.flags & Flag.scaleUp != 0) scale = @min(maximumScale, scale + scaleStep);
        if (event.flags & Flag.scaleDown != 0) scale = @max(minimumScale, scale - scaleStep);
        if (event.width >= minimumInternalSize and event.height >= minimumInternalSize) {
            const nextWidth = internalSize(event.width, scale, maximumInternalWidth);
            const nextHeight = internalSize(event.height, scale, maximumInternalHeight);
            if (nextWidth != width or nextHeight != height) {
                if (maps.len > 0) app.allocator.free(maps);
                maps = &.{};
                maps = try app.allocator.alloc(gpu.Map, @as(usize, nextWidth) * nextHeight);
                width = nextWidth;
                height = nextHeight;
                reset(&prepared, &loadTried, &traceOffset);
                dirty = true;
            }
            scene.quality.width = width;
            scene.quality.height = height;
        }
        if (maps.len == 0) {
            try io.sleep(.fromMilliseconds(idleMilliseconds), .awake);
            continue;
        }
        const sample = thermal.bsMonitorRead(app.scheduler.monitor);
        const decision = app.scheduler.guard.evaluate(sample, thermal.bsMonotonicTime());
        if (decision == .sensorFailure) return error.ThermalSensorUnavailable;
        const isCooling = decision == .cool;
        if (isCooling != cooling) {
            cooling = isCooling;
            bsWindowSetCooling(window, @as(c_int, @intFromBool(cooling)));
        }
        if (cooling) {
            try io.sleep(.fromMilliseconds(coolingMilliseconds), .awake);
            continue;
        }
        if (event.ready == 0) {
            try io.sleep(.fromMilliseconds(idleMilliseconds), .awake);
            continue;
        }
        if (!prepared) {
            if (!loadTried) {
                prepared = try app.loadMaps(scene, time, maps);
                loadTried = true;
            }
            if (!prepared) {
                const count = @min(tilePixels, maps.len - traceOffset);
                try app.traceTile(scene, time, traceOffset, maps[traceOffset..][0..count]);
                traceOffset += count;
                if (traceOffset >= maps.len) {
                    try app.finishMaps(scene, time, maps);
                    prepared = true;
                }
                try app.progress.event(.preparing, traceOffset, maps.len);
                if (!prepared) continue;
            }
        }
        if (!dirty and !playing) {
            try io.sleep(.fromMilliseconds(idleMilliseconds), .awake);
            continue;
        }
        try app.progress.event(.rendering, frameIndex, frames);
        try app.shadeDisplay(scene, time, maps);
        const params = gpu.Params.fromScene(scene, time, 0, @intCast(maps.len));
        const status = bsWindowPresent(window, app.context, &params);
        if (status < 0) return error.MetalFailure;
        if (status != 0) {
            dirty = true;
            try io.sleep(.fromMilliseconds(idleMilliseconds), .awake);
            continue;
        }
        dirty = false;
        if (!playing) continue;
        frameIndex = (frameIndex + 1) % frames;
        reset(&prepared, &loadTried, &traceOffset);
        anchor += 1 / fps;
        const now = thermal.bsMonotonicTime();
        if (anchor > now) {
            try io.sleep(.fromNanoseconds(@as(i96, @intFromFloat((anchor - now) * 1e9))), .awake);
        } else if (now - anchor > driftLimitSeconds) {
            anchor = now;
        }
    }
    try app.progress.event(.complete, 1, 1);
}
fn reset(prepared: *bool, loadTried: *bool, traceOffset: *usize) void {
    prepared.* = false;
    loadTried.* = false;
    traceOffset.* = 0;
}
fn frameCount(timing: Timing) u32 {
    const fps: f64 = @floatFromInt(timing.fps);
    return @max(1, @as(u32, @intFromFloat(@round(timing.duration * fps))));
}
fn frameOf(time: f64, timing: Timing) u32 {
    const fps: f64 = @floatFromInt(timing.fps);
    const index = time * fps;
    if (!std.math.isFinite(index) or index < 0) return 0;
    const frames = frameCount(timing);
    return @as(u32, @intFromFloat(@min(@round(index), @as(f64, @floatFromInt(frames - 1)))));
}
fn internalSize(output: u32, scale: f64, limit: u32) u32 {
    const value = @as(f64, @floatFromInt(output)) * scale;
    if (!std.math.isFinite(value)) return limit;
    const low: f64 = @floatFromInt(minimumInternalSize);
    const high: f64 = @floatFromInt(limit);
    return @intFromFloat(@min(high, @max(low, @round(value))));
}
