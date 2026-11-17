//! Retained cache-name to immutable TVG asset mapping. No asset generation.
const std = @import("std");
const icons = @import("icons");
const desktop = @import("desktop-core");
pub const gui_icon = icons.tvg.lucide.command;
const Entry = struct { name: []const u8, bytes: []const u8 };
pub const entries = [_]Entry{
    .{ .name = "companion", .bytes = icons.tvg.lucide.@"circuit-board" },
    .{ .name = "shutdown", .bytes = icons.tvg.lucide.power },
    .{ .name = "vol_up", .bytes = icons.tvg.lucide.@"volume-2" },
    .{ .name = "vol_down", .bytes = icons.tvg.lucide.@"volume-1" },
    .{ .name = "mute", .bytes = icons.tvg.lucide.@"volume-x" },
    .{ .name = "next", .bytes = icons.tvg.lucide.@"skip-forward" },
    .{ .name = "prev", .bytes = icons.tvg.lucide.@"skip-back" },
    .{ .name = "m_left", .bytes = icons.tvg.lucide.mouse },
    .{ .name = "m_right", .bytes = icons.tvg.lucide.mouse },
    .{ .name = "m_mid", .bytes = icons.tvg.lucide.mouse },
    .{ .name = "w_up", .bytes = icons.tvg.lucide.@"chevron-up" },
    .{ .name = "w_down", .bytes = icons.tvg.lucide.@"chevron-down" },
    .{ .name = "w_left", .bytes = icons.tvg.lucide.@"chevron-left" },
    .{ .name = "w_right", .bytes = icons.tvg.lucide.@"chevron-right" },
    .{ .name = "backspace", .bytes = icons.tvg.lucide.delete },
    .{ .name = "enter", .bytes = icons.tvg.lucide.@"corner-down-left" },
    .{ .name = "left", .bytes = icons.tvg.lucide.@"arrow-left" },
    .{ .name = "right", .bytes = icons.tvg.lucide.@"arrow-right" },
    .{ .name = "up", .bytes = icons.tvg.lucide.@"arrow-up" },
    .{ .name = "down", .bytes = icons.tvg.lucide.@"arrow-down" },
    .{ .name = "tab", .bytes = icons.tvg.lucide.@"arrow-right-left" },
    .{ .name = "space", .bytes = icons.tvg.lucide.space },
    .{ .name = "page_down", .bytes = icons.tvg.lucide.@"arrow-down-to-line" },
    .{ .name = "page_up", .bytes = icons.tvg.lucide.@"arrow-up-to-line" },
    .{ .name = "home", .bytes = icons.tvg.lucide.@"arrow-left-to-line" },
    .{ .name = "end", .bytes = icons.tvg.lucide.@"arrow-right-to-line" },
};
pub fn lookup(name: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.bytes;
    return null;
}
const context: u8 = 0;
pub fn resolver() desktop.label_cache.IconResolver {
    return .{ .context = &context, .resolve = resolve };
}
fn resolve(_: *const anyopaque, gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
    const bytes = lookup(name) orelse return null;
    return try gpa.dupe(u8, bytes);
}
test "every retained cache icon parses and resolver returns owned immutable bytes" {
    const t = std.testing;
    for (entries) |entry| {
        var reader = std.Io.Reader.fixed(entry.bytes);
        var parser = try @import("svg2tvg").tvg.parse(t.allocator, &reader);
        defer parser.deinit();
        var count: usize = 0;
        while (try parser.next()) |_| count += 1;
        try t.expect(count > 0);
        const owned = (try resolve(&context, t.allocator, entry.name)).?;
        defer t.allocator.free(owned);
        try t.expectEqualSlices(u8, entry.bytes, owned);
        try t.expect(owned.ptr != entry.bytes.ptr);
    }
    try t.expect(try resolve(&context, t.allocator, "unknown") == null);
}
