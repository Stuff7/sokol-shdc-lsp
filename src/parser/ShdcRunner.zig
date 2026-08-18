const std = @import("std");
const FileAnalysis = @import("FileAnalysis.zig");
const Parser = @import("Parser.zig");
const yaml = @import("yaml");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diagnostic = FileAnalysis.Diagnostic;
const DiagnosticKind = FileAnalysis.DiagnosticKind;

pub const Config = struct {
    shdc_path: []const u8 = "sokol-shdc",
    slang: []const u8 = "glsl430",
};

/// Parses a single gcc-format diagnostic line:
/// `file:line:col: error: message` or `file:line:col: warning: message`
fn parseDiagnosticLine(line: []const u8, allocator: Allocator) ?Diagnostic {
    const error_marker = ": error: ";
    const warning_marker = ": warning: ";
    const note_marker = ": note: ";

    const kind: DiagnosticKind, const marker_start: usize, const marker_len: usize = blk: {
        if (std.mem.indexOf(u8, line, error_marker)) |i|
            break :blk .{ .@"error", i, error_marker.len };
        if (std.mem.indexOf(u8, line, warning_marker)) |i|
            break :blk .{ .warning, i, warning_marker.len };
        if (std.mem.indexOf(u8, line, note_marker)) |i|
            break :blk .{ .note, i, note_marker.len };
        return null;
    };

    const prefix = line[0..marker_start];
    const message = line[marker_start + marker_len ..];

    // prefix is `file:line:col`
    var it = std.mem.splitScalar(u8, prefix, ':');
    const file = it.next() orelse return null;
    const line_str = it.next() orelse return null;
    const col_str = it.next() orelse return null;

    const line_no = std.fmt.parseInt(u32, std.mem.trim(u8, line_str, " "), 10) catch return null;
    const col_no = std.fmt.parseInt(u32, std.mem.trim(u8, col_str, " "), 10) catch return null;

    const file_duped = allocator.dupe(u8, file) catch return null;
    const msg_duped = allocator.dupe(u8, message) catch return null;

    return .{
        .file = file_duped,
        .line = line_no,
        .col = col_no,
        .kind = kind,
        .message = msg_duped,
    };
}

fn parseDiagnostics(stderr: []const u8, allocator: Allocator) ![]Diagnostic {
    var diags: std.ArrayList(Diagnostic) = .empty;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (parseDiagnosticLine(trimmed, allocator)) |d| {
            try diags.append(allocator, d);
        }
    }
    return diags.toOwnedSlice(allocator);
}

