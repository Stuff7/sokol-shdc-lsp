const std = @import("std");
const response = @import("response.zig");
const common = @import("common.zig");
const json = std.json;

const ShdcRunner = @import("../parser/ShdcRunner.zig");
const FileAnalysis = @import("../parser/FileAnalysis.zig");
const Request = @import("Request.zig");
const Error = common.Error;
const Allocator = std.mem.Allocator;
const Range = common.Range;
const Position = common.Position;
const CompletionItemKind = common.CompletionItemKind;

// ── URI helpers ───────────────────────────────────────────────────────────────

fn uriToPath(uri: []const u8) []const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return uri;
}

fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

// ── Range conversion ──────────────────────────────────────────────────────────

fn faRangeToLsp(r: FileAnalysis.Range) Range {
    return .{
        .start = .{ .line = r.start.line, .character = r.start.col },
        .end = .{ .line = r.end.line, .character = r.end.col },
    };
}

fn lspPosInFaRange(pos: Position, r: FileAnalysis.Range) bool {
    const after_start = pos.line > r.start.line or
        (pos.line == r.start.line and pos.character >= r.start.col);
    const before_end = pos.line < r.end.line or
        (pos.line == r.end.line and pos.character <= r.end.col);
    return after_start and before_end;
}

// ── Capability tracking ───────────────────────────────────────────────────────

const Support = struct {
    bitset: std.bit_set.IntegerBitSet(@typeInfo(Feature).@"enum".fields.len) = .initEmpty(),

    fn has(self: @This(), feat: Feature) bool {
        return self.bitset.isSet(@intFromEnum(feat));
    }

    fn set(self: *@This(), feat: Feature, enabled: bool) void {
        if (enabled) self.enable(feat) else self.disable(feat);
    }

    fn enable(self: *@This(), feat: Feature) void {
        self.bitset.set(@intFromEnum(feat));
    }

    fn disable(self: *@This(), feat: Feature) void {
        self.bitset.unset(@intFromEnum(feat));
    }

    const Feature = enum {
        markdown,
        snippets,
        hover,
        completion,
        definition,
        references,
        rename_prepare,
        document_formatting,
        range_formatting,
        workspace_apply_edit,
    };
};

// ── Hover formatting ──────────────────────────────────────────────────────────

fn declKindLabel(kind: FileAnalysis.DeclKind) []const u8 {
    return switch (kind) {
        .vs_block => "Vertex Shader Block",
        .fs_block => "Fragment Shader Block",
        .cs_block => "Compute Shader Block",
        .named_block => "Named Block",
        .program => "Program",
        .module => "Module",
        .attr => |a| if (a.is_input) "Input Attribute" else "Output Attribute",
        .uniform_block => "Uniform Block",
        .uniform_member => "Uniform Member",
        .texture => "Texture",
        .sampler => "Sampler",
        .storage_buffer => "Storage Buffer",
        .storage_image => "Storage Image",
        .function => "Function",
        .local_var => "Local Variable",
        .@"struct" => "Struct",
        .header => "Header",
        .ctype => "C Type Mapping",
        .include => "Include",
        .include_block => "Include Block",
        .glsl_options => "GLSL Options",
        .hlsl_options => "HLSL Options",
        .msl_options => "MSL Options",
        .image_sample_type => "Image Sample Type",
        .sampler_type => "Sampler Type",
    };
}

