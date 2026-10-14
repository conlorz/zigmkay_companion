//! Application-owned source-build preparation. Never discovers or opens devices.
const std = @import("std");
const desktop = @import("desktop-core");
const jobs = @import("companion-jobs");
const p = @import("project");
const catalog = @import("catalog-project");
pub const Inputs = struct { compiler: []const u8, companion: []const u8, firmware_url: []const u8, firmware_hash: []const u8 };
pub fn enabled(fixture: bool, offline: bool, explicit_inputs: bool) bool {
    return !fixture and !offline and !explicit_inputs;
}
pub const setup_budget_ms = 300_000;
pub const Phase = enum(u8) { checking_cache, checking_compiler, fetching_firmware, resolving_packages, downloading, preparing_tools };
pub const Progress = struct {
    phase: std.atomic.Value(Phase) = .init(.checking_cache),
    started: std.atomic.Value(i64) = .init(0),
    changed: std.atomic.Value(i64) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    fn set(self: *Progress, io: std.Io, phase: Phase) void {
        if (self.phase.swap(phase, .monotonic) != phase) self.changed.store(nowMs(io), .monotonic);
    }
    fn remaining(self: *Progress, io: std.Io) !u32 {
        const elapsed = nowMs(io) - self.started.load(.monotonic);
        if (elapsed >= setup_budget_ms) return error.EditorPreparationTimedOut;
        return @intCast(setup_budget_ms - @max(0, elapsed));
    }
    pub fn message(self: *const Progress, allocator: std.mem.Allocator, now: i64) ![]u8 {
        const start = self.started.load(.monotonic);
        const elapsed = if (start == 0) 0 else @max(0, now - start) / 1000;
        const stage: []const u8 = switch (self.phase.load(.monotonic)) {
            .checking_cache => "checking saved inputs",
            .checking_compiler => "verifying Zig 0.17.0",
            .fetching_firmware => "preparing pinned firmware sources",
            .resolving_packages => "verifying dependencies",
            .downloading => "downloading a pinned dependency",
            .preparing_tools => "compiling Flash tools",
        };
        return std.fmt.allocPrint(allocator, "Setup: {s} | {d}s elapsed | {d} packages ready.{s}", .{ stage, elapsed, self.completed.load(.monotonic), if (elapsed >= 60) " Taking longer than expected. First setup needs downloads/tool compilation; failure offers Retry setup. Nothing will flash automatically." else " First use may take several minutes; subsequent launches reuse the cache." });
    }
};
fn nowMs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}
const ReportContext = struct { io: std.Io, progress: *Progress };
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    plan: desktop.build_worker.Plan,
    tools: jobs.flash_inputs.Record,
    cached: bool,
    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Saved = struct { version: u16 = 1, key: [32]u8, plan: desktop.build_worker.Plan, tools: jobs.flash_inputs.Record };
