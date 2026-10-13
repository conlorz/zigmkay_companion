//! Deterministic traversal only; callers own exclusions and digest formats.
const std = @import("std");
const builtin = @import("builtin");

// Test diagnostics never print source paths, names, or handles.
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
        repeated: usize = 0,
        previous_name: ?[]u8 = null,
        previous_state: ?std.Io.Dir.Reader.State = null,
        previous_index: usize = 0,
        previous_end: usize = 0,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |*frame| {
            if (frame.owns_dir) frame.dir.close(io);
            if (builtin.is_test) if (frame.previous_name) |name| gpa.free(name);
            gpa.free(frame.prefix);
        }
        stack.deinit(gpa);
    }
    const empty = try gpa.dupe(u8, "");
    stack.append(gpa, .{ .dir = root, .iterator = root.iterate(), .prefix = empty, .owns_dir = false }) catch |err| {
        gpa.free(empty);
        return err;
    };
    var trace_steps: usize = 0;
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (builtin.is_test and trace_steps < 30) {
            trace_steps += 1;
            std.debug.print("source traversal step={d} depth={d} before next\n", .{ trace_steps, stack.items.len });
        }
        const entry = try frame.iterator.next(io);
        if (builtin.is_test) {
            if (trace_steps > 0 and trace_steps <= 30) {
                const reader = &frame.iterator.reader;
                std.debug.print("source traversal step={d} depth={d} after next state={any} index={d} end={d}\n", .{
                    trace_steps, stack.items.len, reader.state, reader.index, reader.end,
                });
            }
            const reader = &frame.iterator.reader;
            if (entry) |item| {
                const unchanged = frame.previous_state != null and std.meta.eql(frame.previous_state.?, reader.state) and
                    frame.previous_index == reader.index and frame.previous_end == reader.end and
                    frame.previous_name != null and std.mem.eql(u8, frame.previous_name.?, item.name);
                frame.repeated = if (unchanged) frame.repeated + 1 else 0;
                if (frame.repeated >= 8) return error.SourceTraversalStalled;
                const name = try gpa.dupe(u8, item.name);
                if (frame.previous_name) |old| gpa.free(old);
                frame.previous_name = name;
                frame.previous_state = reader.state;
                frame.previous_index = reader.index;
                frame.previous_end = reader.end;
            }
        }
        const item = entry orelse {
            const done = stack.pop().?;
            if (done.owns_dir) done.dir.close(io);
            if (builtin.is_test) if (done.previous_name) |name| gpa.free(name);
            gpa.free(done.prefix);
            continue;
        };
        if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} before join\n", .{trace_steps});
        const path = try std.fs.path.join(gpa, &.{ frame.prefix, item.name });
        if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} after join, before excluded\n", .{trace_steps});
        const excluded = policy.excluded(path, item.name, item.kind);
        if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} after excluded\n", .{trace_steps});
        if (excluded) {
            gpa.free(path);
            continue;
        }
        if (item.kind == .directory) {
            if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} before child open\n", .{trace_steps});
            const child = frame.dir.openDir(io, item.name, .{ .iterate = true }) catch |err| {
                gpa.free(path);
                return err;
            };
            if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} after child open, before stack append\n", .{trace_steps});
            stack.append(gpa, .{ .dir = child, .iterator = child.iterate(), .prefix = path, .owns_dir = true }) catch |err| {
                child.close(io);
                gpa.free(path);
                return err;
            };
            if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} after stack append\n", .{trace_steps});
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
        if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} before file append\n", .{trace_steps});
        files.append(gpa, .{ .path = path, .kind = item.kind }) catch |err| {
            gpa.free(path);
            return err;
        };
        if (builtin.is_test and trace_steps <= 30) std.debug.print("source traversal step={d} after file append\n", .{trace_steps});
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
