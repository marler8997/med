const OnErr = @This();
const std = @import("std");
const RefString = @import("RefString.zig");

on_err: *const fn(context: *OnErr, msg: RefString) void,

pub fn report(
    self: *OnErr,
    comptime fmt: []const u8,
    args: anytype,
) error{Reported} {
    var msg = RefString.allocFmt(fmt, args) catch |err| switch (err) {
        // if we run out of memory while reporting an error, we're in
        // trouble, just panic
        error.OutOfMemory => @panic("OutOfMemory"),
    };
    defer msg.unref();
    self.on_err(self, msg);
    return error.Reported;
}
