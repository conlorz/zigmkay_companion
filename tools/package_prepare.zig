//! Explicit preparation; archive imports are offline unless the plan opts in.
const std = @import("std");
const jobs = @import("companion-jobs");
const zon = @import("owned-zon");
const Plan = struct { version: u16 = 1, toolchain_receipt: []const u8, source_cache: []const u8, preparation: jobs.package_preparation.Plan };
const Receipt = struct { version: u16 = 1, plan_digest: jobs.firmware.Digest, record: jobs.package_resolution.Record };
const Progress = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    fn update(pointer: *anyopaque, hash: []const u8, phase: jobs.package_preparation.Phase) void {
        const self: *@This() = @ptrCast(@alignCast(pointer));
        const message = std.fmt.allocPrint(self.gpa, "{s}: {s}\n", .{ @tagName(phase), hash }) catch return;
        defer self.gpa.free(message);
        std.Io.File.stderr().writeStreamingAll(self.io, message) catch {};
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 3) return error.Usage;
    if (!std.fs.path.isAbsolute(args[1]) or !std.fs.path.isAbsolute(args[2])) return error.AbsoluteResolutionPathsRequired;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(bytes);
    const text = try init.gpa.dupeSentinel(u8, bytes, 0);
    defer init.gpa.free(text);
    const plan = try zon.parse(Plan, init.gpa, text);
    defer zon.free(init.gpa, plan);
    if (plan.version != 1) return error.UnsupportedResolutionPlan;
    if (!std.fs.path.isAbsolute(plan.toolchain_receipt) or !std.fs.path.isAbsolute(plan.source_cache)) return error.AbsolutePreparationPathsRequired;
    const compiler_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, plan.toolchain_receipt, init.gpa, .limited(32 * 1024));
    defer init.gpa.free(compiler_bytes);
    const compiler = try jobs.toolchain.Receipt.parse(init.gpa, compiler_bytes);
    defer compiler.deinit(init.gpa);
    var sources = try std.Io.Dir.cwd().openDir(init.io, plan.source_cache, .{ .iterate = true });
    defer sources.close(init.io);
    var cache = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[2], .{});
    defer cache.close(init.io);
    const filename = "dependency-preparation.zon";
    const old = cache.readFileAlloc(init.io, filename, init.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old) |existing| {
        defer init.gpa.free(existing);
        const source = try init.gpa.dupeSentinel(u8, existing, 0);
        defer init.gpa.free(source);
        const receipt = try zon.parse(Receipt, init.gpa, source);
        defer zon.free(init.gpa, receipt);
        if (receipt.version != 1) return error.UnsupportedDependencyResolution;
    }
    try compiler.verify(init.gpa, init.io);
    var progress = Progress{ .gpa = init.gpa, .io = init.io };
    var resolved = try jobs.package_preparation.prepareReported(init.gpa, init.io, init.environ_map, compiler, sources, plan.preparation, .{ .context = &progress, .update = Progress.update });
    defer resolved.deinit();
    var encoded: std.Io.Writer.Allocating = .init(init.gpa);
    defer encoded.deinit();
    try std.zon.stringify.serialize(Receipt{ .plan_digest = jobs.firmware.digest(bytes), .record = resolved.record }, .{}, &encoded.writer);
    var atomic = try cache.createFileAtomic(init.io, filename, .{ .replace = true });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, encoded.written());
    try atomic.replace(init.io);
}
