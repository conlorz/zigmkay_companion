//! Retained editor toolbar over explicit profile inventory and build capabilities.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
pub const Profile = struct { id: [8]u8, name: []const u8 };
pub const Frame = struct {
    board_name: []const u8,
    connection: []const u8,
    profiles: []const Profile,
    build_status: []const u8 = "",
    can_build: bool = false,
    can_flash: bool = false,
};
pub const View = struct { light: bool = false };
pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame) !?desktop.editor_dispatch.Request {
    const theme = ui.Theme.get(view.light);
    const box = ui.panel(theme, .toolbar);
    defer box.deinit();
    const doc = model.document();
    var result: ?desktop.editor_dispatch.Request = null;
    ui.label(theme, "Zigmkay", .{ .x = 20, .y = 21, .w = 140, .h = 30 }, 23);
    ui.label(theme, "Keyboard", .{ .x = 140, .y = 7, .w = 85, .h = 18 }, 11);
    ui.label(theme, frame.board_name, .{ .x = 140, .y = 25, .w = 80, .h = 30 }, 13);
    ui.label(theme, frame.connection, .{ .x = 230, .y = 25, .w = 165, .h = 25 }, 12);
    if (frame.profiles.len != 0) {
        const names = try dvui.currentWindow().arena().alloc([]const u8, frame.profiles.len);
        var choice: usize = 0;
        var found = false;
        for (frame.profiles, names, 0..) |profile, *name, index| {
            name.* = profile.name;
            if (std.mem.eql(u8, &profile.id, &doc.profile_id)) {
                choice = index;
                name.* = doc.name;
                found = true;
            }
        }
        if (found) {
            if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, ui.options(theme, .{ .x = 405, .y = 16, .w = 270, .h = 36 }, 14))) result = try desktop.editor_dispatch.Request.capture(model, .{ .profile = frame.profiles[choice].id });
        } else ui.label(theme, doc.name, .{ .x = 405, .y = 16, .w = 270, .h = 36 }, 14);
    } else ui.label(theme, doc.name, .{ .x = 405, .y = 16, .w = 270, .h = 36 }, 14);
    if (model.dirty()) ui.label(theme, "Unsaved", .{ .x = 686, .y = 27, .w = 85, .h = 23 }, 12);
    if (ui.button(theme, "Open / Export", "file.paths", .{ .x = 775, .y = 16, .w = 130, .h = 36 }) and result == null) result = try desktop.editor_dispatch.Request.capture(model, .{ .open = .paths });
    if (ui.buttonEnabled(theme, "Undo", "edit.undo", .{ .x = 920, .y = 16, .w = 68, .h = 36 }, model.undo_stack.items.len != 0) and result == null) result = try desktop.editor_dispatch.Request.capture(model, .undo);
    if (ui.buttonEnabled(theme, "Redo", "edit.redo", .{ .x = 996, .y = 16, .w = 68, .h = 36 }, model.redo_stack.items.len != 0) and result == null) result = try desktop.editor_dispatch.Request.capture(model, .redo);
    if (ui.button(theme, "Save", "file.save", .{ .x = 1078, .y = 16, .w = 76, .h = 36 }) and result == null) result = try desktop.editor_dispatch.Request.capture(model, .save);
    if (ui.buttonEnabled(theme, "Build", "firmware.build", .{ .x = 1166, .y = 16, .w = 110, .h = 36 }, frame.can_build) and result == null) result = try desktop.editor_dispatch.Request.capture(model, .build);
    if (ui.buttonEnabled(theme, "Flash", "firmware.inspect", .{ .x = 1288, .y = 16, .w = 110, .h = 36 }, frame.can_flash) and result == null) result = try desktop.editor_dispatch.Request.capture(model, .flash);
    if (frame.build_status.len != 0) ui.label(theme, frame.build_status, .{ .x = 1166, .y = 52, .w = 230, .h = 14 }, 10);
    if (ui.button(theme, if (view.light) "Dark" else "Light", "theme.toggle", .{ .x = 1410, .y = 16, .w = 100, .h = 36 })) view.light = !view.light;
    return result;
}
