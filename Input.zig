const Input = @This();

const std = @import("std");

pub const Action = union(enum) {
    add_char: u8,
    enter,
    @"keyboard-quit",
    cursor_back,
    cursor_forward,
    cursor_up,
    cursor_down,
    cursor_line_start,
    cursor_line_end,
    tab,
    delete,
    backspace,
    kill_line,
    open_file,
    save_file,
    @"open-process",
    kill_pane,
    quit,
};

// placeholders for keys that currently just act as alias's to other keys
pub const todo = struct {
    pub const kp_enter = Key.enter;
    pub const left_shift = null;
    pub const left_control = Key.control;
    pub const right_control = Key.control;
    pub const left_alt = Key.alt;
    pub const right_alt = Key.alt;
    pub const pause = null;
    pub const caps_lock = null;

    pub const kp_page_up = null;
    pub const kp_page_down = null;
    pub const kp_end = null;
    pub const kp_home = null;
    pub const kp_left = null;
    pub const kp_up = null;
    pub const kp_right = null;
    pub const kp_down = null;
    pub const print_screen = null;
    pub const kp_insert = null;
    pub const kp_delete = null;

    pub const left_super = null;
    pub const right_super = null;

    pub const kp_0 = null;
    pub const kp_1 = null;
    pub const kp_2 = null;
    pub const kp_3 = null;
    pub const kp_4 = null;
    pub const kp_5 = null;
    pub const kp_6 = null;
    pub const kp_7 = null;
    pub const kp_8 = null;
    pub const kp_9 = null;
    pub const kp_multiply = null;
    pub const kp_add = null;
    pub const kp_separator = null;
    pub const kp_subtract = null;
    pub const kp_decimal = null;

    pub const f1 = null;
    pub const f2 = null;
    pub const f3 = null;
    pub const f4 = null;
    pub const f5 = null;
    pub const f6 = null;
    pub const f7 = null;
    pub const f8 = null;
    pub const f9 = null;
    pub const f10 = null;
    pub const f11 = null;
    pub const f12 = null;
    pub const f13 = null;
    pub const f14 = null;
    pub const f15 = null;
    pub const @"f16" = null;
    pub const f17 = null;
    pub const f18 = null;
    pub const f19 = null;
    pub const f20 = null;
    pub const f21 = null;
    pub const f22 = null;
    pub const f23 = null;
    pub const f24 = null;

    pub const num_lock = null;
    pub const scroll_lock = null;
    pub const right_shift = null;

    pub const mute_volume = null;
    pub const lower_volume = null;
    pub const raise_volume = null;
    pub const media_track_next = null;
    pub const media_track_previous = null;
    pub const media_stop = null;
    pub const media_play_pause = null;

    pub const page_up = null;
    pub const page_down = null;
    pub const end = null;
    pub const home = null;
    pub const left = null;
    pub const up = null;
    pub const right = null;
    pub const down = null;
    pub const insert = null;
    pub const delete = null;
    pub const kp_divide = null;
};

