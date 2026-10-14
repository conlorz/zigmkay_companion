//! Frozen result records and comparable, weighted aggregation. No filesystem/UI.
const std = @import("std");
const practice = @import("practice.zig");
const generator = @import("practice_generator.zig");
pub const Assistance = enum { guided, layout_only, hidden };
pub const RunMode = enum { normal, challenge, drill };
pub const Scope = enum { this_run, last_ten, all_history };
pub const Route = struct { layer: u8 = 0, key: u16 = 0, modifiers: u8 = 0 };
pub const Stat = struct {
    cp: u21 = 0,
    opportunities: u64 = 0,
    misses: u64 = 0,
    retries: u64 = 0,
    routes: [4]Route = @splat(.{}),
    route_count: u8 = 0,
    routes_truncated: bool = false,
    pub fn rate(self: Stat) f64 {
        return if (self.opportunities == 0) 0 else 100 * @as(f64, @floatFromInt(self.misses)) / @as(f64, @floatFromInt(self.opportunities));
    }
    pub fn supportedWeakness(self: Stat) bool {
        return self.opportunities >= 5 and self.misses >= 2;
    }
    pub fn rank(self: Stat) f64 {
        return @as(f64, @floatFromInt(self.misses + 1)) / @as(f64, @floatFromInt(self.opportunities + 4));
    }
};
pub const Substitution = struct { expected: u21 = 0, typed: u21 = 0, count: u64 = 0 };
pub const Cohort = struct {
    behavior: [32]u8 = @splat(0),
    mapping: [32]u8 = @splat(0),
    verified: bool = false,
    source: practice.Source = .os,
    family: enum { english, zig } = .english,
    preset: generator.Preset = .words,
    length: u8 = 1,
    assistance: Assistance = .guided,
    mode: RunMode = .normal,
    metric_version: u16 = 1,
    generation_version: u16 = generator.version,
    lesson: u8 = 0,
};
pub const Record = struct {
    version: u16 = 1,
    id: [16]u8 = @splat(0),
    timestamp: i64 = 0,
    cohort: Cohort = .{},
    profile: [96]u8 = @splat(0),
    input_source: [96]u8 = @splat(0),
    seed: u64 = 0,
    layer_count: u8 = 1,
    key_count: u16 = 0,
    scored: bool = true,
    status: enum { completed, stopped } = .completed,
    timing_available: bool = false,
    timing_truncated: bool = false,
    active_us: u64 = 0,
    matched: u64 = 0,
    attempts: u64 = 0,
    correct_attempts: u64 = 0,
    corrections: u64 = 0,
    outside_errors: u64 = 0,
    stats: [256]Stat = @splat(.{}),
    stat_count: u16 = 0,
    substitutions: [256]Substitution = @splat(.{}),
    substitution_count: u16 = 0,
    substitutions_truncated: bool = false,
    targets: [5]u21 = @splat(0),
    target_count: u8 = 0,
    drill_policy: u16 = 1,
    pub fn validate(self: *const Record) !void {
        if ((self.status == .stopped and self.scored) or (self.timing_truncated and !self.timing_available)) return error.InvalidPracticeHistory;
        if (self.version != 1 or self.cohort.metric_version != 1 or self.cohort.generation_version != 1 or self.drill_policy != 1) return error.UnsupportedPracticeHistory;
        if (self.stat_count > 256 or self.substitution_count > 256 or self.target_count > 5 or self.correct_attempts > self.attempts) return error.InvalidPracticeHistory;
        for (self.targets[0..self.target_count]) |cp| if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return error.InvalidPracticeHistory;
        for (self.substitutions[0..self.substitution_count], 0..) |sub, index| {
            if (sub.expected > 0x10ffff or sub.typed > 0x10ffff or (sub.expected >= 0xd800 and sub.expected <= 0xdfff) or (sub.typed >= 0xd800 and sub.typed <= 0xdfff)) return error.InvalidPracticeHistory;
            for (self.substitutions[0..index]) |old| if (old.expected == sub.expected and old.typed == sub.typed) return error.InvalidPracticeHistory;
        }
        if (!std.unicode.utf8ValidateSlice(std.mem.sliceTo(&self.profile, 0)) or !std.unicode.utf8ValidateSlice(std.mem.sliceTo(&self.input_source, 0))) return error.InvalidPracticeHistory;
        var opportunities: u64 = 0;
        for (self.stats[0..self.stat_count], 0..) |stat, index| {
            if (stat.cp > 0x10ffff or (stat.cp >= 0xd800 and stat.cp <= 0xdfff) or stat.misses > stat.opportunities or stat.route_count > 4) return error.InvalidPracticeHistory;
            for (self.stats[0..index]) |previous| if (previous.cp == stat.cp) return error.InvalidPracticeHistory;
            for (stat.routes[0..stat.route_count]) |route| if (route.layer >= self.layer_count or route.key >= self.key_count or std.mem.indexOfScalar(u8, &practice.route_modifiers, route.modifiers) == null) return error.InvalidPracticeHistory;
            opportunities = std.math.add(u64, opportunities, stat.opportunities) catch return error.InvalidPracticeHistory;
        }
        if (opportunities != self.matched or self.matched > 8192 or self.cohort.length > 2 or self.cohort.lesson >= 3 or self.layer_count == 0 or self.layer_count > 15) return error.InvalidPracticeHistory;
    }
    pub fn wpm(self: *const Record) f64 {
        return if (self.active_us == 0) 0 else @as(f64, @floatFromInt(self.matched)) * 12_000_000 / @as(f64, @floatFromInt(self.active_us));
    }
    pub fn accuracy(self: *const Record) f64 {
        return if (self.attempts == 0) 100 else 100 * @as(f64, @floatFromInt(self.correct_attempts)) / @as(f64, @floatFromInt(self.attempts));
    }
};
pub fn capture(session: *const practice.Session, cohort: Cohort, labels: ?practice.Labels) !Record {
    if (session.state != .complete) return error.IncompletePractice;
    return captureMode(session, cohort, labels, false, session.active_us);
}
pub fn captureStopped(session: *const practice.Session, cohort: Cohort, labels: ?practice.Labels, now: u64) !Record {
    return captureMode(session, cohort, labels, true, session.duration(now));
}
fn captureMode(session: *const practice.Session, cohort: Cohort, labels: ?practice.Labels, stopped: bool, active_us: u64) !Record {
    const count = if (stopped) session.observed else session.reference_len;
    var result: Record = .{ .cohort = cohort, .scored = !stopped and session.scored, .status = if (stopped) .stopped else .completed, .timing_available = session.recorder != null, .timing_truncated = if (session.recorder) |recorder| recorder.dropped != 0 else false, .active_us = active_us, .matched = count, .attempts = session.attempts, .correct_attempts = session.correct_attempts, .corrections = session.corrected, .outside_errors = session.outside_errors };
    result.substitution_count = session.substitution_count;
    result.substitutions_truncated = session.substitutions_truncated;
    for (session.substitutions[0..session.substitution_count], 0..) |substitution, index| result.substitutions[index] = .{ .expected = substitution.expected, .typed = substitution.typed, .count = substitution.count };
    for (session.reference[0..count], 0..) |cp, position| {
        var index: usize = 0;
        while (index < result.stat_count and result.stats[index].cp != cp) : (index += 1) {}
        if (index == result.stat_count) {
            if (result.stat_count == 256) return error.TooManyResultCharacters;
            result.stats[index].cp = cp;
            result.stat_count += 1;
        }
        result.stats[index].opportunities += 1;
        result.stats[index].misses += @intFromBool(session.missed[position]);
        result.stats[index].retries += session.position_errors[position];
    }
    if (labels) |routes| {
        try routes.validate();
        result.layer_count = @intCast(routes.layer_count);
        result.key_count = @intCast(routes.key_count);
        for (result.stats[0..result.stat_count]) |*stat| {
            for (0..routes.layer_count) |layer| for (practice.route_modifiers) |mods| for (0..routes.key_count) |key| {
                if (!practice.matches(routes.get(layer, key, mods, practice.layerMask(layer)), stat.cp)) continue;
                // Equivalent modifier variants do not create duplicate routes.
                var duplicate = false;
                for (stat.routes[0..stat.route_count]) |route| if (route.layer == layer and route.key == key) {
                    duplicate = true;
                };
                if (duplicate) continue;
                if (stat.route_count == 4) {
                    stat.routes_truncated = true;
                    continue;
                }
                stat.routes[stat.route_count] = .{ .layer = @intCast(layer), .key = @intCast(key), .modifiers = mods };
                stat.route_count += 1;
            };
        }
    }
    try result.validate();
    return result;
}
pub const Aggregate = struct {
    runs: u64 = 0,
    active_us: u64 = 0,
    matched: u64 = 0,
    attempts: u64 = 0,
    correct_attempts: u64 = 0,
    corrections: u64 = 0,
    best_wpm: f64 = 0,
    substitutions: [256]Substitution = @splat(.{}),
    substitution_count: u16 = 0,
    substitutions_truncated: bool = false,
    stats: [256]Stat = @splat(.{}),
    stat_count: u16 = 0,
    pub fn add(self: *Aggregate, record: *const Record) !void {
        try record.validate();
        if (!record.scored) return;
        self.runs = try std.math.add(u64, self.runs, 1);
        self.active_us = try std.math.add(u64, self.active_us, record.active_us);
        self.matched = try std.math.add(u64, self.matched, record.matched);
        self.attempts = try std.math.add(u64, self.attempts, record.attempts);
        self.correct_attempts = try std.math.add(u64, self.correct_attempts, record.correct_attempts);
        self.corrections = try std.math.add(u64, self.corrections, record.corrections);
        self.best_wpm = @max(self.best_wpm, record.wpm());
        self.substitutions_truncated = self.substitutions_truncated or record.substitutions_truncated;
        for (record.substitutions[0..record.substitution_count]) |sub| {
            var index: usize = 0;
            while (index < self.substitution_count and !(self.substitutions[index].expected == sub.expected and self.substitutions[index].typed == sub.typed)) : (index += 1) {}
            if (index == 256) {
                self.substitutions_truncated = true;
                continue;
            }
            if (index == self.substitution_count) {
                self.substitutions[index] = sub;
                self.substitution_count += 1;
            } else self.substitutions[index].count = try std.math.add(u64, self.substitutions[index].count, sub.count);
        }
        for (record.stats[0..record.stat_count]) |stat| {
            var index: usize = 0;
            while (index < self.stat_count and self.stats[index].cp != stat.cp) : (index += 1) {}
            if (index == self.stat_count) {
                if (index == 256) return error.TooManyResultCharacters;
                self.stats[index] = stat;
                self.stat_count += 1;
            } else {
                const dest = &self.stats[index];
                dest.opportunities = try std.math.add(u64, dest.opportunities, stat.opportunities);
                dest.misses = try std.math.add(u64, dest.misses, stat.misses);
                dest.retries = try std.math.add(u64, dest.retries, stat.retries);
            }
        }
    }
    pub fn remove(self: *Aggregate, record: *const Record) void {
        if (!record.scored) return;
        self.runs -= 1;
        self.active_us -= record.active_us;
        self.matched -= record.matched;
        self.attempts -= record.attempts;
        self.correct_attempts -= record.correct_attempts;
        self.corrections -= record.corrections;
        for (record.substitutions[0..record.substitution_count]) |sub| for (self.substitutions[0..self.substitution_count]) |*dest| if (dest.expected == sub.expected and dest.typed == sub.typed) {
            dest.count -= sub.count;
        };
        for (record.stats[0..record.stat_count]) |stat| for (self.stats[0..self.stat_count]) |*dest| if (dest.cp == stat.cp) {
            dest.opportunities -= stat.opportunities;
            dest.misses -= stat.misses;
            dest.retries -= stat.retries;
        };
    }
    pub fn wpm(self: *const Aggregate) f64 {
        return if (self.active_us == 0) 0 else @as(f64, @floatFromInt(self.matched)) * 12_000_000 / @as(f64, @floatFromInt(self.active_us));
    }
    pub fn targets(self: *const Aggregate, output: *[5]u21) []const u21 {
        var candidates: [256]Stat = self.stats;
        std.mem.sort(Stat, candidates[0..self.stat_count], {}, struct {
            fn less(_: void, a: Stat, b: Stat) bool {
                return if (a.rank() == b.rank()) a.cp < b.cp else a.rank() > b.rank();
            }
        }.less);
        var count: usize = 0;
        for (candidates[0..self.stat_count]) |stat| {
            if (!stat.supportedWeakness() or practice_viewWhitespace(stat.cp)) continue;
            output[count] = stat.cp;
            count += 1;
            if (count == output.len) break;
        }
        return output[0..count];
    }
};
fn practice_viewWhitespace(cp: u21) bool {
    return cp == ' ' or cp == '\n' or cp == '\t';
}
test "distinct occurrences survive retries and weighted aggregation separates case" {
    const t = std.testing;
    var session: practice.Session = .{};
    try session.load(";;Aa", .os);
    try session.insert("x", 1, false);
    session.backspace();
    try session.insert("y", 2, false);
    session.backspace();
    try session.insert(";", 3, false);
    session.backspace();
    try session.insert("z", 4, false);
    session.backspace();
    try session.insert(";;Aa", 5, false);
    const record = try capture(&session, .{}, null);
    try t.expectEqual(@as(u64, 1), record.stats[0].misses);
    try t.expectEqual(@as(u64, 2), record.stats[0].opportunities);
    try t.expectEqual(@as(u64, 3), record.stats[0].retries);
    try t.expectEqual(@as(u16, 3), record.stat_count);
    var other: Record = .{ .matched = 18, .stat_count = 1 };
    other.stats[0] = .{ .cp = ';', .opportunities = 18, .misses = 1 };
    var sum: Aggregate = .{};
    try sum.add(&record);
    try sum.add(&other);
    try t.expectEqual(@as(f64, 10), sum.stats[0].rate());
    other.scored = false;
    try sum.add(&other);
    try t.expectEqual(@as(u64, 2), sum.runs);
}

