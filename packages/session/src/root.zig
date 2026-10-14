// SPDX-License-Identifier: GPL-2.0
// Retained from conlorz/zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f,
// companion-model/src/root.zig. See repository LICENSE for GPL version 2.
const model = @import("layout-model");
const protocol = @import("device-protocol");

pub const State = struct {
    dimensions: model.KeymapDimensions,
    pressed: [128]bool = @splat(false),
    active_layers: u16 = 1,
    highest_layer: model.LayerIndex = 0,
    modifiers: model.Modifiers = .{},
    last_sequence: ?u16 = null,
    needs_resync: bool = false,

    pub fn init(dimensions: model.KeymapDimensions) protocol.ProtocolError!State {
        try protocol.validate(.{ .sequence = 0, .event = .{ .layers = .{ .active_layers = 1, .highest_layer = 0, .modifiers = .{} } } }, dimensions);
        return .{ .dimensions = dimensions };
    }

    pub fn apply(self: *State, message: protocol.Message) !void {
        try protocol.validate(message, self.dimensions);
        if (self.needs_resync) return error.ResyncRequired;
        if (self.last_sequence) |last| {
            if (message.sequence != last +% 1) {
                self.needs_resync = true;
                return error.SequenceDiscontinuity;
            }
        }
        switch (message.event) {
            .key => |key| {
                self.pressed[key.key_index] = key.pressed;
                self.modifiers = key.modifiers;
            },
            .layers => |layers| {
                self.active_layers = layers.active_layers;
                self.highest_layer = layers.highest_layer;
                self.modifiers = layers.modifiers;
            },
        }
        self.last_sequence = message.sequence;
    }

    pub fn receive(self: *State, bytes: []const u8) !void {
        try self.apply(try protocol.decode(bytes, self.dimensions));
    }
};

pub const Phase = enum { disconnected, negotiating, synchronizing, live, recovering, incompatible };
pub const BootloaderStatus = enum { idle, requested, accepted, rejected, timed_out, disconnected };

test "bootloader capability and explicit request are correlated and never retried" {
    const std = @import("std");
    const identity = protocol.Identity{ .board_id = "lk7\x00\x00\x00\x00\x00".*, .profile_id = "default\x00".*, .digest = @splat(0), .dimensions = .{ .key_count = 1, .layer_count = 1 } };
    var session = try Session.init(identity);
    try std.testing.expectEqual(@as(u8, 0), session.requestBootloader(0).count);
    session.phase = .live;
    session.stale = false;
    session.token = 42;
    session.refresh_at = 10_000;
    const query = session.queryCapabilities(0);
    try std.testing.expectEqual(@as(u8, 1), query.count);
    _ = session.apply(.{ .session = 41, .request = session.capability_request, .payload = .{ .capabilities = protocol.capability_bootloader } }, 1);
    try std.testing.expect(!session.bootloaderAvailable());
    _ = session.apply(.{ .session = 42, .request = session.capability_request, .payload = .{ .capabilities = protocol.capability_bootloader } }, 1);
    try std.testing.expect(session.bootloaderAvailable());
    try std.testing.expectEqual(@as(u8, 0), (try session.tick(2, 43)).count);
    try std.testing.expectEqual(@as(u8, 1), session.requestBootloader(3).count);
    try std.testing.expectEqual(@as(u8, 0), session.requestBootloader(4).count);
    _ = session.apply(.{ .session = 42, .request = session.bootloader_request + 1, .payload = .{ .bootloader_result = .accepted } }, 4);
    try std.testing.expectEqual(BootloaderStatus.requested, session.bootloader_status);
    try std.testing.expectEqual(@as(u8, 0), (try session.tick(3 + timeout_ms, 43)).count);
    try std.testing.expectEqual(BootloaderStatus.timed_out, session.bootloader_status);
    try std.testing.expectEqual(@as(u8, 0), session.requestBootloader(10_000).count);
    _ = session.apply(.{ .session = 42, .request = session.bootloader_request, .payload = .{ .bootloader_result = .accepted } }, 10_000);
    try std.testing.expectEqual(BootloaderStatus.timed_out, session.bootloader_status);
    session.disconnect();
    _ = try session.connect(20_000, 43);
    try std.testing.expect(!session.bootloaderAvailable());
    session.phase = .live;
    session.stale = false;
    session.refresh_at = 100_000;
    _ = session.queryCapabilities(20_001);
    _ = try session.tick(20_001 + timeout_ms, 44);
    try std.testing.expect(!session.bootloaderAvailable());
    try std.testing.expectEqual(@as(u8, 0), session.queryCapabilities(30_000).count);
    session.disconnect();
    _ = try session.connect(40_000, 44);
    session.phase = .live;
    session.stale = false;
    _ = session.queryCapabilities(40_001);
    _ = session.apply(.{ .session = 44, .request = session.capability_request, .payload = .{ .capabilities = protocol.capability_bootloader } }, 40_002);
    _ = session.requestBootloader(40_003);
    _ = session.apply(.{ .session = 44, .request = session.bootloader_request, .payload = .{ .bootloader_result = .accepted } }, 40_004);
    try std.testing.expectEqual(BootloaderStatus.accepted, session.bootloader_status);
    session.disconnect();
    try std.testing.expectEqual(BootloaderStatus.disconnected, session.bootloader_status);
}
pub const Action = union(enum) { send: protocol.Packet, signal: protocol.SignalKind };
pub const Actions = struct {
    /// Accepted, ordered edges for hold/release consumers. Legacy actions retain
    /// their press-only semantics for toggle and shutdown callers.
    signal_events: [2]protocol.Signal = undefined,
    signal_event_count: usize = 0,
    items: [2]Action = undefined,
    count: u2 = 0,
    pub fn slice(self: *const Actions) []const Action {
        return self.items[0..self.count];
    }
    fn add(self: *Actions, action: Action) void {
        self.items[self.count] = action;
        self.count += 1;
    }
};
pub const timeout_ms = 500;
pub const refresh_ms = 1000;
pub const max_attempts = 3;
pub const pending_capacity = 8;

