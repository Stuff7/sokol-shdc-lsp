const std = @import("std");
const FileAnalysis = @import("FileAnalysis.zig");

const Location = FileAnalysis.Location;
const Range = FileAnalysis.Range;
const Declaration = FileAnalysis.Declaration;
const Reference = FileAnalysis.Reference;
const Scope = FileAnalysis.Scope;
const ScopeKind = FileAnalysis.ScopeKind;
const DeclKind = FileAnalysis.DeclKind;
const GlslType = FileAnalysis.GlslType;
const ShaderStage = FileAnalysis.ShaderStage;
const Attr = FileAnalysis.Attr;
const UniformBlock = FileAnalysis.UniformBlock;
const UniformMember = FileAnalysis.UniformMember;
const Texture = FileAnalysis.Texture;
const Sampler = FileAnalysis.Sampler;
const StorageBuffer = FileAnalysis.StorageBuffer;
const StorageImage = FileAnalysis.StorageImage;
const FunctionParam = FileAnalysis.FunctionParam;
const Function = FileAnalysis.Function;
const StructMember = FileAnalysis.StructMember;
const Struct = FileAnalysis.Struct;
const Header = FileAnalysis.Header;
const CType = FileAnalysis.CType;
const Program = FileAnalysis.Program;
const Include = FileAnalysis.Include;
const IncludeBlock = FileAnalysis.IncludeBlock;
const ShaderOptions = FileAnalysis.ShaderOptions;

const Allocator = std.mem.Allocator;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t\r");
}

fn makeRange(file: []const u8, start: Location, end: Location) Range {
    return .{ .file = file, .start = start, .end = end };
}

fn pointRange(file: []const u8, loc: Location) Range {
    return makeRange(file, loc, loc);
}

/// Finds the byte offset of `name` within `raw_line` and returns a range
/// spanning exactly that identifier. Falls back to a point range at col 0
/// if not found.
fn nameRange(file: []const u8, line_no: u32, raw_line: []const u8, name: []const u8) Range {
    const col = std.mem.indexOf(u8, raw_line, name) orelse
        return makeRange(file, .{ .line = line_no, .col = 0 }, .{ .line = line_no, .col = 0 });
    return makeRange(
        file,
        .{ .line = line_no, .col = @intCast(col) },
        .{ .line = line_no, .col = @intCast(col + name.len) },
    );
}

/// Returns the tag content if the line starts with `@tag` or `#pragma sokol @tag`,
/// stripping the tag itself. `tag` should not include the `@`.
fn sokolTag(line: []const u8, tag: []const u8) ?[]const u8 {
    const stripped = blk: {
        const pragma = "#pragma sokol ";
        if (std.mem.startsWith(u8, line, pragma)) {
            break :blk line[pragma.len..];
        }
        break :blk line;
    };
    const at_tag = std.mem.concat(std.heap.page_allocator, u8, &.{ "@", tag }) catch return null;
    defer std.heap.page_allocator.free(at_tag);
    if (!std.mem.startsWith(u8, stripped, at_tag)) return null;
    const rest = stripped[at_tag.len..];
    if (rest.len == 0) return rest;
    if (rest[0] != ' ' and rest[0] != '\t') return null;
    return trim(rest);
}

/// Splits a string on whitespace, returns up to `max` tokens.
fn tokenize(s: []const u8, buf: [][]const u8) [][]const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        buf[n] = tok;
        n += 1;
    }
    return buf[0..n];
}

/// Extracts binding slot from `layout(binding=N)` prefix. Returns null if not present.
fn parseBinding(s: []const u8) ?u32 {
    const prefix = "layout(binding=";
    const start = std.mem.indexOf(u8, s, prefix) orelse return null;
    const rest = s[start + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",)") orelse return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

/// Extracts format from `layout(..., rgba8, ...)` style. Returns null if not present.
fn parseLayoutFormat(s: []const u8) ?[]const u8 {
    const known = [_][]const u8{ "rgba8", "rgba16f", "rgba32f", "r32f", "r32ui", "rg16f" };
    for (known) |fmt| {
        if (std.mem.indexOf(u8, s, fmt) != null) return fmt;
    }
    return null;
}

/// Extracts access qualifier from a storage image line.
fn parseAccess(s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "readonly") != null) return "readonly";
    if (std.mem.indexOf(u8, s, "writeonly") != null) return "writeonly";
    if (std.mem.indexOf(u8, s, "readwrite") != null) return "readwrite";
    return "readonly";
}

/// Checks if a line contains `readonly` qualifier for storage buffers.
fn isReadonly(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "readonly") != null;
}

/// Strips a trailing `;` and trims.
fn stripSemicolon(s: []const u8) []const u8 {
    const t = trim(s);
    if (t.len > 0 and t[t.len - 1] == ';') return trim(t[0 .. t.len - 1]);
    return t;
}

