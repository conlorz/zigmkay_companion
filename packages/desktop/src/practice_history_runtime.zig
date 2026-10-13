//! Serialized background persistence. Failed records remain queued for Retry.
const std = @import("std");
const history = @import("practice_history.zig");
const results = @import("practice_results.zig");
pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8 = null,
    worker: ?*history.Worker = null,
    sequence: u64 = 0,
    queue: [16]results.Record = @splat(.{}),
    queued: usize = 0,
    writing: bool = false,
    data: history.Query = .{},
    cohort: results.Cohort = .{},
    requested_cohort: results.Cohort = .{},
    error_value: ?anyerror = null,
    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_path: ?[]const u8) !Runtime {
        return .{ .gpa = gpa, .io = io, .path = if (data_path) |path| try std.fs.path.join(gpa, &.{ path, "typing-practice" }) else null };
    }
    pub fn deinit(self: *Runtime) void {
        if (self.worker) |worker| {
            if (worker.future) |*future| {
                const outcome = future.await(self.io);
                if (outcome) |_| {
                    if (self.writing) {
                        self.queued -= 1;
                        std.mem.copyForwards(results.Record, self.queue[0..self.queued], self.queue[1 .. self.queued + 1]);
                    }
                } else |err| std.log.err("Practice history shutdown: {s}", .{@errorName(err)});
                worker.future = null;
            }
            worker.destroy();
            self.worker = null;
        }
        // Final shutdown is outside rendering. Drain all completed runs rather
        // than dropping a run queued while another write was in progress.
        if (self.path) |path| {
            for (self.queue[0..self.queued]) |record| {
                var final_request = history.Request.init(self.gpa, path, record.cohort) catch |err| {
                    std.log.err("Practice history shutdown: {s}", .{@errorName(err)});
                    break;
                };
                defer final_request.deinit();
                final_request.record = record;
                _ = final_request.prepare(self.gpa, self.io) catch |err| {
                    std.log.err("Practice history shutdown: {s}", .{@errorName(err)});
                    break;
                };
            }
            self.gpa.free(path);
        }
    }
    pub fn enqueue(self: *Runtime, record: results.Record) !void {
        for (self.queue[0..self.queued]) |old| if (std.mem.eql(u8, &old.id, &record.id)) return;
        if (self.queued == self.queue.len) return error.PracticeSaveQueueFull;
        self.queue[self.queued] = record;
        self.queued += 1;
    }
    pub fn poll(self: *Runtime) void {
        if (self.worker) |worker| if (worker.poll()) |event| {
            defer worker.destroy();
            self.worker = null;
            const data = event.result catch |err| {
                self.error_value = err;
                return;
            };
            self.data = data;
            self.cohort = self.requested_cohort;
            self.error_value = null;
            if (self.writing) {
                self.queued -= 1;
                std.mem.copyForwards(results.Record, self.queue[0..self.queued], self.queue[1 .. self.queued + 1]);
            }
        };
    }
    pub fn request(self: *Runtime, cohort: results.Cohort, before: ?results.Record, clearing: bool, retry: bool, current_id: ?[16]u8) !void {
        if (self.worker != null) return;
        if (self.error_value != null and !retry) return;
        const path = self.path orelse return error.PracticeStorageUnavailable;
        var work_request = try history.Request.init(self.gpa, path, cohort);
        errdefer work_request.deinit();
        if (clearing) self.queued = 0;
        self.writing = self.queued > 0;
        if (self.writing) work_request.record = self.queue[0];
        work_request.before = before;
        work_request.current_id = current_id;
        work_request.clearing = clearing;
        self.sequence += 1;
        self.worker = try history.Worker.create(self.gpa, self.io, &work_request, self.sequence);
        self.requested_cohort = cohort;
        self.error_value = null;
    }
};

test "background saves drain once retries retain IDs and reopening restores completed runs" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var runtime = try Runtime.init(t.allocator, t.io, root);
    defer runtime.deinit();
    var record: results.Record = .{};
    record.id[0] = 7;
    try runtime.enqueue(record);
    try runtime.enqueue(record);
    try t.expectEqual(@as(usize, 1), runtime.queued);
    try runtime.request(.{}, null, false, false, record.id);
    const deadline = std.Io.Clock.awake.now(t.io).toMilliseconds() + 5000;
    while (runtime.worker != null) {
        runtime.poll();
        if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.PracticeWorkerDeadline;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(runtime.error_value == null);
    try t.expectEqual(@as(usize, 0), runtime.queued);
    try t.expect(runtime.data.contains_requested);
    var reopened = try Runtime.init(t.allocator, t.io, root);
    defer reopened.deinit();
    try reopened.request(.{}, null, false, false, null);
    while (reopened.worker != null) {
        reopened.poll();
        if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.PracticeWorkerDeadline;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expectEqual(@as(usize, 1), reopened.data.total);
    // An unwritable storage route preserves the queued record for explicit retry.
    const valid = runtime.path.?;
    runtime.path = try std.fs.path.join(t.allocator, &.{ root, "not a directory" });
    defer {
        t.allocator.free(runtime.path.?);
        runtime.path = valid;
    }
    try temp.dir.writeFile(t.io, .{ .sub_path = "not a directory", .data = "preserve this file" });
    record.id[0] = 8;
    try runtime.enqueue(record);
    try runtime.request(.{}, null, false, false, record.id);
    while (runtime.worker != null) {
        runtime.poll();
        if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.PracticeWorkerDeadline;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(runtime.error_value != null);
    try t.expectEqual(@as(usize, 1), runtime.queued);
}
