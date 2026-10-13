//! Verified running keyboard presentation independent of native typing/drafts.
const std = @import("std");
const cache = @import("label_cache.zig");
const companion = @import("session");
const protocol = @import("device-protocol");
const model = @import("layout-model");
pub const Frame = struct {
    labels: ?*const cache.LabelCache = null,
    profile: [8]u8 = @splat(0),
    stale: bool = true,
    layer: usize = 0,
    active: u16 = 1,
    modifiers: model.Modifiers = .{},
    pressed: []const bool = &.{},
    pub fn content(self: Frame, index: usize) ?*const cache.CachedKeyContent {
        const labels = self.labels orelse return null;
        if (index >= labels.key_count) return null;
        return labels.lookupActiveChecked(self.layer, index, self.modifiers, self.active) catch null;
    }
};
pub const Presenter = struct {
    accepted_identity: ?protocol.Identity = null,
    pub fn invalidate(self: *Presenter) void {
        self.accepted_identity = null;
    }
    /// Labels are built from the immutable project matching `binding`. Missing
    /// or newly mismatched identity cannot promote a draft as a live layout.
    /// The caller owns labels, session and output until the draw has finished.
    pub fn select(self: *Presenter, labels: ?*const cache.LabelCache, binding: ?protocol.Identity, session: ?*const companion.Session, output: []bool) !Frame {
        const verified = labels orelse return .{};
        const identity = binding orelse return .{};
        const current = session orelse return .{};
        try protocol.validateIdentity(identity);
        if (!std.meta.eql(identity, current.expected) or !std.meta.eql(identity.dimensions, current.state.dimensions) or verified.key_count != identity.dimensions.key_count or verified.layer_count != identity.dimensions.layer_count or current.bootloader_identity_discovery) {
            self.invalidate();
            return .{};
        }
        const coherent = current.token != 0 and current.hasCoherentState();
        if (output.len < verified.key_count) return error.LiveFrameStorageTooSmall;
        if (coherent) try protocol.validate(.{ .sequence = 0, .event = .{ .layers = .{ .active_layers = current.state.active_layers, .highest_layer = current.state.highest_layer, .modifiers = current.state.modifiers } } }, identity.dimensions);
        if (coherent) self.accepted_identity = identity else {
            const accepted = self.accepted_identity orelse return .{};
            if (!std.meta.eql(accepted, identity)) {
                self.invalidate();
                return .{};
            }
        }
        const pressed = output[0..verified.key_count];
        @memset(pressed, false);
        var frame = Frame{ .labels = verified, .profile = identity.profile_id, .pressed = pressed };
        if (coherent) {
            frame.stale = false;
            frame.layer = current.state.highest_layer;
            frame.active = current.state.active_layers;
            frame.modifiers = current.state.modifiers;
            @memcpy(pressed, current.state.pressed[0..verified.key_count]);
        }
        return frame;
    }
};

/// Keyboard requests never make an unverified draft visible. Hold state is
/// transient and must be cleared on loss of coherent session state.
pub const Visibility = struct {
    mode: enum { toggle, hold, tap_hold } = .toggle,
    latched: bool = false,
    held: bool = false,
    down: bool = false,
    pressed_at: u64 = 0,
    pub const hold_ms = 250;
    pub fn update(self: *Visibility, frame: Frame, signals: []const protocol.Signal) bool {
        return self.updateAt(frame, signals, 0);
    }
    pub fn updateAt(self: *Visibility, frame: Frame, signals: []const protocol.Signal, now: u64) bool {
        if (frame.labels == null or frame.stale) {
            self.held = false;
            self.down = false;
            self.latched = false;
            return false;
        }
        for (signals) |signal| {
            if (signal.kind != .overlay_toggle) continue;
            if (self.mode == .tap_hold) {
                if (signal.pressed and !self.down) {
                    self.pressed_at = now;
                    self.held = true;
                } else if (!signal.pressed and self.down) {
                    if (now -| self.pressed_at < hold_ms) self.latched = !self.latched;
                    self.held = false;
                }
                self.down = signal.pressed;
                continue;
            }
            if (self.mode == .hold) self.held = signal.pressed else if (signal.pressed and !self.down) self.latched = !self.latched;
            self.down = signal.pressed;
        }
        return switch (self.mode) {
            .hold => self.held,
            .toggle => self.latched,
            .tap_hold => self.held or self.latched,
        };
    }
};

