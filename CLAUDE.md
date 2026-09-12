# CLAUDE.md - kynalyzer (Kyte language server)

## What this is

kynalyzer is the Language Server Protocol (LSP) implementation for Kyte: a single pure-Zig binary that
speaks LSP over stdio and reuses the real Kyte compiler frontend (lexer, parser, formatter, type checker),
so its analysis never drifts from `kyte build`. It is version 1.0.0 and pairs with the matching
kyte-vscode-extension. See [README.md](README.md) for the feature list and editor setup.

This repo is the server only. The language it analyses (the compiler, runtime and standard library) lives
in the sibling **kyte** repo; kynalyzer imports kyte's frontend as a module and never vendors a copy.

## Build

Prerequisites: Zig 0.16.0, and the **kyte** compiler checked out as a sibling at `../kyte` (the server
compiles kyte's `src/root.zig` as the `compiler` module). A different layout overrides the path, for
example `zig build -Dkyte-src=../lang/src/root.zig`.

```bash
zig build            # builds zig-out/bin/kynalyzer AND installs it to ~/.kyte/bin/kynalyzer
```

kynalyzer deliberately does NOT link LLVM. It only touches the compiler's parser, formatter, AST, lexer and
the sema modules they re-export, none of which import `llvm` (only codegen does, and codegen is unreachable
from the LSP). That is what keeps it a pure-Zig binary that cross-compiles to every supported OS/arch with
the Zig toolchain alone. The host build defaults to the baseline CPU (armv8-a / x86-64-v1) on purpose, so a
shipped binary never dies with SIGILL on an older CPU.

The VS Code extension launches `~/.kyte/bin/kynalyzer`, not `zig-out/bin/kynalyzer`, so the default build's
install-to-`~/.kyte/bin` step is what actually makes an edit take effect in the editor.

## Tests and the gate

```bash
zig build test       # unit tests in src/ (the authoritative check for behaviour)
zig build cross      # stamp out one binary per target under zig-out/cross/<triple>/
./gate.sh            # build (host) + zig build test + 6-target cross-compile smoke; non-zero on any failure
```

`gate.sh` honours a `KYTE_SRC` env var (turned into `-Dkyte-src=...`) for a non-sibling compiler checkout.

### Version sync (do not let it drift)

There is a single source of truth: build.zig reads `.version` from [build.zig.zon](build.zig.zon) and
injects it as the `build_options` module, so `server_version` in `src/server.zig` (reported in the
`initialize` response's `serverInfo`) can never diverge from the packaging version by construction. A
`zig build test` case (`src/server.zig`, "server version is injected from build.zig.zon") asserts this. At a
release, the **kyte-vscode-extension** `package.json` version must be bumped to match: the extension and the
server move together.

## Working in this repo (how to make a change)

1. **Understand, then plan.** Read `src/server.zig` (the `Handler` struct and the relevant
   `pub fn "textDocument/..."` method) and the analysis module it calls, plus the nearby unit tests, before
   editing. Keep the change minimal and match the surrounding Zig style; do not reformat unrelated code.
2. **Verify real behaviour, not just compilation.** Build, let it install to `~/.kyte/bin/kynalyzer`, then
   exercise the actual LSP path from an editor (or a crafted request) and confirm the response. "It
   compiles" is not done.
3. **Run the gate before and after.** At minimum `zig build test`; run `./gate.sh` (which adds the
   cross-compile smoke) before you consider a change finished. Add a unit test for every behaviour change.
4. **Match the capability contract.** Every capability advertised in the `initialize` response needs a
   matching handler (see the gotcha below); keep the advertised set and the implemented `Handler` methods in
   step.
5. **Keep versions aligned.** If you touch the version, bump build.zig.zon and the kyte-vscode-extension in
   the same breath, and let `zig build test` confirm it.
6. **Commit only when asked**; if you are on `main`, branch first. The compiler frontend belongs to the
   sibling **kyte** repo, not here: a fix that really lives in the frontend should be made there.

## Layout map

- `src/main.zig` - entry point; sets up the stdio transport and runs `lsp.basic_server` against `Handler`.
- `src/server.zig` - the bulk of the server: the `Handler` struct with the `pub fn "textDocument/..."` LSP
  methods, the advertised `server_capabilities`, and the unit tests.
- `src/analysis.zig`, `src/resolve.zig` - the analysis and receiver/binding resolution that back
  navigation, references, rename and inlay hints; they sit alongside `server.zig`.
- `src/root.zig` - the library module root that wires `compiler`, `lsp` and `build_options` together.
- `lib/lsp-kit-0.16.0/` - the vendored LSP toolkit (the `lsp` dependency, wired in build.zig.zon).
- `build.zig` / `build.zig.zon` - build wiring, the `-Dkyte-src` option, the `cross` step, and the version.

## Conventions and gotchas

- **Advertised capability must have a handler.** lsp-kit's `validateServerCapabilities` runs in Debug builds
  and panics at init if a capability has no matching handler. Crucially, the `.bool = true` form of a
  provider such as `inlayHintProvider` is treated as also requiring an `inlayHint/resolve` handler. If you do
  not implement resolve, advertise the options form with `resolveProvider = false` instead (see how
  `inlayHintProvider` is declared in `src/server.zig`). The same pattern applies to other resolve-capable
  providers.
- Keep kynalyzer pure Zig: do not introduce an import path that pulls in `llvm` or any external link
  dependency, or cross-compilation and the baseline-CPU guarantee break.
- Prose follows Indian English with British spellings (behaviour, colour, initialise) and no em dashes;
  never change code identifiers or LSP method names to match.
