const View = @This();

const std = @import("std");
const hook = @import("hook.zig");
const highlight = @import("highlight.zig");
const Error = @import("Error.zig");
const MappedFile = @import("MappedFile.zig");
const RefString = @import("RefString.zig");
const RowView = @import("RowView.zig");
const XY = @import("xy.zig").XY;

arena_instance: std.heap.ArenaAllocator,
file: ?OpenFile = null,
rows: std.ArrayListUnmanaged(Row) = .{},
cursor_pos: ?XY(u32) = .{ .x = 0, .y = 0 },
viewport_pos: XY(u32) = .{ .x = 0, .y = 0 },

pub fn reset(self: *View) void {
    if (self.file) |file| {
        file.close();
        self.file = null;
    }
    // no need to free "rows" because of arena
    if (!self.arena_instance.reset(.retain_capacity)) {
        std.log.warn("view arena failed to reset", .{});
    }
    self.rows = .{};
    self.cursor_pos = .{ .x = 0, .y = 0 };
    self.viewport_pos = .{ .x = 0, .y = 0 };
}

// TODO: make this private once I move more code into this file
pub fn arena(self: *View) std.mem.Allocator {
    return self.arena_instance.allocator();
}

const file_ext_map = std.StaticStringMap(highlight.Mode).initComptime(.{
    .{ ".zig", .zig },
    .{ ".c", .c },
    .{ ".cc", .c },
    .{ ".cpp", .c },
});

pub const OpenFile = struct {
    map: MappedFile,
    name: RefString,
    mode: ?highlight.Mode,
    pub fn initAndNameAddRef(map: MappedFile, name: RefString) OpenFile {
        name.addRef();
        const extension = std.fs.path.extension(name.slice);
        return .{
            .map = map,
            .name = name,
            .mode = file_ext_map.get(extension) orelse null,
        };
    }
    pub fn close(self: OpenFile) void {
        self.map.unmap();
        self.name.unref();
    }
};

pub const Row = union(enum) {
    file_backed: struct {
        offset: usize,
        limit: usize,
    },
    array_list_backed: std.ArrayListUnmanaged(u8),

    pub fn getLen(self: Row) usize {
        return switch (self) {
            .file_backed => |r| r.limit - r.offset,
            .array_list_backed => |al| al.items.len,
        };
    }
    /// WARNING: this slice becomes invalid if this row is "modified" i.e.
    ///          appending to it or change it from file_backed to array_list_backed
    pub fn getSlice(self: Row, open_file: ?OpenFile) []u8 {
        return switch (self) {
            .file_backed => |r| return open_file.?.map.mem[r.offset..r.limit],
            .array_list_backed => |al| al.items,
        };
    }
    pub fn getView(self: Row, view: View, viewport_width: usize) RowView {
        const full = switch (self) {
            .file_backed => |r| view.file.?.map.mem[r.offset..r.limit],
            .array_list_backed => |al| al.items,
        };
        if (view.viewport_pos.x >= full.len) return .{ .full = &[0]u8{}, .index = 0, .limit = 0 };
        return .{
            .full = full,
            .index = view.viewport_pos.x,
            .limit = @min(full.len, view.viewport_pos.x + viewport_width),
        };
    }
};

pub fn getViewportRows(self: View, viewport_height: usize) []Row {
    if (self.viewport_pos.y >= self.rows.items.len) return &[0]Row{};
    const avail = self.rows.items.len - self.viewport_pos.y;
    return self.rows.items[self.viewport_pos.y..][0..@min(avail, viewport_height)];
}
pub fn toViewportPos(self: View, viewport_size: XY(usize), pos: XY(u32)) ?XY(u32) {
    if (pos.x < self.viewport_pos.x) return null;
    if (pos.y < self.viewport_pos.y) return null;
    if (pos.x >= self.viewport_pos.x + viewport_size.x) return null;
    if (pos.y >= self.viewport_pos.y + viewport_size.y) return null;
    return .{
        .x = @intCast(pos.x - self.viewport_pos.x),
        .y = @intCast(pos.y - self.viewport_pos.y),
    };
}

/// WARNING: this slice becomes invalid if this row is "modified" i.e.
///          appending to it or change it from file_backed to array_list_backed
pub fn getRowSlice(self: View, row_index: usize) []u8 {
    std.debug.assert(row_index < self.rows.items.len);
    return self.rows.items[row_index].getSlice(self.file);
}

