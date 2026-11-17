//! Character statistics projected onto frozen proven routes, independent of live layers.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const results = desktop.practice_results;
pub const View = struct {
    scope: usize = 0,
    layer: usize = 0,
    variant: usize = 0,
    selected: ?u21 = null,
    reviewed: ?results.Record = null,
    history_open: bool = false,
    refresh: bool = false,
    retry: bool = false,
    clear: bool = false,
    confirm_clear: bool = false,
    cleared: bool = false,
    before: ?results.Record = null,
    message: []const u8 = "",
    character_page: usize = 0,
    heatmap_mode: usize = 0,
    sort: usize = 0,
    more_details: bool = false,
    diagnostics: bool = false,
};
pub const Action = union(enum) { none, new_exercise, drill: desktop.practice_controller.Config };
fn glyph(cp: u21, buffer: *[4]u8) []const u8 {
    return switch (cp) {
        ' ' => "Space",
        '\n' => "Enter",
        '\t' => "Tab",
        else => desktop.practice_view.glyph(cp, true, buffer),
    };
}
pub fn color(stat: ?results.Stat, light: bool) dvui.Color {
    const value = stat orelse return ui.color(if (light) 0xDFE3E8 else 0x464B55);
    if (value.opportunities == 0) return ui.color(if (light) 0xDFE3E8 else 0x464B55);
    return ui.color(if (value.misses == 0) (if (light) @as(u24, 0xC5EBDC) else 0x245C4D) else if (value.rate() <= 10) (if (light) @as(u24, 0xD4E6FF) else 0x264F80) else if (value.rate() <= 25) (if (light) @as(u24, 0xF8DEA3) else 0x775A24) else (if (light) @as(u24, 0xF4BEBF) else 0x853D48));
}
pub fn select(view: *View, stat: results.Stat) void {
    view.selected = stat.cp;
    if (stat.route_count > 0) {
        view.layer = stat.routes[0].layer;
        view.variant = switch (stat.routes[0].modifiers) {
            2 => 1,
            4 => 2,
            6 => 3,
            64 => 4,
            66 => 5,
            else => 0,
        };
    }
}
pub fn draw(owner: *desktop.practice_controller.Controller, view: *View, record: *const results.Record, history: ?*const desktop.practice_history.Query, history_matches: bool, frame: anytype, theme: ui.Theme, bounds: dvui.Rect, saving: bool, failure: ?anyerror) !Action {
    const page = presentation.Page.init(bounds, if (bounds.w >= 1100) 1030 else 1480, "practice.rundown", theme);
    defer page.deinit();
    const arena = dvui.currentWindow().arena();
    const width = page.width;
    const wide = bounds.w >= 1100;
    const keyboard_width = if (wide) (width - 20) * 0.56 else width;
    const table_x = if (wide) keyboard_width + 20 else 0;
    const table_y: f32 = if (wide) 360 else 780;
    const table_width = width - table_x;
    const light = theme.bg.r > 100;
    var current: results.Aggregate = .{};
    // This run remains visible even when unscored; aggregate defaults exclude it.
    var scored_copy = record.*;
    scored_copy.scored = true;
    try current.add(&scored_copy);
    var historical: results.Aggregate = .{};
    if (history_matches and history != null and view.scope != 0) {
        historical = if (view.scope == 1) history.?.recent else history.?.all;
        const queried = history.?.requested_id;
        var contains = queried != null and std.mem.eql(u8, &queried.?, &record.id) and history.?.contains_requested;
        if (view.scope == 1) {
            contains = false;
            for (history.?.recent_ids[0..history.?.recent_count]) |id| if (std.mem.eql(u8, &id, &record.id)) {
                contains = true;
            };
        }
        if (!contains and record.scored and view.reviewed == null and !view.cleared) {
            if (view.scope == 1 and historical.runs == 10) if (history.?.oldest_recent) |oldest| historical.remove(&oldest);
            try historical.add(record);
        }
    }
    const aggregate = if (view.scope == 0) &current else &historical;
    var missed: u64 = 0;
    for (record.stats[0..record.stat_count]) |stat| missed += stat.misses;
    const success = if (record.matched == 0) @as(f64, 100) else 100 * @as(f64, @floatFromInt(record.matched - missed)) / @as(f64, @floatFromInt(record.matched));
    const metrics = [_][]const u8{
        try std.fmt.allocPrint(arena, "{d:.0} WPM", .{record.wpm()}),
        try std.fmt.allocPrint(arena, "{d:.1}%", .{record.accuracy()}),
        try std.fmt.allocPrint(arena, "{d:.1}%", .{success}),
    };
    presentation.header(if (record.status == .stopped) "Exercise stopped" else "Exercise complete", try std.fmt.allocPrint(arena, "{t} · {t} · {d} corrections · {d:.1}s active", .{ record.cohort.preset, record.cohort.assistance, record.corrections, @as(f64, @floatFromInt(record.active_us)) / 1_000_000 }), width, theme);
    const new_requested = ui.buttonEnabled(theme, "New exercise", "practice.result.new.top", .{ .x = width - 165, .w = 165, .h = 38 }, !owner.save_blocked);
    for (metrics, 0..) |metric, index| {
        const card_w = (width - 32) / 3;
        presentation.metric(([_][]const u8{ "Typing speed", "Attempt accuracy", "First-pass success" })[index], metric, ([_][]const u8{ "This exercise", "Correct attempts / all attempts", "Correct first tries / opportunities" })[index], .{ .x = @as(f32, @floatFromInt(index)) * (card_w + 16), .y = 92, .w = card_w, .h = 116 }, theme);
    }
    _ = dvui.dropdown(@src(), &.{ "This run", "Last 10 runs", "All history" }, .{ .choice = &view.scope }, .{}, .{ .rect = .{ .y = 228, .w = 160, .h = 36 }, .tag = "practice.scope" });
    var baseline: results.Aggregate = .{};
    if (history_matches and history != null and record.scored) {
        baseline = history.?.recent;
        for (history.?.recent_ids[0..history.?.recent_count]) |id| if (std.mem.eql(u8, &id, &record.id)) {
            baseline.remove(record);
            break;
        };
    }
    const comparison = if (baseline.runs > 0 and baseline.active_us > 0 and record.active_us > 0)
        try std.fmt.allocPrint(arena, "{d:.1} WPM vs {d} recent matching runs", .{ record.wpm() - baseline.wpm(), baseline.runs })
    else
        "No matching speed baseline yet";
    _ = presentation.flowText(comparison, 180, 234, width - 180, 14, theme.muted);
    const variants = desktop.practice.route_modifiers;
    var layer_count: usize = record.layer_count;
    for (record.stats[0..record.stat_count]) |stat| for (stat.routes[0..stat.route_count]) |route| {
        layer_count = @max(layer_count, @as(usize, route.layer) + 1);
    };
    const names = try arena.alloc([]const u8, layer_count);
    for (names, 0..) |*name, layer| name.* = try std.fmt.allocPrint(arena, "Layer {d}", .{layer});
    view.layer = @min(view.layer, layer_count - 1);
    presentation.surface(.{ .y = 360, .w = keyboard_width, .h = 400 }, theme.panel);
    presentation.surface(.{ .x = table_x, .y = table_y, .w = table_width, .h = 400 }, theme.panel);
    presentation.label("Where errors happened", .{ .x = 20, .y = 374, .w = keyboard_width - 40, .h = 30 }, 20, theme.text, null);
    _ = dvui.dropdown(@src(), names, .{ .choice = &view.layer }, .{}, .{ .rect = .{ .x = 20, .y = 418, .w = 105, .h = 34 }, .tag = "practice.result.layer" });
    _ = dvui.dropdown(@src(), &.{ "Unshifted", "Shift", "Option / left Alt", "Shift + left Alt", "AltGr / right Alt", "Shift + AltGr" }, .{ .choice = &view.variant }, .{}, .{ .rect = .{ .x = 137, .y = 418, .w = 185, .h = 34 }, .tag = "practice.result.modifiers" });
    _ = dvui.dropdown(@src(), &.{ "Miss rate", "Exposure" }, .{ .choice = &view.heatmap_mode }, .{}, .{ .rect = .{ .x = 334, .y = 418, .w = 135, .h = 34 }, .tag = "practice.heatmap.mode" });
    presentation.label("Characters to review", .{ .x = table_x + 20, .y = table_y + 14, .w = table_width - 40, .h = 30 }, 20, theme.text, null);
    _ = dvui.dropdown(@src(), &.{ "Weakness", "Character", "Exposure" }, .{ .choice = &view.sort }, .{}, .{ .rect = .{ .x = table_x + 20, .y = table_y + 58, .w = 160, .h = 34 }, .tag = "practice.characters.sort" });
    var focus: [5]u21 = undefined;
    const recommended = aggregate.targets(&focus);
    const coaching = if (!record.scored and view.scope == 0) "Unscored run. Start a scored exercise when ready." else if (record.cohort.hints.revealed) "Help was shown; this stays separate from hidden recall." else if (recommended.len == 0) "Keep practicing to build evidence for a targeted drill." else "A short drill can help with these repeated misses.";
    presentation.surface(.{ .y = 284, .w = width, .h = 56 }, ui.color(if (light) 0xC5EBDC else 0x24463B));
    _ = presentation.flowText(coaching, 20, 300, width - 260, 14, theme.text);
    const keyboard_y: f32 = 470;
    const keyboard_h: f32 = 224;
    var drew_geometry = false;
    if (frame) |physical| if (physical.geometry.len > 0 and std.mem.eql(u8, &record.cohort.mapping, &owner.cohort.mapping) and std.mem.eql(u8, &record.cohort.behavior, &owner.cohort.behavior)) {
        const fitted = desktop.physical_view.fit(physical.geometry, .{ .x = 14, .y = keyboard_y, .w = keyboard_width - 28, .h = keyboard_h });
        for (physical.geometry) |key| {
            const placed = fitted.place(key);
            var found: ?results.Stat = null;
            var glyphs: std.Io.Writer.Allocating = .init(arena);
            for (aggregate.stats[0..aggregate.stat_count]) |stat| {
                var matches = false;
                for (stat.routes[0..stat.route_count]) |route| if (route.key == key.key_index and route.layer == view.layer and route.modifiers == variants[view.variant]) {
                    matches = true;
                };
                if (matches) {
                    var bytes: [4]u8 = undefined;
                    try glyphs.writer.print("{s} ", .{glyph(stat.cp, &bytes)});
                    if (found == null) found = stat;
                }
            }
            // Labels are for display only. Statistics always use frozen routes.
            const label = if (found != null and found.?.cp == ' ') "SPC" else if (found != null and found.?.cp == '\n') "RET" else if (found != null and found.?.cp == '\t') "TAB" else if (glyphs.written().len > 0) glyphs.written() else if (view.layer < physical.labels.layer_count) physical.labels.lookup(view.layer, key.key_index, @bitCast(variants[view.variant])).label orelse physical.labels.lookup(view.layer, key.key_index, @bitCast(variants[view.variant])).caption orelse "·" else "·";
            var options = ui.options(theme, ui.rect(placed.rect), @max(8, @min(12, placed.rect.h / 4)));
            options.rect.?.x += 3;
            options.rect.?.y += 3;
            options.rect.?.w -= 6;
            options.rect.?.h -= 6;
            const heat_stat: ?results.Stat = if (view.heatmap_mode == 0) found else if (found) |stat| .{ .opportunities = 100, .misses = if (stat.opportunities < 5) 40 else if (stat.opportunities < 20) 20 else if (stat.opportunities < 50) 5 else 0 } else null;
            options.color_fill = .{ .color = color(heat_stat, light) };
            options.color_text = .{ .color = theme.text };
            options.background = true;
            options.padding = .all(2);
            options.id_extra = placed.id;
            options.rotation = placed.rotation;
            options.tag = try std.fmt.allocPrint(arena, "practice.heatmap.{d}", .{key.key_index});
            const text = if (found) |stat| try std.fmt.allocPrint(arena, "{s}\n{d}/{d}{s}", .{ label, stat.misses, stat.opportunities, if (stat.opportunities < 5) "*" else "" }) else label;
            if (dvui.button(@src(), text, .{}, options)) if (found) |stat| {
                view.selected = stat.cp;
            };
        }
        drew_geometry = true;
    };
    if (!drew_geometry) presentation.caption("Physical routes unavailable for this layout snapshot. Use the character list below.", .{ .y = keyboard_y, .w = width, .h = keyboard_h }, 17, theme.muted, null);
    const legend_y = keyboard_y + keyboard_h + 6;
    const legend = if (view.heatmap_mode == 0) [_][]const u8{ "Unpracticed", "0% misses", "1–10%", "11–25%", ">25%" } else [_][]const u8{ "Unpracticed", "50+ samples", "20–49", "5–19", "1–4 samples" };
    for (legend, 0..) |label, index| {
        const x = @as(f32, @floatFromInt(index)) * keyboard_width / 5;
        const swatch = if (index == 0) null else results.Stat{ .opportunities = 100, .misses = ([_]u64{ 0, 0, 5, 20, 40 })[index] };
        dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5 }, .{ .rect = .{ .x = x, .y = legend_y, .w = keyboard_width / 5 - 5, .h = 26 }, .background = true, .color_fill = .{ .color = color(swatch, light) }, .color_text = .{ .color = theme.text }, .id_extra = index });
    }

    const page_size: usize = 6;
    const pages = @max(1, (aggregate.stat_count + page_size - 1) / page_size);
    view.character_page = @min(view.character_page, pages - 1);
    const first = view.character_page * page_size;
    const last = @min(aggregate.stat_count, first + page_size);
    var sorted = aggregate.stats;
    std.mem.sort(results.Stat, sorted[0..aggregate.stat_count], view.sort, struct {
        fn less(order: usize, a: results.Stat, b: results.Stat) bool {
            if (order == 1) return a.cp < b.cp;
            if (order == 2) return if (a.opportunities == b.opportunities) a.cp < b.cp else a.opportunities > b.opportunities;
            return if (a.rank() == b.rank()) a.cp < b.cp else a.rank() > b.rank();
        }
    }.less);
    for (sorted[first..last], 0..) |stat, index| {
        var bytes: [4]u8 = undefined;
        var confusion: ?results.Substitution = null;
        for (aggregate.substitutions[0..aggregate.substitution_count]) |sub| if (sub.expected == stat.cp and sub.count > 0 and (confusion == null or sub.count > confusion.?.count)) {
            confusion = sub;
        };
        var typed_bytes: [4]u8 = undefined;
        const pair = if (confusion) |sub| try std.fmt.allocPrint(arena, " → {s} ×{d}", .{ glyph(sub.typed, &typed_bytes), sub.count }) else "";
        const label = try std.fmt.allocPrint(arena, "{s}    {d:.0}%    {d} samples{s}{s}", .{ glyph(stat.cp, &bytes), 100 - stat.rate(), stat.opportunities, if (stat.opportunities < 5) "*" else "", pair });
        var key_theme = theme;
        key_theme.control = if (view.selected == stat.cp) color(stat, light) else theme.control;
        if (presentation.rowButton(key_theme, label, try std.fmt.allocPrint(arena, "practice.character.{d}", .{stat.cp}), .{ .x = table_x + 20, .y = table_y + 104 + @as(f32, @floatFromInt(index)) * 40, .w = table_width - 40, .h = 34 }, 15)) select(view, stat);
    }
    if (pages > 1 and ui.button(theme, "More →", "practice.characters.more", .{ .x = width - 130, .y = table_y + 352, .w = 110, .h = 32 })) view.character_page = (view.character_page + 1) % pages;
    const detail_y = table_y + 420;
    var detail: std.Io.Writer.Allocating = .init(arena);
    if (view.selected) |cp| {
        for (aggregate.stats[0..aggregate.stat_count]) |stat| if (stat.cp == cp) {
            var bytes: [4]u8 = undefined;
            try detail.writer.print("«{s}» · {d}/{d} missed · {d:.1}% · {d} retry errors{s}", .{ glyph(cp, &bytes), stat.misses, stat.opportunities, stat.rate(), stat.retries, if (stat.opportunities < 5) " · limited evidence" else "" });
            if (view.more_details and aggregate.cue_known_runs > 0) try detail.writer.print(" · {d} cued / {d} uncued ({d}/{d} runs tracked)", .{ stat.cued, stat.uncued, aggregate.cue_known_runs, aggregate.runs });
            if (stat.route_count == 0) try detail.writer.writeAll(" · no proven route");
            if (view.more_details) for (stat.routes[0..stat.route_count]) |route| try detail.writer.print(" · L{d} key {d} {s}", .{ route.layer, route.key, switch (route.modifiers) {
                2 => "Shift",
                4 => "left Alt",
                6 => "Shift+left Alt",
                64 => "AltGr",
                66 => "Shift+AltGr",
                else => "",
            } });
            if (stat.routes_truncated) try detail.writer.writeAll(" · additional routes omitted");
            // Per-run substitution counts are explicit; aggregates do not invent them.
            for (aggregate.substitutions[0..aggregate.substitution_count]) |sub| if (sub.expected == cp and sub.count > 0) {
                var typed: [4]u8 = undefined;
                try detail.writer.print(" · typed «{s}» {d}×", .{ desktop.practice_view.glyph(sub.typed, true, &typed), sub.count });
            };
        };
    } else try detail.writer.writeAll("Character cells: first-pass success · n=opportunities · * limited evidence. Select for confusion counts.");
    if (aggregate.substitutions_truncated) try detail.writer.writeAll(" · substitution detail limited to 256 observed pairs");
    const detail_height = presentation.flowText(detail.written(), 0, detail_y, width, 14, theme.muted);
    const actions_y = detail_y + detail_height + 24;
    page.ensureHeight(actions_y + 150);
    var action: Action = if (new_requested) .new_exercise else .none;
    var primary = theme;
    primary.control = ui.color(0x287AF2);
    primary.text = dvui.Color.white;
    if ((record.scored or view.scope != 0) and recommended.len > 0 and ui.buttonEnabled(primary, "Practice weak spots", "practice.drill", .{ .x = width - 220, .y = 292, .w = 200, .h = 38 }, !owner.save_blocked)) {
        var config = owner.config;
        config.challenge = null;
        config.target_count = 0;
        if (record.scored or view.scope != 0) {
            const targets = aggregate.targets(&config.targets);
            config.target_count = @intCast(targets.len);
            // A selected confusion overrides the broad drill only with repeated
            // substitution evidence and sufficient expected-character exposure.
            if (view.selected) |cp| for (aggregate.stats[0..aggregate.stat_count]) |stat| {
                if (stat.cp != cp or !stat.supportedWeakness()) continue;
                var best: ?results.Substitution = null;
                for (aggregate.substitutions[0..aggregate.substitution_count]) |sub| {
                    if (sub.expected == cp and sub.count >= 2 and sub.typed != cp and (best == null or sub.count > best.?.count)) best = sub;
                }
                if (best) |pair| {
                    config.targets[0] = cp;
                    config.targets[1] = pair.typed;
                    config.target_count = 2;
                }
            };
        }
        if (config.target_count == 0) view.message = "Not enough evidence yet (5 opportunities and 2 misses). Start a fresh exercise." else if (config.mode != .english) view.message = "Personalized drills currently use the English corpus." else {
            var buffer: [8192]u8 = undefined;
            _ = owner.preview(&buffer, config) catch |err| {
                view.message = if (err == error.HarderPresetRequired) "Choose Mixed case or Punctuation to practice these targets." else "The corpus cannot cover all selected targets with this preset.";
                config.target_count = 0;
            };
            if (config.target_count > 0) action = .{ .drill = config };
        }
    }
    if (ui.buttonEnabled(theme, "New exercise", "practice.result.new", .{ .y = actions_y, .w = 145, .h = 38 }, !owner.save_blocked)) action = .new_exercise;
    if (ui.button(theme, "Saved history", "practice.history", .{ .x = 155, .y = actions_y, .w = 145, .h = 38 })) {
        view.history_open = !view.history_open;
        view.refresh = true;
        view.before = null;
    }
    if (ui.button(theme, "More details", "practice.result.more", .{ .x = 310, .y = actions_y, .w = 140, .h = 38 })) view.more_details = !view.more_details;
    if (view.more_details and ui.button(theme, "Timing details", "practice.result.timing", .{ .x = 460, .y = actions_y, .w = 155, .h = 38 })) {
        view.diagnostics = true;
        view.refresh = true;
    }
    if (view.more_details and !view.confirm_clear and ui.button(theme, "Clear history", "practice.history.clear", .{ .x = width - 140, .y = actions_y + 78, .w = 140, .h = 30 })) view.confirm_clear = true;
    var focus_note: std.Io.Writer.Allocating = .init(arena);
    if (record.cohort.family == .english) try focus_note.writer.print("Seed {d} · generation / corpus / coverage v1 · {d} outside-reference errors", .{ record.seed, record.outside_errors }) else try focus_note.writer.print("Zig lesson {s} · original text corpus v1 · {d} outside-reference errors", .{ desktop.practice.lesson_ids[record.cohort.lesson], record.outside_errors });
    if (record.target_count > 0) {
        try focus_note.writer.writeAll(" · drill focus: ");
        for (record.targets[0..record.target_count]) |cp| {
            var bytes: [4]u8 = undefined;
            try focus_note.writer.print("{s} ", .{glyph(cp, &bytes)});
        }
    }
    if (view.more_details and !view.confirm_clear and !view.history_open) {
        const note_height = presentation.flowText(focus_note.written(), 0, actions_y + 86, width - 180, 13, theme.muted);
        page.ensureHeight(actions_y + 110 + note_height);
    }
    const save_status = if (failure) |err| try std.fmt.allocPrint(arena, "History save/read failed: {s}. In-memory results remain available.", .{@errorName(err)}) else if (saving) "Saving / loading history…" else if (history != null and history.?.rejected > 0) "Some history files could not be read; scopes are incomplete. Original files are preserved." else view.message;
    _ = presentation.flowText(save_status, 0, actions_y + 48, width - 110, 13, theme.muted);
    if (failure != null and ui.button(theme, "Retry", "practice.history.retry", .{ .x = width - 105, .y = actions_y + 43, .w = 100, .h = 30 })) view.retry = true;
    if (view.confirm_clear) {
        page.ensureHeight(actions_y + 282);
        presentation.surface(.{ .y = actions_y + 92, .w = width, .h = 158 }, theme.panel);
        presentation.label("Clear saved practice runs?", .{ .x = 20, .y = actions_y + 108, .w = width - 40, .h = 30 }, 18, theme.text, null);
        _ = presentation.flowText("Projects and preferences are preserved.", 20, actions_y + 148, width - 40, 14, theme.muted);
        if (ui.button(theme, "Clear runs", "practice.history.confirm", .{ .x = 20, .y = actions_y + 192, .w = 140, .h = 38 })) {
            view.clear = true;
            view.cleared = true;
            view.scope = 0;
            view.confirm_clear = false;
            view.reviewed = null;
        }
        if (ui.button(theme, "Cancel", "practice.history.cancel", .{ .x = 174, .y = actions_y + 192, .w = 140, .h = 38 })) view.confirm_clear = false;
    } else if (view.history_open and history != null) {
        const history_y = actions_y + 100;
        const history_h = 116 + @as(f32, @floatFromInt(history.?.page_count)) * 42;
        page.ensureHeight(history_y + history_h + 32);
        presentation.surface(.{ .y = history_y, .w = width, .h = history_h }, theme.panel);
        presentation.label("Saved exercises", .{ .x = 20, .y = history_y + 16, .w = width - 40, .h = 30 }, 20, theme.text, null);
        if (ui.button(theme, "Current run", "practice.history.current", .{ .x = 20, .y = history_y + 58, .w = 150, .h = 34 })) {
            view.reviewed = null;
            view.scope = 0;
        }
        for (history.?.page[0..history.?.page_count], 0..) |saved, index| {
            var date: [32]u8 = undefined;
            const label = try std.fmt.allocPrint(arena, "{s} · {d:.0} WPM · {d:.1}% · {s}", .{ try results.dateLabel(saved.timestamp, &date), saved.wpm(), saved.accuracy(), if (saved.scored) "scored" else "unscored" });
            if (presentation.rowButton(theme, label, try std.fmt.allocPrint(arena, "practice.history.run.{d}", .{index}), .{ .x = 20, .y = history_y + 108 + @as(f32, @floatFromInt(index)) * 42, .w = width - 40, .h = 34 }, 15)) {
                view.reviewed = saved;
                view.scope = 0;
            }
        }
        if (history.?.page_count == 10 and ui.button(theme, "Older runs →", "practice.history.older", .{ .x = width - 165, .y = history_y + 58, .w = 145, .h = 34 })) {
            view.before = history.?.page[9];
            view.refresh = true;
        }
    }
    return action;
}
