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
    const available = capacity - self.len;
    std.debug.assert(self.mmu.items.len > 0);
    return self.mmu.items[self.mmu.items.len - 1][0..available];
}

pub fn finishRead(self: *PagedBuf, len: usize) void {
    std.debug.assert(len <= (self.getReadBuf() catch unreachable).len);
    self.len += len;
}
