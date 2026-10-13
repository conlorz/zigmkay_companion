//! Explicit read-only prepared config generation; never acquires or builds sources.
const std = @import("std");
const p = @import("project");
const desktop = @import("desktop-core");
const jobs = @import("companion-jobs");
const catalog = @import("catalog-project");
const SourceKind = @FieldType(jobs.target_lock.Lock, "source_kind");
const Plan = struct {
    version: u16 = 1,
    toolchain_receipt: []const u8,
    resolution_receipt: []const u8,
    source_cache: ?[]const u8 = null,
    companion_root: []const u8,
    firmware_root: []const u8,
    firmware_revision: []const u8,
    source_kind: SourceKind,
    board_mode: enum { curated_lk7, catalog } = .curated_lk7,
    board_selector: []const u8 = "lk7",
    export_directory: []const u8,
    install_directory: []const u8,
};
const Resolution = struct { version: u16 = 1, plan_digest: jobs.firmware.Digest, record: jobs.package_resolution.Record };
fn read(comptime T: type, init: std.process.Init, path: []const u8, limit: usize) !T {
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteBuildEnvironmentPathRequired;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(limit));
    defer init.gpa.free(bytes);
    const text = try init.gpa.dupeSentinel(u8, bytes, 0);
    defer init.gpa.free(text);
    return p.owned_zon.parse(T, init.gpa, text);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 5) return error.Usage;
    const plan = try read(Plan, init, args[1], 1024 * 1024);
    defer p.owned_zon.free(init.gpa, plan);
    if (plan.version != 1) return error.UnsupportedBuildEnvironmentPlan;
    if (!std.fs.path.isAbsolute(args[2])) return error.AbsoluteBuildEnvironmentPathRequired;
    var output = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[2], .{});
    defer output.close(init.io);
    const filename = "build-environment.zon";
    const old = output.readFileAlloc(init.io, filename, init.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old) |bytes| {
        defer init.gpa.free(bytes);
        const text = try init.gpa.dupeSentinel(u8, bytes, 0);
        defer init.gpa.free(text);
        const previous = try p.owned_zon.parse(desktop.build_worker.Plan, init.gpa, text);
        defer p.owned_zon.free(init.gpa, previous);
        if (previous.version != 1) return error.UnsupportedBuildConfig;
    }
    const compiler = try read(jobs.toolchain.Receipt, init, plan.toolchain_receipt, 32 * 1024);
    defer compiler.deinit(init.gpa);
    const resolution = try read(Resolution, init, plan.resolution_receipt, 1024 * 1024);
    defer p.owned_zon.free(init.gpa, resolution);
    if (resolution.version != 1) return error.UnsupportedDependencyResolution;
    const actual_companion = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, args[3], init.gpa);
    defer init.gpa.free(actual_companion);
    const actual_firmware = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, args[4], init.gpa);
    defer init.gpa.free(actual_firmware);
    var companion_matches = false;
    var firmware_matches = false;
    for (resolution.record.roots) |root| {
        if (std.mem.eql(u8, root.name, plan.companion_root) and std.mem.eql(u8, root.directory, actual_companion)) companion_matches = true;
        if (std.mem.eql(u8, root.name, plan.firmware_root) and std.mem.eql(u8, root.directory, actual_firmware)) firmware_matches = true;
    }
    if (!companion_matches or !firmware_matches) return error.CompiledCatalogSourceMismatch;
    var board = if (plan.board_mode == .curated_lk7) curated: {
        if (!std.mem.eql(u8, plan.board_selector, "lk7")) return error.BuildBoardMismatch;
        var loaded = try p.profiles.create(init.gpa, .qwerty);
        defer loaded.deinit();
        break :curated try catalog.OwnedBoard.fromDocument(init.gpa, loaded.snapshot.document);
    } else try catalog.OwnedBoard.init(init.gpa, plan.board_selector);
    defer board.deinit();
    var mapping: std.Io.Writer.Allocating = .init(init.gpa);
    defer mapping.deinit();
    try std.zon.stringify.serialize(.{ .version = @as(u16, 1), .selector = board.entry.selector, .board = board.board, .processing_digest = board.entry.processing_digest, .index_digest = board.entry.index_digest }, .{}, &mapping.writer);
    var environment = try desktop.build_environment.prepare(init.gpa, init.io, .{ .resolution = resolution.record, .source_cache = plan.source_cache, .compiler_receipt = compiler, .compiler_receipt_path = plan.toolchain_receipt, .companion_root = plan.companion_root, .firmware_root = plan.firmware_root, .firmware_revision = plan.firmware_revision, .source_kind = plan.source_kind, .board_id = board.board.id, .build_board = board.entry.selector, .board_mapping = mapping.written(), .export_directory = plan.export_directory, .install_directory = plan.install_directory });
    defer environment.deinit();
    var encoded: std.Io.Writer.Allocating = .init(init.gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(environment.plan, .{}, &encoded.writer, 32);
    if (encoded.written().len > 1024 * 1024) return error.BuildConfigTooLarge;
    var atomic = try output.createFileAtomic(init.io, filename, .{ .replace = true });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, encoded.written());
    try atomic.replace(init.io);
}
