//! Read-only construction of a prepared build configuration from owned receipts.
const std = @import("std");
const jobs = @import("companion-jobs");
const p = @import("project");
const worker = @import("build_worker.zig");
pub const Input = struct {
    resolution: jobs.package_resolution.Record,
    source_cache: ?[]const u8 = null,
    compiler_receipt: jobs.toolchain.Receipt,
    compiler_receipt_path: []const u8,
    companion_root: []const u8,
    firmware_root: []const u8,
    firmware_revision: []const u8,
    source_kind: @FieldType(jobs.target_lock.Lock, "source_kind"),
    board_id: [8]u8,
    build_board: []const u8,
    board_mapping: []const u8,
    export_directory: []const u8,
    install_directory: []const u8,
};
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    plan: worker.Plan,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, input: Input) !Owned {
    for ([_][]const u8{ input.compiler_receipt_path, input.export_directory, input.install_directory }) |path| if (!std.fs.path.isAbsolute(path)) return error.AbsoluteBuildEnvironmentPathRequired;
    try input.compiler_receipt.verify(gpa, io);
    const receipt_bytes = try std.Io.Dir.cwd().readFileAlloc(io, input.compiler_receipt_path, gpa, .limited(32 * 1024));
    defer gpa.free(receipt_bytes);
    const recorded = try jobs.toolchain.Receipt.parse(gpa, receipt_bytes);
    defer recorded.deinit(gpa);
    const selected_bytes = try input.compiler_receipt.serialize(gpa);
    defer gpa.free(selected_bytes);
    const recorded_bytes = try recorded.serialize(gpa);
    defer gpa.free(recorded_bytes);
    if (!std.mem.eql(u8, selected_bytes, recorded_bytes)) return error.ToolchainReceiptMismatch;
    var resolution = try jobs.package_resolution.verify(gpa, io, input.resolution, input.source_cache);
    defer resolution.deinit();
    var companion: ?jobs.package_resolution.RootRecord = null;
    var firmware: ?jobs.package_resolution.RootRecord = null;
    for (resolution.record.roots) |root| {
        if (std.mem.eql(u8, root.name, input.companion_root)) companion = root;
        if (std.mem.eql(u8, root.name, input.firmware_root)) firmware = root;
    }
    const host_root = companion orelse return error.BuildRootNotResolved;
    const firmware_root = firmware orelse return error.BuildRootNotResolved;
    if (input.source_kind == .published) {
        if (resolution.record.overrides.len != 0) return error.DevelopmentOverrideRequiresDevelopmentLock;
        var published = false;
        for (resolution.record.dependencies) |dependency| if (std.mem.eql(u8, dependency.source_path, firmware_root.directory) and dependency.identity == .git_revision and std.mem.eql(u8, dependency.revision, input.firmware_revision)) {
            published = true;
        };
        if (!published) return error.UnverifiedPublishedFirmware;
    }
    const base = jobs.target_lock.Lock{ .firmware_revision = input.firmware_revision, .firmware_source_digest = firmware_root.tree_digest, .source_kind = input.source_kind, .dependency_digest = resolution.record.closure_digest, .compiler_digest = input.compiler_receipt.compiler_digest, .compiler_bundle_digest = input.compiler_receipt.bundle_digest orelse @splat(0), .board = input.build_board, .board_mapping_digest = jobs.firmware.digest(input.board_mapping) };
    var lock = try input.compiler_receipt.targetLock(gpa, base);
    lock.toolchain_receipt_digest = jobs.firmware.digest(receipt_bytes);
    const selection = jobs.build_provenance.Selection{ .lock = lock, .compiler_path = input.compiler_receipt.compiler, .compiler_distribution_path = input.compiler_receipt.distribution, .compiler_bundle_path = input.compiler_receipt.bundle, .toolchain_receipt_path = input.compiler_receipt_path, .expected_compiler_tree_digest = input.compiler_receipt.tree_digest, .companion_path = host_root.directory, .expected_companion_tree_digest = host_root.tree_digest, .firmware_path = firmware_root.directory, .dependencies = resolution.record.dependencies, .manifests = resolution.record.manifests, .board_mapping = input.board_mapping, .project_digest = @splat(0), .exported_source_digest = @splat(0), .profile_id = @splat(0), .identity_digest = @splat(0) };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const plan = try p.owned_zon.clone(arena.allocator(), worker.Plan{ .config = .{ .board_id = input.board_id, .build_board = input.build_board, .request = .{ .resolution = resolution.record, .source_cache = input.source_cache, .selection = selection, .export_directory = input.export_directory, .expected_export_tree = @splat(0), .install_directory = input.install_directory, .development_firmware = if (input.source_kind == .development) firmware_root.directory else null } } });
    return .{ .arena = arena, .plan = plan };
}
