//! Read-only complete declared dependency traversal over prepared source records.
const std = @import("std");
const jobs = @import("root.zig");
const zon = @import("owned-zon");
pub const Root = struct { name: []const u8, directory: []const u8 };
pub const Override = struct { root: []const u8, dependency: []const u8, target_root: []const u8 };
/// An explicit build-profile decision, never an automatic missing-source fallback.
pub const InactiveLazy = struct { dependency: []const u8, package_hash: []const u8 };
pub const Options = struct { roots: []const Root, sources: []const jobs.package_cache.Source = &.{}, cache_directory: ?[]const u8 = null, overrides: []const Override = &.{}, build_profile: []const u8 = "", inactive_lazy: []const InactiveLazy = &.{}, audit_packages: bool = true };
pub const Provider = struct {
    context: *anyopaque,
    /// Return strings allocated in the supplied traversal allocator.
    acquire: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, jobs.package_manifest.Archive) anyerror!jobs.package_cache.Source,
};
pub const RootRecord = struct { name: []const u8, directory: []const u8, tree_digest: jobs.firmware.Digest };
pub const Record = struct { roots: []const RootRecord, dependencies: []const jobs.build_provenance.Dependency, manifests: []const jobs.build_provenance.Manifest, sources: []const jobs.package_cache.Source, overrides: []const Override, closure_digest: jobs.firmware.Digest, resolution_digest: jobs.firmware.Digest, build_profile: []const u8 = "", inactive_lazy: []const InactiveLazy = &.{}, audit_packages: bool = true };
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    record: Record,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn within(child: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, child, parent) or (std.mem.startsWith(u8, child, parent) and child.len > parent.len and std.fs.path.isSep(child[parent.len]));
}
fn directory(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    if (!std.fs.path.isAbsolute(path) or path.len < 2 or std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsoluteResolutionPathRequired;
    return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa);
}
fn tree(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !jobs.firmware.Digest {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    return jobs.preparation.treeDigest(gpa, io, dir);
}
fn framed(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    hash.update(&size);
    hash.update(bytes);
}
const Walker = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    io: std.Io,
    options: Options,
    roots: []RootRecord,
    dependencies: std.ArrayList(jobs.build_provenance.Dependency) = .empty,
    manifests: std.ArrayList(jobs.build_provenance.Manifest) = .empty,
    override_used: []bool,
    inactive_used: []bool,
    sources: std.ArrayList(jobs.package_cache.Source),
    provider: ?Provider,
    fn root(self: *Walker, name: []const u8) !RootRecord {
        for (self.roots) |entry| if (std.mem.eql(u8, name, entry.name)) return entry;
        return error.UnknownResolutionRoot;
    }
    fn walk(self: *Walker, owner_name: []const u8, scope: []const u8, current: []const u8, depth: usize) !void {
        if (depth > 64 or self.manifests.items.len >= 256) return error.DependencyGraphTooLarge;
        const manifest_path = try std.fs.path.join(self.a, &.{ current, "build.zig.zon" });
        for (self.manifests.items) |existing| if (std.mem.eql(u8, existing.path, manifest_path)) return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return, // Naked pinned packages have no manifest.
            else => return err,
        };
        defer self.gpa.free(bytes);
        if (!within(current, scope)) return error.LocalDependencyEscapesOwner;
        const relative = if (std.mem.eql(u8, scope, current)) "." else current[scope.len + 1 ..];
        const name_hash = jobs.firmware.digest(relative);
        const manifest_name = try std.fmt.allocPrint(self.a, "{s}.{s}", .{ owner_name, std.fmt.bytesToHex(name_hash, .lower) });
        try self.manifests.append(self.a, .{ .name = manifest_name, .path = manifest_path, .expected_digest = jobs.firmware.digest(bytes) });
        var parsed = try jobs.package_manifest.parse(self.gpa, bytes);
        defer parsed.deinit();
        for (parsed.dependencies) |dependency| {
            var inactive = false;
            for (self.options.inactive_lazy, self.inactive_used) |entry, *used| {
                if (!std.mem.eql(u8, dependency.name, entry.dependency) or dependency.package_hash == null or !std.mem.eql(u8, dependency.package_hash.?, entry.package_hash)) continue;
                if (!dependency.lazy) return error.InactiveDependencyMustBeLazy;
                used.* = true;
                inactive = true;
            }
            if (inactive) continue;
            var overridden = false;
            for (self.options.overrides, self.override_used) |override, *used| if (std.mem.eql(u8, owner_name, override.root) and std.mem.eql(u8, dependency.name, override.dependency) and std.mem.eql(u8, current, scope)) {
                if (overridden) return error.DuplicateResolutionOverride;
                const target = try self.root(override.target_root);
                used.* = true;
                overridden = true;
                try self.walk(target.name, target.directory, target.directory, depth + 1);
            };
            if (overridden) continue;
            if (dependency.path) |local| {
                if (std.fs.path.isAbsolute(local)) return error.LocalDependencyEscapesOwner;
                const joined = try std.fs.path.join(self.a, &.{ current, local });
                const child = try directory(self.a, self.io, joined);
                if (!within(child, scope)) return error.LocalDependencyEscapesOwner;
                try self.walk(owner_name, scope, child, depth + 1);
                continue;
            }
            const hash = dependency.package_hash.?;
            const origin = try jobs.package_manifest.archive(self.a, dependency.url.?);
            var selected: ?jobs.package_cache.Source = null;
            for (self.sources.items) |source| if (std.mem.eql(u8, source.package_hash, hash)) {
                if (selected != null) return error.DuplicatePreparedPackage;
                selected = source;
            };
            if (selected == null) {
                const provider = self.provider orelse return error.UnpreparedPackageSource;
                const supplied = try provider.acquire(provider.context, self.a, self.io, hash, origin);
                if (!std.mem.eql(u8, supplied.package_hash, hash)) return error.DependencyPackageHashMismatch;
                const cache_path = try directory(self.a, self.io, self.options.cache_directory orelse return error.PreparedPackageCacheRequired);
                if (self.options.audit_packages) try supplied.verify(self.gpa, self.io, cache_path);
                const copied = try zon.clone(self.a, supplied);
                try self.sources.append(self.a, copied);
                selected = copied;
            }
            const source = selected.?;
            var id_hash = std.crypto.hash.sha2.Sha256.init(.{});
            id_hash.update(&.{@backingInt(origin.identity)});
            id_hash.update(origin.revision);
            id_hash.update(hash);
            const id = try std.fmt.allocPrint(self.a, "pkg.{s}", .{std.fmt.bytesToHex(id_hash.finalResult(), .lower)});
            var present = false;
            for (self.dependencies.items) |existing| if (std.mem.eql(u8, existing.name, id)) {
                present = true;
            };
            if (!present) {
                if (self.dependencies.items.len >= 256) return error.DependencyGraphTooLarge;
                const row = try zon.clone(self.a, jobs.build_provenance.Dependency{ .name = id, .revision = origin.revision, .identity = origin.identity, .package_hash = hash, .source_path = source.source_path, .expected_tree_digest = source.tree_digest });
                try self.dependencies.append(self.a, row);
            }
            // Manifest identity is based on package content, independent of aliases.
            const package_owner = try std.fmt.allocPrint(self.a, "p.{s}", .{std.fmt.bytesToHex(jobs.firmware.digest(hash), .lower)[0..40]});
            try self.walk(package_owner, source.source_path, source.source_path, depth + 1);
        }
    }
};
/// Traverses declared dependencies; only explicit inactive lazy pins are omitted.
/// Missing prepared packages fail explicitly; this function runs no compiler/fetch.
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, options: Options) !Owned {
    return traverse(gpa, io, options, null);
}
/// Rebuild the declared graph read-only; consumers use this fresh owned record.
pub fn verify(gpa: std.mem.Allocator, io: std.Io, expected: Record, cache_directory: ?[]const u8) !Owned {
    const roots = try gpa.alloc(Root, expected.roots.len);
    defer gpa.free(roots);
    for (expected.roots, roots) |source, *root| root.* = .{ .name = source.name, .directory = source.directory };
    var current = try resolve(gpa, io, .{ .roots = roots, .sources = expected.sources, .overrides = expected.overrides, .cache_directory = cache_directory, .build_profile = expected.build_profile, .inactive_lazy = expected.inactive_lazy, .audit_packages = expected.audit_packages });
    errdefer current.deinit();
    if (!std.mem.eql(u8, &expected.closure_digest, &(try jobs.build_provenance.closureDigest(gpa, expected.dependencies, expected.manifests)))) return error.InvalidResolutionClosure;
    if (!std.mem.eql(u8, &expected.closure_digest, &current.record.closure_digest) or !std.mem.eql(u8, &expected.resolution_digest, &current.record.resolution_digest)) return error.DependencyResolutionChanged;
    for (expected.roots) |root| {
        var found = false;
        for (current.record.roots) |fresh| if (std.mem.eql(u8, root.name, fresh.name)) {
            found = true;
            if (!std.mem.eql(u8, &root.tree_digest, &fresh.tree_digest)) return error.ResolutionRootChanged;
        };
        if (!found) return error.UnknownResolutionRoot;
    }
    return current;
}
/// Capture complete fresh dependency inputs instead of trusting caller inventories.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, expected: Record, cache_directory: ?[]const u8, selected: jobs.build_provenance.Selection, dependency_access: jobs.build_provenance.DependencyAccess) !jobs.build_provenance.Captured {
    if (!expected.audit_packages) return error.PackageAuditNotCaptured;
    var verified = try verify(gpa, io, expected, cache_directory);
    defer verified.deinit();
    if (verified.record.overrides.len != 0 and selected.lock.source_kind != .development) return error.DevelopmentOverrideRequiresDevelopmentLock;
    const companion = try directory(gpa, io, selected.companion_path);
    defer gpa.free(companion);
    const firmware = try directory(gpa, io, selected.firmware_path);
    defer gpa.free(firmware);
    var companion_found = false;
    var firmware_found = false;
    for (verified.record.roots) |root| {
        if (std.mem.eql(u8, root.directory, companion)) {
            if (!std.mem.eql(u8, &root.tree_digest, &selected.expected_companion_tree_digest)) return error.CompanionTreeDigestMismatch;
            companion_found = true;
        }
        if (std.mem.eql(u8, root.directory, firmware)) {
            if (!std.mem.eql(u8, &root.tree_digest, &selected.lock.firmware_source_digest)) return error.FirmwareTreeDigestMismatch;
            firmware_found = true;
        }
    }
    if (!companion_found or !firmware_found) return error.BuildRootNotResolved;
    var complete = selected;
    complete.dependency_access = dependency_access;
    complete.dependencies = verified.record.dependencies;
    complete.manifests = verified.record.manifests;
    return jobs.build_provenance.capture(gpa, io, complete);
}
/// Deliberate preparation variant. Only its caller-selected provider may acquire
/// missing packages; the read-only resolve entry point never invokes a provider.
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, options: Options, provider: Provider) !Owned {
    return traverse(gpa, io, options, provider);
}
fn traverse(gpa: std.mem.Allocator, io: std.Io, options: Options, provider: ?Provider) !Owned {
    if (options.inactive_lazy.len > 256 or options.build_profile.len > 128 or (options.inactive_lazy.len != 0 and options.build_profile.len == 0)) return error.InvalidBuildProfile;
    for (options.build_profile) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidBuildProfile;
    for (options.inactive_lazy, 0..) |entry, index| {
        try jobs.build_provenance.validatePackageHash(entry.package_hash);
        for (options.inactive_lazy[0..index]) |prior| if (std.mem.eql(u8, entry.dependency, prior.dependency) and std.mem.eql(u8, entry.package_hash, prior.package_hash)) return error.DuplicateInactiveDependency;
    }
    if (options.roots.len == 0 or options.roots.len > 16 or options.overrides.len > 16) return error.InvalidResolutionRoots;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const roots = try a.alloc(RootRecord, options.roots.len);
    for (options.roots, roots, 0..) |root, *record, index| {
        if (root.name.len == 0 or root.name.len > 40) return error.InvalidResolutionRootName;
        for (root.name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidResolutionRootName;
        for (options.roots[0..index]) |prior| if (std.mem.eql(u8, prior.name, root.name)) return error.DuplicateResolutionRoot;
        const path = try directory(a, io, root.directory);
        record.* = .{ .name = try a.dupe(u8, root.name), .directory = path, .tree_digest = if (options.audit_packages) try tree(gpa, io, path) else @splat(0) };
    }
    std.mem.sort(RootRecord, roots, {}, struct {
        fn less(_: void, lhs: RootRecord, rhs: RootRecord) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.less);
    if (options.audit_packages and options.sources.len != 0) {
        const cache_path = try directory(a, io, options.cache_directory orelse return error.PreparedPackageCacheRequired);
        for (options.sources) |source| try source.verify(gpa, io, cache_path);
    }
    const used = try a.alloc(bool, options.overrides.len);
    @memset(used, false);
    const inactive_used = try a.alloc(bool, options.inactive_lazy.len);
    @memset(inactive_used, false);
    var walker = Walker{ .gpa = gpa, .a = a, .io = io, .options = options, .roots = roots, .override_used = used, .inactive_used = inactive_used, .sources = .empty, .provider = provider };
    for (options.sources) |source| try walker.sources.append(a, try zon.clone(a, source));
    for (roots) |root| try walker.walk(root.name, root.directory, root.directory, 0);
    for (used) |accepted| if (!accepted) return error.UnusedResolutionOverride;
    for (inactive_used) |accepted| if (!accepted) return error.UnusedInactiveDependency;
    if (options.audit_packages) for (roots) |root| {
        if (!std.mem.eql(u8, &root.tree_digest, &(try tree(gpa, io, root.directory)))) return error.ResolutionRootChanged;
    };
    if (options.audit_packages and walker.sources.items.len != 0) {
        const cache_path = try directory(a, io, options.cache_directory.?);
        for (walker.sources.items) |source| try source.verify(gpa, io, cache_path);
    }
    const dependencies = try walker.dependencies.toOwnedSlice(a);
    const manifests = try walker.manifests.toOwnedSlice(a);
    const overrides = try zon.clone(a, options.overrides);
    const sources = try walker.sources.toOwnedSlice(a);
    const digest = try jobs.build_provenance.closureDigest(gpa, dependencies, manifests);
    var resolution = std.crypto.hash.sha2.Sha256.init(.{});
    resolution.update(if (options.build_profile.len == 0) "zigmkay-all-declared-resolution-v1\x00" else "zigmkay-selected-build-resolution-v1\x00");
    if (options.build_profile.len != 0) {
        framed(&resolution, options.build_profile);
        const inactive = try a.dupe(InactiveLazy, options.inactive_lazy);
        std.mem.sort(InactiveLazy, inactive, {}, struct {
            fn less(_: void, lhs: InactiveLazy, rhs: InactiveLazy) bool {
                const first = std.mem.order(u8, lhs.dependency, rhs.dependency);
                return if (first == .eq) std.mem.lessThan(u8, lhs.package_hash, rhs.package_hash) else first == .lt;
            }
        }.less);
        for (inactive) |entry| {
            framed(&resolution, entry.dependency);
            framed(&resolution, entry.package_hash);
        }
    }
    resolution.update(&digest);
    for (roots) |root| {
        framed(&resolution, root.name);
        resolution.update(&root.tree_digest);
    }
    const sorted = try a.dupe(Override, overrides);
    std.mem.sort(Override, sorted, {}, struct {
        fn less(_: void, lhs: Override, rhs: Override) bool {
            const first = std.mem.order(u8, lhs.root, rhs.root);
            return if (first == .eq) std.mem.lessThan(u8, lhs.dependency, rhs.dependency) else first == .lt;
        }
    }.less);
    for (sorted) |override| {
        framed(&resolution, override.root);
        framed(&resolution, override.dependency);
        framed(&resolution, override.target_root);
    }
    const sorted_sources = try a.dupe(jobs.package_cache.Source, sources);
    std.mem.sort(jobs.package_cache.Source, sorted_sources, {}, struct {
        fn less(_: void, lhs: jobs.package_cache.Source, rhs: jobs.package_cache.Source) bool {
            return std.mem.lessThan(u8, lhs.package_hash, rhs.package_hash);
        }
    }.less);
    for (sorted_sources) |source| {
        framed(&resolution, source.package_hash);
        resolution.update(&source.tree_digest);
        resolution.update(&source.archive_digest);
    }
    return .{ .arena = arena, .record = .{ .roots = roots, .dependencies = dependencies, .manifests = manifests, .sources = sources, .overrides = overrides, .closure_digest = digest, .resolution_digest = resolution.finalResult(), .build_profile = try a.dupe(u8, options.build_profile), .inactive_lazy = try zon.clone(a, options.inactive_lazy), .audit_packages = options.audit_packages } };
}

test "unaudited resolution skips content hashing and preserves its policy on reuse" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "payload", .data = "before" });
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const roots = [_]Root{.{ .name = "fixture", .directory = path }};
    var selected = try resolve(t.allocator, t.io, .{ .roots = &roots, .audit_packages = false });
    defer selected.deinit();
    try t.expect(!selected.record.audit_packages);
    try t.expectEqual(@as(jobs.firmware.Digest, @splat(0)), selected.record.roots[0].tree_digest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "payload", .data = "after: deliberately not audited" });
    var reused = try verify(t.allocator, t.io, selected.record, null);
    defer reused.deinit();
    try t.expect(!reused.record.audit_packages);
    // Dependency manifests are still tracked, even without content audits.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{}, .version = \"changed\" }" });
    try t.expectError(error.DependencyResolutionChanged, verify(t.allocator, t.io, selected.record, null));
}

