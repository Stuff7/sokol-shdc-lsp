const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp.zig");
const zut = @import("zut");
const log = std.log;

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var log_buf: [512]u8 = undefined;
    const cwd = std.Io.Dir.cwd();

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.skip();
    const log_path = args.next() orelse "lsp.log";

    if (cwd.createFile(init.io, log_path, .{ .truncate = true })) |f| {
        log_file = f;
    } else |e| std.debug.print("Failed to create log file: {}", .{e});

    defer log_file.close(init.io);

    var w = log_file.writer(init.io, &log_buf);
    log_writer = &w.interface;
    defer log_writer = null;

    var server = lsp.Server.init(allocator, init.io) catch |err|
        return log.err("Encountered error while initializing server: {}\n", .{err});

    server.run(init.io) catch |err| log.err("Encountered error while running server: {}\n", .{err});
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .log_scope_levels = &.{
        .{ .scope = .yaml, .level = .warn },
        .{ .scope = .tokenizer, .level = .warn },
        .{ .scope = .parser, .level = .warn },
    },
    .logFn = logFn,
};

var log_file = std.Io.File.stderr();
var log_writer: ?*std.Io.Writer = null;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const w = log_writer orelse return;
    defer w.flush() catch {};

    const prefix = switch (scope) {
        log.default_log_scope => "",
        else => " [" ++ @tagName(scope) ++ "]: ",
    };

    const f = comptime zut.utf8.ansi(prefix ++ format, switch (level) {
        .err => "1;91", // bold red
        .warn => "1;93", // bold yellow
        .info => "94", // bright blue
        .debug => "38;5;245", // gray
    });

    w.print(f ++ "\n", args) catch {};
}

test {
    std.testing.refAllDecls(@This());
}
