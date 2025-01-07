const std = @import("std");
const win32 = @import("win32").everything;

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const Process = @import("Process.zig");
const XY = @import("xy.zig").XY;

const medwin32 = @import("win32.zig");

pub fn deleteObject(obj: ?win32.HGDIOBJ) void {
    if (0 == win32.DeleteObject(obj)) medwin32.fatalWin32("DeleteObject", win32.GetLastError());
}

pub fn getClientSize(hwnd: win32.HWND) XY(i32) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        medwin32.fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = rect.right, .y = rect.bottom };
}

const Brush = enum {
    void_bg,
    content_bg,
    status_bg,
    menu_bg,
};

pub const ObjectCache = struct {
    brush_void_bg: ?win32.HBRUSH = null,
    brush_content_bg: ?win32.HBRUSH = null,
    brush_status_bg: ?win32.HBRUSH = null,
    brush_menu_bg: ?win32.HBRUSH = null,

    font: ?struct {
        dpi: u32,
        face_name: [*:0]const u16,
        handle: win32.HFONT,
    } = null,

    pub fn getFont(self: *ObjectCache, dpi: u32, face_name: [*:0]const u16) win32.HFONT {
        if (self.font) |font| {
            if (font.dpi == dpi and font.face_name == face_name)
                return font.handle;
            std.log.info(
                "deleting old font '{}' for dpi {}",
                .{ std.unicode.fmtUtf16le(std.mem.span(font.face_name)), font.dpi },
            );
            deleteObject(font.handle);
            self.font = null;
        }

        self.font = .{
            .dpi = dpi,
            .face_name = face_name,
            .handle = win32.CreateFontW(
                win32.scaleDpi(i32, 20, dpi), // height
                0, // width
                0, // escapement
                0, // orientation
                win32.FW_NORMAL, // weight
                0,
                0,
                0, // italic, underline, strikeout
                0, // charset
                .DEFAULT_PRECIS,
                .{}, // outprecision, clipprecision
                .PROOF_QUALITY, // quality
                .MODERN, // pitch and family
                face_name,
            ) orelse medwin32.fatalWin32("CreateFont", win32.GetLastError()),
        };
        return self.font.?.handle;
    }

    fn getBrushRef(self: *ObjectCache, brush: Brush) *?win32.HBRUSH {
        return switch (brush) {
            .void_bg => &self.brush_void_bg,
            .content_bg => &self.brush_content_bg,
            .status_bg => &self.brush_status_bg,
            .menu_bg => &self.brush_menu_bg,
        };
    }

    pub fn getBrush(self: *ObjectCache, brush: Brush) win32.HBRUSH {
        const brush_ref = self.getBrushRef(brush);
        if (brush_ref.* == null) {
            const rgb = switch (brush) {
                .void_bg => theme.bg_void,
                .content_bg => theme.bg_content,
                .status_bg => theme.bg_status,
                .menu_bg => theme.bg_menu,
            };
            brush_ref.* = win32.CreateSolidBrush(colorrefFromRgb(rgb)) orelse medwin32.fatalWin32(
                "CreateSolidBrush",
                win32.GetLastError(),
            );
        }
        return brush_ref.*.?;
    }
};

fn colorrefFromRgb(rgb: theme.Rgb) u32 {
    return (@as(u32, rgb.r) << 0) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 16);
}

