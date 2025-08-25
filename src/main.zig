const global = struct {
    var x11: bool = false;

    var platform: PlatformGlobals = .{};
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // seperate arrays so we can pass handles directly to the wait function
    var handles: std.ArrayListUnmanaged(win32.HANDLE) = .{};
    var handle_callbacks: std.ArrayListUnmanaged(HandleCallback) = .{};
};
const PlatformGlobals = switch (zin.platform_kind) {
    .win32 => PlatformGlobalsWin32,
    else => struct {},
};
const PlatformGlobalsWin32 = struct {
    font: ?struct {
        dpi: u32,
        face_name: [*:0]const u16,
        handle: win32.HFONT,
    } = null,
    font_face_name: [*:0]const u16 = default_font_face_name.ptr,
    pub fn getFont(self: *PlatformGlobalsWin32, dpi: u32, face_name: [*:0]const u16) win32.HFONT {
        if (self.font) |font| {
            if (font.dpi == dpi and font.face_name == face_name)
                return font.handle;
            std.log.info(
                "deleting old font '{}' for dpi {}",
                .{ std.unicode.fmtUtf16Le(std.mem.span(font.face_name)), font.dpi },
            );
            win32.deleteObject(font.handle);
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
            ) orelse win32.panicWin32("CreateFont", win32.GetLastError()),
        };
        return self.font.?.handle;
    }
};

const HandleCallbackFn = *const fn (context: *anyopaque, handle: win32.HANDLE) void;
const HandleCallback = struct {
    context: *anyopaque,
    func: HandleCallbackFn,
};

const default_font_face_name = win32.L("SYSTEM_FIXED_FONT");

pub const zin_config: zin.Config = .{
    .StaticWindowId = StaticWindowId,
};
const StaticWindowId = enum {
    main,
    pub fn getConfig(self: StaticWindowId) zin.WindowConfigData {
        return switch (self) {
            .main => .{
                .window_size_events = true,
                .key_events = true,
                .mouse_events = true,
                .timers = .none,
                .background = theme.bg_void,
                .dynamic_background = false,
                .win32 = .{ .render = .{ .gdi = .{} } },
                .x11 = .{ .render_kind = .double_buffered },
            },
        };
    }
};

pub const panic = zin.panic(.{ .title = "Med Panic!" });

const extra_config: zin.WindowConfigData = .{
    .key_events = false,
    .mouse_events = false,
    .timers = false,
    .background = .{ .r = 255, .g = 0, .b = 0 },
    .dynamic_background = true,
    .win32 = .{ .render = .{ .gdi = .{ .use_backbuffer = false } } },
};

