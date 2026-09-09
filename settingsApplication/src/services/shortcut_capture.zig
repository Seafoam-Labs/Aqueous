pub extern fn aq_shortcut_begin(display: ?*anyopaque, surface: ?*anyopaque, seat: ?*anyopaque) c_int;
pub extern fn aq_shortcut_end() void;
pub extern fn aq_shortcut_take(sym: *u32, mods: *u32) c_int;
