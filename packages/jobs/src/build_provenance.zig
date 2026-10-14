//! Explicit offline capture of actual build inputs. Archive hashes and unpacked
//! tree hashes are distinct. The caller supplies the complete resolved closure;
//! this module neither resolves packages nor infers dependencies from URLs.
const std = @import("std");
const firmware = @import("firmware.zig");
const preparation = @import("preparation.zig");
const target = @import("target_lock.zig");
const sources = @import("source_files.zig");
pub const Digest = firmware.Digest;
pub const DependencyAccess = enum { offline, allow_pinned_fetch };
pub const Dependency = struct {
    name: []const u8,
    revision: []const u8 = "",
    package_hash: []const u8,
    source_path: []const u8,
    expected_tree_digest: Digest,
    identity: enum { git_revision, package_content } = .git_revision,
};
pub const Manifest = struct { name: []const u8, path: []const u8, expected_digest: Digest };
pub const Receipt = struct {
    version: u16 = 1,
    lock_digest: Digest,
    compiler_digest: Digest,
    compiler_bundle_digest: Digest,
    compiler_tree_digest: Digest,
    companion_tree_digest: Digest,
    firmware_tree_digest: Digest,
    dependency_closure_digest: Digest,
    board_mapping_digest: Digest,
    compiler_version_verified: bool,
    compiler_kind: target.CompilerKind = .checked_bundle,
    toolchain_receipt_digest: Digest = @splat(0),
    dependency_access: DependencyAccess = .offline,
    pub fn validate(self: Receipt) !void {
        if (self.version != 1 and self.version != 2) return error.UnsupportedReceiptVersion;
        const zero: Digest = @splat(0);
        if (self.version == 1 and (self.compiler_kind != .checked_bundle or !same(self.toolchain_receipt_digest, zero))) return error.InvalidLegacyCompilerOrigin;
        if (self.version == 2 and (same(self.compiler_tree_digest, zero) or same(self.toolchain_receipt_digest, zero))) return error.MissingCompilerOrigin;
        if (self.compiler_kind == .selected_installation and (!same(self.compiler_bundle_digest, zero) or same(self.toolchain_receipt_digest, zero))) return error.InvalidSelectedCompilerOrigin;
        if (self.version == 2 and self.compiler_kind == .checked_bundle and same(self.compiler_bundle_digest, zero)) return error.InvalidCheckedCompilerOrigin;
    }
    pub fn digest(self: Receipt) Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(if (self.version == 1) "zigmkay-preparation-receipt-v1\x00" else "zigmkay-preparation-receipt-v2\x00");
        var version_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &version_bytes, self.version, .little);
        hash.update(&version_bytes);
        inline for (.{ "lock_digest", "compiler_digest", "compiler_bundle_digest", "compiler_tree_digest", "companion_tree_digest", "firmware_tree_digest", "dependency_closure_digest", "board_mapping_digest" }) |name| hash.update(&@field(self, name));
        hash.update(&.{@intFromBool(self.compiler_version_verified)});
        if (self.version == 2) {
            hash.update(&.{@backingInt(self.compiler_kind)});
            hash.update(&self.toolchain_receipt_digest);
        }
        if (self.dependency_access == .allow_pinned_fetch) {
            hash.update("zigmkay-dependency-access-v1\x00");
            hash.update(&.{@backingInt(self.dependency_access)});
        }
        return hash.finalResult();
    }
    pub fn serialize(self: Receipt, gpa: std.mem.Allocator) ![]u8 {
        try self.validate();
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        if (self.version == 1 and self.dependency_access == .offline) {
            var legacy: LegacyReceipt = undefined;
            inline for (@typeInfo(LegacyReceipt).@"struct".field_names) |name| @field(legacy, name) = @field(self, name);
            try std.zon.stringify.serializeMaxDepth(legacy, .{}, &writer.writer, 8);
        } else if (self.dependency_access == .offline) {
            var legacy: OfflineReceipt = undefined;
            inline for (@typeInfo(OfflineReceipt).@"struct".field_names) |name| @field(legacy, name) = @field(self, name);
            try std.zon.stringify.serializeMaxDepth(legacy, .{}, &writer.writer, 8);
        } else try std.zon.stringify.serializeMaxDepth(self, .{}, &writer.writer, 8);
        return writer.toOwnedSlice();
    }
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Receipt {
        if (bytes.len > 16 * 1024) return error.ReceiptTooLarge;
        const text = try gpa.dupeSentinel(u8, bytes, 0);
        defer gpa.free(text);
        const receipt = try @import("owned-zon").parse(Receipt, gpa, text);
        try receipt.validate();
        return receipt;
    }
};
const LegacyReceipt = struct {
    version: u16,
    lock_digest: Digest,
    compiler_digest: Digest,
    compiler_bundle_digest: Digest,
    compiler_tree_digest: Digest,
    companion_tree_digest: Digest,
    firmware_tree_digest: Digest,
    dependency_closure_digest: Digest,
    board_mapping_digest: Digest,
    compiler_version_verified: bool,
};
const OfflineReceipt = struct {
    version: u16,
    lock_digest: Digest,
    compiler_digest: Digest,
    compiler_bundle_digest: Digest,
    compiler_tree_digest: Digest,
    companion_tree_digest: Digest,
    firmware_tree_digest: Digest,
    dependency_closure_digest: Digest,
    board_mapping_digest: Digest,
    compiler_version_verified: bool,
    compiler_kind: target.CompilerKind,
    toolchain_receipt_digest: Digest,
};
pub const Selection = struct {
    lock: target.Lock,
    compiler_path: []const u8,
    compiler_distribution_path: []const u8,
    compiler_bundle_path: ?[]const u8 = null,
    toolchain_receipt_path: ?[]const u8 = null,
    expected_compiler_tree_digest: Digest,
    companion_path: []const u8,
    expected_companion_tree_digest: Digest,
    firmware_path: []const u8,
    dependencies: []const Dependency,
    manifests: []const Manifest,
    board_mapping: []const u8,
    /// Only this explicit opt-in executes the already hash-verified compiler.
    verify_compiler_version: bool = false,
    project_digest: Digest,
    exported_source_digest: Digest,
    profile_id: [8]u8,
    identity_digest: [16]u8,
    dependency_access: DependencyAccess = .offline,
};
pub const Captured = struct {
    arena: std.heap.ArenaAllocator,
    inputs: firmware.Inputs,
    receipt: Receipt,
    pub fn deinit(self: *Captured) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn absolute(value: []const u8) !void {
    if (!std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidProvenancePath;
}
fn hashFile(gpa: std.mem.Allocator, io: std.Io, filename: []const u8, limit: usize) !Digest {
    try absolute(filename);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, filename, gpa, .limited(limit));
    defer gpa.free(bytes);
    return firmware.digest(bytes);
}
fn framed(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    hash.update(&size);
    hash.update(bytes);
}
fn immutableRevision(value: []const u8) !void {
    if (value.len != 40) return error.FloatingDependencyRevision;
    for (value) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.FloatingDependencyRevision;
}
fn validName(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidDependencyName;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidDependencyName;
}
pub fn validatePackageHash(value: []const u8) !void {
    if (value.len < 46 or value.len > 256 or value[value.len - 45] != '-') return error.InvalidDependencyPackageHash;
    for (value, 0..) |c, offset| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and !((c == '.' or c == '+') and offset < value.len - 45)) return error.InvalidDependencyPackageHash;
}
fn validateClosure(dependencies: []const Dependency, manifests: []const Manifest) !void {
    if (dependencies.len > 256 or manifests.len == 0 or manifests.len > 256) return error.InvalidDependencyClosure;
    for (dependencies, 0..) |dep, index| {
        try validName(dep.name);
        switch (dep.identity) {
            .git_revision => try immutableRevision(dep.revision),
            .package_content => if (dep.revision.len != 0) return error.UnexpectedContentRevision,
        }
        try absolute(dep.source_path);
        // Zig package hash (including its content hash) is mandatory. Strings
        // such as branch names and release tags cannot identify a package.
        try validatePackageHash(dep.package_hash);
        for (dependencies[0..index]) |old| if (std.mem.eql(u8, old.name, dep.name)) return error.DuplicateDependency;
    }
    for (manifests, 0..) |manifest, index| {
        try validName(manifest.name);
        try absolute(manifest.path);
        for (manifests[0..index]) |old| if (std.mem.eql(u8, old.name, manifest.name) or std.mem.eql(u8, old.path, manifest.path)) return error.DuplicateDependencyManifest;
    }
}
/// Canonical closure contract: lexical descriptor names, immutable package IDs,
/// expected actual source tree digests, and exact dependency manifest bytes.
/// Paths are deliberately excluded, allowing relocation of identical inputs.
pub fn closureDigest(gpa: std.mem.Allocator, dependencies: []const Dependency, manifests: []const Manifest) !Digest {
    try validateClosure(dependencies, manifests);
    const deps = try gpa.dupe(Dependency, dependencies);
    defer gpa.free(deps);
    const records = try gpa.dupe(Manifest, manifests);
    defer gpa.free(records);
    std.mem.sort(Dependency, deps, {}, struct {
        fn less(_: void, a: Dependency, b: Dependency) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    std.mem.sort(Manifest, records, {}, struct {
        fn less(_: void, a: Manifest, b: Manifest) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var content_identity = false;
    for (deps) |dep| if (dep.identity == .package_content) {
        content_identity = true;
    };
    hash.update(if (content_identity) "zigmkay-dependency-closure-v2\x00" else "zigmkay-dependency-closure-v1\x00");
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, deps.len, .little);
    hash.update(&count);
    for (deps) |dep| {
        if (content_identity) hash.update(&.{@backingInt(dep.identity)});
        framed(&hash, dep.name);
        framed(&hash, dep.revision);
        framed(&hash, dep.package_hash);
        hash.update(&dep.expected_tree_digest);
    }
    std.mem.writeInt(u64, &count, records.len, .little);
    hash.update(&count);
    for (records) |record| {
        framed(&hash, record.name);
        hash.update(&record.expected_digest);
    }
    return hash.finalResult();
}
fn sourceTree(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) !Digest {
    try absolute(directory);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    return preparation.treeDigest(gpa, io, dir);
}
/// Same source-tree framing, with distribution-sized limits. Hidden compiler
/// files are included, VCS/build caches excluded, and all symlinks rejected.
pub fn compilerTreeDigest(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) !Digest {
    try absolute(directory);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    const files = try sources.collect(gpa, io, dir, .{ .excluded = struct {
        fn excluded(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
            if (kind != .directory) return false;
            return preparation.excludedDirectoryName(name);
        }
    }.excluded, .max_files = 100_000 });
    defer sources.free(gpa, files);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-source-tree-v1\x00");
    var total: usize = 0;
    for (files) |file| {
        if (file.kind != .file) return error.UnsupportedSourceKind;
        const bytes = try dir.readFileAlloc(io, file.path, gpa, .limited(512 * 1024 * 1024));
        defer gpa.free(bytes);
        total += bytes.len;
        if (total > 2 * 1024 * 1024 * 1024) return error.CompilerTreeTooLarge;
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, file.path.len, .little);
        hash.update(&size);
        for (file.path) |c| hash.update(&.{if (c == '\\') '/' else c});
        framed(&hash, bytes);
    }
    return hash.finalResult();
}
fn same(actual: Digest, expected: Digest) bool {
    return std.mem.eql(u8, &actual, &expected);
}
/// Re-read every selected input and compare the complete receipt. No execution
/// occurs unless Selection.verify_compiler_version is explicitly enabled.
pub fn verify(gpa: std.mem.Allocator, io: std.Io, selected: Selection, expected: Receipt) !Captured {
    try expected.validate();
    var current = try capture(gpa, io, selected);
    errdefer current.deinit();
    if (!same(current.receipt.digest(), expected.digest())) return error.PreparationReceiptChanged;
    return current;
}
pub fn capture(gpa: std.mem.Allocator, io: std.Io, selected: Selection) !Captured {
    try selected.lock.validate();
    try absolute(selected.compiler_path);
    try absolute(selected.compiler_distribution_path);
    const compiler_real = try std.Io.Dir.cwd().realPathFileAlloc(io, selected.compiler_path, gpa);
    defer gpa.free(compiler_real);
    const distribution_real = try std.Io.Dir.cwd().realPathFileAlloc(io, selected.compiler_distribution_path, gpa);
    defer gpa.free(distribution_real);
    if (!std.mem.startsWith(u8, compiler_real, distribution_real) or compiler_real.len <= distribution_real.len or !std.fs.path.isSep(compiler_real[distribution_real.len])) return error.CompilerOutsideDistribution;
    const compiler = try hashFile(gpa, io, selected.compiler_path, 512 * 1024 * 1024);
    if (!same(compiler, selected.lock.compiler_digest)) return error.CompilerDigestMismatch;
    var bundle: Digest = @splat(0);
    if (selected.lock.compiler_kind == .checked_bundle) {
        bundle = try hashFile(gpa, io, selected.compiler_bundle_path orelse return error.CompilerBundleRequired, 1024 * 1024 * 1024);
        if (!same(bundle, selected.lock.compiler_bundle_digest)) return error.CompilerBundleDigestMismatch;
    } else if (selected.compiler_bundle_path != null) return error.UnexpectedCompilerBundle;
    const compiler_tree = try compilerTreeDigest(gpa, io, selected.compiler_distribution_path);
    if (!same(compiler_tree, selected.expected_compiler_tree_digest)) return error.CompilerTreeDigestMismatch;
    const zero: Digest = @splat(0);
    if (!same(selected.lock.compiler_tree_digest, zero) and !same(compiler_tree, selected.lock.compiler_tree_digest)) return error.CompilerTreeDigestMismatch;
    var toolchain_receipt: Digest = @splat(0);
    if (selected.toolchain_receipt_path) |path| {
        try absolute(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024));
        defer gpa.free(bytes);
        toolchain_receipt = firmware.digest(bytes);
        if (!same(toolchain_receipt, selected.lock.toolchain_receipt_digest)) return error.ToolchainReceiptChanged;
        const parsed = try @import("toolchain.zig").Receipt.parse(gpa, bytes);
        defer parsed.deinit(gpa);
        if (parsed.kind != selected.lock.compiler_kind or !std.mem.eql(u8, parsed.compiler, compiler_real) or !std.mem.eql(u8, parsed.distribution, distribution_real) or !same(parsed.compiler_digest, compiler) or !same(parsed.tree_digest, compiler_tree)) return error.ToolchainReceiptMismatch;
        if (parsed.bundle_digest) |digest| if (!same(digest, bundle)) return error.CompilerBundleDigestMismatch;
    } else if (!same(selected.lock.toolchain_receipt_digest, zero)) return error.ToolchainReceiptRequired;
    const companion_tree = try sourceTree(gpa, io, selected.companion_path);
    if (!same(companion_tree, selected.expected_companion_tree_digest)) return error.CompanionTreeDigestMismatch;
    const firmware_tree = try sourceTree(gpa, io, selected.firmware_path);
    if (!same(firmware_tree, selected.lock.firmware_source_digest)) return error.FirmwareTreeDigestMismatch;
    const closure = try closureDigest(gpa, selected.dependencies, selected.manifests);
    if (!same(closure, selected.lock.dependency_digest)) return error.DependencyClosureMismatch;
    for (selected.dependencies) |dependency| {
        var directory = try std.Io.Dir.cwd().openDir(io, dependency.source_path, .{ .iterate = true });
        defer directory.close(io);
        if (!same(try preparation.packageTreeDigest(gpa, io, directory), dependency.expected_tree_digest)) return error.DependencySourceChanged;
    }
    for (selected.manifests) |manifest| if (!same(try hashFile(gpa, io, manifest.path, 1024 * 1024), manifest.expected_digest)) return error.DependencyManifestChanged;
    const board_mapping = firmware.digest(selected.board_mapping);
    if (!same(board_mapping, selected.lock.board_mapping_digest)) return error.BoardMappingDigestMismatch;
    if (selected.verify_compiler_version) try preparation.verifyCompiler(gpa, io, selected.compiler_path, compiler);
    const receipt: Receipt = .{ .version = selected.lock.version, .compiler_kind = selected.lock.compiler_kind, .toolchain_receipt_digest = toolchain_receipt, .lock_digest = selected.lock.digest(), .compiler_digest = compiler, .compiler_bundle_digest = bundle, .compiler_tree_digest = compiler_tree, .companion_tree_digest = companion_tree, .firmware_tree_digest = firmware_tree, .dependency_closure_digest = closure, .board_mapping_digest = board_mapping, .compiler_version_verified = selected.verify_compiler_version, .dependency_access = selected.dependency_access };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var owned_lock = selected.lock;
    inline for (.{ "firmware_repository", "firmware_revision", "zig_version", "board", "target", "optimize" }) |name| @field(owned_lock, name) = try arena.allocator().dupe(u8, @field(selected.lock, name));
    return .{ .arena = arena, .receipt = receipt, .inputs = .{ .project_digest = selected.project_digest, .source_digest = selected.exported_source_digest, .build_inputs_digest = receipt.digest(), .profile_id = selected.profile_id, .identity_digest = selected.identity_digest, .lock = owned_lock } };
}

test "compiler tree ignores local worktrees but includes hidden inputs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zig", .data = "compiler" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const original = try compilerTreeDigest(gpa, io, path);
    try tmp.dir.createDirPath(io, ".slim/worktrees/nested/.slim");
    try tmp.dir.writeFile(io, .{ .sub_path = ".slim/worktrees/nested/.slim/source.zig", .data = "source" });
    try std.testing.expectEqual(original, try compilerTreeDigest(gpa, io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = ".slim/worktrees/nested/.slim/source.zig", .data = "changed" });
    try std.testing.expectEqual(original, try compilerTreeDigest(gpa, io, path));
    for ([_][]const u8{ ".zig-cache-flash-preparation", ".zig-cache2" }) |cache| {
        try tmp.dir.createDirPath(io, cache);
        const file = try std.fs.path.join(gpa, &.{ cache, "output" });
        defer gpa.free(file);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "ignored" });
        try std.testing.expectEqual(original, try compilerTreeDigest(gpa, io, path));
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "edited ignored bytes" });
        try std.testing.expectEqual(original, try compilerTreeDigest(gpa, io, path));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache-note", .data = "hidden file" });
    try std.testing.expect(!same(original, try compilerTreeDigest(gpa, io, path)));
    const with_note = try compilerTreeDigest(gpa, io, path);
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache-note", .data = "changed hidden file" });
    try std.testing.expect(!same(with_note, try compilerTreeDigest(gpa, io, path)));
    try tmp.dir.writeFile(io, .{ .sub_path = ".compiler-config", .data = "hidden input" });
    try std.testing.expect(!same(original, try compilerTreeDigest(gpa, io, path)));
}

