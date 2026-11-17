//! Retained physical editor over injected geometry and current owned captions.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const layout = @import("layout-model");
const fonts = @import("editor-fonts");
const ui = @import("editor-ui");

pub const View = struct {
    choice: usize = 0,
    extend: bool = false,
    canvas_focus: bool = false,
    drag: ?desktop.chord_action.Action = null,
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

pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame, theme: ui.Theme, light: bool) !?Result {
    const actual = try model.id();
    if (!std.mem.eql(u8, &actual, &frame.snapshot)) return error.StaleKeyboardLabels;
    const doc = model.document();
    if (!std.mem.eql(u8, &frame.board_id, &doc.board_id) or !std.mem.eql(u8, frame.physical_layout, doc.physical_layout)) {
        return error.KeyboardBoardMismatch;
    }
    if (frame.labels.key_count != doc.key_ids.len or frame.labels.layer_count != doc.layers.len) return error.InvalidDimensions;
    const a = dvui.currentWindow().arena();
    const output = try a.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const pressed = try a.alloc(bool, doc.key_ids.len);
    @memset(pressed, false);
    const area: desktop.physical_view.Rect = .{ .x = 18, .y = 100, .w = 760, .h = 305 };
    const plan = try desktop.physical_view.plan(output, frame.geometry, frame.labels, model.layer, .{}, area, .{ .pressed = pressed });
    const box = ui.panel(theme, .physical);
    defer box.deinit();
    ui.label(theme, frame.board_name, .{ .x = 20, .y = 20, .w = 205, .h = 25 }, 19);
    ui.label(theme, doc.layers[model.layer].name, .{ .x = 242, .y = 23, .w = 250, .h = 25 }, 16);
    ui.label(theme, frame.fidelity, .{ .x = 20, .y = 64, .w = 500, .h = 24 }, 12);
    var result: ?Result = null;
    const views: []const []const u8 = &.{ "Keys", "Combos", "Encoders" };
    const views_options = ui.options(theme, .{ .x = 626, .y = 15, .w = 150, .h = 36 }, 13);
    if (dvui.dropdown(@src(), views, .{ .choice = &view.choice }, .{}, views_options)) {
        const captured = try desktop.key_selection.Action.capture(model, model.primary, false);
        if (view.choice == 1) result = .{ .combo = captured };
        if (view.choice == 2) result = .{ .encoders = captured };
    }
    view.canvas_focus = false;
    if (plan.len == 0) ui.label(theme, "Physical geometry unavailable", .{ .x = 20, .y = 110, .w = 600, .h = 30 }, 16);
    if (view.drag) |drag| drag.validate(model) catch {
        view.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    };
    for (plan) |item| try drawKey(view, model, item, theme, light, &result);
    return result;
}

fn captionSize(caption: []const u8) f32 {
    if (std.mem.indexOfScalar(u8, caption, '\n') != null) return 13;
    const length = std.unicode.utf8CountCodepoints(caption) catch caption.len;
    if (length > 9) return 9;
    if (length >= 4) return 13;
    return 20;
}

/// Draws one selectable key and its signal icons, and accepts host-palette chord drops.
fn drawKey(
    view: *View,
    model: *const desktop.model.Model,
    item: desktop.physical_view.DrawKey,
    theme: ui.Theme,
    light: bool,
    result: *?Result,
) !void {
    const index = item.placed.key_index;
    const rect = ui.rect(item.placed.rect);
    const content = item.content;
    const caption = content.caption orelse content.label orelse content.icon_name;
    var opts = ui.options(theme, rect, 20);
    opts.rotation = item.placed.rotation;
    opts.id_extra = item.placed.id;
    opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "key.select.{d}", .{index});
    opts.background = true;
    opts.border = .all(if (model.selected[index]) 2 else 1);
    if (model.selected[index]) {
        opts.color_border = .{ .color = ui.color(0x3296FF) };
        opts.color_fill = .{ .color = if (light) ui.color(0xE2F0FF) else ui.color(0x233B55) };
    }
    opts.padding = .all(2);
    opts.font = fonts.font(caption, captionSize(caption) * @min(1, item.scale));
    var data: dvui.WidgetData = undefined;
    opts.data_out = &data;
    if (dvui.button(@src(), caption, .{}, opts) and result.* == null) {
        result.* = .{ .select = try desktop.key_selection.Action.capture(model, index, view.extend) };
    }
    ui.signalIcons(opts, rect, caption, content.icon_name, content.hold_signal);
    if (dvui.focusedWidgetId() == data.id) view.canvas_focus = true;
    try acceptChordDrop(view, model, &data, index, result);
    if (model.document().layers[model.layer].actions[index] == null) {
        ui.label(theme, "inherited", .{ .x = rect.x + 3, .y = rect.y + rect.h - 10, .w = @max(0, rect.w - 6), .h = 8 }, 6);
    }
}

fn acceptChordDrop(view: *View, model: *const desktop.model.Model, data: *dvui.WidgetData, index: usize, result: *?Result) !void {
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
            if (result.* == null) result.* = .{ .chord = try drag.drop(model, index, false) };
        }
    }
}
