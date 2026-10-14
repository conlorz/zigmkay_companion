const std = @import("std");
const jobs = @import("companion-jobs");
test "selected toolchain receipts own verified inputs and preserve future sidecars" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer {
        std.debug.print("selected receipts: cleaning temporary directory\n", .{});
        tmp.cleanup();
        std.debug.print("selected receipts: temporary directory cleaned\n", .{});
    }
    std.debug.print("selected receipts: creating distribution\n", .{});
    var distribution = try tmp.dir.createDirPathOpen(io, "distribution", .{});
    std.debug.print("selected receipts: distribution created\n", .{});
    defer {
        std.debug.print("selected receipts: closing distribution\n", .{});
        distribution.close(io);
        std.debug.print("selected receipts: distribution closed\n", .{});
    }
    const executable_name = if (@import("builtin").os.tag == .windows) "zig.exe" else "zig";
    const helper = try std.Io.Dir.cwd().readFileAlloc(io, @import("options").helper_path, t.allocator, .limited(64 * 1024 * 1024));
    defer t.allocator.free(helper);
    var executable = try distribution.createFileAtomic(io, executable_name, .{});
    defer executable.deinit(io);
    try executable.file.writeStreamingAll(io, helper);
    try executable.file.setPermissions(io, .executable_file);
    try executable.link(io);
    try distribution.writeFile(io, .{ .sub_path = "library.marker", .data = "selected standard library" });
    const root = try distribution.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(root);
    const compiler = try distribution.realPathFileAlloc(io, executable_name, t.allocator);
    defer t.allocator.free(compiler);
    const compiler_digest = jobs.firmware.digest(helper);
    std.debug.print("selected receipts: preparing toolchain\n", .{});
    var selected = try jobs.toolchain.prepare(t.allocator, io, .{ .compiler = compiler, .distribution = root, .expected_compiler = compiler_digest });
    defer selected.deinit();
    std.debug.print("selected receipts: verifying toolchain\n", .{});
    try selected.receipt.verify(t.allocator, io);
    std.debug.print("selected receipts: toolchain verified\n", .{});
    try t.expect(selected.receipt.kind == .selected_installation and selected.receipt.bundle_digest == null);
    const bytes = try selected.receipt.serialize(t.allocator);
    defer t.allocator.free(bytes);
    const parsed = try jobs.toolchain.Receipt.parse(t.allocator, bytes);
    defer parsed.deinit(t.allocator);
    try parsed.verify(t.allocator, io);
    try jobs.toolchain.save(t.allocator, io, tmp.dir, selected.receipt);
    const receipt_path = try tmp.dir.realPathFileAlloc(io, jobs.toolchain.filename, t.allocator);
    defer t.allocator.free(receipt_path);
    const source_root = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(source_root);
    const manifest_bytes = ".{ .dependencies = .{} }\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest_bytes });
    const manifest_path = try tmp.dir.realPathFileAlloc(io, "build.zig.zon", t.allocator);
    defer t.allocator.free(manifest_path);
    const manifests = [_]jobs.build_provenance.Manifest{.{ .name = "fixture-build", .path = manifest_path, .expected_digest = jobs.firmware.digest(manifest_bytes) }};
    std.debug.print("selected receipts: hashing source tree\n", .{});
    const source_tree = try jobs.preparation.treeDigest(t.allocator, io, tmp.dir);
    std.debug.print("selected receipts: source tree hashed\n", .{});
    var lock = try selected.receipt.targetLock(t.allocator, jobs.target_lock.fixture());
    lock.firmware_source_digest = source_tree;
    lock.dependency_digest = try jobs.build_provenance.closureDigest(t.allocator, &.{}, &manifests);
    lock.board_mapping_digest = jobs.firmware.digest("fixture board mapping");
    var inputs = jobs.build_provenance.Selection{
        .lock = lock,
        .compiler_path = compiler,
        .compiler_distribution_path = root,
        .expected_compiler_tree_digest = selected.receipt.tree_digest,
        .toolchain_receipt_path = receipt_path,
        .companion_path = source_root,
        .expected_companion_tree_digest = source_tree,
        .firmware_path = source_root,
        .dependencies = &.{},
        .manifests = &manifests,
        .board_mapping = "fixture board mapping",
        .project_digest = @splat(1),
        .exported_source_digest = @splat(2),
        .profile_id = @splat(3),
        .identity_digest = @splat(4),
    };
    std.debug.print("selected receipts: capturing provenance\n", .{});
    var captured = try jobs.build_provenance.capture(t.allocator, io, inputs);
    std.debug.print("selected receipts: provenance captured\n", .{});
    defer captured.deinit();
    try t.expectEqual(@as(u16, 2), captured.receipt.version);
    try t.expect(captured.receipt.compiler_kind == .selected_installation);
    try t.expectEqual(@as(jobs.firmware.Digest, @splat(0)), captured.receipt.compiler_bundle_digest);
    const locked_bytes = try lock.serialize(t.allocator);
    defer t.allocator.free(locked_bytes);
    const restored_lock = try jobs.target_lock.parse(t.allocator, locked_bytes);
    defer jobs.target_lock.free(t.allocator, restored_lock);
    try t.expectEqual(lock.digest(), restored_lock.digest());
    const captured_bytes = try captured.receipt.serialize(t.allocator);
    defer t.allocator.free(captured_bytes);
    const restored_receipt = try jobs.build_provenance.Receipt.parse(t.allocator, captured_bytes);
    try t.expectEqual(captured.receipt.digest(), restored_receipt.digest());
    std.debug.print("selected receipts: verifying provenance\n", .{});
    var verified = try jobs.build_provenance.verify(t.allocator, io, inputs, captured.receipt);
    defer verified.deinit();
    std.debug.print("selected receipts: provenance verified\n", .{});
    inputs.toolchain_receipt_path = null;
    try t.expectError(error.ToolchainReceiptRequired, jobs.build_provenance.capture(t.allocator, io, inputs));
    inputs.toolchain_receipt_path = receipt_path;
    inputs.compiler_bundle_path = receipt_path;
    try t.expectError(error.UnexpectedCompilerBundle, jobs.build_provenance.capture(t.allocator, io, inputs));
    inputs.compiler_bundle_path = null;
    inputs.lock.version = 1;
    try t.expectError(error.InvalidLegacyCompilerOrigin, jobs.build_provenance.capture(t.allocator, io, inputs));
    try distribution.writeFile(io, .{ .sub_path = "library.marker", .data = "changed library" });
    try t.expectError(error.CompilerDistributionChanged, selected.receipt.verify(t.allocator, io));
    try t.expectError(error.CompilerDigestMismatch, jobs.toolchain.prepare(t.allocator, io, .{ .compiler = compiler, .distribution = root, .expected_compiler = @splat(0) }));
    const bundle = try tmp.dir.realPathFileAlloc(io, jobs.toolchain.filename, t.allocator);
    defer t.allocator.free(bundle);
    try t.expectError(error.BundleDigestMismatch, jobs.toolchain.prepare(t.allocator, io, .{ .kind = .checked_bundle, .compiler = compiler, .distribution = root, .bundle = bundle, .expected_bundle = @splat(0) }));
    var checked = try jobs.toolchain.prepare(t.allocator, io, .{ .kind = .checked_bundle, .compiler = compiler, .distribution = root, .bundle = bundle, .expected_bundle = jobs.firmware.digest(bytes) });
    defer checked.deinit();
    try checked.receipt.verify(t.allocator, io);
    try t.expect(checked.receipt.kind == .checked_bundle);
    var future = selected.receipt;
    future.version = 2;
    var encoded: std.Io.Writer.Allocating = .init(t.allocator);
    defer encoded.deinit();
    try std.zon.stringify.serialize(future, .{}, &encoded.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = jobs.toolchain.filename, .data = encoded.written() });
    try t.expectError(error.UnsupportedToolchainReceipt, jobs.toolchain.save(t.allocator, io, tmp.dir, selected.receipt));
    const preserved = try tmp.dir.readFileAlloc(io, jobs.toolchain.filename, t.allocator, .limited(32 * 1024));
    defer t.allocator.free(preserved);
    try t.expectEqualStrings(encoded.written(), preserved);
    var elsewhere = try tmp.dir.createDirPathOpen(io, "elsewhere", .{});
    defer elsewhere.close(io);
    const outside = try elsewhere.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(outside);
    try t.expectError(error.CompilerOutsideDistribution, jobs.toolchain.prepare(t.allocator, io, .{ .compiler = compiler, .distribution = outside }));
}
test "asynchronous jobs own explicit environment before caller mutation" {
    const gpa = std.testing.allocator;
    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    try environment.put("ZIGMKAY_JOB_FIXTURE", "captured");
    var job = try jobs.Job.init(gpa, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "environment" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .environ_map = &environment,
    });
    defer job.deinit();
    try environment.put("ZIGMKAY_JOB_FIXTURE", "changed");
    var result = try jobs.run(gpa, std.testing.io, job.spec);
    defer result.deinit(gpa);
    try std.testing.expect(result.successful());
    try std.testing.expectEqualStrings("captured", result.process.stdout);
}
test "direct argv bounded output crash timeout cancellation and snapshot freshness" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const exe = @import("options").helper_path;
    var spec = jobs.Spec{ .argv = &.{ exe, "literal;$(not-a-shell)" }, .cwd = ".", .snapshot_id = @splat(1), .timeout_ms = 1000 };
    var result = try jobs.run(gpa, io, spec);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("literal;$(not-a-shell)", result.process.stdout);
    try std.testing.expect(result.successful());
    try std.testing.expect(!result.fresh(@splat(2)));
    spec.argv = &.{ exe, "crash" };
    var crashed = try jobs.run(gpa, io, spec);
    defer crashed.deinit(gpa);
    try std.testing.expect(!crashed.successful());
    spec.argv = &.{ exe, "flood" };
    try std.testing.expectError(error.StreamTooLong, jobs.run(gpa, io, spec));
    spec.argv = &.{ exe, "hang" };
    spec.timeout_ms = 50;
    try std.testing.expectError(error.Timeout, jobs.run(gpa, io, spec));
    spec.timeout_ms = 10000;
    var job = try jobs.Job.init(gpa, io, spec);
    defer job.deinit();
    try job.start();
    try std.Io.sleep(io, .fromMilliseconds(30), .awake);
    try std.testing.expect(job.poll() == null);
    job.cancel();
    try std.testing.expect(job.future == null);
    try std.testing.expectError(error.JobAlreadyStarted, job.start());
}