test "capture distinguishes archive from installed trees and detects changed inputs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zig", .data = "verified compiler bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "compiler.tar", .data = "compiler archive bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const compiler = try std.fs.path.join(gpa, &.{ base, "zig" });
    defer gpa.free(compiler);
    const bundle = try std.fs.path.join(gpa, &.{ base, "compiler.tar" });
    defer gpa.free(bundle);
    const manifest_path = try std.fs.path.join(gpa, &.{ base, "build.zig.zon" });
    defer gpa.free(manifest_path);
    const manifests = [_]Manifest{.{ .name = "root", .path = manifest_path, .expected_digest = firmware.digest(".{ .dependencies = .{} }") }};
    const tree = try preparation.treeDigest(gpa, io, tmp.dir);
    var lock = target.fixture();
    lock.compiler_digest = firmware.digest("verified compiler bytes");
    lock.compiler_bundle_digest = firmware.digest("compiler archive bytes");
    lock.firmware_source_digest = tree;
    lock.dependency_digest = try closureDigest(gpa, &.{}, &manifests);
    lock.board_mapping_digest = firmware.digest("canonical board mapping");
    var selection: Selection = .{ .lock = lock, .compiler_path = compiler, .compiler_distribution_path = base, .compiler_bundle_path = bundle, .expected_compiler_tree_digest = tree, .companion_path = base, .expected_companion_tree_digest = tree, .firmware_path = base, .dependencies = &.{}, .manifests = &manifests, .board_mapping = "canonical board mapping", .project_digest = @splat(1), .exported_source_digest = @splat(2), .profile_id = @splat(3), .identity_digest = @splat(4) };
    var captured = try capture(gpa, io, selection);
    defer captured.deinit();
    try std.testing.expect(!same(captured.receipt.compiler_bundle_digest, captured.receipt.compiler_tree_digest));
    try std.testing.expectEqual(captured.receipt.digest(), captured.inputs.build_inputs_digest);
    var fetch_receipt = captured.receipt;
    fetch_receipt.dependency_access = .allow_pinned_fetch;
    try std.testing.expect(!same(captured.receipt.digest(), fetch_receipt.digest()));
    const offline_again = try captured.receipt.serialize(gpa);
    defer gpa.free(offline_again);
    const encoded_fetch = try fetch_receipt.serialize(gpa);
    defer gpa.free(encoded_fetch);
    try std.testing.expect(std.mem.indexOf(u8, offline_again, "dependency_access") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_fetch, "dependency_access") != null);
    const encoded = try captured.receipt.serialize(gpa);
    defer gpa.free(encoded);
    const parsed = try Receipt.parse(gpa, encoded);
    try std.testing.expectEqual(captured.receipt.digest(), parsed.digest());
    selection.board_mapping = "changed board mapping";
    try std.testing.expectError(error.BoardMappingDigestMismatch, capture(gpa, io, selection));
    selection.board_mapping = "canonical board mapping";
    try tmp.dir.writeFile(io, .{ .sub_path = "zig", .data = "changed compiler" });
    try std.testing.expectError(error.CompilerDigestMismatch, capture(gpa, io, selection));
}

