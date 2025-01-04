const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const CmdlineOpt = @import("CmdlineOpt.zig");
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
const CW_USEDEFAULT = win32.CW_USEDEFAULT;
const MSG = win32.MSG;
const HWND = win32.HWND;
const HICON = win32.HICON;

const XY = @import("xy.zig").XY;

const window_style_ex = win32.WINDOW_EX_STYLE{};
const window_style = win32.WS_OVERLAPPEDWINDOW;

const global = struct {
    var x11: if (build_options.enable_x11_backend) bool else void = undefined;
    var gdi_cache: gdi.ObjectCache = .{};
    var hwnd: win32.HWND = undefined;
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

pub fn go(cmdline_opt: CmdlineOpt) !void {
    if (build_options.enable_x11_backend) {
        global.x11 = cmdline_opt.x11;
        if (cmdline_opt.x11) {
            return @import("x11.zig").go(cmdline_opt);
        }
    }
    const icons = getIcons();

    const CLASS_NAME = L("Med");
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = icons.large,
        .hCursor = null,
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
        CW_USEDEFAULT, // x
        CW_USEDEFAULT, // y
        0, // width,
        0, // height
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

    const font_size = gdi.getFontSize(i32, win32.dpiFromHwnd(global.hwnd), &global.gdi_cache);
    resizeWindowToViewport(font_size);

    _ = win32.ShowWindow(global.hwnd, win32.SW_SHOW);
    var msg: MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        // No need for TranslateMessage since we don't use WM_*CHAR messages
        //_ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

// ================================================================================
// The interface for the engine to use
// ================================================================================
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
pub fn viewModified() void {
    if (build_options.enable_x11_backend) {
        if (global.x11)
            return @import("x11.zig").viewModified();
    }

    win32.invalidateHwnd(global.hwnd);
}

fn resizeWindowToViewport(font_size: XY(i32)) void {
    const window_size: XY(i32) = blk: {
        var rect = win32.RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(font_size.x * engine.global_view.viewport_size.x),
            .bottom = @intCast(font_size.y * engine.global_view.viewport_size.y),
        };
        std.debug.assert(0 != win32.AdjustWindowRectEx(
            &rect,
            window_style,
            0,
            window_style_ex,
        ));
        break :blk .{
            .x = rect.right - rect.left,
            .y = rect.bottom - rect.top,
        };
    };
    std.debug.assert(0 != win32.SetWindowPos(
        global.hwnd,
        null,
        0,
        0, // position
        window_size.x,
        window_size.y,
        win32.SET_WINDOW_POS_FLAGS{
            .NOZORDER = 1,
            .NOMOVE = 1,
        },
    ));
}
// ================================================================================
// End of the interface for the engine to use
// ================================================================================

fn lparamToScanCode(lparam: win32.LPARAM) u8 {
    return @intCast((lparam >> 16) & 0xff);
}

fn unicodeToKey(wparam: win32.WPARAM, lparam: win32.LPARAM) ?Input.Key {
    var keyboard_state: [256]u8 = undefined;
    if (0 == win32.GetKeyboardState(&keyboard_state))
        std.debug.panic("GetKeyboardState failed, error={}", .{win32.GetLastError()});
    var char_buf: [10]u16 = undefined;
    const unicode_result = win32.ToUnicode(
        @intCast(wparam),
        lparamToScanCode(lparam),
        &keyboard_state,
        @ptrCast(&char_buf),
        char_buf.len,
        0,
    );
    if (unicode_result == 0)
        return null; // no translation

    if (unicode_result < 0)
        return null; // dead key

    if (unicode_result != 1) std.debug.panic(
        "is it possible for a single key event to create {} characters?",
        .{unicode_result},
    );
    return switch (char_buf[0]) {
        // NOTE: these escape codes are triggered by typing Ctrl+<KEY> where
        //       Key is in the ascii chart range '@' to '_'.
        //       Note that the uppercase ascii value is triggered whether or not
        //       the user typed it as uppercase (with shift pressed).  We always
        //       treat it as the lowercase version (emacs does the same thing).
        0...31 => |c| @as(Input.Key, @enumFromInt(@intFromEnum(Input.Key.at) + c)).lower(),
        ' '...'~' => |c| @enumFromInt(@intFromEnum(Input.Key.space) + (c - ' ')),
        else => |c| {
            const a = if (std.math.cast(u8, c)) |a|
                (if (std.ascii.isPrint(a)) a else '?')
            else
                '?';
            std.debug.panic("TODO: handle character '{c}' {} 0x{x}", .{ a, c, c });
        },
    };
}

fn wmKeyToKey(wparam: win32.WPARAM, lparam: win32.LPARAM) ?Input.Key {
    // NOTE: some special keys have to be intercepted before we try
    //       interpreting them as unicode text, because there are multiple
    //       keys that map to the same unicode text.
    const maybe_special_key: ?Input.Key = switch (wparam) {
        // Return immediately to avoid conflict with CTL-h (ascii 8 backspace)
        @intFromEnum(win32.VK_BACK) => return .backspace,
        // Return immediately to avoid conflict with CTL-m (ascii 13 carriage return)
        @intFromEnum(win32.VK_RETURN) => return .enter,
        @intFromEnum(win32.VK_CONTROL) => .control,

        // These codes are normally handled by unicodeToKey unless Ctrl is
        // down while it's typed
        //@intFromEnum(win32.VK_OEM_MINUS) => .dash,

        else => null,
    };
    const maybe_unicode_key = unicodeToKey(wparam, lparam);

    if (maybe_special_key) |special_key| {
        if (maybe_unicode_key) |unicode_key| std.debug.panic(
            "both key interp methods have values: special={s} unicode={s}",
            .{ @tagName(special_key), @tagName(unicode_key) },
        );
        return special_key;
    }
    return maybe_unicode_key;
}

fn wmKey(wparam: win32.WPARAM, lparam: win32.LPARAM, state: Input.KeyState) void {
    const key = wmKeyToKey(wparam, lparam) orelse {
        std.log.info("unhandled vkey {}(0x{0x}) {s}", .{ wparam, @tagName(state) });
        return;
    };
    std.log.info("{s} {s}", .{ @tagName(key), @tagName(state) });
    engine.notifyKeyEvent(key, state);
}

fn WindowProc(
    hwnd: HWND,
    uMsg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_KEYDOWN => {
            wmKey(wparam, lparam, .down);
            return 0;
        },
        win32.WM_KEYUP => {
            wmKey(wparam, lparam, .up);
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            const dpi = win32.dpiFromHwnd(hwnd);
            const font_size = gdi.getFontSize(i32, dpi, &global.gdi_cache);
            gdi.paint(hwnd, dpi, font_size, &global.gdi_cache);
            return 0;
        },
        win32.WM_SIZE => {
            // since we "stretch" the image accross the full window, we
            // always invalidate the full client area on each window resize
            std.debug.assert(0 != win32.InvalidateRect(hwnd, null, 0));
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wparam, lparam);
}

const Icons = struct {
    small: ?HICON,
    large: ?HICON,
};
fn getIcons() Icons {
    const small_x = win32.GetSystemMetrics(.CXSMICON);
    const small_y = win32.GetSystemMetrics(.CYSMICON);
    const large_x = win32.GetSystemMetrics(.CXICON);
    const large_y = win32.GetSystemMetrics(.CYICON);
    std.log.info("icons small={}x{} large={}x{}", .{
        small_x, small_y,
        large_x, large_y,
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
