// SPDX-License-Identifier: GPL-2.0
//! Explicit, bounded hardware acceptance. No arguments/help/offline never touch HID.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");
const protocol = @import("device-protocol");
const live = @import("live-adapter");
const native = @import("native-hid");
const capture = live.capture;

const Manifest = struct { identity: protocol.Identity };
const help =
    \\usb-acceptance offline <candidate.zon>
    \\usb-acceptance replay <candidate.zon> <capture-file>
    \\usb-acceptance discover
    \\usb-acceptance live <candidate.zon> <seconds: 2..120> <capture-file> [HID-path]
    \\usb-acceptance recovery <candidate.zon> <capture-file> [HID-path]
    \\usb-acceptance reconnect <candidate.zon> <capture-file> [HID-path]
    \\usb-acceptance bootloader <candidate.zon> <capture-file> [HID-path]
    \\Only discover/live/recovery/reconnect/bootloader access HID. No command flashes.
    \\Bootloader requests reset once, only after a matching coherent session.
    \\Live requires a coherent matching identity/snapshot and records key events.
    \\Recovery performs malformed-protocol recovery, a 3-second read pause and a
    \\local close/reopen. Physical reconnect and both USB routes need separate evidence.
    \\Reconnect allows one physical disconnect and waits up to 120 seconds for a
    \\fresh matching session, then observes ten seconds before finishing.
    \\
;

