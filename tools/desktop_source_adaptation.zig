//! Explicit immutable-source adaptation into an empty caller-owned cache.
//! Never edits dependency inputs. Existing C/Objective-C files remain byte exact.
const std = @import("std");
const jobs = @import("companion-jobs");
const dvui_rules = @import("dvui_adaptation_rules.zig");
pub const Kind = enum { dvui, ztray, svg2tvg, icons };
pub const dvui_hash = "dvui-0.5.0-dev-AQFJmRbtAwHyeIDl5laSSUlHNC1I_TXiwitJOowF6z-n";
pub const ztray_hash = "ztray-0.1.0-dev.1-HZHL7Ia4BwBeGve2XpCeCR0cQ_5xTdupgMzOyceJ6BeY";
const inputs = @import("desktop_dependency_pins.zig");
pub fn adaptTinyvg(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !?[]u8 {
    const rules = [_]dvui_rules.Rule{
        .{ .path = "src/tinyvg/parsing.zig", .before = "std.meta.fields(T).len", .after = "@typeInfo(T).@\"struct\".field_names.len", .count = 1 },
        .{ .path = "src/tinyvg/parsing.zig", .before = "std.meta.Int(.unsigned, info.bits + 1)", .after = "@Int(.unsigned, info.bits + 1)", .count = 1 },
        .{ .path = "src/svg-vancluever.zig", .before = "var buf = [_:0]u8{0} ** 256;", .after = "var buf: [256:0]u8 = @splat(0);", .count = 1 },
    };
    var result: ?[]u8 = null;
    errdefer if (result) |owned| gpa.free(owned);
    for (rules) |rule| {
        if (!std.mem.eql(u8, path, rule.path)) continue;
        if (std.mem.count(u8, bytes, rule.before) != rule.count) return error.TinyvgAdaptationInputMismatch;
        const next = try std.mem.replaceOwned(u8, gpa, result orelse bytes, rule.before, rule.after);
        if (result) |owned| gpa.free(owned);
        result = next;
    }
    return result;
}
const Rules = struct {
    const replacements = [_][]const u8{ "[_]WCHAR{0} ** 256", "[_]WCHAR{0} ** 64", "[_]WCHAR{0} ** 128", "[_]u8{0} ** 16" };
    const sentinel_arguments = [_][]const u8{ "tooltip", "p", "action.title", "n", "\"\"", "menu.title", "a.title" };
    const ztray_sentinel_counts = [7]u8{ 2, 1, 1, 1, 2, 1, 1 };
    const macos_sentinel_counts = [7]u8{ 1, 1, 1, 0, 0, 1, 0 };
};
const Manifest = struct {
    version: u16 = 2,
    dependency: Kind,
    original_revision: []const u8,
    original_package_hash: []const u8,
    original_source_tree_digest: [32]u8,
    adapted_source_tree_digest: [32]u8,
    compiler_version: []const u8 = "0.17.0",
    adaptation_contract: []const u8 = "zigmkay-desktop-source-adaptation-v2",
    ztray_replacement_counts: [4]u8,
    windows_replacement_counts: [4]u8,
    ztray_sentinel_counts: [7]u8,
    macos_sentinel_counts: [7]u8,
    dvui_rules_version: u16,
    dvui_replacement_count: u16,
    dvui_modified_files: usize,
    imported_native_sources_preserved: bool = true,
    tinyvg_rules_version: u16 = 0,
    tinyvg_modified_files: usize = 0,
};
fn excluded(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
    if (kind != .directory) return false;
    for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" }) |ignored| if (std.mem.eql(u8, name, ignored)) return true;
    return false;
}
fn absolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsolutePathRequired;
}
fn nested(child: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, child, parent) or (std.mem.startsWith(u8, child, parent) and child.len > parent.len and std.fs.path.isSep(child[parent.len]));
}
pub fn adapt(gpa: std.mem.Allocator, bytes: []const u8, counts: *[4]u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var position: usize = 0;
    counts.* = @splat(0);
    while (position < bytes.len) {
        var matched = false;
        for (Rules.replacements, 0..) |old, index| {
            if (std.mem.startsWith(u8, bytes[position..], old)) {
                if (counts[index] != 0) return error.UnexpectedReplacementCount;
                counts[index] += 1;
                try result.appendSlice(gpa, "@splat(0)");
                position += old.len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try result.append(gpa, bytes[position]);
            position += 1;
        }
    }
    for (counts.*) |count| if (count != 1) return error.UnexpectedReplacementCount;
    return result.toOwnedSlice(gpa);
}
pub fn adaptSentinels(gpa: std.mem.Allocator, bytes: []const u8, expected: [7]u8, counts: *[7]u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var position: usize = 0;
    counts.* = @splat(0);
    while (position < bytes.len) {
        var matched = false;
        inline for (Rules.sentinel_arguments, 0..) |argument, index| {
            const old = "allocator.dupeZ(u8, " ++ argument ++ ")";
            if (!matched and std.mem.startsWith(u8, bytes[position..], old)) {
                if (counts[index] == expected[index]) return error.UnexpectedSentinelReplacementCount;
                counts[index] += 1;
                try result.appendSlice(gpa, "allocator.dupeSentinel(u8, " ++ argument ++ ", 0)");
                position += old.len;
                matched = true;
            }
        }
        if (!matched) {
            try result.append(gpa, bytes[position]);
            position += 1;
        }
    }
    if (!std.mem.eql(u8, counts, &expected)) return error.UnexpectedSentinelReplacementCount;
    return result.toOwnedSlice(gpa);
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 5) return error.Usage;
    try absolute(args[1]);
    try absolute(args[3]);
    try absolute(args[4]);
    const kind: Kind = std.meta.stringToEnum(Kind, args[2]) orelse return error.InvalidDependencyKind;
    const expected = switch (kind) {
        .dvui => dvui_hash,
        .ztray => ztray_hash,
        .svg2tvg => inputs.svg2tvg_hash,
        .icons => inputs.icons_hash,
    };
    const source_real = try std.Io.Dir.cwd().realPathFileAlloc(io, args[3], gpa);
    defer gpa.free(source_real);
    const output_normal = try std.fs.path.resolve(gpa, &.{args[4]});
    defer gpa.free(output_normal);
    if (nested(output_normal, source_real) or nested(source_real, output_normal)) return error.OverlappingSourceAndOutput;
    var version = try jobs.run(gpa, io, .{ .argv = &.{ args[1], "version" }, .cwd = source_real, .snapshot_id = @splat(0), .timeout_ms = 5000 });
    defer version.deinit(gpa);
    if (!version.successful() or !std.mem.eql(u8, std.mem.trim(u8, version.process.stdout, "\r\n"), "0.17.0")) return error.UnsupportedCompilerVersion;
    // fetch of an existing absolute directory computes the Zig package hash;
    // it does not execute that package's build script or fetch its dependencies.
    var fetched = try jobs.run(gpa, io, .{ .argv = &.{ args[1], "fetch", source_real }, .cwd = source_real, .snapshot_id = @splat(0), .timeout_ms = 60_000 });
    defer fetched.deinit(gpa);
    if (!fetched.successful() or !std.mem.eql(u8, std.mem.trim(u8, fetched.process.stdout, "\r\n"), expected)) return error.DependencyPackageHashMismatch;
    var source = try std.Io.Dir.cwd().openDir(io, source_real, .{ .iterate = true });
    defer source.close(io);
    const source_digest = try jobs.preparation.treeDigest(gpa, io, source);
    const files = try jobs.source_files.collect(gpa, io, source, .{ .excluded = excluded, .max_files = 10_000 });
    defer jobs.source_files.free(gpa, files);
    try std.Io.Dir.cwd().createDirPath(io, output_normal);
    var output = try std.Io.Dir.cwd().openDir(io, output_normal, .{ .iterate = true });
    defer output.close(io);
    const output_real = try output.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(output_real);
    if (nested(output_real, source_real) or nested(source_real, output_real)) return error.OverlappingSourceAndOutput;
    var iterator = output.iterate();
    if (try iterator.next(io) != null) return error.OutputDirectoryNotEmpty;
    var ztray_counts: [4]u8 = @splat(0);
    var windows_counts: [4]u8 = @splat(0);
    var ztray_sentinel_counts: [7]u8 = @splat(0);
    var macos_sentinel_counts: [7]u8 = @splat(0);
    var modified: usize = 0;
    var dvui_modified: usize = 0;
    var tinyvg_modified: usize = 0;
    for (files) |file| {
        if (file.kind != .file) return error.UnsupportedSourceKind;
        const original = try source.readFileAlloc(io, file.path, gpa, .limited(32 * 1024 * 1024));
        defer gpa.free(original);
        const counts: ?*[4]u8 = if (kind == .ztray and std.mem.eql(u8, file.path, "src/ztray.zig")) &ztray_counts else if (kind == .ztray and std.mem.eql(u8, file.path, "src/windows.zig")) &windows_counts else null;
        const is_macos = kind == .ztray and std.mem.eql(u8, file.path, "src/macos.zig");
        const dvui_adapted = if (kind == .dvui) try dvui_rules.adapt(gpa, file.path, original) else null;
        const tinyvg_adapted = if (kind == .svg2tvg) try adaptTinyvg(gpa, file.path, original) else null;
        const bytes = if (counts) |count| blk: {
            modified += 1;
            const repeated = try adapt(gpa, original, count);
            if (count == &ztray_counts) {
                defer gpa.free(repeated);
                break :blk try adaptSentinels(gpa, repeated, Rules.ztray_sentinel_counts, &ztray_sentinel_counts);
            }
            break :blk repeated;
        } else if (is_macos) blk: {
            modified += 1;
            break :blk try adaptSentinels(gpa, original, Rules.macos_sentinel_counts, &macos_sentinel_counts);
        } else if (dvui_adapted) |adapted| blk: {
            dvui_modified += 1;
            break :blk adapted;
        } else if (tinyvg_adapted) |adapted| blk: {
            tinyvg_modified += 1;
            break :blk adapted;
        } else original;
        defer if (counts != null or is_macos or dvui_adapted != null or tinyvg_adapted != null) gpa.free(bytes);
        if (std.fs.path.dirname(file.path)) |parent| try output.createDirPath(io, parent);
        var atomic = try output.createFileAtomic(io, file.path, .{ .replace = false });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.replace(io);
        const written = try output.readFileAlloc(io, file.path, gpa, .limited(32 * 1024 * 1024));
        defer gpa.free(written);
        if (!std.mem.eql(u8, bytes, written)) return error.AdaptedCopyMismatch;
    }
    if (kind == .ztray and modified != 3) return error.MissingAdaptationSource;
    if (kind == .svg2tvg and tinyvg_modified != 2) return error.MissingAdaptationSource;
    if (kind == .dvui) {
        var expected_files: usize = 0;
        for (dvui_rules.rules, 0..) |rule, index| {
            var duplicate = false;
            for (dvui_rules.rules[0..index]) |old| if (std.mem.eql(u8, rule.path, old.path)) {
                duplicate = true;
                break;
            };
            if (!duplicate) expected_files += 1;
        }
        if (dvui_modified != expected_files) return error.MissingAdaptationSource;
    }
    if (!std.mem.eql(u8, &source_digest, &try jobs.preparation.treeDigest(gpa, io, source))) return error.SourceChangedDuringAdaptation;
    const manifest: Manifest = .{ .dependency = kind, .original_revision = switch (kind) {
        .dvui => inputs.dvui_revision,
        .ztray => inputs.ztray_revision,
        .svg2tvg => inputs.svg2tvg_revision,
        .icons => inputs.icons_revision,
    }, .original_package_hash = expected, .original_source_tree_digest = source_digest, .adapted_source_tree_digest = try jobs.preparation.treeDigest(gpa, io, output), .ztray_replacement_counts = ztray_counts, .windows_replacement_counts = windows_counts, .ztray_sentinel_counts = ztray_sentinel_counts, .macos_sentinel_counts = macos_sentinel_counts, .dvui_rules_version = if (kind == .dvui) dvui_rules.version else 0, .dvui_replacement_count = if (kind == .dvui) dvui_rules.expected_replacements else 0, .dvui_modified_files = dvui_modified, .tinyvg_rules_version = if (kind == .svg2tvg) 1 else 0, .tinyvg_modified_files = tinyvg_modified };
    // Output digest describes copied sources before this receipt is added.
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(manifest, .{}, &encoded.writer, 8);
    var atomic = try output.createFileAtomic(io, "adaptation-manifest.zon", .{ .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded.written());
    try atomic.replace(io);
}
test "exact adaptation changes only the four known literals and rejects drift" {
    const gpa = std.testing.allocator;
    const original = "A [_]WCHAR{0} ** 256 B [_]WCHAR{0} ** 64 C [_]WCHAR{0} ** 128 D [_]u8{0} ** 16 E";
    var counts: [4]u8 = undefined;
    const result = try adapt(gpa, original, &counts);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("A @splat(0) B @splat(0) C @splat(0) D @splat(0) E", result);
    try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, counts);
    try std.testing.expectError(error.UnexpectedReplacementCount, adapt(gpa, "changed source", &counts));
}

