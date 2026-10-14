//! Explicit data-only acquisition. No dependency build scripts, GUI or devices.
const std = @import("std");
const jobs = @import("companion-jobs");
pub const receipt_name = "source-inputs.zon";
const pins = @import("desktop_dependency_pins.zig");
pub const dvui_revision = pins.dvui_revision;
pub const ztray_revision = pins.ztray_revision;
pub const dvui_url = pins.dvui_url;
pub const ztray_url = pins.ztray_url;
pub const dvui_hash = pins.dvui_hash;
pub const ztray_hash = pins.ztray_hash;
pub const svg2tvg_revision = pins.svg2tvg_revision;
pub const svg2tvg_url = pins.svg2tvg_url;
pub const svg2tvg_hash = pins.svg2tvg_hash;
pub const icons_revision = pins.icons_revision;
pub const icons_url = pins.icons_url;
pub const icons_hash = pins.icons_hash;
pub const Source = struct { revision: []const u8, url: []const u8, package_hash: []const u8, source_path: []const u8, tree_digest: [32]u8 };
pub const Receipt = struct {
    version: u16 = 1,
    compiler_version: []const u8 = "0.17.0",
    compiler_path: []const u8,
    compiler_digest: [32]u8,
    cache_path: []const u8,
    dvui: Source,
    ztray: Source,
    svg2tvg: ?Source = null,
    icons: ?Source = null,
    pub fn validate(self: Receipt) !void {
        if (self.version != 1) return error.UnsupportedSourceInputsVersion;
        if (!std.mem.eql(u8, self.compiler_version, "0.17.0")) return error.UnsupportedCompilerVersion;
        try absolute(self.compiler_path);
        try absolute(self.cache_path);
        if (self.cache_path.len == 1 or std.fs.path.isSep(self.cache_path[self.cache_path.len - 1])) return error.InvalidCachePath;
        try validateSource(self.dvui, self.cache_path, dvui_revision, dvui_url, dvui_hash);
        try validateSource(self.ztray, self.cache_path, ztray_revision, ztray_url, ztray_hash);
        if ((self.svg2tvg == null) != (self.icons == null)) return error.IncompleteVectorSources;
        if (self.svg2tvg) |source| try validateSource(source, self.cache_path, svg2tvg_revision, svg2tvg_url, svg2tvg_hash);
        if (self.icons) |source| try validateSource(source, self.cache_path, icons_revision, icons_url, icons_hash);
    }
    pub fn serialize(self: Receipt, gpa: std.mem.Allocator) ![]u8 {
        try self.validate();
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        try std.zon.stringify.serializeMaxDepth(self, .{}, &writer.writer, 8);
        return writer.toOwnedSlice();
    }
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Receipt {
        if (bytes.len > 32 * 1024) return error.SourceInputsTooLarge;
        const text = try gpa.dupeSentinel(u8, bytes, 0);
        defer gpa.free(text);
        const value = try @import("owned-zon").parse(Receipt, gpa, text);
        errdefer value.deinit(gpa);
        try value.validate();
        return value;
    }
    pub fn deinit(self: Receipt, gpa: std.mem.Allocator) void {
        @import("owned-zon").free(gpa, self);
    }
};
fn absolute(value: []const u8) !void {
    if (!std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.AbsolutePathRequired;
}
fn validateSource(source: Source, cache: []const u8, revision: []const u8, url: []const u8, hash: []const u8) !void {
    if (!std.mem.eql(u8, source.revision, revision) or !std.mem.eql(u8, source.url, url) or !std.mem.eql(u8, source.package_hash, hash)) return error.UnsupportedSourceContract;
    try absolute(source.source_path);
    const suffix_len = 3 + hash.len;
    if (source.source_path.len != cache.len + suffix_len or !std.mem.eql(u8, source.source_path[0..cache.len], cache) or !std.mem.eql(u8, source.source_path[cache.len..][0..3], "/p/") or !std.mem.eql(u8, source.source_path[cache.len + 3 ..], hash)) return error.SourceOutsideSelectedCache;
}
fn compilerHash(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    return jobs.firmware.digest(bytes);
}
fn fetch(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, compiler: []const u8, cache: []const u8, packages: []const u8, local: []const u8, input: []const u8, expected: []const u8) !void {
    _ = packages;
    _ = local;
    // Zig 0.17 rejects --global-cache-dir, and --pkg-dir/--cache-dir only
    // influence --save, which would mutate a manifest. Pass the supported
    // global-cache environment override on the directly launched compiler.
    var result = try jobs.run(gpa, io, .{ .argv = &.{ compiler, "fetch", input }, .cwd = cache, .snapshot_id = @splat(0), .timeout_ms = 120_000, .environ_map = environ });
    defer result.deinit(gpa);
    if (!result.successful()) return error.DependencyFetchFailed;
    if (!std.mem.eql(u8, std.mem.trim(u8, result.process.stdout, "\r\n"), expected)) return error.DependencyPackageHashMismatch;
}
fn archivePath(name: []const u8, hash: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, name, hash) or name.len <= hash.len or name[hash.len] != '/') return error.InvalidArchivePath;
    const relative = name[hash.len + 1 ..];
    if (relative.len == 0 or std.fs.path.isAbsolute(relative) or std.mem.indexOfScalar(u8, relative, '\\') != null or std.mem.indexOfScalar(u8, relative, 0) != null) return error.InvalidArchivePath;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidArchivePath;
    return relative;
}
fn unpack(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, compiler: []const u8, cache: []const u8, packages: []const u8, local: []const u8, hash: []const u8) !void {
    const archive = try std.fmt.allocPrint(gpa, "{s}/{s}.tar.gz", .{ packages, hash });
    defer gpa.free(archive);
    const temporary = try std.fmt.allocPrint(gpa, "{s}/{s}.unpack", .{ packages, hash });
    defer gpa.free(temporary);
    try std.Io.Dir.cwd().createDir(io, temporary, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    var output = try std.Io.Dir.cwd().openDir(io, temporary, .{});
    defer output.close(io);
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
        if (count > 10_000 or entry.size > 32 * 1024 * 1024) return error.ArchiveTooLarge;
        total += entry.size;
        if (total > 128 * 1024 * 1024) return error.ArchiveTooLarge;
        const relative = try archivePath(entry.name, hash);
        switch (entry.kind) {
            .sym_link => return error.UnsupportedArchiveLink,
            .directory => try output.createDirPath(io, relative),
            .file => {
                if (std.fs.path.dirname(relative)) |parent| try output.createDirPath(io, parent);
                var dest = try output.createFile(io, relative, .{ .exclusive = true });
                defer dest.close(io);
                var buffer: [8192]u8 = undefined;
                var writer = dest.writer(io, &buffer);
                try iterator.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
            },
        }
    }
    try fetch(gpa, io, environ, compiler, cache, packages, local, temporary, hash);
    const final = try std.fs.path.join(gpa, &.{ packages, hash });
    defer gpa.free(final);
    try std.Io.Dir.cwd().renamePreserve(temporary, std.Io.Dir.cwd(), final, io);
}
fn acquire(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, compiler: []const u8, cache: []const u8, packages: []const u8, local: []const u8, revision: []const u8, url: []const u8, hash: []const u8) !Source {
    const path = try std.fs.path.join(gpa, &.{ packages, hash });
    errdefer gpa.free(path);
    const present = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (present) |value| {
        var existing = value;
        defer existing.close(io);
        const existing_real = try existing.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(existing_real);
        if (!std.mem.eql(u8, path, existing_real)) return error.SourceOutsideSelectedCache;
        // Hash existing source before fetching its URL: a corrupt cached entry
        // is preserved and rejected rather than accepted by its directory name.
        try fetch(gpa, io, environ, compiler, cache, packages, local, path, hash);
    } else {
        try fetch(gpa, io, environ, compiler, cache, packages, local, url, hash);
        try unpack(gpa, io, environ, compiler, cache, packages, local, hash);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const real = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(real);
    if (!std.mem.eql(u8, path, real)) return error.SourceOutsideSelectedCache;
    try fetch(gpa, io, environ, compiler, cache, packages, local, path, hash);
    return .{ .revision = revision, .url = url, .package_hash = hash, .source_path = path, .tree_digest = try jobs.preparation.treeDigest(gpa, io, dir) };
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3 and args.len != 4) return error.Usage;
    const vectors = args.len == 4;
    if (vectors and !std.mem.eql(u8, args[3], "--vector")) return error.Usage;
    try absolute(args[1]);
    try absolute(args[2]);
    const compiler = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], gpa);
    const compiler_digest = try compilerHash(gpa, io, compiler);
    try std.Io.Dir.cwd().createDirPath(io, args[2]);
    var directory = try std.Io.Dir.cwd().openDir(io, args[2], .{ .iterate = true });
    defer directory.close(io);
    const cache = try directory.realPathFileAlloc(io, ".", gpa);
    var child_env = try init.environ_map.clone(gpa);
    defer child_env.deinit();
    try child_env.put("ZIG_GLOBAL_CACHE_DIR", cache);
    const existing_bytes = directory.readFileAlloc(io, receipt_name, gpa, .limited(32 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var existing: ?Receipt = null;
    defer if (existing) |old| old.deinit(gpa);
    if (existing_bytes) |bytes| {
        existing = try Receipt.parse(gpa, bytes);
        const old = existing.?;
        // Cached GUI sources belong to immutable package pins, not to the
        // installation path of the compiler that originally downloaded them.
        // The selected compiler version is checked below before any fetch.
        if (!std.mem.eql(u8, old.cache_path, cache)) return error.SourceInputsChanged;
    }
    var version = try jobs.run(gpa, io, .{ .argv = &.{ compiler, "version" }, .cwd = cache, .snapshot_id = compiler_digest, .timeout_ms = 5000 });
    defer version.deinit(gpa);
    if (!version.successful() or !std.mem.eql(u8, std.mem.trim(u8, version.process.stdout, "\r\n"), "0.17.0")) return error.UnsupportedCompilerVersion;
    const packages = try std.fs.path.join(gpa, &.{ cache, "p" });
    const local = try std.fs.path.join(gpa, &.{ cache, "fetch" });
    try directory.createDirPath(io, "p");
    try directory.createDirPath(io, "fetch");
    const packages_real = try directory.realPathFileAlloc(io, "p", gpa);
    const local_real = try directory.realPathFileAlloc(io, "fetch", gpa);
    if (!std.mem.eql(u8, packages, packages_real) or !std.mem.eql(u8, local, local_real)) return error.SourceOutsideSelectedCache;
    const dvui = try acquire(gpa, io, &child_env, compiler, cache, packages, local, dvui_revision, dvui_url, dvui_hash);
    const ztray = try acquire(gpa, io, &child_env, compiler, cache, packages, local, ztray_revision, ztray_url, ztray_hash);
    const want_vectors = vectors or (if (existing) |old| old.svg2tvg != null else false);
    const svg2tvg = if (want_vectors) try acquire(gpa, io, &child_env, compiler, cache, packages, local, svg2tvg_revision, svg2tvg_url, svg2tvg_hash) else null;
    const icons = if (want_vectors) try acquire(gpa, io, &child_env, compiler, cache, packages, local, icons_revision, icons_url, icons_hash) else null;
    if (existing) |old| {
        if (old.svg2tvg) |source| if (!std.mem.eql(u8, &source.tree_digest, &svg2tvg.?.tree_digest)) return error.CachedSourceChanged;
        if (old.icons) |source| if (!std.mem.eql(u8, &source.tree_digest, &icons.?.tree_digest)) return error.CachedSourceChanged;
    }
    if (existing) |old| if (!std.mem.eql(u8, &old.dvui.tree_digest, &dvui.tree_digest) or !std.mem.eql(u8, &old.ztray.tree_digest, &ztray.tree_digest)) return error.CachedSourceChanged;
    if (!std.mem.eql(u8, &compiler_digest, &try compilerHash(gpa, io, compiler))) return error.CompilerChangedDuringAcquisition;
    const receipt: Receipt = .{ .compiler_path = compiler, .compiler_digest = compiler_digest, .cache_path = cache, .dvui = dvui, .ztray = ztray, .svg2tvg = svg2tvg, .icons = icons };
    const encoded = try receipt.serialize(gpa);
    var atomic = try directory.createFileAtomic(io, receipt_name, .{ .replace = existing != null });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded);
    if (existing != null) try atomic.replace(io) else try atomic.link(io);
}
test "archive entries stay within the immutable package prefix" {
    try std.testing.expectEqualStrings("src/main.zig", try archivePath("pin/src/main.zig", "pin"));
    for ([_][]const u8{ "other/src.zig", "pin/../escape", "pin//absolute", "pin/./alias", "pin/src\\escape", "pin/" }) |path|
        try std.testing.expectError(error.InvalidArchivePath, archivePath(path, "pin"));
}
test "source receipt fixes immutable IDs and exact paths below selected cache" {
    const gpa = std.testing.allocator;
    const receipt: Receipt = .{ .compiler_path = "/compiler/zig", .compiler_digest = @splat(1), .cache_path = "/cache", .dvui = .{ .revision = dvui_revision, .url = dvui_url, .package_hash = dvui_hash, .source_path = "/cache/p/" ++ dvui_hash, .tree_digest = @splat(2) }, .ztray = .{ .revision = ztray_revision, .url = ztray_url, .package_hash = ztray_hash, .source_path = "/cache/p/" ++ ztray_hash, .tree_digest = @splat(3) } };
    const bytes = try receipt.serialize(gpa);
    defer gpa.free(bytes);
    const parsed = try Receipt.parse(gpa, bytes);
    defer parsed.deinit(gpa);
    try std.testing.expectEqualStrings(receipt.dvui.source_path, parsed.dvui.source_path);
    var changed = receipt;
    changed.dvui.revision = "main";
    try std.testing.expectError(error.UnsupportedSourceContract, changed.validate());
    changed = receipt;
    changed.ztray.source_path = "/elsewhere/p/" ++ ztray_hash;
    try std.testing.expectError(error.SourceOutsideSelectedCache, changed.validate());
    changed = receipt;
    changed.compiler_path = "zig";
    try std.testing.expectError(error.AbsolutePathRequired, changed.validate());
    var vector = receipt;
    vector.svg2tvg = .{ .revision = svg2tvg_revision, .url = svg2tvg_url, .package_hash = svg2tvg_hash, .source_path = "/cache/p/" ++ svg2tvg_hash, .tree_digest = @splat(4) };
    try std.testing.expectError(error.IncompleteVectorSources, vector.validate());
    vector.icons = .{ .revision = icons_revision, .url = icons_url, .package_hash = icons_hash, .source_path = "/cache/p/" ++ icons_hash, .tree_digest = @splat(5) };
    const vector_bytes = try vector.serialize(gpa);
    defer gpa.free(vector_bytes);
    const vector_parsed = try Receipt.parse(gpa, vector_bytes);
    defer vector_parsed.deinit(gpa);
    try std.testing.expectEqualStrings(svg2tvg_revision, vector_parsed.svg2tvg.?.revision);
    try std.testing.expectEqualStrings(icons_hash, vector_parsed.icons.?.package_hash);
    vector.icons.?.revision = "main";
    try std.testing.expectError(error.UnsupportedSourceContract, vector.validate());
}
