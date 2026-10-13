//! Explicit offline exercise of the editor's managed QWERTY build pipeline.
const std = @import("std");
const p = @import("project");
const desktop = @import("desktop-core");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 2 or !std.fs.path.isAbsolute(args[1])) return error.AbsolutePreparedBuildConfigRequired;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(bytes);
    const text = try init.gpa.dupeSentinel(u8, bytes, 0);
    defer init.gpa.free(text);
    const plan = try p.owned_zon.parse(desktop.build_worker.Plan, init.gpa, text);
    defer p.owned_zon.free(init.gpa, plan);
    if (plan.version != 1) return error.UnsupportedPreparedBuildConfig;
    var loaded = try p.profiles.create(init.gpa, .qwerty);
    defer loaded.deinit();
    var model = try desktop.model.Model.init(init.gpa, p.profiles.board, loaded.snapshot);
    defer model.deinit();
    var request = try desktop.build_worker.Request.capture(&model, plan.config, init.environ_map, 1);
    defer request.deinit();
    var prepared = try request.prepare(init.gpa, init.io);
    defer prepared.deinit();
    var bundle = try prepared.takeBundle(&model, .{ .generation = 1, .snapshot = request.captured });
    defer bundle.deinit();
    try bundle.runner.verifyFile(init.gpa, init.io, bundle.firmware.inputs);
    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    try output.writer.print("Verified managed QWERTY build\nUF2: {s}\nRunner: {s}\n", .{ bundle.firmware.uf2_path, bundle.runner.record.path });
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}
