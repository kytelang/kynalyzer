# kynalyzer

The language server for [Kyte](https://github.com/kytelang): a single Zig binary that speaks the Language
Server Protocol over stdio and reuses the real Kyte compiler frontend (lexer, parser, formatter, type
checker), so its analysis never drifts from the compiler. The reference client is the
[kyte-vscode-extension](https://github.com/kytelang/kyte-vscode-extension); the server works with any
LSP-capable editor.

This is version 1.0.0. The extension pairs with this version, and the two move together.

## Features

The server reuses the compiler frontend and runs the real type checker with a project import-closure loader,
so diagnostics and navigation match what `kyte build` sees.

- **Diagnostics** from the actual type checker, resolving the project import closure, with conservative
  cross-module suppression so an unresolved import never cries wolf.
- **Completion** for members, identifiers and keywords, with **signature help** and a lazy
  `completionItem/resolve`.
- **Hover** with documentation comments.
- **Navigation**: go to definition, go to type definition, and go to implementation (list the types that
  implement a trait).
- **Project-wide, binding-accurate references and rename.** Edits span every file in the import closure, not
  just open buffers, and they are type-aware: a receiver-resolution pass means renaming a method never
  touches a same-named method on an unrelated type, and renaming a global never clobbers a shadowing local.
- **Document and workspace symbols.**
- **Document highlight**, **folding ranges**, and **selection ranges** (smart expand selection).
- **Semantic tokens**, whole-document and by range, with a `declaration` modifier so a definition reads
  differently from a use.
- **Inlay hints**: the inferred type of an annotation-free `let`, and parameter names before call arguments
  (the callee is resolved through the same receiver-resolution pass).
- **Formatting** that mirrors `kyte fmt` behind a token-stream safety gate, so a reformat can never alter the
  program's meaning.
- **Code actions**: quick fixes driven by the checker's diagnostics.

All of the above is advertised in the `initialize` response and covered by unit tests in `src/`.

## Releases

Prebuilt binaries for macOS, Linux and Windows (x86_64 and aarch64) are attached to each tagged release on
the [releases page](https://github.com/kytelang/kynalyzer/releases). Download the archive for your platform,
verify it against the release's `SHA256SUMS.txt`, extract it, and place `kynalyzer` on your `PATH` or at
`~/.kyte/bin/kynalyzer` (where the VS Code extension looks by default). If you would rather build from
source, see below.

## Building

kynalyzer is pure Zig with no external libraries, so it builds and cross-compiles from any host with the Zig
toolchain alone.

Requirements:

- **Zig 0.16.0**.
- The **Kyte compiler** checked out as a sibling directory (`../kyte`), since the server imports its frontend
  as a module. If your checkout lives elsewhere, point at it: `zig build -Dkyte-src=../lang/src/root.zig`.

```sh
zig build
```

This produces `zig-out/bin/kynalyzer` and also installs it to `~/.kyte/bin/kynalyzer`, which is where the VS
Code extension looks by default.

### Tests and the gate

```sh
zig build test        # unit tests in src/
./gate.sh             # build + tests + a 6-target cross-compile smoke; exits non-zero on any failure
```

`zig build cross` alone stamps out a binary per supported target under `zig-out/cross/<triple>/` (macOS,
Linux, and Windows for x86_64 and aarch64).

## Using it from an editor

Any LSP client can launch `kynalyzer` over stdio. In VS Code, install the
[kyte-vscode-extension](https://github.com/kytelang/kyte-vscode-extension); it discovers the server via the
`kyte.server.path` setting, then `PATH`, then `~/.kyte/bin/kynalyzer`.

## Licence

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