pub const Key = enum {
    control,
    alt,
    enter,
    backspace,
    tab,
    escape,
    // The rest of the keys are in ASCII order and the engine
    // guarantees this to make it easier to translate to/from
    // ascii codes
    space,
    bang,
    double_quote,
    pound,
    dollar,
    percent,
    ampersand,
    single_quote,
    open_paren,
    close_paren,
    star,
    plus,
    comma,
    dash,
    period,
    forward_slash,
    // zig fmt: off
    @"0", @"1", @"2", @"3", @"4",
    @"5", @"6", @"7", @"8", @"9",
    // zig fmt: on
    colon,
    semicolon,
    open_angle_bracket,
    equal,
    close_angle_bracket,
    question_mark,
    at,
    // zig fmt: off
    A, B, C, D, E, F, G, H, I, J, K, L, M,
    N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    // zig fmt: on
    open_square_bracket,
    backslash,
    close_square_bracket,
    caret,
    underscore,
    backtick,
    // zig fmt: off
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y ,z,
    // zig fmt: on
    open_curly,
    pipe,
    close_curly,
    tilda,

    pub fn lower(self: Key) Key {
        return switch (@intFromEnum(self)) {
            @intFromEnum(Key.A)...@intFromEnum(Key.Z) => |c| @enumFromInt(c + (@intFromEnum(Key.a) - @intFromEnum(Key.A))),
            else => self,
        };
    }
    pub fn str(key: Key) []const u8 {
        return switch (key) {
            .control => "control",
            .alt => "alt",
            .enter => "enter",
            .backspace => "backspace",
            .tab => "tab",
            .escape => "esc",
            .space => "space",
            .bang => "!",
            .double_quote => "\"",
            .pound => "#",
            .dollar => "$",
            .percent => "%",
            .ampersand => "&",
            .single_quote => "'",
            .open_paren => "(",
            .close_paren => ")",
            .star => "*",
            .plus => "+",
            .comma => ",",
            .dash => "-",
            .period => ".",
            .forward_slash => "/",
            .@"0" => "0",
            .@"1" => "1",
            .@"2" => "2",
            .@"3" => "3",
            .@"4" => "4",
            .@"5" => "5",
            .@"6" => "6",
            .@"7" => "7",
            .@"8" => "8",
            .@"9" => "9",
            .colon => ":",
            .semicolon => ";",
            .open_angle_bracket => "<",
            .equal => "=",
            .close_angle_bracket => ">",
            .question_mark => "?",
            .at => "@",
            .A => "A",
            .B => "B",
            .C => "C",
            .D => "D",
            .E => "E",
            .F => "F",
            .G => "G",
            .H => "H",
            .I => "I",
            .J => "J",
            .K => "K",
            .L => "L",
            .M => "M",
            .N => "N",
            .O => "O",
            .P => "P",
            .Q => "Q",
            .R => "R",
            .S => "S",
            .T => "T",
            .U => "U",
            .V => "V",
            .W => "W",
            .X => "X",
            .Y => "Y",
            .Z => "Z",
            .open_square_bracket => "[",
            .backslash => "\\",
            .close_square_bracket => "]",
            .caret => "^",
            .underscore => "_",
            .backtick => "`",
            .a => "a",
            .b => "b",
            .c => "c",
            .d => "d",
            .e => "e",
            .f => "f",
            .g => "g",
            .h => "h",
            .i => "i",
            .j => "j",
            .k => "k",
            .l => "l",
            .m => "m",
            .n => "n",
            .o => "o",
            .p => "p",
            .q => "q",
            .r => "r",
            .s => "s",
            .t => "t",
            .u => "u",
            .v => "v",
            .w => "w",
            .x => "x",
            .y => "y",
            .z => "z",
            .open_curly => "{",
            .pipe => "|",
            .close_curly => "}",
            .tilda => "~",
        };
    }
};
pub const key_count = @typeInfo(Key).Enum.fields.len;
pub const KeyPressKind = enum { initial, repeat };
pub const KeyState = enum { up, down, down_repeat };

pub const KeyMods = packed struct(u2) {
    control: bool,
    alt: bool,
    pub fn eql(self: KeyMods, other: KeyMods) bool {
        return @as(u2, @bitCast(self)) == @as(u2, @bitCast(other));
    }
    pub fn format(
        self: KeyMods,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var sep: []const u8 = "";
        if (self.control) {
            try writer.print("{s}control", .{sep});
            sep = ",";
        }
        if (self.alt) {
            try writer.print("{s}alt", .{sep});
            sep = ",";
        }
    }
};

