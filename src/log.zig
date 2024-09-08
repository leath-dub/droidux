const std = @import("std");

var stdout = std.io.getStdOut().writer();

pub fn info(comptime format: []const u8, args: anytype) void {
    stdout.print("[INFO] " ++ format ++ "\n", args) catch unreachable;
}
