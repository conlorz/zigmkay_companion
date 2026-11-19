//! Retained physical editor over injected geometry and current owned captions.
//! Every key has two halves: the upper one shows and edits the tap, the lower
//! one the hold or autofire.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");
const p = @import("project");
const ui = @import("editor-ui");

/// The half of a key: what it does when tapped or when held.
pub const Part = enum { tap, hold };

pub const View = struct {
    choice: usize = 0,
    extend: bool = false,
    canvas_focus: bool = false,
    drag: ?desktop.chord_action.Action = null,
    /// The half whose editor is open on the primary key, drawn highlighted.
    open: ?Part = null,
    /// The half clicked this frame. The frame opens its editor.
    clicked: ?Part = null,
    /// Screen rectangle of the primary key, where its editor is anchored.
    anchor: ?dvui.Rect.Physical = null,
};

pub const Frame = struct {
    snapshot: [32]u8,
    board_id: [8]u8,
    physical_layout: []const u8,
    geometry: []const layout.physical_layout.Key,
    labels: *const desktop.label_cache.LabelCache,
    board_name: []const u8,
    fidelity: []const u8,
};

pub const Result = union(enum) {
    select: desktop.key_selection.Action,
    combo: desktop.key_selection.Action,
    encoders: desktop.key_selection.Action,
    chord: desktop.chord_action.Action,
};

/// Height of the strip at the bottom of the panel that explains the primary
/// key and holds its clipboard actions; see `key_editor_ui`.
pub const bar_height: f32 = 76;
/// Share of a key's height taken by its tap half.
const tap_share: f32 = 0.62;

pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame, theme: ui.Theme) !?Result {
    const actual = try model.id();
    if (!std.mem.eql(u8, &actual, &frame.snapshot)) return error.StaleKeyboardLabels;
    const doc = model.document();
    if (!std.mem.eql(u8, &frame.board_id, &doc.board_id) or !std.mem.eql(u8, frame.physical_layout, doc.physical_layout)) {
        return error.KeyboardBoardMismatch;
    }
    if (frame.labels.key_count != doc.key_ids.len or frame.labels.layer_count != doc.layers.len) return error.InvalidDimensions;
    const bounds = ui.panelRect(.physical);
    const a = dvui.currentWindow().arena();
    const output = try a.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const pressed = try a.alloc(bool, doc.key_ids.len);
    @memset(pressed, false);
    // The canvas fills the panel between its header and the explanation strip;
    // geometry keeps its aspect.
    const area: desktop.physical_view.Rect = .{ .x = 20, .y = 64, .w = bounds.w - 40, .h = bounds.h - 64 - bar_height - 12 };
    const plan = try desktop.physical_view.plan(output, frame.geometry, frame.labels, model.layer, .{}, area, .{ .pressed = pressed });
    const box = ui.panel(theme, .physical);
    defer box.deinit();
    drawLayerChip(theme, doc.layers[model.layer].name, model.layer);
    var muted = theme;
    muted.text = theme.muted;
    const chip_width = layerChipWidth(theme, doc.layers[model.layer].name);
    const detail = try std.fmt.allocPrint(a, "{s} · {s}", .{ frame.board_name, frame.fidelity });
    ui.label(muted, detail, .{ .x = 20 + chip_width + 14, .y = 26, .w = bounds.w - chip_width - 290, .h = 18 }, 12);
    var result: ?Result = null;
    if (try drawViewSwitch(view, theme, bounds.w)) |choice| {
        const captured = try desktop.key_selection.Action.capture(model, model.primary, false);
        if (choice == 1) result = .{ .combo = captured };
        if (choice == 2) result = .{ .encoders = captured };
    }
    view.canvas_focus = false;
    view.clicked = null;
    view.anchor = null;
    if (plan.len == 0) ui.label(theme, "Physical geometry unavailable", .{ .x = 20, .y = 110, .w = 600, .h = 30 }, 16);
    if (view.drag) |drag| drag.validate(model) catch {
        view.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    };
    for (plan) |item| try drawKey(view, model, frame, item, theme, &result);
    return result;
}

fn layerChipWidth(theme: ui.Theme, name: []const u8) f32 {
    return @min(@as(f32, 220), ui.captionSize(name, theme.captionStyle(19, 0)).w + 44);
}

