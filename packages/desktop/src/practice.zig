//! Hardware-free, bounded Unicode copy practice. Times are monotonic microseconds.
const std = @import("std");
pub const State = enum { ready, running, paused, complete };
pub const Source = enum { os, draft };
pub const lessons = [_][]const u8{
    \\const std = @import("std");
    \\
    \\fn twice(value: i32) i32 {
    \\    return value * 2;
    \\}
    \\
    \\fn distance(a: i32, b: i32) u32 {
    \\    return @intCast(@abs(a - b));
    \\}
    \\
    \\test "small functions" {
    \\    try std.testing.expectEqual(@as(i32, 14), twice(7));
    \\    try std.testing.expectEqual(@as(i32, -6), twice(-3));
    \\    try std.testing.expectEqual(@as(u32, 9), distance(2, 11));
    \\    try std.testing.expectEqual(@as(u32, 0), distance(4, 4));
    \\}
    \\
    ,
    \\const std = @import("std");
    \\
    \\const Scores = struct {
    \\    values: [4]u16,
    \\
    \\    fn total(self: Scores) u32 {
    \\        var sum: u32 = 0;
    \\        for (self.values) |value| {
    \\            sum += value;
    \\        }
    \\        return sum;
    \\    }
    \\};
    \\
    \\test "sum an array" {
    \\    const scores = Scores{ .values = .{ 3, 5, 8, 13 } };
    \\    try std.testing.expectEqual(@as(u32, 29), scores.total());
    \\}
    \\
    ,
    \\const std = @import("std");
    \\
    \\fn readCount(text: ?[]const u8) !u16 {
    \\    const value = text orelse return error.MissingCount;
    \\    return std.fmt.parseInt(u16, value, 10);
    \\}
    \\
    \\fn defaultCount(text: ?[]const u8) u16 {
    \\    return readCount(text) catch 1;
    \\}
    \\
    \\test "optional input and errors" {
    \\    try std.testing.expectEqual(@as(u16, 12), try readCount("12"));
    \\    try std.testing.expectError(error.MissingCount, readCount(null));
    \\    try std.testing.expectEqual(@as(u16, 1), defaultCount(null));
    \\    try std.testing.expectEqual(@as(u16, 1), defaultCount("bad"));
    \\}
    \\
};
pub const lesson_names = [_][]const u8{ "Functions and tests", "Arrays and a struct", "Errors and optionals" };
pub const lesson_ids = [_][]const u8{ "functions-v1", "arrays-v1", "errors-v1" };
pub const compiler_version = "0.16.0";
pub const corpus_version = 1;
pub const Session = struct {
    reference: [8192]u21 = undefined,
    reference_len: usize = 0,
    typed: [8192]u21 = undefined,
    len: usize = 0,
    state: State = .ready,
    source: Source = .os,
    attempts: usize = 0,
    correct_attempts: usize = 0,
    corrected: usize = 0,
    errors: [8192]u32 = @splat(0),
    scored: bool = true,
    started: ?u64 = null,
    segment: u64 = 0,
    active_us: u64 = 0,
    ended: u64 = 0,
    previous_cr: bool = false,
    pub fn load(self: *Session, bytes: []const u8, source: Source) !void {
        var view = try std.unicode.Utf8View.init(bytes);
        var it = view.iterator();
        var count: usize = 0;
        while (it.nextCodepoint()) |cp| {
            if (count == self.reference.len) return error.ExerciseTooLong;
            self.reference[count] = cp;
            count += 1;
        }
        self.reference_len = count;
        self.source = source;
        self.restart();
    }
    pub fn restart(self: *Session) void {
        self.len = 0;
        self.state = .ready;
        self.attempts = 0;
        self.correct_attempts = 0;
        self.corrected = 0;
        self.errors = @splat(0);
        self.scored = true;
        self.started = null;
        self.active_us = 0;
        self.ended = 0;
        self.previous_cr = false;
    }
    pub fn insert(self: *Session, bytes: []const u8, now: u64, paste: bool) !void {
        if (self.state == .paused or self.state == .complete) return;
        var view = try std.unicode.Utf8View.init(bytes);
        var it = view.iterator();
        if (paste) self.scored = false;
        while (it.nextCodepoint()) |raw| {
            if (raw == '\n' and self.previous_cr) {
                self.previous_cr = false;
                continue;
            }
            self.previous_cr = raw == '\r';
            const cp: u21 = if (raw == '\r') '\n' else raw;
            if (self.len == self.typed.len) return error.TextLimit;
            if (self.state == .ready) {
                self.state = .running;
                self.started = now;
                self.segment = now;
            }
            self.attempts += 1;
            if (self.len < self.reference_len and self.reference[self.len] == cp) {
                self.correct_attempts += 1;
            } else if (self.len < self.reference_len) {
                const first = std.mem.indexOfScalar(u21, self.reference[0..self.reference_len], self.reference[self.len]).?;
                self.errors[first] += 1;
            }
            self.typed[self.len] = cp;
            self.len += 1;
            if (self.len == self.reference_len and std.mem.eql(u21, self.typed[0..self.len], self.reference[0..self.reference_len])) {
                self.active_us += now -| self.segment;
                self.ended = now;
                self.state = .complete;
                break;
            }
        }
    }
    pub fn backspace(self: *Session) void {
        if (self.len == 0 or self.state == .paused or self.state == .complete) return;
        self.len -= 1;
        self.previous_cr = false;
        if (self.len >= self.reference_len or self.typed[self.len] != self.reference[self.len]) self.corrected += 1;
    }
    pub fn pause(self: *Session, now: u64) void {
        if (self.state == .complete or self.state == .paused) return;
        if (self.state == .running) self.active_us += now -| self.segment;
        self.state = .paused;
    }
    pub fn resumeRun(self: *Session, now: u64) void {
        if (self.state != .paused) return;
        self.state = if (self.started == null) .ready else .running;
        self.segment = now;
    }
    pub fn duration(self: *const Session, now: u64) u64 {
        return self.active_us + if (self.state == .running) now -| self.segment else 0;
    }
    pub fn matched(self: *const Session) usize {
        var count: usize = 0;
        for (self.typed[0..@min(self.len, self.reference_len)], self.reference[0..@min(self.len, self.reference_len)]) |a, b| {
            count += @intFromBool(a == b);
        }
        return count;
    }
    pub fn wpm(self: *const Session, now: u64) f64 {
        const us = self.duration(now);
        return if (us == 0) 0 else @as(f64, @floatFromInt(self.matched())) * 12_000_000 / @as(f64, @floatFromInt(us));
    }
    pub fn accuracy(self: *const Session) f64 {
        return if (self.attempts == 0) 100 else 100 * @as(f64, @floatFromInt(self.correct_attempts)) / @as(f64, @floatFromInt(self.attempts));
    }
};
pub fn english(buffer: []u8, seed: u64, length: usize) ![]const u8 {
    var random = std.Random.DefaultPrng.init(seed);
    const rng = random.random();
    const subjects = [_][]const u8{ "The quiet gardener", "A curious student", "The friendly baker", "A patient artist", "The young sailor", "A cheerful neighbor", "The careful teacher", "A busy writer" };
    const verbs = [_][]const u8{ "finds", "carries", "chooses", "shares", "keeps", "brings", "collects", "notices" };
    const objects = [_][]const u8{ "a small notebook", "a bright flower", "a fresh apple", "a wooden box", "a warm blanket", "a smooth stone", "a red umbrella", "a useful map" };
    const endings = [_][]const u8{ "near the old bridge", "before the evening rain", "beside the open window", "on a sunny morning", "after a long walk", "under the tall tree" };
    var writer: std.Io.Writer = .fixed(buffer);
    var previous_subject: usize = subjects.len;
    var previous_ending: usize = endings.len;
    for (0..length) |i| {
        var subject = rng.uintLessThan(usize, subjects.len);
        if (subject == previous_subject) subject = (subject + 1) % subjects.len;
        var ending = rng.uintLessThan(usize, endings.len);
        if (ending == previous_ending) ending = (ending + 1) % endings.len;
        try writer.print("{s}{s} {s} {s} {s}.", .{ if (i == 0) "" else " ", subjects[subject], verbs[rng.uintLessThan(usize, verbs.len)], objects[rng.uintLessThan(usize, objects.len)], endings[ending] });
        previous_subject = subject;
        previous_ending = ending;
    }
    return writer.buffered();
}
test "Unicode corrections, pauses and literal scoring" {
    var s: Session = .{};
    try s.load("é a\n", .os);
    try s.insert("é", 1_000_000, false);
    try std.testing.expectEqual(@as(f64, 0), s.wpm(1_000_000));
    try s.insert("x", 2_000_000, false);
    s.backspace();
    try s.insert(" ", 3_000_000, false);
    s.pause(4_000_000);
    try s.insert("ignored", 9_000_000, false);
    s.resumeRun(10_000_000);
    try s.insert("a\r\n", 11_000_000, false);
    try std.testing.expectEqual(State.complete, s.state);
    try std.testing.expectEqual(@as(u64, 4_000_000), s.duration(99_000_000));
    try std.testing.expectEqual(@as(f64, 12), s.wpm(99_000_000));
    try std.testing.expectEqual(@as(f64, 80), s.accuracy());
    try std.testing.expectEqual(@as(usize, 1), s.corrected);
    s.restart();
    try s.insert("é a\n", 1, true);
    try std.testing.expect(!s.scored);
}
test "English seed reproducibility and length" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const first = try english(&a, 42, 5);
    try std.testing.expectEqualStrings(first, try english(&b, 42, 5));
    try std.testing.expect(!std.mem.eql(u8, first, try english(&b, 43, 5)));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, first, "."));
}

