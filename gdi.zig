const std = @import("std");
const win32 = @import("win32").everything;

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const PagedMem = @import("pagedmem.zig").PagedMem;
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
    separator,
};

pub const ObjectCache = struct {
    brush_void_bg: ?win32.HBRUSH = null,
    brush_content_bg: ?win32.HBRUSH = null,
    brush_status_bg: ?win32.HBRUSH = null,
    brush_menu_bg: ?win32.HBRUSH = null,
    brush_separator: ?win32.HBRUSH = null,

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
            .separator => &self.brush_separator,
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
                .separator => theme.separator,
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
            fillRect(hdc, .{
                .left = 0,
                .top = 0,
                .right = client_size.x,
                .bottom = status_y,
            }, cache.getBrush(.void_bg));
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
        .process => |process| renderProcessOutput(hdc, cache, dpi, font_size, process, .{
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
                        fillRect(hdc, .{
                            .left = @intCast(end_of_line_x),
                            .top = y,
                            .right = client_size.x,
                            .bottom = y + font_size.y,
                        }, cache.getBrush(.void_bg));
                    }
                }
            }

            {
                const end_of_file_y: usize = viewport_rows.len * @as(usize, @intCast(font_size.y));
                if (end_of_file_y < status_y) {
                    fillRect(hdc, .{
                        .left = 0,
                        .top = @intCast(end_of_file_y),
                        .right = client_size.x,
                        .bottom = status_y,
                    }, cache.getBrush(.void_bg));
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
        fillRect(hdc, .{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = font_size.y * 2,
        }, cache.getBrush(.menu_bg));
        _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_menu));
        _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));
        const msg = "Open File:";
        _ = win32.TextOutA(hdc, 0, 0 * font_size.y, msg, msg.len);
        const path = prompt.getPathConst();
        _ = win32.TextOutA(hdc, 0, 1 * font_size.y, @ptrCast(path.ptr), @intCast(path.len));
    }
    if (engine.global_err_msg) |err_msg| {
        fillRect(hdc, .{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = font_size.y * 2,
        }, cache.getBrush(.menu_bg));
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
                fillRect(hdc, .{
                    .left = @intCast(end_of_line_x),
                    .top = status_y,
                    .right = client_size.x,
                    .bottom = client_size.y,
                }, cache.getBrush(.status_bg));
            }
        }
    }
}

pub fn utf8ToUtf16LeScalar(
    utf8: []const u8,
) error{ Utf8InvalidStartByte, Truncated }!struct {
    len: usize,
    char: ?u16,
} {
    std.debug.assert(utf8.len > 0);
    const sequence_len = try std.unicode.utf8ByteSequenceLength(utf8[0]);
    if (sequence_len > utf8.len) return error.Truncated;
    var result_buf: [7]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(
        &result_buf,
        utf8[0..sequence_len],
    ) catch |err| switch (err) {
        error.InvalidUtf8 => return .{
            .len = sequence_len,
            .char = null,
        },
    };
    std.debug.assert(len == 1);
    return .{
        .len = sequence_len,
        .char = result_buf[0],
    };
}

const Utf8TextIterator = struct {
    utf8: []const u8,
    offset: usize = 0,
    pub fn next(self: *Utf8TextIterator) ?u16 {
        if (self.offset >= self.utf8.len) return null;

        const decoded = utf8ToUtf16LeScalar(
            self.utf8[self.offset..],
        ) catch |e| switch (e) {
            error.Truncated => {
                self.offset = self.utf8.len;
                return std.unicode.replacement_character;
            },
            error.Utf8InvalidStartByte => {
                self.offset += 1;
                return std.unicode.replacement_character;
            },
        };
        self.offset += decoded.len;
        return decoded.char orelse std.unicode.replacement_character;
    }
};
const PagedMemTextIterator = struct {
    paged_mem: *const PagedMem(std.mem.page_size),
    offset: usize,
    line_end: usize,
    pub fn next(self: *PagedMemTextIterator) ?u16 {
        if (self.offset >= self.line_end) return null;

        const decoded = self.paged_mem.utf8ToUtf16LeScalar(
            self.offset,
            self.line_end,
        ) catch |e| switch (e) {
            error.Truncated => {
                self.offset = self.line_end;
                return std.unicode.replacement_character;
            },
            error.Utf8InvalidStartByte => {
                self.offset += 1;
                return std.unicode.replacement_character;
            },
        };
        self.offset = decoded.end;
        return decoded.char orelse std.unicode.replacement_character;
    }
};

