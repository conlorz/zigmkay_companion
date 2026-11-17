//! Explicit curated profile navigation. Preparation is read-only and owns its result.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
pub const Worker = @import("owned_worker.zig").Owner(Request, Prepared, error.InvalidProfileGeneration);
pub fn profile(id: [8]u8) !p.profiles.Profile {
    const ids = [_][8]u8{ "danish\x00\x00".*, "qwerty\x00\x00".*, "eurkey\x00\x00".*, "eurmac\x00\x00".* };
    for (ids, 0..) |known, index| if (std.mem.eql(u8, &id, &known)) return @fromBackingInt(@intCast(index));
    return error.UnknownProfile;
}
pub const Request = struct {
    gpa: std.mem.Allocator,
    captured: [32]u8,
    id: [8]u8,
    path: []const u8,
    pub fn capture(model: *const Model, id: [8]u8, path: []const u8) !Request {
        if (!std.mem.eql(u8, &model.board.id, &p.profiles.board.id)) return error.ProfileBoardUnavailable;
        try p.validate(model.document(), p.profiles.board);
        _ = try profile(id);
        if (model.dirty()) return error.UnsavedProject;
        if (!std.fs.path.isAbsolute(path) or path.len == 0 or path.len >= 1024 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidProjectPath;
        const captured = try model.id();
        return .{ .gpa = model.gpa, .captured = captured, .id = id, .path = try model.gpa.dupe(u8, path) };
    }
    pub fn deinit(self: *Request) void {
        self.gpa.free(self.path);
        self.* = undefined;
    }
    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io) !Prepared {
        const directory = std.Io.Dir.cwd().openDir(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (directory) |dir| dir.close(io);
        var loaded: ?p.snapshot.Loaded = null;
        defer if (loaded) |*snapshot| snapshot.deinit();
        if (directory) |dir| {
            const present = dir.openFile(io, "project.zon", .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (present) |file| {
                file.close(io);
                loaded = try p.snapshot.load(gpa, io, dir, p.profiles.board);
            }
        }
        const existing = loaded != null;
        if (!existing) loaded = try p.profiles.create(gpa, try profile(self.id));
        if (!std.mem.eql(u8, &loaded.?.snapshot.document.profile_id, &self.id)) return error.ProfileIdentityMismatch;
        var candidate = try Model.init(gpa, p.profiles.board, loaded.?.snapshot);
        errdefer candidate.deinit();
        return .{ .captured = self.captured, .candidate = candidate, .existing = existing };
    }
};
pub const Prepared = struct {
    captured: [32]u8,
    candidate: ?Model,
    existing: bool,
    pub fn deinit(self: *Prepared) void {
        if (self.candidate) |*candidate| candidate.deinit();
        self.* = undefined;
    }
    pub fn promote(self: *Prepared, model: *Model) !void {
        if (self.candidate == null or !std.mem.eql(u8, &self.captured, &(try model.id()))) return error.StaleProfileAction;
        if (model.dirty()) return error.UnsavedProject;
        model.deinit();
        model.* = self.candidate.?;
        self.candidate = null;
    }
};
