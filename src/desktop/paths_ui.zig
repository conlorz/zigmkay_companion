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

    /// Captures the current fields so the caller can detect edits made after drawing.
    pub fn action(self: View, snapshot: [32]u8, kind: Kind) Action {
        return .{ .snapshot = snapshot, .kind = kind, .project = self.project, .exported = self.exported };
    }
};

pub const Frame = struct {
    exported: ?[32]u8 = null,
    can_choose: bool = false,
    recovery_available: bool = false,
    overlay_available: bool = false,
    busy: bool = false,
};

/// Requests `kind` when `clicked`, unless an earlier control already requested one.
fn offer(result: *?Action, view: *const View, snapshot: [32]u8, clicked: bool, kind: Kind) void {
    if (clicked and result.* == null) result.* = view.action(snapshot, kind);
}

/// A button that is grayed out and inert unless `available`.
fn optionalButton(src: std.builtin.SourceLocation, text: []const u8, available: bool) bool {
    return dvui.button(src, text, .{ .grayed = !available }, .{}) and available;
}

pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame, theme: ui.Theme, diagnostic: []const u8) !?Action {
    const captured = try model.id();
    const window = ui.editDrawer(@src(), theme, 800);
    defer window.deinit();
    const size = window.data().rect;
    var result: ?Action = null;
    {
        const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 0, .w = size.w - 36, .h = size.h - 112 } });
        defer area.deinit();
        dvui.label(@src(), "Project directory · atomic project and immutable source bundles", .{}, .{});
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.project } }, .{ .expand = .horizontal });
        entry.deinit();
        offer(&result, view, captured, optionalButton(@src(), "Choose project folder…", frame.can_choose), .choose_project);
        offer(&result, view, captured, dvui.button(@src(), "Open", .{}, .{}), .open);
        const discard = model.dirty() and dvui.button(@src(), "Discard unsaved changes and open", .{}, .{});
        offer(&result, view, captured, discard, .open_discard);
        offer(&result, view, captured, dvui.button(@src(), "Save", .{}, .{}), .save);
        dvui.label(@src(), "Owned export directory · existing different files are preserved", .{}, .{});
        const exported = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.exported } }, .{ .expand = .horizontal });
        exported.deinit();
        offer(&result, view, captured, optionalButton(@src(), "Choose export folder…", frame.can_choose), .choose_export);
        offer(&result, view, captured, dvui.button(@src(), "Export Zig", .{}, .{}), .export_zig);
        try drawAssessment(model, frame, captured);
        offer(&result, view, captured, optionalButton(@src(), "Separate overlay", frame.overlay_available), .overlay);
        offer(&result, view, captured, optionalButton(@src(), "Restore recovery draft", frame.recovery_available), .restore);
        dvui.labelNoFmt(@src(), diagnostic, .{}, .{});
        if (frame.busy) {
            dvui.label(@src(), "Project operation in progress · editing invalidates its result", .{}, .{});
            offer(&result, view, captured, dvui.button(@src(), "Cancel project operation", .{}, .{ .tag = "file.cancel" }), .cancel);
        }
    }
    const close: dvui.Rect = .{ .x = 0, .y = size.h - 86, .w = 100, .h = 40 };
    offer(&result, view, captured, ui.button(theme, "Close", "file.close", close), .close);
    return result;
}

/// Draft and export identities, recovery reachability and unreachable layers.
fn drawAssessment(model: *const desktop.model.Model, frame: Frame, captured: [32]u8) !void {
    dvui.label(@src(), "Draft snapshot: {s}", .{std.fmt.bytesToHex(captured, .lower)}, .{});
    if (frame.exported) |id| {
        const state = if (std.mem.eql(u8, &id, &captured)) "matches draft" else "is stale";
        dvui.label(@src(), "Export {s}: {s} · device identity requires verification", .{ state, std.fmt.bytesToHex(id, .lower) }, .{});
    }
    const advisory = try project.assessment.assess(model.document());
    const summary = .{ advisory.recovery_found, advisory.callbacks_require_review };
    dvui.label(@src(), "Declarative recovery action reachable: {} · callbacks require review: {}", summary, .{});
    for (model.document().layers, 0..) |layer, index| {
        if (!advisory.reachable[index]) dvui.label(
            @src(),
            "Layer {s}: no declarative path from Base",
            .{layer.name},
            .{ .id_extra = index },
        );
    }
}

pub fn validate(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (!std.meta.eql(action, view.action(try model.id(), action.kind))) return error.StaleProjectAction;
}

/// A completed save acknowledges disk IO for the same path, independently of edits.
pub fn validateCompletion(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (action.kind != .save) return validate(action, view, model);
    if (!std.meta.eql(action.project, view.project)) return error.StaleProjectAction;
}

pub fn request(
    action: Action,
    view: View,
    model: *const desktop.model.Model,
    selected_board: ?project.Board,
) !desktop.project_files.Request {
    try validate(action, view, model);
    const target = std.mem.sliceTo(&action.project, 0);
    const board = selected_board orelse model.board;
    return switch (action.kind) {
        .open => desktop.project_files.Request.openForBoard(model, target, board),
        .open_discard => desktop.project_files.Request.openDiscardConfirmed(model, target, board),
        .save => desktop.project_files.Request.capture(model, .save, target),
        .export_zig => desktop.project_files.Request.capture(model, .export_zig, std.mem.sliceTo(&action.exported, 0)),
        else => error.InvalidProjectIntent,
    };
}
