//! The main window shows onboarding, the tutor or the editor.
const std = @import("std");
const dvui = @import("dvui");
const project = @import("project");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const keyboard_onboarding = @import("onboarding-ui");
const dialog = @import("folder-dialog");
const App = @import("App.zig");
const Tutor = @import("Tutor.zig");
const fixtures = @import("fixtures.zig");

const Toolbar = @FieldType(editor.Frame, "toolbar");
const Profile = std.meta.Elem(@FieldType(Toolbar, "profiles"));

/// What the screen requested this frame.
pub const Screen = struct {
    rendered: editor.Result = .{ .effect = .none },
    onboarding: keyboard_onboarding.Action = .none,
    tutor: Tutor.Outcome = .{},
};

pub fn draw(app: *App, board: *const boards.OwnedBoard, practice: Tutor.Frame, can_build: bool, now_us: u64) !Screen {
    var toolbar = try toolbarFrame(app, board, can_build, now_us);
    fixtures.statusToolbar(app, &toolbar);
    var screen: Screen = .{};
    app.onboarding.preparing_tutor = app.jobs.runner != null;
    if (app.onboarding.active) {
        const source = if (app.source) |*value| value.id() else "Offline";
        screen.onboarding = try keyboard_onboarding.draw(&app.onboarding, app.unsavedChanges(), source, app.view.toolbar.light);
    } else if (app.practicing) {
        screen.tutor = Tutor.draw(app, practice, now_us);
    } else if (app.life.editor_visible) {
        screen.rendered = drawEditor(app, board, toolbar) catch |err| failed: {
            app.view.report(err);
            break :failed .{ .effect = .none };
        };
    }
    return screen;
}

fn drawEditor(app: *App, board: *const boards.OwnedBoard, toolbar: Toolbar) !editor.Result {
    const document = app.model.document();
    return editor.draw(&app.view, &app.owner, &app.model, .{
        .toolbar = toolbar,
        .keyboard = .{
            .snapshot = try app.model.id(),
            .board_id = document.board_id,
            .physical_layout = document.physical_layout,
            .geometry = board.entry.geometry,
            .labels = &app.captions.labels,
            .board_name = board.entry.selector,
            .fidelity = "Catalog geometry · physical acceptance pending",
        },
        .host = &app.captions.host,
        .paths = .{ .exported = app.exported, .can_choose = app.frame_limit == null and !dialog.active(), .busy = app.jobs.busy() },
    });
}

fn toolbarFrame(app: *App, board: *const boards.OwnedBoard, can_build: bool, now_us: u64) !Toolbar {
    const flash = &app.flash;
    const build_job = app.jobs.build;
    const default_board = std.mem.eql(u8, &app.model.board.id, &project.profiles.board.id);
    return .{
        .board_name = board.entry.display.name,
        .connection = connectionLabel(app),
        .can_build = can_build,
        .can_flash = app.build.tools != null and app.build.plan != null and can_build and app.frame_limit == null,
        .flash_active = flash.active(),
        .build_active = build_job != null,
        .first_build = if (build_job) |job| job.first_build else false,
        .flash_succeeded = flash.phase() == .ready,
        .flash_failed = flash.failed(),
        .now_ms = now_us / 1000,
        .flash_status = try flash.toolbarStatus(dvui.currentWindow().arena(), build_job != null, now_us / 1000),
        .build_status = try buildStatus(app),
        .profiles = if (default_board) &builtin_profiles else &.{},
    };
}

const builtin_profiles = [_]Profile{
    .{ .id = "danish\x00\x00".*, .name = project.profiles.names[0] },
    .{ .id = "qwerty\x00\x00".*, .name = project.profiles.names[1] },
    .{ .id = "eurkey\x00\x00".*, .name = project.profiles.names[2] },
    .{ .id = "eurmac\x00\x00".*, .name = project.profiles.names[3] },
};

fn connectionLabel(app: *const App) []const u8 {
    if (app.live.driver) |*driver| if (driver.status == .multiple_devices) return "Multiple keyboards: ambiguous";
    return switch (app.live.status()) {
        .offline => "Offline editor",
        .connecting => "Keyboard connecting",
        .live => "Keyboard connected",
        .stale => "Keyboard state stale",
        .disconnected => "Keyboard disconnected",
        .incompatible => "Keyboard layout mismatch",
    };
}

fn buildStatus(app: *App) ![]const u8 {
    if (app.jobs.build) |job| return if (job.first_build)
        "First build: this can take a few minutes. Later builds are faster."
    else
        "Building";
    if (app.build.artifact) |artifact| return if (std.mem.eql(u8, &artifact.inputs.project_digest, &(try app.model.id())))
        "Built snapshot"
    else
        "Build outdated";
    if (app.build.plan != null) return "Ready to build and Flash";
    return "Application bundle is missing build resources";
}