test "closure framing rejects floating duplicate IDs and is relocation/order invariant" {
    const gpa = std.testing.allocator;
    const a: Dependency = .{ .name = "a", .revision = "d8df33801dbea792128baaab516291720d400a91", .package_hash = "picotool-2.3.1-PtJrRaJNAAA3xRwGctKAdomuKCJXz5UwMOrhzQ_Z2f-e", .source_path = "/a", .expected_tree_digest = @splat(1) };
    var b = a;
    b.name = "b";
    b.source_path = "/b";
    const manifests = [_]Manifest{.{ .name = "root", .path = "/build.zig.zon", .expected_digest = @splat(2) }};
    const original = try closureDigest(gpa, &.{ a, b }, &manifests);
    try std.testing.expectEqualStrings("4e6b3594561328771da9ddf7a6515223ef3bd25897e37b8277e7eee306c52097", &std.fmt.bytesToHex(original, .lower));
    try std.testing.expectEqual(original, try closureDigest(gpa, &.{ b, a }, &manifests));
    b.source_path = "/relocated/b";
    try std.testing.expectEqual(original, try closureDigest(gpa, &.{ a, b }, &manifests));
    try std.testing.expectError(error.DuplicateDependency, closureDigest(gpa, &.{ a, a }, &manifests));
    b.revision = "main";
    try std.testing.expectError(error.FloatingDependencyRevision, closureDigest(gpa, &.{b}, &manifests));
    b = a;
    b.package_hash = "latest";
    try std.testing.expectError(error.InvalidDependencyPackageHash, closureDigest(gpa, &.{b}, &manifests));
    try std.testing.expectError(error.DuplicateDependencyManifest, closureDigest(gpa, &.{a}, &.{ manifests[0], manifests[0] }));
    var content = a;
    content.identity = .package_content;
    content.revision = "";
    content.package_hash = "sdl-1.0.3+3.4.16-i4QD0e0HqgDYP8m4T3rMJShyaDLy8ksp8qzCrCSncaPB";
    const pinned = try closureDigest(gpa, &.{content}, &manifests);
    content.source_path = "/relocated/source";
    try std.testing.expectEqual(pinned, try closureDigest(gpa, &.{content}, &manifests));
    content.revision = "main";
    try std.testing.expectError(error.UnexpectedContentRevision, closureDigest(gpa, &.{content}, &manifests));
    content.revision = "";
    content.package_hash = "sdl-1.0.3+3.4.16-i4QD0e0HqgDYP8m4T3rMJShyaDLy8ksp8qzCrCSncaP+";
    try std.testing.expectError(error.InvalidDependencyPackageHash, closureDigest(gpa, &.{content}, &manifests));
}
