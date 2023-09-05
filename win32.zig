const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const CmdlineOpt = @import("CmdlineOpt.zig");
const engine = @import("engine.zig");
const color = @import("color.zig");

const Input = @import("Input.zig");

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").system.memory;
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

const window_style_ex = win32.WINDOW_EX_STYLE.initFlags(.{});
const window_style = win32.WS_OVERLAPPEDWINDOW;

const global = struct {
    pub var x11: if (build_options.enable_x11_backend) bool else void = undefined;
    pub var brush_bg: win32.HBRUSH = undefined;
    pub var brush_bg_menu: win32.HBRUSH = undefined;
    pub var hFont: win32.HFONT = undefined;
    pub var hWnd: win32.HWND = undefined;
    pub var font_size: XY(u16) = undefined;
};

pub fn oom(e: error{OutOfMemory}) noreturn {
    std.log.err("{s}", .{@errorName(e)});
    _ = win32.MessageBoxA(null, "Out of memory", "Med Error", win32.MB_OK);
    std.os.exit(0xff);
}
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    // TODO: detect if there is a console or not, only show message box
    //       if there is not a console
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic("Out of memory");
    const result = win32.MessageBoxA(null, msg.ptr, null, win32.MB_OK);
    std.log.info("MessageBox result is {}", .{result});
    std.os.exit(0xff);
}

fn toColorRef(rgb: color.Rgb) u32 {
    return (@as(u32, rgb.r) << 0) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}

