//! Retained source drawer. Rendering reads no files and returns explicit intents.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
pub const Kind = enum { choose_root, attach, check, checkout, refresh, cancel, close };
pub const Action = struct { snapshot: [32]u8, kind: Kind, index: usize, root: [4096]u8, entry: [240]u8, ids: [1024]u8 };
pub const View = struct {
    root: [4096]u8 = @splat(0),
    entry: [240]u8 = @splat(0),
    ids: [1024]u8 = @splat(0),
    index: usize = 0,
    busy: bool = false,
    pub fn action(self: View, snapshot: [32]u8, kind: Kind) Action {
        return .{ .snapshot = snapshot, .kind = kind, .index = self.index, .root = self.root, .entry = self.entry, .ids = self.ids };
    }
};
pub fn draw(view: *View, model: *const desktop.model.Model, theme: ui.Theme, diagnostic: []const u8) !?Action {
    const captured = try model.id();
    const window = ui.editDrawer(@src(), theme, 900);
    defer window.deinit();
    var result: ?Action = null;
    {
        const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 0, .w = window.data().rect.w - 36, .h = window.data().rect.h - 112 } });
        defer area.deinit();
        dvui.label(@src(), "Callbacks · immutable source snapshots · external Zig editing", .{}, .{});
        dvui.label(@src(), "Attaching and refreshing read bytes only", .{}, .{});
        const root = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.root }, .placeholder = "Source root directory" }, .{ .expand = .horizontal });
        root.deinit();
        if (dvui.button(@src(), "Choose source root…", .{}, .{})) result = view.action(captured, .choose_root);
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.entry }, .placeholder = "Relative entry module, e.g. callbacks.zig" }, .{ .expand = .horizontal });
        entry.deinit();
        const ids = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.ids }, .placeholder = "Callback IDs, e.g. 1,2 (1–252)" }, .{ .expand = .horizontal });
        ids.deinit();
        if (dvui.button(@src(), "Attach callback ID and complete import closure", .{}, .{}) and result == null) result = view.action(captured, .attach);
        const doc = model.document();
        if (doc.callbacks.len > 0) {
            const names = try dvui.currentWindow().arena().alloc([]const u8, doc.callbacks.len);
            for (doc.callbacks, names) |callback, *name| name.* = callback.binding;
            view.index = @min(view.index, doc.callbacks.len - 1);
            _ = dvui.dropdown(@src(), names, .{ .choice = &view.index }, .{}, .{ .expand = .horizontal });
            const callback = doc.callbacks[view.index];
            dvui.label(@src(), "{s}; {d} source files; {d} registered IDs; layer constraints retained", .{ @tagName(callback.kind), callback.sources.len, callback.ids.len }, .{});
            if (callback.kind == .attached) {
                if (dvui.button(@src(), "Check external mirror against frozen snapshot", .{}, .{}) and result == null) result = view.action(captured, .check);
                if (dvui.button(@src(), "Checkout editable mirror", .{}, .{}) and result == null) result = view.action(captured, .checkout);
                if (dvui.button(@src(), "Refresh edited source snapshot (undoable)", .{}, .{}) and result == null) result = view.action(captured, .refresh);
            }
        }
        dvui.labelNoFmt(@src(), diagnostic, .{}, .{});
        if (view.busy) {
            dvui.label(@src(), "Preparation in progress · changed fields invalidate delivery", .{}, .{});
            if (dvui.button(@src(), "Cancel preparation", .{}, .{ .tag = "callback.cancel" }) and result == null) result = view.action(captured, .cancel);
        }
    }
    if (ui.button(theme, "Close", "callback.close", .{ .x = 0, .y = window.data().rect.h - 86, .w = 100, .h = 40 }) and result == null) result = view.action(captured, .close);
    return result;
}

/// Validate rendered fields again before capturing a worker-owned request.
pub fn validate(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (!std.meta.eql(action, view.action(try model.id(), action.kind))) return error.StaleCallbackAction;
}
pub fn request(action: Action, view: View, model: *const desktop.model.Model) !desktop.callback_editor.Request {
    try validate(action, view, model);
    const kind: desktop.callback_editor.Kind = switch (action.kind) {
        .attach => .attach,
        .check => .check,
        .refresh => .refresh,
        else => return error.InvalidCallbackIntent,
    };
    var ids: [252]u8 = undefined;
    var count: usize = 0;
    if (kind == .attach) {
        var parts = std.mem.splitScalar(u8, std.mem.sliceTo(&action.ids, 0), ',');
        while (parts.next()) |part| {
            if (count == ids.len) return error.InvalidCallback;
            const id = try std.fmt.parseInt(u8, std.mem.trim(u8, part, " \t"), 10);
            if (id == 0 or id > 252 or std.mem.indexOfScalar(u8, ids[0..count], id) != null) return error.InvalidCallback;
            ids[count] = id;
            count += 1;
        }
    }
    return desktop.callback_editor.Request.capture(model, kind, action.index, std.mem.sliceTo(&action.entry, 0), ids[0..count], &.{});
}
