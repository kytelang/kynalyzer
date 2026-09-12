const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const types = lsp.types.flat;
const compiler = @import("compiler");
const parser = compiler.parser;
const formatter = compiler.formatter;
const ast = compiler.ast;
const lexer = compiler.lexer;
const type_checker = compiler.type_checker;
const analysis = @import("analysis.zig");
const resolve = @import("resolve.zig");
const Io = std.Io;

const CItem = lsp.types.completion.Item;

/// The server version reported in the initialize response's serverInfo. It is INJECTED from build.zig.zon's
/// `.version` by build.zig (as the `build_options` module), so serverInfo can never drift from the
/// packaging version. Keep the kyte-vscode-extension version aligned with it at a release.
pub const server_version = @import("build_options").version;

/// The semantic-token legend advertised to the client. The INDEX of a name in
/// this array is the token-type id emitted in the token stream, so the order is
/// load-bearing: keep it in sync with `semanticTokenType`. All names are drawn
/// from the standard LSP `SemanticTokenTypes` set so editors theme them.
const semantic_token_types = [_][]const u8{
    "keyword", // 0
    "type", // 1
    "function", // 2
    "variable", // 3
    "string", // 4
    "number", // 5
    "operator", // 6
    "comment", // 7
};

/// Token modifiers advertised in the legend. Bit 0 (`declaration`) is set on the identifier that names a
/// new binding (the name right after `fn`/`struct`/`enum`/`trait`/`let`/`const`), so a theme can
/// distinguish a definition from a use.
const semantic_token_modifiers = [_][]const u8{
    "declaration", // bit 0 -> value 1
};

/// A cached parse of one document: its AST in a dedicated arena, plus a fingerprint of the source it was
/// parsed from. Reparsed only when the fingerprint changes, so repeated requests against an unchanged
/// buffer reuse the AST instead of reparsing. `program` is null when the source did not parse.
const CachedParse = struct {
    arena: std.heap.ArenaAllocator,
    program: ?ast.Program,
    fp: u64,
};

