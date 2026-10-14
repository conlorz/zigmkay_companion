//! Explicit exercise of the editor's managed QWERTY build pipeline (offline by default).
const std = @import("std");
const p = @import("project");
const desktop = @import("desktop-core");
const Arguments = struct {
    config_path: []const u8,
    allow_pinned_fetch: bool,
};

fn parseArguments(args: []const []const u8) !Arguments {
    if (args.len != 2 and args.len != 3) return error.AbsolutePreparedBuildConfigRequired;
    if (!std.fs.path.isAbsolute(args[1])) return error.AbsolutePreparedBuildConfigRequired;
    if (args.len == 3 and !std.mem.eql(u8, args[2], "--allow-pinned-fetch")) return error.UnknownOption;
    return .{ .config_path = args[1], .allow_pinned_fetch = args.len == 3 };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    const options = try parseArguments(args);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, options.config_path, init.gpa, .limited(1024 * 1024));
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
    var config = plan.config;
    if (options.allow_pinned_fetch) config.request.dependency_access = .allow_pinned_fetch;
    var request = try desktop.build_worker.Request.capture(&model, config, init.environ_map, 1);
    defer request.deinit();
    var prepared = try request.prepare(init.gpa, init.io);
    defer prepared.deinit();
    var bundle = try prepared.takeBundle(&model, .{ .generation = 1, .snapshot = request.captured });
    defer bundle.deinit();
    try bundle.runner.verifyFile(init.gpa, init.io, bundle.firmware.inputs);
    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    try output.writer.print("Verified managed QWERTY build\nPinned dependency fetch permission: {s} (not a claim that network was used)\nUF2: {s}\nRunner: {s}\n", .{ if (options.allow_pinned_fetch) @as([]const u8, "allowed") else "not allowed", bundle.firmware.uf2_path, bundle.runner.record.path });
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}

test "managed build arguments default offline and require explicit fetch permission" {
    const t = std.testing;
    const offline = try parseArguments(&.{ "check-managed-build", "/prepared.zon" });
    try t.expect(!offline.allow_pinned_fetch);
    const fetch = try parseArguments(&.{ "check-managed-build", "/prepared.zon", "--allow-pinned-fetch" });
    try t.expect(fetch.allow_pinned_fetch);
    try t.expectError(error.UnknownOption, parseArguments(&.{ "check-managed-build", "/prepared.zon", "--other" }));
    try t.expectError(error.AbsolutePreparedBuildConfigRequired, parseArguments(&.{ "check-managed-build", "relative.zon" }));
}
