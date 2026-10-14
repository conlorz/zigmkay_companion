//! Narrow SQLite C API bridge. Transactions, validation and migration stay in Zig.
const std = @import("std");
const results = @import("practice_results.zig");
const timing = @import("practice_timing.zig");
const Handle = opaque {};
const RawStatement = opaque {};
const Backup = opaque {};
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*Handle, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close_v2(*Handle) c_int;
extern "c" fn sqlite3_busy_timeout(*Handle, c_int) c_int;
extern "c" fn sqlite3_exec(*Handle, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*?[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(*Handle, [*:0]const u8, c_int, *?*RawStatement, ?*?[*:0]const u8) c_int;
extern "c" fn sqlite3_finalize(*RawStatement) c_int;
extern "c" fn sqlite3_step(*RawStatement) c_int;
extern "c" fn sqlite3_bind_blob(*RawStatement, c_int, ?*const anyopaque, c_int, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern "c" fn sqlite3_bind_int64(*RawStatement, c_int, i64) c_int;
extern "c" fn sqlite3_bind_null(*RawStatement, c_int) c_int;
extern "c" fn sqlite3_column_blob(*RawStatement, c_int) ?*const anyopaque;
extern "c" fn sqlite3_column_bytes(*RawStatement, c_int) c_int;
extern "c" fn sqlite3_column_type(*RawStatement, c_int) c_int;
extern "c" fn sqlite3_column_int64(*RawStatement, c_int) i64;
extern "c" fn sqlite3_backup_init(*Handle, [*:0]const u8, *Handle, [*:0]const u8) ?*Backup;
extern "c" fn sqlite3_backup_step(*Backup, c_int) c_int;
extern "c" fn sqlite3_backup_finish(*Backup) c_int;
pub const filename = "practice.sqlite3";
pub const max_payload_bytes = 16 * 1024 * 1024;
const application_id = 0x5a4d5052;
fn check(code: c_int) !void {
    return switch (code & 0xff) {
        0 => {},
        5, 6 => error.PracticeDatabaseBusy,
        7 => error.OutOfMemory,
        8, 3 => error.PracticeDatabaseReadOnly,
        10, 13, 14 => error.PracticeDatabaseIO,
        11, 26 => error.InvalidPracticeDatabase,
        19 => error.PracticeRunCollision,
        else => error.PracticeDatabaseFailure,
    };
}
pub const Statement = struct {
    raw: *RawStatement,
    retained: ?[]u8 = null,
    gpa: ?std.mem.Allocator = null,
    pub fn deinit(self: *Statement) void {
        _ = sqlite3_finalize(self.raw);
        if (self.retained) |bytes| self.gpa.?.free(bytes);
    }
    pub fn step(self: *Statement) !bool {
        const code = sqlite3_step(self.raw);
        if (code == 100) return true;
        if (code == 101) return false;
        try check(code);
        return error.PracticeDatabaseFailure;
    }
    pub fn blob(self: *Statement, column: c_int) ![]const u8 {
        if (sqlite3_column_type(self.raw, column) != 4) return error.InvalidPracticeDatabase;
        const length = sqlite3_column_bytes(self.raw, column);
        if (length < 0 or length > max_payload_bytes) return error.InvalidPracticeDatabase;
        if (length == 0) return &.{};
        const ptr: [*]const u8 = @ptrCast(sqlite3_column_blob(self.raw, column) orelse return error.InvalidPracticeDatabase);
        return ptr[0..@intCast(length)];
    }
    fn bindBlob(self: *Statement, index: c_int, bytes: []const u8) !void {
        if (bytes.len > max_payload_bytes) return error.PracticeRecordTooLarge;
        // SQLITE_STATIC: callers retain these bytes until statement finalization.
        try check(sqlite3_bind_blob(self.raw, index, bytes.ptr, @intCast(bytes.len), null));
    }
    fn integer(self: *Statement, index: c_int, value: i64) !void {
        try check(sqlite3_bind_int64(self.raw, index, value));
    }
};
pub fn encode(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    try std.zon.stringify.serializeMaxDepth(value, .{}, &out.writer, 32);
    if (out.written().len > max_payload_bytes) return error.PracticeRecordTooLarge;
    return gpa.dupe(u8, out.written());
}
pub fn decode(comptime T: type, gpa: std.mem.Allocator, bytes: []const u8) !T {
    if (bytes.len > max_payload_bytes) return error.PracticeRecordTooLarge;
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const value = try std.zon.parse.fromSlice(T, .{ .gpa = gpa, .arena = gpa, .source = text, .diagnostics = &diagnostics });
    try value.validate();
    return value;
}
pub const Database = struct {
    handle: *Handle,
    gpa: std.mem.Allocator,
    pub fn open(gpa: std.mem.Allocator, path: []const u8, readonly: bool) !Database {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsolutePracticeDatabasePathRequired;
        const name = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(name);
        var ptr: ?*Handle = null;
        const code = sqlite3_open_v2(name, &ptr, if (readonly) 1 else 2 | 4, null);
        if (code != 0) {
            if (ptr) |p| _ = sqlite3_close_v2(p);
            try check(code);
        }
        var self = Database{ .handle = ptr orelse return error.PracticeDatabaseFailure, .gpa = gpa };
        errdefer self.deinit();
        try check(sqlite3_busy_timeout(self.handle, 1500));
        try self.exec("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON;");
        const version = try self.number("PRAGMA user_version");
        const app = try self.number("PRAGMA application_id");
        if (!readonly and version == 0 and app == 0 and try self.number("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0) {
            try self.exec("BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS runs(id BLOB PRIMARY KEY CHECK(length(id)=16), timestamp INTEGER NOT NULL, record BLOB NOT NULL, timing BLOB, cohort BLOB NOT NULL) STRICT; CREATE INDEX IF NOT EXISTS runs_chronological ON runs(timestamp,id); CREATE INDEX IF NOT EXISTS runs_cohort_chronological ON runs(cohort,timestamp,id); CREATE TABLE IF NOT EXISTS events(run_id BLOB NOT NULL REFERENCES runs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, elapsed_us INTEGER NOT NULL, active_us INTEGER NOT NULL, kind INTEGER NOT NULL, position INTEGER NOT NULL, expected INTEGER, typed INTEGER, batch INTEGER NOT NULL, input INTEGER NOT NULL, eligibility INTEGER NOT NULL, interval_us INTEGER, correct INTEGER NOT NULL, assistance INTEGER NOT NULL, observed_us INTEGER NOT NULL, clock INTEGER NOT NULL, PRIMARY KEY(run_id,ordinal)) STRICT; CREATE TABLE IF NOT EXISTS legacy_imports(id BLOB PRIMARY KEY, record BLOB NOT NULL) STRICT; PRAGMA application_id=0x5a4d5052; PRAGMA user_version=1; COMMIT;");
        } else if (version != 1 or app != application_id) return error.UnsupportedPracticeDatabase;
        if (!readonly) try self.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
        return self;
    }
    pub fn deinit(self: *Database) void {
        _ = sqlite3_close_v2(self.handle);
    }
    pub fn exec(self: *Database, sql: [:0]const u8) !void {
        try check(sqlite3_exec(self.handle, sql, null, null, null));
    }
    pub fn prepare(self: *Database, sql: [:0]const u8) !Statement {
        var stmt: ?*RawStatement = null;
        try check(sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null));
        return .{ .raw = stmt orelse return error.PracticeDatabaseFailure };
    }
    fn number(self: *Database, sql: [:0]const u8) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        if (!try stmt.step()) return error.InvalidPracticeDatabase;
        return sqlite3_column_int64(stmt.raw, 0);
    }
    pub fn rows(self: *Database) !Statement {
        return self.prepare("SELECT id,record,timing FROM runs ORDER BY timestamp DESC,id DESC");
    }
    pub fn eventCount(self: *Database) !usize {
        return std.math.cast(usize, try self.number("SELECT count(*) FROM events")) orelse error.InvalidPracticeDatabase;
    }
    pub fn runCount(self: *Database) !usize {
        return std.math.cast(usize, try self.number("SELECT count(*) FROM runs")) orelse error.InvalidPracticeDatabase;
    }
    pub fn rowsFor(self: *Database, cohort: results.Cohort) !Statement {
        const bytes = try encode(self.gpa, cohort);
        errdefer self.gpa.free(bytes);
        var stmt = try self.prepare("SELECT id,record,timing FROM runs WHERE cohort=?1 ORDER BY timestamp DESC,id DESC");
        errdefer stmt.deinit();
        try stmt.bindBlob(1, bytes);
        stmt.retained = bytes;
        stmt.gpa = self.gpa;
        return stmt;
    }
    fn put(self: *Database, record: *const results.Record, payload: ?timing.Payload) !void {
        try record.validate();
        if (payload) |p| try p.validate();
        if (record.timing_available != (payload != null) or (payload != null and record.timing_truncated != payload.?.truncated)) return error.InvalidPracticeTiming;
        if (payload) |p| {
            if ((record.status == .completed and p.reference.len != record.matched) or record.matched > p.reference.len) return error.InvalidPracticeTiming;
            var attempts: u64 = 0;
            var correct: u64 = 0;
            for (p.events) |event| if (event.kind == .attempt) {
                attempts += 1;
                correct += @intFromBool(event.correct);
            };
            if (attempts > record.attempts or correct > record.correct_attempts or (!p.truncated and (attempts != record.attempts or correct != record.correct_attempts))) return error.InvalidPracticeTiming;
        }
        const bytes = try encode(self.gpa, record.*);
        defer self.gpa.free(bytes);
        const samples = if (payload) |p| try encode(self.gpa, p) else null;
        defer if (samples) |b| self.gpa.free(b);
        var found = try self.prepare("SELECT record,timing FROM runs WHERE id=?1");
        defer found.deinit();
        try found.bindBlob(1, &record.id);
        if (try found.step()) {
            if (!std.mem.eql(u8, bytes, try found.blob(0))) return error.PracticeRunCollision;
            if (samples) |b| {
                if (sqlite3_column_type(found.raw, 1) == 5 or !std.mem.eql(u8, b, try found.blob(1))) return error.PracticeRunCollision;
            }
            return;
        }
        const cohort = try encode(self.gpa, record.cohort);
        defer self.gpa.free(cohort);
        var stmt = try self.prepare("INSERT INTO runs(id,timestamp,record,timing,cohort) VALUES(?1,?2,?3,?4,?5)");
        defer stmt.deinit();
        try stmt.bindBlob(1, &record.id);
        try stmt.integer(2, record.timestamp);
        try stmt.bindBlob(3, bytes);
        if (samples) |b| try stmt.bindBlob(4, b) else try check(sqlite3_bind_null(stmt.raw, 4));
        try stmt.bindBlob(5, cohort);
        _ = try stmt.step();
        if (payload) |p| for (p.events, 0..) |event, index| {
            var e = try self.prepare("INSERT INTO events VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)");
            defer e.deinit();
            try e.bindBlob(1, &record.id);
            try e.integer(2, @intCast(index));
            try e.integer(3, std.math.cast(i64, event.elapsed_us) orelse return error.InvalidPracticeTiming);
            try e.integer(4, std.math.cast(i64, event.active_us) orelse return error.InvalidPracticeTiming);
            try e.integer(5, @backingInt(event.kind));
            try e.integer(6, event.position);
            if (event.expected) |v| try e.integer(7, v) else try check(sqlite3_bind_null(e.raw, 7));
            if (event.typed) |v| try e.integer(8, v) else try check(sqlite3_bind_null(e.raw, 8));
            try e.integer(9, event.batch);
            try e.integer(10, @backingInt(event.input));
            try e.integer(11, @backingInt(event.eligibility));
            if (event.interval_us) |v| try e.integer(12, std.math.cast(i64, v) orelse return error.InvalidPracticeTiming) else try check(sqlite3_bind_null(e.raw, 12));
            try e.integer(13, @intFromBool(event.correct));
            try e.integer(14, event.assistance);
            try e.integer(15, std.math.cast(i64, event.observed_us) orelse return error.InvalidPracticeTiming);
            try e.integer(16, @backingInt(event.clock));
            _ = try e.step();
        };
    }
    pub fn save(self: *Database, record: *const results.Record, payload: ?timing.Payload) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        try self.put(record, payload);
        try self.exec("COMMIT");
    }
    pub fn importLegacy(self: *Database, record: *const results.Record) !void {
        const bytes = try encode(self.gpa, record.*);
        defer self.gpa.free(bytes);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var old = try self.prepare("SELECT record FROM legacy_imports WHERE id=?1");
        defer old.deinit();
        try old.bindBlob(1, &record.id);
        if (try old.step()) {
            if (!std.mem.eql(u8, bytes, try old.blob(0))) return error.PracticeRunCollision;
        } else {
            try self.put(record, null);
            var receipt = try self.prepare("INSERT INTO legacy_imports VALUES(?1,?2)");
            defer receipt.deinit();
            try receipt.bindBlob(1, &record.id);
            try receipt.bindBlob(2, bytes);
            _ = try receipt.step();
        }
        try self.exec("COMMIT");
    }
    pub fn importDatabase(self: *Database, path: []const u8) !usize {
        var source = try Database.open(self.gpa, path, true);
        defer source.deinit();
        try source.exec("BEGIN");
        defer source.exec("ROLLBACK") catch {};
        var rows_stmt = try source.rows();
        defer rows_stmt.deinit();
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var count: usize = 0;
        while (try rows_stmt.step()) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const record = try decode(results.Record, arena.allocator(), try rows_stmt.blob(1));
            if (!std.mem.eql(u8, try rows_stmt.blob(0), &record.id)) return error.InvalidPracticeDatabase;
            const payload = if (sqlite3_column_type(rows_stmt.raw, 2) == 5) null else try decode(timing.Payload, arena.allocator(), try rows_stmt.blob(2));
            try self.put(&record, payload);
            count += 1;
        }
        try self.exec("COMMIT");
        return count;
    }
    pub fn timingFor(self: *Database, id: [16]u8, gpa: std.mem.Allocator) !?timing.Owned {
        var stmt = try self.prepare("SELECT timing FROM runs WHERE id=?1");
        defer stmt.deinit();
        try stmt.bindBlob(1, &id);
        if (!try stmt.step() or sqlite3_column_type(stmt.raw, 0) == 5) return null;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const payload = try decode(timing.Payload, arena.allocator(), try stmt.blob(0));
        return .{ .arena = arena, .payload = payload };
    }
    pub fn clear(self: *Database) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        // Validate before deleting. Unknown/corrupt run payloads require deliberate handling.
        var stmt = try self.rows();
        defer stmt.deinit();
        while (try stmt.step()) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            _ = try decode(results.Record, arena.allocator(), try stmt.blob(1));
            if (sqlite3_column_type(stmt.raw, 2) != 5) _ = try decode(timing.Payload, arena.allocator(), try stmt.blob(2));
        }
        try self.exec("DELETE FROM runs");
        try self.exec("COMMIT");
        // Migration receipts survive clearing so retained legacy files cannot resurrect history.
    }
    pub fn exportDatabase(self: *Database, io: std.Io, path: []const u8) !void {
        if (!std.fs.path.isAbsolute(path)) return error.AbsolutePracticeDatabasePathRequired;
        var nonce: [16]u8 = undefined;
        try std.Io.randomSecure(io, &nonce);
        const temporary = try std.fmt.allocPrint(self.gpa, "{s}.tmp-{s}", .{ path, std.fmt.bytesToHex(nonce, .lower) });
        defer self.gpa.free(temporary);
        const reserved = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true });
        reserved.close(io);
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        const name = try self.gpa.dupeSentinel(u8, temporary, 0);
        defer self.gpa.free(name);
        var destination: ?*Handle = null;
        const open_code = sqlite3_open_v2(name, &destination, 2, null);
        if (open_code != 0) {
            if (destination) |p| _ = sqlite3_close_v2(p);
            try check(open_code);
        }
        const out = destination orelse return error.PracticeDatabaseFailure;
        var opened = true;
        defer if (opened) {
            _ = sqlite3_close_v2(out);
        };
        try check(sqlite3_busy_timeout(out, 1500));
        const backup = sqlite3_backup_init(out, "main", self.handle, "main") orelse return error.PracticeDatabaseFailure;
        var finished = false;
        defer if (!finished) {
            _ = sqlite3_backup_finish(backup);
        };
        var retries: usize = 0;
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 15000;
        while (true) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return error.PracticeDatabaseBusy;
            const code = sqlite3_backup_step(backup, 256);
            if (code == 101) break;
            if (code == 5 or code == 6) {
                if (retries == 30) return error.PracticeDatabaseBusy;
                retries += 1;
                try std.Io.sleep(io, .fromMilliseconds(50), .awake);
            } else try check(code);
        }
        const finish_code = sqlite3_backup_finish(backup);
        finished = true;
        try check(finish_code);
        try check(sqlite3_close_v2(out));
        opened = false;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{});
        defer atomic.deinit(io);
        // Stream the standalone backup into an unnamed file, then publish exclusively.
        var input = try std.Io.Dir.cwd().openFile(io, temporary, .{});
        defer input.close(io);
        var buffer: [8192]u8 = undefined;
        var reader = input.reader(io, &buffer);
        var out_buffer: [8192]u8 = undefined;
        var writer = atomic.file.writer(io, &out_buffer);
        _ = try reader.interface.streamRemaining(&writer.interface);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.link(io);
    }
};
test "standalone export includes raw timing; imports are idempotent and conflicts roll back" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const first = try std.fs.path.join(t.allocator, &.{ root, "a.sqlite3" });
    defer t.allocator.free(first);
    const second = try std.fs.path.join(t.allocator, &.{ root, "b.sqlite3" });
    defer t.allocator.free(second);
    const exported = try std.fs.path.join(t.allocator, &.{ root, "portable.sqlite3" });
    defer t.allocator.free(exported);
    var a = try Database.open(t.allocator, first, false);
    defer a.deinit();
    var r = timing.Recorder.init(t.allocator);
    defer r.deinit();
    r.reset(&.{'a'});
    r.record(.attempt, 100, 0, 0, 'a', .ordinary);
    r.record(.complete, 100, 0, 1, null, .ordinary);
    var record = results.Record{ .id = @splat(1), .matched = 1, .attempts = 1, .correct_attempts = 1, .stat_count = 1, .timing_available = true };
    record.stats[0] = .{ .cp = 'a', .opportunities = 1 };
    try a.save(&record, r.payload());
    try a.save(&record, r.payload());
    try a.exportDatabase(t.io, exported);
    try t.expectError(error.PathAlreadyExists, a.exportDatabase(t.io, exported));
    var b = try Database.open(t.allocator, second, false);
    defer b.deinit();
    try t.expectEqual(@as(usize, 1), try b.importDatabase(exported));
    try t.expectEqual(@as(usize, 1), try b.importDatabase(exported));
    var saved = (try b.timingFor(record.id, t.allocator)).?;
    defer saved.deinit();
    try t.expectEqual(@as(usize, 2), saved.payload.events.len);
    try t.expectEqual(@as(u21, 'a'), saved.payload.reference[0]);
    record.timestamp = 7;
    try t.expectError(error.PracticeRunCollision, b.save(&record, r.payload()));
    try t.expectEqual(@as(i64, 1), try b.number("SELECT count(*) FROM runs"));
    try b.clear();
    try t.expectEqual(@as(i64, 0), try b.number("SELECT count(*) FROM events"));
}

