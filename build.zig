const std = @import("std");

/// Build the ReleaseSafe application and the isolated mathematical tests.
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.16.0")) @panic("Zig 0.16.0 required");
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .ReleaseSafe;
    const exe = b.addExecutable(.{
        .name = "bSim",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    const native = b.addSystemCommand(&.{ "/usr/bin/xcrun", "clang", "-c", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0" });
    native.addFileArg(b.path("native/thermal.m"));
    native.addArg("-o");
    exe.root_module.addObjectFile(native.addOutputFileArg("thermal.o"));
    const renderer = b.addSystemCommand(&.{ "/usr/bin/xcrun", "clang", "-c", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0" });
    renderer.addFileArg(b.path("native/renderer.m"));
    renderer.addArg("-o");
    exe.root_module.addObjectFile(renderer.addOutputFileArg("renderer.o"));
    const sdk = std.mem.trim(u8, b.run(&.{ "/usr/bin/xcrun", "--show-sdk-path" }), "\r\n ");
    exe.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.addAnonymousImport("shader", .{ .root_source_file = b.path("shaders/renderer.metal") });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run bSim").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Check physics, scenes, and thermal policy").dependOn(&runTests.step);
}
