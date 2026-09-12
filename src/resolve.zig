//! Import resolution for the diagnostics pass.
//!
//! The single-file type checker only ever saw the open buffer, so every symbol
//! reached through an `import` (a repository's `Db`, a view's `OrderView`, a
//! `List`, a `Service` trait) looked undefined and produced a red squiggle that
//! the compiler never emits. This module maps a Kyte `import a.b.c` (stored in
//! the AST with `/` separators, e.g. `a/b/c`) to a concrete `.ky`/`.kyx` file
//! on disk, so the diagnostics pass can merge those files' declarations and run
//! the checker over the same set the real build sees.
//!
//! It is a deliberately trimmed cousin of the compiler's `resolveImportPath`
//! (in `pipeline.zig`): it covers the two cases every project hits, the standard
//! library under `~/.kyte/std` and project-relative modules, plus a best-effort
//! scan of a sibling `packages/` directory. Anything it cannot place is reported
//! as unresolved so the caller can stay conservative rather than invent an error.
//! Keeping it here (rather than importing the compiler's version) is what lets
//! kynalyzer stay a pure-Zig, LLVM-free binary.

const std = @import("std");
const Io = std.Io;

/// Convert a `file://` URI into a filesystem path, undoing `%XX` percent-escapes.
///
/// A Windows path arrives as `/C:/...`; the leading slash is dropped so the drive
/// letter leads. Anything that is not a `file://` URI (already a plain path) is
/// percent-decoded and returned as-is.
pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    var s = uri;
    if (std.mem.startsWith(u8, s, "file://")) {
        s = s["file://".len..];
        if (s.len >= 3 and s[0] == '/' and std.ascii.isAlphabetic(s[1]) and s[2] == ':') s = s[1..];
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(alloc, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(alloc, s[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Inverse of `uriToPath` for absolute paths: prepend the `file://` scheme so a
/// disk path can be handed back to the client as a `Location.uri`. Kept simple
/// (no percent-encoding, since project paths do not contain characters that need
/// escaping); a Windows drive-letter path gets the extra slash (`file:///C:/...`).
pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        return std.fmt.allocPrint(alloc, "file:///{s}", .{path});
    }
    return std.fmt.allocPrint(alloc, "file://{s}", .{path});
}

/// True if `path` names an existing regular file (or anything `statFile` can stat).
fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

/// Allocate `dir + "/" + rest + ".ky"` (and, on a second call, `.kyx`) and
/// return it if it exists on disk, else free it and return null.
fn tryFile(alloc: std.mem.Allocator, io: Io, comptime fmt: []const u8, args: anytype) ?[]u8 {
    const path = std.fmt.allocPrint(alloc, fmt, args) catch return null;
    if (exists(io, path)) return path;
    alloc.free(path);
    return null;
}

/// Map a single-segment std module with no top-level file to its real location
/// under `collections/` or `data/` (mirrors the aliases in the compiler's
/// `resolveImportPath`). Returns the slash-path to try under `std/`, or null.
fn stdAlias(module: []const u8) ?[]const u8 {
    const table = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "list", .path = "collections/list" },
        .{ .name = "map", .path = "collections/map" },
        .{ .name = "set", .path = "collections/set" },
        .{ .name = "string_builder", .path = "collections/string_builder" },
        .{ .name = "deque", .path = "collections/deque" },
        .{ .name = "heap", .path = "collections/heap" },
        .{ .name = "ordered_map", .path = "collections/ordered_map" },
        .{ .name = "db", .path = "data/db" },
        .{ .name = "pool", .path = "data/sql/pool" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, module, e.name)) return e.path;
    }
    return null;
}

/// Resolve one import `module` (a `/`-separated path) referenced from the file
/// at `base_path`, returning an owned absolute path to the backing file, or null
/// if it cannot be located. `home` is the user's home directory (for `~/.kyte`).
pub fn resolveImport(
    alloc: std.mem.Allocator,
    io: Io,
    base_path: []const u8,
    module: []const u8,
    home: ?[]const u8,
) ?[]u8 {
    // 1. Standard library under ~/.kyte/std.
    if (home) |h| {
        if (tryFile(alloc, io, "{s}/.kyte/std/{s}.ky", .{ h, module })) |p| return p;
        if (std.mem.startsWith(u8, module, "std/")) {
            if (tryFile(alloc, io, "{s}/.kyte/std/{s}.ky", .{ h, module[4..] })) |p| return p;
        }
        if (stdAlias(module)) |aliased| {
            if (tryFile(alloc, io, "{s}/.kyte/std/{s}.ky", .{ h, aliased })) |p| return p;
        }
    }

    // 2. Project-relative: walk up the directory chain from the importing file,
    //    trying `<dir>/src/<module>` then `<dir>/<module>`, as .ky then .kyx.
    const dir_end = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0;
    var cur_len = dir_end;
    while (true) {
        const cur = base_path[0..cur_len];
        if (tryFile(alloc, io, "{s}/src/{s}.ky", .{ cur, module })) |p| return p;
        if (tryFile(alloc, io, "{s}/src/{s}.kyx", .{ cur, module })) |p| return p;
        if (tryFile(alloc, io, "{s}/{s}.ky", .{ cur, module })) |p| return p;
        if (tryFile(alloc, io, "{s}/{s}.kyx", .{ cur, module })) |p| return p;

        const slash = std.mem.lastIndexOfScalar(u8, cur, '/') orelse break;
        if (slash == 0) break;
        cur_len = slash;
    }

    // 3. Best-effort: a sibling `packages/<pkg>/src/<module>` for driver/provider
    //    imports. Find the nearest ancestor holding a `packages/` directory, then
    //    scan each package's `src/` (and root) for the module file.
    if (resolveFromPackages(alloc, io, base_path, module)) |p| return p;

    return null;
}

