//! Offline one-click Flash dispatch state-machine coverage. No wrapper, UF2,
//! receipt, HID, discovery, or transfer is constructed by this test.
const std = @import("std");
const desktop = @import("desktop-core");
const project = @import("project");
const app = @import("main.zig");

test "one click dispatches captured Flash intent without starting hardware work" {
    const gpa = std.testing.allocator;
    var template = try project.profiles.create(gpa, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(gpa, project.profiles.board, template.snapshot);
    defer model.deinit();
    var state = try desktop.editor_dispatch.State.init(&model);
    defer state.deinit();

    const effect = try app.dispatchFlash(&state, &model);
    switch (effect) {
        .flash => |captured| {
            try app.acceptFlashEffect(&model, captured);
            try std.testing.expectEqualDeep(try model.id(), captured.snapshot);
        },
        else => return error.FlashIntentNotDispatched,
    }
    try std.testing.expect(state.pending == null);
    try std.testing.expect(!state.closed);
}