test "a conflicting import rolls back earlier rows and future databases remain untouched" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const source_path = try std.fs.path.join(t.allocator, &.{ root, "source.sqlite3" });
    defer t.allocator.free(source_path);
    const target_path = try std.fs.path.join(t.allocator, &.{ root, "target.sqlite3" });
    defer t.allocator.free(target_path);
    var source = try Database.open(t.allocator, source_path, false);
    defer source.deinit();
    var target = try Database.open(t.allocator, target_path, false);
    defer target.deinit();
    var conflict = results.Record{ .id = @splat(1) };
    try source.save(&conflict, null);
    conflict.timestamp = 99;
    try target.save(&conflict, null);
    const earlier = results.Record{ .id = @splat(2), .timestamp = 100 };
    try source.save(&earlier, null);
    try t.expectError(error.PracticeRunCollision, target.importDatabase(source_path));
    try t.expectEqual(@as(usize, 1), try target.runCount());
    try source.exec("PRAGMA user_version=999");
    try t.expectError(error.UnsupportedPracticeDatabase, target.importDatabase(source_path));
    try t.expectEqual(@as(usize, 1), try target.runCount());
    try t.expectEqual(@as(i64, 999), try source.number("PRAGMA user_version"));
}

test "native independent writers share a Unicode database and readonly handles cannot mutate it" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "practice café.sqlite3" });
    defer t.allocator.free(path);
    const Writer = struct {
        fn write(database_path: []const u8, id: u8) !void {
            var db = try Database.open(std.heap.page_allocator, database_path, false);
            defer db.deinit();
            var record = results.Record{};
            record.id[0] = id;
            try db.save(&record, null);
        }
    };
    var a = try std.Io.concurrent(t.io, Writer.write, .{ path, @as(u8, 1) });
    var b = try std.Io.concurrent(t.io, Writer.write, .{ path, @as(u8, 2) });
    try a.await(t.io);
    try b.await(t.io);
    var read = try Database.open(t.allocator, path, true);
    defer read.deinit();
    try t.expectEqual(@as(usize, 2), try read.runCount());
    const record = results.Record{ .id = @splat(3) };
    try t.expectError(error.PracticeDatabaseReadOnly, read.save(&record, null));
}
