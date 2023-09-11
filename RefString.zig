const RefString = @This();

const std = @import("std");
const refstring = std.log.scoped(.refstring);

const Gpa = std.heap.GeneralPurposeAllocator(.{});
// NOTE: this is fine since we're single threaded
var global_gpa_instance = Gpa{ };
const global_gpa = global_gpa_instance.allocator();

const Metadata = struct {
    refcount: usize,
};
const alloc_prefix_len = std.mem.alignForward(usize, @sizeOf(Metadata), @alignOf(Metadata));

slice: []u8,

pub fn alloc(len: usize) error{OutOfMemory}!RefString {
    const alloc_len = alloc_prefix_len + len;
    const full = try global_gpa.alignedAlloc(u8, @alignOf(RefString.Metadata), alloc_len);
    const str = RefString{
        .slice = (full.ptr + alloc_prefix_len)[0 .. len],
    };
    {
        const roundtrip = str.getAllocatorSlice();
        std.debug.assert(full.ptr == roundtrip.ptr);
        std.debug.assert(full.len == roundtrip.len);
    }
    str.getMetadataRef().refcount = 1;
    refstring.debug("alloc {} return {*}", .{len, str.slice});
    return str;
}

pub fn allocDupe(s: []const u8) error{OutOfMemory}!RefString {
    const rs = try alloc(s.len);
    @memcpy(rs.slice, s);
    return rs;
}

pub fn allocFmt(
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!RefString {
    const str = try alloc(
        std.math.cast(usize, std.fmt.count(fmt, args)) orelse return error.OutOfMemory
    );
    const result = std.fmt.bufPrint(str.slice, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable, // we just counted the size above
    };
    std.debug.assert(result.ptr == str.slice.ptr);
    std.debug.assert(result.len == str.slice.len);
    return str;
}

fn getMetadataRef(self: RefString) *Metadata {
    return @ptrFromInt(
        @intFromPtr(self.slice.ptr) - alloc_prefix_len
    );
}
fn getAllocatorSlice(self: RefString) []u8 {
    const ptr: [*]u8 = @ptrFromInt(
        @intFromPtr(self.slice.ptr) - alloc_prefix_len
    );
    return ptr[0 .. alloc_prefix_len + self.slice.len];
}

pub fn addRef(self: RefString) void {
    const metadata = self.getMetadataRef();
    metadata.refcount += 1;
    refstring.debug("addRef {*} new_count={}", .{self.slice, metadata.refcount});
}

pub fn unref(self: RefString) void {
    const metadata = self.getMetadataRef();
    // NOTE: no need for atomics, we are single threaded
    std.debug.assert(metadata.refcount != 0);
    metadata.refcount -= 1;
    if (metadata.refcount == 0) {
        refstring.debug("unref {*} free", .{self.slice});
        global_gpa.rawFree(
            self.getAllocatorSlice(),
            std.math.log2(@alignOf(Metadata)),
            @returnAddress(),
        );
    } else {
        refstring.debug("unref {*} new_count={}", .{self.slice, metadata.refcount});
    }
}
