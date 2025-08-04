const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;

const XY = @import("xy.zig").XY;

const Tty = enum {
    stdout,
    stderr,
    pub fn getHandle(self: Tty) std.posix.fd_t {
        return switch (self) {
            .stdout => std.io.getStdOut().handle,
            .stderr => std.io.getStdErr().handle,
        };
    }
};

pub fn getTerminalSize(tty: Tty) XY(i32) {
    if (builtin.os.tag == .windows) {
        var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (0 == win32.GetConsoleScreenBufferInfo(tty.getHandle(), &info)) {
            std.log.err(
                "GetConsoleScreenBufferInfo on {s} failed, error={}",
                .{ @tagName(tty), win32.GetLastError() },
            );
            std.process.exit(0xff);
        }
        return .{
            .x = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
            .y = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
        };
    } else if (builtin.os.tag == .linux) {
        //const request_term_size = "\x1b[18t";
        var winsz = std.posix.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
        const rv = std.os.linux.ioctl(tty.getHandle(), std.posix.T.IOCGWINSZ, @intFromPtr(&winsz));
        const err = std.posix.errno(rv);

        if (rv >= 0) {
            return .{ .y = winsz.row, .x = winsz.col };
        } else {
            std.process.exit(0);
            //TODO this is a pretty terrible way to handle issues...
            return std.posix.unexpectedErrno(err);
        }
    }
}

fn isTty(tty: Tty) bool {
    if (builtin.os.tag == .windows) {
        var mode: win32.CONSOLE_MODE = undefined;
        if (0 != win32.GetConsoleMode(tty.getHandle(), &mode))
            return true;
        return switch (win32.GetLastError()) {
            .ERROR_INVALID_HANDLE => false,
            else => |e| std.debug.panic("GetConsoleMode failed, error={}", .{e}),
        };
    }
    return std.posix.isatty(tty.getHandle());
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    if (all_args.len <= 1) {
        const stdout_prefix: []const u8 = if (isTty(.stdout)) "" else "NOT ";
        const stderr_prefix: []const u8 = if (isTty(.stderr)) "" else "NOT ";
        var stderr = std.io.bufferedWriter(std.io.getStdErr().writer());
        try stderr.writer().print(
            \\Usage: termtest [stdout|stderr]
            \\   stdout is {s}a tty
            \\   stderr is {s}a tty
            \\
        ,
            .{ stdout_prefix, stderr_prefix },
        );
        try stderr.flush();
        std.process.exit(0xff);
    }

    const args = all_args[1..];
    if (args.len != 1) {
        std.log.err("expected 1 cmdline arg but got {}", .{args.len});
        std.process.exit(0xff);
    }
    const tty_name = args[0];
    const tty: Tty = blk: {
        if (std.mem.eql(u8, tty_name, "stdout")) break :blk .stdout;
        if (std.mem.eql(u8, tty_name, "stderr")) break :blk .stderr;
        std.log.err("expected 'stdout' or 'stderr' but got '{s}'", .{tty_name});
        std.process.exit(0xff);
    };

    if (!isTty(tty)) {
        std.log.warn("{s} is not a tty", .{@tagName(tty)});
    }

    const size = getTerminalSize(tty);
    std.log.info("TerminalSize: {}x{}", .{ size.x, size.y });
}
