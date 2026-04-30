const std = @import("std");
const response = @import("response.zig");
const common = @import("common.zig");
const format = @import("format.zig");
const helpers = @import("helpers.zig");
const json = std.json;

const ShdcRunner = @import("../parser/ShdcRunner.zig");
const FileAnalysis = @import("../parser/FileAnalysis.zig");
const Request = @import("Request.zig");
const Error = common.Error;
const Allocator = std.mem.Allocator;
const BuiltinFunction = common.BuiltinFunction;
const BuiltinParam = common.BuiltinParam;

const stringify = helpers.stringify;
const uriToPath = helpers.uriToPath;
const pathToUri = helpers.pathToUri;
const posToOffset = helpers.posToOffset;
const wordAt = helpers.wordAt;

support: helpers.Support = .{},
workspace: []const u8 = "",
files: std.StringHashMap(helpers.FileEntry),
io: std.Io,
runner_config: ShdcRunner.Config = .{},
builtins: std.StringHashMap([]BuiltinFunction),
builtin_types: std.StringHashMap([]const u8),

const Self = @This();

pub fn init(allocator: Allocator, io: std.Io) Self {
    return .{
        .files = .init(allocator),
        .builtins = .init(allocator),
        .builtin_types = .init(allocator),
        .io = io,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    var bit = self.builtins.iterator();
    while (bit.next()) |entry| {
        for (entry.value_ptr.*) |f| {
            for (f.parameters) |p| {
                allocator.free(p.type);
                allocator.free(p.name);
            }
            if (f.description) |desc| {
                for (desc) |s| allocator.free(s);
                allocator.free(desc);
            }
            allocator.free(f.parameters);
            allocator.free(f.return_type);
        }
        allocator.free(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    self.builtins.deinit(allocator);
}

pub fn initBuiltins(self: *Self, allocator: Allocator) !void {
    const data = @embedFile("../spec.json");

    const Root = struct {
        functions: []BuiltinFunction,
    };

    const parsed = try json.parseFromSlice(Root, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    for (parsed.value.functions) |f| {
        const entry = try self.builtins.getOrPut(f.name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, f.name);
            entry.value_ptr.* = &.{};
        }
        const old = entry.value_ptr.*;
        const new = try allocator.realloc(old, old.len + 1);
        var params = try allocator.alloc(BuiltinParam, f.parameters.len);
        for (f.parameters, 0..) |p, i| {
            params[i] = .{
                .type = try allocator.dupe(u8, p.type),
                .name = try allocator.dupe(u8, p.name),
            };
        }
        new[old.len] = .{
            .return_type = try allocator.dupe(u8, f.return_type),
            .name = entry.key_ptr.*,
            .parameters = params,
            .description = if (f.description) |desc| blk: {
                var duped = try allocator.alloc([]const u8, desc.len);
                for (desc, 0..) |s, i| duped[i] = try allocator.dupe(u8, s);
                break :blk duped;
            } else null,
        };
        entry.value_ptr.* = new;
    }

    const Types = struct { types: []struct { name: []const u8, description: ?[][]const u8 = null } };
    const parsed_types = try json.parseFromSlice(Types, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed_types.deinit();
    for (parsed_types.value.types) |t| {
        const desc = if (t.description) |d| try std.mem.join(allocator, "\n\n", d) else try allocator.dupe(u8, "");
        try self.builtin_types.put(try allocator.dupe(u8, t.name), desc);
    }
}

pub fn createInitResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .initialize);
    const params = req.params.initialize.value;

    self.workspace = if (params.rootUri) |uri| try allocator.dupe(u8, uri) else "";
    self.support.applyClientCapabilities(params.capabilities);

    const td = params.capabilities.textDocument;
    const resp = response.Initialize{
        .id = req.id,
        .result = .{
            .capabilities = .{
                .renameProvider = true,
                .textDocumentSync = .full,
                .hoverProvider = td != null and td.?.hover != null,
                .completionProvider = if (td != null and td.?.completion != null)
                    .{ .resolveProvider = true, .triggerCharacters = &.{ ".", ">" } }
                else
                    null,
                .definitionProvider = td != null and td.?.definition != null,
                .referencesProvider = td != null and td.?.references != null,
                .workspaceSymbolProvider = true,
                .documentFormattingProvider = td != null and td.?.documentFormatting != null,
                .documentRangeFormattingProvider = td != null and td.?.documentFormatting != null,
                .signatureHelpProvider = .{},
                .semanticTokensProvider = .{
                    .legend = .{
                        .tokenTypes = &.{
                            "namespace",  "type",          "class",     "enum",     "interface",
                            "struct",     "typeParameter", "parameter", "variable", "property",
                            "enumMember", "event",         "function",  "method",   "macro",
                            "keyword",    "modifier",      "comment",   "string",   "number",
                            "regexp",     "operator",      "decorator",
                        },
                        .tokenModifiers = &.{
                            "declaration",   "definition",     "readonly", "static",
                            "deprecated",    "abstract",       "async",    "modification",
                            "documentation", "defaultLibrary", "mutable",
                        },
                    },
                    .full = true,
                },
            },
        },
    };
    return stringify(allocator, resp);
}

pub fn createHoverResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .hover);
    const params = req.params.hover.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const null_result = response.NullResult{ .id = req.id };
    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, null_result);

    const decl = analysis.declAtPos(pos) orelse {
        const offset = posToOffset(analysis.source, pos);
        const word = wordAt(analysis.source, offset);
        if (word.len > 0) {
            if (try helpers.hoverBuiltin(allocator, &self.builtins, &self.builtin_types, req.id, word)) |bytes| {
                return bytes;
            }
        }
        return stringify(allocator, null_result);
    };

    const use_markdown = self.support.has(.markdown);
    const content = if (use_markdown)
        try format.declToMarkdown(allocator, decl.name, decl.*)
    else
        try format.declToPlaintext(allocator, decl.name, decl.*);
    defer allocator.free(content);

    const resp = response.Hover{
        .id = req.id,
        .result = .{
            .contents = .{ .kind = if (use_markdown) .markdown else .plaintext, .value = content },
            .range = FileAnalysis.faRangeToLsp(decl.range),
        },
    };
    return stringify(allocator, resp);
}

