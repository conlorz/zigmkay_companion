// SPDX-License-Identifier: GPL-2.0
//! Adapted from zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f.
//! Explicit bounded timed reducer-input and host-control capture, version 1.
const std = @import("std");
const protocol = @import("device-protocol");
const companion = @import("companion-model");

test "full bounded capture survives file read and replay" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    for (0..max_records) |index| recorder.nonce(.tick, index, 0);
    try std.testing.expectEqual(max_bytes, recorder.encoded().len);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "full.bin", .data = recorder.encoded() });
    const bytes = try temp.dir.readFileAlloc(std.testing.io, "full.bin", std.testing.allocator, .limited(max_bytes + 1));
    defer std.testing.allocator.free(bytes);
    const identity = protocol.Identity{ .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 }, .profile_id = .{ 't', 0, 0, 0, 0, 0, 0, 0 }, .digest = @splat(1), .dimensions = .{ .key_count = 1, .layer_count = 1 } };
    const session = try replay(bytes, identity);
    try std.testing.expectEqual(companion.Phase.disconnected, session.phase);
}
pub const magic = "ZMKCAP01";
pub const record_size = 48;
pub const max_records = 4096;
pub const max_bytes = magic.len + record_size * max_records;
pub const Kind = enum(u8) { connect = 1, tick = 2, receive = 3, disconnect = 4, send = 5, capabilities = 6, bootloader = 7 };
pub const Recorder = struct {
    records: []u8,
    used: usize = 0,
    full: bool = false,
    pub fn init(allocator: std.mem.Allocator) !Recorder {
        return .{ .records = try allocator.alloc(u8, max_bytes) };
    }
    pub fn deinit(self: *Recorder, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }
    pub fn add(self: *Recorder, kind: Kind, now: u64, bytes: []const u8) void {
        if (self.used == 0) {
            @memcpy(self.records[0..magic.len], magic);
            self.used = magic.len;
        }
        if (bytes.len > 33 or self.used + record_size > self.records.len) {
            self.full = true;
            return;
        }
        const record = self.records[self.used..][0..record_size];
        @memset(record, 0);
        std.mem.writeInt(u64, record[0..8], now, .little);
        record[8] = @backingInt(kind);
        record[9] = @intCast(bytes.len);
        @memcpy(record[10..][0..bytes.len], bytes);
        self.used += record_size;
    }
    pub fn nonce(self: *Recorder, kind: Kind, now: u64, token: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, token, .little);
        self.add(kind, now, &bytes);
    }
    pub fn encoded(self: *const Recorder) []const u8 {
        return if (self.used == 0) magic else self.records[0..self.used];
    }
};
/// Replays elapsed times, connect tokens, malformed codec frames, disconnects,
/// and verifies every recorded host control against the same pure Session.
pub fn replay(bytes: []const u8, expected: protocol.Identity) !companion.Session {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic) or bytes.len > max_bytes or (bytes.len - magic.len) % record_size != 0) return error.InvalidCapture;
    var session = try companion.Session.init(expected);
    var previous: u64 = 0;
    var actions = companion.Actions{};
    var sent: usize = 0;
    var offset: usize = magic.len;
    while (offset < bytes.len) : (offset += record_size) {
        const record = bytes[offset..][0..record_size];
        const now = std.mem.readInt(u64, record[0..8], .little);
        if (now < previous or record[9] > 33) return error.InvalidCapture;
        previous = now;
        const data = record[10..][0..record[9]];
        for (record[10 + data.len ..]) |padding| if (padding != 0) return error.InvalidCapture;
        const kind = std.enums.fromInt(Kind, record[8]) orelse return error.InvalidCapture;
        switch (kind) {
            .send => {
                while (sent < actions.count and actions.items[sent] == .signal) sent += 1;
                if (sent >= actions.count or data.len != 33 or data[0] != 0) return error.ControlMismatch;
                const report = try protocol.encodePacket(actions.items[sent].send, session.state.dimensions, .host_to_device);
                if (!std.mem.eql(u8, &report, data[1..])) return error.ControlMismatch;
                sent += 1;
            },
            .disconnect => {
                if (data.len != 0) return error.InvalidCapture;
                session.disconnect();
                actions = .{};
                sent = 0;
            },
            else => {
                while (sent < actions.count and actions.items[sent] == .signal) sent += 1;
                if (sent != actions.count) return error.MissingControl;
                sent = 0;
                actions = switch (kind) {
                    .connect, .tick => blk: {
                        if (data.len != 4) return error.InvalidCapture;
                        const token = std.mem.readInt(u32, data[0..4], .little);
                        break :blk if (kind == .connect) try session.connect(now, token) else try session.tick(now, token);
                    },
                    .receive => session.receive(data, now),
                    .capabilities, .bootloader => blk: {
                        if (data.len != 0) return error.InvalidCapture;
                        break :blk if (kind == .capabilities) session.queryCapabilities(now) else session.requestBootloader(now);
                    },
                    else => unreachable,
                };
            },
        }
    }
    // Full capture can intentionally stop at a pending action; retain its stale
    // state, rather than asserting that a failed session became live.
    return session;
}
test "timed capture verifies retries disconnect and fresh reconnect" {
    const identity = protocol.Identity{ .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 }, .profile_id = .{ 't', 0, 0, 0, 0, 0, 0, 0 }, .digest = @splat(1), .dimensions = .{ .key_count = 1, .layer_count = 1 } };
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    var session = try companion.Session.init(identity);
    for ([_]u64{ 0, 500, 1000, 1500, 2500 }) |time| {
        const token: u32 = if (time == 0) 7 else if (time == 2500) 8 else 0;
        recorder.nonce(if (time == 0) .connect else .tick, time, token);
        const actions = if (time == 0) try session.connect(time, token) else try session.tick(time, token);
        for (actions.slice()) |action| if (action == .send) {
            const report = try protocol.encodePacket(action.send, identity.dimensions, .host_to_device);
            var native: [33]u8 = undefined;
            native[0] = 0;
            @memcpy(native[1..], &report);
            recorder.add(.send, time, &native);
        };
    }
    recorder.add(.disconnect, 2501, &.{});
    session.disconnect();
    const result = try replay(recorder.encoded(), identity);
    try std.testing.expectEqual(session.phase, result.phase);
    try std.testing.expect(result.stale);
    recorder.records[magic.len + record_size + 10 + 12] ^= 1;
    try std.testing.expectError(error.ControlMismatch, replay(recorder.encoded(), identity));
}
test "capture memory and file limits are explicit" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    for (0..max_records + 1) |n| recorder.add(.disconnect, n, &.{});
    try std.testing.expect(recorder.full);
    try std.testing.expectEqual(max_bytes, recorder.encoded().len);
}
