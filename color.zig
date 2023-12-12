pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const bg_void    = Rgb{ .r = 0x19, .g = 0x19, .b = 0x19 };
pub const bg_content = Rgb{ .r = 0x24, .g = 0x24, .b = 0x24 };
pub const bg_status  = Rgb{ .r = 0x24, .g = 0x24, .b = 0x44 };
pub const fg         = Rgb{ .r = 0xBA, .g = 0xB6, .b = 0xC0 };
pub const fg_status  = Rgb{ .r = 0xBA, .g = 0xB6, .b = 0xD0 };
pub const cursor     = Rgb{ .r = 0x41, .g = 0x40, .b = 0x42 };

pub const bg_menu = Rgb{ .r = 0x36, .g = 0x35, .b = 0x37 };
pub const err     = Rgb{ .r = 0xFc, .g = 0x61, .b = 0x8D };