pub const Request = struct {
    gpa: std.mem.Allocator,
    progress: *Progress,
    arena: std.heap.ArenaAllocator,
    inputs: Inputs,
    cache: []const u8,
    selector: []const u8,
    board_id: [8]u8,
    environment: std.process.Environ.Map,
    captured: [32]u8,
    pub fn capture(gpa: std.mem.Allocator, inputs: Inputs, cache: []const u8, selector: []const u8, board_id: [8]u8, environment: *const std.process.Environ.Map) !Request {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_inputs = try p.owned_zon.clone(a, inputs);
        const owned_cache = try a.dupe(u8, cache);
        const owned_selector = try a.dupe(u8, selector);
        const owned_environment = try environment.clone(a);
        const progress = try gpa.create(Progress);
        progress.* = .{};
        return .{ .gpa = gpa, .progress = progress, .arena = arena, .inputs = owned_inputs, .cache = owned_cache, .selector = owned_selector, .board_id = board_id, .environment = owned_environment, .captured = jobs.firmware.digest(&board_id) };
    }
    pub fn deinit(self: *Request) void {
        self.gpa.destroy(self.progress);
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io) !Prepared {
        self.progress.started.store(nowMs(io), .monotonic);
        self.progress.changed.store(nowMs(io), .monotonic);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const compiler = try std.Io.Dir.realPathFileAbsoluteAlloc(io, self.inputs.compiler, a);
        const companion = try std.Io.Dir.realPathFileAbsoluteAlloc(io, self.inputs.companion, a);
        const root = try std.fs.path.join(a, &.{ self.cache, "editor-environment" });
        var output = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
        defer output.close(io);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("automatic-editor-environment-v3-no-package-audits");
        hash.update(compiler);
        hash.update(companion);
        hash.update(self.selector);
        hash.update(&self.board_id);
        hash.update(self.inputs.firmware_url);
        hash.update(self.inputs.firmware_hash);
        inline for (.{ "build.zig", "build.zig.zon" }) |name| {
            const path = try std.fs.path.join(a, &.{ companion, name });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2 * 1024 * 1024));
            defer gpa.free(bytes);
            hash.update(bytes);
        }
        // Fast startup uses the admitted compiler's file identity, not another
        // full binary/distribution audit. Cold preparation verifies all bytes.
        const compiler_stat = try std.Io.Dir.cwd().statFile(io, compiler, .{});
        var stamp: std.Io.Writer.Allocating = .init(gpa);
        defer stamp.deinit();
        try std.zon.stringify.serialize(.{ .inode = compiler_stat.inode, .size = compiler_stat.size, .mtime = compiler_stat.mtime.toNanoseconds(), .ctime = compiler_stat.ctime.toNanoseconds() }, .{}, &stamp.writer);
        hash.update(stamp.written());
        const key = hash.finalResult();
        const filename = try std.fmt.allocPrint(a, "{s}.zon", .{std.fmt.bytesToHex(key, .lower)});
        if (try load(gpa, io, output, filename, key)) |saved| {
            defer p.owned_zon.free(gpa, saved);
            const plan = try p.owned_zon.clone(a, saved.plan);
            const tools = try p.owned_zon.clone(a, saved.tools);
            return .{ .arena = arena, .plan = plan, .tools = tools, .cached = true };
        }
        self.progress.set(io, .checking_compiler);
        var selected = try jobs.toolchain.prepare(gpa, io, .{ .compiler = compiler, .distribution = std.fs.path.dirname(compiler).? });
        defer selected.deinit();
        var compiler_session = try jobs.package_cache.CompilerSession.init(gpa, io, selected.receipt);
        compiler_session.audit_packages = false;
        const receipt_name = try std.fmt.allocPrint(a, "compiler-{s}.zon", .{std.fmt.bytesToHex(selected.receipt.compiler_digest, .lower)});
        const receipt = try selected.receipt.serialize(gpa);
        defer gpa.free(receipt);
        try write(io, output, receipt_name, receipt);
        const packages_path = try std.fs.path.join(a, &.{ root, "packages" });
        var packages = try std.Io.Dir.cwd().createDirPathOpen(io, packages_path, .{});
        defer packages.close(io);
        var environment = try self.environment.clone(a);
        try environment.put("ZIG_GLOBAL_CACHE_DIR", packages_path);
        try environment.put("ZIG_LOCAL_PKG_DIR", try std.fs.path.join(a, &.{ packages_path, "p" }));
        try environment.put("ZIG_LIB_DIR", try std.fs.path.join(a, &.{ selected.receipt.distribution, "lib" }));
        const origin = try jobs.package_manifest.archive(a, self.inputs.firmware_url);
        self.progress.set(io, .fetching_firmware);
        var firmware = (try jobs.package_cache.loadWithAudit(gpa, io, packages, self.inputs.firmware_hash, false)) orelse try compiler_session.acquire(gpa, io, &environment, packages, self.inputs.firmware_hash, .{ .download = origin.url });
        defer firmware.deinit();
        var inactive: std.ArrayList(jobs.package_resolution.InactiveLazy) = .empty;
        try inactivePins(a, gpa, io, companion, &inactive);
        try inactivePins(a, gpa, io, firmware.source.source_path, &inactive);
        const manifest_path = try std.fs.path.join(a, &.{ companion, "build.zig.zon" });
        const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1024 * 1024));
        defer gpa.free(manifest_bytes);
        var manifest = try jobs.package_manifest.parse(gpa, manifest_bytes);
        defer manifest.deinit();
        // This MVP builds RP2040 boards, not every unrelated MicroZig port.
        for (manifest.dependencies) |dependency| if (std.mem.eql(u8, dependency.name, "microzig")) {
            const micro_origin = try jobs.package_manifest.archive(a, dependency.url.?);
            var microzig = (try jobs.package_cache.loadWithAudit(gpa, io, packages, dependency.package_hash.?, false)) orelse try compiler_session.acquire(gpa, io, &environment, packages, dependency.package_hash.?, .{ .download = micro_origin.url });
            defer microzig.deinit();
            try inactivePins(a, gpa, io, microzig.source.source_path, &inactive);
        };
        _ = try self.progress.remaining(io);
        self.progress.set(io, .resolving_packages);
        var report_context: ReportContext = .{ .io = io, .progress = self.progress };
        var resolution = try jobs.package_preparation.prepareWithSession(gpa, io, &environment, selected.receipt, packages, .{
            .allow_network = true,
            .options = .{ .roots = &.{ .{ .name = "companion", .directory = companion }, .{ .name = "firmware", .directory = firmware.source.source_path } }, .cache_directory = packages_path, .build_profile = "editor-rp2040", .inactive_lazy = inactive.items, .audit_packages = false },
        }, .{ .context = &report_context, .update = reportPackage, .checkpoint = checkBudget }, &compiler_session);
        defer resolution.deinit();
        var board = try resolveBoard(gpa, self.selector, self.board_id);
        defer board.deinit();
        var mapping: std.Io.Writer.Allocating = .init(gpa);
        defer mapping.deinit();
        try std.zon.stringify.serialize(.{ .version = @as(u16, 1), .selector = board.entry.selector, .board = board.board, .processing_digest = board.entry.processing_digest, .index_digest = board.entry.index_digest }, .{}, &mapping.writer);
        var built = try desktop.build_environment.prepare(gpa, io, .{
            .resolution = resolution.record,
            .source_cache = packages_path,
            .compiler_receipt = selected.receipt,
            .compiler_receipt_path = try std.fs.path.join(a, &.{ root, receipt_name }),
            .companion_root = "companion",
            .firmware_root = "firmware",
            .firmware_revision = origin.revision,
            .source_kind = .published,
            .board_id = board.board.id,
            .build_board = self.selector,
            .board_mapping = mapping.written(),
            .export_directory = try std.fs.path.join(a, &.{ root, "exports" }),
            .install_directory = try std.fs.path.join(a, &.{ root, "builds" }),
        });
        defer built.deinit();
        // Network access is limited to immutable pins. Missing build-script lazy
        // packages can be fetched by Zig into this same owned package cache.
        built.plan.config.request.dependency_access = .allow_pinned_fetch;
        built.plan.config.request.selection.dependency_access = .allow_pinned_fetch;
        if (built.plan.config.request.prepared) |*prepared| {
            prepared.receipt.dependency_access = .allow_pinned_fetch;
            prepared.inputs.build_inputs_digest = prepared.receipt.digest();
        }
        const tools_prefix = try std.fs.path.join(a, &.{ root, "tools", origin.revision });
        const tools_path = try std.fs.path.join(a, &.{ tools_prefix, jobs.flash_inputs.tools_name });
        // The firmware exports picotool's named path during configure. Admit
        // this lazy root first. Zig must fetch its non-lazy transitive pins from
        // their original URLs: a GitHub export archive is not always identical
        // to the pinned Git package (notably libusb's export-ignore files).
        const tool_origin = try jobs.package_manifest.archive(a, "git+https://github.com/allyourcodebase/picotool.git#" ++ jobs.flash_inputs.picotool_revision);
        var tool_source = (try jobs.package_cache.loadWithAudit(gpa, io, packages, jobs.flash_inputs.picotool_package_hash, false)) orelse try compiler_session.acquire(gpa, io, &environment, packages, jobs.flash_inputs.picotool_package_hash, .{ .download = tool_origin.url });
        defer tool_source.deinit();
        self.progress.set(io, .preparing_tools);
        // Zig 0.17 resolves nested local package dependencies relative to the
        // build root; an absolute package-directory spelling is rejected.
        try environment.put("ZIG_LOCAL_PKG_DIR", try std.fs.path.relativeAlloc(a, companion, &environment, companion, try std.fs.path.join(a, &.{ packages_path, "p" })));
        var result = try jobs.run(gpa, io, .{ .argv = &.{ compiler, "build", "prepare-picotool", "-Dflash-tools=true", "-Dflash-source-kind=published", try std.fmt.allocPrint(a, "-Dfirmware-revision={s}", .{origin.revision}), "-p", tools_prefix, "-j2" }, .cwd = companion, .snapshot_id = key, .timeout_ms = try self.progress.remaining(io), .environ_map = &environment, .isolated_group = @import("builtin").os.tag != .windows });
        defer result.deinit(gpa);
        try write(io, output, "preparation.stdout.log", result.process.stdout);
        try write(io, output, "preparation.stderr.log", result.process.stderr);
        if (!result.successful()) return error.FlashToolPreparationFailed;
        const tools_bytes = try std.Io.Dir.cwd().readFileAlloc(io, tools_path, gpa, .limited(16 * 1024));
        defer gpa.free(tools_bytes);
        var tools = try jobs.flash_inputs.Tools.parse(gpa, tools_bytes);
        defer tools.deinit();
        try tools.verify(gpa, io);
        const saved = Saved{ .key = key, .plan = built.plan, .tools = tools.record };
        var encoded: std.Io.Writer.Allocating = .init(gpa);
        defer encoded.deinit();
        try std.zon.stringify.serializeMaxDepth(saved, .{}, &encoded.writer, 64);
        try write(io, output, filename, encoded.written());
        const plan = try p.owned_zon.clone(a, built.plan);
        const tool_record = try p.owned_zon.clone(a, tools.record);
        return .{ .arena = arena, .plan = plan, .tools = tool_record, .cached = false };
    }
};
fn inactivePins(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: []const u8, inactive: *std.ArrayList(jobs.package_resolution.InactiveLazy)) !void {
    const path = try std.fs.path.join(a, &.{ root, "build.zig.zon" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    var manifest = try jobs.package_manifest.parse(gpa, bytes);
    defer manifest.deinit();
    for (manifest.dependencies) |dependency| {
        if (!dependency.lazy or dependency.package_hash == null) continue;
        const unused = std.mem.eql(u8, dependency.name, "freetype") or std.mem.eql(u8, dependency.name, "sdl3") or std.mem.eql(u8, dependency.name, "picotool") or (std.mem.startsWith(u8, dependency.name, "port/") and !std.mem.eql(u8, dependency.name, "port/raspberrypi/rp2xxx"));
        if (!unused) continue;
        var duplicate = false;
        for (inactive.items) |entry| if (std.mem.eql(u8, entry.package_hash, dependency.package_hash.?)) {
            duplicate = true;
        };
        if (!duplicate) try inactive.append(a, .{ .dependency = try a.dupe(u8, dependency.name), .package_hash = try a.dupe(u8, dependency.package_hash.?) });
    }
}
fn resolveBoard(gpa: std.mem.Allocator, selector: []const u8, board_id: [8]u8) !catalog.OwnedBoard {
    var board = if (std.mem.eql(u8, &board_id, &p.profiles.board.id)) curated: {
        var loaded = try p.profiles.create(gpa, .qwerty);
        defer loaded.deinit();
        break :curated try catalog.OwnedBoard.fromDocument(gpa, loaded.snapshot.document);
    } else try catalog.OwnedBoard.init(gpa, selector);
    errdefer board.deinit();
    if (!std.mem.eql(u8, &board.board.id, &board_id) or !std.mem.eql(u8, board.entry.selector, selector)) return error.BuildBoardMismatch;
    return board;
}
fn reportPackage(context: *anyopaque, hash: []const u8, phase: jobs.package_preparation.Phase) void {
    const report: *ReportContext = @ptrCast(@alignCast(context));
    report.progress.set(report.io, if (phase == .downloading) .downloading else .resolving_packages);
    if (phase == .cached or phase == .verified) _ = report.progress.completed.fetchAdd(1, .monotonic);
    std.log.info("editor preparation: {s} {s}", .{ @tagName(phase), hash });
}
fn checkBudget(context: *anyopaque) !void {
    const report: *ReportContext = @ptrCast(@alignCast(context));
    _ = try report.progress.remaining(report.io);
}
fn write(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}
fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, key: [32]u8) !?Saved {
    const bytes = dir.readFileAlloc(io, name, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    const saved = try p.owned_zon.parse(Saved, gpa, text);
    errdefer p.owned_zon.free(gpa, saved);
    if (saved.version != 1 or saved.plan.version != 1 or !std.mem.eql(u8, &saved.key, &key)) return error.UnsupportedAutomaticBuildEnvironment;
    var tools = try jobs.flash_inputs.Tools.clone(gpa, saved.tools);
    defer tools.deinit();
    try tools.verify(gpa, io);
    return saved;
}
pub const Owner = desktop.owned_worker.Owner(Request, Prepared, error.InvalidPreparationGeneration);

test "only normal unconfigured startup automatically prepares" {
    try std.testing.expect(enabled(false, false, false));
    try std.testing.expect(!enabled(true, false, false));
    try std.testing.expect(!enabled(false, true, false));
    try std.testing.expect(!enabled(false, false, true));
}

test "progress reports phase elapsed time and a warning without inventing an ETA" {
    var progress: Progress = .{};
    progress.started.store(1000, .monotonic);
    progress.phase.store(.downloading, .monotonic);
    progress.completed.store(3, .monotonic);
    const text = try progress.message(std.testing.allocator, 61_000);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "downloading") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "60s elapsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3 packages ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Taking longer than expected") != null);
    progress.started.store(nowMs(std.testing.io) - setup_budget_ms, .monotonic);
    try std.testing.expectError(error.EditorPreparationTimedOut, progress.remaining(std.testing.io));
}