fn declToMarkdown(allocator: Allocator, name: []const u8, decl: FileAnalysis.Declaration) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    switch (decl.kind) {
        .attr => |a| {
            try w.print("```glsl\n{s} {s} {s}\n```", .{
                if (a.is_input) "in" else "out",
                a.glsl_type.name,
                name,
            });
            if (a.slot) |slot| try w.print("\n\n*binding = {}*", .{slot});
        },
        .uniform_member => |um| {
            try w.print("```glsl\n{s} {s}", .{ um.glsl_type.name, name });
            if (um.array_count) |count| try w.print("[{}]", .{count});
            try w.writeAll("\n```");
            if (um.offset) |offset| try w.print("\n\n*offset = {} bytes*", .{offset});
        },
        .uniform_block => |ub| {
            try w.print("```glsl\nuniform {s} {{ ... }}", .{name});
            try w.writeAll("\n```");
            if (ub.slot) |slot| try w.print("\n\n*binding = {}*", .{slot});
            if (ub.size) |size| try w.print("  *size = {} bytes*", .{size});
        },
        .texture => |t| {
            try w.print("```glsl\nuniform texture2D {s}\n```", .{name});
            if (t.slot) |slot| try w.print("\n\n*binding = {}*", .{slot});
            if (t.sample_type) |st| try w.print("  *sample type: {s}*", .{st});
        },
        .sampler => |s| {
            try w.print("```glsl\nuniform sampler {s}\n```", .{name});
            if (s.slot) |slot| try w.print("\n\n*binding = {}*", .{slot});
            if (s.sampler_type) |st| try w.print("  *type: {s}*", .{st});
        },
        .storage_buffer => |sb| {
            try w.print("```glsl\nlayout(binding = ?) buffer {s} {{ {s} }}\n```", .{ sb.struct_name, name });
            if (sb.slot) |slot| try w.print("\n\n*binding = {}*", .{slot});
            try w.print("  *{s}*", .{if (sb.readonly) "readonly" else "readwrite"});
        },
        .storage_image => |si| {
            try w.print("```glsl\n{s} {s} {s}\n```", .{ si.access, si.glsl_type.name, name });
            if (si.slot) |slot| try w.print("\n\n*binding = {}*", .{slot});
            if (si.format) |fmt| try w.print("  *format: {s}*", .{fmt});
        },
        .function => |f| {
            try w.print("```glsl\n{s} {s}(", .{ f.return_type.name, name });
            for (f.params, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s} {s}", .{ p.glsl_type.name, p.name });
            }
            try w.writeAll(")\n```");
        },
        .local_var => |t| {
            try w.print("```glsl\n{s} {s}\n```", .{ t.name, name });
        },
        .@"struct" => |s| {
            try w.print("```glsl\nstruct {s} {{\n", .{name});
            for (s.members) |m| {
                try w.print("    {s} {s};\n", .{ m.glsl_type.name, m.name });
            }
            try w.writeAll("}\n```");
        },
        .ctype => |ct| {
            try w.print("```glsl\n@ctype {s} {s}\n```", .{ ct.glsl_type, ct.target_type });
        },
        .header => |h| {
            try w.print("```\n{s}\n```", .{h.content});
        },
        .program => |p| {
            try w.print("```glsl\n@program {s} {s}", .{ name, p.vs_name });
            if (p.fs_name) |fs| try w.print(" {s}", .{fs});
            if (p.cs_name) |cs| try w.print(" {s}", .{cs});
            try w.writeAll("\n```");
        },
        .vs_block => try w.print("```glsl\n@vs {s}\n```", .{name}),
        .fs_block => try w.print("```glsl\n@fs {s}\n```", .{name}),
        .cs_block => try w.print("```glsl\n@cs {s}\n```", .{name}),
        .named_block => try w.print("```glsl\n@block {s}\n```", .{name}),
        .module => try w.print("```glsl\n@module {s}\n```", .{name}),
        .include => try w.print("```glsl\n@include {s}\n```", .{name}),
        .include_block => try w.print("```glsl\n@include_block {s}\n```", .{name}),
        else => try w.print("```glsl\n{s}\n```", .{name}),
    }

    return allocator.dupe(u8, buf.written());
}

