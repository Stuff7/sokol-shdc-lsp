const std = @import("std");

const StdoutPoller = @import("../StdoutPoller.zig");
const Request = @import("Request.zig");
const common = @import("common.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

allocator: std.mem.Allocator,
child: *std.process.Child,
stdin_buf: []u8,
stdin_sink: *Io.File.Writer,
stdin: *Io.Writer,
req_sink: Io.Writer.Allocating,
res_sink: Io.Writer.Allocating,
res_poller: *StdoutPoller,
stderr_poller: *StdoutPoller,
io: Io,

pub const Options = struct {
    workdir: []const u8 = ".",
    stdout_timeout_ms: usize = 300,
    stderr_timeout_ms: usize = 100,
};

pub fn init(allocator: Allocator, io: Io, server_cmd: []const []const u8, opts: Options) !@This() {
    var child_proc = try allocator.create(std.process.Child);
    child_proc.* = try std.process.spawn(io, .{
        .argv = server_cmd,
        .stdout = .pipe,
        .stdin = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = opts.workdir },
    });

    const stdin_sink = try allocator.create(Io.File.Writer);
    const stdin_buf = try allocator.alloc(u8, 1024);
    stdin_sink.* = child_proc.stdin.?.writer(io, stdin_buf);

    return @This(){
        .allocator = allocator,
        .child = child_proc,
        .req_sink = .init(allocator),
        .res_sink = .init(allocator),
        .stdin_buf = stdin_buf,
        .stdin_sink = stdin_sink,
        .stdin = &stdin_sink.interface,
        .res_poller = try .create(allocator, io, child_proc.stdout.?, opts.stdout_timeout_ms),
        .stderr_poller = try .create(allocator, io, child_proc.stderr.?, opts.stderr_timeout_ms),
        .io = io,
    };
}

pub fn deinit(self: *@This(), io: Io) void {
    defer self.allocator.destroy(self.child);
    _ = self.child.wait(io) catch {};
    self.req_sink.deinit();
    self.res_sink.deinit();
    self.res_poller.destroy(self.allocator);
    self.stderr_poller.destroy(self.allocator);
    self.allocator.free(self.stdin_buf);
    self.allocator.destroy(self.stdin_sink);
    self.child.kill(io);
}

pub fn sendRequest(self: *@This(), req: anytype, id: ?common.Id) !void {
    try Request.stringify(req, id, &self.req_sink.writer);
    defer self.req_sink.clearRetainingCapacity();
    const request = self.req_sink.written();
    try self.stdin.print("Content-Length: {d}\r\n\r\n", .{request.len});
    try self.stdin.writeAll(request);
    try self.stdin.flush();
}

pub fn waitResponse(self: *@This()) !?[]const u8 {
    self.res_sink.clearRetainingCapacity();

    const header: Request.Header = while (true) {
        if (try Request.Header.parse(self.res_sink.written())) |h| break h;
        const chunk = self.res_poller.next() orelse return error.Timeout;
        try self.res_sink.writer.writeAll(chunk);
    };

    while (!header.hasBody(self.res_sink.written())) {
        const chunk = self.res_poller.next() orelse return error.UnexpectedEof;
        try self.res_sink.writer.writeAll(chunk);
    }

    return header.body(self.res_sink.written());
}

pub fn drainStderr(self: *@This()) void {
    const timeout = self.stderr_poller.timeout_ms;
    // Do not wait if there's no chunk ready on the first poll
    self.stderr_poller.timeout_ms = 0;

    var has_stderr = false;
    while (self.stderr_poller.next()) |chunk| {
        if (!has_stderr) {
            std.debug.print("=== BEGIN SERVER STDERR ===\n", .{});
            has_stderr = true;
        }
        self.stderr_poller.timeout_ms = timeout;
        std.debug.print("{s}", .{chunk});
    }

    if (has_stderr) std.debug.print("===  END SERVER STDERR  ===\n", .{});
}
