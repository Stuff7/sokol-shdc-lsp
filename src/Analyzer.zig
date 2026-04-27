const std = @import("std");
const zig = std.zig;

const Allocator = std.mem.Allocator;
const Ast = zig.Ast;
const Node = Ast.Node;

ast: *Ast,

pub fn init(allocator: Allocator, source: [:0]const u8) !@This() {
    const ast = try allocator.create(Ast);
    ast.* = try Ast.parse(allocator, source, .zig);
    return .{ .ast = ast };
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.ast.deinit(allocator);
    allocator.destroy(self.ast);
}

pub fn getTag(self: @This(), idx: u32) zig.Token.Tag {
    return self.ast.tokens.items(.tag)[idx];
}

pub fn tokenSlice(self: @This(), idx: u32) []const u8 {
    return self.ast.tokenSlice(idx);
}

pub fn findNodeAtOffset(self: @This(), offset: usize) ?NodeInfo {
    return if (self.findTokenAtOffset(offset)) |token_idx| self.findNodeAtToken(token_idx) else null;
}

pub fn findNodeAtToken(self: @This(), token_idx: Ast.TokenIndex) ?NodeInfo {
    var smallest_node: ?Node.Index = null;
    var smallest_span: u32 = std.math.maxInt(u32);

    const node_tags = self.ast.nodes.items(.tag);
    for (node_tags, 0..) |_, i| {
        const node_idx: Node.Index = @enumFromInt(i);

        const first_token = self.ast.firstToken(node_idx);
        const last_token = self.ast.lastToken(node_idx);

        if (token_idx >= first_token and token_idx <= last_token) {
            const span = last_token - first_token;
            if (span < smallest_span) {
                smallest_span = span;
                smallest_node = node_idx;
            }
        }
    }

    return if (smallest_node) |n| .init(self.ast, n) else null;
}

pub fn findTokenAtOffset(self: @This(), offset: u32) ?Ast.TokenIndex {
    const starts = self.ast.tokens.items(.start);
    for (starts, 0..) |start, i| {
        const end = if (i + 1 < starts.len)
            starts[i + 1]
        else
            @as(u32, @intCast(self.ast.source.len));

        if (offset >= start and offset < end) {
            return @as(Ast.TokenIndex, @intCast(i));
        }
    }
    return null;
}

pub const NodeInfo = struct {
    ast: *const Ast,
    index: Node.Index,
    tag: Node.Tag,
    data: NodeData,

    pub fn init(ast: *const Ast, node: Node.Index) NodeInfo {
        const node_idx = @intFromEnum(node);
        const node_tags = ast.nodes.items(.tag);
        const node_data = ast.nodes.items(.data);

        return .{
            .ast = ast,
            .index = node,
            .tag = node_tags[node_idx],
            .data = .fromUntaggedData(node_tags[node_idx], node_data[node_idx]),
        };
    }

    pub fn getName(self: @This()) ?[]const u8 {
        const node_idx = @intFromEnum(self.index);
        const node_tags = self.ast.nodes.items(.tag);
        const token_tags = self.ast.tokens.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);
        const tag = node_tags[node_idx];
        const main_token = main_tokens[node_idx];

        return switch (tag) {
            .fn_decl => blk: {
                var buf: [1]Node.Index = undefined;
                const fn_proto = self.ast.fullFnProto(&buf, self.index) orelse break :blk null;
                if (fn_proto.name_token) |name_token| {
                    break :blk self.ast.tokenSlice(name_token);
                }
                break :blk null;
            },
            .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => blk: {
                var buf: [1]Node.Index = undefined;
                const fn_proto = self.ast.fullFnProto(&buf, self.index) orelse break :blk null;
                if (fn_proto.name_token) |name_token| {
                    break :blk self.ast.tokenSlice(name_token);
                }
                break :blk null;
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
                const var_decl = self.ast.fullVarDecl(self.index) orelse break :blk null;
                const name_token = var_decl.ast.mut_token + 1;
                if (name_token < self.ast.tokens.len and
                    token_tags[name_token] == .identifier)
                {
                    break :blk self.ast.tokenSlice(name_token);
                }
                break :blk null;
            },
            .identifier => self.ast.tokenSlice(main_token),
            .field_access => blk: {
                // For field access (e.g., foo.bar), the field name is after the period
                const field_token = main_token + 1;
                if (field_token < self.ast.tokens.len and
                    token_tags[field_token] == .identifier)
                {
                    break :blk self.ast.tokenSlice(field_token);
                }
                break :blk null;
            },
            .container_field, .container_field_init, .container_field_align => blk: {
                if (token_tags[main_token] == .identifier) {
                    break :blk self.ast.tokenSlice(main_token);
                }
                break :blk null;
            },
            else => null,
        };
    }

    pub fn getSource(self: @This()) []const u8 {
        const first_token = self.ast.firstToken(self.index);
        const last_token = self.ast.lastToken(self.index);
        const start_offset = self.ast.tokens.items(.start)[first_token];

        const end_offset = if (last_token + 1 < self.ast.tokens.len)
            self.ast.tokens.items(.start)[last_token + 1]
        else
            @as(u32, @intCast(self.ast.source.len));

        return self.ast.source[start_offset..end_offset];
    }

    // pub fn getDocs(self: @This()) ?[]const u8 {
    //     const node_idx = @intFromEnum(self.index);
    //     const first_token = self.ast.firstToken(node_idx);
    //     if (first_token == 0) return null;
    //
    //     const token_tags = self.ast.tokens.items(.tag);
    //
    //     // Look backwards for doc comments
    //     var start_doc_token: ?Ast.TokenIndex = null;
    //     var i = first_token;
    //
    //     while (i > 0) {
    //         i -= 1;
    //         const tag = token_tags[i];
    //
    //         if (tag == .doc_comment or tag == .container_doc_comment) {
    //             start_doc_token = i;
    //         } else if (tag != .doc_comment and tag != .container_doc_comment) {
    //             // Stop when we hit a non-doc-comment token
    //             break;
    //         }
    //     }
    //
    //     if (start_doc_token == null) return null;
    //
    //     // Return the full doc comment range
    //     const start_offset = self.ast.tokens.items(.start)[start_doc_token.?];
    //     const end_offset = self.ast.tokens.items(.start)[first_token];
    //
    //     return self.ast.source[start_offset..end_offset];
    // }
    //
    // /// Caller owns the returned memory
    // pub fn getSignature(self: @This(), allocator: Allocator) ?[]const u8 {
    //     var buf: [1]Node.Index = undefined;
    //     const full = self.ast.fullFnProto(&buf, self.index) orelse return null;
    //
    //     var signature = std.ArrayList(u8).empty;
    //     errdefer signature.deinit();
    //
    //     const writer = signature.writer();
    //
    //     // Write "fn name"
    //     writer.writeAll("fn ") catch return null;
    //     if (full.name_token) |name_token| {
    //         writer.writeAll(self.ast.tokenSlice(name_token)) catch return null;
    //     }
    //
    //     // Write parameters
    //     writer.writeAll("(") catch return null;
    //     var it = full.iterate(&self.ast);
    //     var first = true;
    //     while (it.next()) |param| {
    //         if (!first) {
    //             writer.writeAll(", ") catch return null;
    //         }
    //         first = false;
    //
    //         if (param.name_token) |nt| {
    //             writer.writeAll(self.ast.tokenSlice(nt)) catch return null;
    //             writer.writeAll(": ") catch return null;
    //         }
    //
    //         const param_type_source = getSource(self.ast, param.type_expr);
    //         writer.writeAll(param_type_source) catch return null;
    //     }
    //     writer.writeAll(") ") catch return null;
    //
    //     // Write return type
    //     const return_type_source = getSource(self.ast, full.self.ast.return_type);
    //     writer.writeAll(return_type_source) catch return null;
    //
    //     return signature.toOwnedSlice() catch return null;
    // }
};