/// Human-readable UTC labels; nanosecond timestamps retain same-second ordering.
pub fn dateLabel(timestamp: i64, buffer: []u8) ![]const u8 {
    if (timestamp < 0) return std.fmt.bufPrint(buffer, "unknown time", .{});
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(timestamp, 1_000_000_000)) };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ year.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}
test "history timestamps have readable UTC labels" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01 00:00:00 UTC", try dateLabel(0, &buffer));
}

test "corrupt substitution codepoints and duplicate pairs are rejected before rendering" {
    var record: Record = .{ .substitution_count = 1 };
    record.substitutions[0] = .{ .expected = ';', .typed = 0x110000, .count = 1 };
    try std.testing.expectError(error.InvalidPracticeHistory, record.validate());
    record.substitutions[0].typed = 'x';
    try record.validate();
    record.substitution_count = 2;
    record.substitutions[1] = record.substitutions[0];
    try std.testing.expectError(error.InvalidPracticeHistory, record.validate());
}

/// Bounded display metadata always ends at a UTF-8 codepoint boundary.
pub fn displayName(text: []const u8, buffer: *[96]u8) void {
    buffer.* = @splat(0);
    if (!std.unicode.utf8ValidateSlice(text)) {
        @memcpy(buffer[0..7], "Unknown");
        return;
    }
    var end = @min(text.len, buffer.len - 1);
    while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
    @memcpy(buffer[0..end], text[0..end]);
}
test "bounded Unicode profile names never split a codepoint" {
    var text: [96]u8 = undefined;
    for (0..48) |index| {
        text[index * 2] = 0xc3;
        text[index * 2 + 1] = 0xa9;
    }
    var name: [96]u8 = undefined;
    displayName(&text, &name);
    try std.testing.expectEqual(@as(usize, 94), std.mem.sliceTo(&name, 0).len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(std.mem.sliceTo(&name, 0)));
    var record: Record = .{};
    record.profile[0] = 0xff;
    try std.testing.expectError(error.InvalidPracticeHistory, record.validate());
}
