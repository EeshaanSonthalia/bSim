const std = @import("std");

/// Named cinematic compositions. Preset paths stay outside the horizon.
pub const Shot = enum { wide, orbit, close };
/// Camera values are Boyer-Lindquist coordinates in mass units and radians.
pub const Camera = struct {
    radius: f64 = 40,
    inclination: f64 = 1.48,
    azimuth: f64 = 0,
    verticalFov: f64 = 0.46,
    roll: f64 = 0,
    offsetX: f64 = 0,
    offsetY: f64 = 0,
    velocity: f64 = 0,
    orbitRate: f64 = 0.12,
    radialAmplitude: f64 = 0,
    inclinationAmplitude: f64 = 0,
    /// Evaluate the composition at an absolute scene time.
    pub fn at(self: Camera, time: f64) Camera {
        var result = self;
        result.azimuth += time * self.orbitRate;
        result.radius += self.radialAmplitude * @sin(time * 0.18);
        result.inclination += self.inclinationAmplitude * @sin(time * 0.22);
        return result;
    }
};
/// Deterministic material parameters in scene-linear Rec.709.
pub const Disk = struct {
    innerRadius: f64 = 4.0,
    outerRadius: f64 = 18,
    thickness: f64 = 0.10,
    extinction: f64 = 8,
    albedo: f64 = 0.12,
    anisotropy: f64 = 0.25,
    emission: f64 = 5,
    rotationSpeed: f64 = 2,
    color: [3]f64 = .{ 1, 0.57, 0.24 },
};
/// Display settings do not alter exported scene-linear EXR samples.
pub const Optics = struct { exposure: f64 = 0.9, flare: f64 = 0.12, flareRadius: f64 = 0.025 };
/// Final quality controls. A budget failure remains unresolved.
pub const Quality = struct {
    width: u32 = 3840,
    height: u32 = 2160,
    minSamples: u32 = 8,
    maxSamples: u32 = 64,
    relativeError: f64 = 0.02,
    tolerance: f64 = 0.000002,
    maxSteps: u32 = 4096,
    maxBounces: u32 = 12,
    guiding: bool = true,
};
/// Film timing. Shutter is an angle in degrees.
pub const Timing = struct { fps: u32 = 24, duration: f64 = 8, shutter: f64 = 180 };
/// Immutable after validation and command-line overrides. Own strings externally.
pub const Scene = struct {
    schemaVersion: u32 = 1,
    shot: Shot = .wide,
    spin: f64 = 0.6,
    seed: u32 = 1618033,
    camera: Camera = .{},
    disk: Disk = .{},
    optics: Optics = .{},
    quality: Quality = .{},
    timing: Timing = .{},
    /// Produce a complete preset with deterministic defaults.
    pub fn preset(shot: Shot) Scene {
        var scene: Scene = .{ .shot = shot };
        switch (shot) {
            .wide => scene.camera.orbitRate = 0.025,
            .orbit => scene.camera = .{ .radius = 34, .inclination = 1.22, .verticalFov = 0.60, .roll = -0.10, .orbitRate = 0.20, .inclinationAmplitude = 0.10 },
            .close => scene.camera = .{ .radius = 22, .inclination = 1.42, .verticalFov = 0.90, .offsetX = 0.22, .offsetY = -0.06, .roll = 0.12, .orbitRate = 0.09, .radialAmplitude = 2.5 },
        }
        return scene;
    }
    /// Reject unsupported versions, nonfinite values, and unbounded work.
    pub fn validate(self: Scene) error{InvalidScene}!void {
        if (self.schemaVersion != 1 or !finiteStruct(self) or @abs(self.spin) > 0.99) return error.InvalidScene;
        const horizon = 1 + @sqrt(1 - self.spin * self.spin);
        const c = self.camera;
        const d = self.disk;
        const q = self.quality;
        const t = self.timing;
        if (c.radius - @abs(c.radialAmplitude) < horizon + 1 or c.radius > 150 or c.verticalFov < 0.05 or c.verticalFov > 2.2 or
            c.inclination - @abs(c.inclinationAmplitude) < 0.02 or c.inclination + @abs(c.inclinationAmplitude) > std.math.pi - 0.02 or @abs(c.velocity) > 0.8 or
            d.innerRadius <= horizon + 0.2 or d.outerRadius <= d.innerRadius or d.outerRadius > 100 or d.thickness < 0.01 or d.thickness > 2 or
            d.extinction < 0 or d.extinction > 100 or d.albedo < 0 or d.albedo > 1 or @abs(d.anisotropy) > 0.9 or d.emission < 0 or d.emission > 1000 or
            q.width < 16 or q.height < 16 or q.width > 7680 or q.height > 4320 or q.minSamples < 1 or q.maxSamples < q.minSamples or q.maxSamples > 65536 or
            q.maxSteps < 32 or q.maxSteps > 65536 or q.maxBounces < 1 or q.maxBounces > 64 or q.tolerance < 1e-8 or q.tolerance > 1e-3 or q.relativeError < 0 or q.relativeError > 1 or
            (t.fps != 24 and t.fps != 30 and t.fps != 60) or t.duration <= 0 or t.duration > 3600 or t.shutter < 0 or t.shutter > 360 or
            self.optics.flare < 0 or self.optics.flare > 1 or self.optics.flareRadius < 0.001 or self.optics.flareRadius > 0.2 or self.optics.exposure < 0 or self.optics.exposure > 100) return error.InvalidScene;
        for (d.color) |channel| if (channel < 0 or channel > 1) return error.InvalidScene;
    }
};
fn finiteStruct(value: anytype) bool {
    switch (@typeInfo(@TypeOf(value))) {
        .float => return std.math.isFinite(value),
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!finiteStruct(@field(value, field.name))) return false;
        },
        .array => for (value) |element| {
            if (!finiteStruct(element)) return false;
        },
        else => {},
    }
    return true;
}
test "reject invalid geometry and versions" {
    var s = Scene.preset(.wide);
    try s.validate();
    s.camera.radius = 1;
    try std.testing.expectError(error.InvalidScene, s.validate());
    s = Scene.preset(.close);
    s.disk.albedo = std.math.nan(f64);
    try std.testing.expectError(error.InvalidScene, s.validate());
    s = .{ .schemaVersion = 2 };
    try std.testing.expectError(error.InvalidScene, s.validate());
}
