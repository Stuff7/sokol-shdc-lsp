const std = @import("std");
const common = @import("common.zig");
const json = std.json;

const Range = common.Range;
const TextEdit = common.TextEdit;
const WorkspaceEdit = common.WorkspaceEdit;
const Diagnostic = common.Diagnostic;
const MarkupContent = common.MarkupContent;
const CompletionItem = common.CompletionItem;
const CompletionItemKind = common.CompletionItemKind;
const Id = common.Id;

pub const NullResult = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: ?json.Value = null,
};

pub const Initialize = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: Result,

    pub const Result = struct {
        capabilities: Capabilities = .{},
    };

    pub const Capabilities = struct {
        textDocumentSync: TextDocumentSync = .full,
        hoverProvider: bool = true,
        definitionProvider: bool = true,
        referencesProvider: bool = true,
        workspaceSymbolProvider: bool = true,
        documentFormattingProvider: bool = true,
        documentRangeFormattingProvider: bool = true,
        completionProvider: ?CompletionProvider = null,
        semanticTokensProvider: ?SemanticTokensProvider = null,
        renameProvider: bool = true,
        signatureHelpProvider: ?SignatureHelpProvider = null,

        pub const SignatureHelpProvider = struct {
            triggerCharacters: []const []const u8 = &.{ "(", "," },
        };

        pub const SemanticTokensProvider = struct {
            legend: Legend,
            full: bool = true,

            pub const Legend = struct {
                tokenTypes: []const []const u8,
                tokenModifiers: []const []const u8 = &.{},
            };
        };

        pub const TextDocumentSync = enum(u2) {
            none,
            full,
            incremental,

            pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
                try s.write(@intFromEnum(self));
            }
        };

        pub const CompletionProvider = struct {
            resolveProvider: bool = true,
            triggerCharacters: []const []const u8 = &.{"."},
        };
    };
};

pub const CompletionResolve = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: common.CompletionItem,
};

pub const DiagnosticsNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/publishDiagnostics",
    params: struct {
        uri: []const u8,
        diagnostics: []const common.Diagnostic,
    },
};

pub const SignatureHelp = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: ?Result,

    pub const Result = struct {
        signatures: []const SignatureInformation,
        activeSignature: u32 = 0,
        activeParameter: u32 = 0,
    };

    pub const SignatureInformation = struct {
        label: []const u8,
        documentation: ?[]const u8 = null,
        parameters: []const ParameterInformation,
    };

    pub const ParameterInformation = struct {
        label: []const u8,
        documentation: ?[]const u8 = null,
    };
};

pub const Completion = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: Result,

    pub const Result = struct {
        isIncomplete: bool = false,
        items: []const CompletionItem = &.{},
    };
};

pub const SemanticTokensFull = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: Result,

    pub const Result = struct {
        resultId: ?[]const u8 = null,
        data: []const u32 = &.{},
    };
};

pub const SemanticTokensRefresh = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "workspace/semanticTokens/refresh",
};

pub const Hover = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: Result,

    pub const Result = struct {
        contents: MarkupContent,
        range: ?Range = null,
    };
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const Definition = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const Location,
};

pub const References = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const Location,
};

pub const Implementation = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const Location,
};

pub const TypeDefinition = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const Location,
};

pub const Rename = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: WorkspaceEdit,
};

pub const CodeAction = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const Action,

    pub const Action = struct {
        title: []const u8,
        kind: ?[]const u8 = null,
        diagnostics: ?[]const Diagnostic = null,
        edit: ?WorkspaceEdit = null,
        command: ?Command = null,

        pub const Command = struct {
            title: []const u8,
            command: []const u8,
            arguments: ?[]json.Value = null,
        };
    };
};

pub const SymbolInformation = struct {
    name: []const u8,
    kind: CompletionItemKind,
    location: Location,
    containerName: ?[]const u8 = null,
};

pub const DocumentSymbol = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const SymbolInformation,
};

pub const WorkspaceSymbol = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const SymbolInformation,
};

pub const DocumentFormatting = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const TextEdit,
};

pub const DocumentRangeFormatting = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const TextEdit,
};

pub const DocumentOnTypeFormatting = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?Id,
    result: []const TextEdit,
};

pub const PublishDiagnostics = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/publishDiagnostics",
    params: Params,

    pub const Params = struct {
        uri: []const u8,
        version: ?i64 = null,
        diagnostics: []const Diagnostic = &.{},
    };
};
