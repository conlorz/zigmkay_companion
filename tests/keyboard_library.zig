//! Hardware-free acceptance of keyboard grouping, layout transfer and the
//! layout operations behind My Keyboards and the editor head.
const std = @import("std");
const desktop = @import("desktop-core");
const p = @import("project");
const library = desktop.library;
const boards = desktop.onboarding.boards;

test "layouts group by hardware in place and unreadable projects stay untouched" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var qwerty = try p.profiles.create(t.allocator, .qwerty);
    defer qwerty.deinit();
    var eurmac = try p.profiles.create(t.allocator, .eurmac);
    defer eurmac.deinit();
    var molekula_board = try boards.OwnedBoard.init(t.allocator, "molekula");
    defer molekula_board.deinit();
    var molekula = try boards.createDefault(t.allocator, molekula_board);
    defer molekula.deinit();
    const Project = struct { path: []const u8, snapshot: p.snapshot.Snapshot, board: p.Board };
    const projects = [_]Project{
        .{ .path = "My Keyboards/keyboards/desk", .snapshot = qwerty.snapshot, .board = p.profiles.board },
        .{ .path = "My Keyboards/keyboards/travel", .snapshot = molekula.snapshot, .board = molekula_board.board },
        .{ .path = "eurmac", .snapshot = eurmac.snapshot, .board = p.profiles.board },
    };
    for (projects) |project| {
        var dir = try tmp.dir.createDirPathOpen(t.io, project.path, .{});
        defer dir.close(t.io);
        try p.snapshot.save(t.allocator, t.io, dir, project.snapshot, project.board);
    }
    var collection = try tmp.dir.openDir(t.io, "My Keyboards", .{});
    defer collection.close(t.io);
    try p.collection.save(t.allocator, t.io, collection, .{ .projects = &.{
        .{ .id = "desk", .directory = "keyboards/desk" },
        .{ .id = "travel", .directory = "keyboards/travel" },
    } }, null);
    const broken = "opaque personal bytes\n";
    var corrupt = try tmp.dir.createDirPathOpen(t.io, "corrupt", .{});
    defer corrupt.close(t.io);
    try corrupt.writeFile(t.io, .{ .sub_path = "project.zon", .data = broken });
    const collection_path = try std.fs.path.join(t.allocator, &.{ root, "My Keyboards" });
    defer t.allocator.free(collection_path);
    const desk = try std.fs.path.join(t.allocator, &.{ collection_path, "keyboards/desk" });
    defer t.allocator.free(desk);
    var loaded = try library.load(t.allocator, t.io, .{ .collection = collection_path, .projects = root, .extra = &.{desk} });
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 3), loaded.layouts.len);
    try t.expectEqual(@as(usize, 2), loaded.keyboards.len);
    try t.expectEqual(@as(usize, 2), loaded.keyboards[0].layouts.len);
    try t.expectEqualStrings("keyboards/desk", loaded.layouts[loaded.find(desk).?].member.?);
    const legacy = loaded.layouts[loaded.keyboards[0].layouts[1]];
    try t.expect(legacy.member == null);
    try t.expectEqualStrings("EurKEY Next Mac candidate", legacy.name);
    try t.expectEqualStrings("Q", loaded.layouts[0].base[0]);
    try t.expectEqualStrings("molekula", loaded.layouts[loaded.keyboards[1].layouts[0]].entry.selector);
    try t.expectEqual(@as(usize, 1), loaded.unreadable.len);
    const preserved = try corrupt.readFileAlloc(t.io, "project.zon", t.allocator, .limited(4096));
    defer t.allocator.free(preserved);
    try t.expectEqualStrings(broken, preserved);
}

test "relative ages read naturally" {
    var buffer: [32]u8 = undefined;
    const minute = 60 * std.time.ns_per_s;
    try std.testing.expectEqualStrings("just now", library.age(&buffer, minute / 2, 0));
    try std.testing.expectEqualStrings("2 min ago", library.age(&buffer, 2 * minute, 0));
    try std.testing.expectEqualStrings("yesterday", library.age(&buffer, 30 * 60 * minute, 0));
    try std.testing.expectEqualStrings("3 weeks ago", library.age(&buffer, 21 * 24 * 60 * minute, 0));
}

test "renaming a layout is one undoable edit and refuses empty names" {
    const t = std.testing;
    var template = try p.profiles.create(t.allocator, .eurmac);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, p.profiles.board, template.snapshot);
    defer model.deinit();
    var owner = try desktop.editor_dispatch.State.init(&model);
    defer owner.deinit();
    var name: [129]u8 = @splat(0);
    @memcpy(name[0.."EurKEY Next Mac".len], "EurKEY Next Mac");
    const request = try desktop.editor_dispatch.Request.capture(&model, .{ .rename_layout = name });
    try t.expect(try owner.request(&model, request) == .none);
    try t.expectEqualStrings("EurKEY Next Mac", model.document().name);
    try t.expect(model.dirty());
    try model.undo();
    try t.expectEqualStrings("EurKEY Next Mac candidate", model.document().name);
    const empty = try desktop.editor_dispatch.Request.capture(&model, .{ .rename_layout = @splat(0) });
    try t.expectError(error.InvalidName, owner.request(&model, empty));
}
