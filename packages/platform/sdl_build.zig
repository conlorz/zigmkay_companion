//! Build compatibility for the exact pinned SDL 1.0.3+3.4.16 macOS backend.
//! Zig 0.17 rejects unused CMake values. These five names are absent from that
//! release's template. Adjust generated build values, never dependency sources.
const std = @import("std");

pub fn prepare(library: *std.Build.Step.Compile) void {
    if (library.root_module.resolved_target.?.result.os.tag != .macos)
        @panic("Native USB acceptance currently supports only macOS");
    var found = false;
    for (library.root_module.include_dirs.items) |include| {
        if (include == .config_header_step) {
            const header = include.config_header_step;
            if (!std.mem.eql(u8, header.include_path, "SDL_build_config.h")) continue;
            if (found) @panic("Unexpected duplicate SDL build header");
            found = true;
            for ([_][]const u8{ "HAVE_CALLOC", "HAVE_REALLOC", "HAVE_FREE", "HAVE_MPROTECT", "HAVE_SYSCTL" }) |key| {
                const value = header.values.get(key) orelse @panic("Pinned SDL build contract changed");
                if (value != .int or value.int != 1) @panic("Pinned SDL build contract changed");
                _ = header.values.swapRemove(key);
            }
        }
    }
    if (!found) @panic("Pinned SDL build header missing");
}