test "completed jobs transfer result ownership once and cannot restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var argument = [_]u8{ 'o', 'w', 'n', 'e', 'd' };
    var job = try jobs.Job.init(gpa, io, .{ .argv = &.{ @import("options").helper_path, &argument }, .cwd = ".", .snapshot_id = @splat(9) });
    defer job.deinit();
    argument[0] = 'x';
    try job.start();
    try std.testing.expectError(error.JobAlreadyStarted, job.start());
    const start = std.Io.Clock.awake.now(io);
    var result = while (true) {
        if (job.poll()) |completion| break try completion;
        if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > 5 * std.time.ns_per_s) return error.TestJobDidNotComplete;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    };
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("owned", result.process.stdout);
    try std.testing.expect(result.fresh(@splat(9)));
    try std.testing.expect(job.poll() == null);
    try std.testing.expectError(error.JobAlreadyStarted, job.start());
}

test "watchdog covers children that close both output pipes before hanging" {
    try std.testing.expectError(error.Timeout, jobs.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "closed-hang" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 50,
    }));
}

test "explicit compiler preparation validates bytes and exact version" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const compiler = try std.Io.Dir.cwd().realPathFileAlloc(io, @import("options").helper_path, gpa);
    defer gpa.free(compiler);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, compiler, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    const digest = jobs.firmware.digest(bytes);
    try jobs.preparation.verifyCompiler(gpa, io, compiler, digest);
    var wrong = digest;
    wrong[0] ^= 1;
    try std.testing.expectError(error.CompilerDigestMismatch, jobs.preparation.verifyCompiler(gpa, io, compiler, wrong));
    try std.testing.expectError(error.InvalidCompilerPath, jobs.preparation.verifyCompiler(gpa, io, "zig", digest));
}

