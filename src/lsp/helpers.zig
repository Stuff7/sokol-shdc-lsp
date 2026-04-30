const std = @import("std");
const response = @import("response.zig");
const common = @import("common.zig");
const json = std.json;

const ShdcRunner = @import("../parser/ShdcRunner.zig");
const Request = @import("Request.zig");
const FileAnalysis = @import("../parser/FileAnalysis.zig");
const BuiltinFunction = common.BuiltinFunction;
const Allocator = std.mem.Allocator;
const Position = common.Position;

pub const Support = struct {
    bitset: std.bit_set.IntegerBitSet(@typeInfo(Feature).@"enum".fields.len) = .initEmpty(),

    pub fn has(self: @This(), feat: Feature) bool {
        return self.bitset.isSet(@intFromEnum(feat));
    }

    pub fn set(self: *@This(), feat: Feature, enabled: bool) void {
        if (enabled) self.enable(feat) else self.disable(feat);
    }

    pub fn enable(self: *@This(), feat: Feature) void {
        self.bitset.set(@intFromEnum(feat));
    }

    pub fn disable(self: *@This(), feat: Feature) void {
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

    pub fn applyClientCapabilities(self: *@This(), caps: Request.ClientCapabilities) void {
        if (caps.textDocument) |td| {
            if (if (td.hover) |h| h.contentFormat else null) |formats| {
                for (formats) |fmt| {
                    if (std.mem.eql(u8, fmt, "markdown")) {
                        self.enable(.markdown);
                        break;
                    }
                }
            }
            if (td.completion) |comp| {
                self.enable(.completion);
                if (if (comp.completionItem) |item| item.snippetSupport else false) |snippet| {
                    self.set(.snippets, snippet);
                }
            }
            self.set(.hover, td.hover != null);
            self.set(.definition, td.definition != null);
            self.set(.references, td.references != null);
            if (if (td.rename) |rename| rename.prepareSupport else null) |prep| {
                self.set(.rename_prepare, prep);
            }
            self.set(.document_formatting, td.documentFormatting != null);
            self.set(.range_formatting, td.documentFormatting != null);
        }
        if (caps.workspace) |ws| {
            self.set(.workspace_apply_edit, ws.applyEdit == true);
        }
    }
};

const TokenType = enum(u32) {
    namespace = 0,
    type = 1,
    @"struct" = 5,
    parameter = 7,
    variable = 8,
    property = 9,
    function = 12,
    keyword = 15,
};

pub const SemanticEntry = struct {
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
        .function_param => .parameter,
        else => null,
    };
}

pub fn appendSemanticEntry(list: *std.ArrayList(SemanticEntry), alloc: Allocator, kind: FileAnalysis.DeclKind, name: []const u8, range: FileAnalysis.Range) !void {
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

const CallContext = struct {
    func_name: []const u8,
    active_param: u32,
};

pub fn scanForCall(source: []const u8, offset: usize) ?CallContext {
    var active_param: u32 = 0;
    var depth: u32 = 0;
    var i: usize = offset;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) {
                    var name_end = i;
                    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
                    var name_start = name_end;
                    while (name_start > 0 and (std.ascii.isAlphanumeric(source[name_start - 1]) or source[name_start - 1] == '_')) name_start -= 1;
                    if (name_start == name_end) return null;
                    return .{ .func_name = source[name_start..name_end], .active_param = active_param };
                }
                depth -= 1;
            },
            ',' => if (depth == 0) {
                active_param += 1;
            },
            '\n' => return null,
            else => {},
        }
    }
    return null;
}

pub fn sigsFromDecl(arena: Allocator, decl: *const FileAnalysis.Declaration, active_param: u32) !?response.SignatureHelp.Result {
    const func = decl.kind.function;
    if (func.params.len > 0 and active_param >= func.params.len) return null;

    var label_buf = std.Io.Writer.Allocating.init(arena);
    try label_buf.writer.print("{s} {s}(", .{ func.return_type.name, decl.name });
    var param_infos = std.ArrayList(response.SignatureHelp.ParameterInformation).empty;
    for (func.params, 0..) |p, idx| {
        if (idx > 0) try label_buf.writer.writeAll(", ");
        const param_label = try std.fmt.allocPrint(arena, "{s} {s}", .{ p.glsl_type.name, p.name });
        try label_buf.writer.writeAll(param_label);
        try param_infos.append(arena, .{ .label = param_label });
    }
    try label_buf.writer.writeAll(")");

    return .{
        .signatures = try arena.dupe(response.SignatureHelp.SignatureInformation, &.{.{
            .label = label_buf.written(),
            .parameters = param_infos.items,
        }}),
        .activeSignature = 0,
        .activeParameter = active_param,
    };
}

pub fn sigsFromBuiltins(arena: Allocator, overloads: []const BuiltinFunction, active_param: u32) !?response.SignatureHelp.Result {
    var sigs = std.ArrayList(response.SignatureHelp.SignatureInformation).empty;
    for (overloads) |f| {
        if (f.parameters.len != 0 and active_param >= f.parameters.len) continue;
        var label_buf = std.Io.Writer.Allocating.init(arena);
        try label_buf.writer.print("{s} {s}(", .{ f.return_type, f.name });
        var param_infos = std.ArrayList(response.SignatureHelp.ParameterInformation).empty;
        for (f.parameters, 0..) |p, idx| {
            if (idx > 0) try label_buf.writer.writeAll(", ");
            const param_label = try std.fmt.allocPrint(arena, "{s} {s}", .{ p.type, p.name });
            try label_buf.writer.writeAll(param_label);
            try param_infos.append(arena, .{ .label = param_label });
        }
        try label_buf.writer.writeAll(")");
        try sigs.append(arena, .{ .label = label_buf.written(), .parameters = param_infos.items });
    }
    if (sigs.items.len == 0) return null;
    return .{ .signatures = sigs.items, .activeSignature = 0, .activeParameter = active_param };
}

