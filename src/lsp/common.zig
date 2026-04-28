const std = @import("std");
const json = std.json;

pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
        switch (self) {
            .integer => |v| try s.write(v),
            .string => |v| try s.write(v),
        }
    }
};

pub const Error = error{
    UnexpectedLspRequest,
    MissingJsonRpcVersion,
    UnsupportedJsonRpcVersion,
    MissingLspRequestMethod,
    MissingLspRequestParams,
    MethodNotFound,

    // Errors from json.parseFromSlice, need to be explicit for zls to see it
    BufferUnderrun,
    DuplicateField,
    InvalidCharacter,
    InvalidEnumTag,
    InvalidNumber,
    LengthMismatch,
    MissingField,
    OutOfMemory,
    Overflow,
    SyntaxError,
    UnexpectedEndOfInput,
    UnexpectedToken,
    UnknownField,
    ValueTooLong,
    WriteFailed,
};

pub const Position = struct {
    line: u64 = 0,
    character: u64 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

pub const Severity = enum(u3) {
    @"error" = 1,
    warning,
    information,
    hint,

    pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
        try s.write(@intFromEnum(self));
    }
};

pub const Diagnostic = struct {
    range: Range = .{ .start = .{}, .end = .{} },
    severity: Severity = .@"error",
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8 = "",
};

pub const WorkspaceEditChange = struct {
    uri: []const u8,
    edits: []const TextEdit,
};

pub const WorkspaceEdit = struct {
    changes: ?[]const WorkspaceEditChange = null,
};

pub const WorkspaceFolder = struct {
    uri: []const u8,
    name: []const u8,
};

pub const MarkupKind = enum {
    plaintext,
    markdown,
};

pub const MarkupContent = struct {
    kind: MarkupKind,
    value: []const u8,
};

pub const InsertTextFormat = enum(u2) {
    text = 1,
    snippet,

    pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
        try s.write(@intFromEnum(self));
    }
};

pub const CompletionItem = struct {
    label: []const u8 = "",
    kind: CompletionItemKind = .text,
    detail: []const u8 = "",
    documentation: []const u8 = "",
    insertText: []const u8 = "",
    insertTextFormat: InsertTextFormat = .text,
};

pub const CompletionItemKind = enum(u5) {
    text = 1,
    method,
    function,
    constructor,
    field,
    variable,
    class,
    interface,
    module,
    property,
    unit,
    value,
    @"enum",
    keyword,
    snippet,
    color,
    file,
    reference,
    folder,
    enum_member,
    constant,
    @"struct",
    event,
    operator,
    type_parameter,
    macro,

    pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
        try s.write(@intFromEnum(self));
    }
};
