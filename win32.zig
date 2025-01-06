const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const engine = @import("engine.zig");
const cimport = @cImport({
    @cInclude("MedResourceNames.h");
});

const Input = @import("Input.zig");

const win32 = @import("win32").everything;

const gdi = @import("gdi.zig");

// contains declarations that need to be fixed in zigwin32
const win32fix = struct {
    pub extern "user32" fn LoadImageW(
        hInst: ?win32.HINSTANCE,
        name: ?[*:0]align(1) const u16,
        type: win32.GDI_IMAGE_TYPE,
        cx: i32,
        cy: i32,
        flags: win32.IMAGE_FLAGS,
    ) callconv(std.os.windows.WINAPI) ?win32.HANDLE;
    pub extern "user32" fn LoadCursorW(
        hInstance: ?win32.HINSTANCE,
        lpCursorName: ?[*:0]align(1) const u16,
    ) callconv(std.os.windows.WINAPI) ?win32.HCURSOR;
};

const L = win32.L;
const HINSTANCE = win32.HINSTANCE;
const HWND = win32.HWND;
const HICON = win32.HICON;

const XY = @import("xy.zig").XY;

const window_style_ex = win32.WINDOW_EX_STYLE{};
const window_style = win32.WS_OVERLAPPEDWINDOW;

const HandleCallbackFn = *const fn (context: *anyopaque, handle: win32.HANDLE) void;

const default_font_face_name = win32.L("SYSTEM_FIXED_FONT");

const X11Option = if (build_options.enable_x11_backend) bool else void;
const global = struct {
    var x11: X11Option = if (build_options.enable_x11_backend) false else {};
    var gdi_cache: gdi.ObjectCache = .{};
    var font_face_name: [*:0]const u16 = default_font_face_name.ptr;
    var hwnd: win32.HWND = undefined;
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // seperate arrays so we can pass handles directly to the wait function
    var handles: std.ArrayListUnmanaged(win32.HANDLE) = .{};
    var handle_callbacks: std.ArrayListUnmanaged(HandleCallback) = .{};
};

const HandleCallback = struct {
    context: *anyopaque,
    func: HandleCallbackFn,
};

pub fn oom(e: error{OutOfMemory}) noreturn {
    std.log.err("{s}", .{@errorName(e)});
    _ = win32.MessageBoxA(null, "Out of memory", "Med Error", win32.MB_OK);
    std.posix.exit(0xff);
}
pub fn fatalWin32(what: []const u8, err: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, err.fmt() });
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    // TODO: detect if there is a console or not, only show message box
    //       if there is not a console
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic("Out of memory");
    const result = win32.MessageBoxA(null, msg.ptr, null, win32.MB_OK);
    std.log.info("MessageBox result is {}", .{result});
    std.posix.exit(0xff);
}

const WindowPlacementOptions = struct {
    x: ?i32,
    y: ?i32,
};

const WindowPlacement = struct {
    dpi: XY(u32),
    size: XY(i32),
    pos: XY(i32),
    pub fn default(opt: WindowPlacementOptions) WindowPlacement {
        return .{
            .dpi = .{
                .x = 96,
                .y = 96,
            },
            .pos = .{
                .x = if (opt.x) |x| x else win32.CW_USEDEFAULT,
                .y = if (opt.y) |y| y else win32.CW_USEDEFAULT,
            },
            .size = .{
                .x = win32.CW_USEDEFAULT,
                .y = win32.CW_USEDEFAULT,
            },
        };
    }
};

