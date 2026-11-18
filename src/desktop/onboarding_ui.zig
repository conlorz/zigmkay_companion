//! My Keyboards and the pages that add keyboards and layouts. All IO is
//! scheduled after drawing.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const flow = desktop.onboarding;
const p = @import("project");
const ui = @import("editor-ui");
const keyboards_ui = @import("keyboards_ui.zig");
const catalog_ui = @import("catalog_ui.zig");

pub const Action = enum {
    none,
    inspect,
    analyze,
    prepare,
    create,
    open,
    add_existing,
    cancel,
    cancel_tutor,
    editor,
    tutor,
    choose_source,
    choose_location,
    choose_open,
    toggle_theme,
};

pub const State = struct {
    active: bool = true,
    selected: bool = false,
    stage: flow.Stage = .home,
    /// The keyboard chosen on My Keyboards, an index into `library.keyboards`.
    keyboard: ?usize = null,
    catalog: catalog_ui.View = .{},
    /// Opens the folder the native chooser returns.
    awaiting_open: bool = false,
    /// Opens `location` once the open layout is saved.
    open_when_saved: bool = false,
    /// The collection root My Keyboards was last loaded from.
    listed_root: [4096]u8 = @splat(0),
    generation: u64 = 1,
    editor_generation: u64 = 0,
    captured: [32]u8 = @splat(0),
    operation: ?flow.Operation = null,
    worker: ?*flow.Worker = null,
    source: ?flow.importer.Captured = null,
    analysis: ?flow.importer.Analysis = null,
    prepared: ?flow.importer.Prepared = null,
    collection: ?p.collection.Loaded = null,
    /// The layouts of every known keyboard, grouped by hardware.
    library: ?desktop.library.Library = null,
    root: [4096]u8 = @splat(0),
    location: [4096]u8 = @splat(0),
    source_location: [4096]u8 = @splat(0),
    source_valid: bool = false,
    entry: [256]u8 = @splat(0),
    name: [129]u8 = @splat(0),
    directory: [129]u8 = @splat(0),
    diagnostic: [1024]u8 = @splat(0),
    selector: usize = 0,
    template: usize = 0,
    module: usize = 0,
    confirmed: bool = false,
    discard: bool = false,
    add_existing: bool = false,
    review_details: bool = false,
    preparing_tutor: bool = false,

    pub fn deinit(self: *State) void {
        if (self.worker) |worker| worker.destroy();
        self.clearImport();
        if (self.collection) |*value| value.deinit();
        if (self.library) |*value| value.deinit();
    }

    pub fn replaceLibrary(self: *State, library: desktop.library.Library) void {
        if (self.library) |*old| old.deinit();
        self.library = library;
    }

    pub fn clearImport(self: *State) void {
        if (self.prepared) |*value| value.deinit();
        self.prepared = null;
        if (self.analysis) |*value| value.deinit();
        self.analysis = null;
        if (self.source) |*value| value.deinit();
        self.source = null;
        self.source_valid = false;
        self.confirmed = false;
        self.template = 0;
    }

    pub fn report(self: *State, err: anyerror) void {
        self.diagnostic = @splat(0);
        if (err == error.IncompatibleKeymapSeeCachedCompilerLog) if (self.source) |source| {
            const message = "This module is incompatible with the pinned keymap API. Compiler diagnostics: " ++
                "{s}/analysis.log. Choose another module or migrate the reported API manually.";
            _ = std.fmt.bufPrint(&self.diagnostic, message, .{source.directory}) catch {};
            return;
        };
        if (err == error.DefaultCallbackWithoutIds) {
            const message = "Schema 1 cannot represent a callback without declared custom IDs. " ++
                "Keep this source project and migrate its callback contract manually.";
            _ = std.fmt.bufPrint(&self.diagnostic, message, .{}) catch {};
            return;
        }
        const message = "{s}. Your source and existing projects are preserved. Retry analysis or choose a local folder.";
        _ = std.fmt.bufPrint(&self.diagnostic, message, .{@errorName(err)}) catch {};
    }

    pub fn set(buffer: []u8, value: []const u8) !void {
        if (value.len >= buffer.len or std.mem.indexOfScalar(u8, value, 0) != null) return error.PathTooLong;
        @memset(buffer, 0);
        @memcpy(buffer[0..value.len], value);
    }

    pub fn defaults(self: *State, root: []const u8) !void {
        try set(&self.root, root);
        try set(&self.entry, "src/keymap.zig");
        try set(&self.name, "My keyboard");
        try set(&self.directory, "my-keyboard");
    }

    pub fn reset(self: *State) void {
        if (self.worker) |worker| worker.destroy();
        self.worker = null;
        self.generation +%= 1;
        self.clearImport();
        self.stage = .home;
        self.active = true;
        self.awaiting_open = false;
        self.open_when_saved = false;
        self.discard = false;
        self.diagnostic = @splat(0);
    }

    pub fn reloadCollection(self: *State, gpa: std.mem.Allocator, io: std.Io) !void {
        if (self.collection) |*value| value.deinit();
        self.collection = null;
        var dir = std.Io.Dir.cwd().openDir(io, std.mem.sliceTo(&self.root, 0), .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        self.collection = p.collection.load(gpa, io, dir) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    pub fn fingerprint(self: *State) [32]u8 {
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        inline for (.{ "root", "location", "entry", "name", "directory" }) |field_name| {
            hash.update(std.mem.sliceTo(&@field(self, field_name), 0));
            hash.update(&.{0});
        }
        hash.update(std.mem.asBytes(&self.selector));
        hash.update(std.mem.asBytes(&self.template));
        hash.update(&.{ @intFromBool(self.confirmed), @intFromBool(self.discard) });
        if (self.source) |value| hash.update(&value.provenance.fingerprint);
        return hash.finalResult();
    }

    /// Whether the inspected source still matches the location and module fields.
    fn inspectedSelection(self: *const State) bool {
        const source = self.source orelse return false;
        return self.source_valid and
            std.mem.eql(u8, std.mem.sliceTo(&self.location, 0), std.mem.sliceTo(&self.source_location, 0)) and
            std.mem.eql(u8, std.mem.sliceTo(&self.entry, 0), source.provenance.entry);
    }

    pub fn start(
        self: *State,
        gpa: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        toolchain: flow.importer.Toolchain,
        action: Action,
        owner_generation: u64,
    ) !void {
        if (self.worker != null) return error.OnboardingAlreadyRunning;
        if (action == .analyze and !self.inspectedSelection()) return error.InspectNewSourceSelectionFirst;
        if (action == .inspect) self.source_valid = false;
        self.generation = try std.math.add(u64, self.generation, 1);
        var input: flow.Inputs = .{
            .operation = .inspect,
            .toolchain = toolchain,
            .location = std.mem.sliceTo(&self.location, 0),
            .entry = if (self.entry[0] != 0) std.mem.sliceTo(&self.entry, 0) else null,
            .selector = flow.catalog.entries[self.selector].selector,
            .name = std.mem.sliceTo(&self.name, 0),
        };
        if (self.source) |value| input.source = .{
            .directory = value.directory,
            .source_root = value.source_root,
            .provenance = value.provenance,
            .candidates = value.candidates,
        };
        if (self.analysis) |value| input.analysis = .{ .captured = value.captured, .data = value.data };
        input.template = @fromBackingInt(@intCast(self.template));
        input.operation = switch (action) {
            .inspect => .inspect,
            .analyze => .analyze,
            .prepare => .prepare,
            .create => .create,
            .open => .open,
            .add_existing => .add_existing,
            else => return error.InvalidOnboardingAction,
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (action == .create or action == .add_existing) {
            const relative = try std.fmt.allocPrint(a, "keyboards/{s}", .{std.mem.sliceTo(&self.directory, 0)});
            const entry: p.collection.Entry = .{ .id = std.mem.sliceTo(&self.directory, 0), .directory = relative };
            try p.collection.validate(.{ .projects = &.{entry} });
            input.collection = std.mem.sliceTo(&self.root, 0);
            input.collection_entry = entry;
            input.collection_fingerprint = if (self.collection) |value| value.fingerprint else null;
            input.destination = try std.fs.path.join(a, &.{ input.collection.?, relative });
        }
        if (action == .create) {
            const prepared = self.prepared orelse return error.PreparedProjectRequired;
            input.prepared = .{ .snapshot = prepared.project.snapshot, .selector = prepared.board.entry.selector };
        }
        const source_fingerprint = if (self.source) |value| value.provenance.fingerprint else @as([32]u8, @splat(0));
        var request = try flow.Request.init(gpa, input, environment, source_fingerprint);
        errdefer request.deinit();
        self.captured = self.fingerprint();
        self.editor_generation = owner_generation;
        self.worker = try flow.Worker.create(gpa, io, &request, self.generation);
        self.operation = input.operation;
        self.diagnostic = @splat(0);
    }

    pub fn poll(self: *State, owner_generation: u64) !?flow.Opened {
        const worker = self.worker orelse return null;
        const event = worker.poll() orelse return null;
        self.worker = null;
        defer worker.destroy();
        var result = event.result catch |err| {
            self.report(err);
            return null;
        };
        const stale = event.ticket.generation != self.generation or self.editor_generation != owner_generation or
            !std.mem.eql(u8, &self.captured, &self.fingerprint());
        if (stale) {
            result.deinit();
            return error.StaleOnboardingResult;
        }
        switch (result) {
            .inspected => |value| {
                self.clearImport();
                self.source = value;
                self.source_valid = true;
                try set(&self.source_location, worker.request.inputs.location);
                self.module = 0;
                try set(&self.entry, value.provenance.entry);
                for (value.candidates, 0..) |candidate, index| {
                    if (std.mem.eql(u8, candidate, value.provenance.entry)) self.module = index;
                }
            },
            .analyzed => |value| {
                if (self.analysis) |*old| old.deinit();
                self.analysis = value;
                self.stage = .keyboard;
                for (flow.catalog.entries, 0..) |entry, index| {
                    if (flow.importer.compatible(value.data, entry)) {
                        self.selector = index;
                        break;
                    }
                }
            },
            .prepared => |value| {
                if (self.prepared) |*old| old.deinit();
                self.prepared = value;
                self.stage = .review;
            },
            .opened => |value| return value,
        }
        return null;
    }
};

fn field(comptime label: []const u8, buffer: []u8) void {
    const id = std.hash.Wyhash.hash(0, label);
    dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = id });
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer } }, .{ .expand = .horizontal, .id_extra = id });
    entry.deinit();
}