/// HID report arrival does not wake SDL's event wait. Live mode must poll well
/// below the gesture threshold, even when all application windows are hidden.
pub fn waitBudget(live_enabled: bool, busy: bool, resident_idle: bool) u32 {
    return if (live_enabled or busy) 10_000 else if (resident_idle) 500_000 else 250_000;
}

test "live SDL wait budget preserves quick-tap timing with visible and hidden windows" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 10_000), waitBudget(true, false, false));
    try t.expectEqual(@as(u32, 10_000), waitBudget(true, false, true));
    try t.expectEqual(@as(u32, 250_000), waitBudget(false, false, false));
    try t.expectEqual(@as(u32, 500_000), waitBudget(false, false, true));
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const frame = Frame{ .labels = &labels, .stale = false };
    const press = [_]protocol.Signal{.{ .kind = .overlay_toggle, .pressed = true }};
    const release = [_]protocol.Signal{.{ .kind = .overlay_toggle, .pressed = false }};
    for ([_]bool{ false, true }) |hidden| {
        var visibility = Visibility{ .mode = .tap_hold };
        const poll_ms = waitBudget(true, false, hidden) / 1000;
        // Approximate report acceptance at the next polling boundary. Each
        // physical tap lasts 50 ms, and must toggle in both directions.
        _ = visibility.updateAt(frame, &press, 100);
        try t.expect(visibility.updateAt(frame, &release, 150 + poll_ms));
        _ = visibility.updateAt(frame, &press, 300);
        try t.expect(!visibility.updateAt(frame, &release, 350 + poll_ms));
        _ = visibility.updateAt(frame, &press, 500);
        try t.expect(!visibility.updateAt(frame, &release, 1000 + poll_ms));
    }
}

test "quick taps latch while long holds restore preceding visibility" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const frame = Frame{ .labels = &labels, .stale = false };
    const press = [_]protocol.Signal{.{ .kind = .overlay_toggle, .pressed = true }};
    const release = [_]protocol.Signal{.{ .kind = .overlay_toggle, .pressed = false }};
    var visibility = Visibility{ .mode = .tap_hold };
    try t.expect(visibility.updateAt(frame, &press, 100));
    try t.expect(visibility.updateAt(frame, &release, 200));
    try t.expect(visibility.updateAt(frame, &.{}, 1000));
    try t.expect(visibility.updateAt(frame, &press, 1100));
    try t.expect(visibility.updateAt(frame, &release, 1500));
    try t.expect(visibility.updateAt(frame, &press, 1600));
    try t.expect(!visibility.updateAt(frame, &release, 1700));
    try t.expect(visibility.updateAt(frame, &press, 1800));
    try t.expect(visibility.updateAt(frame, &press, 1900));
    try t.expect(!visibility.updateAt(frame, &release, 2200));
    try t.expect(visibility.updateAt(frame, &press, 2300));
    try t.expect(!visibility.updateAt(.{}, &.{}, 2400));
    try t.expect(!visibility.updateAt(frame, &release, 2450));
}

