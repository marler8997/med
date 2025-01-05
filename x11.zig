const builtin = @import("builtin");
const std = @import("std");
const x = @import("x");

const CmdlineOpt = @import("CmdlineOpt.zig");
const Input = @import("Input.zig");
const engine = @import("engine.zig");
const common = @import("x11common.zig");
const ContiguousReadBuffer = x.ContiguousReadBuffer;
const theme = @import("theme.zig");
const XY = @import("xy.zig").XY;

const Endian = std.builtin.Endian;

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 {
        return self.base;
    }
    pub fn gc_bg_fg(self: Ids) u32 {
        return self.base + 1;
    }
    pub fn gc_cursor_fg(self: Ids) u32 {
        return self.base + 2;
    }
    pub fn gc_bg_menu_fg(self: Ids) u32 {
        return self.base + 3;
    }
    pub fn gc_bg_menu_err(self: Ids) u32 {
        return self.base + 4;
    }
};

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

const global = struct {
    pub var sock: std.posix.socket_t = undefined;
    pub var ids: Ids = undefined;
    pub var font_dims: FontDims = undefined;
    pub var window_content_size = XY(u16){ .x = 400, .y = 400 };
    pub var view_modified = false;
};

fn x11KeysymToKey(keysym: x.charset.Combined) ?Input.Key {
    return switch (keysym.charset()) {
        .latin1 => return switch (keysym.code()) {
            0...31 => null,
            ' '...'~' => |c| @enumFromInt(@intFromEnum(Input.Key.space) + (c - ' ')),
            127...255 => null,
        },
        .keyboard => switch (keysym.code()) {
            @intFromEnum(x.charset.Keyboard.backspace_back_space_back_char) => .backspace,
            @intFromEnum(x.charset.Keyboard.return_enter) => .enter,
            @intFromEnum(x.charset.Keyboard.left_control) => .control,
            @intFromEnum(x.charset.Keyboard.right_control) => .control,
            else => null,
        },
        else => null,
    };
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    std.log.err("{s}", .{@errorName(e)});
    std.posix.exit(0xff);
}

pub fn rgbToXDepth16(rgb: theme.Rgb) u16 {
    const r: u16 = @intCast((rgb.r >> 3) & 0x1f);
    const g: u16 = @intCast((rgb.g >> 3) & 0x1f);
    const b: u16 = @intCast((rgb.b >> 3) & 0x1f);
    return (r << 11) | (g << 6) | b;
}

pub fn rgbToX(rgb: theme.Rgb, depth_bits: u8) u32 {
    return switch (depth_bits) {
        16 => rgbToXDepth16(rgb),
        24 => (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 0),
        32 => (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 0),
        else => @panic("todo"),
    };
}

