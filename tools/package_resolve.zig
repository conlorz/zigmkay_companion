//! Explicit read-only transitive resolution over caller-prepared source records.
const std = @import("std");
const jobs = @import("companion-jobs");
const zon = @import("owned-zon");
const Plan = struct { version: u16 = 1, options: jobs.package_resolution.Options };
const Receipt = struct { version: u16 = 1, plan_digest: jobs.firmware.Digest, record: jobs.package_resolution.Record };
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
    var resolved = try jobs.package_resolution.resolve(init.gpa, init.io, plan.options);
    defer resolved.deinit();
    var cache = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[2], .{});
    defer cache.close(init.io);
    const filename = "dependency-resolution.zon";
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
    var encoded: std.Io.Writer.Allocating = .init(init.gpa);
    defer encoded.deinit();
    try std.zon.stringify.serialize(Receipt{ .plan_digest = jobs.firmware.digest(bytes), .record = resolved.record }, .{}, &encoded.writer);
    var atomic = try cache.createFileAtomic(init.io, filename, .{ .replace = true });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, encoded.written());
    try atomic.replace(init.io);
}
