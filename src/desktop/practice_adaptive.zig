//! Adaptive letter lessons: unlock letters one at a time when every unlocked
//! letter reaches the target speed accurately, focus the weakest letter, and
//! generate pseudo-words and readable words from the unlocked letters only.
const std = @import("std");
pub const generator = @import("practice_generator.zig");
const phonetic = @import("practice_phonetic.zig");
const keys = @import("practice_keys.zig");

/// Generation contract of adaptive lessons, independent of curriculum v1
/// English generation. Changing text for a frozen context needs a new version.
pub const version: u16 = 1;
pub const start_letters = 6;
/// Short, Normal and Long lessons.
pub const word_counts = [_]usize{ 15, 30, 60 };
/// Every third word is a readable vocabulary word when one is available.
pub const real_word_interval = 3;

pub const Reason = enum {
    /// No letter has enough evidence yet; practice the starting letters.
    starting,
    /// A letter without enough runs yet, usually the newest one.
    new_letter,
    /// The unlocked letter furthest below the target speed or accuracy.
    weakest,
    /// Every available letter is confident; keep refining the slowest.
    all_confident,
};

pub const Plan = struct {
    /// Number of `available` letters unlocked, at least `start_letters`.
    unlocked: u8,
    /// Index of the focused letter within the unlocked letters.
    focus: u8,
    reason: Reason,
};

/// Unlocks letters in `available` order while every unlocked letter has
/// reached the target, keeping at least `at_least` letters, then focuses the
/// first letter lacking evidence or the least confident one. `available`
/// must contain at least `start_letters` letters.
pub fn plan(model: *const keys.Model, available: []const u8, target_ms: f64, at_least: usize) Plan {
    std.debug.assert(available.len >= start_letters and available.len <= 26);
    var unlocked: usize = std.math.clamp(at_least, start_letters, available.len);
    while (unlocked < available.len and allReached(model, available[0..unlocked], target_ms)) unlocked += 1;
    const letters = available[0..unlocked];
    for (letters, 0..) |cp, index| if (!model.get(cp).known()) return .{
        .unlocked = @intCast(unlocked),
        .focus = @intCast(index),
        .reason = if (unlocked == start_letters) .starting else .new_letter,
    };
    var focus: usize = 0;
    var lowest = std.math.inf(f64);
    for (letters, 0..) |cp, index| {
        const key = model.get(cp);
        // A letter over the miss threshold is treated as if it were slow.
        var value = key.confidence(target_ms).?;
        if (key.miss_rate > keys.max_miss_rate) value = @min(value, 1) - key.miss_rate;
        if (value < lowest) {
            lowest = value;
            focus = index;
        }
    }
    const done = allReached(model, letters, target_ms) and unlocked == available.len;
    return .{ .unlocked = @intCast(unlocked), .focus = @intCast(focus), .reason = if (done) .all_confident else .weakest };
}

fn allReached(model: *const keys.Model, letters: []const u8, target_ms: f64) bool {
    for (letters) |cp| if (!model.get(cp).reached(target_ms)) return false;
    return true;
}

/// Writes a lesson of space-separated words typed with `letters` only. Each
/// word contains a focus letter, rotating over `focus` per word. Readable
/// vocabulary words containing the focus letter replace every third word when
/// available; the remaining words are pseudo-words.
pub fn generate(buffer: []u8, seed: u64, letters: []const u8, focus: []const u8, length: u8) ![]const u8 {
    if (length >= word_counts.len) return error.InvalidExerciseLevel;
    if (letters.len == 0 or focus.len == 0) return error.CurriculumAlphabetUnavailable;
    const set = phonetic.letterSet(letters);
    for (focus) |cp| if (cp < 'a' or cp > 'z' or set & phonetic.letterSet(&.{cp}) == 0) return error.CurriculumTargetUnavailable;
    var random: generator.Random = .{ .state = seed };
    var writer: std.Io.Writer = .fixed(buffer);
    var previous: [phonetic.max_length]u8 = undefined;
    var previous_len: usize = 0;
    var previous_real: ?usize = null;
    for (0..word_counts[length]) |slot| {
        const cp = focus[slot % focus.len];
        var pseudo: [phonetic.max_length]u8 = undefined;
        const real = if (slot % real_word_interval == real_word_interval - 1)
            realWord(&random, set, cp, previous_real)
        else
            null;
        const text = if (real) |index|
            generator.vocabulary[index]
        else
            try phonetic.word(&random, &pseudo, .{ .letters = set, .focus = cp }, previous[0..previous_len]);
        if (real != null) previous_real = real;
        if (slot != 0) try writer.writeByte(' ');
        try writer.writeAll(text);
        previous_len = @min(text.len, previous.len);
        @memcpy(previous[0..previous_len], text[0..previous_len]);
    }
    return writer.buffered();
}

/// A random vocabulary word typed with `set` that contains `focus`, other
/// than `previous`, or null when the vocabulary has none.
fn realWord(random: *generator.Random, set: phonetic.Letters, focus: u8, previous: ?usize) ?usize {
    const start = random.index(generator.vocabulary.len);
    for (0..generator.vocabulary.len) |offset| {
        const index = (start + offset) % generator.vocabulary.len;
        if (index == previous) continue;
        const entry = generator.vocabulary[index];
        if (entry.len > phonetic.max_length + 3) continue;
        if (std.mem.indexOfScalar(u8, entry, focus) == null) continue;
        if (phonetic.letterSet(entry) & ~set != 0) continue;
        return index;
    }
    return null;
}

const order = "enaritoslcdumpghbyfvkwzxjq";

