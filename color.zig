// zig fmt: off
pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const bg_void    = Rgb{ .r = 0x19, .g = 0x19, .b = 0x19 };
pub const bg_content = Rgb{ .r = 0x24, .g = 0x24, .b = 0x24 };
pub const bg_status  = Rgb{ .r = 0x24, .g = 0x24, .b = 0x44 };
pub const fg         = Rgb{ .r = 0xba, .g = 0xb6, .b = 0xc0 };
pub const fg_status  = Rgb{ .r = 0xba, .g = 0xb6, .b = 0xd0 };
pub const cursor     = Rgb{ .r = 0x41, .g = 0x40, .b = 0x42 };

pub const bg_menu    = Rgb{ .r = 0x36, .g = 0x35, .b = 0x37 };
pub const err        = Rgb{ .r = 0xfc, .g = 0x61, .b = 0x8d };
// zig fmt: on
