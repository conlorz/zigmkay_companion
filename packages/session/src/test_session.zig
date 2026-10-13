// SPDX-License-Identifier: GPL-2.0
// Retained from conlorz/zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f,
// tests/test_protocol_session.zig. Literal fixtures and reducer regressions.
const std = @import("std");

// Independent literals: they precede codec implementation and define the wire.
pub const hello: [32]u8 = .{ 0xA7, 2, 10, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0x44, 0x33, 0x22, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
// Board "lk7", profile "danish", digest bytes 00..0f, dimensions 34/4.
pub const identity_parts: [3][32]u8 = .{
    .{ 0xA7, 2, 11, 18, 0x44, 0x33, 0x22, 0x11, 0, 0, 1, 0, 0, 3, 0x44, 0x33, 0x22, 0x11, 'l', 'k', '7', 0, 0, 0, 0, 0, 'd', 'a', 'n', 'i', 0, 0 },
    .{ 0xA7, 2, 11, 18, 0x44, 0x33, 0x22, 0x11, 0, 0, 1, 0, 1, 3, 's', 'h', 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 0 },
    .{ 0xA7, 2, 11, 8, 0x44, 0x33, 0x22, 0x11, 0, 0, 1, 0, 2, 3, 12, 13, 14, 15, 34, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
pub const snapshot_request: [32]u8 = .{ 0xA7, 2, 12, 0, 0x44, 0x33, 0x22, 0x11, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
// Keys 0 and 30 held, arrows active, persistent left control. Next delta=65535.
pub const snapshot_parts: [2][32]u8 = .{
    .{ 0xA7, 2, 13, 12, 0x44, 0x33, 0x22, 0x11, 0xFF, 0xFF, 2, 0, 0, 2, 1, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0xA7, 2, 13, 12, 0x44, 0x33, 0x22, 0x11, 0xFF, 0xFF, 2, 0, 1, 2, 0, 0, 0, 0, 0, 0, 3, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
};
pub const release: [32]u8 = .{ 0xA7, 2, 14, 4, 0x44, 0x33, 0x22, 0x11, 0xFF, 0xFF, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub const overflow: [32]u8 = .{ 0xA7, 2, 16, 1, 0x44, 0x33, 0x22, 0x11, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

test "v2 independent fixtures define complete report boundaries and zero padding" {
    const reports = .{hello} ++ identity_parts ++ .{snapshot_request} ++ snapshot_parts ++ .{ release, overflow };
    for (reports) |report| {
        try std.testing.expectEqual(@as(u8, 0xA7), report[0]);
        try std.testing.expectEqual(@as(u8, 2), report[1]);
        try std.testing.expect(report[3] <= 20);
        for (report[12 + report[3] ..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

const protocol = @import("device-protocol");
const model = @import("layout-model");
const dimensions = model.KeymapDimensions{ .key_count = 34, .layer_count = 4 };
const fixture_identity = protocol.Identity{ .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 }, .profile_id = .{ 'd', 'a', 'n', 'i', 's', 'h', 0, 0 }, .digest = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, .dimensions = dimensions };

test "v2 codec matches independent identity snapshot recovery and control literals" {
    const hello_packet = protocol.Packet{ .session = 0, .request = 1, .nonce = 0x11223344, .payload = .hello };
    try std.testing.expectEqual(hello, try protocol.encodePacket(hello_packet, dimensions, .host_to_device));
    const identities = try protocol.identityPackets(fixture_identity, 0x11223344, 1);
    for (identities, identity_parts) |packet, literal| {
        try std.testing.expectEqual(literal, try protocol.encodePacket(packet, dimensions, .device_to_host));
        try std.testing.expectEqualDeep(packet, try protocol.decodePacket(&literal, dimensions, .device_to_host));
    }
    var snapshot = protocol.Snapshot{ .active_layers = 3, .highest_layer = 1, .modifiers = .{ .left_ctrl = true } };
    snapshot.pressed[0] = 1;
    snapshot.pressed[3] = 0x40;
    const snapshots = try protocol.snapshotPackets(snapshot, dimensions, 0x11223344, 2, 65535);
    for (snapshots, snapshot_parts) |packet, literal| {
        try std.testing.expectEqual(literal, try protocol.encodePacket(packet, dimensions, .device_to_host));
        try std.testing.expectEqualDeep(packet, try protocol.decodePacket(&literal, dimensions, .device_to_host));
    }
    try std.testing.expectEqualDeep(snapshot, try protocol.decodeSnapshotBody(try protocol.encodeSnapshotBody(snapshot, dimensions), dimensions));
    for ([_]protocol.Report{ snapshot_request, release, overflow }) |literal| {
        const direction: protocol.Direction = if (literal[2] == 12) .host_to_device else .device_to_host;
        try std.testing.expectEqual(literal, try protocol.encodePacket(try protocol.decodePacket(&literal, dimensions, direction), dimensions, direction));
    }
    try std.testing.expectEqualDeep(fixture_identity, try protocol.decodeIdentityBody(try protocol.identityBody(fixture_identity, 0x11223344), 0x11223344));
}

test "v2 invalid framing dimensions transaction fields and fragments reject" {
    try std.testing.expectError(error.InvalidDimensions, protocol.decodePacket(&hello, .{ .key_count = 0, .layer_count = 4 }, .host_to_device));
    try std.testing.expectError(error.WrongDirection, protocol.decodePacket(&hello, dimensions, .device_to_host));
    try std.testing.expectError(error.InvalidLength, protocol.decodePacket(hello[0..31], dimensions, .host_to_device));
    const cases = .{ .{ 0, 0, error.InvalidMagic }, .{ 1, 1, error.UnsupportedVersion }, .{ 2, 0, error.UnsupportedKind }, .{ 3, 3, error.InvalidPayloadLength }, .{ 4, 1, error.InvalidSession }, .{ 8, 1, error.InvalidReserved }, .{ 10, 0, error.InvalidRequest }, .{ 31, 1, error.InvalidPadding } };
    inline for (cases) |case| {
        var bad = hello;
        bad[case[0]] = case[1];
        try std.testing.expectError(case[2], protocol.decodePacket(&bad, dimensions, .host_to_device));
    }
    for ([_]u8{ 0, 4, 255 }) |count| {
        var bad = identity_parts[0];
        bad[13] = count;
        try std.testing.expectError(error.InvalidPart, protocol.decodePacket(&bad, dimensions, .device_to_host));
    }
    var bad = snapshot_parts[0];
    bad[12] = 2;
    try std.testing.expectError(error.InvalidPart, protocol.decodePacket(&bad, dimensions, .device_to_host));
    var body = try protocol.encodeSnapshotBody(.{}, dimensions);
    body[15] = 0x80;
    try std.testing.expectError(error.InvalidKeyIndex, protocol.decodeSnapshotBody(body, dimensions));
    body = try protocol.encodeSnapshotBody(.{}, dimensions);
    body[16] = 0;
    try std.testing.expectError(error.InvalidLayerMask, protocol.decodeSnapshotBody(body, dimensions));
    var identity_body = try protocol.identityBody(fixture_identity, 0x11223344);
    identity_body[5] = 0;
    identity_body[6] = 'a';
    try std.testing.expectError(error.InvalidIdentity, protocol.decodeIdentityBody(identity_body, 0x11223344));
    identity_body = try protocol.identityBody(fixture_identity, 0x11223344);
    identity_body[36] = 128;
    try std.testing.expectError(error.InvalidDimensions, protocol.decodeIdentityBody(identity_body, 0x11223344));
}

const base_keys = [_]?model.KeyDef{.{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } }};
const base_input = protocol.IdentityInput{ .board_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 }, .profile_id = .{ 'b', 'a', 's', 'e', 0, 0, 0, 0 }, .dimensions = .{ .key_count = 1, .layer_count = 1 }, .keys = &base_keys, .sides = &.{.L}, .combos = &.{}, .encoders = &.{}, .callbacks = &.{} };

test "canonical profile digest uses independent semantic bytes" {
    const literal = "zigmkay-profile-v1\x00" ++ "test\x00\x00\x00\x00" ++ "base\x00\x00\x00\x00" ++ [_]u8{ 1, 1, 1, 0, 1, 1, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(literal, &digest, .{});
    const identity = try protocol.computeIdentity(base_input);
    try std.testing.expectEqualSlices(u8, digest[0..16], &identity.digest);
    try std.testing.expectEqual([_]u8{ 0x11, 0xb5, 0x59, 0x62, 0xb8, 0x78, 0x55, 0xf9, 0x41, 0xde, 0x48, 0x43, 0x92, 0xa9, 0x66, 0x50 }, identity.digest);
}

test "identity changes cover optional actions sides combos encoders and callback declarations" {
    const original = (try protocol.computeIdentity(base_input)).digest;
    const variants = [_]?model.KeyDef{ null, .none, .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4, .dead = true } } }, .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4, .tap_modifiers = .{ .left_shift = true } } } }, .{ .tap_only = .{ .one_shot = .{ .hold_modifiers = .{ .left_ctrl = true } } } }, .{ .tap_only = .{ .media_key = .VolumeUp } }, .{ .tap_only = .{ .mouse_action = .WheelLeft } }, .{ .hold_only = .{ .hold_layer = 0 } }, .{ .tap_hold = .{ .tap = .{}, .hold = .{}, .tapping_term = .{ .ms = 150 }, .retro_tapping = true } }, .{ .tap_with_autofire = .{ .tap = .{}, .initial_delay = .{ .ms = 10 }, .repeat_interval = .{ .ms = 20 } } } };
    for (variants) |variant| {
        var input = base_input;
        input.keys = &.{variant};
        try std.testing.expect(!std.mem.eql(u8, &original, &(try protocol.computeIdentity(input)).digest));
    }
    var input = base_input;
    input.sides = &.{.R};
    try std.testing.expect(!std.mem.eql(u8, &original, &(try protocol.computeIdentity(input)).digest));
    input = base_input;
    input.encoders = &.{.{ .tap = .{ .custom = 1 } }};
    input.callbacks = &.{.{ .id = 1, .behavior = "combined-tap-hold-v1" }};
    const callback_v1 = try protocol.computeIdentity(input);
    input.callbacks = &.{.{ .id = 1, .behavior = "combined-tap-hold-v2" }};
    try std.testing.expect(!std.mem.eql(u8, &callback_v1.digest, &(try protocol.computeIdentity(input)).digest));
    input.callbacks = &.{};
    try std.testing.expectError(error.InvalidCallback, protocol.computeIdentity(input));
    input = base_input;
    input.keys = &.{.{ .hold_only = .{ .hold_layer = 1 } }};
    try std.testing.expectError(error.InvalidLayer, protocol.computeIdentity(input));
    input = base_input;
    input.callbacks = &.{ .{ .id = 1, .behavior = "a" }, .{ .id = 1, .behavior = "b" } };
    try std.testing.expectError(error.InvalidCallback, protocol.computeIdentity(input));
    input = base_input;
    input.dimensions.key_count = 2;
    input.keys = &.{ base_keys[0], base_keys[0] };
    input.sides = &.{ .L, .L };
    const no_combo = try protocol.computeIdentity(input);
    input.combos = &.{.{ .key_indexes = .{ 0, 1 }, .timeout = .{ .ms = 40 }, .layer = 0, .key_def = .none }};
    try std.testing.expect(!std.mem.eql(u8, &no_combo.digest, &(try protocol.computeIdentity(input)).digest));
}

test "v2 arbitrary mutations either fail or reencode exactly" {
    for ([_]protocol.Report{ hello, identity_parts[0], identity_parts[2], snapshot_parts[0], release, overflow }) |seed| {
        const direction: protocol.Direction = if (seed[2] == 10) .host_to_device else .device_to_host;
        for (0..32) |index| for (0..256) |value| {
            var report = seed;
            report[index] = @intCast(value);
            const decoded = protocol.decodePacket(&report, dimensions, direction) catch continue;
            try std.testing.expectEqual(report, try protocol.encodePacket(decoded, dimensions, direction));
        };
    }
}

const companion = @import("companion-model");
fn startSession() !companion.Session {
    var session = try companion.Session.init(fixture_identity);
    const actions = try session.connect(0, 0x11223344);
    try std.testing.expectEqual(hello, try protocol.encodePacket(actions.items[0].send, dimensions, .host_to_device));
    for (identity_parts, 0..) |part, index| {
        const result = session.receive(&part, index + 1);
        if (index != 2) try std.testing.expectEqual(@as(u2, 0), result.count) else try std.testing.expectEqual(snapshot_request, try protocol.encodePacket(result.items[0].send, dimensions, .host_to_device));
    }
    return session;
}
fn liveSession() !companion.Session {
    var session = try startSession();
    for (snapshot_parts) |part| _ = session.receive(&part, 5);
    try std.testing.expectEqual(companion.Phase.live, session.phase);
    try std.testing.expect(!session.stale);
    return session;
}
fn delta(sequence: u16, pressed: bool, index: model.KeyIndex) protocol.Packet {
    return .{ .session = 0x11223344, .sequence = sequence, .payload = .{ .key = .{ .pressed = pressed, .key_index = index, .layer = 1, .modifiers = .{} } } };
}
fn respondSnapshot(session: *companion.Session, snapshot: protocol.Snapshot, boundary: u16, now: u64) !companion.Actions {
    const packets = try protocol.snapshotPackets(snapshot, dimensions, session.token, session.request, boundary);
    _ = session.apply(packets[0], now);
    return session.apply(packets[1], now);
}

test "session initializes already held keys then wraps sequence and ignores duplicates" {
    var session = try liveSession();
    try std.testing.expect(session.state.pressed[0] and session.state.pressed[30]);
    try std.testing.expectEqual(@as(u16, 3), session.state.active_layers);
    try std.testing.expect(session.state.modifiers.left_ctrl);
    _ = session.receive(&release, 6);
    try std.testing.expect(!session.state.pressed[0]);
    const after_release = session.state;
    _ = session.receive(&release, 7);
    try std.testing.expectEqualDeep(after_release, session.state);
    _ = session.apply(delta(0, false, 30), 8);
    try std.testing.expectEqual(@as(u16, 0), session.state.last_sequence.?);
    try std.testing.expect(!session.state.pressed[30]);
}

test "gap overflow and malformed frames recover with stale atomic replacement" {
    for (0..3) |mode| {
        var session = try liveSession();
        const before = session.state;
        const actions = switch (mode) {
            0 => session.apply(delta(2, false, 0), 6),
            1 => session.receive(&overflow, 6),
            else => session.receive(&.{0xA7}, 6),
        };
        try std.testing.expectEqual(@as(u2, 1), actions.count);
        try std.testing.expectEqual(companion.Phase.recovering, session.phase);
        try std.testing.expect(session.stale and session.state.needs_resync);
        try std.testing.expectEqual(before.pressed, session.state.pressed);
        const parts = try protocol.snapshotPackets(.{}, dimensions, session.token, session.request, 10);
        _ = session.apply(parts[0], 7);
        try std.testing.expect(session.state.pressed[0]);
        _ = session.apply(parts[1], 8);
        try std.testing.expectEqual(companion.Phase.live, session.phase);
        try std.testing.expect(!session.state.pressed[0] and !session.state.pressed[30]);
        _ = session.apply(delta(10, true, 1), 9);
        try std.testing.expect(session.state.pressed[1]);
    }
}

test "fragment ordering duplicates conflicts and stale request or session traffic" {
    var session = try startSession();
    _ = session.receive(&snapshot_parts[1], 5);
    _ = session.receive(&snapshot_parts[1], 6);
    try std.testing.expect(session.stale);
    _ = session.receive(&snapshot_parts[0], 7);
    try std.testing.expectEqual(companion.Phase.live, session.phase);
    var stale = delta(65535, false, 0);
    stale.session = 0x1234;
    _ = session.apply(stale, 8);
    try std.testing.expect(session.state.pressed[0]);
    _ = session.apply(delta(1, false, 0), 9);
    const request = session.request;
    _ = session.receive(&snapshot_parts[0], 10);
    try std.testing.expectEqual(@as(u2, 0), session.snapshot_seen);
    var parts = try protocol.snapshotPackets(.{}, dimensions, session.token, request, 2);
    _ = session.apply(parts[0], 11);
    parts[0].payload.snapshot.bytes[0] = 1;
    _ = session.apply(parts[0], 12);
    try std.testing.expect(session.request != request);
    try std.testing.expect(session.stale and session.state.pressed[0]);
    var mismatched = try protocol.snapshotPackets(.{}, dimensions, session.token, session.request, 2);
    _ = session.apply(mismatched[0], 13);
    mismatched[1].sequence = 3;
    _ = session.apply(mismatched[1], 14);
    try std.testing.expectEqual(@as(u2, 0), session.snapshot_seen);
}

test "pending deltas filter pre-cut events commit contiguous suffix and bound storage" {
    var session = try startSession();
    _ = session.apply(delta(65534, false, 0), 5); // Included in captured state.
    _ = session.apply(delta(65535, false, 0), 6);
    _ = session.apply(delta(65535, false, 0), 7); // Duplicate pending delta.
    _ = session.apply(delta(0, false, 30), 8);
    for (snapshot_parts) |part| _ = session.receive(&part, 9);
    try std.testing.expectEqual(companion.Phase.live, session.phase);
    try std.testing.expect(!session.state.pressed[0] and !session.state.pressed[30]);
    try std.testing.expectEqual(@as(u16, 1), session.expected_sequence);
    session = try startSession();
    for (0..9) |index| _ = session.apply(delta(@intCast(index), true, 0), 5 + index);
    try std.testing.expectEqual(companion.Phase.recovering, session.phase);
    try std.testing.expectEqual(@as(u4, 0), session.pending_count);
    try std.testing.expect(session.stale);
    session = try startSession();
    _ = session.apply(delta(0, true, 1), 5); // Boundary 65535 missing.
    for (snapshot_parts) |part| _ = session.receive(&part, 6);
    try std.testing.expect(session.stale and !session.state.pressed[1]);
}

test "timeouts bounded retries interrupted recovery fresh session and request exhaustion" {
    var session = try startSession();
    try std.testing.expectEqual(@as(u2, 0), (try session.tick(502, 0x22334455)).count);
    try std.testing.expectEqual(@as(u2, 1), (try session.tick(503, 0x22334455)).count);
    _ = try session.tick(1003, 0x22334455);
    try std.testing.expectEqual(@as(u2, 0), (try session.tick(1503, 0x22334455)).count);
    try std.testing.expect(session.exhausted and session.stale);
    _ = session.receive(&snapshot_parts[0], 1505);
    try std.testing.expectEqual(@as(u2, 0), session.snapshot_seen);
    try std.testing.expectEqual(@as(u2, 0), (try session.tick(2502, 0x22334455)).count);
    const hello_again = try session.tick(2503, 0x22334455);
    try std.testing.expectEqual(@as(u32, 0x22334455), hello_again.items[0].send.nonce);
    _ = session.receive(&identity_parts[0], 2505);
    try std.testing.expectEqual(@as(u3, 0), session.identity_seen);
    session.disconnect();
    try std.testing.expectEqual(companion.Phase.disconnected, session.phase);
    _ = session.receive(&identity_parts[1], 2506);
    try std.testing.expectEqual(@as(u3, 0), session.identity_seen);
    _ = try session.connect(2507, 0x33445566);
    session = try liveSession();
    session.request_counter = 65535;
    _ = session.apply(delta(2, false, 0), 10);
    try std.testing.expect(session.exhausted and session.stale);
    const fresh = try session.tick(10, 0x55667788);
    try std.testing.expectEqual(@as(u32, 0x55667788), fresh.items[0].send.nonce);
}

test "identity mismatch and invalid snapshot never partly mutate visible state" {
    var session = try companion.Session.init(fixture_identity);
    _ = try session.connect(0, 0x11223344);
    var parts = identity_parts;
    parts[1][20] ^= 1;
    for (parts) |part| _ = session.receive(&part, 1);
    try std.testing.expectEqual(companion.Phase.incompatible, session.phase);
    try std.testing.expect(session.stale);
    session = try startSession();
    var snapshots = snapshot_parts;
    snapshots[1][20] = 0;
    for (snapshots) |part| _ = session.receive(&part, 5);
    try std.testing.expect(session.stale and !session.state.pressed[0]);
    try std.testing.expectEqual(error.InvalidLayerMask, session.last_error.?);
}

test "signals share sequence and return bounded intents only for presses" {
    var session = try liveSession();
    const signal = protocol.Packet{ .session = session.token, .sequence = 65535, .payload = .{ .signal = .{ .kind = .overlay_toggle, .pressed = true } } };
    const actions = session.apply(signal, 6);
    try std.testing.expectEqual(@as(u2, 1), actions.count);
    try std.testing.expectEqual(protocol.SignalKind.overlay_toggle, actions.items[0].signal);
    try std.testing.expectEqual(@as(u2, 0), session.apply(signal, 7).count);
    var released = signal;
    released.sequence = 0;
    released.payload.signal.pressed = false;
    try std.testing.expectEqual(@as(u2, 0), session.apply(released, 8).count);
    session = try startSession();
    for (0..3) |index| {
        var pending_signal = signal;
        pending_signal.sequence = 65535 +% @as(u16, @intCast(index));
        _ = session.apply(pending_signal, 5);
    }
    for (snapshot_parts) |part| _ = session.receive(&part, 6);
    try std.testing.expect(session.stale and !session.state.pressed[0]);
}

test "repeated malformed recovery is bounded and version mismatch is incompatible" {
    var session = try liveSession();
    _ = session.receive(&.{0}, 10);
    _ = session.receive(&.{0}, 11);
    _ = session.receive(&.{0}, 12);
    try std.testing.expectEqual(@as(u2, 0), session.receive(&.{0}, 13).count);
    try std.testing.expect(session.exhausted and session.stale and session.state.pressed[0]);
    session = try liveSession();
    var unsupported = release;
    unsupported[1] = 1;
    _ = session.receive(&unsupported, 14);
    try std.testing.expectEqual(companion.Phase.incompatible, session.phase);
    try std.testing.expectEqual(error.UnsupportedVersion, session.last_error.?);
}

test "session static memory budget" {
    try std.testing.expect(@sizeOf(companion.Session) <= 2048);
    try std.testing.expect(@sizeOf(companion.Actions) <= 128);
}

test "routine refresh preserves validated display until completion or timeout" {
    var session = try liveSession();
    const previous = session.state;
    const now = session.refresh_at;
    const request = session.tick(now, 0) catch unreachable;
    try std.testing.expectEqual(@as(u2, 1), request.count);
    try std.testing.expectEqual(companion.Phase.synchronizing, session.phase);
    try std.testing.expect(!session.stale and !session.state.needs_resync);
    try std.testing.expectEqualDeep(previous, session.state);
    const snapshot = protocol.Snapshot{ .active_layers = 1, .highest_layer = 0 };
    const parts = try protocol.snapshotPackets(snapshot, dimensions, session.token, session.request, session.expected_sequence);
    _ = session.apply(parts[0], now + 10);
    try std.testing.expect(!session.stale);
    _ = session.apply(parts[1], now + 25);
    try std.testing.expectEqual(companion.Phase.live, session.phase);
    try std.testing.expect(!session.stale);
    _ = try session.tick(session.refresh_at, 0);
    _ = try session.tick(session.deadline, 0);
    try std.testing.expect(session.stale and session.state.needs_resync);
    try std.testing.expectEqual(companion.Phase.recovering, session.phase);
}
