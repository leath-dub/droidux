const std = @import("std");
const io = std.io;
const mem = std.mem;
const meta = std.meta;
const ascii = std.ascii;
const Version = std.SemanticVersion;
const Self = @This();

const Loc = struct {
    begin: usize,
    end: usize,

    pub fn init(begin: usize, end: usize) Loc {
        return .{ .begin = begin, .end = end };
    }

    pub fn asStr(loc: Loc, data: []const u8) []const u8 {
        return data[loc.begin .. loc.end + 1];
    }
};

pub const TokenValue = struct {
    substr: []const u8,
    location: Loc,

    pub fn init(src: []const u8, begin: usize, end: usize) TokenValue {
        const loc = Loc.init(begin, end);
        return .{
            .substr = loc.asStr(src),
            .location = loc,
        };
    }

    pub fn eql(tok1: TokenValue, tok2: TokenValue) bool {
        return mem.eql(u8, tok1.substr, tok2.substr);
    }
};

pub const Token = union(enum) {
    keyword: TokenValue,
    path: TokenValue,
    ident: TokenValue,
    constant: TokenValue,
    version: TokenValue,
    number: TokenValue,
    string: TokenValue,
    colon: TokenValue,
    lparen: TokenValue,
    rparen: TokenValue,
    comma: TokenValue,
    eof: void,

    pub fn format(t: Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return switch (t) {
            .eof => writer.print("{s}", .{@tagName(t)}),
            inline else => |v| writer.print("{s} \'{s}\' [{d}-{d}]", .{ @tagName(t), v.substr, v.location.begin, v.location.end }),
        };
    }

    pub fn temp(comptime typ: meta.FieldEnum(Token), src: []const u8) Token {
        return @unionInit(Token, @tagName(typ), .{
            .substr = src,
            .location = Loc.init(0, src.len - 1),
        });
    }
};

pub const ErrorValue = union(enum) {
    none,
    unexpected_char: meta.Tuple(&.{ Loc, []const u8 }),
    unmatched_quote: meta.Tuple(&.{ Loc, []const u8 }),

    pub fn format(t: ErrorValue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return switch (t) {
            .none => unreachable,
            inline else => |e| writer.print("{s}({s}) [{d}-{d}]", .{ @tagName(t), e.@"1", e.@"0".begin, e.@"0".end }),
        };
    }
};

const Error = error{lexer_failed};

pos: usize,
input: []const u8,
finished: bool,
err: ErrorValue,

pub fn init(input: []const u8) Self {
    return .{
        .pos = 0,
        .input = input,
        .finished = false,
        .err = .none,
    };
}

pub fn next(self: *Self) !Token {
    if (self.finished) {
        return .eof;
    }

    while (true) {
        const char = self.input[self.pos];
        return switch (char) {
            ':' => {
                self.finished = !self.incPos(1);
                return .{ .colon = TokenValue.init(self.input, self.pos - 1, self.pos - 1) };
            },
            '(' => {
                self.finished = !self.incPos(1);
                return .{ .lparen = TokenValue.init(self.input, self.pos - 1, self.pos - 1) };
            },
            ')' => {
                self.finished = !self.incPos(1);
                return .{ .rparen = TokenValue.init(self.input, self.pos - 1, self.pos - 1) };
            },
            ',' => {
                self.finished = !self.incPos(1);
                return .{ .comma = TokenValue.init(self.input, self.pos - 1, self.pos - 1) };
            },
            '/' => self.path(),
            '-', '0'...'9' => self.numberOrVersion(),
            '"' => self.string(),
            else => {
                if (ascii.isWhitespace(char)) {
                    while (ascii.isWhitespace(self.input[self.pos])) {
                        if (!self.incPos(1)) {
                            self.finished = true;
                            return .eof;
                        }
                    }
                    continue;
                }
                return self.identOrKeyword();
            },
        };
    }
}

pub fn getErr(self: Self) ?ErrorValue {
    if (self.err == .none) {
        return null;
    }

    return self.err;
}

const keywords = .{ "add device", "bus", "vendor", "product", "version", "name", "location", "id", "version", "events", "input props", "<none>", "value", "min", "max", "fuzz", "flat", "resolution" };