fn identity(init: std.process.Init, path: []const u8) !protocol.Identity {
    const allocator = init.arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16384));
    const terminated = try allocator.dupeSentinel(u8, bytes, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = try std.zon.parse.fromSlice(Manifest, .{ .gpa = allocator, .arena = allocator, .source = terminated, .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    try protocol.validateIdentity(manifest.identity);
    return manifest.identity;
}

fn describe(expected: protocol.Identity) void {
    std.debug.print("Expected board={s} profile={s} keys={d} layers={d} digest={s}\n", .{
        std.mem.trimEnd(u8, &expected.board_id, &.{0}), std.mem.trimEnd(u8, &expected.profile_id, &.{0}), expected.dimensions.key_count,
        expected.dimensions.layer_count,                std.fmt.bytesToHex(expected.digest, .lower),
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--help"))) {
        std.debug.print("{s}", .{help});
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "offline")) {
        describe(try identity(init, args[2]));
        std.debug.print("Offline identity validated; Zig {s}; SDL {d}. No device accessed.\n", .{ builtin.zig_version_string, sdl.SDL_GetVersion() });
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "replay")) {
        const expected = try identity(init, args[2]);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], allocator, .limited(capture.max_bytes));
        const session = try capture.replay(bytes, expected);
        std.debug.print("Offline replay passed; final phase={s}.\n", .{@tagName(session.phase)});
        const token = std.mem.readInt(u32, session.identity_body[0..4], .little);
        if (protocol.decodeIdentityBody(session.identity_body, token)) |observed| {
            std.debug.print("Last assembled device identity:\n", .{});
            describe(observed);
        } else |_| {}
        return;
    }
    const discover = args.len == 2 and std.mem.eql(u8, args[1], "discover");
    const recovery = (args.len == 4 or args.len == 5) and std.mem.eql(u8, args[1], "recovery");
    const bootloader = (args.len == 4 or args.len == 5) and std.mem.eql(u8, args[1], "bootloader");
    const reconnect = (args.len == 4 or args.len == 5) and std.mem.eql(u8, args[1], "reconnect");
    const observe = (args.len == 5 or args.len == 6) and std.mem.eql(u8, args[1], "live");
    if (!discover and !recovery and !observe and !bootloader and !reconnect) return error.Usage;
    if (builtin.os.tag != .macos) return error.NativePlatformNotAccepted;
    const expected: ?protocol.Identity = if (discover) null else try identity(init, args[2]);
    const seconds: u32 = if (observe) try std.fmt.parseInt(u32, args[3], 10) else if (bootloader) 5 else if (reconnect) 120 else 20;
    if (seconds < 2 or seconds > 120) return error.DurationOutOfRange;
    const output: ?[]const u8 = if (discover) null else args[if (recovery or bootloader or reconnect) 3 else 4];
    // Refuse to overwrite prior evidence; check destination before device access.
    var file: ?std.Io.File = if (output) |path| try std.Io.Dir.cwd().createFile(init.io, path, .{ .exclusive = true }) else null;
    defer if (file) |f| f.close(init.io);
    const Native = native.Native(sdl);
    defer _ = sdl.SDL_hid_exit();
    var transport: Native = .{ .io = init.io };
    defer transport.close();
    if (sdl.SDL_hid_init() != 0) return error.HidInitializationFailed;
    std.debug.print("Explicit HID operation; macOS SDL {d}; compiler {s}\n", .{ sdl.SDL_GetVersion(), builtin.zig_version_string });
    if (discover) {
        const result = try transport.discover(null);
        std.debug.print("Discovery={s}; vendor collection paths={d}\n", .{ @tagName(result), transport.path_count });
        for (0..transport.path_count) |i| std.debug.print("  {s}\n", .{transport.paths[i][0..transport.path_lengths[i]]});
        if (result != .selected) return error.UniqueDeviceRequired;
        return;
    }
    describe(expected.?);
    var seed: [4]u8 = undefined;
    std.Io.random(init.io, &seed);
    const path = if (args.len == (if (recovery or bootloader or reconnect) @as(usize, 5) else 6)) args[args.len - 1] else null;
    var driver = try live.Driver(Native).init(transport, expected.?, std.mem.readInt(u32, &seed, .little), path);
    var recording = try capture.Recorder.init(allocator);
    defer recording.deinit(allocator);
    driver.recording = &recording;
    var saved = false;
    defer {
        driver.disconnect(driver.transport.now());
        if (!saved) file.?.writeStreamingAll(init.io, recording.encoded()) catch |err| std.debug.print("CAPTURE WRITE FAILED: {s}\n", .{@errorName(err)});
        std.debug.print("Capture: {s}; capacity_exceeded={any}\n", .{ output.?, recording.full });
    }
    const start = driver.transport.now();
    var last_phase = driver.session.phase;
    var live_cuts: usize = 0;
    var key_events: usize = 0;
    var malformed_sent = false;
    var pause_done = false;
    var reopen_done = false;
    var recovery_cuts: [3]bool = @splat(false);
    var bootloader_sent = false;
    var disconnected_nonce: ?u32 = null;
    var reconnected_at: ?u64 = null;
    while (driver.transport.now() -| start < seconds * 1000) {
        const now = driver.transport.now();
        const was_connected = driver.connected;
        const previous_nonce = driver.session.token;
        driver.poll(now);
        if (bootloader and driver.session.bootloader_status == .accepted) {
            std.debug.print("Bootloader request accepted; verify the BOOTSEL volume before flashing.\n", .{});
            driver.disconnect(now);
            try file.?.writeStreamingAll(init.io, recording.encoded());
            saved = true;
            return;
        }
        if (driver.status == .transport_error) {
            const err = driver.transport_error orelse return error.HidTransportFailed;
            if (!reconnect or (err != error.HidReadFailed and err != error.HidWriteFailed)) return err;
            if (was_connected) {
                if (disconnected_nonce != null) return error.UnexpectedRepeatedDisconnect;
                disconnected_nonce = previous_nonce;
                std.debug.print("Observed physical disconnect at t={d}ms; waiting for fresh session.\n", .{now -| start});
            }
        }
        if (driver.status == .multiple_devices or driver.status == .path_not_found) return error.UniqueDeviceRequired;
        if (driver.session.phase == .incompatible) {
            if (protocol.decodeIdentityBody(driver.session.identity_body, driver.session.token)) |observed| {
                std.debug.print("Observed device identity:\n", .{});
                describe(observed);
            } else |_| {}
            return error.IdentityOrProtocolMismatch;
        }
        if (driver.session.phase != last_phase) {
            std.debug.print("t={d}ms phase={s} nonce={d}\n", .{ now -| start, @tagName(driver.session.phase), driver.session.token });
            last_phase = driver.session.phase;
        }
        for (driver.key_events[0..driver.key_event_count]) |event| {
            std.debug.print("key event: {any}\n", .{event});
            key_events += 1;
        }
        if (driver.session.hasCoherentState()) {
            live_cuts += 1;
            if (reconnect and disconnected_nonce != null and driver.session.token != disconnected_nonce.?) {
                if (reconnected_at == null) {
                    reconnected_at = now;
                    std.debug.print("Fresh coherent session after disconnect; nonce={d}.\n", .{driver.session.token});
                } else if (now -| reconnected_at.? >= 10000) break;
            }
            if (bootloader and !bootloader_sent and driver.session.capabilities_queried and driver.session.capability_request == 0) {
                if (!driver.session.bootloaderAvailable()) return error.ManualBootloaderRequired;
                try driver.enterBootloader(now);
                bootloader_sent = true;
                std.debug.print("One explicit remote bootloader request sent.\n", .{});
            }
            if (recovery and driver.session.phase == .live) {
                if (!malformed_sent) {
                    const invalid: [33]u8 = @splat(0);
                    // Raw injection is logged below, outside reducer capture.
                    try driver.transport.write(&invalid);
                    malformed_sent = true;
                    // Following traffic must establish a fresh coherent session.
                    driver.disconnect(now);
                    std.debug.print("Sent one invalid protocol report; reconnecting.\n", .{});
                } else if (!pause_done) {
                    recovery_cuts[0] = true;
                    std.debug.print("Pausing host reads for three seconds.\n", .{});
                    try std.Io.sleep(init.io, .fromMilliseconds(3000), .awake);
                    pause_done = true;
                } else if (!reopen_done) {
                    recovery_cuts[1] = true;
                    driver.disconnect(now);
                    reopen_done = true;
                    std.debug.print("Closing/reopening HID for fresh nonce/snapshot.\n", .{});
                } else recovery_cuts[2] = true;
            }
        }
        try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }
    if (bootloader) return error.BootloaderAcceptanceNotConfirmed;
    if (reconnect and reconnected_at == null) return error.PhysicalReconnectNotObserved;
    if (live_cuts == 0 or !driver.session.hasCoherentState()) return error.NoCoherentFinalSnapshot;
    if (recovery and !std.mem.allEqual(bool, &recovery_cuts, true)) return error.RecoveryNotCompleted;
    if (recording.full) return error.CaptureCapacityExceeded;
    std.debug.print("Capabilities queried={any} value=0x{x}; remote bootloader available={any}\n", .{ driver.session.capabilities_queried, driver.session.capabilities, driver.session.bootloaderAvailable() });
    driver.disconnect(driver.transport.now());
    try file.?.writeStreamingAll(init.io, recording.encoded());
    saved = true;
    std.debug.print("PASS: matching coherent session; key events={d}; recovery={any}. Physical HID behavior/USB-route acceptance remain separate.\n", .{ key_events, recovery_cuts });
}
