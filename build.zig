const std = @import("std");
const sokol = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_zut = b.dependency("zut", .{ .target = target, .optimize = optimize });

    const NAME = "sokol-shdc-lsp";
    const suffix = switch (optimize) {
        .Debug => "-dbg",
        .ReleaseFast => "",
        .ReleaseSafe => "-s",
        .ReleaseSmall => "-sm",
    };

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zut", .module = dep_zut.module("zut") },
        },
    });

    const exe = b.addExecutable(.{
        .name = b.fmt("{s}{s}", .{ NAME, suffix }),
        .root_module = main_module,
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .name = NAME, .root_module = main_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);

    const check = b.addExecutable(.{ .name = "check", .root_module = main_module });
    const check_step = b.step("check", "Build for LSP");
    check_step.dependOn(&check.step);
    check_step.dependOn(&run_tests.step);
}