fn declToPlaintext(allocator: Allocator, name: []const u8, decl: FileAnalysis.Declaration) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.print("{s} — {s}", .{ name, declKindLabel(decl.kind) });

    switch (decl.kind) {
        .attr => |a| {
            try w.print(" ({s}", .{a.glsl_type.name});
            if (a.slot) |slot| try w.print(", slot={}", .{slot});
            try w.writeByte(')');
        },
        .uniform_block => |ub| {
            if (ub.slot) |slot| try w.print(" (binding={})", .{slot});
        },
        .uniform_member => |um| {
            try w.print(" ({s})", .{um.glsl_type.name});
        },
        .texture => |t| {
            try w.print(" ({s}", .{t.glsl_type.name});
            if (t.slot) |slot| try w.print(", binding={}", .{slot});
            try w.writeByte(')');
        },
        .sampler => |s| {
            if (s.slot) |slot| try w.print(" (binding={})", .{slot});
        },
        .function => |f| {
            try w.print(" -> {s}", .{f.return_type.name});
        },
        .local_var => |t| {
            try w.print(" ({s})", .{t.name});
        },
        else => {},
    }

    return allocator.dupe(u8, buf.written());
}

// ── Symbol kind mapping ───────────────────────────────────────────────────────

fn declToSymbolKind(kind: FileAnalysis.DeclKind) CompletionItemKind {
    return switch (kind) {
        .function => .function,
        .uniform_block, .@"struct", .storage_buffer => .@"struct",
        .uniform_member, .attr, .local_var, .storage_image => .variable,
        .texture, .sampler => .property,
        .vs_block, .fs_block, .cs_block, .named_block => .module,
        .program => .module,
        .ctype, .header => .keyword,
        else => .text,
    };
}

// ── File cache ────────────────────────────────────────────────────────────────

const FileEntry = struct {
    analysis: FileAnalysis,
    uri: []const u8,
};

// ── State ─────────────────────────────────────────────────────────────────────

support: Support = .{},
workspace: []const u8 = "",
files: std.StringHashMap(FileEntry),
io: std.Io,
runner_config: ShdcRunner.Config = .{},

const Self = @This();

pub fn init(allocator: Allocator, io: std.Io) Self {
    return .{
        .files = std.StringHashMap(FileEntry).init(allocator),
        .io = io,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    allocator.free(self.workspace);
    var it = self.files.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.analysis.deinit();
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.uri);
    }
    self.files.deinit(allocator);
}

fn analyzeFile(self: *Self, allocator: Allocator, uri: []const u8) !void {
    const path = uriToPath(uri);

    // Remove old entry if present
    if (self.files.fetchRemove(path)) |entry| {
        var old = entry.value;
        old.analysis.deinit();
        allocator.free(entry.key);
        allocator.free(old.uri);
    }

    const analysis = try ShdcRunner.run(self.io, allocator, path, self.runner_config);
    const key = try allocator.dupe(u8, path);
    const uri_owned = try allocator.dupe(u8, uri);
    try self.files.put(key, .{ .analysis = analysis, .uri = uri_owned });
}

fn getAnalysis(self: *Self, uri: []const u8) ?*FileAnalysis {
    const path = uriToPath(uri);
    const entry = self.files.getPtr(path) orelse return null;
    return &entry.analysis;
}

/// Finds the declaration at a given position across all scopes.
fn findDeclAtPos(analysis: *FileAnalysis, pos: Position) ?*const FileAnalysis.Declaration {
    for (analysis.scopes) |*scope| {
        for (scope.declarations) |*decl| {
            if (lspPosInFaRange(pos, decl.range)) return decl;
        }
    }
    for (analysis.top_level) |*decl| {
        if (lspPosInFaRange(pos, decl.range)) return decl;
    }
    return null;
}

/// Finds the reference at a given position and returns its resolved declaration.
fn findRefAtPos(analysis: *FileAnalysis, pos: Position) ?*const FileAnalysis.Declaration {
    for (analysis.scopes) |*scope| {
        for (scope.references) |*ref| {
            if (lspPosInFaRange(pos, ref.range)) return ref.decl;
        }
    }
    return null;
}

/// Returns the declaration or resolved decl under the cursor.
fn declAtPos(analysis: *FileAnalysis, pos: Position) ?*const FileAnalysis.Declaration {
    return findDeclAtPos(analysis, pos) orelse findRefAtPos(analysis, pos);
}

// ── Handlers ──────────────────────────────────────────────────────────────────

