const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp.zig");
const zut = @import("zut");
const log = std.log;

const ZigBuildParser = @import("ZigBuildParser.zig");

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    var buf: [256]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const workdir = buf[0 .. cwd.realPath(init.io, &buf) catch return log.info("Could not get working directory path", .{})];

    var parser = ZigBuildParser.create(allocator, init.io, init.environ_map, workdir) catch |err|
        return log.info("Could not initialize zig parser: {}", .{err});
    defer parser.destroy(init.io);

    parser.setStateChangeCallback(onDiagnostics);
    parser.run(init.io) catch return log.info("Could not start zig build parser", .{});

    var stdin_buf: [256]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buf);
    while (parser.running) {
        std.debug.print("> ", .{});
        const cmd = stdin.interface.takeDelimiterExclusive('\n') catch |err| {
            log.info("Command is too long ({})", .{err});
            continue;
        };
        if (std.ascii.eqlIgnoreCase(cmd, "q")) parser.running = false;
    }
}

// pub fn main(init: std.process.Init) void {
//     const allocator = init.gpa;
//
//     var server = lsp.Server{ .allocator = allocator };
//     server.run(init.io) catch |err| log.err("Encountered error while running server: {}\n", .{err});
// }

fn onDiagnostics(state: *const ZigBuildParser.State) void {
    zut.dbg.dump(state.diagnostics);
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
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

    std.debug.print(f, args);
}

test {
    std.testing.refAllDecls(@This());
}