/// What the onboarding pages know about the editor and the connected keyboard.
pub const Context = struct {
    dirty: bool = false,
    /// Whether the open layout saves itself; otherwise unsaved edits need an
    /// explicit discard before another project opens.
    autosaves: bool = false,
    host_source: []const u8 = "Offline",
    light: bool = false,
    current_path: []const u8 = "",
    running: ?keyboards_ui.Running = null,
    now: i96 = 0,
};

pub fn draw(state: *State, context: Context) !Action {
    const theme = ui.Theme.get(context.light);
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .padding = .{}, .border = .{}, .background = false });
    defer scroll.deinit();
    const canvas = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = keyboards_ui.canvas_width, .h = keyboards_ui.canvas_height },
        .padding = .{},
        .margin = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
    });
    defer canvas.deinit();
    var action: Action = .none;
    const busy = state.worker != null;
    switch (state.stage) {
        .home => action = try home(state, theme, context),
        .catalog => switch (catalog_ui.draw(&state.catalog, theme, context.light, libraryOf(state))) {
            .none => {},
            .back => state.stage = .home,
            .toggle_theme => action = .toggle_theme,
            .choose => |index| {
                state.clearImport();
                state.selector = index;
                state.confirmed = true;
                state.stage = .keyboard;
            },
        },
        else => action = try legacy(state, theme, context, busy),
    }
    if (state.awaiting_open and state.location[0] != 0 and action == .none) {
        state.awaiting_open = false;
        action = .open;
    }
    if (busy) drawBusy(state, theme, &action);
    if (context.dirty and !context.autosaves) {
        const warning = "The editor has unsaved changes.";
        banner(theme, warning, ui.color(0xF59E0B), 0);
        var opts = ui.options(theme, .{ .x = 560, .y = 1012, .w = 560, .h = 22 }, 13);
        opts.padding = .{};
        _ = dvui.checkbox(@src(), &state.discard, "Discard them when opening another project", opts);
        if (!state.discard and (action == .open or action == .create or action == .add_existing)) action = .none;
    }
    const diagnostic = std.mem.sliceTo(&state.diagnostic, 0);
    if (diagnostic.len != 0) banner(theme, diagnostic, ui.color(0xF06B73), 1);
    return action;
}