pub fn getFontSize(comptime T: type, dpi: u32, face_name: [*:0]const u16, cache: *ObjectCache) XY(T) {
    const hdc = win32.CreateCompatibleDC(null);
    defer if (0 == win32.DeleteDC(hdc)) medwin32.fatalWin32("DeleteDC", win32.GetLastError());

    const font = cache.getFont(dpi, face_name);

    const old_font = win32.SelectObject(hdc, font);
    defer _ = win32.SelectObject(hdc, old_font);

    var metrics: win32.TEXTMETRICW = undefined;
    if (0 == win32.GetTextMetricsW(hdc, &metrics)) medwin32.fatalWin32(
        "GetTextMetrics",
        win32.GetLastError(),
    );
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

pub fn paint(
    hdc: win32.HDC,
    dpi: u32,
    font_face_name: [*:0]const u16,
    client_size: XY(i32),
    cache: *ObjectCache,
) void {
    const font_size = getFontSize(i32, dpi, font_face_name, cache);
    const status_y = client_size.y - font_size.y;
    const old_font = win32.SelectObject(hdc, cache.getFont(dpi, font_face_name));
    defer _ = win32.SelectObject(hdc, old_font);

    // NOTE: clearing the entire window first causes flickering
    //       see https://catch22.net/tuts/win32/flicker-free-drawing/
    //       TLDR; don't draw over the same pixel twice

    const viewport_size: XY(usize) = .{
        .x = @intCast(@divTrunc(client_size.x, font_size.x)),
        .y = @intCast(@divTrunc(status_y, font_size.y)),
    };

    switch (engine.global_current_pane) {
        .welcome => {
            const rect = win32.RECT{
                .left = 0,
                .top = 0,
                .right = client_size.x,
                .bottom = status_y,
            };
            _ = win32.FillRect(hdc, &rect, cache.getBrush(.void_bg));

            _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_void));
            _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));

            const msg = win32.L("Welcome");
            const x = @divTrunc(client_size.x - (font_size.x * @as(i32, msg.len)), 2);
            const y = @divTrunc(client_size.y - font_size.y, 2);
            if (0 == win32.TextOutW(hdc, x, y, msg.ptr, @intCast(msg.len))) medwin32.fatalWin32(
                "TextOut",
                win32.GetLastError(),
            );
        },
        .process => |process| renderProcessOutput(hdc, cache, font_size, process, .{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = status_y,
        }),
        .file => |view| {
            const viewport_rows = view.getViewportRows(viewport_size.y);

            _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_content));
            _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));
            for (viewport_rows, 0..) |row, row_index_usize| {
                const row_index: i32 = @intCast(row_index_usize);
                const y: i32 = @intCast(row_index * font_size.y);
                const row_str = row.getViewport(view.*, viewport_size.x);
                // NOTE: for now we only support ASCII
                if (0 == win32.TextOutA(hdc, 0, y, @ptrCast(row_str), @intCast(row_str.len))) medwin32.fatalWin32(
                    "TextOut",
                    win32.GetLastError(),
                );

                {
                    const end_of_line_x: usize = row_str.len * @as(usize, @intCast(font_size.x));
                    if (end_of_line_x < client_size.x) {
                        const rect = win32.RECT{
                            .left = @intCast(end_of_line_x),
                            .top = y,
                            .right = client_size.x,
                            .bottom = y + font_size.y,
                        };
                        _ = win32.FillRect(hdc, &rect, cache.getBrush(.void_bg));
                    }
                }
            }

            {
                const end_of_file_y: usize = viewport_rows.len * @as(usize, @intCast(font_size.y));
                if (end_of_file_y < status_y) {
                    const rect = win32.RECT{
                        .left = 0,
                        .top = @intCast(end_of_file_y),
                        .right = client_size.x,
                        .bottom = status_y,
                    };
                    _ = win32.FillRect(hdc, &rect, cache.getBrush(.void_bg));
                }
            }

            // draw cursor
            if (view.cursor_pos) |cursor_global_pos| {
                if (view.toViewportPos(viewport_size, cursor_global_pos)) |cursor_viewport_pos| {
                    const viewport_pos = XY(i32){
                        .x = @intCast(cursor_viewport_pos.x * font_size.x),
                        .y = @intCast(cursor_viewport_pos.y * font_size.y),
                    };
                    const char_str: []const u8 = blk: {
                        if (cursor_viewport_pos.y >= viewport_rows.len) break :blk " ";
                        const row = &viewport_rows[cursor_viewport_pos.y];
                        const row_str = row.getViewport(view.*, viewport_size.x);
                        if (cursor_viewport_pos.x >= row_str.len) break :blk " ";
                        break :blk row_str[cursor_viewport_pos.x..];
                    };
                    _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.cursor));
                    _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));
                    _ = win32.TextOutA(hdc, viewport_pos.x, viewport_pos.y, @ptrCast(char_str), 1);
                }
            }
        },
    }

    if (engine.global_open_file_prompt) |*prompt| {
        const rect = win32.RECT{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = font_size.y * 2,
        };
        _ = win32.FillRect(hdc, &rect, cache.getBrush(.menu_bg));
        _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_menu));
        _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));
        const msg = "Open File:";
        _ = win32.TextOutA(hdc, 0, 0 * font_size.y, msg, msg.len);
        const path = prompt.getPathConst();
        _ = win32.TextOutA(hdc, 0, 1 * font_size.y, @ptrCast(path.ptr), @intCast(path.len));
    }
    if (engine.global_err_msg) |err_msg| {
        const rect = win32.RECT{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = font_size.y * 2,
        };
        _ = win32.FillRect(hdc, &rect, cache.getBrush(.menu_bg));
        _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_menu));
        _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.err));
        const msg = "Error:";
        _ = win32.TextOutA(hdc, 0, 0 * font_size.y, msg, msg.len);
        _ = win32.TextOutA(hdc, 0, 1 * font_size.y, @ptrCast(err_msg.slice.ptr), @intCast(err_msg.slice.len));
    }

    {
        _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_status));
        _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg_status));

        const text = blk: {
            if (engine.global_dialog) |dialog| {
                break :blk dialog.getText();
            }
            break :blk engine.global_status.slice();
        };
        if (0 == win32.TextOutA(
            hdc,
            0,
            status_y,
            @ptrCast(text.ptr), // todo: win32 api shouldn't require null terminator
            @intCast(text.len),
        )) medwin32.fatalWin32("TextOut", win32.GetLastError());

        {
            const end_of_line_x: usize = @as(usize, text.len) * @as(usize, @intCast(font_size.x));
            if (end_of_line_x < client_size.x) {
                const rect = win32.RECT{
                    .left = @intCast(end_of_line_x),
                    .top = status_y,
                    .right = client_size.x,
                    .bottom = client_size.y,
                };
                _ = win32.FillRect(hdc, &rect, cache.getBrush(.status_bg));
            }
        }
    }
}

