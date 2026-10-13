// SPDX-License-Identifier: GPL-2.0
//! Adapted from zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f.
//! UI-thread transport driver. Native HID is supplied only by the explicit live mode.
const std = @import("std");
const protocol = @import("device-protocol");
const companion = @import("companion-model");
pub const capture = @import("session_capture.zig");

pub const Candidate = struct {
    path: []const u8,
    vendor: u16 = 0xFAFA,
    product: u16 = 0x00F0,
    usage_page: u16 = 0xFF31,
    usage: u16 = 0x0074,
};
pub const Discovery = enum { selected, no_device, multiple_devices, path_not_found };
pub const Selection = union(Discovery) { selected: []const u8, no_device, multiple_devices, path_not_found };
pub fn select(candidates: []const Candidate, path: ?[]const u8) Selection {
    var selected: ?[]const u8 = null;
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.vendor != 0xFAFA or candidate.product != 0x00F0 or candidate.usage_page != 0xFF31 or candidate.usage != 0x0074) continue;
        if (path) |wanted| {
            if (std.mem.eql(u8, wanted, candidate.path)) return .{ .selected = candidate.path };
        } else {
            count += 1;
            selected = candidate.path;
        }
    }
    if (path != null) return .path_not_found;
    if (count == 0) return .no_device;
    if (count > 1) return .multiple_devices;
    return .{ .selected = selected.? };
}
pub fn normalize(bytes: []const u8) !protocol.Report {
    const frame = if (bytes.len == protocol.report_size) bytes else if (bytes.len == protocol.report_size + 1 and bytes[0] == 0) bytes[1..] else return error.InvalidNativeReport;
    return frame[0..protocol.report_size].*;
}
pub fn nativeWrite(report: protocol.Report) [33]u8 {
    var bytes: [33]u8 = undefined;
    bytes[0] = 0;
    @memcpy(bytes[1..], &report);
    return bytes;
}
/// A seed is obtained from OS randomness by the live entry point. Exhaustion is
/// explicit rather than wrapping into an earlier session's queued traffic.
pub const Nonces = struct {
    value: u32,
    remaining: u64 = std.math.maxInt(u32),
    pub fn next(self: *Nonces) !u32 {
        if (self.remaining == 0) return error.NonceExhausted;
        self.remaining -= 1;
        self.value +%= 1;
        if (self.value == 0) self.value = 1;
        return self.value;
    }
};
pub const Status = enum { searching, no_device, multiple_devices, path_not_found, connected, transport_error, nonce_exhausted };
pub const report_budget = 32;
pub const drain_budget_ms = 2;
pub const reconnect_ms = 1000;

pub const BootloaderAttemptStatus = enum { idle, connecting, requested, accepted, manual_recovery };
/// One bounded attempt per explicit Flash click. The independent session binds
/// the running profile, never the unflashed draft or overlay labels.
pub fn BootloaderAttempt(comptime Transport: type) type {
    return struct {
        const Self = @This();
        driver: Driver(Transport),
        status: BootloaderAttemptStatus = .idle,
        deadline: u64 = 0,
        request_sent: bool = false,
        pub fn init(transport: Transport, board: protocol.Identity, nonce: u32, path: ?[]const u8) !Self {
            var driver = try Driver(Transport).init(transport, board, nonce, path);
            driver.session = try companion.Session.initBootloader(board);
            return .{ .driver = driver };
        }
        pub fn active(self: *const Self) bool {
            return self.status == .connecting or self.status == .requested;
        }
        pub fn start(self: *Self, now: u64) void {
            if (self.status != .idle) return;
            self.status = .connecting;
            self.deadline = now +| 2500;
        }
        pub fn stop(self: *Self, status: BootloaderAttemptStatus, now: u64) void {
            self.driver.disconnect(now);
            self.status = status;
        }
        pub fn poll(self: *Self, now: u64) void {
            if (!self.active()) return;
            if (now >= self.deadline) return self.stop(.manual_recovery, now);
            self.driver.poll(now);
            if (!self.driver.connected or self.driver.session.phase == .incompatible) return self.stop(.manual_recovery, now);
            const session = &self.driver.session;
            if (session.bootloader_status == .accepted) return self.stop(.accepted, now);
            if (self.request_sent) {
                if (session.bootloader_status != .requested) self.stop(.manual_recovery, now);
                return;
            }
            if (session.bootloaderAvailable()) {
                self.request_sent = true;
                self.driver.enterBootloader(now) catch return self.stop(.manual_recovery, now);
                self.status = .requested;
            } else if (session.capabilities_queried and session.capability_request == 0) self.stop(.manual_recovery, now);
        }
        pub fn message(self: *const Self) []const u8 {
            return switch (self.status) {
                .idle => "",
                .connecting => "Checking HID bootloader support…",
                .requested => "Bootloader requested via HID…",
                .accepted => "Bootloader accepted · waiting for BOOTSEL drive…",
                .manual_recovery => "HID unavailable · enter BOOTSEL manually to continue flashing.",
            };
        }
    };
}

