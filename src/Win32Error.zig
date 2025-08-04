const Win32Error = @This();

const win32 = @import("win32").everything;

what: [:0]const u8,
code: win32.WIN32_ERROR,

pub fn set(self: *Win32Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Win32} {
    self.* = .{ .what = what, .code = code };
    return error.Win32;
}
