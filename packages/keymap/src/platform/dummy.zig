const root = @import("../root.zig");

/// Unavailable fallback for unsupported platforms.
pub const DummyKeyMap = opaque {
    pub fn init() ?*DummyKeyMap {
        return null;
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
