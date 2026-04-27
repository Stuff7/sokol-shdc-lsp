const std = @import("std");

arena: std.heap.ArenaAllocator,
file: []const u8,
source: []const u8,
diagnostics: []Diagnostic,
scopes: []Scope,
// @header, @ctype, @module, @program, @include at top level
top_level: []Declaration,

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    self.* = undefined;
}

pub const Location = struct {
    line: u32,
    col: u32,
};

pub const Range = struct {
    file: []const u8,
    start: Location,
    end: Location,
};

pub const DiagnosticKind = enum {
    @"error",
    warning,
    note,
};

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    kind: DiagnosticKind,
    message: []const u8,
};

pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
    unknown,

    pub fn fromStr(s: []const u8) ShaderStage {
        if (std.mem.eql(u8, s, "vertex")) return .vertex;
        if (std.mem.eql(u8, s, "fragment")) return .fragment;
        if (std.mem.eql(u8, s, "compute")) return .compute;
        return .unknown;
    }
};

pub const GlslType = struct {
    name: []const u8,
    // YAML-derived e.g. "Float", "UInt" — null if not available
    base_type: ?[]const u8 = null,
};

pub const Attr = struct {
    // YAML-derived — null if not available
    slot: ?u32 = null,
    glsl_type: GlslType,
    is_input: bool,
};

pub const UniformMember = struct {
    glsl_type: GlslType,
    // YAML-derived
    array_count: ?u32 = null,
    offset: ?u32 = null,
};

pub const UniformBlock = struct {
    slot: ?u32 = null,
    stage: ShaderStage,
    // YAML-derived
    size: ?u32 = null,
};

pub const Texture = struct {
    slot: ?u32 = null,
    stage: ShaderStage,
    glsl_type: GlslType,
    // YAML-derived
    multisampled: ?bool = null,
    sample_type: ?[]const u8 = null,
    // from @image_sample_type annotation
    image_sample_type: ?[]const u8 = null,
};

pub const Sampler = struct {
    slot: ?u32 = null,
    stage: ShaderStage,
    // YAML-derived
    sampler_type: ?[]const u8 = null,
    // from @sampler_type annotation
    sampler_type_hint: ?[]const u8 = null,
};

pub const StorageBuffer = struct {
    slot: ?u32 = null,
    stage: ShaderStage,
    readonly: bool,
    struct_name: []const u8,
};

pub const StorageImage = struct {
    slot: ?u32 = null,
    stage: ShaderStage,
    // e.g. "rgba8"
    format: ?[]const u8 = null,
    // e.g. "writeonly", "readwrite"
    access: []const u8,
    glsl_type: GlslType,
};

pub const FunctionParam = struct {
    name: []const u8,
    glsl_type: GlslType,
    range: Range,
};

pub const Function = struct {
    return_type: GlslType,
    params: []FunctionParam,
};

pub const StructMember = struct {
    name: []const u8,
    glsl_type: GlslType,
    range: Range,
};

pub const Struct = struct {
    members: []StructMember,
};

pub const Header = struct {
    // raw content after @header e.g. `#include "path/to/header.h"`
    content: []const u8,
    // resolved path if detectable, language-agnostic
    target_file: ?[]const u8 = null,
};

pub const CType = struct {
    // e.g. @ctype mat4 m.Mat4 -> glsl_type="mat4", target_type="m.Mat4"
    glsl_type: []const u8,
    target_type: []const u8,
    // resolved path if detectable, language-agnostic
    target_file: ?[]const u8 = null,
};

pub const Program = struct {
    vs_name: []const u8,
    // null for compute-only programs
    fs_name: ?[]const u8 = null,
    // non-null for compute-only programs
    cs_name: ?[]const u8 = null,
};

pub const Include = struct {
    // path as written in @include
    path: []const u8,
    // resolved absolute path if detectable
    resolved_path: ?[]const u8 = null,
};

pub const IncludeBlock = struct {
    block_name: []const u8,
    // resolved declaration of the @block, null if unresolved
    decl: ?*const Declaration = null,
};

pub const ShaderOptions = struct {
    // raw option strings e.g. "flip_vert_y", "fixup_clipspace"
    options: [][]const u8,
};

pub const DeclKind = union(enum) {
    vs_block: void,
    fs_block: void,
    cs_block: void,
    named_block: void,
    program: Program,
    module: void,
    attr: Attr,
    uniform_block: UniformBlock,
    uniform_member: UniformMember,
    texture: Texture,
    sampler: Sampler,
    storage_buffer: StorageBuffer,
    storage_image: StorageImage,
    function: Function,
    local_var: GlslType,
    @"struct": Struct,
    header: Header,
    ctype: CType,
    include: Include,
    include_block: IncludeBlock,
    glsl_options: ShaderOptions,
    hlsl_options: ShaderOptions,
    msl_options: ShaderOptions,
    image_sample_type: void,
    sampler_type: void,
};

pub const Declaration = struct {
    name: []const u8,
    range: Range,
    kind: DeclKind,
};

pub const Reference = struct {
    name: []const u8,
    range: Range,
    // null if unresolved
    decl: ?*const Declaration = null,
};

pub const ScopeKind = enum {
    vs,
    fs,
    cs,
    block,
};

pub const Scope = struct {
    name: []const u8,
    kind: ScopeKind,
    range: Range,
    declarations: []Declaration,
    references: []Reference,
};
