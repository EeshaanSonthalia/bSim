const std = @import("std");
const cli = @import("cli.zig");
const gpu = @import("gpu.zig");
const geo = @import("geodesic.zig");
const sceneModule = @import("scene.zig");
const Scene = sceneModule.Scene;
const thermal = @import("thermal.zig");
const output = @import("output.zig");
const cache = @import("cache.zig");
const Progress = @import("progress.zig").Progress;
const transport = @import("transport.zig");
/// Offline convergence data uses actual sample counts, including adaptive stops.
pub const RenderStats = struct { samples: u64 = 0, cpuFallbacks: u64 = 0, unconvergedPixels: u64 = 0, gpuSeconds: f64 = 0, elapsedSeconds: f64 = 0 };
/// Application state owns one reusable Metal context and its thermal monitor.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *gpu.Context,
    scheduler: gpu.Scheduler,
    progress: *Progress,
    /// Build runtime pipelines before any render job. All failure text is observable.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, progress: *Progress) !App {
        const monitor = thermal.bsMonitorCreate();
        errdefer thermal.bsMonitorDestroy(monitor);
        var scheduler: gpu.Scheduler = .{ .monitor = monitor };
        try scheduler.gate(io);
        const shader = @embedFile("shader");
        var message: [8192]u8 = undefined;
        const context = gpu.bsGpuCreate(shader.ptr, shader.len, &message, message.len) orelse {
            std.debug.print("Metal: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.MetalFailure;
        };
        return .{ .allocator = allocator, .io = io, .context = context, .scheduler = scheduler, .progress = progress };
    }
    /// Release all native resources after outstanding work completes.
    pub fn deinit(self: *App) void {
        gpu.bsGpuDestroy(self.context);
        thermal.bsMonitorDestroy(self.scheduler.monitor);
    }
    /// Load or calculate a lens map into caller-owned memory.
    pub fn prepareMap(self: *App, scene: Scene, time: f64, maps: []gpu.Map) !void {
        const key = try cache.key(self.allocator, scene, time, @embedFile("shader"));
        const path = try cache.path(self.allocator, key);
        defer self.allocator.free(path);
        try self.progress.event(.preparing, 0, maps.len);
        if (try cache.load(self.allocator, self.io, path, key, scene, maps)) {
            try self.progress.event(.preparing, maps.len, maps.len);
            return;
        }
        _ = try gpu.trace(self.context, &self.scheduler, self.io, scene, time, maps);
        try self.repair(scene, time, maps);
        try cache.save(self.allocator, self.io, path, key, scene, maps);
        try self.progress.event(.preparing, maps.len, maps.len);
    }
    fn repair(self: *App, scene: Scene, time: f64, maps: []gpu.Map) !void {
        for (maps, 0..) |*map, i| {
            if (map.info[0] != 3 and map.info[3] < 0.00005) continue;
            try self.scheduler.gate(self.io);
            const sx = (2 * (@as(f64, @floatFromInt(i % scene.quality.width)) + 0.5) - @as(f64, @floatFromInt(scene.quality.width))) / @as(f64, @floatFromInt(scene.quality.height));
            const sy = 1 - 2 * (@as(f64, @floatFromInt(i / scene.quality.width)) + 0.5) / @as(f64, @floatFromInt(scene.quality.height));
            const result = geo.trace(geo.cameraRay(scene.camera.at(time), scene.spin, sx, sy), .{ .maxSteps = 65536, .diskInner = scene.disk.innerRadius, .diskOuter = scene.disk.outerRadius });
            if (result.outcome == .unresolved) return error.UnresolvedRay;
            map.* = std.mem.zeroes(gpu.Map);
            for (result.hits[0..result.hitCount], 0..) |hit, j| map.hits[j] = .{ @floatCast(hit.radius), @floatCast(hit.phi), @floatCast(hit.time), @floatCast(hit.cosine) };
            map.sky = .{ @floatCast(result.ray.state[1]), @floatCast(result.ray.state[2]), @floatCast(result.ray.maxError), @floatFromInt(result.hitCount) };
            map.info = .{ @floatFromInt(@intFromEnum(result.outcome)), @floatFromInt(result.ray.steps), @floatCast(result.ray.state[3]), @floatCast(result.invariantError) };
        }
    }
    /// Shade a prepared map into caller-owned scene-linear RGBA memory.
    pub fn shade(self: *App, scene: Scene, time: f64, maps: []const gpu.Map, pixels: []f32) !void {
        var offset: usize = 0;
        while (offset < maps.len) {
            const count = @min(@as(usize, 8192), maps.len - offset);
            var params = gpu.Params.fromScene(scene, time, @intCast(offset), @intCast(count));
            params.timing[1] = 0;
            try self.scheduler.gate(self.io);
            const colors = gpu.bsGpuShade(self.context, &params, maps[offset..].ptr, @intCast(count)) orelse return error.MetalFailure;
            @memcpy(pixels[offset * 4 ..][0 .. count * 4], colors[0 .. count * 4]);
            offset += count;
            try self.progress.event(.rendering, offset, maps.len);
        }
    }
    /// Full volume rendering with deterministic shutter samples and per-pixel variance.
    pub fn renderFrame(self: *App, scene: Scene, time: f64, pixels: []f32) !RenderStats {
        const count = pixels.len / 4;
        const counts = try self.allocator.alloc(u32, count);
        defer self.allocator.free(counts);
        @memset(counts, 0);
        const variance = try self.allocator.alloc(f32, count);
        defer self.allocator.free(variance);
        @memset(variance, 0);
        const active = try self.allocator.alloc(u8, count);
        defer self.allocator.free(active);
        @memset(active, 1);
        @memset(pixels, 0);
        var stats: RenderStats = .{};
        const start = thermal.bsMonotonicTime();
        var remaining: usize = count;
        var sample: u32 = 0;
        while (sample < scene.quality.maxSamples and remaining > 0) : (sample += 1) {
            const shutter = scene.timing.shutter / (360 * @as(f64, @floatFromInt(scene.timing.fps)));
            const sampleTime = time + (radicalInverse(sample + 1) - 0.5) * shutter;
            var offset: usize = 0;
            while (offset < count) {
                const tile = @min(@as(usize, 8192), count - offset);
                var hasWork = false;
                for (active[offset..][0..tile]) |value| {
                    if (value != 0) {
                        hasWork = true;
                        break;
                    }
                }
                if (!hasWork) {
                    offset += tile;
                    continue;
                }
                var params = gpu.Params.fromScene(scene, sampleTime, @intCast(offset), @intCast(tile));
                params.work[2] = sample;
                params.work[3] = scene.quality.maxBounces | @as(u32, if (scene.quality.guiding) 65536 else 0);
                try self.scheduler.gate(self.io);
                if (gpu.bsGpuTransportStart(self.context, &params, active[offset..].ptr) != 0) return error.MetalFailure;
                while (true) {
                    try self.scheduler.gate(self.io);
                    const next = gpu.bsGpuStep(self.context);
                    if (next < 0) return error.MetalFailure;
                    if (next == 0) break;
                }
                const colors = gpu.bsGpuTransportResult(self.context) orelse return error.MetalFailure;
                stats.gpuSeconds += gpu.bsGpuSeconds(self.context);
                for (0..tile) |local| {
                    const index = offset + local;
                    if (active[index] == 0) continue;
                    var value: [4]f32 = colors[local * 4 ..][0..4].*;
                    if (value[3] < 0 or !std.math.isFinite(value[0]) or !std.math.isFinite(value[1]) or !std.math.isFinite(value[2])) {
                        try self.scheduler.gate(self.io);
                        var rng: transport.Rng = .{ .state = scene.seed ^ (@as(u32, @intCast(index)) *% 1664525) ^ (sample *% 1013904223) };
                        const sx = (2 * (@as(f64, @floatFromInt(index % scene.quality.width)) + rng.next()) - @as(f64, @floatFromInt(scene.quality.width))) / @as(f64, @floatFromInt(scene.quality.height));
                        const sy = 1 - 2 * (@as(f64, @floatFromInt(index / scene.quality.width)) + rng.next()) / @as(f64, @floatFromInt(scene.quality.height));
                        var referenceScene = scene;
                        referenceScene.quality.maxSteps = 65536;
                        referenceScene.quality.maxBounces = 64;
                        const result = try transport.sample(referenceScene, geo.cameraRay(scene.camera.at(sampleTime), scene.spin, sx, sy), sampleTime, rng.state);
                        for (0..3) |c| value[c] = @floatCast(result.direct[c] + result.scattered[c]);
                        value[3] = 1;
                        stats.cpuFallbacks += 1;
                    }
                    const oldL = luminance(pixels[index * 4 ..][0..4].*);
                    const sampleL = luminance(value);
                    counts[index] += 1;
                    stats.samples += 1;
                    const n: @Vector(4, f32) = @splat(@floatFromInt(counts[index]));
                    const old: @Vector(4, f32) = pixels[index * 4 ..][0..4].*;
                    const next: @Vector(4, f32) = value;
                    pixels[index * 4 ..][0..4].* = old + (next - old) / n;
                    const newL = luminance(pixels[index * 4 ..][0..4].*);
                    variance[index] += @floatCast((sampleL - oldL) * (sampleL - newL));
                    if (counts[index] >= scene.quality.minSamples and counts[index] > 1 and sample % 4 == 3) {
                        const nn = @as(f64, @floatFromInt(counts[index]));
                        const standardError = @sqrt(@max(0, variance[index]) / (nn * (nn - 1)));
                        if (1.96 * standardError <= scene.quality.relativeError * (@abs(newL) + 0.01)) {
                            active[index] = 0;
                            remaining -= 1;
                        }
                    }
                }
                offset += tile;
                try self.progress.event(.rendering, @as(u64, sample) * count + offset, @as(u64, scene.quality.maxSamples) * count);
            }
        }
        stats.unconvergedPixels = remaining;
        stats.elapsedSeconds = thermal.bsMonotonicTime() - start;
        return stats;
    }
    /// Render a still from a frozen scene and write its exact settings beside it.
    pub fn render(self: *App, scene: Scene, options: cli.Options) !void {
        const count = @as(usize, scene.quality.width) * scene.quality.height;
        const pixels = try self.allocator.alloc(f32, count * 4);
        defer self.allocator.free(pixels);
        const ownedPath = try std.fmt.allocPrint(self.allocator, "renders/{s}.{s}", .{ @tagName(scene.shot), @tagName(options.format) });
        defer self.allocator.free(ownedPath);
        const path = options.output orelse ownedPath;
        const stats = try self.renderFrame(scene, options.time, pixels);
        try self.scheduler.gate(self.io);
        try self.progress.event(.encoding, 0, 1);
        try output.image(self.allocator, self.io, scene, options.format, path, pixels);
        const sidecar = try std.fmt.allocPrint(self.allocator, "{s}.json", .{path});
        defer self.allocator.free(sidecar);
        const key = try cache.key(self.allocator, scene, options.time, @embedFile("shader"));
        const json = try std.json.Stringify.valueAlloc(self.allocator, .{ .schemaVersion = 1, .renderer = cache.version, .jobHash = std.fmt.bytesToHex(key, .lower), .scene = scene, .time = options.time, .colorSpace = "scene-linear Rec.709 D65", .previewApproximation = false, .statistics = stats, .peakBatteryC = self.scheduler.guard.peakBattery, .peakCpuC = self.scheduler.guard.peakCpu, .peakGpuC = self.scheduler.guard.peakGpu }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        try output.text(self.allocator, self.io, sidecar, json);
        try self.progress.event(.complete, 1, 1);
    }
};
fn radicalInverse(index: u32) f64 {
    return @as(f64, @floatFromInt(@bitReverse(index))) / 4294967296.0;
}
fn luminance(value: [4]f32) f64 {
    return 0.2126 * @as(f64, value[0]) + 0.7152 * @as(f64, value[1]) + 0.0722 * @as(f64, value[2]);
}
