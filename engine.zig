// The complete interface between the current platform and the editor engine.
const builtin = @import("builtin");
const std = @import("std");
const Input = @import("Input.zig");
const MappedFile = @import("MappedFile.zig");
const OnErr = @import("OnErr.zig");
const platform = @import("platform.zig");
const RefString = @import("RefString.zig");
const oom = platform.oom;
const View = @import("View.zig");
const XY = @import("xy.zig").XY;

const Gpa = std.heap.GeneralPurposeAllocator(.{});

const global = struct {
    var gpa_instance = Gpa{ };
    pub var gpa = gpa_instance.allocator();

    pub var input: Input = .{};
};


// ================================================================================
// The interface for the platform to use
// ================================================================================
pub var global_view = View.init();
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
        if (global_view.err_msg) |m| {
            m.unref();
            global_view.err_msg = null;
        }
        global_view.err_msg = msg;
        msg.addRef();
    }
}{ };
const to_global_err = &to_global_err_instance.base;

fn handleAction(action: Input.Action) void {
    switch (action) {
        .add_char => |ascii_code| {
            if (global_view.open_file_prompt) |*prompt| {
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

            if (global_view.cursor_pos) |*cursor_pos| {
                if (cursor_pos.y >= global_view.rows.items.len) {
                    const needed_len = cursor_pos.y + 1;
                    if (global_view.rows.items.len < needed_len) {
                        std.log.info("adding {} row(s)", .{needed_len - global_view.rows.items.len});
                        global_view.rows.ensureTotalCapacity(global_view.arena(), needed_len) catch |e| oom(e);
                        const old_len = global_view.rows.items.len;
                        global_view.rows.items.len = needed_len;
                        for (global_view.rows.items[old_len .. needed_len]) |*row| {
                            row.* = .{ .array_list_backed = .{} };
                        }
                    }
                }

                const row = &global_view.rows.items[cursor_pos.y];
                const al: *std.ArrayListUnmanaged(u8) = blk: {
                    switch (row.*) {
                        .file_backed => |fb| {
                            const str = global_view.file.?.map.mem[fb.offset..fb.limit];
                            row.* = .{ .array_list_backed = .{} };
                            row.array_list_backed.appendSlice(global_view.arena(), str) catch |e| oom(e);
                            break :blk &row.array_list_backed;
                        },
                        .array_list_backed => |*al| break :blk al,
                    }
                };

                if (al.items.len > cursor_pos.x) {
                    arrayListUnmanagedShiftRight(global_view.arena(), u8, al, cursor_pos.x, 1);
                }
                if (cursor_pos.x >= al.items.len) {
                    const needed_len = cursor_pos.x + 1;
                    al.ensureTotalCapacity(global_view.arena(), needed_len) catch |e| oom(e);
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
            if (global_view.err_msg) |*err_msg| {
                err_msg.unref();
                global_view.err_msg = null;
                platform.errModified();
                return;
            }
            if (global_view.open_file_prompt) |*prompt| {
                openFile(prompt.getPathConst()) catch |e| switch (e) {
                    error.Reported => {},
                };
                global_view.open_file_prompt = null;
                platform.renderModified();
                return;
            }
            if (global_view.cursor_pos) |*cursor_pos| {
                const new_row_index = cursor_pos.y + 1;
                insertRow(new_row_index);

                // copy contents from current row to new row
                const copied = blk: {
                    // NOTE: current_row becomes invalid once rows at cursor_pos.y is modified
                    const current_row = global_view.getRowSlice(cursor_pos.y);
                    if (cursor_pos.x >= current_row.len)
                        break :blk 0;

                    const src = current_row[cursor_pos.x..];
                    // we know the new row we just added MUST already be array_list_backed
                    global_view.rows.items[new_row_index].array_list_backed.appendSlice(
                        global_view.arena(),
                        src,
                    ) catch |e| oom(e);
                    break :blk src.len;
                };

                const deleted = global_view.deleteToEndOfLine(cursor_pos.y, cursor_pos.x) catch |e| oom(e);
                if (copied != deleted)
                    std.debug.panic("copied {} but deleted {}?", .{copied, deleted});

                global_view.cursor_pos = .{
                    .x = 0, // TODO: should we try to autodetect tabbing here?
                    .y = cursor_pos.y + 1,
                };
                platform.renderModified();
                return;
            }
            std.log.warn("TODO: handle enter with no cursor?", .{});
        },
        .cursor_back => {
            if (global_view.cursor_pos) |*cursor_pos| {
                if (cursor_pos.x == 0) {
                    std.log.info("TODO: implement cursor back wrap", .{});
                } else {
                    cursor_pos.x -= 1;
                    platform.renderModified();
                }
            }
        },
        .cursor_forward => {
            if (global_view.cursor_pos) |*cursor_pos| {
                cursor_pos.x += 1;
                platform.renderModified();
            }
        },
        .cursor_up => {
            if (global_view.cursor_pos) |*cursor_pos| {
                if (cursor_pos.y == 0) {
                    std.log.info("TODO: implement cursor up scroll", .{});
                } else {
                    cursor_pos.y -= 1;
                    platform.renderModified();
                }
            }
        },
        .cursor_down => {
            if (global_view.cursor_pos) |*cursor_pos| {
                cursor_pos.y += 1;
                platform.renderModified();
            }
        },
        .cursor_line_start => {
            if (global_view.cursor_pos) |*cursor_pos| {
                if (cursor_pos.x != 0) {
                    cursor_pos.x = 0;
                    platform.renderModified();
                }
            }
        },
        .cursor_line_end => std.log.info("TODO: implement cursor_line_end", .{}),
        .open_file => {
            if (global_view.open_file_prompt == null) {
                global_view.open_file_prompt = .{ .path_len = 0 };
                const prompt = &global_view.open_file_prompt.?;
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
    global_view.deinit();
    global_view = View.init();

    {
        var line_it = std.mem.split(u8, mapped_file.mem, "\n");
        while (line_it.next()) |line| {
            const offset = @intFromPtr(line.ptr) - @intFromPtr(mapped_file.mem.ptr);
            global_view.rows.append(global_view.arena(), .{ .file_backed = .{
                .offset = offset,
                .limit = offset + line.len,
            }}) catch |e| oom(e);
        }
    }

    if (global_view.file) |file| file.close();
    global_view.file = View.OpenFile.initAndNameAddRef(mapped_file, filename);
}

// after calling, guarantees that global_view.rows[row_index] is
// an empty array_list_backed row.
fn insertRow(row_index: usize) void {
    std.log.info("insertRow at index {} (current_len={})", .{
        row_index,
        global_view.rows.items.len,
    });

    if (row_index >= global_view.rows.items.len) {
        while (true) {
            std.log.info("  insertRow: add blank row at index {}", .{global_view.rows.items.len});
            global_view.rows.append(global_view.arena(), .{ .array_list_backed = .{ } }) catch |e| oom(e);
            if (global_view.rows.items.len > row_index)
                return;
        }
    }

    std.log.info("  insertRow: shifting!", .{});
    arrayListUnmanagedShiftRight(
        global_view.arena(),
        View.Row,
        &global_view.rows,
        row_index,
        1,
    );
    global_view.rows.items[row_index] = .{ .array_list_backed = .{ } };
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
