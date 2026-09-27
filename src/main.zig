const std = @import("std");
const thermal = @import("thermal.zig");
const scene = @import("scene.zig");
const gpu = @import("gpu.zig");

/// Own all application resources through the explicit Zig 0.16 process context.
pub fn main(init: std.process.Init) void {
    thermal.bsInstallSignals();
    run(init) catch |err| {
        std.debug.print("bSim: {s}\n", .{@errorName(err)});
        std.process.exit(if (err == error.Cancelled) 130 else 1);
    };
}
fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var outputBuffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &outputBuffer);
    defer output.interface.flush() catch |err| std.debug.print("output: {s}\n", .{@errorName(err)});
    const command = if (args.len > 1) args[1] else "help";
    const options = try @import("cli.zig").Options.parse(args);
    if (options.command == .render or options.command == .prepare) {
        var progress = try @import("progress.zig").Progress.init(init.io, options.json, options.noAnimation, init.environ_map.get("NO_COLOR") != null);
        defer progress.finish();
        var app = try @import("application.zig").App.init(init.gpa, init.io, &progress);
        defer app.deinit();
        var settings = try options.loadScene(init.gpa, init.io);
        if (options.command == .render) {
            try app.render(settings, options);
        } else {
            if (options.width == null) settings.quality.width = 1280;
            if (options.height == null) settings.quality.height = 720;
            const maps = try init.gpa.alloc(gpu.Map, @as(usize, settings.quality.width) * settings.quality.height);
            defer init.gpa.free(maps);
            try app.prepareMap(settings, options.time, maps);
        }
        return;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        const monitor = thermal.bsMonitorCreate();
        defer thermal.bsMonitorDestroy(monitor);
        const t = thermal.bsMonitorRead(monitor);
        try output.interface.print("bSim  Zig 0.16.0  ReleaseSafe\n\n  Battery  {d:.1} C\n  CPU      {d:.1} C\n  GPU      {d:.1} C\n  Sensors  {s}\n", .{ t.batteryC, t.cpuC, t.gpuC, if (t.valid != 0) "available" else "unavailable" });
    } else if (std.mem.eql(u8, command, "shots")) {
        try output.interface.writeAll("wide   Iconic equatorial composition\norbit  Oblique orbit\nclose  Close disk pass\n");
    } else if (options.command == .@"validate-export") {
        var settings = scene.Scene.preset(.wide);
        settings.quality.width = 16;
        settings.quality.height = 16;
        var pixels: [16 * 16 * 4]f32 = undefined;
        for (0..16 * 16) |i| {
            pixels[i * 4 ..][0..4].* = .{ 4, 2, 0.5, 1 };
        }
        try @import("output.zig").image(init.gpa, init.io, settings, .exr, "renders/export-check.exr", &pixels);
        try @import("output.zig").image(init.gpa, init.io, settings, .png, "renders/export-check.png", &pixels);
        try output.interface.writeAll("Saved linear EXR and 16-bit PNG fixtures\n");
    } else if (std.mem.eql(u8, command, "reference")) {
        var settings = scene.Scene.preset(.wide);
        settings.quality.width = 320;
        settings.quality.height = 180;
        try std.Io.Dir.cwd().createDirPath(init.io, "renders");
        try @import("reference.zig").render(init.gpa, init.io, settings, "renders/reference.ppm");
        try output.interface.writeAll("Saved renders/reference.ppm\n");
    } else if (std.mem.eql(u8, command, "validate-gpu")) {
        var message: [8192]u8 = undefined;
        const shader = @embedFile("shader");
        const context = gpu.bsGpuCreate(shader.ptr, shader.len, &message, message.len) orelse {
            try output.interface.print("Metal: {s}\n", .{std.mem.sliceTo(&message, 0)});
            return error.MetalFailure;
        };
        defer gpu.bsGpuDestroy(context);
        var settings = scene.Scene.preset(.wide);
        settings.quality.width = 64;
        settings.quality.height = 36;
        const maps = try init.gpa.alloc(gpu.Map, 64 * 36);
        defer init.gpa.free(maps);
        const monitor = thermal.bsMonitorCreate();
        defer thermal.bsMonitorDestroy(monitor);
        var scheduler: gpu.Scheduler = .{ .monitor = monitor };
        const seconds = try gpu.trace(context, &scheduler, init.io, settings, 0, maps);
        var unresolved: u32 = 0;
        var mismatch: u32 = 0;
        var errorMax: f64 = 0;
        for (maps, 0..) |map, i| {
            const sx = (2 * (@as(f64, @floatFromInt(i % 64)) + 0.5) - 64) / 36;
            const sy = 1 - 2 * (@as(f64, @floatFromInt(i / 64)) + 0.5) / 36;
            const geo = @import("geodesic.zig");
            const ref = geo.trace(geo.cameraRay(settings.camera, settings.spin, sx, sy), .{});
            if (map.info[0] == 3) unresolved += 1;
            if (@as(u32, @intFromFloat(map.info[0])) != @intFromEnum(ref.outcome) or map.sky[3] != @as(f32, @floatFromInt(ref.hitCount))) {
                mismatch += 1;
                try output.interface.print("mismatch {d}: {d}/{s}, hits {d}/{d}\n", .{ i, map.info[0], @tagName(ref.outcome), map.sky[3], ref.hitCount });
            }
            if (ref.hitCount > 0 and map.sky[3] > 0) errorMax = @max(errorMax, @abs(map.hits[0][0] - ref.hits[0].radius));
        }
        try output.interface.print("GPU {s}\nseconds {d:.4}\nunresolved {d}\nmismatches {d}\nmaximum radius error {e}\n", .{ gpu.bsGpuName(context), seconds, unresolved, mismatch, errorMax });
        if (mismatch != 0 or unresolved != 0 or errorMax > 0.001) return error.GpuValidationFailed;
    } else {
        try output.interface.writeAll("bSim doctor | shots\n");
    }
}
