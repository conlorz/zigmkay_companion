//! Retained project/export drawer. Source and filesystem IO are caller-owned.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const project = @import("project");
const ui = @import("editor-ui");
pub const Kind = enum { choose_project, choose_export, open, open_discard, save, export_zig, restore, overlay, cancel, close };
pub const Action = struct { snapshot: [32]u8, kind: Kind, project: [4096]u8, exported: [4096]u8 };
pub const View = struct {
    project: [4096]u8 = @splat(0),
    exported: [4096]u8 = @splat(0),
    pub fn action(self: View, snapshot: [32]u8, kind: Kind) Action {
        return .{ .snapshot = snapshot, .kind = kind, .project = self.project, .exported = self.exported };
    }
};
pub const Frame = struct { exported: ?[32]u8 = null, can_choose: bool = false, recovery_available: bool = false, overlay_available: bool = false, busy: bool = false };
pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame, theme: ui.Theme, diagnostic: []const u8) !?Action {
    const captured = try model.id();
    const window = ui.editDrawer(@src(), theme, 800);
    defer window.deinit();
    var result: ?Action = null;
    {
        const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 0, .w = window.data().rect.w - 36, .h = window.data().rect.h - 112 } });
        defer area.deinit();
        dvui.label(@src(), "Project directory · atomic project and immutable source bundles", .{}, .{});
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.project } }, .{ .expand = .horizontal });
        entry.deinit();
        if (dvui.button(@src(), "Choose project folder…", .{ .grayed = !frame.can_choose }, .{}) and frame.can_choose) result = view.action(captured, .choose_project);
        if (dvui.button(@src(), "Open", .{}, .{}) and result == null) result = view.action(captured, .open);
        if (model.dirty() and dvui.button(@src(), "Discard unsaved changes and open", .{}, .{}) and result == null) result = view.action(captured, .open_discard);
        if (dvui.button(@src(), "Save", .{}, .{}) and result == null) result = view.action(captured, .save);
        dvui.label(@src(), "Owned export directory · existing different files are preserved", .{}, .{});
        const exported = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.exported } }, .{ .expand = .horizontal });
        exported.deinit();
        if (dvui.button(@src(), "Choose export folder…", .{ .grayed = !frame.can_choose }, .{}) and frame.can_choose and result == null) result = view.action(captured, .choose_export);
        if (dvui.button(@src(), "Export Zig", .{}, .{}) and result == null) result = view.action(captured, .export_zig);
        dvui.label(@src(), "Draft snapshot: {s}", .{std.fmt.bytesToHex(captured, .lower)}, .{});
        if (frame.exported) |id| dvui.label(@src(), "Export {s}: {s} · device identity requires verification", .{ if (std.mem.eql(u8, &id, &captured)) "matches draft" else "is stale", std.fmt.bytesToHex(id, .lower) }, .{});
        const advisory = try project.assessment.assess(model.document());
        dvui.label(@src(), "Declarative recovery action reachable: {} · callbacks require review: {}", .{ advisory.recovery_found, advisory.callbacks_require_review }, .{});
        for (model.document().layers, 0..) |layer, index| if (!advisory.reachable[index]) dvui.label(@src(), "Layer {s}: no declarative path from Base", .{layer.name}, .{ .id_extra = index });
        if (dvui.button(@src(), "Separate overlay", .{ .grayed = !frame.overlay_available }, .{}) and frame.overlay_available and result == null) result = view.action(captured, .overlay);
        if (dvui.button(@src(), "Restore recovery draft", .{ .grayed = !frame.recovery_available }, .{}) and frame.recovery_available and result == null) result = view.action(captured, .restore);
        dvui.labelNoFmt(@src(), diagnostic, .{}, .{});
        if (frame.busy) {
            dvui.label(@src(), "Project operation in progress · editing invalidates its result", .{}, .{});
            if (dvui.button(@src(), "Cancel project operation", .{}, .{ .tag = "file.cancel" }) and result == null) result = view.action(captured, .cancel);
        }
    }
    if (ui.button(theme, "Close", "file.close", .{ .x = 0, .y = window.data().rect.h - 86, .w = 100, .h = 40 }) and result == null) result = view.action(captured, .close);
    return result;
}
pub fn validate(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (!std.meta.eql(action, view.action(try model.id(), action.kind))) return error.StaleProjectAction;
}
pub fn request(action: Action, view: View, model: *const desktop.model.Model, selected_board: ?project.Board) !desktop.project_files.Request {
    try validate(action, view, model);
    const target = std.mem.sliceTo(&action.project, 0);
    return switch (action.kind) {
        .open => desktop.project_files.Request.openForBoard(model, target, selected_board orelse model.board),
        .open_discard => desktop.project_files.Request.openDiscardConfirmed(model, target, selected_board orelse model.board),
        .save => desktop.project_files.Request.capture(model, .save, target),
        .export_zig => desktop.project_files.Request.capture(model, .export_zig, std.mem.sliceTo(&action.exported, 0)),
        else => error.InvalidProjectIntent,
    };
}
