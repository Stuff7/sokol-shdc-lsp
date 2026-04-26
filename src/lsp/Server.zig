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
state: State = .{},

pub fn deinit(self: *@This()) void {
    self.buffer.deinit(self.allocator);
}

fn sendJSON(self: *@This(), content: []const u8) !void {
    var string = std.Io.Writer.Allocating.init(self.allocator);
    defer string.deinit();

    const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{content.len});
    defer self.allocator.free(header);

    log.debug("SEND: {s}\n", .{content});
    try self.stdout.?.print("{s}{s}", .{ header, content });
    try self.stdout.?.flush();
}

fn handleMessage(self: *@This(), message: []const u8) !void {
    log.debug("RECV: {s}\n", .{message});
    const req = try Request.parse(self.allocator, message);
    defer req.deinit();

    const res_bytes = res: switch (req.params) {
        .initialize => try self.state.createInitResponse(self.allocator, req),
        .completion => try self.state.createCompletionResponse(self.allocator, req),
        .hover => try self.state.createHoverResponse(self.allocator, req),
        .definition => |params| {
            var resp = response.Definition{
                .id = req.id,
                .result = &.{.{
                    .uri = params.value.textDocument.uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .references => |params| {
            var resp = response.References{
                .id = req.id,
                .result = &.{.{
                    .uri = params.value.textDocument.uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .implementation => |params| {
            var resp = response.Implementation{
                .id = req.id,
                .result = &.{.{
                    .uri = params.value.textDocument.uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .type_definition => |params| {
            var resp = response.TypeDefinition{
                .id = req.id,
                .result = &.{.{
                    .uri = params.value.textDocument.uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .document_symbol => |params| {
            var resp = response.DocumentSymbol{
                .id = req.id,
                .result = &.{.{
                    .name = "MySymbol",
                    .kind = .function,
                    .location = .{
                        .uri = params.value.textDocument.uri,
                        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                    },
                    .containerName = null,
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .workspace_symbol => {
            var resp = response.WorkspaceSymbol{
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
            break :res try resp.stringify(self.allocator);
        },
        .formatting => {
            const edit = common.TextEdit{
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                .newText = "formatted code",
            };
            var resp = response.DocumentFormatting{ .id = req.id, .result = &.{edit} };
            break :res try resp.stringify(self.allocator);
        },
        .range_formatting => {
            var resp = response.DocumentRangeFormatting{
                .id = req.id,
                .result = &.{.{
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                    .newText = "formatted code",
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .on_type_formatting => {
            var resp = response.DocumentOnTypeFormatting{
                .id = req.id,
                .result = &.{.{
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                    .newText = "formatted code",
                }},
            };
            break :res try resp.stringify(self.allocator);
        },
        .rename => |params| {
            const resp = response.Rename{
                .id = req.id,
                .result = .{
                    .changes = &.{.{
                        .uri = params.value.textDocument.uri,
                        .edits = &.{
                            .{
                                .range = .{
                                    .start = params.value.position,
                                    .end = params.value.position,
                                },
                                .newText = params.value.newName,
                            },
                        },
                    }},
                },
            };

            break :res try resp.stringify(self.allocator);
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

            break :res try resp.stringify(self.allocator);
        },
        .semantic_tokens_full => {
            var resp = response.SemanticTokensFull{ .id = req.id, .result = .{ .items = &.{} } };
            break :res try resp.stringify(self.allocator);
        },
        else => {
            log.debug("SKIP: {s}\n", .{message});
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
