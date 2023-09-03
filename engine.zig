// The complete interface between the current platform and the editor engine.
const std = @import("std");
const Input = @import("Input.zig");
const platform = @import("platform.zig");
const XY = @import("xy.zig").XY;

const global = struct {
    pub var input: Input = .{};
};

// ================================================================================
// The interface for the platform to use
// ================================================================================
pub const Render = struct {
    cursor_pos: XY(u16) = .{ .x = 0, .y = 0 },
    size: XY(u16) = .{ .x = 0, .y = 0 },
    rows: [*][*]u8 = undefined,
};
pub var global_render = Render{ };
pub fn notifyKeyEvent(key: Input.Key, state: Input.KeyState) void {
    if (global.input.setKeyState(key, state)) |action|
        try handleAction(action);
}
// ================================================================================
// End of the interface for the platform to use
// ================================================================================

fn handleAction(action: Input.Action) !void {
    switch (action) {
        .cursor_back => {
            if (global_render.cursor_pos.x == 0) {
                std.log.info("TODO: implement cursor back wrap", .{});
            } else {
                global_render.cursor_pos.x -= 1;
                platform.renderModified();
            }
        },
        .cursor_forward => {
            global_render.cursor_pos.x += 1;
            platform.renderModified();
        },
        .cursor_up => {
            if (global_render.cursor_pos.y == 0) {
                std.log.info("TODO: implement cursor up scroll", .{});
            } else {
                global_render.cursor_pos.y -= 1;
                platform.renderModified();
            }
        },
        .cursor_down => {
            global_render.cursor_pos.y += 1;
            platform.renderModified();
        },
        .cursor_line_start => std.log.info("TODO: implement cursor_line_start", .{}),
        .cursor_line_end => std.log.info("TODO: implement cursor_line_end", .{}),
        .open_file => {
            std.log.info("todo: setup open file UI", .{});
            //platform.renderModified();
        },
        .quit => platform.quit(),
    }
}
