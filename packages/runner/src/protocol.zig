const std = @import("std");
const core = @import("zigmkay").core;
pub const version: u16 = 1;
pub const max_input_bytes = 4096;
pub const max_response_bytes = 1024 * 1024;
pub const max_events = 256;
pub const Command = union(enum) { key_down: u7, key_up: u7, encoder: u8, advance, reset, stop };
pub const Input = struct { version: u16 = version, sequence: u64, time_us: u64, command: Command };
pub const Output = struct {
    version: u16 = version,
    sequence: u64,
    snapshot_id: [32]u8,
    state: enum { ready, processed, restart_required, stopped, failed },
    commands: []const core.OutputCommand = &.{},
    events: []const core.ProcessorEvent = &.{},
    signals: []const @import("zigmkay").telemetry.Signal = &.{},
    active_layers: u16 = 1,
    highest_layer: u4 = 0,
    modifiers: u8 = 0,
    diagnostic: ?[]const u8 = null,
};
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Input {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    const input = try @import("owned-zon").parse(Input, gpa, text);
    if (input.version != version) return error.UnsupportedVersion;
    return input;
}
