//! Shared retained-editor theme, layout options and controls.
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

    const light_theme: Theme = .{
        .bg = color(0xEEF0F3),
        .panel = color(0xFFFFFF),
        .control = color(0xF4F5F7),
        .border = color(0xD4D9E0),
        .text = color(0x20242A),
        .muted = color(0x657080),
    };
    const dark_theme: Theme = .{
        .bg = color(0x191B1F),
        .panel = color(0x22252A),
        .control = color(0x30343B),
        .border = color(0x424852),
        .text = color(0xF4F5F7),
        .muted = color(0xAAB2BF),
    };

    pub fn get(light: bool) Theme {
        return if (light) light_theme else dark_theme;
    }
};

pub fn rect(r: anytype) dvui.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// Base options for an absolutely placed control in theme colors.
pub fn options(t: Theme, r: dvui.Rect, size: f32) dvui.Options {
    return .{
        .rect = r,
        .font = fonts.font("", size),
        .color_text = .{ .color = t.text },
        .color_fill = .{ .color = t.control },
        .color_border = .{ .color = t.border },
        .margin = .{},
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .corners = .all(6),
    };
}

/// A label identified by its position, bold from 18 points up.
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

/// A button, or a muted label in its place while disabled.
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

/// Buttons drawn with the accent fill.
const primary_tags = [_][]const u8{ "try.test", "practice.start", "firmware.build", "firmware.inspect" };

/// A button identified by its tag.
pub fn buttonData(t: Theme, text: []const u8, tag: []const u8, r: dvui.Rect, data: *dvui.WidgetData) bool {
    var opts = options(t, r, 13);
    opts.font = fonts.font(text, 15);
    opts.tag = tag;
    opts.data_out = data;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    opts.background = true;
    if (r.w < 40) opts.padding = .all(2);
    if (std.mem.startsWith(u8, tag, "layer.duplicate") or std.mem.startsWith(u8, tag, "layer.delete")) opts.background = false;
    for (primary_tags) |primary| {
        if (!std.mem.eql(u8, tag, primary)) continue;
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
    return dvui.floatingWindow(src, .{ .modal = modal }, .{
        .rect = bounds,
        .padding = .all(18),
        .background = true,
        .color_fill = .{ .color = t.panel },
    });
}

/// A modal drawer centered in the window, at most `width` wide and 960 high.
pub fn editDrawer(src: std.builtin.SourceLocation, t: Theme, width: f32) *dvui.FloatingWindowWidget {
    const screen = dvui.windowRect();
    const w = @min(width, screen.w - 48);
    const h = @min(@as(f32, 960), screen.h - 48);
    return drawer(src, t, .{ .x = (screen.w - w) / 2, .y = (screen.h - h) / 2, .w = w, .h = h }, true);
}

/// Draws the companion signal icons that a keycap caption cannot show: an icon
/// centered on companion and shutdown taps, and one after the caption's last
/// line for hold signals 253 (toggle logging) and 254 (quit).
pub fn signalIcons(key_options: dvui.Options, bounds: dvui.Rect, caption: []const u8, icon_name: []const u8, hold_signal: ?u8) void {
    var icon_options = key_options;
    icon_options.data_out = null;
    icon_options.tag = null;
    icon_options.background = false;
    icon_options.border = .{};
    const shutdown = std.mem.eql(u8, icon_name, "shutdown");
    if (shutdown or std.mem.eql(u8, icon_name, "companion")) {
        var tap_options = icon_options;
        tap_options.rect = .{ .x = bounds.x + bounds.w * 0.3, .y = bounds.y + bounds.h * 0.3, .w = bounds.w * 0.4, .h = bounds.h * 0.4 };
        dvui.icon(@src(), "tap_signal", if (shutdown) dvui.entypo.cross else dvui.entypo.eye, .{}, tap_options);
    }
    const id = hold_signal orelse return;
    if (id < 253) return;
    const font = key_options.font.?;
    const last_line = caption[(if (std.mem.lastIndexOfScalar(u8, caption, '\n')) |newline| newline + 1 else 0)..];
    const text_size = font.textSize(caption);
    const line_size = font.textSize(last_line);
    const icon_size = font.size;
    var hold_options = icon_options;
    hold_options.padding = .{};
    hold_options.margin = .{};
    hold_options.rect = .{
        .x = bounds.x + (bounds.w + line_size.w) / 2 - icon_size,
        .y = bounds.y + (bounds.h + text_size.h) / 2 - line_size.h + (line_size.h - icon_size) / 2,
        .w = icon_size,
        .h = icon_size,
    };
    dvui.icon(@src(), "hold_signal", if (id == 254) dvui.entypo.cross else dvui.entypo.eye, .{}, hold_options);
}