test "curated and catalog LK7 environments preserve distinct document contracts" {
    const gpa = std.testing.allocator;
    var curated = try resolveBoard(gpa, "lk7", p.profiles.board.id);
    defer curated.deinit();
    try std.testing.expectEqualStrings(p.profiles.board.physical_layout, curated.board.physical_layout);
    var indexed = try catalog.OwnedBoard.init(gpa, "lk7");
    defer indexed.deinit();
    var resolved = try resolveBoard(gpa, "lk7", indexed.board.id);
    defer resolved.deinit();
    try std.testing.expectEqualStrings(indexed.board.physical_layout, resolved.board.physical_layout);
    try std.testing.expect(!std.mem.eql(u8, &curated.board.id, &resolved.board.id));
    try std.testing.expectError(error.BuildBoardMismatch, resolveBoard(gpa, "lk7", @splat(7)));
}

test "automatic request owns inputs and environment without starting work" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("AUTOMATIC_TEST", "captured");
    var selector = [_]u8{ 'l', 'k', '7' };
    var request = try Request.capture(gpa, .{ .compiler = "/compiler/zig", .companion = "/source", .firmware_url = "pinned", .firmware_hash = "hash" }, "/cache", &selector, @splat(1), &environment);
    defer request.deinit();
    selector[0] = 'x';
    try environment.put("AUTOMATIC_TEST", "changed");
    try std.testing.expectEqualStrings("lk7", request.selector);
    try std.testing.expectEqualStrings("captured", request.environment.get("AUTOMATIC_TEST").?);
    try std.testing.expectEqual(jobs.firmware.digest(&@as([8]u8, @splat(1))), request.captured);
}

