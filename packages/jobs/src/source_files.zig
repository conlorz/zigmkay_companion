//! Deterministic traversal only; callers own exclusions and digest formats.
const std = @import("std");
const builtin = @import("builtin");
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
    const Frame = struct {
        dir: std.Io.Dir,
        iterator: std.Io.Dir.Iterator,
        prefix: []const u8,
        owns_dir: bool,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |*frame| {
            if (frame.owns_dir) frame.dir.close(io);
            gpa.free(frame.prefix);
        }
        stack.deinit(gpa);
    }
    const empty = try gpa.dupe(u8, "");
    stack.append(gpa, .{ .dir = root, .iterator = root.iterate(), .prefix = empty, .owns_dir = false }) catch |err| {
        gpa.free(empty);
        return err;
    };
    var entries_seen: usize = 0;
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const entry = try frame.iterator.next(io);
        const item = entry orelse {
            const done = stack.pop().?;
            if (done.owns_dir) done.dir.close(io);
            gpa.free(done.prefix);
            continue;
        };
        // Test-only protection against an iterator repeatedly returning entries.
        // Production source trees are never subject to this diagnostic bound.
        if (builtin.is_test) {
            if (entries_seen == 20_000) return error.SourceTraversalStalled;
            entries_seen += 1;
        }
        if (item.name.len > std.Io.Dir.max_name_bytes) return error.InvalidSourceName;
        const path = try std.fs.path.join(gpa, &.{ frame.prefix, item.name });
        const name = std.fs.path.basename(path);
        if (policy.excluded(path, name, item.kind)) {
            gpa.free(path);
            continue;
        }
        if (item.kind == .directory) {
            const child = frame.dir.openDir(io, name, .{ .iterate = true }) catch |err| {
                gpa.free(path);
                return err;
            };
            stack.append(gpa, .{ .dir = child, .iterator = child.iterate(), .prefix = path, .owns_dir = true }) catch |err| {
                child.close(io);
                gpa.free(path);
                return err;
            };
            continue;
        }
        if (policy.included) |included| {
            if (!included(path, item.kind)) {
                gpa.free(path);
                continue;
            }
        }
        if (files.items.len == policy.max_files) {
            gpa.free(path);
            return error.SourceFileLimit;
        }
        files.append(gpa, .{ .path = path, .kind = item.kind }) catch |err| {
            gpa.free(path);
            return err;
        };
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

fn checkMultipleFiles(io: std.Io) !void {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "nested/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "first.zig", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second.zig", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deeper/third.zig", .data = "c" });
    const Accept = struct {
        fn excluded(_: []const u8, _: []const u8, _: std.Io.File.Kind) bool {
            return false;
        }
    };
    for (0..2) |_| {
        const files = try collect(gpa, io, tmp.dir, .{ .excluded = Accept.excluded });
        defer free(gpa, files);
        try std.testing.expectEqual(@as(usize, 3), files.len);
        try std.testing.expectEqualStrings("first.zig", files[0].path);
        try std.testing.expectEqualStrings("nested/deeper/third.zig", files[1].path);
        try std.testing.expectEqualStrings("second.zig", files[2].path);
    }
}

test "multiple files on one directory handle with testing IO" {
    try checkMultipleFiles(std.testing.io);
}

test "multiple files on one directory handle with threaded IO" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try checkMultipleFiles(threaded.io());
}

fn checkFixtureRoots(io: std.Io, tmp: std.Io.Dir, policy: Policy, expected: []const []const u8) !void {
    const gpa = std.testing.allocator;
    const reopened = try tmp.openDir(io, ".", .{ .iterate = true });
    defer reopened.close(io);
    for ([_]std.Io.Dir{ tmp, reopened }) |root| {
        const files = try collect(gpa, io, root, policy);
        defer free(gpa, files);
        try std.testing.expectEqual(expected.len, files.len);
        for (expected, files) |path, file| try std.testing.expectEqualStrings(path, file.path);
    }
}

const FixturePolicy = struct {
    fn excluded(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
        return kind == .directory and (std.mem.eql(u8, name, ".zig-cache") or
            std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "cache"));
    }
    fn included(path: []const u8, kind: std.Io.File.Kind) bool {
        return kind == .file and (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon"));
    }
    const policy: Policy = .{ .excluded = excluded, .included = included, .max_files = 8 };
};

fn checkColonFixture(io: std.Io) !void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "samples/USB Device 0x46d:0x9a4--USB Mixer");
    try tmp.dir.writeFile(io, .{ .sub_path = "samples/USB Device 0x46d:0x9a4--USB Mixer/main.zig", .data = "" });
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/ignored.zig", .data = "" });
    try checkFixtureRoots(io, tmp.dir, FixturePolicy.policy, &.{"samples/USB Device 0x46d:0x9a4--USB Mixer/main.zig"});
}

fn checkResolutionFixture(io: std.Io) !void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "local");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/build.zig.zon", .data = "" });
    try tmp.dir.createDirPath(io, "cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "cache/ignored.zon", .data = "" });
    try checkFixtureRoots(io, tmp.dir, FixturePolicy.policy, &.{ "build.zig.zon", "local/build.zig.zon" });
}

test "colon nested fixture with testing IO" {
    try checkColonFixture(std.testing.io);
}

test "colon nested fixture with threaded IO" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try checkColonFixture(threaded.io());
}

test "resolution manifest fixture with testing IO" {
    try checkResolutionFixture(std.testing.io);
}

test "resolution manifest fixture with threaded IO" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try checkResolutionFixture(threaded.io());
}

test "nested traversal terminates and preserves relative paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "nested/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deeper/input.zig", .data = "" });
    const Accept = struct {
        fn excluded(_: []const u8, _: []const u8, _: std.Io.File.Kind) bool {
            return false;
        }
    };
    const files = try collect(gpa, io, tmp.dir, .{ .excluded = Accept.excluded, .max_files = 1 });
    defer free(gpa, files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("nested/deeper/input.zig", files[0].path);
}

test "traversal preserves caller policy, sorts paths and enforces bounds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "other/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "other/deeper/b.zig", .data = "" });
    try tmp.dir.createDirPath(io, "sibling/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "sibling/deeper/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sibling/.hidden.zig", .data = "" });
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
    try std.testing.expectEqual(@as(usize, 5), files.len);
    try std.testing.expectEqualStrings(".hidden.zig", files[0].path);
    try std.testing.expectEqualStrings("other/deeper/b.zig", files[1].path);
    try std.testing.expectEqualStrings("sibling/.hidden.zig", files[2].path);
    try std.testing.expectEqualStrings("sibling/deeper/a.zig", files[3].path);
    try std.testing.expectEqualStrings("z.zon", files[4].path);
    var bounded = policy;
    bounded.max_files = 4;
    try std.testing.expectError(error.SourceFileLimit, collect(gpa, io, tmp.dir, bounded));
}
