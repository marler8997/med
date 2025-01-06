const Terminal = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Process = @import("TerminalProcessWin32.zig");
const Win32Error = @import("Win32Error.zig");
const platform = @import("platform.zig");

arena_instance: std.heap.ArenaAllocator,

process: ?Process = null,
handles_added: bool = false,

pages: std.DoublyLinkedList(Page) = .{},

command: std.ArrayListUnmanaged(u8) = .{},
command_cursor_pos: usize = 0,

const Page = union {
    raw: [std.mem.page_size]u8,
};

pub fn deinit(self: *Terminal) void {
    if (self.handles_added) {
        std.debug.assert(platform.removeHandle(self.process.?.info.hProcess));
        std.debug.assert(platform.removeHandle(self.process.?.stderr.read));
        std.debug.assert(platform.removeHandle(self.process.?.stdout.read));
        self.handles_added = false;
    }
    if (self.child_spawned) {
        @panic("todo");
        //self.child.?.kill();
    }
    if (self.child) |*child| {
        child.deinit();
    }
    self.arena_instance.deinit();
    self.* = undefined;
}

pub fn start(self: *Terminal) error{StartTerminalProcess}!void {
    if (self.process == null) {
        var win32_err: Win32Error = undefined;
        self.process = Process.start(&win32_err) catch {
            std.log.err("{s} for cmd.exe failed with {}", .{ win32_err.what, win32_err.code.fmt() });
            return error.StartTerminalProcess;
        };
    }
    if (!self.handles_added) {
        std.debug.assert(platform.addHandle(self.process.?.stdout.read, onStdoutReady));
        std.debug.assert(platform.addHandle(self.process.?.stderr.read, onStderrReady));
        std.debug.assert(platform.addHandle(self.process.?.info.hProcess.?, onProcessDied));
        self.handles_added = true;
    }
}

fn onStdoutReady(handle: win32.HANDLE) void {
    onStdReady(handle, .stdout);
}
fn onStderrReady(handle: win32.HANDLE) void {
    onStdReady(handle, .stderr);
}
fn onStdReady(handle: win32.HANDLE, id: enum { stdout, stderr }) void {
    var buf: [4096]u8 = undefined;
    var win32_err: Win32Error = undefined;
    // TODO: how do we ensure this is non-blocking?
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    std.log.info("readFile {s}...", .{@tagName(id)});
    const len = readFile(handle, &buf, &win32_err) catch |err| switch (err) {
        error.Win32 => std.debug.panic(
            "todo: handle {s} failed with {}",
            .{ win32_err.what, win32_err.code.fmt() },
        ),
        error.NoData => {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            std.log.debug("{s} has no data yet", .{@tagName(id)});
            return;
        },
    };
    std.log.info("readFile {s} returned {}", .{ @tagName(id), len });
    if (len == 0) {
        std.debug.panic("TODO: handle {s} stream has closed", .{@tagName(id)});
    }
    std.log.info("got {} bytes from {s}", .{ len, @tagName(id) });
    // const unused = ui.reserveUnused(u8, opt.stdout, opt.stdout_reserve_len) catch |e|
    //     return err.setAny(e, "ReadingStdout");
    // const len = try readFile(self.child.stdout.?.handle, unused, err);
    // opt.stdout.items.len += len;
    // alive.stdout = len > 0;
    // std.log.info("read {} bytes from stdout", .{len});
}
fn onProcessDied(handle: win32.HANDLE) void {
    _ = handle;
    @panic("todo");
}

fn readFile(handle: win32.HANDLE, buf: []u8, out_err: *Win32Error) error{ Win32, NoData }!usize {
    const to_read: u32 = std.math.cast(u32, buf.len) orelse std.math.maxInt(u32);
    var read_result_len: u32 = undefined;
    if (0 == win32.ReadFile(
        handle,
        buf.ptr,
        to_read,
        &read_result_len,
        null,
    )) switch (win32.GetLastError()) {
        .ERROR_BROKEN_PIPE => return 0,
        .ERROR_HANDLE_EOF => return 0,
        .ERROR_NO_DATA => return error.NoData,
        else => |e| return out_err.set("ReadFile", e),
    };
    return read_result_len;
}

pub fn addInput(self: *Terminal, input: []const u8) error{OutOfMemory}!void {
    try self.command.insertSlice(
        self.arena_instance.allocator(),
        self.command_cursor_pos,
        input,
    );
    self.command_cursor_pos += input.len;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    std.log.info("terminal input '{s}'", .{self.command.items});
}

pub fn submitInput(self: *Terminal) void {
    if (self.command.items.len > 0) {
        const process = self.process orelse @panic("todo: report error");

        self.addInput("\r\n") catch @panic("oom");

        {
            var written: u32 = undefined;
            if (0 == win32.WriteFile(
                process.stdin.write,
                self.command.items.ptr,
                @intCast(self.command.items.len),
                &written,
                null,
            )) std.debug.panic("todo: handle WriteFile error {}", .{win32.GetLastError().fmt()});
            if (written != self.command.items.len) std.debug.panic(
                "todo: handle wrote {} bytes out of {}",
                .{ written, self.command.items.len },
            );
        }
        self.command.clearRetainingCapacity();
        self.command_cursor_pos = 0;
    }
}
pub fn @"cursor-back"(self: *Terminal) bool {
    if (self.command_cursor_pos > 0) {
        // TODO: move backward a full utf8 grapheme/codepoint whatever
        self.command_cursor_pos -= 1;
        return true;
    }
    return false;
}
pub fn @"cursor-forward"(self: *Terminal) bool {
    if (self.command_cursor_pos < self.command.items.len) {
        // TODO: move forward a full utf8 grapheme/codepoint whatever
        self.command_cursor_pos += 1;
        return true;
    }
    return false;
}
pub fn @"cursor-line-start"(self: *Terminal) bool {
    if (self.command_cursor_pos > 0) {
        self.command_cursor_pos = 0;
        return true;
    }
    return false;
}
pub fn @"cursor-line-end"(self: *Terminal) bool {
    if (self.command_cursor_pos != self.command.items.len) {
        self.command_cursor_pos = self.command.items.len;
        return true;
    }
    return false;
}

pub fn tab(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal tab", .{});
    return false;
}
pub fn delete(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal delete", .{});
    return false;
}
pub fn backspace(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal backspace", .{});
    return false;
}
pub fn @"kill-line"(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal kill-line", .{});
    return false;
}