fn libraryOf(state: *const State) ?*const desktop.library.Library {
    return if (state.library) |*value| value else null;
}

fn home(state: *State, theme: ui.Theme, context: Context) !Action {
    const intent = keyboards_ui.draw(theme, context.light, &state.keyboard, .{
        .library = libraryOf(state),
        .current_path = context.current_path,
        .running = context.running,
        .now = context.now,
        .has_editor = state.selected,
        .collection = std.mem.sliceTo(&state.root, 0),
    });
    switch (intent) {
        .none => {},
        .open_layout => |index| {
            try State.set(&state.location, state.library.?.layouts[index].path);
            return .open;
        },
        .new_layout => |index| {
            const keyboard = state.library.?.keyboards[index];
            const first = state.library.?.layouts[keyboard.layouts[0]].entry;
            state.clearImport();
            state.selector = entryIndex(first);
            state.confirmed = true;
            state.stage = .keyboard;
        },
        .add_keyboard => {
            state.catalog = .{};
            state.stage = .catalog;
        },
        .import_git => {
            state.clearImport();
            state.stage = .source;
        },
        .open_folder => {
            state.location = @splat(0);
            state.awaiting_open = true;
            return .choose_open;
        },
        .change_location => return .choose_location,
        .editor => return .editor,
        .toggle_theme => return .toggle_theme,
    }
    return .none;
}

