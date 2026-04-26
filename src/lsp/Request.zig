const std = @import("std");
const zut = @import("zut");
const common = @import("common.zig");
const response = @import("response.zig");
const json = std.json;

const Error = common.Error;
const Allocator = std.mem.Allocator;
const Range = common.Range;
const Position = common.Position;
const Diagnostic = common.Diagnostic;
const WorkspaceFolder = common.WorkspaceFolder;

id: ?i64,
params: Params,

pub fn parse(allocator: Allocator, data: []const u8) Error!@This() {
    var jv: json.Parsed(json.Value) = try json.parseFromSlice(json.Value, allocator, data, .{
        .ignore_unknown_fields = true,
        .max_value_len = data.len,
    });
    defer jv.deinit();
    if (jv.value != .object) return error.UnexpectedLspRequest;

    const jsonrpc = jv.value.object.get("jsonrpc") orelse return error.MissingJsonRpcVersion;
    if (!std.mem.eql(u8, jsonrpc.string, "2.0")) return error.UnsupportedJsonRpcVersion;

    return .{
        .id = if (jv.value.object.get("id")) |n| n.integer else null,
        .params = try getParams(allocator, jv.value),
    };
}

pub fn deinit(self: @This()) void {
    self.params.deinit();
}

pub const Header = struct {
    content_length: usize,
    body_start: usize,

    pub fn parse(buf: []const u8) !?@This() {
        const sep = "\r\n\r\n";
        const header_end = std.mem.indexOf(u8, buf, sep) orelse return null;
        const prefix = "Content-Length: ";
        const start = std.mem.indexOf(u8, buf[0..header_end], prefix) orelse return error.InvalidHeader;
        const value = buf[start + prefix.len .. header_end];
        const end = std.mem.indexOf(u8, value, "\r\n") orelse value.len;
        const content_length = std.fmt.parseInt(usize, value[0..end], 10) catch return error.InvalidHeader;
        return .{
            .content_length = content_length,
            .body_start = header_end + sep.len,
        };
    }

    pub fn hasBody(self: @This(), buf: []const u8) bool {
        return buf.len >= self.body_start + self.content_length;
    }

    pub fn body(self: @This(), buf: []const u8) []const u8 {
        return buf[self.body_start .. self.body_start + self.content_length];
    }
};

fn getParams(allocator: Allocator, jv: json.Value) Error!Params {
    var params: Params = undefined;

    const method = if (jv.object.get("method")) |m| m.string else return error.MissingLspRequestMethod;

    inline for (param_types) |f| {
        const ParamsType = @FieldType(@FieldType(Params, f.name), "value");
        if (std.mem.eql(u8, @field(ParamsType, "method"), method)) {
            const params_value = jv.object.get("params") orelse return error.MissingLspRequestParams;
            const parsed = try json.parseFromValue(ParamsType, allocator, params_value, .{ .ignore_unknown_fields = true });
            params = @unionInit(Params, f.name, parsed);
            return params;
        }
    }

    return error.MissingLspRequestParams;
}

pub fn stringify(v: anytype, id: ?i64, writer: *std.Io.Writer) Error!void {
    const T = @TypeOf(v);
    if (id) |actual_id| {
        const req: struct {
            id: i64,
            jsonrpc: []const u8 = "2.0",
            method: []const u8 = T.method,
            params: T,
        } = .{ .id = actual_id, .params = v };
        return json.Stringify.value(req, .{}, writer);
    } else {
        const req: struct {
            jsonrpc: []const u8 = "2.0",
            method: []const u8 = T.method,
            params: T,
        } = .{ .params = v };
        return json.Stringify.value(req, .{}, writer);
    }
}

