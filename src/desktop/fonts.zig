//! macOS system fonts are read locally, never copied into the repo or bundled.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const sans = "Editor Sans";
/// Fallback for code points the system UI font cannot render.
const unicode = "Editor Unicode";

pub fn install(gpa: std.mem.Allocator, io: std.Io) !void {
    if (builtin.os.tag != .macos) return;
    const sources = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = sans, .path = "/System/Library/Fonts/SFNS.ttf" },
        .{ .name = unicode, .path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" },
    };
    for (sources) |source| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, source.path, gpa, .limited(32 * 1024 * 1024)) catch continue;
        dvui.currentWindow().addFont(source.name, bytes, gpa) catch {
            gpa.free(bytes);
            continue;
        };
    }
}

fn available(name: []const u8) bool {
    for (dvui.currentWindow().fonts.database.items) |source| {
        if (std.mem.eql(u8, std.mem.sliceTo(&source.family, 0), name)) return true;
    }
    return false;
}

/// The editor font at `size`, switching to the Unicode fallback when `text`
/// contains a code point the primary font lacks.
pub fn font(text: []const u8, size: f32) dvui.Font {
    var selected = dvui.Font.find(.{ .family = if (available(sans)) sans else "Vera Sans", .size = size * 0.76 });
    if (builtin.os.tag == .macos and available(unicode)) {
        const entry = dvui.fontCacheGet(selected) catch return selected;
        var iterator = (std.unicode.Utf8View.init(text) catch return selected).iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (dvui.c.FT_Get_Char_Index(entry.face, codepoint) == 0) {
                selected = selected.withFamily(unicode);
                break;
            }
        }
    }
    return selected;
}