fn entryIndex(entry: *const desktop.library.catalog.Entry) usize {
    for (&flow.catalog.entries, 0..) |*candidate, index| if (candidate == entry) return index;
    return 0;
}

/// A one-line message across the bottom of the page.
fn banner(theme: ui.Theme, message: []const u8, tint: dvui.Color, id: usize) void {
    const y: f32 = if (id == 0) 1004 else 964;
    const strip = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = .{ .x = 16, .y = y, .w = keyboards_ui.canvas_width - 32, .h = 36 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, tint, 0.14) },
        .color_border = .{ .color = tint },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = if (id == 0) "onboarding.unsaved" else "onboarding.diagnostic",
    });
    strip.deinit();
    keyboards_ui.text(theme, message, .{ .x = 32, .y = y + 8, .w = 520, .h = 20 }, 13, theme.text, false, 900 + id);
}

/// While a worker prepares something, a strip names it and offers Cancel.
fn drawBusy(state: *State, theme: ui.Theme, action: *Action) void {
    const strip = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 16, .y = 924, .w = keyboards_ui.canvas_width - 32, .h = 36 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "onboarding.busy",
    });
    strip.deinit();
    dvui.spinner(@src(), .{
        .rect = .{ .x = 30, .y = 932, .w = 20, .h = 20 },
        .min_size_content = .{ .w = 20, .h = 20 },
        .padding = .{},
        .margin = .{},
        .color_text = .{ .color = theme.accent },
    });
    var buffer: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "Working: {s}…", .{if (state.operation) |operation| switch (operation) {
        .inspect => "capturing the source",
        .analyze => "analyzing the keymap",
        .prepare => "preparing the layout",
        .create => "creating the layout",
        .open => "opening",
        .add_existing => "adding the project",
    } else "preparing"}) catch "Working…";
    keyboards_ui.text(theme, label, .{ .x = 60, .y = 932, .w = 600, .h = 20 }, 13, theme.text, false, 910);
    if (state.operation != .create and ui.iconButton(theme, null, "Cancel", "onboarding.cancel", .{ .x = keyboards_ui.canvas_width - 128, .y = 928, .w = 96, .h = 28 }, false)) action.* = .cancel;
}

