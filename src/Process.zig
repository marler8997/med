const Process = @This();

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const Impl = switch (builtin.os.tag) {
    .windows => @import("ProcessWin32.zig"),
    else => struct {},
};
const Win32Error = @import("Win32Error.zig");
const platform = @import("platform.zig");

const PagedMem = @import("pagedmem.zig").PagedMem;

arena_instance: std.heap.ArenaAllocator,

impl: ?Impl = null,

overlapped_stdout: MaybeOverlapped = maybe_overlapped_null,
overlapped_stderr: MaybeOverlapped = maybe_overlapped_null,
handles_added: bool = false,

paged_mem_stdout: PagedMem(std.heap.page_size_min) = .{},
paged_mem_stderr: PagedMem(std.heap.page_size_min) = .{},

command: std.ArrayListUnmanaged(u8) = .{},
command_cursor_pos: usize = 0,

const Overlapped = switch (builtin.os.tag) {
    .windows => win32.OVERLAPPED,
    else => void,
};
const MaybeOverlapped = switch (builtin.os.tag) {
    .windows => ?win32.OVERLAPPED,
    else => void,
};
const maybe_overlapped_null: MaybeOverlapped = switch (builtin.os.tag) {
    .windows => null,
    else => {},
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn deinit(self: *Process) void {
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

const StdoutKind = enum { stdout, stderr };

pub fn start(self: *Process) error{StartProcess}!void {
    if (builtin.os.tag != .windows) @panic("todo");

    if (self.impl == null) {
        var win32_err: Win32Error = undefined;
        self.impl = Impl.start(&win32_err) catch {
            std.log.err("{s} for cmd.exe failed, error={}", .{ win32_err.what, win32_err.code });
            return error.StartProcess;
        };
    }

    // issue the initial reads
    for (&[_]StdoutKind{ .stdout, .stderr }) |kind| {
        const overlapped: *?win32.OVERLAPPED = switch (kind) {
            .stdout => &self.overlapped_stdout,
            .stderr => &self.overlapped_stderr,
        };
        if (overlapped.* == null) {
            overlapped.* = std.mem.zeroes(win32.OVERLAPPED);
            switch (kind) {
                .stdout => onStdoutReady(self, self.impl.?.stdout.read),
                .stderr => onStderrReady(self, self.impl.?.stderr.read),
            }
        }
    }

    if (!self.handles_added) {
        std.debug.assert(platform.addHandle(self.impl.?.stdout.read, .{ .context = self, .func = onStdoutReady }));
        std.debug.assert(platform.addHandle(self.impl.?.stderr.read, .{ .context = self, .func = onStderrReady }));
        std.debug.assert(platform.addHandle(self.impl.?.info.hProcess.?, .{ .context = self, .func = onProcessDied }));
        self.handles_added = true;
    }
}

fn onStdoutReady(context: *anyopaque, handle: win32.HANDLE) void {
    onStdReady(context, handle, .stdout);
}
fn onStderrReady(context: *anyopaque, handle: win32.HANDLE) void {
    onStdReady(context, handle, .stderr);
}
fn onStdReady(context: *anyopaque, handle: win32.HANDLE, kind: StdoutKind) void {
    const self: *Process = @alignCast(@ptrCast(context));

    while (true) {
        const overlapped: *win32.OVERLAPPED = switch (kind) {
            .stdout => &self.overlapped_stdout.?,
            .stderr => &self.overlapped_stderr.?,
        };
        const paged_mem: *PagedMem(std.heap.page_size_min) = switch (kind) {
            .stdout => &self.paged_mem_stdout,
            .stderr => &self.paged_mem_stderr,
        };
        const read_buf = paged_mem.getReadBuf() catch |e| oom(e);
        var read_len: u32 = undefined;
        if (0 == win32.ReadFile(
            handle,
            read_buf.ptr,
            @intCast(read_buf.len),
            &read_len,
            overlapped,
        )) switch (win32.GetLastError()) {
            .ERROR_IO_PENDING => {
                std.log.info("{s}: io pending", .{@tagName(kind)});
                return;
            },
            .ERROR_BROKEN_PIPE => {
                @panic("todo: broken pipe");
            },
            .ERROR_HANDLE_EOF => {
                @panic("todo: eof");
            },
            .ERROR_NO_DATA => {
                @panic("todo: nodata");
            },
            else => |e| std.debug.panic("todo: handle error {}", .{e}),
            //else => |e| return out_err.set("ReadFile", e),
        };
        if (read_len == 0) @panic("todo");

        const data = read_buf[0..read_len];
        std.log.info("got {} bytes from {s}: '{}'", .{ read_len, @tagName(kind), std.zig.fmtEscapes(data) });
        paged_mem.finishRead(read_len);
        platform.processModified();
    }
}
fn onProcessDied(context: *anyopaque, handle: win32.HANDLE) void {
    _ = context;
    _ = handle;
    @panic("todo");
}

pub fn addInput(self: *Process, input: []const u8) error{OutOfMemory}!void {
    try self.command.insertSlice(
        self.arena_instance.allocator(),
        self.command_cursor_pos,
        input,
    );
    self.command_cursor_pos += input.len;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    std.log.info("terminal input '{s}'", .{self.command.items});
}

pub fn submitInput(self: *Process) void {
    if (self.command.items.len > 0) {
        const impl = self.impl orelse @panic("todo: report error");

        self.addInput("\r\n") catch @panic("oom");

        {
            var written: u32 = undefined;
            if (0 == win32.WriteFile(
                impl.stdin.write,
                self.command.items.ptr,
                @intCast(self.command.items.len),
                &written,
                null,
            )) std.debug.panic("todo: handle WriteFile error {}", .{win32.GetLastError()});
            if (written != self.command.items.len) std.debug.panic(
                "todo: handle wrote {} bytes out of {}",
                .{ written, self.command.items.len },
            );
        }
        self.command.clearRetainingCapacity();
        self.command_cursor_pos = 0;
    }
}
pub fn @"cursor-back"(self: *Process) bool {
    if (self.command_cursor_pos > 0) {
        // TODO: move backward a full utf8 grapheme/codepoint whatever
        self.command_cursor_pos -= 1;
        return true;
    }
    return false;
}
pub fn @"cursor-forward"(self: *Process) bool {
    if (self.command_cursor_pos < self.command.items.len) {
        // TODO: move forward a full utf8 grapheme/codepoint whatever
        self.command_cursor_pos += 1;
        return true;
    }
    return false;
}
pub fn @"cursor-line-start"(self: *Process) bool {
    if (self.command_cursor_pos > 0) {
        self.command_cursor_pos = 0;
        return true;
    }
    return false;
}
pub fn @"cursor-line-end"(self: *Process) bool {
    if (self.command_cursor_pos != self.command.items.len) {
        self.command_cursor_pos = self.command.items.len;
        return true;
    }
    return false;
}

pub fn tab(self: *Process) bool {
    _ = self;
    std.log.err("TODO: implement terminal tab", .{});
    return false;
}
pub fn delete(self: *Process) bool {
    _ = self;
    std.log.err("TODO: implement terminal delete", .{});
    return false;
}
pub fn backspace(self: *Process) bool {
    if (self.command_cursor_pos > 0) {
        self.command_cursor_pos -= 1;
        _ = self.command.orderedRemove(self.command_cursor_pos);
        return true;
    }
    return false;
}
pub fn @"kill-line"(self: *Process) bool {
    _ = self;
    std.log.err("TODO: implement terminal kill-line", .{});
    return false;
}
