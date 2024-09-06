const std = @import("std");
const meta = std.meta;
const mem = std.mem;
const heap = std.heap;
const fmt = std.fmt;
const json = std.json;

const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Version = std.SemanticVersion;
const Self = @This();

const c = @cImport({
    @cInclude("linux/uinput.h");
});

const NodeType = enum {
    events,
    device_spec,
    input_props,

    pub fn format(t: NodeType, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (t) {
            inline else => |v| return writer.print("{s}", .{@tagName(v)}),
        }
    }
};

const UnexpectedToken = struct {
    found: Token,
    expected: Token,
    while_parsing: NodeType,

    pub fn format(t: UnexpectedToken, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("expected `{s}' but found `{s}' while parsing `{s}'", .{ t.expected, t.found, t.while_parsing });
    }
};

const Error = error{
    init_failed,
    lexer_error,
    unexpected_token,
    unexpected_eof,
};

const ErrorValue = union(enum) {
    none: void,
    lexer_error: Lexer.ErrorValue,
    unexpected_token: UnexpectedToken,
    unexpected_eof: void,

    pub fn format(t: ErrorValue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return switch (t) {
            .none => unreachable,
            .unexpected_eof => writer.print("Unexpected EOF", .{}),
            inline else => |e| writer.print("{s}({s})", .{ @tagName(t), e }),
        };
    }
};

const Code = u16;
const Event = u16;
const AbsEvent = struct {
    code: u16,
    value: i32,
    min: i32,
    max: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

// Json serialize shim for unmanaged array
pub fn JsonArray(comptime T: type) type {
    return struct {
        arr: std.ArrayListUnmanaged(T) = .{},
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.arr.items);
        }
    };
}

pub const DeviceSpec = struct {
    number: u16 = undefined,
    path: []const u8 = undefined,

    bus: u16 = undefined,
    vendor: u16 = undefined,
    product: u16 = undefined,
    version: u16 = undefined,
    name: []const u8 = undefined,
    location: []const u8 = undefined,
    id: []const u8 = undefined,
    semver: Version = undefined,
    // This is not the most efficent way to store it, however it is easily serialized
    normal_events: JsonArray(meta.Tuple(&.{ Code, Event })) = .{},

    // We could hard code this as c.EV_ABS
    // however it is provided by command output
    // anyway and I want to keep that as the
    // source of truth.
    abs_code: ?u16 = null,
    abs_events: JsonArray(AbsEvent) = .{}, // ABS are handled separately as they have extra data

    input_props: JsonArray([]const u8) = .{},
};

src: []const u8,
lex: Lexer,
tok: Token,
err: ErrorValue = .none,

arena: heap.ArenaAllocator,
specs: std.ArrayListUnmanaged(DeviceSpec) = .{},

pub fn init(alloc: mem.Allocator, src: []const u8) Error!Self {
    if (src.len == 0) {
        return Error.init_failed;
    }

    var lex = Lexer.init(src);
    const tok = lex.next() catch return Error.init_failed;
    const arena = heap.ArenaAllocator.init(alloc);

    return .{
        .arena = arena,
        .src = src,
        .lex = lex,
        .tok = tok,
    };
}

pub fn parse(self: *Self) !void {
    // Keep trying to parse device specs until lexer is done
    while (true) {
        const spec = try self.deviceSpec();
        try self.specs.append(self.arena.allocator(), spec);
        if (self.tok == .eof) {
            break;
        }
    }
}

pub fn getErr(self: Self) ?ErrorValue {
    if (self.err == .none) {
        return null;
    }

    return self.err;
}

fn fail(self: *Self, comptime typ: meta.FieldEnum(ErrorValue), value: anytype) Error {
    self.err = @unionInit(ErrorValue, @tagName(typ), value);
    return @field(Error, @tagName(typ));
}

fn expectType(self: *Self, comptime tok: meta.Tag(Token), in_node: NodeType) Error!void {
    if (meta.activeTag(self.tok) != tok) {
        return self.fail(.unexpected_token, .{
            .found = self.tok,
            .expected = Token.temp(tok, "<placeholder>"),
            .while_parsing = in_node,
        });
    }
}

