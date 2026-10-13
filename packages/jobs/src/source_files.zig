//! Deterministic traversal only; callers own exclusions and digest formats.
const std = @import("std");
pub const Entry = struct { path: []const u8, kind: std.Io.File.Kind };
pub const Policy = struct {
    excluded: *const fn (path: []const u8, basename: []const u8, kind: std.Io.File.Kind) bool,
    included: ?*const fn (path: []const u8, kind: std.Io.File.Kind) bool = null,
    max_files: usize = std.math.maxInt(usize),
};

pub fn collect(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, policy: Policy) ![]Entry {
    var files: std.ArrayList(Entry) = .empty;
    errdefer {
        for (files.items) |file| gpa.free(file.path);
        files.deinit(gpa);
    }
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (policy.excluded(entry.path, entry.basename, entry.kind)) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        if (entry.kind == .directory) continue;
        if (policy.included) |included| if (!included(entry.path, entry.kind)) continue;
        if (files.items.len == policy.max_files) return error.SourceFileLimit;
        const path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(path);
        try files.append(gpa, .{ .path = path, .kind = entry.kind });
    }
    std.mem.sort(Entry, files.items, {}, struct {
        fn less(_: void, lhs: Entry, rhs: Entry) bool {
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    }.less);
    return files.toOwnedSlice(gpa);
}

pub fn free(gpa: std.mem.Allocator, files: []Entry) void {
    for (files) |file| gpa.free(file.path);
    gpa.free(files);
}

test "traversal preserves caller policy, sorts paths and enforces bounds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/ignored.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "z.zon", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.md", .data = "" });
    const CompilerPolicy = struct {
        fn excluded(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
            return kind == .directory and std.mem.startsWith(u8, name, ".");
        }
        fn included(path: []const u8, kind: std.Io.File.Kind) bool {
            return kind == .file and (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon"));
        }
    };
    const policy: Policy = .{ .excluded = CompilerPolicy.excluded, .included = CompilerPolicy.included };
    const files = try collect(gpa, io, tmp.dir, policy);
    defer free(gpa, files);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings(".hidden.zig", files[0].path);
    try std.testing.expectEqualStrings("z.zon", files[1].path);
    var bounded = policy;
    bounded.max_files = 1;
    try std.testing.expectError(error.SourceFileLimit, collect(gpa, io, tmp.dir, bounded));
}
