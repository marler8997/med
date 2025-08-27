const Error = @This();

what: [:0]const u8,
code: union(enum) {
    any: anyerror,
    win32: win32.WIN32_ERROR,
},

pub fn setAny(out_err: *Error, what: [:0]const u8, any: anyerror) error{Error} {
    out_err.* = .{ .what = what, .code = .{ .any = any } };
    return error.Error;
}
pub fn setWin32(out_err: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
    out_err.* = .{ .what = what, .code = .{ .win32 = code } };
    return error.Error;
}

pub fn format(
    self: Error,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    switch (self.code) {
        .any => |e| try writer.print("{s} failed with {s}", .{ self.what, @errorName(e) }),
        .win32 => |e| try writer.print("{s} failed, error={}", .{ self.what, e }),
    }
}

const std = @import("std");
const zin = @import("zin");
const win32 = zin.platform.win32;
