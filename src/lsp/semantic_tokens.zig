const std = @import("std");
const response = @import("response.zig");
const common = @import("common.zig");

const Request = @import("Request.zig");
const Session = @import("Session.zig");
const FileAnalysis = @import("../parser/FileAnalysis.zig");
const Error = common.Error;
const Allocator = std.mem.Allocator;

const stringify = common.stringify;

const TokenType = enum(u32) {
    namespace = 0,
    type = 1,
    @"struct" = 5,
    variable = 8,
    property = 9,
    function = 12,
    keyword = 15,
};

const SemanticEntry = struct {
    line: u32,
    col: u32,
    len: u32,
    token_type: TokenType,
    modifiers: u32 = 0,
};

const mod_readonly: u32 = 1 << 2;
const mod_mutable: u32 = 1 << 10;

fn declTokenType(kind: FileAnalysis.DeclKind) ?TokenType {
    return switch (kind) {
        .vs_block, .fs_block, .cs_block, .named_block, .program, .module => .namespace,
        .@"struct", .uniform_block => .@"struct",
        .uniform_member => .property,
        .function => .function,
        .attr, .local_var, .storage_image => .variable,
        .texture, .sampler, .storage_buffer => .type,
        .ctype, .header => .keyword,
        else => null,
    };
}

fn appendSemanticEntry(list: *std.ArrayList(SemanticEntry), alloc: Allocator, kind: FileAnalysis.DeclKind, name: []const u8, range: FileAnalysis.Range) !void {
    const tt = declTokenType(kind) orelse return;
    const modifiers: u32 = switch (kind) {
        .attr => |a| if (a.is_input) mod_readonly else mod_mutable,
        else => 0,
    };
    try list.append(alloc, .{
        .line = range.start.line,
        .col = range.start.col,
        .len = @intCast(name.len),
        .token_type = tt,
        .modifiers = modifiers,
    });
}

pub fn createSemanticTokensResponse(self: *Session, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .semantic_tokens_full);
    const uri = req.params.semantic_tokens_full.value.textDocument.uri;

    const empty = response.SemanticTokensFull{ .id = req.id, .result = .{} };
    const analysis = self.getAnalysis(uri) orelse return stringify(allocator, empty);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var entries = std.ArrayList(SemanticEntry).empty;

    for (analysis.top_level) |*decl| {
        if (decl.name.len == 0) continue;
        try appendSemanticEntry(&entries, arena_alloc, decl.kind, decl.name, decl.range);
    }
    for (analysis.scopes) |*scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            try appendSemanticEntry(&entries, arena_alloc, decl.kind, decl.name, decl.range);
        }
        for (scope.references) |*ref| {
            const decl = ref.decl orelse continue;
            try appendSemanticEntry(&entries, arena_alloc, decl.kind, ref.name, ref.range);
        }
    }

    std.mem.sort(SemanticEntry, entries.items, {}, struct {
        fn lt(_: void, a: SemanticEntry, b: SemanticEntry) bool {
            return a.line < b.line or (a.line == b.line and a.col < b.col);
        }
    }.lt);

    var data = std.ArrayList(u32).empty;
    var prev_line: u32 = 0;
    var prev_col: u32 = 0;
    for (entries.items) |e| {
        const delta_line = e.line - prev_line;
        const delta_col = if (delta_line == 0) e.col - prev_col else e.col;
        try data.append(arena_alloc, delta_line);
        try data.append(arena_alloc, delta_col);
        try data.append(arena_alloc, e.len);
        try data.append(arena_alloc, @intFromEnum(e.token_type));
        try data.append(arena_alloc, e.modifiers);
        prev_line = e.line;
        prev_col = e.col;
    }

    return stringify(allocator, response.SemanticTokensFull{ .id = req.id, .result = .{ .data = data.items } });
}