/// Pure bounded live-session reducer. All times are monotonic milliseconds.
pub const Session = struct {
    expected: protocol.Identity,
    /// Only an explicit bootloader-only connection may bind the running profile.
    /// Overlay sessions must continue requiring the complete expected identity.
    bootloader_identity_discovery: bool = false,
    state: State,
    phase: Phase = .disconnected,
    stale: bool = true,
    token: u32 = 0,
    request_counter: u16 = 0,
    request: u16 = 0,
    attempts: u8 = 0,
    deadline: u64 = 0,
    refresh_at: u64 = 0,
    exhausted: bool = false,
    identity_body: [38]u8 = @splat(0),
    identity_seen: u3 = 0,
    snapshot_body: [20]u8 = @splat(0),
    snapshot_seen: u2 = 0,
    boundary: ?u16 = null,
    pending: [pending_capacity]protocol.Packet = undefined,
    pending_count: u4 = 0,
    expected_sequence: u16 = 0,
    last_error: ?protocol.ProtocolError = null,
    capabilities: u16 = 0,
    capabilities_queried: bool = false,
    capability_request: u16 = 0,
    capability_deadline: u64 = 0,
    bootloader_status: BootloaderStatus = .idle,
    bootloader_request: u16 = 0,
    bootloader_deadline: u64 = 0,

    /// Routine snapshot refreshes preserve the last verified coherent state.
    /// Initial synchronization, recovery and expired refreshes do not.
    pub fn hasCoherentState(self: *const Session) bool {
        return (self.phase == .live or self.phase == .synchronizing) and !self.stale and !self.state.needs_resync;
    }
    pub fn bootloaderAvailable(self: *const Session) bool {
        return self.phase == .live and !self.stale and self.capabilities & protocol.capability_bootloader != 0 and self.bootloader_status == .idle;
    }
    pub fn queryCapabilities(self: *Session, now: u64) Actions {
        if (self.phase != .live or self.stale or self.capabilities_queried) return .{};
        self.capabilities_queried = true;
        if (!self.allocateRequest(now)) return .{};
        self.capability_request = self.request;
        self.capability_deadline = now +| timeout_ms;
        var actions = Actions{};
        actions.add(.{ .send = .{ .session = self.token, .request = self.capability_request, .payload = .capabilities_request } });
        return actions;
    }
    /// Explicit caller action only. No retry is emitted by tick or reconnect.
    pub fn requestBootloader(self: *Session, now: u64) Actions {
        if (!self.bootloaderAvailable() or !self.allocateRequest(now)) return .{};
        self.bootloader_request = self.request;
        self.bootloader_status = .requested;
        self.bootloader_deadline = now +| timeout_ms;
        var actions = Actions{};
        actions.add(.{ .send = .{ .session = self.token, .request = self.bootloader_request, .payload = .enter_bootloader } });
        return actions;
    }

    pub fn init(expected: protocol.Identity) protocol.ProtocolError!Session {
        try protocol.validateIdentity(expected);
        return .{ .expected = expected, .state = try State.init(expected.dimensions) };
    }
    pub fn initBootloader(expected_board: protocol.Identity) protocol.ProtocolError!Session {
        var session = try init(expected_board);
        session.bootloader_identity_discovery = true;
        return session;
    }
    fn clearAssembly(self: *Session) void {
        self.identity_seen = 0;
        self.snapshot_seen = 0;
        self.boundary = null;
        self.pending_count = 0;
    }
    pub fn disconnect(self: *Session) void {
        if (self.bootloader_status == .requested or self.bootloader_status == .accepted) self.bootloader_status = .disconnected;
        self.capabilities = 0;
        self.capability_request = 0;
        self.phase = .disconnected;
        self.stale = true;
        self.state.needs_resync = true;
        self.token = 0;
        self.exhausted = false;
        self.clearAssembly();
    }
    fn hello(self: *Session, now: u64, nonce: u32) Actions {
        self.capabilities = 0;
        self.capabilities_queried = false;
        self.capability_request = 0;
        self.bootloader_status = .idle;
        self.bootloader_request = 0;
        self.token = nonce;
        self.request_counter = 1;
        self.request = 1;
        self.phase = .negotiating;
        self.stale = true;
        self.state.needs_resync = true;
        self.attempts = 1;
        self.deadline = now +| timeout_ms;
        self.exhausted = false;
        self.clearAssembly();
        var actions = Actions{};
        actions.add(.{ .send = .{ .session = 0, .request = self.request, .nonce = nonce, .payload = .hello } });
        return actions;
    }
    pub fn connect(self: *Session, now: u64, nonce: u32) protocol.ProtocolError!Actions {
        if (nonce == 0 or nonce == self.token) return error.InvalidSession;
        return self.hello(now, nonce);
    }
    fn allocateRequest(self: *Session, now: u64) bool {
        if (self.request_counter == 65535) {
            self.phase = .recovering;
            self.stale = true;
            self.state.needs_resync = true;
            self.exhausted = true;
            self.deadline = now;
            self.clearAssembly();
            return false;
        }
        self.request_counter += 1;
        self.request = self.request_counter;
        return true;
    }
    fn startSnapshot(self: *Session, now: u64, recovering: bool, retry: bool) Actions {
        var actions = Actions{};
        // A routine refresh keeps the last coherent state valid until its
        // deadline. Initial synchronization and fault recovery are stale.
        const refreshing = self.phase == .live and !recovering and !retry;
        self.stale = !refreshing;
        self.state.needs_resync = !refreshing;
        self.clearAssembly();
        if (!self.allocateRequest(now)) return actions;
        self.phase = if (recovering) .recovering else .synchronizing;
        if (!retry) self.attempts = 1;
        self.deadline = now +| timeout_ms;
        self.exhausted = false;
        actions.add(.{ .send = .{ .session = self.token, .request = self.request, .payload = .snapshot_request } });
        return actions;
    }
    fn failTransaction(self: *Session, now: u64) Actions {
        if (self.attempts >= max_attempts) {
            self.stale = true;
            self.state.needs_resync = true;
            self.phase = .recovering;
            self.exhausted = true;
            self.deadline = now +| refresh_ms;
            self.clearAssembly();
            return .{};
        }
        self.attempts += 1;
        if (self.phase == .negotiating) {
            var actions = Actions{};
            self.clearAssembly();
            if (!self.allocateRequest(now)) return actions;
            self.phase = .negotiating;
            self.deadline = now +| timeout_ms;
            actions.add(.{ .send = .{ .session = 0, .request = self.request, .nonce = self.token, .payload = .hello } });
            return actions;
        }
        return self.startSnapshot(now, true, true);
    }
    pub fn tick(self: *Session, now: u64, fresh_nonce: u32) protocol.ProtocolError!Actions {
        if (self.capability_request != 0 and now >= self.capability_deadline) self.capability_request = 0;
        if (self.bootloader_status == .requested and now >= self.bootloader_deadline) self.bootloader_status = .timed_out;
        if (self.bootloader_status == .requested or self.bootloader_status == .accepted) return .{};
        switch (self.phase) {
            .disconnected, .incompatible => return .{},
            .live => if (now >= self.refresh_at) return self.startSnapshot(now, false, false),
            .negotiating, .synchronizing, .recovering => {
                if (now < self.deadline) return .{};
                if (self.exhausted) {
                    if (fresh_nonce == 0 or fresh_nonce == self.token) return error.InvalidSession;
                    return self.hello(now, fresh_nonce);
                }
                return self.failTransaction(now);
            },
        }
        return .{};
    }
    fn malformed(self: *Session, now: u64, err: protocol.ProtocolError) Actions {
        self.last_error = err;
        if (err == error.UnsupportedVersion and self.phase != .disconnected) {
            @import("std").log.info("Keyboard handshake rejected: unsupported device protocol version", .{});
            self.phase = .incompatible;
            self.stale = true;
            self.state.needs_resync = true;
            self.clearAssembly();
            return .{};
        }
        return switch (self.phase) {
            .live => self.startSnapshot(now, true, false),
            .negotiating, .synchronizing, .recovering => if (self.exhausted) .{} else self.failTransaction(now),
            .disconnected, .incompatible => .{},
        };
    }
    /// Framing errors are recorded and trigger recovery actions, rather than escaping
    /// before an adapter has a chance to mark the displayed model stale.
    pub fn receive(self: *Session, bytes: []const u8, now: u64) Actions {
        const packet = protocol.decodePacket(bytes, self.expected.dimensions, .device_to_host) catch |err| return self.malformed(now, err);
        return self.apply(packet, now);
    }
    pub fn apply(self: *Session, packet: protocol.Packet, now: u64) Actions {
        protocol.validatePacket(packet, self.expected.dimensions, .device_to_host) catch |err| return self.malformed(now, err);
        if (self.phase == .disconnected or self.phase == .incompatible or self.exhausted or packet.session != self.token) return .{};
        switch (packet.payload) {
            .identity => |part| {
                if (self.phase != .negotiating or packet.request != self.request) return .{};
                const bit = @as(u3, 1) << @as(u2, @intCast(part.index));
                const length: usize = if (part.index == 2) 6 else 16;
                const destination = self.identity_body[@as(usize, part.index) * 16 ..][0..length];
                if (self.identity_seen & bit != 0) {
                    if (!@import("std").mem.eql(u8, destination, part.bytes[0..length])) return self.failTransaction(now);
                    return .{};
                }
                @memcpy(destination, part.bytes[0..length]);
                self.identity_seen |= bit;
                if (self.identity_seen != 7) return .{};
                const identity = protocol.decodeIdentityBody(self.identity_body, self.token) catch |err| return self.malformed(now, err);
                const board_matches = @import("std").mem.eql(u8, &identity.board_id, &self.expected.board_id) and identity.dimensions.key_count == self.expected.dimensions.key_count;
                if (!@import("std").meta.eql(identity, self.expected) and !(self.bootloader_identity_discovery and board_matches)) {
                    @import("std").log.info("Keyboard handshake rejected: saved project identity differs from running firmware. Expected board={s} profile={s} keys={d} layers={d} digest={s}; received board={s} profile={s} keys={d} layers={d} digest={s}", .{
                        @import("std").mem.sliceTo(&self.expected.board_id, 0),
                        @import("std").mem.sliceTo(&self.expected.profile_id, 0),
                        self.expected.dimensions.key_count,
                        self.expected.dimensions.layer_count,
                        @import("std").fmt.bytesToHex(self.expected.digest, .lower),
                        @import("std").mem.sliceTo(&identity.board_id, 0),
                        @import("std").mem.sliceTo(&identity.profile_id, 0),
                        identity.dimensions.key_count,
                        identity.dimensions.layer_count,
                        @import("std").fmt.bytesToHex(identity.digest, .lower),
                    });
                    self.phase = .incompatible;
                    self.stale = true;
                    self.state.needs_resync = true;
                    self.clearAssembly();
                    return .{};
                }
                if (self.bootloader_identity_discovery) {
                    self.expected = identity;
                    self.state = State.init(identity.dimensions) catch |err| return self.malformed(now, err);
                }
                return self.startSnapshot(now, false, false);
            },
            .snapshot => |part| {
                if ((self.phase != .synchronizing and self.phase != .recovering) or packet.request != self.request) return .{};
                if (self.boundary) |boundary| {
                    if (boundary != packet.sequence) return self.failTransaction(now);
                } else self.boundary = packet.sequence;
                const bit = @as(u2, 1) << @as(u1, @intCast(part.index));
                const destination = self.snapshot_body[@as(usize, part.index) * 10 ..][0..10];
                if (self.snapshot_seen & bit != 0) {
                    if (!@import("std").mem.eql(u8, destination, &part.bytes)) return self.failTransaction(now);
                    return .{};
                }
                @memcpy(destination, &part.bytes);
                self.snapshot_seen |= bit;
                if (self.snapshot_seen != 3) return .{};
                return self.commitSnapshot(now);
            },
            .key, .layers, .signal => {
                if (self.phase == .live) return self.liveDelta(packet, now);
                if (self.phase == .synchronizing or self.phase == .recovering) {
                    if (self.pending_count == pending_capacity) return self.failTransaction(now);
                    self.pending[self.pending_count] = packet;
                    self.pending_count += 1;
                }
                return .{};
            },
            .recovery => {
                if (self.phase == .negotiating) return .{};
                if (self.phase == .live) return self.startSnapshot(now, true, false);
                return self.failTransaction(now);
            },
            .capabilities => |value| {
                if (packet.request == self.capability_request and self.capability_request != 0 and now < self.capability_deadline) {
                    self.capabilities = value;
                    self.capability_request = 0;
                }
                return .{};
            },
            .bootloader_result => |result| {
                if (self.bootloader_status == .requested and packet.request == self.bootloader_request and now < self.bootloader_deadline) self.bootloader_status = if (result == .accepted) .accepted else .rejected;
                return .{};
            },
            .hello, .snapshot_request, .capabilities_request, .enter_bootloader => unreachable,
        }
    }
    fn applyDelta(candidate: *State, packet: protocol.Packet) void {
        switch (packet.payload) {
            .key => |key| {
                candidate.pressed[key.key_index] = key.pressed;
                candidate.modifiers = key.modifiers;
            },
            .layers => |layers| {
                candidate.active_layers = layers.active_layers;
                candidate.highest_layer = layers.highest_layer;
                candidate.modifiers = layers.modifiers;
            },
            .signal => {},
            else => unreachable,
        }
        candidate.last_sequence = packet.sequence;
    }
    fn commitSnapshot(self: *Session, now: u64) Actions {
        const snapshot = protocol.decodeSnapshotBody(self.snapshot_body, self.expected.dimensions) catch |err| return self.malformed(now, err);
        var candidate = State.init(self.expected.dimensions) catch unreachable;
        for (&candidate.pressed, 0..) |*pressed, index| pressed.* = snapshot.pressed[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) != 0;
        candidate.active_layers = snapshot.active_layers;
        candidate.highest_layer = snapshot.highest_layer;
        candidate.modifiers = snapshot.modifiers;
        var next = self.boundary.?;
        candidate.last_sequence = next -% 1;
        // A bounded Actions return cannot execute more than two pending signals.
        // Signal intent overflow invalidates the entire candidate atomically.
        var actions = Actions{};
        for (self.pending[0..self.pending_count]) |packet| {
            const difference = packet.sequence -% next;
            if (difference > 32768) continue;
            if (difference != 0) return self.failTransaction(now);
            applyDelta(&candidate, packet);
            next +%= 1;
            if (packet.payload == .signal) {
                if (actions.signal_event_count == actions.signal_events.len) return self.failTransaction(now);
                actions.signal_events[actions.signal_event_count] = packet.payload.signal;
                actions.signal_event_count += 1;
                if (packet.payload.signal.pressed) actions.add(.{ .signal = packet.payload.signal.kind });
            }
        }
        self.state = candidate;
        self.expected_sequence = next;
        self.phase = .live;
        self.stale = false;
        self.exhausted = false;
        self.refresh_at = now +| refresh_ms;
        self.clearAssembly();
        return actions;
    }
    fn liveDelta(self: *Session, packet: protocol.Packet, now: u64) Actions {
        const difference = packet.sequence -% self.expected_sequence;
        if (difference > 32768) return .{};
        if (difference != 0) return self.startSnapshot(now, true, false);
        applyDelta(&self.state, packet);
        self.expected_sequence +%= 1;
        var actions = Actions{};
        if (packet.payload == .signal) {
            actions.signal_events[0] = packet.payload.signal;
            actions.signal_event_count = 1;
        }
        if (packet.payload == .signal and packet.payload.signal.pressed) actions.add(.{ .signal = packet.payload.signal.kind });
        return actions;
    }
};