fn confidentKey(ms: f64) keys.Key {
    return .{ .runs = 3, .ms = ms, .best_ms = ms, .miss_runs = 3 };
}

test "a fresh model practices the starting letters, first unknown letter focused" {
    const t = std.testing;
    const model: keys.Model = .{};
    const value = plan(&model, order, keys.targetMs(35), 0);
    try t.expectEqual(Plan{ .unlocked = 6, .focus = 0, .reason = .starting }, value);
    // Layouts with only the starting letters still produce a plan.
    try t.expectEqual(@as(u8, 6), plan(&model, order[0..6], 300, 0).unlocked);
}

test "confident letters unlock the next one and an unknown letter takes the focus" {
    const t = std.testing;
    var model: keys.Model = .{ .runs = 5 };
    for (order[0..6]) |cp| model.keys[cp - 'a'] = confidentKey(200);
    var value = plan(&model, order, 300, 0);
    try t.expectEqual(Plan{ .unlocked = 7, .focus = 6, .reason = .new_letter }, value);
    // Letters already confident through other practice unlock together.
    model.keys['o' - 'a'] = confidentKey(250);
    model.keys['s' - 'a'] = confidentKey(250);
    model.keys['l' - 'a'] = confidentKey(250);
    value = plan(&model, order, 300, 0);
    try t.expectEqual(@as(u8, 10), value.unlocked);
    try t.expectEqual(@as(u8, 9), value.focus);
}

test "the slowest or least accurate unlocked letter is focused" {
    const t = std.testing;
    var model: keys.Model = .{ .runs = 5 };
    for (order[0..6]) |cp| model.keys[cp - 'a'] = confidentKey(200);
    model.keys['i' - 'a'] = confidentKey(450);
    var value = plan(&model, order, 300, 0);
    try t.expectEqual(Plan{ .unlocked = 6, .focus = 4, .reason = .weakest }, value);
    // A slower recent run keeps letters unlocked once reached; so does a
    // previously frozen larger alphabet.
    model.keys['i' - 'a'].best_ms = 250;
    try t.expectEqual(Plan{ .unlocked = 7, .focus = 6, .reason = .new_letter }, plan(&model, order, 300, 0));
    model.keys['i' - 'a'].best_ms = 450;
    try t.expectEqual(Plan{ .unlocked = 8, .focus = 6, .reason = .new_letter }, plan(&model, order, 300, 8));
    // An inaccurate letter is focused even when it is fast.
    model.keys['i' - 'a'] = confidentKey(200);
    model.keys['a' - 'a'].miss_rate = 0.2;
    value = plan(&model, order, 300, 0);
    try t.expectEqual(Plan{ .unlocked = 6, .focus = 2, .reason = .weakest }, value);
    // All letters of the layout confident: refine the slowest.
    model.keys['a' - 'a'].miss_rate = 0;
    model.keys['t' - 'a'] = confidentKey(290);
    value = plan(&model, order[0..6], 300, 0);
    try t.expectEqual(Plan{ .unlocked = 6, .focus = 5, .reason = .all_confident }, value);
}

test "lessons use unlocked letters only, contain the focus and are reproducible" {
    const t = std.testing;
    for (0..3) |length| for (6..27) |unlocked| for (0..8) |seed| {
        const letters = order[0..unlocked];
        const focus = letters[(seed * 5) % unlocked .. (seed * 5) % unlocked + 1];
        var buffer: [8192]u8 = undefined;
        var again: [8192]u8 = undefined;
        const text = try generate(&buffer, seed, letters, focus, @intCast(length));
        try t.expectEqualStrings(text, try generate(&again, seed, letters, focus, @intCast(length)));
        var words = std.mem.splitScalar(u8, text, ' ');
        var count: usize = 0;
        var with_focus: usize = 0;
        while (words.next()) |entry| {
            try t.expect(entry.len >= phonetic.min_length);
            for (entry) |cp| try t.expect(std.mem.indexOfScalar(u8, letters, cp) != null);
            if (std.mem.indexOfScalar(u8, entry, focus[0]) != null) with_focus += 1;
            count += 1;
        }
        try t.expectEqual(word_counts[length], count);
        try t.expectEqual(count, with_focus);
    };
    var buffer: [8192]u8 = undefined;
    try t.expectError(error.CurriculumTargetUnavailable, generate(&buffer, 1, "enarit", "z", 0));
    try t.expectError(error.InvalidExerciseLevel, generate(&buffer, 1, "enarit", "e", 3));
    try t.expectError(error.WriteFailed, generate(buffer[0..8], 1, "enarit", "e", 0));
}

test "larger alphabets mix in readable vocabulary words" {
    const t = std.testing;
    var buffer: [8192]u8 = undefined;
    const text = try generate(&buffer, 3, order[0..16], "e", 2);
    var real: usize = 0;
    var words = std.mem.splitScalar(u8, text, ' ');
    while (words.next()) |entry| {
        for (generator.vocabulary) |known| if (std.mem.eql(u8, known, entry)) {
            real += 1;
            break;
        };
    }
    try t.expect(real >= word_counts[2] / real_word_interval);
}

test "adaptive v1 literal hash freezes generated lessons" {
    var buffer: [8192]u8 = undefined;
    const text = try generate(&buffer, 42, order[0..8], "o", 1);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    try std.testing.expectEqualStrings(
        "b0afb9de99b1a724b5a0a90f9d2a7e676e776f11552d9285c0621f1abed28aec",
        &std.fmt.bytesToHex(hash, .lower),
    );
}
