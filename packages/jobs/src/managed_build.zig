//! Owned explicit build lifecycle. Preparation and artifact promotion are separate.
const std = @import("std");
const jobs = @import("root.zig");
const zon = @import("owned-zon");
pub const Request = struct {
    pub const DependencyAccess = jobs.build_provenance.DependencyAccess;
    pub const AuditMode = enum { fast, deep };
    pub const Prepared = struct {
        inputs: jobs.firmware.Inputs,
        receipt: jobs.build_provenance.Receipt,
    };
    dependency_access: DependencyAccess = .offline,
    audit_mode: AuditMode = .fast,
    /// Previously prepared inputs and receipt. Fast mode does not re-audit these claims.
    prepared: ?Prepared = null,
    resolution: jobs.package_resolution.Record,
    source_cache: ?[]const u8 = null,
    selection: jobs.build_provenance.Selection,
    export_directory: []const u8,
    expected_export_tree: jobs.firmware.Digest,
    install_directory: []const u8,
    development_firmware: ?[]const u8 = null,
    timeout_ms: u32 = 120_000,
};
/// Stable address from start through completion/cancellation.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    request: Request,
    captured: jobs.build_provenance.Captured,
    command: jobs.firmware.Command,
    process: jobs.Job,
    install_name: []const u8,
    completed: bool = false,
    accepted: bool = false,
    runner_completed: bool = false,
    finish_verified: bool = false,
    finish_verified_key: jobs.firmware.Digest = @splat(0),
    finish_verified_receipt: jobs.build_provenance.Receipt = undefined,
    finish_verified_at_ms: i64 = 0,
    pub fn init(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, request: Request) !Job {
        const phase_start = std.Io.Clock.awake.now(io);
        defer std.log.info("build phase init_capture_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()});
        if (request.timeout_ms == 0) return error.InvalidBuildDeadline;
        if (request.dependency_access == .allow_pinned_fetch and (request.source_cache == null or !std.fs.path.isAbsolute(request.source_cache.?))) return error.PreparedPackageCacheRequired;
        if (request.selection.verify_compiler_version) return error.CompilerExecutionRequiresPreparation;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned = try zon.clone(arena.allocator(), request);
        if (owned.development_firmware) |path| {
            const actual = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa);
            defer gpa.free(actual);
            const expected = try std.Io.Dir.realPathFileAbsoluteAlloc(io, owned.selection.firmware_path, gpa);
            defer gpa.free(expected);
            if (!std.mem.eql(u8, actual, expected)) return error.FirmwareOverrideMismatch;
        }
        for (owned.resolution.overrides) |override| {
            var matched = false;
            for (owned.resolution.roots) |owner| for (owned.resolution.roots) |destination| {
                if (std.mem.eql(u8, owner.name, override.root) and std.mem.eql(u8, destination.name, override.target_root) and std.mem.eql(u8, owner.directory, owned.selection.companion_path) and std.mem.eql(u8, destination.directory, owned.selection.firmware_path) and std.mem.eql(u8, override.dependency, "zigmkay_firmware") and owned.development_firmware != null) matched = true;
            };
            if (!matched) return error.UnsupportedBuildOverride;
        }
        try verifyExport(gpa, io, owned);
        var captured = if (owned.audit_mode == .deep)
            try jobs.package_resolution.capture(gpa, io, owned.resolution, owned.source_cache, owned.selection, owned.dependency_access)
        else blk: {
            const prepared = owned.prepared orelse return error.PreparedBuildInputsRequired;
            var captured_arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer captured_arena.deinit();
            const copied = try zon.clone(captured_arena.allocator(), prepared.inputs);
            break :blk jobs.build_provenance.Captured{
                .arena = captured_arena,
                .inputs = copied,
                .receipt = prepared.receipt,
            };
        };
        errdefer captured.deinit();
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const install_name = try std.fmt.allocPrint(arena.allocator(), "build-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        const install_path = try std.fs.path.join(arena.allocator(), &.{ owned.install_directory, install_name });
        var command = try jobs.firmware.Command.init(gpa, captured.inputs, owned.selection.compiler_path, owned.selection.companion_path, owned.export_directory, install_path, owned.development_firmware);
        errdefer command.deinit();
        var selected_environment = try environment.clone(gpa);
        defer selected_environment.deinit();
        if (owned.source_cache) |cache| {
            try selected_environment.put("ZIG_GLOBAL_CACHE_DIR", cache);
        } else {
            try selected_environment.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(arena.allocator(), &.{ install_path, "global-cache" }));
        }
        // Zig's system package mode reads supplied package directories and
        // refuses fetching missing packages during the managed build. Graphs
        // without external sources receive an empty output-local package path.
        const a = command.arena.allocator();
        const package_path = if (owned.source_cache) |cache| try std.fs.path.join(a, &.{ cache, "p" }) else try std.fs.path.join(a, &.{ install_path, "unprepared-packages" });
        try selected_environment.put("ZIG_LOCAL_PKG_DIR", package_path);
        try selected_environment.put("ZIG_LIB_DIR", try std.fs.path.join(a, &.{ owned.selection.compiler_distribution_path, "lib" }));
        if (owned.dependency_access == .offline) {
            const args = try a.alloc([]const u8, command.argv.len + 2);
            @memcpy(args[0..command.argv.len], command.argv);
            args[command.argv.len] = "--system";
            args[command.argv.len + 1] = package_path;
            command.argv = args;
        }
        const process = try jobs.Job.init(gpa, io, .{ .argv = command.argv, .cwd = command.cwd, .snapshot_id = command.build_key, .timeout_ms = owned.timeout_ms, .environ_map = &selected_environment, .isolated_group = @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi });
        return .{ .arena = arena, .gpa = gpa, .io = io, .request = owned, .captured = captured, .command = command, .process = process, .install_name = install_name };
    }
    pub fn start(self: *Job, current: jobs.firmware.Inputs) !void {
        if (self.completed) return error.BuildAlreadyCompleted;
        if (self.process.started) return error.JobAlreadyStarted;
        if (!std.mem.eql(u8, &self.command.build_key, &jobs.firmware.key(current))) return error.StaleBuild;
        const phase_start = std.Io.Clock.awake.now(self.io);
        if (self.request.audit_mode == .deep) try self.recheck() else try verifyExport(self.gpa, self.io, self.request);
        std.log.info("build phase start_recheck_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds()});
        var output = try std.Io.Dir.cwd().createDirPathOpen(self.io, self.request.install_directory, .{});
        defer output.close(self.io);
        try output.createDir(self.io, self.install_name, .default_dir);
        try self.process.start();
    }
    pub fn poll(self: *Job) ?anyerror!jobs.Result {
        return self.process.poll();
    }
    /// Read/verify bytes only after successful bounded process completion.
    /// Caller owns the returned manifest and explicitly promotes it if still current.
    pub fn finish(self: *Job, result: jobs.Result, current: jobs.firmware.Inputs) !jobs.firmware.Manifest {
        if (self.completed or self.process.future != null or !self.process.started) return error.BuildNotCompleted;
        self.completed = true;
        self.finish_verified = false;
        if (!std.mem.eql(u8, &result.snapshot_id, &self.command.build_key)) return error.StaleBuild;
        if (!result.successful()) return error.BuildFailed;
        if (!std.mem.eql(u8, &jobs.firmware.key(current), &self.command.build_key)) return error.StaleBuild;
        const phase_start = std.Io.Clock.awake.now(self.io);
        if (self.request.audit_mode == .deep) try self.recheck() else try verifyExport(self.gpa, self.io, self.request);
        std.log.info("build phase finish_recheck_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds()});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, self.command.uf2_path, self.gpa, .limited(16 * 1024 * 1024));
        defer self.gpa.free(bytes);
        var manifest = try jobs.firmware.Manifest.complete(self.gpa, .succeeded, self.command.build_key, self.captured.inputs, current, self.command.uf2_path, bytes);
        manifest.audit_mode = if (self.request.audit_mode == .deep) .deep else .fast_prepared_inputs_no_fresh_full_provenance_audit;
        self.accepted = true;
        self.finish_verified_key = jobs.firmware.key(current);
        self.finish_verified_receipt = self.captured.receipt;
        self.finish_verified_at_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
        self.finish_verified = true;
        return manifest;
    }
    /// The existing build-project command also installs the native processor runner.
    /// It is accepted only after successful firmware completion from this same job.
    pub fn finishRunner(self: *Job, current: jobs.firmware.Inputs) !jobs.runner_artifact.Manifest {
        if (!self.accepted or !self.finish_verified or self.runner_completed) return error.RunnerBuildNotCompleted;
        self.runner_completed = true;
        self.finish_verified = false;
        const phase_start = std.Io.Clock.awake.now(self.io);
        defer std.log.info("build phase runner_finalization_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds()});
        if (!std.mem.eql(u8, &jobs.firmware.key(current), &self.finish_verified_key) or
            !std.mem.eql(u8, &self.finish_verified_key, &self.command.build_key) or
            !std.meta.eql(self.finish_verified_receipt, self.captured.receipt) or
            std.Io.Clock.awake.now(self.io).toMilliseconds() - self.finish_verified_at_ms > 1000) return error.StaleBuild;
        const output = std.fs.path.dirname(std.fs.path.dirname(self.command.uf2_path).?).?;
        const executable = "project-runner" ++ if (@import("builtin").os.tag == .windows) ".exe" else "";
        const path = try std.fs.path.join(self.gpa, &.{ output, "bin", executable });
        defer self.gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(jobs.runner_artifact.max_bytes));
        defer self.gpa.free(bytes);
        return jobs.runner_artifact.Manifest.complete(self.gpa, .succeeded, jobs.runner_artifact.key(self.captured.inputs, jobs.runner_artifact.native_target), self.captured.inputs, current, path, bytes);
    }
    fn recheck(self: *Job) !void {
        try verifyExport(self.gpa, self.io, self.request);
        var fresh = try jobs.package_resolution.capture(self.gpa, self.io, self.request.resolution, self.request.source_cache, self.request.selection, self.request.dependency_access);
        defer fresh.deinit();
        if (!std.mem.eql(u8, &fresh.inputs.build_inputs_digest, &self.captured.inputs.build_inputs_digest)) return error.BuildInputsChanged;
    }
    pub fn cancel(self: *Job) void {
        self.process.cancel();
        self.completed = true;
        self.accepted = false;
        self.finish_verified = false;
    }
    pub fn deinit(self: *Job) void {
        self.process.deinit();
        self.command.deinit();
        self.captured.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
fn verifyExport(gpa: std.mem.Allocator, io: std.Io, request: Request) !void {
    if (!std.fs.path.isAbsolute(request.export_directory)) return error.InvalidBuildPath;
    var dir = try std.Io.Dir.cwd().openDir(io, request.export_directory, .{ .iterate = true });
    defer dir.close(io);
    const actual = try jobs.preparation.treeDigest(gpa, io, dir);
    if (!std.mem.eql(u8, &actual, &request.expected_export_tree)) return error.ExportedSourceChanged;
}
