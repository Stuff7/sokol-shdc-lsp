const std = @import("std");
const response = @import("response.zig");
const common = @import("common.zig");

const Error = common.Error;
const Request = @import("Request.zig");
const Allocator = std.mem.Allocator;

const Support = struct {
    bitset: std.bit_set.IntegerBitSet(@typeInfo(Feature).@"enum".fields.len) = .initEmpty(),

    fn has(self: @This(), feat: Feature) bool {
        return self.bitset.isSet(@intFromEnum(feat));
    }

    fn set(self: *@This(), feat: Feature, enabled: bool) void {
        if (enabled) self.enable(feat) else self.disable(feat);
    }

    fn enable(self: *@This(), feat: Feature) void {
        self.bitset.set(@intFromEnum(feat));
    }

    fn disable(self: *@This(), feat: Feature) void {
        self.bitset.unset(@intFromEnum(feat));
    }

    const Feature = enum {
        markdown,
        snippets,
        hover,
        completion,
        definition,
        references,
        rename_prepare,
        document_formatting,
        range_formatting,
        workspace_apply_edit,
    };
};

support: Support = .{},
workspace: []const u8 = "",

pub fn deinit(self: @This(), allocator: Allocator) void {
    allocator.free(self.workspace);
}

pub fn createInitResponse(self: *@This(), allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .initialize);
    const params = req.params.initialize.value;

    self.workspace = if (params.rootUri) |uri| try allocator.dupe(u8, uri) else "";

    const caps = params.capabilities;

    if (caps.textDocument) |td| {
        if (if (td.hover) |h| h.contentFormat else null) |formats| {
            for (formats) |fmt| {
                if (std.mem.eql(u8, fmt, "markdown")) {
                    self.support.enable(.markdown);
                    break;
                }
            }
        }

        if (td.completion) |comp| {
            self.support.enable(.completion);
            if (if (comp.completionItem) |item| item.snippetSupport else false) |snippet| {
                self.support.set(.snippets, snippet);
            }
        }

        self.support.set(.hover, td.hover != null);
        self.support.set(.definition, td.definition != null);
        self.support.set(.references, td.references != null);

        if (if (td.rename) |rename| rename.prepareSupport else null) |prep| {
            self.support.set(.rename_prepare, prep);
        }

        self.support.set(.document_formatting, td.documentFormatting != null);
        self.support.set(.range_formatting, td.documentFormatting != null);
    }

    if (caps.workspace) |ws| {
        self.support.set(.workspace_apply_edit, ws.applyEdit == true);
    }

    const client_caps = params.capabilities;

    const resp = response.Initialize{
        .id = req.id,
        .result = .{
            .capabilities = .{
                // Always safe: client can't choke on receiving sync kind
                .textDocumentSync = .full,
                // Hover: only advertise if client supports hover
                .hoverProvider = client_caps.textDocument != null and client_caps.textDocument.?.hover != null,
                // Completion: only if client says it can handle it
                .completionProvider = if (client_caps.textDocument != null and client_caps.textDocument.?.completion != null)
                    .{
                        .resolveProvider = true,
                        // Trigger characters are basically universal
                        .triggerCharacters = ".>",
                    }
                else
                    null,
                .definitionProvider = client_caps.textDocument != null and client_caps.textDocument.?.definition != null,
                .referencesProvider = client_caps.textDocument != null and client_caps.textDocument.?.references != null,
                // Symbols in workspace: not tied to textDocument, usually safe
                .workspaceSymbolProvider = true,
                .documentFormattingProvider = client_caps.textDocument != null and client_caps.textDocument.?.documentFormatting != null,
                .documentRangeFormattingProvider = client_caps.textDocument != null and client_caps.textDocument.?.documentFormatting != null,
            },
        },
    };

    return resp.stringify(allocator);
}

pub fn createHoverResponse(self: @This(), allocator: Allocator, req: Request) Error![]const u8 {
    std.debug.assert(req.params == .hover);

    const supports_markdown = self.support.has(.markdown);
    const resp = response.Hover{
        .id = req.id,
        .result = .{
            .contents = .{
                .kind = if (supports_markdown) .markdown else .plaintext,
                .value = if (supports_markdown)
                    "```zig\nfn add(a: i32, b: i32) i32\n```\nAdds two integers together."
                else
                    "fn add(a: i32, b: i32) i32 — Adds two integers together.",
            },
            .range = .{
                .start = .{ .line = 10, .character = 12 },
                .end = .{ .line = 10, .character = 15 },
            },
        },
    };

    return resp.stringify(allocator);
}

pub fn createCompletionResponse(self: @This(), allocator: Allocator, req: Request) Error![]const u8 {
    const supports_snippets = self.support.has(.snippets);
    const resp = response.Completion{
        .id = req.id,
        .result = .{
            .items = &.{
                .{
                    .label = "add",
                    .kind = .function,
                    .detail = "fn add(a: i32, b: i32) i32",
                    .documentation = "Adds two integers together.",
                    .insertText = if (supports_snippets)
                        "add(${1:a}, ${2:b})"
                    else
                        "add(a, b)",
                    .insertTextFormat = if (supports_snippets) .snippet else .text,
                },
                .{
                    .label = "subtract",
                    .kind = .function,
                    .detail = "fn subtract(a: i32, b: i32) i32",
                    .documentation = "Subtracts b from a.",
                    .insertText = if (supports_snippets)
                        "subtract(${1:a}, ${2:b})"
                    else
                        "subtract(a, b)",
                    .insertTextFormat = if (supports_snippets) .snippet else .text,
                },
            },
        },
    };

    return resp.stringify(allocator);
}
