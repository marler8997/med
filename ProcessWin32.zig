const ProcessWin32 = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Error = @import("Error.zig");
const Process = @import("Process.zig");

job: win32.HANDLE,
hprocess: win32.HANDLE,

pub fn deinit(self: *ProcessWin32) void {
    win32.closeHandle(self.hprocess);
    win32.closeHandle(self.job);
    self.* = undefined;
}

pub const Io = struct {
    write_pipe: win32.HANDLE,
    read_pipe: win32.HANDLE,
    kind: union(Process.Kind) {
        pipe: struct {
            stderr_read: win32.HANDLE,
        },
        console,
    },
    pub fn deinit(self: *Io) void {
        switch (self.kind) {
            .pipe => |*pipe| {
                win32.closeHandle(pipe.stderr_read);
            },
            .console => {},
        }
        win32.closeHandle(self.read_pipe);
        win32.closeHandle(self.write_pipe);
    }
    pub fn init(
        out_err: *Error,
        kind: Process.Kind,
    ) error{Error}!struct { Io, StartIo } {
        const write_pipe = try Pipe.initSync(out_err);
        errdefer closePipe(write_pipe.read, write_pipe.write);
        try setInherit(out_err, write_pipe.write, false);

        const read_pipe = switch (kind) {
            .pipe => try Pipe.initAsync(out_err),
            .console => try Pipe.initSync(out_err),
        };
        errdefer closePipe(read_pipe.read, read_pipe.write);
        try setInherit(out_err, read_pipe.read, false);

        const stderr_pipe = switch (kind) {
            .pipe => try Pipe.initAsync(out_err),
            .console => undefined,
        };
        errdefer switch (kind) {
            .pipe => closePipe(stderr_pipe.read, stderr_pipe.write),
            .console => {},
        };
        // TODO: is this right?
        switch (kind) {
            .pipe => try setInherit(out_err, stderr_pipe.read, false),
            .console => {},
        }

        return .{
            .{
                .write_pipe = write_pipe.write,
                .read_pipe = read_pipe.read,
                .kind = switch (kind) {
                    .pipe => .{ .pipe = .{ .stderr_read = stderr_pipe.read } },
                    .console => .console,
                },
            },
            switch (kind) {
                .pipe => .{ .pipe = .{
                    .stdin = write_pipe.read,
                    .stdout = read_pipe.write,
                    .stderr = stderr_pipe.write,
                } },
                .console => .{ .console = .{
                    .input = write_pipe.read,
                    .output = read_pipe.write,
                } },
            },
        };
    }
};
pub const StartIo = union(Process.Kind) {
    pipe: struct {
        stdin: win32.HANDLE,
        stdout: win32.HANDLE,
        stderr: win32.HANDLE,
    },
    console: struct {
        input: win32.HANDLE,
        output: win32.HANDLE,
    },
    pub fn deinit(self: *StartIo) void {
        switch (self.*) {
            .pipe => |*pipe| {
                win32.closeHandle(pipe.stderr);
                win32.closeHandle(pipe.stdout);
                win32.closeHandle(pipe.stdin);
            },
            .console => |*console| {
                win32.closeHandle(console.output);
                win32.closeHandle(console.input);
            },
        }
    }
};
pub const Console = union(Process.Kind) {
    pipe,
    console: win32.HPCON,
    pub fn deinit(self: *Console) void {
        switch (self.*) {
            .pipe => {},
            .console => |hpcon| win32.ClosePseudoConsole(hpcon),
        }
        self.* = undefined;
    }
    pub fn init(out_err: *Error, start_io: StartIo) error{Error}!Console {
        switch (start_io) {
            .pipe => return .pipe,
            .console => |*console_io| {
                var hpcon: win32.HPCON = undefined;
                {
                    const hr = win32.CreatePseudoConsole(
                        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                        .{ .X = 69, .Y = 42 },
                        console_io.input,
                        console_io.output,
                        0,
                        @ptrCast(&hpcon),
                    );
                    if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
                }
                return .{ .console = hpcon };
            },
        }
    }
};