pub fn moveCursor(self: *View, new_pos: XY(u32)) bool {
    if (self.cursor_pos) |pos| {
        if (pos.x == new_pos.x and pos.y == new_pos.y) return false;
    }
    self.cursor_pos = new_pos;
    const view_row_count = hook.getViewRowCount();
    _ = view_row_count;
    @panic("todo: move view to cursor");
}

// returns true if it was able to move the cursor backward
pub fn cursorBack(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.x == 0) {
            std.log.info("TODO: implement cursor back wrap", .{});
            return false;
        } else {
            cursor_pos.x -= 1;
            return true;
        }
    }
    return false;
}

// returns true if it was able to move the cursor forward
pub fn cursorForward(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        cursor_pos.x += 1;
        return true;
    }
    return false;
}

// returns true if it was able to move the cursor up
pub fn cursorUp(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.y == 0) return false;
        cursor_pos.y -= 1;
        if (cursor_pos.y < self.viewport_pos.y) {
            // NOTE: emacs will page up so the cursor is in the center, but,
            //       the user could just use control-l to do that so...?
            self.viewport_pos.y = cursor_pos.y;
        }
        return true;
    }
    return false;
}

// returns true if it was able to move the cursor down
pub fn cursorDown(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        cursor_pos.y += 1;

        const view_row_count = hook.getViewRowCount();
        if (cursor_pos.y >= self.viewport_pos.y + view_row_count) {
            // NOTE: emacs will page down so the cursor is in the center, but,
            //       the user could just use control-l to do that so...?
            self.viewport_pos.y = cursor_pos.y + 1 - view_row_count;
        }
        return true;
    }
    return false;
}

// returns true if the cursor moved
pub fn cursorLineStart(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.x != 0) {
            cursor_pos.x = 0;
            return true;
        }
    }
    return false;
}

// returns true if the cursor moved
pub fn cursorLineEnd(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        const eol = blk: {
            // if there is no content, move the cursor back to
            // the start of the line
            if (cursor_pos.y >= self.rows.items.len)
                break :blk 0;
            break :blk self.rows.items[cursor_pos.y].getLen();
        };
        if (cursor_pos.x != eol) {
            // TODO: what do we do if eol exceed std.math.maxInt(u16)?
            cursor_pos.x = @intCast(eol);
            return true;
        }
    }
    return false;
}

pub fn @"cursor-file-start"(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.y == 0 and cursor_pos.x == 0) return false;
    }
    self.cursor_pos = .{ .x = 0, .y = 0 };
    self.viewport_pos = .{ .x = 0, .y = 0 };
    return true;
}

pub fn @"cursor-file-end"(self: *View) bool {
    if (self.rows.items.len == 0) return false;
    const last_row = self.rows.items.len - 1;
    const last_column = self.rows.items[last_row].getLen();
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.y == last_row and cursor_pos.x == last_column) return false;
    }
    self.cursor_pos = .{ .x = @intCast(last_column), .y = @intCast(last_row) };
    const view_row_count = hook.getViewRowCount();
    if (view_row_count > last_row + 1) {
        self.viewport_pos.y = 0;
    } else {
        self.viewport_pos.y = @intCast(last_row + 1 - view_row_count);
    }
    return true;
}

pub fn @"scroll-to-cursor"(self: *View) bool {
    const cursor_pos = self.cursor_pos orelse return false;

    // for now we'll just center
    const view_row_count = hook.getViewRowCount();
    const half_row_count = @divTrunc(view_row_count, 2);

    const new_viewport_y = blk: {
        if (cursor_pos.y <= half_row_count) break :blk 0;
        break :blk cursor_pos.y - half_row_count;
    };

    if (self.viewport_pos.y == new_viewport_y) return false;
    self.viewport_pos.y = new_viewport_y;
    return true;
}