pub fn createDefinitionResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .definition);
    const params = req.params.definition.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty = response.Definition{ .id = req.id, .result = &.{} };

    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, empty);
    const decl = analysis.declAtPos(pos) orelse return stringify(allocator, empty);

    const decl_uri = if (std.mem.eql(u8, decl.range.file, uriToPath(uri)))
        uri
    else
        try pathToUri(allocator, decl.range.file);
    defer if (!std.mem.eql(u8, decl_uri, uri)) allocator.free(decl_uri);

    const resp = response.Definition{
        .id = req.id,
        .result = &.{.{
            .uri = decl_uri,
            .range = FileAnalysis.faRangeToLsp(decl.range),
        }},
    };
    return stringify(allocator, resp);
}

pub fn createReferencesResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .references);
    const params = req.params.references.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty = response.References{ .id = req.id, .result = &.{} };

    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, empty);
    const target_decl = analysis.declAtPos(pos) orelse return stringify(allocator, empty);

    var locs = std.ArrayList(response.Location).empty;
    defer locs.deinit(allocator);

    for (analysis.scopes) |*scope| {
        for (scope.references) |*ref| {
            if (ref.decl == target_decl) {
                try locs.append(allocator, .{
                    .uri = uri,
                    .range = FileAnalysis.faRangeToLsp(ref.range),
                });
            }
        }
    }

    const resp = response.References{ .id = req.id, .result = locs.items };
    return stringify(allocator, resp);
}

pub fn createDocumentSymbolResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .document_symbol);
    const params = req.params.document_symbol.value;
    const uri = params.textDocument.uri;

    const empty = response.DocumentSymbol{ .id = req.id, .result = &.{} };
    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, empty);

    var symbols = std.ArrayList(response.SymbolInformation).empty;
    defer symbols.deinit(allocator);

    for (analysis.top_level) |*decl| {
        if (decl.name.len == 0) continue;
        try symbols.append(allocator, .{
            .name = decl.name,
            .kind = format.declToSymbolKind(decl.kind),
            .location = .{ .uri = uri, .range = FileAnalysis.faRangeToLsp(decl.range) },
            .containerName = null,
        });
    }

    for (analysis.scopes) |*scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            if (decl.kind == .local_var) continue;
            try symbols.append(allocator, .{
                .name = decl.name,
                .kind = format.declToSymbolKind(decl.kind),
                .location = .{ .uri = uri, .range = FileAnalysis.faRangeToLsp(decl.range) },
                .containerName = scope.name,
            });
        }
    }

    const resp = response.DocumentSymbol{ .id = req.id, .result = symbols.items };
    return stringify(allocator, resp);
}

