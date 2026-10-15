//! Compatibility package for the application's retained DVUI desktop sources.
//! Export source pins without importing incompatible upstream build scripts.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const sources = @import("sources.zon");
    const pins = b.addOptions();
    inline for (.{ "dvui", "ztray", "svg2tvg", "icons" }) |name| {
        const source = @field(sources, name);
        pins.addOption([]const u8, name ++ "_url", source.url);
        pins.addOption([]const u8, name ++ "_hash", source.hash);
        pins.addOption([]const u8, name ++ "_revision", source.url[std.mem.lastIndexOfScalar(u8, source.url, '#').? + 1 ..]);
    }
    _ = b.addModule("pins", .{ .root_source_file = pins.getOutput() });
}
