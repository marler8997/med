const std = @import("std");

/// A growable non-continguous group of fixed-width memory pages.
///
/// Access is O(1).
pub fn PagedMem(comptime page_size: usize) type {
    return struct {
        len: usize = 0,
        mmu: std.ArrayListUnmanaged(*[page_size]u8) = .{},

        const Self = @This();
        pub fn deinit(self: *Self) void {
            for (self.mmu.items) |page| {
                std.heap.page_allocator.free(page);
            }
            self.mmu.deinit(std.heap.page_allocator);
        }

        pub fn getCapacity(self: Self) usize {
            return self.mmu.items.len * page_size;
        }

        pub fn getReadBuf(self: *Self) error{OutOfMemory}![]u8 {
            if (page_size != std.mem.page_size) @compileError("cannot call getReadBuf unless page size is std.mem.page_size");

            const capacity = self.getCapacity();
            if (self.len == capacity) {
                const page = try std.heap.page_allocator.alloc(u8, page_size);
                errdefer std.heap.page_allocator.free(page);
                try self.mmu.append(std.heap.page_allocator, @ptrCast(page.ptr));
                std.debug.assert(self.getCapacity() > self.len);
                return page[0..page_size];
            }
            std.debug.assert(self.mmu.items.len > 0);
            return self.mmu.items[self.mmu.items.len - 1][self.len % page_size .. page_size];
        }

        pub fn finishRead(self: *Self, len: usize) void {
            std.debug.assert(len <= (self.getReadBuf() catch unreachable).len);
            self.len += len;
        }

        pub fn getByte(self: *const Self, offset: usize) u8 {
            return self.mmu.items[@divTrunc(offset, page_size)][offset % page_size];
        }

        // returns the index immediately after the given `what` byte of the first
        // occurence searching in reverse
        pub fn scanBackwardsScalar(self: *const Self, limit: usize, what: u8) usize {
            std.debug.assert(limit <= self.len);
            var offset = limit;
            while (offset > 0) {
                const next_offset = offset - 1;
                if (what == self.getByte(next_offset)) return offset;
                offset = next_offset;
            }
            return 0;
        }

        pub fn utf8ToUtf16LeScalar(
            self: *const Self,
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
    };
}
