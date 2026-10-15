//! Shared native desktop graph used by the application and offline compile checks.
const std = @import("std");
pub const Graph = struct { dvui: *std.Build.Module, backend: *std.Build.Module, fonts: *std.Build.Module, ui: *std.Build.Module, events: *std.Build.Module, folder_dialog: *std.Build.Module, tray: *std.Build.Module, icons: ?*std.Build.Module, vectors: ?*std.Build.Module };
pub fn dependency(b: *std.Build, vectors: bool) ?*std.Build.Dependency {
    return b.lazyDependency("dvui", .{
        .target = b.graph.host,
        .optimize = .debug,
        .backend = .sdl3,
        .freetype = true,
        .@"tiny-file-dialogs" = false,
        .@"tree-sitter" = false,
        .tvg = vectors,
        .accesskit = .off,
    });
}
pub fn check(b: *std.Build, step: *std.Build.Step, flash_presenter: *std.Build.Module, tray_lifecycle: *std.Build.Module, vectors: bool) ?Graph {
    const dvui_dep = dependency(b, vectors) orelse return null;
    const tray_dep = b.lazyDependency("ztray", .{ .target = b.graph.host, .optimize = .debug }) orelse return null;
    const dvui = dvui_dep.module("dvui_sdl3");
    const backend = dvui_dep.module("sdl3");
    const sdl_module = backend.import_table.get("sdl3-c").?;
    var icons_module: ?*std.Build.Module = null;
    var vector_module: ?*std.Build.Module = null;
    if (vectors) {
        const svg = b.lazyDependency("svg2tvg", .{ .target = b.graph.host, .optimize = .debug });
        const icons = b.lazyDependency("icons", .{ .target = b.graph.host, .optimize = .debug });
        if (svg == null or icons == null) return null;
        vector_module = svg.?.module("svg2tvg");
        icons_module = icons.?.module("icons");
        const vector_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/desktop_vectors.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "svg2tvg", .module = vector_module.? }, .{ .name = "icons", .module = icons_module.? } },
        }) });
        b.step("test-desktop-vectors", "Decode pinned vector icons without a GUI").dependOn(&b.addRunArtifact(vector_tests).step);
    }
    const placement = b.createModule(.{
        .root_source_file = b.path("packages/platform/src/window_placement.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "sdl3-c", .module = sdl_module }},
    });
    const folder_dialog = b.createModule(.{
        .root_source_file = b.path("packages/platform/src/folder_dialog.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "sdl3-c", .module = sdl_module }},
    });
    const placement_tests = b.addTest(.{ .root_module = placement });
    const placement_tests_step = b.step("test-window-placement", "Validate reference window bounds without opening a window");
    placement_tests_step.dependOn(&b.addRunArtifact(placement_tests).step);
    const fonts = b.createModule(.{
        .root_source_file = b.path("packages/desktop/src/fonts.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "dvui", .module = dvui }},
    });
    const editor_ui = b.createModule(.{
        .root_source_file = b.path("packages/desktop/src/ui.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "dvui", .module = dvui }, .{ .name = "editor-fonts", .module = fonts } },
    });
    editor_ui.addImport("desktop-geometry", b.modules.get("desktop-geometry").?);
    const flash_ui = b.createModule(.{
        .root_source_file = b.path("packages/desktop/src/flash_ui.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "dvui", .module = dvui }, .{ .name = "flash-presenter", .module = flash_presenter } },
    });
    const tray = tray_dep.module("ztray");
    const native_tray = b.createModule(.{
        .root_source_file = b.path("packages/desktop/src/tray_native.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "ztray", .module = tray }, .{ .name = "tray-lifecycle", .module = tray_lifecycle } },
    });
    const tray_icon_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/desktop/src/tray_icon.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "dvui", .module = dvui }},
    }) });
    b.step("test-tray-icon", "Decode retained tray PNG offline without installing a tray").dependOn(&b.addRunArtifact(tray_icon_tests).step);
    const events = b.createModule(.{
        .root_source_file = b.path("packages/platform/src/events.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "dvui", .module = dvui }, .{ .name = "dvui_backend", .module = backend } },
    });
    const event_tests = b.addTest(.{ .root_module = events });
    b.step("test-desktop-events", "Validate child-window IME/drop routing without opening a window").dependOn(&b.addRunArtifact(event_tests).step);
    const probe = b.addExecutable(.{ .name = "desktop-dependency-smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/desktop_dependency_smoke.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "dvui", .module = dvui }, .{ .name = "dvui_backend", .module = backend }, .{ .name = "ztray", .module = tray }, .{ .name = "window-placement", .module = placement }, .{ .name = "editor-fonts", .module = fonts }, .{ .name = "folder-dialog", .module = folder_dialog }, .{ .name = "editor-ui", .module = editor_ui } },
    }) });
    // Force native code generation and linkage, without a run step.
    probe.root_module.addImport("flash-ui", flash_ui);
    probe.root_module.addImport("flash-presenter", flash_presenter);
    probe.root_module.addImport("native-tray", native_tray);
    probe.root_module.addImport("native-events", events);
    const audit_options = b.addOptions();
    audit_options.addOption(bool, "vectors", vectors);
    probe.root_module.addOptions("desktop-audit-options", audit_options);
    if (icons_module) |icons| probe.root_module.addImport("desktop-icons", icons);
    _ = probe.getEmittedBin();
    step.dependOn(&probe.step);
    return .{ .dvui = dvui, .backend = backend, .fonts = fonts, .ui = editor_ui, .events = events, .folder_dialog = folder_dialog, .tray = native_tray, .icons = icons_module, .vectors = vector_module };
}
