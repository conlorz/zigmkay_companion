const std = @import("std");
/// Both the legacy wrapper and active input source use the same Zig and native bridges.
pub fn keymapModule(b: *std.Build, root: std.Build.LazyPath, keycodes: *std.Build.Module, target: std.Build.ResolvedTarget, native: bool, us_fixture: bool) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "native_available", native);
    options.addOption(bool, "us_fixture", us_fixture);
    const module = b.createModule(.{ .root_source_file = root.path(b, "src/root.zig"), .target = target, .imports = &.{.{ .name = "zkeycodes", .module = keycodes }} });
    module.addOptions("options", options);
    addPlatformSources(b, root, module, target, native);
    return module;
}
pub const Published = struct {
    module: *std.Build.Module,
    source: *std.Build.Module,
    tests: *std.Build.Step,
    native_check: *std.Build.Step,
    native_available: bool,
};
/// The selected firmware owns keycodes. Native checks compile/link without
/// running the smoke entrypoint or querying the OS input source.
pub fn publish(b: *std.Build, root: std.Build.LazyPath, keycodes: *std.Build.Module, target: std.Build.ResolvedTarget) Published {
    const native_available = switch (target.result.os.tag) {
        .macos, .windows => true,
        .linux => b.graph.host.result.os.tag == .linux,
        else => false,
    };
    const module = keymapModule(b, root, keycodes, target, native_available, false);
    const source = b.createModule(.{ .root_source_file = root.path(b, "src/input_source.zig"), .target = target, .imports = &.{.{ .name = "zkeymap", .module = module }} });
    const tests = b.step("test-input-source", "Run pure HID mappings and text-result tests without querying active input");
    const pure = keymapModule(b, root, keycodes, b.graph.host, false, false);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pure })).step);
    const hid = b.createModule(.{ .root_source_file = root.path(b, "src/hid_to_platform.zig"), .imports = &.{.{ .name = "zkeycodes", .module = keycodes }} });
    const tables = b.createModule(.{ .root_source_file = root.path(b, "src/hid_to_platform.test.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "hid_to_platform", .module = hid } } });
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tables })).step);
    const native_check = b.step("check-input-source", "Compile/link target native layout source and composition without running it");
    const smoke = b.addExecutable(.{ .name = "input-source-native-check", .root_module = b.createModule(.{ .root_source_file = root.path(b, "src/native_smoke.zig"), .target = target, .imports = &.{ .{ .name = "zkeymap", .module = module }, .{ .name = "input-source", .module = source } } }) });
    _ = smoke.getEmittedBin();
    native_check.dependOn(&smoke.step);
    return .{ .module = module, .source = source, .tests = tests, .native_check = native_check, .native_available = native_available };
}
fn addPlatformSources(b: *std.Build, root: std.Build.LazyPath, module: *std.Build.Module, target: std.Build.ResolvedTarget, available: bool) void {
    if (!available) return;
    switch (target.result.os.tag) {
        .macos => {
            module.addCSourceFile(.{ .file = root.path(b, "src/platform/macos.c"), .flags = &.{"-std=c11"} });
            module.linkFramework("Carbon", .{});
            module.link_libc = true;
        },
        .windows => {
            module.addCSourceFile(.{ .file = root.path(b, "src/platform/windows.c"), .flags = &.{"-std=c11"} });
            module.linkSystemLibrary("user32", .{});
            module.link_libc = true;
        },
        .linux => {
            module.addCSourceFile(.{ .file = root.path(b, "src/platform/linux.c"), .flags = &.{"-std=c11"} });
            module.linkSystemLibrary("xkbcommon", .{});
            module.link_libc = true;
        },
        else => {},
    }
}
