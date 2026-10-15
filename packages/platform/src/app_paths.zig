//! Pure installed-resource and user-storage policy. Callers inject environment
//! and installation paths; this module never queries the OS or touches files.
const std = @import("std");
pub const Platform = enum { macos, windows, linux };
pub const Environment = struct {
    home: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
    localappdata: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
};
pub const Options = struct {
    platform: Platform,
    env: Environment,
    executable_path: []const u8,
    /// Packaging supplies this for layouts other than adjacent resources or a
    /// macOS Contents/MacOS executable with Contents/Resources assets.
    resource_root: ?[]const u8 = null,
    /// Optional package prefix. Otherwise the executable directory (or .app
    /// bundle root) is protected from writable storage paths.
    installation_root: ?[]const u8 = null,
    app_name: []const u8 = "zigmkay",
};
pub const Paths = struct {
    installation_root: []const u8,
    resources: []const u8,
    config: []const u8,
    data: []const u8,
    cache: []const u8,
    projects: []const u8,
    logs: []const u8,
    rollback: []const u8,
    builds: []const u8,
    startup_preference: []const u8,
    profile_preferences: []const u8,
    legacy_profile_preferences: []const u8,
};
pub const OwnedPaths = struct {
    arena: std.heap.ArenaAllocator,
    paths: Paths,
    pub fn deinit(self: *OwnedPaths) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn separator(platform: Platform, char: u8) bool {
    return char == '/' or (platform == .windows and char == '\\');
}
fn validateWindowsSegment(part: []const u8) !void {
    if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.InvalidAssetPath;
    for (part) |char| if (char < 32 or std.mem.indexOfScalar(u8, "<>\"|?*", char) != null) return error.InvalidAssetPath;
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.InvalidAssetPath;
    if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) and stem[3] >= '1' and stem[3] <= '9') return error.InvalidAssetPath;
}
pub fn validateAbsolute(platform: Platform, path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (platform == .windows) {
        const kind = std.fs.path.parsePathWindows(u8, path).kind;
        if (kind != .drive_absolute and kind != .unc_absolute) return error.InvalidPath;
        if (kind == .unc_absolute) {
            var components = std.mem.tokenizeAny(u8, path[2..], "/\\");
            _ = components.next() orelse return error.InvalidPath;
            _ = components.next() orelse return error.InvalidPath;
        }
    } else if (!std.fs.path.isAbsolutePosix(path)) return error.InvalidPath;
}
fn normalize(a: std.mem.Allocator, platform: Platform, parts: []const []const u8) ![]u8 {
    return if (platform == .windows) std.fs.path.resolveAllocWindows(a, parts) else std.fs.path.resolveAllocPosix(a, parts);
}
fn required(platform: Platform, value: ?[]const u8) ![]const u8 {
    const path = value orelse return error.MissingUserDirectory;
    try validateAbsolute(platform, path);
    return path;
}
fn xdg(a: std.mem.Allocator, env: Environment, value: ?[]const u8, fallback: []const u8, app: []const u8) ![]u8 {
    if (value) |path| if (path.len != 0) {
        try validateAbsolute(.linux, path);
        return normalize(a, .linux, &.{ path, app });
    };
    return normalize(a, .linux, &.{ try required(.linux, env.home), fallback, app });
}
fn inside(platform: Platform, child: []const u8, parent: []const u8) bool {
    if (child.len < parent.len) return false;
    const equal = if (platform == .windows) std.ascii.eqlIgnoreCase(child[0..parent.len], parent) else std.mem.eql(u8, child[0..parent.len], parent);
    return equal and (child.len == parent.len or separator(platform, parent[parent.len - 1]) or separator(platform, child[parent.len]));
}