// ================================================================================
// TODO: move this stuff into zigx
// ================================================================================
// Every Keycode has a standard mapping to 4 possible symbols:
//
//      Group 1       Group 2
//         |             |
//      |------|      |------|
//     Sym0   Sym1   Sym2   Sym3
//      |      |      |      |
//    lower  upper  lower  upper
//
// The presence of any modifier flag (Mod1 through Mod5) indicates
// Group 2 should be used instead of Group 1.
//
// The "shift/caps lock" flag indicates the second symbol in the group
// should be used instead of the first.
//
// The Keymap may include less or more than 4 symbols per code.  More than
// 4 entries are for non-standard mappings, less than 4 can be interpreted
// as 4 using the following mapping:
//
//      |  Sym0  |   Sym1   |  Sym2   |   Sym3   |
//   ---------------------------------------------
//    1 |  first | NoSymbol |  first  | NoSymbol |
//    2 |  first |  second  |  first  |  second  |
//    3 |  first |  second  |  third  | NoSymbol |
//
// NOTE: A group of the form
//    Keysym NoSymbol
// Is the same as:
//    lowercase(Keysym) uppercase(Keysym)
//
pub const KeycodeMod = enum(u2) {
    lower,
    upper,
    lower_mod,
    upper_mod,
    pub fn init(state: u16) KeycodeMod {
        var result: u2 = 0;
        if (0 != (state & 1)) result += 1; // Shift flag
        if (0 != (state & 0xf8)) result += 2; // Mod1-Mod5 flags mask
        return @enumFromInt(result);
    }
};
fn keymapEntrySyms(syms_per_code: u8, syms: []u32) [4]x.charset.Combined {
    std.debug.assert(syms.len >= syms_per_code);
    switch (syms_per_code) {
        0 => @panic("keymap syms_per_code can't be 0"),
        1 => @panic("todo"),
        2 => @panic("todo"),
        3 => @panic("todo"),
        4...255 => return [4]x.charset.Combined{
            @enumFromInt(syms[0] & 0xffff),
            @enumFromInt(syms[1] & 0xffff),
            @enumFromInt(syms[2] & 0xffff),
            @enumFromInt(syms[3] & 0xffff),
        },
    }
}
const Keymap = struct {
    map: [248][4]x.charset.Combined,
    pub fn initVoid() Keymap {
        var result: Keymap = undefined;
        for (&result.map) |*entry_ref| {
            // TODO: initialize to VoidSymbol instead of 0
            entry_ref.* = [1]x.charset.Combined{@enumFromInt(0)} ** 4;
        }
        return result;
    }
    pub fn load(
        self: *Keymap,
        min_keycode: u8,
        keymap: x.keymap.Keymap,
    ) void {
        if (min_keycode < 8)
            std.debug.panic("min_keycode is too small {}", .{min_keycode});
        if (keymap.keycode_count > 248)
            std.debug.panic("keymap has too many keycodes {}", .{keymap.keycode_count});
        if (keymap.syms_per_code == 0)
            @panic("keymap syms_per_code cannot be 0");

        std.log.info("Keymap: syms_per_code={} total_syms={}", .{ keymap.syms_per_code, keymap.syms.len });
        var keycode_index: usize = 0;
        var sym_offset: usize = 0;
        while (keycode_index < keymap.keycode_count) : (keycode_index += 1) {
            const keycode: u8 = @intCast(min_keycode + keycode_index);
            self.map[keycode - 8] = keymapEntrySyms(
                keymap.syms_per_code,
                keymap.syms[sym_offset..],
            );
            sym_offset += keymap.syms_per_code;
        }
    }
    pub fn getKeysym(self: Keymap, keycode: u8, mod: KeycodeMod) x.charset.Combined {
        if (keycode < 8) @panic("invalid keycode");
        return self.map[keycode - 8][@intFromEnum(mod)];
    }
};

