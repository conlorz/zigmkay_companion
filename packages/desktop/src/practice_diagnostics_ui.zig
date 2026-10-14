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
    return if (cp == ' ') "Space" else desktop.practice_view.glyph(cp, true, buffer);
}
fn compact(theme: ui.Theme, text: []const u8, tag: []const u8, rect: dvui.Rect) bool {
    var options = ui.options(theme, rect, 13);
    options.padding = .all(2);
    options.tag = tag;
    options.id_extra = @truncate(std.hash.Wyhash.hash(0, tag));
    return dvui.button(@src(), text, .{}, options);
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
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = bounds, .tag = "practice.diagnostics" });
    defer area.deinit();
    const body = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = bounds.w - 20, .h = 930 }, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
    defer body.deinit();
    const width = bounds.w - 20;
    const arena = dvui.currentWindow().arena();
    if (ui.button(theme, "Back to rundown", "practice.diagnostics.back", .{ .w = 180, .h = 38 })) return .back;
    presentation.caption("Timing details · text event intervals · milliseconds", .{ .x = 190, .w = width - 190, .h = 38 }, 22, theme.text, null);
    _ = dvui.dropdown(@src(), &.{ "Characters", "Run rhythm / events", "Skills / provenance" }, .{ .choice = &view.tab }, .{}, .{ .rect = .{ .y = 48, .w = 220, .h = 38 } });
    const status = if (failure) |err| try std.fmt.allocPrint(arena, "History unavailable: {s}", .{@errorName(err)}) else if (saving) "Loading timing…" else view.message;
    presentation.caption(status, .{ .x = 230, .y = 48, .w = width - 330, .h = 38 }, 15, theme.muted, null);
    if (failure != null and ui.button(theme, "Retry", "practice.diagnostics.retry", .{ .x = width - 95, .y = 48, .w = 90, .h = 38 })) view.retry = true;
    if (!record.timing_available) {
        presentation.caption("This older run has counts only. Timing starts with newly recorded exercises.", .{ .y = 130, .w = width, .h = 80 }, 20, theme.muted, null);
        return .none;
    }
    const analysis = (if (history) |h| h.analysis else null) orelse {
        presentation.caption(if (saving) "Waiting for saved timing datapoints…" else "Timing data is unavailable. Counts remain in the rundown.", .{ .y = 130, .w = width, .h = 80 }, 20, theme.muted, null);
        return .none;
    };
    const payload = history.?.timing.?.payload;
    presentation.caption(try std.fmt.allocPrint(arena, "{d} eligible intervals / {d} raw events · analysis v1{s}", .{ analysis.eligible, payload.events.len, if (analysis.truncated) " · truncated recording; conclusions are incomplete" else "" }), .{ .y = 94, .w = width, .h = 30 }, 16, theme.muted, null);
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
        if (dvui.dropdown(@src(), names, .{ .choice = &view.choice }, .{}, .{ .rect = .{ .y = 136, .w = 150, .h = 38 }, .tag = "practice.diagnostics.character" })) view.message = "Character selected";
        const stat = record.stats[view.choice];
        const value = analysis.character(stat.cp) orelse desktop.practice_analysis.Quantiles{};
        const baseline = personal(history.?, record.id, stat.cp);
        const metric = if (value.count == 0) try std.fmt.allocPrint(arena, "Median — · p95 — · n=0 · first-pass {d:.1}%", .{100 - stat.rate()}) else try std.fmt.allocPrint(arena, "Median {d:.0}ms · slow tail (p95) {d:.0}ms · n={d}{s} · first-pass {d:.1}%", .{ @as(f64, @floatFromInt(value.median_us)) / 1000, @as(f64, @floatFromInt(value.p95_us)) / 1000, value.count, if (value.count < 5) " (limited evidence)" else "", 100 - stat.rate() });
        presentation.caption(metric, .{ .x = 160, .y = 136, .w = width - 160, .h = 38 }, 18, theme.text, null);
        const coaching = if (value.count == 0) "No clean timing sample for this character." else if (baseline) |target| try std.fmt.allocPrint(arena, "Personal reference: {d:.0}ms (median of ≥3 matching run medians, each n≥5). {s}", .{ @as(f64, @floatFromInt(target)) / 1000, if (value.count >= 5 and !analysis.truncated and @as(f64, @floatFromInt(value.median_us)) > @as(f64, @floatFromInt(target)) * 1.25) "Slower this run; try a careful short drill." else "Build consistent samples before increasing speed." }) else "No personal timing reference yet: needs ≥3 other matching runs with n≥5.";
        presentation.paragraph(coaching, .{ .y = 185, .w = width, .h = 48 }, 16, theme.text);
        var ymax: f64 = @max(100, @as(f64, @floatFromInt(value.p95_us)) / 1000 * 1.1);
        if (history.?.progress) |data| {
            for (data.points[0..data.count]) |point| for (point.characters[0..point.count]) |character| if (character.cp == stat.cp) {
                ymax = @max(ymax, @as(f64, @floatFromInt(character.median_us)) / 1000 * 1.1);
            };
            var xaxis: dvui.PlotWidget.Axis = .{ .name = "Matching runs (oldest to newest)", .min = 0, .max = @floatFromInt(@max(1, data.count)) };
            var yaxis: dvui.PlotWidget.Axis = .{ .name = "Median clean interval (ms)", .min = 0, .max = ymax };
            const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{ .rect = .{ .y = 244, .w = width, .h = 170 }, .background = true, .color_fill = .{ .color = theme.panel } });
            defer plot.deinit();
            if (baseline) |target| {
                var line = plot.line();
                line.point(0, @as(f64, @floatFromInt(target)) / 1000);
                line.point(xaxis.max.?, @as(f64, @floatFromInt(target)) / 1000);
                line.stroke(1, theme.muted);
                line.deinit();
            }
            for (data.points[0..data.count], 0..) |point, index| for (point.characters[0..point.count]) |character| if (character.cp == stat.cp and character.samples > 0) {
                plot.bar(.{ .x = @floatFromInt(data.count - index - 1), .y = @as(f64, @floatFromInt(character.median_us)) / 1000, .w = 0.15, .h = ymax / 100, .color = ui.color(0x548FF5) });
            };
        }
        if (ui.button(theme, "Practice this character", "practice.diagnostics.drill", .{ .y = 428, .w = 230, .h = 38 })) {
            if (!record.scored or !std.meta.eql(record.cohort, owner.configCohort()) or owner.config.mode != .english) view.message = "Use a scored English run with the current exercise settings for this drill." else {
                var config = owner.config;
                config.challenge = null;
                config.targets[0] = stat.cp;
                config.target_count = 1;
                var output: [8192]u8 = undefined;
                _ = desktop.practice_generator.generate(&output, .{ .seed = owner.seed +% 1, .preset = config.preset, .length = @intCast(config.level) }, config.targets[0..1]) catch {
                    view.message = "This target needs a different preset or is outside the English corpus.";
                    return .none;
                };
                return .{ .drill = config };
            }
        }
        presentation.caption("Slow transitions into this character · same reference context, clean intervals only", .{ .y = 485, .w = width, .h = 30 }, 18, theme.text, null);
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
            presentation.caption(try std.fmt.allocPrint(arena, "{s} to {s} · median {d:.0}ms · p95 {d:.0}ms · n={d}{s}", .{ glyph(transition.from, &from), glyph(transition.to, &to), @as(f64, @floatFromInt(transition.timing.median_us)) / 1000, @as(f64, @floatFromInt(transition.timing.p95_us)) / 1000, transition.timing.count, if (transition.timing.count < 5) " · limited evidence" else "" }), .{ .y = 522 + @as(f32, @floatFromInt(row)) * 32, .w = width, .h = 30 }, 16, theme.text, null);
            row += 1;
        }
        if (row == 0) presentation.caption("No eligible transition samples.", .{ .y = 522, .w = width, .h = 30 }, 16, theme.muted, null);
        if (analysis.transitions_truncated) presentation.caption("Transition table limited to 256 pairs; raw events remain available.", .{ .y = 805, .w = width, .h = 30 }, 15, theme.muted, null);
    } else if (view.tab == 1) {
        var ymax: f64 = 100;
        for (analysis.rhythm) |bucket| ymax = @max(ymax, bucket.mean_ms * 1.1);
        var xaxis: dvui.PlotWidget.Axis = .{ .name = "Active exercise time (seconds)", .min = 0, .max = @max(1, @as(f64, @floatFromInt(analysis.active_us)) / 1_000_000) };
        var yaxis: dvui.PlotWidget.Axis = .{ .name = "Mean clean interval (ms)", .min = 0, .max = ymax };
        const plot = dvui.plot(@src(), .{ .x_axis = &xaxis, .y_axis = &yaxis, .mouse_hover = true }, .{ .rect = .{ .y = 136, .w = width, .h = 180 }, .background = true, .color_fill = .{ .color = theme.panel } });
        for (analysis.rhythm, 0..) |bucket, index| {
            const x = @as(f64, @floatFromInt(index)) * xaxis.max.? / 64;
            if (bucket.count > 0) plot.bar(.{ .x = x, .y = bucket.mean_ms, .w = xaxis.max.? / 128, .h = ymax / 100, .color = ui.color(0x548FF5) });
            const marks = [_]usize{ bucket.errors, bucket.corrections, bucket.pauses, bucket.hints };
            for (marks, 0..) |count, kind| if (count > 0) plot.bar(.{ .x = x, .y = @as(f64, @floatFromInt(kind + 1)) * ymax / 30, .w = xaxis.max.? / 128, .h = ymax / 100, .color = ui.color(([_]u24{ 0xE47777, 0xE4B553, 0xAAAAAA, 0x70BF99 })[kind]) });
        }
        plot.deinit();
        presentation.caption("64 active-time buckets · blue timing · red errors · amber corrections · gray pauses · green hints", .{ .y = 322, .w = width, .h = 36 }, 15, theme.muted, null);
        const pages = @max(1, (payload.events.len + 11) / 12);
        view.event_page = @min(view.event_page, pages - 1);
        if (ui.button(theme, "Previous", "practice.events.previous", .{ .y = 368, .w = 120, .h = 38 }) and view.event_page > 0) view.event_page -= 1;
        if (ui.button(theme, "Next", "practice.events.next", .{ .x = 130, .y = 368, .w = 120, .h = 38 })) view.event_page = (view.event_page + 1) % pages;
        presentation.caption(try std.fmt.allocPrint(arena, "Raw events · page {d}/{d} · includes excluded attempts", .{ view.event_page + 1, pages }), .{ .x = 260, .y = 368, .w = width - 260, .h = 38 }, 16, theme.muted, null);
        const start = view.event_page * 12;
        for (payload.events[start..@min(payload.events.len, start + 12)], 0..) |event, index| {
            const label = try std.fmt.allocPrint(arena, "#{d} · {d:.3}s active · {t} · position {d} · {t} · {t}", .{ start + index, @as(f64, @floatFromInt(event.active_us)) / 1_000_000, event.kind, event.position, event.eligibility, event.clock });
            if (compact(theme, label, try std.fmt.allocPrint(arena, "practice.event.{d}", .{start + index}), .{ .y = 415 + @as(f32, @floatFromInt(index)) * 27, .w = width, .h = 25 })) view.event = start + index;
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
            var typed: [4]u8 = undefined;
            presentation.caption(try std.fmt.allocPrint(arena, "#{d}: {s} · typed {s} · raw clock {d}µs · elapsed {d:.3}s", .{ view.event, context.written(), if (event.typed) |cp| glyph(cp, &typed) else "—", event.observed_us, @as(f64, @floatFromInt(event.elapsed_us)) / 1_000_000 }), .{ .y = 758, .w = width, .h = 60 }, 16, theme.text, null);
            presentation.caption(try std.fmt.allocPrint(arena, "Input {t} · batch ID {d} · assistance {d} · correct {any} · interval {s}", .{ event.input, event.batch, event.assistance, event.correct, if (event.interval_us) |interval| try std.fmt.allocPrint(arena, "{d:.3}ms", .{@as(f64, @floatFromInt(interval)) / 1000}) else "excluded" }), .{ .y = 825, .w = width, .h = 38 }, 15, theme.muted, null);
        }
    } else {
        presentation.caption("Physical layer/modifier performance is unavailable from text events alone.", .{ .y = 136, .w = width, .h = 45 }, 20, theme.text, null);
        presentation.paragraph("Frozen proven routes describe possible ways to produce a character, not the route or finger actually used.", .{ .y = 187, .w = width, .h = 48 }, 16, theme.muted);
        presentation.caption(try std.fmt.allocPrint(arena, "Clock provenance: {d} native events · {d} frame timestamps · {d} injected events", .{ analysis.clocks[@backingInt(desktop.practice_timing.Clock.native_event)], analysis.clocks[@backingInt(desktop.practice_timing.Clock.frame)], analysis.clocks[@backingInt(desktop.practice_timing.Clock.injected)] }), .{ .y = 245, .w = width, .h = 38 }, 18, theme.text, null);
        for (analysis.eligibility, 0..) |count, index| presentation.caption(try std.fmt.allocPrint(arena, "{t}: {d} attempts", .{ @as(desktop.practice_timing.Eligibility, @fromBackingInt(@as(u4, @intCast(index)))), count }), .{ .y = 300 + @as(f32, @floatFromInt(index)) * 31, .w = width, .h = 30 }, 16, theme.text, null);
        presentation.paragraph("Pauses/focus changes/corrections reset interval boundaries. Hint exposure remains recorded; counts never turn batch input into physical speed evidence.", .{ .y = 610, .w = width, .h = 60 }, 16, theme.muted);
        if (selected) |cp| for (record.stats[0..record.stat_count]) |stat| if (stat.cp == cp) {
            if (stat.route_count == 0) presentation.caption("No frozen proven route for the selected character.", .{ .y = 685, .w = width, .h = 30 }, 16, theme.muted, null);
            for (stat.routes[0..stat.route_count], 0..) |route, index| presentation.caption(try std.fmt.allocPrint(arena, "Possible route only: layer {d} · key {d} · modifier mask 0x{x}{s}", .{ route.layer, route.key, route.modifiers, if (stat.routes_truncated) " · additional routes omitted" else "" }), .{ .y = 685 + @as(f32, @floatFromInt(index)) * 32, .w = width, .h = 30 }, 16, theme.text, null);
        };
    }
    return .none;
}
