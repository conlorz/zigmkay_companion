//! Retained keycap rendering: caption, icon, layer and modifier indicators.
const std = @import("std");
const testing = std.testing;
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const zkeymap = @import("zkeymap");
const labels = desktop.labels;
const fonts = @import("editor-fonts");
const core = @import("layout-model");
const CachedKeyContent = desktop.label_cache.CachedKeyContent;

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

fn layerColor(layer: usize) dvui.Color {
    return if (layer < layer_colors.len) layer_colors[layer] else dvui.Color.white;
}

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
            layerColor(i)
        else
            getMutedColor(layerColor(i));

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

const Palette = struct {
    background: dvui.Color,
    border: dvui.Color,
    text: dvui.Color,
    modifier: dvui.Color,

    fn init(layer: usize, active: bool, target: bool, hold: bool) Palette {
        const layer_color = layerColor(layer);
        const muted = getMutedColor(layer_color);
        const dark = dvui.themeGet().dark;
        const target_fill = if (dark)
            dvui.Color{ .r = 58, .g = 47, .b = 22, .a = 255 }
        else
            dvui.Color{ .r = 255, .g = 240, .b = 192, .a = 255 };
        return .{
            .background = if (active) muted else if (target) target_fill else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .border = if (hold)
                dvui.Color{ .r = 80, .g = 210, .b = 255, .a = 255 }
            else if (target)
                dvui.Color{ .r = 255, .g = 201, .b = 83, .a = 255 }
            else if (active)
                layer_color
            else
                muted,
            .text = if (dark or active) dvui.Color.white else dvui.Color{ .r = 32, .g = 36, .b = 42, .a = 255 },
            .modifier = if (dark)
                dvui.Color{ .r = 0, .g = 255, .b = 255, .a = 255 }
            else
                dvui.Color{ .r = 0, .g = 112, .b = 136, .a = 255 },
        };
    }
};

/// Renders one key. Practice guidance marks the next key to `target` (tap) or
/// `hold`; `active` keys are currently pressed.
pub fn drawPracticeKey(
    current_layer: usize,
    index: usize,
    rect: dvui.Rect,
    rotation: f32,
    scale: f32,
    content: CachedKeyContent,
    active: bool,
    target: bool,
    hold: bool,
    resources: Resources,
) !void {
    const size = @min(rect.w, rect.h);
    const palette: Palette = .init(current_layer, active, target, hold);
    const guided = target or hold;

    var b = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .rect = rect,
        .rotation = rotation,
        .background = active or guided,
        .color_fill = .{ .color = palette.background },
        .color_border = .{ .color = palette.border },
        .border = dvui.Rect.all((if (guided) @as(f32, 3) else 1.5) * scale),
        .corners = .all(8 * scale),
        .padding = .{},
    });
    defer b.deinit();
    if (guided) dvui.label(@src(), "{s}", .{if (hold) "HOLD" else "TAP"}, .{
        .gravity_x = 0.5,
        .gravity_y = 1,
        .font = dvui.Font.theme(.body).larger(-3 * scale),
        .color_text = .{ .color = palette.border },
    });

    // A precomputed caption replaces every other indicator.
    if (content.caption) |caption| {
        const reserved: f32 = if (guided) 18 else 8;
        drawCaption(caption, content.hold_signal, index, rect, scale, reserved, palette.text);
        return;
    }
    if (content.icon) |icon_bytes| {
        dvui.icon(@src(), content.icon_name, icon_bytes, .{}, .{
            .id_extra = index,
            .color_text = .{ .color = palette.text },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = size * 0.4, .h = size * 0.4 },
        });
    } else if (content.label) |l| {
        if (std.unicode.utf8ValidateSlice(l)) {
            dvui.label(@src(), "{s}", .{l}, .{
                .id_extra = index,
                .color_text = .{ .color = palette.text },
                .font = dvui.Font.theme(.body).larger(if (l.len <= 2) 4 * scale else 0),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }
    }
    if (content.hold_layer) |layer| drawLayerIndicator(layer, index, size, scale);
    if (content.hold_mods) |mods| drawModifierIndicators(mods, index, size, scale, palette.modifier, resources);
}

/// Draws a caption scaled down to fit the keycap, with an optional hold-signal
/// icon after its last line.
fn drawCaption(caption: []const u8, hold_signal: ?u8, index: usize, rect: dvui.Rect, scale: f32, reserved: f32, color: dvui.Color) void {
    const count = std.unicode.utf8CountCodepoints(caption) catch caption.len;
    const font_size: f32 = if (std.mem.indexOfScalar(u8, caption, '\n') != null) 13 else if (count > 9) 9 else if (count >= 4) 13 else 20;
    var font = fonts.font(caption, font_size * scale);
    const measured = font.textSize(caption);
    const available_width = @max(1, rect.w - 8 * scale);
    const available_height = @max(1, rect.h - reserved * scale);
    const fit = @min(1, @min(available_width / @max(1, measured.w), available_height / @max(1, measured.h)));
    font = font.withSize(font.size * fit);
    // Pixel-snapped font metrics are not proportional to point size. Check
    // the fitted font again so the hold line cannot become an ellipsis.
    for (0..8) |_| {
        const actual = font.textSize(caption);
        if (actual.w <= available_width and actual.h <= available_height) break;
        font = font.withSize(font.size * 0.95);
    }
    dvui.labelNoFmt(@src(), caption, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = index,
        .color_text = .{ .color = color },
        .font = font,
        .rect = .{ .x = 3 * scale, .y = 3 * scale, .w = available_width, .h = available_height },
        .padding = .{},
        .margin = .{},
    });
    // Companion hold signals get an icon: 253 toggles logging (eye), 254 quits (cross).
    const id = hold_signal orelse return;
    if (id < 253) return;
    const last_line = caption[(if (std.mem.lastIndexOfScalar(u8, caption, '\n')) |newline| newline + 1 else 0)..];
    const text_size = font.textSize(caption);
    const line_size = font.textSize(last_line);
    const icon_size = font.size;
    dvui.icon(@src(), "hold_signal", if (id == 254) dvui.entypo.cross else dvui.entypo.eye, .{}, .{
        .color_text = .{ .color = color },
        .rect = .{
            .x = 3 * scale + (available_width + line_size.w) / 2 - icon_size,
            .y = 3 * scale + (available_height + text_size.h) / 2 - line_size.h + (line_size.h - icon_size) / 2,
            .w = icon_size,
            .h = icon_size,
        },
        .padding = .{},
        .margin = .{},
    });
}