pub fn createCompletionResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .completion);
    const params = req.params.completion.value;
    const uri = params.textDocument.uri;
    const pos = params.position;

    const empty = response.Completion{ .id = req.id, .result = .{ .items = &.{} } };
    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, empty);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const active_scope: ?*FileAnalysis.Scope = for (analysis.scopes) |*scope| {
        if (FileAnalysis.lspPosInFaRange(pos, scope.range)) break scope;
    } else null;

    var items = std.ArrayList(common.CompletionItem).empty;
    defer items.deinit(arena_alloc);

    const supports_snippets = self.support.has(.snippets);

    if (active_scope) |scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            if (decl.kind == .uniform_block) continue;

            const detail = try format.declDetail(arena_alloc, decl.*);
            const insert_text = if (supports_snippets and decl.kind == .function)
                try format.functionSnippet(arena_alloc, decl.name, decl.kind.function)
            else
                try arena_alloc.dupe(u8, decl.name);

            try items.append(arena_alloc, .{
                .label = decl.name,
                .kind = format.declToSymbolKind(decl.kind),
                .detail = detail,
                .insertText = insert_text,
                .insertTextFormat = if (supports_snippets and decl.kind == .function) .snippet else .text,
            });
        }
    }

    var builtin_it = self.builtins.iterator();
    while (builtin_it.next()) |entry| {
        const overloads = entry.value_ptr.*;
        if (overloads.len == 0) continue;
        const f = overloads[0];
        var detail_buf = std.Io.Writer.Allocating.init(arena_alloc);
        try helpers.formatBuiltinSignature(&detail_buf, f);
        const detail = try detail_buf.toOwnedSlice();
        const insert_text = if (supports_snippets)
            try std.fmt.allocPrint(arena_alloc, "{s}($1)", .{f.name})
        else
            try arena_alloc.dupe(u8, f.name);
        const doc = try helpers.buildBuiltinDoc(arena_alloc, overloads);
        try items.append(arena_alloc, .{
            .label = f.name,
            .kind = .function,
            .detail = detail,
            .documentation = .{ .kind = .markdown, .value = doc },
            .insertText = insert_text,
            .insertTextFormat = if (supports_snippets) .snippet else .text,
        });
    }

    var type_it = self.builtin_types.iterator();
    while (type_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const desc = entry.value_ptr.*;
        try items.append(arena_alloc, .{
            .label = name,
            .kind = .class,
            .detail = name,
            .documentation = if (desc.len > 0) .{ .kind = .markdown, .value = desc } else null,
            .insertText = try arena_alloc.dupe(u8, name),
            .insertTextFormat = .text,
        });
    }

    const resp = response.Completion{ .id = req.id, .result = .{ .items = items.items } };
    return stringify(allocator, resp);
}

pub fn createDiagnosticsNotification(self: *Self, allocator: Allocator, uri: []const u8) Error!?[]const u8 {
    const analysis = helpers.getAnalysis(&self.files, uri) orelse return null;

    var diags = std.ArrayList(common.Diagnostic).empty;
    defer diags.deinit(allocator);

    for (analysis.diagnostics) |d| {
        try diags.append(allocator, .{
            .range = .{
                .start = .{ .line = d.line -| 1, .character = d.col -| 1 },
                .end = .{ .line = d.line -| 1, .character = d.col -| 1 },
            },
            .severity = switch (d.kind) {
                .@"error" => .@"error",
                .warning => .warning,
                .note => .information,
            },
            .message = d.message,
            .source = "sokol-shdc",
        });
    }

    const notif = response.DiagnosticsNotification{ .params = .{ .uri = uri, .diagnostics = diags.items } };
    return try stringify(allocator, notif);
}

pub fn createRenameResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .rename);
    const params = req.params.rename.value;
    const pos = params.position;
    const uri = params.textDocument.uri;
    const new_name = params.newName;

    const analysis = helpers.getAnalysis(&self.files, uri) orelse
        return json.Stringify.valueAlloc(allocator, response.NullResult{ .id = req.id }, .{});
    const target_decl = analysis.declAtPos(pos) orelse
        return json.Stringify.valueAlloc(allocator, response.NullResult{ .id = req.id }, .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var edits = std.ArrayList(common.TextEdit).empty;
    defer edits.deinit(arena_alloc);

    try edits.append(arena_alloc, .{
        .range = FileAnalysis.faRangeToLsp(target_decl.range),
        .newText = new_name,
    });

    for (analysis.scopes) |*scope| {
        for (scope.references) |*ref| {
            if (ref.decl == target_decl) {
                try edits.append(arena_alloc, .{
                    .range = FileAnalysis.faRangeToLsp(ref.range),
                    .newText = new_name,
                });
            }
        }
    }

    const changes = [1]common.WorkspaceEditChange{.{
        .uri = uri,
        .edits = edits.items,
    }};
    const resp = response.Rename{
        .id = req.id,
        .result = .{ .changes = &changes },
    };
    return stringify(allocator, resp);
}