/// Transport methods: discover(?path)!Discovery, read(*[33]u8)!usize,
/// write([]const u8)!void, close(), and now()u64. discover opens only a uniquely
/// selected vendor collection. read is nonblocking; zero means no report.
pub fn Driver(comptime Transport: type) type {
    return struct {
        const Self = @This();
        transport: Transport,
        session: companion.Session,
        nonces: Nonces,
        path: ?[]const u8 = null,
        connected: bool = false,
        retry_at: u64 = 0,
        status: Status = .searching,
        transport_error: ?anyerror = null,
        signals: [2]protocol.SignalKind = undefined,
        signal_count: usize = 0,
        signal_events: [2]protocol.Signal = undefined,
        signal_event_count: usize = 0,
        key_events: [report_budget]protocol.KeyEvent = undefined,
        key_event_count: usize = 0,
        recording: ?*capture.Recorder = null,
        pub fn init(transport: Transport, expected: protocol.Identity, seed: u32, path: ?[]const u8) !Self {
            return .{ .transport = transport, .session = try companion.Session.init(expected), .nonces = .{ .value = seed }, .path = path };
        }
        pub fn disconnect(self: *Self, now: u64) void {
            if (self.recording) |recording| recording.add(.disconnect, now, &.{});
            if (self.connected) self.transport.close();
            self.connected = false;
            self.session.disconnect();
            self.retry_at = now +| reconnect_ms;
        }
        fn fail(self: *Self, err: anyerror, now: u64) void {
            self.transport_error = err;
            self.status = .transport_error;
            self.disconnect(now);
        }
        fn fresh(self: *Self, now: u64) ?u32 {
            return self.nonces.next() catch {
                self.disconnect(now);
                self.status = .nonce_exhausted;
                self.retry_at = std.math.maxInt(u64);
                return null;
            };
        }
        fn execute(self: *Self, actions: companion.Actions, now: u64) bool {
            if (self.signal_event_count + actions.signal_event_count > self.signal_events.len) {
                self.fail(error.SignalQueueOverflow, now);
                return false;
            }
            for (actions.signal_events[0..actions.signal_event_count]) |event| {
                self.signal_events[self.signal_event_count] = event;
                self.signal_event_count += 1;
            }
            for (actions.slice()) |action| switch (action) {
                .send => |packet| {
                    const report = protocol.encodePacket(packet, self.session.state.dimensions, .host_to_device) catch |err| {
                        self.fail(err, now);
                        return false;
                    };
                    const bytes = nativeWrite(report);
                    if (self.recording) |recording| recording.add(.send, now, &bytes);
                    self.transport.write(&bytes) catch |err| {
                        self.fail(err, now);
                        return false;
                    };
                },
                .signal => |signal| {
                    // Stop draining before another receive can exceed this UI queue.
                    self.signals[self.signal_count] = signal;
                    self.signal_count += 1;
                },
            };
            return true;
        }
        /// Explicit UI action only. Never retried after timeout or reconnect.
        pub fn enterBootloader(self: *Self, now: u64) !void {
            if (!self.connected or !self.session.bootloaderAvailable()) return error.BootloaderUnavailable;
            const actions = self.session.requestBootloader(now);
            if (self.recording) |recording| recording.add(.bootloader, now, &.{});
            if (!self.execute(actions, now)) return error.BootloaderTransportFailed;
        }
        pub fn poll(self: *Self, now: u64) void {
            self.signal_count = 0;
            self.signal_event_count = 0;
            self.key_event_count = 0;
            if (!self.connected) {
                if (now < self.retry_at) return;
                const found = self.transport.discover(self.path) catch |err| {
                    self.fail(err, now);
                    return;
                };
                self.retry_at = now +| reconnect_ms;
                switch (found) {
                    .selected => {
                        self.connected = true;
                        self.status = .connected;
                        self.transport_error = null;
                        const nonce = self.fresh(now) orelse return;
                        if (self.recording) |recording| recording.nonce(.connect, now, nonce);
                        const actions = self.session.connect(now, nonce) catch |err| {
                            self.fail(err, now);
                            return;
                        };
                        if (!self.execute(actions, now)) return;
                    },
                    .no_device => {
                        self.status = .no_device;
                        return;
                    },
                    .multiple_devices => {
                        self.status = .multiple_devices;
                        return;
                    },
                    .path_not_found => {
                        self.status = .path_not_found;
                        return;
                    },
                }
            }
            const start = self.transport.now();
            for (0..report_budget) |_| {
                if (self.signal_event_count != 0 or self.transport.now() -| start >= drain_budget_ms) break;
                var bytes: [33]u8 = undefined;
                const count = self.transport.read(&bytes) catch |err| {
                    self.fail(err, now);
                    return;
                };
                if (count == 0) break;
                // Invalid native lengths enter the same malformed receive recovery
                // path as invalid codec frames; no bytes are silently truncated.
                const report = normalize(bytes[0..@min(count, bytes.len)]) catch {
                    if (!self.receive(&.{}, now)) return;
                    continue;
                };
                if (count > bytes.len) {
                    if (!self.receive(&.{}, now)) return;
                    continue;
                }
                if (!self.receive(&report, now)) return;
            }
            const nonce = if (self.session.exhausted and now >= self.session.deadline) (self.fresh(now) orelse return) else 0;
            if (self.recording) |recording| recording.nonce(.tick, now, nonce);
            const actions = self.session.tick(now, nonce) catch |err| {
                self.fail(err, now);
                return;
            };
            _ = self.execute(actions, now);
            if (self.connected) {
                const query = self.session.queryCapabilities(now);
                if (query.count != 0) {
                    if (self.recording) |recording| recording.add(.capabilities, now, &.{});
                    _ = self.execute(query, now);
                }
            }
        }
        fn receive(self: *Self, bytes: []const u8, now: u64) bool {
            if (self.recording) |recording| recording.add(.receive, now, bytes);
            const previous_sequence = self.session.state.last_sequence;
            const actions = self.session.receive(bytes, now);
            if (self.session.phase == .live and self.session.state.last_sequence != previous_sequence) {
                if (protocol.decodePacket(bytes, self.session.state.dimensions, .device_to_host)) |packet| {
                    if (packet.payload == .key and self.key_event_count < self.key_events.len) {
                        self.key_events[self.key_event_count] = packet.payload.key;
                        self.key_event_count += 1;
                    }
                } else |_| {}
            }
            return self.execute(actions, now);
        }
    };
}

