const PagedList = @This();

const std = @import("std");

comptime {
    std.debug.assert(@sizeOf(Page) == std.mem.page_size);
}
const Page = struct {
    const Metadata = struct {
        prev: ?*Page = null,
        next: ?*Page = null,
    };
    pub const data_len = std.mem.page_size - @sizeOf(Metadata);

    metadata: Metadata = .{},
    bytes: [data_len]u8 = undefined,

    pub fn data(self: *Page) *[data_len]u8 {
        return @as([*]u8, @ptrFromInt(@intFromPtr(&self.bytes) + data_len))[0..data_len];
    }
};

len: usize = 0,
last: ?*Page = null,

pub fn deinit(self: *PagedList) void {
    _ = self;
    @panic("todo");
}

pub fn append(
    self: *PagedList,
    allocator: std.mem.Allocator,
    data: []const u8,
) error{OutOfMemory}!void {
    if (data.len == 0) return;

    const last_buffer_consumed = self.len % std.mem.page_size;
    const last_buffer_available = std.mem.page_size - last_buffer_consumed;

    const copy_len = @min(last_buffer_available, data.len);
    {
        const last = blk: {
            if (self.last) |last| break :blk last;
            std.debug.assert(self.len == 0);
            const page = try allocator.create(Page);
            page.* = .{ .metadata = .{ .prev = null, .next = null } };
            self.last = page;
            break :blk page;
        };
        @memcpy(last.data()[0..copy_len], data[0..copy_len]);
        self.len += copy_len;
    }

    const remaining = data.len - copy_len;
    if (remaining > 0) {
        @panic("todo");
    }
}
