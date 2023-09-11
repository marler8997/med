const View = @This();

const std = @import("std");
const MappedFile = @import("MappedFile.zig");
const RefString = @import("RefString.zig");
const XY = @import("xy.zig").XY;

arena_instance: std.heap.ArenaAllocator,
file: ?OpenFile = null,
rows: std.ArrayListUnmanaged(Row) = .{},
cursor_pos: ?XY(u16) = .{ .x = 0, .y = 0 },
viewport_pos: XY(u32) = .{ .x = 0, .y = 0 },
viewport_size: XY(u16) = .{ .x = 80, .y = 40 },
open_file_prompt: ?OpenFilePrompt = null,
err_msg: ?RefString = null,

pub fn init() View {
    return .{
        .arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
}
pub fn deinit(self: View) void {
    self.arena_instance.deinit();
}

// TODO: make this private once I move more code into this file
pub fn arena(self: *View) std.mem.Allocator {
    return self.arena_instance.allocator();
}

pub const OpenFile = struct {
    map: MappedFile,
    name: RefString,
    pub fn initAndNameAddRef(map: MappedFile, name: RefString) OpenFile {
        name.addRef();
        return .{
            .map = map,
            .name = name,
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
    pub fn getViewport(self: Row, view: View) []u8 {
        const slice = switch (self) {
            .file_backed => |r| view.file.?.map.mem[r.offset..r.limit],
            .array_list_backed => |al| al.items,
        };
        if (view.viewport_pos.x >= slice.len) return &[0]u8{ };
        const avail = slice.len - view.viewport_pos.x;
        return slice[view.viewport_pos.x ..][0 .. @min(avail, view.viewport_size.x)];
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

pub fn getViewportRows(self: View) []Row {
    if (self.viewport_pos.y >= self.rows.items.len) return &[0]Row{ };
    const avail = self.rows.items.len - self.viewport_pos.y;
    return self.rows.items[self.viewport_pos.y ..][0 .. @min(avail, self.viewport_size.y)];
}
pub fn toViewportPos(self: View, pos: XY(u16)) ?XY(u16) {
    if (pos.x < self.viewport_pos.x) return null;
    if (pos.y < self.viewport_pos.y) return null;
    if (pos.x >= self.viewport_pos.x + self.viewport_size.x) return null;
    if (pos.y >= self.viewport_pos.y + self.viewport_size.y) return null;
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
        return true;
    }
    return false;
}

// returns true if it was able to move the cursor down
pub fn cursorDown(self: *View) bool {
    if (self.cursor_pos) |*cursor_pos| {
        cursor_pos.y += 1;
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

pub fn deleteToEndOfLine(self: *View, row_index: usize, line_offset: usize) error{OutOfMemory}!usize {
    if (row_index >= self.rows.items.len)
        return 0;

    const row = &self.rows.items[row_index];
    switch (row.*) {
        .file_backed => |fb| {
            const str = self.file.?.map.mem[fb.offset..fb.limit];
            if (line_offset >= str.len) return 0;
            row.* = .{ .array_list_backed = .{} };
            try row.array_list_backed.appendSlice(self.arena(), str[0 .. line_offset]);
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