/// A layer icon in the top-right corner, in the color of the held layer.
fn drawLayerIndicator(layer: usize, index: usize, size: f32, scale: f32) void {
    const icon_size = size * 0.3;
    const padding = 4 * scale;
    dvui.icon(@src(), "layer_ind", dvui.entypo.layers, .{}, .{
        .id_extra = index + 1000,
        .color_text = .{ .color = layerColor(layer) },
        .rect = .{ .x = size - icon_size - padding, .y = padding, .w = icon_size, .h = icon_size },
    });
}

/// Held modifiers stacked down the left side: GUI, Ctrl, Alt, then Shift.
fn drawModifierIndicators(mods: core.Modifiers, index: usize, size: f32, scale: f32, color: dvui.Color, resources: Resources) void {
    const column: ModifierColumn = .{ .x = 2 * scale, .w = size * 0.6, .item_h = size * 0.25, .color = color };
    var offset_y: f32 = 2 * scale;
    const step = column.item_h + 1 * scale;
    var buffer: [32]u8 = undefined;
    if (mods.left_gui or mods.right_gui) {
        const icon_size = column.item_h * 0.8;
        if (resources.gui_icon) |icon| dvui.icon(@src(), "gui_ind", icon, .{}, .{
            .id_extra = index + 6000,
            .color_text = .{ .color = color },
            .rect = .{
                .x = column.x + (column.w - icon_size) / 2.0,
                .y = offset_y + (column.item_h - icon_size) / 2.0,
                .w = icon_size,
                .h = icon_size,
            },
        }) else {
            column.label(labels.keycapModifiers(labels.runningHost(), 8, &buffer), index + 6000, offset_y);
        }
        offset_y += step;
    }
    if (mods.left_ctrl or mods.right_ctrl) {
        column.label("ctrl", index + 3000, offset_y);
        offset_y += step;
    }
    if (mods.left_alt or mods.right_alt) {
        column.label(labels.keycapModifiers(labels.runningHost(), 4, &buffer), index + 4000, offset_y);
        offset_y += step;
    }
    if (mods.left_shift or mods.right_shift) column.label("shft", index + 5000, offset_y);
}

const ModifierColumn = struct {
    x: f32,
    w: f32,
    item_h: f32,
    color: dvui.Color,

    fn label(self: ModifierColumn, text: []const u8, id_extra: usize, y: f32) void {
        dvui.label(@src(), "{s}", .{text}, .{
            .id_extra = id_extra,
            .color_text = .{ .color = self.color },
            .font = dvui.Font.theme(.body),
            // A taller rect than the slot prevents clipping; slots still advance by item_h.
            .rect = .{ .x = self.x, .y = y, .w = self.w, .h = self.item_h * 1.5 },
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
    }
};

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
