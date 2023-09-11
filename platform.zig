const builtin = @import("builtin");
const impl = if (builtin.os.tag == .windows)
    @import("win32.zig")
else
    @import("x11.zig")
;

pub const oom = impl.oom;
pub const go = impl.go;

// ================================================================================
// The interface for the engine to use
// ================================================================================
pub const quit = impl.quit;
pub const errModified = impl.errModified;
pub const renderModified = impl.renderModified;
// ================================================================================
// End of the interface for the engine to use
// ================================================================================
