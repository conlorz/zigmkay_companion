const root = @import("../root.zig");

/// No-op fallback for unsupported platforms.
/// Returns undefined pointer; all methods discard self without dereferencing.
pub const DummyKeyMap = opaque {
    pub fn init() *DummyKeyMap {
        return undefined;
    }

    pub fn deinit(km: *DummyKeyMap) void {
        _ = km;
    }

    pub fn refresh(km: *DummyKeyMap) void {
        _ = km;
    }

    pub fn keyToText(km: *DummyKeyMap, input: root.KeyCodeFire) root.TextResult {
        _ = km;
        _ = input;
        return .{};
    }
};
