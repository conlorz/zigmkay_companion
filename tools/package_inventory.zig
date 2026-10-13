//! Explicit literal manifest inventory. No fetch, build script, compiler or device.
const std = @import("std");
const jobs = @import("companion-jobs");
const Row = struct { name: []const u8, url: ?[]const u8, archive_url: ?[]const u8, package_hash: ?[]const u8, revision: []const u8, identity: ?@FieldType(jobs.build_provenance.Dependency, "identity"), path: ?[]const u8, lazy: bool };
const Receipt = struct { version: u16 = 1, manifest: []const u8, manifest_digest: jobs.firmware.Digest, dependencies: []const Row };
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len != 3) return error.Usage;
    if (!std.fs.path.isAbsolute(args[1]) or !std.fs.path.isAbsolute(args[2])) return error.AbsoluteInventoryPathsRequired;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    var parsed = try jobs.package_manifest.parse(gpa, bytes);
    defer parsed.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc(Row, parsed.dependencies.len);
    for (rows, parsed.dependencies) |*row, dep| {
        const archive = if (dep.url) |url| try jobs.package_manifest.archive(a, url) else null;
        row.* = .{ .name = dep.name, .url = dep.url, .archive_url = if (archive) |value| value.url else null, .package_hash = dep.package_hash, .revision = if (archive) |value| value.revision else "", .identity = if (archive) |value| value.identity else null, .path = dep.path, .lazy = dep.lazy };
    }
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[2], .{});
    defer directory.close(init.io);
    const filename = "dependency-inventory.zon";
    const old = directory.readFileAlloc(init.io, filename, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old) |existing| {
        defer gpa.free(existing);
        const source = try gpa.dupeSentinel(u8, existing, 0);
        defer gpa.free(source);
        const receipt = try @import("owned-zon").parse(Receipt, gpa, source);
        defer @import("owned-zon").free(gpa, receipt);
        if (receipt.version != 1) return error.UnsupportedDependencyInventory;
        if (!std.mem.eql(u8, receipt.manifest, args[1])) return error.DependencyInventorySourceChanged;
    }
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serialize(Receipt{ .manifest = args[1], .manifest_digest = jobs.firmware.digest(bytes), .dependencies = rows }, .{}, &encoded.writer);
    var atomic = try directory.createFileAtomic(init.io, filename, .{ .replace = true });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, encoded.written());
    try atomic.replace(init.io);
}