const Fake = struct {
    discovery: Discovery = .selected,
    discovery_count: usize = 0,
    frames: [64]protocol.Report = undefined,
    count: usize = 0,
    cursor: usize = 0,
    writes: [64][33]u8 = undefined,
    write_count: usize = 0,
    closed: bool = false,
    broken: bool = false,
    clock: u64 = 0,
    clock_step: u64 = 0,
    fn discover(self: *Fake, _: ?[]const u8) !Discovery {
        self.discovery_count += 1;
        self.closed = false;
        return self.discovery;
    }
    fn read(self: *Fake, bytes: *[33]u8) !usize {
        if (self.broken) return error.Unplugged;
        if (self.cursor == self.count) return 0;
        @memcpy(bytes[0..32], &self.frames[self.cursor]);
        self.cursor += 1;
        return 32;
    }
    fn write(self: *Fake, bytes: []const u8) !void {
        self.writes[self.write_count] = bytes[0..33].*;
        self.write_count += 1;
    }
    fn close(self: *Fake) void {
        self.closed = true;
    }
    fn now(self: *Fake) u64 {
        const result = self.clock;
        self.clock += self.clock_step;
        return result;
    }
    fn queue(self: *Fake, packet: protocol.Packet, dimensions: @import("layout-model").KeymapDimensions) !void {
        self.frames[self.count] = try protocol.encodePacket(packet, dimensions, .device_to_host);
        self.count += 1;
    }
};
fn fixture() protocol.Identity {
    return .{ .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 }, .profile_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 }, .digest = @splat(1), .dimensions = .{ .key_count = 4, .layer_count = 2 } };
}
fn attach(driver: *Driver(Fake), identity: protocol.Identity, held: bool) !void {
    driver.poll(0);
    for (try protocol.identityPackets(identity, driver.session.token, driver.session.request)) |p| try driver.transport.queue(p, identity.dimensions);
    driver.poll(1);
    var snapshot = protocol.Snapshot{ .pressed = @splat(0), .active_layers = 1, .highest_layer = 0, .modifiers = .{} };
    if (held) snapshot.pressed[0] = 1;
    for (try protocol.snapshotPackets(snapshot, identity.dimensions, driver.session.token, driver.session.request, 0)) |p| try driver.transport.queue(p, identity.dimensions);
    driver.poll(2);
}
test "vendor selection refuses ambiguous devices and requires exact path" {
    const candidates = [_]Candidate{ .{ .path = "keyboard", .usage_page = 1 }, .{ .path = "a" }, .{ .path = "b" } };
    try std.testing.expect(select(&candidates, null) == .multiple_devices);
    try std.testing.expectEqualStrings("b", select(&candidates, "b").selected);
    try std.testing.expect(select(&candidates, "keyboard") == .path_not_found);
    try std.testing.expect(select(&.{}, null) == .no_device);
}
test "native report ID boundaries are exact" {
    const report: protocol.Report = @splat(7);
    try std.testing.expectEqual(report, try normalize(&report));
    var native = nativeWrite(report);
    try std.testing.expectEqual(report, try normalize(&native));
    native[0] = 1;
    try std.testing.expectError(error.InvalidNativeReport, normalize(&native));
    try std.testing.expectError(error.InvalidNativeReport, normalize(report[0..31]));
}
test "fake attach held state unplug and reconnect use fresh identity session" {
    var driver = try Driver(Fake).init(.{}, fixture(), 100, null);
    try attach(&driver, fixture(), true);
    try std.testing.expectEqual(companion.Phase.live, driver.session.phase);
    try std.testing.expect(driver.session.state.pressed[0]);
    const old = driver.session.token;
    driver.transport.broken = true;
    driver.poll(3);
    try std.testing.expect(driver.session.stale and driver.transport.closed);
    driver.transport.broken = false;
    driver.poll(1003);
    try std.testing.expect(driver.session.token != old);
    try std.testing.expectEqual(companion.Phase.negotiating, driver.session.phase);
}
test "fake mismatch no device malformed recovery and bounded drain" {
    var driver = try Driver(Fake).init(.{ .discovery = .no_device }, fixture(), 10, null);
    driver.poll(0);
    try std.testing.expectEqual(Status.no_device, driver.status);
    try std.testing.expectEqual(@as(usize, 0), driver.transport.write_count);
    driver.transport.discovery = .selected;
    driver.poll(1000);
    var wrong = fixture();
    wrong.digest[0] = 2;
    for (try protocol.identityPackets(wrong, driver.session.token, driver.session.request)) |p| try driver.transport.queue(p, wrong.dimensions);
    driver.poll(1001);
    try std.testing.expectEqual(companion.Phase.incompatible, driver.session.phase);
    var good = try Driver(Fake).init(.{}, fixture(), 20, null);
    try attach(&good, fixture(), false);
    good.transport.frames[good.transport.count] = @splat(0);
    good.transport.count += 1;
    good.poll(3);
    try std.testing.expect(good.session.stale and good.session.last_error != null);
    var busy = try Driver(Fake).init(.{}, fixture(), 30, null);
    busy.transport.count = 64;
    for (&busy.transport.frames) |*frame| frame.* = @splat(0);
    busy.poll(0);
    try std.testing.expectEqual(@as(usize, report_budget), busy.transport.cursor);
}

