const builtin = @import("builtin");
const impl = if (builtin.os.tag == .windows)
    @import("win32.zig")
else
    @import("x11.zig");

pub const panic = impl.panic;
pub const oom = impl.oom;
pub const go = impl.go;

// ================================================================================
// The interface for the engine to use
// ================================================================================
pub const quit = impl.quit;
pub const statusModified = impl.statusModified;
pub const errModified = impl.errModified;
pub const dialogModified = impl.dialogModified;
pub const processModified = impl.processModified;
pub const viewModified = impl.viewModified;
pub const paneModified = impl.paneModified;
pub const beep = impl.beep;

pub const addHandle = impl.addHandle;
pub const removeHandle = impl.removeHandle;
// ================================================================================
// End of the interface for the engine to use
// ================================================================================
