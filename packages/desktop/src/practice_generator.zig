//! First-party curated vocabulary, fixed SplitMix64 and textual coverage v1.
const std = @import("std");
pub const Preset = enum { words, mixed_case, punctuation };
pub const version: u16 = 1;
pub const Descriptor = struct {
    seed: u64,
    preset: Preset = .words,
    length: u8 = 1,
    generator_version: u16 = version,
    corpus_version: u16 = version,
    coverage_version: u16 = 1,
    pub fn validate(self: Descriptor) !void {
        if (self.length > 2) return error.InvalidExerciseLevel;
        if (self.generator_version != version or self.corpus_version != version or self.coverage_version != 1) return error.UnsupportedChallenge;
    }
};
pub const vocabulary = blk: {
    @setEvalBranchQuota(100_000);
    const data = @embedFile("practice_vocabulary.txt");
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, data, " \n\r\t");
    while (it.next() != null) count += 1;
    var words: [count][]const u8 = undefined;
    it.reset();
    for (&words) |*word| word.* = it.next().?;
    break :blk words;
};
const Random = struct {
    state: u64,
    fn next(self: *Random) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var x = self.state;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        return x ^ (x >> 31);
    }
    fn index(self: *Random, size: usize) usize {
        return @intCast(self.next() % size);
    }
};
/// Focusing selects candidates from the same corpus; plain challenge inputs
/// never include history. Unsupported targets are explicitly rejected.
pub fn generate(buffer: []u8, descriptor: Descriptor, targets: []const u21) ![]const u8 {
    try descriptor.validate();
    if (targets.len > 5) return error.TooManyDrillTargets;
    for (targets) |cp| {
        if (descriptor.preset == .words and (cp < 'a' or cp > 'z')) return error.HarderPresetRequired;
        if (cp > 127) return error.CorpusCoverageUnavailable;
    }
    var random: Random = .{ .state = descriptor.seed };
    var writer: std.Io.Writer = .fixed(buffer);
    var used: [20]usize = undefined;
    var used_len: usize = 0;
    const units = ([_]usize{ 2, 5, 10 })[descriptor.length];
    for (0..units) |unit| {
        var chosen: [2][]const u8 = undefined;
        for (&chosen, 0..) |*word, slot| {
            var candidate = random.index(vocabulary.len);
            if (targets.len > 0) {
                const cp = targets[(unit * 2 + slot) % targets.len];
                const lower = std.ascii.toLower(@intCast(cp));
                if (std.ascii.isAlphabetic(lower)) {
                    var found = false;
                    for (0..vocabulary.len) |offset| {
                        const index = (candidate + offset) % vocabulary.len;
                        if (std.mem.indexOfScalar(u8, vocabulary[index], lower) != null and std.mem.indexOfScalar(usize, used[0..used_len], index) == null) {
                            candidate = index;
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.CorpusCoverageUnavailable;
                }
            }
            for (0..vocabulary.len) |_| {
                if (std.mem.indexOfScalar(usize, used[0..used_len], candidate) == null) break;
                candidate = (candidate + 1) % vocabulary.len;
            }
            used[used_len] = candidate;
            used_len += 1;
            word.* = vocabulary[candidate];
        }
        if (unit > 0) try writer.writeByte(' ');
        const a = chosen[0];
        const b = chosen[1];
        switch (descriptor.preset) {
            .words => switch ((random.index(12) + unit) % 12) {
                0 => try writer.print("we talked about {s} and {s} before lunch.", .{ a, b }),
                1 => try writer.print("please bring your notes on {s} and {s} tomorrow.", .{ a, b }),
                2 => try writer.print("the library has books about {s} and {s}.", .{ a, b }),
                3 => try writer.print("our next lesson explores {s} alongside {s}.", .{ a, b }),
                4 => try writer.print("i found an interesting chapter on {s} and {s}.", .{ a, b }),
                5 => try writer.print("a friend shared a story about {s} and {s}.", .{ a, b }),
                6 => try writer.print("we made time to discuss {s} as well as {s}.", .{ a, b }),
                7 => try writer.print("the exhibition connects {s} with {s} in surprising ways.", .{ a, b }),
                8 => try writer.print("today we will compare ideas about {s} and {s}.", .{ a, b }),
                9 => try writer.print("their latest article considers both {s} and {s}.", .{ a, b }),
                10 => try writer.print("my notebook includes a page about {s} and {s}.", .{ a, b }),
                else => try writer.print("after the walk we read about {s} and {s}.", .{ a, b }),
            },
            .mixed_case => {
                const acronyms = [_][]const u8{ "HTTP", "USB", "API", "HTML", "DNS", "CPU" };
                const terms = [_][]const u8{ "IPv6", "mDNS", "eBPF", "GitHub", "OpenGL", "WebKit" };
                const names = [_][]const u8{ "Maya", "Robin", "Alex", "Sam", "Zoe", "Noah", "Iris", "Ben" };
                try writer.print("{s} shared notes on {s} and {s}; our {s} guide mentions {s}.", .{ names[random.index(names.len)], a, b, acronyms[random.index(acronyms.len)], terms[random.index(terms.len)] });
            },
            .punctuation => switch (unit % 4) {
                0 => try writer.print("Let's discuss {s}; she said, \"try {s} next!\"", .{ a, b }),
                1 => try writer.print("Today's topics: {s} and {s} (pages 12-14).", .{ a, b }),
                2 => try writer.print("Is {s} on your list, or would you prefer {s}?", .{ a, b }),
                else => try writer.print("We wrote \"{s}\" twice; don't forget {s} at 9:30.", .{ a, b }),
            },
        }
    }
    const text = writer.buffered();
    if (text.len > 8192) return error.ExerciseTooLong;
    // Every accepted drill target must actually appear, including punctuation.
    for (targets) |cp| if (std.mem.indexOfScalar(u8, text, @intCast(cp)) == null) return error.CorpusCoverageUnavailable;
    return text;
}
test "curated base vocabulary is unique and all nine configurations have stable bounded coverage" {
    const t = std.testing;
    try t.expect(vocabulary.len >= 500);
    var unique: std.StringHashMap(void) = .init(t.allocator);
    defer unique.deinit();
    for (vocabulary) |word| {
        const entry = try unique.getOrPut(word);
        // Shared category headings were removed; count ordinary base entries once.
        try t.expect(!entry.found_existing);
    }
    for ([_]Preset{ .words, .mixed_case, .punctuation }) |preset| for (0..3) |length| for (0..64) |seed| {
        var buffer: [8192]u8 = undefined;
        var again: [8192]u8 = undefined;
        const descriptor: Descriptor = .{ .seed = seed, .preset = preset, .length = @intCast(length) };
        const text = try generate(&buffer, descriptor, &.{});
        try t.expectEqualStrings(text, try generate(&again, descriptor, &.{}));
        try t.expect(text.len > 70 and text.len < 2000);
        if (preset == .words) for (text) |byte| {
            try t.expect(std.ascii.isLower(byte) or byte == ' ' or byte == '.');
        };
        if (preset == .mixed_case) {
            try t.expect(std.mem.indexOfScalar(u8, text, ';') != null);
            var consecutive = false;
            for (text[1..], text[0 .. text.len - 1]) |a, b| if (std.ascii.isUpper(a) and std.ascii.isUpper(b)) {
                consecutive = true;
            };
            try t.expect(consecutive);
        }
        if (preset == .punctuation) {
            try t.expect(std.mem.indexOfScalar(u8, text, ';') != null);
            try t.expect(std.mem.indexOfScalar(u8, text, '\'') != null);
            try t.expect(std.mem.count(u8, text, "\"") % 2 == 0);
            try t.expectEqual(std.mem.count(u8, text, "("), std.mem.count(u8, text, ")"));
            if (length > 0) try t.expect(std.mem.indexOfScalar(u8, text, ':') != null and std.mem.indexOfScalar(u8, text, '(') != null);
        }
    };
    var buffer: [8192]u8 = undefined;
    try t.expectError(error.InvalidExerciseLevel, generate(&buffer, .{ .seed = 1, .length = 3 }, &.{}));
    try t.expectError(error.UnsupportedChallenge, generate(&buffer, .{ .seed = 1, .generator_version = 2 }, &.{}));
    try t.expectError(error.HarderPresetRequired, generate(&buffer, .{ .seed = 1 }, &.{'A'}));
    try t.expectError(error.WriteFailed, generate(buffer[0..4], .{ .seed = 1 }, &.{}));
}
