//! Immutable per-run files: independent instances never overwrite shared indexes.
//! All-history is streamed from bounded records; ten newest records form a page.
const std = @import("std");
const results = @import("practice_results.zig");
const database = @import("practice_database.zig");
const timing = @import("practice_timing.zig");
const progress = @import("practice_progress.zig");
const analysis = @import("practice_analysis.zig");
pub const Record = results.Record;
pub const max_record_bytes = 512 * 1024;
pub const Query = struct {
    all: results.Aggregate = .{},
    recent: results.Aggregate = .{},
    page: [10]Record = @splat(.{}),
    page_count: usize = 0,
    rejected: usize = 0,
    total: usize = 0,
    requested_id: ?[16]u8 = null,
    contains_requested: bool = false,
    oldest_recent: ?Record = null,
    recent_ids: [10][16]u8 = @splat(@splat(0)),
    recent_count: usize = 0,
    progress: ?*progress.Summary = null,
    progress_allocator: std.mem.Allocator = std.heap.page_allocator,
    requested_record: ?Record = null,
    latest_curriculum: ?Record = null,
    timing: ?timing.Owned = null,
    analysis: ?*analysis.Summary = null,
    database_runs: usize = 0,
    database_events: usize = 0,
    exported: bool = false,
    imported: ?usize = null,
    pub fn deinit(self: *Query) void {
        if (self.progress) |value| self.progress_allocator.destroy(value);
        if (self.timing) |*value| value.deinit();
        if (self.analysis) |value| self.progress_allocator.destroy(value);
        self.progress = null;
        self.timing = null;
        self.analysis = null;
    }
};
pub fn newer(a: Record, b: Record) bool {
    return if (a.timestamp == b.timestamp) std.mem.order(u8, &a.id, &b.id) == .gt else a.timestamp > b.timestamp;
}
fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Record {
    const terminated = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(terminated);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const record = try std.zon.parse.fromSlice(Record, .{ .gpa = gpa, .arena = arena.allocator(), .source = terminated, .diagnostics = &diagnostics });
    try record.validate();
    return record;
}
fn filename(id: [16]u8, buffer: *[36]u8) []const u8 {
    const hex = std.fmt.bytesToHex(id, .lower);
    @memcpy(buffer[0..32], &hex);
    @memcpy(buffer[32..], ".zon");
    return buffer;
}
pub fn save(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, record: *const Record) !void {
    try record.validate();
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(record.*, .{}, &encoded.writer, 32);
    if (encoded.written().len > max_record_bytes) return error.PracticeRecordTooLarge;
    var name: [36]u8 = undefined;
    var atomic = try directory.createFileAtomic(io, filename(record.id, &name), .{});
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded.written());
    try atomic.file.sync(io);
    atomic.link(io) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const old = try directory.readFileAlloc(io, &name, gpa, .limited(max_record_bytes));
        defer gpa.free(old);
        if (!std.mem.eql(u8, old, encoded.written())) return error.PracticeRunCollision;
    };
}
/// Each page uses a frozen exclusive upper boundary. New writes cannot make
/// older pages duplicate runs. All-history aggregation still includes every run.
pub fn query(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, cohort: results.Cohort, before: ?Record) !Query {
    return queryTracked(gpa, io, directory, cohort, before, null);
}
fn queryTracked(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, cohort: results.Cohort, before: ?Record, current_id: ?[16]u8) !Query {
    var output: Query = .{ .requested_id = current_id };
    var newest: [10]Record = @splat(.{});
    var newest_count: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len != 36 or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const bytes = directory.readFileAlloc(io, entry.name, gpa, .limited(max_record_bytes)) catch {
            output.rejected += 1;
            continue;
        };
        defer gpa.free(bytes);
        const record = parse(gpa, bytes) catch {
            output.rejected += 1;
            continue;
        };
        var name: [36]u8 = undefined;
        if (!std.mem.eql(u8, entry.name, filename(record.id, &name))) {
            output.rejected += 1;
            continue;
        }
        if (!std.meta.eql(record.cohort, cohort)) continue;
        output.total += 1;
        if (current_id) |id| if (std.mem.eql(u8, &id, &record.id)) {
            output.contains_requested = true;
        };
        try output.all.add(&record);
        if (record.scored) insert(&newest, &newest_count, record);
        if (before) |boundary| if (!newer(boundary, record)) continue;
        insert(&output.page, &output.page_count, record);
    }
    for (newest[0..newest_count], 0..) |*record, index| {
        try output.recent.add(record);
        output.recent_ids[index] = record.id;
    }
    output.recent_count = newest_count;
    if (newest_count == 10) output.oldest_recent = newest[9];
    return output;
}
fn insert(page: *[10]Record, count: *usize, record: Record) void {
    var index: usize = 0;
    while (index < count.* and !newer(record, page[index])) : (index += 1) {}
    if (index >= 10) return;
    const end = @min(count.*, 9);
    var dest = end;
    while (dest > index) : (dest -= 1) page[dest] = page[dest - 1];
    page[index] = record;
    count.* = @min(count.* + 1, 10);
}
/// Explicit clearing first validates every named result. Corrupt/future files
/// are retained and require deliberate user handling rather than silent loss.
pub fn clear(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !void {
    var iterator = directory.iterate();
    var names: std.ArrayList([36]u8) = .empty;
    defer names.deinit(gpa);
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len != 36 or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const bytes = try directory.readFileAlloc(io, entry.name, gpa, .limited(max_record_bytes));
        defer gpa.free(bytes);
        const record = try parse(gpa, bytes);
        var name: [36]u8 = undefined;
        if (!std.mem.eql(u8, entry.name, filename(record.id, &name))) return error.InvalidPracticeHistory;
        try names.append(gpa, name);
    }
    for (names.items) |name| try directory.deleteFile(io, &name);
}
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    captured: [32]u8 = @splat(0),
    cohort: results.Cohort,
    record: ?Record = null,
    before: ?Record = null,
    clearing: bool = false,
    current_id: ?[16]u8 = null,
    timing: ?timing.Payload = null,
    transfer: enum { none, export_database, import_database } = .none,
    transfer_path: []const u8 = "",
    pub fn init(gpa: std.mem.Allocator, path: []const u8, cohort: results.Cohort) !Request {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned_path = try arena.allocator().dupe(u8, path);
        return .{ .arena = arena, .path = owned_path, .cohort = cohort };
    }
    pub fn deinit(self: *Request) void {
        self.arena.deinit();
    }
    pub fn prepare(self: *Request, gpa: std.mem.Allocator, io: std.Io) !Query {
        // A missing read-only history is ordinary. Only a completed save creates it.
        const directory = if (self.record != null or self.transfer != .none) try std.Io.Dir.cwd().createDirPathOpen(io, self.path, .{ .open_options = .{ .iterate = true } }) else std.Io.Dir.cwd().openDir(io, self.path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return .{};
            return err;
        };
        defer directory.close(io);
        const root = try directory.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        const path = try std.fs.path.join(gpa, &.{ root, database.filename });
        defer gpa.free(path);
        var db = try database.Database.open(gpa, path, false);
        defer db.deinit();
        var rejected: usize = 0;
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or entry.name.len != 36 or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
            const bytes = directory.readFileAlloc(io, entry.name, gpa, .limited(max_record_bytes)) catch {
                rejected += 1;
                continue;
            };
            defer gpa.free(bytes);
            const legacy = parse(gpa, bytes) catch {
                rejected += 1;
                continue;
            };
            var name: [36]u8 = undefined;
            if (!std.mem.eql(u8, entry.name, filename(legacy.id, &name))) {
                rejected += 1;
                continue;
            }
            db.importLegacy(&legacy) catch |err| {
                if (err == error.PracticeRunCollision) {
                    rejected += 1;
                    continue;
                }
                return err;
            };
        }
        if (self.clearing) {
            if (rejected != 0) return error.InvalidPracticeHistory;
            try db.clear();
        }
        if (self.record) |*record| try db.save(record, self.timing);
        var output: Query = .{ .requested_id = self.current_id, .rejected = rejected };
        output.progress_allocator = gpa;
        output.progress = try gpa.create(progress.Summary);
        output.progress.?.* = .{};
        errdefer output.deinit();
        output.progress.?.today = @divFloor(@as(i64, @intCast(std.Io.Clock.real.now(io).toNanoseconds())), progress.day_ns);
        switch (self.transfer) {
            .none => {},
            .export_database => {
                try db.exportDatabase(io, self.transfer_path);
                output.exported = true;
            },
            .import_database => output.imported = try db.importDatabase(self.transfer_path),
        }
        output.database_runs = try db.runCount();
        var rows = try db.rowsFor(self.cohort);
        defer rows.deinit();
        var newest: [10]Record = @splat(.{});
        var newest_count: usize = 0;
        while (try rows.step()) {
            const record = parse(gpa, try rows.blob(1)) catch {
                output.rejected += 1;
                continue;
            };
            if (!std.mem.eql(u8, try rows.blob(0), &record.id)) {
                output.rejected += 1;
                continue;
            }
            if (!std.meta.eql(record.cohort, self.cohort)) continue;
            output.total += 1;
            if (self.current_id) |id| if (std.mem.eql(u8, &id, &record.id)) {
                output.contains_requested = true;
                output.requested_record = record;
            };
            output.progress.?.add(&record);
            try output.all.add(&record);
            if (record.scored) insert(&newest, &newest_count, record);
            if (self.before) |boundary| if (!newer(boundary, record)) continue;
            insert(&output.page, &output.page_count, record);
        }
        for (newest[0..newest_count], 0..) |*record, index| {
            try output.recent.add(record);
            output.recent_ids[index] = record.id;
        }
        output.recent_count = newest_count;
        if (newest_count == 10) output.oldest_recent = newest[9];
        // Raw payloads are decoded one at a time on this background worker.
        // The GUI receives only bounded derived character timing summaries.
        for (output.progress.?.points[0..output.progress.?.count]) |*point| if (point.timing) {
            if (try db.timingFor(point.id, gpa)) |value| {
                var owned = value;
                defer owned.deinit();
                try point.enrich(gpa, owned.payload);
            }
        };
        output.database_events = try db.eventCount();
        var curriculum_rows = try db.rowsForPractice(self.cohort);
        defer curriculum_rows.deinit();
        while (try curriculum_rows.step()) {
            const candidate = parse(gpa, try curriculum_rows.blob(1)) catch continue;
            if (!std.mem.eql(u8, &candidate.id, try curriculum_rows.blob(0)) or !std.meta.eql(database.practiceKey(candidate.cohort), database.practiceKey(self.cohort))) continue;
            if (candidate.cohort.curriculum.version == 1 and candidate.scored and candidate.status == .completed and candidate.cohort.mode == .normal) {
                output.latest_curriculum = candidate;
                break;
            }
        }
        if (output.requested_record) |record| if (record.timing_available) {
            output.timing = try db.timingFor(record.id, gpa);
            if (output.timing) |owned| output.analysis = try analysis.analyze(gpa, owned.payload);
        };
        return output;
    }
};
pub const Worker = @import("owned_worker.zig").Owner(Request, Query, error.InvalidPracticeGeneration);
test "immutable publication restart pages cohorts weighted history and corrupt preservation" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var record: Record = .{ .matched = 2, .stat_count = 1, .attempts = 3, .correct_attempts = 2 };
    record.stats[0] = .{ .cp = ';', .opportunities = 2, .misses = 1 };
    for (0..12) |index| {
        record.id[0] = @intCast(index);
        record.timestamp = @intCast(index);
        try save(t.allocator, t.io, temp.dir, &record);
        try save(t.allocator, t.io, temp.dir, &record);
    }
    const first = try query(t.allocator, t.io, temp.dir, .{}, null);
    try t.expectEqual(@as(u64, 12), first.all.runs);
    try t.expectEqual(@as(u64, 10), first.recent.runs);
    try t.expectEqual(@as(usize, 10), first.recent_count);
    try t.expectEqual(@as(u8, 11), first.recent_ids[0][0]);
    try t.expectEqual(@as(u8, 2), first.recent_ids[9][0]);
    try t.expectEqual(@as(i64, 11), first.page[0].timestamp);
    const second = try query(t.allocator, t.io, temp.dir, .{}, first.page[9]);
    try t.expectEqual(@as(usize, 2), second.page_count);
    // Paging old runs must retain the newest baseline membership, rather than
    // treating every requested historical ID as part of the recent ten.
    try t.expectEqual(first.recent_ids, second.recent_ids);
    record.cohort.assistance = .hidden;
    record.id[0] = 40;
    try save(t.allocator, t.io, temp.dir, &record);
    const again = try query(t.allocator, t.io, temp.dir, .{}, null);
    try t.expectEqual(@as(u64, 12), again.all.runs);
    record.cohort.assistance = .guided;
    try t.expectError(error.PracticeRunCollision, save(t.allocator, t.io, temp.dir, &record));
    var corrupt_name: [36]u8 = undefined;
    try temp.dir.writeFile(t.io, .{ .sub_path = filename(@splat(99), &corrupt_name), .data = ".{ .version = 999 }" });
    const partial = try query(t.allocator, t.io, temp.dir, .{}, null);
    try t.expectEqual(@as(usize, 1), partial.rejected);
    if (clear(t.allocator, t.io, temp.dir)) |_| return error.ExpectedHistoryPreservation else |_| {}
    const retained = try query(t.allocator, t.io, temp.dir, .{}, null);
    try t.expectEqual(@as(u64, 12), retained.all.runs);
    try temp.dir.deleteFile(t.io, &corrupt_name);
    try clear(t.allocator, t.io, temp.dir);
    const empty = try query(t.allocator, t.io, temp.dir, .{}, null);
    try t.expectEqual(@as(usize, 0), empty.total);
}