pub const NodeData = union(enum) {
    const Tag = Node.Tag;
    const Index = Node.Index;
    const OptionalIndex = Node.OptionalIndex;
    const ExtraIndex = Ast.ExtraIndex;
    const OptionalTokenIndex = Ast.OptionalTokenIndex;
    const For = Node.For;
    const SubRange = Node.SubRange;
    const TokenIndex = Ast.TokenIndex;

    node: Index,
    opt_node: OptionalIndex,
    token: TokenIndex,
    node_and_node: struct { Index, Index },
    opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
    node_and_opt_node: struct { Index, OptionalIndex },
    opt_node_and_node: struct { OptionalIndex, Index },
    node_and_extra: struct { Index, ExtraIndex },
    extra_and_node: struct { ExtraIndex, Index },
    extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
    node_and_token: struct { Index, TokenIndex },
    token_and_node: struct { TokenIndex, Index },
    token_and_token: struct { TokenIndex, TokenIndex },
    opt_node_and_token: struct { OptionalIndex, TokenIndex },
    opt_token_and_node: struct { OptionalTokenIndex, Index },
    opt_token_and_opt_node: struct { OptionalTokenIndex, OptionalIndex },
    opt_token_and_opt_token: struct { OptionalTokenIndex, OptionalTokenIndex },
    @"for": struct { ExtraIndex, For },
    extra_range: SubRange,

    pub fn fromUntaggedData(tag: Tag, data: Node.Data) @This() {
        return switch (tag) {
            .root => .{ .extra_range = data.extra_range },
            .aligned_var_decl => .{ .node_and_opt_node = data.node_and_opt_node },
            .global_var_decl, .local_var_decl => .{ .extra_and_opt_node = data.extra_and_opt_node },
            .simple_var_decl => .{ .opt_node_and_opt_node = data.opt_node_and_opt_node },
            .@"errdefer" => .{ .opt_token_and_node = data.opt_token_and_node },
            .field_access, .unwrap_optional => .{ .node_and_token = data.node_and_token },
            .assign_destructure, .array_init, .call => .{ .extra_and_node = data.extra_and_node },
            .call_one, .call_one_comma => .{ .node_and_opt_node = data.node_and_opt_node },
            .switch_case_one, .switch_case_inline_one => .{ .opt_node_and_node = data.opt_node_and_node },
            .for_simple, .@"for" => .{ .@"for" = data.@"for" },
            .container_field_align, .container_field_init => .{ .node_and_node = data.node_and_node },
            .container_field => .{ .node_and_extra = data.node_and_extra },
            .ptr_type, .ptr_type_bit_range => .{ .extra_and_node = data.extra_and_node },
            .ptr_type_aligned, .ptr_type_sentinel => .{ .opt_node_and_node = data.opt_node_and_node },
            .@"return" => .{ .opt_node = data.opt_node },
            .@"defer" => .{ .node = data.node },
            .@"suspend" => .{ .node = data.node },
            .@"resume" => .{ .node = data.node },
            .@"continue", .@"break" => .{ .opt_token_and_opt_node = data.opt_token_and_opt_node },
            .@"comptime", .@"nosuspend" => .{ .node = data.node },
            else => {
                std.log.err("Unhandled NodeData tag: {any}", .{tag});
                unreachable;
            },
        };
    }
};