test "runner session exchanges bounded literal frames and rejects multiline input" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session = try gpa.create(jobs.Session);
    defer gpa.destroy(session);
    session.* = .{};
    defer session.stop(io);
    try session.start(io, &.{ @import("options").helper_path, "echo" });
    const reply = try session.request(gpa, io, "literal;$(not-a-shell)", 1000);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("literal;$(not-a-shell)", reply);
    const maximum: [4096]u8 = @splat('x');
    const maximum_reply = try session.request(gpa, io, &maximum, 1000);
    defer gpa.free(maximum_reply);
    try std.testing.expectEqualSlices(u8, &maximum, maximum_reply);
    try std.testing.expectError(error.InvalidInputFrame, session.request(gpa, io, "one\ntwo", 1000));
    try std.testing.expect(session.child == null);
}

test "hung runner session timeout terminates the child and clears session state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session = try gpa.create(jobs.Session);
    defer gpa.destroy(session);
    session.* = .{};
    defer session.stop(io);
    try session.start(io, &.{ @import("options").helper_path, "hang" });
    try std.testing.expectError(error.Timeout, session.request(gpa, io, null, 30));
    try std.testing.expect(session.child == null);
}

test "artifact freshness includes compiler target optimization and dependency inputs" {
    var input = jobs.ArtifactInput{ .snapshot_id = @splat(1), .build_inputs_digest = @splat(2), .zig_version = "0.17.0", .target = "native", .optimize = "Debug" };
    const original = jobs.artifactKey(input);
    input.zig_version = "future";
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
    input.zig_version = "0.17.0";
    input.target = "thumb-freestanding-eabi";
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
    input.target = "native";
    input.optimize = "ReleaseSafe";
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
    input.optimize = "Debug";
    input.build_inputs_digest = @splat(3);
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
}