test "native Unicode directories atomic interruption and independent writers preserve prior runs" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var directory = try temp.dir.createDirPathOpen(t.io, "practice data café", .{ .open_options = .{ .iterate = true } });
    defer directory.close(t.io);
    const Writer = struct {
        fn write(io: std.Io, dir: std.Io.Dir, id: u8) !void {
            var record: Record = .{};
            record.id[0] = id;
            try save(std.heap.page_allocator, io, dir, &record);
        }
    };
    var first = try std.Io.concurrent(t.io, Writer.write, .{ t.io, directory, @as(u8, 1) });
    var second = try std.Io.concurrent(t.io, Writer.write, .{ t.io, directory, @as(u8, 2) });
    try first.await(t.io);
    try second.await(t.io);
    var interrupted = try directory.createFileAtomic(t.io, "00000000000000000000000000000000.zon", .{});
    defer interrupted.deinit(t.io);
    try interrupted.file.writeStreamingAll(t.io, "unfinished result");
    const restored = try query(t.allocator, t.io, directory, .{}, null);
    try t.expectEqual(@as(usize, 2), restored.total);
    try t.expectEqual(@as(usize, 0), restored.rejected);
    try directory.writeFile(t.io, .{ .sub_path = "project.zon", .data = "unrelated project is preserved" });
    try clear(t.allocator, t.io, directory);
    const project = try directory.readFileAlloc(t.io, "project.zon", t.allocator, .limited(100));
    defer t.allocator.free(project);
    try t.expectEqualStrings("unrelated project is preserved", project);
}
