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
    var ymin: f64 = 0;
    if (accuracy) {
        ymin = 95;
        for (data.points[0..data.count]) |point| if (point.active_us > 0) {
            ymin = @min(ymin, @max(0, @floor(point.accuracy - 5)));
        };
    }
    var yaxis: dvui.PlotWidget.Axis = .{ .name = if (accuracy) "Attempt accuracy (%)" else "Speed (WPM)", .min = ymin, .max = ymax };
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
        const marker_height = (ymax - ymin) / 100;
        plot.bar(.{ .x = x - span / 400, .y = @max(ymin, y - marker_height / 2), .w = span / 200, .h = marker_height, .color = ui.color(0x548FF5) });
        if (previous) |prior| if (@as(f64, @floatFromInt(point.timestamp)) - @as(f64, @floatFromInt(prior.timestamp)) > @as(f64, @floatFromInt(desktop.practice_progress.day_ns))) {
            previous = null;
        };
        // Optional exponential smoothing never replaces the raw points.
        const smooth = if (previous) |prior| 0.35 * y + 0.65 * prior.y else y;
        if (smoothing) if (previous) |prior| {
            var line = plot.line();
            line.point(prior.x, prior.y);
            line.point(x, smooth);
            line.stroke(1.5, ui.color(if (accuracy) 0x548FF5 else 0x69BFA3));
            line.deinit();
        };
        previous = .{ .x = x, .y = smooth, .timestamp = point.timestamp };
    }
}
pub fn draw(view: *View, history: ?*const desktop.practice_history.Query, cohort: desktop.practice_results.Cohort, failure: ?anyerror, saving: bool, theme: ui.Theme, bounds: dvui.Rect) !bool {
    const wide = bounds.w >= 1100;
    const page = presentation.Page.init(bounds, 860, "practice.progress", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    const assistance = if (cohort.hints.revealed) "Help revealed" else if (cohort.assistance == .guided) desktop.practice_help.choices[@backingInt(cohort.hints.policy)] else ([_][]const u8{ "Guided", "Layout only", "Hidden" })[@backingInt(cohort.assistance)];
    const context = if (cohort.curriculum.version != 0) try std.fmt.allocPrint(arena, "{s} · {d} letters · {s} · matching runs only", .{ desktop.practice_curriculum.names[@backingInt(cohort.curriculum.stage)], cohort.curriculum.alphabet, assistance }) else try std.fmt.allocPrint(arena, "{t} · {s} · {t} · matching runs only", .{ cohort.preset, assistance, cohort.mode });
    presentation.header("Your progress", context, width, theme);
    if (ui.button(theme, "Back to practice", "practice.progress.back", .{ .x = width - 165, .w = 165, .h = 38 })) return true;
    _ = dvui.dropdown(@src(), &.{ "Trends", "Activity" }, .{ .choice = &view.tab }, .{}, .{ .rect = .{ .y = 92, .w = 145, .h = 36 } });
    _ = dvui.dropdown(@src(), &.{ "Newest 60", "Today (UTC)", "Last 7 days" }, .{ .choice = &view.range }, .{}, .{ .rect = .{ .x = 157, .y = 92, .w = 170, .h = 36 } });
    const status_y: f32 = if (wide or view.tab != 0) 800 else 1310;
    page.ensureHeight(status_y + 110);
    const status = if (failure) |err| try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)}) else if (saving) "Loading history…" else if (history != null and history.?.rejected > 0) "Some history could not be read; evidence is incomplete." else view.message;
    _ = presentation.flowText(status, 0, status_y, width - 110, 14, theme.muted);
    if (failure != null and ui.button(theme, "Retry", "practice.progress.retry", .{ .x = width - 100, .y = status_y, .w = 100, .h = 34 })) view.retry = true;
    if (history == null) {
        presentation.surface(.{ .y = 160, .w = width, .h = 180 }, theme.panel);
        _ = presentation.flowText("Loading matching practice history…", 24, 188, width - 48, 18, theme.muted);
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
    const metric_w = (width - 32) / 3;
    var total_speed: f64 = 0;
    var speed_count: usize = 0;
    for (data.points[0..data.count]) |point| if (point.active_us > 0) {
        total_speed += point.wpm;
        speed_count += 1;
    };
    presentation.metric("Today", try std.fmt.allocPrint(arena, "{d:.1} min", .{@as(f64, @floatFromInt(source.days[0])) / 60_000_000}), "Active practice · UTC", .{ .y = 148, .w = metric_w, .h = 116 }, theme);
    presentation.metric("Recent average", if (speed_count > 0) try std.fmt.allocPrint(arena, "{d:.0} WPM", .{total_speed / @as(f64, @floatFromInt(speed_count))}) else "—", try std.fmt.allocPrint(arena, "{d} displayed runs", .{data.count}), .{ .x = metric_w + 16, .y = 148, .w = metric_w, .h = 116 }, theme);
    presentation.metric("Accuracy streak", try std.fmt.allocPrint(arena, "{d} runs", .{source.accuracyStreak()}), "≥95% · newest 60 matching runs", .{ .x = 2 * (metric_w + 16), .y = 148, .w = metric_w, .h = 116 }, theme);
    if (view.tab == 0) {
        const charts_w = if (wide) (width - 20) * 0.58 else width;
        const matrix_x = if (wide) charts_w + 20 else 0;
        const matrix_y: f32 = if (wide) 292 else 774;
        const matrix_w = if (wide) width - matrix_x else width;
        _ = dvui.checkbox(@src(), &view.smoothing, "Smooth trend", .{ .rect = .{ .x = 340, .y = 92, .w = 170, .h = 36 }, .tag = "practice.progress.smoothing" });
        for (0..2) |index| {
            const y: f32 = 292 + @as(f32, @floatFromInt(index)) * 236;
            presentation.surface(.{ .y = y, .w = charts_w, .h = 220 }, theme.panel);
            presentation.label(if (index == 0) "Speed over time" else "Accuracy over time", .{ .x = 20, .y = y + 12, .w = charts_w - 40, .h = 30 }, 19, theme.text, null);
            if (data.count == 0) _ = presentation.flowText("Finish a scored exercise to start this chart.", 24, y + 86, charts_w - 48, 16, theme.muted) else chart(data, theme, .{ .x = 12, .y = y + 52, .w = charts_w - 24, .h = 155 }, index == 1, view.smoothing);
        }
        presentation.surface(.{ .x = matrix_x, .y = matrix_y, .w = matrix_w, .h = 456 }, theme.panel);
        presentation.label("Character progress", .{ .x = matrix_x + 20, .y = matrix_y + 12, .w = matrix_w - 40, .h = 30 }, 19, theme.text, null);
        _ = dvui.dropdown(@src(), &.{ "First-pass success", "Exposure", "Median (ms)" }, .{ .choice = &view.matrix }, .{}, .{ .rect = .{ .x = matrix_x + 20, .y = matrix_y + 54, .w = @min(210, matrix_w - 40), .h = 34 } });
        const columns = @min(data.count, @min(12, @as(usize, @intFromFloat(@max(1, @floor((matrix_w - 80) / 50))))));
        const cell_w = (matrix_w - 80) / @as(f32, @floatFromInt(@max(1, columns)));
        for (0..columns) |column| {
            const point = data.points[columns - column - 1];
            var date: [32]u8 = undefined;
            const date_text = try desktop.practice_results.dateLabel(point.timestamp, &date);
            if (compactButton(theme, if (point.timestamp >= 0) date_text[8..10] else "?", try std.fmt.allocPrint(arena, "practice.progress.run.{d}", .{column}), .{ .x = matrix_x + 60 + @as(f32, @floatFromInt(column)) * cell_w, .y = matrix_y + 106, .w = cell_w - 4, .h = 27 })) {
                view.inspect = point.id;
                view.selected = null;
            }
        }
        var stats = history.?.all.stats;
        std.mem.sort(desktop.practice_results.Stat, stats[0..history.?.all.stat_count], {}, struct {
            fn less(_: void, a: desktop.practice_results.Stat, b: desktop.practice_results.Stat) bool {
                return if (a.rank() == b.rank()) a.cp < b.cp else a.rank() > b.rank();
            }
        }.less);
        for (stats[0..@min(6, history.?.all.stat_count)], 0..) |stat, row| {
            var bytes: [4]u8 = undefined;
            const name = switch (stat.cp) {
                ' ' => "SPC",
                '\n' => "RET",
                '\t' => "TAB",
                else => desktop.practice_view.glyph(stat.cp, true, &bytes),
            };
            presentation.label(name, .{ .x = matrix_x + 22, .y = matrix_y + 142 + @as(f32, @floatFromInt(row)) * 34, .w = 32, .h = 30 }, 14, theme.text, null);
            for (0..columns) |column| {
                const point = data.points[columns - column - 1];
                var found: ?desktop.practice_progress.Character = null;
                for (point.characters[0..point.count]) |character| if (character.cp == stat.cp) {
                    found = character;
                    break;
                };
                const text = if (found) |character| switch (view.matrix) {
                    0 => try std.fmt.allocPrint(arena, "{d:.0}%", .{if (character.opportunities == 0) @as(f64, 100) else 100 - 100 * @as(f64, @floatFromInt(character.misses)) / @as(f64, @floatFromInt(character.opportunities))}),
                    1 => try std.fmt.allocPrint(arena, "{d}", .{character.opportunities}),
                    else => if (character.samples > 0) blk: {
                        const ms = @as(f64, @floatFromInt(character.median_us)) / 1000;
                        const number = if (ms < 10_000) try std.fmt.allocPrint(arena, "{d:.0}", .{ms}) else try std.fmt.allocPrint(arena, "{e:.0}", .{ms});
                        break :blk try std.fmt.allocPrint(arena, "{s}{s}", .{ number, if (character.samples < 5 or point.truncated) "*" else "" });
                    } else "—",
                } else "—";
                var cell_theme = theme;
                cell_theme.control = if (found) |character| @import("practice_rundown.zig").color(.{ .opportunities = character.opportunities, .misses = character.misses }, theme.bg.r > 100) else theme.control;
                if (view.matrix != 0) cell_theme.control = if (found != null and (view.matrix == 1 or found.?.samples > 0)) ui.color(if (theme.bg.r > 100) 0xD4E6FF else 0x264F80) else theme.control;
                if (compactButton(cell_theme, text, try std.fmt.allocPrint(arena, "practice.progress.cell.{d}.{d}", .{ row, column }), .{ .x = matrix_x + 60 + @as(f32, @floatFromInt(column)) * cell_w, .y = matrix_y + 142 + @as(f32, @floatFromInt(row)) * 34, .w = cell_w - 4, .h = 30 })) {
                    view.selected = stat.cp;
                    view.inspect = point.id;
                }
            }
        }
        var first_date: [32]u8 = undefined;
        var last_date: [32]u8 = undefined;
        const dates = if (columns == 0) "No runs in this range" else try std.fmt.allocPrint(arena, "{s} to {s} · UTC", .{ if (data.points[columns - 1].timestamp < 0) "unknown time" else (try desktop.practice_results.dateLabel(data.points[columns - 1].timestamp, &first_date))[0..10], if (data.points[0].timestamp < 0) "unknown time" else (try desktop.practice_results.dateLabel(data.points[0].timestamp, &last_date))[0..10] });
        _ = presentation.flowText(dates, matrix_x + 20, matrix_y + 360, matrix_w - 40, 13, theme.muted);
        _ = presentation.flowText("— no sample · * limited timing evidence", matrix_x + 20, matrix_y + 404, matrix_w - 40, 13, theme.muted);
        _ = presentation.flowText("Blue: raw measurements. Smoothing keeps gaps over 24 hours open. Timing uses clean intervals only.", 0, if (wide) 764 else 1248, width, 13, theme.muted);
    } else {
        presentation.surface(.{ .y = 292, .w = width, .h = if (width >= 1000) 370 else 430 }, theme.panel);
        presentation.label("Daily practice", .{ .x = 20, .y = 306, .w = width - 40, .h = 30 }, 20, theme.text, null);
        presentation.label("Last 28 UTC days · oldest to today", .{ .x = 20, .y = 342, .w = width - 40, .h = 24 }, 14, theme.muted, null);
        _ = dvui.dropdown(@src(), &.{ "1 minute goal", "3 minute goal", "5 minute goal" }, .{ .choice = &view.goal }, .{}, .{ .rect = .{ .x = 20, .y = 384, .w = 180, .h = 34 } });
        const goal = ([_]u64{ 60, 180, 300 })[view.goal] * 1_000_000;
        const columns: usize = if (width >= 1000) 14 else 7;
        const cell_w = (width - 40) / @as(f32, @floatFromInt(columns));
        for (0..28) |index| {
            const ago = 27 - index;
            var cell_theme = theme;
            cell_theme.control = if (data.days[ago] >= goal) ui.color(if (theme.bg.r > 100) 0xC5EBDC else 0x245C4D) else if (data.day_runs[ago] > 0) ui.color(if (theme.bg.r > 100) 0xD4E6FF else 0x264F80) else theme.control;
            var date: [32]u8 = undefined;
            const day_label = try desktop.practice_results.dateLabel((data.today - @as(i64, @intCast(ago))) * desktop.practice_progress.day_ns, &date);
            _ = compactButton(cell_theme, try std.fmt.allocPrint(arena, "{s}\n{d:.1}m", .{ if (data.today > 28) day_label[5..10] else "—", @as(f64, @floatFromInt(data.days[ago])) / 60_000_000 }), try std.fmt.allocPrint(arena, "practice.progress.day.{d}", .{ago}), .{ .x = 20 + @as(f32, @floatFromInt(index % columns)) * cell_w, .y = 434 + @as(f32, @floatFromInt(index / columns)) * 50, .w = cell_w - 6, .h = 44 });
        }
        _ = presentation.flowText("Blue: practiced · green: goal reached. Minutes count active practice from matching scored completed runs.", 20, if (columns == 14) 556 else 644, width - 40, 13, theme.muted);
    }
    return false;
}
