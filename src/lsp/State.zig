const std = @import("std");
const response = @import("response.zig");
const common = @import("common.zig");
const ShdcRunner = @import("../parser/ShdcRunner.zig");
const FileAnalysis = @import("../parser/FileAnalysis.zig");

const Error = common.Error;
const Request = @import("Request.zig");
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

    try w.print("### `{s}`\n", .{name});
    try w.print("**Kind:** {s}\n\n", .{declKindLabel(decl.kind)});

    switch (decl.kind) {
        .attr => |a| {
            try w.print("**Type:** `{s}`\n\n", .{a.glsl_type.name});
            if (a.slot) |slot| try w.print("**Slot:** {}\n\n", .{slot});
            if (a.glsl_type.base_type) |bt| try w.print("**Base Type:** {s}\n\n", .{bt});
            try w.print("**Direction:** {s}\n\n", .{if (a.is_input) "in" else "out"});
        },
        .uniform_block => |ub| {
            if (ub.slot) |slot| try w.print("**Binding:** {}\n\n", .{slot});
            if (ub.size) |size| try w.print("**Size:** {} bytes\n\n", .{size});
            try w.print("**Stage:** {s}\n\n", .{@tagName(ub.stage)});
        },
        .uniform_member => |um| {
            try w.print("**Type:** `{s}`\n\n", .{um.glsl_type.name});
            if (um.offset) |offset| try w.print("**Offset:** {} bytes\n\n", .{offset});
            if (um.array_count) |count| try w.print("**Array Count:** {}\n\n", .{count});
        },
        .texture => |t| {
            try w.print("**Type:** `{s}`\n\n", .{t.glsl_type.name});
            if (t.slot) |slot| try w.print("**Binding:** {}\n\n", .{slot});
            if (t.sample_type) |st| try w.print("**Sample Type:** {s}\n\n", .{st});
            if (t.image_sample_type) |ist| try w.print("**Image Sample Type:** {s}\n\n", .{ist});
            if (t.multisampled) |ms| try w.print("**Multisampled:** {}\n\n", .{ms});
            try w.print("**Stage:** {s}\n\n", .{@tagName(t.stage)});
        },
        .sampler => |s| {
            if (s.slot) |slot| try w.print("**Binding:** {}\n\n", .{slot});
            if (s.sampler_type) |st| try w.print("**Sampler Type:** {s}\n\n", .{st});
            if (s.sampler_type_hint) |sth| try w.print("**Sampler Type Hint:** {s}\n\n", .{sth});
            try w.print("**Stage:** {s}\n\n", .{@tagName(s.stage)});
        },
        .storage_buffer => |sb| {
            if (sb.slot) |slot| try w.print("**Binding:** {}\n\n", .{slot});
            try w.print("**Struct:** `{s}`\n\n", .{sb.struct_name});
            try w.print("**Access:** {s}\n\n", .{if (sb.readonly) "readonly" else "readwrite"});
            try w.print("**Stage:** {s}\n\n", .{@tagName(sb.stage)});
        },
        .storage_image => |si| {
            try w.print("**Type:** `{s}`\n\n", .{si.glsl_type.name});
            if (si.slot) |slot| try w.print("**Binding:** {}\n\n", .{slot});
            if (si.format) |fmt| try w.print("**Format:** {s}\n\n", .{fmt});
            try w.print("**Access:** {s}\n\n", .{si.access});
            try w.print("**Stage:** {s}\n\n", .{@tagName(si.stage)});
        },
        .function => |f| {
            try w.print("**Returns:** `{s}`\n\n", .{f.return_type.name});
            if (f.params.len > 0) {
                try w.print("**Parameters:**\n", .{});
                for (f.params) |p| {
                    try w.print("- `{s}`: `{s}`\n", .{ p.name, p.glsl_type.name });
                }
                try w.writeByte('\n');
            }
        },
        .local_var => |t| {
            try w.print("**Type:** `{s}`\n\n", .{t.name});
        },
        .@"struct" => |s| {
            try w.print("**Members:**\n", .{});
            for (s.members) |m| {
                try w.print("- `{s}`: `{s}`\n", .{ m.name, m.glsl_type.name });
            }
            try w.writeByte('\n');
        },
        .ctype => |ct| {
            try w.print("**GLSL Type:** `{s}`\n\n", .{ct.glsl_type});
            try w.print("**Target Type:** `{s}`\n\n", .{ct.target_type});
        },
        .header => |h| {
            try w.print("```\n{s}\n```\n", .{h.content});
        },
        .program => |p| {
            try w.print("**Vertex Shader:** `{s}`\n\n", .{p.vs_name});
            if (p.fs_name) |fs| try w.print("**Fragment Shader:** `{s}`\n\n", .{fs});
            if (p.cs_name) |cs| try w.print("**Compute Shader:** `{s}`\n\n", .{cs});
        },
        else => {},
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
                .textDocumentSync = .full,
                .hoverProvider = caps.textDocument != null and caps.textDocument.?.hover != null,
                .completionProvider = if (caps.textDocument != null and caps.textDocument.?.completion != null)
                    .{ .resolveProvider = true, .triggerCharacters = ".>" }
                else
                    null,
                .definitionProvider = caps.textDocument != null and caps.textDocument.?.definition != null,
                .referencesProvider = caps.textDocument != null and caps.textDocument.?.references != null,
                .workspaceSymbolProvider = true,
                .documentFormattingProvider = caps.textDocument != null and caps.textDocument.?.documentFormatting != null,
                .documentRangeFormattingProvider = caps.textDocument != null and caps.textDocument.?.documentFormatting != null,
            },
        },
    };

    return resp.stringify(allocator);
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
    const uri = req.params.did_change.value.textDocument.uri;
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
        return resp.stringify(allocator);
    };

    const decl = declAtPos(analysis, pos) orelse {
        const resp = response.Hover{
            .id = req.id,
            .result = .{ .contents = .{ .kind = .plaintext, .value = "" } },
        };
        return resp.stringify(allocator);
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
    return resp.stringify(allocator);
}

