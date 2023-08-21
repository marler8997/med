const builtin = @import("builtin");
const std = @import("std");

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

const OpenFileState = struct {
};

const State = struct {
    input: Input = .{},
    cursor_pos: XY(u16) = .{ .x = 0, .y = 0 },
    open_file_opt: ?OpenFileState = null,
};

const global = struct {
    pub var state = State{ };
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

pub fn go() !void {
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

    const hwnd = win32.CreateWindowEx(
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
    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);

    var msg: MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }
}

fn vkToKey(vk: u8) ?Input.Key {
    return switch (vk) {
        @intFromEnum(win32.VK_CONTROL) => .control,
        'A'...'Z' => @enumFromInt(@intFromEnum(Input.Key.a) + (vk - 'A')),
        else => null,
    };
}

fn wmKey(hWnd: HWND, wParam: win32.WPARAM, state: Input.KeyState) void {
    if (vkToKey(@intCast(0xff & wParam))) |key| {
        std.log.info("{s} {s}", .{@tagName(key), @tagName(state)});
        if (global.state.input.setKeyState(key, state)) |action|
            try handleAction(hWnd, action);
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
        win32.WM_KEYDOWN => wmKey(hWnd, wParam, .down),
        win32.WM_KEYUP => wmKey(hWnd, wParam, .up),
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

    _ = win32.FillRect(hdc, &ps.rcPaint, @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_WINDOW)) + 1));

    if (global.state.open_file_opt) |_| {
        const msg = "TODO: show UI to open a file";
        if (0 == win32.TextOutA(hdc, 0, 0, msg, msg.len))
            std.debug.panic("TextOut failed, error={}", .{win32.GetLastError()});
    } else {
        const FONT_WIDTH = 12;
        const FONT_HEIGHT = 20;
        const cursor_pos: XY(i16) = .{
            .x = @intCast(global.state.cursor_pos.x * FONT_WIDTH),
            .y = @intCast(global.state.cursor_pos.y * FONT_HEIGHT),
        };
        const rect = win32.RECT{
            .left = cursor_pos.x,
            .top = cursor_pos.y,
            .right = cursor_pos.x + FONT_WIDTH,
            .bottom = cursor_pos.y + FONT_HEIGHT,
        };
        _ = win32.FillRect(hdc, &rect, @ptrFromInt(@as(usize, @intFromEnum(win32.COLOR_HIGHLIGHT)) + 1));
    }
    _ = win32.EndPaint(hWnd, &ps);
}

fn handleAction(
    hWnd: HWND,
    action: Input.Action,
) !void {
    switch (action) {
        .cursor_back => {
            if (global.state.cursor_pos.x == 0) {
                std.log.info("TODO: implement cursor back wrap", .{});
            } else {
                global.state.cursor_pos.x -= 1;
                invalidate(hWnd);
            }
        },
        .cursor_forward => {
            global.state.cursor_pos.x += 1;
            invalidate(hWnd);
        },
        .cursor_up => {
            if (global.state.cursor_pos.y == 0) {
                std.log.info("TODO: implement cursor up scroll", .{});
            } else {
                global.state.cursor_pos.y -= 1;
                invalidate(hWnd);
            }
        },
        .cursor_down => {
            global.state.cursor_pos.y += 1;
            invalidate(hWnd);
        },
        .cursor_line_start => std.log.info("TODO: implement cursor_line_start", .{}),
        .cursor_line_end => std.log.info("TODO: implement cursor_line_end", .{}),
        .open_file => {
            global.state.open_file_opt = .{};
            invalidate(hWnd);
        },
        .exit => win32.PostQuitMessage(0),
    }
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

fn invalidate(hWnd: HWND) void {
    if (win32.TRUE != win32.InvalidateRect(hWnd, null, 0))
        fatal(hWnd, "InvalidateRect failed, error={}", .{win32.GetLastError()});
}
