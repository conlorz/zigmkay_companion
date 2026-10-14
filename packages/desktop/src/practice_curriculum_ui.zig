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
    const wide = bounds.w >= 1100;
    const page = presentation.Page.init(bounds, if (wide) 880 else 1230, "practice.curriculum", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    presentation.header("Learn your layout", "Choose a stage. Difficulty, help and length stay independent.", width, theme);
    if (ui.button(theme, "Back to practice", "practice.curriculum.back", .{ .x = width - 165, .w = 165, .h = 38 })) return .back;
    const labels = owner.curriculum_labels orelse {
        _ = presentation.flowText("A known layout is needed to create reachable lessons.", 0, 120, width, 18, theme.muted);
        return .none;
    };
    const path_w: f32 = if (wide) 260 else width;
    presentation.surface(.{ .y = 96, .w = path_w, .h = if (wide) 680 else 230 }, theme.panel);
    presentation.label("Learning path", .{ .x = 20, .y = 110, .w = path_w - 40, .h = 30 }, 18, theme.text, null);
    for (curriculum.names, 0..) |name, index| {
        var stage_theme = theme;
        if (@backingInt(view.config.curriculum.stage) == index) stage_theme.control = ui.color(if (theme.bg.r > 100) 0xC5EBDC else 0x245C4D);
        const stage_w: f32 = if (wide) path_w - 40 else (width - 52) / 2;
        const x: f32 = if (wide) 20 else 20 + @as(f32, @floatFromInt(index % 2)) * (stage_w + 12);
        const y: f32 = 158 + @as(f32, @floatFromInt(if (wide) index else index / 2)) * 50;
        var options = ui.options(stage_theme, .{ .x = x, .y = y, .w = stage_w, .h = 40 }, 15);
        options.tag = try std.fmt.allocPrint(arena, "practice.curriculum.stage.{d}", .{index});
        options.id_extra = index;
        if (dvui.button(@src(), try std.fmt.allocPrint(arena, "{d}. {s}", .{ index + 1, name }), .{}, options)) {
            view.config.curriculum.stage = @fromBackingInt(@as(u3, @intCast(index)));
            view.config.curriculum.family = 0;
            if (view.config.curriculum.stage != .real_text) {
                view.config.mode = .english;
                view.config.preset = .words;
            }
            if (view.config.curriculum.stage == .modifiers) view.config.curriculum.layer = 0;
            if (view.config.curriculum.stage == .layers and view.config.curriculum.layer == 0) view.config.curriculum.layer = 1;
            view.message = "Lesson selected. Start when ready.";
        }
    }
    const x: f32 = if (wide) 280 else 0;
    const y: f32 = if (wide) 96 else 346;
    const content_w = width - x;
    const inner_x = x + 24;
    const inner_w = content_w - 48;
    presentation.surface(.{ .x = x, .y = y, .w = content_w, .h = 490 }, theme.panel);
    presentation.label(try std.fmt.allocPrint(arena, "Stage {d}: {s}", .{ @backingInt(view.config.curriculum.stage) + 1, curriculum.names[@backingInt(view.config.curriculum.stage)] }), .{ .x = inner_x, .y = y + 16, .w = inner_w, .h = 34 }, 22, theme.text, null);
    _ = presentation.flowText(descriptions[@backingInt(view.config.curriculum.stage)], inner_x, y + 66, inner_w, 16, theme.muted);
    var alphabet: [26]u8 = undefined;
    const available = curriculum.letters(labels, &alphabet);
    const learned = available[0..@min(available.len, view.config.curriculum.alphabet)];
    var alphabet_text: std.Io.Writer.Allocating = .init(arena);
    for (learned, 0..) |cp, index| try alphabet_text.writer.print("{s}{c}", .{ if (index == 0) "" else " ", cp });
    presentation.label(if (view.config.curriculum.stage == .real_text) "Full text · reachable routes" else "Your current alphabet", .{ .x = inner_x, .y = y + 140, .w = inner_w, .h = 24 }, 14, theme.muted, null);
    presentation.label(if (view.config.curriculum.stage == .real_text) "Sentences and code" else alphabet_text.written(), .{ .x = inner_x, .y = y + 170, .w = inner_w, .h = 42 }, if (learned.len > 16) 20 else 28, theme.text, null);
    if (ui.buttonEnabled(theme, "One fewer letter", "practice.curriculum.less", .{ .x = inner_x, .y = y + 228, .w = 175, .h = 36 }, view.config.curriculum.stage != .real_text and view.config.curriculum.alphabet > 6)) view.config.curriculum.alphabet -= 1;
    if (ui.buttonEnabled(theme, "Add one letter", "practice.curriculum.more", .{ .x = inner_x + 187, .y = y + 228, .w = 170, .h = 36 }, view.config.curriculum.stage != .real_text and view.config.curriculum.alphabet < available.len)) view.config.curriculum.alphabet += 1;
    if (view.config.curriculum.stage == .shift) _ = dvui.checkbox(@src(), &view.config.curriculum.shifted_symbols, "Shifted punctuation", .{ .rect = .{ .x = inner_x, .y = y + 280, .w = inner_w, .h = 34 } });
    if (view.config.curriculum.stage == .layers or view.config.curriculum.stage == .modifiers) {
        const layers = try arena.alloc([]const u8, labels.layer_count);
        for (layers, 0..) |*name, index| name.* = try std.fmt.allocPrint(arena, "Layer {d}", .{index});
        var layer: usize = @min(view.config.curriculum.layer, labels.layer_count - 1);
        if (dvui.dropdown(@src(), layers, .{ .choice = &layer }, .{}, .{ .rect = .{ .x = inner_x, .y = y + 278, .w = 140, .h = 36 } })) view.config.curriculum.family = 0;
        view.config.curriculum.layer = @intCast(layer);
        if (view.config.curriculum.stage == .modifiers) {
            const modifiers = [_]u8{ 4, 64, 6, 66 };
            var variant = std.mem.indexOfScalar(u8, &modifiers, view.config.curriculum.modifiers) orelse 0;
            if (dvui.dropdown(@src(), &.{ "Option / left Alt", "AltGr / right Alt", "Shift + Option", "Shift + AltGr" }, .{ .choice = &variant }, .{}, .{ .rect = .{ .x = inner_x + 152, .y = y + 278, .w = 205, .h = 36 } })) {
                view.config.curriculum.modifiers = modifiers[variant];
                view.config.curriculum.family = 0;
            }
        }
    }
    if (view.config.curriculum.stage == .real_text) {
        var mode: usize = @backingInt(view.config.mode);
        if (dvui.dropdown(@src(), &.{ "English sentences", "Zig lessons" }, .{ .choice = &mode }, .{}, .{ .rect = .{ .x = inner_x, .y = y + 278, .w = 200, .h = 36 } })) view.config.mode = @fromBackingInt(@as(u1, @intCast(mode)));
        if (view.config.mode == .english) {
            var preset: usize = @backingInt(view.config.preset);
            if (dvui.dropdown(@src(), &.{ "Words", "Mixed case", "Punctuation" }, .{ .choice = &preset }, .{}, .{ .rect = .{ .x = inner_x + 212, .y = y + 278, .w = 160, .h = 36 } })) view.config.preset = @fromBackingInt(@as(u2, @intCast(preset)));
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
            _ = dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{ .rect = .{ .x = inner_x, .y = y + 324, .w = 100, .h = 34 }, .tag = "practice.curriculum.target" });
            view.config.curriculum.family = @intCast(choice);
            presentation.label("One new output at a time", .{ .x = inner_x + 112, .y = y + 324, .w = inner_w - 112, .h = 34 }, 14, theme.muted, null);
        } else _ = presentation.flowText("No compatible output here. Choose another family or stage.", inner_x, y + 322, inner_w, 14, theme.muted);
    }
    var expected: [26]u21 = undefined;
    var expected_count: usize = 0;
    if (view.config.curriculum.stage == .find_keys or view.config.curriculum.stage == .fluency or view.config.curriculum.stage == .real_text) {
        for (if (view.config.curriculum.stage == .real_text) available else learned) |cp| {
            expected[expected_count] = cp;
            expected_count += 1;
        }
    } else if (view.config.curriculum.family < members.len) {
        expected[0] = members[view.config.curriculum.family];
        expected_count = 1;
    }
    const matching = std.meta.eql(owner.cohortFor(view.config), history_cohort);
    const assessment = if (matching and history != null) curriculum.assess(view.config.curriculum, history.?.all, history.?.progress, expected[0..expected_count]) else curriculum.Assessment{ .missing = expected_count };
    presentation.label(if (assessment.ready) "Ready for a suggested next step" else try std.fmt.allocPrint(arena, "{d}/3 runs · {d} targets need more practice", .{ @min(3, assessment.runs), assessment.missing }), .{ .x = inner_x, .y = y + 376, .w = inner_w, .h = 28 }, 17, theme.text, null);
    _ = presentation.flowText(if (assessment.ready) "Advance when you feel ready. Your selected lesson never changes automatically." else if (view.config.curriculum.stage == .find_keys) "Aim for 20 opportunities per target at 97% first-pass success across three runs. No speed gate." else "Build three accurate runs and clean timing evidence before advancing.", inner_x, y + 412, inner_w, 14, theme.muted);
    const run_fraction = @as(f32, @floatFromInt(@min(3, assessment.runs))) / 3;
    const target_fraction = if (expected_count == 0) @as(f32, 0) else @as(f32, @floatFromInt(expected_count - assessment.missing)) / @as(f32, @floatFromInt(expected_count));
    const timing_fraction = if (view.config.curriculum.stage == .find_keys) @as(f32, 1) else @as(f32, @floatFromInt(assessment.timing_runs)) / 3;
    presentation.surface(.{ .x = inner_x, .y = y + 464, .w = inner_w, .h = 6 }, theme.control);
    presentation.surface(.{ .x = inner_x, .y = y + 464, .w = inner_w * (run_fraction + target_fraction + timing_fraction) / 3, .h = 6 }, ui.color(0x69BFA3));
    const options_y = y + 510;
    presentation.surface(.{ .x = x, .y = options_y, .w = content_w, .h = 180 }, theme.panel);
    presentation.label("Next exercise", .{ .x = inner_x, .y = options_y + 14, .w = inner_w, .h = 30 }, 20, theme.text, null);
    var assistance: usize = desktop.practice_help.choice(view.config);
    if (dvui.dropdown(@src(), &desktop.practice_help.choices, .{ .choice = &assistance }, .{}, .{ .rect = .{ .x = inner_x, .y = options_y + 62, .w = 210, .h = 38 } })) desktop.practice_help.apply(&view.config, assistance);
    _ = dvui.dropdown(@src(), if (view.config.mode == .english) &.{ "Short", "Normal", "Long" } else &desktop.practice.lesson_names, .{ .choice = &view.config.level }, .{}, .{ .rect = .{ .x = inner_x + 222, .y = options_y + 62, .w = 170, .h = 38 } });
    var primary = theme;
    primary.control = ui.color(0x287AF2);
    primary.text = dvui.Color.white;
    if (ui.button(primary, "Start lesson", "practice.curriculum.start", .{ .x = inner_x, .y = options_y + 120, .w = 165, .h = 40 })) {
        view.config.challenge = null;
        view.config.target_count = 0;
        var buffer: [8192]u8 = undefined;
        const text = owner.preview(&buffer, view.config) catch |err| {
            view.message = switch (err) {
                error.CurriculumAlphabetUnavailable => "Choose fewer base letters for this layout.",
                error.CurriculumFamilyUnavailable => "Choose another layer, modifier or stage; no supported output here.",
                error.CurriculumCorpusUnavailable => "Add a letter to provide more readable words.",
                error.CurriculumSpaceUnavailable => "Space needs a base-layer route before starting.",
                error.CurriculumRouteUnavailable => "Try a simpler preset; a character has no reachable route.",
                error.CurriculumLayoutUnavailable => "Select a known layout before starting.",
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
    if (ui.buttonEnabled(theme, if (view.config.curriculum.stage == .real_text) "Repeat real text" else "Suggested next step", "practice.curriculum.next", .{ .x = inner_x + 177, .y = options_y + 120, .w = 205, .h = 40 }, assessment.ready)) {
        view.config.curriculum = next(view.config.curriculum, labels);
        view.message = "Next lesson selected. Start when ready.";
    }
    const saved_x: f32 = if (wide) 20 else 0;
    const saved_y: f32 = if (wide) 610 else options_y + 210;
    if (history) |data| if (data.latest_curriculum) |record| if (ui.button(theme, "Resume saved lesson", "practice.curriculum.restore", .{ .x = saved_x, .y = saved_y, .w = 220, .h = 38 })) {
        view.config.curriculum = record.cohort.curriculum;
        view.config.mode = @fromBackingInt(@backingInt(record.cohort.family));
        view.config.level = if (record.cohort.family == .zig) record.cohort.lesson else record.cohort.length;
        view.config.preset = record.cohort.preset;
        view.config.assistance = record.cohort.assistance;
        view.config.hints = record.cohort.hints;
        view.config.hints.revealed = false;
        view.message = "Saved lesson restored for this layout and input source.";
    };
    if (ui.button(theme, "Free exercises", "practice.curriculum.free", .{ .x = if (wide) 20 else 236, .y = if (wide) saved_y + 52 else saved_y, .w = 200, .h = 38 })) {
        var config = owner.config;
        config.curriculum = .{};
        return .{ .free = config };
    }
    _ = presentation.flowText(view.message, 0, if (wide) 820 else 1130, width, 15, theme.text);
    return .none;
}