test "fake gap recovery interrupted snapshot and successful reconnect" {
    var driver = try Driver(Fake).init(.{}, fixture(), 200, null);
    try attach(&driver, fixture(), true);
    try driver.transport.queue(.{ .session = driver.session.token, .sequence = 2, .payload = .{ .key = .{ .pressed = false, .key_index = 0, .layer = 0, .modifiers = .{} } } }, fixture().dimensions);
    driver.poll(3);
    try std.testing.expectEqual(companion.Phase.recovering, driver.session.phase);
    try std.testing.expect(driver.session.stale and driver.session.state.pressed[0]);
    driver.transport.broken = true;
    driver.poll(4);
    driver.transport.broken = false;
    driver.poll(1004);
    for (try protocol.identityPackets(fixture(), driver.session.token, driver.session.request)) |p| try driver.transport.queue(p, fixture().dimensions);
    driver.poll(1005);
    const snapshot = protocol.Snapshot{ .pressed = @splat(0), .active_layers = 1, .highest_layer = 0, .modifiers = .{} };
    for (try protocol.snapshotPackets(snapshot, fixture().dimensions, driver.session.token, driver.session.request, 0)) |p| try driver.transport.queue(p, fixture().dimensions);
    driver.poll(1006);
    try std.testing.expectEqual(companion.Phase.live, driver.session.phase);
    try std.testing.expect(!driver.session.stale and !driver.session.state.pressed[0]);
    const old_token = driver.session.token;
    driver.poll(2006);
    driver.poll(2506);
    driver.poll(3006);
    driver.poll(3506);
    driver.poll(4506);
    try std.testing.expectEqual(companion.Phase.negotiating, driver.session.phase);
    try std.testing.expect(driver.session.token != old_token);
}
test "fake ambiguous discovery and nonce exhaustion never reuse a token" {
    var driver = try Driver(Fake).init(.{ .discovery = .multiple_devices }, fixture(), 1, null);
    driver.poll(0);
    try std.testing.expectEqual(Status.multiple_devices, driver.status);
    try std.testing.expectEqual(@as(usize, 0), driver.transport.write_count);
    var nonces = Nonces{ .value = std.math.maxInt(u32), .remaining = 1 };
    try std.testing.expectEqual(@as(u32, 1), try nonces.next());
    try std.testing.expectError(error.NonceExhausted, nonces.next());
}

