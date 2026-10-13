//! Passive, identity-checked layout reference. No buttons or pointer interaction.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");
const ui = @import("editor-ui");
const fonts = @import("editor-fonts");
pub const View = struct { overlay: bool = true, applied_window: ?u32 = null, unavailable: bool = false };
pub const Frame = struct {
    snapshot: [32]u8,
    geometry: []const layout.physical_layout.Key,
    labels: *const desktop.label_cache.LabelCache,
    board_name: []const u8,
    layer: usize,
    modifiers: layout.Modifiers = .{},
    pressed: []const bool,
    practicing: bool = false,
    live: bool = false,
    active_layers: ?u16 = null,
};
pub fn draw(model: *const desktop.model.Model, frame: Frame, light: bool) !void {
    if (!std.mem.eql(u8, &frame.snapshot, &(try model.id()))) return error.StaleKeyboardLabels;
    const doc = model.document();
    if (frame.labels.key_count != doc.key_ids.len or frame.labels.layer_count != doc.layers.len) return error.InvalidDimensions;
    const theme = ui.Theme.get(light);
    const rect = dvui.windowRect();
    var background = ui.options(theme, .{ .w = rect.w, .h = rect.h }, 14);
    background.background = false;
    background.padding = .{};
    background.corners = .all(0);
    var panel = dvui.box(@src(), .{}, background);
    defer panel.deinit();
    if (frame.layer >= doc.layers.len) return error.InvalidLayer;
    ui.label(theme, try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · {s}", .{ if (frame.live) "Verified running profile" else "Draft · device offline", doc.layers[frame.layer].name }), .{ .x = 20, .y = 4, .w = @max(0, rect.w - 40), .h = 20 }, 12);
    const output = try dvui.currentWindow().arena().alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const key_y: f32 = 26;
    const bounds: desktop.physical_view.Rect = .{ .x = 20, .y = key_y, .w = @max(0, rect.w - 40), .h = @max(0, rect.h - key_y - 25) };
    if (bounds.w == 0 or bounds.h == 0) return;
    const keys = try desktop.physical_view.plan(output, frame.geometry, frame.labels, frame.layer, frame.modifiers, bounds, .{ .pressed = frame.pressed, .active_layers = frame.active_layers });
    if (keys.len == 0) ui.label(theme, "Physical geometry unavailable", .{ .x = 20, .y = 100, .w = 600, .h = 30 }, 16);
    for (keys) |key| {
        const caption = key.content.caption orelse key.content.label orelse key.content.icon_name;
        var options = ui.options(theme, ui.rect(key.placed.rect), if ((std.unicode.utf8CountCodepoints(caption) catch caption.len) > 5) 11 else 17);
        options.font = fonts.font(caption, (if ((std.unicode.utf8CountCodepoints(caption) catch caption.len) > 5) @as(f32, 11) else 17) * @min(1, key.scale));
        options.padding = .all(2);
        options.id_extra = key.placed.id;
        options.rotation = key.placed.rotation;
        options.background = key.pressed;
        options.border = .all(1);
        if (key.pressed) options.color_fill = .{ .color = ui.color(0x3296FF) };
        dvui.labelNoFmt(@src(), caption, .{ .align_x = 0.5, .align_y = 0.5 }, options);
        if (std.mem.eql(u8, key.content.icon_name, "companion") or std.mem.eql(u8, key.content.icon_name, "shutdown")) {
            var icon_options = options;
            icon_options.background = false;
            icon_options.border = .{};
            icon_options.rect = .{ .x = key.placed.rect.x + key.placed.rect.w * 0.3, .y = key.placed.rect.y + key.placed.rect.h * 0.3, .w = key.placed.rect.w * 0.4, .h = key.placed.rect.h * 0.4 };
            dvui.icon(@src(), "tap_signal", if (std.mem.eql(u8, key.content.icon_name, "shutdown")) dvui.entypo.cross else dvui.entypo.eye, .{}, icon_options);
        }
        if (key.content.hold_signal) |id| if (id >= 253) {
            var icon_options = options;
            const last_line = caption[(if (std.mem.lastIndexOfScalar(u8, caption, '\n')) |newline| newline + 1 else 0)..];
            const text_size = options.font.?.textSize(caption);
            const line_size = options.font.?.textSize(last_line);
            const icon_size = options.font.?.size;
            icon_options.padding = .{};
            icon_options.margin = .{};
            icon_options.rect = .{ .x = key.placed.rect.x + (key.placed.rect.w + line_size.w) / 2 - icon_size, .y = key.placed.rect.y + (key.placed.rect.h + text_size.h) / 2 - line_size.h + (line_size.h - icon_size) / 2, .w = icon_size, .h = icon_size };
            icon_options.background = false;
            icon_options.border = .{};
            dvui.icon(@src(), "hold_signal", if (id == 254) dvui.entypo.cross else dvui.entypo.eye, .{}, icon_options);
        };
    }
}
