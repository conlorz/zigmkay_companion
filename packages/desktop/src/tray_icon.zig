//! A small keyboard PNG, generated entirely in Zig. White keycaps and a dark
//! outline keep it readable against both light and dark system bars.
const std = @import("std");
const width = 24;
const raw_len = width * (1 + width * 4);
pub const png = makePng();

fn put32(out: []u8, value: u32) void {
    std.mem.writeInt(u32, out[0..4], value, .big);
}
fn chunk(out: []u8, offset: *usize, kind: *const [4]u8, data: []const u8) void {
    const start = offset.*;
    put32(out[start..], @intCast(data.len));
    @memcpy(out[start + 4 ..][0..4], kind);
    @memcpy(out[start + 8 ..][0..data.len], data);
    put32(out[start + 8 + data.len ..], std.hash.Crc32.hash(out[start + 4 ..][0 .. 4 + data.len]));
    offset.* += 12 + data.len;
}
fn makePng() [raw_len + 68]u8 {
    @setEvalBranchQuota(100_000);
    var raw: [raw_len]u8 = @splat(0);
    for (0..width) |y| for (0..width) |x| {
        const inside = x >= 2 and x <= 21 and y >= 6 and y <= 17;
        const border = inside and (x == 2 or x == 21 or y == 6 or y == 17);
        const key = inside and x >= 4 and x <= 19 and y >= 8 and y <= 15 and
            (if (y >= 14) x >= 7 and x <= 16 else (x - 4) % 4 < 3 and (y - 8) % 3 < 2);
        const pixel = raw[y * (1 + width * 4) + 1 + x * 4 ..][0..4];
        if (inside) @memcpy(pixel, &[_]u8{ if (key) 255 else 24, if (key) 255 else 24, if (key) 255 else 24, if (border or key) 255 else 220 });
    };
    var compressed: [raw_len + 11]u8 = undefined;
    @memcpy(compressed[0..7], &[_]u8{ 0x78, 0x01, 0x01, raw_len & 255, raw_len >> 8, (~@as(u16, raw_len)) & 255, (~@as(u16, raw_len)) >> 8 });
    @memcpy(compressed[7..][0..raw_len], &raw);
    var a: u32 = 1;
    var b: u32 = 0;
    for (raw) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    put32(compressed[7 + raw_len ..], (b << 16) | a);
    var out: [raw_len + 68]u8 = undefined;
    @memcpy(out[0..8], &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 });
    var header: [13]u8 = @splat(0);
    put32(header[0..], width);
    put32(header[4..], width);
    header[8] = 8;
    header[9] = 6;
    var offset: usize = 8;
    chunk(&out, &offset, "IHDR", &header);
    chunk(&out, &offset, "IDAT", &compressed);
    chunk(&out, &offset, "IEND", "");
    return out;
}

test "embedded keyboard icon decodes as a transparent RGBA PNG" {
    const c = @import("dvui").c;
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const data = c.stbi_load_from_memory(&png, png.len, &w, &h, &channels, 4);
    try std.testing.expect(data != null);
    defer c.stbi_image_free(data);
    try std.testing.expectEqual(@as(c_int, width), w);
    try std.testing.expectEqual(@as(c_int, width), h);
    try std.testing.expectEqual(@as(u8, 0), data[3]);
    try std.testing.expectEqual(@as(u8, 255), data[(8 * width + 4) * 4 + 3]);
}