/// The edited layer as a pill in its color.
fn drawLayerChip(theme: ui.Theme, name: []const u8, layer: usize) void {
    const color = ui.layerColor(theme, layer);
    const width = layerChipWidth(theme, name);
    const chip = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 20, .y = 18, .w = width, .h = 30 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, color, 0.2) },
        .color_border = .{ .color = color },
        .border = .all(1.5),
        .corners = .all(15),
        .padding = .{},
        .margin = .{},
        .tag = "keyboard.layer",
    });
    chip.deinit();
    const dot = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 31, .y = 28, .w = 10, .h = 10 },
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .all(5),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
    // Key captions use key IDs (u16) as id_extra; stay above that range.
    var style = theme.captionStyle(19, 0x10000);
    style.align_x = 0;
    ui.caption(name, .{ .x = 48, .y = 18, .w = width - 56, .h = 30 }, style);
}

/// Keys, Combos and Encoders as a segmented control at the right of a panel
/// `width` wide. Keys is the canvas; the other two open their editors.
/// Returns the chosen segment when clicked.
fn drawViewSwitch(view: *View, theme: ui.Theme, width: f32) !?usize {
    const names = [_][]const u8{ "Keys", "Combos", "Encoders" };
    const widths = [_]f32{ 64, 80, 88 };
    const track_w: f32 = widths[0] + widths[1] + widths[2] + 8;
    const left = width - 20 - track_w;
    const track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = left, .y = 16, .w = track_w, .h = 34 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
    track.deinit();
    var x: f32 = left + 4;
    var chosen: ?usize = null;
    for (names, widths, 0..) |name, segment, index| {
        var opts = ui.options(theme, .{ .x = x, .y = 20, .w = segment, .h = 26 }, 13);
        opts.id_extra = index;
        opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "keyboard.view.{d}", .{index});
        opts.corners = .all(6);
        opts.padding = .{};
        opts.background = index == 0;
        opts.color_fill = .{ .color = ui.mix(theme.control, theme.text, 0.12) };
        opts.color_text = .{ .color = if (index == 0) theme.text else theme.muted };
        if (dvui.button(@src(), name, .{}, opts) and index != 0) chosen = index;
        x += segment;
    }
    view.choice = 0;
    return chosen;
}

/// The caption a transparent key falls through to, from the nearest lower
/// layer that assigns the key, or null when no layer does.
fn inheritedCaption(labels: *const desktop.label_cache.LabelCache, layer: usize, index: usize) ?[]const u8 {
    var lower = layer;
    while (lower > 0) {
        lower -= 1;
        const entry = labels.lookup(lower, index, .{});
        if (!isTransparent(entry.*)) return entry.caption;
    }
    return null;
}

fn isTransparent(content: desktop.label_cache.CachedKeyContent) bool {
    return if (content.label) |text| std.mem.eql(u8, text, "---") else false;
}

/// The key's action on the edited layer, or the one it falls through to.
fn resolvedAction(doc: p.Document, layer: usize, index: usize) ?p.Action {
    var current = layer + 1;
    while (current > 0) {
        current -= 1;
        if (doc.layers[current].actions[index]) |action| return action;
    }
    return null;
}

/// What each half of a key face shows.
pub const Legends = struct {
    tap: []const u8 = "",
    hold: []const u8 = "",
    /// The repeat interval in ms when the lower half autofires.
    autofire: ?u16 = null,
};

/// Splits a cached keycap caption into the legends of its two halves. A tap
/// and hold caption has the hold on its second line.
pub fn legends(action: ?p.Action, caption: []const u8) Legends {
    const value = action orelse return .{ .tap = caption };
    return switch (value) {
        .tap_hold => if (std.mem.indexOfScalar(u8, caption, '\n')) |split|
            .{ .tap = caption[0..split], .hold = caption[split + 1 ..] }
        else
            .{ .tap = caption },
        .hold_only => .{ .hold = caption },
        .tap_with_autofire => |autofire| .{ .tap = caption, .autofire = autofire.repeat_interval.ms },
        else => .{ .tap = caption },
    };
}