pub const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    files: std.StringHashMapUnmanaged([]u8),
    /// Per-URI parse cache (see CachedParse). Keyed by the document URI; the value's arena owns the AST.
    /// Invalidated by a source-fingerprint change (edits) and freed on didClose / deinit.
    parse_cache: std.StringHashMapUnmanaged(CachedParse) = .empty,
    offset_encoding: lsp.offsets.Encoding,
    /// The user's home directory (for locating `~/.kyte/std`), set by `main`
    /// from the process environment. Null in unit tests, which keeps diagnostics
    /// in single-file mode (no disk reads) so they run without a live `io`.
    home: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Handler {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .files = .empty,
            .offset_encoding = .@"utf-16",
            .home = null,
        };
    }

    pub fn deinit(self: *Handler) void {
        var file_it = self.files.iterator();
        while (file_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);
        self.files = undefined;

        var pc_it = self.parse_cache.iterator();
        while (pc_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.arena.deinit();
        }
        self.parse_cache.deinit(self.allocator);
        self.parse_cache = undefined;
    }

    /// Fast, order-independent fingerprint of a document's source. A changed fingerprint invalidates the
    /// cached parse; an unchanged one lets a repeated request reuse it.
    fn sourceFingerprint(source: []const u8) u64 {
        return std.hash.Wyhash.hash(0, source);
    }

    /// Return the AST for `source` (of document `uri`), reusing the cached parse when the source is
    /// unchanged since last time and reparsing (into the entry's own arena) otherwise. Returns null when
    /// the source does not parse. The returned Program stays valid until the next edit to THIS uri; callers
    /// use it within a single request, so it is never invalidated mid-use (the server is single-threaded).
    fn programFor(self: *Handler, uri: []const u8, source: []const u8) ?ast.Program {
        const fp = sourceFingerprint(source);
        const gop = self.parse_cache.getOrPut(self.allocator, uri) catch return self.parseUncached(source, uri);
        if (!gop.found_existing) {
            // Own the key; the URI slice from the request does not outlive it.
            gop.key_ptr.* = self.allocator.dupe(u8, uri) catch {
                _ = self.parse_cache.remove(uri);
                return self.parseUncached(source, uri);
            };
            gop.value_ptr.* = .{ .arena = std.heap.ArenaAllocator.init(self.allocator), .program = null, .fp = 0 };
        } else if (gop.value_ptr.fp == fp) {
            return gop.value_ptr.program; // hit: source unchanged
        }
        // Miss or stale: reparse into this entry's arena (freeing the previous parse).
        const c = gop.value_ptr;
        _ = c.arena.reset(.retain_capacity);
        c.fp = fp;
        var p = parser.Parser.init(c.arena.allocator(), source, uri, false) catch {
            c.program = null;
            return null;
        };
        c.program = p.parseProgram() catch null;
        return c.program;
    }

    /// Fallback parse into a throwaway arena (used only if the cache map itself cannot allocate). Leaks into
    /// that arena for the process lifetime are avoided because this path is effectively never taken.
    fn parseUncached(self: *Handler, source: []const u8, uri: []const u8) ?ast.Program {
        var p = parser.Parser.init(self.allocator, source, uri, false) catch return null;
        return p.parseProgram() catch null;
    }

    /// Drop any cached parse for `uri` (called on didClose to bound memory).
    fn dropParse(self: *Handler, uri: []const u8) void {
        if (self.parse_cache.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
            var v = kv.value;
            v.arena.deinit();
        }
    }

    pub fn initialize(
        self: *Handler,
        _: std.mem.Allocator,
        request: types.InitializeParams,
    ) types.InitializeResult {
        std.log.debug("Received 'initialize' message", .{});

        const client_capabilities: types.ClientCapabilities = request.capabilities;

        if (client_capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                self.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }

        const server_capabilities: types.ServerCapabilities = .{
            .positionEncoding = switch (self.offset_encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .documentFormattingProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{ ".", ":" } },
            .hoverProvider = .{ .bool = true },
            .definitionProvider = .{ .bool = true },
            .typeDefinitionProvider = .{ .bool = true },
            .implementationProvider = .{ .bool = true },
            .documentSymbolProvider = .{ .bool = true },
            .signatureHelpProvider = .{ .triggerCharacters = &.{ "(", "," } },
            .referencesProvider = .{ .bool = true },
            .documentHighlightProvider = .{ .bool = true },
            .foldingRangeProvider = .{ .bool = true },
            .renameProvider = .{ .rename_options = .{ .prepareProvider = true } },
            .codeActionProvider = .{ .bool = true },
            .workspaceSymbolProvider = .{ .bool = true },
            .semanticTokensProvider = .{ .semantic_tokens_options = .{
                .legend = .{
                    .tokenTypes = &semantic_token_types,
                    .tokenModifiers = &semantic_token_modifiers,
                },
                .full = .{ .bool = true },
                .range = .{ .bool = true },
            } },
            .selectionRangeProvider = .{ .bool = true },
            // Use the options form with resolveProvider = false: we compute every hint fully in
            // `textDocument/inlayHint`, so there is no `inlayHint/resolve`. The plain `.bool = true`
            // form makes lsp-kit treat resolve as expected and panic at init for the missing handler.
            .inlayHintProvider = .{ .inlay_hint_options = .{ .resolveProvider = false } },
        };

        if (builtin.mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Handler, server_capabilities);
        }

        return .{
            .serverInfo = .{
                .name = "Kyte Language Server",
                // Keep in sync with build.zig.zon `.version` and the kyte-vscode-extension version.
                // The gate (docs/check-version.sh / zig build test) asserts serverInfo == the zon version.
                .version = server_version,
            },
            .capabilities = server_capabilities,
        };
    }

    pub fn initialized(
        _: *Handler,
        _: std.mem.Allocator,
        _: types.InitializedParams,
    ) void {
        std.log.debug("Received 'initialized' notification", .{});
    }

    pub fn shutdown(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) ?void {
        std.log.debug("Received 'shutdown' request", .{});
        return null;
    }

    pub fn exit(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) void {
        std.log.debug("Received 'exit' notification", .{});
    }

    pub fn @"textDocument/didOpen"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DidOpenTextDocumentParams,
    ) !void {
        const uri = params.textDocument.uri;
        const text = params.textDocument.text;

        const new_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(new_text);

        const gop = try self.files.getOrPut(self.allocator, uri);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, uri);
        }
        gop.value_ptr.* = new_text;

        try self.runDiagnostics(arena, uri, new_text);
    }

    pub fn @"textDocument/didChange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DidChangeTextDocumentParams,
    ) !void {
        const uri = params.textDocument.uri;
        const current_text = self.files.getPtr(uri) orelse return;

        if (params.contentChanges.len == 0) return;
        const change = params.contentChanges[0];

        const new_text = try self.allocator.dupe(u8, change.text_document_content_change_whole_document.text);
        self.allocator.free(current_text.*);
        current_text.* = new_text;

        try self.runDiagnostics(arena, uri, new_text);
    }

    pub fn @"textDocument/didClose"(
        self: *Handler,
        _: std.mem.Allocator,
        params: types.DidCloseTextDocumentParams,
    ) !void {
        self.dropParse(params.textDocument.uri);
        const entry = self.files.fetchRemove(params.textDocument.uri) orelse return;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    fn runDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, source: []const u8) !void {
        var diags = std.ArrayList(types.Diagnostic).empty;

        var p = parser.Parser.init(arena, source, uri, false) catch |err| {
            std.log.err("Parser init failed: {any}", .{err});
            return;
        };
        defer p.deinit();

        if (p.parseProgram()) |program| {
            // The buffer parses, so hand it to the SAME type checker the compiler
            // runs and surface every spanned error it produces (not just the first
            // token). Single-file mode: imports aren't resolved, so the checker's
            // cross-module checks (e.g. undefined-trait) are best-effort; every
            // check it emits is decl-guarded, so this stays low on false positives.
            try self.collectSemanticDiagnostics(arena, uri, source, program, &diags);
        } else |_| {
            // Didn't parse, so report the parser's single syntax error, as before.
            const err_token = p.tokens[@min(p.pos, p.tokens.len - 1)];
            const line = err_token.line - 1;
            const column = err_token.column - 1;
            const msg = try std.fmt.allocPrint(arena, "Syntax error: unexpected token '{s}'", .{err_token.lexeme});
            try diags.append(arena, .{
                .range = .{
                    .start = .{ .line = @intCast(line), .character = @intCast(column) },
                    .end = .{ .line = @intCast(line), .character = @intCast(column + err_token.lexeme.len) },
                },
                .severity = .Error,
                .source = "kyte",
                .message = msg,
            });
        }

        const publish_params = types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = diags.items,
        };
        try self.transport.writeNotification(self.io, arena, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams, publish_params, .{});
    }

    /// Run the compiler's type checker over `program` and translate each of its
    /// span-carrying diagnostics into an LSP `Diagnostic` for the current file.
    fn collectSemanticDiagnostics(
        self: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        source: []const u8,
        program: ast.Program,
        out: *std.ArrayList(types.Diagnostic),
    ) !void {
        var file_sources = std.StringHashMap([]const u8).init(arena);
        file_sources.put(uri, source) catch return;

        // Start the merged declaration set with the open buffer's own decls, then
        // fold in the transitive import closure so the checker sees the same
        // symbols the real build does. Kyte resolves types in one global merged
        // namespace, so a feature file's `impl RequestHandler<...>` is only valid
        // because the app entry (`main.ky`) pulls the framework in; type-checking
        // the open file alone flagged every imported type/trait the compiler never
        // does.
        var decls = std.ArrayList(ast.Declaration).empty;
        for (program.declarations) |d| decls.append(arena, d) catch {};

        var have_imports = false;
        var any_unresolved = false;
        var loaded_project = false;

        // Disk resolution only runs on the real server (`home` set). Unit tests
        // pass a null home and an undefined `io`, so they stay in single-file mode.
        if (self.home) |home| {
            const base_path = resolve.uriToPath(arena, uri) catch uri;

            var visited = std.StringHashMap(void).init(arena);
            // The open buffer is already merged and keyed under `uri`; mark its
            // path visited so the closure never re-reads a stale on-disk copy.
            visited.put(base_path, {}) catch {};

            // Work queue of file paths still to load. Seed it with the open
            // buffer's own imports, plus the project entry so framework-level
            // declarations (auto-discovered handlers rely on them) come into scope.
            var work = std.ArrayList([]const u8).empty;
            for (program.declarations) |d| {
                if (d != .import_decl) continue;
                if (std.mem.eql(u8, d.import_decl.module, "bytes")) continue;
                have_imports = true;
                if (resolve.resolveImport(arena, self.io, base_path, d.import_decl.module, home)) |rp| {
                    work.append(arena, rp) catch {};
                } else any_unresolved = true;
            }
            if (resolve.projectEntry(arena, self.io, base_path)) |entry| {
                loaded_project = true;
                if (!std.mem.eql(u8, entry, base_path)) work.append(arena, entry) catch {};
            }

            // Breadth-first over the closure. Each file's imports resolve relative
            // to that file. A generous cap guards against pathological graphs.
            var loaded: usize = 0;
            while (work.pop()) |path| {
                if (visited.contains(path)) continue;
                visited.put(path, {}) catch {};

                const fsrc = Io.Dir.readFileAlloc(.cwd(), self.io, path, arena, .unlimited) catch {
                    any_unresolved = true;
                    continue;
                };
                file_sources.put(path, fsrc) catch {};

                var fp = parser.Parser.init(arena, fsrc, path, false) catch continue;
                defer fp.deinit();
                const fprog = fp.parseProgram() catch continue;
                for (fprog.declarations) |fd| decls.append(arena, fd) catch {};

                for (fprog.declarations) |fd| {
                    if (fd != .import_decl) continue;
                    if (std.mem.eql(u8, fd.import_decl.module, "bytes")) continue;
                    if (resolve.resolveImport(arena, self.io, path, fd.import_decl.module, home)) |rp| {
                        if (!visited.contains(rp)) work.append(arena, rp) catch {};
                    } else any_unresolved = true;
                }

                loaded += 1;
                if (loaded > 2000) break;
            }
        }

        const merged = ast.Program{ .declarations = decls.items, .span = program.span };

        var tc = type_checker.TypeChecker.init(arena, &file_sources);
        tc.silent = true; // keep stderr clean; the errors come back structured
        defer tc.deinit();

        // `check` returns error.TypeCheckError when it finds problems; that is the
        // expected path here. Any other failure just yields no diagnostics.
        tc.check(merged) catch {};

        // When we loaded the project's full closure the checker is authoritative,
        // so every diagnostic stands and genuine typos surface. Only for a loose
        // file outside any project, where an unresolved import might legitimately
        // define the symbol we are about to call unknown, do we drop the
        // cross-module diagnostics rather than cry wolf.
        const suppress_xmod = have_imports and any_unresolved and !loaded_project;

        for (tc.structured.items) |d| {
            if (!std.mem.eql(u8, d.file, uri)) continue;
            if (suppress_xmod and resolve.isCrossModuleDiag(d.message)) continue;
            try out.append(arena, .{
                .range = self.diagRange(source, d),
                .severity = .Error,
                .source = "kyte",
                .message = try arena.dupe(u8, d.message),
            });
        }
    }

    /// Map a type-checker diagnostic's start offset onto an editor range. The
    /// checker gives a reliable start (byte offset of the reported node); we widen
    /// it over the identifier there so the squiggle covers a whole name, falling
    /// back to a single character when the node doesn't begin on a word.
    fn diagRange(self: *Handler, source: []const u8, d: type_checker.Diagnostic) types.Range {
        const start_idx = @min(d.start, source.len);
        var end_idx = start_idx;
        while (end_idx < source.len and
            (std.ascii.isAlphanumeric(source[end_idx]) or source[end_idx] == '_')) end_idx += 1;
        if (end_idx == start_idx) end_idx = @min(start_idx + 1, source.len);
        return .{
            .start = lsp.offsets.indexToPosition(source, start_idx, self.offset_encoding),
            .end = lsp.offsets.indexToPosition(source, end_idx, self.offset_encoding),
        };
    }

    fn getDocumentEnd(text: []const u8) types.Position {
        var line: u32 = 0;
        var character: u32 = 0;
        for (text) |c| {
            if (c == '\n') {
                line += 1;
                character = 0;
            } else {
                character += 1;
            }
        }
        return .{ .line = line, .character = character };
    }

    /// True when `a` and `b` lex to the identical token stream (same types and
    /// lexemes, in order). Comments and whitespace are lexer trivia and never
    /// surface as tokens, so equal token streams mean the CODE is unchanged. This
    /// is the formatter's correctness gate: a reformat that preserves the token
    /// stream cannot have altered program meaning. Mirrors `kyte/src/format.zig`.
    fn sameTokenStream(a: []const u8, b: []const u8) bool {
        var la = lexer.Lexer.init(a);
        var lb = lexer.Lexer.init(b);
        while (true) {
            const ta = la.nextToken();
            const tb = lb.nextToken();
            if (ta.type != tb.type) return false;
            if (!std.mem.eql(u8, ta.lexeme, tb.lexeme)) return false;
            if (ta.type == .eof) return true;
        }
    }

    pub fn @"textDocument/formatting"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DocumentFormattingParams,
    ) !?[]const types.TextEdit {
        const uri = params.textDocument.uri;
        const source = self.files.get(uri) orelse return null;

        // Reuse the cached AST for this document when the source is unchanged (see programFor).
        const program = self.programFor(uri, source) orelse return null;

        var f = formatter.Formatter.init(arena, source);
        defer f.deinit();

        const formatted = f.formatProgram(program) catch return null;

        // SAFETY GATE (mirrors `kyte fmt`'s formatFile): only return the reformat
        // if it produces the SAME token stream as the source. The formatter rebuilds
        // surface syntax from a lossy AST and silently no-ops on constructs it cannot
        // render faithfully; without this guard the editor would replace the buffer
        // with semantically-altered text (the historical `spawn`->`go` / dropped-`pub`
        // corruption). If the token streams differ, return no edit and leave the file
        // untouched rather than corrupt it.
        if (!sameTokenStream(source, formatted)) return null;

        const end_pos = getDocumentEnd(source);
        const full_range = types.Range{
            .start = .{ .line = 0, .character = 0 },
            .end = end_pos,
        };

        const edit = types.TextEdit{
            .range = full_range,
            .newText = formatted,
        };

        const edits = try arena.alloc(types.TextEdit, 1);
        edits[0] = edit;
        return edits;
    }

    // ------------------------------------------------------------------
    // Completion
    // ------------------------------------------------------------------

    const CompletionContext = union(enum) {
        /// `receiver.` ,  the dotted segment chain BEFORE the trailing dot.
        member: []const []const u8,
        /// Typing a bare identifier.
        identifier,
    };

    /// Resolve a completion item. Our `textDocument/completion` already fills every field eagerly (label,
    /// kind, detail), so there is nothing expensive to defer: resolve returns the item unchanged. The
    /// capability is still advertised because some clients only render `detail`/`documentation` after a
    /// resolve round-trip, and this makes that round-trip a well-defined no-op rather than an error.
    pub fn @"completionItem/resolve"(
        self: *Handler,
        arena: std.mem.Allocator,
        item: CItem,
    ) !CItem {
        _ = self;
        _ = arena;
        return item;
    }

    pub fn @"textDocument/completion"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.completion.Params,
    ) !?lsp.types.completion.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);

        // The context (receiver chain / bare-word) is read from the ORIGINAL buffer.
        const ctx = analyzeCompletionContext(arena, source, index);

        // The buffer is usually mid-edit and won't parse (a dangling `.` or a bare
        // word with no `;`); parseBest falls back to blanking the cursor's line so
        // the rest of the file still yields declarations and the enclosing scope.
        const program = parseBest(arena, params.textDocument.uri, source, index) orelse
            ast.Program{ .declarations = &.{}, .span = undefined };

        var items = std.ArrayList(CItem).empty;

        switch (ctx) {
            .member => |segments| try self.memberCompletions(arena, program, source, index, segments, &items),
            .identifier => try self.identifierCompletions(arena, program, source, index, &items),
        }

        return .{ .completion_items = try items.toOwnedSlice(arena) };
    }

    /// Parse `source`; if it doesn't parse (the usual mid-edit case), retry with
    /// the cursor's line blanked. Prefers the real parse so a completion/signature
    /// request on an already-valid buffer isn't degraded by the repair. Offsets are
    /// preserved either way, so spans stay valid against `index`.
    fn parseBest(arena: std.mem.Allocator, uri: []const u8, source: []const u8, index: usize) ?ast.Program {
        if (parser.Parser.init(arena, source, uri, false)) |*p_ok| {
            var p = p_ok.*;
            if (p.parseProgram()) |program| {
                return program;
            } else |_| {}
        } else |_| {}

        const repaired = repairLine(arena, source, index) catch return null;
        var p = parser.Parser.init(arena, repaired, uri, false) catch return null;
        return p.parseProgram() catch null;
    }

    /// Blank the line containing `index` (spaces), keeping `{`/`}` so brace
    /// nesting stays balanced. Same length as the input, so every byte offset , 
    /// and thus every AST span ,  is preserved.
    fn repairLine(arena: std.mem.Allocator, source: []const u8, index: usize) ![]u8 {
        const buf = try arena.dupe(u8, source);
        var ls = @min(index, buf.len);
        while (ls > 0 and buf[ls - 1] != '\n') ls -= 1;
        var le = @min(index, buf.len);
        while (le < buf.len and buf[le] != '\n') le += 1;
        for (buf[ls..le]) |*c| {
            if (c.* != '{' and c.* != '}' and c.* != '\r') c.* = ' ';
        }
        return buf;
    }

    fn analyzeCompletionContext(arena: std.mem.Allocator, source: []const u8, index: usize) CompletionContext {
        // Back over the partial identifier under the cursor.
        var i = @min(index, source.len);
        while (i > 0 and isIdentChar(source[i - 1])) i -= 1;
        if (i == 0 or source[i - 1] != '.') return .identifier;

        // We're completing a member. Collect the receiver chain before the dot.
        var end = i - 1; // at the '.'
        while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
        var start = end;
        while (start > 0 and (isIdentChar(source[start - 1]) or source[start - 1] == '.')) start -= 1;
        const chain = std.mem.trim(u8, source[start..end], " \t");

        var segs = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, chain, '.');
        while (it.next()) |seg| {
            const s = std.mem.trim(u8, seg, " \t");
            if (s.len > 0) segs.append(arena, s) catch {};
        }
        return .{ .member = segs.toOwnedSlice(arena) catch &.{} };
    }

    fn memberCompletions(
        _: *Handler,
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        index: usize,
        segments: []const []const u8,
        items: *std.ArrayList(CItem),
    ) !void {
        // Build the local scope so `foo.` can be resolved.
        var locals = std.ArrayList(analysis.Local).empty;
        const enc = analysis.enclosingFunction(program, index);
        if (enc) |e| try analysis.collectLocals(arena, program, e, index, &locals);

        const receiver = analysis.resolveChain(segments, locals.items, enc, program);
        if (receiver) |r| {
            try appendTypeMembers(arena, program, source, r, items);
            if (items.items.len > 0) return;
        }
        // Unresolved receiver → offer the union of all members so the user still
        // gets useful suggestions (a good LSP degrades, it doesn't go blank).
        try appendAllMembers(arena, program, source, items);
    }

    fn appendTypeMembers(
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        receiver: analysis.Receiver,
        items: *std.ArrayList(CItem),
    ) !void {
        const decl = analysis.findTypeDecl(program, receiver.type_name) orelse return;
        switch (decl) {
            .struct_decl => |sd| {
                if (!receiver.is_static) {
                    for (sd.fields) |f| {
                        try items.append(arena, .{
                            .label = f.name,
                            .kind = .Field,
                            .detail = try fieldDetail(arena, sd.name, f),
                        });
                    }
                }
                for (sd.methods) |md| {
                    if (md.is_static != receiver.is_static) continue;
                    if (std.mem.eql(u8, md.decl.name, "init")) continue;
                    try items.append(arena, try methodItem(arena, source, sd.name, md));
                }
            },
            .enum_decl => |ed| {
                if (receiver.is_static) {
                    for (ed.variants) |v| {
                        try items.append(arena, .{
                            .label = v.name,
                            .kind = .EnumMember,
                            .detail = try std.fmt.allocPrint(arena, "{s}.{s}", .{ ed.name, v.name }),
                        });
                    }
                }
                for (ed.methods) |md| {
                    if (md.is_static != receiver.is_static) continue;
                    try items.append(arena, try methodItem(arena, source, ed.name, md));
                }
            },
        }
    }

    fn appendAllMembers(
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        items: *std.ArrayList(CItem),
    ) !void {
        // Fallback for an UNRESOLVED receiver: distinct member names declared in THIS file (deduped), so
        // the user still gets suggestions rather than a blank list. Hard-capped so a very large file cannot
        // flood the popup; a resolved receiver (appendTypeMembers) is always preferred and returns first.
        const MAX_FALLBACK = 200;
        var seen = std.StringHashMap(void).init(arena);
        for (program.declarations) |decl| {
            if (items.items.len >= MAX_FALLBACK) break;
            switch (decl) {
                .struct_decl => |sd| {
                    for (sd.fields) |f| {
                        if ((try seen.getOrPut(f.name)).found_existing) continue;
                        try items.append(arena, .{ .label = f.name, .kind = .Field, .detail = try fieldDetail(arena, sd.name, f) });
                    }
                    for (sd.methods) |md| {
                        if (std.mem.eql(u8, md.decl.name, "init")) continue;
                        if ((try seen.getOrPut(md.decl.name)).found_existing) continue;
                        try items.append(arena, try methodItem(arena, source, sd.name, md));
                    }
                },
                .enum_decl => |ed| {
                    for (ed.methods) |md| {
                        if ((try seen.getOrPut(md.decl.name)).found_existing) continue;
                        try items.append(arena, try methodItem(arena, source, ed.name, md));
                    }
                },
                else => {},
            }
        }
    }

    fn identifierCompletions(
        _: *Handler,
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        index: usize,
        items: *std.ArrayList(CItem),
    ) !void {
        // Locals + params first (most relevant, sort them to the top).
        var locals = std.ArrayList(analysis.Local).empty;
        if (analysis.enclosingFunction(program, index)) |e| {
            try analysis.collectLocals(arena, program, e, index, &locals);
            if (e.container != null) {
                try items.append(arena, .{ .label = "self", .kind = .Variable, .detail = e.container.?, .sortText = "0000self" });
            }
        }
        for (locals.items) |l| {
            const detail = if (l.type_name) |t|
                try std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ if (l.is_const) "const" else "let", l.name, t })
            else
                try std.fmt.allocPrint(arena, "{s} {s}", .{ if (l.is_param) "param" else if (l.is_const) "const" else "let", l.name });
            try items.append(arena, .{
                .label = l.name,
                .kind = if (l.is_param) .Variable else .Variable,
                .detail = detail,
                .sortText = try std.fmt.allocPrint(arena, "0001{s}", .{l.name}),
            });
        }

        // Top-level declarations.
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| try items.append(arena, .{
                    .label = fd.name,
                    .kind = .Function,
                    .detail = try formatSignature(arena, fd.name, fd.params, fd.ret_type, null),
                    .documentation = try docMarkup(arena, source, fd.span.start),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{fd.name}),
                }),
                .struct_decl => |sd| try items.append(arena, .{
                    .label = sd.name,
                    .kind = .Struct,
                    .detail = try std.fmt.allocPrint(arena, "struct {s}", .{sd.name}),
                    .documentation = try docMarkup(arena, source, sd.span.start),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{sd.name}),
                }),
                .enum_decl => |ed| try items.append(arena, .{
                    .label = ed.name,
                    .kind = .Enum,
                    .detail = try std.fmt.allocPrint(arena, "enum {s}", .{ed.name}),
                    .documentation = try docMarkup(arena, source, ed.span.start),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{ed.name}),
                }),
                .const_decl => |cd| try items.append(arena, .{
                    .label = cd.name,
                    .kind = .Constant,
                    .detail = try std.fmt.allocPrint(arena, "const {s}", .{cd.name}),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{cd.name}),
                }),
                .trait_decl => |td| try items.append(arena, .{
                    .label = td.name,
                    .kind = .Interface,
                    .detail = try std.fmt.allocPrint(arena, "trait {s}", .{td.name}),
                    .sortText = try std.fmt.allocPrint(arena, "0002{s}", .{td.name}),
                }),
                .import_decl => |id| {
                    for (id.items) |item| {
                        const name = item.alias orelse item.name;
                        try items.append(arena, .{ .label = name, .kind = .Module, .detail = try std.fmt.allocPrint(arena, "import {s}", .{id.module}), .sortText = try std.fmt.allocPrint(arena, "0003{s}", .{name}) });
                    }
                },
                else => {},
            }
        }

        // Primitive types.
        for (analysis.primitive_types) |t| {
            try items.append(arena, .{ .label = t, .kind = .TypeParameter, .detail = "builtin type", .sortText = try std.fmt.allocPrint(arena, "0008{s}", .{t}) });
        }
        // Keywords last.
        for (analysis.keywords) |kw| {
            try items.append(arena, .{ .label = kw, .kind = .Keyword, .sortText = try std.fmt.allocPrint(arena, "0009{s}", .{kw}) });
        }
    }

    fn fieldDetail(arena: std.mem.Allocator, owner: []const u8, f: ast.Field) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        try list.appendSlice(arena, owner);
        try list.appendSlice(arena, ".");
        try list.appendSlice(arena, f.name);
        try list.appendSlice(arena, ": ");
        try writeTypeRef(arena, &list, f.type_name);
        return list.toOwnedSlice(arena);
    }

    fn methodItem(arena: std.mem.Allocator, source: []const u8, owner: []const u8, md: ast.MethodDecl) !CItem {
        return .{
            .label = md.decl.name,
            .kind = .Method,
            .detail = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, owner),
            .documentation = try docMarkup(arena, source, md.decl.span.start),
        };
    }

    fn docMarkup(arena: std.mem.Allocator, source: []const u8, start: usize) !?lsp.types.Documentation {
        const doc = try getDocComment(source, start, arena) orelse return null;
        return .{ .markup_content = .{ .kind = .markdown, .value = doc } };
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    // ------------------------------------------------------------------
    // Hover
    // ------------------------------------------------------------------

    pub fn @"textDocument/hover"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.Hover.Params,
    ) !?types.Hover {
        const current_source = self.files.get(params.textDocument.uri) orelse return null;
        const source_index = lsp.offsets.positionToIndex(current_source, params.position, self.offset_encoding);

        const hovered_word = getWordAtIndex(current_source, source_index) orelse return null;

        // Builtin type keyword?
        for (analysis.primitive_types) |t| {
            if (std.mem.eql(u8, t, hovered_word)) {
                return markdownHover(arena, try std.fmt.allocPrint(arena, "```kyte\n{s}\n```\nKyte builtin primitive type.", .{t}));
            }
        }

        // Local variable / parameter in the enclosing function?
        {
            var p = parser.Parser.init(arena, current_source, params.textDocument.uri, false) catch null;
            if (p) |*pp| {
                defer pp.deinit();
                if (pp.parseProgram()) |program| {
                    if (analysis.enclosingFunction(program, source_index)) |enc| {
                        var locals = std.ArrayList(analysis.Local).empty;
                        try analysis.collectLocals(arena, program, enc, source_index, &locals);
                        // Prefer a binding whose own span does NOT enclose the cursor
                        // (i.e. a use site) but fall back to any match.
                        for (locals.items) |l| {
                            if (!std.mem.eql(u8, l.name, hovered_word)) continue;
                            const kind = if (l.is_param) "param" else if (l.is_const) "const" else "let";
                            const body = if (l.type_name) |t|
                                try std.fmt.allocPrint(arena, "```kyte\n{s} {s}: {s}\n```", .{ kind, l.name, t })
                            else
                                try std.fmt.allocPrint(arena, "```kyte\n{s} {s}\n```", .{ kind, l.name });
                            return markdownHover(arena, body);
                        }
                    }
                } else |_| {}
            }
        }

        // Top-level / member declarations across all open files.
        var file_iter = self.files.iterator();
        while (file_iter.next()) |entry| {
            const file_uri = entry.key_ptr.*;
            const file_source = entry.value_ptr.*;

            var p = parser.Parser.init(arena, file_source, file_uri, false) catch continue;
            defer p.deinit();

            const program = p.parseProgram() catch continue;

            if (try hoverForDecl(arena, program, file_source, hovered_word)) |h| return h;
        }

        return null;
    }

    fn hoverForDecl(arena: std.mem.Allocator, program: ast.Program, source: []const u8, word: []const u8) !?types.Hover {
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| {
                    if (std.mem.eql(u8, fd.name, word)) {
                        const sig = try formatSignature(arena, fd.name, fd.params, fd.ret_type, null);
                        return codeHover(arena, source, sig, fd.span.start);
                    }
                },
                .const_decl => |cd| {
                    if (std.mem.eql(u8, cd.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "const {s}", .{cd.name});
                        return codeHover(arena, source, sig, cd.span.start);
                    }
                },
                .trait_decl => |td| {
                    if (std.mem.eql(u8, td.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "trait {s}", .{td.name});
                        return codeHover(arena, source, sig, td.span.start);
                    }
                },
                .struct_decl => |sd| {
                    if (std.mem.eql(u8, sd.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "struct {s}", .{sd.name});
                        return codeHover(arena, source, sig, sd.span.start);
                    }
                    for (sd.fields) |f| {
                        if (std.mem.eql(u8, f.name, word)) {
                            var list = std.ArrayList(u8).empty;
                            try list.appendSlice(arena, sd.name);
                            try list.appendSlice(arena, ".");
                            try list.appendSlice(arena, f.name);
                            try list.appendSlice(arena, ": ");
                            try writeTypeRef(arena, &list, f.type_name);
                            return codeHover(arena, source, try list.toOwnedSlice(arena), f.span.start);
                        }
                    }
                    for (sd.methods) |md| {
                        if (std.mem.eql(u8, md.decl.name, word)) {
                            const sig = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, sd.name);
                            return codeHover(arena, source, sig, md.decl.span.start);
                        }
                    }
                },
                .enum_decl => |ed| {
                    if (std.mem.eql(u8, ed.name, word)) {
                        const sig = try std.fmt.allocPrint(arena, "enum {s}", .{ed.name});
                        return codeHover(arena, source, sig, ed.span.start);
                    }
                    for (ed.variants) |v| {
                        if (std.mem.eql(u8, v.name, word)) {
                            const sig = try std.fmt.allocPrint(arena, "{s}.{s}", .{ ed.name, v.name });
                            return codeHover(arena, source, sig, v.span.start);
                        }
                    }
                    for (ed.methods) |md| {
                        if (std.mem.eql(u8, md.decl.name, word)) {
                            const sig = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, ed.name);
                            return codeHover(arena, source, sig, md.decl.span.start);
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Hover rendering a `kyte` code fence plus any `///` doc comment above `start`.
    fn codeHover(arena: std.mem.Allocator, source: []const u8, sig: []const u8, start: usize) !?types.Hover {
        var md = std.ArrayList(u8).empty;
        try md.appendSlice(arena, "```kyte\n");
        try md.appendSlice(arena, sig);
        try md.appendSlice(arena, "\n```\n");
        if (try getDocComment(source, start, arena)) |doc| {
            try md.appendSlice(arena, doc);
            try md.appendSlice(arena, "\n");
        }
        return markdownHover(arena, try md.toOwnedSlice(arena));
    }

    fn markdownHover(_: std.mem.Allocator, value: []const u8) types.Hover {
        return .{ .contents = .{ .markup_content = .{ .kind = .markdown, .value = value } } };
    }

    // ------------------------------------------------------------------
    // Go-to-definition
    // ------------------------------------------------------------------

    pub fn @"textDocument/definition"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.Definition.Params,
    ) !?types.Definition.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        // Local binding in the enclosing function wins ,  jump to its declaration.
        {
            var p = parser.Parser.init(arena, source, params.textDocument.uri, false) catch null;
            if (p) |*pp| {
                defer pp.deinit();
                if (pp.parseProgram()) |program| {
                    if (analysis.enclosingFunction(program, index)) |enc| {
                        var locals = std.ArrayList(analysis.Local).empty;
                        try analysis.collectLocals(arena, program, enc, index, &locals);
                        for (locals.items) |l| {
                            if (std.mem.eql(u8, l.name, word) and l.span.start != index) {
                                return locationResult(arena, source, params.textDocument.uri, l.span, word);
                            }
                        }
                    }
                } else |_| {}
            }
        }

        // Otherwise search every open file for the declaration (the word's own
        // definition), remembering the first hit as the primary target.
        var primary: ?types.Location = null;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            const file_uri = entry.key_ptr.*;
            const file_source = entry.value_ptr.*;
            var p = parser.Parser.init(arena, file_source, file_uri, false) catch continue;
            defer p.deinit();
            const program = p.parseProgram() catch continue;
            if (declSpanFor(program, word)) |span| {
                primary = .{ .uri = file_uri, .range = nameRange(file_source, span, word) };
                break;
            }
        }

        // Anti-magic navigation: if `word` is a command type served by one or more
        // `RequestHandler<word, _>` implementations, surface those handlers. So
        // go-to-definition on `Register` in a route (`app.post<Register>`) or a
        // registration (`handlers.add<Register, RegisterHandler>`) reaches
        // `RegisterHandler`, instead of the route-to-handler link being invisible.
        // The command's own definition is kept first when it is among the open
        // buffers, so if you have the command file open you get both (a peek list
        // in VS Code); otherwise the result is just the handler, and the editor
        // jumps straight to it, which is exactly what you want from a routing file.
        var handler_locs = std.ArrayList(types.Location).empty;
        // Gate the (potentially whole-project) handler search to files that
        // actually route or register, so ordinary go-to-definition stays cheap.
        if (fileRoutesOrRegisters(source)) {
            self.collectHandlerLocations(arena, params.textDocument.uri, source, word, &handler_locs) catch {};
        }
        if (handler_locs.items.len > 0) {
            var all = std.ArrayList(types.Location).empty;
            if (primary) |p| try all.append(arena, p);
            for (handler_locs.items) |h| try all.append(arena, h);
            return .{ .definition = .{ .locations = try all.toOwnedSlice(arena) } };
        }

        if (primary) |p| return .{ .definition = .{ .location = p } };
        return null;
    }

    fn declSpanFor(program: ast.Program, word: []const u8) ?ast.Span {
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| if (std.mem.eql(u8, fd.name, word)) return fd.span,
                .const_decl => |cd| if (std.mem.eql(u8, cd.name, word)) return cd.span,
                .trait_decl => |td| if (std.mem.eql(u8, td.name, word)) return td.span,
                .struct_decl => |sd| {
                    if (std.mem.eql(u8, sd.name, word)) return sd.span;
                    for (sd.fields) |f| if (std.mem.eql(u8, f.name, word)) return f.span;
                    for (sd.methods) |md| if (std.mem.eql(u8, md.decl.name, word)) return md.decl.span;
                },
                .enum_decl => |ed| {
                    if (std.mem.eql(u8, ed.name, word)) return ed.span;
                    for (ed.variants) |v| if (std.mem.eql(u8, v.name, word)) return v.span;
                    for (ed.methods) |md| if (std.mem.eql(u8, md.decl.name, word)) return md.decl.span;
                },
                else => {},
            }
        }
        return null;
    }

    /// Cheap gate: does this file route (`app.post<...>`, `get`/`put`/`delete`/
    /// `patch`) or register handlers (`.add<...>`)? Only such files (typically the
    /// app entry `main.ky`) benefit from the command-to-handler jump, so the
    /// whole-project handler search is skipped everywhere else and ordinary
    /// go-to-definition pays nothing.
    fn fileRoutesOrRegisters(source: []const u8) bool {
        const needles = [_][]const u8{ ".post<", ".get<", ".put<", ".delete<", ".patch<", ".add<" };
        for (needles) |n| {
            if (std.mem.indexOf(u8, source, n) != null) return true;
        }
        return false;
    }

    /// True if struct `sd` implements `RequestHandler<cmd, _>`, i.e. it is the
    /// request handler that serves the command type named `cmd`. This is the link
    /// go-to-definition follows from a route (`app.post<Register>`) or a
    /// registration (`handlers.add<Register, RegisterHandler>`) to the handler.
    fn structHandlesCommand(sd: ast.StructDecl, cmd: []const u8) bool {
        for (sd.impls) |im| {
            if (!std.mem.eql(u8, im.name, "RequestHandler")) continue;
            if (im.type_args.len == 0) continue;
            const first = analysis.typeRefName(im.type_args[0]) orelse continue;
            if (std.mem.eql(u8, first, cmd)) return true;
        }
        return false;
    }

    /// Appends, for every `struct Y impl RequestHandler<cmd, _>` found in `program`,
    /// a `Location` at `Y`'s name. `seen` dedupes by handler type name so the same
    /// handler is not reported once per open buffer and once from disk.
    fn scanHandlersInProgram(
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        uri: []const u8,
        cmd: []const u8,
        out: *std.ArrayList(types.Location),
        seen: *std.StringHashMap(void),
    ) !void {
        for (program.declarations) |decl| {
            if (decl != .struct_decl) continue;
            const sd = decl.struct_decl;
            if (!structHandlesCommand(sd, cmd)) continue;
            if (seen.contains(sd.name)) continue;
            try seen.put(sd.name, {});
            try out.append(arena, .{ .uri = uri, .range = nameRange(source, sd.span, sd.name) });
        }
    }

    /// Collects the handler(s) that serve the command type named `cmd`, across
    /// open buffers and the transitive import closure on disk (handler files are
    /// usually not open when the cursor sits on a route in `main.ky`). This is
    /// what makes `app.post<Register>` navigable straight to `RegisterHandler`.
    fn collectHandlerLocations(
        self: *Handler,
        arena: std.mem.Allocator,
        base_uri: []const u8,
        base_source: []const u8,
        cmd: []const u8,
        out: *std.ArrayList(types.Location),
    ) !void {
        var seen = std.StringHashMap(void).init(arena);

        // Open buffers first: they hold the freshest, possibly-unsaved source.
        var it = self.files.iterator();
        while (it.next()) |entry| {
            var p = parser.Parser.init(arena, entry.value_ptr.*, entry.key_ptr.*, false) catch continue;
            defer p.deinit();
            const program = p.parseProgram() catch continue;
            try scanHandlersInProgram(arena, program, entry.value_ptr.*, entry.key_ptr.*, cmd, out, &seen);
        }

        // Then the import closure from disk. Only runs on the real server (home
        // set); unit tests pass a null home and stay in open-buffer mode.
        const home = self.home orelse return;
        const base_path = resolve.uriToPath(arena, base_uri) catch return;

        var visited = std.StringHashMap(void).init(arena);
        visited.put(base_path, {}) catch {};

        var work = std.ArrayList([]const u8).empty;
        var bp = parser.Parser.init(arena, base_source, base_path, false) catch return;
        defer bp.deinit();
        const bprog = bp.parseProgram() catch return;
        for (bprog.declarations) |d| {
            if (d != .import_decl) continue;
            if (std.mem.eql(u8, d.import_decl.module, "bytes")) continue;
            if (resolve.resolveImport(arena, self.io, base_path, d.import_decl.module, home)) |rp| {
                work.append(arena, rp) catch {};
            }
        }
        if (resolve.projectEntry(arena, self.io, base_path)) |entry| {
            if (!std.mem.eql(u8, entry, base_path)) work.append(arena, entry) catch {};
        }

        var loaded: usize = 0;
        while (work.pop()) |path| {
            if (visited.contains(path)) continue;
            visited.put(path, {}) catch {};
            loaded += 1;
            if (loaded > 4000) break;

            const fsrc = Io.Dir.readFileAlloc(.cwd(), self.io, path, arena, .unlimited) catch continue;
            var fp = parser.Parser.init(arena, fsrc, path, false) catch continue;
            defer fp.deinit();
            const fprog = fp.parseProgram() catch continue;

            const furi = resolve.pathToUri(arena, path) catch path;
            try scanHandlersInProgram(arena, fprog, fsrc, furi, cmd, out, &seen);

            for (fprog.declarations) |fd| {
                if (fd != .import_decl) continue;
                if (std.mem.eql(u8, fd.import_decl.module, "bytes")) continue;
                if (resolve.resolveImport(arena, self.io, path, fd.import_decl.module, home)) |rp| {
                    if (!visited.contains(rp)) work.append(arena, rp) catch {};
                }
            }
        }
    }

    // A (uri, source) pair a project-wide symbol query should scan: every open buffer plus every file in
    // the import closure on disk. References/rename use this so an edit is not confined to open buffers.
    const SymTarget = struct { uri: []const u8, source: []const u8 };

    /// Collect the files a project-wide references/rename should scan: open buffers first (freshest,
    /// possibly-unsaved source) then the transitive import closure from `base_uri` on disk. Deduplicated by
    /// canonical path so an open file is not scanned twice. On the unit-test path (no `home`) it stays in
    /// open-buffer mode, exactly like collectHandlerLocations.
    fn collectSymbolTargets(
        self: *Handler,
        arena: std.mem.Allocator,
        base_uri: []const u8,
        base_source: []const u8,
        out: *std.ArrayList(SymTarget),
    ) !void {
        var seen = std.StringHashMap(void).init(arena);

        var it = self.files.iterator();
        while (it.next()) |entry| {
            const p = resolve.uriToPath(arena, entry.key_ptr.*) catch entry.key_ptr.*;
            if (seen.contains(p)) continue;
            try seen.put(p, {});
            try out.append(arena, .{ .uri = entry.key_ptr.*, .source = entry.value_ptr.* });
        }

        const home = self.home orelse return;
        const base_path = resolve.uriToPath(arena, base_uri) catch return;

        var work = std.ArrayList([]const u8).empty;
        var bp = parser.Parser.init(arena, base_source, base_path, false) catch return;
        defer bp.deinit();
        const bprog = bp.parseProgram() catch return;
        for (bprog.declarations) |d| {
            if (d != .import_decl) continue;
            if (std.mem.eql(u8, d.import_decl.module, "bytes")) continue;
            if (resolve.resolveImport(arena, self.io, base_path, d.import_decl.module, home)) |rp| {
                work.append(arena, rp) catch {};
            }
        }
        if (resolve.projectEntry(arena, self.io, base_path)) |entry| {
            if (!seen.contains(entry)) work.append(arena, entry) catch {};
        }

        var loaded: usize = 0;
        while (work.pop()) |path| {
            if (seen.contains(path)) continue;
            try seen.put(path, {});
            loaded += 1;
            if (loaded > 4000) break;

            const fsrc = Io.Dir.readFileAlloc(.cwd(), self.io, path, arena, .unlimited) catch continue;
            const furi = resolve.pathToUri(arena, path) catch path;
            try out.append(arena, .{ .uri = furi, .source = fsrc });

            var fp = parser.Parser.init(arena, fsrc, path, false) catch continue;
            defer fp.deinit();
            const fprog = fp.parseProgram() catch continue;
            for (fprog.declarations) |fd| {
                if (fd != .import_decl) continue;
                if (std.mem.eql(u8, fd.import_decl.module, "bytes")) continue;
                if (resolve.resolveImport(arena, self.io, path, fd.import_decl.module, home)) |rp| {
                    if (!seen.contains(rp)) work.append(arena, rp) catch {};
                }
            }
        }
    }

    /// Collect whole-word ranges of `word` in `source`, but when `exclude_locals` is set, SKIP any
    /// occurrence that binds to a function-LOCAL of the same name (a parameter or `let`/`const`). This is
    /// what makes renaming a global / type / field NOT clobber an unrelated same-named local in some
    /// function, and vice versa (a local rename already goes through localBindingScope). The file is parsed
    /// once and the enclosing-function locals are consulted per candidate via the analysis pass -- no
    /// re-parse per match. Full type-based disambiguation of a method on an unrelated type is out of scope
    /// here (it needs receiver-type resolution); this closes the local/global shadowing case.
    fn collectSemanticRanges(
        self: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        source: []const u8,
        word: []const u8,
        exclude_locals: bool,
        member_type: ?[]const u8,
        out: *std.ArrayList(types.Range),
    ) !void {
        if (word.len == 0) return;

        // Parse (cached) for the shadowing check and receiver-type disambiguation; if it fails to parse,
        // fall back to plain textual matches.
        const program_opt: ?ast.Program = if (exclude_locals or member_type != null) self.programFor(uri, source) else null;

        var i: usize = 0;
        while (i < source.len) {
            const c = source[i];
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i = @min(i + 2, source.len);
                continue;
            }
            if (c == '"' or c == '`' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < source.len and source[i] != quote) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                continue;
            }
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
                if (std.mem.eql(u8, source[start..i], word)) {
                    var skip = false;
                    if (exclude_locals) {
                        if (program_opt) |program| {
                            if (analysis.enclosingFunction(program, start)) |enc| {
                                var locals = std.ArrayList(analysis.Local).empty;
                                analysis.collectLocals(arena, program, enc, start, &locals) catch {};
                                for (locals.items) |l| {
                                    if (std.mem.eql(u8, l.name, word)) {
                                        skip = true; // this occurrence binds to a shadowing local
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    // Receiver-type disambiguation: when we know the member's declaring type, attribute THIS
                    // occurrence to an owning type and skip it if that owner is provably DIFFERENT. Two shapes:
                    // a `recv.word` use resolves to `recv`'s type; a bare `word` (e.g. a `fn word` declaration
                    // or a self-scoped reference) is attributed to the top-level type whose body encloses it.
                    // We only ever remove occurrences with a KNOWN, different owner; an unknown owner is kept,
                    // so this never makes rename/references incomplete.
                    if (!skip and member_type != null) {
                        if (program_opt) |program| {
                            const owner = self.receiverTypeAt(arena, program, source, i) orelse
                                analysis.enclosingTopLevelTypeName(program, start);
                            if (owner) |o| {
                                if (!std.mem.eql(u8, o, member_type.?)) skip = true;
                            }
                        }
                    }
                    if (!skip) {
                        try out.append(arena, .{
                            .start = lsp.offsets.indexToPosition(source, start, .@"utf-16"),
                            .end = lsp.offsets.indexToPosition(source, i, .@"utf-16"),
                        });
                    }
                }
                continue;
            }
            i += 1;
        }
    }

    /// Resolve the static type of the receiver of a member access whose member name ENDS at byte offset
    /// `word_end`, i.e. for `recv.word` with the cursor/occurrence on `word`, return the type of `recv`.
    /// Reuses the completion context reader (which walks BACKWARDS over the source, so it never depends on
    /// the unreliable AST span end) and the receiver chain resolver. Returns null when the occurrence is not
    /// a member access or the receiver's type can't be determined.
    fn receiverTypeAt(self: *Handler, arena: std.mem.Allocator, program: ast.Program, source: []const u8, word_end: usize) ?[]const u8 {
        _ = self;
        const ctx = analyzeCompletionContext(arena, source, word_end);
        switch (ctx) {
            .member => |segs| {
                if (segs.len == 0) return null;
                const enc = analysis.enclosingFunction(program, word_end);
                var locals = std.ArrayList(analysis.Local).empty;
                if (enc) |e| analysis.collectLocals(arena, program, e, word_end, &locals) catch {};
                const r = analysis.resolveChain(segs, locals.items, enc, program) orelse return null;
                return r.type_name;
            },
            else => return null,
        }
    }

    /// Decide whether the symbol under the cursor is a type MEMBER (field/method) whose occurrences can be
    /// disambiguated by receiver type, and if so which type it belongs to. Two ways in: the cursor sits on a
    /// `recv.word` use (resolve `recv`'s type), or `word` is declared as a member by exactly one type
    /// (`uniqueMemberDeclaringType`). Returns null for a plain global/function/type/local, which keeps the
    /// existing textual behaviour unchanged.
    fn memberTypeForCursor(self: *Handler, arena: std.mem.Allocator, uri: []const u8, source: []const u8, index: usize, word: []const u8) ?[]const u8 {
        const program = self.programFor(uri, source) orelse return null;
        // Cursor on a `recv.word` use: the member belongs to recv's type.
        if (self.receiverTypeAt(arena, program, source, index)) |t| return t;
        // Cursor on a bare `word` inside a type body (e.g. the `fn word` declaration or a self-scoped
        // reference): the member belongs to that enclosing type, provided the type actually declares it.
        if (analysis.enclosingTopLevelTypeName(program, index)) |ty| {
            if (analysis.typeHasMember(program, ty, word)) return ty;
        }
        // Otherwise: only disambiguate if exactly one type declares this member (else stay complete).
        return analysis.uniqueMemberDeclaringType(program, word);
    }

    /// Build a Definition result pointing at `word` within `span` (the name's
    /// own range when we can find it, else the declaration start).
    fn locationResult(arena: std.mem.Allocator, source: []const u8, uri: []const u8, span: ast.Span, word: []const u8) !?types.Definition.Result {
        _ = arena;
        const range = nameRange(source, span, word);
        return .{ .definition = .{ .location = .{ .uri = uri, .range = range } } };
    }

    // ------------------------------------------------------------------
    // Type definition (jump to the TYPE of the symbol under the cursor)
    // ------------------------------------------------------------------

    pub fn @"textDocument/typeDefinition"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.TypeDefinitionParams,
    ) !?types.Definition.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        // If the cursor sits on a local whose type we inferred (`let x: Foo` or `let x = Foo{}`), jump to
        // Foo's declaration. Otherwise treat the word itself as a type name (so it also works on a type
        // used directly). Cross-file: search open buffers for the type's declaration.
        var target: []const u8 = word;
        if (self.programFor(params.textDocument.uri, source)) |program| {
            if (analysis.enclosingFunction(program, index)) |enc| {
                var locals = std.ArrayList(analysis.Local).empty;
                analysis.collectLocals(arena, program, enc, index, &locals) catch {};
                for (locals.items) |l| {
                    if (std.mem.eql(u8, l.name, word)) {
                        if (l.type_name) |tn| target = tn;
                        break;
                    }
                }
            }
        }

        var it = self.files.iterator();
        while (it.next()) |entry| {
            const fp = self.programFor(entry.key_ptr.*, entry.value_ptr.*) orelse continue;
            if (analysis.findTypeDecl(fp, target)) |td| {
                const span = switch (td) {
                    .struct_decl => |sd| sd.span,
                    .enum_decl => |ed| ed.span,
                };
                return locationResult(arena, entry.value_ptr.*, entry.key_ptr.*, span, target);
            }
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Implementation (from a trait, list the types that implement it)
    // ------------------------------------------------------------------

    pub fn @"textDocument/implementation"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.ImplementationParams,
    ) !?types.Definition.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        // Treat the word under the cursor as a trait name and gather every struct that declares
        // `impl <word>` (across open buffers plus the on-disk import closure). This covers the cursor
        // sitting on a `trait X` declaration or on the `X` in an `impl X` clause. Resolving a trait
        // method CALL back to its trait (receiver-type inference) is a future refinement.
        var locations = std.ArrayList(types.Location).empty;

        var it = self.files.iterator();
        while (it.next()) |entry| {
            const buf = entry.value_ptr.*;
            const program = self.programFor(entry.key_ptr.*, buf) orelse continue;
            for (program.declarations) |decl| {
                if (decl != .struct_decl) continue;
                const sd = decl.struct_decl;
                for (sd.impls) |ti| {
                    if (std.mem.eql(u8, ti.name, word)) {
                        try locations.append(arena, .{
                            .uri = entry.key_ptr.*,
                            .range = nameRange(buf, sd.span, sd.name),
                        });
                        break;
                    }
                }
            }
        }

        if (locations.items.len == 0) return null;
        if (locations.items.len == 1) {
            return .{ .definition = .{ .location = locations.items[0] } };
        }
        return .{ .definition = .{ .locations = try locations.toOwnedSlice(arena) } };
    }

    // ------------------------------------------------------------------
    // Signature help (parameter hints while typing a call)
    // ------------------------------------------------------------------

    pub fn @"textDocument/signatureHelp"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.SignatureHelp.Params,
    ) !?types.SignatureHelp {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);

        const call = findEnclosingCall(arena, source, index) orelse return null;
        if (call.segments.len == 0) return null;

        // Prefer the real parse; fall back to blanking the cursor's line when the
        // half-typed call breaks the file. Receiver types resolve against the
        // locals declared on earlier lines.
        const program = parseBest(arena, params.textDocument.uri, source, index) orelse return null;

        var locals = std.ArrayList(analysis.Local).empty;
        const enc = analysis.enclosingFunction(program, index);
        if (enc) |e| try analysis.collectLocals(arena, program, e, index, &locals);

        const callable = resolveCallable(program, locals.items, enc, call.segments) orelse return null;
        const owner = callable.owner;
        const fd = callable.decl;

        const label = try formatSignature(arena, fd.name, fd.params, fd.ret_type, owner);

        var infos = std.ArrayList(types.ParameterInformation).empty;
        for (fd.params) |prm| {
            const plabel = if (prm.type_name) |t|
                try std.fmt.allocPrint(arena, "{s}: {s}", .{ prm.name, try typeRefString(arena, t) })
            else
                prm.name;
            try infos.append(arena, .{ .label = .{ .string = plabel } });
        }

        const sig = types.SignatureInformation{
            .label = label,
            .documentation = try docMarkup(arena, source, fd.span.start),
            .parameters = try infos.toOwnedSlice(arena),
            .activeParameter = call.active,
        };
        const sigs = try arena.alloc(types.SignatureInformation, 1);
        sigs[0] = sig;
        return .{ .signatures = sigs, .activeSignature = 0, .activeParameter = call.active };
    }

    const CallInfo = struct {
        segments: []const []const u8,
        active: u32,
    };

    /// Locate the call whose argument list the cursor is inside: the callee's
    /// dotted name and the zero-based index of the argument being typed.
    fn findEnclosingCall(arena: std.mem.Allocator, source: []const u8, index: usize) ?CallInfo {
        var i = @min(index, source.len);
        var depth: i32 = 0;
        var commas: u32 = 0;
        var open: ?usize = null;
        while (i > 0) {
            const c = source[i - 1];
            switch (c) {
                ')', ']' => depth += 1,
                '(' => {
                    if (depth == 0) {
                        open = i - 1;
                        break;
                    }
                    depth -= 1;
                },
                '[' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => if (depth == 0) {
                    commas += 1;
                },
                ';', '{', '}' => return null, // statement boundary ,  not in a call
                else => {},
            }
            i -= 1;
        }
        const op = open orelse return null;

        // The callee is the identifier chain immediately before `(`.
        var end = op;
        while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
        var start = end;
        while (start > 0 and (isIdentChar(source[start - 1]) or source[start - 1] == '.')) start -= 1;
        const chain = std.mem.trim(u8, source[start..end], " \t");
        if (chain.len == 0) return null;

        var segs = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, chain, '.');
        while (it.next()) |seg| {
            const s = std.mem.trim(u8, seg, " \t");
            if (s.len > 0) segs.append(arena, s) catch {};
        }
        return .{ .segments = segs.toOwnedSlice(arena) catch &.{}, .active = commas };
    }

    const Callable = struct {
        decl: ast.FunctionDecl,
        owner: ?[]const u8,
    };

    /// Resolve a (possibly dotted) callee name to its declaration: a free
    /// function, or a static/instance method on a resolved receiver type.
    fn resolveCallable(program: ast.Program, locals: []const analysis.Local, enc: ?analysis.Enclosing, segments: []const []const u8) ?Callable {
        if (segments.len == 1) {
            for (program.declarations) |decl| {
                if (decl == .fn_decl and std.mem.eql(u8, decl.fn_decl.name, segments[0])) {
                    return .{ .decl = decl.fn_decl, .owner = null };
                }
            }
            return null;
        }
        // `recv.method` ,  resolve the receiver chain (all but the last segment).
        const method_name = segments[segments.len - 1];
        const recv = analysis.resolveChain(segments[0 .. segments.len - 1], locals, enc, program) orelse return null;
        const decl = analysis.findTypeDecl(program, recv.type_name) orelse return null;
        const methods = switch (decl) {
            .struct_decl => |sd| sd.methods,
            .enum_decl => |ed| ed.methods,
        };
        for (methods) |md| {
            if (std.mem.eql(u8, md.decl.name, method_name)) {
                return .{ .decl = md.decl, .owner = recv.type_name };
            }
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Document symbols (outline)
    // ------------------------------------------------------------------

    pub fn @"textDocument/documentSymbol"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DocumentSymbol.Params,
    ) !?types.DocumentSymbol.Result {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        var p = parser.Parser.init(arena, source, params.textDocument.uri, false) catch return null;
        defer p.deinit();
        const program = p.parseProgram() catch return null;

        var syms = std.ArrayList(types.DocumentSymbol).empty;
        for (program.declarations) |decl| {
            switch (decl) {
                .fn_decl => |fd| try syms.append(arena, .{
                    .name = fd.name,
                    .detail = try formatSignature(arena, fd.name, fd.params, fd.ret_type, null),
                    .kind = .Function,
                    .range = fullRange(source, fd.span),
                    .selectionRange = nameRange(source, fd.span, fd.name),
                }),
                .const_decl => |cd| try syms.append(arena, .{
                    .name = cd.name,
                    .kind = .Constant,
                    .range = fullRange(source, cd.span),
                    .selectionRange = nameRange(source, cd.span, cd.name),
                }),
                .trait_decl => |td| try syms.append(arena, .{
                    .name = td.name,
                    .kind = .Interface,
                    .range = fullRange(source, td.span),
                    .selectionRange = nameRange(source, td.span, td.name),
                }),
                .struct_decl => |sd| {
                    var children = std.ArrayList(types.DocumentSymbol).empty;
                    for (sd.fields) |f| try children.append(arena, .{
                        .name = f.name,
                        .detail = try typeRefString(arena, f.type_name),
                        .kind = .Field,
                        .range = fullRange(source, f.span),
                        .selectionRange = nameRange(source, f.span, f.name),
                    });
                    for (sd.methods) |md| try children.append(arena, .{
                        .name = md.decl.name,
                        .detail = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, sd.name),
                        .kind = if (md.is_static) .Function else .Method,
                        .range = fullRange(source, md.decl.span),
                        .selectionRange = nameRange(source, md.decl.span, md.decl.name),
                    });
                    try syms.append(arena, .{
                        .name = sd.name,
                        .kind = .Struct,
                        .range = fullRange(source, sd.span),
                        .selectionRange = nameRange(source, sd.span, sd.name),
                        .children = try children.toOwnedSlice(arena),
                    });
                },
                .enum_decl => |ed| {
                    var children = std.ArrayList(types.DocumentSymbol).empty;
                    for (ed.variants) |v| try children.append(arena, .{
                        .name = v.name,
                        .kind = .EnumMember,
                        .range = fullRange(source, v.span),
                        .selectionRange = nameRange(source, v.span, v.name),
                    });
                    for (ed.methods) |md| try children.append(arena, .{
                        .name = md.decl.name,
                        .detail = try formatSignature(arena, md.decl.name, md.decl.params, md.decl.ret_type, ed.name),
                        .kind = if (md.is_static) .Function else .Method,
                        .range = fullRange(source, md.decl.span),
                        .selectionRange = nameRange(source, md.decl.span, md.decl.name),
                    });
                    try syms.append(arena, .{
                        .name = ed.name,
                        .kind = .Enum,
                        .range = fullRange(source, ed.span),
                        .selectionRange = nameRange(source, ed.span, ed.name),
                        .children = try children.toOwnedSlice(arena),
                    });
                },
                else => {},
            }
        }
        return .{ .document_symbols = try syms.toOwnedSlice(arena) };
    }

    // ------------------------------------------------------------------
    // Find references
    // ------------------------------------------------------------------

    pub fn @"textDocument/references"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.ReferenceParams,
    ) !?[]const types.Location {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        var locs = std.ArrayList(types.Location).empty;

        // Binding-accurate for function-locals: if the cursor word is a parameter or a `let`/`const` in the
        // enclosing function, confine references to that function's extent in THIS file only, so a local
        // never picks up a same-named local elsewhere or a global.
        if (try self.localBindingScope(arena, source, params.textDocument.uri, index, word)) |scope| {
            var ranges = std.ArrayList(types.Range).empty;
            try collectWordRangesBounded(arena, source, word, scope.lo, scope.hi, &ranges);
            for (ranges.items) |r| try locs.append(arena, .{ .uri = params.textDocument.uri, .range = r });
            return try locs.toOwnedSlice(arena);
        }

        // Otherwise (globals, types, functions, fields, methods): scan the whole project -- open buffers AND
        // the on-disk import closure, not just open files -- for string/comment-aware whole-word matches,
        // skipping occurrences that bind to a shadowing local of the same name (see collectSemanticRanges).
        const member_type = self.memberTypeForCursor(arena, params.textDocument.uri, source, index, word);
        var targets = std.ArrayList(SymTarget).empty;
        try self.collectSymbolTargets(arena, params.textDocument.uri, source, &targets);
        for (targets.items) |t| {
            var ranges = std.ArrayList(types.Range).empty;
            try self.collectSemanticRanges(arena, t.uri, t.source, word, true, member_type, &ranges);
            for (ranges.items) |r| try locs.append(arena, .{ .uri = t.uri, .range = r });
        }
        return try locs.toOwnedSlice(arena);
    }

    // ------------------------------------------------------------------
    // Document highlight (all occurrences of the symbol under the cursor, THIS file)
    // ------------------------------------------------------------------

    pub fn @"textDocument/documentHighlight"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.DocumentHighlightParams,
    ) !?[]const types.DocumentHighlight {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        var ranges = std.ArrayList(types.Range).empty;
        // Highlight is single-file: a local is confined to its function; anything else is the whole file,
        // minus occurrences that bind to a shadowing local of the same name (same rule as references).
        if (try self.localBindingScope(arena, source, params.textDocument.uri, index, word)) |scope| {
            try collectWordRangesBounded(arena, source, word, scope.lo, scope.hi, &ranges);
        } else {
            const member_type = self.memberTypeForCursor(arena, params.textDocument.uri, source, index, word);
            try self.collectSemanticRanges(arena, params.textDocument.uri, source, word, true, member_type, &ranges);
        }

        var hi = std.ArrayList(types.DocumentHighlight).empty;
        for (ranges.items) |r| try hi.append(arena, .{ .range = r });
        return try hi.toOwnedSlice(arena);
    }

    // ------------------------------------------------------------------
    // Folding ranges (fold every brace-delimited block spanning >1 line)
    // ------------------------------------------------------------------

    pub fn @"textDocument/foldingRange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.FoldingRangeParams,
    ) !?[]const types.FoldingRange {
        const source = self.files.get(params.textDocument.uri) orelse return null;

        var out = std.ArrayList(types.FoldingRange).empty;
        var stack = std.ArrayList(u32).empty; // start LINE of each open brace
        defer stack.deinit(arena);

        var i: usize = 0;
        while (i < source.len) {
            const c = source[i];
            // Skip comments and string/char/template literals so a `{` inside them never opens a fold.
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i = @min(i + 2, source.len);
                continue;
            }
            if (c == '"' or c == '`' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < source.len and source[i] != quote) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                continue;
            }
            if (c == '{') {
                const line = lsp.offsets.indexToPosition(source, i, self.offset_encoding).line;
                try stack.append(arena, line);
            } else if (c == '}') {
                if (stack.pop()) |start_line| {
                    const end_line = lsp.offsets.indexToPosition(source, i, self.offset_encoding).line;
                    // Fold from the `{` line to the line BEFORE the `}` so the closing brace stays visible,
                    // and only when the block actually spans more than one line.
                    if (end_line > start_line) {
                        try out.append(arena, .{ .startLine = start_line, .endLine = end_line - 1 });
                    }
                }
            }
            i += 1;
        }
        return try out.toOwnedSlice(arena);
    }

    // ------------------------------------------------------------------
    // Rename (+ prepareRename)
    // ------------------------------------------------------------------

    pub fn @"textDocument/prepareRename"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.PrepareRenameParams,
    ) !?types.PrepareRenameResult {
        _ = arena;
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const r = self.wordRangeAt(source, index) orelse return null;
        return .{ .range = r };
    }

    pub fn @"textDocument/rename"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.RenameParams,
    ) !?types.WorkspaceEdit {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const index = lsp.offsets.positionToIndex(source, params.position, self.offset_encoding);
        const word = getWordAtIndex(source, index) orelse return null;

        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};

        // Binding-accurate for function-locals: rename only within the enclosing function's extent in this
        // file, matching the references handler. A local rename must not spill into another scope.
        if (try self.localBindingScope(arena, source, params.textDocument.uri, index, word)) |scope| {
            var ranges = std.ArrayList(types.Range).empty;
            try collectWordRangesBounded(arena, source, word, scope.lo, scope.hi, &ranges);
            if (ranges.items.len == 0) return null;
            var edits = try arena.alloc(types.TextEdit, ranges.items.len);
            for (ranges.items, 0..) |r, i| edits[i] = .{ .range = r, .newText = params.newName };
            try changes.map.put(arena, params.textDocument.uri, edits);
            return .{ .changes = changes };
        }

        // Otherwise: one TextEdit per whole-word occurrence across the WHOLE PROJECT (open buffers + the
        // on-disk import closure), skipping occurrences that bind to a shadowing local of the same name, so
        // a global/type/field rename neither misses on-disk references nor clobbers an unrelated local.
        const member_type = self.memberTypeForCursor(arena, params.textDocument.uri, source, index, word);
        var targets = std.ArrayList(SymTarget).empty;
        try self.collectSymbolTargets(arena, params.textDocument.uri, source, &targets);
        for (targets.items) |t| {
            var ranges = std.ArrayList(types.Range).empty;
            try self.collectSemanticRanges(arena, t.uri, t.source, word, true, member_type, &ranges);
            if (ranges.items.len == 0) continue;
            var edits = try arena.alloc(types.TextEdit, ranges.items.len);
            for (ranges.items, 0..) |r, i| edits[i] = .{ .range = r, .newText = params.newName };
            try changes.map.put(arena, t.uri, edits);
        }
        if (changes.map.count() == 0) return null;
        return .{ .changes = changes };
    }

    // ------------------------------------------------------------------
    // Code actions (quick fixes off published diagnostics)
    // ------------------------------------------------------------------

    pub fn @"textDocument/codeAction"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.CodeActionParams,
    ) !?[]const types.CodeAction.Result {
        const uri = params.textDocument.uri;
        const source = self.files.get(uri);
        var actions = std.ArrayList(types.CodeAction.Result).empty;

        for (params.context.diagnostics) |diag| {
            // An async call used without `await`/`spawn`. The checker's message
            // spells out both fixes, and both are a safe insertion at the call
            // start, so offer them as two quick fixes.
            if (std.mem.indexOf(u8, diag.message, "await'ed") != null) {
                try actions.append(arena, self.insertActionFor(arena, uri, diag.range, "await ", "Add 'await' to the async call", true) catch continue);
                try actions.append(arena, self.insertActionFor(arena, uri, diag.range, "spawn ", "Run the async call with 'spawn'", false) catch continue);
            }
            // The 128-bit integer types were removed; the checker names both replacements. The checker's
            // span for a rejected type points at the enclosing declaration start, NOT the offending token,
            // so we cannot replace `diag.range` blindly (that would clobber `fn`/`let`). Re-locate the
            // actual `i128`/`u128` token in the buffer at or after the diagnostic start and replace THAT.
            if (std.mem.indexOf(u8, diag.message, "128-bit integer' was removed") != null) {
                if (source) |src| {
                    const from = lsp.offsets.positionToIndex(src, diag.range.start, self.offset_encoding);
                    const tok_range = self.findTokenRange(src, from, "i128") orelse
                        self.findTokenRange(src, from, "u128");
                    if (tok_range) |r| {
                        try actions.append(arena, self.replaceActionFor(arena, uri, r, "long", "Replace with 'long'", true) catch continue);
                        try actions.append(arena, self.replaceActionFor(arena, uri, r, "i64", "Replace with 'i64'", false) catch continue);
                    }
                }
            }
        }
        return try actions.toOwnedSlice(arena);
    }

    /// Find the first whole-word occurrence of `needle` in `source` at or after `from`, and return its LSP
    /// range. Whole-word means the characters on either side are not identifier characters, so `i128` does
    /// not match inside `mi128x`. Returns null if not found. Used to re-anchor a quick fix on the real
    /// offending token when the checker's diagnostic span is coarser than the token.
    fn findTokenRange(self: *Handler, source: []const u8, from: usize, needle: []const u8) ?types.Range {
        var i = @min(from, source.len);
        while (std.mem.indexOfPos(u8, source, i, needle)) |pos| {
            const before_ok = pos == 0 or !isIdentChar(source[pos - 1]);
            const after = pos + needle.len;
            const after_ok = after >= source.len or !isIdentChar(source[after]);
            if (before_ok and after_ok) {
                return .{
                    .start = lsp.offsets.indexToPosition(source, pos, self.offset_encoding),
                    .end = lsp.offsets.indexToPosition(source, after, self.offset_encoding),
                };
            }
            i = pos + 1;
        }
        return null;
    }

    /// Build a quick-fix CodeAction that REPLACES `range` with `text`.
    fn replaceActionFor(
        self: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        range: types.Range,
        text: []const u8,
        title: []const u8,
        preferred: bool,
    ) !types.CodeAction.Result {
        _ = self;
        const edits = try arena.alloc(types.TextEdit, 1);
        edits[0] = .{ .range = range, .newText = text };
        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
        try changes.map.put(arena, uri, edits);
        return .{ .code_action = .{
            .title = title,
            .kind = .quickfix,
            .isPreferred = preferred,
            .edit = .{ .changes = changes },
        } };
    }

    /// Build a quick-fix CodeAction that inserts `text` at the start of `range`.
    fn insertActionFor(
        self: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        range: types.Range,
        text: []const u8,
        title: []const u8,
        preferred: bool,
    ) !types.CodeAction.Result {
        _ = self;
        const at = types.Range{ .start = range.start, .end = range.start };
        const edits = try arena.alloc(types.TextEdit, 1);
        edits[0] = .{ .range = at, .newText = text };
        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
        try changes.map.put(arena, uri, edits);
        return .{ .code_action = .{
            .title = title,
            .kind = .quickfix,
            .isPreferred = preferred,
            .edit = .{ .changes = changes },
        } };
    }

    // ------------------------------------------------------------------
    // Semantic tokens (full document)
    // ------------------------------------------------------------------

    pub fn @"textDocument/semanticTokens/full"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.SemanticTokensParams,
    ) !?types.SemanticTokens {
        return self.semanticTokensImpl(arena, params.textDocument.uri, null);
    }

    // ------------------------------------------------------------------
    // Semantic tokens (bounded to a visible range)
    // ------------------------------------------------------------------

    pub fn @"textDocument/semanticTokens/range"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.SemanticTokensRangeParams,
    ) !?types.SemanticTokens {
        return self.semanticTokensImpl(arena, params.textDocument.uri, params.range);
    }

    /// Emit LSP semantic tokens for a document. When `limit` is set, only tokens whose start line falls
    /// inside `[limit.start.line, limit.end.line]` are emitted (the range request colours just the visible
    /// viewport); the delta encoding is still computed against the previous EMITTED token, so a partial
    /// result is self-consistent. When `limit` is null this is the whole document.
    fn semanticTokensImpl(
        self: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        limit: ?types.Range,
    ) !?types.SemanticTokens {
        const source = self.files.get(uri) orelse return null;

        // The parser lexes on init and keeps the whole token array (`p.tokens`),
        // available even when parseProgram later fails, so a half-typed file still
        // colours. A successful parse additionally seeds the type/function name
        // sets used to upgrade a bare identifier's colour.
        var p = parser.Parser.init(arena, source, uri, false) catch return null;
        defer p.deinit();

        var type_names = std.StringHashMap(void).init(arena);
        var fn_names = std.StringHashMap(void).init(arena);
        if (p.parseProgram()) |program| {
            for (program.declarations) |decl| switch (decl) {
                .struct_decl => |sd| try type_names.put(sd.name, {}),
                .enum_decl => |ed| try type_names.put(ed.name, {}),
                .trait_decl => |td| try type_names.put(td.name, {}),
                .fn_decl => |fd| try fn_names.put(fd.name, {}),
                else => {},
            };
        } else |_| {}
        const tokens = p.tokens;

        var data = std.ArrayList(u32).empty;
        var prev_line: u32 = 0;
        var prev_char: u32 = 0;
        for (tokens, 0..) |tok, i| {
            const ttype = semanticTokenType(tok, &type_names, &fn_names) orelse continue;
            if (tok.line == 0) continue;
            const line: u32 = @intCast(tok.line - 1);
            if (limit) |r| {
                if (line < r.start.line or line > r.end.line) continue;
            }
            const char: u32 = @intCast(tok.column - 1);
            const len: u32 = @intCast(tok.lexeme.len);
            if (len == 0) continue;
            // Declaration modifier (bit 0): an identifier that immediately follows a declaring keyword names
            // a new binding. The previous token is the raw lexer predecessor, so this is exact, not a
            // heuristic over spans.
            const modifiers: u32 = blk: {
                if (tok.type == .identifier and i > 0 and isDeclaringKeyword(tokens[i - 1].type)) break :blk 1;
                break :blk 0;
            };
            const d_line = line - prev_line;
            const d_char = if (d_line == 0) char - prev_char else char;
            try data.append(arena, d_line);
            try data.append(arena, d_char);
            try data.append(arena, len);
            try data.append(arena, ttype);
            try data.append(arena, modifiers);
            prev_line = line;
            prev_char = char;
        }
        return .{ .data = try data.toOwnedSlice(arena) };
    }

    // ------------------------------------------------------------------
    // Selection range (smart expand-selection: word -> brackets -> document)
    // ------------------------------------------------------------------

    pub fn @"textDocument/selectionRange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.SelectionRangeParams,
    ) !?[]const types.SelectionRange {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        var out = std.ArrayList(types.SelectionRange).empty;
        for (params.positions) |pos| {
            const index = lsp.offsets.positionToIndex(source, pos, self.offset_encoding);
            const node = try self.selectionChain(arena, source, index);
            try out.append(arena, node);
        }
        return try out.toOwnedSlice(arena);
    }

    /// Build the expand-selection hierarchy for a single cursor position: the innermost range is the
    /// identifier under the cursor (or a single character), then each enclosing bracket pair from smallest
    /// to largest, then the whole document. Strings and line comments are skipped while matching brackets
    /// so an unbalanced bracket inside a literal does not corrupt the hierarchy. Returns the INNERMOST
    /// node; its `parent` chain walks outward.
    fn selectionChain(self: *Handler, arena: std.mem.Allocator, source: []const u8, index: usize) !types.SelectionRange {
        const idx = @min(index, source.len);

        // Gather ranges from OUTERMOST to innermost so we can chain parents forward.
        var byte_ranges = std.ArrayList([2]usize).empty;
        try byte_ranges.append(arena, .{ 0, source.len }); // whole document

        // Enclosing bracket pairs, collected then sorted largest-first.
        const pairs = try enclosingBracketPairs(arena, source, idx);
        std.mem.sort([2]usize, pairs.items, {}, struct {
            fn gt(_: void, a: [2]usize, b: [2]usize) bool {
                return (a[1] - a[0]) > (b[1] - b[0]);
            }
        }.gt);
        for (pairs.items) |p| try byte_ranges.append(arena, p);

        // Innermost: the identifier under the cursor, else a single char.
        var ws = idx;
        while (ws > 0 and isIdentChar(source[ws - 1])) ws -= 1;
        var we = idx;
        while (we < source.len and isIdentChar(source[we])) we += 1;
        if (we > ws) {
            try byte_ranges.append(arena, .{ ws, we });
        } else if (idx < source.len) {
            try byte_ranges.append(arena, .{ idx, idx + 1 });
        }

        // Chain outermost -> innermost, so each node's parent is the one before it.
        var parent: ?*types.SelectionRange = null;
        for (byte_ranges.items) |br| {
            const node = try arena.create(types.SelectionRange);
            node.* = .{
                .range = .{
                    .start = lsp.offsets.indexToPosition(source, br[0], self.offset_encoding),
                    .end = lsp.offsets.indexToPosition(source, br[1], self.offset_encoding),
                },
                .parent = parent,
            };
            parent = node;
        }
        return (parent orelse return error.EmptySelection).*;
    }

    /// Return every matched bracket pair `(open, close)` (byte offsets, close exclusive-end returned as the
    /// close index) that encloses `index`, i.e. open <= index and close >= index. Skips double-quoted
    /// strings and `//` line comments so literal brackets do not desync the stack.
    fn enclosingBracketPairs(arena: std.mem.Allocator, source: []const u8, index: usize) !std.ArrayList([2]usize) {
        var stack = std.ArrayList(usize).empty;
        defer stack.deinit(arena);
        var pairs = std.ArrayList([2]usize).empty;
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '"') {
                i += 1;
                while (i < source.len and source[i] != '"') : (i += 1) {
                    if (source[i] == '\\') i += 1;
                }
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '(' or c == '[' or c == '{') {
                try stack.append(arena, i);
            } else if (c == ')' or c == ']' or c == '}') {
                if (stack.pop()) |open| {
                    if (open <= index and i >= index) try pairs.append(arena, .{ open, i + 1 });
                }
            }
        }
        return pairs;
    }

    // ------------------------------------------------------------------
    // Inlay hints (inferred `let` types shown after the binding name)
    // ------------------------------------------------------------------

    pub fn @"textDocument/inlayHint"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.InlayHintParams,
    ) !?[]const types.InlayHint {
        const source = self.files.get(params.textDocument.uri) orelse return null;
        const program = self.programFor(params.textDocument.uri, source) orelse return &.{};

        var lets = std.ArrayList(analysis.InferredLet).empty;
        try analysis.collectInferredLets(arena, program, &lets);

        var out = std.ArrayList(types.InlayHint).empty;
        for (lets.items) |il| {
            // Place the hint right after the binding name. The statement span starts at `let`/`const`, so
            // the first whole-word occurrence of the name at/after it is the binding site.
            const name_range = self.findTokenRange(source, il.span.start, il.name) orelse continue;
            // Honour the requested viewport (the client asks per visible range).
            if (name_range.end.line < params.range.start.line or name_range.end.line > params.range.end.line) continue;
            const label = try std.fmt.allocPrint(arena, ": {s}", .{il.type_name});
            try out.append(arena, .{
                .position = name_range.end,
                .label = .{ .string = label },
                .kind = .Type,
                .paddingLeft = false,
                .paddingRight = false,
            });
        }

        // Parameter-name hints. The compiler AST does not carry reliable EXPRESSION spans here (they come
        // back as 0), so hint POSITIONS are found by scanning the source for calls and their argument
        // offsets; the callee is resolved to a signature through the receiver-resolution pass. Positioning
        // stays source-driven (like rename), typing stays pass-driven.
        try self.collectParamHints(arena, program, source, params.range, &out);
        return try out.toOwnedSlice(arena);
    }

    /// Scan `source` for calls and emit a `name:` inlay hint before each argument, resolving the callee's
    /// parameter names through the receiver-resolution pass. Source-driven because expression spans are
    /// unreliable in this AST. Skips control-flow `(` (the token before it is a keyword), the noise case
    /// where the argument text already equals the parameter name, and anything past the resolved parameter
    /// count (variadic / arity mismatch).
    fn collectParamHints(
        self: *Handler,
        arena: std.mem.Allocator,
        program: ast.Program,
        source: []const u8,
        range: types.Range,
        out: *std.ArrayList(types.InlayHint),
    ) !void {
        var i: usize = 0;
        while (i < source.len) {
            const c = source[i];
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i = @min(i + 2, source.len);
                continue;
            }
            if (c == '"' or c == '`' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < source.len and source[i] != quote) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                continue;
            }
            if (c != '(') {
                i += 1;
                continue;
            }

            // `i` is a `(`. Resolve the callee chain immediately before it; skip non-calls / control words.
            const segs = calleeSegmentsBefore(arena, source, i) orelse {
                i += 1;
                continue;
            };
            const enc = analysis.enclosingFunction(program, i);
            var locals = std.ArrayList(analysis.Local).empty;
            if (enc) |e| analysis.collectLocals(arena, program, e, i, &locals) catch {};
            const sig = analysis.resolveCallSignatureFromSegments(program, locals.items, enc, segs);

            if (sig) |s| {
                var args = std.ArrayList([2]usize).empty;
                _ = topLevelArgRanges(arena, source, i, &args) catch 0;
                for (args.items, 0..) |ar, j| {
                    const pidx = s.first_arg_param + j;
                    if (pidx >= s.params.len) break; // variadic / arity mismatch: stop labelling
                    const pname = s.params[pidx].name;
                    if (pname.len == 0) continue;
                    const arg_text = std.mem.trim(u8, source[ar[0]..ar[1]], " \t\r\n");
                    if (std.mem.eql(u8, arg_text, pname)) continue; // already reads as the parameter
                    const pos = lsp.offsets.indexToPosition(source, ar[0], self.offset_encoding);
                    if (pos.line < range.start.line or pos.line > range.end.line) continue;
                    const label = try std.fmt.allocPrint(arena, "{s}:", .{pname});
                    try out.append(arena, .{
                        .position = pos,
                        .label = .{ .string = label },
                        .kind = .Parameter,
                        .paddingLeft = false,
                        .paddingRight = true,
                    });
                }
            }
            // Resume just past the `(`; nested calls in the arguments are handled by their own `(`.
            i += 1;
        }
    }

    /// The dotted callee chain immediately before the `(` at `paren`, as segments (`a.b.m(` -> {a,b,m}), or
    /// null when there is no identifier there (a grouping `(`) or the sole segment is a keyword (`if (`).
    fn calleeSegmentsBefore(arena: std.mem.Allocator, source: []const u8, paren: usize) ?[]const []const u8 {
        var end = paren;
        while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
        if (end == 0 or !isIdentChar(source[end - 1])) return null;
        var start = end;
        while (start > 0 and (isIdentChar(source[start - 1]) or source[start - 1] == '.')) start -= 1;
        const chain = std.mem.trim(u8, source[start..end], " \t");
        if (chain.len == 0) return null;

        var segs = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, chain, '.');
        while (it.next()) |seg| {
            const s = std.mem.trim(u8, seg, " \t");
            if (s.len > 0) segs.append(arena, s) catch return null;
        }
        if (segs.items.len == 0) return null;
        if (segs.items.len == 1) {
            for (analysis.keywords) |kw| if (std.mem.eql(u8, kw, segs.items[0])) return null;
        }
        return segs.toOwnedSlice(arena) catch null;
    }

    /// Given `open` = the index of a call's `(`, fill `out` with the [start, end) byte range of each
    /// top-level argument (commas at depth 0 separate them; strings and line comments are skipped) and
    /// return the index of the matching `)`. An empty argument list yields no ranges.
    fn topLevelArgRanges(arena: std.mem.Allocator, source: []const u8, open: usize, out: *std.ArrayList([2]usize)) !usize {
        var depth: i32 = 0;
        var i = open;
        var arg_start: usize = open + 1;
        var seen_nonspace = false;
        while (i < source.len) {
            const c = source[i];
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '"' or c == '`' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < source.len and source[i] != quote) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                seen_nonspace = true;
                continue;
            }
            if (c == '(' or c == '[' or c == '{') {
                depth += 1;
            } else if (c == ')' or c == ']' or c == '}') {
                depth -= 1;
                if (depth == 0) {
                    if (seen_nonspace) try out.append(arena, .{ arg_start, i });
                    return i;
                }
            } else if (c == ',' and depth == 1) {
                try out.append(arena, .{ arg_start, i });
                arg_start = i + 1;
                seen_nonspace = false;
                i += 1;
                continue;
            } else if (c != ' ' and c != '\t' and c != '\r' and c != '\n') {
                if (!seen_nonspace) arg_start = i;
                seen_nonspace = true;
            }
            i += 1;
        }
        return source.len;
    }

    /// True for the keywords that introduce a named binding; the identifier that follows one carries the
    /// `declaration` semantic-token modifier.
    fn isDeclaringKeyword(t: lexer.TokenType) bool {
        return switch (t) {
            .keyword_fn, .keyword_struct, .keyword_enum, .keyword_trait, .keyword_let, .keyword_const => true,
            else => false,
        };
    }

    /// Classify a lexer token into a semantic-token-type id (index into
    /// `semantic_token_types`), or null to leave it unhighlighted.
    fn semanticTokenType(
        tok: lexer.Token,
        type_names: *std.StringHashMap(void),
        fn_names: *std.StringHashMap(void),
    ) ?u32 {
        return switch (tok.type) {
            .identifier => blk: {
                if (type_names.contains(tok.lexeme)) break :blk 1; // type
                if (fn_names.contains(tok.lexeme)) break :blk 2; // function
                break :blk 3; // variable
            },
            .string, .template_string, .interpolated_string, .char_literal => 4, // string
            .integer, .float, .decimal => 5, // number
            .bool_true, .bool_false => 0, // keyword-like
            else => |t| if (isKeywordToken(t)) 0 else null,
        };
    }

    fn isKeywordToken(t: lexer.TokenType) bool {
        return switch (t) {
            .keyword_fn, .keyword_async, .keyword_await, .keyword_spawn, .keyword_extern,
            .keyword_struct, .keyword_class, .keyword_import, .keyword_trait, .keyword_impl,
            .keyword_return, .keyword_let, .keyword_defer, .keyword_errdefer, .keyword_break,
            .keyword_continue, .keyword_if, .keyword_else, .keyword_while, .keyword_for,
            .keyword_switch, .keyword_case, .keyword_default, .keyword_try, .keyword_catch,
            .keyword_throw, .keyword_match, .keyword_const, .keyword_export, .keyword_enum,
            .keyword_pub, .keyword_var, .keyword_union => true,
            else => false,
        };
    }

    // ------------------------------------------------------------------
    // Workspace symbols (project-wide search)
    // ------------------------------------------------------------------

    pub fn @"workspace/symbol"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: types.WorkspaceSymbolParams,
    ) !?types.WorkspaceSymbol.Result {
        var syms = std.ArrayList(types.WorkspaceSymbol).empty;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            const file_uri = entry.key_ptr.*;
            const file_source = entry.value_ptr.*;
            var p = parser.Parser.init(arena, file_source, file_uri, false) catch continue;
            defer p.deinit();
            const program = p.parseProgram() catch continue;
            for (program.declarations) |decl| {
                switch (decl) {
                    .fn_decl => |fd| try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, fd.name, .Function, fd.span, null),
                    .const_decl => |cd| try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, cd.name, .Constant, cd.span, null),
                    .trait_decl => |td| try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, td.name, .Interface, td.span, null),
                    .struct_decl => |sd| {
                        try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, sd.name, .Struct, sd.span, null);
                        for (sd.methods) |md| try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, md.decl.name, if (md.is_static) .Function else .Method, md.decl.span, sd.name);
                    },
                    .enum_decl => |ed| {
                        try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, ed.name, .Enum, ed.span, null);
                        for (ed.methods) |md| try appendWorkspaceSymbol(arena, &syms, params.query, file_uri, file_source, md.decl.name, if (md.is_static) .Function else .Method, md.decl.span, ed.name);
                    },
                    else => {},
                }
            }
        }
        return .{ .workspace_symbols = try syms.toOwnedSlice(arena) };
    }

    fn appendWorkspaceSymbol(
        arena: std.mem.Allocator,
        syms: *std.ArrayList(types.WorkspaceSymbol),
        query: []const u8,
        uri: []const u8,
        source: []const u8,
        name: []const u8,
        kind: types.SymbolKind,
        span: ast.Span,
        container: ?[]const u8,
    ) !void {
        if (!fuzzyMatch(query, name)) return;
        try syms.append(arena, .{
            .name = name,
            .kind = kind,
            .containerName = container,
            .location = .{ .location = .{ .uri = uri, .range = nameRange(source, span, name) } },
        });
    }

    /// Relaxed subsequence match (case-insensitive), the matching a workspace
    /// symbol query is meant to use. An empty query matches everything.
    fn fuzzyMatch(query: []const u8, candidate: []const u8) bool {
        if (query.len == 0) return true;
        var qi: usize = 0;
        for (candidate) |c| {
            if (qi >= query.len) break;
            if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
        }
        return qi == query.len;
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    /// The identifier range covering `index`, or null if `index` isn't on a word.
    fn wordRangeAt(self: *Handler, source: []const u8, index: usize) ?types.Range {
        if (index > source.len) return null;
        var start = index;
        while (start > 0 and isWordByte(source, start - 1)) start -= 1;
        var end = index;
        while (end < source.len and isWordByte(source, end)) end += 1;
        if (start == end) return null;
        return .{
            .start = lsp.offsets.indexToPosition(source, start, self.offset_encoding),
            .end = lsp.offsets.indexToPosition(source, end, self.offset_encoding),
        };
    }

    fn isWordByte(source: []const u8, i: usize) bool {
        const c = source[i];
        return std.ascii.isAlphanumeric(c) or c == '_' or (c == '-' and interiorHyphen(source, i));
    }

    /// Append the range of every whole-identifier occurrence of `word` in
    /// `source`, skipping matches inside string literals and comments so a rename
    /// never rewrites text or a `// foo` mention.
    fn collectWordRanges(arena: std.mem.Allocator, source: []const u8, word: []const u8, out: *std.ArrayList(types.Range)) !void {
        if (word.len == 0) return;
        var i: usize = 0;
        while (i < source.len) {
            const c = source[i];
            // Skip line comments.
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            // Skip block comments.
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i = @min(i + 2, source.len);
                continue;
            }
            // Skip string / template / char literals.
            if (c == '"' or c == '`' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < source.len and source[i] != quote) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                continue;
            }
            // Identifier run.
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
                if (std.mem.eql(u8, source[start..i], word)) {
                    try out.append(arena, .{
                        .start = lsp.offsets.indexToPosition(source, start, .@"utf-16"),
                        .end = lsp.offsets.indexToPosition(source, i, .@"utf-16"),
                    });
                }
                continue;
            }
            i += 1;
        }
    }

    /// Like collectWordRanges but only emits matches whose start byte falls in [lo, hi). Used to confine a
    /// local binding's references/rename to its enclosing function, so renaming a local `x` never touches a
    /// same-named local in another function or a global `x`.
    fn collectWordRangesBounded(arena: std.mem.Allocator, source: []const u8, word: []const u8, lo: usize, hi: usize, out: *std.ArrayList(types.Range)) !void {
        if (word.len == 0) return;
        var i: usize = lo;
        while (i < hi) {
            const c = source[i];
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i = @min(i + 2, source.len);
                continue;
            }
            if (c == '"' or c == '`' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < source.len and source[i] != quote) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                continue;
            }
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
                if (start < hi and std.mem.eql(u8, source[start..i], word)) {
                    try out.append(arena, .{
                        .start = lsp.offsets.indexToPosition(source, start, .@"utf-16"),
                        .end = lsp.offsets.indexToPosition(source, i, .@"utf-16"),
                    });
                }
                continue;
            }
            i += 1;
        }
    }

    /// Byte offset just past the matching `}` of the first `{` at or after `from`, skipping braces inside
    /// strings, char literals, and comments. `span.end` is documented unreliable, so brace-match instead to
    /// get a function's reliable extent. Returns null if no balanced body is found.
    fn braceMatchEnd(source: []const u8, from: usize) ?usize {
        var i: usize = from;
        // Advance to the opening brace.
        while (i < source.len and source[i] != '{') : (i += 1) {
            const c = source[i];
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                if (i >= source.len) return null;
            } else if (c == '"' or c == '`' or c == '\'') {
                const q = c;
                i += 1;
                while (i < source.len and source[i] != q) : (i += 1) {
                    if (source[i] == '\\') i += 1;
                }
            }
        }
        if (i >= source.len) return null;
        var depth: usize = 0;
        while (i < source.len) {
            const c = source[i];
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i = @min(i + 2, source.len);
                continue;
            }
            if (c == '"' or c == '`' or c == '\'') {
                const q = c;
                i += 1;
                while (i < source.len and source[i] != q) {
                    if (source[i] == '\\') i += 1;
                    i += 1;
                }
                i = @min(i + 1, source.len);
                continue;
            }
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
            i += 1;
        }
        return null;
    }

    /// If the word at `index` binds to a function-LOCAL (a parameter or a `let`/`const` in the enclosing
    /// function), return the [lo, hi) byte extent of that function so references/rename can be confined to
    /// it. Returns null for anything that is not a function-local -- globals, types, functions, fields,
    /// methods, enum variants -- which keep the cross-file whole-word behaviour.
    fn localBindingScope(self: *Handler, arena: std.mem.Allocator, source: []const u8, uri: []const u8, index: usize, word: []const u8) !?struct { lo: usize, hi: usize } {
        const program = self.programFor(uri, source) orelse return null;
        const enc = analysis.enclosingFunction(program, index) orelse return null;
        var locals = std.ArrayList(analysis.Local).empty;
        try analysis.collectLocals(arena, program, enc, index, &locals);
        var is_local = false;
        for (locals.items) |l| {
            if (std.mem.eql(u8, l.name, word)) {
                is_local = true;
                break;
            }
        }
        if (!is_local) return null;
        const lo = enc.decl.span.start;
        const hi = braceMatchEnd(source, lo) orelse source.len;
        return .{ .lo = lo, .hi = hi };
    }

    // A hyphen is part of a word only when it sits BETWEEN two identifier characters, so a hypermedia
    // attribute name (data-on-click, hx-get) is captured whole while a subtraction `a - b` is not.
    fn interiorHyphen(source: []const u8, i: usize) bool {
        if (i == 0 or i + 1 >= source.len) return false;
        const prev = source[i - 1];
        const next = source[i + 1];
        const ok = struct {
            fn f(c: u8) bool {
                return std.ascii.isAlphanumeric(c) or c == '_';
            }
        }.f;
        return ok(prev) and ok(next);
    }

    fn getWordAtIndex(source: []const u8, index: usize) ?[]const u8 {
        if (index > source.len) return null;

        var start = index;
        while (start > 0) {
            const c = source[start - 1];
            if (std.ascii.isAlphanumeric(c) or c == '_' or (c == '-' and interiorHyphen(source, start - 1))) {
                start -= 1;
            } else {
                break;
            }
        }

        var end = index;
        while (end < source.len) {
            const c = source[end];
            if (std.ascii.isAlphanumeric(c) or c == '_' or (c == '-' and interiorHyphen(source, end))) {
                end += 1;
            } else {
                break;
            }
        }

        if (start == end) return null;
        return source[start..end];
    }

    fn getDocComment(source: []const u8, start_offset: usize, allocator: std.mem.Allocator) !?[]const u8 {
        var idx = @min(start_offset, source.len);
        while (idx > 0 and source[idx - 1] != '\n') : (idx -= 1) {}

        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(allocator);

        var current_line_end = idx;
        while (current_line_end > 0) {
            var current_line_start = current_line_end - 1;
            while (current_line_start > 0 and source[current_line_start - 1] != '\n') : (current_line_start -= 1) {}

            const raw_line = source[current_line_start..current_line_end];
            const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "///")) {
                const doc = std.mem.trim(u8, trimmed[3..], " ");
                try lines.append(allocator, doc);
            } else {
                break;
            }
            current_line_end = current_line_start;
        }

        if (lines.items.len == 0) return null;

        var i: usize = 0;
        while (i < lines.items.len / 2) : (i += 1) {
            std.mem.swap([]const u8, &lines.items[i], &lines.items[lines.items.len - 1 - i]);
        }

        var joined = std.ArrayList(u8).empty;
        defer joined.deinit(allocator);
        for (lines.items, 0..) |line, j| {
            try joined.appendSlice(allocator, line);
            if (j + 1 < lines.items.len) {
                try joined.append(allocator, '\n');
            }
        }
        return try joined.toOwnedSlice(allocator);
    }

    /// The LSP Range covering the whole declaration span.
    fn fullRange(source: []const u8, span: ast.Span) types.Range {
        const lo = @min(span.start, source.len);
        // span.end is unreliable for the LAST declaration in a file: its body-closing token's span
        // derives from the EOF lexeme, a static "" at offset 0, so span.end comes back as 0 (i.e.
        // BEFORE span.start). An inverted range, or a selectionRange not contained in it ,  makes the
        // VS Code client reject the WHOLE documentSymbol response ("Request documentSymbol failed"),
        // which fires on every file because every file has a last declaration. Fall back to end-of-file
        // (the final declaration does run to EOF), matching how nameRange guards the same span.end.
        const hi = if (span.end > span.start) @min(span.end, source.len) else source.len;
        return .{
            .start = lsp.offsets.indexToPosition(source, lo, .@"utf-16"),
            .end = lsp.offsets.indexToPosition(source, hi, .@"utf-16"),
        };
    }

    /// The Range of `name` inside `span` (its declaration site). Falls back to a
    /// zero-width range at the span start if the name isn't found textually.
    fn nameRange(source: []const u8, span: ast.Span, name: []const u8) types.Range {
        const lo = @min(span.start, source.len);
        // span.end is unreliable for a declaration whose body-closing token is the
        // last in the file (its span derives from an EOF lexeme at offset 0). When
        // it's missing or behind the start, scan a bounded forward window from the
        // declaration start ,  the name always appears on the first line or two.
        const hi = if (span.end > span.start) @min(span.end, source.len) else @min(source.len, lo + 200);
        if (lo < hi) {
            if (std.mem.indexOfPos(u8, source[0..hi], lo, name)) |pos| {
                return .{
                    .start = lsp.offsets.indexToPosition(source, pos, .@"utf-16"),
                    .end = lsp.offsets.indexToPosition(source, pos + name.len, .@"utf-16"),
                };
            }
        }
        const p = lsp.offsets.indexToPosition(source, lo, .@"utf-16");
        return .{ .start = p, .end = p };
    }

    fn typeRefString(arena: std.mem.Allocator, tr: ast.TypeRef) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        try writeTypeRef(arena, &list, tr);
        return list.toOwnedSlice(arena);
    }

    fn writeTypeRef(arena: std.mem.Allocator, list: *std.ArrayList(u8), tr: ast.TypeRef) !void {
        switch (tr) {
            .ident => |id| try list.appendSlice(arena, id),
            .optional => |opt| {
                try writeTypeRef(arena, list, opt.*);
                try list.appendSlice(arena, "?");
            },
            .error_union => |eu| {
                try writeTypeRef(arena, list, eu.ok.*);
                try list.appendSlice(arena, " | ");
                try writeTypeRef(arena, list, eu.err.*);
            },
            .fixed_array => |fa| {
                try writeTypeRef(arena, list, fa.element.*);
                try list.appendSlice(arena, "[");
                var buf: [32]u8 = undefined;
                const len_str = try std.fmt.bufPrint(&buf, "{d}", .{fa.length});
                try list.appendSlice(arena, len_str);
                try list.appendSlice(arena, "]");
            },
            .generic => |g| {
                try list.appendSlice(arena, g.name);
                try list.appendSlice(arena, "<");
                for (g.params, 0..) |param, idx| {
                    try writeTypeRef(arena, list, param);
                    if (idx + 1 < g.params.len) try list.appendSlice(arena, ", ");
                }
                try list.appendSlice(arena, ">");
            },
            .func => |f| {
                try list.appendSlice(arena, "(");
                for (f.params, 0..) |param, idx| {
                    try writeTypeRef(arena, list, param);
                    if (idx + 1 < f.params.len) try list.appendSlice(arena, ", ");
                }
                try list.appendSlice(arena, ") -> ");
                try writeTypeRef(arena, list, f.ret.*);
            },
            .tuple => |t| {
                try list.appendSlice(arena, "(");
                for (t, 0..) |param, idx| {
                    try writeTypeRef(arena, list, param);
                    if (idx + 1 < t.len) try list.appendSlice(arena, ", ");
                }
                try list.appendSlice(arena, ")");
            },
        }
    }

    fn formatSignature(arena: std.mem.Allocator, name: []const u8, params: []const ast.Param, ret_type: ?ast.TypeRef, struct_name_opt: ?[]const u8) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(arena);

        if (struct_name_opt) |s_name| {
            try list.appendSlice(arena, "fn ");
            try list.appendSlice(arena, s_name);
            try list.appendSlice(arena, ".");
            try list.appendSlice(arena, name);
        } else {
            try list.appendSlice(arena, "fn ");
            try list.appendSlice(arena, name);
        }
        try list.appendSlice(arena, "(");
        for (params, 0..) |p, i| {
            try list.appendSlice(arena, p.name);
            if (p.type_name) |t| {
                try list.appendSlice(arena, ": ");
                try writeTypeRef(arena, &list, t);
            }
            if (i + 1 < params.len) {
                try list.appendSlice(arena, ", ");
            }
        }
        try list.appendSlice(arena, ")");
        if (ret_type) |ret| {
            try list.appendSlice(arena, ": ");
            try writeTypeRef(arena, &list, ret);
        } else {
            try list.appendSlice(arena, ": void");
        }
        return try list.toOwnedSlice(arena);
    }

    pub fn onResponse(
        _: *Handler,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        std.log.warn("received unexpected response from client with id '{?}'!", .{response.id});
    }
};

