//! The inspector edits a session; only its fixed Apply control commits a snapshot.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const p = @import("project");
const ui = @import("editor-ui");
const labels = desktop.labels;
const catalog = desktop.action_catalog;
const editing = desktop.inspector_session;
const forms = desktop.action_form;
const fonts = @import("editor-fonts");

pub const State = struct {
    target: catalog.Target = .tap,
    category: catalog.Category = .all,
    advanced: bool = false,
    conversion: bool = false,
    removal_summary: []const u8 = "",
};
pub const Intent = desktop.inspector_action.Intent;
pub const Action = desktop.inspector_action.Action;
pub const KeycapResolver = struct {
    context: *anyopaque,
    render: *const fn (*anyopaque, ?p.Action, p.Document, []u8) []const u8,
};
pub const View = struct {
    state: State = .{},
    search: [128]u8 = @splat(0),
    diagnostic: [128]u8 = @splat(0),
    pending: bool = false,
    close_requested: bool = false,
    drag_chord: ?desktop.assignment.Chord = null,
    keycap: ?KeycapResolver = null,
};
// Borrowed copies exist only during one frame. Their arenas/documents are never
// allocated, freed or committed here; mutation touches the shared owned drafts.
const Context = struct {
    model: desktop.model.Model,
    edit_session: ?editing.Session,
    inspector_state: State,
    search: [128]u8,
    inspector_error: [128]u8,
    pending: ?u8,
    close_requested: bool,
    light: bool,
    drag_chord: ?desktop.assignment.Chord,
    resolver: ?KeycapResolver,
    intent: Intent = .none,
    fn choose(self: *Context, intent: Intent) void {
        if (self.intent == .none) self.intent = intent;
    }
    fn ensureSession(self: *Context) !void {
        if (try self.edit_session.?.stale(&self.model)) return error.StaleSession;
    }
    fn keycap(self: *Context, value: ?p.Action, buffer: []u8) []const u8 {
        if (self.resolver) |resolver| return resolver.render(resolver.context, value, self.model.document(), buffer);
        return labels.keycap(value, self.model.document(), buffer);
    }
    fn request(self: *Context, kind: enum { copy, paste }) !void {
        self.choose(if (kind == .copy) .copy else .paste);
    }
    fn reportInspector(self: *Context, failure: anyerror) void {
        @memset(&self.inspector_error, 0);
        const name = @errorName(failure);
        const count = @min(name.len, self.inspector_error.len - 1);
        @memcpy(self.inspector_error[0..count], name[0..count]);
    }
    fn applySession(self: *Context) !bool {
        self.choose(.apply);
        return false;
    }
    fn cancelSession(self: *Context) !void {
        self.choose(.cancel);
    }
    fn resolvePending(self: *Context, apply_edits: bool) !void {
        self.choose(if (apply_edits) .resolve_apply else .resolve_discard);
    }
    fn finishClose(self: *Context, save: bool) !void {
        self.choose(if (save) .save_close else .discard_close);
    }
    fn chordDrop(self: *Context, data: *dvui.WidgetData, held: bool, _: ?usize) void {
        const chord = self.drag_chord orelse return;
        if (!dvui.dragName("key_chord")) return;
        for (dvui.events()) |*event| {
            if (!dvui.eventMatch(event, .{ .id = data.id, .r = data.borderRectScale().r, .drag_name = "key_chord" })) continue;
            if (event.evt != .mouse) continue;
            const mouse = event.evt.mouse;
            if (mouse.action == .position) data.focusBorder();
            if (mouse.action == .release and mouse.button == .left) {
                event.handle(@src(), data);
                dvui.dragEnd();
                self.drag_chord = null;
                if (held) {
                    if (chord.tap_keycode < 224 or chord.tap_keycode > 231) {
                        self.reportInspector(error.HoldRequiresModifier);
                        return;
                    }
                    self.edit_session.?.toggleModifier(.hold, @intCast(chord.tap_keycode - 224));
                } else self.edit_session.?.mutate(.{ .tap_key = chord });
            }
        }
    }
};
pub fn draw(session: *editing.Session, model: *const desktop.model.Model, view: *View, theme: ui.Theme, light: bool) !?Action {
    if (try session.stale(model)) return error.StaleSession;
    var context = Context{ .model = model.*, .edit_session = session.*, .inspector_state = view.state, .search = view.search, .inspector_error = view.diagnostic, .pending = if (view.pending) 1 else null, .close_requested = view.close_requested, .light = light, .drag_chord = view.drag_chord, .resolver = view.keycap };
    defer {
        view.state = context.inspector_state;
        view.search = context.search;
        view.diagnostic = context.inspector_error;
        view.pending = context.pending != null;
        view.close_requested = context.close_requested;
        view.drag_chord = context.drag_chord;
    }
    try retainedDraw(&context, theme);
    return if (context.intent == .none) null else try Action.capture(session, model, context.intent);
}

