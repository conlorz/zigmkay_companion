//! Joined offline flash admission. No transfer or device discovery occurs here.
const std = @import("std");
const desktop = @import("desktop-core");
const jobs = @import("companion-jobs");
const flash = @import("flash_session.zig");

pub const FlashAdmission = struct {
    request: desktop.build_worker.Request,
    tools: jobs.flash_inputs.Tools,
    manifest: jobs.firmware.Manifest,
    expected_export_tree: jobs.firmware.Digest,
    cache: std.Io.Dir,
    cache_path: []const u8,
    snapshot: [32]u8,
    generation: u64,
    now: u64,
    /// Inputs may borrow caller storage until create returns. The worker copies
    /// manifest/path and opens its own cache handle before scheduling.
    pub fn deinit(self: *FlashAdmission) void {
        self.request.deinit();
        self.tools.deinit();
        self.* = undefined;
    }
};

pub const Worker = struct {
    const Self = @This();
    pub const Event = struct { generation: u64, snapshot: [32]u8, result: anyerror!flash.Session };
    gpa: std.mem.Allocator,
    io: std.Io,
    admission: FlashAdmission,
    owned_manifest: jobs.firmware.Manifest,
    owned_cache_path: []u8,
    owned_cache: std.Io.Dir,
    future: ?std.Io.Future(anyerror!flash.Session) = null,
    done: std.atomic.Value(bool) = .init(false),

    /// Transfers admission ownership only on successful scheduling.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, admission: *FlashAdmission) !*Self {
        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);
        const serialized = try admission.manifest.serialize(gpa);
        defer gpa.free(serialized);
        var manifest = try jobs.firmware.Manifest.parse(gpa, serialized);
        errdefer manifest.deinit();
        const path = try admission.cache.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(path);
        if (!std.mem.eql(u8, path, admission.cache_path)) return error.CachePathMismatch;
        var cache = try std.Io.Dir.cwd().openDir(io, path, .{});
        errdefer cache.close(io);
        self.* = .{ .gpa = gpa, .io = io, .admission = admission.*, .owned_manifest = manifest, .owned_cache_path = path, .owned_cache = cache };
        self.future = try std.Io.concurrent(io, prepare, .{self});
        admission.* = undefined;
        return self;
    }

    fn prepare(self: *Self) anyerror!flash.Session {
        defer self.done.store(true, .release);
        const a = &self.admission;
        // Session takes tools/request ownership on success only. Keep admission
        // intact on failure so destroy can release it.
        var session = try flash.Session.init(self.gpa, self.io, a.snapshot, a.generation, self.owned_manifest, a.request, a.expected_export_tree, a.tools);
        a.request = undefined;
        a.tools = undefined;
        self.transferred.store(true, .release);
        errdefer session.deinit();
        try session.prepare(a.now);
        try session.built(self.owned_manifest, a.now);
        try session.freeze(self.owned_manifest, self.owned_cache, self.owned_cache_path, a.now);
        return session;
    }

    pub fn poll(self: *Self) ?Event {
        if (self.future == null or !self.done.load(.acquire)) return null;
        const result = self.future.?.await(self.io);
        self.future = null;
        return .{ .generation = self.admission.generation, .snapshot = self.admission.snapshot, .result = result };
    }

    /// Join before freeing any admission storage. The caller owns a polled session.
    pub fn destroy(self: *Self) void {
        if (self.future) |*future| {
            if (future.cancel(self.io)) |completed| {
                var session = completed;
                session.deinit();
            } else |_| {}
        }
        // Request and tools move into Session when initialization succeeds.
        // See ownership flag below.
        if (!self.transferred.load(.acquire)) self.admission.deinit();
        self.owned_manifest.deinit();
        self.owned_cache.close(self.io);
        self.gpa.free(self.owned_cache_path);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }
    transferred: std.atomic.Value(bool) = .init(false),
};
