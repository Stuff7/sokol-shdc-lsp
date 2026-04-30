const std = @import("std");

pub const response = @import("lsp/response.zig");
pub const Request = @import("lsp/Request.zig");
pub const Server = @import("lsp/Server.zig");
pub const Client = @import("lsp/Client.zig");
const Io = std.Io;

fn unixFileUri(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const abs_path = buf[0..try std.Io.Dir.cwd().realPathFile(io, path, &buf)];
    return std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
}

const server_cmd = &.{"zig-out/bin/sokol-shdc-lsp-dbg"};

fn initClient(allocator: std.mem.Allocator, io: Io) !Client {
    return Client.init(allocator, io, server_cmd, .{});
}

fn initialize(client: *Client, io: Io) !void {
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = std.testing.io;

    const uri = try unixFileUri(allocator, io, "src/tests/chunk.glsl");

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, io);
    try client.sendRequest(Request.InitializedParams{}, null);

    // didOpen
    try client.sendRequest(Request.DidOpenTextDocumentParams{
        .textDocument = .{
            .uri = uri,
            .languageId = "glsl",
            .version = 1,
            .text = shader_text,
        },
    }, null);
    _ = try client.waitNotification(); // drain diagnostics notification

    // semantic tokens
    try client.sendRequest(Request.SemanticTokensFull{
        .textDocument = .{ .uri = uri },
    }, .{ .integer = 2 });
    const tokens_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const tokens = try std.json.parseFromSlice(std.json.Value, allocator, tokens_res, .{});
        defer tokens.deinit();
        const data = tokens.value.object.get("result").?.object.get("data").?.array;
        try std.testing.expect(data.items.len >= 25); // 5+ tokens × 5 u32s each
    }

    // hover: builtin `texture` (line 35, char 17)
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 35, .character = 17 },
    }, .{ .integer = 3 });
    const hover_builtin_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_builtin_res, .{});
        defer hover.deinit();
        const contents = hover.value.object.get("result").?.object.get("contents").?.object;
        try std.testing.expectEqualStrings("markdown", contents.get("kind").?.string);
        const value = contents.get("value").?.string;
        try std.testing.expect(std.mem.indexOf(u8, value, "texture") != null);
        try std.testing.expect(std.mem.indexOf(u8, value, "vec4") != null);
    }

    // hover: uniform member `mvp` (line 16, char 16)
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 16, .character = 16 },
    }, .{ .integer = 4 });
    const hover_mvp_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_mvp_res, .{});
        defer hover.deinit();
        const contents = hover.value.object.get("result").?.object.get("contents").?.object;
        try std.testing.expectEqualStrings("markdown", contents.get("kind").?.string);
        const value = contents.get("value").?.string;
        try std.testing.expect(std.mem.indexOf(u8, value, "mvp") != null);
        try std.testing.expect(std.mem.indexOf(u8, value, "mat4") != null);
    }

    // hover: blank line — null result (line 14, char 0)
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 14, .character = 0 },
    }, .{ .integer = 5 });
    const hover_null_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_null_res, .{});
        defer hover.deinit();
        const result_val = hover.value.object.get("result");
        try std.testing.expect(result_val == null or result_val.? == .null);
    }

    // definition: `mvp` → declaration (line 16, char 16)
    try client.sendRequest(Request.DefinitionParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 16, .character = 16 },
    }, .{ .integer = 6 });
    const def_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const def = try std.json.parseFromSlice(std.json.Value, allocator, def_res, .{});
        defer def.deinit();
        const locs = def.value.object.get("result").?.array;
        try std.testing.expect(locs.items.len >= 1);
        try std.testing.expect(std.mem.indexOf(u8, locs.items[0].object.get("uri").?.string, "chunk.glsl") != null);
    }

    // references: `xd` call sites (line 30, char 6)
    // TODO: server ignores includeDeclaration; only call sites returned.
    try client.sendRequest(Request.ReferenceParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 30, .character = 6 },
        .context = .{ .includeDeclaration = true },
    }, .{ .integer = 7 });
    const refs_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const refs = try std.json.parseFromSlice(std.json.Value, allocator, refs_res, .{});
        defer refs.deinit();
        const locs = refs.value.object.get("result").?.array;
        try std.testing.expect(locs.items.len >= 1);
    }

    // signature help: inside `xd(` args (line 36, char 15)
    try client.sendRequest(Request.SignatureHelpParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 36, .character = 15 },
    }, .{ .integer = 8 });
    const sig_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const sig = try std.json.parseFromSlice(std.json.Value, allocator, sig_res, .{});
        defer sig.deinit();
        const sigs = sig.value.object.get("result").?.object.get("signatures").?.array;
        try std.testing.expect(sigs.items.len >= 1);
        try std.testing.expect(std.mem.indexOf(u8, sigs.items[0].object.get("label").?.string, "xd") != null);
    }

    // rename: `xd` → `my_func` (line 30, char 6)
    try client.sendRequest(Request.RenameParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 30, .character = 6 },
        .newName = "my_func",
    }, .{ .integer = 9 });
    const rename_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const rename = try std.json.parseFromSlice(std.json.Value, allocator, rename_res, .{});
        defer rename.deinit();
        const edits = rename.value.object.get("result").?.object.get("changes").?.object.get(uri).?.array;
        try std.testing.expect(edits.items.len >= 2);
        for (edits.items) |edit| {
            try std.testing.expectEqualStrings("my_func", edit.object.get("newText").?.string);
        }
    }

    // didChange
    const changed_text = shader_text ++ "// change\n";
    var content_changes = [1]Request.TextDocumentContentChangeEvent{.{ .text = changed_text }};
    try client.sendRequest(Request.DidChangeTextDocumentParams{
        .textDocument = .{ .uri = uri, .version = 2 },
        .contentChanges = &content_changes,
    }, null);

    // completion: uniform member `mvp` present (line 16, char 16)
    try client.sendRequest(Request.CompletionParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 16, .character = 16 },
    }, .{ .integer = 10 });
    const completion_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const completion = try std.json.parseFromSlice(std.json.Value, allocator, completion_res, .{});
        defer completion.deinit();
        const items = completion.value.object.get("result").?.object.get("items").?.array;
        try std.testing.expect(items.items.len > 0);
        var found_mvp = false;
        for (items.items) |item| {
            if (std.mem.eql(u8, item.object.get("label").?.string, "mvp")) {
                found_mvp = true;
                try std.testing.expect(std.mem.indexOf(u8, item.object.get("detail").?.string, "mat4") != null);
                break;
            }
        }
        try std.testing.expect(found_mvp);
    }

    // completion: builtin `texture` present (line 36, char 15)
    try client.sendRequest(Request.CompletionParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 36, .character = 15 },
    }, .{ .integer = 11 });
    const builtin_completion_res = try client.waitResponse() orelse return error.NoResponse;
    {
        const completion = try std.json.parseFromSlice(std.json.Value, allocator, builtin_completion_res, .{});
        defer completion.deinit();
        const items = completion.value.object.get("result").?.object.get("items").?.array;
        var found_texture = false;
        for (items.items) |item| {
            if (std.mem.eql(u8, item.object.get("label").?.string, "texture")) {
                found_texture = true;
                try std.testing.expect(item.object.get("detail").?.string.len > 0);
                break;
            }
        }
        try std.testing.expect(found_texture);
    }
}
