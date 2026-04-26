const std = @import("std");

pub const response = @import("lsp/response.zig");
pub const Request = @import("lsp/Request.zig");
pub const Server = @import("lsp/Server.zig");
pub const Client = @import("lsp/Client.zig");

fn unixFileUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    const abs_path = buf[0..try std.Io.Dir.cwd().realPathFile(path, &buf)];
    return std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
}

test Server {
    const allocator = std.testing.allocator;

    var client = try Client.init(allocator, std.testing.io, &.{"zig-out/bin/sokol-shdc-lsp-dbg"}, ".", 1000);
    defer client.deinit(std.testing.io);

    const workdir_rel = "src/tests/project";

    const workdir = try unixFileUri(allocator, workdir_rel);
    defer allocator.free(workdir);
    const main_zig = try unixFileUri(allocator, workdir_rel ++ "/src/main.zig");
    defer allocator.free(main_zig);

    const messages = .{
        .{
            .request = Request.InitializeParams{
                .processId = 12,
                .rootUri = workdir,
                .capabilities = .{
                    .workspace = .{
                        .applyEdit = true,
                        .workspaceEdit = .{ .documentChanges = true },
                        .workspaceFolders = true,
                        .configuration = true,
                        .didChangeConfiguration = .{ .dynamicRegistration = true },
                    },
                    .textDocument = .{
                        .synchronization = .{
                            .willSave = true,
                            .didSave = true,
                            .willSaveWaitUntil = true,
                        },
                        .completion = .{
                            .dynamicRegistration = true,
                            .completionItem = .{
                                .snippetSupport = true,
                                .resolveSupport = .{
                                    .properties = &[_][]const u8{
                                        "documentation", "detail", "additionalTextEdits",
                                    },
                                },
                            },
                        },
                        .hover = .{ .contentFormat = &[_][]const u8{ "markdown", "plaintext" } },
                        .signatureHelp = .{
                            .signatureInformation = .{
                                .documentationFormat = &[_][]const u8{ "markdown", "plaintext" },
                            },
                        },
                        .references = .{ .dynamicRegistration = true },
                        .definition = .{ .dynamicRegistration = true },
                        .documentFormatting = .{ .dynamicRegistration = true },
                        .rename = .{ .prepareSupport = true },
                        .publishDiagnostics = .{
                            .relatedInformation = true,
                            .tagSupport = .{ .valueSet = &[_]u32{ 1, 2 } }, // Unused/Deprecated
                        },
                    },
                    .window = .{
                        .workDoneProgress = true,
                        .showMessage = .{ .messageActionItem = .{ .additionalPropertiesSupport = true } },
                    },
                    .general = .{
                        .markdown = .{ .parser = "marked", .version = "1.0.0" },
                        .positionEncodings = &[_][]const u8{"utf-16"},
                    },
                },
                .trace = .messages,
                .workspaceFolders = null,
            },
            .response = response.Initialize{
                .id = 1,
                .result = .{
                    .capabilities = .{
                        .textDocumentSync = .full,
                        .hoverProvider = true,
                        .completionProvider = .{ .resolveProvider = true, .triggerCharacters = ".>" },
                        .definitionProvider = true,
                        .referencesProvider = true,
                        .workspaceSymbolProvider = true,
                        .documentFormattingProvider = true,
                        .documentRangeFormattingProvider = true,
                    },
                },
            },
        },

        .{
            .request = Request.DidOpenTextDocumentParams{
                .textDocument = .{
                    .uri = main_zig,
                    .languageId = "zig",
                    .version = 1,
                    .text = "const std = @import(\"std\");\n",
                },
            },
            .response = response.Empty{ .result = .{} },
            .notification = true,
        },

        .{
            .request = Request.DidSaveTextDocumentParams{
                .textDocument = .{ .uri = main_zig },
                .text = null,
            },
            .response = response.Empty{ .result = .{} },
            .notification = true,
        },

        .{
            .request = Request.DidCloseTextDocumentParams{
                .textDocument = .{ .uri = main_zig },
            },
            .response = response.Empty{ .result = .{} },
            .notification = true,
        },

        .{
            .request = Request.HoverParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
            },
            .response = response.Hover{
                .id = 5,
                .result = .{
                    .contents = .{
                        .kind = .markdown,
                        .value = "```zig\nfn add(a: i32, b: i32) i32\n```\nAdds two integers together.",
                    },
                    .range = .{
                        .start = .{ .line = 10, .character = 12 },
                        .end = .{ .line = 10, .character = 15 },
                    },
                },
            },
        },

        .{
            .request = Request.CompletionParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
                .context = .{ .triggerKind = .invoked },
            },
            .response = response.Completion{
                .id = 6,
                .result = .{
                    .items = &.{
                        .{
                            .label = "add",
                            .kind = .function,
                            .detail = "fn add(a: i32, b: i32) i32",
                            .documentation = "Adds two integers together.",
                            .insertText = "add(${1:a}, ${2:b})",
                            .insertTextFormat = .snippet,
                        },
                        .{
                            .label = "subtract",
                            .kind = .function,
                            .detail = "fn subtract(a: i32, b: i32) i32",
                            .documentation = "Subtracts b from a.",
                            .insertText = "subtract(${1:a}, ${2:b})",
                            .insertTextFormat = .snippet,
                        },
                    },
                },
            },
        },

        .{
            .request = Request.DefinitionParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
            },
            .response = response.Definition{
                .id = 7,
                .result = &.{.{
                    .uri = main_zig,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            },
        },

        .{
            .request = Request.ReferenceParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
                .context = .{ .includeDeclaration = true },
            },
            .response = response.References{
                .id = 8,
                .result = &.{.{
                    .uri = main_zig,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            },
        },

        .{
            .request = Request.ImplementationParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
            },
            .response = response.Implementation{
                .id = 9,
                .result = &.{.{
                    .uri = main_zig,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            },
        },

        .{
            .request = Request.TypeDefinitionParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
            },
            .response = response.TypeDefinition{
                .id = 10,
                .result = &.{.{
                    .uri = main_zig,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                }},
            },
        },

        .{
            .request = Request.DocumentSymbolParams{
                .textDocument = .{ .uri = main_zig },
            },
            .response = response.DocumentSymbol{
                .id = 11,
                .result = &.{.{
                    .name = "MySymbol",
                    .kind = .function,
                    .location = .{
                        .uri = main_zig,
                        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                    },
                    .containerName = null,
                }},
            },
        },

        .{
            .request = Request.DocumentRangeFormattingParams{
                .textDocument = .{ .uri = main_zig },
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 5, .character = 0 } },
                .options = .{ .tabSize = 4, .insertSpaces = true },
            },
            .response = response.DocumentRangeFormatting{
                .id = 12,
                .result = &.{.{
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                    .newText = "formatted code",
                }},
            },
        },

        .{
            .request = Request.DocumentOnTypeFormattingParams{
                .textDocument = .{ .uri = main_zig },
                .position = .{ .line = 5, .character = 12 },
                .ch = ';',
                .options = .{ .tabSize = 4, .insertSpaces = true },
            },
            .response = response.DocumentOnTypeFormatting{
                .id = 13,
                .result = &.{.{
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                    .newText = "formatted code",
                }},
            },
        },

        .{
            .request = Request.SemanticTokensFull{
                .textDocument = .{ .uri = main_zig },
            },
            .response = response.SemanticTokensFull{ .id = 14, .result = .{ .items = &.{} } },
        },

        .{
            .request = Request.CodeActionParams{
                .textDocument = .{ .uri = main_zig },
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 5, .character = 0 } },
                .context = .{ .diagnostics = &.{} },
            },
            .response = response.CodeAction{
                .id = 15,
                .result = &.{.{
                    .title = "Mock fix",
                    .kind = null,
                    .diagnostics = &.{},
                    .edit = .{
                        .changes = &.{.{
                            .uri = main_zig,
                            .edits = &.{.{
                                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 5, .character = 0 } },
                                .newText = "fixed code",
                            }},
                        }},
                    },
                    .command = null,
                }},
            },
        },

        .{
            .request = Request.WorkspaceSymbolParams{ .query = "" },
            .response = response.WorkspaceSymbol{
                .id = 16,
                .result = &.{.{
                    .name = "MySymbol",
                    .kind = .function,
                    .location = response.Location{
                        .uri = "file:///foo.zig",
                        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
                    },
                    .containerName = null,
                }},
            },
        },

        .{
            .request = Request.ExecuteCommandParams{ .command = "dummy.command", .arguments = null },
            .response = response.Empty{ .result = .{} },
            .notification = true,
        },

        .{
            .request = Request.ShutdownParams{},
            .response = response.Empty{ .result = .{} },
            .notification = true,
        },

        .{
            .request = Request.ExitParams{},
            .response = response.Empty{ .result = .{} },
            .notification = true,
        },
    };

    inline for (messages, 1..) |msg, i| {
        const is_notification = @hasField(@TypeOf(msg), "notification");
        try client.sendRequest(msg.request, if (!is_notification) i else null);
        if (is_notification) continue;
        const res = try client.waitResponse();
        if (res) |actual| {
            const expected = try msg.response.stringify(allocator);
            defer allocator.free(expected);
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
    }

    try client.drainStderr();
}
