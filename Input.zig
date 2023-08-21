const Input = @This();

const std = @import("std");

pub const Action = enum {
    cursor_back,
    cursor_forward,
    cursor_up,
    cursor_down,
    cursor_line_start,
    cursor_line_end,
    open_file,
    exit,
};


pub const Key = enum {
    control,
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
};
pub const key_count = @typeInfo(Key).Enum.fields.len;
pub const KeyState = enum { up, down };
const max_control_sequence = 2;

key_states: [key_count]KeyState = [1]KeyState { .up } ** key_count,
control_sequence_buf: [max_control_sequence]Key = undefined,
control_sequence_len: u2 = 0,

fn getState(self: *Input, key: Key) *KeyState {
    return &self.key_states[@intFromEnum(key)];
}

pub fn setKeyState(self: *Input, key: Key, state: KeyState) ?Action {
    if (self.getState(key).* == state) return null;
    self.getState(key).* = state;
    if (state == .down) {
        switch (key) {
            .control => {
                self.control_sequence_len = 0;
            },
            else => {},
        }
        if (key != .control and self.getState(.control).* == .down) {
            if (self.control_sequence_len < max_control_sequence) {
                self.control_sequence_buf[self.control_sequence_len] = key;
                self.control_sequence_len += 1;
                switch (self.control_sequence_len) {
                    0 => unreachable,
                    1 => switch (self.control_sequence_buf[0]) {
                        .a => {
                            self.control_sequence_len = 0;
                            return .cursor_line_start;
                        },
                        .b => {
                            self.control_sequence_len = 0;
                            return .cursor_back;
                        },
                        .e => {
                            self.control_sequence_len = 0;
                            return .cursor_line_end;
                        },
                        .f => {
                            self.control_sequence_len = 0;
                            return .cursor_forward;
                        },
                        .n => {
                            self.control_sequence_len = 0;
                            return .cursor_down;
                        },
                        .p => {
                            self.control_sequence_len = 0;
                            return .cursor_up;
                        },
                        .x => {
                            std.log.info("Ctrl-x-", .{});
                        },
                        else => {
                            std.log.info("Ctrl-{s} unknown", .{@tagName(self.control_sequence_buf[0])});
                            self.control_sequence_len = max_control_sequence; // disable
                        },
                    },
                    2 => switch (self.control_sequence_buf[0]) {
                        .x => switch (self.control_sequence_buf[1]) {
                            .c => {
                                self.control_sequence_len = 0;
                                return .exit;
                            },
                            .f => {
                                self.control_sequence_len = 0;
                                return .open_file;
                            },
                            else => {
                                std.log.info("Ctrl-x-{s} unknown", .{@tagName(self.control_sequence_buf[1])});
                            },
                        },
                        else => {
                            std.log.info("Ctrl-{s}-{s} unknown", .{@tagName(self.control_sequence_buf[0]), @tagName(self.control_sequence_buf[1])});
                        },
                    },
                    else => unreachable,
                }
            }
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