test "managed build freezes inputs rechecks sources and refuses failed stale or cancelled artifacts" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer {
        std.debug.print("managed build: cleaning temporary directory\n", .{});
        tmp.cleanup();
        std.debug.print("managed build: temporary directory cleaned\n", .{});
    }
    std.debug.print("managed build: creating compiler directory\n", .{});
    var distribution = try tmp.dir.createDirPathOpen(t.io, "compiler", .{ .open_options = .{ .iterate = true } });
    std.debug.print("managed build: compiler directory created\n", .{});
    defer {
        std.debug.print("managed build: closing distribution\n", .{});
        distribution.close(t.io);
        std.debug.print("managed build: distribution closed\n", .{});
    }
    const helper = try std.Io.Dir.cwd().readFileAlloc(t.io, @import("options").helper_path, t.allocator, .limited(64 * 1024 * 1024));
    defer t.allocator.free(helper);
    const name = if (@import("builtin").os.tag == .windows) "zig.exe" else "zig";
    var executable = try distribution.createFileAtomic(t.io, name, .{});
    defer executable.deinit(t.io);
    try executable.file.writeStreamingAll(t.io, helper);
    try executable.file.setPermissions(t.io, .executable_file);
    try executable.link(t.io);
    try distribution.writeFile(t.io, .{ .sub_path = "bundle.tar", .data = "fixture bundle" });
    var source = try tmp.dir.createDirPathOpen(t.io, "source", .{ .open_options = .{ .iterate = true } });
    defer source.close(t.io);
    try source.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    const root = try source.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const compiler_root = try distribution.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(compiler_root);
    const compiler = try distribution.realPathFileAlloc(t.io, name, t.allocator);
    defer t.allocator.free(compiler);
    const bundle = try distribution.realPathFileAlloc(t.io, "bundle.tar", t.allocator);
    defer t.allocator.free(bundle);
    std.debug.print("managed build: creating export directory\n", .{});
    var exported = try tmp.dir.createDirPathOpen(t.io, ".zig-cache/export", .{ .open_options = .{ .iterate = true } });
    std.debug.print("managed build: export directory created\n", .{});
    defer exported.close(t.io);
    try exported.writeFile(t.io, .{ .sub_path = "keymap.zig", .data = "frozen fixture export" });
    const export_path = try exported.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(export_path);
    const install = try std.fs.path.join(t.allocator, &.{ root, ".zig-cache/install" });
    defer t.allocator.free(install);
    std.debug.print("managed build: resolving source tree\n", .{});
    var graph = try jobs.package_resolution.resolve(t.allocator, t.io, .{ .roots = &.{.{ .name = "fixture", .directory = root }} });
    defer graph.deinit();
    std.debug.print("managed build: source tree resolved\n", .{});
    var lock = jobs.target_lock.fixture();
    lock.compiler_digest = jobs.firmware.digest(helper);
    lock.compiler_bundle_digest = jobs.firmware.digest("fixture bundle");
    lock.firmware_source_digest = graph.record.roots[0].tree_digest;
    lock.dependency_digest = graph.record.closure_digest;
    lock.board_mapping_digest = jobs.firmware.digest("mapping");
    std.debug.print("managed build: hashing compiler tree\n", .{});
    const compiler_tree = try jobs.preparation.treeDigest(t.allocator, t.io, distribution);
    std.debug.print("managed build: compiler tree hashed\n", .{});
    const selection = jobs.build_provenance.Selection{ .lock = lock, .compiler_path = compiler, .compiler_distribution_path = compiler_root, .compiler_bundle_path = bundle, .expected_compiler_tree_digest = compiler_tree, .companion_path = root, .expected_companion_tree_digest = lock.firmware_source_digest, .firmware_path = root, .dependencies = &.{}, .manifests = &.{}, .board_mapping = "mapping", .project_digest = @splat(1), .exported_source_digest = @splat(2), .profile_id = @splat(3), .identity_digest = @splat(4) };
    std.debug.print("managed build: hashing export tree\n", .{});
    const export_tree = try jobs.preparation.treeDigest(t.allocator, t.io, exported);
    std.debug.print("managed build: export tree hashed\n", .{});
    const request = jobs.managed_build.Request{ .resolution = graph.record, .selection = selection, .export_directory = export_path, .expected_export_tree = export_tree, .install_directory = install, .development_firmware = root, .timeout_ms = 5000 };
    var environment: std.process.Environ.Map = .init(t.allocator);
    defer environment.deinit();
    inline for (.{ "success", "missing-runner", "failed", "invalid", "missing", "hang" }) |mode| {
        try environment.put("ZIGMKAY_BUILD_FIXTURE", mode);
        std.debug.print("managed build ({s}): initializing job\n", .{mode});
        var job = try jobs.managed_build.Job.init(t.allocator, t.io, &environment, request);
        defer job.deinit();
        std.debug.print("managed build ({s}): job initialized\n", .{mode});
        try t.expectEqualStrings("--system", job.command.argv[job.command.argv.len - 2]);
        try t.expect(std.fs.path.isAbsolute(job.command.argv[job.command.argv.len - 1]));
        try t.expectEqualStrings(job.command.argv[job.command.argv.len - 1], job.process.spec.environ_map.?.get("ZIG_LOCAL_PKG_DIR").?);
        try t.expect(job.process.spec.environ_map.?.get("ZIG_LIB_DIR") != null);
        var changed = job.captured.inputs;
        changed.project_digest[0] ^= 1;
        try t.expectError(error.StaleBuild, job.start(changed));
        try t.expectError(error.RunnerBuildNotCompleted, job.finishRunner(job.captured.inputs));
        std.debug.print("managed build ({s}): starting job\n", .{mode});
        try job.start(job.captured.inputs);
        std.debug.print("managed build ({s}): job started\n", .{mode});
        if (comptime std.mem.eql(u8, mode, "hang")) {
            std.debug.print("managed build ({s}): cancelling job\n", .{mode});
            job.cancel();
            std.debug.print("managed build ({s}): job cancelled\n", .{mode});
            try t.expect(job.process.future == null and job.poll() == null);
            continue;
        }
        std.debug.print("managed build ({s}): waiting for job\n", .{mode});
        const deadline = std.Io.Clock.awake.now(t.io).toMilliseconds() + 10_000;
        var result: jobs.Result = while (true) {
            if (job.poll()) |completed| break try completed;
            if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.ManagedBuildTestTimeout;
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        };
        defer result.deinit(t.allocator);
        std.debug.print("managed build ({s}): job completed\n", .{mode});
        if (comptime std.mem.eql(u8, mode, "missing-runner")) {
            var manifest = try job.finish(result, job.captured.inputs);
            defer manifest.deinit();
            try t.expectError(error.FileNotFound, job.finishRunner(job.captured.inputs));
        } else if (comptime std.mem.eql(u8, mode, "success")) {
            var manifest = try job.finish(result, job.captured.inputs);
            defer manifest.deinit();
            try t.expectEqual(job.command.build_key, manifest.build_key);
            var runner = try job.finishRunner(job.captured.inputs);
            defer runner.deinit();
            try runner.verifyFile(t.allocator, t.io, job.captured.inputs);
            try t.expectEqual(jobs.runner_artifact.key(job.captured.inputs, jobs.runner_artifact.native_target), runner.record.build_key);
            try t.expectError(error.RunnerBuildNotCompleted, job.finishRunner(job.captured.inputs));
            try t.expectError(error.BuildNotCompleted, job.finish(result, job.captured.inputs));
        } else if (comptime std.mem.eql(u8, mode, "failed")) {
            try t.expectError(error.BuildFailed, job.finish(result, job.captured.inputs));
        } else if (comptime std.mem.eql(u8, mode, "missing")) {
            try t.expectError(error.FileNotFound, job.finish(result, job.captured.inputs));
        } else {
            std.debug.print("managed build (invalid): finishing invalid artifact\n", .{});
            try t.expectError(error.InvalidUf2Magic, job.finish(result, job.captured.inputs));
            std.debug.print("managed build (invalid): invalid artifact rejected\n", .{});
        }
    }
    std.debug.print("managed build: mode jobs complete; checking stale inputs\n", .{});
    try environment.put("ZIGMKAY_BUILD_FIXTURE", "success");
    std.debug.print("managed build (stale inputs): initializing job\n", .{});
    var completed_export = try jobs.managed_build.Job.init(t.allocator, t.io, &environment, request);
    defer completed_export.deinit();
    std.debug.print("managed build (stale inputs): starting job\n", .{});
    try completed_export.start(completed_export.captured.inputs);
    std.debug.print("managed build (stale inputs): waiting for job\n", .{});
    var completed_result: jobs.Result = while (true) {
        if (completed_export.poll()) |completed| break try completed;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    };
    defer completed_result.deinit(t.allocator);
    std.debug.print("managed build (stale inputs): job completed\n", .{});
    var changed_current = completed_export.captured.inputs;
    changed_current.project_digest[0] ^= 1;
    try t.expectError(error.StaleBuild, completed_export.finish(completed_result, changed_current));
    std.debug.print("managed build (changed export): initializing job\n", .{});
    var changed_export = try jobs.managed_build.Job.init(t.allocator, t.io, &environment, request);
    defer changed_export.deinit();
    std.debug.print("managed build (changed export): job initialized\n", .{});
    try exported.writeFile(t.io, .{ .sub_path = "keymap.zig", .data = "changed export" });
    try t.expectError(error.ExportedSourceChanged, changed_export.start(changed_export.captured.inputs));
    try t.expect(!changed_export.process.started);
    std.debug.print("managed build: assertions complete; releasing resources\n", .{});
}