/// Finds a declaration by name and kind tag within all scopes.
fn findDecl(decls: []FileAnalysis.Declaration, name: []const u8) ?FileAnalysis.Declaration {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

fn normalizeYamlForParser(allocator: Allocator, source: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, source, " \t\r\n");
    if (std.mem.endsWith(u8, trimmed, ":")) {
        return std.fmt.allocPrint(allocator, "{s} []\n", .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
}

fn enrichFromYaml(analysis: *FileAnalysis, yaml_source: []const u8) !void {
    const allocator = analysis.arena.allocator();
    const normalized = try normalizeYamlForParser(allocator, yaml_source);
    var doc = yaml.Yaml{ .source = normalized };
    defer doc.deinit(allocator);
    try doc.load(allocator);

    const root = doc.docs.items[0].map;
    const shaders = root.get("shaders") orelse return;

    for (shaders.list) |shader| {
        const programs = shader.map.get("programs") orelse continue;
        for (programs.list) |program| {
            if (program.map.get("attrs")) |attrs| {
                for (attrs.list) |attr| {
                    const glsl_name = (attr.map.get("glsl_name") orelse continue).scalar;
                    const slot = std.fmt.parseInt(u32, (attr.map.get("slot") orelse continue).scalar, 10) catch continue;
                    const base_type = try allocator.dupe(u8, (attr.map.get("base_type") orelse continue).scalar);
                    for (analysis.scopes) |*scope| {
                        for (scope.declarations) |*decl| {
                            if (decl.kind != .attr) continue;
                            if (!std.mem.eql(u8, decl.name, glsl_name)) continue;
                            decl.kind.attr.slot = slot;
                            decl.kind.attr.glsl_type.base_type = base_type;
                        }
                    }
                }
            }

            if (program.map.get("uniform_blocks")) |ubs| {
                for (ubs.list) |ub| {
                    const struct_name = (ub.map.get("struct_name") orelse continue).scalar;
                    const slot = std.fmt.parseInt(u32, (ub.map.get("slot") orelse continue).scalar, 10) catch continue;
                    const size = std.fmt.parseInt(u32, (ub.map.get("size") orelse continue).scalar, 10) catch continue;
                    const stage_str = (ub.map.get("stage") orelse continue).scalar;

                    for (analysis.scopes) |*scope| {
                        for (scope.declarations) |*decl| {
                            if (decl.kind != .uniform_block) continue;
                            if (!std.mem.eql(u8, decl.name, struct_name)) continue;
                            decl.kind.uniform_block.slot = slot;
                            decl.kind.uniform_block.size = size;
                            decl.kind.uniform_block.stage = FileAnalysis.ShaderStage.fromStr(stage_str);
                        }
                    }
                }
            }

            if (program.map.get("views")) |views| {
                for (views.list) |view| {
                    const tex = view.map.get("texture") orelse continue;
                    const name = (tex.map.get("name") orelse continue).scalar;
                    const slot = std.fmt.parseInt(u32, (tex.map.get("slot") orelse continue).scalar, 10) catch continue;
                    const stage_str = (tex.map.get("stage") orelse continue).scalar;
                    const multisampled_str = (tex.map.get("multisampled") orelse continue).scalar;
                    const sample_type = try allocator.dupe(u8, (tex.map.get("sample_type") orelse continue).scalar);
                    const multisampled = std.mem.eql(u8, multisampled_str, "true");

                    for (analysis.scopes) |*scope| {
                        for (scope.declarations) |*decl| {
                            if (decl.kind != .texture) continue;
                            if (!std.mem.eql(u8, decl.name, name)) continue;
                            decl.kind.texture.slot = slot;
                            decl.kind.texture.stage = FileAnalysis.ShaderStage.fromStr(stage_str);
                            decl.kind.texture.multisampled = multisampled;
                            decl.kind.texture.sample_type = sample_type;
                        }
                    }
                }
            }

            if (program.map.get("samplers")) |samplers| {
                for (samplers.list) |sampler| {
                    const name = (sampler.map.get("name") orelse continue).scalar;
                    const slot = std.fmt.parseInt(u32, (sampler.map.get("slot") orelse continue).scalar, 10) catch continue;
                    const stage_str = (sampler.map.get("stage") orelse continue).scalar;
                    const sampler_type = try allocator.dupe(u8, (sampler.map.get("sampler_type") orelse continue).scalar);

                    for (analysis.scopes) |*scope| {
                        for (scope.declarations) |*decl| {
                            if (decl.kind != .sampler) continue;
                            if (!std.mem.eql(u8, decl.name, name)) continue;
                            decl.kind.sampler.slot = slot;
                            decl.kind.sampler.stage = FileAnalysis.ShaderStage.fromStr(stage_str);
                            decl.kind.sampler.sampler_type = sampler_type;
                        }
                    }
                }
            }
        }
    }
}

pub fn run(
    io: Io,
    parent_allocator: Allocator,
    glsl_file: []const u8,
    config: Config,
) !FileAnalysis {
    const allocator = parent_allocator;

    const cwd = Io.Dir.cwd();
    const source_tmp = try cwd.readFileAlloc(io, glsl_file, allocator, .limited(1024 * 1024));

    var analysis = try Parser.parse(parent_allocator, glsl_file, source_tmp, config.slang);
    errdefer analysis.deinit();
    const source_owned = try analysis.arena.allocator().dupe(u8, source_tmp);
    allocator.free(source_tmp);
    analysis.source = source_owned;

    const pid = std.os.linux.getpid();
    const yaml_path = try std.fmt.allocPrintSentinel(allocator, "/tmp/sokol_shdc_{}.glsl_reflection.yaml", .{pid}, 0);
    const out_path = try std.fmt.allocPrintSentinel(allocator, "/tmp/sokol_shdc_{}.glsl", .{pid}, 0);

    defer {
        _ = std.os.linux.unlink(yaml_path);
        _ = std.os.linux.unlink(out_path);
        allocator.free(yaml_path);
        allocator.free(out_path);
    }

    const argv: []const []const u8 = &.{
        config.shdc_path,
        "--input",
        glsl_file,
        "--output",
        out_path,
        "--slang",
        config.slang,
        "--format",
        "bare_yaml",
        "--errfmt",
        "gcc",
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .inherit,
    });

    // Read stderr for diagnostics
    var mr: Io.File.MultiReader = undefined;
    var mr_buf: Io.File.MultiReader.Buffer(1) = undefined;
    var stderr_sink = Io.Writer.Allocating.init(allocator);
    defer stderr_sink.deinit();

    if (child.stderr) |stderr_file| {
        Io.File.MultiReader.init(&mr, allocator, io, mr_buf.toStreams(), &.{stderr_file});
        defer mr.deinit();

        while (true) {
            mr.fill(1, .none) catch break;
            const data = mr.reader(0).buffered();
            if (data.len == 0) break;
            stderr_sink.writer.writeAll(data) catch break;
            mr.reader(0).tossBuffered();
        }

        _ = mr.fillRemaining(.none) catch {};
        const remaining = mr.reader(0).buffered();
        if (remaining.len > 0) stderr_sink.writer.writeAll(remaining) catch {};
    }

    const stderr_data = stderr_sink.written();

    const term = try child.wait(io);
    _ = term;

    defer cleanup: {
        var tmp_dir = std.Io.Dir.openDirAbsolute(io, "/tmp", .{ .iterate = true }) catch break :cleanup;
        defer tmp_dir.close(io);
        const prefix = std.fmt.allocPrint(allocator, "sokol_shdc_{}", .{pid}) catch break :cleanup;
        defer allocator.free(prefix);
        var it = tmp_dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, prefix)) {
                const full = std.fmt.allocPrintSentinel(allocator, "/tmp/{s}", .{entry.name}, 0) catch continue;
                defer allocator.free(full);
                _ = std.os.linux.unlink(full);
            }
        }
    }

    const arena_alloc = analysis.arena.allocator();
    const diags = try parseDiagnostics(stderr_data, arena_alloc);
    analysis.diagnostics = diags;

    const yaml_source = cwd.readFileAlloc(io, yaml_path, arena_alloc, .limited(1024 * 1024)) catch null;
    if (yaml_source) |ys| {
        enrichFromYaml(&analysis, ys) catch {};
    }

    return analysis;
}