pub const Params = union(enum) {
    initialize: json.Parsed(InitializeParams),
    completion: json.Parsed(CompletionParams),
    semantic_tokens_full: json.Parsed(SemanticTokensFull),
    hover: json.Parsed(HoverParams),
    will_save: json.Parsed(WillSaveParams),
    formatting: json.Parsed(FormattingParams),
    rename: json.Parsed(RenameParams),

    definition: json.Parsed(DefinitionParams),
    references: json.Parsed(ReferenceParams),
    implementation: json.Parsed(ImplementationParams),
    type_definition: json.Parsed(TypeDefinitionParams),
    document_symbol: json.Parsed(DocumentSymbolParams),
    range_formatting: json.Parsed(DocumentRangeFormattingParams),
    on_type_formatting: json.Parsed(DocumentOnTypeFormattingParams),
    code_action: json.Parsed(CodeActionParams),

    did_open: json.Parsed(DidOpenTextDocumentParams),
    did_save: json.Parsed(DidSaveTextDocumentParams),
    did_close: json.Parsed(DidCloseTextDocumentParams),
    workspace_symbol: json.Parsed(WorkspaceSymbolParams),
    execute_command: json.Parsed(ExecuteCommandParams),
    show_message: json.Parsed(ShowMessageRequestParams),

    shutdown: json.Parsed(ShutdownParams),
    exit: json.Parsed(ExitParams),

    pub fn deinit(self: @This()) void {
        switch (self) {
            inline else => |t| t.deinit(),
        }
    }
};

pub const param_types = @typeInfo(Params).@"union".fields;

pub const TextDocumentIdentifier = struct {
    uri: []const u8 = "",
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i64,
};

pub const ClientCapabilities = struct {
    workspace: ?WorkspaceCapabilities = null,
    textDocument: ?TextDocumentCapabilities = null,
    window: ?WindowCapabilities = null,
    general: ?GeneralCapabilities = null,
    experimental: ?json.Value = null,
};

pub const WindowCapabilities = struct {
    workDoneProgress: ?bool = null,
    showMessage: ?struct {
        messageActionItem: ?struct {
            additionalPropertiesSupport: ?bool = null,
        } = null,
    } = null,
};

pub const GeneralCapabilities = struct {
    markdown: ?struct {
        parser: ?[]const u8 = null,
        version: ?[]const u8 = null,
    } = null,
    positionEncodings: ?[]const []const u8 = null, // usually ["utf-16"]
};

pub const WorkspaceCapabilities = struct {
    applyEdit: ?bool = null,
    workspaceEdit: ?struct {
        documentChanges: ?bool = null,
    } = null,
    workspaceFolders: ?bool = null,
    configuration: ?bool = null,
    didChangeConfiguration: ?struct {
        dynamicRegistration: ?bool = null,
    } = null,
};

pub const TextDocumentCapabilities = struct {
    synchronization: ?struct {
        willSave: ?bool = null,
        didSave: ?bool = null,
        willSaveWaitUntil: ?bool = null,
    } = null,

    completion: ?struct {
        dynamicRegistration: ?bool = null,
        completionItem: ?struct {
            snippetSupport: ?bool = null,
            resolveSupport: ?struct {
                properties: ?[]const []const u8 = null,
            } = null,
        } = null,
    } = null,

    hover: ?struct {
        contentFormat: ?[]const []const u8 = null, // e.g. ["markdown", "plaintext"]
    } = null,

    signatureHelp: ?struct {
        signatureInformation: ?struct {
            documentationFormat: ?[]const []const u8 = null,
        } = null,
    } = null,

    references: ?struct {
        dynamicRegistration: ?bool = null,
    } = null,

    definition: ?struct {
        dynamicRegistration: ?bool = null,
    } = null,

    documentFormatting: ?struct {
        dynamicRegistration: ?bool = null,
    } = null,

    rename: ?struct {
        prepareSupport: ?bool = null,
    } = null,

    publishDiagnostics: ?struct {
        relatedInformation: ?bool = null,
        tagSupport: ?struct {
            valueSet: ?[]const u32 = null,
        } = null,
    } = null,
};

pub const InitializeParams = struct {
    pub const method = "initialize";

    processId: ?u32 = null, // Client PID
    rootUri: ?[]const u8 = null, // Workspace root URI
    initializationOptions: ?json.Value = null,
    capabilities: ClientCapabilities = .{},
    trace: ?Trace = null,
    workspaceFolders: ?[]WorkspaceFolder = null,

    pub const Trace = enum {
        off,
        messages,
        verbose,

        pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
            try s.write(@intFromEnum(self));
        }
    };
};

pub const ImplementationParams = struct {
    pub const method = "textDocument/implementation";

    textDocument: TextDocumentIdentifier = .{},
    position: Position = .{},
};