test "Hover documentation comments" {
    const allocator = std.heap.page_allocator;

    var handler = Handler{
        .allocator = allocator,
        .io = undefined,
        .transport = undefined,
        .files = .empty,
        .offset_encoding = .@"utf-16",
    };
    defer handler.deinit();

    const source =
        \\pub struct Watcher {
        \\    pub handle: i32,
        \\
        \\    /// Create a new Watcher monitoring the specified directory path.
        \\    init(path: string) {
        \\        self.handle = 123;
        \\    }
        \\
        \\    /// Wait cooperatively for the next file modification event.
        \\    /// Returns the full path of the modified/created/deleted file.
        \\    pub fn nextEvent(self: Watcher): string {
        \\        return "event";
        \\    }
        \\}
    ;

    const uri = "file:///mock.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const init_index = std.mem.indexOf(u8, source, "init").?;
    const init_pos = lsp.offsets.indexToPosition(source, init_index, handler.offset_encoding);

    const hover_params = types.Hover.Params{
        .textDocument = .{ .uri = uri },
        .position = init_pos,
    };

    const hover_res = try handler.@"textDocument/hover"(allocator, hover_params);
    try std.testing.expect(hover_res != null);

    const hover_val = hover_res.?.contents.markup_content.value;
    try std.testing.expect(std.mem.indexOf(u8, hover_val, "Create a new Watcher monitoring the specified directory path.") != null);

    const next_index = std.mem.indexOf(u8, source, "nextEvent").?;
    const next_pos = lsp.offsets.indexToPosition(source, next_index, handler.offset_encoding);

    const hover_params2 = types.Hover.Params{
        .textDocument = .{ .uri = uri },
        .position = next_pos,
    };

    const hover_res2 = try handler.@"textDocument/hover"(allocator, hover_params2);
    try std.testing.expect(hover_res2 != null);

    const hover_val2 = hover_res2.?.contents.markup_content.value;
    try std.testing.expect(std.mem.indexOf(u8, hover_val2, "Wait cooperatively for the next file modification event.") != null);
}

