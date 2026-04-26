//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub fn bufferedPrint(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{3});
    try stdout.print("ok.\n", .{4});
    // var x = "lol";
    // x = 12;
    var i = 4;
    i += 2;

    try stdout.flush();
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
