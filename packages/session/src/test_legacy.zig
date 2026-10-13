// SPDX-License-Identifier: GPL-2.0
// Retained from conlorz/zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f,
// tests/test_device_protocol.zig. Legacy reducer regressions.
const std = @import("std");
const model = @import("layout-model");
const protocol = @import("device-protocol");
const companion = @import("companion-model");
const dimensions = model.KeymapDimensions{ .key_count = 34, .layer_count = 4 };

fn key(sequence: u16, pressed: bool, index: model.KeyIndex, layer: model.LayerIndex) protocol.Message {
    return .{ .sequence = sequence, .event = .{ .key = .{ .pressed = pressed, .key_index = index, .layer = layer, .modifiers = .{} } } };
}

fn golden(prefix: [12]u8) protocol.Report {
    return prefix ++ @as([20]u8, @splat(0));
}

test "golden wire bytes are independent of memory layout" {
    const expected = golden(.{ 0xA7, 1, 3, 4, 0x34, 0x12, 0, 0, 1, 30, 2, 0x81 });
    var message = key(0x1234, true, 30, 2);
    message.event.key.modifiers = model.Modifiers.fromByte(0x81);
    try std.testing.expectEqual(expected, try protocol.encode(message, dimensions));
    try std.testing.expectEqualDeep(message, try protocol.decode(&expected, dimensions));
    const layer_message = protocol.Message{ .sequence = 3, .event = .{ .layers = .{ .active_layers = 3, .highest_layer = 1, .modifiers = .{} } } };
    const layer_bytes = golden(.{ 0xA7, 1, 1, 4, 3, 0, 0, 0, 3, 0, 1, 0 });
    try std.testing.expectEqual(layer_bytes, try protocol.encode(layer_message, dimensions));
    try std.testing.expectEqualDeep(layer_message, try protocol.decode(&layer_bytes, dimensions));
}

test "decoder rejects malformed framing and values before narrowing" {
    const valid = golden(.{ 0xA7, 1, 3, 4, 0, 0, 0, 0, 1, 0, 0, 0 });
    try std.testing.expectError(error.InvalidDimensions, protocol.decode(&valid, .{ .key_count = 0, .layer_count = 4 }));
    var long: [33]u8 = @splat(0);
    @memcpy(long[0..32], &valid);
    for (0..34) |len| {
        if (len != 32) try std.testing.expectError(error.InvalidLength, protocol.decode(long[0..len], dimensions));
    }
    const cases = .{
        .{ 0, 0, error.InvalidMagic },
        .{ 1, 2, error.UnsupportedVersion },
        .{ 2, 9, error.UnsupportedKind },
        .{ 3, 3, error.InvalidPayloadLength },
        .{ 6, 1, error.InvalidReserved },
        .{ 7, 1, error.InvalidReserved },
        .{ 8, 2, error.InvalidBoolean },
        .{ 9, 34, error.InvalidKeyIndex },
        .{ 9, 255, error.InvalidKeyIndex },
        .{ 10, 4, error.InvalidLayer },
        .{ 10, 255, error.InvalidLayer },
        .{ 31, 1, error.InvalidPadding },
    };
    inline for (cases) |case| {
        var bytes = valid;
        bytes[case[0]] = case[1];
        try std.testing.expectError(case[2], protocol.decode(&bytes, dimensions));
    }
}

test "active mask requires the base layer and correct highest layer" {
    var message = protocol.Message{ .sequence = 0, .event = .{ .layers = .{ .active_layers = 0, .highest_layer = 0, .modifiers = .{} } } };
    try std.testing.expectError(error.InvalidLayerMask, protocol.encode(message, dimensions));
    message.event.layers.active_layers = 0x11;
    try std.testing.expectError(error.InvalidLayerMask, protocol.encode(message, dimensions));
    message.event.layers.active_layers = 3;
    try std.testing.expectError(error.InvalidLayerMask, protocol.encode(message, dimensions));
    message.event.layers.highest_layer = 1;
    _ = try protocol.encode(message, dimensions);
    try std.testing.expectError(error.InvalidDimensions, protocol.encode(key(0, true, 0, 0), .{ .key_count = 0, .layer_count = 4 }));
    try std.testing.expectError(error.InvalidLayer, protocol.encode(key(0, true, 0, 4), dimensions));
    try std.testing.expectError(error.InvalidKeyIndex, protocol.encode(key(0, true, 34, 0), dimensions));
}

test "companion reducer tracks physical keys and layer state through sequence wrap" {
    var state = try companion.State.init(dimensions);
    try state.apply(key(65535, true, 30, 0));
    try std.testing.expect(state.pressed[30]);
    try state.apply(.{ .sequence = 0, .event = .{ .layers = .{ .active_layers = 3, .highest_layer = 1, .modifiers = .{ .left_ctrl = true } } } });
    try std.testing.expectEqual(@as(u16, 3), state.active_layers);
    try std.testing.expectEqual(@as(model.LayerIndex, 1), state.highest_layer);
    try std.testing.expect(state.modifiers.left_ctrl);
    try state.apply(key(1, false, 30, 1));
    try std.testing.expect(!state.pressed[30]);
}

test "sequence gaps and duplicates require resync without applying stale events" {
    for ([_]u16{ 10, 12 }) |next| {
        var state = try companion.State.init(dimensions);
        try state.apply(key(10, true, 0, 0));
        try std.testing.expectError(error.SequenceDiscontinuity, state.apply(key(next, false, 0, 0)));
        try std.testing.expect(state.pressed[0]);
        try std.testing.expect(state.needs_resync);
        try std.testing.expectError(error.ResyncRequired, state.apply(key(11, false, 0, 0)));
    }
    var state = try companion.State.init(dimensions);
    const before = state;
    try std.testing.expectError(error.InvalidLength, state.receive(&.{ 0xA7, 1 }));
    try std.testing.expectEqualDeep(before, state);
}

test "arbitrary reports either validate or fail without panicking" {
    const seed = golden(.{ 0xA7, 1, 3, 4, 0, 0, 0, 0, 1, 0, 0, 0 });
    for (0..32) |index| {
        for (0..256) |value| {
            var bytes = seed;
            bytes[index] = @intCast(value);
            const result = protocol.decode(&bytes, dimensions) catch continue;
            try protocol.validate(result, dimensions);
        }
    }
    var random = std.Random.DefaultPrng.init(0xA701);
    for (0..1000) |_| {
        var bytes: protocol.Report = undefined;
        random.random().bytes(&bytes);
        const result = protocol.decode(&bytes, dimensions) catch continue;
        try protocol.validate(result, dimensions);
    }
}
