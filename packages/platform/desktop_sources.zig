//! Shared source adaptation for the local DVUI compatibility package.
const std = @import("std");

fn adapt(b: *std.Build, tool: *std.Build.Step.Compile, name: []const u8, acquired: std.Build.LazyPath, override: ?[]const u8) std.Build.LazyPath {
    const source: std.Build.LazyPath = if (override) |path| blk: {
        if (!std.fs.path.isAbsolute(path)) @panic("Desktop source overrides must be absolute");
        break :blk .{ .cwd_relative = path };
    } else acquired;
    const run = b.addRunArtifact(tool);
    run.addFileArg2(.zig_exe, .{ .make_absolute = true });
    run.addArg(name);
    run.addDirectoryArg2(source, .{ .make_absolute = true });
    const output = run.addOutputDirectoryArg2(name, .{ .make_absolute = true });
    if (override == null) run.addArg("--acquired");
    return output;
}

pub fn prepare(b: *std.Build, step: *std.Build.Step, jobs: *std.Build.Module, pins: *std.Build.Module, acquisition: *std.Build.Step.Compile, presenter: *std.Build.Module, lifecycle: *std.Build.Module) ?@import("desktop_build.zig").Graph {
    const tool = b.addExecutable(.{ .name = "desktop-source-adaptation", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/desktop_source_adaptation.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "companion-jobs", .module = jobs }, .{ .name = "desktop-pins", .module = pins } },
    }) });
    const vectors_enabled = b.option(bool, "desktop-vectors", "Enable TinyVG rendering and icons") orelse false;
    const acquire = b.addRunArtifact(acquisition);
    acquire.addFileArg2(.zig_exe, .{ .make_absolute = true });
    const acquired = acquire.addOutputDirectoryArg2("desktop-sources", .{ .make_absolute = true });
    if (vectors_enabled) acquire.addArg("--vector");
    const dvui = adapt(b, tool, "dvui", acquired, b.option([]const u8, "desktop-dvui-source", "Explicit pristine DVUI development source override"));
    const tray = adapt(b, tool, "ztray", acquired, b.option([]const u8, "desktop-ztray-source", "Explicit pristine ztray development source override"));
    var vectors: ?@import("desktop_build.zig").VectorSources = null;
    if (vectors_enabled) vectors = .{
        .svg2tvg = adapt(b, tool, "svg2tvg", acquired, b.option([]const u8, "desktop-svg2tvg-source", "Explicit pristine SVG/TinyVG development source override")),
        .icons = adapt(b, tool, "icons", acquired, b.option([]const u8, "desktop-icons-source", "Explicit pristine icon development source override")),
    };
    return @import("desktop_build.zig").check(b, step, dvui, tray, presenter, lifecycle, vectors);
}