/// Draws one key with its tap and hold halves. Each half selects the key and
/// opens its editor, and accepts host-palette chord drops for that part. The
/// border carries the color of the edited layer; transparent keys show the
/// legend they fall through to, dimmed.
fn drawKey(
    view: *View,
    model: *const desktop.model.Model,
    frame: Frame,
    item: desktop.physical_view.DrawKey,
    theme: ui.Theme,
    result: *?Result,
) !void {
    const index = item.placed.key_index;
    const rect = ui.rect(item.placed.rect);
    const content = item.content;
    const transparent = isTransparent(content);
    const selected = model.selected[index];
    const primary = selected and model.primary == index;
    const layer_color = ui.layerColor(theme, model.layer);
    const turned = item.placed.rotation != 0;
    const fill = if (selected) ui.mix(theme.keycap, layer_color, 0.14) else if (transparent) theme.panel else theme.keycap;
    const border = if (selected) layer_color else ui.mix(theme.keycap, layer_color, if (transparent) 0.3 else 0.65);
    const corner = @max(4, rect.w * 0.12);
    const thickness: f32 = if (selected) 2.5 else 1.5;
    const id = item.placed.id;
    const split = @round(rect.h * tap_share);
    const halves = [2]dvui.Rect{
        .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = split },
        .{ .x = rect.x, .y = rect.y + split, .w = rect.w, .h = rect.h - split },
    };
    // A turned key keeps upright hit areas and draws its face as a path.
    if (turned) {
        ui.turnedFace(rect, item.placed.rotation, corner, fill, border, thickness);
    } else {
        const face = dvui.box(@src(), .{}, .{
            .id_extra = id,
            .rect = rect,
            .background = true,
            .color_fill = .{ .color = fill },
            .color_border = .{ .color = border },
            .border = .all(thickness),
            .corners = .all(corner),
            .padding = .{},
            .margin = .{},
        });
        face.deinit();
        // The hold half sits on a slightly darker band below a hairline.
        const open = if (primary) view.open else null;
        const band_fill = if (open == .hold)
            ui.mix(fill, layer_color, 0.4)
        else
            ui.mix(fill, theme.bg, if (transparent) 0.25 else 0.45);
        const band = dvui.box(@src(), .{}, .{
            .id_extra = id,
            .rect = .{ .x = rect.x + thickness, .y = rect.y + split, .w = rect.w - thickness * 2, .h = rect.h - split - thickness },
            .background = true,
            .color_fill = .{ .color = band_fill },
            .corners = bottomCorners(corner - thickness),
            .padding = .{},
            .margin = .{},
        });
        band.deinit();
        if (open == .tap) {
            const tint = dvui.box(@src(), .{}, .{
                .id_extra = id,
                .rect = .{ .x = rect.x + thickness, .y = rect.y + thickness, .w = rect.w - thickness * 2, .h = split - thickness },
                .background = true,
                .color_fill = .{ .color = ui.mix(fill, layer_color, 0.4) },
                .corners = topCorners(corner - thickness),
                .padding = .{},
                .margin = .{},
            });
            tint.deinit();
        }
        const line = dvui.box(@src(), .{}, .{
            .id_extra = id,
            .rect = .{ .x = rect.x + thickness, .y = rect.y + split, .w = rect.w - thickness * 2, .h = 1 },
            .background = true,
            .color_fill = .{ .color = ui.mix(fill, border, if (selected) 0.6 else 0.25) },
            .padding = .{},
            .margin = .{},
        });
        line.deinit();
    }
    const arena = dvui.currentWindow().arena();
    var anchor: ?dvui.Rect.Physical = null;
    inline for (.{ Part.tap, Part.hold }, 0..) |part, half| {
        const bounds = halves[half];
        var data: dvui.WidgetData = undefined;
        const hover = theme.text.opacity(0.07);
        const clear = theme.text.opacity(0);
        // The tap half keeps the key's historic tag for scripted clicks.
        const tag = if (part == .tap)
            try std.fmt.allocPrint(arena, "key.select.{d}", .{index})
        else
            try std.fmt.allocPrint(arena, "key.hold.{d}", .{index});
        if (dvui.button(@src(), "", .{}, .{
            .id_extra = @as(usize, id) * 2 + half,
            .tag = tag,
            .rect = bounds,
            .background = !turned,
            .color_fill = .{ .color = clear },
            .color_fill_hover = .{ .color = hover },
            .color_fill_press = .{ .color = theme.text.opacity(0.12) },
            .border = .{},
            .corners = if (part == .tap) topCorners(corner) else bottomCorners(corner),
            .padding = .{},
            .margin = .{},
            .data_out = &data,
        }) and result.* == null) {
            result.* = .{ .select = try desktop.key_selection.Action.capture(model, index, view.extend) };
            view.clicked = part;
        }
        if (dvui.focusedWidgetId() == data.id) view.canvas_focus = true;
        try acceptChordDrop(view, model, &data, index, part == .hold, result);
        const r = data.borderRectScale().r;
        anchor = if (anchor) |previous| previous.unionWith(r) else r;
    }
    if (primary) view.anchor = anchor;

    const doc = model.document();
    const fallthrough = if (transparent) inheritedCaption(frame.labels, model.layer, index) else null;
    const text = if (transparent) fallthrough orelse "" else content.caption orelse content.label orelse "";
    const shown = legends(resolvedAction(doc, model.layer, index), text);
    const inset = @max(3, rect.w * 0.08);
    const scale = @min(1.2, item.scale);
    const tap_bounds: dvui.Rect = .{ .x = rect.x + inset, .y = rect.y + inset * 0.7, .w = @max(1, rect.w - inset * 2), .h = @max(1, split - inset * 1.2) };
    const hold_bounds: dvui.Rect = .{ .x = rect.x + inset, .y = rect.y + split + 2, .w = @max(1, rect.w - inset * 2), .h = @max(1, rect.h - split - 5) };
    ui.caption(shown.tap, tap_bounds, .{
        .color = if (transparent) theme.muted else theme.text,
        .secondary = theme.muted,
        .size = 24 * scale,
        .id_extra = id,
        .layer_colors = !transparent,
        .layers = theme.layers,
    });
    if (shown.autofire) |interval| {
        drawAutofire(theme, hold_bounds, interval, id, scale);
    } else if (shown.hold.len != 0) {
        ui.caption(shown.hold, hold_bounds, .{
            .color = theme.muted,
            .secondary = theme.muted,
            .size = 16 * scale,
            .id_extra = @as(usize, id) + 0x20000,
            .layer_colors = !transparent,
            .layers = theme.layers,
        });
    }
}