fn calcWindowPlacement(opt: WindowPlacementOptions) WindowPlacement {
    var result = WindowPlacement.default(opt);

    const monitor = win32.MonitorFromPoint(
        .{ .x = 0, .y = 0 },
        win32.MONITOR_DEFAULTTOPRIMARY,
    ) orelse {
        std.log.warn("MonitorFromPoint failed with {}", .{win32.GetLastError().fmt()});
        return result;
    };

    result.dpi = blk: {
        var dpi: XY(u32) = undefined;
        const hr = win32.GetDpiForMonitor(
            monitor,
            win32.MDT_EFFECTIVE_DPI,
            &dpi.x,
            &dpi.y,
        );
        if (hr < 0) {
            std.log.warn("GetDpiForMonitor failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
            return result;
        }
        break :blk dpi;
    };
    std.log.info("primary monitor dpi {}x{}", .{ result.dpi.x, result.dpi.y });

    const work_rect: win32.RECT = blk: {
        var info: win32.MONITORINFO = undefined;
        info.cbSize = @sizeOf(win32.MONITORINFO);
        if (0 == win32.GetMonitorInfoW(monitor, &info)) {
            std.log.warn("GetMonitorInfo failed with {}", .{win32.GetLastError().fmt()});
            return result;
        }
        break :blk info.rcWork;
    };

    const work_size: XY(i32) = .{
        .x = work_rect.right - work_rect.left,
        .y = work_rect.bottom - work_rect.top,
    };
    std.log.info(
        "primary monitor work topleft={},{} size={}x{}",
        .{ work_rect.left, work_rect.top, work_size.x, work_size.y },
    );

    const wanted_size: XY(i32) = .{
        .x = win32.scaleDpi(i32, 800, result.dpi.x),
        .y = win32.scaleDpi(i32, 1200, result.dpi.y),
    };
    result.size = .{
        .x = @min(wanted_size.x, work_size.x),
        .y = @min(wanted_size.y, work_size.y),
    };
    result.pos = .{
        // TODO: maybe we should shift this window away from the center?
        .x = if (opt.x) |x| x else work_rect.left + @divTrunc(work_size.x - result.size.x, 2),
        .y = if (opt.y) |y| y else work_rect.top + @divTrunc(work_size.y - result.size.y, 2),
    };
    return result;
}

pub export fn wWinMain(
    hinstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    cmdline: [*:0]u16,
    cmdshow: c_int,
) c_int {
    _ = hinstance;
    _ = cmdline;
    _ = cmdshow;
    winmain() catch |err| {
        // TODO: put this error information elsewhere, maybe a file, maybe
        //       show it in the error messagebox
        std.log.err("{s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        _ = win32.MessageBoxA(null, @errorName(err), "Med Error", .{ .ICONASTERISK = 1 });
        return -1;
    };
    return 0;
}
fn winmain() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    var cmdline_opt: struct {
        @"window-x": ?i32 = null,
        @"window-y": ?i32 = null,
    } = .{};

    {
        var it = try std.process.ArgIterator.initWithAllocator(arena);
        defer it.deinit();
        std.debug.assert(it.skip()); // skip the executable name
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--x11")) {
                if (build_options.enable_x11_backend) {
                    global.x11 = true;
                    return @import("x11.zig").go();
                } else fatal("the x11 backend was not enabled in this build", .{});
            } else if (std.mem.eql(u8, arg, "--font")) {
                const font = it.next() orelse fatal("missing argument for --font", .{});
                // HACK! std converts from wtf16 to wtf8...and we convert back to wtf16 here!
                global.font_face_name = try std.unicode.wtf8ToWtf16LeAllocZ(arena, font);
            } else if (std.mem.eql(u8, arg, "--window-x")) {
                const str = it.next() orelse fatal("missing argument for --window-x", .{});
                cmdline_opt.@"window-x" = std.fmt.parseInt(i32, str, 10) catch fatal("invalid --window-x value '{s}'", .{str});
            } else if (std.mem.eql(u8, arg, "--window-y")) {
                const str = it.next() orelse fatal("missing argument for --window-y", .{});
                cmdline_opt.@"window-y" = std.fmt.parseInt(i32, str, 10) catch fatal("invalid --window-x value '{s}'", .{str});
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
    }

    const initial_placement = calcWindowPlacement(.{
        .x = cmdline_opt.@"window-x",
        .y = cmdline_opt.@"window-y",
    });
    const icons = getIcons(initial_placement.dpi);

    const CLASS_NAME = L("Med");
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = icons.large,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = icons.small,
    };
    const class_id = win32.RegisterClassExW(&wc);
    if (class_id == 0) {
        std.log.err("RegisterClass failed, error={}", .{win32.GetLastError()});
        std.posix.exit(0xff);
    }

    global.hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME,
        L("Med"),
        window_style,
        initial_placement.pos.x,
        initial_placement.pos.y,
        initial_placement.size.x,
        initial_placement.size.y,
        null, // Parent window
        null, // Menu
        win32.GetModuleHandleW(null), // Instance handle
        null, // Additional application data
    ) orelse {
        std.log.err("CreateWindow failed with {}", .{win32.GetLastError()});
        std.posix.exit(0xff);
    };

    {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            global.hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={}",
            .{ dark_value, win32.GetLastError() },
        );
    }

    _ = win32.ShowWindow(global.hwnd, win32.SW_SHOW);

    while (true) {
        while (global.handles.items.len == 0) {
            var msg: win32.MSG = undefined;
            const result = win32.GetMessageW(&msg, null, 0, 0);
            if (result < 0) fatalWin32("GetMessage", win32.GetLastError());
            if (result == 0) onWmQuit(msg.wParam);
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }

        const wait_result = win32.MsgWaitForMultipleObjectsEx(
            @intCast(global.handles.items.len),
            global.handles.items.ptr,
            win32.INFINITE,
            win32.QS_ALLINPUT,
            .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 },
        );

        if (wait_result < global.handles.items.len) {
            const cb = &global.handle_callbacks.items[wait_result];
            cb.func(cb.context, global.handles.items[wait_result]);
        } else {
            std.debug.assert(wait_result == global.handles.items.len);
        }

        {
            var msg: win32.MSG = undefined;
            while (true) {
                const result = win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE);
                if (result < 0) fatalWin32("PeekMessage", win32.GetLastError());
                if (result == 0) break;
                if (msg.message == win32.WM_QUIT) onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        }
    }
}