fn renderProcessOutput(
    hdc: win32.HDC,
    cache: *ObjectCache,
    dpi: u32,
    font_size: XY(i32),
    process: *const Process,
    rect: win32.RECT,
) void {
    _ = win32.SetBkColor(hdc, colorrefFromRgb(theme.bg_content));
    _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));

    var bottom: i32 = rect.bottom;
    if (process.command.items.len > 0) {
        const top = bottom - font_size.y;

        var text_it: Utf8TextIterator = .{
            .utf8 = process.command.items,
        };
        const text_right = drawText(hdc, font_size, &text_it, .{
            .left = rect.left,
            .top = top,
            .right = rect.right,
        });
        if (text_right < rect.right) fillRect(hdc, .{
            .left = text_right,
            .top = top,
            .right = rect.right,
            .bottom = bottom,
        }, cache.getBrush(.void_bg));

        bottom = top;
    }

    const remaining_height: i32 = bottom - rect.top;
    const separator_height = win32.scaleDpi(i32, 1, dpi);
    const stdout_height = if (process.paged_mem_stderr.len == 0)
        remaining_height
    else
        @divTrunc(remaining_height - separator_height, 2);
    const stdout_bottom = if (process.paged_mem_stderr.len == 0)
        bottom
    else
        rect.top + stdout_height;
    if (process.paged_mem_stderr.len > 0) {
        const stderr_top: i32 = stdout_bottom + separator_height;
        _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.err));
        renderStream(hdc, cache, font_size, .{
            .left = rect.left,
            .top = stderr_top,
            .right = rect.right,
            .bottom = bottom,
        }, &process.paged_mem_stderr);
        fillRect(hdc, .{
            .left = rect.left,
            .top = stdout_bottom,
            .right = rect.right,
            .bottom = stderr_top,
        }, cache.getBrush(.separator));
    }
    _ = win32.SetTextColor(hdc, colorrefFromRgb(theme.fg));
    renderStream(hdc, cache, font_size, .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = stdout_bottom,
    }, &process.paged_mem_stdout);
}

fn renderStream(
    hdc: win32.HDC,
    cache: *ObjectCache,
    font_size: XY(i32),
    rect: win32.RECT,
    paged_mem: *const PagedMem(std.mem.page_size),
) void {
    if (paged_mem.len == 0) {
        fillRect(hdc, rect, cache.getBrush(.void_bg));
        // TODO: should we render a "no output" message or something?
        return;
    }

    var bottom = rect.bottom;
    var line_end: usize = paged_mem.len;
    while (bottom > rect.top) {
        const line_start = paged_mem.scanBackwardsScalar(line_end, '\n');
        var text_it: PagedMemTextIterator = .{
            .paged_mem = paged_mem,
            .offset = line_start,
            .line_end = line_end,
        };
        const top = bottom - font_size.y;
        const text_right = drawText(hdc, font_size, &text_it, .{
            .left = rect.left,
            .top = top,
            .right = rect.right,
        });
        if (text_right < rect.right) fillRect(hdc, .{
            .left = text_right,
            .top = top,
            .right = rect.right,
            .bottom = bottom,
        }, cache.getBrush(.void_bg));
        bottom = top;

        if (line_start == 0) break;
        line_end = line_start - 1;
    }
    if (bottom > rect.top) {
        fillRect(hdc, .{
            .left = rect.left,
            .right = rect.right,
            .top = rect.top,
            .bottom = bottom,
        }, cache.getBrush(.void_bg));
    }
}

fn drawText(
    hdc: win32.HDC,
    font_size: XY(i32),
    text_iterator: anytype,
    box: struct {
        left: i32,
        right: i32,
        top: i32,
    },
) i32 {
    var left: i32 = box.left;
    while (left < box.right) {
        const char = text_iterator.next() orelse break;
        const str = [_:0]u16{char};
        if (0 == win32.TextOutW(hdc, left, box.top, &str, 1)) medwin32.fatalWin32(
            "TextOut",
            win32.GetLastError(),
        );
        left += font_size.x;
    }
    return left;
}
fn fillRect(hdc: win32.HDC, rect: win32.RECT, brush: win32.HBRUSH) void {
    if (0 == win32.FillRect(hdc, &rect, brush)) medwin32.fatalWin32(
        "FillRect",
        win32.GetLastError(),
    );
}