pub fn createInitResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .initialize);
    const params = req.params.initialize.value;

    self.workspace = if (params.rootUri) |uri| try allocator.dupe(u8, uri) else "";

    const caps = params.capabilities;

    if (caps.textDocument) |td| {
        if (if (td.hover) |h| h.contentFormat else null) |formats| {
            for (formats) |fmt| {
                if (std.mem.eql(u8, fmt, "markdown")) {
                    self.support.enable(.markdown);
                    break;
                }
            }
        }
        if (td.completion) |comp| {
            self.support.enable(.completion);
            if (if (comp.completionItem) |item| item.snippetSupport else false) |snippet| {
                self.support.set(.snippets, snippet);
            }
        }
        self.support.set(.hover, td.hover != null);
        self.support.set(.definition, td.definition != null);
        self.support.set(.references, td.references != null);
        if (if (td.rename) |rename| rename.prepareSupport else null) |prep| {
            self.support.set(.rename_prepare, prep);
        }
        self.support.set(.document_formatting, td.documentFormatting != null);
        self.support.set(.range_formatting, td.documentFormatting != null);
    }
    if (caps.workspace) |ws| {
        self.support.set(.workspace_apply_edit, ws.applyEdit == true);
    }

    const resp = response.Initialize{
        .id = req.id,
        .result = .{
            .capabilities = .{
                .renameProvider = true,
                .textDocumentSync = .full,
                .hoverProvider = caps.textDocument != null and caps.textDocument.?.hover != null,
                .completionProvider = if (caps.textDocument != null and caps.textDocument.?.completion != null)
                    .{ .resolveProvider = true, .triggerCharacters = &.{ ".", ">" } }
                else
                    null,
                .definitionProvider = caps.textDocument != null and caps.textDocument.?.definition != null,
                .referencesProvider = caps.textDocument != null and caps.textDocument.?.references != null,
                .workspaceSymbolProvider = true,
                .documentFormattingProvider = caps.textDocument != null and caps.textDocument.?.documentFormatting != null,
                .documentRangeFormattingProvider = caps.textDocument != null and caps.textDocument.?.documentFormatting != null,
                .semanticTokensProvider = .{
                    .legend = .{
                        .tokenTypes = &.{
                            "namespace",
                            "type",
                            "class",
                            "enum",
                            "interface",
                            "struct",
                            "typeParameter",
                            "parameter",
                            "variable",
                            "property",
                            "enumMember",
                            "event",
                            "function",
                            "method",
                            "macro",
                            "keyword",
                            "modifier",
                            "comment",
                            "string",
                            "number",
                            "regexp",
                            "operator",
                            "decorator",
                        },
                        .tokenModifiers = &.{
                            "declaration",
                            "definition",
                            "readonly",
                            "static",
                            "deprecated",
                            "abstract",
                            "async",
                            "modification",
                            "documentation",
                            "defaultLibrary",
                            "mutable",
                        },
                    },
                    .full = true,
                },
            },
        },
    };

    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn handleDidOpen(self: *Self, allocator: Allocator, req: Request) Error!void {
    std.debug.assert(req.params == .did_open);
    const uri = req.params.did_open.value.textDocument.uri;
    self.analyzeFile(allocator, uri) catch |err| {
        std.log.err("Failed to analyze {s}: {}", .{ uri, err });
    };
}

pub fn handleDidChange(self: *Self, allocator: Allocator, req: Request) Error!void {
    std.debug.assert(req.params == .did_change);
    const params = req.params.did_change.value;
    const uri = params.textDocument.uri;
    if (params.contentChanges.len == 0) return;
    const content = params.contentChanges[params.contentChanges.len - 1].text;
    self.analyzeBuffer(allocator, uri, content) catch |err| {
        std.log.err("Failed to analyze buffer {s}: {}", .{ uri, err });
    };
}

