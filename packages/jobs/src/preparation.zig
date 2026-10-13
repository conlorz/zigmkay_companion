//! Explicit offline preparation only. Opening/editing project data never calls this API.
const std = @import("std");
const sources = @import("source_files.zig");
const firmware = @import("firmware.zig");
pub const Digest = [32]u8;
pub const package_max_bytes: usize = 256 * 1024 * 1024;

fn length(hash: *std.crypto.hash.sha2.Sha256, n: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, n, .little);
    hash.update(&bytes);
}

/// Hash the exact explicitly selected source root, including hidden source files.
/// Excludes only VCS/build outputs and resolved package caches. Dependencies have
/// their own lock digest; symlinks are rejected rather than silently escaping root.
pub fn treeDigest(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Digest {
    return tree(gpa, io, dir, false);
}
/// Package imports may contain relative links whose targets stay in hashed sources.
/// File-only trees retain the original digest. Links add a distinct framed domain.
pub fn packageTreeDigest(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Digest {
    return tree(gpa, io, dir, true);
}
pub fn packageLink(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = buffer[0..try dir.readLink(io, path, &buffer)];
    if (target.len == 0 or std.fs.path.isAbsolute(target)) return error.PackageLinkEscapesRoot;
    for (target) |byte| if (byte < 32 or byte == '\\' or byte == ':') return error.PackageLinkEscapesRoot;
    const root = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const actual = try dir.realPathFileAlloc(io, path, gpa);
    defer gpa.free(actual);
    if (!std.mem.eql(u8, actual, root) and (!std.mem.startsWith(u8, actual, root) or actual.len <= root.len or !std.fs.path.isSep(actual[root.len]))) return error.PackageLinkEscapesRoot;
    var components = std.mem.tokenizeAny(u8, actual[root.len..], "/\\");
    while (components.next()) |component| for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" }) |excluded| if (std.mem.eql(u8, component, excluded)) return error.PackageLinkTargetsExcludedInput;
    return gpa.dupe(u8, target);
}
fn excludedDirectory(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
    return kind == .directory and
        (std.mem.eql(u8, name, ".git") or
            std.mem.eql(u8, name, ".zig-cache") or
            std.mem.eql(u8, name, "zig-out") or
            std.mem.eql(u8, name, "zig-pkg"));
}

fn tree(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, allow_links: bool) !Digest {
    const policy: sources.Policy = .{ .excluded = excludedDirectory, .max_files = 10_000 };
    const files = try sources.collect(gpa, io, dir, policy);
    defer sources.free(gpa, files);
    var has_links = false;
    for (files) |file| if (file.kind == .sym_link) {
        has_links = true;
    };
    if (has_links and !allow_links) return error.UnsupportedSourceKind;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(if (has_links) "zigmkay-package-tree-links-v1\x00" else "zigmkay-source-tree-v1\x00");
    var total: usize = 0;
    for (files) |file| {
        if (file.kind != .file and file.kind != .sym_link) return error.UnsupportedSourceKind;
        const bytes = if (file.kind == .sym_link) try packageLink(gpa, io, dir, file.path) else try dir.readFileAlloc(io, file.path, gpa, .limited(32 * 1024 * 1024));
        defer gpa.free(bytes);
        total += bytes.len;
        if (total > (if (allow_links) package_max_bytes else 128 * 1024 * 1024)) return error.SourceTreeTooLarge;
        if (has_links) hash.update(&.{if (file.kind == .sym_link) @as(u8, 2) else 1});
        length(&hash, file.path.len);
        // Canonicalize directory separators for identical Windows/POSIX sources.
        for (file.path) |c| hash.update(&.{if (c == '\\') '/' else c});
        length(&hash, bytes.len);
        hash.update(bytes);
    }
    return hash.finalResult();
}

/// Import an already obtained archive/blob into a caller-owned cache by digest.
/// A corrupt pre-existing entry is reported and preserved for diagnosis. No
/// archive extraction, network, tool execution or device operation takes place.
pub fn importBlob(gpa: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, expected: Digest, bytes: []const u8) !void {
    if (!std.mem.eql(u8, &expected, &firmware.digest(bytes))) return error.BundleDigestMismatch;
    const name = std.fmt.bytesToHex(expected, .lower);
    const present = cache.readFileAlloc(io, &name, gpa, .limited(512 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (present) |data| {
        defer gpa.free(data);
        if (!std.mem.eql(u8, &expected, &firmware.digest(data))) return error.CachedBundleCorrupt;
        return;
    }
    var atomic = try cache.createFileAtomic(io, &name, .{ .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // A concurrent importer won the race. Never overwrite its entry.
            const existing = try cache.readFileAlloc(io, &name, gpa, .limited(512 * 1024 * 1024));
            defer gpa.free(existing);
            if (!std.mem.eql(u8, &expected, &firmware.digest(existing))) return error.CachedBundleCorrupt;
        },
        else => return err,
    };
}

/// Byte verification is performed immediately before running this deliberately
/// selected compiler's version command. The full distribution is pinned
/// independently by compiler_bundle_digest in the target lock.
pub fn verifyCompiler(gpa: std.mem.Allocator, io: std.Io, compiler: []const u8, expected: Digest) !void {
    if (!std.fs.path.isAbsolute(compiler) or std.mem.indexOfScalar(u8, compiler, 0) != null) return error.InvalidCompilerPath;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, compiler, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    if (!std.mem.eql(u8, &expected, &firmware.digest(bytes))) return error.CompilerDigestMismatch;
    var result = try @import("root.zig").run(gpa, io, .{ .argv = &.{ compiler, "version" }, .cwd = std.fs.path.dirname(compiler).?, .snapshot_id = @splat(0), .timeout_ms = 5000 });
    defer result.deinit(gpa);
    if (!result.successful() or !std.mem.eql(u8, std.mem.trim(u8, result.process.stdout, "\r\n"), "0.17.0")) return error.UnsupportedCompilerVersion;
}

test "offline bundle imports are immutable and verify existing cache bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "offline prepared source bundle";
    const expected = firmware.digest(bytes);
    try std.testing.expectError(error.BundleDigestMismatch, importBlob(gpa, io, tmp.dir, expected, "modified"));
    const name = std.fmt.bytesToHex(expected, .lower);
    try importBlob(gpa, io, tmp.dir, expected, bytes);
    const created = try tmp.dir.readFileAlloc(io, &name, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(created);
    try std.testing.expectEqualStrings(bytes, created);
    try importBlob(gpa, io, tmp.dir, expected, bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = &name, .data = "corrupt" });
    try std.testing.expectError(error.CachedBundleCorrupt, importBlob(gpa, io, tmp.dir, expected, bytes));
    const preserved = try tmp.dir.readFileAlloc(io, &name, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(preserved);
    try std.testing.expectEqualStrings("corrupt", preserved);
}

test "source trees ignore caches but retain hidden and non-Zig build inputs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "source" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigversion", .data = "0.17.0" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bridge.c", .data = "imported source" });
    const original = try treeDigest(gpa, io, tmp.dir);
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/output", .data = "ignored" });
    try std.testing.expectEqual(original, try treeDigest(gpa, io, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "bridge.c", .data = "changed" });
    try std.testing.expect(!std.mem.eql(u8, &original, &try treeDigest(gpa, io, tmp.dir)));
}

test "excluded directories ignore nested contents but same-named files remain inputs" {
    const t = std.testing;
    const names = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" };
    for (names) |name| {
        try t.expect(excludedDirectory("nested", name, .directory));
        try t.expect(!excludedDirectory("nested", name, .file));
    }
    try t.expect(!excludedDirectory("nested", "ordinary", .directory));

    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source.zig", .data = "source" });
    const original = try treeDigest(t.allocator, t.io, tmp.dir);
    for (names) |name| {
        const nested = try std.fmt.allocPrint(t.allocator, "{s}/deep", .{name});
        defer t.allocator.free(nested);
        try tmp.dir.createDirPath(t.io, nested);
        const path = try std.fmt.allocPrint(t.allocator, "{s}/ignored.zig", .{nested});
        defer t.allocator.free(path);
        try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = "ignored contents" });
    }
    try t.expectEqual(original, try treeDigest(t.allocator, t.io, tmp.dir));
    try tmp.dir.createDirPath(t.io, "ordinary");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ordinary/kept.zig", .data = "kept" });
    try t.expect(!std.mem.eql(u8, &original, &try treeDigest(t.allocator, t.io, tmp.dir)));
}

test "package tree links stay contained and never bypass excluded inputs" {
    const t = std.testing;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source.zig", .data = "source bytes" });
    try t.expectEqual(try treeDigest(t.allocator, t.io, tmp.dir), try packageTreeDigest(t.allocator, t.io, tmp.dir));
    try tmp.dir.symLink(t.io, "source.zig", "alias.zig", .{});
    try t.expectError(error.UnsupportedSourceKind, treeDigest(t.allocator, t.io, tmp.dir));
    const before = try packageTreeDigest(t.allocator, t.io, tmp.dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source.zig", .data = "changed target bytes" });
    try t.expect(!std.mem.eql(u8, &before, &(try packageTreeDigest(t.allocator, t.io, tmp.dir))));
    try tmp.dir.createDirPath(t.io, ".zig-cache");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zig-cache/hidden.zig", .data = "excluded bytes" });
    try tmp.dir.symLink(t.io, ".zig-cache/hidden.zig", "excluded-link", .{});
    try t.expectError(error.PackageLinkTargetsExcludedInput, packageTreeDigest(t.allocator, t.io, tmp.dir));
    try tmp.dir.deleteFile(t.io, "excluded-link");
    try tmp.dir.symLink(t.io, "..", "escape", .{ .is_directory = true });
    try t.expectError(error.PackageLinkEscapesRoot, packageTreeDigest(t.allocator, t.io, tmp.dir));
    try tmp.dir.deleteFile(t.io, "escape");
    try tmp.dir.symLink(t.io, "cycle", "cycle", .{});
    try t.expectError(error.SymLinkLoop, packageTreeDigest(t.allocator, t.io, tmp.dir));
}
