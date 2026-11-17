//! Retained layer sidebar; draw returns one immutable document-operation intent.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
pub const View = struct {
    observed: ?[32]u8 = null,
    selected: ?@import("project").LayerId = null,
    name: [129]u8 = @splat(0),
};
// Exact layer palette retained from the reference editor/key component.
const palette = [_]dvui.Color{ ui.color(0xFF3232), ui.color(0x3296FF), ui.color(0xFF9632), ui.color(0x96FF32), ui.color(0xB432FF), ui.color(0x32FFC8), ui.color(0x32FF32), ui.color(0xFFE632), ui.color(0xFF32B4) };
pub fn draw(view: *View, model: *const desktop.model.Model, theme: ui.Theme) !?desktop.layer_editor.Action {
    const digest = try model.id();
    const doc = model.document();
    const selected = doc.layers[model.layer];
    if (view.observed == null or !std.mem.eql(u8, &view.observed.?, &digest) or view.selected != selected.id) {
        view.name = @splat(0);
        @memcpy(view.name[0..selected.name.len], selected.name);
        view.observed = digest;
        view.selected = selected.id;
    }
    const box = ui.panel(theme, .sidebar);
    defer box.deinit();
    var result: ?desktop.layer_editor.Action = null;
    ui.label(theme, "Layers", .{ .x = 16, .y = 18, .w = 160, .h = 25 }, 19);
    if (ui.button(theme, "+", "layer.add", .{ .x = 196, .y = 13, .w = 36, .h = 33 })) result = try desktop.layer_editor.capture(model, .add, selected.id, "");
    {
        const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 11, .y = 52, .w = 225, .h = 725 }, .padding = .{}, .margin = .{}, .background = false });
        defer area.deinit();
        const list = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 224, .h = @as(f32, @floatFromInt(doc.layers.len)) * 67 }, .padding = .{}, .background = false });
        defer list.deinit();
        for (doc.layers, 0..) |layer, i| {
            const y = @as(f32, @floatFromInt(i)) * 67;
            const c = palette[i % palette.len];
            var opts = ui.options(theme, .{ .x = 0, .y = y, .w = 224, .h = 59 }, 15);
            opts.id_extra = i;
            opts.tag = try std.fmt.allocPrint(dvui.currentWindow().arena(), "layer.select.{d}", .{layer.id});
            opts.background = true;
            opts.color_fill = .{ .color = if (model.layer == i) c else .{ .r = @intCast((@as(u16, theme.panel.r) * 4 + c.r) / 5), .g = @intCast((@as(u16, theme.panel.g) * 4 + c.g) / 5), .b = @intCast((@as(u16, theme.panel.b) * 4 + c.b) / 5), .a = 255 } };
            opts.color_text = .{ .color = if (model.layer == i) ui.color(0x10151C) else theme.text };
            opts.border = .all(if (model.layer == i) 2 else 0);
            {
                var background = opts;
                background.id_extra = 1000 + i;
                background.tag = null;
                const card = dvui.box(@src(), .{}, background);
                card.deinit();
            }
            opts.background = false;
            opts.border = .{};
            opts.rect.?.w = 168;
            if (dvui.button(@src(), "", .{}, opts) and result == null) result = try desktop.layer_editor.capture(model, .select, layer.id, "");
            var badge = ui.options(theme, .{ .x = 0, .y = y, .w = 48, .h = 59 }, 24);
            badge.color_fill = .{ .color = c };
            badge.color_text = .{ .color = ui.color(0x10151C) };
            badge.background = true;
            badge.id_extra = i;
            dvui.label(@src(), "{d}", .{i}, badge);
            var text_theme = theme;
            if (model.layer == i) text_theme.text = ui.color(0x10151C);
            ui.label(text_theme, layer.name, .{ .x = 59, .y = y + 20, .w = 115, .h = 24 }, 14);
            const dup = try std.fmt.allocPrint(dvui.currentWindow().arena(), "layer.duplicate.{d}", .{layer.id});
            if (ui.button(theme, "+", dup, .{ .x = 170, .y = y + 14, .w = 25, .h = 30 }) and result == null) result = try desktop.layer_editor.capture(model, .duplicate, layer.id, "");
            const del = try std.fmt.allocPrint(dvui.currentWindow().arena(), "layer.delete.{d}", .{layer.id});
            if (ui.button(theme, "×", del, .{ .x = 197, .y = y + 14, .w = 25, .h = 30 }) and result == null) result = try desktop.layer_editor.capture(model, .delete, layer.id, "");
        }
    }
    ui.label(theme, "Selected layer name", .{ .x = 16, .y = 804, .w = 220, .h = 23 }, 13);
    const rename = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.name } }, ui.options(theme, .{ .x = 16, .y = 832, .w = 215, .h = 34 }, 13));
    const enter = rename.enter_pressed;
    rename.deinit();
    const rename_clicked = ui.button(theme, "Rename", "layer.rename", .{ .x = 16, .y = 876, .w = 90, .h = 33 });
    if ((enter or rename_clicked) and result == null) result = try desktop.layer_editor.capture(model, .rename, selected.id, std.mem.sliceTo(&view.name, 0));
    return result;
}
