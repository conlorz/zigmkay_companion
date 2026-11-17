//! Generic offline screenshot layout; never alters a saved project or firmware.
const desktop = @import("desktop-core");
pub fn install(model: *desktop.model.Model) !void {
    const previous_layer = model.layer;
    model.layer = 3;
    // Explicit US punctuation actions establish real fixture routes. The
    // ordinary imported QWERTY template does not contain every symbol route.
    for ([_]struct { usize, u8 }{ .{ 0, 52 }, .{ 1, 51 }, .{ 2, 45 }, .{ 3, 38 }, .{ 4, 39 }, .{ 5, 30 } }) |entry| {
        model.select(entry[0], false);
        try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = entry[1] } } });
    }
    model.layer = previous_layer;
    try model.rename("QWERTY fixture");
    model.saved_id = try model.id();
}