test "semantic diagnostics surface type-checker errors" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // Two functions of the same name in one module is a type-checker error
    // (Kyte has no overloading). The parser accepts it; the checker rejects it.
    const source =
        \\fn dup(): int { return 1; }
        \\fn dup(): int { return 2; }
    ;
    const uri = "file:///m.ky";

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = try parser.Parser.init(arena, source, uri, false);
    defer p.deinit();
    const program = try p.parseProgram();

    var diags = std.ArrayList(types.Diagnostic).empty;
    try handler.collectSemanticDiagnostics(arena, uri, source, program, &diags);

    try std.testing.expect(diags.items.len >= 1);
    var saw_dup = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "duplicate function") != null) saw_dup = true;
    }
    try std.testing.expect(saw_dup);
}

test "formatting never returns a semantically-altered edit (token-stream gate)" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // A union with single-line fields and no trailing comma: the formatter would
    // normalise it (adding a trailing comma), which is NOT token-equivalent. The
    // handler must return no edit rather than replace the buffer with altered code.
    const uri = "file:///u.ky";
    // deinit frees both key and value, so both must be allocator-owned.
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, "pub union U { pub a: int, b: int }\n"));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const params = types.DocumentFormattingParams{
        .textDocument = .{ .uri = uri },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    };
    const edits = try handler.@"textDocument/formatting"(arena, params);

    // If an edit IS returned, it must be token-equivalent to the source (the gate).
    // For this altering input the gate suppresses the edit entirely.
    if (edits) |es| {
        for (es) |e| try std.testing.expect(Handler.sameTokenStream("pub union U { pub a: int, b: int }\n", e.newText));
    }
    try std.testing.expect(edits == null);
}