test "verified visibility preserves releases and clears holds on stale or mismatched identity" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const frame = Frame{ .labels = &labels, .stale = false };
    const press = [_]protocol.Signal{.{ .kind = .overlay_toggle, .pressed = true }};
    const release = [_]protocol.Signal{.{ .kind = .overlay_toggle, .pressed = false }};
    var hold = Visibility{ .mode = .hold };
    try t.expect(hold.update(frame, &press));
    try t.expect(!hold.update(frame, &release));
    try t.expect(hold.update(frame, &press));
    try t.expect(!hold.update(.{}, &.{}));
    try t.expect(!hold.update(frame, &.{}));
    var toggle = Visibility{};
    try t.expect(toggle.update(frame, &press));
    try t.expect(toggle.update(frame, &press));
    try t.expect(toggle.update(frame, &release));
    try t.expect(!toggle.update(frame, &press));
    try t.expect(!toggle.update(.{}, &press));
}
test "live frame waits for coherent identity and clears stale held state" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 4, 34);
    defer labels.deinit();
    const identity = protocol.Identity{ .board_id = "lk7\x00\x00\x00\x00\x00".*, .profile_id = "eurmac\x00\x00".*, .digest = @splat(1), .dimensions = .{ .key_count = 34, .layer_count = 4 } };
    var session = try companion.Session.init(identity);
    var presenter = Presenter{};
    var storage: [34]bool = @splat(true);
    try t.expect((try presenter.select(&labels, identity, &session, &storage)).labels == null);
    // Coherent phase is normally established by the protocol reducer. These
    // presentation fixtures inject its accepted result without device access.
    session.phase = .live;
    session.stale = false;
    session.token = 7;
    session.state.pressed[30] = true;
    session.state.highest_layer = 2;
    session.state.active_layers = 5;
    session.state.modifiers.left_shift = true;
    var frame = try presenter.select(&labels, identity, &session, &storage);
    try t.expect(frame.labels != null and !frame.stale and frame.pressed[30]);
    try t.expectEqual(@as(usize, 2), frame.layer);
    try t.expectEqual(@as(u16, 5), frame.active);
    session.disconnect();
    frame = try presenter.select(&labels, identity, &session, &storage);
    try t.expect(frame.labels != null and frame.stale);
    try t.expectEqual(@as(usize, 0), frame.layer);
    try t.expectEqual(@as(u16, 1), frame.active);
    try t.expectEqual(@as(u8, 0), frame.modifiers.toByte());
    for (frame.pressed) |down| try t.expect(!down);
    var changed = identity;
    changed.digest[0] ^= 1;
    try t.expect((try presenter.select(&labels, changed, &session, &storage)).labels == null);
    try t.expect(presenter.accepted_identity == null);
}
test "wire identity and complete snapshot promote the verified presentation atomically" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const identity = protocol.Identity{ .board_id = "fixture\x00".*, .profile_id = "profile\x00".*, .digest = @splat(2), .dimensions = .{ .key_count = 3, .layer_count = 2 } };
    var session = try companion.Session.init(identity);
    var presenter = Presenter{};
    var output: [3]bool = @splat(false);
    _ = try session.connect(0, 42);
    for (try protocol.identityPackets(identity, 42, session.request)) |packet| {
        const report = try protocol.encodePacket(packet, identity.dimensions, .device_to_host);
        _ = session.receive(&report, 1);
        try t.expect((try presenter.select(&labels, identity, &session, &output)).labels == null);
    }
    var snapshot = protocol.Snapshot{ .active_layers = 3, .highest_layer = 1 };
    snapshot.pressed[0] = 4;
    const packets = try protocol.snapshotPackets(snapshot, identity.dimensions, 42, session.request, 9);
    const first = try protocol.encodePacket(packets[0], identity.dimensions, .device_to_host);
    _ = session.receive(&first, 2);
    try t.expect((try presenter.select(&labels, identity, &session, &output)).labels == null);
    const second = try protocol.encodePacket(packets[1], identity.dimensions, .device_to_host);
    _ = session.receive(&second, 3);
    const frame = try presenter.select(&labels, identity, &session, &output);
    try t.expect(frame.labels != null and !frame.stale and frame.pressed[2]);
    try t.expectEqual(@as(usize, 1), frame.layer);
    try t.expect(frame.content(2) != null and frame.content(3) == null);
    var visibility = Visibility{ .mode = .hold };
    const press = session.apply(.{ .session = 42, .sequence = 9, .payload = .{ .signal = .{ .kind = .overlay_toggle, .pressed = true } } }, 3);
    try t.expectEqual(@as(usize, 1), press.signal_event_count);
    try t.expect(visibility.update(frame, press.signal_events[0..press.signal_event_count]));
    const release = session.apply(.{ .session = 42, .sequence = 10, .payload = .{ .signal = .{ .kind = .overlay_toggle, .pressed = false } } }, 3);
    try t.expectEqual(@as(usize, 1), release.signal_event_count);
    try t.expectEqual(@as(u2, 0), release.count);
    try t.expect(!visibility.update(frame, release.signal_events[0..release.signal_event_count]));
    _ = session.apply(.{ .session = 42, .sequence = 13, .payload = .{ .key = .{ .key_index = 2, .pressed = false, .layer = 1, .modifiers = .{} } } }, 4);
    const stale = try presenter.select(&labels, identity, &session, &output);
    try t.expect(stale.stale and !stale.pressed[2]);
}
