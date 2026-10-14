//! Retained tutor word and animated context rendering; no input or runner I/O.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const desktop = @import("desktop-core");
const practice = desktop.practice;
const view = desktop.practice_view;
pub const Scroll = struct { position: f32 = 0, at: ?u64 = null };
pub fn caption(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color, tag: ?[]const u8) void {
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, .{ .rect = bounds, .font = dvui.Font.theme(.body).withSize(size), .color_text = .{ .color = color }, .padding = .{}, .tag = tag, .id_extra = std.hash.Wyhash.hash(0, std.mem.asBytes(&bounds)) });
}
pub fn paragraph(text: []const u8, bounds: dvui.Rect, size: f32, color: dvui.Color) void {
    const layout = dvui.textLayout(@src(), .{ .break_lines = true }, .{ .rect = bounds, .font = dvui.Font.theme(.body).withSize(size), .color_text = .{ .color = color }, .padding = .{}, .id_extra = std.hash.Wyhash.hash(0, std.mem.asBytes(&bounds)) });
    layout.addText(text, .{});
    layout.deinit();
}
fn letter(s: *const practice.Session, index: usize, focus: usize, bounds: dvui.Rect, size: f32, t: ui.Theme, hero: bool) void {
    const current = index == focus and s.state != .complete;
    const wrong = index < s.len and s.typed[index] != s.reference[index];
    const text_color = if (current) dvui.Color.white else if (wrong) ui.color(0xE85A68) else if (index < s.len) ui.color(if (t.bg.r > 100) 0x2C876E else 0x69BFA3) else if (hero) t.text else t.muted;
    var bytes: [4]u8 = undefined;
    const text = view.glyph(s.reference[index], current or hero, &bytes);
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .rect = bounds,
        .font = dvui.Font.theme(.mono).withSize(size),
        .padding = .{},
        .margin = .{},
        .id_extra = index,
        .color_text = .{ .color = text_color },
        .background = current,
        .color_fill = .{ .color = if (wrong) ui.color(0xCF4055) else ui.color(0x287AF2) },
        .corners = .all(6),
        .tag = if (current and !hero) "practice.current" else null,
    });
}
pub fn focusWord(s: *const practice.Session, active: bool, t: ui.Theme, bounds: dvui.Rect, focus: usize) void {
    const panel = dvui.box(@src(), .{}, .{ .rect = bounds, .background = true, .color_fill = .{ .color = t.control }, .corners = .all(14), .padding = .{}, .tag = "practice.word" });
    defer panel.deinit();
    if (!active) {
        caption("Learn your layout, one word at a time", .{ .x = 0, .y = 16, .w = bounds.w, .h = bounds.h - 32 }, @min(34, bounds.h * 0.4), t.text, null);
        return;
    }
    if (s.state == .complete) {
        caption("Exercise complete", .{ .x = 0, .y = 8, .w = bounds.w, .h = bounds.h - 36 }, @min(44, bounds.h * 0.5), ui.color(0x36A77C), null);
        caption("Your character rundown is ready", .{ .x = 0, .y = bounds.h - 34, .w = bounds.w, .h = 28 }, 16, t.muted, null);
        return;
    }
    const range = view.word(s.reference[0..s.reference_len], focus);
    const count = range.end - range.start;
    if (count == 0) return;
    const size = @min(@min(@as(f32, 52), bounds.h * 0.5), (bounds.w - 60) / (@as(f32, @floatFromInt(count)) * 0.65));
    const cell = dvui.Font.theme(.mono).withSize(size).textSize("M").w + 4;
    const x = (bounds.w - cell * @as(f32, @floatFromInt(count))) / 2;
    const glyph_height = @min(bounds.h - 43, size * 1.4);
    for (range.start..range.end) |i| letter(s, i, focus, .{ .x = x + @as(f32, @floatFromInt(i - range.start)) * cell, .y = (bounds.h - 43 - glyph_height) / 2 + 4, .w = cell, .h = glyph_height }, size, t, true);
    const wrong = focus < s.len;
    const name = switch (s.reference[focus]) {
        ' ' => "Space",
        '\n' => "Enter",
        '\t' => "Tab",
        else => "Next highlighted letter",
    };
    var wrong_bytes: [4]u8 = undefined;
    const hint = if (wrong) std.fmt.allocPrint(dvui.currentWindow().arena(), "Typed «{s}» · Backspace {d} character{s} to correct", .{ view.glyph(s.typed[focus], true, &wrong_bytes), s.len - focus, if (s.len - focus == 1) "" else "s" }) catch "Correct the red letter" else if (s.state == .paused) "Paused · press Resume to continue" else name;
    caption(hint, .{ .x = 0, .y = bounds.h - 36, .w = bounds.w, .h = 30 }, @min(17, bounds.h * 0.18), if (wrong) ui.color(0xE85A68) else t.muted, "practice.next");
}
pub fn context(s: *const practice.Session, active: bool, mode: desktop.practice_controller.Mode, scroll: *Scroll, fixture: bool, t: ui.Theme, bounds: dvui.Rect, focus: usize, now: u64) void {
    const panel = dvui.box(@src(), .{}, .{ .rect = bounds, .background = true, .color_fill = .{ .color = t.bg }, .corners = .all(12), .padding = .{}, .tag = "practice.text" });
    defer panel.deinit();
    if (!active) {
        caption("Type the highlighted character. Your keyboard guide stays below.", .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h }, 22, t.muted, null);
        return;
    }
    const font_size = @min(@as(f32, 30), @max(@as(f32, 22), bounds.h / 5));
    const cell = dvui.Font.theme(.mono).withSize(font_size).textSize("M").w + 2;
    const columns: usize = @intFromFloat(@max(1, @floor((bounds.w - 80) / cell)));
    var storage: [8192]view.Range = undefined;
    const ranges = view.lines(s.reference[0..s.reference_len], columns, &storage);
    const active_line = view.currentLine(ranges, focus);
    const target: f32 = @floatFromInt(active_line);
    const previous = scroll.at;
    const elapsed: f32 = if (previous) |at| @as(f32, @floatFromInt(@min(now -| at, 100_000))) / 1_000_000 else 1;
    scroll.at = now;
    if (fixture or previous == null or @abs(target - scroll.position) > 3) scroll.position = target else scroll.position += (target - scroll.position) * (1 - @exp(-elapsed * 18));
    if (@abs(scroll.position - target) > 0.01) dvui.refresh(null, @src(), null);
    const line_height = font_size * 1.65;
    const clip = dvui.clip(panel.data().contentRectScale().r);
    defer dvui.clipSet(clip);
    for (ranges, 0..) |range, row_index| {
        const y = bounds.h / 2 - line_height / 2 + (@as(f32, @floatFromInt(row_index)) - scroll.position) * line_height;
        if (y + line_height < 0 or y > bounds.h) continue;
        const row = dvui.box(@src(), .{}, .{ .id_extra = row_index, .rect = .{ .x = 8, .y = y, .w = bounds.w - 16, .h = line_height }, .padding = .{}, .background = row_index == active_line, .color_fill = .{ .color = t.control }, .corners = .all(8) });
        defer row.deinit();
        if (mode == .zig) dvui.label(@src(), "{d}", .{std.mem.count(u21, s.reference[0..range.start], &.{'\n'}) + 1}, .{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = line_height }, .font = dvui.Font.theme(.mono).withSize(14), .color_text = .{ .color = t.muted } });
        const count: f32 = @floatFromInt(range.end - range.start);
        const x = if (mode == .zig) @as(f32, 50) else @max(40, (bounds.w - 16 - count * cell) / 2);
        for (range.start..range.end) |i| letter(s, i, focus, .{ .x = x + @as(f32, @floatFromInt(i - range.start)) * cell, .y = 0, .w = cell, .h = line_height }, font_size, t, false);
    }
}