pub fn resolve(gpa: std.mem.Allocator, options: Options) !OwnedPaths {
    if (options.app_name.len == 0) return error.InvalidAppName;
    for (options.app_name) |char| if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-')) return error.InvalidAppName;
    if (options.platform == .windows) validateWindowsSegment(options.app_name) catch return error.InvalidAppName;
    try validateAbsolute(options.platform, options.executable_path);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const platform = options.platform;
    const executable = try normalize(a, platform, &.{options.executable_path});
    const exe_dir = (if (platform == .windows) std.fs.path.dirnameWindows(executable) else std.fs.path.dirnamePosix(executable)) orelse return error.InvalidPath;
    const resources = if (options.resource_root) |root| blk: {
        try validateAbsolute(platform, root);
        break :blk try normalize(a, platform, &.{root});
    } else if (platform == .macos and std.mem.endsWith(u8, exe_dir, "/Contents/MacOS"))
        try normalize(a, platform, &.{ exe_dir, "../Resources" })
    else
        try normalize(a, platform, &.{ exe_dir, "resources" });
    const installation_root = if (options.installation_root) |root| blk: {
        try validateAbsolute(platform, root);
        const prefix = try normalize(a, platform, &.{root});
        if (!inside(platform, executable, prefix) or !inside(platform, resources, prefix)) return error.InvalidInstallationRoot;
        break :blk prefix;
    } else if (platform == .macos and std.mem.endsWith(u8, exe_dir, "/Contents/MacOS"))
        try normalize(a, platform, &.{ exe_dir, "../.." })
    else
        try a.dupe(u8, exe_dir);
    var config: []const u8 = undefined;
    var data: []const u8 = undefined;
    var cache: []const u8 = undefined;
    switch (platform) {
        .macos => {
            const home = try required(platform, options.env.home);
            config = try normalize(a, platform, &.{ home, "Library/Application Support", options.app_name, "preferences" });
            data = try normalize(a, platform, &.{ home, "Library/Application Support", options.app_name, "data" });
            cache = try normalize(a, platform, &.{ home, "Library/Caches", options.app_name });
        },
        .windows => {
            config = try normalize(a, platform, &.{ try required(platform, options.env.appdata), options.app_name, "preferences" });
            const local = try required(platform, options.env.localappdata);
            data = try normalize(a, platform, &.{ local, options.app_name, "data" });
            cache = try normalize(a, platform, &.{ local, options.app_name, "cache" });
        },
        .linux => {
            config = try xdg(a, options.env, options.env.xdg_config_home, ".config", options.app_name);
            data = try xdg(a, options.env, options.env.xdg_data_home, ".local/share", options.app_name);
            cache = try xdg(a, options.env, options.env.xdg_cache_home, ".cache", options.app_name);
        },
    }
    const writable = [_][]const u8{ config, data, cache };
    for (writable, 0..) |path, i| {
        if (inside(platform, path, resources) or inside(platform, resources, path) or inside(platform, path, installation_root) or inside(platform, installation_root, path)) return error.StorageOverlap;
        for (writable[0..i]) |earlier| if (inside(platform, path, earlier) or inside(platform, earlier, path)) return error.StorageOverlap;
    }
    return .{ .arena = arena, .paths = .{
        .installation_root = installation_root,
        .resources = resources,
        .config = config,
        .data = data,
        .cache = cache,
        .projects = try normalize(a, platform, &.{ data, "projects" }),
        .logs = try normalize(a, platform, &.{ data, "logs" }),
        .rollback = try normalize(a, platform, &.{ data, "verified-rollback" }),
        .builds = try normalize(a, platform, &.{ cache, "builds" }),
        .startup_preference = try normalize(a, platform, &.{ config, "startup-project.zon" }),
        .profile_preferences = try normalize(a, platform, &.{ config, "profile-projects-v1.zon" }),
        .legacy_profile_preferences = try normalize(a, platform, &.{ config, "profile-projects.zon" }),
    } };
}