test "rename edits every whole-word occurrence, skipping strings and comments" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn total(): int {
        \\    let count = 1;
        \\    // count here is a comment mention
        \\    let s = "count in a string";
        \\    return count;
        \\}
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor on the `count` binding.
    const at = std.mem.indexOf(u8, source, "count").?;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/rename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = pos,
        .newName = "amount",
    });
    try std.testing.expect(res != null);
    const edits = res.?.changes.?.map.get(uri).?;
    // The declaration and the `return count;` use, but not the comment or string.
    try std.testing.expectEqual(@as(usize, 2), edits.len);
}

test "rename of a function-local is confined to its function (binding-accurate)" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // Two functions each with their OWN local `x`. Renaming one must not touch the other.
    const source =
        \\fn a(): int {
        \\    let x = 1;
        \\    return x + x;
        \\}
        \\fn b(): int {
        \\    let x = 2;
        \\    return x;
        \\}
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor on the `x` binding inside `a` (its first occurrence).
    const at = std.mem.indexOf(u8, source, "let x").? + 4;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/rename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = pos,
        .newName = "y",
    });
    try std.testing.expect(res != null);
    const edits = res.?.changes.?.map.get(uri).?;
    // `a` has three `x` occurrences (decl + two uses); `b`'s three must be untouched.
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    // Every edit must fall before `fn b` (i.e. inside `a`).
    const b_start = std.mem.indexOf(u8, source, "fn b").?;
    const b_pos = lsp.offsets.indexToPosition(source, b_start, handler.offset_encoding);
    for (edits) |e| {
        try std.testing.expect(e.range.start.line < b_pos.line);
    }
}

