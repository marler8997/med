const CmdlineOpt = @This();
const build_options = @import("build_options");
const X11Option = if (build_options.enable_x11_backend) bool else void;

x11: X11Option = if (build_options.enable_x11_backend) false else {},