// ── Scope building ─────────────────────────────────────────────────────────────

const ScopeBuilder = struct {
    name: []const u8,
    kind: ScopeKind,
    start: Location,
    decls: std.ArrayList(Declaration),
    refs: std.ArrayList(Reference),

    fn init(name: []const u8, kind: ScopeKind, start: Location) ScopeBuilder {
        return .{
            .name = name,
            .kind = kind,
            .start = start,
            .decls = .empty,
            .refs = .empty,
        };
    }

    fn finish(self: *ScopeBuilder, allocator: Allocator, file: []const u8, end: Location) !Scope {
        return .{
            .name = self.name,
            .kind = self.kind,
            .range = makeRange(file, self.start, end),
            .declarations = try self.decls.toOwnedSlice(allocator),
            .references = try self.refs.toOwnedSlice(allocator),
        };
    }
};

// ── GLSL pass ─────────────────────────────────────────────────────────────────

/// State machine for parsing GLSL content within a scope.
const GlslParser = struct {
    const State = enum {
        top,
        uniform_block, // inside uniform { ... }
        storage_buffer, // inside buffer { ... }
        struct_body, // inside struct { ... }
        function_body, // inside a function body
    };

    allocator: Allocator,
    file: []const u8,
    scope_stage: ShaderStage,
    state: State = .top,
    brace_depth: u32 = 0,

    // Pending context accumulated across lines
    pending_binding: ?u32 = null,
    pending_format: ?[]const u8 = null,
    pending_access: ?[]const u8 = null,
    pending_struct_name: ?[]const u8 = null,
    pending_struct_start: ?Location = null,
    pending_struct_members: std.ArrayList(StructMember) = undefined,
    pending_function_depth: u32 = 0,

    fn init(allocator: Allocator, file: []const u8, stage: ShaderStage) GlslParser {
        var self = GlslParser{
            .allocator = allocator,
            .file = file,
            .scope_stage = stage,
        };
        self.pending_struct_members = .empty;
        return self;
    }

    fn deinit(self: *GlslParser) void {
        self.pending_struct_members.deinit(self.allocator);
    }

    fn parseLine(
        self: *GlslParser,
        raw: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
        refs: *std.ArrayList(Reference),
    ) !void {
        const line = trim(raw);
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) return;

        // Track brace depth
        for (line) |c| {
            if (c == '{') self.brace_depth += 1;
            if (c == '}') {
                if (self.brace_depth > 0) self.brace_depth -= 1;
            }
        }

        switch (self.state) {
            .top => try self.parseTop(raw, line_no, decls, refs),
            .uniform_block => try self.parseUniformBlockBody(raw, line_no, decls),
            .struct_body => try self.parseStructBody(raw, line_no, decls),
            .storage_buffer => try self.parseStorageBufferBody(line, line_no, decls),
            .function_body => try self.parseFunctionBody(raw, line_no, decls, refs),
        }
    }

    fn parseTop(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
        refs: *std.ArrayList(Reference),
    ) !void {
        const line = trim(raw_line);
        // layout(...) prefix — capture binding/format/access for next line
        if (std.mem.startsWith(u8, line, "layout(")) {
            self.pending_binding = parseBinding(line);
            self.pending_format = parseLayoutFormat(line);
            self.pending_access = if (std.mem.indexOf(u8, line, "image") != null)
                parseAccess(line)
            else
                null;
            // If the declaration is on the same line, fall through
            if (!std.mem.endsWith(u8, line, ";") and
                !std.mem.endsWith(u8, line, "{") and
                std.mem.indexOf(u8, line, "uniform") == null and
                std.mem.indexOf(u8, line, "buffer") == null) return;
        }

        // in/out attributes
        const is_in = std.mem.startsWith(u8, line, "in ") or
            std.mem.startsWith(u8, line, "flat in ") or
            std.mem.startsWith(u8, line, "smooth in ");
        const is_out = std.mem.startsWith(u8, line, "out ") or
            std.mem.startsWith(u8, line, "flat out ") or
            std.mem.startsWith(u8, line, "smooth out ");
        if (is_in or is_out) {
            const is_input = is_in;
            const slot = self.pending_binding;
            self.pending_binding = null;
            const stripped = stripInOut(line);
            const s = trim(stripSemicolon(stripped));
            var tok_buf: [16][]const u8 = undefined;
            const toks = tokenize(s, &tok_buf);
            if (toks.len >= 2) {
                const glsl_type: GlslType = .{ .name = toks[0] };
                var it = std.mem.splitScalar(u8, trim(s[toks[0].len..]), ',');
                while (it.next()) |raw| {
                    var name = trim(raw);
                    if (std.mem.indexOf(u8, name, "=")) |eq| name = trim(name[0..eq]);
                    if (std.mem.indexOf(u8, name, "[")) |br| name = trim(name[0..br]);
                    if (name.len == 0) continue;
                    try decls.append(self.allocator, .{
                        .name = name,
                        .range = nameRange(self.file, line_no, raw_line, name),
                        .kind = .{ .attr = .{
                            .slot = slot,
                            .glsl_type = glsl_type,
                            .is_input = is_input,
                        } },
                    });
                }
            }
            return;
        }

        // uniform block: `layout(...) uniform BlockName {`
        if (std.mem.indexOf(u8, line, "uniform") != null and
            std.mem.endsWith(u8, line, "{"))
        {
            // texture/sampler uniforms handled below — block has `{`
            const slot = self.pending_binding;
            self.pending_binding = null;
            const name = extractNameBeforeBrace(line) orelse "unknown";
            try decls.append(self.allocator, .{
                .name = name,
                .range = nameRange(self.file, line_no, raw_line, name),
                .kind = .{ .uniform_block = .{
                    .slot = slot,
                    .stage = self.scope_stage,
                } },
            });
            self.state = .uniform_block;
            return;
        }

        // texture uniform: `layout(...) uniform texture2D name;`
        if (std.mem.indexOf(u8, line, "uniform texture") != null) {
            const slot = self.pending_binding;
            self.pending_binding = null;
            const glsl_type = extractUniformType(line) orelse GlslType{ .name = "texture2D" };
            const name = extractLastToken(stripSemicolon(line));
            try decls.append(self.allocator, .{
                .name = name,
                .range = nameRange(self.file, line_no, raw_line, name),
                .kind = .{ .texture = .{
                    .slot = slot,
                    .stage = self.scope_stage,
                    .glsl_type = glsl_type,
                } },
            });
            return;
        }

        // sampler uniform: `layout(...) uniform sampler name;`
        if (std.mem.indexOf(u8, line, "uniform sampler") != null and
            !std.mem.endsWith(u8, line, "{"))
        {
            const slot = self.pending_binding;
            self.pending_binding = null;
            const name = extractLastToken(stripSemicolon(line));
            try decls.append(self.allocator, .{
                .name = name,
                .range = nameRange(self.file, line_no, raw_line, name),
                .kind = .{ .sampler = .{
                    .slot = slot,
                    .stage = self.scope_stage,
                } },
            });
            return;
        }

        // storage image: `layout(...) uniform writeonly image2D name;`
        if (std.mem.indexOf(u8, line, "uniform") != null and
            std.mem.indexOf(u8, line, "image") != null and
            std.mem.endsWith(u8, line, ";"))
        {
            const slot = self.pending_binding;
            const fmt = self.pending_format;
            const access = self.pending_access orelse "writeonly";
            self.pending_binding = null;
            self.pending_format = null;
            self.pending_access = null;
            const name = extractLastToken(stripSemicolon(line));
            const type_name = extractImageType(line) orelse "image2D";
            try decls.append(self.allocator, .{
                .name = name,
                .range = nameRange(self.file, line_no, raw_line, name),
                .kind = .{ .storage_image = .{
                    .slot = slot,
                    .stage = self.scope_stage,
                    .format = fmt,
                    .access = access,
                    .glsl_type = .{ .name = type_name },
                } },
            });
            return;
        }

        // storage buffer: `layout(...) readonly buffer Name {`
        if (std.mem.indexOf(u8, line, "buffer") != null and
            std.mem.endsWith(u8, line, "{"))
        {
            const slot = self.pending_binding;
            self.pending_binding = null;
            const readonly = isReadonly(line);
            const name = extractNameBeforeBrace(line) orelse "unknown";
            const sb_decl = Declaration{
                .name = name,
                .range = nameRange(self.file, line_no, raw_line, name),
                .kind = .{ .storage_buffer = .{
                    .slot = slot,
                    .stage = self.scope_stage,
                    .readonly = readonly,
                    .struct_name = name,
                } },
            };
            try decls.append(self.allocator, sb_decl);
            self.state = .storage_buffer;
            return;
        }

        // struct definition: `struct Name {`
        if (std.mem.startsWith(u8, line, "struct ") and
            std.mem.endsWith(u8, line, "{"))
        {
            var tok_buf: [4][]const u8 = undefined;
            const toks = tokenize(line, &tok_buf);
            if (toks.len >= 2) {
                self.pending_struct_name = toks[1];
                self.pending_struct_start = .{ .line = line_no, .col = 0 };
                self.pending_struct_members.clearRetainingCapacity();
                self.state = .struct_body;
            }
            return;
        }

        // function definition: `type name(params) {`
        if (std.mem.endsWith(u8, line, "{") and
            std.mem.indexOf(u8, line, "(") != null and
            std.mem.indexOf(u8, line, ")") != null and
            !std.mem.startsWith(u8, line, "if") and
            !std.mem.startsWith(u8, line, "for") and
            !std.mem.startsWith(u8, line, "while") and
            !std.mem.startsWith(u8, line, "else"))
        {
            if (try self.parseFunctionSignature(raw_line, line_no, decls)) {
                self.state = .function_body;
                self.pending_function_depth = self.brace_depth;
            }
            return;
        }

        // top-level variable declaration (outside functions)
        if (std.mem.endsWith(u8, line, ";") and
            !std.mem.startsWith(u8, line, "return") and
            !std.mem.startsWith(u8, line, "//"))
        {
            try self.parseLocalVar(line, line_no, decls);
        }

        // references — scan all identifiers against known decls after all passes
        _ = refs;
    }

    fn parseUniformBlockBody(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
    ) !void {
        const line = trim(raw_line);
        if (std.mem.startsWith(u8, line, "}")) {
            self.state = .top;
            return;
        }
        if (!std.mem.endsWith(u8, line, ";")) return;

        // Parse member: `type name;` or `type name[N];`
        const s = stripSemicolon(line);
        var tok_buf: [4][]const u8 = undefined;
        const toks = tokenize(s, &tok_buf);
        if (toks.len < 2) return;

        const glsl_type: GlslType = .{ .name = toks[0] };
        const raw_name = toks[1];
        // Strip array suffix from name
        const name = if (std.mem.indexOf(u8, raw_name, "[")) |i|
            raw_name[0..i]
        else
            raw_name;

        // Detect array count
        const array_count: ?u32 = if (std.mem.indexOf(u8, raw_name, "[")) |i| blk: {
            const inner = raw_name[i + 1 ..];
            const close = std.mem.indexOf(u8, inner, "]") orelse break :blk null;
            break :blk std.fmt.parseInt(u32, inner[0..close], 10) catch null;
        } else null;

        try decls.append(self.allocator, .{
            .name = name,
            .range = nameRange(self.file, line_no, raw_line, name),
            .kind = .{ .uniform_member = .{
                .glsl_type = glsl_type,
                .array_count = array_count,
            } },
        });
    }

    fn parseStorageBufferBody(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
    ) !void {
        _ = line_no;
        const line = trim(raw_line);
        if (std.mem.startsWith(u8, line, "}")) {
            self.state = .top;
            return;
        }
        // Storage buffer body contains struct members — parse as struct members
        // but attach them to the buffer's struct type, not as top-level decls.
        // We track them as uniform_members for LSP purposes.
        if (!std.mem.endsWith(u8, line, ";")) return;
        const s = stripSemicolon(line);
        var tok_buf: [4][]const u8 = undefined;
        const toks = tokenize(s, &tok_buf);
        if (toks.len < 2) return;
        _ = decls;
        // Storage buffer members are not individually declared in LSP scope —
        // they're accessed via the buffer instance name. Skip for now.
    }

    fn parseStructBody(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
    ) !void {
        const line = trim(raw_line);
        if (std.mem.startsWith(u8, line, "}")) {
            if (self.pending_struct_name) |name| {
                const members = try self.pending_struct_members.toOwnedSlice(self.allocator);
                const end_loc = Location{ .line = line_no, .col = 0 };
                try decls.append(self.allocator, .{
                    .name = name,
                    .range = makeRange(
                        self.file,
                        self.pending_struct_start orelse end_loc,
                        end_loc,
                    ),
                    .kind = .{ .@"struct" = .{ .members = members } },
                });
                self.pending_struct_name = null;
                self.pending_struct_start = null;
            }
            self.state = .top;
            return;
        }
        if (!std.mem.endsWith(u8, line, ";")) return;
        const s = stripSemicolon(line);
        var tok_buf: [4][]const u8 = undefined;
        const toks = tokenize(s, &tok_buf);
        if (toks.len < 2) return;
        try self.pending_struct_members.append(self.allocator, .{
            .name = toks[1],
            .glsl_type = .{ .name = toks[0] },
            .range = nameRange(self.file, line_no, raw_line, toks[1]),
        });
    }

    fn parseFunctionBody(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
        refs: *std.ArrayList(Reference),
    ) !void {
        _ = refs;
        const line = trim(raw_line);
        // Exit function body when we return to the depth we entered at
        if (std.mem.startsWith(u8, line, "}") and
            self.brace_depth < self.pending_function_depth)
        {
            self.state = .top;
            return;
        }
        // Parse local variable declarations
        if (std.mem.endsWith(u8, line, ";") and
            !std.mem.startsWith(u8, line, "return") and
            !std.mem.startsWith(u8, line, "//") and
            std.mem.indexOf(u8, line, "=") == null or
            (std.mem.endsWith(u8, line, ";") and
                !std.mem.startsWith(u8, line, "return") and
                looksLikeLocalDecl(line)))
        {
            try self.parseLocalVar(raw_line, line_no, decls);
        }
    }

    fn parseLocalVar(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
    ) !void {
        const line = trim(raw_line);
        const s = trim(stripSemicolon(line));
        // Must start with a known GLSL type or a word that looks like a type
        var tok_buf: [8][]const u8 = undefined;
        const toks = tokenize(s, &tok_buf);
        if (toks.len < 2) return;
        if (!looksLikeGlslType(toks[0])) return;

        const glsl_type: GlslType = .{ .name = toks[0] };
        const rest = trim(s[toks[0].len..]);

        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |raw| {
            const decl_str = trim(raw);
            if (decl_str.len == 0) continue;
            const name = blk: {
                var n = decl_str;
                if (std.mem.indexOf(u8, n, "=")) |eq| n = trim(n[0..eq]);
                if (std.mem.indexOf(u8, n, "[")) |br| n = trim(n[0..br]);
                break :blk trim(n);
            };
            if (name.len == 0 or !isIdentifier(name)) continue;
            try decls.append(self.allocator, .{
                .name = name,
                .range = nameRange(self.file, line_no, raw_line, name),
                .kind = .{ .local_var = glsl_type },
            });
        }
    }

    fn parseFunctionSignature(
        self: *GlslParser,
        raw_line: []const u8,
        line_no: u32,
        decls: *std.ArrayList(Declaration),
    ) !bool {
        const line = trim(raw_line);
        // `return_type name(param_type param_name, ...) {`
        const paren_open = std.mem.indexOf(u8, line, "(") orelse return false;
        const paren_close = std.mem.lastIndexOf(u8, line, ")") orelse return false;
        if (paren_close < paren_open) return false;

        const before_paren = trim(line[0..paren_open]);
        var tok_buf: [4][]const u8 = undefined;
        const toks = tokenize(before_paren, &tok_buf);
        if (toks.len < 2) return false;

        const return_type: GlslType = .{ .name = toks[toks.len - 2] };
        const fn_name = toks[toks.len - 1];
        const params_str = trim(line[paren_open + 1 .. paren_close]);

        var params: std.ArrayList(FunctionParam) = .empty;
        if (params_str.len > 0 and !std.mem.eql(u8, params_str, "void")) {
            var pit = std.mem.splitScalar(u8, params_str, ',');
            while (pit.next()) |raw_param| {
                const p = trim(raw_param);
                var ptok_buf: [6][]const u8 = undefined;
                const ptoks = tokenize(p, &ptok_buf);
                if (ptoks.len < 2) continue;
                // Skip qualifiers: in, out, inout, const
                var ti: usize = 0;
                while (ti < ptoks.len and isParamQualifier(ptoks[ti])) : (ti += 1) {}
                if (ti + 1 >= ptoks.len) continue;
                try params.append(self.allocator, .{
                    .name = ptoks[ti + 1],
                    .glsl_type = .{ .name = ptoks[ti] },
                    .range = nameRange(self.file, line_no, raw_line, ptoks[ti + 1]),
                });
            }
        }

        try decls.append(self.allocator, .{
            .name = fn_name,
            .range = nameRange(self.file, line_no, raw_line, fn_name),
            .kind = .{ .function = .{
                .return_type = return_type,
                .params = try params.toOwnedSlice(self.allocator),
            } },
        });
        return true;
    }
};