/// Pages of the earlier wizard, framed in the current style until they are
/// replaced.
fn legacy(state: *State, theme: ui.Theme, context: Context, busy: bool) !Action {
    var action: Action = .none;
    const trail: []const []const u8 = switch (state.stage) {
        .source => &.{ "My Keyboards", "Import from Git" },
        .keyboard, .review => &.{ "My Keyboards", "New layout" },
        .created => &.{ "My Keyboards", "Layout ready" },
        else => &.{ "My Keyboards", "Open" },
    };
    if (keyboards_ui.bar(theme, trail, context.light)) action = .toggle_theme;
    if (!busy and state.stage != .created and ui.iconButton(theme, ui.control_icons.back, "Back to My Keyboards", "onboarding.back", .{ .x = 1270, .y = 14, .w = 204, .h = 36 }, false)) {
        state.clearImport();
        state.stage = .home;
    }
    keyboards_ui.panel(theme, .{ .x = 16, .y = 80, .w = keyboards_ui.canvas_width - 32, .h = 836 }, 3);
    const body = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 40, .y = 100, .w = keyboards_ui.canvas_width - 80, .h = 796 }, .background = false });
    defer body.deinit();
    const content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .font = ui.options(theme, .{}, 15).font, .color_text = .{ .color = theme.text } });
    defer content.deinit();
    if (busy) return action;
    const chosen = switch (state.stage) {
        .home, .catalog => Action.none,
        .source => try drawSource(state),
        .keyboard => try drawKeyboard(state),
        .review => try drawReview(state, context.host_source),
        .created => drawCreated(state),
        .open => drawOpen(state),
    };
    if (chosen != .none) action = chosen;
    return action;
}

fn drawSource(state: *State) !Action {
    var action: Action = .none;
    field("Local source folder or public GitHub repository URL", &state.location);
    if (dvui.button(@src(), "Choose source folder…", .{}, .{})) action = .choose_source;
    field("Keymap module (suggested: src/keymap.zig)", &state.entry);
    if (dvui.button(@src(), "Inspect source / Retry", .{}, .{})) action = .inspect;
    const source = state.source orelse return action;
    const digest = std.fmt.bytesToHex(source.provenance.fingerprint, .lower);
    dvui.label(@src(), "Captured {d} source files · {s}", .{ source.provenance.sources.len, digest }, .{});
    if (source.candidates.len > 1 and dvui.dropdown(@src(), source.candidates, .{ .choice = &state.module }, .{}, .{})) {
        try State.set(&state.entry, source.candidates[state.module]);
        try State.set(&state.location, source.source_root);
        action = .inspect;
    }
    if (source.provenance.commit) |commit| dvui.label(@src(), "Immutable commit: {s}", .{commit}, .{});
    for (source.provenance.sources, 0..) |file, index| dvui.label(@src(), "Retain {s}", .{file.path}, .{ .id_extra = index });
    if (state.inspectedSelection() and dvui.button(@src(), "Analyze selected module", .{}, .{})) action = .analyze;
    return action;
}