fn onWmQuit(wparam: win32.WPARAM) noreturn {
    if (std.math.cast(u32, wparam)) |c| {
        std.log.info("quit {}", .{c});
        win32.ExitProcess(c);
    }
    std.log.info("quit {} (0xffffffff)", .{wparam});
    win32.ExitProcess(0xffffffff);
}

// ============================================================
// The interface for the engine to use
// ============================================================
pub fn quit() void {
    if (build_options.enable_x11_backend) {
        if (global.x11)
            return @import("x11.zig").quit();
    }

    // TODO: this message could get lost if we are inside a modal loop I think
    win32.PostQuitMessage(0);
}

threadlocal var thread_is_panicing = false;
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            arena.allocator(),
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "WinTerm Panic!", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

// NOTE: for now we'll just repaint the whole window
//       no matter what is modified
pub const statusModified = viewModified;
pub const errModified = viewModified;
pub const dialogModified = viewModified;
pub const processModified = viewModified;
pub const paneModified = viewModified;
pub fn viewModified() void {
    if (build_options.enable_x11_backend) {
        if (global.x11)
            return @import("x11.zig").viewModified();
    }

    win32.invalidateHwnd(global.hwnd);
}
pub fn beep() void {
    _ = win32.MessageBeep(@as(u32, @bitCast(win32.MB_OK)));
}

pub fn addHandle(handle: win32.HANDLE, cb: HandleCallback) bool {
    for (global.handles.items) |existing| {
        if (existing == handle) return false;
    }
    global.handles.append(global.arena_instance.allocator(), handle) catch |e| oom(e);
    global.handle_callbacks.append(global.arena_instance.allocator(), cb) catch |e| oom(e);
    return true;
}
pub fn removeHandle(handle: win32.HANDLE) bool {
    _ = handle;
    @panic("todo: implement removeHandle");
}

// ============================================================
// End of the interface for the engine to use
// ============================================================

