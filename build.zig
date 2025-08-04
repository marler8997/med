const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_x11_backend = blk: {
        if (b.option(bool, "x11", "enable the x11 backend")) |opt| break :blk opt;
        break :blk true;
    };

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_x11_backend", enable_x11_backend);

    const win32_dep = b.dependency("win32", .{});

    const exe = b.addExecutable(.{
        .name = "med",
        .root_source_file = switch (target.result.os.tag) {
            .windows => b.path("src/win32.zig"),
            else => b.path("src/posix.zig"),
        },
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .win32_manifest = b.path("res/med.manifest"),
    });
    exe.root_module.addOptions("build_options", build_options);

    if (enable_x11_backend) {
        const zigx_dep = b.dependency("x11", .{});
        exe.root_module.addImport("x", zigx_dep.module("x11"));
    }
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
        exe.mingw_unicode_entry_point = true;
        exe.root_module.addImport("win32", win32_dep.module("win32"));
        const res_inc = b.path("res/inc");
        exe.addIncludePath(res_inc);
        exe.addWin32ResourceFile(.{
            .file = b.path("res/med.rc"),
            .include_paths = &.{res_inc},
        });
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    addTermTest(b, target, optimize, win32_dep);
}

fn addTermTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    win32_dep: *std.Build.Dependency,
) void {
    const exe = b.addExecutable(.{
        .name = "termtest",
        .root_source_file = b.path("src/termtest.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    exe.root_module.addImport("win32", win32_dep.module("win32"));
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("termtest", "").dependOn(&run.step);
}
