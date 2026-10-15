const std = @import("std");

pub fn module(b: *std.Build, firmware: *std.Build.Module, keycodes: *std.Build.Module, us_fixture: bool) *std.Build.Module {
    _ = firmware;
    const shared = @import("../input-source/build.zig").keymapModule(b, b.path("packages/input-source"), keycodes, b.graph.host, !us_fixture, us_fixture);
    return b.createModule(.{
        .root_source_file = b.path("packages/keymap/src/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "input-keymap", .module = shared }},
    });
}

pub fn tests(b: *std.Build, firmware: *std.Build.Module, keycodes: *std.Build.Module, tests_step: *std.Build.Step, check: *std.Build.Step) void {
    const portable = module(b, firmware, keycodes, true);
    const native = module(b, firmware, keycodes, false);
    b.modules.put(b.allocator, "zkeymap", native) catch @panic("out of memory");
    const step = b.step("test-keymap", "Run deterministic offline labels, wrapper and HID mapping tests");
    for ([_]*std.Build.Module{
        portable,
        b.createModule(.{
            .root_source_file = b.path("packages/keymap/src/hid_to_platform.test.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "hid_to_platform", .module = b.createModule(.{ .root_source_file = b.path("packages/input-source/src/hid_to_platform.zig"), .imports = &.{.{ .name = "zkeycodes", .module = keycodes }} }) } },
        }),
        b.createModule(.{
            .root_source_file = b.path("packages/keymap/example/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "zkeymap", .module = portable }},
        }),
    }) |root| {
        const artifact = b.addTest(.{ .root_module = root });
        check.dependOn(&artifact.step);
        step.dependOn(&b.addRunArtifact(artifact).step);
    }
    tests_step.dependOn(step);
    const native_tests = b.addTest(.{ .root_module = native });
    b.step("check-native-keymap", "Compile retained native layout bridge without querying the OS").dependOn(&native_tests.step);
    b.step("test-native-keymap", "Explicitly test current native layout (US fixture assumptions apply)").dependOn(&b.addRunArtifact(native_tests).step);
}
