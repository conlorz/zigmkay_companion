//! Explicit controls. Caller handles the returned intent and owned diagnostics.
const std = @import("std");
const dvui = @import("dvui");
const policy = @import("flash-presenter");
pub const Input = struct {
    selection: ?policy.controller.Selection = null,
    session_token: ?u32 = null,
    diagnostics: ?policy.Diagnostics = null,
    failure: ?anyerror = null,
};
pub fn draw(owner: *const policy.controller.Controller, input: Input) !?policy.controller.Intent {
    const state = policy.view(owner, input.session_token);
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{});
    defer column.deinit();
    dvui.label(@src(), "{s}", .{state.status}, .{});
    if (owner.failure) |failure| dvui.label(@src(), "Failure: {s}", .{@tagName(failure)}, .{});
    if (input.failure) |failure| dvui.label(@src(), "{s}", .{@errorName(failure)}, .{});
    if (input.diagnostics) |diagnostics| {
        if (diagnostics.cancelled) dvui.label(@src(), "Transfer cancelled", .{}, .{});
        if (diagnostics.timed_out) dvui.label(@src(), "Transfer timed out", .{}, .{});
        if (diagnostics.truncated) dvui.label(@src(), "Diagnostic output was truncated", .{}, .{});
        if (diagnostics.stdout.len > 0) dvui.label(@src(), "{s}", .{diagnostics.stdout}, .{});
        if (diagnostics.stderr.len > 0) dvui.label(@src(), "{s}", .{diagnostics.stderr}, .{});
    }
    if (owner.artifact) |artifact| {
        dvui.label(@src(), "Artifact: {s}", .{artifact.path}, .{});
        dvui.label(@src(), "SHA-256: {s}", .{std.fmt.bytesToHex(artifact.uf2_hash, .lower)}, .{});
        dvui.label(@src(), "Board: {s}  Profile: {s}", .{ &artifact.expected_identity.board_id, &artifact.expected_identity.profile_id }, .{});
    }
    if (owner.selected) |chosen| switch (chosen) {
        .serial => |serial| dvui.label(@src(), "Device serial: {s}", .{serial}, .{}),
        .bus_address => |address| dvui.label(@src(), "Device bus {d}, address {d}", .{ address.bus, address.address }, .{}),
    };
    const actions = [_]policy.Action{ .prepare, .build, .freeze, .select, .confirm, .cancel, .reset };
    const captions = [_][]const u8{ "Prepare tools", "Build", "Freeze artifact", "Select device", "Flash", "Cancel", "Reset" };
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    defer row.deinit();
    for (actions, captions, 0..) |action, caption, index| {
        const enabled = state.enabled(action) and (action != .select or input.selection != null);
        if (enabled) {
            if (dvui.button(@src(), caption, .{}, .{ .id_extra = index })) return try state.intent(action, input.selection);
        } else dvui.label(@src(), "{s}", .{caption}, .{ .id_extra = index, .color_text = .{ .color = .{ .r = 128, .g = 128, .b = 128, .a = 255 } } });
    }
    return null;
}
