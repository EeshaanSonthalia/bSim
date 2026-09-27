const std = @import("std");
const geo = @import("geodesic.zig");
const material = @import("material.zig");
const Scene = @import("scene.zig").Scene;
const Vec = [3]f64;
/// A reference sample separates unscattered and scattered light.
pub const Sample = struct { direct: Vec, scattered: Vec };
/// Deterministic scalar random stream. Arithmetic wraps by design.
pub const Rng = struct {
    state: u32,
    /// Return an open-interval sample. Zero never reaches a logarithm.
    pub fn next(self: *Rng) f64 {
        self.state = self.state *% 747796405 +% 2891336453;
        const shift: u5 = @intCast((self.state >> 28) + 4);
        const word = ((self.state >> shift) ^ self.state) *% 277803737;
        return (@as(f64, @floatFromInt((word >> 22) ^ word)) + 0.5) / 4294967296.0;
    }
};
/// Evaluate HG with both directions oriented along backward path travel.
pub fn phase(cosine: f64, g: f64) f64 {
    const denominator = 1 + g * g - 2 * g * cosine;
    return (1 - g * g) / (4 * std.math.pi * denominator * @sqrt(denominator));
}
/// Sample the normalized phase function in the local material frame.
pub fn samplePhase(axis: Vec, g: f64, rng: *Rng) Vec {
    const u = rng.next();
    const fraction = (1 - g * g) / (1 - g + 2 * g * u);
    const cosine = if (@abs(g) < 0.001) 2 * u - 1 else std.math.clamp((1 + g * g - fraction * fraction) / (2 * g), -1, 1);
    const sine = @sqrt(@max(0, 1 - cosine * cosine));
    const phi = 2 * std.math.pi * rng.next();
    const basis = normalize(cross(axis, if (@abs(axis[2]) < 0.9) .{ 0, 0, 1 } else .{ 0, 1, 0 }));
    const other = cross(axis, basis);
    var result: Vec = undefined;
    for (0..3) |i| result[i] = axis[i] * cosine + sine * (@cos(phi) * basis[i] + @sin(phi) * other[i]);
    return normalize(result);
}
fn cross(a: Vec, b: Vec) Vec {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn normalize(a: Vec) Vec {
    const length = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    return .{ a[0] / length, a[1] / length, a[2] / length };
}
/// Local matter speed, photon energy, and propagation direction.
pub const Frame = struct { velocity: f64, energy: f64, direction: Vec, sigma: f64 };
/// Transform the past-directed photon into an orbiting local material frame.
pub fn frame(ray: geo.Ray) Frame {
    const y = ray.state;
    const k = ray.constants;
    const r = y[0];
    const a = k.spin;
    const s = @sin(y[1]);
    const c = @cos(y[1]);
    const sigma = r * r + a * a * c * c;
    const delta = r * r - 2 * r + a * a;
    const bigA = (r * r + a * a) * (r * r + a * a) - a * a * delta * s * s;
    const alpha = @sqrt(sigma * delta / bigA);
    const omega = 2 * a * r / bigA;
    const varpi = @sqrt(bigA / sigma) * s;
    const orbital = 1 / (std.math.pow(f64, r, 1.5) + a);
    const velocity = std.math.clamp((orbital - omega) * varpi / alpha, -0.8, 0.8);
    const gamma = 1 / @sqrt(1 - velocity * velocity);
    const pt = (k.energy - omega * k.angularMomentum) / alpha;
    const pp = k.angularMomentum / varpi;
    const energy = -gamma * (pt - velocity * pp);
    return .{ .velocity = velocity, .energy = energy, .sigma = sigma, .direction = normalize(.{ y[4] / @sqrt(sigma * delta), y[5] / @sqrt(sigma), gamma * (pp - velocity * pt) }) };
}
/// Limit geometric steps near the thin volume so a whole disk cannot be skipped.
pub fn limitVolumeStep(ray: *geo.Ray, scene: Scene, stepFraction: f64) void {
    const r = ray.state[0];
    const theta = ray.state[1];
    const z = r * @cos(theta);
    const dz = ray.state[4] * @cos(theta) - r * @sin(theta) * ray.state[5];
    if (r < scene.disk.innerRadius - 1 or r > scene.disk.outerRadius + 2) return;
    const h = scene.disk.thickness;
    if (@abs(z) < 6 * h) ray.step = @min(ray.step, stepFraction * h / @max(@abs(dz), 0.01));
    if (z * dz < 0 and @abs(z) >= 6 * h) ray.step = @min(ray.step, @max(stepFraction * h, (@abs(z) - 4 * h) * 0.5) / @max(@abs(dz), 0.01));
}
/// Gaussian volume extinction. Density is zero outside the radial disk.
pub fn density(scene: Scene, y: geo.State) f64 {
    if (y[0] < scene.disk.innerRadius or y[0] > scene.disk.outerRadius) return 0;
    const z = y[0] * @cos(y[1]) / scene.disk.thickness;
    if (@abs(z) > 8) return 0;
    return scene.disk.extinction * @exp(-0.5 * z * z);
}
/// Integrate deterministic direct light and an analog scattered-light estimator.
pub fn sample(scene: Scene, initial: geo.Ray, time: f64, seed: u32) error{UnresolvedRay}!Sample {
    var rng: Rng = .{ .state = seed };
    return .{ .direct = try integrate(scene, initial, time, &rng, false), .scattered = if (scene.disk.albedo == 0) .{ 0, 0, 0 } else try integrate(scene, initial, time, &rng, true) };
}
fn integrate(scene: Scene, initial: geo.Ray, time: f64, rng: *Rng, scattering: bool) error{UnresolvedRay}!Vec {
    var ray = initial;
    var radiance: Vec = .{ 0, 0, 0 };
    var throughput: f64 = 1;
    var depth = -@log(rng.next());
    var bounces: u32 = 0;
    var steps: u32 = 0;
    while (steps < scene.quality.maxSteps * scene.quality.maxBounces) : (steps += 1) {
        if (ray.state[0] <= geo.horizon(scene.spin) + 0.001 and ray.state[4] < 0) return radiance;
        if (ray.state[0] >= 200 and ray.state[4] > 0) return radiance;
        limitVolumeStep(&ray, scene, 0.04);
        const old = ray.state;
        if (!geo.advance(&ray, 1e-11)) return error.UnresolvedRay;
        var middle = ray;
        for (0..6) |i| middle.state[i] = (old[i] + ray.state[i]) * 0.5;
        const local = frame(middle);
        const extinction = density(scene, middle.state);
        const distance = local.energy * local.sigma * ray.lastStep;
        const tau = extinction * distance;
        if (tau <= 0) continue;
        const source = material.emission(scene, middle.state[0], middle.state[2], time + middle.state[3], 0);
        if (!scattering) {
            const opacity = -std.math.expm1(-tau);
            for (0..3) |c| radiance[c] += throughput * opacity * source[c];
            throughput *= 1 - opacity;
            if (throughput < 1e-10) return radiance;
        } else {
            const travelled = @min(tau, depth);
            if (bounces > 0) for (0..3) |c| {
                radiance[c] += throughput * travelled * source[c];
            };
            if (tau < depth) {
                depth -= tau;
                continue;
            }
            const fraction = depth / tau;
            for (0..6) |i| ray.state[i] = old[i] + fraction * (ray.state[i] - old[i]);
            const collision = frame(ray);
            const direction = samplePhase(collision.direction, scene.disk.anisotropy, rng);
            ray = geo.localRay(ray.state, scene.spin, direction, collision.velocity);
            throughput *= scene.disk.albedo;
            bounces += 1;
            if (bounces >= scene.quality.maxBounces) return error.UnresolvedRay;
            if (bounces >= 3) {
                const survival = std.math.clamp(throughput, 0.05, 0.95);
                if (rng.next() > survival) return radiance;
                throughput /= survival;
            }
            depth = -@log(rng.next());
        }
    }
    return error.UnresolvedRay;
}
test "HG phase conserves energy and has the specified mean cosine" {
    var integral: f64 = 0;
    var mean: f64 = 0;
    const n = 10000;
    for (0..n) |i| {
        const cosine = -1 + 2 * (@as(f64, @floatFromInt(i)) + 0.5) / n;
        const probability = phase(cosine, 0.25) * 4 * std.math.pi / n;
        integral += probability;
        mean += probability * cosine;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1), integral, 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), mean, 1e-7);
}
test "phase sampling agrees with its mean and isotropic limit" {
    var rng: Rng = .{ .state = 42 };
    var mean: f64 = 0;
    for (0..20000) |_| mean += samplePhase(.{ 0, 0, 1 }, 0.25, &rng)[2];
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), mean / 20000, 0.015);
    try std.testing.expectApproxEqAbs(1.0 / (4.0 * std.math.pi), phase(0.6, 0), 1e-14);
}