test "missing automatic receipt is a cache miss and does not run preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(try load(std.testing.allocator, std.testing.io, tmp.dir, "absent.zon", @splat(1)) == null);
}

test "automatic preparation fails before acquisition when its compiler is unavailable" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const compiler = try std.fs.path.join(gpa, &.{ root, "missing-compiler" });
    defer gpa.free(compiler);
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var request = try Request.capture(gpa, .{ .compiler = compiler, .companion = root, .firmware_url = "pinned", .firmware_hash = "hash" }, root, "lk7", @splat(1), &environment);
    defer request.deinit();
    try std.testing.expectError(error.FileNotFound, request.prepare(gpa, std.testing.io));
}

test "warm receipt reload verifies tools and rejects changed executables" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "picotool", .data = "tool bytes" });
    const wrapper = try std.fs.path.join(gpa, &.{ root, "wrapper" });
    defer gpa.free(wrapper);
    const tool = try std.fs.path.join(gpa, &.{ root, "picotool" });
    defer gpa.free(tool);
    var tools = try jobs.flash_inputs.Tools.capture(gpa, io, "e122f7502df4ad58e831f0b37439085774b670cb", @splat(1), .published, wrapper, tool);
    defer tools.deinit();
    const plan: desktop.build_worker.Plan = .{ .config = .{
        .board_id = "board123".*,
        .build_board = "lk7",
        .request = .{
            .resolution = .{ .roots = &.{}, .dependencies = &.{}, .manifests = &.{}, .sources = &.{}, .overrides = &.{}, .closure_digest = @splat(1), .resolution_digest = @splat(1) },
            .selection = .{ .lock = jobs.target_lock.fixture(), .compiler_path = wrapper, .compiler_distribution_path = root, .compiler_bundle_path = wrapper, .expected_compiler_tree_digest = @splat(1), .companion_path = root, .expected_companion_tree_digest = @splat(1), .firmware_path = root, .dependencies = &.{}, .manifests = &.{}, .board_mapping = "mapping", .project_digest = @splat(1), .exported_source_digest = @splat(1), .profile_id = @splat(1), .identity_digest = @splat(1) },
            .export_directory = root,
            .expected_export_tree = @splat(1),
            .install_directory = root,
        },
    } };
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(Saved{ .key = @splat(7), .plan = plan, .tools = tools.record }, .{}, &encoded.writer, 64);
    try write(io, tmp.dir, "cached.zon", encoded.written());
    const saved = (try load(gpa, io, tmp.dir, "cached.zon", @splat(7))).?;
    defer p.owned_zon.free(gpa, saved);
    try std.testing.expectEqualStrings("lk7", saved.plan.config.build_board);
    try std.testing.expectError(error.UnsupportedAutomaticBuildEnvironment, load(gpa, io, tmp.dir, "cached.zon", @splat(8)));
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "changed bytes" });
    try std.testing.expectError(error.WrapperChanged, load(gpa, io, tmp.dir, "cached.zon", @splat(7)));
}

test "automatic RP2040 profile keeps selected port and ignores only lazy unrelated pins" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes =
        \\.{ .dependencies = .{
        \\ .@"port/raspberrypi/rp2xxx" = .{ .lazy = true, .url = "https://example.com/rp.tar.gz", .hash = "rp-0.1.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        \\ .@"port/other/mcu" = .{ .lazy = true, .url = "https://example.com/other.tar.gz", .hash = "other-0.1.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        \\ .picotool = .{ .lazy = true, .url = "https://example.com/tool.tar.gz", .hash = "tool-0.1.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        \\ .required = .{ .url = "https://example.com/required.tar.gz", .hash = "required-0.1.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        \\} }
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig.zon", .data = bytes });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var inactive: std.ArrayList(jobs.package_resolution.InactiveLazy) = .empty;
    try inactivePins(arena.allocator(), gpa, std.testing.io, root, &inactive);
    try std.testing.expectEqual(@as(usize, 2), inactive.items.len);
}