test "ready pauses, UTF-8 validation and split CRLF preserve character attempts" {
    var s: Session = .{};
    try s.load("a\nb", .os);
    try s.insert("", 10, false);
    try std.testing.expect(s.started == null);
    s.pause(20);
    s.resumeRun(30);
    try std.testing.expectEqual(State.ready, s.state);
    try std.testing.expectError(error.InvalidUtf8, s.insert("\xff", 40, false));
    try s.insert("a\r", 50, false);
    try s.insert("\nb", 60, false);
    try std.testing.expectEqual(State.complete, s.state);
    try std.testing.expectEqual(@as(usize, 3), s.attempts);
}

test "errors aggregate by expected character and full wrong text requires correction" {
    var s: Session = .{};
    try s.load("aa", .os);
    try s.insert("xx", 10, false);
    try std.testing.expectEqual(State.running, s.state);
    try std.testing.expectEqual(@as(u32, 2), s.errors[0]);
    s.backspace();
    s.backspace();
    try s.insert("aa", 20, false);
    try std.testing.expectEqual(State.complete, s.state);
    try std.testing.expectEqual(@as(f64, 50), s.accuracy());
}

/// Project/cache adapters supply only proven literal labels. Never infer text
/// from callback or dead-key captions. Modifier bytes use USB modifier bits.
pub const Label = struct {
    text: ?[]const u8 = null,
    hid_code: ?u8 = null,
    dead: bool = false,
    shortcut: bool = false,
    hold_layer: ?usize = null,
    hold_modifiers: ?u8 = null,
};
pub const Labels = struct {
    context: *const anyopaque,
    key_count: usize,
    layer_count: usize,
    lookup: *const fn (*const anyopaque, usize, usize, u8, u16) Label,
    pub fn validate(self: Labels) !void {
        if (self.key_count == 0 or self.layer_count == 0 or self.layer_count > 16) return error.InvalidDimensions;
    }
    fn get(self: Labels, layer: usize, key: usize, mods: u8, active: u16) Label {
        return self.lookup(self.context, layer, key, mods, active);
    }
};
pub const Hint = struct { layer: usize, key: usize, modifiers: u8 };
pub const KeyMetadata = struct { hand: enum { left, right, neutral } = .neutral, thumb: bool = false };
/// Every output slot is in the caller's board processing-index order.
pub const Guidance = struct {
    tap: []bool,
    hold: []bool,
    fn reset(self: Guidance, count: usize) !void {
        if (self.tap.len != count or self.hold.len != count) return error.InvalidDimensions;
        @memset(self.tap, false);
        @memset(self.hold, false);
    }
};
fn layerMask(layer: usize) u16 {
    return 1 | (@as(u16, 1) << @intCast(layer));
}
fn matches(entry: Label, cp: u21) bool {
    if (entry.dead or entry.shortcut) return false;
    if (entry.hid_code) |code| {
        if ((cp == '\n' and code == 40) or (cp == '\t' and code == 43) or (cp == ' ' and code == 44)) return true;
    }
    const text = entry.text orelse return false;
    var buffer: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buffer) catch return false;
    return std.mem.eql(u8, text, buffer[0..n]);
}
pub fn hint(labels: Labels, layer: usize, modifiers: u8, cp: u21, active: u16) !?Hint {
    try labels.validate();
    if (layer >= labels.layer_count) return error.InvalidLayer;
    const variants = [_]u8{ modifiers, 0, 2, 4, 6 };
    for (0..labels.layer_count) |offset| {
        const candidate = (layer + offset) % labels.layer_count;
        for (variants) |mods| {
            if (mods & 0x99 != 0) continue;
            for (0..labels.key_count) |key| {
                if (matches(labels.get(candidate, key, mods, if (candidate == layer) active else layerMask(candidate)), cp)) return .{ .layer = candidate, .key = key, .modifiers = mods };
            }
        }
    }
    return null;
}
pub fn guidance(labels: Labels, metadata: ?[]const KeyMetadata, layer: usize, modifiers: u8, next: ?Hint, output: Guidance) !void {
    try labels.validate();
    if (layer >= labels.layer_count) return error.InvalidLayer;
    if (metadata) |keys| if (keys.len != labels.key_count) {
        return error.InvalidDimensions;
    };
    try output.reset(labels.key_count);
    const needed = next orelse return;
    if (needed.layer >= labels.layer_count or needed.key >= labels.key_count) return error.InvalidHint;
    output.tap[needed.key] = true;
    if (needed.layer != layer) {
        for (0..labels.key_count) |key| {
            const entry = labels.get(layer, key, modifiers, layerMask(layer));
            if (entry.hold_layer) |held| if (held == needed.layer and key != needed.key) {
                output.hold[key] = true;
                break;
            };
        }
    }
    var missing = needed.modifiers & ~modifiers;
    if (modifiers & 0x22 != 0) missing &= ~@as(u8, 0x22);
    for (0..8) |bit| {
        const flag = @as(u8, 1) << @intCast(bit);
        if (missing & flag == 0) continue;
        var best: ?usize = null;
        var best_score: usize = 0;
        for (0..labels.key_count) |key| {
            if (key == needed.key) continue;
            const entry = labels.get(layer, key, modifiers, layerMask(layer));
            const held = entry.hold_modifiers orelse if (entry.hid_code) |code| (if (code >= 224 and code <= 231) @as(u8, 1) << @intCast(code - 224) else 0) else 0;
            const accepted = if (flag & 0x22 != 0) @as(u8, 0x22) else flag;
            if (held & accepted == 0) continue;
            var score: usize = 1;
            if (metadata) |keys| {
                if (keys[key].hand != keys[needed.key].hand and keys[key].hand != .neutral) score += 4;
                if (!keys[key].thumb) score += 2;
            }
            if (score > best_score) {
                best = key;
                best_score = score;
            }
        }
        if (best) |key| output.hold[key] = true;
    }
}

