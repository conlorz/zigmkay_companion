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
};
pub const View = struct {
    scroll: presentation.Scroll = .{},
    show_keyboard: bool = true,
    drawn_len: usize = 0,
    drawn_keyboard: bool = false,
    rundown: rundown.View = .{},
    challenge_open: bool = false,
    challenge_enabled: bool = false,
    challenge_seed: u64 = 1,
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
    dvui.wantTextInput(data.borderRectScale().r.toNatural());
    for (dvui.events()) |*event| {
        if (event.handled) continue;
        switch (event.evt) {
            .text => |text| {
                if (accepting and text.action == .value and !text.action.value.selected) effect.reset_text = (try owner.insertOs(true, text.action.value.txt, input.now_us, false)).reset_text or effect.reset_text;
                event.handle(@src(), data);
            },
            .key => |key| {
                if (key.action != .up and accepting) {
                    if (key.matchBind("paste")) effect.reset_text = (try owner.insertOs(true, dvui.clipboardText(), input.now_us, true)).reset_text or effect.reset_text else if (!key.mod.control() and !key.mod.command()) switch (key.code) {
                        .backspace => owner.session.backspace(),
                        .tab => effect.reset_text = (try owner.insertOs(true, "    ", input.now_us, false)).reset_text or effect.reset_text,
                        .enter => effect.reset_text = (try owner.insertOs(true, "\n", input.now_us, false)).reset_text or effect.reset_text,
                        .escape => effect.reset_text = owner.pause(input.now_us).reset_text or effect.reset_text,
                        else => {},
                    };
                }
                event.handle(@src(), data);
            },
            else => {},
        }
    }
    return effect;
}
fn keyboard(owner: *const control.Controller, frame: Frame, theme: ui.Theme, bounds: dvui.Rect, focus: usize, resources: geometry.Resources) !void {
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
    const guided = owner.config.assistance == .guided;
    const next = if (guided and owner.active and owner.session.state != .complete and focus < owner.session.reference_len) try desktop.practice.hint(labels.practiceLabels(), layer, mods.toByte(), owner.session.reference[focus], active) else null;
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
    presentation.caption(try std.fmt.allocPrint(arena, "{s} · {s} · layer {d}{s}{s}", .{ title, frame.profile, layer, if (mods.toByte() & 0x22 != 0) " · Shift" else "", if (mods.toByte() & 0x44 != 0) " · Alt / Option" else "" }), .{ .x = 8, .y = 0, .w = bounds.w - 16, .h = 28 }, @min(18, bounds.h * 0.09), theme.text, "practice.keyboard.source");
    if (next) |hint| {
        const has_holds = std.mem.indexOfScalar(bool, hold, true) != null;
        var shift_note: []const u8 = "";
        if (hint.modifiers & 0x22 != 0) {
            if (frame.modifiers.toByte() & 0x22 != 0) shift_note = " · Shift already held" else {
                shift_note = " · Shift provider unavailable";
                for (hold, 0..) |held, key| if (held) {
                    const provider = labels.lookup(hold_source_layer, key, frame.modifiers);
                    const shifts = if (provider.hold_mods) |value| value.toByte() & 0x22 != 0 else if (provider.hid_code) |code| code == 225 or code == 229 else false;
                    if (!shifts) continue;
                    shift_note = " · fallback Shift provider";
                    if (frame.metadata) |keys| {
                        if (keys[hint.key].hand == .neutral) shift_note = " · handedness unavailable" else if (keys[key].hand != keys[hint.key].hand and keys[key].hand != .neutral and keys[key].home_row) shift_note = " · opposite-hand home-row Shift";
                    }
                };
            }
        }
        const instruction = try std.fmt.allocPrint(arena, "{s} · layer {d}{s}", .{ if (has_holds) "Hold blue HOLD keys first; keep holding, then tap gold TAP" else "Tap the gold TAP key", hint.layer, shift_note });
        presentation.caption(instruction, .{ .x = 8, .y = 28, .w = bounds.w - 16, .h = 23 }, 14, ui.color(if (theme.bg.r > 100) 0x8B6318 else 0xFFD179), null);
    } else if (guided and owner.active and owner.session.state != .complete) presentation.caption("Use your layout's composition or custom action for this character", .{ .x = 8, .y = 28, .w = bounds.w - 16, .h = 23 }, 14, theme.muted, null);
    const neutral_pressed = try arena.alloc(bool, labels.key_count);
    @memset(neutral_pressed, false);
    const output = try arena.alloc(desktop.physical_view.DrawKey, frame.geometry.len);
    const plan = try desktop.physical_view.plan(output, frame.geometry, labels, layer, mods, .{ .x = 18, .y = 52, .w = @max(0, bounds.w - 36), .h = @max(0, bounds.h - 62) }, .{ .pressed = if (guided) frame.pressed else neutral_pressed, .targets = tap, .holds = hold, .hold_source_layer = hold_source_layer, .active_layers = active, .stale = frame.stale });
    try geometry.draw(layer, plan, resources);
}
pub fn draw(owner: *control.Controller, view: *View, theme: ui.Theme, bounds: dvui.Rect, input: Input) !DrawResult {
    view.drawn_keyboard = false;
    const window = dvui.box(@src(), .{}, .{ .rect = bounds, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg }, .tag = "practice.inline" });
    defer window.deinit();
    const height = window.data().rect.h;
    const width = bounds.w;
    if (height < 300 or width < 300) return .{};
    // Exercise input precedes controls so Space cannot toggle a focused checkbox.
    const input_effect = try consumeInput(owner, window.data(), input);
    var pending: ?control.Intent = null;
    const controls_height: f32 = if (view.challenge_open) 126 else 84;
    var mode: usize = @backingInt(owner.config.mode);
    var level = owner.config.level;
    var preset: usize = @backingInt(owner.config.preset);
    var source: usize = @backingInt(owner.config.source);
    var assistance: usize = @backingInt(owner.config.assistance);
    var changed = false;
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.dropdown(@src(), &.{ "English", "Zig" }, .{ .choice = &mode }, .{}, .{ .min_size_content = .{ .w = 110 } });
        if (mode == 0) changed = dvui.dropdown(@src(), &.{ "Words", "Mixed case", "Punctuation" }, .{ .choice = &preset }, .{}, .{ .tag = "practice.preset" }) or changed;
        changed = dvui.dropdown(@src(), if (mode == 0) &.{ "Short · 2 units", "Normal · 5 units", "Long · 10 units" } else &desktop.practice.lesson_names, .{ .choice = &level }, .{}, .{ .tag = "practice.length" }) or changed;
    }
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 42, .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.dropdown(@src(), &.{ "OS keyboard text", "Unflashed draft" }, .{ .choice = &source }, .{}, .{ .tag = "practice.input.source" }) or changed;
        changed = dvui.dropdown(@src(), &.{ "Guided", "Layout only", "Hidden" }, .{ .choice = &assistance }, .{}, .{ .tag = "practice.assistance" }) or changed;
        if (!owner.active and dvui.button(@src(), "Saved history", .{}, .{ .tag = "practice.history.open" })) {
            view.rundown.refresh = true;
            view.rundown.history_open = true;
            if (input.history) |saved| if (saved.page_count > 0) {
                view.rundown.reviewed = saved.page[0];
            };
        }
        if (dvui.button(@src(), "Challenge seed…", .{}, .{ .tag = "practice.challenge.toggle" })) view.challenge_open = !view.challenge_open;
    }
    if (view.challenge_open) {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = 84, .w = width, .h = 38 } });
        defer row.deinit();
        changed = dvui.checkbox(@src(), &view.challenge_enabled, "Challenge v1", .{}) or changed;
        changed = dvui.textEntryNumber(@src(), u64, .{ .value = &view.challenge_seed }, .{ .min_size_content = .{ .w = 200 }, .tag = "practice.challenge.seed" }).changed or changed;
        dvui.labelNoFmt(@src(), "Match seed, preset, length and versions", .{}, .{});
    }
    if (changed) {
        var config = owner.config;
        config.mode = @fromBackingInt(@intCast(mode));
        config.level = level;
        config.source = @fromBackingInt(@intCast(source));
        config.preset = @fromBackingInt(@intCast(preset));
        config.assistance = @fromBackingInt(@intCast(assistance));
        config.challenge = if (view.challenge_enabled) view.challenge_seed else null;
        config.target_count = 0;
        pending = .{ .choose = config };
    }
    view.show_keyboard = owner.config.assistance != .hidden;
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
        if (input.frame) |frame| try keyboard(owner, frame, theme, keyboard_bounds, focus, input.resources) else presentation.caption("Companion · no verified keyboard layout", keyboard_bounds, 18, theme.muted, "practice.keyboard.source");
    }
    view.drawn_len = session.len;
    if (ui.button(theme, if (owner.active) "Fresh run" else "Start", "practice.start", .{ .x = 0, .y = footer_y, .w = 120, .h = 40 }) and pending == null) pending = .{ .start = true };
    if (ui.button(theme, "New exercise", "practice.new", .{ .x = 130, .y = footer_y, .w = 150, .h = 40 }) and pending == null) pending = .new_exercise;
    if (ui.button(theme, if (session.state == .paused) "Resume" else "Pause", "practice.pause", .{ .x = 290, .y = footer_y, .w = 120, .h = 40 }) and owner.active and pending == null) pending = if (session.state == .paused) .resume_run else .pause;
    if (ui.button(theme, "Stop", "practice.stop", .{ .x = 420, .y = footer_y, .w = 100, .h = 40 }) and pending == null) pending = .stop;
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
            view.rundown.reviewed = null;
            view.rundown.selected = null;
            view.rundown.message = "";
            view.scroll.at = null;
            view.drawn_len = 0;
        },
        else => {},
    }
    return effect;
}
