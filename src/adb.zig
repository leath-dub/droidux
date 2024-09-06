const std = @import("std");
const mem = std.mem;
const log = std.log;
const meta = std.meta;
const Child = std.process.Child;
const GeteventParser = @import("getevent/Parser.zig");

pub fn startServer(al: mem.Allocator) !void {
    var child = Child.init(&.{ "adb", "start-server" }, al);
    _ = try child.spawnAndWait();
    // TODO handle error messages reported
}

pub const AdbErr = error{
    NoDeviceFound,
};

// We yield a tuple as the the source code is referenced by the device specs
// so we give the owned memory back
pub fn getDevices(al: mem.Allocator) !meta.Tuple(&.{ []u8, GeteventParser }) {
    const res = try Child.run(.{
        .allocator = al,
        .argv = &.{ "adb", "shell", "getevent", "-pi" },
    });

    defer al.free(res.stderr);

    switch (res.term) {
        .Exited => |code| if (code != 0) {
            if (code != 1) unreachable;
            if (mem.endsWith(u8, res.stderr, "adb: no devices/emulators found\n")) {
                return AdbErr.NoDeviceFound;
            }
            unreachable;
        },
        else => unreachable,
    }

    var par = try GeteventParser.init(al, res.stdout);

    par.parse() catch |err| {
        log.err("{s}\n", .{par.getErr().?});
        return err;
    };

    return .{ res.stdout, par };
}