const GuidanceFixture = struct {
    fn lookup(_: *const anyopaque, layer: usize, key: usize, mods: u8, _: u16) Label {
        return switch (key) {
            0 => if (layer == 0) .{ .text = if (mods & 0x22 != 0) "A" else "a" } else .{},
            1 => .{ .hold_layer = 1 },
            2 => .{ .hold_modifiers = 2 },
            3, 4 => .{ .hold_modifiers = 32 },
            129 => if (layer == 1) .{ .text = "!" } else .{},
            128 => .{ .text = "´", .dead = true },
            127 => .{ .text = " ", .hid_code = 44, .shortcut = true },
            else => .{},
        };
    }
};
test "guidance follows board dimensions beyond 128 keys and injected hand metadata" {
    const t = std.testing;
    var context: u8 = 0;
    const labels: Labels = .{ .context = &context, .key_count = 130, .layer_count = 2, .lookup = GuidanceFixture.lookup };
    var taps: [130]bool = undefined;
    var holds: [130]bool = undefined;
    const output: Guidance = .{ .tap = &taps, .hold = &holds };
    var keys: [130]KeyMetadata = @splat(.{});
    keys[0].hand = .left;
    keys[2].hand = .left;
    keys[3].hand = .right;
    keys[4] = .{ .hand = .right, .thumb = true };
    const capital = (try hint(labels, 0, 0, 'A', 1)).?;
    try guidance(labels, &keys, 0, 0, capital, output);
    try t.expect(taps[0] and holds[3]);
    try t.expect(!holds[2] and !holds[4]);
    try guidance(labels, &keys, 0, 32, capital, output);
    try t.expect(!holds[2] and !holds[3]);
    const punctuation = (try hint(labels, 0, 0, '!', 1)).?;
    try t.expectEqual(@as(usize, 129), punctuation.key);
    try guidance(labels, null, 0, 0, punctuation, output);
    try t.expect(taps[129] and holds[1]);
    try t.expect((try hint(labels, 0, 0, '´', 1)) == null);
    try t.expect((try hint(labels, 0, 0, ' ', 1)) == null);
    try t.expectError(error.InvalidDimensions, guidance(labels, null, 0, 0, punctuation, .{ .tap = taps[0..128], .hold = &holds }));
    try t.expectError(error.InvalidHint, guidance(labels, null, 0, 0, .{ .layer = 1, .key = 130, .modifiers = 0 }, output));
}

