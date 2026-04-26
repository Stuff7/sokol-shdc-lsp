const std = @import("std");

const Module = std.Build.Module;
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const NAME = "project";
    const suffix = switch (optimize) {
        .Debug => "-dbg",
        .ReleaseFast => "",
        .ReleaseSafe => "-s",
        .ReleaseSmall => "-sm",
    };
    var name_buf: [NAME.len + 4]u8 = undefined;
    const bin_name = std.fmt.bufPrint(@constCast(&name_buf), "{s}{s}", .{ NAME, suffix }) catch unreachable;

    const mod = b.addModule(NAME, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = NAME, .module = mod }},
    });

    const tests = b.addTest(.{ .root_module = main_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);

    const exe = b.addExecutable(.{ .name = bin_name, .root_module = main_module });
    b.installArtifact(exe);

    const check = b.addExecutable(.{ .name = bin_name, .root_module = main_module });
    const check_step = b.step("check", "Build for LSP Diagnostics");
    check_step.dependOn(&check.step);
    check_step.dependOn(&b.addTest(.{ .root_module = main_module }).step);
}
