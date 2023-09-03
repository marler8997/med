// The complete interface between the current platform and the editor engine.
const std = @import("std");
const Input = @import("Input.zig");
const platform = @import("platform.zig");
const oom = platform.oom;
const XY = @import("xy.zig").XY;

const global = struct {
    pub var input: Input = .{};
    pub var opening_file = false;
};

// ================================================================================
// The interface for the platform to use
// ================================================================================
pub const Row = union(enum) {
    file_backed,
    array_list_backed: std.ArrayListUnmanaged(u8),

    pub fn getViewport(self: Row, render: Render) []u8 {
        switch (self) {
            .file_backed => @panic("todo"),
            .array_list_backed => |al| {
                if (render.viewport_pos.x >= al.items.len) return &[0]u8{ };
                const avail = al.items.len - render.viewport_pos.x;
                return al.items[render.viewport_pos.x ..][0 .. @min(avail, render.viewport_size.x)];
            },
        }
    }
};
pub const Render = struct {
    cursor_pos: ?XY(u16) = .{ .x = 0, .y = 0 },
    size: XY(u16) = .{ .x = 0, .y = 0 },
    viewport_pos: XY(u32) = .{ .x = 0, .y = 0 },
    viewport_size: XY(u16) = .{ .x = 30, .y = 40 },
    rows: std.ArrayListUnmanaged(Row) = .{},

    pub fn getViewportRows(self: *Render) []Row {
        if (self.viewport_pos.y >= self.rows.items.len) return &[0]Row{ };
        const avail = self.rows.items.len - self.viewport_pos.y;
        return self.rows.items[self.viewport_pos.y ..][0 .. @min(avail, self.viewport_size.y)];
    }
    pub fn toViewportPos(self: *Render, pos: XY(u16)) ?XY(u16) {
        if (pos.x < self.viewport_pos.x) return null;
        if (pos.y < self.viewport_pos.y) return null;
        if (pos.x >= self.viewport_pos.x + self.viewport_size.x) return null;
        if (pos.y >= self.viewport_pos.y + self.viewport_size.y) return null;
        return .{
            .x = @intCast(pos.x - self.viewport_pos.x),
            .y = @intCast(pos.y - self.viewport_pos.y),
        };
    }
};
pub var global_render = Render{ };
pub fn notifyKeyEvent(key: Input.Key, state: Input.KeyState) void {
    if (global.input.setKeyState(key, state)) |action|
        handleAction(action);
}
// ================================================================================
// End of the interface for the platform to use
// ================================================================================

fn handleAction(action: Input.Action) void {
    switch (action) {
        .add_char => |ascii_code| {
            if (global_render.cursor_pos) |*cursor_pos| {
                if (cursor_pos.y >= global_render.size.y) {
                    const needed_len = cursor_pos.y + 1;
                    if (global_render.rows.items.len < needed_len) {
                        std.log.info("adding {} row(s)", .{needed_len - global_render.rows.items.len});
                        global_render.rows.ensureTotalCapacity(row_allocator, needed_len) catch |e| oom(e);
                        const old_len = global_render.rows.items.len;
                        global_render.rows.items.len = needed_len;
                        for (global_render.rows.items[old_len .. needed_len]) |*row| {
                            row.* = .{ .array_list_backed = .{} };
                        }
                    }
                }

                const row = &global_render.rows.items[cursor_pos.y];
                const al = switch (row.*) {
                    .file_backed => @panic("todo"),
                    .array_list_backed => |*al| al,
                };

                if (cursor_pos.x >= al.items.len) {
                    const needed_len = cursor_pos.x + 1;
                    al.ensureTotalCapacity(row_allocator, needed_len) catch |e| oom(e);
                    const old_len = al.items.len;
                    al.items.len = needed_len;
                    for (al.items[old_len .. needed_len]) |*c| {
                        c.* = ' ';
                    }
                }
                std.log.warn("TODO: shift the old contents", .{});
                std.log.info("setting row {} col {} to '{c}'", .{cursor_pos.y, cursor_pos.x, ascii_code});
                al.items[cursor_pos.x] = ascii_code;
                cursor_pos.x += 1;
                platform.renderModified();
            }
        },
        .cursor_back => {
            if (global_render.cursor_pos) |*cursor_pos| {
                if (cursor_pos.x == 0) {
                    std.log.info("TODO: implement cursor back wrap", .{});
                } else {
                    cursor_pos.x -= 1;
                    platform.renderModified();
                }
            }
        },
        .cursor_forward => {
            if (global_render.cursor_pos) |*cursor_pos| {
                cursor_pos.x += 1;
                platform.renderModified();
            }
        },
        .cursor_up => {
            if (global_render.cursor_pos) |*cursor_pos| {
                if (cursor_pos.y == 0) {
                    std.log.info("TODO: implement cursor up scroll", .{});
                } else {
                    cursor_pos.y -= 1;
                    platform.renderModified();
                }
            }
        },
        .cursor_down => {
            if (global_render.cursor_pos) |*cursor_pos| {
                cursor_pos.y += 1;
                platform.renderModified();
            }
        },
        .cursor_line_start => std.log.info("TODO: implement cursor_line_start", .{}),
        .cursor_line_end => std.log.info("TODO: implement cursor_line_end", .{}),
        .open_file => {
            std.log.warn("TODO: implement open_file", .{});
//            if (!global.opening_file) {
//                global.opening_file = true;
//                updateRenderSize(.{ .x = 100, .y = 2 });
//                const prompt = "Open File:";
//                @memcpy(global_render.rows[0], prompt);
//                @memset(global_render.rows[0][prompt.len..global_render.size.x], ' ');
//
//                const path_buf = global_render.rows[1][0 .. global_render.size.x];
//                // TODO: handle errors
//                const path = std.os.getcwd(path_buf) catch |e| std.debug.panic("todo handle '{s}'", .{@errorName(e)});
//                if (path.len + 1 >= global_render.size.x) @panic("handle long cwd");
//                global_render.rows[1][path.len] = std.fs.path.sep;
//                global_render.cursor_pos = .{ .x = @intCast(path.len + 1), .y = 1 };
//                @memset(global_render.rows[1][path.len + 1..global_render.size.x], ' ');
//                platform.renderModified();
//            }
        },
        .quit => platform.quit(),
    }
}

pub fn updateRenderSize(size: XY(u16)) void {
    if (global_render.size.x == size.x and global_render.size.y == size.y)
        return;
    freeRows(global_render.size, global_render.rows);
    global_render.size = size;
    global_render.rows = allocRows(size);
}

var row_allocator_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const row_allocator = row_allocator_instance.allocator();
fn allocRows(size: XY(u16)) [*][*]u8 {
    const rows = row_allocator.alloc([*]u8, size.y) catch |e| platform.oom(e);
    for (0 .. size.y) |y| {
        rows[y] = (row_allocator.alloc(u8, size.x) catch |e| platform.oom(e)).ptr;
    }
    return rows.ptr;
}
fn freeRows(size: XY(u16), rows: [*][*]u8) void {
    if (size.x == 0 or size.y == 0) return;

    for (0 .. size.y) |y| {
        // free in reverse order, might be better for arena allocator?
        row_allocator.free(rows[size.y - y - 1][0 .. size.x]);
    }
    row_allocator.free(rows[0 .. size.y]);
}
