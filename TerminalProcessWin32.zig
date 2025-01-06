const Process = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Win32Error = @import("Win32Error.zig");

job: win32.HANDLE,
stdin: Pipe,
stdout: Pipe,
stderr: Pipe,
info: win32.PROCESS_INFORMATION,

pub fn start(out_err: *Win32Error) error{Win32}!Process {
    // The job object allows us to automatically kill our child process
    // if our process dies.
    const job = win32.CreateJobObjectW(null, null) orelse return out_err.set(
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
        )) return out_err.set("SetInformationJobObject", win32.GetLastError());
    }

    var stdin = try Pipe.init(out_err, .write);
    errdefer stdin.deinit();
    try setInherit(out_err, stdin.write);
    //try win32.SetHandleInformation(read_handle, windows.HANDLE_FLAG_INHERIT, 0);
    //rd.* = read_handle;
    //wr.* = write_handle;

    var stdout = try Pipe.init(out_err, .read);
    errdefer stdout.deinit();
    try setInherit(out_err, stdout.read);
    //try setNonBlocking(out_err, stdout.read);

    var stderr = try Pipe.init(out_err, .read);
    errdefer stderr.deinit();
    try setInherit(out_err, stderr.read);
    //try setNonBlocking(out_err, stdout.read);

    var startup_info = win32.STARTUPINFOW{
        .cb = @sizeOf(win32.STARTUPINFOW),
        .hStdError = stderr.write,
        .hStdOutput = stdout.write,
        .hStdInput = stdin.read,
        .dwFlags = win32.STARTF_USESTDHANDLES,

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
    };
    var process_info: win32.PROCESS_INFORMATION = undefined;
    if (0 == win32.CreateProcessW(
        win32.L("C:\\Windows\\System32\\cmd.exe"),
        null,
        null,
        null,
        1,
        .{ .CREATE_NO_WINDOW = 1, .CREATE_SUSPENDED = 1 },
        null,
        null,
        &startup_info,
        &process_info,
    )) return out_err.set("CreateProcess", win32.GetLastError());
    errdefer deinitProcess(&process_info);

    if (0 == win32.AssignProcessToJobObject(job, process_info.hProcess)) return out_err.set(
        "AssignProcessToJobObject",
        win32.GetLastError(),
    );

    {
        const suspend_count = win32.ResumeThread(process_info.hThread);
        if (suspend_count == -1) return out_err.set("ResumeThread", win32.GetLastError());
    }
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //std.log.info("spawned cmd.exe {}", .{process_info});
    return .{
        .job = job,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
        .info = process_info,
    };
}

pub fn deinit(self: *Process) void {
    deinitProcess(self.info);
    self.stderr.deinit();
    self.stdout.deinit();
    self.stdin.deinit();
    win32.closeHandle(self.job);
    self.job = undefined;
}

fn deinitProcess(
    info: *win32.PROCESS_INFORMATION,
) void {
    win32.closeHandle(info.hThread.?);
    win32.closeHandle(info.hProcess.?);
    info.* = undefined;
}

var pipe_name_counter = std.atomic.Value(u32).init(1);

const Pipe = struct {
    read: win32.HANDLE,
    write: win32.HANDLE,

    fn deinit(self: *Pipe) void {
        win32.closeHandle(self.read);
        win32.closeHandle(self.write);
        self.* = undefined;
    }
    fn init(out_err: *Win32Error, direction: enum { read, write }) error{Win32}!Pipe {
        //rd: *?windows.HANDLE, wr: *?windows.HANDLE,
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
            .{
                .NOWAIT = switch (direction) {
                    //.read => 1,
                    .read => 0,
                    .write => 0,
                },
            },
            1,
            4096,
            4096,
            0,
            &sec_attr,
        );
        if (read == win32.INVALID_HANDLE_VALUE) return out_err.set(
            "CreateNamedPipe",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(read.?);

        const write = win32.CreateFileW(
            pipe_path.ptr,
            win32.FILE_GENERIC_WRITE,
            .{}, // no sharing
            &sec_attr,
            win32.OPEN_EXISTING,
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        );
        if (write == win32.INVALID_HANDLE_VALUE) return out_err.set(
            "CreateNamedPipe",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(write.?);
        return .{
            .read = read.?,
            .write = write,
        };
    }
};

// fn setNonBlocking(out_err: *Win32Error, handle: win32.HANDLE) error{Win32}!void {
//     var mode: win32.NAMED_PIPE_MODE = .{ .NOWAIT = 1 };
//     if (0 == win32.SetNamedPipeHandleState(handle, &mode, null, null)) {
//         return out_err.set("SetNamedPipeHandleState", win32.GetLastError());
//     }
// }
fn setInherit(out_err: *Win32Error, handle: win32.HANDLE) error{Win32}!void {
    if (0 == win32.SetHandleInformation(
        handle,
        @bitCast(win32.HANDLE_FLAGS{ .INHERIT = 1 }),
        .{ .INHERIT = 1 },
    )) return out_err.set(
        "SetHandleInformation",
        win32.GetLastError(),
    );
}
