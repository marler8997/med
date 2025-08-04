///! hook: the engine interface back into main
pub const quit = main.quit;
pub const statusModified = main.statusModified;
pub const errModified = main.errModified;
pub const dialogModified = main.dialogModified;
pub const processModified = main.processModified;
pub const viewModified = main.viewModified;
pub const paneModified = main.paneModified;
pub const beep = main.beep;

pub const addHandle = main.addHandle;
pub const removeHandle = main.removeHandle;

const main = @import("main.zig");
