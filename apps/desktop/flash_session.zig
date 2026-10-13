//! Offline editor flash surface. A controller may only be advanced by an
//! accepted preparation/build/freeze adapter; this application has none yet.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const jobs = @import("companion-jobs");

pub const Session = struct {
    controller: desktop.flash_controller.Controller,
    open: bool = false,
    tools: ?jobs.flash_inputs.Tools = null,
    tools_snapshot: ?desktop.flash_controller.Digest = null,

    pub fn init(gpa: std.mem.Allocator, context: desktop.flash_controller.Context) Session {
        return .{ .controller = desktop.flash_controller.Controller.init(gpa, context) };
    }

    fn clearTools(self: *Session) void {
        if (self.tools) |*tools| tools.deinit();
        self.tools = null;
        self.tools_snapshot = null;
    }

    pub fn deinit(self: *Session) void {
        self.clearTools();
        self.controller.deinit();
    }

    /// Only an explicit caller-provided receipt is accepted; this reads files,
    /// but never starts a job, probes hardware, or authorizes a transfer.
    pub fn prepareTools(self: *Session, receipt_path: []const u8, io: std.Io, manifest: jobs.firmware.Manifest, snapshot: desktop.flash_controller.Digest) !void {
        self.clearTools();
        if (!std.fs.path.isAbsolute(receipt_path) or std.mem.indexOfScalar(u8, receipt_path, 0) != null) return error.InvalidFlashPath;
        if (!std.mem.eql(u8, &snapshot, &self.controller.current.snapshot)) return error.StaleFlashRequest;
        if (!std.mem.eql(u8, &manifest.build_key, &jobs.firmware.key(manifest.inputs)) or
            !std.mem.eql(u8, &manifest.build_key, &self.controller.current.build_key)) return error.StaleBuild;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, receipt_path, self.controller.gpa, .limited(16 * 1024));
        defer self.controller.gpa.free(bytes);
        var parsed = try jobs.flash_inputs.Tools.parse(self.controller.gpa, bytes);
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, parsed.record.firmware_revision, manifest.inputs.lock.firmware_revision)) return error.ToolsRevisionMismatch;
        if (parsed.record.source_kind != manifest.inputs.lock.source_kind or !std.mem.eql(u8, &parsed.record.firmware_source_digest, &manifest.inputs.lock.firmware_source_digest)) return error.ToolsSourceMismatch;
        try parsed.verify(self.controller.gpa, io);
        self.tools = parsed;
        self.tools_snapshot = self.controller.current.snapshot;
    }

    pub fn show(self: *Session) void {
        self.open = true;
    }

    /// Never substitute a toolbar build result for the accepted flash artifact.
    /// Changes invalidate any future frozen artifact and device selection.
    pub fn observe(self: *Session, context: desktop.flash_controller.Context) void {
        if (!std.meta.eql(context, self.controller.current)) self.clearTools();
        _ = self.controller.observe(context);
    }

    pub fn draw(self: *Session) void {
        if (!self.open) return;
        const state = desktop.flash_presenter.view(&self.controller, null);
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{});
        defer panel.deinit();
        dvui.label(@src(), "Flash preparation", .{}, .{});
        dvui.label(@src(), "{s}", .{state.status}, .{});
        dvui.label(@src(), "Flash unavailable: accepted tool provenance, a matching frozen UF2 artifact, and an explicitly selected device are required.", .{}, .{});
        dvui.label(@src(), "The editor does not yet have a flash preparation adapter. Build output alone cannot authorize flashing.", .{}, .{});
        if (dvui.button(@src(), "Close flash panel", .{}, .{})) self.open = false;
    }
};

