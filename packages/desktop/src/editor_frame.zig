//! Native frame composition. Document dispatch happens after retained controls draw.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const toolbar = @import("toolbar-ui");
const layers = @import("layer-ui");
const keyboard = @import("keyboard-ui");
const host = @import("host-palette-ui");
const inspector = @import("inspector-ui");
const combos = @import("combo-ui");
const callbacks = @import("callback-ui");
const paths = @import("paths-ui");
const encoders = @import("encoder-ui");
const dispatch = desktop.editor_dispatch;
pub const Frame = struct { toolbar: toolbar.Frame, keyboard: keyboard.Frame, host: *const desktop.host_palette.Cache, paths: paths.Frame = .{} };
pub const View = struct {
    scroll: dvui.ScrollInfo = .{ .horizontal = .auto },
    toolbar: toolbar.View = .{},
    layers: layers.View = .{},
    keyboard: keyboard.View = .{},
    host: host.View = .{},
    inspector: inspector.View = .{},
    modal: enum { none, combo, callback, paths, encoders } = .none,
    combo: ?desktop.combo_editor.Session = null,
    encoders: ?desktop.encoder_editor.Session = null,
    callback: callbacks.View = .{},
    paths: paths.View = .{},
    diagnostic: [512]u8 = @splat(0),
    pub fn report(self: *View, failure: anyerror) void {
        self.diagnostic = @splat(0);
        const name = @errorName(failure);
        const len = @min(name.len, self.diagnostic.len - 1);
        @memcpy(self.diagnostic[0..len], name[0..len]);
    }
};
pub const Result = union(enum) { effect: dispatch.Effect, callback: callbacks.Action, paths: paths.Action };
pub fn draw(view: *View, owner: *dispatch.State, model: *desktop.model.Model, frame: Frame) !Result {
    var stale = false;
    owner.sync(model) catch |err| switch (err) {
        error.StaleInspectorSession => stale = true,
        else => return err,
    };
    const theme = ui.Theme.get(view.toolbar.light);
    dvui.themeSet(if (view.toolbar.light) dvui.Theme.builtin.adwaita_light else dvui.Theme.builtin.adwaita_dark);
    // Retained panels use a fixed design canvas. Scroll the canvas rather than
    // clipping controls when the host window is smaller than that design.
    const scroll = dvui.scrollArea(@src(), .{ .scroll_info = &view.scroll }, .{ .expand = .both, .padding = .{}, .border = .{}, .background = false });
    defer scroll.deinit();
    const canvas = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = @max(1536, dvui.windowRect().w), .h = @max(1024, dvui.windowRect().h) }, .padding = .{}, .margin = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
    defer canvas.deinit();
    var requested = try toolbar.draw(&view.toolbar, model, frame.toolbar);
    if (try layers.draw(&view.layers, model, theme)) |action| if (requested == null) {
        requested = dispatch.Request.fromLayer(action, model);
    };
    // Validate before forwarding an old drag into either target panel.
    if (view.host.source_revision != null and view.host.source_revision.? != frame.host.revision) {
        view.host.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    }
    if (view.host.drag) |drag| drag.validate(model) catch {
        view.host.drag = null;
        if (dvui.dragName("key_chord")) dvui.dragEnd();
    };
    view.keyboard.drag = view.host.drag;
    const physical = try keyboard.draw(&view.keyboard, model, frame.keyboard, theme, view.toolbar.light);
    if (physical) |action| switch (action) {
        .select => |selected| if (requested == null) {
            requested = dispatch.Request.fromKey(selected);
        },
        .chord => |chord| {
            view.host.drag = null;
            if (requested == null) requested = dispatch.Request.fromChord(chord);
        },
        .combo, .encoders => |captured| if (requested == null) {
            var opened = dispatch.Request.fromKey(captured);
            opened.intent = .{ .open = if (action == .combo) .combo else .encoders };
            requested = opened;
        },
    };
    var inspector_result: ?desktop.inspector_action.Action = null;
    var recovery: ?dispatch.Recovery = null;
    if (stale) {
        const rendered = try owner.recovery(model);
        const box = ui.panel(theme, .inspector);
        defer box.deinit();
        dvui.label(@src(), "Project changed · staged edits are preserved", .{}, .{});
        for (owner.inspector.selected, 0..) |selected, index| if (selected) {
            var summary: [1024]u8 = undefined;
            dvui.label(@src(), "{s}: {s}", .{ owner.inspector.key_storage[index], desktop.labels.action(owner.inspector.drafts[index], &summary) }, .{});
        };
        if (dvui.button(@src(), "Discard stale staged edits", .{}, .{})) recovery = rendered;
    } else {
        view.inspector.pending = owner.pending != null;
        view.inspector.close_requested = owner.close_requested != null;
        view.inspector.drag_chord = if (view.host.drag) |drag| drag.chord else null;
        inspector_result = try inspector.draw(&owner.inspector, model, &view.inspector, theme, view.toolbar.light);
        if (view.host.drag != null and view.inspector.drag_chord == null) view.host.drag = null;
    }
    if (try host.draw(&view.host, model, frame.host, theme)) |action| if (requested == null) {
        requested = dispatch.Request.fromChord(action);
    };
    {
        const box = ui.panel(theme, .testing);
        defer box.deinit();
        ui.label(theme, "Try it out", .{ .x = 18, .y = 12, .w = 200, .h = 24 }, 16);
        ui.label(theme, "Choose OS typing or explicitly prepare the draft runner", .{ .x = 18, .y = 49, .w = 750, .h = 24 }, 12);
        if (ui.button(theme, "Open tutor", "practice.open", .{ .x = 623, .y = 9, .w = 150, .h = 31 }) and requested == null) requested = try dispatch.Request.capture(model, .{ .open = .practice });
    }
    {
        const box = ui.panel(theme, .callbacks);
        defer box.deinit();
        ui.label(theme, "Callbacks", .{ .x = 18, .y = 12, .w = 200, .h = 24 }, 16);
        ui.label(theme, if (model.document().callbacks.len == 0) "No attached source · external Zig files" else "Source snapshot preserved · refresh explicitly", .{ .x = 18, .y = 49, .w = 750, .h = 24 }, 12);
        if (ui.button(theme, "Manage source", "callback.attach", .{ .x = 623, .y = 9, .w = 150, .h = 31 }) and requested == null) requested = try dispatch.Request.capture(model, .{ .open = .callback });
    }
    const diagnostic = std.mem.sliceTo(&view.diagnostic, 0);
    if (diagnostic.len != 0) ui.label(theme, diagnostic, .{ .x = 294, .y = 490, .w = 760, .h = 25 }, 12);
    var combo_result: ?combos.Result = null;
    var callback_result: ?callbacks.Action = null;
    var paths_result: ?paths.Action = null;
    var encoder_result: ?encoders.Result = null;
    switch (view.modal) {
        .none => {},
        .combo => combo_result = try combos.draw(&view.combo.?, model, theme, diagnostic),
        .callback => callback_result = try callbacks.draw(&view.callback, model, theme, diagnostic),
        .paths => paths_result = try paths.draw(&view.paths, model, frame.paths, theme, diagnostic),
        .encoders => encoder_result = try encoders.draw(&view.encoders.?, model, theme, diagnostic),
    }
    // Every document mutation below happens after drawing all retained controls.
    if (recovery) |rendered| {
        try owner.discardStale(model, rendered);
        return .{ .effect = .none };
    }
    if (combo_result) |action| {
        switch (action) {
            .close => {
                view.modal = .none;
                view.combo = null;
            },
            .action => |rendered| {
                if (stale) return .{ .effect = .none };
                if (owner.inspector.dirty() or owner.pending != null) return error.PendingEditorRequest;
                try view.combo.?.dispatch(model, rendered);
            },
        }
        return .{ .effect = .none };
    }
    if (callback_result) |action| {
        try callbacks.validate(action, view.callback, model);
        if (action.kind == .close) {
            view.modal = .none;
            return .{ .effect = .none };
        }
        if (action.kind == .cancel) return .{ .callback = action };
        if (stale) return .{ .effect = .none };
        if (owner.inspector.dirty() or owner.pending != null) return error.PendingEditorRequest;
        return .{ .callback = action };
    }
    if (paths_result) |action| {
        try paths.validate(action, view.paths, model);
        if (action.kind == .close) {
            view.modal = .none;
            return .{ .effect = .none };
        }
        if (action.kind == .cancel) return .{ .paths = action };
        if (stale) return .{ .effect = .none };
        if (owner.inspector.dirty() or owner.pending != null) return error.PendingEditorRequest;
        return .{ .paths = action };
    }
    if (encoder_result) |action| {
        switch (action) {
            .close => {
                view.modal = .none;
                view.encoders = null;
            },
            .action => |rendered| {
                if (stale) return .{ .effect = .none };
                if (owner.inspector.dirty() or owner.pending != null) return error.PendingEditorRequest;
                try view.encoders.?.dispatch(model, rendered);
            },
        }
        return .{ .effect = .none };
    }
    if (stale or view.modal != .none) return .{ .effect = .none };
    const effect = if (inspector_result) |action| try owner.inspect(model, action) else if (requested) |captured| try owner.request(model, captured) else dispatch.Effect.none;
    if (effect == .open) switch (effect.open) {
        .combo => {
            view.combo = try desktop.combo_editor.Session.init(model);
            view.modal = .combo;
            return .{ .effect = .none };
        },
        .callback => {
            view.modal = .callback;
            return .{ .effect = .none };
        },
        .paths => {
            view.modal = .paths;
            return .{ .effect = .none };
        },
        .encoders => {
            view.encoders = try desktop.encoder_editor.Session.init(model);
            view.modal = .encoders;
            return .{ .effect = .none };
        },
        else => {},
    };
    return .{ .effect = effect };
}
