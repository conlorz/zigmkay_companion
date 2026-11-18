//! Per-letter learning estimates for adaptive lessons. Each completed run
//! contributes one observation per letter: its median clean interval and its
//! first-pass miss rate. Observations are smoothed in chronological order and
//! compared with a target speed. This is a tutor policy, not a statistical
//! claim about motor skill.
const std = @import("std");
const progress = @import("practice_progress.zig");

/// Weight of the newest run in the smoothed interval and miss rate.
pub const smoothing = 0.25;
/// Runs need this many clean intervals of a letter to update its timing.
pub const min_samples = 3;
/// Letters need this many smoothed observations before they count as known.
pub const min_runs = 2;
/// A smoothed miss rate above this makes a letter count as not yet confident.
pub const max_miss_rate = 0.05;
/// Words per minute are characters per minute divided by five.
pub const characters_per_word = 5;
pub const target_choices = [_]u16{ 20, 25, 30, 35, 40, 50, 60 };
pub const default_target_wpm: u16 = 35;

/// Milliseconds per character at `wpm` words per minute.
pub fn targetMs(wpm: u16) f64 {
    std.debug.assert(wpm > 0);
    return 60_000.0 / @as(f64, @floatFromInt(@as(u32, wpm) * characters_per_word));
}

/// Words per minute equivalent of `ms` per character.
pub fn wpmFor(ms: f64) f64 {
    return 60_000.0 / (ms * characters_per_word);
}

pub const Key = struct {
    /// Runs that updated the smoothed interval.
    runs: u32 = 0,
    /// Smoothed median clean interval in milliseconds.
    ms: f64 = 0,
    /// Fastest smoothed interval reached so far.
    best_ms: f64 = 0,
    /// Smoothed first-pass miss rate of the runs with opportunities.
    miss_rate: f64 = 0,
    miss_runs: u32 = 0,
    opportunities: u64 = 0,
    misses: u64 = 0,

    pub fn known(self: Key) bool {
        return self.runs >= min_runs;
    }

    /// Target interval divided by the smoothed interval: 1 means the letter
    /// reaches the target speed. Null until the letter has enough runs.
    pub fn confidence(self: Key, target_ms: f64) ?f64 {
        if (!self.known() or self.ms <= 0) return null;
        return target_ms / self.ms;
    }

    pub fn bestConfidence(self: Key, target_ms: f64) ?f64 {
        if (!self.known() or self.best_ms <= 0) return null;
        return target_ms / self.best_ms;
    }

    /// Whether the letter is currently fast and accurate enough.
    pub fn confident(self: Key, target_ms: f64) bool {
        const value = self.confidence(target_ms) orelse return false;
        return value >= 1 and self.miss_rate <= max_miss_rate;
    }

    /// Whether the letter has reached the target speed at some point and is
    /// currently accurate. A slower day therefore never locks letters again.
    pub fn reached(self: Key, target_ms: f64) bool {
        const value = self.bestConfidence(target_ms) orelse return false;
        return value >= 1 and self.miss_rate <= max_miss_rate;
    }

    fn observe(self: *Key, character: progress.Character) void {
        self.opportunities += character.opportunities;
        self.misses += character.misses;
        if (character.opportunities > 0) {
            const rate = @as(f64, @floatFromInt(character.misses)) / @as(f64, @floatFromInt(character.opportunities));
            self.miss_rate = if (self.miss_runs == 0) rate else self.miss_rate + smoothing * (rate - self.miss_rate);
            self.miss_runs += 1;
        }
        if (character.samples < min_samples or character.median_us == 0) return;
        const ms = @as(f64, @floatFromInt(character.median_us)) / 1000;
        self.ms = if (self.runs == 0) ms else self.ms + smoothing * (ms - self.ms);
        self.best_ms = if (self.runs == 0) self.ms else @min(self.best_ms, self.ms);
        self.runs += 1;
    }
};