test "explicit tools receipt validates paths provenance bytes and stale context offline" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const wrapper = try std.fs.path.join(gpa, &.{ base, "wrapper" });
    defer gpa.free(wrapper);
    const picotool = try std.fs.path.join(gpa, &.{ base, "picotool" });
    defer gpa.free(picotool);
    const receipt = try std.fs.path.join(gpa, &.{ base, jobs.flash_inputs.tools_name });
    defer gpa.free(receipt);
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "picotool", .data = "picotool bytes" });
    const lock = jobs.target_lock.fixture();
    var captured = try jobs.flash_inputs.Tools.capture(gpa, io, lock.firmware_revision, lock.firmware_source_digest, lock.source_kind, wrapper, picotool);
    defer captured.deinit();
    const encoded = try captured.serialize(gpa);
    defer gpa.free(encoded);
    try tmp.dir.writeFile(io, .{ .sub_path = jobs.flash_inputs.tools_name, .data = encoded });
    const inputs: jobs.firmware.Inputs = .{ .project_digest = @splat(1), .source_digest = @splat(2), .build_inputs_digest = @splat(3), .profile_id = @splat(4), .identity_digest = @splat(5), .lock = lock };
    // This manifest is metadata-only: no UF2 is read or transferred by preparation.
    const manifest: jobs.firmware.Manifest = .{ .arena = .init(gpa), .inputs = inputs, .build_key = jobs.firmware.key(inputs), .uf2_path = "/unused.uf2", .uf2_size = 0, .uf2_hash = @splat(0) };
    const snapshot: desktop.flash_controller.Digest = @splat(9);
    var session = Session.init(gpa, .{ .snapshot = snapshot, .build_key = manifest.build_key });
    defer session.deinit();
    try std.testing.expectError(error.InvalidFlashPath, session.prepareTools("flash-tools.zon", io, manifest, snapshot));
    try std.testing.expectError(error.InvalidFlashPath, session.prepareTools("/bad\x00path", io, manifest, snapshot));
    try std.testing.expectError(error.StaleFlashRequest, session.prepareTools(receipt, io, manifest, @splat(8)));
    var wrong_manifest = manifest;
    wrong_manifest.build_key[0] ^= 1;
    try std.testing.expectError(error.StaleBuild, session.prepareTools(receipt, io, wrong_manifest, snapshot));
    var wrong_context = session.controller.current;
    wrong_context.build_key[0] ^= 1;
    session.observe(wrong_context);
    try std.testing.expectError(error.StaleBuild, session.prepareTools(receipt, io, manifest, snapshot));
    session.observe(.{ .snapshot = snapshot, .build_key = manifest.build_key });
    wrong_manifest = manifest;
    wrong_manifest.inputs.lock.firmware_revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    wrong_manifest.build_key = jobs.firmware.key(wrong_manifest.inputs);
    session.observe(.{ .snapshot = snapshot, .build_key = wrong_manifest.build_key });
    try std.testing.expectError(error.ToolsRevisionMismatch, session.prepareTools(receipt, io, wrong_manifest, snapshot));
    wrong_manifest = manifest;
    wrong_manifest.inputs.lock.source_kind = .published;
    wrong_manifest.build_key = jobs.firmware.key(wrong_manifest.inputs);
    session.observe(.{ .snapshot = snapshot, .build_key = wrong_manifest.build_key });
    try std.testing.expectError(error.ToolsSourceMismatch, session.prepareTools(receipt, io, wrong_manifest, snapshot));
    wrong_manifest = manifest;
    wrong_manifest.inputs.lock.firmware_source_digest[0] ^= 1;
    wrong_manifest.build_key = jobs.firmware.key(wrong_manifest.inputs);
    session.observe(.{ .snapshot = snapshot, .build_key = wrong_manifest.build_key });
    try std.testing.expectError(error.ToolsSourceMismatch, session.prepareTools(receipt, io, wrong_manifest, snapshot));
    session.observe(.{ .snapshot = snapshot, .build_key = manifest.build_key });
    try session.prepareTools(receipt, io, manifest, snapshot);
    try std.testing.expect(session.tools != null);
    try std.testing.expectEqual(snapshot, session.tools_snapshot.?);
    session.observe(session.controller.current);
    try std.testing.expect(session.tools != null);
    session.observe(.{ .snapshot = @splat(7), .build_key = manifest.build_key });
    try std.testing.expect(session.tools == null);
    try std.testing.expect(session.tools_snapshot == null);
    session.observe(.{ .snapshot = snapshot, .build_key = manifest.build_key });
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "tampered wrapper" });
    try std.testing.expectError(error.WrapperChanged, session.prepareTools(receipt, io, manifest, snapshot));
    try std.testing.expect(session.tools == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = jobs.flash_inputs.tools_name, .data = "invalid zon" });
    if (session.prepareTools(receipt, io, manifest, snapshot)) |_| return error.ExpectedInvalidReceipt else |_| {}
    try std.testing.expect(session.tools == null);
    try std.testing.expectEqual(desktop.flash_controller.Phase.idle, session.controller.phase);
    try std.testing.expect(!desktop.flash_presenter.view(&session.controller, null).can_confirm);
}

test "offline flash panel cannot advance controller or authorize transfer" {
    var session = Session.init(std.testing.allocator, .{ .snapshot = @splat(1), .build_key = @splat(3) });
    defer session.deinit();
    session.show();
    try std.testing.expect(session.open);
    try std.testing.expect(!desktop.flash_presenter.view(&session.controller, null).can_confirm);
    session.observe(.{ .snapshot = @splat(2), .build_key = @splat(3) });
    try std.testing.expectEqual(desktop.flash_controller.Phase.idle, session.controller.phase);
    try std.testing.expectError(error.DisabledAction, desktop.flash_presenter.view(&session.controller, null).intent(.confirm, null));
}
