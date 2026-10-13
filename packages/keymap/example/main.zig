const std = @import("std");
const zkeymap = @import("zkeymap");

/// Collects a sequence of key events into text written to `writer`.
/// Label keys (F-keys, arrows, …) are logged via std.log.debug and skipped in the output.
pub fn eventsToText(km: *zkeymap.KeyMap, events: []const zkeymap.KeyCodeFire, writer: anytype) !void {
    for (events) |ev| {
        const text = km.keyToText(ev);
        if (text.isLabel()) {
            std.log.debug("label key: {s}", .{text.getLabel()});
        } else if (text.len > 0) {
            try writer.writeAll(text.slice());
        }
    }
}

pub fn main() !void {
    var km: zkeymap.KeyMap = undefined;
    zkeymap.KeyMap.init(&km);
    defer zkeymap.KeyMap.deinit(&km);

    const events: []const zkeymap.KeyCodeFire = &.{
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_H), .tap_modifiers = .{ .left_shift = true } },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_F1) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_I) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_UP) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_1), .tap_modifiers = .{ .left_shift = true } },
    };

    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try eventsToText(&km, events, &fbs);

    std.debug.print("{s}\n", .{fbs.buffered()}); // "Hi!"
}

pub const std_options: std.Options = .{
    .log_level = .debug,
};

test "readme sample: events produce Hi! (US QWERTY assumed)" {
    var km: zkeymap.KeyMap = undefined;
    zkeymap.KeyMap.init(&km);
    defer zkeymap.KeyMap.deinit(&km);

    const events: []const zkeymap.KeyCodeFire = &.{
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_H), .tap_modifiers = .{ .left_shift = true } },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_I) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_1), .tap_modifiers = .{ .left_shift = true } },
    };

    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try eventsToText(&km, events, &fbs);

    try std.testing.expectEqualStrings("Hi!", fbs.buffered());
}

test "eventsToText: label keys are skipped in writer output" {
    var km: zkeymap.KeyMap = undefined;
    zkeymap.KeyMap.init(&km);
    defer zkeymap.KeyMap.deinit(&km);

    const events: []const zkeymap.KeyCodeFire = &.{
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_A) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_F1) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_B) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_UP) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_C) },
    };

    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try eventsToText(&km, events, &fbs);

    try std.testing.expectEqualStrings("abc", fbs.buffered());
}

test "eventsToText: three text events produce three bytes (any layout)" {
    var km: zkeymap.KeyMap = undefined;
    zkeymap.KeyMap.init(&km);
    defer zkeymap.KeyMap.deinit(&km);

    const events: []const zkeymap.KeyCodeFire = &.{
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_H), .tap_modifiers = .{ .left_shift = true } },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_I) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_1), .tap_modifiers = .{ .left_shift = true } },
    };

    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try eventsToText(&km, events, &fbs);

    try std.testing.expect(fbs.buffered().len == 3);
}

test "eventsToText: label keys do not contribute bytes to the writer" {
    var km: zkeymap.KeyMap = undefined;
    zkeymap.KeyMap.init(&km);
    defer zkeymap.KeyMap.deinit(&km);

    const events: []const zkeymap.KeyCodeFire = &.{
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_A) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_F1) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_B) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_UP) },
        .{ .tap_keycode = @backingInt(zkeymap.ScanCode.KC_C) },
    };

    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try eventsToText(&km, events, &fbs);

    try std.testing.expect(fbs.buffered().len == 3);
}
