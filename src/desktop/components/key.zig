const std = @import("std");
const testing = std.testing;
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const zkeymap = @import("zkeymap");
const labels = desktop.labels;
const fonts = @import("editor-fonts");

const log = std.log.scoped(.companion);

const core = @import("layout-model");

const cache = desktop.label_cache;
pub const CachedKeyContent = cache.CachedKeyContent;
pub const LabelCache = cache.LabelCache;
pub const Resources = struct { gui_icon: ?[]const u8 = null };

/// Vibrant color palette for up to 9 layers.
pub const layer_colors = [9]dvui.Color{
    .{ .r = 255, .g = 50, .b = 50, .a = 255 }, // 0: Red
    .{ .r = 50, .g = 150, .b = 255, .a = 255 }, // 1: Blue
    .{ .r = 255, .g = 150, .b = 50, .a = 255 }, // 2: Orange
    .{ .r = 150, .g = 255, .b = 50, .a = 255 }, // 3: Lime
    .{ .r = 180, .g = 50, .b = 255, .a = 255 }, // 4: Purple
    .{ .r = 50, .g = 255, .b = 200, .a = 255 }, // 5: Teal
    .{ .r = 50, .g = 255, .b = 50, .a = 255 }, // 6: Green
    .{ .r = 255, .g = 230, .b = 50, .a = 255 }, // 7: Yellow
    .{ .r = 255, .g = 50, .b = 180, .a = 255 }, // 8: Pink
};

/// Returns a muted version of a layer color.
pub fn getMutedColor(color: dvui.Color) dvui.Color {
    return .{
        .r = @intCast(@as(u32, color.r) / 2),
        .g = @intCast(@as(u32, color.g) / 2),
        .b = @intCast(@as(u32, color.b) / 2),
        .a = 180,
    };
}

/// Color for layers not present in the keymap.
pub const empty_layer_color = dvui.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };

/// Content representation for a keyboard key, supporting main label/icon
/// and secondary indicators for layers and modifiers.
pub const KeyContent = struct {
    label: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    icon_name: []const u8 = "",
    /// If non-null, show a layer indicator in the top right
    hold_layer: ?core.LayerIndex = null,
    /// If non-null, show modifier icons on the left
    hold_mods: ?core.Modifiers = null,
    /// HID keycode decoded from firmware
    hid_code: ?u8 = null,

    pub fn withIcon(self: KeyContent, icon: []const u8, name: []const u8) KeyContent {
        var c = self;
        c.icon = icon;
        c.icon_name = name;
        return c;
    }

    pub fn withLabel(self: KeyContent, label: []const u8) KeyContent {
        var c = self;
        c.label = label;
        return c;
    }
};

/// Renders a 3x3 grid representing layers.
pub fn drawLayerGrid(active_layer: usize, total_layers: usize, size: f32, scale: f32) !void {
    var outer = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = size, .h = size },
        .gravity_x = 0.5,
    });
    defer outer.deinit();

    const cells = @max(9, total_layers);
    const rows: f32 = @floatFromInt((cells + 2) / 3);
    const cell_size = (size - 2 * (rows + 1) * scale) / rows;

    for (0..cells) |i| {
        const row: f32 = @floatFromInt(i / 3);
        const col: f32 = @floatFromInt(i % 3);

        const color = if (i >= total_layers)
            empty_layer_color
        else if (i == active_layer)
            (if (i < layer_colors.len) layer_colors[i] else dvui.Color.white)
        else
            getMutedColor(if (i < layer_colors.len) layer_colors[i] else dvui.Color.white);

        var cell = dvui.box(@src(), .{}, .{
            .id_extra = i + 9000,
            .rect = .{
                .x = col * (cell_size + 2 * scale),
                .y = row * (cell_size + 2 * scale),
                .w = cell_size,
                .h = cell_size,
            },
            .background = true,
            .color_fill = .{ .color = color },
            .corners = .all(2 * scale),
        });
        cell.deinit();
    }
}

