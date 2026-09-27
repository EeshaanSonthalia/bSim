const std = @import("std");
const Scene = @import("scene.zig").Scene;
const geo = @import("geodesic.zig");
/// Scene-linear RGB uses Rec.709 primaries and the D65 white point.
pub const Color = [3]f64;
fn smooth(lo: f64, hi: f64, x: f64) f64 {
    const t = std.math.clamp((x - lo) / (hi - lo), 0, 1);
    return t * t * (3 - 2 * t);
}
/// Analytically filtered deterministic filament source function.
pub fn emission(scene: Scene, radius: f64, phi: f64, time: f64, footprint: f64) Color {
    const disk = scene.disk;
    const phase = phi - time * disk.rotationSpeed / (std.math.pow(f64, radius, 1.5) + scene.spin);
    const seed = @as(f64, @floatFromInt(scene.seed % 1024)) * 0.013;
    var filaments: f64 = 0;
    var normalization: f64 = 0;
    for (0..6) |i| {
        const fi: @TypeOf(radius) = @floatFromInt(i);
        const frequency = 7 * std.math.pow(f64, 1.9, fi);
        const weight = std.math.pow(f64, 0.58, fi);
        const attenuation = @exp(-0.5 * frequency * frequency * footprint * footprint);
        filaments += weight * attenuation * @sin(radius * frequency + 2 * @sin(phase * (3 + fi) + radius * 0.4 + seed) + phase * (2 + fi));
        normalization += weight;
    }
    const edge = smooth(disk.innerRadius, disk.innerRadius + 0.6, radius) * (1 - smooth(disk.outerRadius - 3, disk.outerRadius, radius));
    const radial = std.math.pow(f64, disk.innerRadius / @max(radius, disk.innerRadius), 1.2);
    const brightness = disk.emission * edge * radial * (0.65 + 0.55 * filaments / normalization);
    return .{ brightness * disk.color[0], brightness * disk.color[1], brightness * disk.color[2] };
}
/// Thin-column preview estimator. Full exports use volume integration.
pub fn shadeMap(scene: Scene, result: geo.Result, time: f64, footprint: f64) Color {
    var color: Color = .{ 0, 0, 0 };
    var transmission: f64 = 1;
    for (result.hits[0..result.hitCount]) |hit| {
        const source = emission(scene, hit.radius, hit.phi, time + hit.time, footprint);
        const tau = scene.disk.extinction * scene.disk.thickness * 2.506628 / @max(hit.cosine, 0.03);
        const opacity = 1 - @exp(-tau);
        for (0..3) |c| color[c] += transmission * opacity * source[c];
        transmission *= 1 - opacity;
    }
    return color;
}
/// Hable filmic curve normalized at linear 11.2, then the IEC sRGB transfer.
pub fn display(value: f64, exposure: f64) f64 {
    const x = @max(0, value * exposure);
    const mapped = std.math.clamp(hable(x) / hable(11.2), 0, 1);
    return if (mapped <= 0.0031308) 12.92 * mapped else 1.055 * std.math.pow(f64, mapped, 1.0 / 2.4) - 0.055;
}
fn hable(x: f64) f64 {
    return ((x * (0.15 * x + 0.05) + 0.004) / (x * (0.15 * x + 0.5) + 0.06)) - 0.02 / 0.3;
}
test "homogeneous absorption and analytic emission" {
    const sigma: f64 = 0.75;
    const length: f64 = 4;
    var t: f64 = 1;
    var light: f64 = 0;
    for (0..1000) |_| {
        const attenuation = @exp(-sigma * length / 1000);
        light += t * (1 - attenuation) * 3;
        t *= attenuation;
    }
    try std.testing.expectApproxEqAbs(@exp(-3.0), t, 1e-12);
    try std.testing.expectApproxEqAbs(3 * (1 - @exp(-3.0)), light, 1e-12);
}
