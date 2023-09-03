const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const CmdlineOpt = @import("CmdlineOpt.zig");
const engine = @import("engine.zig");

const Input = @import("Input.zig");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").ui.input.keyboard_and_mouse;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
};
const L = win32.L;
const HINSTANCE = win32.HINSTANCE;
const CW_USEDEFAULT = win32.CW_USEDEFAULT;
const MSG = win32.MSG;
const HWND = win32.HWND;

const XY = @import("xy.zig").XY;

const global = struct {
    pub var x11: if (build_options.enable_x11_backend) bool else void = undefined;
    pub var hWnd: win32.HWND = undefined;
};

pub fn fatal(hWnd: ?win32.HWND, comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    // TODO: detect if there is a console or not, only show message box
    //       if there is not a console
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic("Out of memory");
    const result = win32.MessageBoxA(hWnd, msg.ptr, null, win32.MB_OK);
    std.log.info("MessageBox result is {}", .{result});
    std.os.exit(0xff);
}

pub fn go(cmdline_opt: CmdlineOpt) !void {
    if (build_options.enable_x11_backend) {
        global.x11 = cmdline_opt.x11;
        if (cmdline_opt.x11) {
            return @import("x11.zig").go(cmdline_opt);
        }
    }

    const CLASS_NAME = L("Med");
    const wc = win32.WNDCLASS{
        .style = @enumFromInt(0),
        .lpfnWndProc = WindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandle(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
    };
    const class_id = win32.RegisterClass(&wc);
    if (class_id == 0) {
        std.log.err("RegisterClass failed, error={}", .{win32.GetLastError()});
        std.os.exit(0xff);
    }

    const window_style = win32.WS_OVERLAPPEDWINDOW;
    const size: XY(i32) = blk: {
        const default = XY(i32){ .x = CW_USEDEFAULT, .y = CW_USEDEFAULT };
        var client_rect: win32.RECT = undefined;
        client_rect = .{
            .left = 0, .top = 0,
            .right  = std.math.cast(i32, 400) orelse break :blk default,
            .bottom = std.math.cast(i32, 400) orelse break :blk default,
        };
        std.debug.assert(0 != win32.AdjustWindowRect(&client_rect, window_style, 0));
        break :blk .{
            .x = client_rect.right - client_rect.left,
            .y = client_rect.bottom - client_rect.top,
        };
    };

    global.hWnd = win32.CreateWindowEx(
        @enumFromInt(0), // Optional window styles.
        CLASS_NAME, // Window class
        // TODO: use the image name in the title if we have one
        L("Image Viewer"),
        window_style,
        // position
        CW_USEDEFAULT, CW_USEDEFAULT,
        size.x, size.y,
        null, // Parent window
        null, // Menu
        win32.GetModuleHandle(null), // Instance handle
        null // Additional application data
    ) orelse {
        std.log.err("CreateWindow failed with {}", .{win32.GetLastError()});
        std.os.exit(0xff);
    };
    _ = win32.ShowWindow(global.hWnd, win32.SW_SHOW);
    var msg: MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
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
pub fn renderModified() void {
    if (build_options.enable_x11_backend) {
        if (global.x11)
            return @import("x11.zig").renderModified();
    }

    if (win32.TRUE != win32.InvalidateRect(global.hWnd, null, 0))
        fatal(global.hWnd, "InvalidateRect failed, error={}", .{win32.GetLastError()});
}
// ================================================================================
// End of the interface for the engine to use
// ================================================================================



fn vkToKey(vk: u8) ?Input.Key {
    return switch (vk) {
        @intFromEnum(win32.VK_CONTROL) => .control,
        'A'...'Z' => @enumFromInt(@intFromEnum(Input.Key.a) + (vk - 'A')),
        else => null,
    };
}

fn wmKey(wParam: win32.WPARAM, state: Input.KeyState) void {
    if (vkToKey(@intCast(0xff & wParam))) |key| {
        std.log.info("{s} {s}", .{@tagName(key), @tagName(state)});
        engine.notifyKeyEvent(key, state);
    } else {
        std.log.info("unhandled vkey {} {s}", .{wParam, @tagName(state)});
    }
}

fn WindowProc(
    hWnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_KEYDOWN => wmKey(wParam, .down),
        win32.WM_KEYUP => wmKey(wParam, .up),
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_PAINT => {
            paint(hWnd);
            return 0;
        },
        win32.WM_SIZE => {
            // since we "stretch" the image accross the full window, we
            // always invalidate the full client area on each window resize
            std.debug.assert(0 != win32.InvalidateRect(hWnd, null, 0));
        },
        else => {},
    }
    return win32.DefWindowProc(hWnd, uMsg, wParam, lParam);
}

fn paint(hWnd: HWND) void {
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hWnd, &ps);

    // hbrBackground is null so we draw our own background for now
    _ = win32.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_WINDOW)) + 1));

    const FONT_WIDTH = 8;
    const FONT_HEIGHT = 14;

    _ = win32.SetBkColor(hdc, 0x00ffffff);
    _ = win32.SetTextColor(hdc, 0x00000000);
    for (0 .. engine.global_render.size.y) |row_index| {
        const y: i32 = @intCast(row_index * FONT_HEIGHT);
        const row_str = engine.global_render.rows[row_index];
        // NOTE: for now we only support ASCII
        if (0 == win32.TextOutA(hdc, 0, y, @ptrCast(row_str), engine.global_render.size.x))
            std.debug.panic("TextOut failed, error={}", .{win32.GetLastError()});
    }

    // draw cursor
    {
        const x: i16 = @intCast(engine.global_render.cursor_pos.x * FONT_WIDTH);
        const y: i16 = @intCast(engine.global_render.cursor_pos.y * FONT_HEIGHT);
        const row_str = engine.global_render.rows[engine.global_render.cursor_pos.y];
        const char_ptr = row_str + engine.global_render.cursor_pos.x;
        _ = win32.SetBkColor(hdc, 0x00ff0000);
        _ = win32.SetTextColor(hdc, 0x00ffffff);
        _ = win32.TextOutA(hdc, x, y, @ptrCast(char_ptr), 1);
    }

    _ = win32.EndPaint(hWnd, &ps);
}

fn getClientSize(hWnd: HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hWnd, &rect))
        fatal(hWnd, "GetClientRect failed, error={}", .{win32.GetLastError()});
    return .{
        .x = rect.right - rect.left,
        .y = rect.bottom - rect.top,
    };
}
