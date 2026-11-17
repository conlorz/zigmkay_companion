//! Retained editor toolbar over explicit profile inventory and build capabilities.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const dispatch = desktop.editor_dispatch;

pub const Profile = struct { id: [8]u8, name: []const u8 };

pub const Frame = struct {
    board_name: []const u8,
    connection: []const u8,
    profiles: []const Profile,
    build_status: []const u8 = "",
    can_build: bool = false,
    can_flash: bool = false,
    flash_status: []const u8 = "",
    flash_active: bool = false,
    build_active: bool = false,
    first_build: bool = false,
    flash_succeeded: bool = false,
    flash_failed: bool = false,
    diagnostic: []const u8 = "",
    now_ms: u64 = 0,
};

pub const View = struct {
    light: bool = false,
    auto_build: bool = false,
    details_open: bool = false,
    result_hash: u64 = 0,
    result_until: u64 = 0,
};

/// Captures `intent` when `clicked`, unless an earlier control already requested one.
fn offer(result: *?dispatch.Request, model: *const desktop.model.Model, clicked: bool, intent: dispatch.Intent) !void {
    if (clicked and result.* == null) result.* = try dispatch.Request.capture(model, intent);
}

pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame) !?dispatch.Request {
    const theme = ui.Theme.get(view.light);
    const box = ui.panel(theme, .toolbar);
    defer box.deinit();
    var result: ?dispatch.Request = null;
    ui.label(theme, "Zigmkay", .{ .x = 20, .y = 21, .w = 140, .h = 30 }, 23);
    const keyboards = ui.button(theme, "Keyboards", "keyboard.collection", .{ .x = 130, .y = 1, .w = 95, .h = 30 });
    try offer(&result, model, keyboards, .{ .open = .keyboards });
    ui.label(theme, frame.board_name, .{ .x = 135, .y = 33, .w = 90, .h = 18 }, 11);
    ui.label(theme, frame.connection, .{ .x = 230, .y = 25, .w = 165, .h = 25 }, 12);
    // Switching profiles replaces any earlier request.
    if (try drawProfile(model, frame.profiles, theme)) |id| result = try dispatch.Request.capture(model, .{ .profile = id });
    if (model.dirty()) ui.label(theme, "Unsaved", .{ .x = 650, .y = 27, .w = 70, .h = 23 }, 12);
    const paths = ui.button(theme, "Open / Export", "file.paths", .{ .x = 725, .y = 8, .w = 130, .h = 36 });
    try offer(&result, model, paths, .{ .open = .paths });
    const undo = ui.buttonEnabled(theme, "Undo", "edit.undo", .{ .x = 870, .y = 8, .w = 68, .h = 36 }, model.undo_stack.items.len != 0);
    try offer(&result, model, undo, .undo);
    const redo = ui.buttonEnabled(theme, "Redo", "edit.redo", .{ .x = 946, .y = 8, .w = 68, .h = 36 }, model.redo_stack.items.len != 0);
    try offer(&result, model, redo, .redo);
    try offer(&result, model, ui.button(theme, "Save", "file.save", .{ .x = 1028, .y = 8, .w = 76, .h = 36 }), .save);
    const build = ui.buttonEnabled(theme, "Build", "firmware.build", .{ .x = 1116, .y = 8, .w = 110, .h = 36 }, frame.can_build);
    try offer(&result, model, build, .build);
    const flash_bounds: dvui.Rect = .{ .x = 1238, .y = 8, .w = 110, .h = 36 };
    const flash_label = if (frame.flash_active) "Flash details" else "Flash";
    const flash = ui.buttonEnabled(theme, flash_label, "firmware.inspect", flash_bounds, frame.can_flash or frame.flash_active);
    try offer(&result, model, flash, .flash);
    if (ui.button(theme, if (view.light) "Dark" else "Light", "theme.toggle", .{ .x = 1358, .y = 8, .w = 78, .h = 36 })) {
        view.light = !view.light;
    }
    drawActivity(view, theme, frame, box.data().contentRect().w);
    return result;
}

/// Shows the document name, as a profile picker when the document is one of the
/// listed profiles. Returns the newly chosen profile.
fn drawProfile(model: *const desktop.model.Model, profiles: []const Profile, theme: ui.Theme) !?[8]u8 {
    const doc = model.document();
    const bounds: dvui.Rect = .{ .x = 405, .y = 8, .w = 240, .h = 36 };
    const names = try dvui.currentWindow().arena().alloc([]const u8, profiles.len);
    var choice: ?usize = null;
    for (profiles, names, 0..) |profile, *name, index| {
        name.* = profile.name;
        if (std.mem.eql(u8, &profile.id, &doc.profile_id)) {
            choice = index;
            name.* = doc.name;
        }
    }
    var selected = choice orelse {
        ui.label(theme, doc.name, bounds, 14);
        return null;
    };
    if (dvui.dropdown(@src(), names, .{ .choice = &selected }, .{}, ui.options(theme, bounds, 14))) return profiles[selected].id;
    return null;
}