test "selected build binds inactive lazy pins and rejects silent omissions" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const lazy = ".{ .dependencies = .{ .optional = .{ .url = \"https://example.test/archive.tar.gz\", .hash = \"N-V-__8AAH-J2wA1QFgeIKK0hLveAjq3mNnOJb96xak4HFqx\", .lazy = true } } }";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = lazy });
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const roots = [_]Root{.{ .name = "companion", .directory = path }};
    const pins = [_]InactiveLazy{.{ .dependency = "optional", .package_hash = "N-V-__8AAH-J2wA1QFgeIKK0hLveAjq3mNnOJb96xak4HFqx" }};
    try t.expectError(error.UnpreparedPackageSource, resolve(t.allocator, t.io, .{ .roots = &roots }));
    try t.expectError(error.InvalidBuildProfile, resolve(t.allocator, t.io, .{ .roots = &roots, .inactive_lazy = &pins }));
    var selected = try resolve(t.allocator, t.io, .{ .roots = &roots, .build_profile = "aarch64-macos-managed", .inactive_lazy = &pins });
    defer selected.deinit();
    try t.expectEqual(@as(usize, 0), selected.record.dependencies.len);
    try t.expectEqual(@as(usize, 1), selected.record.manifests.len);
    var verified = try verify(t.allocator, t.io, selected.record, null);
    defer verified.deinit();
    var changed = selected.record;
    changed.build_profile = "windows-managed";
    try t.expectError(error.DependencyResolutionChanged, verify(t.allocator, t.io, changed, null));
    var wrong = pins;
    wrong[0].dependency = "unknown";
    try t.expectError(error.UnpreparedPackageSource, resolve(t.allocator, t.io, .{ .roots = &roots, .build_profile = "macos", .inactive_lazy = &wrong }));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    try t.expectError(error.UnusedInactiveDependency, resolve(t.allocator, t.io, .{ .roots = &roots, .build_profile = "macos", .inactive_lazy = &pins }));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{ .optional = .{ .url = \"https://example.test/archive.tar.gz\", .hash = \"N-V-__8AAH-J2wA1QFgeIKK0hLveAjq3mNnOJb96xak4HFqx\" } } }" });
    try t.expectError(error.InactiveDependencyMustBeLazy, resolve(t.allocator, t.io, .{ .roots = &roots, .build_profile = "macos", .inactive_lazy = &pins }));
}