pub fn @"page-up"(self: *View) bool {
    if (self.viewport_pos.y == 0) {
        std.log.info("page-up: already at top", .{});
        return false;
    }

    const view_row_count = hook.getViewRowCount();
    const page_line_count = switch (view_row_count) {
        0...3 => 1,
        else => view_row_count - 2,
    };

    const new_viewport_y = if (self.viewport_pos.y > page_line_count)
        self.viewport_pos.y - page_line_count
    else
        0;

    self.viewport_pos.y = new_viewport_y;

    if (self.cursor_pos) |*cursor_pos| {
        const viewport_bottom = self.viewport_pos.y + view_row_count;
        if (cursor_pos.y >= viewport_bottom) {
            cursor_pos.y = viewport_bottom -| 1;
            if (cursor_pos.y >= self.rows.items.len and self.rows.items.len > 0) {
                cursor_pos.y = @intCast(self.rows.items.len - 1);
            }
        }
    }

    return true;
}

pub fn @"page-down"(self: *View) bool {
    const view_row_count = hook.getViewRowCount();
    const page_line_count = switch (view_row_count) {
        0...3 => 1,
        else => view_row_count - 2,
    };
    const max_viewport_top = if (self.rows.items.len >= view_row_count) self.rows.items.len - view_row_count else 0;
    if (self.viewport_pos.y == max_viewport_top) {
        std.log.info("page-down: already at end", .{});
        return false;
    }
    if (self.viewport_pos.y > max_viewport_top) {
        std.log.warn("page-down: viewport top {} is > max {}", .{ self.viewport_pos.y, max_viewport_top });
        self.viewport_pos.y = @intCast(max_viewport_top);
        // TODO: update cursor pos?
        return true;
    }

    const new_candidate_viewport_top = self.viewport_pos.y + page_line_count;
    self.viewport_pos.y = @intCast(@min(new_candidate_viewport_top, max_viewport_top));
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.y < self.viewport_pos.y) {
            cursor_pos.* = self.viewport_pos;
        }
    }
    return true;
}

pub const DeleteOption = enum { from_backspace, not_from_backspace };
pub fn delete(self: *View, opt: DeleteOption) error{OutOfMemory}!bool {
    if (self.cursor_pos) |*cursor_pos| {
        if (cursor_pos.y >= self.rows.items.len)
            return false;
        const row = &self.rows.items[cursor_pos.y];
        const row_len = row.getLen();
        if (cursor_pos.x >= row_len) switch (opt) {
            .from_backspace => return false,
            .not_from_backspace => std.log.err("TODO: implement delete at end of line", .{}),
        } else switch (row.*) {
            .file_backed => |fb| {
                const str = self.file.?.map.mem[fb.offset..fb.limit];
                row.* = .{ .array_list_backed = .{} };
                const al = &row.array_list_backed;
                try al.ensureTotalCapacity(self.arena(), str.len - 1);
                al.items.len = str.len - 1;
                @memcpy(
                    al.items[0..cursor_pos.x],
                    str[0..cursor_pos.x],
                );
                @memcpy(
                    al.items[cursor_pos.x..],
                    str[cursor_pos.x + 1 ..],
                );
                return true;
            },
            .array_list_backed => |*al| {
                arrayListUnmanagedCut(u8, al, cursor_pos.x, 1);
                return true;
            },
        }
    }
    return false;
}

pub fn deleteToEndOfLine(self: *View, row_index: usize, line_offset: usize) error{OutOfMemory}!usize {
    if (row_index >= self.rows.items.len)
        return 0;

    const row = &self.rows.items[row_index];
    switch (row.*) {
        .file_backed => |fb| {
            const str = self.file.?.map.mem[fb.offset..fb.limit];
            if (line_offset >= str.len) return 0;
            row.* = .{ .array_list_backed = .{} };
            try row.array_list_backed.appendSlice(self.arena(), str[0..line_offset]);
            return str.len - line_offset;
        },
        .array_list_backed => |*al| {
            if (line_offset >= al.items.len) return 0;
            const remove_len = al.items.len - line_offset;
            al.items.len = line_offset;
            return remove_len;
        },
    }
}

