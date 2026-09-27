const std = @import("std");
const Scene = @import("scene.zig").Scene;
const geo = @import("geodesic.zig");
const material = @import("material.zig");
const thermal = @import("thermal.zig");
/// Write a deterministic CPU reference image for validation. All I/O is explicit.
pub fn render(allocator: std.mem.Allocator, io: std.Io, scene: Scene, path: []const u8) !void {
    const width = scene.quality.width;
    const height = scene.quality.height;
    const rgb = try allocator.alloc(u8, @as(usize, width) * height * 3);
    defer allocator.free(rgb);
    const monitor = thermal.bsMonitorCreate();
    defer thermal.bsMonitorDestroy(monitor);
    var guard: thermal.Guard = .{};
    for (0..height) |y| {
        while (true) {
            const t = thermal.bsMonitorRead(monitor);
            switch (guard.evaluate(t, thermal.bsMonotonicTime())) {
                .proceed => break,
                .sensorFailure => return error.ThermalSensorUnavailable,
                .cool => try io.sleep(.fromMilliseconds(250), .awake),
            }
        }
        try io.checkCancel();
        for (0..width) |x| {
            const sx = (2 * (@as(f64, @floatFromInt(x)) + 0.5) - @as(f64, @floatFromInt(width))) / @as(f64, @floatFromInt(height));
            const sy = 1 - 2 * (@as(f64, @floatFromInt(y)) + 0.5) / @as(f64, @floatFromInt(height));
            const result = geo.trace(geo.cameraRay(scene.camera, scene.spin, sx, sy), .{ .diskInner = scene.disk.innerRadius, .diskOuter = scene.disk.outerRadius });
            if (result.outcome == .unresolved) return error.UnresolvedRay;
            const color = material.shadeMap(scene, result, 0, 0.015);
            for (0..3) |c| rgb[(y * width + x) * 3 + c] = @intFromFloat(255 * material.display(color[c], scene.optics.exposure));
        }
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("P6\n{d} {d}\n255\n", .{ width, height });
    try writer.interface.writeAll(rgb);
    try writer.interface.flush();
}
