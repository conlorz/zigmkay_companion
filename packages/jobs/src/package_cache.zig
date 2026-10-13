//! Explicit data-archive acquisition into an owned cache. Never clones or runs scripts.
const std = @import("std");
const jobs = @import("root.zig");
const zon = @import("owned-zon");
pub const Input = union(enum) { offline_archive: []const u8, download: []const u8 };
pub const Source = struct {
    package_hash: []const u8,
    source_path: []const u8,
    tree_digest: jobs.firmware.Digest,
    archive_path: []const u8,
    archive_digest: jobs.firmware.Digest,
    pub fn verify(self: Source, gpa: std.mem.Allocator, io: std.Io, cache_path: []const u8) !void {
        try jobs.build_provenance.validatePackageHash(self.package_hash);
        try absolute(cache_path);
        const expected_source = try std.fs.path.join(gpa, &.{ cache_path, "p", self.package_hash });
        defer gpa.free(expected_source);
        const blob_name = std.fmt.bytesToHex(self.archive_digest, .lower) ++ ".tar.gz";
        const expected_archive = try std.fs.path.join(gpa, &.{ cache_path, "blobs", blob_name });
        defer gpa.free(expected_archive);
        if (!std.mem.eql(u8, self.source_path, expected_source) or !std.mem.eql(u8, self.archive_path, expected_archive)) return error.PackageSourceOutsideCache;
        var directory = try std.Io.Dir.cwd().openDir(io, self.source_path, .{ .iterate = true });
        defer directory.close(io);
        const real = try directory.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(real);
        if (!std.mem.eql(u8, real, expected_source)) return error.PackageSourceOutsideCache;
        if (!std.mem.eql(u8, &self.tree_digest, &(try jobs.preparation.packageTreeDigest(gpa, io, directory)))) return error.CachedPackageSourceChanged;
        const archive_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, self.archive_path, gpa);
        defer gpa.free(archive_real);
        if (!std.mem.eql(u8, archive_real, expected_archive)) return error.PackageSourceOutsideCache;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.archive_path, gpa, .limited(512 * 1024 * 1024));
        defer gpa.free(bytes);
        if (!std.mem.eql(u8, &self.archive_digest, &jobs.firmware.digest(bytes))) return error.CachedBundleCorrupt;
    }
};
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    source: Source,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Record = struct { version: u16 = 1, package_hash: []const u8, tree_digest: jobs.firmware.Digest, archive_digest: jobs.firmware.Digest };
/// Reuse a previously verified import without running a compiler or downloading.
/// Paths are derived from the selected cache, so complete cache relocation works.
pub fn load(gpa: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, package_hash: []const u8) !?Owned {
    try jobs.build_provenance.validatePackageHash(package_hash);
    const name = try std.fmt.allocPrint(gpa, "source-records/{s}.zon", .{package_hash});
    defer gpa.free(name);
    const bytes = cache.readFileAlloc(io, name, gpa, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    const record = try zon.parse(Record, gpa, text);
    defer zon.free(gpa, record);
    if (record.version != 1) return error.UnsupportedPackageSourceRecord;
    if (!std.mem.eql(u8, record.package_hash, package_hash)) return error.DependencyPackageHashMismatch;
    const base = try cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const source = Source{ .package_hash = try a.dupe(u8, package_hash), .source_path = try std.fs.path.join(a, &.{ base, "p", package_hash }), .tree_digest = record.tree_digest, .archive_path = try std.fs.path.join(a, &.{ base, "blobs", std.fmt.bytesToHex(record.archive_digest, .lower) ++ ".tar.gz" }), .archive_digest = record.archive_digest };
    try source.verify(gpa, io, base);
    return .{ .arena = arena, .source = source };
}
fn saveRecord(gpa: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, source: Source) !void {
    if (try load(gpa, io, cache, source.package_hash)) |cached| {
        var owned = cached;
        defer owned.deinit();
        if (!std.mem.eql(u8, &source.tree_digest, &owned.source.tree_digest)) return error.PackageSourceRecordConflict;
        return;
    }
    var records = try cache.createDirPathOpen(io, "source-records", .{});
    defer records.close(io);
    const base = try cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const actual = try records.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(actual);
    const expected = try std.fs.path.join(gpa, &.{ base, "source-records" });
    defer gpa.free(expected);
    if (!std.mem.eql(u8, expected, actual)) return error.PackageSourceOutsideCache;
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serialize(Record{ .package_hash = source.package_hash, .tree_digest = source.tree_digest, .archive_digest = source.archive_digest }, .{}, &encoded.writer);
    const name = try std.fmt.allocPrint(gpa, "{s}.zon", .{source.package_hash});
    defer gpa.free(name);
    var atomic = try records.createFileAtomic(io, name, .{ .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded.written());
    try atomic.replace(io);
}
fn absolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsolutePackagePathRequired;
}
fn within(child: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, child, parent) or (std.mem.startsWith(u8, child, parent) and child.len > parent.len and std.fs.path.isSep(child[parent.len]));
}
fn fetch(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, compiler: jobs.toolchain.Receipt, cwd: []const u8, input: []const u8, expected: ?[]const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, compiler.compiler, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    if (!std.mem.eql(u8, &jobs.firmware.digest(bytes), &compiler.compiler_digest)) return error.CompilerDigestMismatch;
    var result = try jobs.run(gpa, io, .{ .argv = &.{ compiler.compiler, "fetch", input }, .cwd = cwd, .snapshot_id = compiler.compiler_digest, .timeout_ms = 120_000, .environ_map = environment });
    defer result.deinit(gpa);
    if (!result.successful()) return error.PackageFetchFailed;
    const actual = std.mem.trim(u8, result.process.stdout, "\r\n");
    try jobs.build_provenance.validatePackageHash(actual);
    if (expected) |hash| if (!std.mem.eql(u8, actual, hash)) return error.DependencyPackageHashMismatch;
    return gpa.dupe(u8, actual);
}
fn descend(gpa: std.mem.Allocator, io: std.Io, directory: *std.Io.Dir) !bool {
    var iterator = directory.iterate();
    const entry = (try iterator.next(io)) orelse return false;
    if (entry.kind != .directory) return false;
    const child_name = try gpa.dupe(u8, entry.name);
    defer gpa.free(child_name);
    if (try iterator.next(io) != null) return false;
    const child = try directory.openDir(io, child_name, .{ .iterate = true });
    directory.close(io);
    directory.* = child;
    return true;
}
pub fn relative(name: []const u8, package_hash: []const u8) ![]const u8 {
    return relativeForPlatform(name, package_hash, @import("builtin").os.tag == .windows);
}
fn relativeForPlatform(name: []const u8, package_hash: []const u8, windows: bool) ![]const u8 {
    if (!std.mem.startsWith(u8, name, package_hash) or name.len <= package_hash.len or name[package_hash.len] != '/') return error.InvalidPackageArchivePath;
    const path = name[package_hash.len + 1 ..];
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidPackageArchivePath;
    for (path) |byte| if (byte < 32 or byte == '\\' or (windows and byte == ':')) return error.InvalidPackageArchivePath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        // A colon inside a POSIX filename is data; drive prefixes remain refused.
        if (component.len >= 2 and std.ascii.isAlphabetic(component[0]) and component[1] == ':') return error.InvalidPackageArchivePath;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or (component.len != 0 and (component[component.len - 1] == '.' or component[component.len - 1] == ' '))) return error.InvalidPackageArchivePath;
        const stem = component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len];
        for ([_][]const u8{ "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.InvalidPackageArchivePath;
    }
    return path;
}
fn unpack(gpa: std.mem.Allocator, io: std.Io, archive: []const u8, package_hash: []const u8, output: std.Io.Dir) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var pending: std.ArrayList(struct { path: []const u8, target: []const u8, done: bool = false }) = .empty;
    var file = try std.Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var input_buffer: [8192]u8 = undefined;
    var input = file.reader(io, &input_buffer);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input.interface, .gzip, &decompress_buffer);
    var names: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var links: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&decompress.reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var total: u64 = 0;
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        count += 1;
        if (count > 100_000 or entry.size > 32 * 1024 * 1024) return error.PackageArchiveTooLarge;
        total += entry.size;
        if (total > jobs.preparation.package_max_bytes) return error.PackageArchiveTooLarge;
        if (entry.kind == .directory and std.mem.eql(u8, std.mem.trimEnd(u8, entry.name, "/"), package_hash)) continue;
        const path = try relative(entry.name, package_hash);
        switch (entry.kind) {
            .sym_link => {
                if (pending.items.len >= 4096 or entry.size != 0 or entry.link_name.len == 0 or std.fs.path.isAbsolute(entry.link_name)) return error.InvalidPackageArchiveLink;
                for (entry.link_name) |byte| if (byte < 32 or byte == '\\' or byte == ':') return error.InvalidPackageArchiveLink;
                try pending.append(a, .{ .path = try a.dupe(u8, path), .target = try a.dupe(u8, entry.link_name) });
            },
            .directory => try output.createDirPath(io, path),
            .file => {
                if (std.fs.path.dirname(path)) |parent| try output.createDirPath(io, parent);
                var destination = try output.createFile(io, path, .{ .exclusive = true, .permissions = if (entry.mode & 0o100 != 0) .executable_file else .default_file });
                defer destination.close(io);
                var buffer: [8192]u8 = undefined;
                var writer = destination.writer(io, &buffer);
                try iterator.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
            },
        }
    }
    // Links are created only after regular files, preventing archive writes
    // through earlier symlink entries. Resolve chains in bounded passes.
    const root = try output.realPathFileAlloc(io, ".", a);
    var remaining = pending.items.len;
    while (remaining != 0) {
        var progress = false;
        for (pending.items) |*link| {
            if (link.done) continue;
            const actual = try std.fs.path.resolveAlloc(a, &.{ root, std.fs.path.dirname(link.path) orelse ".", link.target });
            if (!within(actual, root)) return error.InvalidPackageArchiveLink;
            const stat = std.Io.Dir.cwd().statFile(io, actual, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, actual, a);
            if (!within(canonical, root)) return error.InvalidPackageArchiveLink;
            if (std.fs.path.dirname(link.path)) |parent| try output.createDirPath(io, parent);
            try output.symLink(io, link.target, link.path, .{ .is_directory = stat.kind == .directory });
            link.done = true;
            remaining -= 1;
            progress = true;
        }
        if (!progress) return error.PackageArchiveLinkCycleOrMissingTarget;
    }
}
/// The caller supplies an existing owned cache directory and deliberate input.
/// A fresh child cache canonicalizes package bytes through the verified compiler.
/// Existing source trees must match the canonical archive; conflicts are preserved.
pub fn acquire(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, compiler: jobs.toolchain.Receipt, cache: std.Io.Dir, package_hash: []const u8, input: Input) !Owned {
    try jobs.build_provenance.validatePackageHash(package_hash);
    switch (input) {
        .offline_archive => |path| {
            try absolute(path);
            if ((try std.Io.Dir.cwd().statFile(io, path, .{})).kind != .file) return error.PackageArchiveFileRequired;
        },
        .download => |url| {
            if (!std.mem.startsWith(u8, url, "https://")) return error.DataArchiveUrlRequired;
            for (url) |byte| if (byte < 33 or byte == '\\') return error.DataArchiveUrlRequired;
        },
    }
    const base = try cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    if (base.len < 2 or within(base, compiler.distribution) or within(compiler.distribution, base)) return error.PackageCacheOverlapsToolchain;
    try compiler.verify(gpa, io);
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const temporary_name = ".package-" ++ std.fmt.bytesToHex(nonce, .lower);
    try cache.createDir(io, temporary_name, .default_dir);
    defer cache.deleteTree(io, temporary_name) catch {};
    var temporary = try cache.openDir(io, temporary_name, .{ .iterate = true });
    defer temporary.close(io);
    const temporary_path = try temporary.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(temporary_path);
    var child_environment = try environment.clone(gpa);
    defer child_environment.deinit();
    try child_environment.put("ZIG_GLOBAL_CACHE_DIR", temporary_path);
    const selected = switch (input) {
        .offline_archive, .download => |value| value,
    };
    const fetched = try fetch(gpa, io, &child_environment, compiler, temporary_path, selected, package_hash);
    defer gpa.free(fetched);
    const archive_path = try std.fmt.allocPrint(gpa, "{s}/p/{s}.tar.gz", .{ temporary_path, package_hash });
    defer gpa.free(archive_path);
    var sources = try temporary.createDirPathOpen(io, "sources", .{ .open_options = .{ .iterate = true } });
    defer sources.close(io);
    try unpack(gpa, io, archive_path, package_hash, sources);
    var package_root = try sources.openDir(io, ".", .{ .iterate = true });
    defer package_root.close(io);
    // Zig 0.17's cache recompression may retain a common archive wrapper. Each
    // candidate is rehashed; only a unique directory may be descended into.
    var matched = false;
    for (0..8) |_| {
        const candidate = try package_root.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(candidate);
        const hash = try fetch(gpa, io, &child_environment, compiler, temporary_path, candidate, null);
        defer gpa.free(hash);
        if (std.mem.eql(u8, hash, package_hash)) {
            matched = true;
            break;
        }
        if (!try descend(gpa, io, &package_root)) break;
    }
    if (!matched) return error.DependencyPackageHashMismatch;
    const sources_path = try package_root.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(sources_path);
    const tree = try jobs.preparation.packageTreeDigest(gpa, io, package_root);
    const archive_bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive_path, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(archive_bytes);
    const archive_digest = jobs.firmware.digest(archive_bytes);
    try compiler.verify(gpa, io);
    try cache.createDirPath(io, "p");
    var packages = try cache.openDir(io, "p", .{ .iterate = true });
    defer packages.close(io);
    const packages_path = try packages.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(packages_path);
    const expected_packages = try std.fs.path.join(gpa, &.{ base, "p" });
    defer gpa.free(expected_packages);
    if (!std.mem.eql(u8, packages_path, expected_packages)) return error.PackageSourceOutsideCache;
    const existing = packages.openDir(io, package_hash, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |directory| {
        defer directory.close(io);
        const actual = try directory.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(actual);
        const expected = try std.fs.path.join(gpa, &.{ packages_path, package_hash });
        defer gpa.free(expected);
        if (!std.mem.eql(u8, actual, expected)) return error.PackageSourceOutsideCache;
        if (!std.mem.eql(u8, &tree, &(try jobs.preparation.packageTreeDigest(gpa, io, directory)))) return error.CachedPackageSourceChanged;
    } else try std.Io.Dir.cwd().renamePreserve(sources_path, packages, package_hash, io);
    var blobs = try cache.createDirPathOpen(io, "blobs", .{});
    defer blobs.close(io);
    const blobs_path = try blobs.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(blobs_path);
    const expected_blobs = try std.fs.path.join(gpa, &.{ base, "blobs" });
    defer gpa.free(expected_blobs);
    if (!std.mem.eql(u8, blobs_path, expected_blobs)) return error.PackageSourceOutsideCache;
    const blob_name = std.fmt.bytesToHex(archive_digest, .lower) ++ ".tar.gz";
    const old_blob = blobs.readFileAlloc(io, blob_name, gpa, .limited(512 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old_blob) |bytes| {
        defer gpa.free(bytes);
        if (!std.mem.eql(u8, &archive_digest, &jobs.firmware.digest(bytes))) return error.CachedBundleCorrupt;
    } else {
        var blob = try blobs.createFileAtomic(io, blob_name, .{ .replace = false });
        defer blob.deinit(io);
        try blob.file.writeStreamingAll(io, archive_bytes);
        try blob.replace(io);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const source_path = try std.fs.path.join(arena.allocator(), &.{ packages_path, package_hash });
    const blob_path = try std.fs.path.join(arena.allocator(), &.{ base, "blobs", blob_name });
    const source = try zon.clone(arena.allocator(), Source{ .package_hash = package_hash, .source_path = source_path, .tree_digest = tree, .archive_path = blob_path, .archive_digest = archive_digest });
    try saveRecord(gpa, io, cache, source);
    return .{ .arena = arena, .source = source };
}
test "package archive paths reject escapes links aliases and device names" {
    const t = std.testing;
    try t.expectEqualStrings("src/main.zig", try relative("pin/src/main.zig", "pin"));
    for ([_][]const u8{ "other/src.zig", "pin/../escape", "pin/a/../../escape", "pin/C:stream", "pin/a\\escape", "pin/a/CON.txt", "pin/a/lpt1", "pin/trailing.", "pin/trailing " }) |path| try t.expectError(error.InvalidPackageArchivePath, relative(path, "pin"));
}

test "package archive paths preserve POSIX colon names without Windows streams" {
    const t = std.testing;
    const name = "pin/samples/USB Device 0x46d:0x9a4--USB Mixer";
    try t.expectEqualStrings("samples/USB Device 0x46d:0x9a4--USB Mixer", try relativeForPlatform(name, "pin", false));
    try t.expectError(error.InvalidPackageArchivePath, relativeForPlatform(name, "pin", true));
    for ([_][]const u8{ "pin/C:stream", "pin/sub/D:drive", "pin/../escape" }) |path| {
        try t.expectError(error.InvalidPackageArchivePath, relativeForPlatform(path, "pin", false));
        try t.expectError(error.InvalidPackageArchivePath, relativeForPlatform(path, "pin", true));
    }
    if (@import("builtin").os.tag == .windows) return;
    var fixture = t.tmpDir(.{});
    defer fixture.cleanup();
    var destination = t.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    var bytes: std.Io.Writer.Allocating = .init(t.allocator);
    defer bytes.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.Raw.init(&bytes.writer, &window, .gzip);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
    try tar.writeFileBytes(name, "mixer sample", .{});
    try tar.finishPedantically();
    try gzip.finish();
    try fixture.dir.writeFile(t.io, .{ .sub_path = "colon.tar.gz", .data = bytes.written() });
    const archive = try fixture.dir.realPathFileAlloc(t.io, "colon.tar.gz", t.allocator);
    defer t.allocator.free(archive);
    try unpack(t.allocator, t.io, archive, "pin", destination.dir);
    const extracted = try destination.dir.readFileAlloc(t.io, name[4..], t.allocator, .limited(128));
    defer t.allocator.free(extracted);
    try t.expectEqualStrings("mixer sample", extracted);
    _ = try jobs.preparation.packageTreeDigest(t.allocator, t.io, destination.dir);
}

test "package source records rebase paths verify bytes and preserve unsupported versions" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const hash = "N-V-__8AAA46JQABKU7sa-6xGUAN44uFsYSUS_w79UVuu7qo";
    try t.expect(try load(t.allocator, t.io, tmp.dir, hash) == null);
    const relative_source = try std.fs.path.join(t.allocator, &.{ "p", hash });
    defer t.allocator.free(relative_source);
    var directory = try tmp.dir.createDirPathOpen(t.io, relative_source, .{ .open_options = .{ .iterate = true } });
    defer directory.close(t.io);
    try directory.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    var blobs = try tmp.dir.createDirPathOpen(t.io, "blobs", .{});
    defer blobs.close(t.io);
    const archive = "metadata-only archive fixture";
    const archive_digest = jobs.firmware.digest(archive);
    const blob_name = std.fmt.bytesToHex(archive_digest, .lower) ++ ".tar.gz";
    try blobs.writeFile(t.io, .{ .sub_path = blob_name, .data = archive });
    const source_path = try directory.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(source_path);
    const archive_path = try blobs.realPathFileAlloc(t.io, blob_name, t.allocator);
    defer t.allocator.free(archive_path);
    const source = Source{ .package_hash = hash, .source_path = source_path, .tree_digest = try jobs.preparation.treeDigest(t.allocator, t.io, directory), .archive_path = archive_path, .archive_digest = archive_digest };
    try saveRecord(t.allocator, t.io, tmp.dir, source);
    var cached = (try load(t.allocator, t.io, tmp.dir, hash)).?;
    defer cached.deinit();
    try t.expectEqual(source.tree_digest, cached.source.tree_digest);
    const record_path = try std.fmt.allocPrint(t.allocator, "source-records/{s}.zon", .{hash});
    defer t.allocator.free(record_path);
    const original_record = try tmp.dir.readFileAlloc(t.io, record_path, t.allocator, .limited(16 * 1024));
    defer t.allocator.free(original_record);
    var moved = t.tmpDir(.{ .iterate = true });
    defer moved.cleanup();
    var moved_source = try moved.dir.createDirPathOpen(t.io, relative_source, .{});
    defer moved_source.close(t.io);
    try moved_source.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    var moved_blobs = try moved.dir.createDirPathOpen(t.io, "blobs", .{});
    defer moved_blobs.close(t.io);
    try moved_blobs.writeFile(t.io, .{ .sub_path = blob_name, .data = archive });
    try moved.dir.createDirPath(t.io, "source-records");
    try moved.dir.writeFile(t.io, .{ .sub_path = record_path, .data = original_record });
    var rebased = (try load(t.allocator, t.io, moved.dir, hash)).?;
    defer rebased.deinit();
    try t.expectEqual(source.tree_digest, rebased.source.tree_digest);
    try t.expect(!std.mem.eql(u8, source.source_path, rebased.source.source_path));
    try moved_blobs.writeFile(t.io, .{ .sub_path = blob_name, .data = "corrupt archive" });
    try t.expectError(error.CachedBundleCorrupt, load(t.allocator, t.io, moved.dir, hash));
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    try std.zon.stringify.serialize(Record{ .version = 2, .package_hash = hash, .tree_digest = source.tree_digest, .archive_digest = source.archive_digest }, .{}, &output.writer);
    try tmp.dir.writeFile(t.io, .{ .sub_path = record_path, .data = output.written() });
    try t.expectError(error.UnsupportedPackageSourceRecord, load(t.allocator, t.io, tmp.dir, hash));
    try t.expectError(error.UnsupportedPackageSourceRecord, saveRecord(t.allocator, t.io, tmp.dir, source));
    const retained = try tmp.dir.readFileAlloc(t.io, record_path, t.allocator, .limited(16 * 1024));
    defer t.allocator.free(retained);
    try t.expectEqualStrings(output.written(), retained);
}

fn linkArchiveFixture(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, target: []const u8, chain: bool) ![:0]u8 {
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.Raw.init(&bytes.writer, &buffer, .gzip);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
    try tar.setRoot("pin");
    try tar.writeLink("alias", target, .{}); // Deliberately before the target file.
    if (chain) try tar.writeLink("chain", "source.zig", .{});
    try tar.writeFileBytes("source.zig", "source bytes", .{});
    try tar.finishPedantically();
    try gzip.finish();
    try directory.writeFile(io, .{ .sub_path = "links.tar.gz", .data = bytes.written() });
    return directory.realPathFileAlloc(io, "links.tar.gz", gpa);
}
test "package archive paths defer links and refuse escaped or missing targets" {
    const t = std.testing;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fixture = t.tmpDir(.{});
    defer fixture.cleanup();
    var destination = t.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    const safe = try linkArchiveFixture(t.allocator, t.io, fixture.dir, "chain", true);
    defer t.allocator.free(safe);
    try unpack(t.allocator, t.io, safe, "pin", destination.dir);
    const bytes = try destination.dir.readFileAlloc(t.io, "alias", t.allocator, .limited(128));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("source bytes", bytes);
    _ = try jobs.preparation.packageTreeDigest(t.allocator, t.io, destination.dir);
    var escape = t.tmpDir(.{});
    defer escape.cleanup();
    const unsafe = try linkArchiveFixture(t.allocator, t.io, fixture.dir, "../outside", false);
    defer t.allocator.free(unsafe);
    try t.expectError(error.InvalidPackageArchiveLink, unpack(t.allocator, t.io, unsafe, "pin", escape.dir));
    var missing = t.tmpDir(.{});
    defer missing.cleanup();
    const absent = try linkArchiveFixture(t.allocator, t.io, fixture.dir, "absent", false);
    defer t.allocator.free(absent);
    try t.expectError(error.PackageArchiveLinkCycleOrMissingTarget, unpack(t.allocator, t.io, absent, "pin", missing.dir));
}