pub fn go(cmdline_opt: CmdlineOpt) !void {
    _ = cmdline_opt;

    try x.wsaStartup();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const conn = try common.connect(arena);
    defer {
        std.posix.shutdown(conn.sock, .both) catch {};
        conn.setup.deinit(arena);
    }
    global.sock = conn.sock;

    const fixed = conn.setup.fixed();
    inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
        std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
    }
    global.ids = Ids{ .base = conn.setup.fixed().resource_id_base };
    std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
    const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
    for (formats, 0..) |format, i| {
        std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
    }
    const screen = conn.setup.getFirstScreenPtr(format_list_limit);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
    }

    // TODO: maybe need to call conn.setup.verify or something?

    var keymap = Keymap.initVoid();
    {
        const keymap_response = try x.keymap.request(gpa, conn.sock, conn.setup.fixed().*);
        defer keymap_response.deinit(gpa);
        keymap.load(conn.setup.fixed().min_keycode, keymap_response);
    }

    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = global.ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0,
            .y = 0,
            .width = global.window_content_size.x,
            .height = global.window_content_size.y,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            //            .bg_pixmap = .copy_from_parent,
            .bg_pixel = rgbToX(theme.bg_content, screen.root_depth),
            //            //.border_pixmap =
            //            .border_pixel = 0x01fa8ec9,
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //            .override_redirect = true,
            //            .save_under = true,
            .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion
            //                | x.event.pointer_motion_hint WHAT THIS DO?
            //                | x.event.button1_motion  WHAT THIS DO?
            //                | x.event.button2_motion  WHAT THIS DO?
            //                | x.event.button3_motion  WHAT THIS DO?
            //                | x.event.button4_motion  WHAT THIS DO?
            //                | x.event.button5_motion  WHAT THIS DO?
            //                | x.event.button_motion  WHAT THIS DO?
            | x.event.keymap_state | x.event.exposure,
            //            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    try createGc(
        screen.root,
        global.ids.gc_bg_fg(),
        rgbToX(theme.bg_content, screen.root_depth),
        rgbToX(theme.fg, screen.root_depth),
    );
    try createGc(
        screen.root,
        global.ids.gc_cursor_fg(),
        rgbToX(theme.cursor, screen.root_depth),
        rgbToX(theme.fg, screen.root_depth),
    );
    try createGc(
        screen.root,
        global.ids.gc_bg_menu_fg(),
        rgbToX(theme.bg_menu, screen.root_depth),
        rgbToX(theme.fg, screen.root_depth),
    );
    try createGc(
        screen.root,
        global.ids.gc_bg_menu_err(),
        rgbToX(theme.bg_menu, screen.root_depth),
        rgbToX(theme.err, screen.root_depth),
    );

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, global.ids.gc_bg_fg(), text);
        try conn.send(&msg);
    }

    const double_buf = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.mem.page_size),
        .{ .memfd_name = "MedX11DoubleBuffer" },
    );
    defer double_buf.deinit();
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    global.font_dims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return error.X11UnexpectedReply;
            },
        }
    };
    std.log.info("font_dims {}x{} left={} ascent={}", .{
        global.font_dims.width,
        global.font_dims.height,
        global.font_dims.font_left,
        global.font_dims.font_ascent,
    });

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, global.ids.window());
        try conn.send(&msg);
    }

    while (true) {
        if (global.view_modified) {
            try render();
            global.view_modified = false;
        }

        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return error.X11BufferTooSmall;
            }
            const len = try x.readSock(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (msg_len == 0)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return error.X11Error;
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    const mod = KeycodeMod.init(msg.state);
                    //std.log.info("key_press: keycode={} mod={s}", .{msg.keycode, @tagName(mod)});
                    const keysym = keymap.getKeysym(msg.keycode, mod);
                    if (x11KeysymToKey(keysym)) |key| {
                        _ = key;
                        @panic("todo");
                        //engine.notifyKeyEvent(key, .down);
                    }
                },
                .key_release => |msg| {
                    const mod = KeycodeMod.init(msg.state);
                    //std.log.info("key_release: keycode={} mod={s}", .{msg.keycode, @tagName(mod)});
                    const keysym = keymap.getKeysym(msg.keycode, mod);
                    if (x11KeysymToKey(keysym)) |key| {
                        _ = key;
                        @panic("todo");
                        //engine.notifyKeyEvent(key, .up);
                    }
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render();
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for structure_notify events
            }
        }
    }
}

fn createGc(drawable_id: u32, gc_id: u32, bg: u32, fg: u32) !void {
    var msg_buf: [x.create_gc.max_len]u8 = undefined;
    const len = x.create_gc.serialize(&msg_buf, .{
        .gc_id = gc_id,
        .drawable_id = drawable_id,
    }, .{
        .background = bg,
        .foreground = fg,
        // prevent NoExposure events when we CopyArea
        .graphics_exposures = false,
    });
    try common.send(global.sock, msg_buf[0..len]);
}