fn identOrKeyword(self: *Self) !Token {
    inline for (keywords) |kw| {
        const after = self.input[self.pos..];
        if (after.len >= kw.len) {
            if (mem.eql(u8, kw, after[0..kw.len])) {
                return .{
                    .keyword = self.jump(kw.len) orelse return .eof,
                };
            }
        }
    }

    const char = self.input[self.pos];
    if (!ascii.isAlphabetic(char)) {
        self.err = .{ .unexpected_char = .{ Loc.init(self.pos, self.pos), self.input[self.pos .. self.pos + 1] } };
        self.finished = true;
        return Error.lexer_failed;
    }

    // Handle contants with CAPS_AND_UNDERSCORES
    if (ascii.isUpper(char)) {
        const oldPos = self.pos;
        while (ascii.isAlphabetic(self.input[self.pos]) or self.input[self.pos] == '_') {
            if (!self.incPos(1)) {
                self.finished = true;
                break;
            }
        }

        return .{ .constant = TokenValue.init(self.input, oldPos, self.pos - 1) };
    }

    // TODO remove idents entirely as they are buggy due to the ambiguity of
    // `vendor beef` -> beef is a hex number here not an ident !
    // Also MAYBE make sure this is at least representable as hex ?

    const oldPos = self.pos;
    while (ascii.isAlphanumeric(self.input[self.pos])) {
        if (!self.incPos(1)) {
            self.finished = true;
            break;
        }
    }

    return .{ .number = TokenValue.init(self.input, oldPos, self.pos - 1) };
}

fn number(self: *Self) ?Token {
    const oldPos = self.pos;
    while (true) {
        switch (self.input[self.pos]) {
            '*' => {
                // For some reason sometimes the event key numbers are postfixed by a '*'
                // Just skip it !
                const actual_end = self.pos;
                if (!self.incPos(1)) {
                    self.finished = true;
                    return null;
                }
                return .{ .number = TokenValue.init(self.input, oldPos, actual_end - 1) };
            },
            '-', '.', '0'...'9', 'a'...'f' => if (!self.incPos(1)) {
                self.finished = true;
                return null;
            },
            else => return .{ .number = TokenValue.init(self.input, oldPos, self.pos - 1) },
        }
    }
}

fn numberOrVersion(self: *Self) Token {
    const tok = self.number() orelse return .eof;
    switch (tok) {
        .number => |numl| {
            _ = Version.parse(numl.substr) catch return tok;
            return .{ .version = numl };
        },
        else => unreachable,
    }
}

fn string(self: *Self) !Token {
    if (mem.indexOfScalar(u8, self.input[self.pos + 1 ..], '"')) |end| {
        return .{ .string = self.jump(end + 2) orelse return .eof };
    }
    self.finished = true;
    self.err = .{ .unmatched_quote = .{ Loc.init(self.pos, self.pos), self.input[self.pos .. self.pos + 1] } };
    return Error.lexer_failed;
}

fn jump(self: *Self, amt: usize) ?TokenValue {
    const oldPos = self.pos;
    if (!self.incPos(amt)) {
        return null;
    }
    return TokenValue.init(self.input, oldPos, self.pos - 1);
}

fn incPos(self: *Self, by: usize) bool {
    self.pos += by;
    return self.pos != self.input.len;
}

fn locToStr(self: Self, loc: Loc) []const u8 {
    return loc.asStr(self.input);
}

fn until_ws_or_eof(self: Self) []const u8 {
    var it = std.mem.tokenizeAny(u8, self.input[self.pos..], &ascii.whitespace);
    if (it.next()) |s| {
        return s;
    }
    return self.input[self.pos..];
}

fn path(self: *Self) Token {
    const s = self.until_ws_or_eof();
    return .{ .path = self.jump(s.len) orelse return .eof };
}

