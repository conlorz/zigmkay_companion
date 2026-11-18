//! Pronounceable pseudo-words from a letter-trigram model of the first-party
//! practice vocabulary. Generation is restricted to a learner's letter set and
//! uses only integer weights, so a seed reproduces the same words everywhere.
const std = @import("std");
const generator = @import("practice_generator.zig");

/// Part of the adaptive lesson contract: changing the model or the sampling
/// changes generated text and therefore needs a new version.
pub const version: u16 = 1;
pub const min_length = 3;
pub const max_length = 9;

/// A set of lowercase ASCII letters, bit 0 being `a`.
pub const Letters = u26;

pub fn letterSet(letters: []const u8) Letters {
    var set: Letters = 0;
    for (letters) |cp| set |= bit(cp);
    return set;
}

fn bit(cp: u8) Letters {
    std.debug.assert(cp >= 'a' and cp <= 'z');
    return @as(Letters, 1) << @intCast(cp - 'a');
}

/// Symbols 0-25 are letters; `boundary` marks the start and end of a word.
const boundary = 26;
const symbols = 27;

/// Transition counts after the two previous symbols and after one, plus
/// letter totals, for backing off when a context has no allowed successor.
pub const Model = struct {
    trigram: [symbols][symbols][symbols]u16,
    bigram: [symbols][symbols]u16,

    fn train(words: []const []const u8) Model {
        var trained: Model = .{
            .trigram = @splat(@splat(@splat(0))),
            .bigram = @splat(@splat(0)),
        };
        for (words) |entry| {
            var a: usize = boundary;
            var b: usize = boundary;
            for (0..entry.len + 1) |index| {
                const c: usize = if (index == entry.len) boundary else entry[index] - 'a';
                trained.trigram[a][b][c] += 1;
                trained.bigram[b][c] += 1;
                a = b;
                b = c;
            }
        }
        return trained;
    }
};

pub const model: Model = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk Model.train(&generator.vocabulary);
};

pub const Options = struct {
    letters: Letters,
    /// A letter each word should contain; words without it are retried.
    focus: ?u8 = null,
    min_length: usize = min_length,
    max_length: usize = max_length,
};

/// Whole pseudo-words that are never offered, because letter models can
/// assemble them from harmless vocabulary.
/// No entry repeats a single letter, which keeps the last-resort word safe.
pub const blocked = [_][]const u8{
    "anal", "anus", "arse", "ass",  "bitch", "boob",  "butt",  "cock",   "coon",
    "crap", "cum",  "cunt", "damn", "dick",  "dildo", "dyke",  "fag",    "fart",
    "fuck", "gook", "homo", "jizz", "kike",  "nazi",  "nigga", "nigger", "penis",
    "piss", "porn", "pube", "rape", "scum",  "sex",   "shit",  "slut",   "spic",
    "tit",  "tits", "turd", "twat", "wank",  "whore",
};

fn isBlocked(text: []const u8) bool {
    for (blocked) |entry| if (std.mem.eql(u8, entry, text)) return true;
    return false;
}

/// Writes one pseudo-word into `buffer` using only `options.letters`. Up to
/// sixteen candidates are drawn until one contains the focus letter, ends
/// before the length limit, differs from `previous` and is not blocked. A
/// rare focus letter that the model did not produce then starts the word,
/// so every word contains it.
pub fn word(random: *generator.Random, buffer: *[max_length]u8, options: Options, previous: []const u8) ![]const u8 {
    if (options.letters == 0) return error.PseudoWordLettersUnavailable;
    if (options.min_length == 0 or
        options.min_length > options.max_length or
        options.max_length > max_length) return error.InvalidPseudoWordLength;
    if (options.focus) |cp| if (options.letters & bit(cp) == 0) return error.PseudoWordFocusUnavailable;
    for (0..16) |_| {
        const length = candidate(random, buffer, options, null);
        const text = buffer[0..length];
        const focused = if (options.focus) |cp| std.mem.indexOfScalar(u8, text, cp) != null else true;
        // Prefer words the model ended before the length limit.
        const ended = length < options.max_length;
        if (focused and ended and !std.mem.eql(u8, text, previous) and !isBlocked(text)) return text;
    }
    for (0..16) |_| {
        const length = candidate(random, buffer, options, options.focus);
        if (!isBlocked(buffer[0..length])) return buffer[0..length];
    }
    // Tiny alphabets can make a blocked word nearly certain. A repeated
    // letter is never blocked.
    const cp = options.focus orelse 'a' + @as(u8, @ctz(options.letters));
    @memset(buffer[0..options.min_length], cp);
    return buffer[0..options.min_length];
}

fn candidate(random: *generator.Random, buffer: *[max_length]u8, options: Options, first: ?u8) usize {
    var a: usize = boundary;
    var b: usize = boundary;
    var length: usize = 0;
    if (first) |cp| {
        buffer[0] = cp;
        length = 1;
        b = cp - 'a';
    }
    while (length < options.max_length) {
        const end_allowed = length >= options.min_length;
        const next = choose(random, a, b, options.letters, end_allowed);
        if (next == boundary) break;
        buffer[length] = @intCast('a' + next);
        length += 1;
        a = b;
        b = next;
    }
    return length;
}