test "server version is injected from build.zig.zon (no hardcoded drift)" {
    // server_version comes from the `build_options` module, which build.zig fills from build.zig.zon's
    // `.version`. So serverInfo cannot drift from the packaging version by construction; this just asserts
    // the injection produced a sane, non-empty semver-ish string.
    try std.testing.expect(server_version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, server_version, '.') != null);
}

test "rename of a global skips a shadowing local of the same name (binding-accurate)" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // A global `foo` used in `bar`, and an UNRELATED local `foo` in `baz`. Renaming the global must edit
    // the global decl + its use in bar, but NOT the local `foo` decl/use in baz.
    const source =
        \\fn foo(): int { return 1; }
        \\fn bar(): int { return foo(); }
        \\fn baz(): int {
        \\    let foo = 5;
        \\    return foo;
        \\}
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor on the global declaration `fn foo`.
    const at = std.mem.indexOf(u8, source, "fn foo").? + 3;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/rename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = pos,
        .newName = "quux",
    });
    try std.testing.expect(res != null);
    const edits = res.?.changes.?.map.get(uri).?;
    // Exactly two edits: the global decl and its use in `bar`. The two `foo` in `baz` are a shadowing
    // local and must be left alone.
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    const baz_line = lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "let foo").?, handler.offset_encoding).line;
    for (edits) |e| {
        try std.testing.expect(e.range.start.line < baz_line);
    }
}