pub fn go(cmdline_opt: CmdlineOpt) !void {
    if (build_options.enable_x11_backend) {
        global.x11 = cmdline_opt.x11;
        if (cmdline_opt.x11) {
            return @import("x11.zig").go(cmdline_opt);
        }
    }

    global.brush_bg = win32.CreateSolidBrush(toColorRef(color.bg)) orelse
        fatal("CreateSolidBrush failed, error={}", .{win32.GetLastError()});
    global.brush_bg_menu = win32.CreateSolidBrush(toColorRef(color.bg_menu)) orelse
        fatal("CreateSolidBrush failed, error={}", .{win32.GetLastError()});
    global.hFont = win32.CreateFontW(
        20,0, // height/width
        0,0, // escapement/orientation
        win32.FW_NORMAL, // weight
        0, 0, 0, // italic, underline, strikeout
        0, // charset
        .DEFAULT_PRECIS, .DEFAULT_PRECIS, // outprecision, clipprecision
        .PROOF_QUALITY, // quality
        .MODERN, // pitch and family
        L("SYSTEM_FIXED_FONT"), // face name
    ) orelse fatal("CreateFont failed, error={}", .{win32.GetLastError()});

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

    global.hWnd = win32.CreateWindowEx(
        window_style_ex,
        CLASS_NAME, // Window class
        // TODO: use the image name in the title if we have one
        L("Image Viewer"),
        window_style,
        CW_USEDEFAULT, CW_USEDEFAULT, // position
        0, 0, // size
        null, // Parent window
        null, // Menu
        win32.GetModuleHandle(null), // Instance handle
        null // Additional application data
    ) orelse {
        std.log.err("CreateWindow failed with {}", .{win32.GetLastError()});
        std.os.exit(0xff);
    };

    global.font_size = getTextSize(global.hWnd, global.hFont);
    resizeWindowToViewport();

    _ = win32.ShowWindow(global.hWnd, win32.SW_SHOW);
    var msg: MSG = undefined;
    while (win32.GetMessage(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessage(&msg);
    }
}

fn getTextSize(hWnd: win32.HWND, hFont: win32.HFONT) XY(u16) {
    const hdc = win32.GetDC(hWnd) orelse std.debug.panic("GetDC failed, error={}", .{win32.GetLastError()});
    defer std.debug.assert(1 == win32.ReleaseDC(hWnd, hdc));

    const old_font = win32.SelectObject(hdc, hFont);
    defer _ = win32.SelectObject(hdc, old_font);

    var metrics: win32.TEXTMETRIC = undefined;
    if (0 == win32.GetTextMetrics(hdc, &metrics))
        std.debug.panic("GetTextMetrics failed, error={}", .{win32.GetLastError()});
    //std.log.info("{}", .{metrics});
    return .{
        // WARNING: windows doesn't guarantee AFAIK that rendering a multi-character
        //          string will always use the same char width.  I could modify
        //          how I'm rendering strings to position each one or figure out
        //          how I can get TextOut to maintain a constant width.
        .x = @intCast(metrics.tmAveCharWidth),
        .y = @intCast(metrics.tmHeight),
    };
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
        fatal("InvalidateRect failed, error={}", .{win32.GetLastError()});
}

fn resizeWindowToViewport() void {
    const window_size: XY(i32) = blk: {
        var rect = win32.RECT {
            .left = 0, .top = 0,
            .right  = @intCast(global.font_size.x * engine.global_render.viewport_size.x),
            .bottom = @intCast(global.font_size.y * engine.global_render.viewport_size.y),
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
        global.hWnd,
        null,
        0, 0, // position
        window_size.x, window_size.y,
        win32.SET_WINDOW_POS_FLAGS.initFlags(.{
            .NOZORDER = 1,
            .NOMOVE = 1,
        }),
    ));
}

pub const Mmap = struct {
    mapping: win32.HANDLE,
    mem: []align(std.mem.page_size)u8,
    pub fn deinit(self: Mmap) void {
        std.debug.assert(0 != win32.UnmapViewOfFile(self.mem.ptr));
        std.os.windows.CloseHandle(self.mapping);
    }
};
pub fn mmap(filename: []const u8, file: std.fs.File, file_size: u64) error{Reported}!Mmap {
    const mapping = win32.CreateFileMappingW(
        file.handle,
        null,
        win32.PAGE_READONLY,
        @intCast(0xffffffff & (file_size >> 32)),
        @intCast(0xffffffff & (file_size)),
        null,
    ) orelse {
        engine.global_render.setError("CreateFileMapping of '{s}' failed, error={}", .{filename, win32.GetLastError()});
        return error.Reported;
    };
    errdefer std.os.windows.CloseHandle(mapping);

    const ptr = win32.MapViewOfFile(
        mapping,
        win32.FILE_MAP_READ,
        0, 0, 0,
    ) orelse {
        engine.global_render.setError("MapViewOfFile of '{s}' failed, error={}", .{filename, win32.GetLastError()});
        return error.Reported;
    };
    errdefer std.debug.assert(0 != win32.UnmapViewOfFile(ptr));

    return .{
        .mapping = mapping,
        .mem = @as([*]align(std.mem.page_size)u8, @alignCast(@ptrCast(ptr)))[0 .. file_size],
    };
}
// ================================================================================
// End of the interface for the engine to use
// ================================================================================



fn vkToKey(vk: u8) ?Input.Key {
    return switch (vk) {
        @intFromEnum(win32.VK_RETURN) => .enter,
        @intFromEnum(win32.VK_CONTROL) => .control,
        @intFromEnum(win32.VK_SPACE) => .space,
        'A'...'Z' => @enumFromInt(@intFromEnum(Input.Key.a) + (vk - 'A')),
        @intFromEnum(win32.VK_OEM_COMMA) => .comma,
        @intFromEnum(win32.VK_OEM_PERIOD) => .period,
        @intFromEnum(win32.VK_OEM_2) => .forward_slash,
        else => null,
    };
}

fn wmKey(wParam: win32.WPARAM, state: Input.KeyState) void {
    if (vkToKey(@intCast(0xff & wParam))) |key| {
        std.log.info("{s} {s}", .{@tagName(key), @tagName(state)});
        engine.notifyKeyEvent(key, state);
    } else {
        std.log.info("unhandled vkey {}(0x{0x}) {s}", .{wParam, @tagName(state)});
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

    const client_size = getClientSize(hWnd);
    {
        // hbrBackground is null so we draw our own background for now
        const rect = win32.RECT{ .left = 0, .top = 0, .right = client_size.x, .bottom = client_size.y };
        _ = win32.FillRect(hdc, &rect, global.brush_bg);
    }

    const viewport_rows = engine.global_render.getViewportRows();

    _ = win32.SelectObject(hdc, global.hFont);
    _ = win32.SetBkColor(hdc, toColorRef(color.bg));
    _ = win32.SetTextColor(hdc, toColorRef(color.fg));
    for (viewport_rows, 0..) |row, row_index| {
        const y: i32 = @intCast(row_index * global.font_size.y);
        const row_str = row.getViewport(engine.global_render);
        // NOTE: for now we only support ASCII
        if (0 == win32.TextOutA(hdc, 0, y, @ptrCast(row_str), @intCast(row_str.len)))
            std.debug.panic("TextOut failed, error={}", .{win32.GetLastError()});
    }

    // draw cursor
    if (engine.global_render.cursor_pos) |cursor_global_pos| {
        if (engine.global_render.toViewportPos(cursor_global_pos)) |cursor_viewport_pos| {
            const viewport_pos = XY(i32){
                .x = @intCast(cursor_viewport_pos.x * global.font_size.x),
                .y = @intCast(cursor_viewport_pos.y * global.font_size.y),
            };
            const char_str: []const u8 = blk: {
                if (cursor_viewport_pos.y >= viewport_rows.len) break :blk " ";
                const row = &viewport_rows[cursor_viewport_pos.y];
                const row_str = row.getViewport(engine.global_render);
                if (cursor_viewport_pos.x >= row_str.len) break :blk " ";
                break :blk row_str[cursor_viewport_pos.x..];
            };
            _ = win32.SetBkColor(hdc, toColorRef(color.cursor));
            _ = win32.SetTextColor(hdc, toColorRef(color.fg));
            _ = win32.TextOutA(hdc, viewport_pos.x, viewport_pos.y, @ptrCast(char_str), 1);
        }
    }

    if (engine.global_render.open_file_prompt) |*prompt| {
        const rect = win32.RECT {
            .left = 0, .top = 0,
            .right = client_size.x,
            .bottom = global.font_size.y * 2,
        };
        _ = win32.FillRect(hdc, &rect, global.brush_bg_menu);
        _ = win32.SetBkColor(hdc, toColorRef(color.bg_menu));
        _ = win32.SetTextColor(hdc, toColorRef(color.fg));
        const msg = "Open File:";
        _ = win32.TextOutA(hdc, 0, 0 * global.font_size.y, msg, msg.len);
        const path = prompt.getPathConst();
        _ = win32.TextOutA(hdc, 0, 1 * global.font_size.y, @ptrCast(path.ptr), @intCast(path.len));
    }
    if (engine.global_render.getError()) |error_msg| {
        const rect = win32.RECT {
            .left = 0, .top = 0,
            .right = client_size.x,
            .bottom = global.font_size.y * 2,
        };
        _ = win32.FillRect(hdc, &rect, global.brush_bg_menu);
        _ = win32.SetBkColor(hdc, toColorRef(color.bg_menu));
        _ = win32.SetTextColor(hdc, toColorRef(color.err));
        const msg = "Error:";
        _ = win32.TextOutA(hdc, 0, 0 * global.font_size.y, msg, msg.len);
        _ = win32.TextOutA(hdc, 0, 1 * global.font_size.y, @ptrCast(error_msg.ptr), @intCast(error_msg.len));
    }

    _ = win32.EndPaint(hWnd, &ps);
}

fn getClientSize(hWnd: HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hWnd, &rect))
        fatal("GetClientRect failed, error={}", .{win32.GetLastError()});
    return .{
        .x = rect.right - rect.left,
        .y = rect.bottom - rect.top,
    };
}
