//! Explicit SDL dummy/software interaction fixture. No native input source/devices.
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const project = @import("project");
const catalog = @import("catalog");
const editor = @import("editor-frame-ui");
const zkeymap = @import("zkeymap");
const Fixture = struct {
    pub fn keyToText(_: *@This(), input: zkeymap.KeyCodeFire) zkeymap.TextResult {
        var result: zkeymap.TextResult = .{};
        if (input.tap_keycode >= 4 and input.tap_keycode <= 29) {
            result.data[0] = 'a' + input.tap_keycode - 4;
            result.len = 1;
        }
        return result;
    }
};
const Observed = struct { result: editor.Result, key3: dvui.Rect.Physical, key4: dvui.Rect.Physical, host_b: dvui.Rect.Physical, callbacks: dvui.Rect.Physical, paths: dvui.Rect.Physical, paths_close: ?dvui.Rect.Physical, encoder_close: ?dvui.Rect.Physical, pending_keep: ?dvui.Rect.Physical, pending_discard: ?dvui.Rect.Physical, callback_close: ?dvui.Rect.Physical };
fn tagged(name: []const u8) ?dvui.Rect.Physical {
    return if (dvui.tagGet(name)) |tag| tag.rect else null;
}
fn frame(native: *Backend, window: *dvui.Window, view: *editor.View, owner: *desktop.editor_dispatch.State, model: *desktop.model.Model, labels: *const desktop.label_cache.LabelCache, host: *const desktop.host_palette.Cache, click: ?dvui.Rect.Physical) !Observed {
    try window.begin(native.nanoTime());
    errdefer _ = window.end(.{ .manage_backend = false }) catch {};
    if (click) |rect| {
        _ = try window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 } });
        _ = try window.addEventMouseButton(.left, .press);
        _ = try window.addEventMouseButton(.left, .release);
    }
    const doc = model.document();
    const result = try editor.draw(view, owner, model, .{
        .toolbar = .{ .board_name = "LK7", .connection = "Injected fixture", .profiles = &.{} },
        .keyboard = .{ .snapshot = try model.id(), .board_id = doc.board_id, .physical_layout = doc.physical_layout, .geometry = catalog.find("lk7").?.geometry, .labels = labels, .board_name = "LK7", .fidelity = "Curated schematic" },
        .host = host,
    });
    const observed = Observed{ .result = result, .key3 = tagged("key.select.3") orelse return error.MissingKeyTag, .key4 = tagged("key.select.4") orelse return error.MissingKeyTag, .host_b = tagged("os.key.5") orelse return error.MissingHostTag, .callbacks = tagged("callback.attach") orelse return error.MissingCallbackTag, .paths = tagged("file.paths") orelse return error.MissingPathsTag, .paths_close = tagged("file.close"), .encoder_close = tagged("encoder.close"), .pending_keep = tagged("pending.keep"), .pending_discard = tagged("pending.discard"), .callback_close = tagged("callback.close") };
    _ = try window.end(.{ .manage_backend = false });
    native.renderPresent();
    return observed;
}
test "composed editor handles selection pending keep/discard callback close and host assignment" {
    const t = std.testing;
    // The build runner pins dummy/software. Refuse accidentally interactive runs.
    const driver = std.c.getenv("SDL_VIDEODRIVER") orelse return error.DummyVideoRequired;
    if (!std.mem.eql(u8, std.mem.span(driver), "dummy")) return error.DummyVideoRequired;
    var native = try Backend.initWindow(.{ .io = t.io, .size = .{ .w = 1536, .h = 1024 }, .vsync = false, .title = "Zigmkay offline editor fixture", .hidden = true, .persist_window_geometry = false });
    defer native.deinit();
    var window = try dvui.Window.init(@src(), t.allocator, native.backend(), .{});
    defer window.deinit();
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var owner = try desktop.editor_dispatch.State.init(&model);
    defer owner.deinit();
    var fixture: Fixture = .{};
    var labels = try desktop.label_cache.buildProjectCache(t.allocator, &fixture, model.document());
    defer labels.deinit();
    var host = try desktop.host_palette.Cache.init(t.allocator, .macos, "Injected fixture", 1, &fixture);
    defer host.deinit();
    var view: editor.View = .{};
    var observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.key3);
    try t.expectEqual(@as(usize, 3), model.primary);
    // Refresh selection ownership before staging a draft.
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    owner.inspector.mutate(.{ .tap_usage = 7 });
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.key4);
    try t.expect(observed.result.effect == .pending);
    try t.expectEqual(@as(usize, 3), model.primary);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.pending_keep orelse return error.MissingPendingTag);
    try t.expect(owner.pending == null and owner.inspector.dirty());
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.key4);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.pending_discard orelse return error.MissingPendingTag);
    try t.expectEqual(@as(usize, 4), model.primary);
    try t.expectEqual(@as(usize, 0), model.undo_stack.items.len);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.callbacks);
    try t.expect(view.modal == .callback);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.callback_close orelse return error.MissingModalTag);
    try t.expect(view.modal == .none);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.paths);
    try t.expect(view.modal == .paths);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.paths_close orelse return error.MissingModalTag);
    try t.expect(view.modal == .none);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    _ = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.host_b);
    try t.expectEqual(@as(u8, 5), model.action().?.tap_only.key_press.?.tap_keycode);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    view.toolbar.light = true;
    _ = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    try t.expect(!window.theme.dark);
    view.toolbar.light = false;
    _ = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    try t.expect(window.theme.dark);
    view.encoders = try desktop.encoder_editor.Session.init(&model);
    view.modal = .encoders;
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    _ = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.encoder_close orelse return error.MissingModalTag);
    try t.expect(view.modal == .none and view.encoders == null);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    // A laptop-sized viewport must expose the lower action after scrolling.
    try t.expect(Backend.c.SDL_SetWindowSize(native.window, 1152, 600));
    _ = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    try t.expect(view.scroll.virtual_size.h >= 1024);
    try t.expect(view.scroll.viewport.h < view.scroll.virtual_size.h);
    view.scroll.scrollToOffset(.vertical, std.math.floatMax(f32));
    observed = try frame(&native, &window, &view, &owner, &model, &labels, &host, null);
    try t.expect(observed.callbacks.y >= 0 and observed.callbacks.y + observed.callbacks.h <= 600);
    _ = try frame(&native, &window, &view, &owner, &model, &labels, &host, observed.callbacks);
    try t.expect(view.modal == .callback);
}