const Activity = struct {
    busy: bool,
    failed: bool,
    /// The complete latest status, shown in the details popup.
    full: []const u8,
    hint: []const u8,
    /// The short status shown in the toolbar row.
    message: []const u8,

    /// Summarizes build and flash progress. A success message is shown for five
    /// seconds after the status last changed, then collapses to "Ready".
    fn init(view: *View, frame: Frame) Activity {
        const busy = frame.build_active or frame.flash_active;
        const failed = frame.diagnostic.len != 0 or (frame.flash_failed and !frame.build_active);
        const full = if (frame.diagnostic.len != 0)
            frame.diagnostic
        else if (frame.build_active)
            "Building firmware…"
        else if (frame.flash_status.len != 0)
            frame.flash_status
        else
            frame.build_status;
        const hint = if (failed)
            ""
        else if (frame.build_active and frame.first_build)
            "First build may take a few minutes"
        else if (frame.build_active)
            "Compiling firmware and practice runner"
        else
            "";
        const result_hash = std.hash.Wyhash.hash(0, full);
        if (view.result_hash != result_hash) {
            view.result_hash = result_hash;
            view.result_until = frame.now_ms +| 5000;
        }
        const success = !busy and !failed and (frame.flash_succeeded or std.mem.eql(u8, full, "Built snapshot"));
        const message = if (frame.diagnostic.len != 0)
            "Needs attention · open Details"
        else if (failed)
            "Flash failed · open Details"
        else if (success and frame.now_ms > view.result_until)
            "Ready"
        else if (full.len == 0)
            "Ready"
        else
            full;
        return .{ .busy = busy, .failed = failed, .full = full, .hint = hint, .message = message };
    }
};

fn drawActivity(view: *View, theme: ui.Theme, frame: Frame, width: f32) void {
    const activity: Activity = .init(view, frame);
    const row = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 10, .y = 54, .w = width - 20, .h = 38 },
        .padding = .{},
        .margin = .{},
        .tag = "editor.activity",
    });
    defer row.deinit();
    const row_width = width - 20;
    const separator = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 0, .y = 0, .w = row_width, .h = 1 },
        .background = true,
        .color_fill = .{ .color = theme.border },
        .padding = .{},
        .margin = .{},
    });
    separator.deinit();
    drawActivityIcon(activity, theme);
    const message_width = if (activity.hint.len != 0) @min(@as(f32, 190), row_width - 300) else row_width - 300;
    var label_options = ui.options(theme, .{ .x = 44, .y = 11, .w = message_width, .h = 24 }, 14);
    label_options.padding = .{};
    label_options.tag = "editor.activity.message";
    dvui.labelNoFmt(@src(), activity.message, .{ .align_y = 0.5, .ellipsize = true }, label_options);
    if (activity.hint.len != 0) {
        var muted = theme;
        muted.text = theme.muted;
        const hint_bounds: dvui.Rect = .{ .x = 44 + message_width + 10, .y = 14, .w = @max(0, row_width - message_width - 320), .h = 20 };
        ui.label(muted, activity.hint, hint_bounds, 12);
    }
    var auto_options = ui.options(theme, .{ .x = row_width - 234, .y = 14, .w = 120, .h = 22 }, 13);
    auto_options.padding = .{};
    auto_options.tag = "firmware.auto_build";
    _ = dvui.checkbox(@src(), &view.auto_build, "Auto-build", auto_options);
    const details_label = if (view.details_open) "Details ▴" else "Details ▾";
    if (ui.button(theme, details_label, "editor.activity.details", .{ .x = row_width - 98, .y = 7, .w = 90, .h = 30 })) {
        view.details_open = !view.details_open;
    }
    if (view.details_open) drawDetails(view, activity, theme);
}

/// A spinner while busy, otherwise a status dot or a warning mark.
fn drawActivityIcon(activity: Activity, theme: ui.Theme) void {
    const tint = if (activity.failed) ui.color(0xF06B73) else if (activity.busy) ui.color(0x328BFF) else ui.color(0x6EC59A);
    if (!activity.busy) {
        var icon_theme = theme;
        icon_theme.text = tint;
        ui.label(icon_theme, if (activity.failed) "!" else "●", .{ .x = 12, .y = 13, .w = 18, .h = 20 }, 14);
        return;
    }
    const track = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 8, .y = 11, .w = 22, .h = 22 },
        .padding = .{},
        .margin = .{},
        .border = .all(3),
        .corners = .all(11),
        .color_border = .{ .color = theme.control },
    });
    track.deinit();
    dvui.spinner(@src(), .{
        .rect = .{ .x = 8, .y = 11, .w = 22, .h = 22 },
        .min_size_content = .{ .w = 22, .h = 22 },
        .padding = .{},
        .margin = .{},
        .color_text = .{ .color = tint },
    });
}

fn drawDetails(view: *View, activity: Activity, theme: ui.Theme) void {
    const popup = dvui.floatingWindow(@src(), .{ .modal = false }, .{
        .rect = .{ .x = @max(16, dvui.windowRect().w - 650), .y = 110, .w = 620, .h = 240 },
        .padding = .all(18),
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_text = .{ .color = theme.text },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
    });
    defer popup.deinit();
    ui.label(theme, "Build and Flash activity", .{ .x = 0, .y = 0, .w = 584, .h = 25 }, 17);
    {
        const scroll = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 0, .y = 36, .w = 584, .h = 105 }, .background = false });
        defer scroll.deinit();
        const text = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .expand = .horizontal,
            .background = false,
            .font = ui.options(theme, .{}, 14).font,
            .padding = .{},
        });
        text.addText(activity.full, .{});
        if (activity.hint.len != 0) {
            text.addText("\n\n", .{});
            text.addText(activity.hint, .{});
        }
        text.deinit();
    }
    if (ui.button(theme, "Copy details", "editor.activity.copy", .{ .x = 0, .y = 155, .w = 130, .h = 32 })) {
        const full = activity.full;
        const details = if (activity.hint.len == 0)
            full
        else
            std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}\n\n{s}", .{ full, activity.hint }) catch full;
        dvui.clipboardTextSet(details);
    }
    if (ui.button(theme, "Close", "editor.activity.close", .{ .x = 474, .y = 155, .w = 110, .h = 32 })) view.details_open = false;
}
