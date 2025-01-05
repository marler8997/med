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
    var gpa_instance = Gpa{};
    pub var gpa = gpa_instance.allocator();

    pub var input: Input = .{};
};

// ================================================================================
// The interface for the platform to use
// ================================================================================
pub const global_status = struct {
    pub const max_len = 400;
    var buf: [max_len]u8 = undefined;
    pub var len: std.math.IntFittingRange(0, max_len) = 0;
    pub fn slice() []const u8 {
        return buf[0..len];
    }
};
pub var global_view = View.init();

pub fn notifyKeyDown(press_kind: Input.KeyPressKind, key: Input.Keybind.Node) void {
    if (press_kind == .repeat) {
        // for now, we just ignore all repeat events
        // if we're in the middle of a keybind
        if (global_keybind.len > 0) return;
    }

    if (!global_keybind.add(key)) {
        reportErrorFmt("key bind too long", .{});
        global_keybind.len = 0;
        return;
    }

    switch (Input.evaluateKeybind(&global_keybind)) {
        .unbound => {
            reportInfoFmt("{} (unbound)", .{global_keybind});
            global_keybind.len = 0;
        },
        .modifier => {
            if (global_keybind.last()) |last| {
                if (last.eql(key)) {
                    global_keybind.len -= 1;
                }
            }
        },
        .prefix => {
            reportInfoFmt("{} ...", .{global_keybind});
        },
        .action => |action| {
            reportInfoFmt("{} ({s})", .{ global_keybind, @tagName(action) });
            global_keybind.len = 0;
            handleAction(action);
        },
    }
}
// ================================================================================
// End of the interface for the platform to use
// ================================================================================

var global_keybind: Input.Keybind = .{};

fn MaxBufWriter(comptime max_len: usize) type {
    return struct {
        buf: [max_len]u8 = undefined,
        len: usize = 0,

        const Self = @This();
        pub const Writer = std.io.GenericWriter(*Self, error{Full}, write);
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
        pub fn written(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        fn write(self: *Self, bytes: []const u8) error{Full}!usize {
            const available = max_len - self.len;
            const copy_len = @min(available, bytes.len);
            @memcpy(self.buf[self.len..][0..copy_len], bytes[0..copy_len]);
            self.len += copy_len;
            if (copy_len < bytes.len and copy_len == 0) {
                return error.Full;
            }
            return copy_len;
        }
    };
}

fn reportInfoFmt(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
    var max_buf_writer: MaxBufWriter(global_status.max_len) = .{};
    max_buf_writer.writer().print(fmt, args) catch {
        max_buf_writer.buf[global_status.max_len - 1] = '.';
        max_buf_writer.buf[global_status.max_len - 2] = '.';
        max_buf_writer.buf[global_status.max_len - 3] = '.';
    };
    setGlobalStatus(max_buf_writer.written(), .{});
}
fn reportErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
    var max_buf_writer: MaxBufWriter(global_status.max_len) = .{};
    max_buf_writer.writer().print("error: " ++ fmt, args) catch {
        max_buf_writer.buf[global_status.max_len - 1] = '.';
        max_buf_writer.buf[global_status.max_len - 2] = '.';
        max_buf_writer.buf[global_status.max_len - 3] = '.';
    };
    setGlobalStatus(max_buf_writer.written(), .{});
}

pub fn setGlobalStatus(new_status: []const u8, opt: struct {
    check_if_equal: bool = true,
}) void {
    if (opt.check_if_equal) {
        if (std.mem.eql(u8, global_status.slice(), new_status))
            return;
    }

    if (new_status.len > global_status.max_len) {
        @memcpy(
            global_status.buf[0 .. global_status.max_len - 3],
            new_status[0 .. global_status.max_len - 3],
        );
        @memcpy(global_status.buf[global_status.max_len - 3 ..], "...");
        global_status.len = global_status.max_len;
    } else {
        @memcpy(global_status.buf[0..new_status.len], new_status);
        global_status.len = @intCast(new_status.len);
    }
    platform.statusModified();
}

fn setGlobalError(new_err: RefString) void {
    if (global_view.err_msg) |m| {
        m.unref();
        global_view.err_msg = null;
    }
    global_view.err_msg = new_err;
    new_err.addRef();
    platform.errModified();
}
var to_global_err_instance = struct {
    base: OnErr = .{ .on_err = on_err },
    fn on_err(context: *OnErr, msg: RefString) void {
        _ = context;
        setGlobalError(msg);
    }
}{};
const to_global_err = &to_global_err_instance.base;

