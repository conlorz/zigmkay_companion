//! Optional hint settings and recall navigation, separate from exercise input.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const control = desktop.practice_controller;
pub const Review = struct { page: usize = 0, due_only: bool = true, message: []const u8 = "", retry: bool = false };
pub const Action = union(enum) { none, back, start: control.Config };
pub fn settings(config: *control.Config, theme: ui.Theme, viewport: dvui.Rect) !bool {
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = viewport });
    defer area.deinit();
    const bounds: dvui.Rect = .{ .w = viewport.w - 20, .h = 740 };
    const body = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = bounds.w, .h = bounds.h }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
    defer body.deinit();
    presentation.caption("Hint settings", .{ .w = bounds.w, .h = 44 }, 26, theme.text, "practice.help.title");
    presentation.paragraph("Full guidance, delayed hints, hints on request and hidden practice stay under your control. Show hint remains available during an exercise, including hidden recall.", .{ .y = 65, .w = bounds.w, .h = 80 }, 18, theme.text);
    var choice = desktop.practice_help.choice(config.*);
    if (dvui.dropdown(@src(), &desktop.practice_help.choices, .{ .choice = &choice }, .{}, .{ .rect = .{ .y = 160, .w = 220, .h = 40 } })) desktop.practice_help.apply(config, choice);
    const delays = [_]u16{ 250, 500, 1000, 1500, 2000, 3000, 5000, 10000 };
    var delay = std.mem.indexOfScalar(u16, &delays, config.hints.delay_ms) orelse 3;
    if (dvui.dropdown(@src(), &.{ "250 ms", "500 ms", "1 second", "1.5 seconds", "2 seconds", "3 seconds", "5 seconds", "10 seconds" }, .{ .choice = &delay }, .{}, .{ .rect = .{ .x = 235, .y = 160, .w = 180, .h = 40 } })) config.hints.delay_ms = delays[delay];
    _ = dvui.checkbox(@src(), &config.hints.adaptive, "Adapt delayed hints to my measured pace", .{ .rect = .{ .y = 222, .w = bounds.w, .h = 38 } });
    presentation.paragraph("Delayed hints wait while you hesitate, including before the first key, and stop counting during pauses. Adaptation uses your character timing when available, within half to twice the chosen delay.", .{ .y = 282, .w = bounds.w, .h = 160 }, 17, theme.muted);
    presentation.paragraph("Start a fresh run after applying a different policy. Help revealed during hidden recall is saved separately from fully hidden evidence.", .{ .y = 470, .w = bounds.w, .h = 130 }, 17, theme.text);
    return ui.button(theme, "Apply and return", "practice.help.apply", .{ .y = 630, .w = 200, .h = 42 });
}
pub fn reviews(view: *Review, owner: *control.Controller, history: ?*const desktop.practice_history.Query, failure: ?anyerror, saving: bool, theme: ui.Theme, bounds: dvui.Rect) !Action {
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = bounds, .tag = "practice.review" });
    defer area.deinit();
    const body = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = bounds.w - 20, .h = 920 }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
    defer body.deinit();
    const width = bounds.w - 20;
    const arena = dvui.currentWindow().arena();
    if (ui.button(theme, "Back to practice", "practice.review.back", .{ .w = 180, .h = 38 })) return .back;
    presentation.caption("Recall review · optional practice, no deadline", .{ .x = 190, .w = width - 190, .h = 38 }, 22, theme.text, null);
    _ = dvui.checkbox(@src(), &view.due_only, "Show due reviews only", .{ .rect = .{ .y = 52, .w = 250, .h = 34 } });
    const status = if (failure) |err| try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)}) else if (saving) "Loading review evidence…" else view.message;
    presentation.caption(status, .{ .x = 260, .y = 52, .w = width - 365, .h = 34 }, 15, theme.muted, null);
    if (failure != null and ui.button(theme, "Retry", "practice.review.retry", .{ .x = width - 100, .y = 52, .w = 95, .h = 34 })) view.retry = true;
    const data = (if (history) |h| h.retention else null) orelse {
        presentation.paragraph("Finish newly recorded scored exercises to build cue exposure evidence. Older runs retain their counts and are not treated as proof of unaided recall.", .{ .y = 110, .w = width, .h = 90 }, 20, theme.muted);
        return .none;
    };
    presentation.paragraph("A qualified recall needs hidden help, no revealed cue, positive duration, at least five clean uncued occurrences of the character and ≥97% uncued first-pass success. Visible layout practice is assistance. Suggested intervals are 1, 3, 7 and 14 days after qualifying recalls; these are initial policy choices for manual validation.", .{ .y = 104, .w = width, .h = 175 }, 16, theme.muted);
    var sorted = data.entries;
    std.mem.sort(desktop.practice_retention.Entry, sorted[0..data.count], {}, struct {
        fn less(_: void, a: desktop.practice_retention.Entry, b: desktop.practice_retention.Entry) bool {
            return if (a.dueAt() == b.dueAt()) a.cp < b.cp else a.dueAt() < b.dueAt();
        }
    }.less);
    var visible: [256]desktop.practice_retention.Entry = undefined;
    var count: usize = 0;
    for (sorted[0..data.count]) |entry| if ((!view.due_only or entry.due(data.now)) and entry.opportunities >= 5) {
        visible[count] = entry;
        count += 1;
    };
    const pages = @max(1, (count + 7) / 8);
    view.page = @min(view.page, pages - 1);
    if (count == 0) presentation.caption("No reviews due. Keep practicing, or show all tracked characters for an early check.", .{ .y = 290, .w = width, .h = 70 }, 20, theme.text, null);
    const first = view.page * 8;
    for (visible[first..@min(count, first + 8)], 0..) |entry, index| {
        var bytes: [4]u8 = undefined;
        var date: [32]u8 = undefined;
        const name = desktop.practice_view.glyph(entry.cp, true, &bytes);
        const label = try std.fmt.allocPrint(arena, "{s} · {d} samples · {d} cued / {d} uncued · {s}", .{ name, entry.opportunities, entry.cued, entry.uncued, if (entry.last_recall == null) "first unaided check" else try desktop.practice_results.dateLabel(entry.dueAt(), &date) });
        presentation.caption(label, .{ .y = 295 + @as(f32, @floatFromInt(index)) * 52, .w = width - 200, .h = 42 }, 16, theme.text, null);
        if (ui.button(theme, "Recall without guide", try std.fmt.allocPrint(arena, "practice.review.start.{d}", .{entry.cp}), .{ .x = width - 195, .y = 295 + @as(f32, @floatFromInt(index)) * 52, .w = 190, .h = 42 })) {
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
                view.message = "This target is unavailable in the current corpus/layout. Choose a matching guided lesson or another character.";
                return .none;
            };
            return .{ .start = config };
        }
    }
    if (ui.button(theme, "Next page", "practice.review.next", .{ .y = 730, .w = 140, .h = 38 })) view.page = (view.page + 1) % pages;
    presentation.caption(try std.fmt.allocPrint(arena, "{d} tracked characters · {d} recorded runs · {d} older/truncated runs lack cue evidence{s}", .{ data.count, data.eligible_runs, data.unknown_runs, if (data.truncated) " · character list limited to 256" else "" }), .{ .x = 150, .y = 730, .w = width - 150, .h = 38 }, 15, theme.muted, null);
    presentation.paragraph("A due review is an invitation to check recall, not evidence that you forgot. Recall lessons retain familiar words around the target. Show hint is always available; revealing help keeps that run out of fully hidden recall evidence.", .{ .y = 788, .w = width, .h = 90 }, 17, theme.text);
    return .none;
}