pub const Asset = struct { relative_path: []const u8, bytes: []const u8 };
pub const MigrationEntry = struct {
    source: []const u8,
    destination: []const u8,
    bytes: []const u8,
    digest: [32]u8,
};
/// A proposal only. An eventual explicit executor must retain originals, reject
/// differing destinations and recheck source/destination digests. These bytes
/// are never parsed, normalized, compiled or rewritten as part of migration.
pub const MigrationReceipt = struct {
    version: u16 = 1,
    entries: []const MigrationEntry,
    preserve_originals: bool = true,
    destination_policy: enum { absent_or_identical } = .absent_or_identical,
};
pub const OwnedMigration = struct {
    arena: std.heap.ArenaAllocator,
    receipt: MigrationReceipt,
    pub fn deinit(self: *OwnedMigration) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn proposeMigration(gpa: std.mem.Allocator, platform: Platform, old_directory: []const u8, destination_directory: []const u8, assets: []const Asset) !OwnedMigration {
    try validateAbsolute(platform, old_directory);
    try validateAbsolute(platform, destination_directory);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const old = try normalize(a, platform, &.{old_directory});
    const destination = try normalize(a, platform, &.{destination_directory});
    if (inside(platform, old, destination) or inside(platform, destination, old)) return error.StorageOverlap;
    const entries = try a.alloc(MigrationEntry, assets.len);
    for (assets, entries, 0..) |asset, *entry, index| {
        if (asset.relative_path.len == 0 or std.mem.indexOfScalar(u8, asset.relative_path, 0) != null or separator(platform, asset.relative_path[0])) return error.InvalidAssetPath;
        if (std.mem.indexOfScalar(u8, asset.relative_path, ':') != null or std.mem.indexOfScalar(u8, asset.relative_path, '\\') != null) return error.InvalidAssetPath;
        var parts = std.mem.splitScalar(u8, asset.relative_path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidAssetPath;
            if (platform == .windows) try validateWindowsSegment(part);
        }
        const source = try normalize(a, platform, &.{ old, asset.relative_path });
        const target = try normalize(a, platform, &.{ destination, asset.relative_path });
        for (entries[0..index]) |earlier| {
            if (inside(platform, earlier.destination, target) or inside(platform, target, earlier.destination)) return error.DuplicateAsset;
        }
        entry.* = .{ .source = source, .destination = target, .bytes = try a.dupe(u8, asset.bytes), .digest = undefined };
        std.crypto.hash.sha2.Sha256.hash(entry.bytes, &entry.digest, .{});
    }
    return .{ .arena = arena, .receipt = .{ .entries = entries } };
}

test "installed paths are independent of working directories on all platforms" {
    var mac = try resolve(std.testing.allocator, .{ .platform = .macos, .env = .{ .home = "/Users/Jane Doe" }, .executable_path = "/Applications/Zigmkay.app/Contents/MacOS/zigmkay" });
    defer mac.deinit();
    try std.testing.expectEqualStrings("/Applications/Zigmkay.app/Contents/Resources", mac.paths.resources);
    try std.testing.expectEqualStrings("/Applications/Zigmkay.app", mac.paths.installation_root);
    try std.testing.expectEqualStrings("/Users/Jane Doe/Library/Application Support/zigmkay/data/projects", mac.paths.projects);
    try std.testing.expectEqualStrings("/Users/Jane Doe/Library/Caches/zigmkay/builds", mac.paths.builds);
    var windows = try resolve(std.testing.allocator, .{ .platform = .windows, .env = .{ .appdata = "C:\\Users\\Zoë\\AppData\\Roaming", .localappdata = "C:\\Users\\Zoë\\AppData\\Local" }, .executable_path = "C:\\Program Files\\Zigmkay\\zigmkay.exe" });
    defer windows.deinit();
    try std.testing.expectEqualStrings("C:\\Program Files\\Zigmkay\\resources", windows.paths.resources);
    try std.testing.expectEqualStrings("C:\\Users\\Zoë\\AppData\\Roaming\\zigmkay\\preferences\\startup-project.zon", windows.paths.startup_preference);
    var linux = try resolve(std.testing.allocator, .{ .platform = .linux, .env = .{ .home = "/home/zoë" }, .executable_path = "/usr/bin/zigmkay", .resource_root = "/usr/share/zigmkay" });
    defer linux.deinit();
    try std.testing.expectEqualStrings("/home/zoë/.local/share/zigmkay/projects", linux.paths.projects);
    try std.testing.expectEqualStrings("/home/zoë/.config/zigmkay/profile-projects-v1.zon", linux.paths.profile_preferences);
    try std.testing.expectEqualStrings("/home/zoë/.config/zigmkay/profile-projects.zon", linux.paths.legacy_profile_preferences);
    try std.testing.expectEqualStrings("/usr/share/zigmkay", linux.paths.resources);
}

test "Windows relocated smoke test separates installation from user storage" {
    const env: Environment = .{
        .home = "C:\\temp\\Zigmkay offline ü\\home",
        .appdata = "C:\\temp\\Zigmkay offline ü\\config",
        .localappdata = "C:\\temp\\Zigmkay offline ü\\cache",
    };
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{
        .platform = .windows,
        .env = env,
        .executable_path = "C:\\temp\\Zigmkay offline ü\\Zigmkay.exe",
    }));
    var paths = try resolve(std.testing.allocator, .{
        .platform = .windows,
        .env = env,
        .executable_path = "C:\\temp\\Zigmkay offline ü\\install\\Zigmkay.exe",
    });
    defer paths.deinit();
    try std.testing.expectEqualStrings("C:\\temp\\Zigmkay offline ü\\install", paths.paths.installation_root);
    try std.testing.expectEqualStrings("C:\\temp\\Zigmkay offline ü\\cache\\zigmkay\\cache", paths.paths.cache);
}