pub const Keybind = struct {
    pub const max = 3;
    pub const Node = struct {
        key: Key,
        mods: KeyMods,
        pub fn eql(self: Node, other: Node) bool {
            return self.key == other.key and self.mods.eql(other.mods);
        }
        pub fn format(
            self: Node,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (self.mods.control) {
                try writer.writeAll("control-");
            }
            try writer.writeAll(self.key.str());
        }
    };
    buf: [max]Node = undefined,
    len: usize = 0,

    pub fn last(self: *const Keybind) ?Node {
        return if (self.len == 0) null else self.buf[self.len - 1];
    }

    pub fn add(self: *Keybind, node: Node) bool {
        if (self.len >= max)
            return false;
        self.buf[self.len] = node;
        self.len += 1;
        return true;
    }

    pub fn format(
        self: Keybind,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var sep: []const u8 = "";
        for (self.buf[0..self.len]) |node| {
            try writer.print("{s}{}", .{ sep, node });
            sep = " ";
        }
    }
};

const KeybindResult = union(enum) {
    unbound,
    modifier,
    prefix,
    action: Action,
};
pub fn evaluateKeybind(
    keybind: *const Keybind,
) KeybindResult {
    switch (keybind.len) {
        0 => unreachable,
        1 => if (keybind.buf[0].mods.control) switch (keybind.buf[0].key) {
            .comma => return .prefix,
            .a => return .{ .action = .cursor_line_start },
            .b => return .{ .action = .cursor_back },
            .d => return .{ .action = .delete },
            .e => return .{ .action = .cursor_line_end },
            .f => return .{ .action = .cursor_forward },
            .g => return .{ .action = .@"keyboard-quit" },
            .k => return .{ .action = .kill_line },
            .n => return .{ .action = .cursor_down },
            .p => return .{ .action = .cursor_up },
            .x => return .prefix,
            else => {},
        } else return switch (keybind.buf[0].key) {
            .control, .alt => .modifier,
            .enter => return .{ .action = .enter },
            .backspace => return .{ .action = .backspace },
            .tab => return .{ .action = .tab },
            .escape => return .unbound,
            .space,
            .bang,
            .double_quote,
            .pound,
            .dollar,
            .percent,
            .ampersand,
            .single_quote,
            .open_paren,
            .close_paren,
            .star,
            .plus,
            .comma,
            .dash,
            .period,
            .forward_slash,
            // zig fmt: off
            .@"0", .@"1", .@"2", .@"3", .@"4",
            .@"5", .@"6", .@"7", .@"8", .@"9",
            // zig fmt: on
            .colon,
            .semicolon,
            .open_angle_bracket,
            .equal,
            .close_angle_bracket,
            .question_mark,
            .at,
            // zig fmt: off
            .A, .B, .C, .D, .E, .F, .G, .H, .I, .J, .K, .L, .M,
            .N, .O, .P, .Q, .R, .S, .T, .U, .V, .W, .X, .Y, .Z,
            // zig fmt: on
            .open_square_bracket,
            .backslash,
            .close_square_bracket,
            .caret,
            .underscore,
            .backtick,
            // zig fmt: off
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
            // zig fmt: on
            .open_curly,
            .pipe,
            .close_curly,
            .tilda,
            => |c| {
                const offset: u8 = @intFromEnum(c) - @intFromEnum(Key.space);
                return .{ .action = .{ .add_char = ' ' + offset } };
            },
        },
        2 => if (keybind.buf[0].mods.control) switch (keybind.buf[0].key) {
            .comma => if (keybind.buf[1].mods.control) switch (keybind.buf[1].key) {
                .comma => return .{ .action = .@"open-process" },
                else => {},
            } else {},
            .x => if (keybind.buf[1].mods.control) switch (keybind.buf[1].key) {
                .c => return .{ .action = .quit },
                .f => return .{ .action = .open_file },
                .s => return .{ .action = .save_file },
                else => {},
            } else switch (keybind.buf[1].key) {
                .k => return .{ .action = .kill_pane },
                else => {},
            },
            else => {},
        },
        else => {},
    }
    return switch (keybind.buf[keybind.len - 1].key) {
        .control, .alt => .modifier,
        else => .unbound,
    };
}