test "rename spans every open buffer (project-wide, not just the active file)" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const a_src = "fn foo(): int { return 1; }\n";
    const b_src = "fn bar(): int { return foo(); }\n";
    const a_uri = "file:///a.ky";
    const b_uri = "file:///b.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, a_uri), try allocator.dupe(u8, a_src));
    try handler.files.put(allocator, try allocator.dupe(u8, b_uri), try allocator.dupe(u8, b_src));

    // Rename `foo` with the cursor in a.ky; the use in b.ky (a different, unopened-in-this-request file)
    // must also be edited.
    const at = std.mem.indexOf(u8, a_src, "foo").?;
    const pos = lsp.offsets.indexToPosition(a_src, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/rename"(arena, .{
        .textDocument = .{ .uri = a_uri },
        .position = pos,
        .newName = "baz",
    });
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.changes.?.map.get(a_uri) != null);
    try std.testing.expect(res.?.changes.?.map.get(b_uri) != null); // the OTHER file was edited too
}

test "parse cache reuses an unchanged buffer and reparses on change" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit(); // frees the cache arenas; the testing allocator fails the test on any leak

    const uri = "file:///m.ky";
    const src1 = "fn a(): int { return 1; }";
    const p1 = handler.programFor(uri, src1);
    try std.testing.expect(p1 != null);
    try std.testing.expectEqual(@as(usize, 1), handler.parse_cache.count());
    const fp1 = handler.parse_cache.get(uri).?.fp;

    // Same source again: still one entry, same fingerprint (a cache hit, not a reparse).
    _ = handler.programFor(uri, src1);
    try std.testing.expectEqual(@as(usize, 1), handler.parse_cache.count());
    try std.testing.expectEqual(fp1, handler.parse_cache.get(uri).?.fp);

    // Changed source: still one entry, but a new fingerprint (reparsed into the reused arena).
    const src2 = "fn a(): int { return 2; }\nfn b(): int { return 3; }";
    try std.testing.expect(handler.programFor(uri, src2) != null);
    try std.testing.expectEqual(@as(usize, 1), handler.parse_cache.count());
    try std.testing.expect(handler.parse_cache.get(uri).?.fp != fp1);

    // dropParse clears it (as didClose does).
    handler.dropParse(uri);
    try std.testing.expectEqual(@as(usize, 0), handler.parse_cache.count());
}

test "folding range folds a multi-line brace block" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn a(): int {
        \\    let x = 1;
        \\    return x;
        \\}
        \\fn b(): int { return 2; }
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/foldingRange"(arena, .{ .textDocument = .{ .uri = uri } });
    try std.testing.expect(res != null);
    // `a` spans lines 0..3 -> one fold (0 -> 2); `b` is single-line -> no fold.
    try std.testing.expectEqual(@as(usize, 1), res.?.len);
    try std.testing.expectEqual(@as(u32, 0), res.?[0].startLine);
    try std.testing.expectEqual(@as(u32, 2), res.?[0].endLine);
}

test "document highlight marks the symbol's occurrences in the file" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn foo(): int { return 1; }
        \\fn bar(): int { return foo() + foo(); }
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const at = std.mem.indexOf(u8, source, "fn foo").? + 3;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/documentHighlight"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    });
    try std.testing.expect(res != null);
    // decl + two uses = 3 highlights.
    try std.testing.expectEqual(@as(usize, 3), res.?.len);
}

