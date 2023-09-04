// The complete interface between the current platform and the editor engine.
const std = @import("std");
const Input = @import("Input.zig");
const platform = @import("platform.zig");
const oom = platform.oom;
const XY = @import("xy.zig").XY;

const global = struct {
    pub var input: Input = .{};
};

var row_allocator_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const row_allocator = row_allocator_instance.allocator();

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
pub const OpenFilePrompt = struct {
    const max_path_len = 2048;
    path_buf: [max_path_len]u8 = undefined,
    path_len: usize,
    pub fn getPathConst(self: *const OpenFilePrompt) []const u8 {
        return self.path_buf[0 .. self.path_len];
    }
};
pub const Render = struct {
    const max_error_msg = 400;

    cursor_pos: ?XY(u16) = .{ .x = 0, .y = 0 },
    size: XY(u16) = .{ .x = 0, .y = 0 },
    viewport_pos: XY(u32) = .{ .x = 0, .y = 0 },
    viewport_size: XY(u16) = .{ .x = 30, .y = 40 },
    rows: std.ArrayListUnmanaged(Row) = .{},
    open_file_prompt: ?OpenFilePrompt = null,

    error_len: usize = 0,
    error_buf: [max_error_msg]u8 = undefined,

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
    pub fn getError(self: *Render) ?[]const u8 {
        if (self.error_len == 0) return null;
        return self.error_buf[0 .. self.error_len];
    }
    pub fn setError(self: *Render, comptime fmt: []const u8, args: anytype) void {
        self.error_len = (std.fmt.bufPrint(&self.error_buf, fmt, args) catch |e| switch (e) {
            error.NoSpaceLeft => {
                std.log.err("the next error is too long to format!", .{});
                std.log.err(fmt, args);
                const too_long_msg = "got error but message is too long. (see log)";
                @memcpy(self.error_buf[0 .. too_long_msg.len], too_long_msg);
                self.error_len = too_long_msg.len;
                return;
            },
        }).len;
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
            if (global_render.open_file_prompt) |*prompt| {
                if (prompt.path_len >= prompt.path_buf.len) {
                    // beep?
                    std.log.err("path too long", .{});
                    return;
                }
                prompt.path_buf[prompt.path_len] = ascii_code;
                prompt.path_len += 1;
                platform.renderModified();
                return;
            }

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

                if (al.items.len > cursor_pos.x) {
                    al.ensureUnusedCapacity(row_allocator, 1) catch |e| oom(e);
                    const old_len = al.items.len;
                    al.items.len += 1;
                    std.mem.copyBackwards(u8, al.items[cursor_pos.x + 1..], al.items[cursor_pos.x..old_len]);
                }
                if (cursor_pos.x >= al.items.len) {
                    const needed_len = cursor_pos.x + 1;
                    al.ensureTotalCapacity(row_allocator, needed_len) catch |e| oom(e);
                    const old_len = al.items.len;
                    al.items.len = needed_len;
                    for (al.items[old_len .. needed_len]) |*c| {
                        c.* = ' ';
                    }
                }
                std.log.info("setting row {} col {} to '{c}'", .{cursor_pos.y, cursor_pos.x, ascii_code});
                al.items[cursor_pos.x] = ascii_code;
                cursor_pos.x += 1;
                platform.renderModified();
            }
        },
        .enter => {
            if (global_render.error_len != 0) {
                global_render.error_len = 0;
                platform.renderModified();
                return;
            }
            if (global_render.open_file_prompt) |*prompt| {
                openFile(prompt.getPathConst());
                global_render.open_file_prompt = null;
                platform.renderModified();
                return;
            }
            std.log.warn("TODO: handle enter", .{});
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
        .cursor_line_start => {
            if (global_render.cursor_pos) |*cursor_pos| {
                if (cursor_pos.x != 0) {
                    cursor_pos.x = 0;
                    platform.renderModified();
                }
            }
        },
        .cursor_line_end => std.log.info("TODO: implement cursor_line_end", .{}),
        .open_file => {
            if (global_render.open_file_prompt == null) {
                global_render.open_file_prompt = .{ .path_len = 0 };
                const prompt = &global_render.open_file_prompt.?;
                const path = std.os.getcwd(&prompt.path_buf) catch |e| std.debug.panic("todo handle '{s}'", .{@errorName(e)});
                if (path.len + 1 >= prompt.path_buf.len) @panic("handle long cwd");
                prompt.path_buf[path.len] = std.fs.path.sep;
                prompt.path_len = path.len + 1;
                platform.renderModified();
            }
        },
        .quit => platform.quit(),
    }
}

fn openFile(filename: []const u8) void {
    var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        global_render.setError("openFile '{s}' failed with {s}", .{filename, @errorName(err)});
        platform.renderModified();
        return;
    };
    defer file.close();
    std.log.err("TODO: implement openFile '{s}'", .{filename});
}
