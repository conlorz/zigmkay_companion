//! Frozen editor export and managed build on the joined preparation worker.
const std = @import("std");
const p = @import("project");
const jobs = @import("companion-jobs");
const files = @import("project_files.zig");
const workers = @import("owned_worker.zig");
const Model = @import("model.zig").Model;
pub const Ticket = workers.Ticket;
pub const Artifact = jobs.firmware.Manifest;
pub const Runner = jobs.runner_artifact.Manifest;
pub const Plan = struct { version: u16 = 1, config: Config };
pub const Config = struct { board_id: [8]u8, build_board: []const u8, request: jobs.managed_build.Request };
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    file: files.Request,
    config: Config,
    environment: std.process.Environ.Map,
    captured: [32]u8,
    generation: u64,
    pub fn capture(model: *const Model, config: Config, environment: *const std.process.Environ.Map, generation: u64) !Request {
        if (generation == 0) return error.InvalidBuildGeneration;
        if (!std.mem.eql(u8, &model.board.id, &config.board_id) or !std.mem.eql(u8, config.build_board, config.request.selection.lock.board)) return error.BuildBoardMismatch;
        const digest = try model.id();
        var arena: std.heap.ArenaAllocator = .init(model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try p.owned_zon.clone(a, config);
        const path = try std.fs.path.join(a, &.{ owned.request.export_directory, &std.fmt.bytesToHex(digest, .lower) });
        var file = try files.Request.capture(model, .export_zig, path);
        errdefer file.deinit();
        const copied_environment = try environment.clone(a);
        return .{ .arena = arena, .file = file, .config = owned, .environment = copied_environment, .captured = digest, .generation = generation };
    }
    pub fn deinit(self: *Request) void {
        self.file.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io) !Prepared {
        var exported = try self.file.prepare(gpa, io);
        defer exported.deinit();
        var inventory = try p.export_inventory.read(p.owned_zon, gpa, io, self.file.path);
        defer inventory.deinit();
        const manifest = inventory.manifest;
        if (!std.mem.eql(u8, &manifest.snapshot_id, &self.captured) or !std.mem.eql(u8, &manifest.board_id, &self.config.board_id) or !std.mem.eql(u8, &manifest.profile_id, &self.file.loaded.snapshot.document.profile_id)) return error.ExportedIdentityMismatch;
        const identity = try p.snapshot.identity(gpa, self.file.loaded.snapshot, self.file.board);
        var request = self.config.request;
        request.export_directory = self.file.path;
        request.selection.project_digest = self.captured;
        request.selection.exported_source_digest = inventory.source_digest;
        request.selection.profile_id = manifest.profile_id;
        request.selection.identity_digest = identity.digest;
        var dir = try std.Io.Dir.cwd().openDir(io, self.file.path, .{ .iterate = true });
        defer dir.close(io);
        request.expected_export_tree = try jobs.preparation.treeDigest(gpa, io, dir);
        var job = try jobs.managed_build.Job.init(gpa, io, &self.environment, request);
        defer job.deinit();
        try job.start(job.captured.inputs);
        var result: jobs.Result = while (true) {
            if (job.poll()) |completion| break try completion;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        };
        defer result.deinit(gpa);
        const output_path = std.fs.path.dirname(std.fs.path.dirname(job.command.uf2_path).?).?;
        var output = try std.Io.Dir.cwd().openDir(io, output_path, .{});
        defer output.close(io);
        // Keep bounded compiler diagnostics in this job's fresh output even
        // when no artifact can be accepted. Never overwrite a producer's file.
        inline for (.{ .{ "build.stdout.log", result.process.stdout }, .{ "build.stderr.log", result.process.stderr } }) |log| {
            var file = try output.createFile(io, log[0], .{ .exclusive = true });
            defer file.close(io);
            try file.writeStreamingAll(io, log[1]);
        }
        var candidate = try job.finish(result, job.captured.inputs);
        errdefer candidate.deinit();
        var runner = try job.finishRunner(job.captured.inputs);
        defer runner.deinit();
        try jobs.sidecar.saveLock(gpa, io, output, candidate.inputs.lock, .create);
        try jobs.sidecar.saveReceipt(gpa, io, output, job.captured.receipt, .create);
        var runner_cache = try output.createDirPathOpen(io, "runners", .{});
        defer runner_cache.close(io);
        var frozen_runner = try jobs.runner_artifact.freeze(gpa, io, runner_cache, runner, job.captured.inputs);
        errdefer frozen_runner.deinit();
        try jobs.sidecar.saveRunner(gpa, io, output, frozen_runner, .create);
        try jobs.sidecar.saveManifest(gpa, io, output, candidate, .create);
        return .{ .ticket = .{ .generation = self.generation, .snapshot = self.captured }, .manifest = candidate, .runner = frozen_runner, .receipt = job.captured.receipt };
    }
};
pub const Prepared = struct {
    ticket: Ticket,
    manifest: ?jobs.firmware.Manifest,
    runner: ?Runner = null,
    receipt: jobs.build_provenance.Receipt,
    pub fn deinit(self: *Prepared) void {
        if (self.manifest) |*manifest| manifest.deinit();
        if (self.runner) |*runner| runner.deinit();
        self.* = undefined;
    }
    /// The caller advances generation on editor replacement or preparation changes.
    pub fn take(self: *Prepared, model: *const Model, current: Ticket) !jobs.firmware.Manifest {
        if (!std.meta.eql(self.ticket, current) or !std.mem.eql(u8, &current.snapshot, &(try model.id()))) return error.StaleBuild;
        const manifest = self.manifest orelse return error.BuildAlreadyCompleted;
        self.manifest = null;
        return manifest;
    }
    pub fn takeBundle(self: *Prepared, model: *const Model, current: Ticket) !Bundle {
        if (!std.meta.eql(self.ticket, current) or !std.mem.eql(u8, &current.snapshot, &(try model.id()))) return error.StaleBuild;
        const manifest = self.manifest orelse return error.BuildAlreadyCompleted;
        const runner = self.runner orelse return error.RunnerBuildNotCompleted;
        self.manifest = null;
        self.runner = null;
        return .{ .firmware = manifest, .runner = runner };
    }
};
pub const Bundle = struct {
    firmware: Artifact,
    runner: Runner,
    pub fn deinit(self: *Bundle) void {
        self.firmware.deinit();
        self.runner.deinit();
        self.* = undefined;
    }
};
pub const Owner = workers.Owner(Request, Prepared, error.InvalidBuildGeneration);