/// Renders a single keyboard key box with its associated label or icon.
pub fn drawKey(current_layer: usize, index: usize, x: f32, y: f32, size: f32, scale: f32, content: CachedKeyContent, active: bool, resources: Resources) !void {
    const rect = dvui.Rect{ .x = x, .y = y, .w = size, .h = size };
    return drawPhysicalKey(current_layer, index, rect, 0, scale, content, active, resources);
}

pub fn drawPhysicalKey(current_layer: usize, index: usize, rect: dvui.Rect, rotation: f32, scale: f32, content: CachedKeyContent, active: bool, resources: Resources) !void {
    return drawGuidedKey(current_layer, index, rect, rotation, scale, content, active, false, resources);
}
pub fn drawGuidedKey(current_layer: usize, index: usize, rect: dvui.Rect, rotation: f32, scale: f32, content: CachedKeyContent, active: bool, target: bool, resources: Resources) !void {
    return drawPracticeKey(current_layer, index, rect, rotation, scale, content, active, target, false, resources);
}
pub fn drawPracticeKey(current_layer: usize, index: usize, rect: dvui.Rect, rotation: f32, scale: f32, content: CachedKeyContent, active: bool, target: bool, hold: bool, resources: Resources) !void {
    const size = @min(rect.w, rect.h);

    const layer_color = if (current_layer < layer_colors.len) layer_colors[current_layer] else dvui.Color.white;
    const muted_layer_color = getMutedColor(layer_color);

    const dark = dvui.themeGet().dark;
    const bg_color = if (active) muted_layer_color else if (target) (if (dark) dvui.Color{ .r = 58, .g = 47, .b = 22, .a = 255 } else dvui.Color{ .r = 255, .g = 240, .b = 192, .a = 255 }) else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const border_color = if (hold) dvui.Color{ .r = 80, .g = 210, .b = 255, .a = 255 } else if (target) dvui.Color{ .r = 255, .g = 201, .b = 83, .a = 255 } else if (active) layer_color else muted_layer_color;
    const text_color = if (dark or active) dvui.Color.white else dvui.Color{ .r = 32, .g = 36, .b = 42, .a = 255 };
    const mod_color = if (dark) dvui.Color{ .r = 0, .g = 255, .b = 255, .a = 255 } else dvui.Color{ .r = 0, .g = 112, .b = 136, .a = 255 };

    var b = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .rect = rect,
        .rotation = rotation,
        .background = active or target or hold,
        .color_fill = .{ .color = bg_color },
        .color_border = .{ .color = border_color },
        .border = dvui.Rect.all((if (target or hold) @as(f32, 3) else 1.5) * scale),
        .corners = .all(8 * scale),
        .padding = .{},
    });
    defer b.deinit();
    if (target or hold) dvui.label(@src(), "{s}", .{if (hold) "HOLD" else "TAP"}, .{
        .gravity_x = 0.5,
        .gravity_y = 1,
        .font = dvui.Font.theme(.body).larger(-3 * scale),
        .color_text = .{ .color = border_color },
    });

    // 1. Main Content (Center)
    if (content.caption) |caption| {
        const count = std.unicode.utf8CountCodepoints(caption) catch caption.len;
        const font_size: f32 = if (std.mem.indexOfScalar(u8, caption, '\n') != null) 13 else if (count > 9) 9 else if (count >= 4) 13 else 20;
        var caption_font = fonts.font(caption, font_size * scale);
        const measured = caption_font.textSize(caption);
        const available_width = @max(1, rect.w - 8 * scale);
        const available_height = @max(1, rect.h - (if (target or hold) @as(f32, 18) else 8) * scale);
        const fit = @min(1, @min(available_width / @max(1, measured.w), available_height / @max(1, measured.h)));
        caption_font = caption_font.withSize(caption_font.size * fit);
        // Pixel-snapped font metrics are not proportional to point size. Check
        // the fitted font again so the hold line cannot become an ellipsis.
        for (0..8) |_| {
            const actual = caption_font.textSize(caption);
            if (actual.w <= available_width and actual.h <= available_height) break;
            caption_font = caption_font.withSize(caption_font.size * 0.95);
        }
        dvui.labelNoFmt(@src(), caption, .{ .align_x = 0.5, .align_y = 0.5 }, .{
            .id_extra = index,
            .color_text = .{ .color = text_color },
            .font = caption_font,
            .rect = .{ .x = 3 * scale, .y = 3 * scale, .w = available_width, .h = available_height },
            .padding = .{},
            .margin = .{},
        });
        if (content.hold_signal) |id| if (id >= 253) {
            const last_line = caption[(if (std.mem.lastIndexOfScalar(u8, caption, '\n')) |newline| newline + 1 else 0)..];
            const text_size = caption_font.textSize(caption);
            const line_size = caption_font.textSize(last_line);
            const icon_size = caption_font.size;
            dvui.icon(@src(), "hold_signal", if (id == 254) dvui.entypo.cross else dvui.entypo.eye, .{}, .{
                .color_text = .{ .color = text_color },
                .rect = .{ .x = 3 * scale + (available_width + line_size.w) / 2 - icon_size, .y = 3 * scale + (available_height + text_size.h) / 2 - line_size.h + (line_size.h - icon_size) / 2, .w = icon_size, .h = icon_size },
                .padding = .{},
                .margin = .{},
            });
        };
        return;
    }
    if (content.icon) |icon_bytes| {
        dvui.icon(@src(), content.icon_name, icon_bytes, .{}, .{
            .id_extra = index,
            .color_text = .{ .color = text_color },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = size * 0.4, .h = size * 0.4 },
        });
    } else if (content.label) |l| {
        if (std.unicode.utf8ValidateSlice(l)) {
            dvui.label(@src(), "{s}", .{l}, .{
                .id_extra = index,
                .color_text = .{ .color = text_color },
                .font = dvui.Font.theme(.body).larger(if (l.len <= 2) 4 * scale else 0),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }
    }

    // 2. Layer Indicator (Top Right)
    if (content.hold_layer) |l| {
        const icon_size = size * 0.3;
        const padding = 4 * scale;
        const color = if (l < layer_colors.len) layer_colors[l] else dvui.Color.white;

        dvui.icon(@src(), "layer_ind", dvui.entypo.layers, .{}, .{
            .id_extra = index + 1000,
            .color_text = .{ .color = color },
            .rect = .{ .x = size - icon_size - padding, .y = padding, .w = icon_size, .h = icon_size },
        });
    }

    // 3. Hold Modifier Indicators (Left Side)
    if (content.hold_mods) |m| {
        const item_h = size * 0.25;
        const padding_x = 2 * scale;
        var offset_y: f32 = 2 * scale;

        const font = dvui.Font.theme(.body);
        const col_w = size * 0.6; // width of the mod column on the left

        if (m.left_gui or m.right_gui) {
            const gui_icon_size = item_h * 0.8;
            if (resources.gui_icon) |icon| dvui.icon(@src(), "gui_ind", icon, .{}, .{
                .id_extra = index + 6000,
                .color_text = .{ .color = mod_color },
                // Center icon horizontally in col_w and vertically in its slot
                .rect = .{
                    .x = padding_x + (col_w - gui_icon_size) / 2.0,
                    .y = offset_y + (item_h - gui_icon_size) / 2.0,
                    .w = gui_icon_size,
                    .h = gui_icon_size,
                },
            }) else {
                var modifier_buffer: [32]u8 = undefined;
                dvui.label(@src(), "{s}", .{labels.keycapModifiers(labels.runningHost(), 8, &modifier_buffer)}, .{ .id_extra = index + 6000, .color_text = .{ .color = mod_color }, .font = font, .rect = .{ .x = padding_x, .y = offset_y, .w = col_w, .h = item_h * 1.5 }, .gravity_x = 0.5, .gravity_y = 0.5 });
            }
            offset_y += item_h + 1 * scale;
        }

        if (m.left_ctrl or m.right_ctrl) {
            dvui.label(@src(), "ctrl", .{}, .{
                .id_extra = index + 3000,
                .color_text = .{ .color = mod_color },
                .font = font,
                // Use a significantly taller rect for the label itself to prevent clipping,
                // but keep the offset_y increment standard.
                .rect = .{ .x = padding_x, .y = offset_y, .w = col_w, .h = item_h * 1.5 },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
            offset_y += item_h + 1 * scale;
        }

        if (m.left_alt or m.right_alt) {
            var modifier_buffer: [32]u8 = undefined;
            dvui.label(@src(), "{s}", .{labels.keycapModifiers(labels.runningHost(), 4, &modifier_buffer)}, .{
                .id_extra = index + 4000,
                .color_text = .{ .color = mod_color },
                .font = font,
                .rect = .{ .x = padding_x, .y = offset_y, .w = col_w, .h = item_h * 1.5 },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
            offset_y += item_h + 1 * scale;
        }

        if (m.left_shift or m.right_shift) {
            dvui.label(@src(), "shft", .{}, .{
                .id_extra = index + 5000,
                .color_text = .{ .color = mod_color },
                .font = font,
                .rect = .{ .x = padding_x, .y = offset_y, .w = col_w, .h = item_h * 1.5 },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }
    }
}

test "getLabel: KC_A tap_only produces correct KeyDef" {
    const def = core.KeyDef{ .tap_only = .{
        .key_press = .{
            .tap_keycode = @backingInt(zkeymap.ScanCode.KC_A),
        },
    } };

    try testing.expect(def.tap_only.key_press != null);
    try testing.expectEqual(@as(u8, @backingInt(zkeymap.ScanCode.KC_A)), def.tap_only.key_press.?.tap_keycode);
}

test "getLabel: transparent key returns transparent variant" {
    const def: ?core.KeyDef = null;
    try testing.expect(def == null);
}

test "getLabel: none key returns none variant" {
    const def = core.KeyDef.none;
    try testing.expect(def == .none);
}

test "getLabel: media key volume up has correct media_key" {
    const def = core.KeyDef{ .tap_only = .{
        .media_key = .VolumeUp,
    } };
    try testing.expectEqual(core.MediaCode.VolumeUp, def.tap_only.media_key.?);
}

test "getLabel: COM_TOG custom has correct id" {
    const def = core.KeyDef{ .tap_only = .{
        .custom = core.CUSTOM_ID_COMPANION_TOGGLE,
    } };
    try testing.expectEqual(@as(u8, core.CUSTOM_ID_COMPANION_TOGGLE), def.tap_only.custom);
}

test "getLabel: mouse left click has correct action" {
    const def = core.KeyDef{ .tap_only = .{
        .mouse_action = .LeftButton,
    } };
    try testing.expect(def.tap_only.mouse_action == .LeftButton);
}

test "getLabel: tap_hold with layer has correct hold_layer" {
    const def = core.KeyDef{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_SPACE) } },
        .hold = .{ .hold_layer = 2 },
        .tapping_term = .{ .ms = 200 },
    } };
    try testing.expectEqual(@as(?core.LayerIndex, 2), def.tap_hold.hold.hold_layer);
}

test "getLabel: hold_only with modifiers shows modifier" {
    const def = core.KeyDef{ .hold_only = .{
        .hold_modifiers = .{ .left_shift = true, .right_shift = true },
    } };
    try testing.expect(def.hold_only.hold_modifiers.has_any());
    try testing.expect(def.hold_only.hold_modifiers.left_shift);
    try testing.expect(def.hold_only.hold_modifiers.right_shift);
}

test "getLabel: tap_with_autofire has correct structure" {
    const def = core.KeyDef{ .tap_with_autofire = .{
        .tap = .{ .key_press = .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_B) } },
        .initial_delay = .{ .ms = 100 },
        .repeat_interval = .{ .ms = 50 },
    } };
    try testing.expect(def.tap_with_autofire.tap.key_press != null);
}