test "General test on real data" {
    // This data is taken from my boox note air 2. This is the digitizer device info that is printed
    // by `getevent -pi`
    const content =
        \\add device 9: /dev/input/event3
        \\  bus:      0018
        \\  vendor    2d1f
        \\  product   012b
        \\  version   1372
        \\  name:     "onyx_emp_Wacom I2C Digitizer"
        \\  location: ""
        \\  id:       ""
        \\  version:  1.0.1
        \\  events:
        \\    KEY (0001): 0141  0142  014a  014b  014c  0152  0153
        \\    ABS (0003): 0000  : value 0, min 0, max 20966, fuzz 0, flat 0, resolution 0
        \\                0001  : value 0, min 0, max 15725, fuzz 0, flat 0, resolution 0
        \\                0018  : value 0, min 0, max 4095, fuzz 0, flat 0, resolution 0
        \\                0019  : value 0, min 0, max 255, fuzz 0, flat 0, resolution 0
        \\                001a  : value 0, min -63, max 63, fuzz 0, flat 0, resolution 0
        \\                001b  : value 0, min -63, max 63, fuzz 0, flat 0, resolution 0
        \\  input props:
        \\    INPUT_PROP_DIRECT
    ;

    const expected = .{
        .{ .keyword, "add device" },
        .{ .number, "9" },
        .{ .colon, ":" },
        .{ .path, "/dev/input/event3" },
        .{ .keyword, "bus" },
        .{ .colon, ":" },
        .{ .number, "0018" },
        .{ .keyword, "bus" },
        .{ .number, "2d1f" },
        .{ .keyword, "product" },
        .{ .number, "012b" },
        .{ .keyword, "version" },
        .{ .number, "1372" },
        .{ .keyword, "name" },
        .{ .colon, ":" },
        .{ .string, "\"onyx_emp_Wacom I2C Digitizer\"" },
        .{ .keyword, "location" },
        .{ .colon, ":" },
        .{ .string, "\"\"" },
        .{ .keyword, "id" },
        .{ .colon, ":" },
        .{ .string, "\"\"" },
        .{ .keyword, "version" },
        .{ .colon, ":" },
        .{ .version, "1.0.1" },
        .{ .keyword, "events" },
        .{ .colon, ":" },

        .{ .constant, "KEY" },
        .{ .lparen, "(" },
        .{ .number, "0001" },
        .{ .rparen, ")" },
        .{ .colon, ":" },
        .{ .number, "0141" },
        .{ .number, "0142" },
        .{ .number, "014a" },
        .{ .number, "014b" },
        .{ .number, "014c" },
        .{ .number, "0152" },
        .{ .number, "0153" },

        .{ .constant, "ABS" },
        .{ .lparen, "(" },
        .{ .number, "0003" },
        .{ .rparen, ")" },
        .{ .colon, ":" },
        .{ .number, "0000" },
        .{ .colon, ":" },
        .{ .keyword, "value" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "min" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "max" },
        .{ .number, "20966" },
        .{ .comma, "," },
        .{ .keyword, "fuzz" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "flat" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "resolution" },
        .{ .number, "0" },

        .{ .number, "0001" },
        .{ .colon, ":" },
        .{ .keyword, "value" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "min" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "max" },
        .{ .number, "15725" },
        .{ .comma, "," },
        .{ .keyword, "fuzz" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "flat" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "resolution" },
        .{ .number, "0" },

        .{ .number, "0018" },
        .{ .colon, ":" },
        .{ .keyword, "value" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "min" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "max" },
        .{ .number, "4095" },
        .{ .comma, "," },
        .{ .keyword, "fuzz" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "flat" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "resolution" },
        .{ .number, "0" },

        .{ .number, "0019" },
        .{ .colon, ":" },
        .{ .keyword, "value" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "min" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "max" },
        .{ .number, "255" },
        .{ .comma, "," },
        .{ .keyword, "fuzz" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "flat" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "resolution" },
        .{ .number, "0" },

        .{ .number, "001a" },
        .{ .colon, ":" },
        .{ .keyword, "value" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "min" },
        .{ .number, "-63" },
        .{ .comma, "," },
        .{ .keyword, "max" },
        .{ .number, "63" },
        .{ .comma, "," },
        .{ .keyword, "fuzz" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "flat" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "resolution" },
        .{ .number, "0" },

        .{ .number, "001b" },
        .{ .colon, ":" },
        .{ .keyword, "value" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "min" },
        .{ .number, "-63" },
        .{ .comma, "," },
        .{ .keyword, "max" },
        .{ .number, "63" },
        .{ .comma, "," },
        .{ .keyword, "fuzz" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "flat" },
        .{ .number, "0" },
        .{ .comma, "," },
        .{ .keyword, "resolution" },
        .{ .number, "0" },

        .{ .keyword, "input props" },
        .{ .colon, ":" },
        .{ .constant, "INPUT_PROP_DIRECT" },
        .{.eof},
    };

    var tokens = std.ArrayList(Token).init(std.testing.allocator);
    defer tokens.deinit();

    var lex = init(content);
    while (lex.next() catch null) |t| {
        try tokens.append(t);
        if (t == .eof) {
            break;
        }
    }

    try std.testing.expectEqual(expected.len, tokens.items.len);

    inline for (tokens.items, expected) |tok, expected_tok| {
        try std.testing.expectEqualDeep(@tagName(expected_tok.@"0"), @tagName(tok));
    }
}
