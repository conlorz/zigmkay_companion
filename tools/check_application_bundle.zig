//! Build a catalog project through the same bundled context used by the editor.
const std = @import("std");
const desktop = @import("desktop-core");
const project = @import("project");
const catalog = @import("catalog-project");
const jobs = @import("companion-jobs");
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    // toSlice requires an arena: Windows returns a view into a larger allocation.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.Usage;
    var resources = if (@import("builtin").os.tag == .windows)
        try jobs.application_bundle.Bundle.fromExecutable(a, init.io, args[1], args[2])
    else
        try jobs.application_bundle.Bundle.open(a, init.io, args[1]);
    defer resources.deinit();
    if (std.mem.eql(u8, args[3], "all")) {
        for (@import("catalog-inventory").entries) |entry| try check(init, resources, args[2], entry.selector);
    } else try check(init, resources, args[2], args[3]);
}
fn check(init: std.process.Init, resources: jobs.application_bundle.Bundle, cache: []const u8, selector: []const u8) !void {
    std.log.info("Offline bundle build starting: {s}", .{selector});
    const a = init.gpa;
    var board = try catalog.OwnedBoard.init(a, selector);
    defer board.deinit();
    var source = try catalog.createDefault(a, board);
    defer source.deinit();
    var model = try desktop.model.Model.init(a, board.board, source.snapshot);
    defer model.deinit();
    const plan = try desktop.application_bundle.plan(a, resources, cache, selector, board.board.id);
    defer project.owned_zon.free(a, plan);
    var request = try desktop.build_worker.Request.capture(&model, plan.config, init.environ_map, 1);
    defer request.deinit();
    var candidate = try request.prepare(a, init.io);
    defer candidate.deinit();
    var result = try candidate.takeBundle(&model, .{ .generation = 1, .snapshot = request.captured });
    defer result.deinit();
    try result.runner.verifyFile(a, init.io, result.firmware.inputs);
    std.log.info("Offline bundle build passed: {s}", .{selector});
}