// ── Small GLSL helpers ─────────────────────────────────────────────────────────

fn stripInOut(line: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "flat in ", "smooth in ", "centroid in ", "in ", "flat out ", "smooth out ", "centroid out ", "out " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return line[p.len..];
    }
    return line;
}

fn extractLastToken(s: []const u8) []const u8 {
    var tok_buf: [16][]const u8 = undefined;
    const toks = tokenize(s, &tok_buf);
    if (toks.len == 0) return "";
    return toks[toks.len - 1];
}

fn extractNameBeforeBrace(line: []const u8) ?[]const u8 {
    const s = trim(line[0..(std.mem.lastIndexOf(u8, line, "{") orelse return null)]);
    return extractLastToken(s);
}

fn extractUniformType(line: []const u8) ?GlslType {
    // `uniform texture2D name` -> type is token after "uniform"
    const idx = std.mem.indexOf(u8, line, "uniform ") orelse return null;
    const rest = trimLeft(line[idx + "uniform ".len ..]);
    var tok_buf: [4][]const u8 = undefined;
    const toks = tokenize(rest, &tok_buf);
    if (toks.len == 0) return null;
    return .{ .name = toks[0] };
}

fn extractImageType(line: []const u8) ?[]const u8 {
    const image_types = [_][]const u8{ "image2D", "image3D", "imageCube", "image2DArray" };
    for (image_types) |t| {
        if (std.mem.indexOf(u8, line, t) != null) return t;
    }
    return null;
}

