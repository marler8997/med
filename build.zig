const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11: bool = blk: {
        const x11_option = b.option(bool, "x11", "Use X11");
        break :blk switch (target.result.os.tag) {
            .linux => {
                if (x11_option == false) @panic("cannot disable x11 for linux target");
                break :blk true;
            },
            else => x11_option orelse false,
        };
    };

    const zin = b.dependency("zin", .{
        .x11 = x11,
    }).module("zin");

    const exe = b.addExecutable(.{
        .name = "med",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zin", .module = zin },
            },
            .single_threaded = true,
        }),
        .win32_manifest = b.path("res/med.manifest"),
    });

    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
        const res_inc = b.path("res/inc");
        exe.addIncludePath(res_inc);
        exe.addWin32ResourceFile(.{
            .file = b.path("res/med.rc"),
            .include_paths = &.{res_inc},
        });
    }

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    {
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install_exe.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("run", "Run the app").dependOn(&run.step);
    }

    addTermTest(b, target, optimize);
}

fn addTermTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "termtest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/termtest.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("termtest", "").dependOn(&run.step);
}
