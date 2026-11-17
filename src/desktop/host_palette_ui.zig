//! Retained OS keyboard chord source; injected owned previews only.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const fonts = @import("editor-fonts");
pub const View = struct { shift: bool = false, option: bool = false, drag: ?desktop.chord_action.Action = null, source_revision: ?u64 = null };
pub fn draw(view: *View, model: *const desktop.model.Model, cache: *const desktop.host_palette.Cache, theme: ui.Theme) !?desktop.chord_action.Action {
    const box = ui.panel(theme, .os);
    defer box.deinit();
    ui.label(theme, "OS keyboard", .{ .x = 20, .y = 18, .w = 205, .h = 25 }, 19);
    ui.label(theme, cache.source_id, .{ .x = 225, .y = 23, .w = 320, .h = 25 }, 12);
    var shift_theme = theme;
    var option_theme = theme;
    if (view.shift) {
        shift_theme.control = ui.color(0x126AFF);
        shift_theme.text = ui.color(0xFFFFFF);
    }
    if (view.option) {
        option_theme.control = ui.color(0x126AFF);
        option_theme.text = ui.color(0xFFFFFF);
    }
    if (ui.button(shift_theme, "Shift", "os.shift", .{ .x = 622, .y = 15, .w = 70, .h = 33 })) view.shift = !view.shift;
    if (ui.button(option_theme, if (cache.host == .macos) "Option" else "Alt", "os.option", .{ .x = 699, .y = 15, .w = 73, .h = 33 })) view.option = !view.option;
    var result: ?desktop.chord_action.Action = null;
    if (view.source_revision != null and view.source_revision.? != cache.revision) {
        view.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    }
    view.source_revision = cache.revision;
    if (view.drag) |drag| drag.validate(model) catch {
        view.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    };
    for (desktop.host_palette.rows, 0..) |row, ri| {
        var x: f32 = 14;
        for (row, 0..) |key, ki| {
            const caption = cache.caption(key.code, view.shift, view.option);
            var opts = ui.options(theme, .{ .x = x, .y = 58 + @as(f32, @floatFromInt(ri)) * 38, .w = 47.5 * key.units - 3, .h = 35 }, if (caption.len > 3) 11 else 18);
            opts.padding = .all(2);
            opts.font = fonts.font(caption, if (caption.len > 3) 11 else 18);
            opts.id_extra = ri * 100 + ki;
            opts.background = true;
            opts.gravity_x = 0.5;
            opts.gravity_y = 0.5;
            opts.border = .all(1);
            opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "os.key.{d}", .{key.code});
            if (try source(view, model, key.code, caption, opts)) |action| if (result == null) {
                result = action;
            };
            x += 47.5 * key.units;
        }
    }
    return result;
}
fn source(view: *View, model: *const desktop.model.Model, code: u8, caption: []const u8, opts: dvui.Options) !?desktop.chord_action.Action {
    var key: dvui.ButtonWidget = undefined;
    key.init(@src(), .{}, opts);
    defer key.deinit();
    var result: ?desktop.chord_action.Action = null;
    for (dvui.events()) |*event| {
        if (!key.matchEvent(event) or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action == .press and mouse.button == .left) {
            event.handle(@src(), key.data());
            dvui.captureMouse(key.data(), event.num);
            dvui.focusWidget(key.data().id, null, null);
            view.drag = try desktop.chord_action.Action.capture(model, .{ .tap_keycode = code, .tap_modifiers = .{ .left_shift = view.shift, .left_alt = view.option } });
            dvui.dragPreStart(.left, mouse.p, .{ .name = "key_chord", .cursor = .crosshair });
        } else if (mouse.action == .motion and dvui.captured(key.data().id)) {
            if (dvui.dragging(mouse.p, "key_chord")) |_| {
                event.handle(@src(), key.data());
                dvui.captureMouse(null, event.num);
            }
        } else if (mouse.action == .release and mouse.button == .left and dvui.captured(key.data().id)) {
            event.handle(@src(), key.data());
            dvui.captureMouse(null, event.num);
            dvui.dragEnd();
            result = view.drag;
            view.drag = null;
        } else if (mouse.action == .position) key.hover = true;
    }
    key.drawBackground();
    dvui.labelNoFmt(@src(), caption, .{ .align_x = 0.5, .align_y = 0.5 }, .{ .expand = .both, .gravity_x = 0.5, .gravity_y = 0.5, .font = opts.font, .color_text = opts.color_text, .padding = .{}, .margin = .{} });
    key.drawFocus();
    return result;
}
