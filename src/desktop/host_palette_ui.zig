//! Retained OS keyboard chord source; injected owned previews only.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const Chord = desktop.chord_action.Action;

pub const View = struct {
    shift: bool = false,
    option: bool = false,
    drag: ?Chord = null,
    source_revision: ?u64 = null,
};

/// The theme of a modifier toggle, highlighted while it is on.
fn toggleTheme(theme: ui.Theme, on: bool) ui.Theme {
    var result = theme;
    if (on) {
        result.control = theme.accent;
        result.text = ui.color(0xFFFFFF);
    }
    return result;
}

fn cancelDrag(view: *View) void {
    view.drag = null;
    if (dvui.dragName("key_chord")) dvui.dragEnd();
}

pub fn draw(view: *View, model: *const desktop.model.Model, cache: *const desktop.host_palette.Cache, theme: ui.Theme) !?Chord {
    const box = ui.panel(theme, .os);
    defer box.deinit();
    ui.label(theme, "OS keyboard", .{ .x = 20, .y = 18, .w = 205, .h = 25 }, 19);
    ui.label(theme, cache.source_id, .{ .x = 225, .y = 23, .w = 320, .h = 25 }, 12);
    if (ui.button(toggleTheme(theme, view.shift), "Shift", "os.shift", .{ .x = 622, .y = 15, .w = 70, .h = 33 })) view.shift = !view.shift;
    const option = if (cache.host == .macos) "Option" else "Alt";
    const option_bounds: dvui.Rect = .{ .x = 699, .y = 15, .w = 73, .h = 33 };
    if (ui.button(toggleTheme(theme, view.option), option, "os.option", option_bounds)) view.option = !view.option;
    // A drag started from an older input source preview no longer matches its captions.
    if (view.source_revision != null and view.source_revision.? != cache.revision) cancelDrag(view);
    view.source_revision = cache.revision;
    if (view.drag) |drag| drag.validate(model) catch cancelDrag(view);
    var result: ?Chord = null;
    for (desktop.host_palette.rows, 0..) |row, ri| {
        var x: f32 = 14;
        for (row, 0..) |key, ki| {
            const caption = cache.caption(key.code, view.shift, view.option);
            const length = std.unicode.utf8CountCodepoints(caption) catch caption.len;
            const size: f32 = if (length > 3) 12 else 18;
            const bounds: dvui.Rect = .{ .x = x, .y = 58 + @as(f32, @floatFromInt(ri)) * 38, .w = 47.5 * key.units - 3, .h = 35 };
            var opts = ui.options(theme, bounds, size);
            opts.padding = .all(2);
            opts.id_extra = ri * 100 + ki;
            opts.background = true;
            opts.gravity_x = 0.5;
            opts.gravity_y = 0.5;
            opts.border = .all(1);
            opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "os.key.{d}", .{key.code});
            if (try dragSource(view, model, key.code, caption, size, opts)) |action| {
                if (result == null) result = action;
            }
            x += 47.5 * key.units;
        }
    }
    return result;
}

/// A key that starts a chord drag on press. Returns the chord when the drag is
/// released on the key itself instead of on a drop target.
fn dragSource(view: *View, model: *const desktop.model.Model, code: u8, caption: []const u8, size: f32, opts: dvui.Options) !?Chord {
    var key: dvui.ButtonWidget = undefined;
    key.init(@src(), .{}, opts);
    defer key.deinit();
    var result: ?Chord = null;
    for (dvui.events()) |*event| {
        if (!key.matchEvent(event) or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action == .press and mouse.button == .left) {
            event.handle(@src(), key.data());
            dvui.captureMouse(key.data(), event.num);
            dvui.focusWidget(key.data().id, null, null);
            view.drag = try Chord.capture(model, .{
                .tap_keycode = code,
                .tap_modifiers = .{ .left_shift = view.shift, .left_alt = view.option },
            });
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
    const content = key.data().contentRect();
    const tint = opts.color_text.?.color;
    ui.caption(caption, .{ .w = content.w, .h = content.h }, .{
        .color = tint,
        .secondary = tint,
        .size = size,
        .id_extra = opts.id_extra orelse 0,
    });
    key.drawFocus();
    return result;
}
