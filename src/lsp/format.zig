const std = @import("std");
const common = @import("common.zig");

const FileAnalysis = @import("../parser/FileAnalysis.zig");
const Allocator = std.mem.Allocator;
const CompletionItemKind = common.CompletionItemKind;

pub fn declToMarkdown(allocator: Allocator, name: []const u8, decl: FileAnalysis.Declaration) ![]const u8 {
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

pub fn declToPlaintext(allocator: Allocator, name: []const u8, decl: FileAnalysis.Declaration) ![]const u8 {
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

pub fn declKindLabel(kind: FileAnalysis.DeclKind) []const u8 {
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

pub fn declToSymbolKind(kind: FileAnalysis.DeclKind) CompletionItemKind {
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

pub fn declDetail(allocator: Allocator, decl: FileAnalysis.Declaration) ![]const u8 {
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

pub fn functionSnippet(allocator: Allocator, name: []const u8, f: FileAnalysis.Function) ![]const u8 {
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
