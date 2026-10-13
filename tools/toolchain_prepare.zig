//! Explicit selected-installation preparation. No downloads, builds or devices.
const std = @import("std");
const jobs = @import("companion-jobs");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--verify")) {
        if (!std.fs.path.isAbsolute(args[2])) return error.AbsoluteCacheRequired;
        var cache = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
        defer cache.close(init.io);
        const bytes = try cache.readFileAlloc(init.io, jobs.toolchain.filename, init.gpa, .limited(32 * 1024));
        defer init.gpa.free(bytes);
        const receipt = try jobs.toolchain.Receipt.parse(init.gpa, bytes);
        defer receipt.deinit(init.gpa);
        return receipt.verify(init.gpa, init.io);
    }
    if (args.len != 4) return error.Usage;
    if (!std.fs.path.isAbsolute(args[3])) return error.AbsoluteCacheRequired;
    var prepared = try jobs.toolchain.prepare(init.gpa, init.io, .{ .compiler = args[1], .distribution = args[2] });
    defer prepared.deinit();
    var cache = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[3], .{});
    defer cache.close(init.io);
    try jobs.toolchain.save(init.gpa, init.io, cache, prepared.receipt);
}