pub fn @"kill-line"(self: *View) bool {
    const cursor_pos = self.cursor_pos orelse return false;
    if (cursor_pos.x == 0) {
        if (cursor_pos.y >= self.rows.items.len) return false;

        const row = &self.rows.items[cursor_pos.y];
        if (cursor_pos.y + 1 == self.rows.items.len) {
            if (row.getLen() == 0) {
                std.log.info("cannot kill last empty line", .{});
                return false;
            }
        }

        if (row.getLen() == 0) {
            switch (row.*) {
                .file_backed => {},
                .array_list_backed => |*al| al.deinit(self.arena()),
            }
            _ = self.rows.orderedRemove(cursor_pos.y);
            return true;
        }

        var err: Error = undefined;
        hook.clipboardSetFmt(&err, "{s}\n", .{row.getSlice(self.file)}) catch {
            // TODO: how should we handle this
            std.log.err("set clipboard failed because {}", .{err});
            return false;
        };
        switch (row.*) {
            .file_backed => row.* = .{ .array_list_backed = .{} },
            .array_list_backed => |*al| al.clearRetainingCapacity(),
        }
        return true;
    } else {
        std.log.err("TODO: implement kill-line for a partial line", .{});
        return false;
    }
}

fn findString(self: *View, string: []const u8, start: XY(u32), end: XY(u32)) ?XY(u32) {
    if (end.x != 0) @panic("todo");
    const start_row = blk: {
        if (start.x != 0) @panic("todo");
        break :blk start.y;
    };
    for (start_row..end.y) |row_index| {
        const slice = self.rows.items[row_index].getSlice(self.file);
        if (std.mem.indexOf(u8, slice, string)) |col| return .{ .x = @intCast(col), .y = @intCast(row_index) };
    }
    return null;
}

pub fn findStringFromCursor(self: *View, string: []const u8) ?XY(u32) {
    const cursor_pos = self.cursor_pos orelse return self.findString(
        string,
        .{ .x = 0, .y = 0 },
        .{ .x = std.math.maxInt(u32), .y = @intCast(self.rows.items.len) },
    );

    if (self.findString(
        string,
        .{ .x = cursor_pos.x, .y = cursor_pos.y },
        .{ .x = std.math.maxInt(u32), .y = @intCast(self.rows.items.len) },
    )) |match| return match;

    if (cursor_pos.y > 0 or cursor_pos.y > 0) return self.findString(
        string,
        .{ .x = 0, .y = 0 },
        .{ .x = cursor_pos.x, .y = cursor_pos.y },
    );
    return null;
}

pub fn hasChanges(self: *View, normalized: *bool) bool {
    const file = self.file orelse return true;

    var next_row_offset: usize = 0;
    for (self.rows.items, 0..) |row, row_index| {
        switch (row) {
            .file_backed => |fb| {
                if (fb.limit == file.map.mem.len) {
                    next_row_offset = std.math.maxInt(usize);
                } else {
                    std.debug.assert(file.map.mem[fb.limit] == '\n');
                    next_row_offset = fb.limit + 1;
                }
            },
            .array_list_backed => |al| {
                const fb_mem_remaining = file.map.mem[next_row_offset..];
                if (al.items.len > fb_mem_remaining.len)
                    return true;
                if (al.items.len < fb_mem_remaining.len) {
                    if (fb_mem_remaining[al.items.len] != '\n')
                        return true;
                }
                const fb_mem = fb_mem_remaining[0..al.items.len];
                if (std.mem.eql(u8, fb_mem, al.items)) {
                    std.log.info("REVERTING ArrayListBacked to FileBacked '{s}'", .{fb_mem});
                    normalized.* = true;
                    self.rows.items[row_index] = .{
                        .file_backed = .{
                            .offset = next_row_offset,
                            .limit = next_row_offset + fb_mem.len,
                        },
                    };
                    continue;
                }
                return true;
            },
        }
    }
    return false;
}

pub fn writeContents(self: View, writer: anytype) !void {
    for (self.rows.items) |row| {
        switch (row) {
            .file_backed => |fb| try writer.writeAll(self.file.?.map.mem[fb.offset..fb.limit]),
            .array_list_backed => |al| try writer.writeAll(al.items),
        }
        try writer.writeAll("\n");
    }
}

fn arrayListUnmanagedCut(
    comptime T: type,
    al: *std.ArrayListUnmanaged(T),
    pos: usize,
    amount: usize,
) void {
    const from = pos + amount;
    std.log.info("al cut len={} pos={} amount={} from={}", .{ al.items.len, pos, amount, from });
    std.debug.assert(from <= al.items.len);
    const dst = al.items[pos .. al.items.len - amount];
    std.mem.copyForwards(T, dst, al.items[from..]);
    al.items.len -= amount;
}