pub fn handleDidSave(self: *Self, allocator: Allocator, req: Request) Error!void {
    std.debug.assert(req.params == .did_save);
    const uri = req.params.did_save.value.textDocument.uri;
    self.analyzeFile(allocator, uri) catch |err| {
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

pub fn createHoverResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .hover);
    const params = req.params.hover.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const analysis = self.getAnalysis(uri) orelse {
        const resp = response.Hover{
            .id = req.id,
            .result = .{ .contents = .{ .kind = .plaintext, .value = "" } },
        };
        return json.Stringify.valueAlloc(allocator, resp, .{});
    };

    const decl = declAtPos(analysis, pos) orelse {
        const resp = response.Hover{
            .id = req.id,
            .result = .{ .contents = .{ .kind = .plaintext, .value = "" } },
        };
        return json.Stringify.valueAlloc(allocator, resp, .{});
    };

    const use_markdown = self.support.has(.markdown);
    const content = if (use_markdown)
        try declToMarkdown(allocator, decl.name, decl.*)
    else
        try declToPlaintext(allocator, decl.name, decl.*);
    defer allocator.free(content);

    const resp = response.Hover{
        .id = req.id,
        .result = .{
            .contents = .{
                .kind = if (use_markdown) .markdown else .plaintext,
                .value = content,
            },
            .range = faRangeToLsp(decl.range),
        },
    };
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn createDefinitionResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .definition);
    const params = req.params.definition.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty = response.Definition{ .id = req.id, .result = &.{} };

    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty, .{});
    const decl = declAtPos(analysis, pos) orelse return json.Stringify.valueAlloc(allocator, empty, .{});

    const decl_uri = if (std.mem.eql(u8, decl.range.file, uriToPath(uri)))
        uri
    else
        try pathToUri(allocator, decl.range.file);
    defer if (!std.mem.eql(u8, decl_uri, uri)) allocator.free(decl_uri);

    const resp = response.Definition{
        .id = req.id,
        .result = &.{.{
            .uri = decl_uri,
            .range = faRangeToLsp(decl.range),
        }},
    };
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn createReferencesResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .references);
    const params = req.params.references.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty = response.References{ .id = req.id, .result = &.{} };

    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty, .{});
    const target_decl = declAtPos(analysis, pos) orelse return json.Stringify.valueAlloc(allocator, empty, .{});

    var locs = std.ArrayList(response.Location).empty;
    defer locs.deinit(allocator);

    for (analysis.scopes) |*scope| {
        for (scope.references) |*ref| {
            if (ref.decl == target_decl) {
                try locs.append(allocator, .{
                    .uri = uri,
                    .range = faRangeToLsp(ref.range),
                });
            }
        }
    }

    const resp = response.References{ .id = req.id, .result = locs.items };
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn createDocumentSymbolResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .document_symbol);
    const params = req.params.document_symbol.value;
    const uri = params.textDocument.uri;

    const empty = response.DocumentSymbol{ .id = req.id, .result = &.{} };
    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty, .{});

    var symbols = std.ArrayList(response.SymbolInformation).empty;
    defer symbols.deinit(allocator);

    // Top-level declarations
    for (analysis.top_level) |*decl| {
        if (decl.name.len == 0) continue;
        try symbols.append(allocator, .{
            .name = decl.name,
            .kind = declToSymbolKind(decl.kind),
            .location = .{ .uri = uri, .range = faRangeToLsp(decl.range) },
            .containerName = null,
        });
    }

    // Scope declarations
    for (analysis.scopes) |*scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            // Skip local vars from symbols — too noisy
            if (decl.kind == .local_var) continue;
            try symbols.append(allocator, .{
                .name = decl.name,
                .kind = declToSymbolKind(decl.kind),
                .location = .{ .uri = uri, .range = faRangeToLsp(decl.range) },
                .containerName = scope.name,
            });
        }
    }

    const resp = response.DocumentSymbol{ .id = req.id, .result = symbols.items };
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn createCompletionResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .completion);
    const params = req.params.completion.value;
    const uri = params.textDocument.uri;
    const pos = params.position;

    const empty = response.Completion{ .id = req.id, .result = .{ .items = &.{} } };
    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty, .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var active_scope: ?*FileAnalysis.Scope = null;
    for (analysis.scopes) |*scope| {
        if (lspPosInFaRange(pos, scope.range)) {
            active_scope = scope;
            break;
        }
    }

    var items = std.ArrayList(common.CompletionItem).empty;
    defer items.deinit(arena_alloc);

    const supports_snippets = self.support.has(.snippets);

    if (active_scope) |scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            if (decl.kind == .uniform_block) continue;

            const detail = try declDetail(arena_alloc, decl.*);
            const insert_text = if (supports_snippets and decl.kind == .function)
                try functionSnippet(arena_alloc, decl.name, decl.kind.function)
            else
                try arena_alloc.dupe(u8, decl.name);

            try items.append(arena_alloc, .{
                .label = decl.name,
                .kind = declToSymbolKind(decl.kind),
                .detail = detail,
                .insertText = insert_text,
                .insertTextFormat = if (supports_snippets and decl.kind == .function) .snippet else .text,
            });
        }
    }

    const resp = response.Completion{ .id = req.id, .result = .{ .items = items.items } };
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn createDiagnosticsNotification(self: *Self, allocator: Allocator, uri: []const u8) Error!?[]const u8 {
    const analysis = self.getAnalysis(uri) orelse return null;

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

    // Diagnostics are sent as a notification, not a response
    const notif = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8 = "textDocument/publishDiagnostics",
        params: struct {
            uri: []const u8,
            diagnostics: []const common.Diagnostic,
        },
    }{
        .params = .{ .uri = uri, .diagnostics = diags.items },
    };

    return try std.json.Stringify.valueAlloc(allocator, notif, .{});
}

