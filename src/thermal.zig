const std = @import("std");
/// Native ABI for a fresh maximum-temperature sample.
pub const Temperatures = extern struct { batteryC: f64, cpuC: f64, gpuC: f64, sampleTime: f64, thermalState: u32, valid: u32 };
/// Exclusive owner of the read-only platform connection.
pub const Monitor = opaque {};
/// Create a monitor, or return null when platform access fails.
pub extern fn bsMonitorCreate() ?*Monitor;
/// Release a monitor. Accepts null.
pub extern fn bsMonitorDestroy(monitor: ?*Monitor) void;
/// Read current sensor maxima. Check validity before scheduling work.
pub extern fn bsMonitorRead(monitor: ?*Monitor) Temperatures;
/// Monotonic seconds, using the same clock as each sample.
pub extern fn bsMonotonicTime() f64;
/// Result of the mandatory scheduling gate.
pub const Decision = enum { proceed, cool, sensorFailure };
/// Hysteresis state owned by the scheduler. No override is exposed.
pub const Guard = struct {
    paused: bool = true,
    peakBattery: f64 = 0,
    peakCpu: f64 = 0,
    peakGpu: f64 = 0,
    /// Fail closed on invalid or expired samples. Update observed maxima.
    pub fn evaluate(self: *Guard, t: Temperatures, now: f64) Decision {
        if (t.valid == 0 or !std.math.isFinite(now) or !std.math.isFinite(t.sampleTime) or now - t.sampleTime > 1 or now < t.sampleTime or
            !validTemperature(t.batteryC) or !validTemperature(t.cpuC) or !validTemperature(t.gpuC)) return .sensorFailure;
        self.peakBattery = @max(self.peakBattery, t.batteryC);
        self.peakCpu = @max(self.peakCpu, t.cpuC);
        self.peakGpu = @max(self.peakGpu, t.gpuC);
        if (t.batteryC >= 37.5 or t.cpuC >= 75 or t.gpuC >= 75 or t.thermalState != 0) self.paused = true;
        if (self.paused and t.batteryC <= 36 and t.cpuC <= 65 and t.gpuC <= 65 and t.thermalState == 0) self.paused = false;
        return if (self.paused) .cool else .proceed;
    }
};
fn validTemperature(t: f64) bool {
    return std.math.isFinite(t) and t > 0 and t < 130;
}
comptime {
    std.debug.assert(@sizeOf(Temperatures) == 40);
}
test "thermal hysteresis and unavailable sensors fail closed" {
    var guard: Guard = .{};
    var t: Temperatures = .{ .batteryC = 35, .cpuC = 60, .gpuC = 60, .sampleTime = 1, .thermalState = 0, .valid = 1 };
    try std.testing.expectEqual(Decision.proceed, guard.evaluate(t, 1));
    t.batteryC = 37.5;
    try std.testing.expectEqual(Decision.cool, guard.evaluate(t, 1));
    t.batteryC = 36.5;
    try std.testing.expectEqual(Decision.cool, guard.evaluate(t, 1));
    t.batteryC = 36;
    try std.testing.expectEqual(Decision.proceed, guard.evaluate(t, 1));
    try std.testing.expectEqual(Decision.sensorFailure, guard.evaluate(t, 3));
    t.cpuC = std.math.nan(f64);
    try std.testing.expectEqual(Decision.sensorFailure, guard.evaluate(t, 1));
}
