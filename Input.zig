const Input = @This();

const std = @import("std");

pub const Action = union(enum) {
    add_char: u8,
    enter,
    cursor_back,
    cursor_forward,
    cursor_up,
    cursor_down,
    cursor_line_start,
    cursor_line_end,
    backspace,
    open_file,
    save_file,
    quit,
};


pub const Key = enum {
    control,
    enter,
    backspace,
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
    _0, _1, _2, _3, _4, _5, _6, _7, _8, _9,
    colon,
    semicolon,
    open_angle_bracket,
    equal,
    close_angle_bracket,
    question_mark,
    at,
    A, B, C, D, E, F, G, H, I, J, K, L, M,
    N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    open_square_bracket,
    backslash,
    close_square_bracket,
    caret,
    underscore,
    backtick,
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    open_curly,
    pipe,
    close_curly,
    tilda,
};
pub const key_count = @typeInfo(Key).Enum.fields.len;
pub const KeyState = enum { up, down };
const max_control_sequence = 2;

key_states: [key_count]KeyState = [1]KeyState { .up } ** key_count,
control_sequence_buf: [max_control_sequence]Key = undefined,
control_sequence_len: u2 = 0,

maybe_status: ?Status = null,
const Status = struct {
    action: ?Action,
    keys_buf: [max_control_sequence]Key,
    keys_len: u2,
};

fn getState(self: Input, key: Key) KeyState {
    return self.key_states[@intFromEnum(key)];
}
fn getStateRef(self: *Input, key: Key) *KeyState {
    return &self.key_states[@intFromEnum(key)];
}

pub fn setKeyState(self: *Input, key: Key, state: KeyState) ?Action {
    const key_state_ptr = self.getStateRef(key);

    var state_modified = false;
    if (key_state_ptr.* == state) {
        if (state == .up) return null;
    } else {
        key_state_ptr.* = state;
        state_modified = true;
    }
    if (state == .down) {
        // clear status if user newly pressed a new key
        if (state_modified) {
            self.maybe_status = null;
        }

        if (self.getStateRef(.control).* == .down) {
            return self.onKeyDownWithControlDown(key);
        } else switch (key) {
            .control => {
                self.control_sequence_len = 0;
            },
            .enter => return Action.enter,
            .backspace => return Action.backspace,
            .escape => return null,
            .space, .bang, .double_quote, .pound,
            .dollar, .percent, .ampersand, .single_quote,
            .open_paren, .close_paren, .star, .plus, .comma,
            .dash, .period, .forward_slash,
            ._0, ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9,
            .colon, .semicolon, .open_angle_bracket, .equal,
            .close_angle_bracket, .question_mark, .at,
            .A, .B, .C, .D, .E, .F, .G, .H, .I, .J, .K, .L, .M,
            .N, .O, .P, .Q, .R, .S, .T, .U, .V, .W, .X, .Y, .Z,
            .open_square_bracket, .backslash, .close_square_bracket,
            .caret, .underscore, .backtick,
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
            .open_curly, .pipe, .close_curly, .tilda,
            => |c| {
                const offset: u8 = @intFromEnum(c) - @intFromEnum(Key.space);
                return Action{ .add_char = ' ' + offset };
            },
        }
    } else {
        switch (key) {
            .control => {
                self.control_sequence_len = 0;
            },
            else => {},
        }
    }

    return null;
}

fn onKeyDownWithControlDown(self: *Input, key: Key) ?Action {
    if (key == .control) return null;

    if (self.control_sequence_len < max_control_sequence) {
        self.control_sequence_buf[self.control_sequence_len] = key;
        self.control_sequence_len += 1;

        const next: union(enum) {
            action: ?Action,
            need_more,
        } = switch (self.control_sequence_len) {
            0 => unreachable,
            1 => switch (self.control_sequence_buf[0]) {
                .a => .{ .action = .cursor_line_start },
                .b => .{ .action = .cursor_back },
                .e => .{ .action = .cursor_line_end },
                .f => .{ .action = .cursor_forward },
                .n => .{ .action = .cursor_down },
                .p => .{ .action = .cursor_up },
                .x => .need_more,
                else => .{ .action = null },
            },
            2 => switch (self.control_sequence_buf[0]) {
                .x => switch (self.control_sequence_buf[1]) {
                    .c => .{ .action = .quit },
                    .f => .{ .action = .open_file },
                    .s => .{ .action = .save_file },
                    else => .{ .action = null },
                },
                else => .{ .action = null },
            },
            3 => unreachable,
        };

        switch (next) {
            .action => |action| {
                self.maybe_status = .{
                    .action = action,
                    .keys_buf = self.control_sequence_buf,
                    .keys_len = self.control_sequence_len,
                };
                self.control_sequence_len = 0;
                return action;
            },
            .need_more => {},
        }
    }
    return null;
}

pub fn formatStatus(self: Input, writer: anytype) !void {
    if (self.control_sequence_len == 0) {
        if (self.maybe_status) |status| {
            try formatSequence(writer, status.keys_buf[0..status.keys_len]);
            try writer.writeAll(" ");
            if (status.action)  |action| {
                try writer.print("({s})", .{@tagName(action)});
            } else {
                try writer.writeAll("is undefined");
            }
        } else if (self.getState(.control) == .down) {
            try writer.writeAll("Ctl-");
        }
    } else {
        try formatSequence(writer, self.control_sequence_buf[0..self.control_sequence_len]);
    }
}

fn formatSequence(writer: anytype, keys: []const Key) !void {
    try writer.writeAll("Ctl-");
    for (keys, 0..) |key, i| {
        if (i > 0) {
            try writer.writeAll("-");
        }
        try writer.print("{s}", .{keyStatusString(key)});
    }
}

fn keyStatusString(key: Key) []const u8 {
    return switch (key) {
        .control => "Ctl",
        .enter => "return",
        .backspace => "backspace",
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
        ._0 => "0", ._1 => "1", ._2 => "2", ._3 => "3", ._4 => "4",
        ._5 => "5", ._6 => "6", ._7 => "7", ._8 => "8", ._9 => "9",
        .colon => ":",
        .semicolon => ";",
        .open_angle_bracket => "<",
        .equal => "=",
        .close_angle_bracket => ">",
        .question_mark => "?",
        .at => "@",
        .A => "A", .B => "B", .C => "C", .D => "D", .E => "E", .F => "F",
        .G => "G", .H => "H", .I => "I", .J => "J", .K => "K", .L => "L",
        .M => "M", .N => "N", .O => "O", .P => "P", .Q => "Q", .R => "R",
        .S => "S", .T => "T", .U => "U", .V => "V", .W => "W", .X => "X",
        .Y => "Y", .Z => "Z",
        .open_square_bracket => "[",
        .backslash => "\\",
        .close_square_bracket => "]",
        .caret => "^",
        .underscore => "_",
        .backtick => "`",
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e", .f => "f",
        .g => "g", .h => "h", .i => "i", .j => "j", .k => "k", .l => "l",
        .m => "m", .n => "n", .o => "o", .p => "p", .q => "q", .r => "r",
        .s => "s", .t => "t", .u => "u", .v => "v", .w => "w", .x => "x",
        .y => "y", .z => "z",
        .open_curly => "{",
        .pipe => "|",
        .close_curly => "}",
        .tilda => "~",
    };
}