fn caption(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .expand = .horizontal, .font = fonts.font(text, 13), .id_extra = std.hash.Wyhash.hash(0, text) });
}
fn fieldMixed(self: anytype, comptime part: []const u8, comptime field: []const u8) bool {
    const session = &self.edit_session.?;
    const primary = forms.Draft.from(session.first() orelse session.resolved[session.primary]);
    const value = @field(@field(primary, part), field);
    for (session.selected, session.drafts, session.resolved) |selected, action, resolved| {
        if (!selected) continue;
        const draft = forms.Draft.from(action orelse resolved);
        if (!std.meta.eql(value, @field(@field(draft, part), field))) return true;
    }
    return false;
}
fn chip(self: anytype, text: []const u8, tag: []const u8, operation: editing.Operation) void {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = std.hash.Wyhash.hash(0, tag), .padding = .all(2) });
    defer row.deinit();
    dvui.labelNoFmt(@src(), text, .{}, .{ .expand = .horizontal, .background = true, .padding = .all(5), .corners = .all(5), .font = fonts.font(text, 13) });
    if (dvui.button(@src(), "×", .{}, .{ .tag = tag, .min_size_content = .{ .w = 28, .h = 28 }, .id_extra = std.hash.Wyhash.hash(0, tag) })) self.edit_session.?.mutate(operation);
}
fn modifierButtons(self: anytype, target: editing.ModifierTarget) void {
    const names = switch (labels.running_host) {
        .macos => [_][]const u8{ "L ⌃", "L ⇧", "L ⌥", "L ⌘", "R ⌃", "R ⇧", "R ⌥", "R ⌘" },
        .windows => [_][]const u8{ "L Ctrl", "L Shift", "L Alt", "L Win", "R Ctrl", "R Shift", "R Alt", "R Win" },
        .linux => [_][]const u8{ "L Ctrl", "L Shift", "L Alt", "L Super", "R Ctrl", "R Shift", "R Alt", "R Super" },
    };
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{}, .padding = .{} });
        defer row.deinit();
        inline for (0..8) |bit| {
            const state = self.edit_session.?.modifierState(target, bit);
            const text = if (state == .mixed) std.fmt.allocPrint(dvui.currentWindow().arena(), "− {s}", .{names[bit]}) catch unreachable else names[bit];
            const tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "inspector.modifier.{s}.{d}", .{ @tagName(target), bit }) catch unreachable;
            if (dvui.button(@src(), text, .{}, .{ .tag = tag, .id_extra = bit, .expand = .horizontal, .padding = .all(4), .margin = .all(1), .font = fonts.font(text, 12), .color_fill = .{ .color = if (state == .on) ui.color(0x126AFF) else ui.Theme.get(self.light).control } })) self.edit_session.?.toggleModifier(target, bit);
        }
    }
}
fn card(self: anytype, held: bool) void {
    const session = &self.edit_session.?;
    const target: catalog.Target = if (held) .hold else .tap;
    const t = ui.Theme.get(self.light);
    const box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .id_extra = if (held) 2 else 1, .background = true, .color_fill = .{ .color = t.control }, .border = .all(1), .corners = .all(9), .padding = .all(7), .margin = .{ .h = 8 } });
    defer box.deinit();
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var data: dvui.WidgetData = undefined;
        if (dvui.button(@src(), if (held) "Hold" else "Tap", .{}, .{ .tag = if (held) "inspector.hold" else "inspector.tap", .data_out = &data, .expand = .horizontal })) self.inspector_state.target = target;
        self.chordDrop(&data, held, null);
        if (dvui.button(@src(), "Clear", .{}, .{ .tag = if (held) "inspector.clear.hold" else "inspector.clear.tap" })) session.mutate(if (held) .clear_hold else .clear_tap);
        if (dvui.button(@src(), "+ Action", .{}, .{ .tag = if (held) "inspector.add.hold" else "inspector.add.tap" })) self.inspector_state.target = target;
    }
    var buffer: [512]u8 = undefined;
    var draft = forms.Draft.from(session.first() orelse session.resolved[session.primary]);
    // Display each populated schema field even when the primary key lacks it.
    for (session.selected, session.drafts, session.resolved) |selected, action, resolved| {
        if (!selected) continue;
        const other = forms.Draft.from(action orelse resolved);
        inline for (.{ "key_press", "one_shot", "media_key", "mouse_action", "custom" }) |field| if (@field(draft.tap, field) == null) {
            @field(draft.tap, field) = @field(other.tap, field);
        };
        inline for (.{ "layer_id", "custom" }) |field| if (@field(draft.hold, field) == null) {
            @field(draft.hold, field) = @field(other.hold, field);
        };
        draft.hold.hold_modifiers = @bitCast(draft.hold.hold_modifiers.toByte() | other.hold.hold_modifiers.toByte());
    }
    if (held) {
        const value = draft.hold;
        if (value.hold_modifiers.toByte() != 0) chip(self, if (fieldMixed(self, "hold", "hold_modifiers")) "Mixed modifiers" else labels.hostModifierNames(labels.runningHost(), value.hold_modifiers.toByte(), &buffer), "inspector.remove.hold.modifiers", .{ .hold_modifiers = .{} });
        if (value.layer_id) |id| chip(self, if (fieldMixed(self, "hold", "layer_id")) "Mixed layers" else catalog.label(.{ .layer = id }, self.model.document(), &buffer), "inspector.remove.hold.layer", .{ .hold_layer = null });
        if (value.custom) |id| chip(self, if (fieldMixed(self, "hold", "custom")) "Mixed callbacks" else labels.signal(id, &buffer), "inspector.remove.hold.callback", .{ .hold_custom = null });
        if (value.hold_modifiers.toByte() == 0 and value.layer_id == null and value.custom == null) caption("No hold");
        modifierButtons(self, .hold);
    } else {
        const value = draft.tap;
        if (value.key_press) |key| chip(self, if (fieldMixed(self, "tap", "key_press")) "Mixed key / chord" else self.keycap(.{ .tap_only = .{ .key_press = key } }, &buffer), "inspector.remove.tap.key", .{ .tap_key = null });
        if (value.one_shot) |one| chip(self, if (fieldMixed(self, "tap", "one_shot")) "Mixed one-shot" else std.fmt.allocPrint(dvui.currentWindow().arena(), "One-shot · {s}", .{labels.hold(one, self.model.document(), &buffer)}) catch unreachable, "inspector.remove.tap.one_shot", .{ .tap_one_shot = null });
        if (value.media_key) |media| chip(self, if (fieldMixed(self, "tap", "media_key")) "Mixed media" else @tagName(media), "inspector.remove.tap.media", .{ .tap_media = null });
        if (value.mouse_action) |mouse| chip(self, if (fieldMixed(self, "tap", "mouse_action")) "Mixed mouse" else @tagName(mouse), "inspector.remove.tap.mouse", .{ .tap_mouse = null });
        if (value.custom) |id| chip(self, if (fieldMixed(self, "tap", "custom")) "Mixed callbacks" else labels.signal(id, &buffer), "inspector.remove.tap.callback", .{ .tap_custom = null });
        if (value.key_press == null and value.one_shot == null and value.media_key == null and value.mouse_action == null and value.custom == null) caption("No tap");
        modifierButtons(self, .tap);
    }
}
fn number(self: anytype, comptime T: type, title: []const u8, value: *T, comptime operation: []const u8) void {
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = std.hash.Wyhash.hash(0, title) });
    defer row.deinit();
    dvui.labelNoFmt(@src(), title, .{}, .{ .expand = .horizontal });
    if (dvui.textEntryNumber(@src(), T, .{ .value = value }, .{ .min_size_content = .{ .w = 100, .h = 30 } }).changed) self.edit_session.?.mutate(@unionInit(editing.Operation, operation, value.*));
}
pub fn add(self: anytype, entry: catalog.Entry) void {
    const session = &self.edit_session.?;
    const held = self.inspector_state.target == .hold;
    switch (entry) {
        .key => |code| session.mutate(.{ .tap_usage = code }),
        .modifier => |bit| session.toggleModifier(if (held) .hold else .tap, @intCast(bit)),
        .layer => |id| session.mutate(.{ .hold_layer = id }),
        .media => |value| session.mutate(.{ .tap_media = value }),
        .mouse => |value| session.mutate(.{ .tap_mouse = value }),
        .callback => |id| session.mutate(if (held) .{ .hold_custom = id } else .{ .tap_custom = id }),
        .signal => |id| session.mutate(if (held) .{ .hold_custom = id } else .{ .tap_custom = id }),
        .one_shot => session.mutate(.{ .tap_one_shot = .{} }),
    }
}
fn retainedDraw(self: anytype, t: ui.Theme) !void {
    try self.ensureSession();
    const box = ui.panel(t, .inspector);
    defer box.deinit();
    const session = &self.edit_session.?;
    const arena = dvui.currentWindow().arena();
    const before = try arena.dupe(?p.Action, session.drafts);
    ui.label(t, "Key inspector", .{ .x = 18, .y = 18, .w = 225, .h = 26 }, 20);
    if (ui.button(t, "Copy", "edit.copy", .{ .x = 284, .y = 14, .w = 62, .h = 34 })) try self.request(.copy);
    if (ui.button(t, "Paste", "edit.paste", .{ .x = 352, .y = 14, .w = 70, .h = 34 })) try self.request(.paste);
    var buffer: [512]u8 = undefined;
    _ = ui.button(t, self.keycap(session.first() orelse session.resolved[session.primary], &buffer), "inspector.preview", .{ .x = 18, .y = 64, .w = 80, .h = 66 });
    ui.label(t, self.model.document().key_ids[self.model.primary], .{ .x = 111, .y = 65, .w = 300, .h = 22 }, 15);
    var count: usize = 0;
    for (session.selected) |selected| if (selected) {
        count += 1;
    };
    ui.label(t, try std.fmt.allocPrint(arena, "{s} · {d} selected", .{ self.model.document().layers[self.model.layer].name, count }), .{ .x = 111, .y = 94, .w = 300, .h = 22 }, 13);
    var mixed = false;
    for (session.selected, session.drafts) |selected, action| if (selected and !std.meta.eql(action, session.first())) {
        mixed = true;
    };
    const stored = session.first();
    const status = if (mixed) "Mixed assignments" else if (stored == null) if (session.source_layers[session.primary]) |id| try std.fmt.allocPrint(arena, "Inherited · source layer {d}", .{id}) else "Inherited · no lower assignment" else if (stored.? == .none) "Unassigned · do nothing" else "Custom assignment";
    ui.label(t, status, .{ .x = 18, .y = 141, .w = 405, .h = 22 }, 13);
    {
        const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 14, .y = 175, .w = 412, .h = if (self.pending != null or self.close_requested) 589 else 653 }, .padding = .all(4) });
        defer area.deinit();
        const draft = forms.Draft.from(session.first() orelse session.resolved[session.primary]);
        var mode: usize = if (session.first() == null or session.first().? == .none) 0 else switch (draft.mode) {
            2 => 1,
            3 => 2,
            4 => 3,
            5 => 4,
            else => 0,
        };
        if (dvui.dropdown(@src(), &.{ "Add an action…", "Tap", "Hold", "Tap / Hold", "Repeat" }, .{ .choice = &mode }, .{}, .{ .expand = .horizontal, .tag = "inspector.mode" })) if (mode > 0) {
            var removes = false;
            for (session.selected, 0..) |selected, index| if (selected) {
                const action = session.drafts[index] orelse session.resolved[index];
                removes = removes or ((mode == 1 or mode == 4) and !editing.holdEmpty(editing.holdPart(action))) or (mode == 2 and !editing.tapEmpty(editing.tapPart(action)));
            };
            self.inspector_state.conversion = removes;
            self.inspector_state.removal_summary = if (mode == 2) "Mode change removes Tap components" else "Mode change removes Hold components";
            session.mutate(.{ .mode = @fromBackingInt(@intCast(mode - 1)) });
        };
        card(self, false);
        card(self, true);
        if (draft.mode == 4) {
            var value = draft.term;
            number(self, u16, "Tapping term (ms)", &value, "tapping_term");
        }
        if (draft.mode == 5) {
            var initial = draft.initial;
            var interval = draft.repeat;
            number(self, u16, "Initial delay (ms)", &initial, "initial_delay");
            number(self, u16, "Repeat interval (ms)", &interval, "repeat_interval");
        }
        if (dvui.button(@src(), if (self.inspector_state.advanced) "Advanced -" else "Advanced +", .{}, .{ .expand = .horizontal, .tag = "inspector.advanced" })) self.inspector_state.advanced = !self.inspector_state.advanced;
        if (self.inspector_state.advanced) {
            if (draft.tap.key_press) |previous| {
                var code = previous.tap_keycode;
                const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                caption("HID usage");
                if (dvui.textEntryNumber(@src(), u8, .{ .value = &code }, .{ .min_size_content = .{ .w = 90, .h = 30 } }).changed) session.mutate(.{ .tap_usage = code });
                row.deinit();
                var dead = previous.dead;
                if (dvui.checkbox(@src(), &dead, "Dead-key chord", .{})) session.mutate(.{ .tap_dead = dead });
            }
            if (draft.mode == 4) {
                var retro = draft.retro;
                if (dvui.checkbox(@src(), &retro, "Retro tapping", .{})) session.mutate(.{ .retro_tapping = retro });
            }
            if (draft.tap.one_shot) |previous| {
                caption("One-shot modifiers");
                modifierButtons(self, .one_shot);
                var names: [16][]const u8 = undefined;
                names[0] = "No one-shot layer";
                var selected: usize = 0;
                for (self.model.document().layers, 0..) |layer, index| {
                    names[index + 1] = layer.name;
                    if (previous.layer_id == layer.id) selected = index + 1;
                }
                if (dvui.dropdown(@src(), names[0 .. self.model.document().layers.len + 1], .{ .choice = &selected }, .{}, .{ .expand = .horizontal })) session.mutate(.{ .one_shot_layer = if (selected == 0) null else self.model.document().layers[selected - 1].id });
                var custom = previous.custom != null;
                if (dvui.checkbox(@src(), &custom, "One-shot callback", .{})) session.mutate(.{ .one_shot_custom = if (custom) 1 else null });
                if (previous.custom) |id| {
                    var value = id;
                    number(self, u8, "One-shot callback ID", &value, "one_shot_custom");
                }
            }
            caption("Callback IDs come from attached sources. Reserved signals remain available in search.");
            if (draft.tap.custom) |id| {
                var value = id;
                number(self, u8, "Tap callback / signal ID", &value, "tap_custom");
            }
            if (draft.hold.custom) |id| {
                var value = id;
                number(self, u8, "Hold callback ID", &value, "hold_custom");
            }
        }
        caption(if (self.inspector_state.target == .tap) "Add to Tap" else "Add to Hold");
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &self.search }, .placeholder = "Search keys, symbols, layers…" }, .{ .expand = .horizontal, .tag = "inspector.search", .padding = .all(8) });
        entry.deinit();
        var category: usize = @backingInt(self.inspector_state.category);
        if (dvui.dropdown(@src(), &.{ "All", "Keys", "Modifiers", "Layers", "Media", "Mouse", "Callbacks", "One-shot", "Signals" }, .{ .choice = &category }, .{}, .{ .expand = .horizontal, .tag = "inspector.category" })) self.inspector_state.category = @fromBackingInt(@intCast(category));
        const results = dvui.scrollArea(@src(), .{}, .{ .min_size_content = .{ .w = 370, .h = 210 }, .max_size_content = .{ .w = 400, .h = 210 }, .expand = .horizontal });
        defer results.deinit();
        var entries: [48]catalog.Entry = undefined;
        const found = catalog.search(self.model.document(), self.inspector_state.target, self.inspector_state.category, std.mem.sliceTo(&self.search, 0), &entries);
        for (entries[0..found], 0..) |result, index| {
            const tag = try std.fmt.allocPrint(arena, "inspector.result.{d}", .{index});
            const text = catalog.label(result, self.model.document(), &buffer);
            if (dvui.button(@src(), text, .{}, .{ .tag = tag, .id_extra = index, .expand = .horizontal, .padding = .all(6), .font = fonts.font(text, 13) })) add(self, result);
        }
        if (found == 0) caption("No matching actions for this target");
    }
    for (before, session.drafts) |old, staged| if (!std.meta.eql(old, staged)) {
        self.inspector_error = @splat(0);
        break;
    };
    for (session.selected, session.originals, session.drafts) |selected, original, staged| {
        if (selected and original != null and original.? == .tap_with_autofire and staged != null and staged.? != .tap_with_autofire) {
            self.inspector_state.conversion = true;
            self.inspector_state.removal_summary = "Mode change removes Repeat delay and interval";
        }
    }
    var valid = true;
    session.validate(&self.model) catch |err| {
        valid = false;
        self.reportInspector(err);
    };
    if (self.pending != null) {
        ui.label(t, "Pending edits · resolve before continuing", .{ .x = 18, .y = 769, .w = 400, .h = 23 }, 13);
        if (ui.button(t, "Apply", "pending.apply", .{ .x = 18, .y = 797, .w = 110, .h = 32 })) try self.resolvePending(true);
        if (ui.button(t, "Discard", "pending.discard", .{ .x = 140, .y = 797, .w = 110, .h = 32 })) try self.resolvePending(false);
        if (ui.button(t, "Keep editing", "pending.keep", .{ .x = 262, .y = 797, .w = 156, .h = 32 })) {
            self.choose(.keep_editing);
            self.pending = null;
        }
    } else if (self.close_requested) {
        ui.label(t, "Unsaved project · save before closing", .{ .x = 18, .y = 769, .w = 400, .h = 23 }, 13);
        if (ui.button(t, "Save and close", "close.save", .{ .x = 18, .y = 797, .w = 125, .h = 32 })) self.finishClose(true) catch |err| self.reportInspector(err);
        if (ui.button(t, "Close", "close.discard", .{ .x = 150, .y = 797, .w = 100, .h = 32 })) self.finishClose(false) catch |err| self.reportInspector(err);
        if (ui.button(t, "Keep editing", "close.keep", .{ .x = 262, .y = 797, .w = 156, .h = 32 })) {
            self.choose(.keep_close);
            self.close_requested = false;
        }
    }
    if (self.inspector_state.conversion) ui.label(t, self.inspector_state.removal_summary, .{ .x = 18, .y = 839, .w = 405, .h = 20 }, 11);
    if (self.inspector_error[0] != 0) ui.label(t, std.mem.sliceTo(&self.inspector_error, 0), .{ .x = 18, .y = 839, .w = 405, .h = 24 }, 11);
    if (ui.button(t, "Unassign", "inspector.unassign", .{ .x = 18, .y = 869, .w = 94, .h = 35 })) session.mutate(.unassign);
    if (ui.buttonEnabled(t, "Inherit", "inspector.inherit", .{ .x = 119, .y = 869, .w = 85, .h = 35 }, self.model.layer > 0)) session.mutate(.inherit);
    if (ui.button(t, "Cancel", "advanced.cancel", .{ .x = 211, .y = 869, .w = 82, .h = 35 })) try self.cancelSession();
    const apply_caption = try std.fmt.allocPrint(arena, "Apply ({d})", .{count});
    if (ui.buttonEnabled(t, apply_caption, "advanced.apply", .{ .x = 300, .y = 869, .w = 122, .h = 35 }, session.dirty() and valid)) _ = self.applySession() catch |err| {
        self.reportInspector(err);
    };
    ui.label(t, "Do nothing", .{ .x = 18, .y = 909, .w = 95, .h = 16 }, 10);
    ui.label(t, if (self.model.layer == 0) "Base has no lower layer" else "Lower active layer", .{ .x = 119, .y = 909, .w = 180, .h = 16 }, 10);
}
