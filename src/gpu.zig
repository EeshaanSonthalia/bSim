const std = @import("std");
const Scene = @import("scene.zig").Scene;
const thermal = @import("thermal.zig");
/// Opaque exclusive owner of the Metal device, queues, pipelines, and buffers.
pub const Context = opaque {};
/// Checked C and Metal parameter layout. Geometry is f32 on the GPU.
pub const Params = extern struct {
    camera: [4]f32,
    composition: [4]f32,
    disk: [4]f32,
    material: [4]f32,
    color: [4]f32,
    optics: [4]f32,
    timing: [4]f32,
    image: [4]u32,
    work: [4]u32,
    /// Freeze the current camera sample and tile range.
    pub fn fromScene(scene: Scene, time: f64, offset: u32, count: u32) Params {
        const c = scene.camera.at(time);
        const d = scene.disk;
        const o = scene.optics;
        return .{ .camera = cast4(.{ c.radius, c.inclination, c.azimuth, c.verticalFov }), .composition = cast4(.{ c.roll, c.offsetX, c.offsetY, c.velocity }), .disk = cast4(.{ scene.spin, d.innerRadius, d.outerRadius, d.thickness }), .material = cast4(.{ d.extinction, d.albedo, d.rotationSpeed, d.emission }), .color = cast4(.{ d.color[0], d.color[1], d.color[2], d.anisotropy }), .optics = cast4(.{ o.exposure, o.flare, o.flareRadius, scene.quality.tolerance }), .timing = cast4(.{ time, 0, scene.timing.shutter, 0 }), .image = .{ scene.quality.width, scene.quality.height, scene.quality.maxSteps, scene.seed }, .work = .{ offset, count, 0, 0 } };
    }
};
fn cast4(values: [4]f64) [4]f32 {
    var out: [4]f32 = undefined;
    for (values, 0..) |value, i| out[i] = @floatCast(value);
    return out;
}
/// A prepared beam: four disk crossings plus escaped direction and error diagnostics.
pub const Map = extern struct { hits: [4][4]f32, sky: [4]f32, info: [4]f32 };
/// Create runtime compiled pipelines. The caller owns the returned context.
pub extern fn bsGpuCreate(source: [*]const u8, len: usize, message: [*]u8, capacity: usize) ?*Context;
/// Release all Metal resources.
pub extern fn bsGpuDestroy(context: *Context) void;
/// Device name borrowed until context destruction.
pub extern fn bsGpuName(context: *Context) [*:0]const u8;
/// Begin a tile after the Zig thermal gate. Returns zero on success.
pub extern fn bsGpuStart(context: *Context, params: *const Params) c_int;
/// Advance a bounded 32-step wave. Return active count or a negative error.
pub extern fn bsGpuStep(context: *Context) c_int;
/// Borrow the completed tile map until the next context mutation.
pub extern fn bsGpuMap(context: *Context) [*]const Map;
/// Accumulated GPU seconds for the current tile.
pub extern fn bsGpuSeconds(context: *Context) f64;
/// Shade a map to a borrowed scene-linear RGBA buffer.
pub extern fn bsGpuShade(context: *Context, params: *const Params, map: [*]const Map, count: u32) ?[*]const f32;
/// Return the integration pipeline SIMD width.
pub extern fn bsGpuThreadWidth(context: *Context) u32;
/// Select a measured legal group size.
pub extern fn bsGpuSetGroup(context: *Context, size: u32) void;
/// Begin a direct and scattered volume sample with a per-pixel active mask.
pub extern fn bsGpuTransportStart(context: *Context, params: *const Params, mask: [*]const u8) c_int;
/// Borrow the resolved full-transport sample. Negative alpha means unresolved.
pub extern fn bsGpuTransportResult(context: *Context) ?[*]const f32;
/// Application scheduling state. The caller owns and destroys both native handles.
pub const Scheduler = struct {
    monitor: ?*thermal.Monitor,
    guard: thermal.Guard = .{},
    /// Gate every wave on a fresh sample. Cooling is cancellable.
    pub fn gate(self: *Scheduler, io: std.Io) !void {
        while (true) {
            if (thermal.bsIsCancelled() != 0) return error.Cancelled;
            try io.checkCancel();
            const sample = thermal.bsMonitorRead(self.monitor);
            switch (self.guard.evaluate(sample, thermal.bsMonotonicTime())) {
                .proceed => return,
                .cool => try io.sleep(.fromMilliseconds(250), .awake),
                .sensorFailure => return error.ThermalSensorUnavailable,
            }
        }
    }
};
/// Trace into caller-owned map memory. Resources and queues stay bounded.
pub fn trace(context: *Context, scheduler: *Scheduler, io: std.Io, scene: Scene, time: f64, maps: []Map) !f64 {
    var offset: usize = 0;
    var gpuSeconds: f64 = 0;
    while (offset < maps.len) {
        const count = @min(@as(usize, 8192), maps.len - offset);
        const params = Params.fromScene(scene, time, @intCast(offset), @intCast(count));
        try scheduler.gate(io);
        if (bsGpuStart(context, &params) != 0) return error.MetalFailure;
        while (true) {
            try scheduler.gate(io);
            const active = bsGpuStep(context);
            if (active < 0) return error.MetalFailure;
            if (active == 0) break;
        }
        @memcpy(maps[offset..][0..count], bsGpuMap(context)[0..count]);
        gpuSeconds += bsGpuSeconds(context);
        offset += count;
    }
    return gpuSeconds;
}
comptime {
    std.debug.assert(@sizeOf(Params) == 144);
    std.debug.assert(@sizeOf(Map) == 96);
}
