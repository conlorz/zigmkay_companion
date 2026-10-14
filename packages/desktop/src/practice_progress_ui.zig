//! Native progress view; aggregate counts and chronological points share a cohort.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
pub const View = struct { smoothing: bool = false, goal: usize = 1, tab: usize = 0, range: usize = 0, matrix: usize = 0, selected: ?u21 = null, inspect: ?[16]u8 = null, message: []const u8 = "", retry: bool = false };
fn compactButton(theme: ui.Theme, text: []const u8, tag: []const u8, rect: dvui.Rect) bool {
    var options = ui.options(theme, rect, 13);
    options.padding = .all(2);
    options.tag = tag;
    options.id_extra = @truncate(std.hash.Wyhash.hash(0, tag));
    return dvui.button(@src(), text, .{}, options);
}
fn chart(data: *const desktop.practice_progress.Summary, theme: ui.Theme, rect: dvui.Rect, accuracy: bool, smoothing: bool) void {
    if (data.count == 0) return;
    const first = data.points[data.count - 1].timestamp;
    const span = @max(1, (@as(f64, @floatFromInt(data.points[0].timestamp)) - @as(f64, @floatFromInt(first))) / 3_600_000_000_000);
    var ymax: f64 = if (accuracy) 101 else 10;
    if (!accuracy) for (data.points[0..data.count]) |point| {
        ymax = @max(ymax, point.wpm * 1.1);
    };
    var xaxis: dvui.PlotWidget.Axis = .{ .name = "Hours from first displayed run (UTC)", .min = -span * 0.01, .max = span * 1.01 };
    var yaxis: dvui.PlotWidget.Axis = .{ .name = if (accuracy) "Attempt accuracy (%)" else "Speed (WPM)", .min = 0, .max = ymax };
    const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{ .rect = rect, .id_extra = @intFromBool(accuracy), .background = true, .color_fill = .{ .color = theme.panel } });
    defer plot.deinit();
    var previous: ?struct { x: f64, y: f64, timestamp: i64 } = null;
    var index = data.count;
    while (index > 0) {
        index -= 1;
        const point = data.points[index];
        if (point.active_us == 0) {
            previous = null;
            continue;
        }
        const x = (@as(f64, @floatFromInt(point.timestamp)) - @as(f64, @floatFromInt(first))) / 3_600_000_000_000;
        const y = if (accuracy) point.accuracy else point.wpm;
        plot.bar(.{ .x = x - span / 400, .y = @max(0, y - ymax / 200), .w = span / 200, .h = ymax / 100, .color = ui.color(0x548FF5) });
        if (previous) |prior| if (@as(f64, @floatFromInt(point.timestamp)) - @as(f64, @floatFromInt(prior.timestamp)) > @as(f64, @floatFromInt(desktop.practice_progress.day_ns))) {
            previous = null;
        };
        // Optional exponential smoothing never replaces the raw points.
        const smooth = if (previous) |prior| 0.35 * y + 0.65 * prior.y else y;
        if (smoothing) if (previous) |prior| {
            var line = plot.line();
            line.point(prior.x, prior.y);
            line.point(x, smooth);
            line.stroke(1.5, ui.color(0xE4B553));
            line.deinit();
        };
        previous = .{ .x = x, .y = smooth, .timestamp = point.timestamp };
    }
}
pub fn draw(view: *View, history: ?*const desktop.practice_history.Query, cohort: desktop.practice_results.Cohort, failure: ?anyerror, saving: bool, theme: ui.Theme, bounds: dvui.Rect) !bool {
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = bounds, .tag = "practice.progress" });
    defer area.deinit();
    const body = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = bounds.w - 20, .h = if (view.tab == 0) 850 else 500 }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
    defer body.deinit();
    const width = bounds.w - 20;
    const arena = dvui.currentWindow().arena();
    const status = if (failure) |err| try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)}) else if (saving) "Loading history…" else if (history != null and history.?.rejected > 0) "Some history could not be read; evidence is incomplete." else view.message;
    presentation.caption(status, .{ .y = if (view.tab == 0) 795 else 400, .w = width - 100, .h = 38 }, 15, theme.muted, null);
    if (failure != null and ui.button(theme, "Retry", "practice.progress.retry", .{ .x = width - 95, .y = if (view.tab == 0) 795 else 400, .w = 90, .h = 32 })) view.retry = true;
    if (ui.button(theme, "Back to practice", "practice.progress.back", .{ .w = 180, .h = 38 })) return true;
    const assistance = ([_][]const u8{ "Guided", "Layout only", "Hidden" })[@backingInt(cohort.assistance)];
    const context = if (cohort.curriculum.version != 0) try std.fmt.allocPrint(arena, "Progress · {s} · {d} letters · {s}", .{ desktop.practice_curriculum.names[@backingInt(cohort.curriculum.stage)], cohort.curriculum.alphabet, assistance }) else try std.fmt.allocPrint(arena, "Progress · {t} · {s} · {t} · UTC dates", .{ cohort.preset, assistance, cohort.mode });
    presentation.caption(context, .{ .x = 190, .w = width - 190, .h = 38 }, 20, theme.text, null);
    _ = dvui.dropdown(@src(), &.{ "Trends", "Activity" }, .{ .choice = &view.tab }, .{}, .{ .rect = .{ .y = 44, .w = 160, .h = 32 } });
    _ = dvui.dropdown(@src(), &.{ "Newest 60", "Today (UTC)", "Last 7 days" }, .{ .choice = &view.range }, .{}, .{ .rect = .{ .x = 170, .y = 44, .w = 170, .h = 32 } });
    if (history == null) {
        presentation.caption("Loading matching practice history…", .{ .y = 90, .w = width, .h = 48 }, 18, theme.muted, null);
        return false;
    }
    const empty = try arena.create(desktop.practice_progress.Summary);
    empty.* = .{};
    const source = history.?.progress orelse empty;
    const filtered = try arena.create(desktop.practice_progress.Summary);
    filtered.* = source.*;
    filtered.count = 0;
    for (source.points[0..source.count]) |point| {
        const day = @divFloor(point.timestamp, desktop.practice_progress.day_ns);
        if (view.range == 1 and day != source.today) continue;
        if (view.range == 2 and (day < source.today - 6 or day > source.today)) continue;
        filtered.points[filtered.count] = point;
        filtered.count += 1;
    }
    const data = filtered;
    presentation.caption(try std.fmt.allocPrint(arena, "{d} displayed / {d} matching runs · ≥95% streak: {d} in newest window", .{ data.count, data.eligible, source.accuracyStreak() }), .{ .x = 350, .y = 44, .w = width - 350, .h = 32 }, 14, theme.muted, null);
    if (view.tab == 0) {
        _ = dvui.checkbox(@src(), &view.smoothing, "Smoothed trend · blue = raw points · gaps >24h stay open", .{ .rect = .{ .y = 86, .w = width, .h = 30 }, .tag = "practice.progress.smoothing" });
        if (data.count == 0) presentation.caption("Finish a scored exercise to start your progress history.", .{ .y = 130, .w = width, .h = 240 }, 20, theme.muted, null) else {
            chart(data, theme, .{ .y = 124, .w = width, .h = 145 }, false, view.smoothing);
            chart(data, theme, .{ .y = 280, .w = width, .h = 145 }, true, view.smoothing);
        }
        presentation.caption("Character evidence · newest 12 displayed runs · click to inspect", .{ .y = 438, .w = width - 180, .h = 28 }, 18, theme.text, null);
        _ = dvui.dropdown(@src(), &.{ "Misses / samples", "Exposure", "Median (ms)" }, .{ .choice = &view.matrix }, .{}, .{ .rect = .{ .x = width - 175, .y = 438, .w = 175, .h = 30 } });
        const columns = @min(data.count, 12);
        const cell_w = (width - 100) / @as(f32, @floatFromInt(@max(1, columns)));
        for (0..columns) |column| {
            const point = data.points[columns - column - 1];
            var date: [32]u8 = undefined;
            const label = try desktop.practice_results.dateLabel(point.timestamp, &date);
            if (compactButton(theme, if (point.timestamp >= 0) label[5..10] else "?", try std.fmt.allocPrint(arena, "practice.progress.run.{d}", .{column}), .{ .x = 100 + @as(f32, @floatFromInt(column)) * cell_w, .y = 472, .w = cell_w - 4, .h = 26 })) {
                view.inspect = point.id;
                view.selected = null;
            }
        }
        if (history) |h| {
            var stats = h.all.stats;
            std.mem.sort(desktop.practice_results.Stat, stats[0..h.all.stat_count], {}, struct {
                fn less(_: void, a: desktop.practice_results.Stat, b: desktop.practice_results.Stat) bool {
                    return if (a.rank() == b.rank()) a.cp < b.cp else a.rank() > b.rank();
                }
            }.less);
            for (stats[0..@min(6, h.all.stat_count)], 0..) |stat, row| {
                var bytes: [4]u8 = undefined;
                presentation.caption(desktop.practice_view.glyph(stat.cp, true, &bytes), .{ .y = 502 + @as(f32, @floatFromInt(row)) * 30, .w = 90, .h = 28 }, 16, theme.text, null);
                for (0..columns) |column| {
                    const point = data.points[columns - column - 1];
                    var found: ?desktop.practice_progress.Character = null;
                    for (point.characters[0..point.count]) |character| if (character.cp == stat.cp) {
                        found = character;
                        break;
                    };
                    const label = if (found) |character| switch (view.matrix) {
                        0 => try std.fmt.allocPrint(arena, "{d}/{d}", .{ character.misses, character.opportunities }),
                        1 => try std.fmt.allocPrint(arena, "{d}", .{character.opportunities}),
                        else => if (character.samples > 0) try std.fmt.allocPrint(arena, "{d:.0}{s}", .{ @as(f64, @floatFromInt(character.median_us)) / 1000, if (character.samples < 5 or point.truncated) "*" else "" }) else "—",
                    } else "—";
                    var cell_theme = theme;
                    cell_theme.control = if (found) |character| @import("practice_rundown.zig").color(.{ .opportunities = character.opportunities, .misses = character.misses }, theme.bg.r > 100) else theme.control;
                    if (view.matrix != 0) cell_theme.control = if (found != null and (view.matrix == 1 or found.?.samples > 0)) ui.color(if (theme.bg.r > 100) 0xD4E6FF else 0x264F80) else theme.control;
                    if (compactButton(cell_theme, label, try std.fmt.allocPrint(arena, "practice.progress.cell.{d}.{d}", .{ row, column }), .{ .x = 100 + @as(f32, @floatFromInt(column)) * cell_w, .y = 502 + @as(f32, @floatFromInt(row)) * 30, .w = cell_w - 4, .h = 27 })) {
                        view.selected = stat.cp;
                        view.inspect = point.id;
                    }
                }
            }
        }
        var start: [32]u8 = undefined;
        var end: [32]u8 = undefined;
        if (data.count > 0) presentation.caption(try std.fmt.allocPrint(arena, "{s} to {s}", .{ try desktop.practice_results.dateLabel(data.points[data.count - 1].timestamp, &start), try desktop.practice_results.dateLabel(data.points[0].timestamp, &end) }), .{ .y = 700, .w = width, .h = 30 }, 15, theme.muted, null);
        presentation.caption("Timing: clean intervals only · * fewer than 5 or truncated · — no sample. Zero-duration runs have no plotted speed.", .{ .y = 738, .w = width, .h = 38 }, 15, theme.muted, null);
    } else {
        presentation.caption("Daily practice · last 28 UTC days · oldest to today", .{ .y = 130, .w = width, .h = 28 }, 18, theme.text, null);
        _ = dvui.dropdown(@src(), &.{ "1 minute goal", "3 minute goal", "5 minute goal" }, .{ .choice = &view.goal }, .{}, .{ .rect = .{ .y = 170, .w = 180, .h = 32 } });
        const goal = ([_]u64{ 60, 180, 300 })[view.goal] * 1_000_000;
        presentation.caption(try std.fmt.allocPrint(arena, "Today: {d:.1} active minutes · {d} runs · {s}", .{ @as(f64, @floatFromInt(data.days[0])) / 60_000_000, data.day_runs[0], if (data.days[0] >= goal) "goal reached" else "practice when it suits you" }), .{ .x = 190, .y = 170, .w = width - 190, .h = 32 }, 16, theme.text, null);
        for (0..28) |index| {
            const ago = 27 - index;
            var cell_theme = theme;
            cell_theme.control = if (data.days[ago] >= goal) ui.color(0x245C4D) else if (data.day_runs[ago] > 0) ui.color(0x264F80) else theme.control;
            var date: [32]u8 = undefined;
            const day_label = try desktop.practice_results.dateLabel((data.today - @as(i64, @intCast(ago))) * desktop.practice_progress.day_ns, &date);
            _ = compactButton(cell_theme, try std.fmt.allocPrint(arena, "{s}\n{d:.1}m", .{ if (data.today > 28) day_label[5..10] else "—", @as(f64, @floatFromInt(data.days[ago])) / 60_000_000 }), try std.fmt.allocPrint(arena, "practice.progress.day.{d}", .{ago}), .{ .x = @as(f32, @floatFromInt(index % 14)) * width / 14, .y = 220 + @as(f32, @floatFromInt(index / 14)) * 58, .w = width / 14 - 4, .h = 54 });
        }
        presentation.caption("All matching scored completed runs contribute active minutes. Blue = practiced, green = chosen goal reached.", .{ .y = 345, .w = width, .h = 38 }, 15, theme.muted, null);
    }
    return false;
}
