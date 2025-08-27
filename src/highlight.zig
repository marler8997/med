pub const Mode = enum {
    zig,
    c,
};

pub const Token = struct {
    kind: TokenKind,
    end: usize,
};

pub fn tokenize(mode: Mode, row_str: []const u8, start: usize) Token {
    return switch (mode) {
        .zig => @import("highlight/zig.zig").tokenize(row_str, start),
        .c => @import("highlight/c.zig").tokenize(row_str, start),
    };
}

pub const TokenKind = enum {
    todo,
    unknown,
    keyword,
    string_literal,
    operator,
    doc_comment,
    comment,
    pub fn color(self: TokenKind) zin.Rgb8 {
        return switch (self) {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            .todo => theme.fg,
            .unknown => .{ .r = 0xff, .g = 0x33, .b = 0x33 },
            .keyword => .{ .r = 0xf7, .g = 0xa4, .b = 0x1d },
            .string_literal => .{ .r = 0x3c, .g = 0x51, .b = 0x90 },
            .operator => .{ .r = 0x04, .g = 0x96, .b = 0xff },
            .doc_comment => .{ .r = 0x20, .g = 0x83, .b = 0x73 },
            .comment => .{ .r = 0x3a, .g = 0xcf, .b = 0xc8 },
        };
    }
};

const zin = @import("zin");
const theme = @import("theme.zig");
