//! Shared native desktop graph used by the application and offline compile checks.
const std = @import("std");
pub const VectorSources = struct { svg2tvg: std.Build.LazyPath, icons: std.Build.LazyPath };
pub const Graph = struct { dvui: *std.Build.Module, backend: *std.Build.Module, fonts: *std.Build.Module, ui: *std.Build.Module, events: *std.Build.Module, folder_dialog: *std.Build.Module, tray: *std.Build.Module, icons: ?*std.Build.Module, vectors: ?*std.Build.Module };
pub fn check(b: *std.Build, step: *std.Build.Step, dvui_source: std.Build.LazyPath, tray_source: std.Build.LazyPath, flash_presenter: *std.Build.Module, tray_lifecycle: *std.Build.Module, vectors: ?VectorSources) ?Graph {
    const sdl = b.lazyDependency("sdl3", .{ .target = b.graph.host, .optimize = .Debug }) orelse return null;
    @import("sdl_build.zig").prepare(sdl.artifact("SDL3"));
    const freetype = b.lazyDependency("freetype", .{ .target = b.graph.host, .optimize = .Debug }) orelse return null;
    const c = b.addTranslateC(.{
        .root_source_file = dvui_source.path(b, "src/dvui-c.h"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    c.addIncludePath(dvui_source.path(b, "vendor/stb"));
    c.defineCMacro("DVUI_USE_LIBC", "1");
    c.defineCMacro("DVUI_USE_FREETYPE", "1");
    c.addIncludePath(freetype.path("include"));
    const dvui = b.createModule(.{
        .root_source_file = dvui_source.path(b, "src/dvui.zig"),
        .target = b.graph.host,
        .link_libc = true,
        .imports = &.{.{ .name = "dvui-c", .module = c.createModule() }},
    });
    dvui.linkLibrary(freetype.artifact("freetype"));
    for ([_][]const u8{ "stb_image_impl.c", "stb_image_write_impl.c", "stb_truetype_impl.c" }) |file| dvui.addCSourceFile(.{
        .file = dvui_source.path(b, b.fmt("vendor/stb/{s}", .{file})),
    });
    const options = b.addOptions();
    options.addOption(?[]const u8, "snapshot_image_suffix", null);
    options.addOption(?[]const u8, "image_dir", null);
    options.addOption(?u8, "log_stack_trace", null);
    options.addOption(?bool, "log_error_trace", null);
    options.addOption(bool, "tvg", vectors != null);
    options.addOption(enum { u16, u32 }, "vertex_index", .u16);
    options.addOption(enum { off, static, dynamic }, "accesskit", .off);
    dvui.addOptions("build_options", options);
    var icons_module: ?*std.Build.Module = null;
    var vector_module: ?*std.Build.Module = null;
    if (vectors) |sources| {
        vector_module = b.createModule(.{ .root_source_file = sources.svg2tvg.path(b, "src/root.zig"), .target = b.graph.host });
        dvui.addImport("svg2tvg", vector_module.?);
        icons_module = b.createModule(.{ .root_source_file = sources.icons.path(b, "src/root.zig"), .target = b.graph.host });
        const vector_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/desktop_vectors.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "svg2tvg", .module = vector_module.? }, .{ .name = "icons", .module = icons_module.? } },
        }) });
        b.step("test-desktop-vectors", "Decode immutable reference vector icons without a GUI").dependOn(&b.addRunArtifact(vector_tests).step);
    }
    const defaults = b.addOptions();
    defaults.addOption(bool, "libc", true);
    defaults.addOption(bool, "freetype", true);
    defaults.addOption(bool, "tiny_file_dialogs", false);
    defaults.addOption(bool, "tree_sitter", false);
    dvui.addOptions("default_options", defaults);
    const renderer = b.createModule(.{
        .root_source_file = dvui_source.path(b, "src/backends/render/default.zig"),
        .imports = &.{.{ .name = "dvui", .module = dvui }},
    });
    dvui.addImport("render_backend", renderer);
    const sdl_c = b.addTranslateC(.{
        .root_source_file = dvui_source.path(b, "src/backends/sdl3-c.h"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    sdl_c.addIncludePath(sdl.artifact("SDL3").getEmittedIncludeTree());
    const sdl_module = sdl_c.createModule();
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
    const backend = b.createModule(.{
        .root_source_file = dvui_source.path(b, "src/backends/sdl.zig"),
        .target = b.graph.host,
        .link_libc = true,
        .imports = &.{ .{ .name = "dvui", .module = dvui }, .{ .name = "sdl3-c", .module = sdl_module } },
    });
    backend.linkLibrary(sdl.artifact("SDL3"));
    const sdl_options = b.addOptions();
    sdl_options.addOption(std.SemanticVersion, "version", .{ .major = 3, .minor = 0, .patch = 0 });
    sdl_options.addOption(?bool, "callbacks", null);
    backend.addOptions("sdl_options", sdl_options);
    dvui.addImport("backend", backend);
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
    const menu = b.createModule(.{ .root_source_file = tray_source.path(b, "src/zmenu.zig"), .target = b.graph.host });
    const flash_ui = b.createModule(.{
        .root_source_file = b.path("packages/desktop/src/flash_ui.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "dvui", .module = dvui }, .{ .name = "flash-presenter", .module = flash_presenter } },
    });
    const tray = b.createModule(.{
        .root_source_file = tray_source.path(b, "src/ztray.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "zmenu", .module = menu }},
    });
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
    if (b.graph.host.result.os.tag == .macos) {
        backend.addCSourceFile(.{ .file = dvui_source.path(b, "src/backends/macos_monitor.m"), .language = .objective_c });
        backend.linkFramework("AppKit", .{});
        menu.addCSourceFile(.{ .file = tray_source.path(b, "src/macos_menu.m"), .language = .objective_c });
        menu.linkFramework("AppKit", .{});
        tray.addCSourceFile(.{ .file = tray_source.path(b, "src/macos_tray.m"), .language = .objective_c });
        tray.linkFramework("AppKit", .{});
    }
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
    audit_options.addOption(bool, "vectors", vectors != null);
    probe.root_module.addOptions("desktop-audit-options", audit_options);
    if (icons_module) |icons| probe.root_module.addImport("desktop-icons", icons);
    _ = probe.getEmittedBin();
    step.dependOn(&probe.step);
    return .{ .dvui = dvui, .backend = backend, .fonts = fonts, .ui = editor_ui, .events = events, .folder_dialog = folder_dialog, .tray = native_tray, .icons = icons_module, .vectors = vector_module };
}
