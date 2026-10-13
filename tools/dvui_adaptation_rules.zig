//! Counted Zig 0.17 reflection adaptation for the retained immutable DVUI source.
const std = @import("std");
pub const version: u16 = 7;
pub const Rule = struct { path: []const u8, before: []const u8, after: []const u8, count: usize };
pub const rules = [_]Rule{
    .{ .path = "src/Backend.zig", .before = "info.params.len", .after = "info.param_types.len", .count = 1 },
    .{ .path = "src/Backend.zig", .before = "info.params[0].type", .after = "info.param_types[0]", .count = 1 },
    .{ .path = "src/Backend.zig", .before = "info.params[1].type", .after = "info.param_types[1]", .count = 1 },
    .{ .path = "src/render_tvg.zig", .before = "std.meta.Int(.unsigned, f.bits)", .after = "@Int(.unsigned, f.bits)", .count = 1 },
    .{ .path = "src/render_tvg.zig", .before = "inline for (s.fields) |field| hashValue(h, @field(v, field.name))", .after = "inline for (s.field_names) |field_name| hashValue(h, @field(v, field_name))", .count = 1 },
    .{ .path = "src/render_tvg.zig", .before = "inline for (u.fields) |field| {", .after = "inline for (u.field_names, u.field_types) |field_name, field_type| {\n                const field = .{ .name = field_name, .type = field_type };", .count = 1 },
    .{ .path = "src/struct_ui.zig", .before = "@typeInfo(T).@\"enum\".is_exhaustive", .after = "(@typeInfo(T).@\"enum\".mode == .exhaustive)", .count = 1 },
    .{ .path = "src/struct_ui.zig", .before = "inline for (si.fields) |field| {\n                    if (field.defaultValue() == null) {", .after = "inline for (si.field_attrs) |field_attrs| {\n                    if (field_attrs.default_value_ptr == null) {", .count = 1 },
    .{ .path = "src/struct_ui.zig", .before = "@enumFromInt(e.fields[0].value)", .after = "@enumFromInt(e.field_values[0])", .count = 1 },
    .{ .path = "src/struct_ui.zig", .before = "                .enum_literal,\n                => {}, // These types are not displayed", .after = "                .enum_literal,\n                .spirv,\n                => {}, // These types are not displayed", .count = 1 },
    .{ .path = "src/Data.zig", .before = "st.pointer.alignment orelse @alignOf(T)", .after = "st.pointer.attrs.@\"align\" orelse @alignOf(T)", .count = 1 },
    .{ .path = "src/Debug.zig", .before = "inline for (struct_info.fields) |field| blk: {", .after = "inline for (struct_info.field_names, struct_info.field_types, struct_info.field_attrs) |field_name, field_type, field_attrs| blk: {\n                        const field = .{ .name = field_name, .type = field_type, .attrs = field_attrs };", .count = 1 },
    .{ .path = "src/Debug.zig", .before = "field.defaultValue()", .after = "field.attrs.defaultValue(field.type)", .count = 1 },
    .{ .path = "src/Options.zig", .before = "inline for (@typeInfo(Options).@\"struct\".fields) |f| {", .after = "inline for (@typeInfo(Options).@\"struct\".field_names) |field_name| {\n        const f = .{ .name = field_name };", .count = 1 },
    .{ .path = "src/dvui.zig", .before = "inline for (@typeInfo(@TypeOf(user_struct)).@\"struct\".fields) |f| {", .after = "inline for (@typeInfo(@TypeOf(user_struct)).@\"struct\".field_names) |field_name| {\n        const f = .{ .name = field_name, .type = @FieldType(@TypeOf(user_struct), field_name) };", .count = 1 },
    .{ .path = "src/dvui.zig", .before = "inline for (@typeInfo(T).@\"enum\".fields) |e| {", .after = "inline for (@typeInfo(T).@\"enum\".field_names) |field_name| {\n            const e = .{ .name = field_name };", .count = 1 },
    .{ .path = "src/struct_ui.zig", .before = ".pointer.is_const", .after = ".pointer.attrs.@\"const\"", .count = 15 },
    .{ .path = "src/struct_ui.zig", .before = "ptr.is_const", .after = "ptr.attrs.@\"const\"", .count = 1 },
    .{ .path = "src/backends/sdl.zig", .before = "@typeInfo(dvui.enums.Cursor).@\"enum\".fields.len", .after = "@typeInfo(dvui.enums.Cursor).@\"enum\".field_names.len", .count = 1 },
    .{ .path = "src/backends/sdl3gpu.zig", .before = "@typeInfo(dvui.enums.Cursor).@\"enum\".fields.len", .after = "@typeInfo(dvui.enums.Cursor).@\"enum\".field_names.len", .count = 1 },
    .{ .path = "src/Examples.zig", .before = "@typeInfo(demoKind).@\"enum\".fields.len", .after = "@typeInfo(demoKind).@\"enum\".field_names.len", .count = 2 },
    .{ .path = "src/Examples.zig", .before = "@typeInfo(@This()).@\"enum\".fields.len", .after = "@typeInfo(@This()).@\"enum\".field_names.len", .count = 1 },
    .{ .path = "src/Data.zig", .before = "builtin.mode == .Debug", .after = "builtin.mode == .debug", .count = 1 },
    .{ .path = "src/WidgetStack.zig", .before = "builtin.mode == .Debug", .after = "builtin.mode == .debug", .count = 3 },
    .{ .path = "src/dvui.zig", .before = "builtin.mode == .Debug", .after = "builtin.mode == .debug", .count = 11 },
    .{ .path = "src/widgets/BoxWidget.zig", .before = "builtin.mode == .Debug", .after = "builtin.mode == .debug", .count = 4 },
    .{ .path = "src/widgets/OsWindowWidget.zig", .before = "builtin.mode == .Debug", .after = "builtin.mode == .debug", .count = 1 },
    .{ .path = "src/backends/sdl.zig", .before = "std.fmt.bufPrintZ(buf, \"{s}{s}\", .{ dir, zon_file_name })", .after = "std.fmt.bufPrintSentinel(buf, \"{s}{s}\", .{ dir, zon_file_name }, 0)", .count = 1 },
    .{ .path = "src/backends/sdl.zig", .before = "std.fmt.bufPrintZ(buf, \"{s}{c}{s}\", .{ dir, std.fs.path.sep, zon_file_name })", .after = "std.fmt.bufPrintSentinel(buf, \"{s}{c}{s}\", .{ dir, std.fs.path.sep, zon_file_name }, 0)", .count = 1 },
    .{ .path = "src/backends/sdl.zig", .before = "std.fmt.bufPrintZ(buf, \"{s}\" ++ zon_file_name, .{std.mem.span(@as([*:0]const u8, @ptrCast(pref)))})", .after = "std.fmt.bufPrintSentinel(buf, \"{s}\" ++ zon_file_name, .{std.mem.span(@as([*:0]const u8, @ptrCast(pref)))}, 0)", .count = 1 },
    .{ .path = "src/backends/sdl.zig", .before =
    \\        const saved = std.zon.parse.fromSlice(
    \\            Saved,
    \\            std.heap.page_allocator,
    \\            nul_buf[0..data.len :0],
    \\            null,
    \\            .{ .ignore_unknown_fields = true },
    \\        ) catch return null;
    , .after =
    \\        var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    \\        defer parse_arena.deinit();
    \\        var diagnostics: std.zon.parse.Diagnostics = undefined;
    \\        const saved = std.zon.parse.fromSlice(Saved, .{
    \\            .gpa = std.heap.page_allocator,
    \\            .arena = parse_arena.allocator(),
    \\            .source = nul_buf[0..data.len :0],
    \\            .diagnostics = &diagnostics,
    \\            .ignore_unknown_fields = true,
    \\        }) catch return null;
    , .count = 1 },
};
pub const expected_replacements: u16 = blk: {
    var count: u16 = 0;
    for (rules) |rule| count += @intCast(rule.count);
    break :blk count;
};
/// Only exact source-relative paths are admitted. A known file with mismatched
/// original occurrence counts is a different input and must not be adapted.
/// Caller owns the returned bytes; null leaves every original byte untouched.
pub fn adapt(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !?[]u8 {
    if (!std.mem.endsWith(u8, path, ".zig")) return null;
    var replacement: ?[]u8 = null;
    errdefer if (replacement) |owned| gpa.free(owned);
    for (rules) |rule| {
        if (!std.mem.eql(u8, path, rule.path)) continue;
        const original_count = std.mem.count(u8, bytes, rule.before);
        if (original_count != rule.count) return error.DvuiAdaptationInputMismatch;
        const current = replacement orelse bytes;
        const next = try std.mem.replaceOwned(u8, gpa, current, rule.before, rule.after);
        if (replacement) |owned| gpa.free(owned);
        replacement = next;
    }
    return replacement;
}

test "exact Zig reflection substitutions reject drift and preserve other files" {
    const t = std.testing;
    const input = "const cursor_enum_count = @typeInfo(dvui.enums.Cursor).@\"enum\".fields.len;\n";
    const result = (try adapt(t.allocator, "src/backends/sdl3gpu.zig", input)).?;
    defer t.allocator.free(result);
    try t.expectEqualStrings("const cursor_enum_count = @typeInfo(dvui.enums.Cursor).@\"enum\".field_names.len;\n", result);
    try t.expectError(error.DvuiAdaptationInputMismatch, adapt(t.allocator, "src/backends/sdl.zig", "changed input"));
    try t.expectError(error.DvuiAdaptationInputMismatch, adapt(t.allocator, "src/backends/sdl3gpu.zig", result));
    try t.expect((try adapt(t.allocator, "unlisted.zig", input)) == null);
    try t.expect((try adapt(t.allocator, "src/backends/sdl.c", input)) == null);
}