/// Estimates for the 26 lowercase letters. Other characters are ignored:
/// adaptive lessons introduce letters only.
pub const Model = struct {
    keys: [26]Key = @splat(.{}),
    runs: u32 = 0,

    pub fn get(self: *const Model, cp: u8) Key {
        std.debug.assert(cp >= 'a' and cp <= 'z');
        return self.keys[cp - 'a'];
    }

    /// Adds one run. Callers add runs oldest first.
    pub fn add(self: *Model, point: *const progress.Point) void {
        if (point.active_us == 0) return;
        self.runs += 1;
        for (point.characters[0..point.count]) |character| {
            if (character.cp < 'a' or character.cp > 'z') continue;
            var value = character;
            // Count-only and truncated runs keep accuracy but not timing.
            if (!point.timing or point.truncated) value.samples = 0;
            self.keys[character.cp - 'a'].observe(value);
        }
    }

    /// Builds the model from newest-first points, as history provides them.
    pub fn fromNewest(points: []const progress.Point) Model {
        var model: Model = .{};
        var index = points.len;
        while (index > 0) {
            index -= 1;
            model.add(&points[index]);
        }
        return model;
    }
};

fn testPoint(characters: []const progress.Character) progress.Point {
    var value: progress.Point = .{ .active_us = 1, .timing = true, .count = characters.len };
    @memcpy(value.characters[0..characters.len], characters);
    return value;
}

test "target speed converts between words per minute and character intervals" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 342.857), targetMs(35), 0.001);
    try t.expectApproxEqAbs(@as(f64, 35), wpmFor(targetMs(35)), 0.000_001);
    try t.expectEqual(@as(f64, 200), targetMs(60));
}

test "smoothed intervals follow the newest runs and keep the best value" {
    const t = std.testing;
    var model: Model = .{};
    for ([_]u64{ 400_000, 300_000, 200_000, 600_000 }) |median| {
        const value = testPoint(&.{.{ .cp = 'e', .opportunities = 10, .samples = 5, .median_us = median }});
        model.add(&value);
    }
    const key = model.get('e');
    try t.expectEqual(@as(u32, 4), key.runs);
    // 400 -> 375 -> 331.25 -> 398.4375
    try t.expectApproxEqAbs(@as(f64, 398.4375), key.ms, 0.000_001);
    try t.expectApproxEqAbs(@as(f64, 331.25), key.best_ms, 0.000_001);
    try t.expectApproxEqAbs(@as(f64, 200.0 / 398.4375), key.confidence(200).?, 0.000_001);
    try t.expectApproxEqAbs(@as(f64, 200.0 / 331.25), key.bestConfidence(200).?, 0.000_001);
    try t.expect(!key.confident(200));
    try t.expect(key.confident(400));
    try t.expect(!key.confident(340) and key.reached(340));
}

test "sparse timing, truncation and misses withhold confidence" {
    const t = std.testing;
    var model: Model = .{};
    const sparse = testPoint(&.{.{ .cp = 'a', .opportunities = 4, .samples = 2, .median_us = 100_000 }});
    model.add(&sparse);
    model.add(&sparse);
    try t.expectEqual(@as(?f64, null), model.get('a').confidence(300));
    var truncated = testPoint(&.{.{ .cp = 'a', .opportunities = 10, .samples = 9, .median_us = 100_000 }});
    truncated.truncated = true;
    model.add(&truncated);
    model.add(&truncated);
    try t.expectEqual(@as(u32, 0), model.get('a').runs);
    try t.expectEqual(@as(u64, 28), model.get('a').opportunities);

    const clean = testPoint(&.{.{ .cp = 'n', .opportunities = 20, .samples = 15, .median_us = 150_000 }});
    const missed = testPoint(&.{.{ .cp = 'n', .opportunities = 20, .misses = 4, .samples = 15, .median_us = 150_000 }});
    model = .{};
    model.add(&clean);
    model.add(&clean);
    try t.expect(model.get('n').confident(300));
    model.add(&missed);
    try t.expectApproxEqAbs(@as(f64, 0.05), model.get('n').miss_rate, 0.000_001);
    model.add(&missed);
    try t.expect(!model.get('n').confident(300));
}

test "models are built oldest first from newest-first history and ignore other characters" {
    const t = std.testing;
    const points = [_]progress.Point{
        testPoint(&.{ .{ .cp = 't', .opportunities = 5, .samples = 5, .median_us = 100_000 }, .{ .cp = 'T', .opportunities = 5, .samples = 5, .median_us = 1 } }),
        testPoint(&.{.{ .cp = 't', .opportunities = 5, .samples = 5, .median_us = 500_000 }}),
    };
    const model = Model.fromNewest(&points);
    try t.expectEqual(@as(u32, 2), model.runs);
    // The older 500 ms run is the starting value; the newer 100 ms run moves it.
    try t.expectApproxEqAbs(@as(f64, 400), model.get('t').ms, 0.000_001);
}
