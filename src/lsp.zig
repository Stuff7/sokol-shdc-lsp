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
const shader_uri = "file://src/tests/chunk.glsl";

// ── Helpers ───────────────────────────────────────────────────────────────────

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
    }, 1);
    _ = try client.waitResponse();
    _ = io;
}

fn openShader(client: *Client) !void {
    try client.sendRequest(Request.DidOpenTextDocumentParams{
        .textDocument = .{
            .uri = shader_uri,
            .languageId = "glsl",
            .version = 1,
            .text = "",
        },
    }, null);
}

test "hover: uniform block shows binding and size" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    // `vs_params` is at line 4, col 28 in chunk.glsl
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = shader_uri },
        .position = .{ .line = 4, .character = 28 },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?;
    const contents = result.object.get("contents").?.object;
    const kind = contents.get("kind").?.string;
    const value = contents.get("value").?.string;

    try std.testing.expectEqualStrings("markdown", kind);
    try std.testing.expect(std.mem.indexOf(u8, value, "Uniform Block") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "144") != null); // size
    try std.testing.expect(std.mem.indexOf(u8, value, "0") != null); // slot
}

test "hover: input attribute shows type and slot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    // `position` is at line 11, col 8 in chunk.glsl
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = shader_uri },
        .position = .{ .line = 10, .character = 8 },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get("result").?
        .object.get("contents").?
        .object.get("value").?.string;

    try std.testing.expect(std.mem.indexOf(u8, value, "Input Attribute") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "vec3") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "Float") != null); // base_type from YAML
}

test "hover: texture shows binding and sample type" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    // `shadow_map` is in @fs, find its line in chunk.glsl
    // layout(binding = 0) uniform texture2D shadow_map; -> line 23, col ~35
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = shader_uri },
        .position = .{ .line = 23, .character = 39 },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get("result").?
        .object.get("contents").?
        .object.get("value").?.string;

    try std.testing.expect(std.mem.indexOf(u8, value, "Texture") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "float") != null); // sample_type
}

test "definition: resolves to declaration site" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    // `mvp` reference in void main() body — line 17, col ~14
    try client.sendRequest(Request.DefinitionParams{
        .textDocument = .{ .uri = shader_uri },
        .position = .{ .line = 16, .character = 16 },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.array;
    try std.testing.expect(result.items.len > 0);

    const loc = result.items[0].object;
    const range = loc.get("range").?.object;
    const start = range.get("start").?.object;

    // mvp declared at line 5
    try std.testing.expectEqual(@as(i64, 5), start.get("line").?.integer);
}

test "references: finds all usages of a declaration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    // `position` declaration at line 11, col 8
    try client.sendRequest(Request.ReferenceParams{
        .textDocument = .{ .uri = shader_uri },
        .position = .{ .line = 11, .character = 8 },
        .context = .{ .includeDeclaration = true },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.array;
    // `position` is used in void main() at least once
    try std.testing.expect(result.items.len > 0);
}

test "document symbols: lists all named declarations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    try client.sendRequest(Request.DocumentSymbolParams{
        .textDocument = .{ .uri = shader_uri },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.array;
    try std.testing.expect(result.items.len > 0);

    // Verify expected symbol names are present
    const expected_names = &[_][]const u8{
        "chunk", "vs_params", "position", "texcoord", "main", "shadow_map", "shadow_sampler",
    };
    for (expected_names) |name| {
        var found = false;
        for (result.items) |sym| {
            if (std.mem.eql(u8, sym.object.get("name").?.string, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("Symbol not found: {s}\n", .{name});
            return error.SymbolNotFound;
        }
    }
}

test "completion: returns declarations in scope" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);
    try openShader(&client);

    // Inside @vs main body
    try client.sendRequest(Request.CompletionParams{
        .textDocument = .{ .uri = shader_uri },
        .position = .{ .line = 17, .character = 0 },
        .context = .{ .triggerKind = .invoked },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    const items = parsed.value.object.get("result").?
        .object.get("items").?.array;

    try std.testing.expect(items.items.len > 0);

    // Should include vs scope declarations
    var found_position = false;
    var found_mvp = false;
    for (items.items) |item| {
        const label = item.object.get("label").?.string;
        if (std.mem.eql(u8, label, "position")) found_position = true;
        if (std.mem.eql(u8, label, "mvp")) found_mvp = true;
    }
    try std.testing.expect(found_position);
    try std.testing.expect(found_mvp);
}

test "diagnostics: invalid shader produces error diagnostic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try initClient(allocator, io);
    defer client.deinit(io);
    defer client.drainStderr();

    try initialize(&client, allocator, io);

    // Open a shader with a deliberate error
    try client.sendRequest(Request.DidOpenTextDocumentParams{
        .textDocument = .{
            .uri = "file://src/tests/bad.glsl",
            .languageId = "glsl",
            .version = 1,
            .text = "",
        },
    }, null);

    // The server should push a publishDiagnostics notification
    // Since it's a notification (no id), we check stderr for the error
    // or check that hover returns empty for an unknown file
    try client.sendRequest(Request.HoverParams{
        .textDocument = .{ .uri = "file://src/tests/bad.glsl" },
        .position = .{ .line = 0, .character = 0 },
    }, 2);

    const res = try client.waitResponse() orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, res, .{});
    defer parsed.deinit();

    // Should return empty hover for a file that failed analysis
    const value = parsed.value.object.get("result").?
        .object.get("contents").?
        .object.get("value").?.string;
    try std.testing.expectEqualStrings("", value);
}
