const MappedFile = @This();

const builtin = @import("builtin");
const std = @import("std");
const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.memory;
};
const OnErr = @import("OnErr.zig");

mem: []align(std.mem.page_size) u8,
mapping: if (builtin.os.tag == .windows) win32.HANDLE else void,

pub const Options = struct {
    mode: enum { read_only, read_write } = .read_only,
};
const empty_mem: [0]u8 align(std.mem.page_size) = undefined;

pub fn init(
    filename: []const u8,
    on_err: *OnErr,
    opt: Options,
) error{Reported}!MappedFile {
    var file = std.fs.cwd().openFile(filename, .{}) catch |err|
        return on_err.report("open '{s}' failed, error={s}", .{filename, @errorName(err)});
    defer file.close();
    const file_size = file.getEndPos() catch |err|
        return on_err.report("get file size of '{s}' failed, error={s}", .{filename, @errorName(err)});

    if (builtin.os.tag == .windows) {
        if (file_size == 0) return MappedFile{
            .mem = &empty_mem,
            .mapping = undefined,
        };
        
        const mapping = win32.CreateFileMappingW(
            file.handle,
            null,
            switch (opt.mode) {
                .read_only => win32.PAGE_READONLY,
                .read_write => win32.PAGE_READWRITE,
            },
            @intCast(0xffffffff & (file_size >> 32)),
            @intCast(0xffffffff & (file_size)),
            null,
        ) orelse return on_err.report(
            "CreateFileMapping of '{s}' failed, error={}",
            .{filename, win32.GetLastError()},
        );
        errdefer std.os.windows.CloseHandle(mapping);

        const ptr = win32.MapViewOfFile(
            mapping,
            switch (opt.mode) {
                .read_only => win32.FILE_MAP_READ,
                .read_write => win32.FILE_MAP.initFlags(.{ .READ = 1, .WRITE = 1 }),
            },
            0, 0, 0,
        ) orelse return on_err.report(
            "MapViewOfFile of '{s}' failed, error={}",
            .{filename, win32.GetLastError()},
        );
        errdefer std.debug.assert(0 != win32.UnmapViewOfFile(ptr));

        return .{
            .mapping = mapping,
            .mem = @as([*]align(std.mem.page_size)u8, @alignCast(@ptrCast(ptr)))[0 .. file_size],
        };
    }

    return .{
        .mem = std.os.mmap(
            null,
            file_size,
            switch (opt.mode) {
                .read_only => std.os.PROT.READ,
                .read_write => std.os.PROT.READ | std.os.PROT.WRITE,
            },
            std.os.MAP.PRIVATE,
            file.handle,
            0,
        ) catch |err| return on_err.report(
            "mmap '{s}' failed, error={s}",
            .{filename, @errorName(err)},
        ),
        .mapping = {},
    };    
}
             
pub fn unmap(self: MappedFile) void {
    if (builtin.os.tag == .windows) {
        if (self.mem.len != 0) {
            std.debug.assert(0 != win32.UnmapViewOfFile(self.mem.ptr));
            std.os.windows.CloseHandle(self.mapping);
        }
    } else {
        std.os.munmap(self.mem);
    }
}