test "workspace symbol fuzzy-matches declarations" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\struct HttpServer { pub port: int }
        \\fn handleRequest() {}
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"workspace/symbol"(arena, .{ .query = "hs" });
    try std.testing.expect(res != null);
    var saw_server = false;
    for (res.?.workspace_symbols) |s| {
        if (std.mem.eql(u8, s.name, "HttpServer")) saw_server = true;
    }
    try std.testing.expect(saw_server);
}

test "member completion resolves receiver type" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\struct Conn {
        \\    pub host: string,
        \\    pub port: int,
        \\    pub fn ping(self: Conn): bool { return true; }
        \\}
        \\
        \\fn use() {
        \\    let c = Conn{ host: "a", port: 1 };
        \\    c.
        \\}
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const dot = std.mem.indexOf(u8, source, "c.").? + 2;
    const pos = lsp.offsets.indexToPosition(source, dot, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/completion"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    const items = res.?.completion_items;

    var saw_host = false;
    var saw_ping = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "host")) saw_host = true;
        if (std.mem.eql(u8, it.label, "ping")) saw_ping = true;
    }
    try std.testing.expect(saw_host);
    try std.testing.expect(saw_ping);
}

test "identifier completion offers top-level symbols and locals" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn helper(): int { return 1; }
        \\
        \\fn main() {
        \\    let total = 0;
        \\    t
        \\}
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const at = std.mem.indexOf(u8, source, "    t\n").? + 5;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/completion"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);

    var saw_helper = false;
    var saw_total = false;
    for (res.?.completion_items) |it| {
        if (std.mem.eql(u8, it.label, "helper")) saw_helper = true;
        if (std.mem.eql(u8, it.label, "total")) saw_total = true;
    }
    try std.testing.expect(saw_helper);
    try std.testing.expect(saw_total);
}

test "signature help reports params and active index" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn add(a: int, b: int): int { return a + b; }
        \\fn main() { let s = add(1, 2); }
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor after the comma → second argument (active index 1).
    const comma = std.mem.indexOf(u8, source, "add(1, 2)").? + 6;
    const pos = lsp.offsets.indexToPosition(source, comma, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/signatureHelp"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    try std.testing.expectEqual(@as(usize, 1), res.?.signatures.len);
    const sig = res.?.signatures[0];
    try std.testing.expect(std.mem.indexOf(u8, sig.label, "fn add(a: int, b: int): int") != null);
    try std.testing.expectEqual(@as(usize, 2), sig.parameters.?.len);
    try std.testing.expectEqual(@as(u32, 1), res.?.activeParameter.?);
}

test "go to definition finds a function span" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn target(): int { return 42; }
        \\fn caller() { let x = target(); }
    ;
    const uri = "file:///m.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    const use = std.mem.indexOf(u8, source, "target()").?;
    const pos = lsp.offsets.indexToPosition(source, use + 1, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/definition"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    const loc = res.?.definition.location;
    // The definition is the `target` on line 0, not the call on line 1.
    try std.testing.expectEqual(@as(u32, 0), loc.range.start.line);
}

test "go to definition on a command type also surfaces its RequestHandler" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // The command and its route live in one file; the handler in another. Both
    // are open buffers (home is null in tests, so only the open-buffer path runs).
    const main_src =
        \\struct Register { email: string, init() { self.email = ""; } }
        \\fn build(app: App) { app.post<Register>("/register"); }
    ;
    const handler_src =
        \\struct RegisterHandler impl RequestHandler<Register, Response> {
        \\    init() {}
        \\    async fn handle(self: RegisterHandler, c: Register): Response { return ok(); }
        \\}
    ;
    const main_uri = "file:///main.ky";
    const handler_uri = "file:///handler.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, main_uri), try allocator.dupe(u8, main_src));
    try handler.files.put(allocator, try allocator.dupe(u8, handler_uri), try allocator.dupe(u8, handler_src));

    // Cursor on `Register` inside the route `app.post<Register>`.
    const at = std.mem.indexOf(u8, main_src, "post<Register>").? + "post<".len;
    const pos = lsp.offsets.indexToPosition(main_src, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/definition"(arena, .{ .textDocument = .{ .uri = main_uri }, .position = pos });
    try std.testing.expect(res != null);
    // Multiple results: the command definition plus the handler that serves it.
    const locs = res.?.definition.locations;
    try std.testing.expect(locs.len >= 2);
    var saw_handler = false;
    for (locs) |l| {
        if (std.mem.eql(u8, l.uri, handler_uri)) saw_handler = true;
    }
    try std.testing.expect(saw_handler);
}

test "type definition jumps from a typed local to its type declaration" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // `u`'s type is `User`; the cursor on `u` should land on the `User` struct decl (line 1),
    // not on the `let u` binding on line 2.
    const source =
        \\
        \\struct User { name: string, init() { self.name = ""; } }
        \\fn make(): User { let u: User = User{}; return u; }
    ;
    const uri = "file:///t.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor on the `u` in `return u`.
    const at = std.mem.indexOf(u8, source, "return u").? + "return ".len;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/typeDefinition"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    const loc = res.?.definition.location;
    try std.testing.expectEqual(@as(u32, 1), loc.range.start.line);
}

test "implementation lists the types that implement a trait" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // Two structs implement `Greeter`; a third does not. Placing the cursor on the trait name in an
    // `impl Greeter` clause should list exactly the two implementors.
    const source =
        \\struct English impl Greeter { init() {} fn hi(self: English): string { return "hi"; } }
        \\struct Hindi impl Greeter { init() {} fn hi(self: Hindi): string { return "namaste"; } }
        \\struct Loner { init() {} }
    ;
    const uri = "file:///impl.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    // Cursor on the `Greeter` in `English impl Greeter`.
    const at = std.mem.indexOf(u8, source, "impl Greeter").? + "impl ".len;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handler.@"textDocument/implementation"(arena, .{ .textDocument = .{ .uri = uri }, .position = pos });
    try std.testing.expect(res != null);
    const locs = res.?.definition.locations;
    try std.testing.expectEqual(@as(usize, 2), locs.len);
}

test "code action fix for a removed type resolves the diagnostic when applied" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const uri = "file:///fix.ky";
    var source: []const u8 = "fn f(x: i128): int { return 0; }\n";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1) The real checker flags the removed 128-bit type.
    var p1 = try parser.Parser.init(arena, source, uri, false);
    const prog1 = try p1.parseProgram();
    var diags = std.ArrayList(types.Diagnostic).empty;
    try handler.collectSemanticDiagnostics(arena, uri, source, prog1, &diags);
    p1.deinit();

    var target_diag: ?types.Diagnostic = null;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "128-bit integer' was removed") != null) target_diag = d;
    }
    try std.testing.expect(target_diag != null);

    // 2) codeAction offers a fix for that diagnostic.
    const one = try arena.alloc(types.Diagnostic, 1);
    one[0] = target_diag.?;
    const actions = (try handler.@"textDocument/codeAction"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = target_diag.?.range,
        .context = .{ .diagnostics = one },
    })).?;
    try std.testing.expect(actions.len >= 1);

    // 3) Apply the first fix's edit ("Replace with 'long'") to the buffer.
    const edit = actions[0].code_action.edit.?;
    const edits = edit.changes.?.map.get(uri).?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    const te = edits[0];
    const s = lsp.offsets.positionToIndex(source, te.range.start, handler.offset_encoding);
    const e = lsp.offsets.positionToIndex(source, te.range.end, handler.offset_encoding);
    const fixed = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ source[0..s], te.newText, source[e..] });

    // 4) The removed-type diagnostic is gone from the fixed buffer.
    var p2 = try parser.Parser.init(arena, fixed, uri, false);
    const prog2 = try p2.parseProgram();
    var diags2 = std.ArrayList(types.Diagnostic).empty;
    try handler.collectSemanticDiagnostics(arena, uri, fixed, prog2, &diags2);
    p2.deinit();
    for (diags2.items) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.message, "128-bit integer' was removed") == null);
    }
    source = fixed; // silence unused-reassign
    _ = &source;
}

test "selection range expands from the identifier out through brackets to the document" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source = "fn f() { let y = g(abc); }\n";
    const uri = "file:///sel.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cursor inside the identifier `abc`.
    const at = std.mem.indexOf(u8, source, "abc").? + 1;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    const res = (try handler.@"textDocument/selectionRange"(arena, .{
        .textDocument = .{ .uri = uri },
        .positions = &.{pos},
    })).?;
    try std.testing.expectEqual(@as(usize, 1), res.len);

    // Innermost range is exactly `abc`.
    const inner = res[0];
    const s0 = lsp.offsets.positionToIndex(source, inner.range.start, handler.offset_encoding);
    const e0 = lsp.offsets.positionToIndex(source, inner.range.end, handler.offset_encoding);
    try std.testing.expectEqualStrings("abc", source[s0..e0]);

    // Each parent must strictly contain its child, and the outermost is the whole document.
    var node: ?*const types.SelectionRange = &inner;
    var last: types.SelectionRange = inner;
    var prev_s: usize = s0;
    var prev_e: usize = e0;
    while (node) |n| {
        const ns = lsp.offsets.positionToIndex(source, n.range.start, handler.offset_encoding);
        const ne = lsp.offsets.positionToIndex(source, n.range.end, handler.offset_encoding);
        try std.testing.expect(ns <= prev_s and ne >= prev_e);
        prev_s = ns;
        prev_e = ne;
        last = n.*;
        node = n.parent;
    }
    // The outermost node spans the whole document.
    const os = lsp.offsets.positionToIndex(source, last.range.start, handler.offset_encoding);
    const oe = lsp.offsets.positionToIndex(source, last.range.end, handler.offset_encoding);
    try std.testing.expectEqual(@as(usize, 0), os);
    try std.testing.expectEqual(source.len, oe);
}

test "semantic tokens range emits only tokens inside the requested line span" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    const source =
        \\fn a(): int { return 1; }
        \\fn b(): int { return 2; }
        \\fn c(): int { return 3; }
    ;
    const uri = "file:///st.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const full = (try handler.@"textDocument/semanticTokens/full"(arena, .{ .textDocument = .{ .uri = uri } })).?;
    // Restrict to the middle line only (line index 1).
    const ranged = (try handler.@"textDocument/semanticTokens/range"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 100 } },
    })).?;

    // Both are 5-int-per-token streams; the ranged result must be strictly smaller (one line vs three).
    try std.testing.expect(ranged.data.len > 0);
    try std.testing.expect(ranged.data.len < full.data.len);
    try std.testing.expectEqual(@as(usize, 0), ranged.data.len % 5);
}

test "completion item resolve returns the item unchanged" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const item = CItem{ .label = "foo", .detail = "fn foo(): int" };
    const out = try handler.@"completionItem/resolve"(arena, item);
    try std.testing.expectEqualStrings("foo", out.label);
    try std.testing.expectEqualStrings("fn foo(): int", out.detail.?);
}

test "inlay hint shows the inferred type of an annotation-free let" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // `p` is inferred from a struct literal; `n` has an explicit annotation and must get NO hint.
    const source =
        \\struct Point { x: int, init() { self.x = 0; } }
        \\fn f() { let p = Point{}; let n: int = 3; }
    ;
    const uri = "file:///inlay.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hints = (try handler.@"textDocument/inlayHint"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 100, .character = 0 } },
    })).?;

    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings(": Point", hints[0].label.string);
    // The hint sits right after `p` (the binding name on line 1).
    try std.testing.expectEqual(@as(u32, 1), hints[0].position.line);
}

test "semantic tokens set the declaration modifier on a binding name but not a use" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // `greeter` (length 7, no same-length collision with keywords/types here) is declared after `fn`, then
    // used; the declaration token must carry modifier bit 0, the use must not.
    const source = "fn greeter(): bool { return true; }\nfn caller(): bool { return greeter(); }\n";
    const uri = "file:///mod.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const st = (try handler.@"textDocument/semanticTokens/full"(arena, .{ .textDocument = .{ .uri = uri } })).?;

    // Decode the delta stream into absolute (line, char, len, type, mods) and inspect the two `greeter`
    // tokens (length 7).
    var line: u32 = 0;
    var char: u32 = 0;
    var decl_mod: ?u32 = null;
    var use_mod: ?u32 = null;
    var idx: usize = 0;
    while (idx + 5 <= st.data.len) : (idx += 5) {
        const d_line = st.data[idx];
        const d_char = st.data[idx + 1];
        if (d_line != 0) {
            line += d_line;
            char = d_char;
        } else {
            char += d_char;
        }
        const mods = st.data[idx + 4];
        if (st.data[idx + 2] == 7) {
            if (line == 0) decl_mod = mods else if (line == 1) use_mod = mods;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), decl_mod.?); // declaration bit set
    try std.testing.expectEqual(@as(u32, 0), use_mod.?); // plain use
}

test "rename of a method disambiguates by receiver type (unrelated same-named method untouched)" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // Both A and B declare `save`. Renaming `a.save` (a: A) must edit A's declaration and the `a.save`
    // use only, never B's declaration nor the `b.save` use.
    const source =
        \\struct A { init() {} fn save(self: A): int { return 1; } }
        \\struct B { init() {} fn save(self: B): int { return 2; } }
        \\fn run(): int { let a = A{}; let b = B{}; return a.save() + b.save(); }
    ;
    const uri = "file:///rn.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cursor on the `save` in `a.save()`.
    const at = std.mem.indexOf(u8, source, "a.save").? + "a.".len;
    const pos = lsp.offsets.indexToPosition(source, at, handler.offset_encoding);

    const edit = (try handler.@"textDocument/rename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = pos,
        .newName = "store",
    })).?;
    const edits = edit.changes.?.map.get(uri).?;

    // Exactly two edits: A's `fn save` declaration and the `a.save` use. Not B's.
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    // Both edits must fall on line 0 (A's decl) or line 2's `a.save`, never line 1 (B's decl) or the
    // `b.save` use.
    const b_decl_line = lsp.offsets.indexToPosition(source, std.mem.indexOf(u8, source, "struct B").?, handler.offset_encoding).line;
    const b_use_off = std.mem.indexOf(u8, source, "b.save").?;
    const b_use_pos = lsp.offsets.indexToPosition(source, b_use_off, handler.offset_encoding);
    for (edits) |e| {
        try std.testing.expect(e.range.start.line != b_decl_line);
        // not the b.save use position (line 2, but a different character than a.save)
        const same_line = e.range.start.line == b_use_pos.line;
        const at_b_use = same_line and e.range.start.character >= b_use_pos.character;
        try std.testing.expect(!at_b_use);
    }
}

test "inlay hints label call arguments with parameter names (via the receiver pass)" {
    const allocator = std.testing.allocator;
    var handler = Handler.init(allocator, undefined, undefined);
    defer handler.deinit();

    // `a.send(...)` is an instance method call: the receiver `a` resolves to Api, its method `send` is
    // found, and its non-self params (host, port) label the two arguments. `self` is skipped.
    const source =
        \\struct Api { init() {} fn send(self: Api, host: string, port: int): int { return 0; } }
        \\fn run(): int { let a = Api{}; return a.send("localhost", 8080); }
    ;
    const uri = "file:///ph.ky";
    try handler.files.put(allocator, try allocator.dupe(u8, uri), try allocator.dupe(u8, source));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hints = (try handler.@"textDocument/inlayHint"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 100, .character = 0 } },
    })).?;

    var saw_host = false;
    var saw_port = false;
    for (hints) |h| {
        if (std.mem.eql(u8, h.label.string, "host:")) {
            saw_host = true;
            try std.testing.expectEqual(types.InlayHintKind.Parameter, h.kind.?);
        }
        if (std.mem.eql(u8, h.label.string, "port:")) saw_port = true;
    }
    try std.testing.expect(saw_host);
    try std.testing.expect(saw_port);
}

test "uniqueMemberDeclaringType is null for an ambiguous or non-member name" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\struct A { x: int, init() {} fn only(self: A): int { return 1; } }
        \\struct B { init() {} fn shared(self: B): int { return 2; } }
        \\struct C { init() {} fn shared(self: C): int { return 3; } }
        \\fn free(): int { return 0; }
    ;
    var p = try parser.Parser.init(arena, src, "file:///u.ky", false);
    defer p.deinit();
    const program = try p.parseProgram();

    // `only` is a member of exactly one type -> A.
    try std.testing.expectEqualStrings("A", analysis.uniqueMemberDeclaringType(program, "only").?);
    // `shared` is declared by B and C -> ambiguous -> null.
    try std.testing.expect(analysis.uniqueMemberDeclaringType(program, "shared") == null);
    // `free` is a top-level function -> not a member -> null.
    try std.testing.expect(analysis.uniqueMemberDeclaringType(program, "free") == null);
}