/// Walk up from `base_path` to the nearest ancestor directory that contains a
/// `packages/` subdirectory, then look for `<pkg>/src/<module>` (or `<pkg>/<module>`)
/// under each package. Returns an owned path or null.
fn resolveFromPackages(alloc: std.mem.Allocator, io: Io, base_path: []const u8, module: []const u8) ?[]u8 {
    var cur_len = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse return null;
    while (true) {
        const cur = base_path[0..cur_len];
        const packages_dir = std.fmt.allocPrint(alloc, "{s}/packages", .{cur}) catch return null;
        defer alloc.free(packages_dir);

        if (Io.Dir.openDir(.cwd(), io, packages_dir, .{ .iterate = true })) |dir| {
            defer Io.Dir.close(dir, io);
            var it = Io.Dir.iterate(dir);
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                if (tryFile(alloc, io, "{s}/{s}/src/{s}.ky", .{ packages_dir, entry.name, module })) |p| return p;
                if (tryFile(alloc, io, "{s}/{s}/{s}.ky", .{ packages_dir, entry.name, module })) |p| return p;
            }
        } else |_| {}

        const slash = std.mem.lastIndexOfScalar(u8, cur, '/') orelse break;
        if (slash == 0) break;
        cur_len = slash;
    }
    return null;
}

/// Find the project's entry file. Walks up from the file at `base_path` looking
/// for a directory that holds a `project.json`; if found and it has a
/// `src/main.ky`, returns that path (owned). This is the root the compiler
/// compiles from, and whose transitive closure defines the whole app's symbols,
/// including framework traits (e.g. `RequestHandler`) that individual feature
/// files never import directly. Returns null if no project root is found.
pub fn projectEntry(alloc: std.mem.Allocator, io: Io, base_path: []const u8) ?[]u8 {
    var cur_len = std.mem.lastIndexOfScalar(u8, base_path, '/') orelse return null;
    while (true) {
        const cur = base_path[0..cur_len];
        const manifest = std.fmt.allocPrint(alloc, "{s}/project.json", .{cur}) catch return null;
        const has_manifest = exists(io, manifest);
        alloc.free(manifest);
        if (has_manifest) {
            if (tryFile(alloc, io, "{s}/src/main.ky", .{cur})) |p| return p;
            return null; // project root found but no conventional entry
        }
        const slash = std.mem.lastIndexOfScalar(u8, cur, '/') orelse break;
        if (slash == 0) break;
        cur_len = slash;
    }
    return null;
}

/// Whether `message` is one of the cross-module diagnostics that a single-file
/// or partially-resolved view cannot trust: it names a type or trait that a
/// module we failed to load might well define. The caller suppresses these only
/// when an import went unresolved, so genuine typos in fully-resolved files still
/// surface.
pub fn isCrossModuleDiag(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "unknown type '") or
        std.mem.indexOf(u8, message, "implements undefined trait") != null;
}

// -------------------------------------------------------------------------------------------------
// Tests (pure, io-free): URI <-> path mapping, percent-decoding, and the cross-module diag classifier.
// resolveImport/projectEntry touch the filesystem and are exercised by the live server, not here.
// -------------------------------------------------------------------------------------------------

test "uriToPath strips the file scheme" {
    const a = std.testing.allocator;
    const p = try uriToPath(a, "file:///home/u/app/main.ky");
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/u/app/main.ky", p);
}

test "uriToPath percent-decodes escaped bytes" {
    const a = std.testing.allocator;
    const p = try uriToPath(a, "file:///home/u/my%20app/a%2Bb.ky");
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/u/my app/a+b.ky", p);
}

test "uriToPath handles a Windows drive-letter uri" {
    const a = std.testing.allocator;
    const p = try uriToPath(a, "file:///C:/src/main.ky");
    defer a.free(p);
    try std.testing.expectEqualStrings("C:/src/main.ky", p);
}

test "pathToUri round-trips a unix path" {
    const a = std.testing.allocator;
    const path = "/home/u/app/main.ky";
    const uri = try pathToUri(a, path);
    defer a.free(uri);
    try std.testing.expectEqualStrings("file:///home/u/app/main.ky", uri);
    const back = try uriToPath(a, uri);
    defer a.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "pathToUri adds the extra slash for a Windows drive path" {
    const a = std.testing.allocator;
    const uri = try pathToUri(a, "C:/src/main.ky");
    defer a.free(uri);
    try std.testing.expectEqualStrings("file:///C:/src/main.ky", uri);
}

test "isCrossModuleDiag flags only cross-module messages" {
    try std.testing.expect(isCrossModuleDiag("unknown type 'Foo'"));
    try std.testing.expect(isCrossModuleDiag("struct Bar implements undefined trait Baz"));
    try std.testing.expect(!isCrossModuleDiag("expected ';' but found '}'"));
    try std.testing.expect(!isCrossModuleDiag("unused variable 'x'"));
}
