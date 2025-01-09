const Process = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Impl = @import("ProcessWin32.zig");
const Error = @import("Error.zig");
const platform = @import("platform.zig");

const PagedMem = @import("pagedmem.zig").PagedMem;

arena_instance: std.heap.ArenaAllocator,

running: ?Running = null,
paged_mem_stdout: PagedMem(std.mem.page_size) = .{},
paged_mem_stderr: PagedMem(std.mem.page_size) = .{},
command: std.ArrayListUnmanaged(u8) = .{},
command_cursor_pos: usize = 0,

pub fn deinit(self: *Process) void {
    if (self.running) |*running| {
        running.deinit();
    }
    self.paged_mem_stdout.deinit();
    self.paged_mem_stderr.deinit();
    // command will be freed when we free the arena
    self.arena_instance.deinit();
    self.* = undefined;
}

fn fatalWin32(what: [:0]const u8, code: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, code.fmt() });
}

const PipeStream = struct {
    overlapped: win32.OVERLAPPED,
    registered: bool,
};

const Running = struct {
    io: Impl.Io,
    kind: union(enum) {
        pipe: struct {
            stdout: PipeStream,
            stderr: PipeStream,
        },
        console: struct {
            thread: ?std.Thread,
        },
    },
    console: Impl.Console,
    impl: Impl,
    pub fn init(process: *Process, io: Impl.Io, console: Impl.Console, impl: Impl) Running {
        std.debug.assert(platform.addHandle(
            impl.hprocess,
            .{ .context = process, .func = onProcessDied },
        ));
        return .{
            .io = io,
            .console = console,
            .impl = impl,
            .kind = switch (io.kind) {
                .pipe => .{ .pipe = .{
                    .stdout = .{
                        .overlapped = std.mem.zeroes(win32.OVERLAPPED),
                        .registered = true,
                    },
                    .stderr = .{
                        .overlapped = std.mem.zeroes(win32.OVERLAPPED),
                        .registered = true,
                    },
                } },
                .console => .{ .console = .{
                    .thread = null,
                } },
            },
        };
    }

    pub fn deinit(self: *Running) void {
        self.console.deinit();

        switch (self.kind) {
            .pipe => |*self_pipe| {
                const impl_pipe = switch (self.io.kind) {
                    .pipe => |*pipe| pipe,
                    .console => unreachable,
                };
                if (0 == win32.CancelIo(impl_pipe.stderr_read)) fatalWin32("CancelIo", win32.GetLastError());
                if (0 == win32.CancelIo(self.io.read_pipe)) fatalWin32("CancelIo", win32.GetLastError());
                if (self_pipe.stderr.registered) {
                    std.debug.assert(platform.removeHandle(impl_pipe.stderr_read));
                }
                if (self_pipe.stdout.registered) {
                    std.debug.assert(platform.removeHandle(self.io.read_pipe));
                }
            },
            .console => |*console| {
                if (console.thread) |thread| {
                    thread.join();
                }
            },
        }
        std.debug.assert(platform.removeHandle(self.impl.hprocess));
        self.impl.deinit();
        self.* = undefined;
    }
};
pub const Kind = enum {
    pipe,
    console,
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const StdoutKind = enum { stdout, stderr };

pub fn start(self: *Process, out_err: *Error, command: []const u8, kind: Kind) error{Error}!void {
    std.debug.assert(self.running == null);

    std.log.info("launching command '{s}'", .{command});

    {
        var io, var start_io = try Impl.Io.init(out_err, kind);
        errdefer io.deinit();
        var start_io_owned = true;
        defer if (start_io_owned) start_io.deinit();
        const console = try Impl.Console.init(out_err, start_io);
        const impl = try Impl.start(out_err, command, &start_io, console);
        start_io_owned = false;
        self.running = Running.init(
            self,
            io,
            console,
            impl,
        );
    }
    const running = &self.running.?;
    switch (running.kind) {
        .pipe => {
            const impl_pipe = switch (running.io.kind) {
                .pipe => |*p| p,
                .console => unreachable,
            };
            std.debug.assert(platform.addHandle(
                running.io.read_pipe,
                .{ .context = self, .func = onStdoutReady },
            ));
            std.debug.assert(platform.addHandle(
                impl_pipe.stderr_read,
                .{ .context = self, .func = onStderrReady },
            ));
            onStdoutReady(self, running.io.read_pipe);
            onStderrReady(self, impl_pipe.stderr_read);
        },
        .console => |*console| {
            std.debug.assert(console.thread == null);
            console.thread = std.Thread.spawn(
                .{},
                readConsoleThread,
                .{running.io.read_pipe},
            ) catch |e| return out_err.setZig("SpawnReadConsoleThread", e);
        },
    }
}

fn onStdoutReady(context: *anyopaque, handle: win32.HANDLE) void {
    onStdReady(context, handle, .stdout);
}
fn onStderrReady(context: *anyopaque, handle: win32.HANDLE) void {
    onStdReady(context, handle, .stderr);
}
fn onStdReady(context: *anyopaque, handle: win32.HANDLE, stream_kind: StdoutKind) void {
    const self: *Process = @alignCast(@ptrCast(context));
    const running: *Running = &self.running.?;
    const pipe = switch (running.kind) {
        .pipe => |*pipe| pipe,
        .console => unreachable,
    };
    const stream: *PipeStream = switch (stream_kind) {
        .stdout => &pipe.stdout,
        .stderr => &pipe.stderr,
    };
    std.debug.assert(stream.registered);

    while (true) {
        const paged_mem: *PagedMem(std.mem.page_size) = switch (stream_kind) {
            .stdout => &self.paged_mem_stdout,
            .stderr => &self.paged_mem_stderr,
        };
        const read_buf = paged_mem.getReadBuf() catch |e| oom(e);
        var read_len: u32 = undefined;
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        std.log.info("ReadFile {s}...", .{@tagName(stream_kind)});
        if (0 == win32.ReadFile(
            handle,
            read_buf.ptr,
            @intCast(read_buf.len),
            &read_len,
            &stream.overlapped,
        )) switch (win32.GetLastError()) {
            .ERROR_IO_PENDING => {
                std.log.info("{s}: io pending", .{@tagName(stream_kind)});
                return;
            },
            .ERROR_BROKEN_PIPE => {
                std.log.info("{s} closed", .{@tagName(stream_kind)});
                std.debug.assert(platform.removeHandle(handle));
                stream.registered = false;
                return;
            },
            .ERROR_HANDLE_EOF => {
                @panic("todo: eof");
            },
            .ERROR_NO_DATA => {
                @panic("todo: nodata");
            },
            else => |e| std.debug.panic("todo: handle error {}", .{e.fmt()}),
            //else => |e| return out_err.set("ReadFile", e),
        };
        if (read_len == 0) {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            //@panic("todo");
            std.log.err("IS THIS OK? Have we unintentially made a busy loop?", .{});
            return;
        }

        const data = read_buf[0..read_len];
        std.log.info(
            "got {} bytes from {s}: '{}'",
            .{ read_len, @tagName(stream_kind), std.zig.fmtEscapes(data) },
        );
        paged_mem.finishRead(read_len);
        platform.processModified();
    }
}
fn onProcessDied(context: *anyopaque, handle: win32.HANDLE) void {
    const self: *Process = @alignCast(@ptrCast(context));
    const running: *Running = &(self.running orelse @panic("possible?"));
    std.debug.assert(running.impl.hprocess == handle);
    running.deinit();
    self.running = null;
}

fn readConsoleThread(
    handle: win32.HANDLE,
) void {
    while (true) {
        var buffer: [std.mem.page_size]u8 = undefined;
        var read_len: u32 = undefined;
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        std.log.info("ReadConsoleThread: ReadFile ...", .{});
        if (0 == win32.ReadFile(
            handle,
            &buffer,
            buffer.len,
            &read_len,
            null,
        )) switch (win32.GetLastError()) {
            .ERROR_BROKEN_PIPE => {
                std.log.info("console output closed", .{});
                return;
                //@panic("TODO");
                // std.log.info("{s} closed", .{@tagName(stream_kind)});
                // std.debug.assert(platform.removeHandle(handle));
                // stream.registered = false;
                // return;
            },
            .ERROR_HANDLE_EOF => {
                @panic("todo: eof");
            },
            .ERROR_NO_DATA => {
                @panic("todo: nodata");
            },
            else => |e| std.debug.panic("todo: handle error {}", .{e.fmt()}),
            //else => |e| return out_err.set("ReadFile", e),
        };
        if (read_len == 0) {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            //@panic("todo");
            std.log.err("IS THIS OK? Have we unintentially made a busy loop?", .{});
            return;
        }

        const data = buffer[0..read_len];
        std.log.info(
            "got {} bytes : '{}'",
            .{ read_len, std.zig.fmtEscapes(data) },
        );
        if (true) @panic("TODO: append data to page");
        //paged_mem.finishRead(read_len);
        platform.processModified();
    }
}

// pub fn getStderrPagedMem(self: *const Process) ?*const PagedMem(std.mem.page_size) {
//     const running = &(self.running orelse return null);
//     return running.paged_mem_stderr;
// }

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

pub fn submitInput(self: *Process, out_err: *Error) error{Error}!bool {
    if (self.running) |*running| {
        self.addInput("\r\n") catch @panic("OOM");

        {
            var written: u32 = undefined;
            // TODO: I think this can block...we might need to do this
            //       on another thread for the pseudo console and/or use
            //       overlapped IO in the other case.
            if (0 == win32.WriteFile(
                running.io.write_pipe,
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
        return true;
    }

    if (self.command.items.len == 0) {
        // TODO: report status, nothing to submit?
        //.reportInfoFmt("no command to execute", .{});
        std.log.info("no command to execute", .{});
        return false;
    }
    // TODO: save command to some sort of history?
    //       maybe we have another paged_mem for command history?
    //       it's common to run the same command multiple times, so
    //       we could use a RefString along with a hash_map/etc as awell
    try self.start(out_err, self.command.items, .pipe);
    //try self.start(out_err, self.command.items, .console);
    self.command.clearRetainingCapacity();
    self.command_cursor_pos = 0;
    return true;
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