fn isParamQualifier(s: []const u8) bool {
    return std.mem.eql(u8, s, "in") or
        std.mem.eql(u8, s, "out") or
        std.mem.eql(u8, s, "inout") or
        std.mem.eql(u8, s, "const") or
        std.mem.eql(u8, s, "highp") or
        std.mem.eql(u8, s, "mediump") or
        std.mem.eql(u8, s, "lowp");
}

fn looksLikeGlslType(s: []const u8) bool {
    const builtins = [_][]const u8{
        "float",     "double",    "int",       "uint",      "bool",
        "vec2",      "vec3",      "vec4",      "dvec2",     "dvec3",
        "dvec4",     "ivec2",     "ivec3",     "ivec4",     "uvec2",
        "uvec3",     "uvec4",     "bvec2",     "bvec3",     "bvec4",
        "mat2",      "mat3",      "mat4",      "mat2x2",    "mat2x3",
        "mat2x4",    "mat3x2",    "mat3x3",    "mat3x4",    "mat4x2",
        "mat4x3",    "mat4x4",    "sampler2D", "sampler3D", "samplerCube",
        "texture2D", "texture3D",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, s, b)) return true;
    }
    // Also accept user-defined types (capitalized or containing upper case — heuristic)
    return s.len > 0 and (std.ascii.isUpper(s[0]) or isIdentifier(s));
}

