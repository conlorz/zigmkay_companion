//! Deliberate offline package import, using only a recorded compiler and cache.
const std = @import("std");
const jobs = @import("companion-jobs");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 5) return error.Usage;
    for ([_]usize{ 1, 3, 4 }) |index| if (!std.fs.path.isAbsolute(args[index])) return error.AbsolutePackagePathsRequired;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(32 * 1024));
    defer init.gpa.free(bytes);
    const compiler = try jobs.toolchain.Receipt.parse(init.gpa, bytes);
    defer compiler.deinit(init.gpa);
    var cache = try std.Io.Dir.cwd().openDir(init.io, args[4], .{ .iterate = true });
    defer cache.close(init.io);
    var source = try jobs.package_cache.acquire(init.gpa, init.io, init.environ_map, compiler, cache, args[2], .{ .offline_archive = args[3] });
    defer source.deinit();
    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    try std.zon.stringify.serialize(source.source, .{}, &output.writer);
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}