pub fn createSignatureHelpResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .signature_help);
    const params = req.params.signature_help.value;
    const uri = params.textDocument.uri;
    const pos = params.position;

    const empty = response.SignatureHelp{ .id = req.id, .result = .{ .signatures = &.{} } };

    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, empty);

    const scope = for (analysis.scopes) |*s| {
        if (FileAnalysis.lspPosInFaRange(pos, s.range)) break s;
    } else return stringify(allocator, empty);

    var offset: usize = 0;
    var line: u32 = 0;
    while (offset < analysis.source.len) {
        if (line == pos.line) {
            offset += pos.character;
            break;
        }
        if (analysis.source[offset] == '\n') line += 1;
        offset += 1;
    }
    if (offset > analysis.source.len) return stringify(allocator, empty);

    const ctx = helpers.scanForCall(analysis.source, offset) orelse return stringify(allocator, empty);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const result: ?response.SignatureHelp.Result = for (scope.declarations) |*d| {
        if (d.kind == .function and std.mem.eql(u8, d.name, ctx.func_name))
            break try helpers.sigsFromDecl(arena_alloc, d, ctx.active_param);
    } else if (self.builtins.get(ctx.func_name)) |overloads|
        try helpers.sigsFromBuiltins(arena_alloc, overloads, ctx.active_param)
    else
        null;

    const resp = if (result) |r|
        response.SignatureHelp{ .id = req.id, .result = r }
    else
        empty;

    return stringify(allocator, resp);
}

pub fn createSemanticTokensResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .semantic_tokens_full);
    const uri = req.params.semantic_tokens_full.value.textDocument.uri;

    const empty = response.SemanticTokensFull{ .id = req.id, .result = .{} };
    const analysis = helpers.getAnalysis(&self.files, uri) orelse return stringify(allocator, empty);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var entries = std.ArrayList(helpers.SemanticEntry).empty;

    for (analysis.top_level) |*decl| {
        if (decl.name.len == 0) continue;
        if (decl.kind == .function) {
            for (decl.kind.function.params) |p| {
                try helpers.appendSemanticEntry(&entries, arena_alloc, .function_param, p.name, p.range);
            }
        }
        try helpers.appendSemanticEntry(&entries, arena_alloc, decl.kind, decl.name, decl.range);
    }
    for (analysis.scopes) |*scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            try helpers.appendSemanticEntry(&entries, arena_alloc, decl.kind, decl.name, decl.range);
            if (decl.kind == .function) {
                for (decl.kind.function.params) |p| {
                    try helpers.appendSemanticEntry(&entries, arena_alloc, .function_param, p.name, p.range);
                }
            }
        }
        for (scope.references) |*ref| {
            const decl = ref.decl orelse continue;
            try helpers.appendSemanticEntry(&entries, arena_alloc, decl.kind, ref.name, ref.range);
        }
    }

    std.mem.sort(helpers.SemanticEntry, entries.items, {}, struct {
        fn lt(_: void, a: helpers.SemanticEntry, b: helpers.SemanticEntry) bool {
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

pub fn handleDidOpen(self: *Self, allocator: Allocator, req: Request) Error!void {
    std.debug.assert(req.params == .did_open);
    const uri = req.params.did_open.value.textDocument.uri;
    helpers.analyzeFile(allocator, self.io, &self.files, self.runner_config, uri) catch |err| {
        std.log.err("Failed to analyze {s}: {}", .{ uri, err });
    };
}

pub fn handleDidChange(self: *Self, allocator: Allocator, req: Request) Error!void {
    std.debug.assert(req.params == .did_change);
    const params = req.params.did_change.value;
    const uri = params.textDocument.uri;
    if (params.contentChanges.len == 0) return;
    const content = params.contentChanges[params.contentChanges.len - 1].text;
    helpers.analyzeBuffer(allocator, self.io, &self.files, self.runner_config, uri, content) catch |err| {
        std.log.err("Failed to analyze buffer {s}: {}", .{ uri, err });
    };
}

pub fn handleDidSave(self: *Self, allocator: Allocator, req: Request) Error!void {
    std.debug.assert(req.params == .did_save);
    const uri = req.params.did_save.value.textDocument.uri;
    helpers.analyzeFile(allocator, self.io, &self.files, self.runner_config, uri) catch |err| {
        std.log.err("Failed to analyze {s}: {}", .{ uri, err });
    };
}

pub fn handleDidClose(self: *Self, allocator: Allocator, req: Request) void {
    std.debug.assert(req.params == .did_close);
    const uri = req.params.did_close.value.textDocument.uri;
    const path = uriToPath(uri);
    if (self.files.fetchRemove(path)) |entry| {
        var old = entry.value;
        old.analysis.deinit();
        allocator.free(entry.key);
        allocator.free(old.uri);
    }
}
