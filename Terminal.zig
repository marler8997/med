const Terminal = @This();

const std = @import("std");

arena_instance: std.heap.ArenaAllocator,
pages: std.DoublyLinkedList(Page) = .{},

command: std.ArrayListUnmanaged(u8) = .{},
command_cursor_pos: usize = 0,

const Page = union {
    raw: [std.mem.page_size]u8,
};

pub fn init() Terminal {
    return .{
        .arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
}

pub fn deinit(self: *Terminal) void {
    self.arena_instance.deinit();
    self.* = undefined;
}

pub fn addInput(self: *Terminal, input: []const u8) void {
    self.command.insertSlice(self.command_cursor_pos, input);
    self.command_cursor_pos += input.len;
}

pub fn submitInput(self: *Terminal) void {
    if (self.command.items.len > 0) {
        std.log.err("TODO: submit input to terminal: '{s}'", .{self.command.items});
        self.command.clearRetainingCapacity();
        self.command_cursor_pos = 0;
    }
}
pub fn @"cursor-back"(self: *Terminal) bool {
    if (self.command_cursor_pos > 0) {
        // TODO: move backward a full utf8 grapheme/codepoint whatever
        self.command_cursor_pos -= 1;
        return true;
    }
    return false;
}
pub fn @"cursor-forward"(self: *Terminal) bool {
    if (self.command_cursor_pos < self.command.items.len) {
        // TODO: move forward a full utf8 grapheme/codepoint whatever
        self.command_cursor_pos += 1;
        return true;
    }
    return false;
}
pub fn @"cursor-line-start"(self: *Terminal) bool {
    if (self.command_cursor_pos > 0) {
        self.command_cursor_pos = 0;
        return true;
    }
    return false;
}
pub fn @"cursor-line-end"(self: *Terminal) bool {
    if (self.command_cursor_pos != self.command.items.len) {
        self.command_cursor_pos = self.command.items.len;
        return true;
    }
    return false;
}

pub fn tab(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal tab", .{});
    return false;
}
pub fn delete(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal delete", .{});
    return false;
}
pub fn backspace(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal backspace", .{});
    return false;
}
pub fn @"kill-line"(self: *Terminal) bool {
    _ = self;
    std.log.err("TODO: implement terminal kill-line", .{});
    return false;
}