// ================================================================================
// The interface for the engine to use
// ================================================================================
pub fn quit() void {
    std.log.info("TODO: should we check if there are unsaved changes before exiting?", .{});
    std.posix.exit(0);
}
pub const errModified = viewModified;
pub fn viewModified() void {
    global.view_modified = true;
}
// ================================================================================
// End of the interface for the engine to use
// ================================================================================

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render() !void {
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, global.ids.window(), .{
            .x = 0,
            .y = 0,
            .width = global.window_content_size.x,
            .height = global.window_content_size.y,
        });
        try common.send(global.sock, &msg);
    }

    const viewport_rows = engine.global_view.getViewportRows();

    for (viewport_rows, 0..) |row, row_index| {
        const text = row.getViewport(engine.global_view);
        try renderText(global.ids.gc_bg_fg(), text, .{ .x = 0, .y = @intCast(row_index) });
    }

    // draw cursor
    if (engine.global_view.cursor_pos) |cursor_global_pos| {
        if (engine.global_view.toViewportPos(cursor_global_pos)) |cursor_viewport_pos| {
            const char_str: []const u8 = blk: {
                if (cursor_viewport_pos.y >= viewport_rows.len) break :blk " ";
                const row = &viewport_rows[cursor_viewport_pos.y];
                const row_str = row.getViewport(engine.global_view);
                if (cursor_viewport_pos.x >= row_str.len) break :blk " ";
                break :blk row_str[cursor_viewport_pos.x..];
            };
            try renderText(global.ids.gc_cursor_fg(), char_str[0..1], cursor_viewport_pos);
        }
    }

    if (engine.global_view.open_file_prompt) |*prompt| {
        {
            var msg: [x.clear_area.len]u8 = undefined;
            x.clear_area.serialize(&msg, false, global.ids.window(), .{
                .x = 0,
                .y = 0,
                .width = global.window_content_size.x,
                .height = 2 * global.font_dims.height,
            });
            try common.send(global.sock, &msg);
        }
        try renderText(global.ids.gc_bg_menu_fg(), "Open File:", .{ .x = 0, .y = 0 });
        try renderText(global.ids.gc_bg_menu_fg(), prompt.getPathConst(), .{ .x = 0, .y = 1 });
    }
    if (engine.global_view.err_msg) |err_msg| {
        {
            var msg: [x.clear_area.len]u8 = undefined;
            x.clear_area.serialize(&msg, false, global.ids.window(), .{
                .x = 0,
                .y = 0,
                .width = global.window_content_size.x,
                .height = global.font_dims.height,
            });
            try common.send(global.sock, &msg);
        }
        try renderText(global.ids.gc_bg_menu_err(), "Error:", .{ .x = 0, .y = 0 });
        try renderText(global.ids.gc_bg_menu_err(), err_msg.slice, .{ .x = 0, .y = 1 });
    }
}

fn renderText(gc_id: u32, text: []const u8, pos: XY(u16)) !void {
    const xslice = x.Slice(u8, [*]const u8){
        .ptr = text.ptr,
        .len = std.math.cast(u8, text.len) orelse @panic("todo: handle render text longer than 255"),
    };
    var msg_buf: [x.image_text8.max_len]u8 = undefined;
    x.image_text8.serialize(&msg_buf, xslice, .{
        .drawable_id = global.ids.window(),
        .gc_id = gc_id,
        .x = @intCast(pos.x * global.font_dims.width),
        .y = @as(i16, @intCast(pos.y * global.font_dims.height)) + global.font_dims.font_ascent,
    });
    try common.send(global.sock, msg_buf[0..x.image_text8.getLen(xslice.len)]);
}

fn getCodeName(set: x.Charset, code: u8) ?[]const u8 {
    switch (set) {
        inline else => |set_ct| {
            const Enum = set_ct.Enum();
            return std.enums.tagName(Enum, enumFromInt(Enum, code) orelse return null);
        },
    }
}

pub fn enumFromInt(comptime E: type, value: @typeInfo(E).Enum.tag_type) ?E {
    return inline for (@typeInfo(E).Enum.fields) |f| {
        if (value == f.value) break @enumFromInt(f.value);
    } else null;
}
