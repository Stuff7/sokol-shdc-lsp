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

support: Support = .{},
workspace: []const u8 = "",
files: std.StringHashMap(FileEntry),
io: std.Io,
runner_config: ShdcRunner.Config = .{},
builtins: std.StringHashMap([]BuiltinFunction),
builtin_types: std.StringHashMap([]const u8),

const Self = @This();

pub const BuiltinParam = struct {
    type: []const u8,
    name: []const u8,
};

pub const BuiltinFunction = struct {
    return_type: []const u8,
    name: []const u8,
    parameters: []BuiltinParam,
    description: ?[][]const u8 = null,
};

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

    const parsed = try std.json.parseFromSlice(Root, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Group by name — all strings duped into allocator since parsed will be freed
    for (parsed.value.functions) |f| {
        const entry = try self.builtins.getOrPut(f.name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, f.name);
            entry.value_ptr.* = &.{};
        }
        const old = entry.value_ptr.*;
        const new = try allocator.realloc(old, old.len + 1);
        // dupe all strings since parsed arena is freed after this function
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
    const parsed_types = try std.json.parseFromSlice(Types, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed_types.deinit();
    for (parsed_types.value.types) |t| {
        const desc = if (t.description) |d| try std.mem.join(allocator, "\n\n", d) else try allocator.dupe(u8, "");
        try self.builtin_types.put(try allocator.dupe(u8, t.name), desc);
    }
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
                .signatureHelpProvider = .{},
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

    return json.Stringify.valueAlloc(allocator, resp, .{ .emit_null_optional_fields = false });
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
        return json.Stringify.valueAlloc(allocator, response.NullResult{ .id = req.id }, .{});
    };

    const decl = declAtPos(analysis, pos) orelse {
        // check builtins — get word under cursor
        const source = analysis.source;
        var offset: usize = 0;
        var line: u32 = 0;
        while (offset < source.len) {
            if (line == pos.line) {
                offset += @min(pos.character, source.len - offset);
                break;
            }
            if (source[offset] == '\n') line += 1;
            offset += 1;
        }
        var word_end = offset;
        while (word_end < source.len and (std.ascii.isAlphanumeric(source[word_end]) or source[word_end] == '_')) {
            word_end += 1;
        }
        var word_start = offset;
        while (word_start > 0 and (std.ascii.isAlphanumeric(source[word_start - 1]) or source[word_start - 1] == '_')) {
            word_start -= 1;
        }
        if (word_start < word_end) {
            const word = source[word_start..word_end];
            if (self.builtins.get(word)) |overloads| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const arena_alloc = arena.allocator();
                var buf = std.Io.Writer.Allocating.init(arena_alloc);
                defer buf.deinit();
                for (overloads) |f| {
                    try buf.writer.print("```glsl\n{s} {s}(", .{ f.return_type, f.name });
                    for (f.parameters, 0..) |p, i| {
                        if (i > 0) try buf.writer.writeAll(", ");
                        try buf.writer.print("{s} {s}", .{ p.type, p.name });
                    }
                    try buf.writer.writeAll(")\n```");
                    if (f.description) |desc| {
                        for (desc) |l| {
                            try buf.writer.print("\n\n{s}", .{l});
                        }
                    }
                    try buf.writer.writeAll("\n\n");
                }
                const content = try allocator.dupe(u8, std.mem.trimEnd(u8, buf.written(), "\n"));
                defer allocator.free(content);
                const resp = response.Hover{
                    .id = req.id,
                    .result = .{ .contents = .{ .kind = .markdown, .value = content } },
                };
                return json.Stringify.valueAlloc(allocator, resp, .{ .emit_null_optional_fields = false });
            } else if (self.builtin_types.get(word)) |desc| {
                const content = try std.fmt.allocPrint(allocator, "```glsl\n{s}\n```\n\n{s}", .{ word, desc });
                defer allocator.free(content);
                const resp = response.Hover{
                    .id = req.id,
                    .result = .{ .contents = .{ .kind = .markdown, .value = content } },
                };
                return json.Stringify.valueAlloc(allocator, resp, .{ .emit_null_optional_fields = false });
            }
        }
        return json.Stringify.valueAlloc(allocator, response.NullResult{ .id = req.id }, .{});
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
    return json.Stringify.valueAlloc(allocator, resp, .{ .emit_null_optional_fields = false });
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

    // Add builtin functions
    var builtin_it = self.builtins.iterator();
    while (builtin_it.next()) |entry| {
        const overloads = entry.value_ptr.*;
        if (overloads.len == 0) continue;
        // Use first overload for detail/insert, they all share the same name
        const f = overloads[0];
        const detail = try std.fmt.allocPrint(arena_alloc, "{s} {s}(...)", .{ f.return_type, f.name });
        const insert_text = if (supports_snippets)
            try std.fmt.allocPrint(arena_alloc, "{s}($1)", .{f.name})
        else
            try arena_alloc.dupe(u8, f.name);
        try items.append(arena_alloc, .{
            .label = f.name,
            .kind = .function,
            .detail = detail,
            .insertText = insert_text,
            .insertTextFormat = if (supports_snippets) .snippet else .text,
        });
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

pub fn createSignatureHelpResponse(self: *Self, allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .signature_help);
    const params = req.params.signature_help.value;
    const pos = params.position;
    const uri = params.textDocument.uri;

    const empty_result = response.SignatureHelp{ .id = req.id, .result = .{ .signatures = &.{} } };
    const analysis = self.getAnalysis(uri) orelse return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });

    // Find the active scope
    var active_scope: ?*FileAnalysis.Scope = null;
    for (analysis.scopes) |*scope| {
        if (lspPosInFaRange(pos, scope.range)) {
            active_scope = scope;
            break;
        }
    }
    const scope = active_scope orelse return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });

    // Walk backwards from cursor to find the opening '(' and function name
    const source = analysis.source;
    // Convert LSP position to byte offset
    var offset: usize = 0;
    var line: u32 = 0;
    while (offset < source.len) {
        if (line == pos.line) {
            offset += pos.character;
            break;
        }
        if (source[offset] == '\n') line += 1;
        offset += 1;
    }
    if (offset > source.len) return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });

    // Scan backwards to find '(' and count active parameter
    var active_param: u32 = 0;
    var depth: u32 = 0;
    var paren_offset: ?usize = null;
    var i: usize = offset;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) {
                    paren_offset = i;
                    break;
                }
                depth -= 1;
            },
            ',' => if (depth == 0) {
                active_param += 1;
            },
            '\n' => break, // don't scan past line boundary
            else => {},
        }
    }

    const paren = paren_offset orelse return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });

    // Extract function name before '('
    var name_end = paren;
    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(source[name_start - 1]) or source[name_start - 1] == '_')) {
        name_start -= 1;
    }
    if (name_start == name_end) return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });
    const func_name = source[name_start..name_end];

    // Find the declaration
    var found_decl: ?*FileAnalysis.Declaration = null;

    for (scope.declarations) |*d| {
        if (d.kind == .function and std.mem.eql(u8, d.name, func_name)) {
            found_decl = d;
            break;
        }
    }

    if (found_decl == null) {
        // fall back to builtins
        if (self.builtins.get(func_name)) |overloads| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();

            var sigs = std.ArrayList(response.SignatureHelp.SignatureInformation).empty;

            var best_active_param: u32 = active_param;
            for (overloads) |f| {
                if (f.parameters.len == 0 and active_param == 0 or
                    active_param < f.parameters.len)
                {
                    var label_buf = std.Io.Writer.Allocating.init(arena_alloc);
                    try label_buf.writer.print("{s} {s}(", .{ f.return_type, f.name });
                    var param_infos = std.ArrayList(response.SignatureHelp.ParameterInformation).empty;
                    for (f.parameters, 0..) |p, idx| {
                        if (idx > 0) try label_buf.writer.writeAll(", ");
                        const param_label = try std.fmt.allocPrint(arena_alloc, "{s} {s}", .{ p.type, p.name });
                        try label_buf.writer.writeAll(param_label);
                        try param_infos.append(arena_alloc, .{ .label = param_label });
                    }
                    try label_buf.writer.writeAll(")");
                    try sigs.append(arena_alloc, .{
                        .label = label_buf.written(),
                        .parameters = param_infos.items,
                    });
                    best_active_param = active_param;
                }
            }

            if (sigs.items.len == 0) {
                arena.deinit();
                return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });
            }

            const result = response.SignatureHelp.Result{
                .signatures = sigs.items,
                .activeSignature = 0,
                .activeParameter = best_active_param,
            };
            const resp = response.SignatureHelp{ .id = req.id, .result = result };
            const bytes = try json.Stringify.valueAlloc(allocator, resp, .{ .emit_null_optional_fields = false });
            arena.deinit();
            return bytes;
        }
        return json.Stringify.valueAlloc(allocator, empty_result, .{ .emit_null_optional_fields = false });
    }
    const decl = found_decl.?;
    for (scope.declarations) |*d| {
        if (d.kind == .function and std.mem.eql(u8, d.name, func_name)) {
            found_decl = d;
            break;
        }
    }
    const func = decl.kind.function;

    // Only show if active_param is within range
    if (active_param >= func.params.len and func.params.len > 0) {
        return json.Stringify.valueAlloc(allocator, empty_result, .{});
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build label: "return_type name(type param, ...)"
    var label_buf = std.Io.Writer.Allocating.init(arena_alloc);
    defer label_buf.deinit();
    try label_buf.writer.print("{s} {s}(", .{ func.return_type.name, func_name });
    var param_infos = std.ArrayList(response.SignatureHelp.ParameterInformation).empty;
    defer param_infos.deinit(arena_alloc);
    for (func.params, 0..) |p, idx| {
        if (idx > 0) try label_buf.writer.writeAll(", ");
        const param_label = try std.fmt.allocPrint(arena_alloc, "{s} {s}", .{ p.glsl_type.name, p.name });
        try label_buf.writer.writeAll(param_label);
        try param_infos.append(arena_alloc, .{ .label = param_label });
    }
    try label_buf.writer.writeAll(")");

    const sig = response.SignatureHelp.SignatureInformation{
        .label = label_buf.written(),
        .parameters = param_infos.items,
    };

    const result = response.SignatureHelp.Result{
        .signatures = &.{sig},
        .activeSignature = 0,
        .activeParameter = active_param,
    };
    const resp = response.SignatureHelp{ .id = req.id, .result = result };
    return json.Stringify.valueAlloc(allocator, resp, .{ .emit_null_optional_fields = false });
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
