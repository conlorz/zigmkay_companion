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
    assistance: desktop.practice_results.Assistance = .guided,
    live: bool = false,
    active_layers: ?u16 = null,
    targets: ?[]const bool = null,
    holds: ?[]const bool = null,
};

pub fn draw(model: *const desktop.model.Model, frame: Frame, light: bool) !void {
    if (!std.mem.eql(u8, &frame.snapshot, &(try model.id()))) return error.StaleKeyboardLabels;
    const doc = model.document();
    if (frame.labels.key_count != doc.key_ids.len or frame.labels.layer_count != doc.layers.len) return error.InvalidDimensions;
    const arena = dvui.currentWindow().arena();
    const theme = ui.Theme.get(light);
    const rect = dvui.windowRect();
    var background = ui.options(theme, .{ .w = rect.w, .h = rect.h }, 14);
    background.background = false;
    background.padding = .{};
    background.corners = .all(0);
    var panel = dvui.box(@src(), .{}, background);
    defer panel.deinit();
    if (frame.layer >= doc.layers.len) return error.InvalidLayer;
    const source = if (frame.live) "Verified running profile" else "Draft · device offline";
    const title = try std.fmt.allocPrint(arena, "{s} · {s}", .{ source, doc.layers[frame.layer].name });
    ui.label(theme, title, .{ .x = 20, .y = 4, .w = @max(0, rect.w - 40), .h = 20 }, 12);
    const output = try arena.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const key_y: f32 = 26;
    const bounds: desktop.physical_view.Rect = .{ .x = 20, .y = key_y, .w = @max(0, rect.w - 40), .h = @max(0, rect.h - key_y - 25) };
    if (bounds.w == 0 or bounds.h == 0) return;
    const neutral = try arena.alloc(bool, frame.labels.key_count);
    @memset(neutral, false);
    // Practice without guided assistance shows neither presses nor targets.
    const guided = frame.practicing and frame.assistance == .guided;
    const keys = try desktop.physical_view.plan(output, frame.geometry, frame.labels, frame.layer, frame.modifiers, bounds, .{
        .pressed = if (frame.practicing and frame.assistance != .guided) neutral else frame.pressed,
        .active_layers = frame.active_layers,
        .targets = if (guided) frame.targets else null,
        .holds = if (guided) frame.holds else null,
        .hold_source_layer = frame.layer,
    });
    if (keys.len == 0) ui.label(theme, "Physical geometry unavailable", .{ .x = 20, .y = 100, .w = 600, .h = 30 }, 16);
    for (keys) |key| try drawKey(key, theme);
}

fn drawKey(key: desktop.physical_view.DrawKey, theme: ui.Theme) !void {
    const caption = key.content.caption orelse key.content.label orelse key.content.icon_name;
    const long = (std.unicode.utf8CountCodepoints(caption) catch caption.len) > 5;
    const bounds = ui.rect(key.placed.rect);
    var options = ui.options(theme, bounds, if (long) 11 else 17);
    options.font = fonts.font(caption, (if (long) @as(f32, 11) else 17) * @min(1, key.scale));
    options.padding = .all(2);
    options.id_extra = key.placed.id;
    options.rotation = key.placed.rotation;
    options.background = key.pressed or key.target or key.hold;
    if (key.target) options.color_fill = .{ .color = ui.color(0xD6A54D) };
    if (key.hold) options.color_fill = .{ .color = ui.color(0x267FA5) };
    options.border = .all(1);
    if (key.pressed) options.color_fill = .{ .color = ui.color(0x3296FF) };
    const arena = dvui.currentWindow().arena();
    const text = if (key.hold)
        try std.fmt.allocPrint(arena, "{s}\nHOLD", .{caption})
    else if (key.target)
        try std.fmt.allocPrint(arena, "{s}\nTAP", .{caption})
    else
        caption;
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, options);
    ui.signalIcons(options, bounds, caption, key.content.icon_name, key.content.hold_signal);
}
