//! On-demand timing diagnostics. Raw events remain inspectable beside exclusions.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const presentation = @import("practice_presentation.zig");
const results = desktop.practice_results;
pub const View = struct { tab: usize = 0, choice: usize = 0, event_page: usize = 0, event: usize = 0, message: []const u8 = "", retry: bool = false };
pub const Action = union(enum) { none, back, drill: desktop.practice_controller.Config };
fn glyph(cp: u21, buffer: *[4]u8) []const u8 {
    return switch (cp) {
        ' ' => "Space",
        '\n' => "Enter",
        '\t' => "Tab",
        else => desktop.practice_view.glyph(cp, true, buffer),
    };
}
fn compact(theme: ui.Theme, text: []const u8, tag: []const u8, rect: dvui.Rect) bool {
    return presentation.rowButton(theme, text, tag, rect, 15);
}
fn personal(history: *const desktop.practice_history.Query, id: [16]u8, cp: u21) ?u64 {
    var values: [60]u64 = undefined;
    var count: usize = 0;
    if (history.progress) |data| for (data.points[0..data.count]) |point| {
        if (std.mem.eql(u8, &point.id, &id) or point.truncated) continue;
        for (point.characters[0..point.count]) |character| if (character.cp == cp and character.samples >= 5) {
            values[count] = character.median_us;
            count += 1;
        };
    };
    if (count < 3) return null;
    std.mem.sort(u64, values[0..count], {}, std.sort.asc(u64));
    return values[(count - 1) / 2] + (values[count / 2] - values[(count - 1) / 2]) / 2;
}
pub fn draw(view: *View, selected: ?u21, owner: *desktop.practice_controller.Controller, record: *const results.Record, history: ?*const desktop.practice_history.Query, saving: bool, failure: ?anyerror, theme: ui.Theme, bounds: dvui.Rect) !Action {
    const wide = bounds.w >= 1100;
    const page = presentation.Page.init(bounds, if (view.tab == 1) 1440 else if (wide) 1000 else 1390, "practice.diagnostics", theme);
    defer page.deinit();
    const width = page.width;
    const arena = dvui.currentWindow().arena();
    presentation.header("Timing details", "Delivered text intervals · clean timing and raw events stay separate.", width, theme);
    if (ui.button(theme, "Back to rundown", "practice.diagnostics.back", .{ .x = width - 165, .w = 165, .h = 38 })) return .back;
    _ = dvui.dropdown(@src(), &.{ "Characters", "Rhythm and events", "Skills and provenance" }, .{ .choice = &view.tab }, .{}, .{ .rect = .{ .y = 92, .w = 240, .h = 36 } });
    const status = if (failure) |err| try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)}) else if (saving) "Loading timing…" else view.message;
    var status_y: f32 = if (view.tab == 1) 1410 else if (!wide and view.tab == 0) 1350 else 940;
    defer {
        const status_height = presentation.flowText(status, 0, status_y, width - 110, 14, theme.muted);
        page.ensureHeight(status_y + @max(36, status_height) + 40);
        if (failure != null and ui.button(theme, "Retry", "practice.diagnostics.retry", .{ .x = width - 100, .y = status_y, .w = 100, .h = 36 })) view.retry = true;
    }
    if (!record.timing_available) {
        _ = presentation.flowText("This older run has counts only. New exercises record timing.", 0, 184, width, 18, theme.muted);
        return .none;
    }
    const analysis = (if (history) |h| h.analysis else null) orelse {
        _ = presentation.flowText(if (saving) "Waiting for saved timing…" else "Timing is unavailable. Counts remain in the rundown.", 0, 184, width, 18, theme.muted);
        return .none;
    };
    const payload = history.?.timing.?.payload;
    presentation.label(try std.fmt.allocPrint(arena, "{d} clean intervals · {d} raw events{s}", .{ analysis.eligible, payload.events.len, if (analysis.truncated) " · recording truncated" else "" }), .{ .y = 144, .w = width, .h = 26 }, 14, theme.muted, null);
    if (view.tab == 0) {
        if (record.stat_count == 0) return .none;
        const names = try arena.alloc([]const u8, record.stat_count);
        for (record.stats[0..record.stat_count], 0..) |stat, index| {
            var bytes: [4]u8 = undefined;
            names[index] = try arena.dupe(u8, glyph(stat.cp, &bytes));
        }
        view.choice = @min(view.choice, record.stat_count - 1);
        if (selected) |cp| if (view.message.len == 0) for (record.stats[0..record.stat_count], 0..) |stat, index| if (stat.cp == cp) {
            view.choice = index;
            break;
        };
        if (dvui.dropdown(@src(), names, .{ .choice = &view.choice }, .{}, .{ .rect = .{ .x = 260, .y = 92, .w = 120, .h = 36 }, .tag = "practice.diagnostics.character" })) view.message = "Character selected";
        const stat = record.stats[view.choice];
        const value = analysis.character(stat.cp) orelse desktop.practice_analysis.Quantiles{};
        const baseline = personal(history.?, record.id, stat.cp);
        const card_w = (width - 32) / 3;
        presentation.metric("Clean interval", if (value.count == 0) "—" else try std.fmt.allocPrint(arena, "{d:.0} ms", .{@as(f64, @floatFromInt(value.median_us)) / 1000}), try std.fmt.allocPrint(arena, "Median · {d} samples{s}", .{ value.count, if (value.count < 5) " · limited" else "" }), .{ .y = 190, .w = card_w, .h = 116 }, theme);
        presentation.metric("First-pass success", try std.fmt.allocPrint(arena, "{d:.1}%", .{100 - stat.rate()}), try std.fmt.allocPrint(arena, "{d} missed / {d} opportunities", .{ stat.misses, stat.opportunities }), .{ .x = card_w + 16, .y = 190, .w = card_w, .h = 116 }, theme);
        presentation.metric("Slow tail", if (value.count == 0) "—" else try std.fmt.allocPrint(arena, "{d:.0} ms", .{@as(f64, @floatFromInt(value.p95_us)) / 1000}), "95th percentile · clean intervals", .{ .x = 2 * (card_w + 16), .y = 190, .w = card_w, .h = 116 }, theme);
        const chart_w = if (wide) (width - 20) * 0.62 else width;
        presentation.surface(.{ .y = 332, .w = chart_w, .h = 310 }, theme.panel);
        presentation.label("Character interval over time", .{ .x = 20, .y = 346, .w = chart_w - 40, .h = 30 }, 19, theme.text, null);
        var ymax: f64 = @max(100, @as(f64, @floatFromInt(value.p95_us)) / 1000 * 1.1);
        if (history.?.progress) |data| {
            for (data.points[0..data.count]) |point| for (point.characters[0..point.count]) |character| if (character.cp == stat.cp) {
                ymax = @max(ymax, @as(f64, @floatFromInt(character.median_us)) / 1000 * 1.1);
            };
            var xaxis: dvui.PlotWidget.Axis = .{ .name = "Matching runs · oldest to newest", .min = -0.2, .max = @floatFromInt(@max(1, data.count)) };
            var yaxis: dvui.PlotWidget.Axis = .{ .name = "Median interval (ms)", .min = 0, .max = ymax };
            const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{ .rect = .{ .x = 12, .y = 390, .w = chart_w - 24, .h = 230 }, .background = true, .color_fill = .{ .color = theme.panel } });
            if (baseline) |target| {
                var line = plot.line();
                line.point(0, @as(f64, @floatFromInt(target)) / 1000);
                line.point(xaxis.max.?, @as(f64, @floatFromInt(target)) / 1000);
                line.stroke(1, theme.muted);
                line.deinit();
            }
            for (data.points[0..data.count], 0..) |point, index| for (point.characters[0..point.count]) |character| if (character.cp == stat.cp and character.samples > 0) {
                plot.bar(.{ .x = @floatFromInt(data.count - index - 1), .y = @as(f64, @floatFromInt(character.median_us)) / 1000, .w = 0.15, .h = ymax / 100, .color = ui.color(0x69BFA3) });
            };
            plot.deinit();
        }
        const coaching = if (value.count == 0) "No clean timing samples for this character yet." else if (baseline) |target| try std.fmt.allocPrint(arena, "Personal reference: {d:.0} ms. {s}", .{ @as(f64, @floatFromInt(target)) / 1000, if (value.count >= 5 and !analysis.truncated and @as(f64, @floatFromInt(value.median_us)) > @as(f64, @floatFromInt(target)) * 1.25) "Try a careful short drill." else "Build consistency before increasing speed." }) else "A personal reference needs three other matching runs with five clean samples each.";
        _ = presentation.flowText(coaching, 0, 666, chart_w, 15, theme.muted);
        var primary = theme;
        primary.control = ui.color(0x287AF2);
        primary.text = dvui.Color.white;
        if (ui.button(primary, "Practice this character", "practice.diagnostics.drill", .{ .y = 750, .w = 230, .h = 40 })) {
            if (!record.scored or !owner.matchesSettings(record.cohort) or owner.config.mode != .english) view.message = "Use a scored English run with matching exercise settings." else {
                var config = owner.config;
                config.challenge = null;
                config.targets[0] = stat.cp;
                config.target_count = 1;
                var output: [8192]u8 = undefined;
                _ = owner.preview(&output, config) catch {
                    view.message = "This target needs a matching preset or corpus.";
                    return .none;
                };
                return .{ .drill = config };
            }
        }
        const tx = if (wide) chart_w + 20 else 0;
        const ty: f32 = if (wide) 332 else 822;
        const tw = width - tx;
        presentation.surface(.{ .x = tx, .y = ty, .w = tw, .h = 510 }, theme.panel);
        presentation.label("Difficult transitions", .{ .x = tx + 20, .y = ty + 16, .w = tw - 40, .h = 30 }, 19, theme.text, null);
        _ = presentation.flowText("Into this character · clean intervals", tx + 20, ty + 56, tw - 40, 13, theme.muted);
        var transitions = analysis.transitions;
        std.mem.sort(desktop.practice_analysis.Transition, transitions[0..analysis.transition_count], {}, struct {
            fn less(_: void, a: desktop.practice_analysis.Transition, b: desktop.practice_analysis.Transition) bool {
                return a.timing.median_us > b.timing.median_us;
            }
        }.less);
        var row: usize = 0;
        for (transitions[0..analysis.transition_count]) |transition| {
            if (transition.to != stat.cp or row == 8) continue;
            var from: [4]u8 = undefined;
            var to: [4]u8 = undefined;
            const row_y = ty + 102 + @as(f32, @floatFromInt(row)) * 48;
            presentation.label(try std.fmt.allocPrint(arena, "{s} -> {s}    {d:.0} ms", .{ glyph(transition.from, &from), glyph(transition.to, &to), @as(f64, @floatFromInt(transition.timing.median_us)) / 1000 }), .{ .x = tx + 20, .y = row_y, .w = tw - 40, .h = 24 }, 16, theme.text, null);
            presentation.label(try std.fmt.allocPrint(arena, "p95 {d:.0} ms · {d} samples{s}", .{ @as(f64, @floatFromInt(transition.timing.p95_us)) / 1000, transition.timing.count, if (transition.timing.count < 5) " · limited" else "" }), .{ .x = tx + 20, .y = row_y + 24, .w = tw - 40, .h = 20 }, 12, theme.muted, null);
            row += 1;
        }
        if (row == 0) _ = presentation.flowText("No clean transition samples yet.", tx + 20, ty + 102, tw - 40, 15, theme.muted);
        if (analysis.transitions_truncated) {
            const note_y: f32 = if (wide) 864 else 1348;
            const note_height = presentation.flowText("Transition list limited to 256 pairs. Raw events remain available.", 0, note_y, width, 13, theme.muted);
            status_y = @max(status_y, note_y + note_height + 20);
        }
    } else if (view.tab == 1) {
        presentation.surface(.{ .y = 190, .w = width, .h = 320 }, theme.panel);
        presentation.label("Run rhythm", .{ .x = 20, .y = 204, .w = width - 40, .h = 30 }, 20, theme.text, null);
        var ymax: f64 = 100;
        for (analysis.rhythm) |bucket| ymax = @max(ymax, bucket.mean_ms * 1.1);
        var xaxis: dvui.PlotWidget.Axis = .{ .name = "Active time (seconds)", .min = 0, .max = @max(1, @as(f64, @floatFromInt(analysis.active_us)) / 1_000_000) };
        var yaxis: dvui.PlotWidget.Axis = .{ .name = "Mean clean interval (ms)", .min = 0, .max = ymax };
        const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{ .rect = .{ .x = 12, .y = 250, .w = width - 24, .h = 210 }, .background = true, .color_fill = .{ .color = theme.panel } });
        for (analysis.rhythm, 0..) |bucket, index| {
            const x = @as(f64, @floatFromInt(index)) * xaxis.max.? / 64;
            if (bucket.count > 0) plot.bar(.{ .x = x, .y = bucket.mean_ms, .w = xaxis.max.? / 128, .h = ymax / 100, .color = ui.color(0x548FF5) });
            for ([_]usize{ bucket.errors, bucket.corrections, bucket.pauses, bucket.hints }, 0..) |count, kind| if (count > 0) plot.bar(.{ .x = x, .y = @as(f64, @floatFromInt(kind + 1)) * ymax / 30, .w = xaxis.max.? / 128, .h = ymax / 100, .color = ui.color(([_]u24{ 0xE47777, 0xE4B553, 0xAAAAAA, 0x70BF99 })[kind]) });
        }
        plot.deinit();
        _ = presentation.flowText("Blue: timing · red: errors · amber: corrections · gray: pauses · green: hints", 20, 478, width - 40, 13, theme.muted);
        presentation.surface(.{ .y = 534, .w = width, .h = 640 }, theme.panel);
        presentation.label("Raw events", .{ .x = 20, .y = 548, .w = width - 40, .h = 30 }, 20, theme.text, null);
        const pages = @max(1, (payload.events.len + 11) / 12);
        view.event_page = @min(view.event_page, pages - 1);
        if (ui.button(theme, "Previous", "practice.events.previous", .{ .x = 20, .y = 594, .w = 120, .h = 34 }) and view.event_page > 0) view.event_page -= 1;
        if (ui.button(theme, "Next", "practice.events.next", .{ .x = 152, .y = 594, .w = 120, .h = 34 })) view.event_page = (view.event_page + 1) % pages;
        presentation.label(try std.fmt.allocPrint(arena, "Page {d}/{d} · excluded attempts retained", .{ view.event_page + 1, pages }), .{ .x = 292, .y = 594, .w = width - 312, .h = 34 }, 13, theme.muted, null);
        const start = view.event_page * 12;
        for (payload.events[start..@min(payload.events.len, start + 12)], 0..) |event, index| {
            const text = try std.fmt.allocPrint(arena, "#{d}   {d:.3}s   {t}   pos {d}   {t}", .{ start + index, @as(f64, @floatFromInt(event.active_us)) / 1_000_000, event.kind, event.position, event.eligibility });
            if (compact(theme, text, try std.fmt.allocPrint(arena, "practice.event.{d}", .{start + index}), .{ .x = 20, .y = 648 + @as(f32, @floatFromInt(index)) * 38, .w = width - 40, .h = 32 })) view.event = start + index;
        }
        if (payload.events.len > 0) {
            view.event = @min(view.event, payload.events.len - 1);
            const event = payload.events[view.event];
            var context: std.Io.Writer.Allocating = .init(arena);
            const pos: usize = @min(event.position, payload.reference.len);
            for (payload.reference[pos -| 5..@min(payload.reference.len, pos + 6)], pos -| 5..) |cp, index| {
                var bytes: [4]u8 = undefined;
                try context.writer.print("{s}{s}{s}", .{ if (index == pos) "[" else "", if (cp == ' ' and index != pos) " " else glyph(cp, &bytes), if (index == pos) "]" else "" });
            }
            presentation.surface(.{ .y = 1196, .w = width, .h = 200 }, theme.panel);
            var typed: [4]u8 = undefined;
            const h = presentation.flowText(try std.fmt.allocPrint(arena, "#{d}: {s} · typed {s}", .{ view.event, context.written(), if (event.typed) |cp| glyph(cp, &typed) else "—" }), 20, 1214, width - 40, 17, theme.text);
            _ = presentation.flowText(try std.fmt.allocPrint(arena, "{t} clock {d}µs · {d:.3}s elapsed · {t} input · batch {d} · cue {s} · correct {any} · interval {s}", .{ event.clock, event.observed_us, @as(f64, @floatFromInt(event.elapsed_us)) / 1_000_000, event.input, event.batch, if (!payload.cue_tracking) "unknown" else if (event.cue_visible) "shown" else "not shown", event.correct, if (event.interval_us) |interval| try std.fmt.allocPrint(arena, "{d:.3} ms", .{@as(f64, @floatFromInt(interval)) / 1000}) else "excluded" }), 20, 1230 + h, width - 40, 13, theme.muted);
        }
    } else {
        presentation.surface(.{ .y = 190, .w = width, .h = 160 }, theme.panel);
        presentation.label("Physical execution is unavailable", .{ .x = 24, .y = 210, .w = width - 48, .h = 30 }, 20, theme.text, null);
        _ = presentation.flowText("Text events cannot prove the layer, modifier or finger you used. Frozen routes describe possible ways to produce a character.", 24, 260, width - 48, 16, theme.muted);
        presentation.surface(.{ .y = 374, .w = width, .h = 470 }, theme.panel);
        presentation.label("Timing provenance", .{ .x = 24, .y = 392, .w = width - 48, .h = 30 }, 20, theme.text, null);
        _ = presentation.flowText(try std.fmt.allocPrint(arena, "{d} native · {d} frame · {d} injected events", .{ analysis.clocks[@backingInt(desktop.practice_timing.Clock.native_event)], analysis.clocks[@backingInt(desktop.practice_timing.Clock.frame)], analysis.clocks[@backingInt(desktop.practice_timing.Clock.injected)] }), 24, 438, width - 48, 14, theme.muted);
        for (analysis.eligibility, 0..) |count, index| presentation.label(try std.fmt.allocPrint(arena, "{t}: {d} attempts", .{ @as(desktop.practice_timing.Eligibility, @fromBackingInt(@as(u4, @intCast(index)))), count }), .{ .x = 24, .y = 478 + @as(f32, @floatFromInt(index)) * 30, .w = width - 48, .h = 26 }, 15, theme.text, null);
        if (selected) |cp| for (record.stats[0..record.stat_count]) |stat| if (stat.cp == cp) {
            for (stat.routes[0..stat.route_count], 0..) |route, index| _ = presentation.flowText(try std.fmt.allocPrint(arena, "Possible route: layer {d} · key {d} · modifiers 0x{x}{s}", .{ route.layer, route.key, route.modifiers, if (stat.routes_truncated) " · others omitted" else "" }), 0, 874 + @as(f32, @floatFromInt(index)) * 32, width, 14, theme.muted);
            status_y = @max(status_y, 894 + @as(f32, @floatFromInt(stat.route_count)) * 32);
        };
    }
    return .none;
}
