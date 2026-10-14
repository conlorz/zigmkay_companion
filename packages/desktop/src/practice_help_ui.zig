//! Optional hint settings and recall navigation, separate from exercise input.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const control = desktop.practice_controller;
pub const Review = struct { page: usize = 0, due_only: bool = true, message: []const u8 = "", retry: bool = false, details: bool = false };
pub const Action = union(enum) { none, back, start: control.Config };
pub fn reviews(view: *Review, owner: *control.Controller, history: ?*const desktop.practice_history.Query, failure: ?anyerror, saving: bool, theme: ui.Theme, bounds: dvui.Rect) !Action {
    const data = if (history) |h| h.retention else null;
    const page = presentation.Page.init(bounds, 120, "practice.review", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    presentation.header("Recall review", "Optional practice. A due review is an invitation, not a deadline.", width, theme);
    if (ui.button(theme, "Back to practice", "practice.review.back", .{ .x = width - 165, .w = 165, .h = 38 })) return .back;
    _ = dvui.checkbox(@src(), &view.due_only, "Due reviews only", .{ .rect = .{ .y = 94, .w = 200, .h = 34 } });
    _ = dvui.checkbox(@src(), &view.details, "Review rules", .{ .rect = .{ .x = 220, .y = 94, .w = 190, .h = 34 } });
    var visible: [256]desktop.practice_retention.Entry = undefined;
    var count: usize = 0;
    if (data) |summary| {
        var sorted = summary.entries;
        std.mem.sort(desktop.practice_retention.Entry, sorted[0..summary.count], {}, struct {
            fn less(_: void, a: desktop.practice_retention.Entry, b: desktop.practice_retention.Entry) bool {
                return if (a.dueAt() == b.dueAt()) a.cp < b.cp else a.dueAt() < b.dueAt();
            }
        }.less);
        for (sorted[0..summary.count]) |entry| if ((!view.due_only or entry.due(summary.now)) and entry.opportunities >= 5) {
            visible[count] = entry;
            count += 1;
        };
    }
    const rows_y: f32 = if (view.details) 362 else 218;
    const row_count = @min(8, count);
    const footer_y = rows_y + @as(f32, @floatFromInt(@max(1, row_count))) * 90 + 28;
    page.ensureHeight(footer_y + 160);
    presentation.surface(.{ .y = 148, .w = width, .h = if (view.details) 190 else 50 }, theme.panel);
    _ = presentation.flowText("Hidden recall keeps familiar words around the target. Show hint is always available.", 20, 162, width - 40, 14, theme.muted);
    if (view.details) _ = presentation.flowText("A qualifying check needs hidden help, no revealed cue, positive duration, five clean uncued occurrences and ≥97% uncued first-pass success. Visible layout practice is assistance. Suggested intervals are 1, 3, 7 and 14 days. Older and truncated runs cannot establish unaided recall.", 20, 218, width - 40, 14, theme.muted);
    const pages = @max(1, (count + 7) / 8);
    view.page = @min(view.page, pages - 1);
    const first = view.page * 8;
    if (count == 0) {
        presentation.surface(.{ .y = rows_y, .w = width, .h = 100 }, theme.panel);
        _ = presentation.flowText(if (data == null) "Finish newly recorded scored exercises to build review evidence. Older counts stay available." else "No reviews due. Keep practicing, or show all tracked characters for an early check.", 24, rows_y + 26, width - 48, 17, theme.text);
    }
    for (visible[first..@min(count, first + 8)], 0..) |entry, index| {
        const y = rows_y + @as(f32, @floatFromInt(index)) * 90;
        presentation.surface(.{ .y = y, .w = width, .h = 78 }, theme.panel);
        var bytes: [4]u8 = undefined;
        var date: [32]u8 = undefined;
        presentation.label(desktop.practice_view.glyph(entry.cp, true, &bytes), .{ .x = 24, .y = y + 16, .w = 52, .h = 42 }, 28, theme.text, null);
        presentation.label(try std.fmt.allocPrint(arena, "{d} samples · {d} cued · {d} uncued", .{ entry.opportunities, entry.cued, entry.uncued }), .{ .x = 92, .y = y + 12, .w = width - 292, .h = 24 }, 14, theme.text, null);
        const due_label = if (entry.last_recall == null) "First unaided check" else try std.fmt.allocPrint(arena, "Suggested review: {s} (UTC)", .{(try desktop.practice_results.dateLabel(entry.dueAt(), &date))[0..10]});
        presentation.label(due_label, .{ .x = 92, .y = y + 43, .w = width - 292, .h = 22 }, 13, theme.muted, null);
        if (ui.button(theme, "Practice recall", try std.fmt.allocPrint(arena, "practice.review.start.{d}", .{entry.cp}), .{ .x = width - 180, .y = y + 20, .w = 160, .h = 38 })) {
            var config = owner.config;
            config.challenge = null;
            config.assistance = .hidden;
            config.hints = .{};
            config.targets[0] = entry.cp;
            config.target_count = 1;
            config.curriculum = entry.context.curriculum;
            config.preset = entry.context.preset;
            if (entry.context.family == .zig) {
                config.mode = .zig;
                config.level = entry.context.lesson;
                config.target_count = 0;
            } else config.mode = .english;
            if (config.curriculum.version == 0 and config.mode == .english) config.preset = if (entry.cp >= 'a' and entry.cp <= 'z') .words else if (entry.cp >= 'A' and entry.cp <= 'Z') .mixed_case else .punctuation;
            var buffer: [8192]u8 = undefined;
            _ = owner.preview(&buffer, config) catch {
                view.message = "This target needs a matching corpus or guided lesson.";
                return .none;
            };
            return .{ .start = config };
        }
    }
    if (pages > 1 and ui.button(theme, "Next page", "practice.review.next", .{ .y = footer_y, .w = 140, .h = 36 })) view.page = (view.page + 1) % pages;
    if (data) |summary| _ = presentation.flowText(try std.fmt.allocPrint(arena, "{d} characters · {d} recorded runs · {d} runs lack complete cue evidence{s}", .{ summary.count, summary.eligible_runs, summary.unknown_runs, if (summary.truncated) " · list limited to 256" else "" }), if (pages > 1) 160 else 0, footer_y, width - (if (pages > 1) @as(f32, 160) else 0), 13, theme.muted);
    const status = if (failure) |err| try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)}) else if (saving) "Loading review evidence…" else view.message;
    _ = presentation.flowText(status, 0, footer_y + 58, width - 110, 14, theme.muted);
    if (failure != null and ui.button(theme, "Retry", "practice.review.retry", .{ .x = width - 100, .y = footer_y + 58, .w = 100, .h = 34 })) view.retry = true;
    return .none;
}
pub fn settings(config: *control.Config, theme: ui.Theme, viewport: dvui.Rect) !bool {
    const wide = viewport.w >= 1100;
    const page = presentation.Page.init(viewport, if (wide) 640 else 850, "practice.help.title", theme);
    defer page.deinit();
    const width = page.width;
    presentation.header("Hint settings", "Choose the amount of help. Show hint remains available during every exercise.", width, theme);
    const left_w = if (wide) (width - 20) * 0.62 else width;
    presentation.surface(.{ .y = 96, .w = left_w, .h = 400 }, theme.panel);
    presentation.label("How much help?", .{ .x = 24, .y = 114, .w = left_w - 48, .h = 30 }, 20, theme.text, null);
    presentation.label("Hint policy", .{ .x = 24, .y = 166, .w = left_w - 48, .h = 24 }, 14, theme.muted, null);
    var choice = desktop.practice_help.choice(config.*);
    if (dvui.dropdown(@src(), &desktop.practice_help.choices, .{ .choice = &choice }, .{}, .{ .rect = .{ .x = 24, .y = 200, .w = 250, .h = 40 } })) desktop.practice_help.apply(config, choice);
    if (config.assistance == .guided and config.hints.policy == .delayed) {
        const delays = [_]u16{ 250, 500, 1000, 1500, 2000, 3000, 5000, 10000 };
        var delay = std.mem.indexOfScalar(u16, &delays, config.hints.delay_ms) orelse 3;
        presentation.label("Wait before showing a hint", .{ .x = 24, .y = 268, .w = left_w - 48, .h = 24 }, 14, theme.muted, null);
        if (dvui.dropdown(@src(), &.{ "250 ms", "500 ms", "1 second", "1.5 seconds", "2 seconds", "3 seconds", "5 seconds", "10 seconds" }, .{ .choice = &delay }, .{}, .{ .rect = .{ .x = 24, .y = 302, .w = 175, .h = 38 } })) config.hints.delay_ms = delays[delay];
        _ = dvui.checkbox(@src(), &config.hints.adaptive, "Adapt to my pace", .{ .rect = .{ .x = 215, .y = 302, .w = left_w - 239, .h = 38 } });
        _ = presentation.flowText("The delay counts hesitation, not paused time. Adaptation uses your recorded character timing.", 24, 374, left_w - 48, 15, theme.muted);
    } else _ = presentation.flowText(switch (config.assistance) {
        .hidden => "The keyboard stays hidden until you request help.",
        .layout_only => "See the layout without predictive highlights. Request a hint whenever you need one.",
        .guided => if (config.hints.policy == .on_request) "Highlights appear when you choose Show hint." else "Highlights stay available as you type.",
    }, 24, 280, left_w - 48, 17, theme.muted);
    const note_x = if (wide) left_w + 20 else 0;
    const note_y: f32 = if (wide) 96 else 516;
    const note_w = if (wide) width - note_x else width;
    presentation.surface(.{ .x = note_x, .y = note_y, .w = note_w, .h = 200 }, theme.panel);
    presentation.label("Help stays under your control", .{ .x = note_x + 24, .y = note_y + 18, .w = note_w - 48, .h = 28 }, 18, theme.text, null);
    _ = presentation.flowText("Start a fresh run to apply a different policy. Revealing help during hidden recall keeps that run separate from fully hidden evidence.", note_x + 24, note_y + 68, note_w - 48, 15, theme.muted);
    var primary = theme;
    primary.control = ui.color(0x287AF2);
    primary.text = dvui.Color.white;
    return ui.button(primary, "Apply and return", "practice.help.apply", .{ .y = if (wide) 520 else 740, .w = 200, .h = 42 });
}