const WinKey = struct {
    vk: u16,
    extended: bool,
    pub fn eql(self: WinKey, other: WinKey) bool {
        return self.vk == other.vk and self.extended == other.extended;
    }
    pub fn format(
        self: WinKey,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const e_suffix: []const u8 = if (self.extended) "e" else "";
        try writer.print("{}{s}", .{ self.vk, e_suffix });
    }
    fn digit(capitalize: bool, val: u16) Input.Key {
        if (capitalize) return switch (val) {
            0 => Input.Key.close_paren,
            1 => Input.Key.bang,
            2 => Input.Key.at,
            3 => Input.Key.pound,
            4 => Input.Key.dollar,
            5 => Input.Key.percent,
            6 => Input.Key.caret,
            7 => Input.Key.ampersand,
            8 => Input.Key.star,
            9 => Input.Key.open_paren,
            else => unreachable,
        };
        return @enumFromInt(@intFromEnum(Input.Key.@"0") + val);
    }
    pub fn toMed(self: WinKey, capitalize: bool) ?Input.Key {
        if (self.extended) return switch (self.vk) {
            // @intFromEnum(win32.VK_RETURN) => input.key.kp_enter,
            @intFromEnum(win32.VK_CONTROL) => Input.Key.control,
            @intFromEnum(win32.VK_MENU) => Input.Key.alt,
            // @intFromEnum(win32.VK_PRIOR) => Input.key.page_up,
            // @intFromEnum(win32.VK_NEXT) => input.key.page_down,
            // @intFromEnum(win32.VK_END) => input.key.end,
            // @intFromEnum(win32.VK_HOME) => input.key.home,
            // @intFromEnum(win32.VK_LEFT) => input.key.left,
            // @intFromEnum(win32.VK_UP) => input.key.up,
            // @intFromEnum(win32.VK_RIGHT) => input.key.right,
            // @intFromEnum(win32.VK_DOWN) => input.key.down,
            // @intFromEnum(win32.VK_INSERT) => input.key.insert,
            // @intFromEnum(win32.VK_DELETE) => input.key.delete,

            // @intFromEnum(win32.VK_DIVIDE) => input.key.kp_divide,

            else => null,
        };
        return switch (self.vk) {
            @intFromEnum(win32.VK_BACK) => Input.Key.backspace,
            @intFromEnum(win32.VK_TAB) => Input.Key.tab,
            @intFromEnum(win32.VK_RETURN) => Input.Key.enter,
            @intFromEnum(win32.VK_CONTROL) => Input.Key.control,
            @intFromEnum(win32.VK_MENU) => Input.Key.alt,
            // @intFromEnum(win32.VK_PAUSE) => Input.Key.pause,
            // @intFromEnum(win32.VK_CAPITAL) => Input.Key.caps_lock,
            @intFromEnum(win32.VK_ESCAPE) => Input.Key.escape,
            @intFromEnum(win32.VK_SPACE) => Input.Key.space,
            // @intFromEnum(win32.VK_PRIOR) => Input.Key.kp_page_up,
            // @intFromEnum(win32.VK_NEXT) => Input.Key.kp_page_down,
            // @intFromEnum(win32.VK_END) => Input.Key.kp_end,
            // @intFromEnum(win32.VK_HOME) => Input.Key.kp_home,
            // @intFromEnum(win32.VK_LEFT) => Input.Key.kp_left,
            // @intFromEnum(win32.VK_UP) => Input.Key.kp_up,
            // @intFromEnum(win32.VK_RIGHT) => Input.Key.kp_right,
            // @intFromEnum(win32.VK_DOWN) => Input.Key.kp_down,
            // @intFromEnum(win32.VK_SNAPSHOT) => Input.Key.print_screen,
            // @intFromEnum(win32.VK_INSERT) => Input.Key.kp_insert,
            // @intFromEnum(win32.VK_DELETE) => Input.Key.kp_delete,

            '0'...'9' => |ascii| digit(capitalize, ascii - '0'),
            'A'...'Z' => |ascii| @enumFromInt(ascii - 'A' + if (capitalize) @intFromEnum(Input.Key.A) else @intFromEnum(Input.Key.a)),

            // @intFromEnum(win32.VK_LWIN) => Input.Key.left_meta,
            // @intFromEnum(win32.VK_RWIN) => Input.Key.right_meta,
            // @intFromEnum(win32.VK_NUMPAD0) => Input.Key.kp_0,
            // @intFromEnum(win32.VK_NUMPAD1) => Input.Key.kp_1,
            // @intFromEnum(win32.VK_NUMPAD2) => Input.Key.kp_2,
            // @intFromEnum(win32.VK_NUMPAD3) => Input.Key.kp_3,
            // @intFromEnum(win32.VK_NUMPAD4) => Input.Key.kp_4,
            // @intFromEnum(win32.VK_NUMPAD5) => Input.Key.kp_5,
            // @intFromEnum(win32.VK_NUMPAD6) => Input.Key.kp_6,
            // @intFromEnum(win32.VK_NUMPAD7) => Input.Key.kp_7,
            // @intFromEnum(win32.VK_NUMPAD8) => Input.Key.kp_8,
            // @intFromEnum(win32.VK_NUMPAD9) => Input.Key.kp_9,
            // @intFromEnum(win32.VK_MULTIPLY) => Input.Key.kp_multiply,
            // @intFromEnum(win32.VK_ADD) => Input.Key.kp_add,
            // @intFromEnum(win32.VK_SEPARATOR) => Input.Key.kp_separator,
            // @intFromEnum(win32.VK_SUBTRACT) => Input.Key.kp_subtract,
            // @intFromEnum(win32.VK_DECIMAL) => Input.Key.kp_decimal,
            // odd, for some reason the divide key is considered extended?
            //@intFromEnum(win32.VK_DIVIDE) => Input.Key.kp_divide,
            // @intFromEnum(win32.VK_F1) => Input.Key.f1,
            // @intFromEnum(win32.VK_F2) => Input.Key.f2,
            // @intFromEnum(win32.VK_F3) => Input.Key.f3,
            // @intFromEnum(win32.VK_F4) => Input.Key.f4,
            // @intFromEnum(win32.VK_F5) => Input.Key.f5,
            // @intFromEnum(win32.VK_F6) => Input.Key.f6,
            // @intFromEnum(win32.VK_F7) => Input.Key.f8,
            // @intFromEnum(win32.VK_F8) => Input.Key.f8,
            // @intFromEnum(win32.VK_F9) => Input.Key.f9,
            // @intFromEnum(win32.VK_F10) => Input.Key.f10,
            // @intFromEnum(win32.VK_F11) => Input.Key.f11,
            // @intFromEnum(win32.VK_F12) => Input.Key.f12,
            // @intFromEnum(win32.VK_F13) => Input.Key.f13,
            // @intFromEnum(win32.VK_F14) => Input.Key.f14,
            // @intFromEnum(win32.VK_F15) => Input.Key.f15,
            // @intFromEnum(win32.VK_F16) => Input.Key.f16,
            // @intFromEnum(win32.VK_F17) => Input.Key.f17,
            // @intFromEnum(win32.VK_F18) => Input.Key.f18,
            // @intFromEnum(win32.VK_F19) => Input.Key.f19,
            // @intFromEnum(win32.VK_F20) => Input.Key.f20,
            // @intFromEnum(win32.VK_F21) => Input.Key.f21,
            // @intFromEnum(win32.VK_F22) => Input.Key.f22,
            // @intFromEnum(win32.VK_F23) => Input.Key.f23,
            // @intFromEnum(win32.VK_F24) => Input.Key.f24,
            // @intFromEnum(win32.VK_NUMLOCK) => Input.Key.num_lock,
            // @intFromEnum(win32.VK_SCROLL) => Input.Key.scroll_lock,
            // @intFromEnum(win32.VK_LSHIFT) => Input.Key.left_shift,
            //@intFromEnum(win32.VK_10) => Input.Key.left_shift,
            // @intFromEnum(win32.VK_RSHIFT) => Input.Key.right_shift,
            @intFromEnum(win32.VK_LCONTROL) => Input.Key.control,
            //@intFromEnum(win32.VK_11) => Input.Key.left_control,
            @intFromEnum(win32.VK_RCONTROL) => Input.Key.control,
            // @intFromEnum(win32.VK_LMENU) => Input.Key.left_alt,
            //@intFromEnum(win32.VK_12) => Input.Key.left_alt,
            // @intFromEnum(win32.VK_RMENU) => Input.Key.right_alt,
            // @intFromEnum(win32.VK_VOLUME_MUTE) => Input.Key.mute_volume,
            // @intFromEnum(win32.VK_VOLUME_DOWN) => Input.Key.lower_volume,
            // @intFromEnum(win32.VK_VOLUME_UP) => Input.Key.raise_volume,
            // @intFromEnum(win32.VK_MEDIA_NEXT_TRACK) => Input.Key.media_track_next,
            // @intFromEnum(win32.VK_MEDIA_PREV_TRACK) => Input.Key.media_track_previous,
            // @intFromEnum(win32.VK_MEDIA_STOP) => Input.Key.media_stop,
            // @intFromEnum(win32.VK_MEDIA_PLAY_PAUSE) => Input.Key.media_play_pause,
            @intFromEnum(win32.VK_OEM_COMMA) => Input.Key.comma,
            else => null,
        };
    }
};

