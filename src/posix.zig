const std = @import("std");
pub fn main() !void {
    try @import("x11.zig").go();
}