const CornerRect = @typeInfo(@FieldType(dvui.Options, "corners")).optional.child;

fn topCorners(radius: f32) CornerRect {
    return .{ .tl = .round(radius), .tr = .round(radius), .br = .square, .bl = .square };
}

fn bottomCorners(radius: f32) CornerRect {
    return .{ .tl = .square, .tr = .square, .br = .round(radius), .bl = .round(radius) };
}

/// The lower half of an autofire key: the repeat icon and the interval.
fn drawAutofire(theme: ui.Theme, bounds: dvui.Rect, interval: u16, id: u16, scale: f32) void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{interval}) catch "";
    const size = @max(9, 13 * scale);
    const font = ui.editorFont(text, size);
    const icon = size + 1;
    const width = icon + 4 + font.textSize(text).w;
    const x = bounds.x + (bounds.w - width) / 2;
    const y = bounds.y + (bounds.h - icon) / 2;
    dvui.icon(@src(), "autofire", ui.control_icons.autofire, .{}, .{
        .id_extra = id,
        .rect = .{ .x = x, .y = y, .w = icon, .h = icon },
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
    dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = id,
        .rect = .{ .x = x + icon + 4, .y = bounds.y, .w = width - icon - 4 + 2, .h = bounds.h },
        .font = font,
        .color_text = .{ .color = theme.muted },
        .gravity_y = 0.5,
        .padding = .{},
        .margin = .{},
    });
}

/// Accepts a host-palette chord dropped on one half of a key. The hold half
/// takes modifiers; any other key dropped there becomes the tap.
fn acceptChordDrop(view: *View, model: *const desktop.model.Model, data: *dvui.WidgetData, index: usize, held: bool, result: *?Result) !void {
    const drag = view.drag orelse return;
    if (!dvui.dragName("key_chord")) return;
    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = data.id, .r = data.borderRectScale().r, .drag_name = "key_chord" })) continue;
        if (event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action == .position) data.focusBorder();
        if (mouse.action == .release and mouse.button == .left) {
            event.handle(@src(), data);
            dvui.dragEnd();
            view.drag = null;
            const modifier = drag.chord.tap_keycode >= 224 and drag.chord.tap_keycode <= 231;
            if (result.* == null) result.* = .{ .chord = try drag.drop(model, index, held and modifier) };
        }
    }
}

test "key legends split tap and hold captions by the action's parts" {
    const t = std.testing;
    const tap: p.Tap = .{ .key_press = .{ .tap_keycode = 4 } };
    const both = legends(.{ .tap_hold = .{ .tap = tap, .hold = .{ .layer_id = 1 }, .tapping_term = .{ .ms = 180 } } }, "A\nL1");
    try t.expectEqualStrings("A", both.tap);
    try t.expectEqualStrings("L1", both.hold);
    const held = legends(.{ .hold_only = .{ .layer_id = 1 } }, "L1");
    try t.expectEqualStrings("", held.tap);
    try t.expectEqualStrings("L1", held.hold);
    const repeat = legends(.{ .tap_with_autofire = .{
        .tap = tap,
        .initial_delay = .{ .ms = 300 },
        .repeat_interval = .{ .ms = 50 },
    } }, "A");
    try t.expectEqualStrings("A", repeat.tap);
    try t.expectEqual(@as(?u16, 50), repeat.autofire);
    try t.expectEqualStrings("A", legends(.{ .tap_only = tap }, "A").tap);
    try t.expectEqualStrings("K", legends(null, "K").tap);
}
