const std = @import("std");
const zc = @import("zcompress");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const data_size = 50 * 1024 * 1024;

    const input = try allocator.alloc(u8, data_size);
    defer allocator.free(input);

    for (input, 0..) |*byte, i| {
        byte.* = @intCast(((i % 251) ^ (i / 1024)) & 0xff);
    }

    var compressed: std.Io.Writer.Allocating = .init(allocator);
    defer compressed.deinit();

    var source: std.Io.Reader = .fixed(input);
    const start_compress = std.Io.Clock.now(.awake, init.io);
    try zc.compress(init.io, allocator, &source, &compressed.writer, .{
        .algorithm = .zstd,
        .level = .default,
        .chunk_size = 256 * 1024,
    });
    try compressed.writer.flush();
    const end_compress = std.Io.Clock.now(.awake, init.io);

    var decoded: std.Io.Writer.Allocating = .init(allocator);
    defer decoded.deinit();

    var encoded: std.Io.Reader = .fixed(compressed.written());
    const start_decompress = std.Io.Clock.now(.awake, init.io);
    try zc.decompress(init.io, allocator, &encoded, &decoded.writer, .{});
    try decoded.writer.flush();
    const end_decompress = std.Io.Clock.now(.awake, init.io);

    if (!std.mem.eql(u8, input, decoded.written())) return error.DataCorruption;

    std.debug.print("input={d} compressed={d} compress_ms={d} decompress_ms={d}\n", .{
        input.len,
        compressed.written().len,
        start_compress.durationTo(end_compress).toMilliseconds(),
        start_decompress.durationTo(end_decompress).toMilliseconds(),
    });
}