test "read-only resolution traverses local cycles and requires explicit prepared or overridden pins" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer {
        std.debug.print("resolution cycle: before tmp cleanup\n", .{});
        tmp.cleanup();
        std.debug.print("resolution cycle: after tmp cleanup\n", .{});
    }
    std.debug.print("resolution cycle: before local open\n", .{});
    var local = try tmp.dir.createDirPathOpen(t.io, "local", .{});
    std.debug.print("resolution cycle: after local open\n", .{});
    defer {
        std.debug.print("resolution cycle: before local close\n", .{});
        local.close(t.io);
        std.debug.print("resolution cycle: after local close\n", .{});
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{ .local = .{ .path = \"local\" } } }" });
    try local.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{ .parent = .{ .path = \"..\" } } }" });
    std.debug.print("resolution cycle: begin root realpath\n", .{});
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    std.debug.print("resolution cycle: end root realpath\n", .{});
    defer t.allocator.free(path);
    const roots = [_]Root{.{ .name = "companion", .directory = path }};
    std.debug.print("resolution cycle: begin initial resolve\n", .{});
    var resolved = try resolve(t.allocator, t.io, .{ .roots = &roots });
    std.debug.print("resolution cycle: end initial resolve\n", .{});
    defer resolved.deinit();
    try t.expectEqual(@as(usize, 2), resolved.record.manifests.len);
    try t.expectEqual(@as(usize, 0), resolved.record.dependencies.len);
    const pinned = ".{ .dependencies = .{ .firmware = .{ .url = \"git+https://github.com/owner/repo#d8df33801dbea792128baaab516291720d400a91\", .hash = \"picotool-2.3.1-PtJrRaJNAAA3xRwGctKAdomuKCJXz5UwMOrhzQ_Z2f-e\", .lazy = true } } }";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = pinned });
    try t.expectError(error.UnpreparedPackageSource, resolve(t.allocator, t.io, .{ .roots = &roots }));
    try local.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    const local_path = try local.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(local_path);
    const selected_roots = [_]Root{ roots[0], .{ .name = "firmware", .directory = local_path } };
    const override = [_]Override{.{ .root = "companion", .dependency = "firmware", .target_root = "firmware" }};
    var overridden = try resolve(t.allocator, t.io, .{ .roots = &selected_roots, .overrides = &override });
    defer overridden.deinit();
    try t.expectEqual(@as(usize, 2), overridden.record.manifests.len);
    try t.expectEqual(@as(usize, 1), overridden.record.overrides.len);
    var unknown = override;
    unknown[0].dependency = "unselected";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    try t.expectError(error.UnusedResolutionOverride, resolve(t.allocator, t.io, .{ .roots = &roots, .overrides = &unknown }));
    const package_hash = "sdl-1.0.3+3.4.16-i4QD0e0HqgDYP8m4T3rMJShyaDLy8ksp8qzCrCSncaPB";
    var cache = t.tmpDir(.{ .iterate = true });
    defer {
        std.debug.print("resolution cycle: before cache cleanup\n", .{});
        cache.cleanup();
        std.debug.print("resolution cycle: after cache cleanup\n", .{});
    }
    const cache_path = try cache.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(cache_path);
    const package_relative = try std.fs.path.join(t.allocator, &.{ "p", package_hash });
    defer t.allocator.free(package_relative);
    var prepared_dir = try cache.dir.createDirPathOpen(t.io, package_relative, .{ .open_options = .{ .iterate = true } });
    defer {
        std.debug.print("resolution cycle: before prepared directory close\n", .{});
        prepared_dir.close(t.io);
        std.debug.print("resolution cycle: after prepared directory close\n", .{});
    }
    try prepared_dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    try cache.dir.createDirPath(t.io, "blobs");
    const blob = "explicit prepared-source fixture bytes";
    const blob_hash = jobs.firmware.digest(blob);
    const blob_relative = try std.fs.path.join(t.allocator, &.{ "blobs", std.fmt.bytesToHex(blob_hash, .lower) ++ ".tar.gz" });
    defer t.allocator.free(blob_relative);
    try cache.dir.writeFile(t.io, .{ .sub_path = blob_relative, .data = blob });
    const prepared_path = try prepared_dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(prepared_path);
    const blob_path = try cache.dir.realPathFileAlloc(t.io, blob_relative, t.allocator);
    defer t.allocator.free(blob_path);
    const sources = [_]jobs.package_cache.Source{.{ .package_hash = package_hash, .source_path = prepared_path, .tree_digest = try jobs.preparation.treeDigest(t.allocator, t.io, prepared_dir), .archive_path = blob_path, .archive_digest = blob_hash }};
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{ .sdl = .{ .url = \"https://example.test/release.tar.gz\", .hash = \"sdl-1.0.3+3.4.16-i4QD0e0HqgDYP8m4T3rMJShyaDLy8ksp8qzCrCSncaPB\", .lazy = true } } }" });
    var external = try resolve(t.allocator, t.io, .{ .roots = &roots, .sources = &sources, .cache_directory = cache_path });
    defer external.deinit();
    try t.expectEqual(@as(usize, 1), external.record.dependencies.len);
    try t.expect(external.record.dependencies[0].identity == .package_content);
    try t.expectEqual(@as(usize, 2), external.record.manifests.len);
    const Fixture = struct {
        source: jobs.package_cache.Source,
        calls: usize = 0,
        fn acquire(pointer: *anyopaque, output: std.mem.Allocator, _: std.Io, hash: []const u8, _: jobs.package_manifest.Archive) anyerror!jobs.package_cache.Source {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (!std.mem.eql(u8, hash, self.source.package_hash)) return error.UnexpectedPackage;
            self.calls += 1;
            return zon.clone(output, self.source);
        }
    };
    var provider_fixture = Fixture{ .source = sources[0] };
    var prepared = try prepare(t.allocator, t.io, .{ .roots = &roots, .cache_directory = cache_path }, .{ .context = &provider_fixture, .acquire = Fixture.acquire });
    defer prepared.deinit();
    try t.expectEqual(@as(usize, 1), provider_fixture.calls);
    try t.expectEqual(@as(usize, 1), prepared.record.sources.len);
    try t.expectEqual(external.record.resolution_digest, prepared.record.resolution_digest);
    var environment: std.process.Environ.Map = .init(t.allocator);
    defer environment.deinit();
    const compiler = jobs.toolchain.Receipt{ .kind = .selected_installation, .compiler = "/unused/zig", .distribution = "/unused", .compiler_digest = @splat(0), .tree_digest = @splat(0) };
    try t.expectError(error.OfflinePackageArchiveRequired, jobs.package_preparation.prepare(t.allocator, t.io, &environment, compiler, cache.dir, .{ .options = .{ .roots = &roots } }));
    const Progress = struct {
        phases: [4]jobs.package_preparation.Phase = undefined,
        count: usize = 0,
        fn update(pointer: *anyopaque, _: []const u8, phase: jobs.package_preparation.Phase) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (self.count < self.phases.len) self.phases[self.count] = phase;
            self.count += 1;
        }
    };
    var progress: Progress = .{};
    try t.expectError(error.OfflinePackageArchiveRequired, jobs.package_preparation.prepareReported(t.allocator, t.io, &environment, compiler, cache.dir, .{ .options = .{ .roots = &roots } }, .{ .context = &progress, .update = Progress.update }));
    try t.expectEqual(@as(usize, 2), progress.count);
    try t.expectEqual(.checking_cache, progress.phases[0]);
    try t.expectEqual(.missing_archive, progress.phases[1]);
    var reused = try jobs.package_preparation.prepare(t.allocator, t.io, &environment, compiler, cache.dir, .{ .options = .{ .roots = &roots, .sources = &sources } });
    defer reused.deinit();
    try t.expectEqual(external.record.resolution_digest, reused.record.resolution_digest);
    var rechecked = try verify(t.allocator, t.io, reused.record, cache_path);
    defer rechecked.deinit();
    try t.expectEqual(reused.record.resolution_digest, rechecked.record.resolution_digest);
    var altered = reused.record;
    altered.resolution_digest[0] ^= 1;
    try t.expectError(error.DependencyResolutionChanged, verify(t.allocator, t.io, altered, cache_path));
    altered = reused.record;
    altered.closure_digest[0] ^= 1;
    try t.expectError(error.InvalidResolutionClosure, verify(t.allocator, t.io, altered, cache_path));
    try prepared_dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = "changed prepared data" });
    try t.expectError(error.CachedPackageSourceChanged, resolve(t.allocator, t.io, .{ .roots = &roots, .sources = &sources, .cache_directory = cache_path }));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{ .escape = .{ .path = \"..\" } } }" });
    try t.expectError(error.LocalDependencyEscapesOwner, resolve(t.allocator, t.io, .{ .roots = &roots }));
}

