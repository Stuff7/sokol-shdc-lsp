const std = @import("std");
const common = @import("common.zig");
const response = @import("response.zig");
const log = std.log;
const json = std.json;

const Session = @import("Session.zig");
const Request = @import("Request.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

allocator: Allocator,
buffer: ArrayList(u8) = ArrayList(u8).empty,
stdout: ?*std.Io.Writer = undefined,
state: Session,
running: bool = false,

pub fn init(allocator: Allocator, io: std.Io) !@This() {
    var state = Session.init(allocator, io);
    try state.initBuiltins(allocator);
    return .{ .allocator = allocator, .state = state };
}

pub fn deinit(self: *@This()) void {
    self.buffer.deinit(self.allocator);
}

fn sendJSON(self: *@This(), content: []const u8) !void {
    const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{content.len});
    defer self.allocator.free(header);

    log.debug("SEND: {s}", .{content});
    try self.stdout.?.print("{s}{s}", .{ header, content });
    try self.stdout.?.flush();
}

fn handleMessage(self: *@This(), message: []const u8) !void {
    log.debug("RECV: {s}", .{message});
    if (std.mem.indexOf(u8, message, "\"exit\"") != null) std.process.exit(0);
    const req = Request.parse(self.allocator, message) catch |err| switch (err) {
        error.MethodNotFound => return,
        else => return err,
    };
    defer req.deinit();

    const res_bytes = bytes: switch (req.params) {
        .initialize => try self.state.createInitResponse(self.allocator, req),
        .completion => try self.state.createCompletionResponse(self.allocator, req),
        .hover => try self.state.createHoverResponse(self.allocator, req),
        .definition => try self.state.createDefinitionResponse(self.allocator, req),
        .references => try self.state.createReferencesResponse(self.allocator, req),
        .document_symbol => try self.state.createDocumentSymbolResponse(self.allocator, req),
        .did_open => {
            try self.state.handleDidOpen(self.allocator, req);
            if (try self.state.createDiagnosticsNotification(self.allocator, req.params.did_open.value.textDocument.uri)) |notif| {
                defer self.allocator.free(notif);
                try self.sendJSON(notif);
            }
            return;
        },
        .did_change => {
            try self.state.handleDidChange(self.allocator, req);
            const refresh_bytes = try std.json.Stringify.valueAlloc(self.allocator, response.SemanticTokensRefresh{}, .{});
            defer self.allocator.free(refresh_bytes);
            try self.sendJSON(refresh_bytes);
            return;
        },
        .did_save => {
            try self.state.handleDidSave(self.allocator, req);
            const uri = req.params.did_save.value.textDocument.uri;
            if (try self.state.createDiagnosticsNotification(self.allocator, uri)) |notif| {
                defer self.allocator.free(notif);
                try self.sendJSON(notif);
            }
            const refresh_bytes = try std.json.Stringify.valueAlloc(self.allocator, response.SemanticTokensRefresh{}, .{});
            defer self.allocator.free(refresh_bytes);
            try self.sendJSON(refresh_bytes);
            return;
        },
        .did_close => {
            self.state.handleDidClose(self.allocator, req);
            return;
        },
        .signature_help => try self.state.createSignatureHelpResponse(self.allocator, req),
        .semantic_tokens_full => try self.state.createSemanticTokensResponse(self.allocator, req),
        .rename => try self.state.createRenameResponse(self.allocator, req),
        .shutdown => {
            self.running = false;
            break :bytes try json.Stringify.valueAlloc(self.allocator, response.NullResult{ .id = req.id }, .{});
        },
        else => {
            log.debug("SKIP: {s}", .{message});
            return;
        },
    };

    defer self.allocator.free(res_bytes);
    try self.sendJSON(res_bytes);
}

pub fn run(self: *@This(), io: std.Io) !void {
    var in_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &in_buf);
    var stdout_reader = std.Io.File.stdout().writer(io, &out_buf);

    const stdin = &stdin_reader.interface;
    self.stdout = &stdout_reader.interface;

    self.running = true;
    while (self.running) {
        const header = std.mem.trim(u8, try stdin.takeDelimiterInclusive('\n'), " \r\n");
        if (header.len == 0) continue;

        if (!std.ascii.startsWithIgnoreCase(header, "Content-Length: ")) continue;
        const length_str = header[16..];
        const content_length = std.fmt.parseInt(usize, length_str, 10) catch continue;

        _ = stdin.discardDelimiterInclusive('\n') catch continue;

        self.buffer.clearRetainingCapacity();
        try self.buffer.resize(self.allocator, content_length);
        try stdin.readSliceAll(self.buffer.items);

        try self.handleMessage(self.buffer.items);
    }
}
