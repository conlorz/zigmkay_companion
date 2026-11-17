const p = @import("project");
const std = @import("std");
const Modifiers = @import("layout-model").Modifiers;
pub const Host = enum { macos, windows, linux };
pub const running_host: Host = switch (@import("builtin").os.tag) {
    .macos => .macos,
    .windows => .windows,
    else => .linux,
};
pub fn runningHost() Host {
    return running_host;
}
// Keycaps omit names and modifier handedness; inspectors retain both.
pub fn keycapUsage(host: Host, code: u8, buffer: []u8) []const u8 {
    if (code >= 224 and code <= 231) return keycapModifiers(host, @as(u8, 1) << @intCast(code - 224), buffer);
    return switch (code) {
        40, 88 => "↩",
        41 => "⎋",
        42 => "⌫",
        43 => "⇥",
        44 => "␣",
        57 => "⇪",
        74 => "↖",
        75 => "⇞",
        76 => "⌦",
        77 => "↘",
        78 => "⇟",
        79 => "→",
        80 => "←",
        81 => "↓",
        82 => "↑",
        83 => "⇭",
        else => usage(code, buffer),
    };
}
pub fn keycapModifiers(host: Host, bits: u8, buffer: []u8) []const u8 {
    const names: [4][]const u8 = switch (host) {
        .macos => .{ "⌃", "⇧", "⌥", "⌘" },
        .windows => .{ "Ctrl", "⇧", "Alt", "Win" },
        .linux => .{ "Ctrl", "⇧", "Alt", "Super" },
    };
    var used: usize = 0;
    for (names, 0..) |name, bit| {
        if ((bits | (bits >> 4)) & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        const part = std.fmt.bufPrint(buffer[used..], "{s}{s}", .{ if (used == 0 or host == .macos) "" else "+", name }) catch return "Modifiers";
        used += part.len;
    }
    return buffer[0..used];
}
pub fn hostUsage(host: Host, code: u8, buffer: []u8) []const u8 {
    if (code >= 224 and code <= 231) return hostModifierNames(host, @as(u8, 1) << @intCast(code - 224), buffer);
    if (host == .macos) return switch (code) {
        40 => "↩ Return",
        42 => "⌫ Backspace",
        43 => "⇥ Tab",
        57 => "⇪ Caps Lock",
        79 => "→ Right",
        80 => "← Left",
        81 => "↓ Down",
        82 => "↑ Up",
        else => usage(code, buffer),
    };
    return usage(code, buffer);
}
pub fn hostModifierNames(host: Host, bits: u8, buffer: []u8) []const u8 {
    const names: [8][]const u8 = switch (host) {
        .macos => .{ "L ⌃ Control", "L ⇧ Shift", "L ⌥ Option", "L ⌘ Command", "R ⌃ Control", "R ⇧ Shift", "R ⌥ Option", "R ⌘ Command" },
        .windows => .{ "L Ctrl", "L Shift", "L Alt", "L Win", "R Ctrl", "R Shift", "R Alt", "R Win" },
        .linux => .{ "L Ctrl", "L Shift", "L Alt", "L Super", "R Ctrl", "R Shift", "R Alt", "R Super" },
    };
    var used: usize = 0;
    for (names, 0..) |name, bit| {
        if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        const part = std.fmt.bufPrint(buffer[used..], "{s}{s}", .{ if (used == 0) "" else "+", name }) catch return "Modifiers";
        used += part.len;
    }
    return buffer[0..used];
}
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    return false;
}
pub fn matchesUsage(host: Host, code: u8, query: []const u8) bool {
    if (std.fmt.parseInt(u8, query, 0)) |numeric| {
        if (numeric == code) return true;
    } else |_| {}
    var buffer: [128]u8 = undefined;
    if (containsIgnoreCase(hostUsage(host, code, &buffer), query) or containsIgnoreCase(usage(code, &buffer), query)) return true;
    const aliases = switch (code) {
        224, 228 => "Ctrl Control ⌃",
        225, 229 => "Shift ⇧",
        226, 230 => "Alt Option ⌥",
        227, 231 => "GUI Cmd Command Win Super ⌘",
        40 => "Return Enter ↩",
        42 => "Backspace ⌫",
        43 => "Tab ⇥",
        else => "",
    };
    return aliases.len > 0 and containsIgnoreCase(aliases, query);
}
pub fn usage(code: u8, buffer: []u8) []const u8 {
    if (code >= 4 and code <= 29) {
        if (buffer.len == 0) return "?";
        buffer[0] = 'A' + code - 4;
        return buffer[0..1];
    }
    if (code >= 30 and code <= 38) {
        if (buffer.len == 0) return "?";
        buffer[0] = '1' + code - 30;
        return buffer[0..1];
    }
    return switch (code) {
        0 => "—",
        39 => "0",
        40 => "Return",
        41 => "Esc",
        42 => "Backspace",
        43 => "Tab",
        44 => "Space",
        45 => "-",
        46 => "=",
        47 => "[",
        48 => "]",
        49 => "\\",
        51 => ";",
        52 => "'",
        53 => "`",
        54 => ",",
        55 => ".",
        56 => "/",
        57 => "Caps",
        70 => "Print Screen",
        71 => "Scroll Lock",
        72 => "Pause",
        73 => "Insert",
        74 => "Home",
        75 => "Page Up",
        76 => "Delete",
        77 => "End",
        78 => "Page Down",
        79 => "Right",
        80 => "Left",
        81 => "Down",
        82 => "Up",
        224 => "L Ctrl",
        225 => "L Shift",
        226 => "L Alt",
        227 => "L GUI",
        228 => "R Ctrl",
        229 => "R Shift",
        230 => "R Alt",
        231 => "R GUI",
        252 => "BOOT",
        253 => "Print statistics",
        254 => "Show / hide companion",
        255 => "Quit companion",
        else => knownUsage(code, buffer),
    };
}
fn knownUsage(code: u8, buffer: []u8) []const u8 {
    const info = @typeInfo(@import("zkeycodes").layouts.keycodes.kc.basic).@"enum";
    inline for (info.field_names, info.field_values) |enum_name, enum_value| {
        const field = .{ .name = enum_name, .value = enum_value };
        if (field.value == code) {
            const name = field.name[3..];
            const len = @min(name.len, buffer.len);
            for (name[0..len], 0..) |char, i| buffer[i] = if (char == '_') ' ' else char;
            return buffer[0..len];
        }
    }
    return std.fmt.bufPrint(buffer, "HID {d}", .{code}) catch "?";
}
pub fn tap(value: p.Tap, buffer: []u8) []const u8 {
    return tapLabel(value, buffer, false);
}
fn tapLabel(value: p.Tap, buffer: []u8, compact: bool) []const u8 {
    return tapLabelWithLayout(null, value, .{}, buffer, compact);
}
fn tapLabelWithLayout(km: anytype, value: p.Tap, physical: Modifiers, buffer: []u8, compact: bool) []const u8 {
    var used: usize = 0;
    var scratch: [256]u8 = undefined;
    if (value.key_press) |key| {
        var key_buffer: [64]u8 = undefined;
        var mod_buffer: [192]u8 = undefined;
        var key_name = if (compact and key.tap_keycode >= 254) "" else if (compact) keycapUsage(running_host, key.tap_keycode, &key_buffer) else hostUsage(running_host, key.tap_keycode, &key_buffer);
        var mods = if (@import("zkeymap").isLayoutDependent(key.tap_keycode) and key.tap_keycode != 44) key.tap_modifiers.add(physical) else key.tap_modifiers;
        if (comptime @TypeOf(km) != @TypeOf(null)) {
            // Shortcuts retain their modifiers, but their base key follows the
            // layout. Text-producing modifiers are consumed only on success.
            const shortcut = mods.left_ctrl or mods.right_ctrl or mods.left_gui or mods.right_gui;
            const translated = km.keyToText(.{ .tap_keycode = key.tap_keycode, .tap_modifiers = if (shortcut) .{} else mods, .dead = key.dead });
            const text = translated.slice();
            if (!translated.isLabel() and text.len > 0 and key.tap_keycode != 44) {
                var printable = true;
                for (text) |byte| if (byte < 32) {
                    printable = false;
                };
                if (std.mem.indexOfScalar(u8, text, 127) != null) printable = false;
                if (printable) {
                    @memcpy(key_buffer[0..text.len], text);
                    // Keep conventional uppercase keycaps for plain letters.
                    if (compact and (shortcut or mods.toByte() == 0) and text.len == 1) key_buffer[0] = std.ascii.toUpper(key_buffer[0]);
                    key_name = key_buffer[0..text.len];
                    if (!shortcut) mods = .{};
                }
            }
        }
        const name = if (mods.toByte() == 0) key_name else std.fmt.bufPrint(&scratch, "{s}{s}{s}", .{ if (compact) keycapModifiers(running_host, mods.toByte(), &mod_buffer) else hostModifierNames(running_host, mods.toByte(), &mod_buffer), if (compact and running_host == .macos) "" else "+", key_name }) catch "Chord";
        appendSummary(buffer, &used, name);
        if (key.dead) appendSummary(buffer, &used, "Dead key");
    }
    if (value.media_key) |media| appendSummary(buffer, &used, if (compact) switch (media) {
        .VolumeUp => "🔊",
        .VolumeDown => "🔉",
        .VolumeMute => "🔇",
        .NextTrack => "⏭",
        .PreviousTrack => "⏮",
    } else @tagName(media));
    if (value.mouse_action) |mouse| appendSummary(buffer, &used, @tagName(mouse));
    if (value.custom) |custom| {
        if (!compact or custom < 254) appendSummary(buffer, &used, signal(custom, &scratch));
    }
    if (value.one_shot) |one| {
        appendSummary(buffer, &used, "One-shot");
        if (one.layer_id) |id| appendSummary(buffer, &used, std.fmt.bufPrint(&scratch, "L{d}", .{id}) catch "Layer");
        if (one.hold_modifiers.toByte() != 0) appendSummary(buffer, &used, if (compact) keycapModifiers(running_host, one.hold_modifiers.toByte(), &scratch) else hostModifierNames(running_host, one.hold_modifiers.toByte(), &scratch));
        if (one.custom) |id| appendSummary(buffer, &used, std.fmt.bufPrint(&scratch, "Callback {d}", .{id}) catch "Callback");
    }
    return if (used == 0) (if (compact and ((value.custom != null and value.custom.? >= 253) or (value.key_press != null and value.key_press.?.tap_keycode >= 254))) "" else "No tap") else buffer[0..used];
}
fn appendSummary(buffer: []u8, used: *usize, text: []const u8) void {
    const part = std.fmt.bufPrint(buffer[used.*..], "{s}{s}", .{ if (used.* == 0) "" else " · ", text }) catch return;
    used.* += part.len;
}
pub fn signal(id: u8, buffer: []u8) []const u8 {
    return switch (id) {
        253 => "Toggle companion logging",
        254 => "Quit companion",
        255 => "Show / hide companion",
        else => std.fmt.bufPrint(buffer, "Custom {d}", .{id}) catch "Custom",
    };
}
pub fn modifierNames(bits: u8, buffer: []u8) []const u8 {
    var used: usize = 0;
    for ([_][]const u8{ "L Ctrl", "L Shift", "L Alt", "L GUI", "R Ctrl", "R Shift", "R Alt", "R GUI" }, 0..) |name, i| {
        if (bits & (@as(u8, 1) << @intCast(i)) == 0) continue;
        const part = std.fmt.bufPrint(buffer[used..], "{s}{s}", .{ if (used == 0) "" else "+", name }) catch return "Modifiers";
        used += part.len;
    }
    return buffer[0..used];
}
pub fn keycap(value: ?p.Action, doc: p.Document, buffer: []u8) []const u8 {
    return keycapWithLayout(null, value, doc, .{}, buffer);
}
test "companion keycaps omit signal prose for icon rendering" {
    const doc: p.Document = .{ .schema_version = 1, .board_id = @splat(0), .profile_id = @splat(0), .physical_layout = "fixture", .name = "Fixture", .key_ids = &.{}, .layers = &.{} };
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", keycap(.{ .tap_only = .{ .custom = 255 } }, doc, &buffer));
    try std.testing.expectEqualStrings("", keycap(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 254 } } }, doc, &buffer));
    try std.testing.expect(!containsIgnoreCase(keycap(.{ .hold_only = .{ .custom = 255 } }, doc, &buffer), "Show"));
}
pub fn keycapWithLayout(km: anytype, value: ?p.Action, doc: p.Document, physical: Modifiers, buffer: []u8) []const u8 {
    const a = value orelse return "Inherited";
    var tap_buffer: [128]u8 = undefined;
    var hold_buffer: [128]u8 = undefined;
    return switch (a) {
        .tap_only => |t| tapLabelWithLayout(km, t, physical, buffer, true),
        .tap_with_autofire => |t| tapLabelWithLayout(km, t.tap, physical, buffer, true),
        .tap_hold => |th| std.fmt.bufPrint(buffer, "{s}\nHold {s}", .{ tapLabelWithLayout(km, th.tap, physical, &tap_buffer, true), holdLabel(th.hold, doc, &hold_buffer, true) }) catch "Tap / hold",
        .hold_only => |h| std.fmt.bufPrint(buffer, "Hold{s}{s}", .{ if (h.custom != null and h.custom.? >= 253) " " else "\n", holdLabel(h, doc, &hold_buffer, true) }) catch "Hold",
        else => action(value, buffer),
    };
}
pub fn hold(value: p.Hold, doc: p.Document, buffer: []u8) []const u8 {
    return holdLabel(value, doc, buffer, false);
}
fn holdLabel(value: p.Hold, doc: p.Document, buffer: []u8, compact: bool) []const u8 {
    var used: usize = 0;
    var scratch: [256]u8 = undefined;
    if (value.layer_id) |id| {
        var name: []const u8 = "Missing layer";
        for (doc.layers) |layer| if (layer.id == id) {
            name = layer.name;
            break;
        };
        appendSummary(buffer, &used, if (compact) std.fmt.bufPrint(&scratch, "L{d}", .{id}) catch "Layer" else std.fmt.bufPrint(&scratch, "L{d} {s}", .{ id, name }) catch "Layer");
    }
    if (value.hold_modifiers.toByte() != 0) appendSummary(buffer, &used, if (compact) keycapModifiers(running_host, value.hold_modifiers.toByte(), &scratch) else hostModifierNames(running_host, value.hold_modifiers.toByte(), &scratch));
    if (value.custom) |id| {
        if (id < 253) appendSummary(buffer, &used, std.fmt.bufPrint(&scratch, "Callback {d}", .{id}) catch "Callback") else if (!compact) appendSummary(buffer, &used, signal(id, &scratch));
        if (compact and id >= 253) {
            const space = std.fmt.bufPrint(buffer[used..], "    ", .{}) catch return buffer[0..used];
            used += space.len;
        }
    }
    return if (used == 0) (if (compact and value.custom != null and value.custom.? >= 253) "" else "No hold fields") else buffer[0..used];
}
pub fn action(value: ?p.Action, buffer: []u8) []const u8 {
    const a = value orelse return "Inherited";
    return switch (a) {
        .none => "None",
        .tap_only => |t| tap(t, buffer),
        .tap_hold => |t| tap(t.tap, buffer),
        .tap_with_autofire => |t| tap(t.tap, buffer),
        .hold_only => |h| if (h.layer_id) |id| std.fmt.bufPrint(buffer, "Layer {d}", .{id}) catch "?" else if (h.custom) |id| std.fmt.bufPrint(buffer, "Custom {d}", .{id}) catch "?" else "Modifiers",
    };
}
pub const HostKey = struct { code: u8, name: []const u8 = "", units: f32 = 1 };
test "layout captions consume text modifiers and preserve shortcuts holds and fallbacks" {
    var source: @import("label_fixture.zig").Fixture = .{};
    var buffer: [256]u8 = undefined;
    const left: p.Tap = .{ .key_press = .{ .tap_keycode = 38, .tap_modifiers = .{ .left_shift = true } } };
    try std.testing.expectEqualStrings("(", tapLabelWithLayout(&source, left, .{}, &buffer, true));
    try std.testing.expectEqualStrings("(", tapLabelWithLayout(&source, left, .{}, &buffer, false));
    const right: p.Tap = .{ .key_press = .{ .tap_keycode = 39, .tap_modifiers = .{ .right_shift = true } } };
    try std.testing.expectEqualStrings(")", tapLabelWithLayout(&source, right, .{}, &buffer, true));
    try std.testing.expectEqualStrings("{", tapLabelWithLayout(&source, .{ .key_press = .{ .tap_keycode = 47 } }, .{ .right_shift = true }, &buffer, true));
    const shortcut: p.Tap = .{ .key_press = .{ .tap_keycode = 29, .tap_modifiers = .{ .left_gui = true, .left_shift = true } } };
    try std.testing.expectEqualStrings(if (running_host == .macos) "⇧⌘Z" else if (running_host == .windows) "⇧+Win+Z" else "⇧+Super+Z", tapLabelWithLayout(&source, shortcut, .{}, &buffer, true));
    const doc: p.Document = .{ .schema_version = 1, .board_id = @splat(0), .profile_id = @splat(0), .physical_layout = "", .name = "", .key_ids = &.{}, .layers = &.{} };
    const action_value: p.Action = .{ .tap_hold = .{ .tap = left, .hold = .{ .hold_modifiers = .{ .left_ctrl = true } }, .tapping_term = .{ .ms = 200 } } };
    try std.testing.expectEqualStrings(if (running_host == .macos) "(\nHold ⌃" else "(\nHold Ctrl", keycapWithLayout(&source, action_value, doc, .{}, &buffer));
    try std.testing.expectEqualStrings("(", keycapWithLayout(&source, .{ .tap_with_autofire = .{ .tap = left, .initial_delay = .{ .ms = 200 }, .repeat_interval = .{ .ms = 50 } } }, doc, .{}, &buffer));
    try std.testing.expectEqualStrings(if (running_host == .macos) "⇧↩" else "⇧+↩", tapLabelWithLayout(&source, .{ .key_press = .{ .tap_keycode = 40, .tap_modifiers = .{ .left_shift = true } } }, .{}, &buffer, true));
    const Translation = struct {
        output: @import("zkeymap").TextResult,
        pub fn keyToText(self: *@This(), _: @import("zkeymap").KeyCodeFire) @import("zkeymap").TextResult {
            return self.output;
        }
    };
    var alternate = Translation{ .output = .{ .data = .{ 0xc3, 0xa4, 0, 0 }, .len = 2 } };
    try std.testing.expectEqualStrings("ä", tapLabelWithLayout(&alternate, .{ .key_press = .{ .tap_keycode = 52, .tap_modifiers = .{ .right_alt = true } } }, .{}, &buffer, true));
    try std.testing.expectEqualStrings("ä · Dead key", tapLabelWithLayout(&alternate, .{ .key_press = .{ .tap_keycode = 52, .dead = true } }, .{}, &buffer, true));
    alternate.output = .{};
    try std.testing.expectEqualStrings(if (running_host == .macos) "⇧9" else "⇧+9", tapLabelWithLayout(&alternate, left, .{}, &buffer, true));
    alternate.output = .{ .data = .{ 1, 0, 0, 0 }, .len = 1 };
    try std.testing.expectEqualStrings(if (running_host == .macos) "⇧9" else "⇧+9", tapLabelWithLayout(&alternate, left, .{}, &buffer, true));
}
test "compact keycaps preserve descriptive search labels" {
    var buffer: [256]u8 = undefined;
    for ([_]Host{ .macos, .windows, .linux }) |host| {
        for ([_]struct { code: u8, symbol: []const u8 }{
            .{ .code = 40, .symbol = "↩" },
            .{ .code = 41, .symbol = "⎋" },
            .{ .code = 42, .symbol = "⌫" },
            .{ .code = 43, .symbol = "⇥" },
            .{ .code = 44, .symbol = "␣" },
            .{ .code = 57, .symbol = "⇪" },
            .{ .code = 74, .symbol = "↖" },
            .{ .code = 75, .symbol = "⇞" },
            .{ .code = 76, .symbol = "⌦" },
            .{ .code = 77, .symbol = "↘" },
            .{ .code = 78, .symbol = "⇟" },
            .{ .code = 79, .symbol = "→" },
            .{ .code = 80, .symbol = "←" },
            .{ .code = 81, .symbol = "↓" },
            .{ .code = 82, .symbol = "↑" },
            .{ .code = 83, .symbol = "⇭" },
            .{ .code = 88, .symbol = "↩" },
        }) |entry| try std.testing.expectEqualStrings(entry.symbol, keycapUsage(host, entry.code, &buffer));
        try std.testing.expect(matchesUsage(host, 42, "Backspace"));
        try std.testing.expect(matchesUsage(host, 76, "Delete"));
    }
    try std.testing.expectEqualStrings("⌘", keycapModifiers(.macos, 0x88, &buffer));
    try std.testing.expectEqualStrings("⌃⇧⌥⌘", keycapModifiers(.macos, 0xff, &buffer));
    try std.testing.expectEqualStrings("🔊", tapLabel(.{ .media_key = .VolumeUp }, &buffer, true));
    try std.testing.expectEqualStrings("VolumeUp", tap(.{ .media_key = .VolumeUp }, &buffer));
    const chord: p.Tap = .{ .key_press = .{ .tap_keycode = 29, .tap_modifiers = .{ .left_gui = true } } };
    try std.testing.expectEqualStrings(if (running_host == .macos) "⌘Z" else if (running_host == .windows) "Win+Z" else "Super+Z", tapLabel(chord, &buffer, true));
    try std.testing.expect(containsIgnoreCase(tap(chord, &buffer), if (running_host == .macos) "Command" else if (running_host == .windows) "Win" else "Super"));
}
test "all basic keycodes have names and companion namespaces remain distinct" {
    var buffer: [256]u8 = undefined;
    inline for (@typeInfo(@import("zkeycodes").layouts.keycodes.kc.basic).@"enum".field_values) |value| {
        try std.testing.expect(!std.mem.startsWith(u8, usage(@intCast(value), &buffer), "HID "));
    }
    try std.testing.expectEqualStrings("Home", usage(74, &buffer));
    try std.testing.expectEqualStrings("Backspace", usage(42, &buffer));
    try std.testing.expectEqualStrings("Delete", usage(76, &buffer));
    try std.testing.expectEqualStrings("Print statistics", usage(253, &buffer));
    try std.testing.expectEqualStrings("Toggle companion logging", tap(.{ .custom = 253 }, &buffer));
    try std.testing.expectEqualStrings("Quit companion", tap(.{ .custom = 254 }, &buffer));
    try std.testing.expectEqualStrings("Show / hide companion", tap(.{ .custom = 255 }, &buffer));
    try std.testing.expect(containsIgnoreCase(tap(.{ .key_press = .{ .tap_keycode = 30, .tap_modifiers = .{ .left_shift = true } } }, &buffer), "Shift"));
}
pub const rows = [_][]const HostKey{
    &.{ .{ .code = 41 }, .{ .code = 58 }, .{ .code = 59 }, .{ .code = 60 }, .{ .code = 61 }, .{ .code = 62 }, .{ .code = 63 }, .{ .code = 64 }, .{ .code = 65 }, .{ .code = 66 }, .{ .code = 67 }, .{ .code = 68 }, .{ .code = 69 }, .{ .code = 76, .name = "Del" } },
    &.{ .{ .code = 53 }, .{ .code = 30 }, .{ .code = 31 }, .{ .code = 32 }, .{ .code = 33 }, .{ .code = 34 }, .{ .code = 35 }, .{ .code = 36 }, .{ .code = 37 }, .{ .code = 38 }, .{ .code = 39 }, .{ .code = 45 }, .{ .code = 46 }, .{ .code = 42, .units = 2 } },
    &.{ .{ .code = 43, .units = 1.5 }, .{ .code = 20 }, .{ .code = 26 }, .{ .code = 8 }, .{ .code = 21 }, .{ .code = 23 }, .{ .code = 28 }, .{ .code = 24 }, .{ .code = 12 }, .{ .code = 18 }, .{ .code = 19 }, .{ .code = 47 }, .{ .code = 48 }, .{ .code = 49, .units = 1.5 } },
    &.{ .{ .code = 57, .units = 1.75 }, .{ .code = 4 }, .{ .code = 22 }, .{ .code = 7 }, .{ .code = 9 }, .{ .code = 10 }, .{ .code = 11 }, .{ .code = 13 }, .{ .code = 14 }, .{ .code = 15 }, .{ .code = 51 }, .{ .code = 52 }, .{ .code = 40, .units = 2.25 } },
    &.{ .{ .code = 225, .name = "Shift", .units = 2.25 }, .{ .code = 29 }, .{ .code = 27 }, .{ .code = 6 }, .{ .code = 25 }, .{ .code = 5 }, .{ .code = 17 }, .{ .code = 16 }, .{ .code = 54 }, .{ .code = 55 }, .{ .code = 56 }, .{ .code = 229, .name = "Shift", .units = 1.75 }, .{ .code = 82 } },
    &.{ .{ .code = 224, .name = "Control", .units = 1.25 }, .{ .code = 226, .name = "Option", .units = 1.25 }, .{ .code = 227, .name = "Command", .units = 1.5 }, .{ .code = 44, .units = 5.5 }, .{ .code = 231, .name = "Command", .units = 1.5 }, .{ .code = 230, .name = "Option" }, .{ .code = 80 }, .{ .code = 81 }, .{ .code = 79 } },
};

