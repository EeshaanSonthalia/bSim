const std = @import("std");
const Camera = @import("scene.zig").Camera;
/// State in Mino time: radius, polar angle, azimuth, coordinate time, dr, dtheta.
pub const State = [6]f64;
/// Constants of a past-directed null ray. Units have G = c = M = 1.
pub const Constants = struct { spin: f64, energy: f64, angularMomentum: f64, carter: f64 };
/// Geometric ray including the explicit adaptive integrator state.
pub const Ray = struct { state: State, constants: Constants, step: f64 = 0.001, lastStep: f64 = 0, steps: u32 = 0, rejected: u32 = 0, maxError: f64 = 0 };
/// Outcomes are geometric only. Exhaustion never maps to capture.
pub const Outcome = enum(u32) { active, escaped, captured, unresolved };
/// A resolved disk crossing retains travel time and proper incidence angle.
pub const Hit = struct { radius: f64, phi: f64, time: f64, cosine: f64 };
/// Controls for a bounded trace. CPU defaults prioritize accuracy.
pub const Config = struct { tolerance: f64 = 1e-12, maxSteps: u32 = 16384, escapeRadius: f64 = 200, diskInner: f64 = 4, diskOuter: f64 = 18 };
/// Trace summary owns no memory. At most four visible disk crossings are retained.
pub const Result = struct { outcome: Outcome, ray: Ray, hits: [4]Hit = undefined, hitCount: u32 = 0, invariantError: f64 = 0 };
/// Outer event horizon in mass units.
pub fn horizon(spin: f64) f64 {
    return 1 + @sqrt(1 - spin * spin);
}
/// Create a past-directed ray in the camera ZAMO tetrad, with an azimuthal boost.
pub fn cameraRay(camera: Camera, spin: f64, screenX: f64, screenY: f64) Ray {
    const scale = @tan(camera.verticalFov * 0.5);
    const x = (screenX + camera.offsetX) * scale;
    const y = (screenY + camera.offsetY) * scale;
    const cr = @cos(camera.roll);
    const sr = @sin(camera.roll);
    const norm = @sqrt(1 + x * x + y * y);
    return localRay(.{ camera.radius, camera.inclination, camera.azimuth, 0, 0, 0 }, spin, .{ -1 / norm, -(y * cr + x * sr) / norm, (x * cr - y * sr) / norm }, camera.velocity);
}
/// Launch from a local orthonormal frame. Direction must have unit length.
pub fn localRay(position: State, spin: f64, direction: [3]f64, velocity: f64) Ray {
    const r = position[0];
    const theta = position[1];
    const sin = @sin(theta);
    const cos = @cos(theta);
    const sigma = r * r + spin * spin * cos * cos;
    const delta = r * r - 2 * r + spin * spin;
    const bigA = (r * r + spin * spin) * (r * r + spin * spin) - spin * spin * delta * sin * sin;
    const alpha = @sqrt(sigma * delta / bigA);
    const omega = 2 * spin * r / bigA;
    const gamma = 1 / @sqrt(1 - velocity * velocity);
    const timeLocal = gamma * (-1 + velocity * direction[2]);
    const phiLocal = gamma * (direction[2] - velocity);
    const angularMomentum = @sqrt(bigA / sigma) * sin * phiLocal;
    const energy = alpha * timeLocal + omega * angularMomentum;
    const polarVelocity = @sqrt(sigma) * direction[1];
    const carter = polarVelocity * polarVelocity + cos * cos * (angularMomentum * angularMomentum / (sin * sin) - spin * spin * energy * energy);
    return .{ .state = .{ r, theta, position[2], position[3], @sqrt(sigma * delta) * direction[0], polarVelocity }, .constants = .{ .spin = spin, .energy = energy, .angularMomentum = angularMomentum, .carter = carter }, .step = 0.04 / r };
}
/// Evaluate the separated Kerr null equations in Mino time without turning-point sign switches.
pub fn derivative(y: State, k: Constants) State {
    const r = y[0];
    const s = @sin(y[1]);
    const c = @cos(y[1]);
    const s2 = @max(s * s, 1e-24);
    const a = k.spin;
    const e = k.energy;
    const l = k.angularMomentum;
    const delta = r * r - 2 * r + a * a;
    const p = e * (r * r + a * a) - a * l;
    const capitalK = (l - a * e) * (l - a * e) + k.carter;
    return .{ y[4], y[5], l / s2 - a * e + a * p / delta, a * (l - a * e * s2) + (r * r + a * a) * p / delta, 2 * e * r * p - (r - 1) * capitalK, c * (l * l / (s2 * s) - a * a * e * e * s) };
}
fn combine(y: State, h: f64, ks: []const State, coefficients: []const f64) State {
    var output = y;
    for (ks, coefficients) |k, coefficient| for (0..6) |i| {
        output[i] += h * coefficient * k[i];
    };
    return output;
}
/// Take one accepted RKF45 step. Return false for a singular or unresolvable ray.
pub fn advance(ray: *Ray, tolerance: f64) bool {
    const r = ray.state[0];
    const rh = horizon(ray.constants.spin);
    var h = @min(ray.step, 0.15 / @max(r, 1));
    if (ray.state[4] < 0) h = @min(h, 0.3 * (r - rh) / @max(@abs(ray.state[4]), 1));
    for (0..24) |_| {
        if (h < 1e-14 or !std.math.isFinite(h)) return false;
        var ks: [6]State = undefined;
        ks[0] = derivative(ray.state, ray.constants);
        ks[1] = derivative(combine(ray.state, h, ks[0..1], &.{1.0 / 4.0}), ray.constants);
        ks[2] = derivative(combine(ray.state, h, ks[0..2], &.{ 3.0 / 32.0, 9.0 / 32.0 }), ray.constants);
        ks[3] = derivative(combine(ray.state, h, ks[0..3], &.{ 1932.0 / 2197.0, -7200.0 / 2197.0, 7296.0 / 2197.0 }), ray.constants);
        ks[4] = derivative(combine(ray.state, h, ks[0..4], &.{ 439.0 / 216.0, -8, 3680.0 / 513.0, -845.0 / 4104.0 }), ray.constants);
        ks[5] = derivative(combine(ray.state, h, ks[0..5], &.{ -8.0 / 27.0, 2, -3544.0 / 2565.0, 1859.0 / 4104.0, -11.0 / 40.0 }), ray.constants);
        const low = combine(ray.state, h, &ks, &.{ 25.0 / 216.0, 0, 1408.0 / 2565.0, 2197.0 / 4104.0, -1.0 / 5.0, 0 });
        const high = combine(ray.state, h, &ks, &.{ 16.0 / 135.0, 0, 6656.0 / 12825.0, 28561.0 / 56430.0, -9.0 / 50.0, 2.0 / 55.0 });
        var err: f64 = 0;
        for (high, low, ray.state) |hi, lo, old| {
            if (!std.math.isFinite(hi)) return false;
            err = @max(err, @abs(hi - lo) / (1 + @max(@abs(hi), @abs(old))));
        }
        const factor = std.math.clamp(0.9 * std.math.pow(f64, tolerance / @max(err, 1e-30), 0.2), 0.2, 3.0);
        if (err <= tolerance) {
            ray.state = high;
            ray.step = h * factor;
            ray.lastStep = h;
            ray.steps += 1;
            ray.maxError = @max(ray.maxError, err);
            return true;
        }
        h *= factor;
        ray.rejected += 1;
    }
    return false;
}
/// Measure radial and polar constraint drift relative to their characteristic scales.
pub fn invariantError(ray: Ray) f64 {
    const k = ray.constants;
    const y = ray.state;
    const r = y[0];
    const c = @cos(y[1]);
    const s = @sin(y[1]);
    const p = k.energy * (r * r + k.spin * k.spin) - k.spin * k.angularMomentum;
    const capK = (k.angularMomentum - k.spin * k.energy) * (k.angularMomentum - k.spin * k.energy) + k.carter;
    const radial = p * p - (r * r - 2 * r + k.spin * k.spin) * capK;
    const polar = k.carter - c * c * (k.angularMomentum * k.angularMomentum / (s * s) - k.spin * k.spin * k.energy * k.energy);
    return @max(@abs(y[4] * y[4] - radial) / (1 + p * p + @abs((r * r - 2 * r + k.spin * k.spin) * capK)), @abs(y[5] * y[5] - polar) / (1 + @abs(k.carter) + k.angularMomentum * k.angularMomentum));
}
/// Trace to escape, the outer horizon, or explicit failure. Refine each plane event.
pub fn trace(initial: Ray, config: Config) Result {
    var out: Result = .{ .outcome = .unresolved, .ray = initial };
    while (out.ray.steps < config.maxSteps) {
        const old = out.ray;
        if (old.state[0] <= horizon(old.constants.spin) + 0.001 and old.state[4] < 0) {
            out.outcome = .captured;
            break;
        }
        if (old.state[0] >= config.escapeRadius and old.state[4] > 0) {
            out.outcome = .escaped;
            break;
        }
        if (!advance(&out.ray, config.tolerance)) break;
        out.invariantError = @max(out.invariantError, invariantError(out.ray));
        if (@cos(old.state[1]) * @cos(out.ray.state[1]) < 0 and out.hitCount < 4) {
            var left = old.state;
            var right = out.ray.state;
            // Cubic Hermite interpolation locates the event within an accepted step.
            const usedH = out.ray.lastStep;
            const d0 = derivative(old.state, old.constants);
            const d1 = derivative(out.ray.state, old.constants);
            var lo: f64 = 0;
            var hi: f64 = 1;
            for (0..24) |_| {
                const t = (lo + hi) * 0.5;
                var middle: State = undefined;
                for (0..6) |i| middle[i] = (2 * t * t * t - 3 * t * t + 1) * old.state[i] + (t * t * t - 2 * t * t + t) * usedH * d0[i] + (-2 * t * t * t + 3 * t * t) * out.ray.state[i] + (t * t * t - t * t) * usedH * d1[i];
                if (@cos(left[1]) * @cos(middle[1]) > 0) {
                    lo = t;
                    left = middle;
                } else {
                    hi = t;
                    right = middle;
                }
            }
            const hit = right;
            if (hit[0] >= config.diskInner and hit[0] <= config.diskOuter) {
                out.hits[out.hitCount] = .{ .radius = hit[0], .phi = hit[2], .time = hit[3], .cosine = @min(1, @abs(hit[5]) / hit[0]) };
                out.hitCount += 1;
            }
        }
    }
    return out;
}
test "ZAMO null initial conditions and Kerr invariant convergence" {
    const ray = cameraRay(.{}, 0.6, 0.63, 0.27);
    try std.testing.expect(invariantError(ray) < 1e-14);
    const result = trace(ray, .{});
    try std.testing.expect(result.outcome != .unresolved);
    try std.testing.expect(result.invariantError < 1e-7);
    try std.testing.expect(result.ray.state[3] < 0);
}
test "Schwarzschild critical impact parameter" {
    const camera: Camera = .{ .radius = 100, .inclination = std.math.pi / 2.0, .verticalFov = 0.2 };
    const critical = 3 * @sqrt(@as(f64, 3));
    for ([_]f64{ 0.999, 1.001 }) |factor| {
        const sine = critical * factor * @sqrt(1 - 2 / camera.radius) / camera.radius;
        const screen = sine / @sqrt(1 - sine * sine) / @tan(camera.verticalFov / 2);
        const result = trace(cameraRay(camera, 0, screen, 0), .{});
        try std.testing.expectEqual(if (factor < 1) Outcome.captured else Outcome.escaped, result.outcome);
    }
}
test "budget exhaustion and disk crossings" {
    const ray = cameraRay(.{}, 0.6, 0.8, 0.15);
    try std.testing.expectEqual(Outcome.unresolved, trace(ray, .{ .maxSteps = 1 }).outcome);
    const result = trace(cameraRay(.{}, 0.6, 1.2, -0.1), .{});
    try std.testing.expect(result.hitCount > 0);
    for (result.hits[0..result.hitCount]) |hit| try std.testing.expect(hit.radius >= 4 and hit.radius <= 18);
}
