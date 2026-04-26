const std = @import("std");
const common = @import("common.zig");
const json = std.json;

const Allocator = std.mem.Allocator;
const Range = common.Range;
const Position = common.Position;
const TextEdit = common.TextEdit;
const WorkspaceEdit = common.WorkspaceEdit;
const Diagnostic = common.Diagnostic;
const MarkupContent = common.MarkupContent;
const CompletionItem = common.CompletionItem;
const CompletionItemKind = common.CompletionItemKind;

fn Response(Result: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: ?i64 = null,
        result: Result,

        pub fn stringify(self: @This(), allocator: Allocator) error{OutOfMemory}![]const u8 {
            return json.Stringify.valueAlloc(allocator, self, .{});
        }
    };
}

pub const Empty = Response(struct {});

pub const Initialize = Response(struct {
    capabilities: Capabilites = .{},
    definitionProvider: bool = true,
    referencesProvider: bool = true,
    workspaceSymbolProvider: bool = true,
    documentFormattingProvider: bool = true,
    documentRangeFormattingProvider: bool = true,

    pub const Capabilites = struct {
        textDocumentSync: TextDocumentSync = .full,
        hoverProvider: bool = true,
        definitionProvider: bool = true,
        referencesProvider: bool = true,
        workspaceSymbolProvider: bool = true,
        documentFormattingProvider: bool = true,
        documentRangeFormattingProvider: bool = true,
        completionProvider: ?CompletionProvider = null,

        pub const TextDocumentSync = enum(u2) {
            none = 1,
            full,
            incremental,

            pub fn jsonStringify(self: @This(), s: *json.Stringify) !void {
                try s.write(@intFromEnum(self));
            }
        };
    };

    pub const CompletionProvider = struct {
        resolveProvider: bool = true,
        triggerCharacters: []const u8 = ".",
    };
});

pub const Completion = Response(struct {
    isIncomplete: bool = false,
    items: []const CompletionItem = &.{},
});

pub const SemanticTokensFull = Response(struct { items: []const u32 = &.{} });

pub const Rename = Response(WorkspaceEdit);

pub const Hover = Response(struct {
    contents: MarkupContent,
    range: ?Range = null,
});

pub const CodeAction = Response([]const struct {
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
});

pub const Definition = Response([]const Location);
pub const References = Response([]const Location);
pub const Implementation = Response([]const Location);
pub const TypeDefinition = Response([]const Location);

pub const Location = struct {
    uri: []const u8 = "",
    range: Range = .{ .start = .{}, .end = .{} },
};

pub const DocumentSymbol = Response([]const SymbolInformation);
pub const WorkspaceSymbol = Response([]const SymbolInformation);

pub const SymbolInformation = struct {
    name: []const u8 = "",
    kind: CompletionItemKind = .text,
    location: Location = .{},
    containerName: ?[]const u8 = null,
};

pub const DocumentFormatting = Response([]const TextEdit);
pub const DocumentRangeFormatting = Response([]const TextEdit);
pub const DocumentOnTypeFormatting = Response([]const TextEdit);

pub const PublishDiagnostics = Response([]const Diagnostic);