fn expectValue(self: *Self, tok: Token, in_node: NodeType) Error!void {
    if (meta.activeTag(self.tok) != meta.activeTag(tok)) {
        return self.fail(.unexpected_token, .{
            .found = self.tok,
            .expected = tok,
            .while_parsing = in_node,
        });
    }

    switch (self.tok) {
        // Unfortunately we have to handle the .eof case explicitly as
        // it has a void value. Maybe I should make it have a value :shrug:
        .eof => return self.fail(.unexpected_token, .{
            .found = self.tok,
            .expected = tok,
            .while_parsing = in_node,
        }),
        inline else => |found| {
            switch (tok) {
                .eof => return self.fail(.unexpected_token, .{
                    .found = self.tok,
                    .expected = tok,
                    .while_parsing = in_node,
                }),
                inline else => |expected| {
                    if (!found.eql(expected)) {
                        return self.fail(.unexpected_token, .{
                            .found = self.tok,
                            .expected = tok,
                            .while_parsing = in_node,
                        });
                    }
                },
            }
        },
    }
}

fn consume(self: *Self) Error!void {
    self.tok = self.lex.next() catch {
        return self.fail(.lexer_error, self.lex.getErr() orelse unreachable);
    };
}

pub fn deviceSpec(self: *Self) Error!DeviceSpec {
    var spec: DeviceSpec = .{};

    // e.g: add device 9: /dev/input/event3
    try self.expectValue(Token.temp(.keyword, "add device"), .device_spec);
    try self.consume();
    try self.expectType(.number, .device_spec);
    spec.number = fmt.parseInt(u16, self.tok.number.substr, 10) catch unreachable;
    try self.consume();
    try self.expectType(.colon, .device_spec);
    try self.consume();
    try self.expectType(.path, .device_spec);
    spec.path = self.tok.path.substr;
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "bus"), .device_spec);
    try self.consume();
    try self.expectType(.colon, .device_spec);
    try self.consume();
    try self.expectType(.number, .device_spec);
    spec.bus = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "vendor"), .device_spec);
    try self.consume();
    try self.expectType(.number, .device_spec);
    spec.vendor = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "product"), .device_spec);
    try self.consume();
    try self.expectType(.number, .device_spec);
    spec.product = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "version"), .device_spec);
    try self.consume();
    try self.expectType(.number, .device_spec);
    spec.version = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "name"), .device_spec);
    try self.consume();
    try self.expectType(.colon, .device_spec);
    try self.consume();
    try self.expectType(.string, .device_spec);
    spec.name = self.tok.string.substr[1 .. self.tok.string.substr.len - 1];
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "location"), .device_spec);
    try self.consume();
    try self.expectType(.colon, .device_spec);
    try self.consume();
    try self.expectType(.string, .device_spec);
    spec.location = self.tok.string.substr[1 .. self.tok.string.substr.len - 1];
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "id"), .device_spec);
    try self.consume();
    try self.expectType(.colon, .device_spec);
    try self.consume();
    try self.expectType(.string, .device_spec);
    spec.id = self.tok.string.substr[1 .. self.tok.string.substr.len - 1];
    try self.consume();

    try self.expectValue(Token.temp(.keyword, "version"), .device_spec);
    try self.consume();
    try self.expectType(.colon, .device_spec);
    try self.consume();
    try self.expectType(.version, .device_spec);
    spec.semver = Version.parse(self.tok.version.substr) catch unreachable;
    try self.consume();

    const event_data = try self.events(&spec.normal_events.arr);
    spec.abs_code = event_data.@"0";
    spec.abs_events = event_data.@"1";

    // e.g. input props:
    //        INPUT_PROP_DIRECT
    try self.expectValue(Token.temp(.keyword, "input props"), .device_spec);
    try self.consume();
    try self.expectType(.colon, .input_props);
    try self.consume();

    self.expectType(.constant, .input_props) catch {
        try self.expectValue(Token.temp(.keyword, "<none>"), .input_props);
        try self.consume();
    };

    while (self.expectType(.constant, .input_props) catch null) |_| {
        spec.input_props.arr.append(self.arena.allocator(), self.tok.constant.substr) catch unreachable;
        self.consume() catch break; // we could eof here, and thats fine !
    }

    return spec;
}