test "XDG values and UNC user directories are injected and validated" {
    var linux = try resolve(std.testing.allocator, .{ .platform = .linux, .env = .{ .xdg_config_home = "/settings", .xdg_data_home = "/personal", .xdg_cache_home = "/scratch" }, .executable_path = "/opt/zigmkay/zigmkay" });
    defer linux.deinit();
    try std.testing.expectEqualStrings("/personal/zigmkay", linux.paths.data);
    try validateAbsolute(.windows, "\\\\server\\share\\profiles");
    for ([_][]const u8{ "C:relative", "\\rooted", "relative", "\\\\server", "C:\\bad\x00path" }) |bad| try std.testing.expectError(error.InvalidPath, validateAbsolute(.windows, bad));
    try std.testing.expectError(error.InvalidPath, resolve(std.testing.allocator, .{ .platform = .linux, .env = .{ .home = "/home/test", .xdg_data_home = "relative" }, .executable_path = "/opt/app" }));
    try std.testing.expectError(error.MissingUserDirectory, resolve(std.testing.allocator, .{ .platform = .macos, .env = .{}, .executable_path = "/Applications/app" }));
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{ .platform = .macos, .env = .{ .home = "/user" }, .executable_path = "/Applications/app", .resource_root = "/user/Library/Application Support/zigmkay/data" }));
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{ .platform = .macos, .env = .{ .home = "/Applications/Zigmkay.app" }, .executable_path = "/Applications/Zigmkay.app/Contents/MacOS/app" }));
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{ .platform = .linux, .env = .{ .xdg_config_home = "/settings", .xdg_data_home = "/settings", .xdg_cache_home = "/scratch" }, .executable_path = "/opt/app" }));
}

test "migration receipt preserves exact project and source bytes and never overwrites" {
    var bytes = [_]u8{ 0, '\n', 255, '\r', 0 };
    var proposal = try proposeMigration(std.testing.allocator, .linux, "/old/repo/projects/personal", "/home/user/projects/personal", &.{ .{ .relative_path = "project.zon", .bytes = "old project bytes\r\n" }, .{ .relative_path = "sources/original.zig", .bytes = &bytes } });
    defer proposal.deinit();
    bytes[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 0, '\n', 255, '\r', 0 }, proposal.receipt.entries[1].bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(proposal.receipt.entries[1].bytes, &digest, .{});
    try std.testing.expectEqual(digest, proposal.receipt.entries[1].digest);
    try std.testing.expect(proposal.receipt.preserve_originals);
    try std.testing.expectEqual(.absent_or_identical, proposal.receipt.destination_policy);
    try std.testing.expectEqualStrings("/old/repo/projects/personal/sources/original.zig", proposal.receipt.entries[1].source);
    try std.testing.expectError(error.InvalidAssetPath, proposeMigration(std.testing.allocator, .linux, "/old", "/new", &.{.{ .relative_path = "../escape", .bytes = "" }}));
    try std.testing.expectError(error.DuplicateAsset, proposeMigration(std.testing.allocator, .windows, "C:\\old", "C:\\new", &.{ .{ .relative_path = "project.zon", .bytes = "a" }, .{ .relative_path = "PROJECT.zon", .bytes = "a" } }));
    for ([_][]const u8{ "sources/CON.zig", "sources/filename. ", "sources/lpt1", "sources/file:stream" }) |bad|
        try std.testing.expectError(error.InvalidAssetPath, proposeMigration(std.testing.allocator, .windows, "C:\\old", "C:\\new", &.{.{ .relative_path = bad, .bytes = "" }}));
}