fn looksLikeLocalDecl(line: []const u8) bool {
    var tok_buf: [4][]const u8 = undefined;
    const toks = tokenize(line, &tok_buf);
    if (toks.len < 2) return false;
    return looksLikeGlslType(toks[0]) and isIdentifier(toks[1]);
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// ── Reference resolution pass ──────────────────────────────────────────────────

fn resolveReferences(
    allocator: Allocator,
    file: []const u8,
    source: []const u8,
    scopes: []Scope,
) !void {
    // Build a flat map of name -> *Declaration across all scopes
    var decl_map = std.StringHashMap(*Declaration).init(allocator);
    defer decl_map.deinit();

    for (scopes) |*scope| {
        for (scope.declarations) |*decl| {
            try decl_map.put(decl.name, decl);
            // Also index function params
            if (decl.kind == .function) {
                for (decl.kind.function.params) |*param| {
                    _ = param;
                }
            }
        }
    }

    // Scan each scope's source range for identifier usages
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 0;
    for (scopes) |*scope| {
        decl_map.clearRetainingCapacity();
        for (scope.declarations) |*decl| {
            try decl_map.put(decl.name, decl);
        }

        var refs: std.ArrayList(Reference) = .empty;
        lines = std.mem.splitScalar(u8, source, '\n');
        line_no = 0;

        while (lines.next()) |raw_line| {
            defer line_no += 1;
            if (line_no < scope.range.start.line or line_no > scope.range.end.line) continue;
            const trimmed = trim(raw_line);
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;

            var i: usize = 0;
            while (i < raw_line.len) {
                if (std.ascii.isAlphabetic(raw_line[i]) or raw_line[i] == '_') {
                    const start = i;
                    while (i < raw_line.len and (std.ascii.isAlphanumeric(raw_line[i]) or raw_line[i] == '_')) : (i += 1) {}
                    const ident = raw_line[start..i];
                    const col: u32 = @intCast(start);
                    if (decl_map.get(ident)) |decl| {
                        if (decl.range.start.line == line_no and decl.range.start.col == col) continue;
                        try refs.append(allocator, .{
                            .name = ident,
                            .range = makeRange(
                                file,
                                .{ .line = line_no, .col = col },
                                .{ .line = line_no, .col = col + @as(u32, @intCast(ident.len)) },
                            ),
                            .decl = decl,
                        });
                    }
                } else {
                    i += 1;
                }
            }
        }
        scope.references = try refs.toOwnedSlice(allocator);
    }
}

// ── Main parser ────────────────────────────────────────────────────────────────

pub fn parse(
    parent_allocator: Allocator,
    file: []const u8,
    source_in: []const u8,
    slang: []const u8,
) !FileAnalysis {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const source = try allocator.dupe(u8, source_in);

    var top_level: std.ArrayList(Declaration) = .empty;
    var scopes: std.ArrayList(Scope) = .empty;

    var current_scope: ?ScopeBuilder = null;
    var glsl_parser: ?GlslParser = null;

    // Pending per-scope annotations accumulated before the block opens
    var pending_image_sample_type: ?struct { tex: []const u8, kind: []const u8 } = null;
    var pending_sampler_type: ?struct { smp: []const u8, kind: []const u8 } = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 0;

    while (lines.next()) |raw_line| {
        defer line_no += 1;
        const line = trim(raw_line);
        const loc = Location{ .line = line_no, .col = 0 };

        if (line.len == 0) continue;

        // ── Sokol tag detection ────────────────────────────────────────────────

        if (sokolTag(line, "vs")) |name| {
            current_scope = ScopeBuilder.init(name, .vs, loc);
            glsl_parser = GlslParser.init(allocator, file, .vertex);
            continue;
        }
        if (sokolTag(line, "fs")) |name| {
            current_scope = ScopeBuilder.init(name, .fs, loc);
            glsl_parser = GlslParser.init(allocator, file, .fragment);
            continue;
        }
        if (sokolTag(line, "cs")) |name| {
            current_scope = ScopeBuilder.init(name, .cs, loc);
            glsl_parser = GlslParser.init(allocator, file, .compute);
            continue;
        }
        if (sokolTag(line, "block")) |name| {
            current_scope = ScopeBuilder.init(name, .block, loc);
            glsl_parser = GlslParser.init(allocator, file, .unknown);
            continue;
        }

        if (sokolTag(line, "end")) |_| {
            if (current_scope) |*sb| {
                if (glsl_parser) |*gp| {
                    gp.deinit();
                    glsl_parser = null;
                }
                // Apply pending annotations to matching decls
                if (pending_image_sample_type) |ann| {
                    for (sb.decls.items) |*decl| {
                        if (std.mem.eql(u8, decl.name, ann.tex)) {
                            if (decl.kind == .texture) {
                                decl.kind.texture.image_sample_type = ann.kind;
                            }
                        }
                    }
                    pending_image_sample_type = null;
                }
                if (pending_sampler_type) |ann| {
                    for (sb.decls.items) |*decl| {
                        if (std.mem.eql(u8, decl.name, ann.smp)) {
                            if (decl.kind == .sampler) {
                                decl.kind.sampler.sampler_type_hint = ann.kind;
                            }
                        }
                    }
                    pending_sampler_type = null;
                }
                const scope = try sb.finish(allocator, file, loc);
                try scopes.append(allocator, scope);
                current_scope = null;
            }
            continue;
        }

        // ── Top-level tags (outside any scope) ────────────────────────────────

        if (current_scope == null) {
            if (sokolTag(line, "header")) |content| {
                try top_level.append(allocator, .{
                    .name = "",
                    .range = pointRange(file, loc),
                    .kind = .{ .header = .{ .content = content } },
                });
                continue;
            }
            if (sokolTag(line, "ctype")) |content| {
                var tok_buf: [4][]const u8 = undefined;
                const toks = tokenize(content, &tok_buf);
                if (toks.len >= 2) {
                    try top_level.append(allocator, .{
                        .name = toks[0],
                        .range = nameRange(file, line_no, raw_line, toks[0]),
                        .kind = .{ .ctype = .{
                            .glsl_type = toks[0],
                            .target_type = toks[1],
                        } },
                    });
                }
                continue;
            }
            if (sokolTag(line, "module")) |name| {
                try top_level.append(allocator, .{
                    .name = name,
                    .range = nameRange(file, line_no, raw_line, name),
                    .kind = .module,
                });
                continue;
            }
            if (sokolTag(line, "program")) |content| {
                var tok_buf: [4][]const u8 = undefined;
                const toks = tokenize(content, &tok_buf);
                if (toks.len >= 3) {
                    try top_level.append(allocator, .{
                        .name = toks[0],
                        .range = nameRange(file, line_no, raw_line, toks[0]),
                        .kind = .{ .program = .{
                            .vs_name = toks[1],
                            .fs_name = toks[2],
                        } },
                    });
                } else if (toks.len == 2) {
                    // compute-only program
                    try top_level.append(allocator, .{
                        .name = toks[0],
                        .range = nameRange(file, line_no, raw_line, toks[0]),
                        .kind = .{ .program = .{
                            .vs_name = "",
                            .cs_name = toks[1],
                        } },
                    });
                }
                continue;
            }
            if (sokolTag(line, "include")) |path| {
                try top_level.append(allocator, .{
                    .name = path,
                    .range = nameRange(file, line_no, raw_line, path),
                    .kind = .{ .include = .{ .path = path } },
                });
                continue;
            }
        }

        // ── Within-scope tags ──────────────────────────────────────────────────

        if (current_scope != null) {
            if (sokolTag(line, "include_block")) |name| {
                try current_scope.?.decls.append(allocator, .{
                    .name = name,
                    .range = pointRange(file, loc),
                    .kind = .{ .include_block = .{ .block_name = name } },
                });
                continue;
            }

            inline for ([_]struct { tag: []const u8, field: []const u8 }{
                .{ .tag = "glsl_options", .field = "glsl_options" },
                .{ .tag = "hlsl_options", .field = "hlsl_options" },
                .{ .tag = "msl_options", .field = "msl_options" },
            }) |entry| {
                if (sokolTag(line, entry.tag)) |content| {
                    var opts: std.ArrayList([]const u8) = .empty;
                    var it = std.mem.tokenizeAny(u8, content, " \t");
                    while (it.next()) |opt| try opts.append(allocator, opt);
                    try current_scope.?.decls.append(allocator, .{
                        .name = "",
                        .range = pointRange(file, loc),
                        .kind = @unionInit(DeclKind, entry.field, .{
                            .options = try opts.toOwnedSlice(allocator),
                        }),
                    });
                }
            }

            if (sokolTag(line, "image_sample_type")) |content| {
                var tok_buf: [4][]const u8 = undefined;
                const toks = tokenize(content, &tok_buf);
                if (toks.len >= 2) {
                    pending_image_sample_type = .{ .tex = toks[0], .kind = toks[1] };
                }
                continue;
            }
            if (sokolTag(line, "sampler_type")) |content| {
                var tok_buf: [4][]const u8 = undefined;
                const toks = tokenize(content, &tok_buf);
                if (toks.len >= 2) {
                    pending_sampler_type = .{ .smp = toks[0], .kind = toks[1] };
                }
                continue;
            }

            // Feed line to GLSL parser
            if (glsl_parser) |*gp| {
                try gp.parseLine(
                    raw_line,
                    line_no,
                    &current_scope.?.decls,
                    &current_scope.?.refs,
                );
            }
        }
    }

    // ── Pass 3: resolve references ─────────────────────────────────────────────
    const scopes_slice = try scopes.toOwnedSlice(allocator);
    try resolveReferences(allocator, file, source, scopes_slice);

    _ = slang; // used by caller to invoke sokol-shdc

    return FileAnalysis{
        .arena = arena,
        .file = file,
        .source = source,
        .diagnostics = &.{}, // filled by ShdcRunner
        .scopes = scopes_slice,
        .top_level = try top_level.toOwnedSlice(allocator),
    };
}

test "parser: basic sokol shader" {
    const allocator = std.testing.allocator;

    const source =
        \\@header const m = @import("../math.zig")
        \\@ctype mat4 m.Mat4
        \\
        \\@vs vs
        \\layout(binding = 0) uniform vs_params {
        \\  mat4 mvp;
        \\};
        \\
        \\in vec3 position;
        \\out vec3 frag_normal;
        \\
        \\void main() {
        \\  gl_Position = mvp * vec4(position, 1.0);
        \\}
        \\@end
        \\
        \\@fs fs
        \\out vec4 frag_color;
        \\
        \\void main() {
        \\  frag_color = vec4(1.0);
        \\}
        \\@end
        \\
        \\@program chunk vs fs
    ;

    var analysis = try parse(allocator, "test.glsl", source, "glsl430");
    defer analysis.deinit();

    // Top-level: @header, @ctype, @program
    try std.testing.expectEqual(@as(usize, 3), analysis.top_level.len);
    try std.testing.expect(analysis.top_level[0].kind == .header);
    try std.testing.expect(analysis.top_level[1].kind == .ctype);
    try std.testing.expect(analysis.top_level[2].kind == .program);
    try std.testing.expectEqualStrings("chunk", analysis.top_level[2].name);

    // Two scopes: vs and fs
    try std.testing.expectEqual(@as(usize, 2), analysis.scopes.len);
    try std.testing.expectEqual(ScopeKind.vs, analysis.scopes[0].kind);
    try std.testing.expectEqual(ScopeKind.fs, analysis.scopes[1].kind);

    // vs scope: uniform block, uniform member, attr in, attr out, function
    const vs = analysis.scopes[0];
    const vs_names = blk: {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        for (vs.declarations) |d| try names.append(allocator, d.name);
        break :blk try names.toOwnedSlice(allocator);
    };
    defer allocator.free(vs_names);

    try std.testing.expect(containsStr(vs_names, "vs_params"));
    try std.testing.expect(containsStr(vs_names, "mvp"));
    try std.testing.expect(containsStr(vs_names, "position"));
    try std.testing.expect(containsStr(vs_names, "frag_normal"));
    try std.testing.expect(containsStr(vs_names, "main"));

    // Check kinds
    const mvp = findDecl(vs.declarations, "mvp").?;
    try std.testing.expect(mvp.kind == .uniform_member);

    const position = findDecl(vs.declarations, "position").?;
    try std.testing.expect(position.kind == .attr);
    try std.testing.expect(position.kind.attr.is_input);

    const frag_normal = findDecl(vs.declarations, "frag_normal").?;
    try std.testing.expect(frag_normal.kind == .attr);
    try std.testing.expect(!frag_normal.kind.attr.is_input);
}

fn containsStr(haystack: [][]const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn findDecl(decls: []FileAnalysis.Declaration, name: []const u8) ?FileAnalysis.Declaration {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}