pub fn formatBuiltinSignature(buf: *std.Io.Writer.Allocating, f: BuiltinFunction) !void {
    try buf.writer.print("{s} {s}(", .{ f.return_type, f.name });
    for (f.parameters, 0..) |p, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print("{s} {s}", .{ p.type, p.name });
    }
    try buf.writer.writeAll(")");
}

pub fn buildBuiltinDoc(arena: Allocator, overloads: []const BuiltinFunction) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);
    const o = overloads[0];
    if (overloads.len > 1) {
        try buf.writer.print("(+{d} overloads)\n\n", .{overloads.len - 1});
    }
    if (o.description) |lines| {
        for (lines) |line| try buf.writer.print("{s}\n", .{line});
    }
    return buf.toOwnedSlice();
}

pub fn hoverBuiltin(
    allocator: Allocator,
    builtins: *std.StringHashMap([]BuiltinFunction),
    builtin_types: *std.StringHashMap([]const u8),
    id: ?common.Id,
    word: []const u8,
) !?[]const u8 {
    if (builtins.get(word)) |overloads| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var buf = std.Io.Writer.Allocating.init(arena.allocator());
        const f = overloads[0];
        try buf.writer.writeAll("```glsl\n");
        try formatBuiltinSignature(&buf, f);
        try buf.writer.writeAll("\n```");
        if (overloads.len > 1) {
            try buf.writer.print("\n\n(+{d} overloads)", .{overloads.len - 1});
        }
        if (f.description) |desc| for (desc) |l| try buf.writer.print("\n\n{s}", .{l});
        const content = buf.written();
        const resp = response.Hover{ .id = id, .result = .{ .contents = .{ .kind = .markdown, .value = content } } };
        return try stringify(allocator, resp);
    }
    if (builtin_types.get(word)) |desc| {
        const content = try std.fmt.allocPrint(allocator, "```glsl\n{s}\n```\n\n{s}", .{ word, desc });
        const resp = response.Hover{ .id = id, .result = .{ .contents = .{ .kind = .markdown, .value = content } } };
        return try stringify(allocator, resp);
    }
    return null;
}

pub const FileEntry = struct {
    analysis: FileAnalysis,
    uri: []const u8,
};

pub fn getAnalysis(
    files: *std.StringHashMap(FileEntry),
    uri: []const u8,
) ?*FileAnalysis {
    const path = uriToPath(uri);
    const entry = files.getPtr(path) orelse return null;
    return &entry.analysis;
}

pub fn analyzeBuffer(
    allocator: Allocator,
    io: std.Io,
    files: *std.StringHashMap(FileEntry),
    runner_config: ShdcRunner.Config,
    uri: []const u8,
    content: []const u8,
) !void {
    const path = uriToPath(uri);

    const pid = std.os.linux.getpid();
    const tmp_path = try std.fmt.allocPrintSentinel(allocator, "/tmp/sokol_lsp_buf_{}.glsl", .{pid}, 0);
    defer {
        _ = std.os.linux.unlink(tmp_path);
        allocator.free(tmp_path);
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_path,
        .data = content,
    });

    if (files.fetchRemove(path)) |entry| {
        var old = entry.value;
        old.analysis.deinit();
        allocator.free(entry.key);
        allocator.free(old.uri);
    }

    const analysis = try ShdcRunner.run(io, allocator, tmp_path, runner_config);
    const key = try allocator.dupe(u8, path);
    const uri_owned = try allocator.dupe(u8, uri);
    try files.put(key, .{ .analysis = analysis, .uri = uri_owned });
}

pub fn analyzeFile(
    allocator: Allocator,
    io: std.Io,
    files: *std.StringHashMap(FileEntry),
    runner_config: ShdcRunner.Config,
    uri: []const u8,
) !void {
    const path = uriToPath(uri);

    if (files.fetchRemove(path)) |entry| {
        var old = entry.value;
        old.analysis.deinit();
        allocator.free(entry.key);
        allocator.free(old.uri);
    }

    const analysis = try ShdcRunner.run(io, allocator, path, runner_config);
    const key = try allocator.dupe(u8, path);
    const uri_owned = try allocator.dupe(u8, uri);
    try files.put(key, .{ .analysis = analysis, .uri = uri_owned });
}

pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
}

pub fn uriToPath(uri: []const u8) []const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return uri;
}

pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

pub fn posToOffset(source: []const u8, pos: Position) usize {
    var offset: usize = 0;
    var line: u32 = 0;
    while (offset < source.len) {
        if (line == pos.line) return offset + @min(pos.character, source.len - offset);
        if (source[offset] == '\n') line += 1;
        offset += 1;
    }
    return offset;
}

pub fn wordAt(source: []const u8, offset: usize) []const u8 {
    var start = offset;
    var end = offset;
    while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) end += 1;
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
    return source[start..end];
}