pub fn main() !void {
    main2() catch |err| {
        // TODO: zin should expose some sort of messagebox
        if (builtin.os.tag == .windows) {
            // TODO: detect if there is a console or not, only show message box
            //       if there is not a console
            const result = win32.MessageBoxA(null, @errorName(err), "Med Fatal Error!", .{ .ICONASTERISK = 1 });
            std.log.info("MessageBox result: {s}", .{@tagName(result)});
        }
        return err;
    };
}
fn main2() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
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
                @panic("todo: update zin so we can switch to the x11 backend");
            } else if (std.mem.eql(u8, arg, "--font")) {
                const font = it.next() orelse errExit("missing argument for --font", .{});
                switch (zin.platform_kind) {
                    .win32 => {
                        // HACK! std converts from wtf16 to wtf8...and we convert back to wtf16 here!
                        global.platform.font_face_name = try std.unicode.wtf8ToWtf16LeAllocZ(arena, font);
                    },
                    .macos, .x11 => @panic("--font command not supported on this platform"),
                }
            } else if (std.mem.eql(u8, arg, "--window-x")) {
                const str = it.next() orelse errExit("missing argument for --window-x", .{});
                cmdline_opt.@"window-x" = std.fmt.parseInt(i32, str, 10) catch errExit("invalid --window-x value '{s}'", .{str});
            } else if (std.mem.eql(u8, arg, "--window-y")) {
                const str = it.next() orelse errExit("missing argument for --window-y", .{});
                cmdline_opt.@"window-y" = std.fmt.parseInt(i32, str, 10) catch errExit("invalid --window-x value '{s}'", .{str});
            } else {
                errExit("unknown cmdline option '{s}'", .{arg});
            }
        }
    }

    const initial_placement = calcWindowPlacement(.{
        .x = cmdline_opt.@"window-x",
        .y = cmdline_opt.@"window-y",
    });
    const icons = getIcons(initial_placement.dpi);

    try zin.loadAppKit();
    try zin.enforceDpiAware();

    try zin.connect(arena, .{});
    defer zin.disconnect(arena);

    zin.staticWindow(.main).registerClass(.{
        .callback = callback,
        .win32_name = zin.L("HelloMainWindow"),
        .macos_view = "HelloView",
    }, .{
        .win32_icon_large = icons.large,
        .win32_icon_small = icons.small,
    });
    defer zin.staticWindow(.main).unregisterClass();
    try zin.staticWindow(.main).create(.{
        .title = "Med",
        .size = .{ .window = initial_placement.size },
        .pos = initial_placement.pos,
    });
    // TODO: not working for x11 yet, closing the window
    //       seems to close the entire X11 connection right now?
    defer if (zin.platform_kind != .x11) zin.staticWindow(.main).destroy();

    if (zin.platform_kind == .win32) {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            zin.staticWindow(.main).hwnd(),
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={}",
            .{ dark_value, win32.GetLastError() },
        );
    }

    zin.staticWindow(.main).show();

    if (builtin.os.tag == .windows) mainLoopWin32() else try zin.mainLoop();
}