/// Draws the next symbol from the trigram context, backing off to the bigram
/// context and then to a uniform choice among the allowed letters.
fn choose(random: *generator.Random, a: usize, b: usize, letters: Letters, end_allowed: bool) usize {
    var weights: [symbols]u32 = @splat(0);
    if (fill(&weights, &model.trigram[a][b], letters, end_allowed) or
        fill(&weights, &model.bigram[b], letters, end_allowed))
    {
        return draw(random, &weights);
    }
    for (0..26) |index| weights[index] = @intFromBool(letters & (@as(Letters, 1) << @intCast(index)) != 0);
    return draw(random, &weights);
}

/// Copies allowed counts into `weights` and reports whether any letter is
/// possible. The end of a word alone is not enough while it is disallowed.
fn fill(weights: *[symbols]u32, counts: *const [symbols]u16, letters: Letters, end_allowed: bool) bool {
    var any_letter = false;
    for (0..26) |index| {
        const allowed = letters & (@as(Letters, 1) << @intCast(index)) != 0;
        weights[index] = if (allowed) counts[index] else 0;
        if (weights[index] != 0) any_letter = true;
    }
    weights[boundary] = if (end_allowed) counts[boundary] else 0;
    return any_letter or weights[boundary] != 0;
}

fn draw(random: *generator.Random, weights: *const [symbols]u32) usize {
    var total: u64 = 0;
    for (weights) |weight| total += weight;
    std.debug.assert(total != 0);
    var point = random.next() % total;
    for (weights, 0..) |weight, index| {
        if (point < weight) return index;
        point -= weight;
    }
    unreachable;
}

test "the trigram model is trained from every vocabulary transition" {
    const t = std.testing;
    var starts: u64 = 0;
    var ends: u64 = 0;
    for (model.trigram[boundary][boundary]) |count| starts += count;
    for (model.bigram) |row| ends += row[boundary];
    try t.expectEqual(@as(u64, generator.vocabulary.len), starts);
    try t.expectEqual(@as(u64, generator.vocabulary.len), ends);
    // "qu" dominates the corpus, so a q is followed by u.
    var after_q: u64 = 0;
    for (model.bigram['q' - 'a']) |count| after_q += count;
    try t.expectEqual(after_q, model.bigram['q' - 'a']['u' - 'a']);
}

test "pseudo-words use only allowed letters, respect bounds and are reproducible" {
    const t = std.testing;
    const sets = [_][]const u8{ "enarit", "enaritosl", "enaritoslcdumpgh", "abcdefghijklmnopqrstuvwxyz", "q", "xz" };
    for (sets) |letters| for (0..32) |seed| {
        var random: generator.Random = .{ .state = seed };
        var again: generator.Random = .{ .state = seed };
        var previous: [max_length]u8 = undefined;
        var previous_len: usize = 0;
        for (0..20) |_| {
            var buffer: [max_length]u8 = undefined;
            var copy: [max_length]u8 = undefined;
            const options: Options = .{ .letters = letterSet(letters), .focus = letters[letters.len - 1] };
            const text = try word(&random, &buffer, options, previous[0..previous_len]);
            try t.expectEqualStrings(text, try word(&again, &copy, options, previous[0..previous_len]));
            try t.expect(text.len >= min_length and text.len <= max_length);
            try t.expect(std.mem.indexOfScalar(u8, text, options.focus.?) != null);
            for (text) |cp| try t.expect(std.mem.indexOfScalar(u8, letters, cp) != null);
            @memcpy(previous[0..text.len], text);
            previous_len = text.len;
        }
    };
    var random: generator.Random = .{ .state = 1 };
    var buffer: [max_length]u8 = undefined;
    try t.expectError(error.PseudoWordLettersUnavailable, word(&random, &buffer, .{ .letters = 0 }, ""));
    try t.expectError(
        error.PseudoWordFocusUnavailable,
        word(&random, &buffer, .{ .letters = letterSet("abc"), .focus = 'z' }, ""),
    );
    try t.expectError(
        error.InvalidPseudoWordLength,
        word(&random, &buffer, .{ .letters = letterSet("abc"), .min_length = 5, .max_length = 4 }, ""),
    );
}

test "blocked words are never generated" {
    const t = std.testing;
    for (blocked) |entry| {
        for (entry) |cp| try t.expect(cp >= 'a' and cp <= 'z');
        try t.expect(std.mem.indexOfNone(u8, entry, entry[0..1]) != null);
        // Small alphabets containing a blocked word's letters reject it.
        var buffer: [max_length]u8 = undefined;
        for (0..64) |seed| {
            var random: generator.Random = .{ .state = seed };
            const text = try word(&random, &buffer, .{ .letters = letterSet(entry), .focus = entry[0] }, "");
            try t.expect(!isBlocked(text));
        }
    }
}

test "a focus letter appears in every pseudo-word" {
    const t = std.testing;
    var random: generator.Random = .{ .state = 7 };
    var focused: usize = 0;
    var previous: [max_length]u8 = undefined;
    var previous_len: usize = 0;
    for (0..200) |_| {
        var buffer: [max_length]u8 = undefined;
        const text = try word(&random, &buffer, .{ .letters = letterSet("enaritosl"), .focus = 'l' }, previous[0..previous_len]);
        if (std.mem.indexOfScalar(u8, text, 'l') != null) focused += 1;
        try t.expect(!std.mem.eql(u8, text, previous[0..previous_len]));
        @memcpy(previous[0..text.len], text);
        previous_len = text.len;
    }
    try t.expectEqual(@as(usize, 200), focused);
}
