const std = @import("std");
const builtin = @import("builtin");
const zut = @import("zut");
const ioutils = @import("io.zig");
const proc = @import("proc.zig");
const log = std.log;
const fmt = std.fmt;

const Io = std.Io;
const StdoutPoller = @import("StdoutPoller.zig");
const Allocator = std.mem.Allocator;

const dump = zut.dbg.dump;
const ansi = zut.utf8.ansi;

pub const State = struct {
    diagnostics: std.ArrayList(Diagnostic) = .empty,
};

pub const StateChangeCallback = *const fn (state: *const State, ctx: ?*anyopaque) void;

allocator: Allocator,
child_process: *std.process.Child,
running: bool,
zig_thread: ?std.Thread = null,
state_buf: [2]State,
last_state: *State = undefined,
draft_state: *State = undefined,
state_change_callback: ?StateChangeCallback = null,
ctx: ?*anyopaque = null,

pub fn create(allocator: Allocator, io: Io, env: *std.process.Environ.Map, workdir: []const u8) !*@This() {
    const zig_exe_path = proc.findZigPath(allocator, io, env) orelse return error.ZigPathNotFound;
    defer allocator.free(zig_exe_path);

    log.info("Workdir: {s}\nZig Exe: {s}", .{ workdir, zig_exe_path });

    const cmd: []const []const u8 = &.{
        zig_exe_path,
        "build",
        "check",
        "--watch",
        "--color",
        "off",
        "--summary",
        "none",
        "-freference-trace",
    };

    const child_process = try allocator.create(std.process.Child);

    child_process.* = try std.process.spawn(io, .{
        .argv = cmd,
        .stdout = .pipe,
        .stdin = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = workdir },
    });

    errdefer _ = proc.waitForProcess(io, child_process, "zig build");

    const self = try allocator.create(@This());
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .child_process = child_process,
        .running = false,
        .state_buf = .{ .{}, .{} },
    };

    return self;
}

pub fn setStateChangeCallback(self: *@This(), callback: ?StateChangeCallback, ctx: ?*anyopaque) void {
    self.state_change_callback = callback;
    self.ctx = ctx;
}

pub fn destroy(self: *@This(), io: Io) void {
    defer self.allocator.destroy(self);
    defer self.allocator.destroy(self.child_process);

    if (self.child_process.stdin) |*stdin| {
        stdin.close(io);
        self.child_process.stdin = null;
    }

    self.running = false;
    if (self.zig_thread) |t| t.join();
    for (&self.state_buf) |*s| s.diagnostics.deinit(self.allocator);

    if (self.child_process.id) |id| {
        proc.killProcessTree(io, id, self.child_process) catch
            log.err("Failed to close zig process tree", .{});
    }
}

pub fn run(self: *@This(), io: Io) !void {
    self.last_state = &self.state_buf[0];
    self.draft_state = &self.state_buf[1];
    self.running = true;
    self.zig_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, readBuildOutput, .{ self, io });
}

fn swapState(self: *@This()) void {
    const tmp = self.last_state;
    self.last_state = self.draft_state;
    self.draft_state = tmp;

    if (self.state_change_callback) |callback| callback(self.last_state, self.ctx);
}

fn handleChunk(self: *@This(), body: []const u8) !void {
    // log.debug("=== BODY ===\n{s}\n============", .{body});
    var r = Io.Reader.fixed(body);
    _ = r.discardDelimiterInclusive('\n') catch return error.UnexpectedBuildOutput;
    _ = r.discardDelimiterInclusive('\n') catch return error.UnexpectedBuildOutput;

    const diagnostics = &self.draft_state.diagnostics;
    diagnostics.clearRetainingCapacity();

    while (true) {
        try diagnostics.append(self.allocator, Diagnostic.init(&r) catch break);

        while (true) {
            const peeked = r.peekDelimiterInclusive('\n') catch break;
            if (!std.mem.startsWith(u8, peeked, "    ")) break;
            r.toss(peeked.len);
        }

        if (r.seek >= r.end) break;
    }

    self.swapState();
}

fn readBuildOutput(self: *@This(), io: Io) void {
    var poller = StdoutPoller.create(self.allocator, io, self.child_process.stderr.?, 50) catch return;
    defer poller.destroy(self.allocator);

    var buf = std.Io.Writer.Allocating.init(self.allocator);
    defer buf.deinit();

    const delimiter = "check\n";

    while (self.running) {
        const chunk = poller.next() orelse continue;
        buf.writer.writeAll(chunk) catch continue;

        const data = buf.written();
        const first = std.mem.indexOf(u8, data, delimiter) orelse continue;
        const rest = data[first + delimiter.len ..];
        const second = std.mem.indexOf(u8, rest, delimiter) orelse continue;

        const message = data[first .. first + delimiter.len + second];
        self.handleChunk(message) catch |err| log.err("Error handling chunk: {}", .{err});

        var r = Io.Reader.fixed(data);
        r.toss(first + delimiter.len + second);
        buf.clearRetainingCapacity();
        buf.writer.writeAll(r.buffered()) catch continue;
    }

    log.debug("Zig build parser thread has exited", .{});
}

