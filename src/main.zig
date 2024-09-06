const std = @import("std");
const heap = std.heap;
const io = std.io;
const os = std.os;
const json = std.json;
const log = std.log;

const clap = @import("clap");
const adb = @import("adb.zig");
const GeteventParser = @import("getevent/Parser.zig");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            _ = gpa.detectLeaks();
        }
    }
    const al = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\ -h, --help		Display this help and exit.
        \\ -l, --list-devices	Dump devices as list of json device specs.
        \\ -p, --parse-devices	Dump devices as list of json parsed from stdin (result from `adb shell getevent -pi`).
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = al,
    }) catch |e| {
        diag.report(io.getStdErr().writer(), e) catch unreachable;
        return e;
    };
    defer res.deinit();

    if (res.args.help != 0 or os.argv.len == 1) {
        return clap.help(io.getStdErr().writer(), clap.Help, &params, .{});
    }

    if (res.args.@"parse-devices" != 0) {
        try adb.startServer(al);

        const input = try io.getStdIn().readToEndAlloc(al, 16_384);
        defer al.free(input);

        var parser = try GeteventParser.init(al, input);
        parser.parse() catch |err| {
            log.err("{s}\n", .{parser.getErr().?});
            return err;
        };
        defer parser.deinit();

        const stdout = io.getStdOut();
        for (parser.specs.items) |dev| {
            try json.stringify(dev, .{ .whitespace = .indent_2 }, stdout.writer());
            _ = try stdout.write("\n");
        }

        return;
    }

    if (res.args.@"list-devices" != 0) {
        try adb.startServer(al);

        const src, const parser = try adb.getDevices(al);
        defer parser.deinit();
        defer al.free(src);

        const stdout = io.getStdOut();
        for (parser.specs.items) |dev| {
            try json.stringify(dev, .{ .whitespace = .indent_2 }, stdout.writer());
            _ = try stdout.write("\n");
        }
        return;
    }
}
