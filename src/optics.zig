const std = @import("std");
const material = @import("material.zig");
const Scene = @import("scene.zig").Scene;
/// Apply a normalized separable veiling-flare PSF. Caller owns the RGBA buffer.
pub fn flare(allocator: std.mem.Allocator, rgba: []f32, width: usize, height: usize, strength: f64, radius: f64) !void {
    if (strength == 0) return;
    const temp = try allocator.alloc(f32, rgba.len);
    defer allocator.free(temp);
    const blurred = try allocator.alloc(f32, rgba.len);
    defer allocator.free(blurred);
    const sigma = @max(1, radius * @as(f64, @floatFromInt(height)));
    const reach: @TypeOf(width) = @intFromFloat(@ceil(3 * sigma));
    const weights = try allocator.alloc(f32, reach * 2 + 1);
    defer allocator.free(weights);
    var total: f64 = 0;
    for (weights, 0..) |*weight, i| {
        const x = @as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(reach));
        weight.* = @floatCast(@exp(-0.5 * x * x / (sigma * sigma)));
        total += weight.*;
    }
    for (weights) |*weight| weight.* /= @floatCast(total);
    convolve(rgba, temp, width, height, weights, reach, true);
    convolve(temp, blurred, width, height, weights, reach, false);
    const direct: @Vector(4, f32) = @splat(@floatCast(1 - strength));
    const scattered: @Vector(4, f32) = @splat(@floatCast(strength));
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        const a: @Vector(4, f32) = rgba[i..][0..4].*;
        const b: @Vector(4, f32) = blurred[i..][0..4].*;
        rgba[i..][0..4].* = a * direct + b * scattered;
    }
}
fn convolve(input: []const f32, output: []f32, width: usize, height: usize, weights: []const f32, reach: usize, horizontal: bool) void {
    for (0..height) |y| for (0..width) |x| {
        var sum: @Vector(4, f32) = @splat(0);
        for (weights, 0..) |weight, k| {
            const sx = if (horizontal) @min(width - 1, (x + k) -| reach) else x;
            const sy = if (horizontal) y else @min(height - 1, (y + k) -| reach);
            const pixel: @Vector(4, f32) = input[(sy * width + sx) * 4 ..][0..4].*;
            sum += pixel * @as(@Vector(4, f32), @splat(weight));
        }
        output[(y * width + x) * 4 ..][0..4].* = sum;
    };
}
/// Convert scene-linear pixels to finished 16-bit sRGB after the optical PSF.
pub fn display16(input: []const f32, output: []u16, exposure: f64) void {
    std.debug.assert(input.len == output.len);
    for (input, 0..) |value, i| output[i] = if (i % 4 == 3) 65535 else @intFromFloat(@round(65535 * material.display(value, exposure)));
}
test "constant radiance survives normalized flare" {
    var pixels: [16 * 16 * 4]f32 = @splat(2.5);
    try flare(std.testing.allocator, &pixels, 16, 16, 0.2, 0.04);
    for (pixels) |value| try std.testing.expectApproxEqAbs(@as(f32, 2.5), value, 2e-6);
}