const Diagnostic = struct {
    path: []const u8,
    kind: Kind,
    msg: []const u8,
    line: usize,
    column: usize,

    pub const Kind = enum {
        @"error",
        note,
    };

    fn init(r: *Io.Reader) !@This() {
        var path_info, const kind_int = ioutils.readUntilAny(r, &.{ ": error: ", ": note: " }) orelse return error.UnexpectedBuildHeader;
        const last_seek = r.seek;
        const msg = msg: while (true) {
            _ = try r.discardDelimiterInclusive('\n');
            const b = try r.peekByte();
            if (!std.ascii.isWhitespace(b)) break :msg r.buffer[last_seek..r.seek];
        } else "";

        const references_line = "referenced by:\n";
        if (std.ascii.startsWithIgnoreCase(try r.peek(references_line.len), references_line)) {
            r.toss(references_line.len);
        }

        if (path_info[0] == '/') if (ioutils.findRelativeReference(r)) |rel| {
            path_info = rel;
        };

        var it = std.mem.splitScalar(u8, path_info, ':');

        return .{
            .path = it.next() orelse return error.MissingMainPath,
            .kind = @enumFromInt(kind_int),
            .msg = msg,
            .line = fmt.parseInt(usize, it.next() orelse return error.MissingLine, 10) catch return error.UnexpectedBuildOutput,
            .column = fmt.parseInt(usize, it.next() orelse return error.MissingColumn, 10) catch return error.UnexpectedBuildOutput,
        };
    }
};

fn onStateChange(state: *const State, ctx: ?*anyopaque) void {
    const done: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
    defer done.store(true, .release);

    std.testing.expect(state.diagnostics.items.len == 5) catch {
        log.err("Expected 5 diagnostics got {}", .{state.diagnostics.items.len});
        return;
    };

    const expected_diagnostics = &[_]Diagnostic{
        .{
            .path = "src/main.zig",
            .kind = .@"error",
            .msg =
            \\invalid digit 'x' for decimal base
            \\    try list.append(gpa, 42xd);
            \\                           ^~
            \\
            ,
            .line = 14,
            .column = 28,
        },
        .{
            .path = "src/root.zig",
            .kind = .@"error",
            .msg =
            \\unused argument in 'Run `zig build test` to run the tests.
            \\                                                                         '
            \\            1 => @compileError("unused argument in '" ++ fmt ++ "'"),
            \\                 ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            \\
            ,
            .line = 9,
            .column = 21,
        },
        .{
            .path = "src/root.zig",
            .kind = .@"error",
            .msg =
            \\unused argument in 'ok.
            \\                                                                         '
            \\            1 => @compileError("unused argument in '" ++ fmt ++ "'"),
            \\                 ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            \\
            ,
            .line = 10,
            .column = 21,
        },
        .{
            .path = "src/root.zig",
            .kind = .@"error",
            .msg =
            \\variable of type 'comptime_int' must be const or comptime
            \\    var i = 4;
            \\        ^
            \\
            ,
            .line = 13,
            .column = 9,
        },
        .{
            .path = "src/root.zig",
            .kind = .note,
            .msg =
            \\to modify this variable at runtime, it must be given an explicit fixed-size number type
            \\
            ,
            .line = 13,
            .column = 9,
        },
    };

    for (expected_diagnostics, state.diagnostics.items, 0..) |expected, actual, i| {
        std.testing.expectEqualDeep(expected, actual) catch {
            log.err(ansi("Expected Diagnostic[{}]:", "1"), .{i});
            dump(expected);
            log.err(ansi("Got Diagnostic[{}]:", "1"), .{i});
            dump(actual);
            return;
        };
    }

    log.info(ansi("Diagnostics are as expected", "1;32"), .{});
}

test "run ZigBuildParser" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    var env = try std.testing.environ.createMap(allocator);
    defer env.deinit();

    var buf: [256]u8 = undefined;
    const cwd = Io.Dir.cwd();
    const workdir = buf[0..try cwd.realPathFile(std.testing.io, "./src/tests/project", &buf)];

    var done = std.atomic.Value(bool).init(false);
    const parser = try create(allocator, std.testing.io, &env, workdir);
    defer {
        while (!done.load(.acquire)) std.Thread.yield() catch {};
        parser.destroy(std.testing.io);
    }

    parser.setStateChangeCallback(onStateChange, @ptrCast(&done));
    try parser.run(std.testing.io);
}