test "ShdcRunner: valid shader enriches declarations and produces no diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_path = "/tmp/shdc_test.glsl";
    const source =
        \\@vs vs
        \\layout(binding = 0) uniform vs_params {
        \\  mat4 mvp;
        \\};
        \\
        \\in vec3 position;
        \\out vec2 frag_uv;
        \\
        \\void main() {
        \\  gl_Position = mvp * vec4(position, 1.0);
        \\}
        \\@end
        \\
        \\@fs fs
        \\in vec2 frag_uv;
        \\out vec4 frag_color;
        \\
        \\void main() {
        \\  frag_color = vec4(1.0);
        \\}
        \\@end
        \\
        \\@program test vs fs
    ;

    const cwd = Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll(source);
    }
    defer _ = std.os.linux.unlink(tmp_path);

    var analysis = try run(io, allocator, tmp_path, .{});
    defer analysis.deinit();

    // No diagnostics for valid shader
    try std.testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);

    // Two scopes: vs and fs
    try std.testing.expectEqual(@as(usize, 2), analysis.scopes.len);

    const vs = analysis.scopes[0];

    // Find enriched declarations
    const vs_params = findDecl(vs.declarations, "vs_params").?;
    try std.testing.expect(vs_params.kind == .uniform_block);
    // Fill these in after running once:
    try std.testing.expectEqual(@as(?u32, 0), vs_params.kind.uniform_block.slot);
    try std.testing.expectEqual(@as(?u32, 64), vs_params.kind.uniform_block.size);

    const position = findDecl(vs.declarations, "position").?;
    try std.testing.expect(position.kind == .attr);
    try std.testing.expectEqual(@as(?u32, 0), position.kind.attr.slot);
}

test "ShdcRunner: invalid shader produces diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_path = "/tmp/shdc_test_err.glsl";
    const source =
        \\@vs vs
        \\in vec3 position;
        \\void main() {
        \\  gl_Position = notadeclaration * vec4(position, 1.0);
        \\}
        \\@end
        \\
        \\@fs fs
        \\out vec4 frag_color;
        \\void main() { frag_color = vec4(1.0); }
        \\@end
        \\
        \\@program test vs fs
    ;

    const cwd = Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        var w = f.writer(io, &.{});
        try w.interface.writeAll(source);
    }
    defer _ = std.os.linux.unlink(tmp_path);

    var analysis = try run(io, allocator, tmp_path, .{});
    defer analysis.deinit();

    try std.testing.expect(analysis.diagnostics.len > 0);
    try std.testing.expectEqual(FileAnalysis.DiagnosticKind.@"error", analysis.diagnostics[0].kind);
}