fn drawKeyboard(state: *State) !Action {
    const arena = dvui.currentWindow().arena();
    const names = try arena.alloc([]const u8, flow.catalog.entries.len);
    for (flow.catalog.entries, names) |entry, *name| {
        name.* = try std.fmt.allocPrint(
            arena,
            "{s} · PCB {s} · {s}",
            .{ entry.display.name, entry.display.revision, entry.display.template },
        );
    }
    if (dvui.dropdown(@src(), names, .{ .choice = &state.selector }, .{}, .{ .expand = .horizontal })) {
        state.confirmed = false;
        state.template = 0;
    }
    const selected = flow.catalog.entries[state.selector];
    if (state.analysis == null and std.mem.eql(u8, selected.selector, "lk7")) {
        dvui.label(@src(), "Starting template", .{}, .{});
        const templates: []const []const u8 = &.{ "Selected firmware default", "QWERTY", "EurKEY draft", "EurKEY Next Mac candidate" };
        _ = dvui.dropdown(@src(), templates, .{ .choice = &state.template }, .{}, .{});
    }
    const dimensions = .{ selected.default_dimensions.key_count, selected.encoder_action_slots };
    dvui.label(@src(), "{d} keys · {d} encoder directions · schematic geometry", dimensions, .{});
    if (state.analysis) |analysis| if (!flow.importer.compatible(analysis.data, selected)) {
        const text = "Choose a compatible Keycaprio 0.6 or 0.7 target. " ++
            "Matching dimensions alone do not establish hardware compatibility.";
        dvui.label(@src(), text, .{}, .{});
    };
    _ = dvui.checkbox(@src(), &state.confirmed, "I confirm this keyboard hardware and PCB revision", .{});
    field("Profile name", &state.name);
    if (state.confirmed and dvui.button(@src(), "Review keyboard", .{}, .{})) return .prepare;
    return .none;
}

fn drawReview(state: *State, host_source: []const u8) !Action {
    var action: Action = .none;
    const prepared = state.prepared orelse return error.PreparedProjectRequired;
    const doc = prepared.project.snapshot.document;
    const board = prepared.board.entry.display;
    dvui.label(@src(), "Keyboard: {s} · PCB {s}", .{ board.name, board.revision }, .{});
    dvui.label(
        @src(),
        "{s}: {d} keys, {d} layers, {d} ordered combos",
        .{ doc.name, doc.key_ids.len, doc.layers.len, doc.combos.len },
        .{},
    );
    for (doc.layers, 0..) |layer, index| {
        var disabled: usize = 0;
        var transparent: usize = 0;
        for (layer.actions) |assignment| {
            if (assignment) |value| {
                if (value == .none) disabled += 1;
            } else transparent += 1;
        }
        const assigned = layer.actions.len - transparent - disabled;
        const counts = .{ layer.name, assigned, transparent, disabled };
        dvui.label(@src(), "{s}: {d} assignments, {d} transparent, {d} disabled", counts, .{ .id_extra = index });
    }
    if (doc.callbacks.len != 0) {
        const text = "Custom callback source is retained byte-for-byte. " ++
            "Existing layer indices stay fixed; names and assignments remain editable.";
        dvui.label(@src(), text, .{}, .{});
    }
    for (doc.callbacks, 0..) |callback, index| {
        dvui.label(@src(), "Retained module {s} · custom IDs {any}", .{ callback.binding, callback.ids }, .{ .id_extra = index });
    }
    _ = dvui.checkbox(@src(), &state.review_details, "Show every assignment, combo and encoder action", .{});
    if (state.review_details) {
        for (doc.layers, 0..) |layer, li| for (layer.actions, 0..) |assignment, ki| {
            dvui.label(@src(), "{s} / {s}: {any}", .{ layer.name, doc.key_ids[ki], assignment }, .{ .id_extra = li * 128 + ki });
        };
        for (doc.combos, 0..) |combo, index| dvui.label(@src(), "Combo {d}: {any}", .{ index + 1, combo }, .{ .id_extra = index });
        for (doc.encoders, 0..) |encoder, index| {
            dvui.label(@src(), "Encoder direction {d}: {any}", .{ index + 1, encoder }, .{ .id_extra = index });
        }
    }
    const host_hint = if (state.source) |source| source.provenance.host_layout_hint else board.host_layout;
    dvui.label(@src(), "Host layout hint: {s} · active OS input source: {s}", .{ host_hint, host_source }, .{});
    dvui.label(@src(), "Your OS input settings are unchanged. Exports use the application's pinned firmware.", .{}, .{});
    field("Collection location (Change location)", &state.root);
    if (dvui.button(@src(), "Change location…", .{}, .{})) action = .choose_location;
    field("New keyboard directory / stable collection entry ID", &state.directory);
    const destination = .{ std.mem.sliceTo(&state.root, 0), std.mem.sliceTo(&state.directory, 0) };
    dvui.label(@src(), "Destination: {s}/keyboards/{s}", destination, .{});
    if (dvui.button(@src(), "Create new project", .{}, .{ .tag = "onboarding.commit" })) action = .create;
    return action;
}