test "fake elapsed drain budget returns UI and capture replays final state" {
    var driver = try Driver(Fake).init(.{ .clock_step = 1 }, fixture(), 17, null);
    driver.transport.count = 64;
    for (&driver.transport.frames) |*frame| frame.* = @splat(0);
    driver.poll(0);
    try std.testing.expectEqual(@as(usize, 1), driver.transport.cursor);
    var recorder = try capture.Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    var recorded = try Driver(Fake).init(.{}, fixture(), 18, null);
    recorded.recording = &recorder;
    try attach(&recorded, fixture(), true);
    recorded.transport.broken = true;
    recorded.poll(3);
    const replayed = try capture.replay(recorder.encoded(), fixture());
    try std.testing.expectEqual(recorded.session.phase, replayed.phase);
    try std.testing.expectEqual(recorded.session.stale, replayed.stale);
    try std.testing.expectEqual(recorded.session.state.pressed, replayed.state.pressed);
}

test "live bootloader requires capability and one explicit action without retry" {
    var driver = try Driver(Fake).init(.{}, fixture(), 300, null);
    try std.testing.expectError(error.BootloaderUnavailable, driver.enterBootloader(0));
    try attach(&driver, fixture(), false);
    const query = try protocol.decodePacket(driver.transport.writes[driver.transport.write_count - 1][1..], fixture().dimensions, .host_to_device);
    try std.testing.expect(query.payload == .capabilities_request);
    try driver.transport.queue(.{ .session = driver.session.token, .request = query.request, .payload = .{ .capabilities = protocol.capability_bootloader } }, fixture().dimensions);
    driver.poll(3);
    const before = driver.transport.write_count;
    try std.testing.expect(driver.session.bootloaderAvailable());
    try driver.enterBootloader(4);
    try std.testing.expectEqual(before + 1, driver.transport.write_count);
    const request = try protocol.decodePacket(driver.transport.writes[before][1..], fixture().dimensions, .host_to_device);
    try std.testing.expect(request.payload == .enter_bootloader);
    try std.testing.expectError(error.BootloaderUnavailable, driver.enterBootloader(5));
    driver.poll(10000);
    for (driver.transport.writes[before + 1 .. driver.transport.write_count]) |bytes| {
        const packet = try protocol.decodePacket(bytes[1..], fixture().dimensions, .host_to_device);
        try std.testing.expect(packet.payload != .enter_bootloader);
    }
    try std.testing.expectEqual(companion.BootloaderStatus.timed_out, driver.session.bootloader_status);
}

