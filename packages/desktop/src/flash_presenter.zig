//! UI policy over the controller. Rendering cannot dispatch a hardware effect.
const std = @import("std");
pub const controller = @import("flash-controller");
pub const Action = enum { prepare, build, freeze, select, confirm, cancel, reset };
/// Borrowed from an owned runtime completion; keep that completion alive while
/// drawing. No parsing of diagnostic text is used to change transfer phases.
pub const Diagnostics = struct {
    stdout: []const u8,
    stderr: []const u8,
    cancelled: bool,
    timed_out: bool,
    truncated: bool,
    pub fn fromResult(result: anytype) Diagnostics {
        return .{ .stdout = result.process.stdout, .stderr = result.process.stderr, .cancelled = result.cancelled, .timed_out = result.timed_out, .truncated = result.diagnostics_truncated };
    }
};
pub const View = struct {
    phase: controller.Phase,
    operation_id: u64,
    uf2_hash: ?controller.Digest,
    previous_session_token: ?u32,
    can_prepare: bool,
    can_build: bool,
    can_freeze: bool,
    can_select: bool,
    can_confirm: bool,
    can_cancel: bool,
    can_reset: bool,
    status: []const u8,
    pub fn enabled(self: View, action: Action) bool {
        return switch (action) {
            .prepare => self.can_prepare,
            .build => self.can_build,
            .freeze => self.can_freeze,
            .select => self.can_select,
            .confirm => self.can_confirm,
            .cancel => self.can_cancel,
            .reset => self.can_reset,
        };
    }
    /// Confirm binds the exact rendered artifact and operation. The controller
    /// independently rejects stale views after edits or a new operation.
    pub fn intent(self: View, action: Action, selection: ?controller.Selection) !controller.Intent {
        if (!self.enabled(action)) return error.DisabledAction;
        return switch (action) {
            .prepare => .prepare,
            .build => .build,
            .freeze => .freeze,
            .select => .{ .select = selection orelse return error.SelectionRequired },
            .confirm => .{ .confirm = .{ .operation_id = self.operation_id, .uf2_hash = self.uf2_hash.?, .previous_session_token = self.previous_session_token } },
            .cancel => .cancel,
            .reset => .reset,
        };
    }
};
pub fn view(owner: *const controller.Controller, session_token: ?u32) View {
    const phase = owner.phase;
    const busy = switch (phase) {
        .preparing, .building, .freezing, .verifying, .rebooting, .reconnecting, .cancelling => true,
        else => false,
    };
    const fresh = if (owner.captured) |captured| std.meta.eql(captured, owner.current) else false;
    return .{
        .phase = phase,
        .operation_id = owner.operation_id,
        .uf2_hash = if (owner.artifact) |artifact| artifact.uf2_hash else null,
        .previous_session_token = session_token,
        .can_prepare = !busy,
        .can_build = phase == .prepared and fresh,
        .can_freeze = phase == .built and fresh,
        .can_select = (phase == .frozen or phase == .awaiting_confirmation) and fresh,
        .can_confirm = phase == .awaiting_confirmation and fresh and owner.artifact != null and owner.selected != null,
        .can_cancel = switch (phase) {
            .idle, .cancelled, .stale, .cancelling => false,
            else => true,
        },
        .can_reset = !busy and phase != .idle,
        .status = switch (phase) {
            .idle => "Prepare flash tools to begin",
            .preparing => "Preparing flash tools",
            .prepared => "Tools prepared; build the current project",
            .building => "Building firmware",
            .built => "Build complete; freeze the artifact",
            .freezing => "Freezing the verified artifact",
            .frozen => "Artifact frozen; select a device",
            .awaiting_confirmation => "Selected device ready for Flash",
            .verifying => "Loading and verifying firmware",
            .rebooting => "Rebooting device",
            .reconnecting => "Waiting for matching firmware to reconnect",
            .ready => "Firmware identity confirmed",
            .cancelling => "Cancelling; waiting for the operation to finish",
            .cancelled => "Operation cancelled",
            .stale => "Project changed; prepare a new build",
            .failed => "Operation failed",
            .reconnect_timeout => "Reconnection timed out",
        },
    };
}
test "rendered flash confirmation is stale after a new operation and never inferred from a build" {
    const t = std.testing;
    var owner = controller.Controller.init(t.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    try t.expectError(error.DisabledAction, view(&owner, null).intent(.confirm, null));
    _ = try owner.dispatch(.prepare);
    try t.expect(!view(&owner, null).can_prepare);
    _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
    _ = try owner.dispatch(try view(&owner, null).intent(.build, null));
    _ = try owner.receive(.{ .built = .{ .operation_id = owner.operation_id, .build_key = owner.current.build_key } }, 0);
    try t.expect(!view(&owner, null).can_confirm);
    _ = try owner.dispatch(try view(&owner, null).intent(.freeze, null));
    _ = try owner.receive(.{ .frozen = .{ .operation_id = owner.operation_id, .artifact = .{ .context = owner.current, .path = "/cache/fixture.uf2", .uf2_hash = @splat(3), .expected_identity = .{ .board_id = "board_v1".*, .profile_id = "profile1".*, .digest = @splat(4) } } } }, 0);
    try t.expectError(error.SelectionRequired, view(&owner, null).intent(.select, null));
    _ = try owner.dispatch(try view(&owner, null).intent(.select, .{ .serial = "chosen" }));
    const rendered = view(&owner, 10);
    const confirm = try rendered.intent(.confirm, null);
    try t.expectEqual(@as(?u32, 10), confirm.confirm.previous_session_token);
    _ = try owner.dispatch(.prepare);
    _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
    _ = try owner.dispatch(.build);
    _ = try owner.receive(.{ .built = .{ .operation_id = owner.operation_id, .build_key = owner.current.build_key } }, 0);
    _ = try owner.dispatch(.freeze);
    _ = try owner.receive(.{ .frozen = .{ .operation_id = owner.operation_id, .artifact = .{ .context = owner.current, .path = "/cache/new.uf2", .uf2_hash = @splat(3), .expected_identity = .{ .board_id = "board_v1".*, .profile_id = "profile1".*, .digest = @splat(4) } } } }, 0);
    _ = try owner.dispatch(.{ .select = .{ .serial = "chosen" } });
    try t.expectError(error.StaleConfirmation, owner.dispatch(confirm));
}
