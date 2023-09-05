const builtin = @import("builtin");
const std = @import("std");
const x = @import("x");

const CmdlineOpt = @import("CmdlineOpt.zig");
const Input = @import("Input.zig");
const engine = @import("engine.zig");
const color = @import("color.zig");
const common = @import("x11common.zig");
const ContiguousReadBuffer = x.ContiguousReadBuffer;
const XY = @import("xy.zig").XY;

const Endian = std.builtin.Endian;

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 { return self.base; }
    pub fn gc_bg_fg(self: Ids) u32 { return self.base + 1; }
    pub fn gc_cursor_fg(self: Ids) u32 { return self.base + 2; }
    pub fn gc_bg_menu_fg(self: Ids) u32 { return self.base + 3; }
    pub fn gc_bg_menu_err(self: Ids) u32 { return self.base + 4; }
};

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

const global = struct {
    pub var sock: std.os.socket_t = undefined;
    pub var ids: Ids = undefined;
    pub var font_dims: FontDims = undefined;
    pub var window_content_size = XY(u16){ .x = 400, .y = 400 };
};

fn x11Key(set: x.Charset, code: u8) ?Input.Key {
    return switch (set) {
        .latin1 => switch (code) {
            @intFromEnum(x.charset.Latin1.space) => .space,
            @intFromEnum(x.charset.Latin1.comma) => .comma,
            @intFromEnum(x.charset.Latin1.period) => .period,
            @intFromEnum(x.charset.Latin1.slash) => .forward_slash,
            @intFromEnum(x.charset.Latin1.digit_zero) => ._0,
            @intFromEnum(x.charset.Latin1.digit_one) => ._1,
            @intFromEnum(x.charset.Latin1.digit_two) => ._2,
            @intFromEnum(x.charset.Latin1.digit_three) => ._3,
            @intFromEnum(x.charset.Latin1.digit_four) => ._4,
            @intFromEnum(x.charset.Latin1.digit_five) => ._5,
            @intFromEnum(x.charset.Latin1.digit_six) => ._6,
            @intFromEnum(x.charset.Latin1.digit_seven) => ._7,
            @intFromEnum(x.charset.Latin1.digit_eight) => ._8,
            @intFromEnum(x.charset.Latin1.digit_nine) => ._9,
            @intFromEnum(x.charset.Latin1.a) => .a,
            @intFromEnum(x.charset.Latin1.b) => .b,
            @intFromEnum(x.charset.Latin1.c) => .c,
            @intFromEnum(x.charset.Latin1.d) => .d,
            @intFromEnum(x.charset.Latin1.e) => .e,
            @intFromEnum(x.charset.Latin1.f) => .f,
            @intFromEnum(x.charset.Latin1.g) => .g,
            @intFromEnum(x.charset.Latin1.h) => .h,
            @intFromEnum(x.charset.Latin1.i) => .i,
            @intFromEnum(x.charset.Latin1.j) => .j,
            @intFromEnum(x.charset.Latin1.k) => .k,
            @intFromEnum(x.charset.Latin1.l) => .l,
            @intFromEnum(x.charset.Latin1.m) => .m,
            @intFromEnum(x.charset.Latin1.n) => .n,
            @intFromEnum(x.charset.Latin1.o) => .o,
            @intFromEnum(x.charset.Latin1.p) => .p,
            @intFromEnum(x.charset.Latin1.q) => .q,
            @intFromEnum(x.charset.Latin1.r) => .r,
            @intFromEnum(x.charset.Latin1.s) => .s,
            @intFromEnum(x.charset.Latin1.t) => .t,
            @intFromEnum(x.charset.Latin1.u) => .u,
            @intFromEnum(x.charset.Latin1.v) => .v,
            @intFromEnum(x.charset.Latin1.w) => .w,
            @intFromEnum(x.charset.Latin1.x) => .x,
            @intFromEnum(x.charset.Latin1.y) => .y,
            @intFromEnum(x.charset.Latin1.z) => .z,
            else => null,
        },
        .keyboard => switch (code) {
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
    std.os.exit(0xff);
}

pub fn rgbToXDepth16(rgb: color.Rgb) u16 {
    const r: u16 = @intCast((rgb.r >> 3) & 0x1f);
    const g: u16 = @intCast((rgb.g >> 3) & 0x1f);
    const b: u16 = @intCast((rgb.b >> 3) & 0x1f);
    return (r << 11) | (g << 6) | b;
}

pub fn rgbToX(rgb: color.Rgb, depth_bits: u8) u32 {
    return switch (depth_bits) {
        16 => rgbToXDepth16(rgb),
        24 => (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 0),
        32 => (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | (@as(u32, rgb.b) << 0),
        else => @panic("todo"),
    };
}

pub fn go(cmdline_opt: CmdlineOpt) !void {
    _ = cmdline_opt;

    try x.wsaStartup();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const conn = try common.connect(arena);
    defer {
        std.os.shutdown(conn.sock, .both) catch {};
        conn.setup.deinit(arena);
    }
    global.sock = conn.sock;

    const fixed = conn.setup.fixed();
    inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
        std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
    }
    global.ids = Ids{ .base = conn.setup.fixed().resource_id_base };
    std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
    const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
    for (formats, 0..) |format, i| {
        std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
    }
    const screen = conn.setup.getFirstScreenPtr(format_list_limit);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
    }

    // TODO: maybe need to call conn.setup.verify or something?


    var keycode_map = std.AutoHashMapUnmanaged(u8, Input.Key){};
    {
        const keymap = try x.keymap.request(gpa, conn.sock, conn.setup.fixed().*);
        defer keymap.deinit(gpa);
        std.log.info("Keymap: syms_per_code={} total_syms={}", .{keymap.syms_per_code, keymap.syms.len});
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode: u8 = @intCast(conn.setup.fixed().min_keycode + i);
                var j: usize = 0;
                while (j < keymap.syms_per_code) : (j += 1) {
                    const sym = keymap.syms[sym_offset];
                    if (sym == 0) {
                        //std.log.info("{}-{}: nothing", .{keycode, j});
                    } else {
                        const set_u8: u8 = @intCast((sym >> 8) & 0xff);
                        const set_opt: ?x.Charset = x.Charset.fromInt(set_u8);
                        const code: u8 = @intCast(sym & 0xff);
                        const set_name = if (set_opt) |set| @tagName(set) else "?";
                        const code_name = if (set_opt) |set| getCodeName(set, code) orelse "?" else "?";
                        //std.log.info("{}-{}: 0x{x} set {s}({}) code {s}({})", .{keycode, j, sym, set_name, set_u8, code_name, code});

                        if (set_opt) |set| {
                            if (x11Key(set, code)) |key| {
                                std.log.info("keycode {}: set {s}({}) code {s}({}) key {s}", .{
                                    keycode,
                                    set_name,
                                    set_u8,
                                    code_name,
                                    code,
                                    @tagName(key),
                                });
                                const entry = try keycode_map.getOrPut(gpa, keycode);
                                if (entry.found_existing) {
                                    if (entry.value_ptr.* != key) {
                                        std.debug.panic("keycode {} maps to muliple keys? {s} and {s}", .{keycode, @tagName(entry.value_ptr.*), @tagName(key)});
                                    }
                                } else {
                                    entry.value_ptr.* = key;
                                }
                            }
                        }
                    }
                    sym_offset += 1;
                }
            }
        }
    }


    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = global.ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0, .y = 0,
            .width = global.window_content_size.x,
            .height = global.window_content_size.y,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
            }, .{
            //            .bg_pixmap = .copy_from_parent,
            .bg_pixel = rgbToX(color.bg, screen.root_depth),
            //            //.border_pixmap =
            //            .border_pixel = 0x01fa8ec9,
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //            .override_redirect = true,
            //            .save_under = true,
            .event_mask =
                x.event.key_press
                | x.event.key_release
                | x.event.button_press
                | x.event.button_release
                | x.event.enter_window
                | x.event.leave_window
                | x.event.pointer_motion
                //                | x.event.pointer_motion_hint WHAT THIS DO?
                //                | x.event.button1_motion  WHAT THIS DO?
                //                | x.event.button2_motion  WHAT THIS DO?
                //                | x.event.button3_motion  WHAT THIS DO?
                //                | x.event.button4_motion  WHAT THIS DO?
                //                | x.event.button5_motion  WHAT THIS DO?
                //                | x.event.button_motion  WHAT THIS DO?
                | x.event.keymap_state
                | x.event.exposure
                ,
            //            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    try createGc(
        screen.root,
        global.ids.gc_bg_fg(),
        rgbToX(color.bg, screen.root_depth),
        rgbToX(color.fg, screen.root_depth),
    );
    try createGc(
        screen.root,
        global.ids.gc_cursor_fg(),
        rgbToX(color.cursor, screen.root_depth),
        rgbToX(color.fg, screen.root_depth),
    );
    try createGc(
        screen.root,
        global.ids.gc_bg_menu_fg(),
        rgbToX(color.bg_menu, screen.root_depth),
        rgbToX(color.fg, screen.root_depth),
    );
    try createGc(
        screen.root,
        global.ids.gc_bg_menu_err(),
        rgbToX(color.bg_menu, screen.root_depth),
        rgbToX(color.err, screen.root_depth),
    );

    // get some font information
    {
        const text_literal = [_]u16 { 'm' };
        const text = x.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
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
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                    if (keycode_map.get(msg.keycode)) |key| {
                        engine.notifyKeyEvent(key, .down);
                    }
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
                    if (keycode_map.get(msg.keycode)) |key| {
                        engine.notifyKeyEvent(key, .up);
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
    std.os.exit(0);
}
pub fn renderModified() void {
    // TODO: maybe defer the rendering?
    render() catch |err| std.debug.panic("render failed with error {s}", .{@errorName(err)});
}
pub const Mmap = struct {
    mem: []align(std.mem.page_size)u8,
    pub fn deinit(self: Mmap) void {
        std.os.munmap(self.mem);
    }
};
pub fn mmap(filename: []const u8, file: std.fs.File, file_size: u64) error{Reported}!Mmap {
    return .{
        .mem = std.os.mmap(null, file_size, std.os.PROT.READ, std.os.MAP.PRIVATE, file.handle, 0) catch |err| {
            engine.global_render.setError("mmap '{s}' failed, error={s}", .{filename, @errorName(err)});
            return error.Reported;
        },
    };
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
            .x = 0, .y = 0, .width = global.window_content_size.x, .height = global.window_content_size.y,
        });
        try common.send(global.sock, &msg);
    }

    const viewport_rows = engine.global_render.getViewportRows();

    for (viewport_rows, 0..) |row, row_index| {
        const text = row.getViewport(engine.global_render);
        try renderText(global.ids.gc_bg_fg(), text, .{ .x = 0, .y = @intCast(row_index) });
    }

    // draw cursor
    if (engine.global_render.cursor_pos) |cursor_global_pos| {
        if (engine.global_render.toViewportPos(cursor_global_pos)) |cursor_viewport_pos| {
            const char_str: []const u8 = blk: {
                if (cursor_viewport_pos.y >= viewport_rows.len) break :blk " ";
                const row = &viewport_rows[cursor_viewport_pos.y];
                const row_str = row.getViewport(engine.global_render);
                if (cursor_viewport_pos.x >= row_str.len) break :blk " ";
                break :blk row_str[cursor_viewport_pos.x..];
            };
            try renderText(global.ids.gc_cursor_fg(), char_str[0 .. 1], cursor_viewport_pos);
        }
    }

    if (engine.global_render.open_file_prompt) |*prompt| {
        {
            var msg: [x.clear_area.len]u8 = undefined;
            x.clear_area.serialize(&msg, false, global.ids.window(), .{
                .x = 0, .y = 0,
                .width = global.window_content_size.x,
                .height = 2 * global.font_dims.height,
            });
            try common.send(global.sock, &msg);
        }
        try renderText(global.ids.gc_bg_menu_fg(), "Open File:", .{ .x = 0, .y = 0 });
        try renderText(global.ids.gc_bg_menu_fg(), prompt.getPathConst(), .{ .x = 0, .y = 1 });
    }
    if (engine.global_render.getError()) |error_msg| {
        {
            var msg: [x.clear_area.len]u8 = undefined;
            x.clear_area.serialize(&msg, false, global.ids.window(), .{
                .x = 0, .y = 0,
                .width = global.window_content_size.x,
                .height = global.font_dims.height,
            });
            try common.send(global.sock, &msg);
        }
        try renderText(global.ids.gc_bg_menu_err(), "Error:", .{ .x = 0, .y = 0 });
        try renderText(global.ids.gc_bg_menu_err(), error_msg, .{ .x = 0, .y = 1 });
    }
}

fn renderText(gc_id: u32, text: []const u8, pos: XY(u16)) !void {
    const xslice = x.Slice(u8, [*]const u8) {
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
    try common.send(global.sock, msg_buf[0 .. x.image_text8.getLen(xslice.len)]);
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
