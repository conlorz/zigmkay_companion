//! Retained combo drawer; only its returned bound action can commit a document.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const forms = @import("action-form-ui");
pub const Result = union(enum) { close, action: desktop.combo_editor.Action };
pub fn draw(session: *desktop.combo_editor.Session, model: *const desktop.model.Model, theme: ui.Theme, diagnostic: []const u8) !?Result {
    const window = ui.editDrawer(@src(), theme, 900);
    defer window.deinit();
    dvui.label(@src(), "Combos · stable physical positions and stable layer references", .{}, .{});
    const height = window.data().rect.h;
    if (!try session.fresh(model)) {
        dvui.label(@src(), "Project changed · reopen the combo editor", .{}, .{});
        return if (ui.button(theme, "Close", "combo.close", .{ .x = 0, .y = height - 86, .w = 100, .h = 40 })) .close else null;
    }
    const doc = model.document();
    {
        const body = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 36, .w = window.data().rect.w - 36, .h = height - 160 } });
        defer body.deinit();
        {
            const row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer row.deinit();
            for (doc.combos, 0..) |combo, index| {
                const title = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} + {s}", .{ combo.key_ids[0], combo.key_ids[1] });
                if (dvui.button(@src(), title, .{}, .{ .id_extra = index })) try session.pick(model, index);
            }
        }
        if (dvui.button(@src(), "New combo", .{}, .{})) session.new();
        _ = dvui.dropdown(@src(), doc.key_ids, .{ .choice = &session.keys[0] }, .{}, .{ .expand = .horizontal });
        _ = dvui.dropdown(@src(), doc.key_ids, .{ .choice = &session.keys[1] }, .{}, .{ .expand = .horizontal });
        var layer_names: [15][]const u8 = undefined;
        for (doc.layers, 0..) |layer, index| layer_names[index] = layer.name;
        session.layer = @min(session.layer, doc.layers.len - 1);
        _ = dvui.dropdown(@src(), layer_names[0..doc.layers.len], .{ .choice = &session.layer }, .{}, .{ .expand = .horizontal });
        dvui.label(@src(), "Combo timeout (ms)", .{}, .{});
        _ = dvui.textEntryNumber(@src(), u16, .{ .value = &session.timeout }, .{});
        try forms.draw(&session.draft, doc);
    }
    var result: ?Result = null;
    if (ui.button(theme, "Save combo", "combo.save", .{ .x = 0, .y = height - 86, .w = 150, .h = 40 })) result = .{ .action = session.action(.save) };
    if (session.index != null and ui.button(theme, "Delete combo", "combo.delete", .{ .x = 160, .y = height - 86, .w = 150, .h = 40 }) and result == null) result = .{ .action = session.action(.delete) };
    dvui.labelNoFmt(@src(), diagnostic, .{}, .{ .rect = .{ .x = 0, .y = height - 120, .w = window.data().rect.w - 36, .h = 25 }, .color_text = .{ .color = theme.text } });
    if (ui.button(theme, "Close", "combo.close", .{ .x = 320, .y = height - 86, .w = 100, .h = 40 }) and result == null) result = .close;
    return result;
}
