//! Carries out what the editor frame requested: project files, callback
//! sources, folder choosers, navigation, profiles, builds and Flash.
//!
//! Filesystem work and native choosers start only after the frame that
//! showed the request was displayed.
const std = @import("std");
const desktop = @import("desktop-core");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const paths = @import("paths-ui");
const callbacks = @import("callback-ui");
const dialog = @import("folder-dialog");
const App = @import("App.zig");
const Flash = @import("Flash.zig");
const workers = @import("workers.zig");

/// A refused request skips the rest of the frame.
pub fn apply(app: *App, result: editor.Result, board: *const boards.OwnedBoard, can_build: bool) !App.Flow {
    return switch (result) {
        .paths => |action| projectFiles(app, action),
        .callback => |action| callbackSource(app, action),
        .effect => |effect| switch (effect) {
            .save, .save_close => |captured| save(app, captured, effect == .save_close),
            .open => |target| open(app, target),
            .profile => |captured| switchProfile(app, captured),
            .build => |captured| build(app, captured),
            .flash => |captured| Flash.request(app, captured, board, can_build),
            else => .proceed,
        },
    };
}

fn projectFiles(app: *App, action: paths.Action) !App.Flow {
    switch (action.kind) {
        .cancel => app.jobs.cancel(),
        .choose_project => return chooseFolder(app, action.snapshot, .project),
        .choose_export => return chooseFolder(app, action.snapshot, .export_directory),
        else => {
            if (refuseWhileBusy(app)) return .next_frame;
            const next_job = try std.math.add(u64, app.job_generation, 1);
            app.jobs.file = workers.startFile(app, action, next_job) catch |err| return reported(app, err);
            app.job_generation = next_job;
        },
    }
    return .proceed;
}

fn callbackSource(app: *App, action: callbacks.Action) !App.Flow {
    if (action.kind == .cancel) {
        app.jobs.cancel();
        return .next_frame;
    }
    if (refuseWhileBusy(app)) return .next_frame;
    if (action.kind == .choose_root) return chooseFolder(app, action.snapshot, .callback_source);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.source = workers.startSource(app, action, next_job) catch |err| return reported(app, err);
    app.job_generation = next_job;
    return .proceed;
}

fn chooseFolder(app: *App, snapshot: [32]u8, target: desktop.folder_selection.Target) App.Flow {
    const ticket = app.chooser.begin(app.owner_generation, snapshot, target) catch |err| return reported(app, err);
    dialog.startCorrelated(app.native.window, ticket.generation) catch |err| {
        _ = app.chooser.discard(ticket);
        app.view.report(err);
    };
    return .proceed;
}

fn save(app: *App, captured: desktop.editor_dispatch.Request, close: bool) !App.Flow {
    captured.validate(&app.model) catch |err| return reported(app, err);
    if (refuseWhileBusy(app)) return .next_frame;
    const next_job = try std.math.add(u64, app.job_generation, 1);
    const action = app.view.paths.action(try app.model.id(), .save);
    app.jobs.file = workers.startFile(app, action, next_job) catch |err| {
        app.view.report(err);
        app.view.modal = .paths;
        return .next_frame;
    };
    app.job_generation = next_job;
    if (close) app.jobs.file.?.close = captured;
    return .proceed;
}

fn open(app: *App, target: desktop.editor_dispatch.Open) App.Flow {
    switch (target) {
        .practice => {
            app.practicing = true;
            app.view.diagnostic = @splat(0);
        },
        .keyboards => {
            app.onboarding.reset();
            app.onboarding.reloadCollection(app.gpa, app.io) catch |err| app.onboarding.report(err);
        },
        else => app.view.report(error.NavigationNotConnected),
    }
    return .proceed;
}

/// Opens the project associated with the selected profile, or creates it in
/// the projects folder.
fn switchProfile(app: *App, captured: desktop.editor_dispatch.Request) !App.Flow {
    if (refuseWhileBusy(app)) return .next_frame;
    captured.validate(&app.model) catch |err| return reported(app, err);
    const owned = app.user_paths orelse return reported(app, error.UserPathsUnavailable);
    const id = captured.intent.profile;
    const key: desktop.profile_projects.Key = .{ .board_id = app.model.document().board_id, .profile_id = id };
    const target = if (app.registry.path(key)) |associated|
        try app.gpa.dupe(u8, associated)
    else
        try std.fs.path.join(app.gpa, &.{ owned.paths.projects, std.mem.sliceTo(&id, 0) });
    defer app.gpa.free(target);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    var request = desktop.profile_switch.Request.capture(&app.model, id, target) catch |err| return reported(app, err);
    const worker = desktop.profile_switch.Worker.create(app.gpa, app.io, &request, next_job) catch |err| {
        request.deinit();
        return reported(app, err);
    };
    app.jobs.profile = .{
        .worker = worker,
        .action = captured,
        .editor_generation = app.owner_generation,
        .previous_path = app.view.paths.project,
    };
    app.job_generation = next_job;
    return .proceed;
}

fn build(app: *App, captured: desktop.editor_dispatch.Request) !App.Flow {
    if (refuseWhileBusy(app)) return .next_frame;
    captured.validate(&app.model) catch |err| return reported(app, err);
    const plan = app.build.plan orelse return reported(app, error.MissingApplicationBundle);
    const next_job = try std.math.add(u64, app.job_generation, 1);
    app.jobs.build = workers.startBuild(app, plan.config, next_job) catch |err| return reported(app, err);
    app.job_generation = next_job;
    app.build.scheduler.manual(try app.model.id());
    app.view.diagnostic = @splat(0);
    return .proceed;
}

fn refuseWhileBusy(app: *App) bool {
    if (!app.jobs.busy()) return false;
    app.view.report(error.ProjectOperationAlreadyRunning);
    return true;
}

fn reported(app: *App, err: anyerror) App.Flow {
    app.view.report(err);
    return .next_frame;
}