pub const TypeDefinitionParams = struct {
    pub const method = "textDocument/typeDefinition";

    textDocument: TextDocumentIdentifier = .{},
    position: Position = .{},
};

pub const DocumentSymbolParams = struct {
    pub const method = "textDocument/documentSymbol";

    textDocument: TextDocumentIdentifier = .{},
};

pub const DocumentRangeFormattingParams = struct {
    pub const method = "textDocument/rangeFormatting";

    textDocument: TextDocumentIdentifier = .{},
    range: Range = .{},
    options: struct { tabSize: u64, insertSpaces: bool } = .{ .tabSize = 4, .insertSpaces = true },
};

pub const DocumentOnTypeFormattingParams = struct {
    pub const method = "textDocument/onTypeFormatting";

    textDocument: TextDocumentIdentifier = .{},
    position: Position = .{},
    ch: u8 = 0, // the character typed
    options: struct { tabSize: u64, insertSpaces: bool } = .{ .tabSize = 4, .insertSpaces = true },
};

pub const SemanticTokensFull = struct {
    pub const method = "textDocument/semanticTokens/full";

    textDocument: TextDocumentIdentifier = .{},
};

pub const CompletionParams = struct {
    pub const method = "textDocument/completion";

    context: struct { triggerKind: TriggerKind } = .{ .triggerKind = .invoked },
    textDocument: TextDocumentIdentifier = .{},
    position: Position = .{},

    pub const TriggerKind = enum(u2) {
        invoked = 1,
        character,
        incomplete_completion,

        pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
            try s.write(@intFromEnum(self));
        }
    };
};

pub const HoverParams = struct {
    pub const method = "textDocument/hover";

    textDocument: TextDocumentIdentifier = .{},
    position: Position = .{},
};

pub const WillSaveParams = struct {
    pub const method = "textDocument/willSaveWaitUntil";

    textDocument: TextDocumentIdentifier = .{},
};

pub const FormattingParams = struct {
    pub const method = "textDocument/formatting";

    textDocument: TextDocumentIdentifier = .{},
    options: struct { tabSize: u64, insertSpaces: bool },
};

pub const RenameParams = struct {
    pub const method = "textDocument/rename";

    textDocument: TextDocumentIdentifier = .{},
    position: Position = .{},
    newName: []const u8,
};

pub const ShutdownParams = struct {
    pub const method = "shutdown";
};

pub const ExitParams = struct {
    pub const method = "exit";
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i64,
    text: []const u8,
};

pub const DidOpenTextDocumentParams = struct {
    pub const method = "textDocument/didOpen";

    textDocument: TextDocumentItem,
};

pub const DidSaveTextDocumentParams = struct {
    pub const method = "textDocument/didSave";

    textDocument: TextDocumentIdentifier,
    text: ?[]const u8,
};

pub const DidCloseTextDocumentParams = struct {
    pub const method = "textDocument/didClose";

    textDocument: TextDocumentIdentifier,
};

pub const TextDocumentPositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position = .{},
};

pub const DefinitionParams = struct {
    pub const method = "textDocument/definition";

    textDocument: TextDocumentIdentifier,
    position: Position = .{},
};

pub const ReferenceContext = struct {
    includeDeclaration: bool,
};

pub const ReferenceParams = struct {
    pub const method = "textDocument/references";

    textDocument: TextDocumentIdentifier,
    position: Position = .{},
    context: ReferenceContext,
};

pub const CodeActionContext = struct {
    diagnostics: []const Diagnostic,
    only: ?[][]const u8 = null,
};

pub const CodeActionParams = struct {
    pub const method = "textDocument/codeAction";

    textDocument: TextDocumentIdentifier,
    range: Range,
    context: CodeActionContext,
};

pub const WorkspaceSymbolParams = struct {
    pub const method = "workspace/symbol";

    query: []const u8,
};

pub const ExecuteCommandParams = struct {
    pub const method = "workspace/executeCommand";

    command: []const u8,
    arguments: ?json.Value = null,
};

pub const MessageType = enum {
    @"error",
    warning,
    info,
    log,

    pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
        try s.write(@intFromEnum(self));
    }
};

pub const ShowMessageRequestParams = struct {
    pub const method = "window/showMessageRequest";

    type: MessageType,
    message: []const u8,
};
