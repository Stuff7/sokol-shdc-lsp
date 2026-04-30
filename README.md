# sokol-shdc-lsp

A language server for [sokol-shdc](https://github.com/floooh/sokol-tools) GLSL shader files — the annotated `.glsl` format used by sokol-tools with `@vs`, `@fs`, `@program` blocks and sokol-specific attributes.

## Requirements

- [sokol-shdc](https://github.com/floooh/sokol-tools) in your `PATH`
- Zig nightly master (>= 0.16.0)

## Building

```sh
zig build -Doptimize=ReleaseFast
```

The binary will be at `zig-out/bin/sokol-shdc-lsp`.

## Neovim Setup

```lua
vim.lsp.start({
  name = "sokol_shdc_lsp",
  cmd = { "/path/to/sokol-shdc-lsp", "/path/to/lsp.log" },
  root_dir = vim.fn.getcwd(),
  filetypes = { "glsl" },
})
```

## Features

- **Hover** — type and documentation for GLSL builtins, user-defined functions, uniforms, attributes, and struct members
- **Completion** — all in-scope declarations, GLSL builtin functions, and builtin types with signatures and documentation
- **Signature help** — active parameter highlighting as you type function calls
- **Go to definition** — jump to any declaration in the shader file
- **Find references** — all usages of a symbol
- **Rename** — rename any user-defined symbol across the file
- **Document symbols** — outline of all declarations
- **Semantic tokens** — token types for variables, parameters, functions, uniforms, attributes, structs, and keywords
- **Diagnostics** — errors and warnings from sokol-shdc on save and open

## Limitations

- Linux only
- Single-file only — cross-file references are not supported
- Diagnostic column numbers are always 0 (limitation of sokol-shdc's output format)
- `sampler2D` and other type constructors have no signature help (not in the GLSL spec)
- User-defined function documentation requires doc comments in source — not yet parsed
- `@vs`, `@fs`, `@program` blocks are not yet highlighted as semantic tokens
- No support for `completionItem/resolve` lazy documentation — all docs are populated upfront

## In Progress

- Doc comment parsing for user-defined functions
- `@vs`/`@fs`/`@program` keyword semantic highlighting
