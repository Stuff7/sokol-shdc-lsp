const std = @import("std");
const log = std.log;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const File = Io.File;
const MultiReader = Io.File.MultiReader;

const StreamEnum = enum(usize) { stdout = 0 };

io: Io,
mr: MultiReader,
mr_buf: MultiReader.Buffer(1),
sink: Writer.Allocating,
timeout_ms: usize,

pub fn create(allocator: Allocator, io: Io, stdout: File, timeout_ms: usize) !*@This() {
    const self = try allocator.create(@This());
    self.* = .{
        .io = io,
        .mr = undefined,
        .mr_buf = undefined,
        .sink = Writer.Allocating.init(allocator),
        .timeout_ms = timeout_ms,
    };
    MultiReader.init(&self.mr, allocator, io, self.mr_buf.toStreams(), &.{stdout});
    return self;
}

pub fn destroy(self: *@This(), allocator: Allocator) void {
    self.deinit();
    allocator.destroy(self);
}

pub fn init(allocator: Allocator, io: Io, stdout: File, timeout_ms: usize) @This() {
    var self: @This() = .{
        .io = io,
        .mr = undefined,
        .mr_buf = undefined,
        .sink = Writer.Allocating.init(allocator),
        .timeout_ms = timeout_ms,
    };
    MultiReader.init(&self.mr, allocator, io, self.mr_buf.toStreams(), &.{stdout});
    return self;
}

pub fn deinit(self: *@This()) void {
    self.mr.deinit();
    self.sink.deinit();
}

pub fn next(self: *@This()) ?[]const u8 {
    const timeout = Io.Timeout{
        .duration = .{
            .raw = .{ .nanoseconds = @as(i96, self.timeout_ms) * std.time.ns_per_ms },
            .clock = .awake,
        },
    };

    self.mr.fill(1, timeout) catch |err| switch (err) {
        error.Timeout, error.EndOfStream => return null,
        else => {
            log.err("Failed to poll process stdout: {}", .{err});
            return null;
        },
    };

    const r = self.mr.reader(0);
    const available = r.buffered();
    if (available.len == 0) return null;

    self.sink.clearRetainingCapacity();
    self.sink.writer.writeAll(available) catch |err| {
        log.err("Failed to write stdout data: {}", .{err});
        return null;
    };
    r.tossBuffered();

    return self.sink.written();
}
