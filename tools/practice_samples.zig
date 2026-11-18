//! Reviewable fixed seed samples; this utility performs no acquisition or device I/O.
const std = @import("std");
const adaptive = @import("adaptive");
const generator = adaptive.generator;

pub fn main() !void {
    std.debug.print("Curated base entries: {d}\n", .{generator.vocabulary.len});
    for ([_]generator.Preset{ .words, .mixed_case, .punctuation }) |preset| for (0..3) |length| {
        var buffer: [8192]u8 = undefined;
        const text = try generator.generate(&buffer, .{
            .seed = 42,
            .preset = preset,
            .length = @intCast(length),
        }, &.{});
        printSample(@tagName(preset), length, text);
    };
    // Adaptive lessons with a growing alphabet, focusing its newest letter.
    const order = "enaritoslcdumpghbyfvkwzxjq";
    for ([_]usize{ 6, 7, 10, 16, 26 }) |unlocked| {
        var buffer: [8192]u8 = undefined;
        const text = try adaptive.generate(&buffer, 42, order[0..unlocked], order[unlocked - 1 .. unlocked], 1);
        var name: [32]u8 = undefined;
        printSample(try std.fmt.bufPrint(&name, "adaptive {d} letters", .{unlocked}), 1, text);
    }
}

fn printSample(name: []const u8, length: usize, text: []const u8) void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    std.debug.print("\n{s}/{d} · {d} chars · {s}\n{s}\n", .{
        name,
        length,
        text.len,
        std.fmt.bytesToHex(hash, .lower),
        text,
    });
}
