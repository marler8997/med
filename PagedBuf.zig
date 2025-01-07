const PagedBuf = @This();

const std = @import("std");

len: usize = 0,
mmu: std.ArrayListUnmanaged(*[std.mem.page_size]u8) = .{},

pub fn deinit(self: *PagedBuf) void {
    for (self.mmu.items) |page| {
        std.heap.page_allocator.free(page);
    }
    self.mmu.deinit(std.heap.page_allocator);
}

pub fn getCapacity(self: PagedBuf) usize {
    return self.mmu.items.len * std.mem.page_size;
}

pub fn getReadBuf(self: *PagedBuf) error{OutOfMemory}![]u8 {
    const capacity = self.getCapacity();
    if (self.len == capacity) {
        const page = try std.heap.page_allocator.alloc(u8, std.mem.page_size);
        errdefer std.heap.page_allocator.free(page);
        try self.mmu.append(std.heap.page_allocator, @ptrCast(page.ptr));
        std.debug.assert(self.getCapacity() > self.len);
        return page[0..std.mem.page_size];
    }
    std.debug.assert(self.mmu.items.len > 0);
    return self.mmu.items[self.mmu.items.len - 1][self.len % std.mem.page_size .. std.mem.page_size];
}

pub fn finishRead(self: *PagedBuf, len: usize) void {
    std.debug.assert(len <= (self.getReadBuf() catch unreachable).len);
    self.len += len;
}

pub fn getByte(self: *const PagedBuf, offset: usize) u8 {
    return self.mmu.items[@divTrunc(offset, std.mem.page_size)][offset % std.mem.page_size];
}

// returns the index immediately after the given `what` byte of the first
// occurence searching in reverse
pub fn scanBackwardsScalar(self: *const PagedBuf, limit: usize, what: u8) usize {
    std.debug.assert(limit <= self.len);
    var offset = limit;
    while (offset > 0) {
        const next_offset = offset - 1;
        if (what == self.getByte(next_offset)) return offset;
        offset = next_offset;
    }
    return 0;
}

pub fn utf8ToUtf16Le(
    self: *const PagedBuf,
    offset: usize,
    limit: usize,
) error{ Utf8InvalidStartByte, Truncated }!struct {
    end: usize,
    char: ?u16,
} {
    std.debug.assert(offset < self.len);
    std.debug.assert(limit <= self.len);

    var buf: [7]u8 = undefined;
    buf[0] = self.getByte(offset);
    const sequence_len = try std.unicode.utf8ByteSequenceLength(buf[0]);
    if (offset + sequence_len > limit) return error.Truncated;
    for (1..sequence_len) |i| {
        buf[i] = self.getByte(offset + i);
    }
    var result_buf: [7]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(
        &result_buf,
        buf[0..sequence_len],
    ) catch |err| switch (err) {
        error.InvalidUtf8 => return .{
            .end = offset + sequence_len,
            .char = null,
        },
    };
    std.debug.assert(len == 1);
    return .{
        .end = offset + sequence_len,
        .char = result_buf[0],
    };
}