fn lparamToScanCode(lparam: win32.LPARAM) u8 {
    return @intCast((lparam >> 16) & 0xff);
}

fn wmKeyDown(wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const winkey: WinKey = .{
        .vk = @intCast(0xffff & wparam),
        .extended = (0 != (lparam & 0x1000000)),
    };
    const press_kind: Input.KeyPressKind = if (0 != (lparam & 0x40000000)) .repeat else .initial;

    var keyboard_state: [256]u8 = undefined;
    if (0 == win32.GetKeyboardState(&keyboard_state)) fatalWin32(
        "GetKeyboardState",
        win32.GetLastError(),
    );

    const mods: Input.KeyMods = .{
        .control = (0 != keyboard_state[@intFromEnum(win32.VK_CONTROL)] & 0x80),
    };
    const shift_down = (0 != keyboard_state[@intFromEnum(win32.VK_SHIFT)] & 0x80);
    const caps_lock_on = (0 != (keyboard_state[@intFromEnum(win32.VK_CAPITAL)] & 1));
    const capitalize = shift_down or caps_lock_on;
    if (winkey.toMed(capitalize)) |key| {
        engine.notifyKeyDown(press_kind, .{ .key = key, .mods = mods });
        return;
    }

    var char_buf: [10]u16 = undefined;
    const unicode_result = win32.ToUnicode(
        @intCast(wparam),
        lparamToScanCode(lparam),
        &keyboard_state,
        @ptrCast(&char_buf),
        char_buf.len,
        0,
    );
    if (unicode_result == 0) {
        std.log.warn("unknown key", .{});
        return;
    }

    if (unicode_result < 0)
        return; // dead key

    if (unicode_result != 1) std.debug.panic(
        "TODO: handle multiple unicode chars from one key (result={})",
        .{unicode_result},
    );
    const key: Input.Key = switch (char_buf[0]) {
        ' '...'~' => |c| @enumFromInt(@intFromEnum(Input.Key.space) + (c - ' ')),
        else => |c| {
            const a = if (std.math.cast(u8, c)) |a|
                (if (std.ascii.isPrint(a)) a else '?')
            else
                '?';
            std.debug.panic("TODO: handle character '{c}' {} 0x{x}", .{ a, c, c });
        },
    };
    engine.notifyKeyDown(press_kind, .{ .key = key, .mods = mods });
}

fn WindowProc(
    hwnd: HWND,
    uMsg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            wmKeyDown(wparam, lparam);
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            const dpi = win32.dpiFromHwnd(hwnd);
            const client_size = gdi.getClientSize(hwnd);
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps) orelse fatalWin32("BeginPaint", win32.GetLastError());
            gdi.paint(hdc, dpi, global.font_face_name, client_size, &global.gdi_cache);
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_SIZE => {
            // since we "stretch" the image accross the full window, we
            // always invalidate the full client area on each window resize
            win32.invalidateHwnd(hwnd);
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wparam, lparam);
}

const Icons = struct {
    small: ?HICON,
    large: ?HICON,
};
fn getIcons(dpi: XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);
    std.log.info("icons small={}x{} large={}x{} at dpi {}x{}", .{
        small_x, small_y,
        large_x, large_y,
        dpi.x,   dpi.y,
    });
    const small = win32fix.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MED),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    );
    if (small == null)
        std.debug.panic("LoadImage for small icon failed, error={}", .{win32.GetLastError()});
    const large = win32fix.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MED),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    );
    if (large == null)
        std.debug.panic("LoadImage for large icon failed, error={}", .{win32.GetLastError()});
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}
