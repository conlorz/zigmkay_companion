//! Explicit preparation records bytes without executing either flash tool.
const std = @import("std");
const jobs = @import("companion-jobs");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 7) return error.Usage;
    const source_kind: @FieldType(jobs.target_lock.Lock, "source_kind") = if (std.mem.eql(u8, args[2], "development")) .development else if (std.mem.eql(u8, args[2], "published")) .published else return error.InvalidSourceKind;
    for (args[3..]) |path| if (!std.fs.path.isAbsolute(path)) return error.AbsolutePathRequired;
    var source = try std.Io.Dir.cwd().openDir(io, args[3], .{ .iterate = true });
    defer source.close(io);
    const source_digest = try jobs.preparation.treeDigest(gpa, io, source);
    // Development provenance identifies both the checkout revision and its
    // current bytes; dirty source remains visible through the separate digest.
    if (source_kind == .development) {
        var result = try jobs.run(gpa, io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = args[3], .snapshot_id = source_digest, .timeout_ms = 5000 });
        defer result.deinit(gpa);
        if (!result.successful() or !std.mem.eql(u8, std.mem.trim(u8, result.process.stdout, "\r\n"), args[1])) return error.FirmwareRevisionMismatch;
    }
    var tools = try jobs.flash_inputs.Tools.capture(gpa, io, args[1], source_digest, source_kind, args[4], args[5]);
    defer tools.deinit();
    const encoded = try tools.serialize(gpa);
    var directory = try std.Io.Dir.cwd().openDir(io, args[6], .{});
    defer directory.close(io);
    const name = jobs.flash_inputs.tools_name;
    const existing = directory.readFileAlloc(io, name, gpa, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        var old = try jobs.flash_inputs.Tools.parse(gpa, bytes);
        defer old.deinit();
    }
    var atomic = try directory.createFileAtomic(io, name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded);
    try atomic.replace(io);
}
