const root = @import("../root.zig");
const hid = @import("../hid_to_platform.zig");

/// Opaque handle allocated by the C implementation in platform/linux.c.
/// Wraps xkb_context + xkb_keymap + xkb_state + cached modifier indices.
pub const LinuxKeyMap = opaque {
    extern fn linuxKeyMapInit() ?*LinuxKeyMap;
    pub fn init() *LinuxKeyMap {
        // Returns null if xkb_context_new fails (very unusual); fall back to
        // undefined so the opaque pointer is never dereferenced on failure.
        return linuxKeyMapInit() orelse undefined;
    }

    extern fn linuxKeyMapDeinit(*LinuxKeyMap) void;
    pub fn deinit(km: *LinuxKeyMap) void {
        linuxKeyMapDeinit(km);
    }

    extern fn linuxKeyMapRefresh(*LinuxKeyMap) void;
    pub fn refresh(km: *LinuxKeyMap) void {
        linuxKeyMapRefresh(km);
    }

    /// keycode is the xkbcommon keycode (evdev + 8).
    /// mods bit layout identical to MacOsKeyMap (see macos.zig).
    extern fn linuxKeyMapTranslate(*LinuxKeyMap, keycode: u32, mods: u8, is_dead: bool, buf: [*]u8, buf_len: usize) usize;

    pub fn keyToText(km: *LinuxKeyMap, input: root.KeyCodeFire) root.TextResult {
        const xkb_code = hid.hidToXkbKeycode(input.tap_keycode) orelse return .{};
        var result = root.TextResult{};
        result.len = @intCast(linuxKeyMapTranslate(
            km,
            xkb_code,
            hid.toPlatformMods(input.tap_modifiers),
            input.dead,
            &result.data,
            result.data.len,
        ));
        return result;
    }
};
