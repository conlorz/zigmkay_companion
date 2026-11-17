//! macOS system fonts are read locally, never copied into the repo or bundled.
const std = @import("std");
const dvui = @import("dvui");
pub fn install(gpa: std.mem.Allocator, io: std.Io) !void {
    if (@import("builtin").os.tag != .macos) return;
    for ([_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "Editor Sans", .path = "/System/Library/Fonts/SFNS.ttf" },
        .{ .name = "Editor Unicode", .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    }) |source| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, source.path, gpa, .limited(32 * 1024 * 1024)) catch continue;
        dvui.currentWindow().addFont(source.name, bytes, gpa) catch {
            gpa.free(bytes);
            continue;
        };
    }
}
fn available(name: []const u8) bool {
    for (dvui.currentWindow().fonts.database.items) |source| if (std.mem.eql(u8, std.mem.sliceTo(&source.family, 0), name)) return true;
    return false;
}
pub fn font(text: []const u8, size: f32) dvui.Font {
    var selected = dvui.Font.find(.{ .family = if (available("Editor Sans")) "Editor Sans" else "Vera Sans", .size = size * 0.76 });
    if (@import("builtin").os.tag == .macos and available("Editor Unicode")) {
        const entry = dvui.fontCacheGet(selected) catch return selected;
        var iterator = (std.unicode.Utf8View.init(text) catch return selected).iterator();
        while (iterator.nextCodepoint()) |codepoint| if (dvui.c.FT_Get_Char_Index(entry.face, codepoint) == 0) {
            selected = selected.withFamily("Editor Unicode");
            break;
        };
    }
    return selected;
}
