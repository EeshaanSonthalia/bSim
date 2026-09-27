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
    const window = b.addSystemCommand(&.{ "/usr/bin/xcrun", "clang", "-c", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0" });
    window.addFileArg(b.path("native/window.m"));
    window.addArg("-o");
    exe.root_module.addObjectFile(window.addOutputFileArg("window.o"));
    const home = b.graph.environ_map.get("HOME") orelse @panic("HOME required for the global Nix profile");
    const profile = b.fmt("{s}/.local/state/dotfiles/nix-profile", .{home});
    const exrLib = b.graph.environ_map.get("BSIM_OPENEXR") orelse profile;
    const exrDev = b.graph.environ_map.get("BSIM_OPENEXR_DEV") orelse profile;
    const encoder = b.addSystemCommand(&.{ "/usr/bin/xcrun", "clang", "-c", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0" });
    encoder.addArg(b.fmt("-I{s}/include", .{exrDev}));
    const imathDev = b.graph.environ_map.get("BSIM_IMATH_DEV") orelse profile;
    encoder.addArg(b.fmt("-I{s}/include/OpenEXR", .{exrDev}));
    encoder.addArg(b.fmt("-I{s}/include/Imath", .{imathDev}));
    encoder.addFileArg(b.path("native/export.m"));
    encoder.addArg("-o");
    exe.root_module.addObjectFile(encoder.addOutputFileArg("export.o"));
    exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{exrLib}) });
    exe.root_module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{exrLib}) });
    exe.root_module.linkSystemLibrary("OpenEXRCore-3_4", .{});
    const sdk = std.mem.trim(u8, b.run(&.{ "/usr/bin/xcrun", "--show-sdk-path" }), "\r\n ");
    exe.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("ImageIO", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("MetalKit", .{});
    exe.root_module.linkFramework("MetalFX", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("MetalPerformanceShaders", .{});
    exe.root_module.addAnonymousImport("shader", .{ .root_source_file = b.path("shaders/renderer.metal") });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run bSim").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize }) });
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Check physics, scenes, and thermal policy").dependOn(&runTests.step);
}
