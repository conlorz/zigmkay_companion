const std = @import("std");
const dvui = @import("dvui");
const geometry = @import("desktop-geometry");
const fonts = @import("editor-fonts");
pub fn color(hex: u24) dvui.Color {
    return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex), .a = 255 };
}
pub const Theme = struct {
    bg: dvui.Color,
    panel: dvui.Color,
    control: dvui.Color,
    border: dvui.Color,
    text: dvui.Color,
    muted: dvui.Color,
    pub fn get(light: bool) Theme {
        return if (light) .{ .bg = color(0xEEF0F3), .panel = color(0xFFFFFF), .control = color(0xF4F5F7), .border = color(0xD4D9E0), .text = color(0x20242A), .muted = color(0x657080) } else .{ .bg = color(0x191B1F), .panel = color(0x22252A), .control = color(0x30343B), .border = color(0x424852), .text = color(0xF4F5F7), .muted = color(0xAAB2BF) };
    }
};
pub fn rect(r: anytype) dvui.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}
pub fn options(t: Theme, r: dvui.Rect, size: f32) dvui.Options {
    return .{ .rect = r, .font = fonts.font("", size), .color_text = .{ .color = t.text }, .color_fill = .{ .color = t.control }, .color_border = .{ .color = t.border }, .margin = .{}, .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 }, .corners = .all(6) };
}
pub fn label(t: Theme, text: []const u8, r: dvui.Rect, size: f32) void {
    var opts = options(t, r, size);
    opts.font = fonts.font(text, size);
    if (size >= 18) opts.font = opts.font.?.withWeight(.bold);
    opts.id_extra = (@as(usize, @intFromFloat(r.x)) << 16) + @as(usize, @intFromFloat(r.y));
    opts.padding = .{};
    dvui.labelNoFmt(@src(), text, .{}, opts);
}
pub fn button(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect) bool {
    var data: dvui.WidgetData = undefined;
    return buttonData(t, text, tag, r, &data);
}
pub fn buttonEnabled(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect, enabled: bool) bool {
    if (enabled) return button(t, text, tag, r);
    var opts = options(t, r, 15);
    opts.tag = tag;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = true;
    opts.color_text = .{ .color = t.muted };
    opts.font = fonts.font(text, 15);
    dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
    return false;
}
pub fn buttonData(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect, data: *dvui.WidgetData) bool {
    var opts = options(t, r, 13);
    opts.font = fonts.font(text, 15);
    opts.tag = tag;
    opts.data_out = data;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = true;
    if (r.w < 40) opts.padding = .all(2);
    if (std.mem.startsWith(u8, tag, "layer.duplicate") or std.mem.startsWith(u8, tag, "layer.delete")) opts.background = false;
    if (std.mem.eql(u8, tag, "try.test") or std.mem.eql(u8, tag, "practice.start") or std.mem.eql(u8, tag, "firmware.build") or std.mem.eql(u8, tag, "firmware.inspect")) {
        opts.color_fill = .{ .color = color(0x126AFF) };
        opts.color_text = .{ .color = color(0xFFFFFF) };
    }
    return dvui.button(@src(), text, .{}, opts);
}
pub fn panel(t: Theme, which: geometry.Panel) *dvui.BoxWidget {
    var bounds = rect(geometry.panel(which));
    const width = @max(@as(f32, 1536), dvui.parentGet().data().contentRect().w);
    if (which == .toolbar) bounds.w = width;
    if (which == .inspector) bounds.w = width - bounds.x - 15;
    var opts = options(t, bounds, 14);
    opts.tag = @tagName(which);
    opts.id_extra = @backingInt(which);
    opts.color_fill = .{ .color = t.panel };
    opts.background = true;
    opts.border = .all(1);
    opts.padding = .{};
    opts.corners = .all(12);
    return dvui.box(@src(), .{}, opts);
}

pub fn drawer(src: std.builtin.SourceLocation, t: Theme, bounds: dvui.Rect, modal: bool) *dvui.FloatingWindowWidget {
    return dvui.floatingWindow(src, .{ .modal = modal }, .{ .rect = bounds, .padding = .all(18), .background = true, .color_fill = .{ .color = t.panel } });
}
pub fn editDrawer(src: std.builtin.SourceLocation, t: Theme, width: f32) *dvui.FloatingWindowWidget {
    const screen = dvui.windowRect();
    const w = @min(width, screen.w - 48);
    const h = @min(@as(f32, 960), screen.h - 48);
    return drawer(src, t, .{ .x = (screen.w - w) / 2, .y = (screen.h - h) / 2, .w = w, .h = h }, true);
}
