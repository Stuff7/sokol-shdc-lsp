const std = @import("std");
const builtin = @import("builtin");
const ioutils = @import("io.zig");
const fmt = std.fmt;
const log = std.log;

const Io = std.Io;
const Child = std.process.Child;
const Allocator = std.mem.Allocator;

const is_windows = builtin.target.os.tag == .windows;

/// `std.process.Child.kill` does not kill subprocesses.
pub fn killProcessTree(io: Io, pid: i32, child_process: ?*Child) !void {
    comptime if (is_windows) {
        _ = try child_process.?.kill();
        return;
    };

    var buf: [256]u8 = undefined;
    const path = try fmt.bufPrint(&buf, "/proc/{}/task/{}/children", .{ pid, pid });

    const proc_children = try Io.Dir.cwd().readFile(io, path, &buf);

    var children = std.mem.splitScalar(u8, proc_children, ' ');
    while (children.next()) |n| {
        if (n.len == 0) continue;
        const cpid = try fmt.parseInt(i32, n, 10);
        try killProcessTree(io, cpid, null);
    }

    if (std.os.linux.kill(pid, std.c.SIG.KILL) == -1) {
        return error.ProcessKill;
    }
}

pub fn findZigPath(allocator: Allocator, io: Io, env: *std.process.Environ.Map) ?[]const u8 {
    const path_env = env.get("PATH") orelse return null;

    var path_iter = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);

    while (path_iter.next()) |dir_path| {
        const zig_path = std.fs.path.join(allocator, &.{ dir_path, "zig" }) catch continue;
        defer allocator.free(zig_path);

        std.Io.Dir.accessAbsolute(io, zig_path, .{}) catch continue;
        return allocator.dupe(u8, zig_path) catch null;
    }

    return null;
}

pub fn waitForProcess(io: Io, process: *Child, process_name: []const u8) bool {
    const result = process.wait(io) catch |err| {
        std.log.warn("Failed to wait for {s}: {}", .{ process_name, err });
        return false;
    };

    switch (result) {
        .exited => |code| {
            if (code != 0) {
                std.log.warn("{s} failed with exit code: {}", .{ process_name, code });
                return false;
            }
        },
        else => {
            std.log.warn("{s} terminated abnormally: {}", .{ process_name, result });
            return false;
        },
    }

    return true;
}
