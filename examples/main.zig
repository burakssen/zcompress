const std = @import("std");
const zc = @import("zcompress");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create repetitive data that compresses well
    const size = 1000;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);
    @memset(input, 'A');

    var deflate = zc.Deflate.init(allocator, .deflate, .best);
    var compressor = zc.Compressor.init(&deflate);
    var decompressor = zc.Decompressor.init(&deflate);

    const compressed = try compressor.compress(input);
    defer allocator.free(compressed);

    const decompressed = try decompressor.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}