fn handleAction(action: Input.Action) void {
    if (global_view.err_msg) |err_msg| {
        switch (action) {
            .add_char => {}, // ignore
            .enter => {
                err_msg.unref();
                global_view.err_msg = null;
                platform.errModified();
            },
            .cursor_back,
            .cursor_forward,
            .cursor_up,
            .cursor_down,
            .cursor_line_start,
            .cursor_line_end,
            => {}, // ignore
            .delete => {}, // ignore
            .backspace => {}, // ignore
            .kill_line => {}, // ignore
            .open_file => {}, // ignore
            .save_file => {}, // ignore
            .quit => platform.quit(),
        }
        return;
    }

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
                platform.viewModified();
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
                        for (global_view.rows.items[old_len..needed_len]) |*row| {
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
                    for (al.items[old_len..needed_len]) |*c| {
                        c.* = ' ';
                    }
                }
                std.log.info("setting row {} col {} to '{c}'", .{ cursor_pos.y, cursor_pos.x, ascii_code });
                al.items[cursor_pos.x] = ascii_code;
                cursor_pos.x += 1;
                platform.viewModified();
            }
        },
        .enter => {
            if (global_view.open_file_prompt) |*prompt| {
                const filename = RefString.allocDupe(prompt.getPathConst()) catch |e| oom(e);
                defer filename.unref();
                openFile(filename) catch |e| switch (e) {
                    error.Reported => {},
                };
                global_view.open_file_prompt = null;
                platform.viewModified();
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
                    std.debug.panic("copied {} but deleted {}?", .{ copied, deleted });

                global_view.cursor_pos = .{
                    .x = 0, // TODO: should we try to autodetect tabbing here?
                    .y = cursor_pos.y + 1,
                };
                platform.viewModified();
                return;
            }
            std.log.warn("TODO: handle enter with no cursor?", .{});
        },
        .cursor_back => {
            if (global_view.open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else if (global_view.cursorBack()) {
                platform.viewModified();
            }
        },
        .cursor_forward => {
            if (global_view.open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else if (global_view.cursorForward()) {
                platform.viewModified();
            }
        },
        .cursor_up => {
            if (global_view.open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else if (global_view.cursorUp()) {
                platform.viewModified();
            }
        },
        .cursor_down => {
            if (global_view.open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else if (global_view.cursorDown()) {
                platform.viewModified();
            }
        },
        .cursor_line_start => {
            if (global_view.open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else if (global_view.cursorLineStart()) {
                platform.viewModified();
            }
        },
        .cursor_line_end => {
            if (global_view.open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else if (global_view.cursorLineEnd()) {
                platform.viewModified();
            }
        },
        .delete => {
            if (global_view.delete(.not_from_backspace) catch |e| oom(e)) {
                platform.viewModified();
            }
        },
        .backspace => {
            if (global_view.open_file_prompt) |_| {
                std.log.info("todo: implement backspace for file prompt", .{});
            } else {
                if (global_view.cursorBack()) {
                    _ = global_view.delete(.from_backspace) catch |e| oom(e);
                    platform.viewModified();
                }
            }
        },
        .kill_line => {
            if (global_view.killLine()) {
                platform.viewModified();
            }
        },
        .open_file => {
            if (global_view.open_file_prompt == null) {
                global_view.open_file_prompt = .{ .path_len = 0 };
                const prompt = &global_view.open_file_prompt.?;
                const path = std.posix.getcwd(&prompt.path_buf) catch |e| std.debug.panic("todo handle '{s}'", .{@errorName(e)});
                if (path.len + 1 >= prompt.path_buf.len) @panic("handle long cwd");
                prompt.path_buf[path.len] = std.fs.path.sep;
                prompt.path_len = path.len + 1;
                platform.viewModified();
            }
        },
        .save_file => saveFile(),
        .quit => platform.quit(),
    }
}

// TODO: use a different error reporting mechanism
// can set error but does not call viewModified
fn openFile(filename: RefString) error{Reported}!void {
    const mapped_file = try MappedFile.init(filename.slice, to_global_err, .{});
    errdefer mapped_file.unmap();

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
            } }) catch |e| oom(e);
        }
    }

    if (global_view.file) |file| file.close();
    global_view.file = View.OpenFile.initAndNameAddRef(mapped_file, filename);
}

fn saveFile() void {
    if (global_view.open_file_prompt != null)
        return;

    {
        var normalized = false;
        const has_changes = global_view.hasChanges(&normalized);
        if (normalized) {
            platform.viewModified();
        }
        if (!has_changes) {
            std.log.info("no changes to save", .{});
            return;
        }
    }

    const file = global_view.file orelse return setGlobalError(RefString.allocDupe(
        "Not Implemented: saveToDisk for a view without a file",
    ) catch |e| oom(e));

    var path_buf: [std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
    const tmp_filename = std.fmt.bufPrint(
        &path_buf,
        "{s}.med-saving",
        .{file.name.slice},
    ) catch |err| switch (err) {
        error.NoSpaceLeft => {
            setGlobalError(RefString.allocDupe("saveToDisk error: file path too long") catch |e| oom(e));
            platform.errModified();
            return;
        },
    };

    if (writeViewToFile(tmp_filename, global_view)) |err| {
        setGlobalError(err);
        platform.errModified();
        return;
    }

    std.fs.cwd().rename(tmp_filename, file.name.slice) catch |err| {
        setGlobalError(RefString.allocFmt("rename tmp file failed with {s}", .{@errorName(err)}) catch |e| oom(e));
        platform.errModified();
        return;
    };

    const save_filename = file.name;
    save_filename.addRef();
    defer save_filename.unref();

    const save_cursor_pos = global_view.cursor_pos;
    const save_viewport_pos = global_view.viewport_pos;

    global_view.deinit();
    global_view = View.init();
    platform.viewModified();

    openFile(save_filename) catch |err| switch (err) {
        error.Reported => return,
    };

    global_view.cursor_pos = save_cursor_pos;
    global_view.viewport_pos = save_viewport_pos;
}

// returns an optional error
fn writeViewToFile(filename: []const u8, view: View) ?RefString {
    var file = std.fs.cwd().createFile(filename, .{}) catch |err| return RefString.allocFmt(
        "createFile '{s}' failed with {s}",
        .{ filename, @errorName(err) },
    ) catch |e| oom(e);
    defer file.close();
    view.writeContents(file.writer()) catch |err| return RefString.allocFmt("write to file '{s}' failed with {s}", .{ filename, @errorName(err) }) catch |e| oom(e);
    return null;
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
            global_view.rows.append(global_view.arena(), .{ .array_list_backed = .{} }) catch |e| oom(e);
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
    global_view.rows.items[row_index] = .{ .array_list_backed = .{} };
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
    std.mem.copyBackwards(T, al.items[start + amount ..], al.items[start..old_len]);
}