pub fn createRenameResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .rename);
    const params = req.params.rename.value;
    const pos = params.position;
    const uri = params.textDocument.uri;
    const new_name = params.newName;

    const empty = response.Rename{ .id = req.id, .result = .{} };
    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty, .{});
    const target_decl = declAtPos(analysis, pos) orelse return json.Stringify.valueAlloc(allocator, empty, .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var edits = std.ArrayList(common.TextEdit).empty;
    defer edits.deinit(arena_alloc);

    // Edit the declaration itself
    try edits.append(arena_alloc, .{
        .range = faRangeToLsp(target_decl.range),
        .newText = new_name,
    });

    // Edit all references to this declaration
    for (analysis.scopes) |*scope| {
        for (scope.references) |*ref| {
            if (ref.decl == target_decl) {
                try edits.append(arena_alloc, .{
                    .range = faRangeToLsp(ref.range),
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
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

pub fn createSemanticTokensResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .semantic_tokens_full);
    const params = req.params.semantic_tokens_full.value;
    const uri = params.textDocument.uri;

    const empty = response.SemanticTokensFull{ .id = req.id, .result = .{} };
    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty, .{});

    const TokenType = enum(u32) {
        namespace = 0,
        type = 1,
        @"struct" = 5,
        variable = 8,
        property = 9,
        function = 12,
        keyword = 15,
    };

    const Entry = struct {
        line: u32,
        col: u32,
        len: u32,
        token_type: TokenType,
        modifiers: u32 = 0,
    };

    const mod_readonly: u32 = 1 << 2; // "readonly" — index 2
    const mod_mutable: u32 = 1 << 10; // "mutable" — index 10

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(arena_alloc);

    const declTokenType = struct {
        fn f(kind: FileAnalysis.DeclKind) ?TokenType {
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
    }.f;

    const getSemanticTokens = struct {
        fn f(alloc: Allocator, entry_list: *std.ArrayList(Entry), kind: FileAnalysis.DeclKind, name: []const u8, range: FileAnalysis.Range) !void {
            const modifiers: u32 = switch (kind) {
                .attr => |attr| if (attr.is_input) mod_readonly else mod_mutable,
                else => 0,
            };
            const tt = declTokenType(kind) orelse return;
            try entry_list.append(alloc, .{
                .line = range.start.line,
                .col = range.start.col,
                .len = @intCast(name.len),
                .token_type = tt,
                .modifiers = modifiers,
            });
        }
    }.f;

    for (analysis.top_level) |*decl| {
        if (decl.name.len == 0) continue;
        const tt = declTokenType(decl.kind) orelse continue;
        try entries.append(arena_alloc, .{
            .line = decl.range.start.line,
            .col = decl.range.start.col,
            .len = @intCast(decl.name.len),
            .token_type = tt,
        });
    }

    for (analysis.scopes) |*scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            try getSemanticTokens(arena_alloc, &entries, decl.kind, decl.name, decl.range);
        }
        for (scope.references) |*ref| {
            const decl = ref.decl orelse continue;
            try getSemanticTokens(arena_alloc, &entries, decl.kind, ref.name, ref.range);
        }
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.line < b.line or (a.line == b.line and a.col < b.col);
        }
    }.lt);

    var data = std.ArrayList(u32).empty;
    defer data.deinit(arena_alloc);

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

    const resp = response.SemanticTokensFull{ .id = req.id, .result = .{ .data = data.items } };
    return json.Stringify.valueAlloc(allocator, resp, .{});
}

