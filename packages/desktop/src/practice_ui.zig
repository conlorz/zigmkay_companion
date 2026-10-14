//! Retained tutor controls over injected project/live views and explicit effects.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const model = @import("layout-model");
const geometry = @import("physical-ui");
const presentation = @import("practice_presentation.zig");
const control = desktop.practice_controller;
const rundown = @import("practice_rundown.zig");
const progress_ui = @import("practice_progress_ui.zig");
const diagnostics_ui = @import("practice_diagnostics_ui.zig");
const curriculum_ui = @import("practice_curriculum_ui.zig");
const help = desktop.practice_help;
const help_ui = @import("practice_help_ui.zig");
pub const Frame = struct {
    /// Live frames must come from the coherent identity-checked session adapter.
    /// Native text and an editable draft never establish a live frame.
    source: enum { draft, simulated, live },
    labels: *const desktop.label_cache.LabelCache,
    geometry: []const model.physical_layout.Key,
    metadata: ?[]const desktop.practice.KeyMetadata = null,
    profile: []const u8,
    layer: usize = 0,
    active_layers: u16 = 1,
    modifiers: model.Modifiers = .{},
    pressed: []const bool,
    stale: bool = false,
};
pub const Input = struct {
    now_us: u64,
    window_focused: bool = false,
    owns_input: bool = false,
    prepared_snapshot: ?control.Digest = null,
    frame: ?Frame = null,
    resources: geometry.Resources = .{},
    fixture: bool = false,
    diagnostic: []const u8 = "",
    history: ?*const desktop.practice_history.Query = null,
    history_cohort: desktop.practice_results.Cohort = .{},
    history_saving: bool = false,
    history_failure: ?anyerror = null,
    history_path: []const u8 = "",
    history_pending: usize = 0,
    event_times: []const desktop.practice_timing.EventTime = &.{},
};
pub const View = struct {
    scroll: presentation.Scroll = .{},
    show_keyboard: bool = true,
    drawn_len: usize = 0,
    drawn_keyboard: bool = false,
    drawn_panel: bool = false,
    rundown: rundown.View = .{},
    challenge_open: bool = false,
    challenge_enabled: bool = false,
    challenge_seed: u64 = 1,
    was_focused: ?bool = null,
    data_open: bool = false,
    progress_open: bool = false,
    progress: progress_ui.View = .{},
    diagnostics_open: bool = false,
    diagnostics: diagnostics_ui.View = .{},
    curriculum_open: bool = false,
    curriculum: curriculum_ui.View = .{},
    help: help.State = .{},
    help_open: bool = false,
    help_config: control.Config = .{},
    review_open: bool = false,
    review: help_ui.Review = .{},
    data_path: [4096]u8 = @splat(0),
    transfer: enum { none, export_database, import_database } = .none,
};
pub const DrawResult = struct { input_effect: control.Effect = .{}, action: ?control.Action = null };
/// Free typing observes only the verified live presenter. Ordinary native text
/// remains independent and never becomes synthetic matrix input here.
pub fn drawFreeCompanion(frame: desktop.live_keyboard.Frame, physical: []const model.physical_layout.Key, theme: ui.Theme, bounds: dvui.Rect, resources: geometry.Resources) !void {
    const panel = dvui.box(@src(), .{}, .{ .rect = bounds, .background = true, .color_fill = .{ .color = theme.bg }, .corners = .all(12), .padding = .{}, .tag = "free.keyboard" });
    defer panel.deinit();
    const labels = frame.labels orelse {
        presentation.caption("Companion · no verified keyboard layout", .{ .x = 8, .y = 0, .w = bounds.w - 16, .h = 28 }, 18, theme.text, "free.keyboard.source");
        presentation.caption("Waiting for matching keyboard telemetry. Native typing remains available.", .{ .x = 8, .y = 38, .w = bounds.w - 16, .h = 48 }, 16, theme.muted, "free.keyboard.unavailable");
        return;
    };
    presentation.caption(try std.fmt.allocPrint(dvui.currentWindow().arena(), "Live companion · {s} · {s} · layer {d}", .{ std.mem.sliceTo(&frame.profile, 0), if (frame.stale) "stale / reconnecting" else "verified keyboard", frame.layer }), .{ .x = 8, .y = 0, .w = bounds.w - 16, .h = 28 }, 18, theme.text, "free.keyboard.source");
    if (physical.len == 0) {
        presentation.caption("Keyboard view unavailable", .{ .x = 8, .y = 38, .w = bounds.w - 16, .h = 48 }, 16, theme.muted, "free.keyboard.unavailable");
        return;
    }
    const output = try dvui.currentWindow().arena().alloc(desktop.physical_view.DrawKey, physical.len);
    const plan = try desktop.physical_view.plan(output, physical, labels, frame.layer, frame.modifiers, .{ .x = 18, .y = 34, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - 44) }, .{ .pressed = frame.pressed, .active_layers = frame.active, .stale = frame.stale });
    try geometry.draw(frame.layer, plan, resources);
}
fn consumeInput(owner: *control.Controller, data: *dvui.WidgetData, input: Input) !control.Effect {
    var effect: control.Effect = .{};
    if (!input.owns_input or !input.window_focused) return effect;
    const accepting = owner.acceptingOsText(true);
    if (!accepting or owner.session.state == .complete) return effect;
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        var at = input.now_us;
        var native_time = false;
        for (input.event_times) |time| if (time.number == event.num) {
            at = time.now_us;
            native_time = true;
            break;
        };
        if (owner.session.recorder) |recorder| recorder.clock = if (native_time) .native_event else .frame;
        switch (event.evt) {
            .text => |text| {
                if (accepting and text.action == .value and !text.action.value.selected) effect.reset_text = (try owner.insertOs(true, text.action.value.txt, at, false)).reset_text or effect.reset_text;
                event.handle(@src(), data);
            },
            .key => |key| {
                if (key.action != .up and accepting) {
                    if (key.matchBind("paste")) effect.reset_text = (try owner.insertOs(true, dvui.clipboardText(), at, true)).reset_text or effect.reset_text else if (!key.mod.control() and !key.mod.command()) switch (key.code) {
                        .backspace => owner.session.backspaceAt(at),
                        .tab => effect.reset_text = (try owner.insertOs(true, "    ", at, false)).reset_text or effect.reset_text,
                        .enter => effect.reset_text = (try owner.insertOs(true, "\n", at, false)).reset_text or effect.reset_text,
                        .escape => effect.reset_text = owner.pause(at).reset_text or effect.reset_text,
                        else => {},
                    };
                    owner.session.input_repeat = key.action == .repeat;
                }
                event.handle(@src(), data);
            },
            else => {},
        }
    }
    return effect;
}
fn keyboard(owner: *const control.Controller, frame: Frame, theme: ui.Theme, bounds: dvui.Rect, focus: usize, resources: geometry.Resources, show_hint: bool) !void {
    const panel = dvui.box(@src(), .{}, .{ .rect = bounds, .background = true, .color_fill = .{ .color = theme.bg }, .corners = .all(12), .padding = .{}, .tag = "practice.keyboard" });
    defer panel.deinit();
    if (frame.geometry.len == 0) {
        presentation.caption("Keyboard view unavailable", .{ .x = 8, .y = 0, .w = bounds.w - 16, .h = 48 }, 18, theme.muted, null);
        return;
    }
    const labels = frame.labels;
    var layer = @min(frame.layer, labels.layer_count - 1);
    var active = frame.active_layers;
    var mods = frame.modifiers;
    const guided = show_hint;
    const next = if (guided and owner.active and owner.session.state != .complete and focus < owner.session.reference_len) desktop.practice_curriculum.hintFor(labels.practiceLabels(), owner.config.curriculum, owner.session.reference[focus]) orelse try desktop.practice.hint(labels.practiceLabels(), layer, mods.toByte(), owner.session.reference[focus], active) else null;
    const arena = dvui.currentWindow().arena();
    const tap = try arena.alloc(bool, labels.key_count);
    const hold = try arena.alloc(bool, labels.key_count);
    try desktop.practice.guidance(labels.practiceLabels(), frame.metadata, layer, mods.toByte(), next, .{ .tap = tap, .hold = hold });
    const hold_source_layer = layer;
    if (guided and frame.source == .draft) if (next) |hint| {
        layer = hint.layer;
        mods = @bitCast(hint.modifiers);
        active = 1 | (@as(u16, 1) << @intCast(layer));
    };
    const title = switch (frame.source) {
        .live => if (frame.stale) "Live companion · stale / reconnecting" else "Live companion",
        .simulated => "Draft companion · simulated key presses",
        .draft => if (guided) "Draft guide · next-route preview" else "Static draft reference · no key telemetry",
    };
    dvui.labelNoFmt(@src(), try std.fmt.allocPrint(arena, "{s} · {s} · layer {d}{s}", .{ title, frame.profile, layer, if (owner.cohort.verified) "" else " · unverified" }), .{ .align_x = 0 }, .{ .rect = .{ .x = 8, .y = bounds.h - 22, .w = @max(0, bounds.w - 200), .h = 20 }, .font = dvui.Font.theme(.body).withSize(11), .color_text = .{ .color = theme.muted }, .padding = .{}, .tag = "practice.keyboard.source" });
    for ([_][]const u8{ "Hold", "Tap" }, 0..) |label, index| {
        const x = bounds.w - 182 + @as(f32, @floatFromInt(index)) * 92;
        const color = ui.color(if (index == 0) 0x50D2FF else 0xFFC953);
        const swatch = dvui.box(@src(), .{}, .{ .rect = .{ .x = x, .y = bounds.h - 19, .w = 10, .h = 10 }, .background = true, .color_fill = .{ .color = color }, .padding = .{}, .id_extra = index });
        swatch.deinit();
        dvui.labelNoFmt(@src(), label, .{}, .{ .rect = .{ .x = x + 16, .y = bounds.h - 24, .w = 65, .h = 22 }, .font = dvui.Font.theme(.body).withSize(13), .color_text = .{ .color = theme.muted }, .padding = .{}, .id_extra = index });
    }
    const neutral_pressed = try arena.alloc(bool, labels.key_count);
    @memset(neutral_pressed, false);
    const output = try arena.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const top: f32 = 0;
    const plan = try desktop.physical_view.plan(output, frame.geometry, labels, layer, mods, .{ .x = 18, .y = top, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - top - 34) }, .{ .pressed = if (guided) frame.pressed else neutral_pressed, .targets = tap, .holds = hold, .hold_source_layer = hold_source_layer, .active_layers = active, .stale = frame.stale });
    try geometry.draw(layer, plan, resources);
}
pub fn draw(owner: *control.Controller, view: *View, theme: ui.Theme, bounds: dvui.Rect, input: Input) !DrawResult {
    view.drawn_keyboard = false;
    view.drawn_panel = false;
    const window = dvui.box(@src(), .{}, .{ .rect = bounds, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg }, .tag = "practice.inline" });
    defer window.deinit();
    const height = window.data().rect.h;
    const width = bounds.w;
    if (height < 300 or width < 300) {
        if (input.fixture) std.log.err("Practice bounds height={d} width={d} requested={d}", .{ height, width, bounds.h });
        return .{};
    }
    view.drawn_panel = true;
    if (owner.session.recorder) |recorder| recorder.clock = .frame;
    var focus_effect: control.Effect = .{};
    if (owner.active and owner.session.state != .complete) {
        if (view.was_focused) |previous| if (previous != input.window_focused) {
            if (!input.window_focused) focus_effect = owner.pause(input.now_us);
            if (owner.session.recorder) |recorder| recorder.record(if (input.window_focused) .focus_gained else .focus_lost, input.now_us, owner.session.duration(input.now_us), owner.session.len, null, .ordinary);
        };
    }
    view.was_focused = input.window_focused;
    const auxiliary = view.data_open or view.progress_open or view.diagnostics_open or view.curriculum_open or view.help_open or view.review_open;
    view.help.tick(owner.generation, desktop.practice_view.focus(&owner.session), input.now_us, !owner.active or owner.session.state == .paused or owner.session.state == .complete or auxiliary or !input.window_focused);
    if (auxiliary and owner.active and owner.session.state != .complete) if (owner.session.recorder) |recorder| recorder.setCue(false, owner.session.len, input.now_us, owner.session.duration(input.now_us));
    if (view.data_open) {
        presentation.caption("Practice data", .{ .w = width, .h = 42 }, 28, theme.text, "practice.data.title");
        presentation.caption("Timing datapoints are saved locally during practice. Older runs keep their original counts.", .{ .y = 52, .w = width, .h = 48 }, 17, theme.muted, null);
        presentation.caption(try std.fmt.allocPrint(dvui.currentWindow().arena(), "{d} saved runs · {d} timing events · {d} pending saves", .{ if (input.history) |data| data.database_runs else 0, if (input.history) |data| data.database_events else 0, input.history_pending }), .{ .y = 110, .w = width, .h = 34 }, 20, theme.text, "practice.data.counts");
        presentation.caption("History folder", .{ .y = 158, .w = width, .h = 28 }, 17, theme.muted, null);
        presentation.caption(input.history_path, .{ .y = 189, .w = width, .h = 50 }, 14, theme.text, null);
        presentation.caption("Database file to export or import (absolute path)", .{ .y = 254, .w = width, .h = 28 }, 17, theme.text, null);
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.data_path } }, .{ .rect = .{ .y = 288, .w = width, .h = 44 }, .tag = "practice.data.path" });
        entry.deinit();
        const available = !input.history_saving and input.history_pending == 0;
        if (ui.buttonEnabled(theme, "Export database", "practice.data.export", .{ .y = 350, .w = 180, .h = 42 }, available)) view.transfer = .export_database;
        if (ui.buttonEnabled(theme, "Import database", "practice.data.import", .{ .x = 195, .y = 350, .w = 180, .h = 42 }, available)) view.transfer = .import_database;
        presentation.caption("Export creates a standalone snapshot. Import merges runs without duplicating or replacing them.", .{ .y = 410, .w = width, .h = 48 }, 16, theme.muted, null);
        const message = if (input.history_failure) |err| switch (err) {
            error.PathAlreadyExists => "Export destination already exists. Choose another filename.",
            error.PracticeRunCollision => "Import conflict: the same run ID has different data. No runs were imported.",
            error.UnsupportedPracticeDatabase => "This file is not a supported practice database.",
            error.PracticeDatabaseBusy => "Database busy. Wait for other writes and retry.",
            else => @errorName(err),
        } else if (input.history_saving) "Working on practice data…" else if (input.history) |data| (if (data.exported) "Database exported successfully." else if (data.imported != null) "Database imported successfully. Existing matching runs were kept." else "") else "";
        presentation.caption(message, .{ .y = 479, .w = width, .h = 54 }, 17, theme.text, "practice.data.status");
        if (input.history_failure != null and ui.button(theme, "Retry pending saves", "practice.data.retry", .{ .y = 545, .w = 215, .h = 42 })) view.rundown.retry = true;
        if (ui.button(theme, "Back to practice", "practice.data.back", .{ .y = @min(height - 62, 620), .w = 180, .h = 42 })) view.data_open = false;
        return .{ .input_effect = focus_effect };
    }
    if (view.progress_open) {
        if (view.progress.inspect) |id| if (input.history) |history| if (history.requested_record) |record| if (std.mem.eql(u8, &id, &record.id)) {
            view.rundown.reviewed = record;
            view.rundown.selected = view.progress.selected;
            if (view.progress.selected) |cp| for (record.stats[0..record.stat_count]) |stat| if (stat.cp == cp) {
                rundown.select(&view.rundown, stat);
            };
            if (view.progress.selected != null and view.progress.matrix == 2) {
                view.rundown.diagnostics = true;
                view.rundown.refresh = true;
            }
            view.progress.inspect = null;
            view.progress_open = false;
        };
        if (view.progress_open) {
            if (view.progress.inspect) |id| if (input.history) |history| if (history.requested_id) |requested| if (std.mem.eql(u8, &id, &requested) and !history.contains_requested and !input.history_saving) {
                view.progress.inspect = null;
                view.progress.message = "This saved run is no longer available.";
            };
            const progress_cohort = if (view.rundown.reviewed) |record| record.cohort else if (owner.completed) |record| record.cohort else owner.configCohort();
            if (try progress_ui.draw(&view.progress, if (std.meta.eql(progress_cohort, input.history_cohort)) input.history else null, progress_cohort, input.history_failure, input.history_saving, theme, .{ .w = width, .h = height })) view.progress_open = false;
            if (view.progress.retry) {
                view.rundown.retry = true;
                view.progress.retry = false;
            }
            if (view.progress.inspect != null) view.rundown.refresh = true;
            return .{ .input_effect = focus_effect };
        }
    }
    if (view.rundown.diagnostics) {
        view.diagnostics_open = true;
        view.diagnostics = .{};
        view.rundown.diagnostics = false;
    }
    if (view.diagnostics_open) {
        const record = if (view.rundown.reviewed) |*reviewed| reviewed else if (owner.completed) |*completed| completed else {
            view.diagnostics_open = false;
            return .{};
        };
        const matching = if (input.history) |history| (if (history.requested_record) |saved| std.mem.eql(u8, &saved.id, &record.id) else false) else false;
        const action = try diagnostics_ui.draw(&view.diagnostics, view.rundown.selected, owner, record, if (matching) input.history else null, input.history_saving, input.history_failure, theme, .{ .w = width, .h = height });
        if (view.diagnostics.retry) {
            view.rundown.retry = true;
            view.diagnostics.retry = false;
        }
        switch (action) {
            .none => {},
            .back => view.diagnostics_open = false,
            .drill => |config| {
                view.diagnostics_open = false;
                view.rundown.reviewed = null;
                return .{ .input_effect = focus_effect, .action = owner.action(.{ .drill = config }) };
            },
        }
        return .{ .input_effect = focus_effect };
    }
    if (view.curriculum_open) {
        const action = try curriculum_ui.draw(&view.curriculum, owner, input.history, input.history_cohort, theme, .{ .w = width, .h = height });
        switch (action) {
            .none => {},
            .back => view.curriculum_open = false,
            .start => |config| {
                view.curriculum_open = false;
                view.rundown.reviewed = null;
                return .{ .input_effect = focus_effect, .action = owner.action(.{ .drill = config }) };
            },
            .free => |config| {
                view.curriculum_open = false;
                return .{ .input_effect = focus_effect, .action = owner.action(.{ .choose = config }) };
            },
        }
        return .{ .input_effect = focus_effect };
    }
    if (view.help_open) {
        if (try help_ui.settings(&view.help_config, theme, .{ .w = width, .h = height })) {
            view.help_open = false;
            return .{ .input_effect = focus_effect, .action = owner.action(.{ .choose = view.help_config }) };
        }
        return .{ .input_effect = focus_effect };
    }
    if (view.review_open) {
        const context = owner.configCohort();
        const matches = context.verified == input.history_cohort.verified and context.source == input.history_cohort.source and context.family == input.history_cohort.family and std.mem.eql(u8, &context.behavior, &input.history_cohort.behavior) and std.mem.eql(u8, &context.mapping, &input.history_cohort.mapping);
        const action = try help_ui.reviews(&view.review, owner, if (matches) input.history else null, input.history_failure, input.history_saving or !matches, theme, .{ .w = width, .h = height });
        if (view.review.retry) {
            view.rundown.retry = true;
            view.review.retry = false;
        }
        switch (action) {
            .none => {},
            .back => view.review_open = false,
            .start => |config| {
                view.review_open = false;
                view.rundown.reviewed = null;
                return .{ .input_effect = focus_effect, .action = owner.action(.{ .drill = config }) };
            },
        }
        return .{ .input_effect = focus_effect };
    }
    // Exercise input precedes controls so Space cannot toggle a focused checkbox.
    var input_effect = try consumeInput(owner, window.data(), input);
    if (focus_effect.runner != .none or focus_effect.reset_text) input_effect = focus_effect;
    var pending: ?control.Intent = null;
    const controls_height: f32 = if (view.challenge_open and owner.config.mode == .english) 126 else 84;
    var mode: usize = @backingInt(owner.config.mode);
    var level = owner.config.level;
    var preset: usize = @backingInt(owner.config.preset);
    var source: usize = @backingInt(owner.config.source);
    var assistance: usize = help.choice(owner.config);
    var changed = false;
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.dropdown(@src(), &.{ "English", "Zig" }, .{ .choice = &mode }, .{}, .{ .min_size_content = .{ .w = 110 } });
        if (mode == 0) {
            if (owner.config.curriculum.version != 0 and owner.config.curriculum.stage != .real_text) dvui.labelNoFmt(@src(), desktop.practice_curriculum.names[@backingInt(owner.config.curriculum.stage)], .{}, .{}) else changed = dvui.dropdown(@src(), &.{ "Words", "Mixed case", "Punctuation" }, .{ .choice = &preset }, .{}, .{ .tag = "practice.preset" }) or changed;
        }
        changed = dvui.dropdown(@src(), if (mode != 0) &desktop.practice.lesson_names else if (owner.config.curriculum.version != 0) &.{ "Short", "Normal", "Long" } else &.{ "Short · 2 units", "Normal · 5 units", "Long · 10 units" }, .{ .choice = &level }, .{}, .{ .tag = "practice.length" }) or changed;
    }
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 42, .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.dropdown(@src(), &.{ "OS keyboard text", "Unflashed draft" }, .{ .choice = &source }, .{}, .{ .tag = "practice.input.source" }) or changed;
        changed = dvui.dropdown(@src(), &help.choices, .{ .choice = &assistance }, .{}, .{ .tag = "practice.assistance" }) or changed;
        if (!owner.active and dvui.button(@src(), "Saved history", .{}, .{ .tag = "practice.history.open" })) {
            view.rundown.refresh = true;
            view.rundown.history_open = true;
            if (input.history) |saved| if (saved.page_count > 0) {
                view.rundown.reviewed = saved.page[0];
            };
        }
        if (mode == 0 and owner.config.curriculum.version == 0 and dvui.button(@src(), "Challenge seed…", .{}, .{ .tag = "practice.challenge.toggle" })) {
            view.challenge_open = !view.challenge_open;
            if (view.challenge_open and owner.active and owner.session.state != .complete) pending = .pause;
        }
        if (dvui.button(@src(), "Practice data", .{}, .{ .tag = "practice.data.open" })) {
            view.data_open = true;
            view.rundown.refresh = true;
            if (owner.active and owner.session.state != .complete) pending = .pause;
            if (view.data_path[0] == 0 and input.history_path.len != 0) {
                const default_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ input.history_path, "practice-export.sqlite3" });
                if (default_path.len < view.data_path.len) @memcpy(view.data_path[0..default_path.len], default_path);
            }
        }
        if (dvui.button(@src(), "Progress", .{}, .{ .tag = "practice.progress.open" })) {
            view.progress_open = true;
            view.rundown.refresh = true;
            if (owner.active and owner.session.state != .complete) pending = .pause;
        }
        if (dvui.button(@src(), "Guided difficulty", .{}, .{ .tag = "practice.curriculum.open" })) {
            view.curriculum_open = true;
            view.curriculum.config = owner.config;
            view.curriculum.config.challenge = null;
            view.curriculum.config.target_count = 0;
            if (view.curriculum.config.curriculum.version == 0) {
                view.curriculum.config.curriculum.version = 1;
                view.curriculum.config.mode = .english;
                view.curriculum.config.preset = .words;
            }
            view.challenge_open = false;
            view.challenge_enabled = false;
            view.rundown.refresh = true;
            if (owner.active and owner.session.state != .complete) pending = .pause;
        }
        if (dvui.button(@src(), "Hint settings", .{}, .{ .tag = "practice.help.open" })) {
            view.help_open = true;
            view.help_config = owner.config;
            if (owner.active and owner.session.state != .complete) pending = .pause;
        }
        if (dvui.button(@src(), "Review", .{}, .{ .tag = "practice.review.open" })) {
            view.review_open = true;
            view.rundown.refresh = true;
            if (owner.active and owner.session.state != .complete) pending = .pause;
        }
    }
    if (view.challenge_open and mode == 0) {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 84, .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.checkbox(@src(), &view.challenge_enabled, "Challenge v1", .{}) or changed;
        changed = dvui.textEntryNumber(@src(), u64, .{ .value = &view.challenge_seed }, .{ .min_size_content = .{ .w = 200 }, .tag = "practice.challenge.seed" }).changed or changed;
        dvui.labelNoFmt(@src(), "Match seed, preset, length and versions", .{}, .{});
    }
    if (changed) {
        var config = owner.config;
        config.mode = @fromBackingInt(@intCast(mode));
        if (config.curriculum.version != 0 and config.mode == .zig) config.curriculum.stage = .real_text;
        config.level = level;
        config.source = @fromBackingInt(@intCast(source));
        config.preset = @fromBackingInt(@intCast(preset));
        help.apply(&config, assistance);
        config.challenge = if (mode == 0 and view.challenge_enabled and config.curriculum.version == 0) view.challenge_seed else null;
        config.target_count = 0;
        pending = .{ .choose = config };
    }
    view.show_keyboard = owner.config.assistance != .hidden or (view.help.requested and !view.help.paused);
    if (view.rundown.history_open and view.rundown.reviewed == null and owner.completed == null and !owner.active) {
        if (input.history) |saved| if (saved.page_count > 0 and std.meta.eql(input.history_cohort, owner.configCohort())) {
            view.rundown.reviewed = saved.page[0];
        };
    }
    if (view.rundown.reviewed != null or owner.completed != null) {
        const record = if (view.rundown.reviewed) |*reviewed| reviewed else &owner.completed.?;
        const action = try rundown.draw(owner, &view.rundown, record, input.history, std.meta.eql(record.cohort, input.history_cohort), input.frame, theme, .{ .y = controls_height + 6, .w = width, .h = height - controls_height - 6 }, input.history_saving, input.history_failure);
        switch (action) {
            .none => {},
            .new_exercise => {
                view.rundown.reviewed = null;
                pending = .new_exercise;
            },
            .drill => |config| {
                view.rundown.reviewed = null;
                pending = .{ .drill = config };
            },
        }
        return .{ .input_effect = input_effect, .action = if (pending) |intent| owner.action(intent) else null };
    }
    const session = &owner.session;
    var focus_text: std.Io.Writer.Allocating = .init(dvui.currentWindow().arena());
    if (owner.captured_config.target_count > 0) {
        try focus_text.writer.writeAll("Drill focus: ");
        for (owner.captured_config.targets[0..owner.captured_config.target_count]) |cp| {
            var bytes: [4]u8 = undefined;
            try focus_text.writer.print("«{s}» ", .{desktop.practice_view.glyph(cp, true, &bytes)});
        }
    } else if (owner.config.challenge != null) try focus_text.writer.print("Challenge v1 · seed {d}", .{owner.exercise_seed}) else if (owner.config.preset == .mixed_case) try focus_text.writer.writeAll(if (owner.normal_coverage != null) "Capital hand coverage follows proven physical routes" else "Text coverage only · capital hand mapping unavailable");
    if (focus_text.written().len > 0) presentation.caption(focus_text.written(), .{ .y = height - 24, .w = width, .h = 22 }, 14, theme.muted, "practice.focus");
    presentation.caption(try std.fmt.allocPrint(dvui.currentWindow().arena(), "{d:.0} WPM     {d:.1}% accuracy     {d:.1}s     {s}", .{ session.wpm(input.now_us), session.accuracy(), @as(f64, @floatFromInt(session.duration(input.now_us))) / 1_000_000, if (!owner.active) "Ready" else @tagName(session.state) }), .{ .x = 0, .y = controls_height + 2, .w = width, .h = 26 }, 18, theme.muted, "practice.metrics");
    const focus = desktop.practice_view.focus(session);
    view.help.tick(owner.generation, focus, input.now_us, !owner.active or session.state == .paused or session.state == .complete or !input.window_focused);
    const baseline = if (focus < session.reference_len and input.history != null and std.meta.eql(owner.captured_cohort, input.history_cohort)) help.baseline(input.history.?.progress, session.reference[focus]) else null;
    const show_hint = if (owner.config.assistance == .guided) view.help.visible(owner.config.hints, baseline) else view.help.requested and !view.help.paused;
    if (owner.config.assistance == .guided and owner.config.hints.policy == .delayed and !view.help.paused and !show_hint) dvui.timer(window.data().id, @intCast(owner.config.hints.delay(baseline) -| view.help.waited_us));
    view.show_keyboard = owner.config.assistance != .hidden or (view.help.requested and !view.help.paused);
    const work_y = controls_height + 34;
    const work_height = @max(0, height - 112 - work_y - 24);
    const hero_height = @min(125, work_height * 0.23);
    const context_height = if (view.show_keyboard) work_height * 0.23 else work_height - hero_height - 8;
    const footer_y = work_y + 16 + hero_height + context_height;
    presentation.focusWord(session, owner.active, theme, .{ .x = 0, .y = work_y, .w = width, .h = hero_height }, focus);
    presentation.context(session, owner.active, owner.config.mode, &view.scroll, input.fixture, theme, .{ .x = 0, .y = work_y + 8 + hero_height, .w = width, .h = context_height }, focus, input.now_us);
    if (view.show_keyboard) {
        view.drawn_keyboard = input.frame != null;
        const keyboard_bounds: dvui.Rect = .{ .x = 0, .y = footer_y + 124, .w = width, .h = @max(0, height - footer_y - 124) };
        if (input.frame) |frame| try keyboard(owner, frame, theme, keyboard_bounds, focus, input.resources, show_hint) else presentation.caption("Companion · no verified keyboard layout", keyboard_bounds, 18, theme.muted, "practice.keyboard.source");
        if (owner.active and session.state != .complete) if (session.recorder) |recorder| {
            recorder.clock = .frame;
            const frame = input.frame;
            const available = frame != null and frame.?.geometry.len > 0 and keyboard_bounds.h >= 80;
            const proven = available and focus < session.reference_len and (desktop.practice_curriculum.hintFor(frame.?.labels.practiceLabels(), owner.config.curriculum, session.reference[focus]) != null or try desktop.practice.hint(frame.?.labels.practiceLabels(), frame.?.layer, frame.?.modifiers.toByte(), session.reference[focus], frame.?.active_layers) != null);
            recorder.setCue(show_hint and proven, focus, input.now_us, session.duration(input.now_us));
            if (available and view.help.requested and owner.config.assistance != .guided) recorder.help_revealed = true;
        };
    } else if (owner.active and session.state != .complete) if (session.recorder) |recorder| {
        recorder.clock = .frame;
        recorder.setCue(false, focus, input.now_us, session.duration(input.now_us));
    };
    view.drawn_len = session.len;
    if (ui.buttonEnabled(theme, if (owner.active) "Fresh run" else "Start", "practice.start", .{ .x = 0, .y = footer_y, .w = 120, .h = 40 }, session.state != .complete) and pending == null) pending = .{ .start = true };
    if (ui.buttonEnabled(theme, "New exercise", "practice.new", .{ .x = 130, .y = footer_y, .w = 150, .h = 40 }, session.state != .complete) and pending == null) pending = .new_exercise;
    if (ui.button(theme, if (session.state == .paused) "Resume" else "Pause", "practice.pause", .{ .x = 290, .y = footer_y, .w = 120, .h = 40 }) and owner.active and pending == null) pending = if (session.state == .paused) .resume_run else .pause;
    if (ui.button(theme, "Stop", "practice.stop", .{ .x = 420, .y = footer_y, .w = 100, .h = 40 }) and pending == null) pending = .stop;
    if (ui.buttonEnabled(theme, "Show hint", "practice.hint.request", .{ .x = 530, .y = footer_y, .w = 130, .h = 40 }, owner.active and !view.help.paused and focus < session.reference_len)) {
        view.help.requested = true;
        dvui.refresh(null, @src(), null);
        if (session.recorder) |recorder| {
            recorder.clock = .frame;
            recorder.record(.hint_requested, input.now_us, session.duration(input.now_us), focus, null, .ordinary);
        }
    }
    const progress = if (session.reference_len == 0) @as(f32, 0) else @as(f32, @floatFromInt(session.matched())) / @as(f32, @floatFromInt(session.reference_len));
    {
        const bar = dvui.box(@src(), .{}, .{ .rect = .{ .x = 0, .y = footer_y + 52, .w = width, .h = 5 }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.control }, .corners = .all(3) });
        defer bar.deinit();
        const fill = dvui.box(@src(), .{}, .{ .rect = .{ .w = width * progress, .h = 5 }, .background = true, .color_fill = .{ .color = ui.color(0x287AF2) } });
        fill.deinit();
    }
    const code_speed = if (owner.config.mode == .zig) try std.fmt.allocPrint(dvui.currentWindow().arena(), " · {d:.0} CPM", .{session.wpm(input.now_us) * 5}) else "";
    const best: f64 = if (std.meta.eql(owner.captured_cohort, input.history_cohort) and input.history != null) input.history.?.all.best_wpm else 0;
    presentation.caption(try std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}/{d} characters · {d} corrections · best {d:.0} WPM · {s}{s}", .{ session.matched(), session.reference_len, session.corrected, best, if (session.scored) "scored" else "paste preview", code_speed }), .{ .x = 0, .y = footer_y + 63, .w = width, .h = 22 }, 14, theme.muted, null);
    const diagnostic = if (owner.failure) |failure| switch (failure) {
        error.PracticeContextChanged => "Layout or input source changed · start a fresh exercise",
        error.DraftChangedRestartPractice => "Draft changed · restart the exercise",
        error.DraftPreparationFailed => "Draft preparation failed · retry with Resume",
        error.RunnerArtifactNotPrepared => "Build the current draft before starting practice",
        error.StaleBuild => "Build the current draft before starting practice",
        error.RunnerArtifactChanged => "The prepared draft runner changed · rebuild the draft",
        error.RunnerHostMismatch => "This draft runner was built for another system",
        error.HostMappingUnavailable => "Draft practice has no host key mapping for this board",
        else => input.diagnostic,
    } else input.diagnostic;
    const status = if (owner.config.source == .draft and owner.active) switch (owner.runner_state) {
        .preparing => "Preparing the current draft",
        .prepared => "Draft ready · press Resume",
        .stopping => "Stopping draft practice",
        .idle => "Build the current draft, then press Resume",
        .failed => if (diagnostic.len != 0) diagnostic else "Draft practice failed · build or retry",
        .stale => "Draft changed · restart the exercise",
        .running => diagnostic,
    } else diagnostic;
    presentation.caption(status, .{ .x = 0, .y = footer_y + 87, .w = width, .h = 22 }, 14, theme.muted, null);
    return .{ .input_effect = input_effect, .action = if (pending) |intent| owner.action(intent) else null };
}
pub fn apply(owner: *control.Controller, view: *View, rendered: control.Action, input: Input) !control.Effect {
    const effect = try owner.dispatch(rendered, input.prepared_snapshot, input.now_us);
    switch (rendered.intent) {
        .start, .new_exercise, .drill => {
            if (rendered.intent == .drill) view.challenge_enabled = false;
            view.rundown.reviewed = null;
            view.rundown.cleared = false;
            view.rundown.scope = 0;
            view.rundown.before = null;
            view.rundown.selected = null;
            view.rundown.message = "";
            view.scroll.at = null;
            view.drawn_len = 0;
        },
        else => {},
    }
    return effect;
}