pub fn createDefinitionResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .definition);
    const params = req.params.definition.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty = response.Definition{ .id = req.id, .result = &.{} };

    const analysis = self.getAnalysis(uri) orelse return empty.stringify(allocator);
    const decl = declAtPos(analysis, pos) orelse return empty.stringify(allocator);

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
    return resp.stringify(allocator);
}

pub fn createReferencesResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .references);
    const params = req.params.references.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty = response.References{ .id = req.id, .result = &.{} };

    const analysis = self.getAnalysis(uri) orelse return empty.stringify(allocator);
    const target_decl = declAtPos(analysis, pos) orelse return empty.stringify(allocator);

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
    return resp.stringify(allocator);
}

pub fn createDocumentSymbolResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .document_symbol);
    const params = req.params.document_symbol.value;
    const uri = params.textDocument.uri;

    const empty = response.DocumentSymbol{ .id = req.id, .result = &.{} };
    const analysis = self.getAnalysis(uri) orelse return empty.stringify(allocator);

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
    return resp.stringify(allocator);
}

pub fn createCompletionResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .completion);
    const params = req.params.completion.value;
    const uri = params.textDocument.uri;
    const pos = params.position;

    const empty = response.Completion{ .id = req.id, .result = .{ .items = &.{} } };
    const analysis = self.getAnalysis(uri) orelse return empty.stringify(allocator);

    // Find which scope the cursor is in
    var active_scope: ?*FileAnalysis.Scope = null;
    for (analysis.scopes) |*scope| {
        if (lspPosInFaRange(pos, scope.range)) {
            active_scope = scope;
            break;
        }
    }

    var items = std.ArrayList(common.CompletionItem).empty;
    defer items.deinit(allocator);

    const supports_snippets = self.support.has(.snippets);

    if (active_scope) |scope| {
        for (scope.declarations) |*decl| {
            if (decl.name.len == 0) continue;
            if (decl.kind == .uniform_block) continue; // block name not directly usable

            const detail = try declDetail(allocator, decl.*);
            defer allocator.free(detail);

            const insert_text = if (supports_snippets and decl.kind == .function)
                try functionSnippet(allocator, decl.name, decl.kind.function)
            else
                try allocator.dupe(u8, decl.name);
            defer allocator.free(insert_text);

            try items.append(allocator, .{
                .label = decl.name,
                .kind = declToSymbolKind(decl.kind),
                .detail = detail,
                .insertText = insert_text,
                .insertTextFormat = if (supports_snippets and decl.kind == .function) .snippet else .text,
            });
        }
    }

    const resp = response.Completion{ .id = req.id, .result = .{ .items = items.items } };
    return resp.stringify(allocator);
}

pub fn createDiagnosticsNotification(self: *Self, allocator: Allocator, uri: []const u8) Error!?[]const u8 {
    const analysis = self.getAnalysis(uri) orelse return null;
    if (analysis.diagnostics.len == 0) return null;

    var diags = std.ArrayList(common.Diagnostic).empty;
    defer diags.deinit(allocator);

    for (analysis.diagnostics) |d| {
        try diags.append(allocator, .{
            .range = .{
                .start = .{ .line = d.line, .character = d.col },
                .end = .{ .line = d.line, .character = d.col },
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