test "sentinel adaptation preserves expressions and rejects unexpected counts" {
    const gpa = std.testing.allocator;
    var counts: [7]u8 = undefined;
    const result = try adaptSentinels(gpa, "before allocator.dupeZ(u8, tooltip) after allocator.dupeZ(u8, p)", .{ 1, 1, 0, 0, 0, 0, 0 }, &counts);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("before allocator.dupeSentinel(u8, tooltip, 0) after allocator.dupeSentinel(u8, p, 0)", result);
    try std.testing.expectError(error.UnexpectedSentinelReplacementCount, adaptSentinels(gpa, "allocator.dupeZ(u8, tooltip)", @splat(0), &counts));
}
test "TinyVG field-count adaptation is exact and rejects drift" {
    const result = (try adaptTinyvg(std.testing.allocator, "src/tinyvg/parsing.zig", "if (fields.len != std.meta.fields(T).len) {} std.meta.Int(.unsigned, info.bits + 1)")).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("if (fields.len != @typeInfo(T).@\"struct\".field_names.len) {} @Int(.unsigned, info.bits + 1)", result);
    try std.testing.expectError(error.TinyvgAdaptationInputMismatch, adaptTinyvg(std.testing.allocator, "src/tinyvg/parsing.zig", "different"));
    try std.testing.expect(try adaptTinyvg(std.testing.allocator, "unrelated.zig", "different") == null);
}