fn renderProcessOutput(
    hdc: win32.HDC,
    //dpi: u32,
    //font_face_name: [*:0]const u16,
    //client_size: XY(i32),
    cache: *ObjectCache,
    font_size: XY(i32),
    process: *const Process,
    rect: win32.RECT,
) void {
    _ = win32.FillRect(hdc, &rect, cache.getBrush(.void_bg));

    _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_void));
    _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));

    if (process.paged_buf_stdout.len == 0) {
        const msg = win32.L("waiting for output...");
        if (0 == win32.TextOutW(hdc, 0, 0, msg.ptr, @intCast(msg.len))) medwin32.fatalWin32(
            "TextOut",
            win32.GetLastError(),
        );
        return;
    }

    const height_px = rect.bottom - rect.top;
    const row_count = blk: {
        const min = @divTrunc(height_px, font_size.y);
        break :blk min + @as(i32, if (min * font_size.y == height_px) 0 else 1);
    };
    var offset: usize = process.paged_buf_stdout.len;

    _ = row_count;
    _ = &offset;
    // const stdout_buf = process.paged_buf_stdout.last.?;
    // _ = stdout_buf;
    {
        var buf: [100]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "TODO: render {} bytes of output", .{process.paged_buf_stdout.len}) catch unreachable;
        if (0 == win32.TextOutA(hdc, 0, 0, @ptrCast(msg.ptr), @intCast(msg.len))) medwin32.fatalWin32(
            "TextOut",
            win32.GetLastError(),
        );
    }
}
