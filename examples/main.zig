const std = @import("std");
// Assuming zcompress is available in your build.zig as a module
const zc = @import("zcompress");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try createDummyInput(allocator);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = 8,
    });
    defer pool.deinit();
    var deflate = zc.Deflate.init(allocator, &pool, .zlib, .fast);
    defer deflate.deinit();
    var zstd = zc.Zstd.init(allocator, &pool, .best);
    defer zstd.deinit();

    var deflate_compressor = zc.Compressor.init(&deflate);
    var deflate_decompressor = zc.Decompressor.init(&deflate);

    var zstd_compressor = zc.Compressor.init(&zstd);
    var zstd_decompressor = zc.Decompressor.init(&zstd);

    inline for (&.{
        .{ .name = "Deflate", .compressor = &deflate_compressor, .decompressor = &deflate_decompressor },
        .{ .name = "Zstd", .compressor = &zstd_compressor, .decompressor = &zstd_decompressor },
    }) |tc| {
        std.log.debug("=== Testing {s} ===", .{tc.name});
        try test_compress(tc.compressor, tc.decompressor);
    }
}

pub fn test_compress(
    compressor: *const zc.Compressor,
    decompressor: *const zc.Decompressor,
) !void {
    const input_file = try std.fs.cwd().openFile("input_data.txt", .{});
    defer input_file.close();

    var input_buf: [1024]u8 = undefined;
    var input_buf_reader = input_file.reader(&input_buf);
    const reader = &input_buf_reader.interface;

    const compressed_file = try std.fs.cwd().createFile("compressed_data.txt", .{ .read = true });
    defer compressed_file.close();

    var compressed_buf: [1024]u8 = undefined;
    var compressed_buf_writer = compressed_file.writer(&compressed_buf);
    const writer = &compressed_buf_writer.interface;

    std.log.debug("Compressing...", .{});
    const start_comp = std.time.milliTimestamp();

    try compressor.compress(reader, writer);

    try writer.flush();

    const end_comp = std.time.milliTimestamp();

    const comp_stat = try compressed_file.stat();
    std.log.debug("Compressed size: {d} bytes", .{comp_stat.size});
    std.log.debug("Compression time: {d}ms", .{end_comp - start_comp});

    try compressed_file.seekTo(0);

    var compressed_buf_reader = compressed_file.reader(&compressed_buf);
    const decomp_reader = &compressed_buf_reader.interface;

    const decompressed_file = try std.fs.cwd().createFile("decompressed_data.txt", .{});
    defer decompressed_file.close();

    var decompressed_buf: [1024]u8 = undefined;
    var decompressed_buf_writer = decompressed_file.writer(&decompressed_buf);
    const decomp_writer = &decompressed_buf_writer.interface;

    std.log.debug("Decompressing...", .{});
    const start_decomp = std.time.milliTimestamp();

    try decompressor.decompress(decomp_reader, decomp_writer);

    try decomp_writer.flush();

    const end_decomp = std.time.milliTimestamp();

    const decomp_stat = try decompressed_file.stat();
    std.log.debug("Decompressed size: {d} bytes", .{decomp_stat.size});
    std.log.debug("Decompression time: {d}ms", .{end_decomp - start_decomp});

    const input_stat = try input_file.stat();
    if (input_stat.size == decomp_stat.size) {
        std.log.debug("SUCCESS: Size matches original ({d} bytes).", .{input_stat.size});
    } else {
        std.log.debug("FAILURE: Size mismatch. Original: {d}, Result: {d}", .{ input_stat.size, decomp_stat.size });
    }
}

// Helper to generate a file so the test has something to read
fn createDummyInput(_: std.mem.Allocator) !void {
    const file = try std.fs.cwd().createFile("input_data.txt", .{});
    defer file.close();

    // Create 5MB of repeated text
    const text = "This is a test line for zig compression testing.\n";
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        _ = try file.write(text);
    }
}
