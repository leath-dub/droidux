const std = @import("std");
const mem = std.mem;
const log = std.log;
const info = @import("log.zig").info;
const meta = std.meta;
const io = std.io;
const fs = std.fs;
const fmt = std.fmt;
const posix = std.posix;
const Child = std.process.Child;

const GeteventParser = @import("getevent/Parser.zig");
const DeviceSpec = GeteventParser.DeviceSpec;
const VirtDevice = @import("uinput.zig");
const c = VirtDevice.c;

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

// Below is the form of the lines we are reading
const MAGIC_BUFLEN = "0000 0000 00000000\n".len;
const MAX_BUFFERED_EVENTS = 8;

// Faster hex string to number conversion
pub inline fn intOfHex(comptime T: type, hex: []const u8) T {
    var r: T = 0;
    for (hex) |d| {
        r <<= 4;
        r |= d - '0' - (d / 'a' * (('a' - '0') - 10));
    }
    return r;
}

// Cursed signal handling shenanigans
// I think anybody who has written signal handlers has sinned
// (forgive me)
var stdout_ref: *?fs.File = undefined;
pub fn handleUSR1(_: i32) callconv(.C) void {
    stdout_ref.*.?.close();
    stdout_ref.* = null;
}

pub fn proxyEvents(al: mem.Allocator, spec: DeviceSpec, vdev: VirtDevice) !void {
    var child = Child.init(&.{ "adb", "shell", "getevent", spec.path }, al);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    // Register sigaction to allow user to stop proxying events
    const act: posix.Sigaction = .{
        .flags = 0,
        .handler = .{ .handler = handleUSR1 },
        .mask = posix.empty_sigset,
    };
    try posix.sigaction(posix.SIG.USR1, &act, null);
    try posix.sigaction(posix.SIG.INT, &act, null);

    // This is a bit of a mess however I don't want to pay the
    // cost of a vtable by using a reader, and I don't want to needless
    // buffer memcpy's by using a buffedReader.
    //
    // The idea is to keep large enough buffer for `MAX_BUFFERED_EVENTS`
    // and just let the reader read up to that at a time. If there are
    // any partial events, we just memcpy that data back to the start of
    // the buffer and bump the read head, e.g:
    //
    // [xxx xxx xx-]
    //  ev0 ev1 ev2 (partial read)
    //
    // translate [xxx xxx xx-] -> [xx- --- ---]
    //                               ^- read head

    var ev_data = std.mem.zeroes([MAGIC_BUFLEN * MAX_BUFFERED_EVENTS]u8);
    var readh: usize = 0;
    const ios = child.stdout.?;

    stdout_ref = &child.stdout; // set pointer to this stream

    info("Proxying device events. send SIGUSR1 or SIGINT (CTRL+C) signal to stop.", .{});

    while (true) {
        const bytes_read = (std.posix.read(ios.handle, ev_data[readh..]) catch break) + readh;
        const part = bytes_read % MAGIC_BUFLEN;

        // Emit the complete read events
        const tot = bytes_read / MAGIC_BUFLEN;
        var rem = tot;

        while (rem != 0) : (rem -= 1) {
            const ev_bytes = ev_data[(tot - rem) * MAGIC_BUFLEN ..][0..MAGIC_BUFLEN];
            try vdev.dev.writeAll(mem.asBytes(&c.input_event{
                .type = intOfHex(u16, ev_bytes[0..4]),
                .code = intOfHex(u16, ev_bytes[5..9]),
                .value = @bitCast(intOfHex(u32, ev_bytes[10 .. MAGIC_BUFLEN - 1])),
                .time = .{
                    .tv_sec = 0,
                    .tv_usec = 0,
                },
            }));
        }

        readh = 0;
        if (part != 0) {
            // there is a partial read @ bytes_read - part
            const off = bytes_read - part;
            mem.copyForwards(u8, ev_data[0..], ev_data[off..][0..part]);
            readh = part; // set new buffer offset to the partial read
        }
    }

    // If we get here it means we want to quit, kill the child !
    _ = try child.kill();

    info("Stopped listening due to interrupt.", .{});
}
