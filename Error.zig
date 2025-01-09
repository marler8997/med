const Error = @This();

const builtin = @import("builtin");
const std = @import("std");

const win32 = @import("win32").everything;

what: [:0]const u8,
code: switch (builtin.os.tag) {
    .windows => WindowsCode,
    else => PosixCode,
},

pub fn setZig(self: *Error, what: [:0]const u8, code: anyerror) error{Error} {
    self.* = .{ .what = what, .code = .{ .zig = code } };
    return error.Error;
}
pub fn setWin32(self: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
    self.* = .{ .what = what, .code = .{ .win32 = code } };
    return error.Error;
}
pub fn setHresult(self: *Error, what: [:0]const u8, code: i32) error{Error} {
    self.* = .{ .what = what, .code = .{ .hresult = code } };
    return error.Error;
}

const WindowsCode = union(enum) {
    zig: anyerror,
    win32: win32.WIN32_ERROR,
    hresult: win32.HRESULT,
    pub fn format(
        self: WindowsCode,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .zig => |e| try writer.print("error {s}", .{@errorName(e)}),
            .win32 => |c| try c.fmt().format(fmt, options, writer),
            .hresult => |hr| try writer.print("HRESULT 0x{x}", .{@as(u32, @bitCast(hr))}),
        }
    }
};
const PosixCode = union(enum) {
    zig: anyerror,
    errno: i32,
    pub fn format(
        self: PosixCode,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .zig => |e| try writer.print("error {s}", .{@errorName(e)}),
            .errno => |errno| try writer.print("errno {}", .{errno}),
        }
    }
};

pub fn format(
    self: Error,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try writer.print("{s} failed with {}", .{ self.what, self.code });
}
