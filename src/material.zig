const std = @import("std");
const Scene = @import("scene.zig").Scene;
const geo = @import("geodesic.zig");
/// Scene-linear RGB uses Rec.709 primaries and the D65 white point.
pub const Color = [3]f64;
fn smooth(lo: f64, hi: f64, x: f64) f64 {
    const t = std.math.clamp((x - lo) / (hi - lo), 0, 1);
    return t * t * (3 - 2 * t);
}
/// Low-bias 32-bit mixer. The Metal shading path repeats it.
fn hash32(value: u32) u32 {
    var mixed = value;
    mixed ^= mixed >> 16;
    mixed *%= 0x7feb352d;
    mixed ^= mixed >> 15;
    mixed *%= 0x846ca68b;
    mixed ^= mixed >> 16;
    return mixed;
}
/// Seeded unit-interval sample for one stream.
fn unit(salt: u32, key: u32) f64 {
    return @as(f64, @floatFromInt(hash32(salt ^ key))) / 4294967296;
}
/// Smooth value noise on a unit lattice.
fn noise(salt: u32, x: f64) f64 {
    const cell: i64 = @intFromFloat(@floor(x));
    const low = unit(salt, @as(u32, @truncate(@as(u64, @bitCast(cell)))));
    const high = unit(salt, @as(u32, @truncate(@as(u64, @bitCast(cell + 1)))));
    return low + (high - low) * smooth(0, 1, x - @floor(x));
}
/// Three-octave band profile in the unit interval.
fn band(salt: u32, x: f64) f64 {
    var value: f64 = 0;
    var weight: f64 = 0.5;
    var scale: f64 = 1;
    var total: f64 = 0;
    for (0..3) |octave| {
        value += weight * noise(salt ^ (@as(u32, @intCast(octave)) *% 0x9e3779b9), x * scale);
        total += weight;
        weight *= 0.55;
        scale *= 2.13;
    }
    return value / total;
}
/// Analytically filtered deterministic filament source function.
pub fn emission(scene: Scene, radius: f64, phi: f64, time: f64, footprint: f64) Color {
    const disk = scene.disk;
    const phase = phi - time * disk.rotationSpeed / (std.math.pow(f64, radius, 1.5) + scene.spin);
    const salt = scene.seed;
    const undulate = @sin(phase);
    const envelope = band(salt, radius * 0.55 + 0.3 * undulate);
    const wobbleAt = radius * 0.45 + 0.35 * undulate;
    var filaments: f64 = 0;
    var normalization: f64 = 0;
    for (0..6) |i| {
        const fi: @TypeOf(radius) = @floatFromInt(i);
        const key = @as(u32, @intCast(i)) *% 0x85ebca6b;
        const frequency = 7 * std.math.pow(f64, 1.9, fi);
        const strength = std.math.pow(f64, 0.58, fi) * (0.45 + 1.1 * unit(salt, key +% 1));
        const attenuation = @exp(-0.5 * frequency * frequency * footprint * footprint);
        const order: @TypeOf(radius) = @floatFromInt(1 + hash32(salt ^ (key +% 2)) % 7);
        const swirlOrder: @TypeOf(radius) = @floatFromInt(2 + hash32(salt ^ (key +% 3)) % 6);
        const swirlPhase = unit(salt, key +% 4) * (2 * std.math.pi);
        const drift = (unit(salt, key +% 5) - 0.5) * (2 * std.math.pi);
        const swirl = 1.2 + 1.6 * unit(salt, key +% 7);
        const wobble = (noise(salt ^ (key +% 6), wobbleAt) - 0.5) * std.math.pi;
        filaments += strength * attenuation * @sin(radius * frequency + wobble + order * phase + swirl * @sin(swirlOrder * phase + radius * 0.4 + swirlPhase) + drift);
        normalization += strength;
    }
    const edge = smooth(disk.innerRadius, disk.innerRadius + 0.6, radius) * (1 - smooth(disk.outerRadius - 3, disk.outerRadius, radius));
    const radial = std.math.pow(f64, disk.innerRadius / @max(radius, disk.innerRadius), 1.2);
    const brightness = disk.emission * edge * radial * (0.65 + 0.55 * envelope * filaments / normalization);
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
test "seeded filament emission is stable and seed dependent" {
    var scene = Scene.preset(.wide);
    const first = emission(scene, 9.5, 1, 0.5, 0.015);
    const again = emission(scene, 9.5, 1, 0.5, 0.015);
    for (first, again) |a, b| try std.testing.expectEqual(a, b);
    scene.seed +%= 1;
    const other = emission(scene, 9.5, 1, 0.5, 0.015);
    try std.testing.expect(first[0] != other[0] or first[1] != other[1] or first[2] != other[2]);
}