pub fn start(
    out_err: *Error,
    cmd_utf8: []const u8,
    start_io: *StartIo,
    console: Console,
) error{Error}!ProcessWin32 {
    var cmd_fba_buf: [1000]u8 = undefined;
    var cmd_fba = std.heap.FixedBufferAllocator.init(&cmd_fba_buf);
    const cmd_wide = std.unicode.utf8ToUtf16LeAllocZ(
        cmd_fba.allocator(),
        cmd_utf8,
    ) catch |err| switch (err) {
        error.OutOfMemory => return out_err.setZig("decode command", error.TodoImplementSupportForLargeCommands),
        error.InvalidUtf8 => |e| return out_err.setZig("decode command", e),
    };

    const max_attr_list_size = 100; // actual size should be 48, 100 to be safe
    var attr_list_buf: [max_attr_list_size]u8 = undefined;
    var attr_list_size: usize = undefined;
    switch (console) {
        .pipe => {},
        .console => |hpcon| {
            if (0 == win32.InitializeProcThreadAttributeList(&attr_list_buf, 1, 0, &attr_list_size))
                return out_err.setWin32("InitializeProcThreadAttributeList", win32.GetLastError());
            if (0 == win32.UpdateProcThreadAttribute(
                &attr_list_buf,
                0,
                win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                hpcon,
                @sizeOf(@TypeOf(hpcon)),
                null,
                null,
            )) return out_err.setWin32("UpdateProcThreadAttribute", win32.GetLastError());
        },
    }
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO DeleteThreadProcAttributeList

    var startup_info = win32.STARTUPINFOEXW{
        .StartupInfo = .{
            .cb = @sizeOf(win32.STARTUPINFOEXW),
            .hStdError = switch (start_io.*) {
                .pipe => |*pipe| pipe.stderr,
                .console => null,
            },
            .hStdOutput = switch (start_io.*) {
                .pipe => |*pipe| pipe.stdout,
                .console => null,
            },
            .hStdInput = switch (start_io.*) {
                .pipe => |*pipe| pipe.stdin,
                .console => null,
            },
            .dwFlags = .{
                .USESTDHANDLES = switch (start_io.*) {
                    .pipe => 1,
                    .console => 0,
                },
            },

            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        },
        .lpAttributeList = switch (start_io.*) {
            .pipe => null,
            .console => &attr_list_buf,
        },
    };

    var process_info: win32.PROCESS_INFORMATION = undefined;
    if (0 == win32.CreateProcessW(
        null,
        cmd_wide,
        null,
        null,
        1,
        // switch (console) {
        //     .pipe => 1,
        //     .console => 0,
        // },
        .{
            .CREATE_NO_WINDOW = 1,
            .CREATE_SUSPENDED = 1,
            .EXTENDED_STARTUPINFO_PRESENT = 1,
        },
        null,
        null,
        &startup_info.StartupInfo,
        &process_info,
    )) return out_err.setWin32("CreateProcess", win32.GetLastError());
    defer win32.closeHandle(process_info.hThread.?);
    errdefer win32.closeHandle(process_info.hProcess.?);

    // The job object allows us to automatically kill our child process
    // if our process dies.
    const job = win32.CreateJobObjectW(null, null) orelse return out_err.setWin32(
        "CreateJobObject",
        win32.GetLastError(),
    );
    errdefer win32.closeHandle(job);

    {
        var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (0 == win32.SetInformationJobObject(
            job,
            win32.JobObjectExtendedLimitInformation,
            &info,
            @sizeOf(@TypeOf(info)),
        )) return out_err.setWin32("SetInformationJobObject", win32.GetLastError());
    }

    if (0 == win32.AssignProcessToJobObject(job, process_info.hProcess)) return out_err.setWin32(
        "AssignProcessToJobObject",
        win32.GetLastError(),
    );

    {
        const suspend_count = win32.ResumeThread(process_info.hThread);
        if (suspend_count == -1) return out_err.setWin32("ResumeThread", win32.GetLastError());
    }

    start_io.deinit();
    start_io.* = undefined;
    return .{
        .job = job,
        .hprocess = process_info.hProcess.?,
    };
}

var pipe_name_counter = std.atomic.Value(u32).init(1);

fn closePipe(a: win32.HANDLE, b: win32.HANDLE) void {
    win32.closeHandle(a);
    win32.closeHandle(b);
}

const Pipe = struct {
    read: win32.HANDLE,
    write: win32.HANDLE,

    pub fn initSync(out_err: *Error) error{Error}!Pipe {
        var sec_attr = win32.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
            .bInheritHandle = 1,
            .lpSecurityDescriptor = null,
        };
        var read: win32.HANDLE = undefined;
        var write: win32.HANDLE = undefined;
        if (0 == win32.CreatePipe(@ptrCast(&read), @ptrCast(&write), &sec_attr, 0)) return out_err.setWin32(
            "CreatePipe",
            win32.GetLastError(),
        );
        errdefer closePipe(read, write);
        return .{ .read = read, .write = write };
    }
    fn initAsync(out_err: *Error) error{Error}!Pipe {
        var tmp_bufw: [128]u16 = undefined;
        var sec_attr = win32.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
            .bInheritHandle = 1,
            .lpSecurityDescriptor = null,
        };

        // Anonymous pipes are built upon Named pipes.
        // https://docs.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe
        // Asynchronous (overlapped) read and write operations are not supported by anonymous pipes.
        // https://docs.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations
        const pipe_path = blk: {
            var tmp_buf: [128]u8 = undefined;
            // Forge a random path for the pipe.
            const pipe_path = std.fmt.bufPrintZ(
                &tmp_buf,
                "\\\\.\\pipe\\zig-childprocess-{d}-{d}",
                .{ win32.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
            ) catch unreachable;
            const len = std.unicode.wtf8ToWtf16Le(&tmp_bufw, pipe_path) catch unreachable;
            tmp_bufw[len] = 0;
            break :blk tmp_bufw[0..len :0];
        };

        // Create the read handle that can be used with overlapped IO ops.
        const read = win32.CreateNamedPipeW(
            pipe_path.ptr,
            .{
                .FILE_ATTRIBUTE_READONLY = 1,
                .FILE_FLAG_OVERLAPPED = 1,
            },
            .{},
            1,
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: what the heck should I set these to?
            std.mem.page_size,
            std.mem.page_size,
            0,
            &sec_attr,
        );
        if (read == win32.INVALID_HANDLE_VALUE) return out_err.setWin32(
            "CreateNamedPipe",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(read);

        const write = win32.CreateFileW(
            pipe_path.ptr,
            win32.FILE_GENERIC_WRITE,
            .{}, // no sharing
            &sec_attr,
            win32.OPEN_EXISTING,
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        );
        if (write == win32.INVALID_HANDLE_VALUE) return out_err.setWin32(
            "CreateNamedPipe",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(write.?);

        return .{ .read = read, .write = write };
    }
};

fn setInherit(out_err: *Error, handle: win32.HANDLE, enable: bool) error{Error}!void {
    if (0 == win32.SetHandleInformation(
        handle,
        @bitCast(win32.HANDLE_FLAGS{ .INHERIT = 1 }),
        .{ .INHERIT = if (enable) 1 else 0 },
    )) return out_err.setWin32(
        "SetHandleInformation",
        win32.GetLastError(),
    );
}
