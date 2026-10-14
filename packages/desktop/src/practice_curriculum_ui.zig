//! Learner-controlled curriculum. Recommendations never lock or demote a stage.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const curriculum = desktop.practice_curriculum;
const control = desktop.practice_controller;
pub const View = struct { config: control.Config = .{}, message: []const u8 = "" };
pub const Action = union(enum) { none, back, start: control.Config, free: control.Config };
const descriptions = [_][]const u8{
    "Find a small useful alphabet and space. Practice readable short words without a speed gate.",
    "Retain familiar letters while introducing one more. Build consistent timing and transitions at your own pace.",
    "Add one capital or shifted punctuation character with a proven compatible Shift provider.",
    "Practice one new output on a layer reached by a proven hold provider. Familiar words remain between targets.",
    "Choose one Option/AltGr or combined modifier family. Only proven reachable output is generated.",
    "Use full sentences, paired punctuation or Zig lessons. Every generated character needs a proven reachable route.",
};
pub fn next(context: curriculum.Context, labels: desktop.practice.Labels) curriculum.Context {
    var output = context;
    var alphabet: [26]u8 = undefined;
    const available = curriculum.letters(labels, &alphabet);
    var symbols: [256]u21 = undefined;
    const members = curriculum.family(labels, context, &symbols);
    switch (context.stage) {
        .find_keys => output.stage = .fluency,
        .fluency => if (context.alphabet < available.len) {
            output.alphabet += 1;
        } else {
            output.stage = .shift;
            output.family = 0;
        },
        .shift, .layers, .modifiers => {
            if (@as(usize, context.family) + 1 < members.len) output.family += 1 else switch (context.stage) {
                .shift => {
                    if (!context.shifted_symbols) {
                        output.shifted_symbols = true;
                        output.family = 0;
                        if (curriculum.family(labels, output, &symbols).len == 0) {
                            output.stage = .layers;
                            output.layer = 1;
                        }
                    } else {
                        output.stage = .layers;
                        output.layer = 1;
                        output.family = 0;
                    }
                },
                .layers => if (@as(usize, context.layer) + 1 < labels.layer_count) {
                    output.layer += 1;
                    output.family = 0;
                } else {
                    output.stage = .modifiers;
                    output.layer = 0;
                    output.modifiers = 4;
                    output.family = 0;
                },
                .modifiers => {
                    const variants = [_]u8{ 4, 64, 6, 66 };
                    const index = std.mem.indexOfScalar(u8, &variants, context.modifiers) orelse 0;
                    if (index < variants.len - 1) {
                        output.modifiers = variants[index + 1];
                        output.family = 0;
                    } else output.stage = .real_text;
                },
                else => unreachable,
            }
        },
        .real_text => {},
    }
    return output;
}
pub fn draw(view: *View, owner: *control.Controller, history: ?*const desktop.practice_history.Query, history_cohort: desktop.practice_results.Cohort, theme: ui.Theme, bounds: dvui.Rect) !Action {
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = bounds, .tag = "practice.curriculum" });
    defer area.deinit();
    const body = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = bounds.w - 20, .h = 860 }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
    defer body.deinit();
    const width = bounds.w - 20;
    const arena = dvui.currentWindow().arena();
    if (ui.button(theme, "Back to practice", "practice.curriculum.back", .{ .w = 180, .h = 38 })) return .back;
    presentation.caption("Guided difficulty · choose your next step", .{ .x = 190, .w = width - 190, .h = 38 }, 24, theme.text, null);
    const labels = owner.curriculum_labels orelse {
        presentation.caption("A known layout is needed to create reachable lessons.", .{ .y = 90, .w = width, .h = 60 }, 20, theme.muted, null);
        return .none;
    };
    for (curriculum.names, 0..) |name, index| {
        var stage_theme = theme;
        if (@backingInt(view.config.curriculum.stage) == index) stage_theme.control = ui.color(0x264F80);
        if (ui.button(stage_theme, name, try std.fmt.allocPrint(arena, "practice.curriculum.stage.{d}", .{index}), .{ .y = 95 + @as(f32, @floatFromInt(index)) * 52, .w = 220, .h = 46 })) {
            view.config.curriculum.stage = @fromBackingInt(@as(u3, @intCast(index)));
            view.config.curriculum.family = 0;
            if (view.config.curriculum.stage != .real_text) {
                view.config.mode = .english;
                view.config.preset = .words;
            }
            if (view.config.curriculum.stage == .modifiers) view.config.curriculum.layer = 0;
            if (view.config.curriculum.stage == .layers and view.config.curriculum.layer == 0) view.config.curriculum.layer = 1;
            view.message = "Manual selection is always available.";
        }
    }
    const x: f32 = 240;
    const content_w = width - x;
    presentation.paragraph(descriptions[@backingInt(view.config.curriculum.stage)], .{ .x = x, .y = 95, .w = content_w, .h = 80 }, 18, theme.text);
    _ = dvui.dropdown(@src(), if (view.config.mode == .english) &.{ "Short", "Normal", "Long" } else &desktop.practice.lesson_names, .{ .choice = &view.config.level }, .{}, .{ .rect = .{ .x = x, .y = 190, .w = 180, .h = 38 } });
    var assistance: usize = @backingInt(view.config.assistance);
    if (dvui.dropdown(@src(), &.{ "Guided", "Layout only", "Hidden" }, .{ .choice = &assistance }, .{}, .{ .rect = .{ .x = x + 190, .y = 190, .w = 180, .h = 38 } })) view.config.assistance = @fromBackingInt(@as(u2, @intCast(assistance)));
    var alphabet: [26]u8 = undefined;
    const available = curriculum.letters(labels, &alphabet);
    if (ui.buttonEnabled(theme, "One fewer letter", "practice.curriculum.less", .{ .x = x, .y = 240, .w = 180, .h = 38 }, view.config.curriculum.stage != .real_text and view.config.curriculum.alphabet > 6)) view.config.curriculum.alphabet -= 1;
    if (ui.buttonEnabled(theme, "Add one letter", "practice.curriculum.more", .{ .x = x + 190, .y = 240, .w = 180, .h = 38 }, view.config.curriculum.stage != .real_text and view.config.curriculum.alphabet < available.len)) view.config.curriculum.alphabet += 1;
    const learned = available[0..@min(available.len, view.config.curriculum.alphabet)];
    presentation.caption(if (view.config.curriculum.stage == .real_text) "Full corpus: every character must have a reachable route" else try std.fmt.allocPrint(arena, "Alphabet: {s} · {d}/{d} reachable base letters", .{ learned, view.config.curriculum.alphabet, available.len }), .{ .x = x, .y = 290, .w = content_w, .h = 34 }, 18, theme.text, null);
    if (view.config.curriculum.stage == .shift) _ = dvui.checkbox(@src(), &view.config.curriculum.shifted_symbols, "Shifted punctuation (otherwise capitals)", .{ .rect = .{ .x = x, .y = 335, .w = content_w, .h = 38 } });
    if (view.config.curriculum.stage == .layers or view.config.curriculum.stage == .modifiers) {
        const layers = try arena.alloc([]const u8, labels.layer_count);
        for (layers, 0..) |*name, index| name.* = try std.fmt.allocPrint(arena, "Layer {d}", .{index});
        var layer: usize = @min(view.config.curriculum.layer, labels.layer_count - 1);
        if (dvui.dropdown(@src(), layers, .{ .choice = &layer }, .{}, .{ .rect = .{ .x = x, .y = 335, .w = 150, .h = 38 } })) {
            view.config.curriculum.layer = @intCast(layer);
            view.config.curriculum.family = 0;
        }
        view.config.curriculum.layer = @intCast(layer);
        if (view.config.curriculum.stage == .modifiers) {
            const modifiers = [_]u8{ 4, 64, 6, 66 };
            var variant = std.mem.indexOfScalar(u8, &modifiers, view.config.curriculum.modifiers) orelse 0;
            if (dvui.dropdown(@src(), &.{ "Option / left Alt", "AltGr / right Alt", "Shift + Option", "Shift + AltGr" }, .{ .choice = &variant }, .{}, .{ .rect = .{ .x = x + 160, .y = 335, .w = 210, .h = 38 } })) {
                view.config.curriculum.modifiers = modifiers[variant];
                view.config.curriculum.family = 0;
            }
        }
    }
    if (view.config.curriculum.stage == .real_text) {
        var mode: usize = @backingInt(view.config.mode);
        if (dvui.dropdown(@src(), &.{ "English sentences", "Zig lessons" }, .{ .choice = &mode }, .{}, .{ .rect = .{ .x = x, .y = 335, .w = 200, .h = 38 } })) view.config.mode = @fromBackingInt(@as(u1, @intCast(mode)));
        if (view.config.mode == .english) {
            var preset: usize = @backingInt(view.config.preset);
            if (dvui.dropdown(@src(), &.{ "Words", "Mixed case", "Punctuation" }, .{ .choice = &preset }, .{}, .{ .rect = .{ .x = x + 210, .y = 335, .w = 160, .h = 38 } })) view.config.preset = @fromBackingInt(@as(u2, @intCast(preset)));
        }
    }
    var members_buffer: [256]u21 = undefined;
    const members = curriculum.family(labels, view.config.curriculum, &members_buffer);
    if (view.config.curriculum.stage == .shift or view.config.curriculum.stage == .layers or view.config.curriculum.stage == .modifiers) {
        if (members.len > 0) {
            const names = try arena.alloc([]const u8, members.len);
            for (members, 0..) |cp, index| {
                var bytes: [4]u8 = undefined;
                names[index] = try arena.dupe(u8, desktop.practice_view.glyph(cp, true, &bytes));
            }
            var choice: usize = @min(view.config.curriculum.family, members.len - 1);
            _ = dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{ .rect = .{ .x = x, .y = 385, .w = 150, .h = 38 }, .tag = "practice.curriculum.target" });
            view.config.curriculum.family = @intCast(choice);
            presentation.caption("One new output at a time; familiar words stay in the exercise.", .{ .x = x + 160, .y = 385, .w = content_w - 160, .h = 38 }, 15, theme.muted, null);
        } else presentation.paragraph("No new output has a proven compatible provider for this family. Choose another family or stage.", .{ .x = x, .y = 385, .w = content_w, .h = 60 }, 16, theme.muted);
    }
    var expected: [26]u21 = undefined;
    var expected_count: usize = 0;
    if (view.config.curriculum.stage == .find_keys or view.config.curriculum.stage == .fluency or view.config.curriculum.stage == .real_text) {
        const values = if (view.config.curriculum.stage == .real_text) available else learned;
        for (values) |cp| {
            expected[expected_count] = cp;
            expected_count += 1;
        }
    } else if (view.config.curriculum.family < members.len) {
        expected[0] = members[view.config.curriculum.family];
        expected_count = 1;
    }
    const matching = std.meta.eql(owner.cohortFor(view.config), history_cohort);
    const assessment = if (matching and history != null) curriculum.assess(view.config.curriculum, history.?.all, history.?.progress, expected[0..expected_count]) else curriculum.Assessment{ .missing = expected_count };
    presentation.caption(if (view.config.curriculum.stage == .find_keys) try std.fmt.allocPrint(arena, "{d}/3 runs · {d} targets need evidence · no speed gate", .{ @min(3, assessment.runs), assessment.missing }) else try std.fmt.allocPrint(arena, "{d}/3 runs · {d} targets need evidence · {d}/3 clean timing runs", .{ @min(3, assessment.runs), assessment.missing, assessment.timing_runs }), .{ .x = x, .y = 470, .w = content_w, .h = 38 }, 17, theme.text, null);
    presentation.paragraph(if (assessment.ready) "Suggested next step is available. Advancement is your choice; a poor run never changes your selected lesson." else "Suggested advancement needs 20 opportunities per target at ≥97% first-pass success across ≥3 runs. After Find keys, the newest three runs also need ≥97% attempt accuracy and ≥5 clean timing samples each.", .{ .x = x, .y = 515, .w = content_w, .h = 100 }, 16, theme.muted);
    const run_fraction = @as(f32, @floatFromInt(@min(3, assessment.runs))) / 3;
    const target_fraction = if (expected_count == 0) @as(f32, 0) else @as(f32, @floatFromInt(expected_count - assessment.missing)) / @as(f32, @floatFromInt(expected_count));
    const timing_fraction = if (view.config.curriculum.stage == .find_keys) @as(f32, 1) else @as(f32, @floatFromInt(assessment.timing_runs)) / 3;
    const progress = (run_fraction + target_fraction + timing_fraction) / 3;
    const bar = dvui.box(@src(), .{}, .{ .rect = .{ .x = x, .y = 612, .w = content_w, .h = 6 }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.control }, .tag = "practice.curriculum.progress" });
    const fill = dvui.box(@src(), .{}, .{ .rect = .{ .w = content_w * progress, .h = 6 }, .padding = .{}, .background = true, .color_fill = .{ .color = ui.color(0x69BFA3) } });
    fill.deinit();
    bar.deinit();
    if (ui.button(theme, "Start this lesson", "practice.curriculum.start", .{ .x = x, .y = 630, .w = 190, .h = 42 })) {
        view.config.challenge = null;
        view.config.target_count = 0;
        var buffer: [8192]u8 = undefined;
        const text = owner.preview(&buffer, view.config) catch |err| {
            view.message = switch (err) {
                error.CurriculumAlphabetUnavailable => "Choose fewer base letters for this layout.",
                error.CurriculumFamilyUnavailable => "No supported output in this family. Choose another layer, modifier or stage.",
                error.CurriculumCorpusUnavailable => "This alphabet has too few readable corpus words. Add one letter.",
                error.CurriculumSpaceUnavailable => "Space needs a proven base-layer route before this lesson can start.",
                error.CurriculumRouteUnavailable => "A lesson character lacks a proven reachable route. Try a simpler preset or another stage.",
                error.CurriculumLayoutUnavailable => "Select a known keyboard layout before starting a guided lesson.",
                else => @errorName(err),
            };
            return .none;
        };
        curriculum.validateText(labels, text) catch |err| {
            view.message = @errorName(err);
            return .none;
        };
        return .{ .start = view.config };
    }
    if (ui.buttonEnabled(theme, if (view.config.curriculum.stage == .real_text) "Repeat real text" else "Suggested next step", "practice.curriculum.next", .{ .x = x + 200, .y = 630, .w = 205, .h = 42 }, assessment.ready)) {
        view.config.curriculum = next(view.config.curriculum, labels);
        view.message = "Next lesson selected. Start when ready.";
    }
    if (history) |data| if (data.latest_curriculum) |record| if (ui.button(theme, "Resume saved curriculum", "practice.curriculum.restore", .{ .x = x, .y = 687, .w = 250, .h = 38 })) {
        view.config.curriculum = record.cohort.curriculum;
        view.config.mode = @fromBackingInt(@backingInt(record.cohort.family));
        view.config.level = if (record.cohort.family == .zig) record.cohort.lesson else record.cohort.length;
        view.config.preset = record.cohort.preset;
        view.config.assistance = record.cohort.assistance;
        view.message = "Restored the last completed normal lesson for this layout and input source.";
    };
    if (ui.button(theme, "Free exercises", "practice.curriculum.free", .{ .x = x + 260, .y = 687, .w = 180, .h = 38 })) {
        var config = owner.config;
        config.curriculum = .{};
        return .{ .free = config };
    }
    presentation.paragraph("Mastery thresholds are an initial tutor policy for manual validation. Guided progress is assisted practice; hidden assistance has its own evidence. Length and assistance remain independent choices.", .{ .y = 745, .w = width, .h = 60 }, 15, theme.muted);
    presentation.caption(view.message, .{ .y = 815, .w = width, .h = 38 }, 16, theme.text, null);
    return .none;
}