test "read-only resolution capture supplies complete inventory and rejects unresolved roots" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zig", .data = "compiler fixture" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "compiler.tar", .data = "bundle fixture" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const compiler = try std.fs.path.join(t.allocator, &.{ path, "zig" });
    defer t.allocator.free(compiler);
    const bundle = try std.fs.path.join(t.allocator, &.{ path, "compiler.tar" });
    defer t.allocator.free(bundle);
    var graph = try resolve(t.allocator, t.io, .{ .roots = &.{.{ .name = "fixture", .directory = path }} });
    defer graph.deinit();
    var lock = jobs.target_lock.fixture();
    lock.compiler_digest = jobs.firmware.digest("compiler fixture");
    lock.compiler_bundle_digest = jobs.firmware.digest("bundle fixture");
    lock.firmware_source_digest = graph.record.roots[0].tree_digest;
    lock.dependency_digest = graph.record.closure_digest;
    lock.board_mapping_digest = jobs.firmware.digest("mapping");
    var selection = jobs.build_provenance.Selection{ .lock = lock, .compiler_path = compiler, .compiler_distribution_path = path, .compiler_bundle_path = bundle, .expected_compiler_tree_digest = lock.firmware_source_digest, .companion_path = path, .expected_companion_tree_digest = lock.firmware_source_digest, .firmware_path = path, .dependencies = &.{}, .manifests = &.{}, .board_mapping = "mapping", .project_digest = @splat(1), .exported_source_digest = @splat(2), .profile_id = @splat(3), .identity_digest = @splat(4) };
    var captured = try capture(t.allocator, t.io, graph.record, null, selection, .offline);
    defer captured.deinit();
    try t.expectEqual(graph.record.closure_digest, captured.receipt.dependency_closure_digest);
    var unrelated = t.tmpDir(.{ .iterate = true });
    defer unrelated.cleanup();
    const unrelated_path = try unrelated.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(unrelated_path);
    selection.companion_path = unrelated_path;
    try t.expectError(error.BuildRootNotResolved, capture(t.allocator, t.io, graph.record, null, selection, .offline));
    selection.companion_path = path;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{}, .changed = true }" });
    try t.expectError(error.DependencyResolutionChanged, capture(t.allocator, t.io, graph.record, null, selection, .offline));
}
