//! Retained layer sidebar; draw returns one immutable document-operation intent.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const LayerId = @import("project").LayerId;

pub const View = struct {
    observed: ?[32]u8 = null,
    selected: ?LayerId = null,
    name: [129]u8 = @splat(0),
};

const row_pitch: f32 = 67;
const dark_text = ui.color(0x10151C);

pub fn draw(view: *View, model: *const desktop.model.Model, theme: ui.Theme) !?desktop.layer_editor.Action {
    const digest = try model.id();
    const doc = model.document();
    const selected = doc.layers[model.layer];
    // Reload the name field when the document or the selected layer changes.
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
    if (ui.button(theme, "+", "layer.add", .{ .x = 196, .y = 13, .w = 36, .h = 33 })) {
        result = try desktop.layer_editor.capture(model, .add, selected.id, "");
    }
    {
        const area = dvui.scrollArea(@src(), .{}, .{
            .rect = .{ .x = 11, .y = 52, .w = 225, .h = 725 },
            .padding = .{},
            .margin = .{},
            .background = false,
        });
        defer area.deinit();
        const list = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 224, .h = @as(f32, @floatFromInt(doc.layers.len)) * row_pitch },
            .padding = .{},
            .background = false,
        });
        defer list.deinit();
        for (doc.layers, 0..) |layer, i| {
            if (try drawRow(model, layer, i, theme)) |action| {
                if (result == null) result = try desktop.layer_editor.capture(model, action, layer.id, "");
            }
        }
    }
    ui.label(theme, "Selected layer name", .{ .x = 16, .y = 804, .w = 220, .h = 23 }, 13);
    const rename = dvui.textEntry(
        @src(),
        .{ .text = .{ .buffer = &view.name } },
        ui.options(theme, .{ .x = 16, .y = 832, .w = 215, .h = 34 }, 13),
    );
    const enter = rename.enter_pressed;
    rename.deinit();
    const rename_clicked = ui.button(theme, "Rename", "layer.rename", .{ .x = 16, .y = 876, .w = 90, .h = 33 });
    if ((enter or rename_clicked) and result == null) {
        result = try desktop.layer_editor.capture(model, .rename, selected.id, std.mem.sliceTo(&view.name, 0));
    }
    return result;
}

/// Mixes one part of `accent` into four parts of the panel color.
fn tint(panel: dvui.Color, accent: dvui.Color) dvui.Color {
    return .{
        .r = @intCast((@as(u16, panel.r) * 4 + accent.r) / 5),
        .g = @intCast((@as(u16, panel.g) * 4 + accent.g) / 5),
        .b = @intCast((@as(u16, panel.b) * 4 + accent.b) / 5),
        .a = 255,
    };
}

/// Draws one layer card: a select area, the index badge, the name and the
/// duplicate and delete buttons. Returns the operation the user requested.
fn drawRow(model: *const desktop.model.Model, layer: anytype, i: usize, theme: ui.Theme) !?desktop.layer_editor.Kind {
    const arena = dvui.currentWindow().arena();
    const y = @as(f32, @floatFromInt(i)) * row_pitch;
    const accent = ui.layerColor(theme, i);
    const current = model.layer == i;
    var requested: ?desktop.layer_editor.Kind = null;
    var opts = ui.options(theme, .{ .x = 0, .y = y, .w = 224, .h = 59 }, 15);
    opts.id_extra = i;
    opts.tag = try std.fmt.allocPrint(arena, "layer.select.{d}", .{layer.id});
    opts.background = true;
    opts.color_fill = .{ .color = if (current) accent else tint(theme.panel, accent) };
    opts.color_text = .{ .color = if (current) dark_text else theme.text };
    opts.border = .all(if (current) 2 else 0);
    {
        var background = opts;
        background.id_extra = 1000 + i;
        background.tag = null;
        const card = dvui.box(@src(), .{}, background);
        card.deinit();
    }
    // The select button leaves room for the duplicate and delete buttons.
    opts.background = false;
    opts.border = .{};
    opts.rect.?.w = 168;
    if (dvui.button(@src(), "", .{}, opts)) requested = .select;
    var badge = ui.options(theme, .{ .x = 0, .y = y, .w = 48, .h = 59 }, 24);
    badge.color_fill = .{ .color = accent };
    badge.color_text = .{ .color = dark_text };
    badge.background = true;
    badge.id_extra = i;
    dvui.label(@src(), "{d}", .{i}, badge);
    var text_theme = theme;
    if (current) text_theme.text = dark_text;
    ui.label(text_theme, layer.name, .{ .x = 59, .y = y + 20, .w = 115, .h = 24 }, 14);
    const duplicate = try std.fmt.allocPrint(arena, "layer.duplicate.{d}", .{layer.id});
    if (ui.button(theme, "+", duplicate, .{ .x = 170, .y = y + 14, .w = 25, .h = 30 }) and requested == null) requested = .duplicate;
    const delete = try std.fmt.allocPrint(arena, "layer.delete.{d}", .{layer.id});
    if (ui.button(theme, "×", delete, .{ .x = 197, .y = y + 14, .w = 25, .h = 30 }) and requested == null) requested = .delete;
    return requested;
}
