//! Explicit read-only capture from a revalidated prepared dependency graph.
const std = @import("std");
const jobs = @import("companion-jobs");
const zon = @import("owned-zon");
const Plan = struct {
    version: u16 = 1,
    resolution: jobs.package_resolution.Record,
    source_cache: ?[]const u8 = null,
    selection: jobs.build_provenance.Selection,
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 2 or !std.fs.path.isAbsolute(args[1])) return error.AbsoluteBuildCapturePlanRequired;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(bytes);
    const text = try init.gpa.dupeSentinel(u8, bytes, 0);
    defer init.gpa.free(text);
    const plan = try zon.parse(Plan, init.gpa, text);
    defer zon.free(init.gpa, plan);
    if (plan.version != 1) return error.UnsupportedBuildCapturePlan;
    // This command never runs a compiler; version execution belongs to preparation.
    if (plan.selection.verify_compiler_version) return error.CompilerExecutionRequiresPreparation;
    var captured = try jobs.package_resolution.capture(init.gpa, init.io, plan.resolution, plan.source_cache, plan.selection);
    defer captured.deinit();
    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    try std.zon.stringify.serialize(.{ .version = @as(u16, 1), .plan_digest = jobs.firmware.digest(bytes), .resolution_digest = plan.resolution.resolution_digest, .inputs = captured.inputs, .receipt = captured.receipt }, .{}, &output.writer);
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}
