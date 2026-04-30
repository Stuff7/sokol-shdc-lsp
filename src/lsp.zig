const std = @import("std");

pub const response = @import("lsp/response.zig");
pub const Request = @import("lsp/Request.zig");
pub const Server = @import("lsp/Server.zig");
pub const Client = @import("lsp/Client.zig");
const Io = std.Io;

fn unixFileUri(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    const abs_path = buf[0..try std.Io.Dir.cwd().realPathFile(io, path, &buf)];
    return std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
}

const server_cmd = &.{"zig-out/bin/sokol-shdc-lsp-dbg"};

fn initClient(allocator: std.mem.Allocator, io: Io) !Client {
    return Client.init(allocator, io, server_cmd, .{});
}

fn initialize(client: *Client, allocator: std.mem.Allocator, io: Io) !void {
    _ = allocator;
    try client.sendRequest(Request.InitializeParams{
        .processId = null,
        .rootUri = null,
        .capabilities = .{
            .textDocument = .{
                .hover = .{ .contentFormat = &.{ "markdown", "plaintext" } },
                .completion = .{ .completionItem = .{ .snippetSupport = true } },
                .definition = .{ .dynamicRegistration = true },
                .references = .{ .dynamicRegistration = true },
            },
        },
    }, .{ .integer = 1 });
    _ = try client.waitResponse();
    _ = io;
}

const shader_text = @embedFile("tests/chunk.glsl");

test "server handles full neovim session: open, change, complete, shutdown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const uri = try unixFileUri(allocator, io, "src/tests/chunk.glsl");
    defer allocator.free(uri);

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try client.sendRequest(Request.InitializedParams{}, null);

    // open
    try client.sendRequest(Request.DidOpenTextDocumentParams{
        .textDocument = .{
            .uri = uri,
            .languageId = "glsl",
            .version = 1,
            .text = shader_text,
        },
    }, null);
    _ = try client.waitNotification();

    // semantic tokens
    try client.sendRequest(Request.SemanticTokensFull{
        .textDocument = .{ .uri = uri },
    }, .{ .integer = 2 });
    const tokens_res = try client.waitResponse() orelse return error.NoResponse;
    const tokens = try std.json.parseFromSlice(std.json.Value, allocator, tokens_res, .{});
    defer tokens.deinit();
    const token_data = tokens.value.object.get("result").?.object.get("data").?.array;
    try std.testing.expect(token_data.items.len > 0);

    // hover over builtin `texture` at line 35, char 14
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 35, .character = 15 },
    }, .{ .integer = 3 });
    const hover_res = try client.waitResponse() orelse return error.NoResponse;
    const hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_res, .{});
    defer hover.deinit();
    const hover_contents = hover.value.object.get("result").?.object.get("contents").?.object;
    try std.testing.expectEqualStrings("markdown", hover_contents.get("kind").?.string);
    try std.testing.expect(hover_contents.get("value").?.string.len > 0);

    // change — append a comment to trigger re-analysis
    const changed_text = shader_text ++ "// change\n";
    var content_changes = [1]Request.TextDocumentContentChangeEvent{.{ .text = changed_text }};
    try client.sendRequest(Request.DidChangeTextDocumentParams{
        .textDocument = .{ .uri = uri, .version = 2 },
        .contentChanges = &content_changes,
    }, null);
    // _ = try client.waitNotification();

    // completion at line 16 char 14 (inside main, after `mvp`)
    try client.sendRequest(Request.CompletionParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 16, .character = 14 },
    }, .{ .integer = 4 });
    const completion_res = try client.waitResponse() orelse return error.NoResponse;
    const completion = try std.json.parseFromSlice(std.json.Value, allocator, completion_res, .{});
    defer completion.deinit();
    const items = completion.value.object.get("result").?.object.get("items").?.array;
    try std.testing.expect(items.items.len > 0);
}