fn events(self: *Self, normal_events: *std.ArrayListUnmanaged(meta.Tuple(&.{ Code, Event }))) Error!meta.Tuple(&.{ ?u16, JsonArray(AbsEvent) }) {
    try self.expectValue(Token.temp(.keyword, "events"), .events);
    try self.consume();
    try self.expectType(.colon, .events);
    try self.consume();

    var abs_code: ?u16 = null;
    var abs_events: JsonArray(AbsEvent) = .{};

    while (true) {
        self.expectValue(Token.temp(.constant, "ABS"), .events) catch {
            self.expectType(.constant, .events) catch break; // finished reading events if this fails
            try self.consume();
            try self.expectType(.lparen, .events);
            try self.consume();

            try self.expectType(.number, .events);
            const code = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
            try self.consume();

            try self.expectType(.rparen, .events);
            try self.consume();

            try self.expectType(.colon, .events);
            try self.consume();

            while (self.expectType(.number, .events) catch null) |_| {
                const ev = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
                normal_events.append(self.arena.allocator(), .{ code, ev }) catch unreachable;
                try self.consume();
            }

            continue;
        };
        try self.consume();

        try self.expectType(.lparen, .events);
        try self.consume();

        try self.expectType(.number, .events);
        abs_code = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
        try self.consume();

        try self.expectType(.rparen, .events);
        try self.consume();
        try self.expectType(.colon, .events);
        try self.consume();

        while (self.expectType(.number, .events) catch null) |_| {
            var ev: AbsEvent = undefined;

            ev.code = fmt.parseInt(u16, self.tok.number.substr, 16) catch unreachable;
            try self.consume();

            try self.expectType(.colon, .events);
            try self.consume();

            // The following parses this: value 0, min 0, max 20966, fuzz 0, flat 0, resolution 0
            const fields = .{ "value", "min", "max", "fuzz", "flat", "resolution" };
            inline for (fields) |fname| {
                try self.expectValue(Token.temp(.keyword, fname), .events);
                try self.consume();
                try self.expectType(.number, .events);
                @field(ev, fname) = fmt.parseInt(i32, self.tok.number.substr, 10) catch unreachable;
                try self.consume();

                // The last case will not have a comma, just don't shit a brick
                // when that happens and also don't consume whatever the next
                // token may be
                if (self.expectType(.comma, .events) catch null) |_| {
                    try self.consume();
                }
            }

            abs_events.arr.append(self.arena.allocator(), ev) catch unreachable;
        }
    }

    return .{ abs_code, abs_events };
}

pub fn deinit(self: Self) void {
    self.arena.deinit();
}

// TODO test boundry cases (empty input etc)

test "Test corpus" {
    const testing = std.testing;
    const fs = std.fs;
    const log = std.log;

    const Helper = struct {
        fn runInTestDir(entr: fs.Dir.Entry, corpus_dir: fs.Dir) !void {
            try testing.expectEqual(entr.kind, .directory);
            var test_dir = try corpus_dir.openDir(entr.name, .{});
            defer test_dir.close();

            const input = try test_dir.openFile("input.txt", .{});
            const output = try test_dir.openFile("output.txt", .{});
            defer input.close();
            defer output.close();

            const input_txt = try input.readToEndAlloc(testing.allocator, 16_384);
            defer testing.allocator.free(input_txt);

            const output_txt = try output.readToEndAlloc(testing.allocator, 16_384);
            defer testing.allocator.free(output_txt);

            var par = try Self.init(testing.allocator, input_txt);
            defer par.deinit();

            par.parse() catch |err| {
                log.err("{s}\n", .{par.getErr().?});
                return err;
            };

            var actual_output = std.ArrayList(u8).init(testing.allocator);
            defer actual_output.deinit();

            for (par.specs.items) |spec| {
                try json.stringify(spec, .{ .whitespace = .indent_2 }, actual_output.writer());
                _ = try actual_output.writer().write("\n");
            }

            try testing.expectEqualSlices(u8, output_txt, actual_output.items);
        }
    };

    var corpus_dir = try fs.cwd().openDir("src/getevent/corpus", .{ .iterate = true });
    defer corpus_dir.close();

    var it = corpus_dir.iterate();
    while (try it.next()) |entr| {
        Helper.runInTestDir(entr, corpus_dir) catch |err| {
            log.err("TESTCASE: {s} @ src/getevent/corpus/{s}/output.txt\n", .{
                entr.name,
                entr.name,
            });
            return err;
        };
    }
}