fn mainLoopWin32() void {
    while (true) {
        while (global.handles.items.len == 0) {
            var msg: win32.MSG = undefined;
            const result = win32.GetMessageW(&msg, null, 0, 0);
            if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
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
                if (result < 0) win32.panicWin32("PeekMessage", win32.GetLastError());
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

fn callback(cb: zin.Callback(.{ .static = .main })) void {
    switch (cb) {
        .close => zin.quitMainLoop(),
        .window_size => {}, // invalidate should already happen?
        .draw => |*d| paint(d),
        .key => |key| onKey(key),
        .mouse => |mouse| {
            _ = mouse;
            // global.mouse_position = mouse.position;
            zin.staticWindow(.main).invalidate();
        },
    }
}

fn paint(d: *const zin.Draw(.{ .static = .main })) void {
    const client_size = zin.staticWindow(.main).getClientSize();
    d.clear();
    const dpi = getDpi(d);
    const font_size = getFontSize(i32, dpi, &global.platform);
    const status_top = client_size.y - font_size.y;

    const old_font = blk: switch (zin.platform_kind) {
        .win32 => break :blk win32.SelectObject(
            d.hdc,
            global.platform.getFont(dpi, global.platform.font_face_name),
        ),
        else => {},
    };
    defer switch (zin.platform_kind) {
        .win32 => _ = win32.SelectObject(d.hdc, old_font),
        else => {},
    };

    const viewport_size: XY(usize) = .{
        .x = @intCast(@divTrunc(client_size.x, font_size.x)),
        .y = @intCast(@divTrunc(status_top, font_size.y)),
    };

    switch (engine.global_current_pane) {
        .welcome => {
            const msg = "Welcome";
            const x = @divTrunc(client_size.x - (font_size.x * @as(i32, msg.len)), 2);
            const y = @divTrunc(client_size.y - font_size.y, 2);
            d.text(msg, x, y, theme.fg);
        },
        .process => |process| {
            _ = process;
            @panic("todo");
        },
        //     renderProcessOutput(hdc, cache, dpi, font_size, process, .{
        //     .left = 0,
        //     .top = 0,
        //     .right = client_size.x,
        //     .bottom = status_y,
        // }),
        .file => |view| {
            const viewport_rows = view.getViewportRows(viewport_size.y);

            // draw cursor
            if (view.cursor_pos) |cursor_global_pos| {
                if (view.toViewportPos(viewport_size, cursor_global_pos)) |cursor_viewport_pos| {
                    const viewport_pos = zin.XY{
                        .x = @intCast(cursor_viewport_pos.x * @as(u32, @intCast(font_size.x))),
                        .y = @intCast(cursor_viewport_pos.y * @as(u32, @intCast(font_size.y))),
                    };
                    d.rect(.ltwh(viewport_pos.x, viewport_pos.y, font_size.x, font_size.y), theme.cursor);
                }
            }
            const mode: FileMode = if (view.file) |f| f.mode else .default;
            for (viewport_rows, 0..) |row, row_index_usize| {
                const row_index: i32 = @intCast(row_index_usize);
                const y: i32 = @intCast(row_index * font_size.y);
                const row_str = row.getViewport(view.*, viewport_size.x);
                drawFileRow(d, mode, row_str, 0, y, font_size.x);
            }
        },
    }

    d.rect(.{
        .left = 0,
        .top = status_top,
        .right = client_size.x,
        .bottom = client_size.y,
    }, theme.bg_status);
    {
        const status_text = blk: {
            if (engine.global_dialog) |dialog| {
                break :blk dialog.getText();
            }
            break :blk engine.global_status.slice();
        };
        d.text(status_text, 0, status_top, theme.fg_status);
    }

    if (engine.global_open_file_prompt) |*prompt| {
        d.rect(.{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = font_size.y * 2,
        }, theme.bg_menu);
        const msg = "Open File:";
        d.text(msg, 0, 0 * font_size.y, theme.fg);
        const path = prompt.getPathConst();
        d.text(path, 0, 1 * font_size.y, theme.fg);
    }
    if (engine.global_err_msg) |err_msg| {
        d.rect(.{
            .left = 0,
            .top = 0,
            .right = client_size.x,
            .bottom = font_size.y * 2,
        }, theme.bg_menu);
        const msg = "Error:";
        d.text(msg, 0, 0 * font_size.y, theme.err);
        d.text(err_msg.slice, 0, 1 * font_size.y, theme.err);
    }
}

fn drawFileRow(d: *const zin.Draw(.{ .static = .main }), mode: FileMode, row_str: []const u8, x: i32, y: i32, font_width: i32) void {
    // NOTE: for now we only support ASCII
    switch (mode) {
        .default => {
            d.text(row_str, x, y, theme.fg);
        },
        .zig => {
            var offset: usize = 0;
            while (offset < row_str.len) {
                const token = tokenizeZig(row_str, offset);
                if (token.end > offset) {
                    // const token_kind = tokenKindFromZig(token.tag);
                    d.text(
                        row_str[offset..token.end],
                        x + (@as(i32, @intCast(offset)) * font_width),
                        y,
                        token.kind.color(),
                    );
                    offset = token.end;
                } else {
                    offset += 1; // skip this one char I guess
                }
            }
        },
    }
}

const TokenKind = enum {
    todo,
    unknown,
    keyword,
    string_literal,
    operator,
    doc_comment,
    comment,
    pub fn color(self: TokenKind) zin.Rgb8 {
        return switch (self) {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            .todo => theme.fg,
            .unknown => .{ .r = 0xff, .g = 0x33, .b = 0x33 },
            .keyword => .{ .r = 0xf7, .g = 0xa4, .b = 0x1d },
            .string_literal => .{ .r = 0x3c, .g = 0x51, .b = 0x90 },
            .operator => .{ .r = 0x04, .g = 0x96, .b = 0xff },
            .doc_comment => .{ .r = 0x20, .g = 0x83, .b = 0x73 },
            .comment => .{ .r = 0x3a, .g = 0xcf, .b = 0xc8 },
        };
    }
};

fn tokenizeZig(row_str: []const u8, start: usize) struct {
    kind: TokenKind,
    end: usize,
} {
    var tokenizer = zigtokenizer.Tokenizer{ .buffer = row_str, .index = start };
    const token = tokenizer.next();
    std.debug.assert(token.loc.start >= start);
    switch (token.tag) {
        .eof => {
            if (std.mem.indexOf(u8, row_str, "//")) |comment_start| {
                if (comment_start == 0) return .{ .kind = .comment, .end = row_str.len };
                return .{ .kind = .unknown, .end = comment_start };
            }
        },
        else => {},
    }
    return .{ .kind = tokenKindFromZig(token.tag), .end = token.loc.end };
}

fn tokenKindFromZig(tag: zigtokenizer.Token.Tag) TokenKind {
    return switch (tag) {
        .invalid,
        .invalid_periodasterisks,
        .identifier,
        => .todo,
        .string_literal,
        .multiline_string_literal_line,
        .char_literal,
        => .string_literal,
        .eof => .unknown,
        .builtin => .keyword,
        .bang,
        .pipe,
        .pipe_pipe,
        .pipe_equal,
        .equal,
        .equal_equal,
        .equal_angle_bracket_right,
        .bang_equal,
        .l_paren,
        .r_paren,
        .semicolon,
        .percent,
        .percent_equal,
        .l_brace,
        .r_brace,
        .l_bracket,
        .r_bracket,
        .period,
        .period_asterisk,
        .ellipsis2,
        .ellipsis3,
        .caret,
        .caret_equal,
        .plus,
        .plus_plus,
        .plus_equal,
        .plus_percent,
        .plus_percent_equal,
        .plus_pipe,
        .plus_pipe_equal,
        .minus,
        .minus_equal,
        .minus_percent,
        .minus_percent_equal,
        .minus_pipe,
        .minus_pipe_equal,
        .asterisk,
        .asterisk_equal,
        .asterisk_asterisk,
        .asterisk_percent,
        .asterisk_percent_equal,
        .asterisk_pipe,
        .asterisk_pipe_equal,
        .arrow,
        .colon,
        .slash,
        .slash_equal,
        .comma,
        .ampersand,
        .ampersand_equal,
        .question_mark,
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .angle_bracket_angle_bracket_right,
        .angle_bracket_angle_bracket_right_equal,
        .tilde,
        => .operator,
        .number_literal,
        .doc_comment,
        .container_doc_comment,
        => .doc_comment,
        .keyword_addrspace,
        .keyword_align,
        .keyword_allowzero,
        .keyword_and,
        .keyword_anyframe,
        .keyword_anytype,
        .keyword_asm,
        .keyword_async,
        .keyword_await,
        .keyword_break,
        .keyword_callconv,
        .keyword_catch,
        .keyword_comptime,
        .keyword_const,
        .keyword_continue,
        .keyword_defer,
        .keyword_else,
        .keyword_enum,
        .keyword_errdefer,
        .keyword_error,
        .keyword_export,
        .keyword_extern,
        .keyword_fn,
        .keyword_for,
        .keyword_if,
        .keyword_inline,
        .keyword_noalias,
        .keyword_noinline,
        .keyword_nosuspend,
        .keyword_opaque,
        .keyword_or,
        .keyword_orelse,
        .keyword_packed,
        .keyword_pub,
        .keyword_resume,
        .keyword_return,
        .keyword_linksection,
        .keyword_struct,
        .keyword_suspend,
        .keyword_switch,
        .keyword_test,
        .keyword_threadlocal,
        .keyword_try,
        .keyword_union,
        .keyword_unreachable,
        .keyword_usingnamespace,
        .keyword_var,
        .keyword_volatile,
        .keyword_while,
        => .keyword,
    };
}

fn getDpi(d: *const zin.Draw(.{ .static = .main })) u32 {
    return switch (zin.platform_kind) {
        .x11, .macos => 96, // we'll just assume 96 dpi for now
        .win32 => return win32.dpiFromHwnd(d.hwnd),
    };
}

fn getFontSize(comptime T: type, dpi: u32, globals: *PlatformGlobals) if (T == i32) zin.XY else XY(T) {
    switch (zin.platform_kind) {
        .x11 => @panic("getFontSize not implemented on x11"),
        .win32 => {
            const hdc = win32.CreateCompatibleDC(null);
            defer if (0 == win32.DeleteDC(hdc)) win32.panicWin32("DeleteDC", win32.GetLastError());

            const font = global.platform.getFont(dpi, globals.font_face_name);

            const old_font = win32.SelectObject(hdc, font);
            defer _ = win32.SelectObject(hdc, old_font);

            var metrics: win32.TEXTMETRICW = undefined;
            if (0 == win32.GetTextMetricsW(hdc, &metrics)) win32.panicWin32(
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
        },
        .macos => @panic("getFontSize not implemented on macos"),
    }
}

// ================================================================================
// The interface for the engine to use
// ================================================================================
pub fn quit() void {
    zin.quitMainLoop();
}
// NOTE: for now we'll just repaint the whole window
//       no matter what is modified
pub const statusModified = viewModified;
pub const errModified = viewModified;
pub const dialogModified = viewModified;
pub const processModified = viewModified;
pub const paneModified = viewModified;
pub fn viewModified() void {
    zin.staticWindow(.main).invalidate();
}
pub fn beep() void {
    if (builtin.os.tag == .windows) {
        _ = win32.MessageBeep(@as(u32, @bitCast(win32.MB_OK)));
    }
}

pub fn getViewRowCount() u32 {
    const client_size = zin.staticWindow(.main).getClientSize();
    const font_height = blk: switch (zin.platform_kind) {
        .win32 => {
            const dpi = win32.dpiFromHwnd(zin.staticWindow(.main).hwnd());
            break :blk getFontSize(i32, dpi, &global.platform).y;
        },
        else => @panic("todo"),
    };
    const status_top = client_size.y - font_height;
    return @intCast(@divTrunc(status_top, font_height));
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
// ================================================================================
// End of the interface for the engine to use
// ================================================================================

fn onKey(e: zin.Key) void {
    // const key_flags: KeyFlags = @bitCast(@as(u32, @intCast(0xffffffff & lparam)));
    // const winkey: WinKey = .{
    //     .vk = @intCast(0xffff & wparam),
    //     .extended = key_event.win32_extended,
    // };
    const press_kind: Input.KeyPressKind = switch (e.kind) {
        .up => return,
        .down => .initial,
        .down_repeat => .repeat,
    };

    switch (zin.platform_kind) {
        .win32 => {
            var keyboard_state: [256]u8 = undefined;
            if (0 == win32.GetKeyboardState(&keyboard_state)) win32.panicWin32(
                "GetKeyboardState",
                win32.GetLastError(),
            );

            const mods: Input.KeyMods = .{
                .control = (0 != keyboard_state[@intFromEnum(win32.VK_CONTROL)] & 0x80),
                .alt = (0 != (keyboard_state[@intFromEnum(win32.VK_MENU)] & 0x80)),
            };
            if (keyFromZin(e.vk, e.win32_extended)) |key| {
                engine.notifyKeyDown(press_kind, .{ .key = key, .mods = mods });
                return;
            }

            // release control key when getting the unicode character of this key
            //const save_control_state = keyboard_state[@intFromEnum(win32.VK_CONTROL)];
            keyboard_state[@intFromEnum(win32.VK_CONTROL)] = 0;

            const max_char_count = 20;
            var char_buf: [max_char_count + 1]u16 = undefined;
            const unicode_result = win32.ToUnicode(
                @intFromEnum(e.vk),
                @intFromEnum(e.scan_code),
                &keyboard_state,
                @ptrCast(&char_buf),
                max_char_count,
                0,
            );

            if (unicode_result < 0)
                return; // dead key

            if (unicode_result > max_char_count) {
                for (char_buf[0..@intCast(unicode_result)], 0..) |codepoint, i| {
                    std.log.err("UNICODE[{}] 0x{x} {d}", .{ i, codepoint, unicode_result });
                }
                return;
            }

            const extended_suffix: []const u8 = if (e.win32_extended) "E" else "";
            if (unicode_result == 0) {
                std.log.warn(
                    "unknown virtual key {}{s} (0x{x})",
                    .{ @intFromEnum(e.vk), extended_suffix, @intFromEnum(e.vk) },
                );
                return;
            }

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
        },
        .macos => std.log.err("todo: support onKey macos", .{}),
        .x11 => std.log.err("todo: support onKey x11", .{}),
    }
}

fn keyFromZin(vk: zin.VirtualKey, extended: zin.Win32ExtendedKey) ?Input.Key {
    if (builtin.os.tag == .windows) if (extended) return switch (vk) {
        .@"return" => Input.todo.kp_enter,
        .control => Input.todo.right_control,
        .alt => Input.todo.right_alt,
        .left_super => Input.todo.left_super,
        .right_super => Input.todo.right_super,
        .page_up => Input.todo.page_up,
        .page_down => Input.todo.page_down,
        .end => Input.todo.end,
        .home => Input.todo.home,
        .left => Input.todo.left,
        .up => Input.todo.up,
        .right => Input.todo.right,
        .down => Input.todo.down,
        .insert => Input.todo.insert,
        .delete => Input.todo.delete,

        .divide => Input.todo.kp_divide,

        else => null,
    };
    return switch (vk) {
        .back => Input.Key.backspace,
        .tab => Input.Key.tab,
        .@"return" => Input.Key.enter,
        // note: this could be left or right shift
        .shift => Input.todo.left_shift,
        .control => Input.todo.left_control,
        .alt => Input.todo.left_alt,
        .pause => Input.todo.pause,
        .caps_lock => Input.todo.caps_lock,
        .escape => Input.Key.escape,
        .space => Input.Key.space,
        .page_up => Input.todo.kp_page_up,
        .page_down => Input.todo.kp_page_down,
        .end => Input.todo.kp_end,
        .home => Input.todo.kp_home,
        .left => Input.todo.kp_left,
        .up => Input.todo.kp_up,
        .right => Input.todo.kp_right,
        .down => Input.todo.kp_down,
        .print_screen => Input.todo.print_screen,
        .insert => Input.todo.kp_insert,
        .delete => Input.todo.kp_delete,

        .left_super => Input.todo.left_super,
        .right_super => Input.todo.right_super,
        .numpad0 => Input.todo.kp_0,
        .numpad1 => Input.todo.kp_1,
        .numpad2 => Input.todo.kp_2,
        .numpad3 => Input.todo.kp_3,
        .numpad4 => Input.todo.kp_4,
        .numpad5 => Input.todo.kp_5,
        .numpad6 => Input.todo.kp_6,
        .numpad7 => Input.todo.kp_7,
        .numpad8 => Input.todo.kp_8,
        .numpad9 => Input.todo.kp_9,
        .multiply => Input.todo.kp_multiply,
        .add => Input.todo.kp_add,
        .separator => Input.todo.kp_separator,
        .subtract => Input.todo.kp_subtract,
        .decimal => Input.todo.kp_decimal,
        // odd, for some reason the divide key is considered extended?
        //.divide => Input.todo.kp_divide,
        .f1 => Input.todo.f1,
        .f2 => Input.todo.f2,
        .f3 => Input.todo.f3,
        .f4 => Input.todo.f4,
        .f5 => Input.todo.f5,
        .f6 => Input.todo.f6,
        .f7 => Input.todo.f8,
        .f8 => Input.todo.f8,
        .f9 => Input.todo.f9,
        .f10 => Input.todo.f10,
        .f11 => Input.todo.f11,
        .f12 => Input.todo.f12,
        .f13 => Input.todo.f13,
        .f14 => Input.todo.f14,
        .f15 => Input.todo.f15,
        .f16 => Input.todo.f16,
        .f17 => Input.todo.f17,
        .f18 => Input.todo.f18,
        .f19 => Input.todo.f19,
        .f20 => Input.todo.f20,
        .f21 => Input.todo.f21,
        .f22 => Input.todo.f22,
        .f23 => Input.todo.f23,
        .f24 => Input.todo.f24,
        .numlock => Input.todo.num_lock,
        .scroll => Input.todo.scroll_lock,
        .left_shift => Input.todo.left_shift,
        .right_shift => Input.todo.right_shift,
        .left_control => Input.todo.left_control,
        .right_control => Input.todo.right_control,
        .left_alt => Input.todo.left_alt,
        .right_alt => Input.todo.right_alt,
        .volume_mute => Input.todo.mute_volume,
        .volume_down => Input.todo.lower_volume,
        .volume_up => Input.todo.raise_volume,
        .media_next_track => Input.todo.media_track_next,
        .media_prev_track => Input.todo.media_track_previous,
        .media_stop => Input.todo.media_stop,
        .media_play_pause => Input.todo.media_play_pause,
        else => null,
    };
}

const WindowPlacementOptions = struct {
    x: ?i32,
    y: ?i32,
};

const window_use_default: i32 = switch (builtin.os.tag) {
    .windows => win32.CW_USEDEFAULT,
    else => 0,
};
const WindowPlacement = struct {
    dpi: XY(u32),
    size: zin.XY,
    pos: ?zin.XY,
    pub fn default(opt: WindowPlacementOptions) WindowPlacement {
        return .{
            .dpi = .{
                .x = 96,
                .y = 96,
            },
            .pos = .{
                .x = if (opt.x) |x| x else window_use_default,
                .y = if (opt.y) |y| y else window_use_default,
            },
            .size = .{
                .x = window_use_default,
                .y = window_use_default,
            },
        };
    }
};

fn calcWindowPlacement(opt: WindowPlacementOptions) WindowPlacement {
    var result = WindowPlacement.default(opt);

    if (builtin.os.tag == .windows) {
        const monitor = win32.MonitorFromPoint(
            .{ .x = 0, .y = 0 },
            win32.MONITOR_DEFAULTTOPRIMARY,
        ) orelse {
            std.log.warn("MonitorFromPoint failed, error={}", .{win32.GetLastError()});
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
                std.log.warn("GetMonitorInfo failed, error={}", .{win32.GetLastError()});
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
    } else {
        std.log.warn("calcWindowPlacement not implemented on this platform", .{});
    }
    return result;
}

const Icons = struct {
    small: zin.MaybeWin32Icon,
    large: zin.MaybeWin32Icon,
};
fn getIcons(dpi: XY(u32)) Icons {
    if (builtin.os.tag == .windows) {
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
        return .{
            .small = .init(@ptrCast(small)),
            .large = .init(@ptrCast(large)),
        };
    }
    return .{ .small = .none, .large = .none };
}

pub fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);

    // TODO: zin should expose some sort of messagebox
    if (builtin.os.tag == .windows) {
        // TODO: detect if there is a console or not, only show message box
        //       if there is not a console
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const msg = std.fmt.allocPrintZ(arena.allocator(), fmt, args) catch @panic("Out of memory");
        const result = win32.MessageBoxA(null, msg.ptr, null, win32.MB_OK);
        std.log.info("MessageBox result is {}", .{result});
    }
    std.posix.exit(0xff);
}

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

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const builtin = @import("builtin");
const std = @import("std");
const zin = @import("zin");
const win32 = zin.platform.win32;

const cimport = @cImport({
    @cInclude("MedResourceNames.h");
});

const engine = @import("engine.zig");
const theme = @import("theme.zig");
const Input = @import("Input.zig");
const XY = @import("xy.zig").XY;
const FileMode = @import("filemode.zig").FileMode;
const zigtokenizer = @import("zigtokenizer.zig");
