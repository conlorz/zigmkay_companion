const std = @import("std");

pub fn runner(b: *std.Build, name: []const u8, firmware: *std.Build.Module, profile: *std.Build.Module, protocol: *std.Build.Module, snapshot_id: ?[32]u8) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([32]u8, "snapshot_id", snapshot_id orelse @splat(0));
    options.addOption(bool, "verify_snapshot", snapshot_id != null);
    const module = b.createModule(.{
        .root_source_file = b.path("packages/runner/src/main.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "zigmkay", .module = firmware }, .{ .name = "selected-profile", .module = profile }, .{ .name = "runner-protocol", .module = protocol } },
    });
    module.addOptions("snapshot-options", options);
    return b.addExecutable(.{ .name = name, .root_module = module });
}

fn fixture(b: *std.Build, project: *std.Build.Module, name: []const u8, mode: ?[]const u8) std.Build.LazyPath {
    const generator = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("packages/runner/src/fixture.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "keymap-project", .module = project }},
    }) });
    const run = b.addRunArtifact(generator);
    const source = run.addOutputFileArg("keymap.zig");
    if (mode) |arg| run.addArg(arg);
    return source;
}

pub fn tests(b: *std.Build, step: *std.Build.Step, check: *std.Build.Step, firmware: *std.Build.Module, project: *std.Build.Module, registered_handler: *std.Build.Module, jobs: *std.Build.Module, protocol: *std.Build.Module, zon: *std.Build.Module) *std.Build.Step.Compile {
    const client = b.addModule("runner-client", .{ .root_source_file = b.path("packages/runner/src/client.zig"), .imports = &.{ .{ .name = "runner-protocol", .module = protocol }, .{ .name = "companion-jobs", .module = jobs }, .{ .name = "owned-zon", .module = zon } } });
    const async_client = b.addModule("runner-async", .{ .root_source_file = b.path("packages/runner/src/async_client.zig"), .imports = &.{ .{ .name = "runner-client", .module = client }, .{ .name = "runner-protocol", .module = protocol }, .{ .name = "companion-jobs", .module = jobs } } });
    b.modules.get("desktop-core").?.addImport("runner-async", async_client);
    const a = fixture(b, project, "runner-fixture", null);
    const basic_profile = b.createModule(.{ .root_source_file = a, .imports = &.{.{ .name = "zigmkay", .module = firmware }} });
    const basic = runner(b, "keymap-test", firmware, basic_profile, protocol, null);
    const rejected_snapshot = runner(b, "reject-zero-snapshot", firmware, basic_profile, protocol, @as([32]u8, @splat(0)));
    rejected_snapshot.expect_errors = .{ .contains = "Export snapshot identity mismatch" };
    step.dependOn(&rejected_snapshot.step);
    check.dependOn(&rejected_snapshot.step);
    const invalid = b.addExecutable(.{ .name = "invalid-runner-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("packages/runner/src/invalid_fixture.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "runner-protocol", .module = protocol }, .{ .name = "test-profile", .module = basic_profile }, .{ .name = "zigmkay", .module = firmware } },
    }) });
    const actions = fixture(b, project, "runner-actions", "all-actions");
    const handler = b.createModule(.{ .root_source_file = b.path("packages/runner/src/callback_fixture.zig"), .imports = &.{.{ .name = "zigmkay", .module = firmware }} });
    const action_profile = b.createModule(.{ .root_source_file = actions, .imports = &.{ .{ .name = "zigmkay", .module = firmware }, .{ .name = "callback_0", .module = handler } } });
    const action_runner = runner(b, "action-runner", firmware, action_profile, protocol, null);
    const registered = fixture(b, project, "runner-registered", "danish");
    const registered_profile = b.createModule(.{ .root_source_file = registered, .imports = &.{ .{ .name = "zigmkay", .module = firmware }, .{ .name = "callback_0", .module = registered_handler } } });
    const registered_runner = runner(b, "registered-runner", firmware, registered_profile, protocol, null);
    const artifact = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/runner/src/test_runner.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "runner-protocol", .module = protocol }, .{ .name = "zigmkay", .module = firmware }, .{ .name = "companion-jobs", .module = jobs }, .{ .name = "owned-zon", .module = zon }, .{ .name = "runner-client", .module = client }, .{ .name = "test-profile", .module = basic_profile }, .{ .name = "project", .module = project } },
    }) });
    const options = b.addOptions();
    options.addOptionPath("runner_path", basic.getEmittedBin());
    options.addOptionPath("invalid_runner_path", invalid.getEmittedBin());
    options.addOptionPath("action_runner_path", action_runner.getEmittedBin());
    options.addOptionPath("registered_runner_path", registered_runner.getEmittedBin());
    artifact.root_module.addOptions("options", options);
    artifact.root_module.addImport("runner-async", async_client);
    artifact.root_module.addImport("desktop-core", b.modules.get("desktop-core").?);
    step.dependOn(&b.addRunArtifact(artifact).step);
    check.dependOn(&artifact.step);
    return basic;
}