test "explicit bootloader binds running profile while ordinary overlay rejects mismatch" {
    var running = fixture();
    running.profile_id = "running\x00".*;
    running.digest = @splat(9);
    running.dimensions.layer_count = 3;
    var attempt = try BootloaderAttempt(Fake).init(.{}, fixture(), 400, null);
    try std.testing.expectEqual(@as(usize, 0), attempt.driver.transport.write_count);
    attempt.start(0);
    try attach(&attempt.driver, running, false);
    try std.testing.expectEqual(companion.Phase.live, attempt.driver.session.phase);
    try std.testing.expectEqual(running, attempt.driver.session.expected);
    const query = attempt.driver.session.capability_request;
    try attempt.driver.transport.queue(.{ .session = attempt.driver.session.token, .request = query, .payload = .{ .capabilities = protocol.capability_bootloader } }, running.dimensions);
    attempt.poll(3);
    try std.testing.expectEqual(BootloaderAttemptStatus.requested, attempt.status);
    const request = attempt.driver.session.bootloader_request;
    try attempt.driver.transport.queue(.{ .session = attempt.driver.session.token, .request = request, .payload = .{ .bootloader_result = .accepted } }, running.dimensions);
    attempt.poll(4);
    try std.testing.expectEqual(BootloaderAttemptStatus.accepted, attempt.status);
    try std.testing.expect(attempt.driver.transport.closed);
    const count = attempt.driver.transport.write_count;
    attempt.poll(10000);
    attempt.start(10000);
    try std.testing.expectEqual(count, attempt.driver.transport.write_count);
    var boot_requests: usize = 0;
    for (attempt.driver.transport.writes[0..count]) |bytes| {
        const packet = try protocol.decodePacket(bytes[1..], running.dimensions, .host_to_device);
        if (packet.payload == .enter_bootloader) boot_requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), boot_requests);
    var overlay = try Driver(Fake).init(.{}, fixture(), 500, null);
    try attach(&overlay, running, false);
    try std.testing.expectEqual(companion.Phase.incompatible, overlay.session.phase);
}

test "optional bootloader falls back for absent ambiguous unsupported and wrong-board devices" {
    for ([_]Discovery{ .no_device, .multiple_devices, .path_not_found }) |discovery| {
        var attempt = try BootloaderAttempt(Fake).init(.{ .discovery = discovery }, fixture(), 600, null);
        attempt.poll(0); // Construction and idle polling cannot access hardware.
        try std.testing.expectEqual(@as(usize, 0), attempt.driver.transport.discovery_count);
        try std.testing.expectEqual(@as(usize, 0), attempt.driver.transport.write_count);
        attempt.start(0);
        attempt.poll(0);
        try std.testing.expectEqual(BootloaderAttemptStatus.manual_recovery, attempt.status);
        try std.testing.expect(!attempt.request_sent);
    }
    var wrong = fixture();
    wrong.board_id = "other\x00\x00\x00".*;
    var incompatible = try BootloaderAttempt(Fake).init(.{}, fixture(), 700, null);
    incompatible.start(0);
    try attach(&incompatible.driver, wrong, false);
    incompatible.poll(3);
    try std.testing.expectEqual(BootloaderAttemptStatus.manual_recovery, incompatible.status);
    try std.testing.expect(!incompatible.request_sent);
    for ([_]?u16{ null, 0 }) |capabilities| {
        var old = try BootloaderAttempt(Fake).init(.{}, fixture(), 800, null);
        old.start(0);
        try attach(&old.driver, fixture(), false);
        if (capabilities) |value| try old.driver.transport.queue(.{ .session = old.driver.session.token, .request = old.driver.session.capability_request, .payload = .{ .capabilities = value } }, fixture().dimensions);
        old.poll(if (capabilities == null) 503 else 3);
        try std.testing.expectEqual(BootloaderAttemptStatus.manual_recovery, old.status);
        try std.testing.expect(!old.request_sent);
    }
}

