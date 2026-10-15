//! Legacy keymap API and regression tests over the shared input-source implementation.
const std = @import("std");
const testing = std.testing;
const shared = @import("input-keymap");
pub const zkeycodes = shared.zkeycodes;
pub const KeyCodeFire = shared.KeyCodeFire;
pub const ScanCode = shared.ScanCode;
pub const KeyMap = shared.KeyMap;
pub const TextResult = shared.TextResult;
pub const hid_to_platform = shared.hid_to_platform;
pub const isLayoutDependent = shared.isLayoutDependent;

// ─── Tests ───────────────────────────────────────────────────────────────────

test "keyLabel: layout-dependent keys return true" {
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_A)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_Z)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_1)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_0)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_SPACE)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_DOT)));
    try testing.expect(isLayoutDependent(@backingInt(ScanCode.KC_SLASH)));
}

test "keyLabel: function keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F1)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F11)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F12)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_F24)));
}

test "keyLabel: navigation keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_UP)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_DOWN)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_LEFT)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_RIGHT)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_HOME)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_END)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_INSERT)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_DELETE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PAGE_UP)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PAGE_DOWN)));
}

test "keyLabel: system and lock keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_CAPS_LOCK)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_NUM_LOCK)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PRINT_SCREEN)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_SCROLL_LOCK)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_PAUSE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_APPLICATION)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_KB_POWER)));
}

test "keyLabel: control keys return false (fixed labels)" {
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_ESCAPE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_TAB)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_BACKSPACE)));
    try testing.expect(!isLayoutDependent(@backingInt(ScanCode.KC_ENTER)));
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "TextResult.slice returns correct bytes" {
    var r = TextResult{};
    r.data[0] = 'h';
    r.data[1] = 'i';
    r.len = 2;
    try testing.expectEqualStrings("hi", r.slice());
}

test "TextResult.slice with four-byte UTF-8 sequence" {
    // 4-byte UTF-8 sequence: U+1F600 GRINNING FACE (0xF0 0x9F 0x98 0x80)
    var r = TextResult{};
    r.data[0] = 0xF0;
    r.data[1] = 0x9F;
    r.data[2] = 0x98;
    r.data[3] = 0x80;
    r.len = 4;
    try testing.expectEqualSlices(u8, &.{ 0xF0, 0x9F, 0x98, 0x80 }, r.slice());
}

test "TextResult default is empty and not a label" {
    const r = TextResult{};
    try testing.expectEqual(@as(u8, 0), r.len);
    try testing.expectEqualStrings("", r.slice());
    try testing.expect(!r.isLabel());
}

test "KeyMap: basic latin letters (US layout assumed)" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_a = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A) });
    try testing.expectEqualStrings("a", r_a.slice());
    try testing.expect(!r_a.isLabel());

    const r_A = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A), .tap_modifiers = .{ .left_shift = true } });
    try testing.expectEqualStrings("A", r_A.slice());
    try testing.expect(!r_A.isLabel());

    const r_z = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_Z) });
    try testing.expectEqualStrings("z", r_z.slice());
    try testing.expect(!r_z.isLabel());
}

test "KeyMap: digits and shifted digits (US layout)" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r1 = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_1) });
    try testing.expectEqualStrings("1", r1.slice());

    const r_bang = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_1), .tap_modifiers = .{ .left_shift = true } });
    try testing.expectEqualStrings("!", r_bang.slice());

    const r0 = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_0) });
    try testing.expectEqualStrings("0", r0.slice());
}

test "KeyMap: space and common punctuation (US layout)" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_sp = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_SPACE) });
    try testing.expectEqualStrings(" ", r_sp.slice());

    const r_dot = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_DOT) });
    try testing.expectEqualStrings(".", r_dot.slice());

    const r_comma = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_COMMA) });
    try testing.expectEqualStrings(",", r_comma.slice());

    const r_slash = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_SLASH) });
    try testing.expectEqualStrings("/", r_slash.slice());
}

test "KeyMap: non-printing keys return their label with is_label=true" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_f1 = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_F1) });
    try testing.expect(r_f1.isLabel());
    try testing.expectEqualStrings("F1", r_f1.getLabel());

    const r_f11 = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_F11) });
    try testing.expect(r_f11.isLabel());
    try testing.expectEqualStrings("F11", r_f11.getLabel());

    const r_up = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_UP) });
    try testing.expect(r_up.isLabel());
    try testing.expectEqualStrings("UP", r_up.getLabel());

    const r_del = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_DELETE) });
    try testing.expect(r_del.isLabel());
    try testing.expectEqualStrings("DEL", r_del.getLabel());

    const r_pgdn = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_PAGE_DOWN) });
    try testing.expect(r_pgdn.isLabel());
    try testing.expectEqualStrings("PGDN", r_pgdn.getLabel());
}

test "KeyMap: get text after dead keys" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_quot = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_QUOTE), .dead = true });
    try testing.expectEqualStrings("'", r_quot.slice());

    const r_z = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_Z) });
    try testing.expectEqualStrings("z", r_z.slice());
    try testing.expect(!r_z.isLabel());
}

test "KeyMap: ESC returns label ESCAPE with is_label=true" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_esc = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_ESCAPE) });
    try testing.expect(r_esc.isLabel());
    try testing.expectEqualStrings("ESC", r_esc.getLabel());
}

test "KeyMap: shift modifier produces uppercase" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A), .tap_modifiers = .{ .left_shift = true } });
    try testing.expectEqualStrings("A", r.slice());
}

test "KeyMap: Tab, Enter, Backspace return their named labels" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_tab = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_TAB) });
    try testing.expect(r_tab.isLabel());
    try testing.expectEqualStrings("TAB", r_tab.getLabel());

    const r_enter = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_ENTER) });
    try testing.expect(r_enter.isLabel());
    try testing.expectEqualStrings("ENT", r_enter.getLabel());

    const r_bs = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_BACKSPACE) });
    try testing.expect(r_bs.isLabel());
    try testing.expectEqualStrings("BSPC", r_bs.getLabel());
}

test "KeyMap: shift produces uppercase (platform behavior)" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A), .tap_modifiers = .{ .left_shift = true } });
    try testing.expectEqualStrings("A", r.slice());
}

test "KeyMap: same keycode produces same output" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r_first = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A) });
    const r_again = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A) });
    try testing.expectEqualStrings(r_first.slice(), r_again.slice());
}

test "KeyMap: numpad keys produce digit and operator characters (US layout)" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);

    const r1 = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_KP_1) });
    try testing.expectEqualStrings("1", r1.slice());

    const r_plus = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_KP_PLUS) });
    try testing.expectEqualStrings("+", r_plus.slice());
}

test "KeyMap: refresh does not crash" {
    var km: KeyMap = undefined;
    KeyMap.init(&km);
    defer KeyMap.deinit(&km);
    km.refresh();
    const r = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_A) });
    try testing.expectEqualStrings("a", r.slice());
}

test "unavailable native backend keeps fixed labels and returns empty text" {
    var km: KeyMap = .{};
    try testing.expect(!km.available());
    try testing.expectEqualStrings("", km.keyToText(.{ .tap_keycode = 4 }).slice());
    const label = km.keyToText(.{ .tap_keycode = @backingInt(ScanCode.KC_F1) });
    try testing.expectEqualStrings("F1", label.getLabel());
    km.refresh();
    km.deinit();
}
