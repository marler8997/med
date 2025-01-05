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

pub const Pane = union(enum) {
    welcome,
    file: View,
    pub fn deinit(self: *Pane) void {
        switch (self.*) {
            .welcome => {},
            .file => |*view| {
                view.deinit();
            },
        }
        self.* = undefined;
    }
};
pub var global_current_pane: Pane = .welcome;
pub var global_err_msg: ?RefString = null;
pub var global_open_file_prompt: ?OpenFilePrompt = null;
pub var global_dialog: ?Dialog = null;

pub const OpenFilePrompt = struct {
    const max_path_len = 2048;
    path_buf: [max_path_len]u8 = undefined,
    path_len: usize,
    pub fn getPathConst(self: *const OpenFilePrompt) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

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

const Dialog = struct {
    pub const Kind = enum {
        //@"kill-pane",
        unsaved_changes_confirm_kill,
        pub fn textPrefix(self: Kind) []const u8 {
            return switch (self) {
                .unsaved_changes_confirm_kill => "file modified; kill anyway? (yes or no) ",
            };
        }
    };
    kind: Kind,
    text_buf: [500]u8,
    text_len: u16,
    pub fn init(kind: Kind) Dialog {
        var result: Dialog = .{
            .kind = kind,
            .text_buf = undefined,
            .text_len = 0,
        };
        result.append(kind.textPrefix());
        return result;
    }
    pub fn getText(self: *const Dialog) []const u8 {
        return self.text_buf[0..self.text_len];
    }
    pub fn getAnswer(self: *const Dialog) []const u8 {
        return self.text_buf[self.kind.textPrefix().len..self.text_len];
    }
    pub fn append(self: *Dialog, text: []const u8) void {
        const available = self.text_buf.len - self.text_len;
        const copy_len = @min(text.len, available);
        @memcpy(self.text_buf[self.text_len..][0..copy_len], text[0..copy_len]);
        self.text_len += @intCast(copy_len);
    }
    fn handleAction(self: *Dialog, action: Input.Action) void {
        switch (action) {
            .add_char => |c| {
                const s = [_]u8{c};
                self.append(&s);
                platform.dialogModified();
            }, // ignore
            .enter => {
                const answer = self.getAnswer();
                switch (self.kind) {
                    .unsaved_changes_confirm_kill => {
                        if (std.mem.eql(u8, answer, "yes")) {
                            @"kill-pane"(.{ .prompt_unsaved_changes = false });
                            global_dialog = null;
                        } else if (std.mem.eql(u8, answer, "no")) {
                            self.* = undefined;
                            global_dialog = null;
                        } else {
                            self.* = init(.unsaved_changes_confirm_kill);
                        }
                        platform.dialogModified();
                    },
                }
            },
            .cursor_back,
            .cursor_forward,
            .cursor_up,
            .cursor_down,
            .cursor_line_start,
            .cursor_line_end,
            => {}, // ignore
            .delete => {}, // ignore
            .tab => {},
            .backspace => {
                if (self.text_len > self.kind.textPrefix().len) {
                    self.text_len -= 1;
                    platform.dialogModified();
                }
            }, // ignore
            .kill_line => {
                std.log.err("TODO: kill line", .{});
            }, // ignore
            .open_file => {}, // ignore
            .save_file => {}, // ignore
            .kill_pane => {}, // ignore
            .quit => platform.quit(),
        }
    }
};
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

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: remove this and instead, just use std.log.err and append each
//       message to a link-list of memory pages where all error log messages
//       are stored
fn setGlobalError(new_err: RefString) void {
    if (global_err_msg) |m| {
        m.unref();
        global_err_msg = null;
    }
    global_err_msg = new_err;
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
    if (global_dialog) |*dialog| {
        dialog.handleAction(action);
        return;
    }

    if (global_err_msg) |err_msg| {
        switch (action) {
            .add_char => {}, // ignore
            .enter => {
                err_msg.unref();
                global_err_msg = null;
                platform.errModified();
            },
            .cursor_back,
            .cursor_forward,
            .cursor_up,
            .cursor_down,
            .cursor_line_start,
            .cursor_line_end,
            => {}, // ignore
            .tab => {}, // ignore
            .delete => {}, // ignore
            .backspace => {}, // ignore
            .kill_line => {}, // ignore
            .open_file => {}, // ignore
            .save_file => {}, // ignore
            .kill_pane => {}, // ignore
            .quit => platform.quit(),
        }
        return;
    }

    switch (action) {
        .add_char => |ascii_code| {
            if (global_open_file_prompt) |*prompt| {
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

            switch (global_current_pane) {
                .welcome => {
                    // TODO: should we just create a file view?
                    platform.beep();
                    reportErrorFmt("no file open", .{});
                },
                .file => |*view| {
                    if (view.cursor_pos) |*cursor_pos| {
                        if (cursor_pos.y >= view.rows.items.len) {
                            const needed_len = cursor_pos.y + 1;
                            if (view.rows.items.len < needed_len) {
                                std.log.info("adding {} row(s)", .{needed_len - view.rows.items.len});
                                view.rows.ensureTotalCapacity(view.arena(), needed_len) catch |e| oom(e);
                                const old_len = view.rows.items.len;
                                view.rows.items.len = needed_len;
                                for (view.rows.items[old_len..needed_len]) |*row| {
                                    row.* = .{ .array_list_backed = .{} };
                                }
                            }
                        }

                        const row = &view.rows.items[cursor_pos.y];
                        const al: *std.ArrayListUnmanaged(u8) = blk: {
                            switch (row.*) {
                                .file_backed => |fb| {
                                    const str = view.file.?.map.mem[fb.offset..fb.limit];
                                    row.* = .{ .array_list_backed = .{} };
                                    row.array_list_backed.appendSlice(view.arena(), str) catch |e| oom(e);
                                    break :blk &row.array_list_backed;
                                },
                                .array_list_backed => |*al| break :blk al,
                            }
                        };

                        if (al.items.len > cursor_pos.x) {
                            arrayListUnmanagedShiftRight(view.arena(), u8, al, cursor_pos.x, 1);
                        }
                        if (cursor_pos.x >= al.items.len) {
                            const needed_len = cursor_pos.x + 1;
                            al.ensureTotalCapacity(view.arena(), needed_len) catch |e| oom(e);
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
            }
        },
        .enter => {
            if (global_open_file_prompt) |*prompt| {
                const filename = RefString.allocDupe(prompt.getPathConst()) catch |e| oom(e);
                defer filename.unref();
                @"open-file"(filename) catch |e| switch (e) {
                    error.Reported => {},
                };
                global_open_file_prompt = null;
                platform.viewModified();
                return;
            }

            switch (global_current_pane) {
                .welcome => {
                    // TODO: should we just create a file view?
                    platform.beep();
                    reportErrorFmt("no file open", .{});
                },
                .file => |*view| {
                    if (view.cursor_pos) |*cursor_pos| {
                        const new_row_index = cursor_pos.y + 1;
                        insertRow(view, new_row_index);

                        // copy contents from current row to new row
                        const copied = blk: {
                            // NOTE: current_row becomes invalid once rows at cursor_pos.y is modified
                            const current_row = view.getRowSlice(cursor_pos.y);
                            if (cursor_pos.x >= current_row.len)
                                break :blk 0;

                            const src = current_row[cursor_pos.x..];
                            // we know the new row we just added MUST already be array_list_backed
                            view.rows.items[new_row_index].array_list_backed.appendSlice(
                                view.arena(),
                                src,
                            ) catch |e| oom(e);
                            break :blk src.len;
                        };

                        const deleted = view.deleteToEndOfLine(cursor_pos.y, cursor_pos.x) catch |e| oom(e);
                        if (copied != deleted)
                            std.debug.panic("copied {} but deleted {}?", .{ copied, deleted });

                        view.cursor_pos = .{
                            .x = 0, // TODO: should we try to autodetect tabbing here?
                            .y = cursor_pos.y + 1,
                        };
                        platform.viewModified();
                        return;
                    }
                    std.log.warn("TODO: handle enter with no cursor?", .{});
                },
            }
        },
        .cursor_back => {
            if (global_open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorBack()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .cursor_forward => {
            if (global_open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorForward()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .cursor_up => {
            if (global_open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorUp()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .cursor_down => {
            if (global_open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorDown()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .cursor_line_start => {
            if (global_open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorLineStart()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .cursor_line_end => {
            if (global_open_file_prompt) |_| {
                // TODO: make the open file prompt it's own view so
                //       we can just reuse it's functions for this
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorLineEnd()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .tab => {
            if (global_open_file_prompt) |_| {
                reportErrorFmt("TODO: tab completion for open file prompt", .{});
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    _ = view;
                    reportErrorFmt("TODO: implement tab", .{});
                },
            }
        },
        .delete => {
            switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.delete(.not_from_backspace) catch |e| oom(e)) {
                        platform.viewModified();
                    }
                },
            }
        },
        .backspace => {
            if (global_open_file_prompt) |_| {
                std.log.info("todo: implement backspace for file prompt", .{});
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.cursorBack()) {
                        _ = view.delete(.from_backspace) catch |e| oom(e);
                        platform.viewModified();
                    }
                },
            }
        },
        .kill_line => {
            if (global_open_file_prompt) |_| {
                @panic("todo: kill-line while opening file");
            } else switch (global_current_pane) {
                .welcome => {},
                .file => |*view| {
                    if (view.killLine()) {
                        platform.viewModified();
                    }
                },
            }
        },
        .open_file => {
            if (global_open_file_prompt == null) {
                global_open_file_prompt = .{ .path_len = 0 };
                const prompt = &global_open_file_prompt.?;
                const path = std.posix.getcwd(&prompt.path_buf) catch |e| std.debug.panic("todo handle '{s}'", .{@errorName(e)});
                if (path.len + 1 >= prompt.path_buf.len) @panic("handle long cwd");
                prompt.path_buf[path.len] = std.fs.path.sep;
                prompt.path_len = path.len + 1;
                platform.viewModified();
            }
        },
        .save_file => saveFile(),
        .kill_pane => @"kill-pane"(.{ .prompt_unsaved_changes = true }),
        .quit => platform.quit(),
    }
}

// TODO: use a different error reporting mechanism
// can set error but does not call viewModified
fn @"open-file"(filename: RefString) error{Reported}!void {
    const mapped_file = try MappedFile.init(filename.slice, to_global_err, .{});
    errdefer mapped_file.unmap();

    // initialize the view
    global_current_pane.deinit();
    global_current_pane = .welcome;

    var view = View.init();

    {
        var line_it = std.mem.split(u8, mapped_file.mem, "\n");
        while (line_it.next()) |line| {
            const offset = @intFromPtr(line.ptr) - @intFromPtr(mapped_file.mem.ptr);
            view.rows.append(view.arena(), .{ .file_backed = .{
                .offset = offset,
                .limit = offset + line.len,
            } }) catch |e| oom(e);
        }
    }

    if (view.file) |file| file.close();
    view.file = View.OpenFile.initAndNameAddRef(mapped_file, filename);
    global_current_pane = Pane{ .file = view };
}

fn saveFile() void {
    if (global_open_file_prompt != null) {
        platform.beep();
        std.log.err("cannot save-file while opening file", .{});
        return;
    }

    const view = switch (global_current_pane) {
        .welcome => {
            platform.beep();
            std.log.err("no file to save", .{});
            return;
        },
        .file => |*view| view,
    };

    {
        var normalized = false;
        const has_changes = view.hasChanges(&normalized);
        if (normalized) {
            platform.viewModified();
        }
        if (!has_changes) {
            std.log.info("no changes to save", .{});
            return;
        }
    }

    const file = view.file orelse return setGlobalError(RefString.allocDupe(
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

    if (writeViewToFile(tmp_filename, view)) |err| {
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

    const save_cursor_pos = view.cursor_pos;
    const save_viewport_pos = view.viewport_pos;

    view.deinit();
    view.* = View.init();
    platform.viewModified();

    @"open-file"(save_filename) catch |err| switch (err) {
        error.Reported => return,
    };

    view.cursor_pos = save_cursor_pos;
    view.viewport_pos = save_viewport_pos;
}

fn @"kill-pane"(opt: struct { prompt_unsaved_changes: bool }) void {
    if (global_open_file_prompt != null) {
        std.log.err("cannot kill-pane while opening file", .{});
        return;
    }

    // TODO: if we want to be like emacs, then we'll first ask the user which
    //       pane they'd like to close, for now we'll just default to closing
    //       the current pane
    //
    // if (global_dialog) |_| {
    //     std.log.err("cannot kill-pane while there is already a dialog", .{});
    //     return;
    // }
    // global_dialog = .{
    //     .kind = .@"kill-pane",
    // };
    // platform.viewModified();

    switch (global_current_pane) {
        .welcome => {
            std.log.err("cannot kill the welcome pane", .{});
            return;
        },
        .file => |*view| {
            if (opt.prompt_unsaved_changes) {
                var normalized = false;
                const has_changes = view.hasChanges(&normalized);
                if (normalized) {
                    platform.viewModified();
                }
                if (has_changes) {
                    if (global_dialog) |_| {
                        std.log.err("cannot kill-pane while there's unsaved changes and a pending dialog", .{});
                        return;
                    }
                    global_dialog = Dialog.init(.unsaved_changes_confirm_kill);
                    platform.viewModified();
                    return;
                }
            }
            global_current_pane.deinit();
            global_current_pane = .welcome;
            platform.viewModified();
        },
    }
}

// returns an optional error
fn writeViewToFile(filename: []const u8, view: *const View) ?RefString {
    var file = std.fs.cwd().createFile(filename, .{}) catch |err| return RefString.allocFmt(
        "createFile '{s}' failed with {s}",
        .{ filename, @errorName(err) },
    ) catch |e| oom(e);
    defer file.close();
    view.writeContents(file.writer()) catch |err| return RefString.allocFmt(
        "write to file '{s}' failed with {s}",
        .{ filename, @errorName(err) },
    ) catch |e| oom(e);
    return null;
}

// after calling, guarantees that view.rows[row_index] is
// an empty array_list_backed row.
fn insertRow(view: *View, row_index: usize) void {
    std.log.info("insertRow at index {} (current_len={})", .{
        row_index,
        view.rows.items.len,
    });

    if (row_index >= view.rows.items.len) {
        while (true) {
            std.log.info("  insertRow: add blank row at index {}", .{view.rows.items.len});
            view.rows.append(view.arena(), .{ .array_list_backed = .{} }) catch |e| oom(e);
            if (view.rows.items.len > row_index)
                return;
        }
    }

    std.log.info("  insertRow: shifting!", .{});
    arrayListUnmanagedShiftRight(
        view.arena(),
        View.Row,
        &view.rows,
        row_index,
        1,
    );
    view.rows.items[row_index] = .{ .array_list_backed = .{} };
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
