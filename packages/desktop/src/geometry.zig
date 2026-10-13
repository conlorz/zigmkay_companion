const std = @import("std");
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Panel = enum { toolbar, sidebar, physical, inspector, os, testing, callbacks };
pub const reference = [7]Rect{
    .{ .x = 0, .y = 0, .w = 1536, .h = 67 },
    .{ .x = 15, .y = 77, .w = 247, .h = 932 },
    .{ .x = 273, .y = 77, .w = 796, .h = 425 },
    .{ .x = 1081, .y = 77, .w = 440, .h = 932 },
    .{ .x = 273, .y = 514, .w = 796, .h = 298 },
    .{ .x = 273, .y = 824, .w = 796, .h = 87 },
    .{ .x = 273, .y = 923, .w = 796, .h = 87 },
};
pub const initial = Rect{ .x = 0, .y = 0, .w = 1152, .h = 768 };
pub const minimum = Rect{ .x = 0, .y = 0, .w = 900, .h = 600 };
/// Preserve panel proportions and scale fonts and input coordinates together.
pub fn fitScale(width: f32, height: f32) f32 {
    return @max(0.01, @min(width / 1536, height / 1024));
}
pub fn panel(which: Panel) Rect {
    return reference[@backingInt(which)];
}
test "resized canvas fits both axes without requiring outer scrolling" {
    for ([_]Rect{ minimum, initial, .{ .x = 0, .y = 0, .w = 1400, .h = 800 }, .{ .x = 0, .y = 0, .w = 1920, .h = 1280 } }) |bounds| {
        const scale = fitScale(bounds.w, bounds.h);
        try std.testing.expect(1536 * scale <= bounds.w + 0.01);
        try std.testing.expect(1024 * scale <= bounds.h + 0.01);
    }
    try std.testing.expectEqual(@as(f32, 0.75), fitScale(initial.w, initial.h));
}
test "reference panels match visual specification and remain disjoint" {
    for (reference[1..], 1..) |a, i| {
        try std.testing.expect(a.x >= 15 and a.y >= 77 and a.x + a.w <= 1521 and a.y + a.h <= 1010);
        for (reference[i + 1 ..]) |b| try std.testing.expect(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y);
    }
}