fn drawCreated(state: *State) Action {
    var action: Action = .none;
    dvui.label(@src(), "Saved, reopened and added to your collection.", .{}, .{});
    if (dvui.button(@src(), "Open editor", .{}, .{})) action = .editor;
    if (state.preparing_tutor) {
        dvui.label(@src(), "Preparing the native tutor runner…", .{}, .{});
        if (dvui.button(@src(), "Cancel tutor preparation", .{}, .{})) action = .cancel_tutor;
    } else if (dvui.button(@src(), "Try tutor", .{}, .{})) {
        action = .tutor;
    }
    return action;
}

fn drawOpen(state: *State) Action {
    var action: Action = .none;
    if (state.add_existing) {
        const text = "Add a project inside this collection, or explicitly make a portable copy of an external project. " ++
            "The original stays unchanged.";
        dvui.label(@src(), text, .{}, .{});
        field("Existing project directory (leave empty for membership only)", &state.location);
        if (dvui.button(@src(), "Choose existing project…", .{}, .{})) action = .choose_open;
        field("Directory name inside keyboards/", &state.directory);
        const label = if (state.location[0] != 0) "Copy project into collection" else "Add existing project";
        if (dvui.button(@src(), label, .{}, .{})) action = .add_existing;
    } else {
        field("Project or collection directory", &state.location);
        if (dvui.button(@src(), "Choose folder…", .{}, .{})) action = .choose_open;
        if (dvui.button(@src(), "Open", .{}, .{})) action = .open;
    }
    return action;
}

test "wizard rejects stale settings and owner generations without touching destinations" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var state: State = .{};
    defer state.deinit();
    try state.defaults(path);
    const toolchain: flow.importer.Toolchain = .{ .compiler = "", .build_root = "", .cache = path };
    try state.start(t.allocator, t.io, &env, toolchain, .prepare, 1);
    try State.set(&state.name, "Newer selection");
    var refused = false;
    for (0..1000) |_| {
        if (state.poll(1)) |opened| {
            if (opened != null) return error.UnexpectedProjectReplacement;
        } else |err| {
            try t.expectEqual(error.StaleOnboardingResult, err);
            refused = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(refused);
    try t.expect(state.prepared == null);
    try state.start(t.allocator, t.io, &env, toolchain, .prepare, 1);
    refused = false;
    for (0..1000) |_| {
        if (state.poll(2)) |opened| {
            if (opened != null) return error.UnexpectedProjectReplacement;
        } else |err| {
            try t.expectEqual(error.StaleOnboardingResult, err);
            refused = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(refused);
    try state.start(t.allocator, t.io, &env, toolchain, .prepare, 2);
    state.reset();
    try t.expect(state.worker == null and state.prepared == null);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "project.zon", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "workspace.zon", .{}));
    try State.set(&state.location, "/new/source");
    try t.expectError(error.InspectNewSourceSelectionFirst, state.start(t.allocator, t.io, &env, toolchain, .analyze, 2));
}
