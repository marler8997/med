// The complete interface between the current platform and the editor engine.
const builtin = @import("builtin");
const std = @import("std");
const Input = @import("Input.zig");
const MappedFile = @import("MappedFile.zig");
const OnErr = @import("OnErr.zig");
const platform = @import("platform.zig");
const RefString = @import("RefString.zig");
const oom = platform.oom;
const XY = @import("xy.zig").XY;

const Gpa = std.heap.GeneralPurposeAllocator(.{});

const CurrentFile = struct {
    map: MappedFile,
    name: RefString,
    pub fn deinit(self: CurrentFile) void {
        self.map.unmap();
        self.name.unref();
    }
};

const global = struct {
    var gpa_instance = Gpa{ };
    pub var gpa = gpa_instance.allocator();

    pub var row_allocator_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    pub const row_allocator = row_allocator_instance.allocator();

    pub var input: Input = .{};
    pub var current_file: ?CurrentFile = null;
};




// ================================================================================
// The interface for the platform to use
// ================================================================================
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
    pub fn getSlice(self: Row) []u8 {
        return switch (self) {
            .file_backed => |r| global.current_file.?.map.mem[r.offset..r.limit],
            .array_list_backed => |al| al.items,
        };
    }
    pub fn getViewport(self: Row, render: Render) []u8 {
        const slice = switch (self) {
            .file_backed => |r| global.current_file.?.map.mem[r.offset..r.limit],
            .array_list_backed => |al| al.items,
        };
        if (render.viewport_pos.x >= slice.len) return &[0]u8{ };
        const avail = slice.len - render.viewport_pos.x;
        return slice[render.viewport_pos.x ..][0 .. @min(avail, render.viewport_size.x)];
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
    viewport_pos: XY(u32) = .{ .x = 0, .y = 0 },
    viewport_size: XY(u16) = .{ .x = 80, .y = 40 },
    rows: std.ArrayListUnmanaged(Row) = .{},
    open_file_prompt: ?OpenFilePrompt = null,

    err_msg: ?RefString = null,

    pub fn getViewportRows(self: Render) []Row {
        if (self.viewport_pos.y >= self.rows.items.len) return &[0]Row{ };
        const avail = self.rows.items.len - self.viewport_pos.y;
        return self.rows.items[self.viewport_pos.y ..][0 .. @min(avail, self.viewport_size.y)];
    }
    pub fn toViewportPos(self: Render, pos: XY(u16)) ?XY(u16) {
        if (pos.x < self.viewport_pos.x) return null;
        if (pos.y < self.viewport_pos.y) return null;
        if (pos.x >= self.viewport_pos.x + self.viewport_size.x) return null;
        if (pos.y >= self.viewport_pos.y + self.viewport_size.y) return null;
        return .{
            .x = @intCast(pos.x - self.viewport_pos.x),
            .y = @intCast(pos.y - self.viewport_pos.y),
        };
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

var to_global_err_instance = struct {
    base: OnErr = .{ .on_err = on_err },
    fn on_err(context: *OnErr, msg: RefString) void {
        _ = context;
        if (global_render.err_msg) |m| {
            m.unref();
            global_render.err_msg = null;
        }
        global_render.err_msg = msg;
        msg.addRef();
    }
}{ };
const to_global_err = &to_global_err_instance.base;

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
                if (cursor_pos.y >= global_render.rows.items.len) {
                    const needed_len = cursor_pos.y + 1;
                    if (global_render.rows.items.len < needed_len) {
                        std.log.info("adding {} row(s)", .{needed_len - global_render.rows.items.len});
                        global_render.rows.ensureTotalCapacity(global.row_allocator, needed_len) catch |e| oom(e);
                        const old_len = global_render.rows.items.len;
                        global_render.rows.items.len = needed_len;
                        for (global_render.rows.items[old_len .. needed_len]) |*row| {
                            row.* = .{ .array_list_backed = .{} };
                        }
                    }
                }

                const row = &global_render.rows.items[cursor_pos.y];
                const al: *std.ArrayListUnmanaged(u8) = blk: {
                    switch (row.*) {
                        .file_backed => |fb| {
                            const str = global.current_file.?.map.mem[fb.offset..fb.limit];
                            row.* = .{ .array_list_backed = .{} };
                            row.array_list_backed.appendSlice(global.row_allocator, str) catch |e| oom(e);
                            break :blk &row.array_list_backed;
                        },
                        .array_list_backed => |*al| break :blk al,
                    }
                };

                if (al.items.len > cursor_pos.x) {
                    arrayListUnmanagedShiftRight(global.row_allocator, u8, al, cursor_pos.x, 1);
                }
                if (cursor_pos.x >= al.items.len) {
                    const needed_len = cursor_pos.x + 1;
                    al.ensureTotalCapacity(global.row_allocator, needed_len) catch |e| oom(e);
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
            if (global_render.err_msg) |*err_msg| {
                err_msg.unref();
                global_render.err_msg = null;
                platform.errModified();
                return;
            }
            if (global_render.open_file_prompt) |*prompt| {
                openFile(prompt.getPathConst()) catch |e| switch (e) {
                    error.Reported => {},
                };
                global_render.open_file_prompt = null;
                platform.renderModified();
                return;
            }
            if (global_render.cursor_pos) |*cursor_pos| {
                const new_row_index = cursor_pos.y + 1;
                insertRow(new_row_index);

                // copy contents from current row to new row
                const copied = blk: {
                    // NOTE: current_row becomes invalid once rows at cursor_pos.y is modified
                    const current_row = global_render.rows.items[cursor_pos.y].getSlice();
                    if (cursor_pos.x >= current_row.len)
                        break :blk 0;

                    const src = current_row[cursor_pos.x..];
                    // we know the new row we just added MUST already be array_list_backed
                    global_render.rows.items[new_row_index].array_list_backed.appendSlice(
                        global.row_allocator,
                        src,
                    ) catch |e| oom(e);
                    break :blk src.len;
                };

                const deleted = deleteToEndOfLine(cursor_pos.y, cursor_pos.x);
                if (copied != deleted)
                    std.debug.panic("copied {} but deleted {}?", .{copied, deleted});

                global_render.cursor_pos = .{
                    .x = 0, // TODO: should we try to autodetect tabbing here?
                    .y = cursor_pos.y + 1,
                };
                platform.renderModified();
                return;
            }
            std.log.warn("TODO: handle enter with no cursor?", .{});
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

// TODO: use a different error reporting mechanism
// can set error but does not call renderModified
fn openFile(filename_borrowed: []const u8) error{Reported}!void {
    const mapped_file = try MappedFile.init(filename_borrowed, to_global_err, .{});
    errdefer mapped_file.deinit;

    var filename = RefString.allocDupe(filename_borrowed) catch |e| oom(e);
    defer filename.unref();

    // initialize the view
    global.row_allocator_instance.deinit();
    global.row_allocator_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    global_render.rows = .{};

    {
        var line_it = std.mem.split(u8, mapped_file.mem, "\n");
        while (line_it.next()) |line| {
            const offset = @intFromPtr(line.ptr) - @intFromPtr(mapped_file.mem.ptr);
            global_render.rows.append(global.row_allocator, .{ .file_backed = .{
                .offset = offset,
                .limit = offset + line.len,
            }}) catch |e| oom(e);
        }
    }

    if (global.current_file) |current_file| current_file.deinit();
    global.current_file = .{
        .map = mapped_file,
        .name = filename,
    };
}

// after calling, guarantees that global_render.rows[row_index] is
// an empty array_list_backed row.
fn insertRow(row_index: usize) void {
    std.log.info("insertRow at index {} (current_len={})", .{
        row_index,
        global_render.rows.items.len,
    });

    if (row_index >= global_render.rows.items.len) {
        while (true) {
            std.log.info("  insertRow: add blank row at index {}", .{global_render.rows.items.len});
            global_render.rows.append(global.row_allocator, .{ .array_list_backed = .{ } }) catch |e| oom(e);
            if (global_render.rows.items.len > row_index)
                return;
        }
    }

    std.log.info("  insertRow: shifting!", .{});
    arrayListUnmanagedShiftRight(
        global.row_allocator,
        Row,
        &global_render.rows,
        row_index,
        1,
    );
    global_render.rows.items[row_index] = .{ .array_list_backed = .{ } };
}

fn deleteToEndOfLine(row_index: usize, line_offset: usize) usize {
    if (row_index >= global_render.rows.items.len)
        return 0;

    const row = &global_render.rows.items[row_index];
    switch (row.*) {
        .file_backed => |fb| {
            const str = global.current_file.?.map.mem[fb.offset..fb.limit];
            if (line_offset >= str.len) return 0;
            row.* = .{ .array_list_backed = .{} };
            row.array_list_backed.appendSlice(global.row_allocator, str[0 .. line_offset]) catch |e| oom(e);
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

fn arrayListUnmanagedShiftRight(
    allocator: std.mem.Allocator,
    comptime T: type,
    al: *std.ArrayListUnmanaged(T),
    start: usize,
    amount: usize,
) void {
    al.ensureUnusedCapacity(allocator, amount) catch |e| oom(e);
    const old_len = al.items.len;
    al.items.len += amount;
    std.mem.copyBackwards(T, al.items[start + amount..], al.items[start .. old_len]);
}
