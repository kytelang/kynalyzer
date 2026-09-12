//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const server = @import("server.zig");
pub const analysis = @import("analysis.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("server.zig");
    _ = @import("analysis.zig");
}