test "bootloader rejection stale acknowledgments and timeout never resend the command" {
    for ([_]?protocol.BootloaderResult{ .unsupported, .busy, .duplicate, null }) |reply| {
        var attempt = try BootloaderAttempt(Fake).init(.{}, fixture(), 900, null);
        attempt.start(0);
        try attach(&attempt.driver, fixture(), false);
        try attempt.driver.transport.queue(.{ .session = attempt.driver.session.token, .request = attempt.driver.session.capability_request, .payload = .{ .capabilities = protocol.capability_bootloader } }, fixture().dimensions);
        attempt.poll(3);
        const count = attempt.driver.transport.write_count;
        const request = attempt.driver.session.bootloader_request;
        try attempt.driver.transport.queue(.{ .session = attempt.driver.session.token + 1, .request = request, .payload = .{ .bootloader_result = .accepted } }, fixture().dimensions);
        try attempt.driver.transport.queue(.{ .session = attempt.driver.session.token, .request = request + 1, .payload = .{ .bootloader_result = .accepted } }, fixture().dimensions);
        attempt.poll(4);
        try std.testing.expectEqual(BootloaderAttemptStatus.requested, attempt.status);
        if (reply) |value| try attempt.driver.transport.queue(.{ .session = attempt.driver.session.token, .request = request, .payload = .{ .bootloader_result = value } }, fixture().dimensions);
        attempt.poll(if (reply == null) 503 else 5);
        try std.testing.expectEqual(BootloaderAttemptStatus.manual_recovery, attempt.status);
        attempt.poll(10000);
        try std.testing.expectEqual(count, attempt.driver.transport.write_count);
    }
}

test "routine snapshot refresh retains coherent held state without reconnecting" {
    var driver = try Driver(Fake).init(.{}, fixture(), 900, null);
    try attach(&driver, fixture(), true);
    const token = driver.session.token;
    for (0..4) |_| {
        const now = driver.session.refresh_at;
        driver.poll(now);
        try std.testing.expectEqual(companion.Phase.synchronizing, driver.session.phase);
        try std.testing.expect(driver.session.hasCoherentState());
        try std.testing.expect(driver.session.state.pressed[0]);
        try std.testing.expectEqual(token, driver.session.token);
        try std.testing.expect(!driver.transport.closed);
        const snapshot = protocol.Snapshot{ .pressed = .{1} ++ @as([15]u8, @splat(0)), .active_layers = 3, .highest_layer = 1, .modifiers = .{} };
        for (try protocol.snapshotPackets(snapshot, fixture().dimensions, token, driver.session.request, driver.session.state.last_sequence.?)) |packet| try driver.transport.queue(packet, fixture().dimensions);
        driver.poll(now + 1);
        try std.testing.expect(driver.session.hasCoherentState() and driver.session.state.pressed[0]);
        try std.testing.expectEqual(@as(u8, 1), driver.session.state.highest_layer);
    }
    driver.poll(driver.session.refresh_at);
    driver.poll(driver.session.deadline);
    try std.testing.expect(!driver.session.hasCoherentState());
    driver.disconnect(driver.session.deadline + 1);
    try std.testing.expect(!driver.session.hasCoherentState());
}