test "lesson corpus remains original text and bounded exercise scoring uses injected times" {
    const t = std.testing;
    const hashes = [_][]const u8{
        "c8039baa381495a184f8679808e4daacb7b9bc7adf19bb0ea75f7eb9540c4caf",
        "86366a94d88ed55d88b1733fbf415cf2da109d17c476843d4b6e081215956b79",
        "38342ac2998b6acccd50c8bd8eca81cf8bee06144fe61d496add32521b96164e",
    };
    for (lessons, hashes) |lesson, expected| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(lesson, &hash, .{});
        try t.expectEqualStrings(expected, &std.fmt.bytesToHex(hash, .lower));
        var session: Session = .{};
        try session.load(lesson, .draft);
        try session.insert(lesson, 123, false);
        try t.expectEqual(State.complete, session.state);
        try t.expectEqual(@as(f64, 100), session.accuracy());
        try t.expectEqual(@as(u64, 0), session.duration(999));
    }
    var session: Session = .{};
    const long: [8193]u8 = @splat('a');
    try t.expectError(error.ExerciseTooLong, session.load(&long, .os));
    try session.load("a", .os);
    try session.insert("x", 100, false);
    session.backspace();
    try session.insert("a", 50, false);
    try t.expectEqual(@as(u64, 0), session.duration(999));
    try t.expectEqual(@as(usize, 1), session.corrected);
}