// ── Small helpers ─────────────────────────────────────────────────────────────

fn declDetail(allocator: Allocator, decl: FileAnalysis.Declaration) ![]const u8 {
    return switch (decl.kind) {
        .attr => |a| std.fmt.allocPrint(allocator, "{s} {s}", .{ a.glsl_type.name, decl.name }),
        .uniform_member => |um| std.fmt.allocPrint(allocator, "{s} {s}", .{ um.glsl_type.name, decl.name }),
        .local_var => |t| std.fmt.allocPrint(allocator, "{s} {s}", .{ t.name, decl.name }),
        .function => |f| blk: {
            var buf = std.Io.Writer.Allocating.init(allocator);
            defer buf.deinit();
            try buf.writer.print("{s} {s}(", .{ f.return_type.name, decl.name });
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.writer.writeAll(", ");
                try buf.writer.print("{s} {s}", .{ p.glsl_type.name, p.name });
            }
            try buf.writer.writeByte(')');
            break :blk allocator.dupe(u8, buf.written());
        },
        .texture => |t| std.fmt.allocPrint(allocator, "{s} {s}", .{ t.glsl_type.name, decl.name }),
        .sampler => std.fmt.allocPrint(allocator, "sampler {s}", .{decl.name}),
        .uniform_block => |ub| std.fmt.allocPrint(allocator, "uniform {s} ({}b)", .{ decl.name, ub.size orelse 0 }),
        else => allocator.dupe(u8, decl.name),
    };
}

fn functionSnippet(allocator: Allocator, name: []const u8, f: FileAnalysis.Function) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try buf.writer.print("{s}(", .{name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print("${{{}: {s}}}", .{ i + 1, p.name });
    }
    try buf.writer.writeByte(')');
    return allocator.dupe(u8, buf.written());
}

fn analyzeBuffer(self: *Self, allocator: Allocator, uri: []const u8, content: []const u8) !void {
    const path = uriToPath(uri);

    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.allocPrintSentinel(allocator, "/tmp/sokol_lsp_buf_{}.glsl", .{pid}, 0);
    defer {
        _ = std.os.linux.unlink(tmp_path);
        allocator.free(tmp_path);
    }

    try std.Io.Dir.cwd().writeFile(self.io, .{
        .sub_path = tmp_path,
        .data = content,
    });

    if (self.files.fetchRemove(path)) |entry| {
        var old = entry.value;
        old.analysis.deinit();
        allocator.free(entry.key);
        allocator.free(old.uri);
    }

    const analysis = try ShdcRunner.run(self.io, allocator, tmp_path, self.runner_config);
    const key = try allocator.dupe(u8, path);
    const uri_owned = try allocator.dupe(u8, uri);
    try self.files.put(key, .{ .analysis = analysis, .uri = uri_owned });
}