test "host glyphs aliases and fallback preserve HID values" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("L ⌘ Command", hostUsage(.macos, 227, &buffer));
    try std.testing.expectEqualStrings("L Win", hostUsage(.windows, 227, &buffer));
    try std.testing.expectEqualStrings("R Super", hostUsage(.linux, 231, &buffer));
    for ([_][]const u8{ "⌘", "Command", "Cmd", "GUI", "227", "0xe3" }) |query| try std.testing.expect(matchesUsage(.macos, 227, query));
    try std.testing.expect(!matchesUsage(.macos, 4, "Cmd"));
}
test "compound tap and one shot summaries show every populated schema field" {
    var buffer: [1024]u8 = undefined;
    const summary = tap(.{ .key_press = .{ .tap_keycode = 4, .dead = true }, .media_key = .VolumeUp, .mouse_action = .WheelDown, .custom = 253, .one_shot = .{ .layer_id = 42, .hold_modifiers = .{ .left_gui = true }, .custom = 7 } }, &buffer);
    for ([_][]const u8{ "A", "Dead key", "VolumeUp", "WheelDown", "Toggle companion logging", "One-shot", "L42", "Callback 7" }) |part| try std.testing.expect(containsIgnoreCase(summary, part));
}
test "target aware catalog excludes unsupported hold fields and bounds output" {
    const catalog = @import("action_catalog.zig");
    const doc: p.Document = .{ .schema_version = 1, .board_id = @splat(0), .profile_id = @splat(0), .physical_layout = "fixture", .name = "Fixture", .key_ids = &.{}, .layers = &.{.{ .id = 42, .name = "Navigation", .actions = &.{} }} };
    var entries: [256]catalog.Entry = undefined;
    const count = catalog.search(doc, .hold, .all, "", &entries);
    try std.testing.expectEqual(@as(usize, 12), count);
    for (entries[0..count]) |entry| switch (entry) {
        .modifier, .layer, .callback, .signal => {},
        else => return error.UnsupportedHoldEntry,
    };
    try std.testing.expectEqual(@as(usize, 0), catalog.search(doc, .hold, .media, "", &entries));
    try std.testing.expectEqual(@as(usize, 2), catalog.search(doc, .tap, .modifier, "Cmd", &entries));
    try std.testing.expectEqual(@as(usize, 1), catalog.search(doc, .tap, .key, "252", &entries));
    try std.testing.expectEqual(@as(usize, 1), catalog.search(doc, .tap, .all, "", entries[0..1]));
}

test "empty and small caller buffers keep bounded label fallbacks" {
    const t = std.testing;
    var empty: [0]u8 = .{};
    try t.expectEqualStrings("?", usage(4, &empty));
    try t.expectEqualStrings("?", usage(30, &empty));
    try t.expectEqualStrings("Modifiers", hostModifierNames(.macos, 255, &empty));
    var small: [1]u8 = undefined;
    _ = tap(.{ .key_press = .{ .tap_keycode = 4, .tap_modifiers = .{ .left_gui = true } }, .media_key = .VolumeUp, .custom = 7 }, &small);
    const doc: p.Document = .{ .schema_version = 1, .board_id = @splat(0), .profile_id = @splat(0), .physical_layout = "", .name = "", .key_ids = &.{}, .layers = &.{.{ .id = 77, .name = "Named stable layer", .actions = &.{} }} };
    var buffer: [128]u8 = undefined;
    try t.expect(containsIgnoreCase(hold(.{ .layer_id = 77 }, doc, &buffer), "Named stable layer"));
    try t.expectEqualStrings("Inherited", keycap(null, doc, &buffer));
    try t.expectEqualStrings("None", keycap(.none, doc, &buffer));
}
