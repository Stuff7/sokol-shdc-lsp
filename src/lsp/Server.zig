const std = @import("std");
const common = @import("common.zig");
const response = @import("response.zig");
const log = std.log;
const json = std.json;

const State = @import("State.zig");
const Request = @import("Request.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

allocator: Allocator,
buffer: ArrayList(u8) = ArrayList(u8).empty,
stdout: ?*std.Io.Writer = undefined,
state: State,

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

    const res_bytes = res: switch (req.params) {
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
            if (try self.state.createDiagnosticsNotification(self.allocator, req.params.did_change.value.textDocument.uri)) |notif| {
                defer self.allocator.free(notif);
                try self.sendJSON(notif);
            }
            return;
        },
        .did_close => {
            self.state.handleDidClose(self.allocator, req);
            return;
        },
        .implementation => |params| {
            const resp = response.Implementation{
                .id = req.id,
                .result = &.{.{
                    .uri = params.value.textDocument.uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .type_definition => |params| {
            const resp = response.TypeDefinition{
                .id = req.id,
                .result = &.{.{
                    .uri = params.value.textDocument.uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .workspace_symbol => {
            const resp = response.WorkspaceSymbol{
                .id = req.id,
                .result = &.{.{
                    .name = "MySymbol",
                    .kind = .function,
                    .location = response.Location{
                        .uri = "file:///foo.zig",
                        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                    },
                    .containerName = null,
                }},
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .formatting => {
            const edit = common.TextEdit{
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                .newText = "formatted code",
            };
            const resp = response.DocumentFormatting{ .id = req.id, .result = &.{edit} };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .range_formatting => {
            const resp = response.DocumentRangeFormatting{
                .id = req.id,
                .result = &.{.{
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                    .newText = "formatted code",
                }},
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .on_type_formatting => {
            const resp = response.DocumentOnTypeFormatting{
                .id = req.id,
                .result = &.{.{
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                    .newText = "formatted code",
                }},
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .rename => |params| {
            const resp = response.Rename{
                .id = req.id,
                .result = .{
                    .changes = &.{.{
                        .uri = params.value.textDocument.uri,
                        .edits = &.{.{
                            .range = .{
                                .start = params.value.position,
                                .end = params.value.position,
                            },
                            .newText = params.value.newName,
                        }},
                    }},
                },
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .code_action => |params| {
            const resp = response.CodeAction{
                .id = req.id,
                .result = &.{.{
                    .title = "Mock fix",
                    .kind = null,
                    .diagnostics = params.value.context.diagnostics,
                    .edit = .{
                        .changes = &.{.{
                            .uri = params.value.textDocument.uri,
                            .edits = &.{.{
                                .range = params.value.range,
                                .newText = "fixed code",
                            }},
                        }},
                    },
                    .command = null,
                }},
            };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
        },
        .semantic_tokens_full => {
            const resp = response.SemanticTokensFull{ .id = req.id, .result = .{ .data = &.{} } };
            break :res try json.Stringify.valueAlloc(self.allocator, resp, .{});
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

    while (true) {
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
