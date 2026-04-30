const std = @import("std");

const FileAnalysis = @import("FileAnalysis.zig");
const Allocator = std.mem.Allocator;
const Location = FileAnalysis.Location;
const Range = FileAnalysis.Range;
const Declaration = FileAnalysis.Declaration;
const Reference = FileAnalysis.Reference;
const Scope = FileAnalysis.Scope;
const GlslType = FileAnalysis.GlslType;
const ScopeKind = FileAnalysis.ScopeKind;

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t\r");
}

pub fn makeRange(file: []const u8, start: Location, end: Location) Range {
    return .{ .file = file, .start = start, .end = end };
}

pub fn pointRange(file: []const u8, loc: Location) Range {
    return makeRange(file, loc, loc);
}

/// Finds the byte offset of `name` within `raw_line` and returns a range
/// spanning exactly that identifier. Falls back to a point range at col 0
/// if not found.
pub fn nameRange(file: []const u8, line_no: u32, raw_line: []const u8, name: []const u8) Range {
    var i: usize = 0;
    while (i + name.len <= raw_line.len) {
        const idx = std.mem.indexOf(u8, raw_line[i..], name) orelse break;
        const abs = i + idx;
        const before_ok = abs == 0 or !isIdentChar(raw_line[abs - 1]);
        const after_ok = abs + name.len >= raw_line.len or !isIdentChar(raw_line[abs + name.len]);
        if (before_ok and after_ok) {
            return makeRange(
                file,
                .{ .line = line_no, .col = @intCast(abs) },
                .{ .line = line_no, .col = @intCast(abs + name.len) },
            );
        }
        i = abs + 1;
    }
    return makeRange(file, .{ .line = line_no, .col = 0 }, .{ .line = line_no, .col = 0 });
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Returns the tag content if the line starts with `@tag` or `#pragma sokol @tag`,
/// stripping the tag itself. `tag` should not include the `@`.
pub fn sokolTag(line: []const u8, tag: []const u8) ?[]const u8 {
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
pub fn tokenize(s: []const u8, buf: [][]const u8) [][]const u8 {
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
pub fn parseBinding(s: []const u8) ?u32 {
    const prefix = "layout(binding=";
    const start = std.mem.indexOf(u8, s, prefix) orelse return null;
    const rest = s[start + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",)") orelse return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

/// Extracts format from `layout(..., rgba8, ...)` style. Returns null if not present.
pub fn parseLayoutFormat(s: []const u8) ?[]const u8 {
    const known = [_][]const u8{ "rgba8", "rgba16f", "rgba32f", "r32f", "r32ui", "rg16f" };
    for (known) |fmt| {
        if (std.mem.indexOf(u8, s, fmt) != null) return fmt;
    }
    return null;
}

/// Extracts access qualifier from a storage image line.
pub fn parseAccess(s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "readonly") != null) return "readonly";
    if (std.mem.indexOf(u8, s, "writeonly") != null) return "writeonly";
    if (std.mem.indexOf(u8, s, "readwrite") != null) return "readwrite";
    return "readonly";
}

/// Checks if a line contains `readonly` qualifier for storage buffers.
pub fn isReadonly(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "readonly") != null;
}

/// Strips a trailing `;` and trims.
pub fn stripSemicolon(s: []const u8) []const u8 {
    const t = trim(s);
    if (t.len > 0 and t[t.len - 1] == ';') return trim(t[0 .. t.len - 1]);
    return t;
}

pub const ScopeBuilder = struct {
    name: []const u8,
    kind: ScopeKind,
    start: Location,
    decls: std.ArrayList(Declaration),
    refs: std.ArrayList(Reference),

    pub fn init(name: []const u8, kind: ScopeKind, start: Location) ScopeBuilder {
        return .{
            .name = name,
            .kind = kind,
            .start = start,
            .decls = .empty,
            .refs = .empty,
        };
    }

    pub fn finish(self: *ScopeBuilder, allocator: Allocator, file: []const u8, end: Location) !Scope {
        return .{
            .name = self.name,
            .kind = self.kind,
            .range = makeRange(file, self.start, end),
            .declarations = try self.decls.toOwnedSlice(allocator),
            .references = try self.refs.toOwnedSlice(allocator),
        };
    }
};

pub fn stripInOut(line: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "flat in ", "smooth in ", "centroid in ", "in ", "flat out ", "smooth out ", "centroid out ", "out " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return line[p.len..];
    }
    return line;
}

pub fn extractLastToken(s: []const u8) []const u8 {
    var tok_buf: [16][]const u8 = undefined;
    const toks = tokenize(s, &tok_buf);
    if (toks.len == 0) return "";
    return toks[toks.len - 1];
}

pub fn extractNameBeforeBrace(line: []const u8) ?[]const u8 {
    const s = trim(line[0..(std.mem.lastIndexOf(u8, line, "{") orelse return null)]);
    return extractLastToken(s);
}

pub fn extractUniformType(line: []const u8) ?GlslType {
    const idx = std.mem.indexOf(u8, line, "uniform ") orelse return null;
    const rest = trimLeft(line[idx + "uniform ".len ..]);
    var tok_buf: [4][]const u8 = undefined;
    const toks = tokenize(rest, &tok_buf);
    if (toks.len == 0) return null;
    return .{ .name = toks[0] };
}

pub fn extractImageType(line: []const u8) ?[]const u8 {
    const image_types = [_][]const u8{ "image2D", "image3D", "imageCube", "image2DArray" };
    for (image_types) |t| {
        if (std.mem.indexOf(u8, line, t) != null) return t;
    }
    return null;
}

pub fn isParamQualifier(s: []const u8) bool {
    return std.mem.eql(u8, s, "in") or
        std.mem.eql(u8, s, "out") or
        std.mem.eql(u8, s, "inout") or
        std.mem.eql(u8, s, "const") or
        std.mem.eql(u8, s, "highp") or
        std.mem.eql(u8, s, "mediump") or
        std.mem.eql(u8, s, "lowp");
}

pub fn looksLikeGlslType(s: []const u8) bool {
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

pub fn looksLikeLocalDecl(line: []const u8) bool {
    var tok_buf: [4][]const u8 = undefined;
    const toks = tokenize(line, &tok_buf);
    if (toks.len < 2) return false;
    return looksLikeGlslType(toks[0]) and isIdentifier(toks[1]);
}

pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn resolveReferences(
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

pub fn containsStr(haystack: [][]const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

pub fn findDecl(decls: []FileAnalysis.Declaration, name: []const u8) ?FileAnalysis.Declaration {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}
