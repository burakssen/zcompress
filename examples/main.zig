const std = @import("std");
// Assuming zcompress is available in your build.zig as a module
const zc = @import("zcompress");

pub fn main() !void {
    // 1. Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Helper: Create a dummy input file so the test works
    try createDummyInput(allocator);

    // 2. Setup Thread Pool
    // New ThreadPool initialization syntax (Zig 0.12+)
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = 8,
    });
    defer pool.deinit();

    std.debug.print("Starting compression tests...\n", .{});
    std.debug.print("-------------------------\n", .{});
    std.debug.print("Testing Deflate...\n", .{});
    try test_deflate(allocator, &pool);
    std.debug.print("-------------------------\n", .{});
    std.debug.print("Testing Zstd...\n", .{});
    try test_zstd(allocator, &pool);
    std.debug.print("Done.\n", .{});
}

pub fn test_deflate(allocator: std.mem.Allocator, pool: *std.Thread.Pool) !void {
    const cwd = std.fs.cwd();

    // --- PREPARE INPUT ---
    const input_file = try cwd.openFile("input_data.txt", .{});
    defer input_file.close();

    // Create a Buffered Reader for the input (Performance)
    // 4096 is a standard page size, usually better than 1024
    var input_buf: [1024]u8 = undefined;
    var input_buf_reader = input_file.reader(&input_buf);
    const reader = &input_buf_reader.interface;

    // --- PREPARE COMPRESSED OUTPUT ---
    const compressed_file = try cwd.createFile("compressed_data.txt", .{ .read = true });
    defer compressed_file.close();

    var compressed_buf: [1024]u8 = undefined;
    var compressed_buf_writer = compressed_file.writer(&compressed_buf);
    const writer = &compressed_buf_writer.interface;

    // --- INITIALIZE COMPRESSOR ---
    // Assuming zc.Deflate accepts `anytype` for reader/writer in .compress()
    var deflate = zc.Deflate.init(allocator, pool, .deflate, .best);
    defer deflate.deinit();

    // --- COMPRESS ---
    std.debug.print("Compressing...\n", .{});
    const start_comp = std.time.milliTimestamp();

    // Pass the generic reader/writer interfaces
    try deflate.compress(reader, writer);

    // IMPORTANT: Flush the buffer to ensure all bytes are written to disk
    try writer.flush();

    const end_comp = std.time.milliTimestamp();

    // Check size
    const comp_stat = try compressed_file.stat();
    std.debug.print("Compressed size: {d} bytes\n", .{comp_stat.size});
    std.debug.print("Compression time: {d}ms\n", .{end_comp - start_comp});

    // --- PREPARE FOR DECOMPRESSION ---
    // 1. Rewind the compressed file to the beginning so we can read it
    try compressed_file.seekTo(0);

    // 2. Setup reader for the compressed data
    var compressed_buf_reader = compressed_file.reader(&compressed_buf);
    const decomp_reader = &compressed_buf_reader.interface;

    // 3. Setup file for final output
    const decompressed_file = try cwd.createFile("decompressed_data.txt", .{});
    defer decompressed_file.close();

    var decompressed_buf: [1024]u8 = undefined;
    var decompressed_buf_writer = decompressed_file.writer(&decompressed_buf);
    const decomp_writer = &decompressed_buf_writer.interface;

    // --- DECOMPRESS ---
    std.debug.print("Decompressing...\n", .{});
    const start_decomp = std.time.milliTimestamp();

    try deflate.decompress(decomp_reader, decomp_writer);

    // Flush again!
    try decomp_writer.flush();

    const end_decomp = std.time.milliTimestamp();

    const decomp_stat = try decompressed_file.stat();
    std.debug.print("Decompressed size: {d} bytes\n", .{decomp_stat.size});
    std.debug.print("Decompression time: {d}ms\n", .{end_decomp - start_decomp});

    // --- VERIFY ---
    // Simple check: File sizes should match (checking content requires reading both again)
    const input_stat = try input_file.stat();
    if (input_stat.size == decomp_stat.size) {
        std.debug.print("SUCCESS: Size matches original ({d} bytes).\n", .{input_stat.size});
    } else {
        std.debug.print("FAILURE: Size mismatch. Original: {d}, Result: {d}\n", .{ input_stat.size, decomp_stat.size });
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

pub fn test_zstd(allocator: std.mem.Allocator, pool: *std.Thread.Pool) !void {
    const cwd = std.fs.cwd();

    // --- PREPARE INPUT ---
    const input_file = try cwd.openFile("input_data.txt", .{});
    defer input_file.close();

    // Create a Buffered Reader for the input (Performance)
    // 4096 is a standard page size, usually better than 1024
    var input_buf: [1024]u8 = undefined;
    var input_buf_reader = input_file.reader(&input_buf);
    const reader = &input_buf_reader.interface;

    // --- PREPARE COMPRESSED OUTPUT ---
    const compressed_file = try cwd.createFile("compressed_data.txt", .{ .read = true });
    defer compressed_file.close();

    var compressed_buf: [1024]u8 = undefined;
    var compressed_buf_writer = compressed_file.writer(&compressed_buf);
    const writer = &compressed_buf_writer.interface;

    // --- INITIALIZE COMPRESSOR ---
    // Assuming zc.Deflate accepts `anytype` for reader/writer in .compress()
    var zstd = zc.Zstd.init(allocator, pool, .best);
    defer zstd.deinit();

    // --- COMPRESS ---
    std.debug.print("Compressing...\n", .{});
    const start_comp = std.time.milliTimestamp();

    // Pass the generic reader/writer interfaces
    try zstd.compress(reader, writer);

    // IMPORTANT: Flush the buffer to ensure all bytes are written to disk
    try writer.flush();

    const end_comp = std.time.milliTimestamp();

    // Check size
    const comp_stat = try compressed_file.stat();
    std.debug.print("Compressed size: {d} bytes\n", .{comp_stat.size});
    std.debug.print("Compression time: {d}ms\n", .{end_comp - start_comp});

    // --- PREPARE FOR DECOMPRESSION ---
    // 1. Rewind the compressed file to the beginning so we can read it
    try compressed_file.seekTo(0);

    // 2. Setup reader for the compressed data
    var compressed_buf_reader = compressed_file.reader(&compressed_buf);
    const decomp_reader = &compressed_buf_reader.interface;

    // 3. Setup file for final output
    const decompressed_file = try cwd.createFile("decompressed_data.txt", .{});
    defer decompressed_file.close();

    var decompressed_buf: [1024]u8 = undefined;
    var decompressed_buf_writer = decompressed_file.writer(&decompressed_buf);
    const decomp_writer = &decompressed_buf_writer.interface;

    // --- DECOMPRESS ---
    std.debug.print("Decompressing...\n", .{});
    const start_decomp = std.time.milliTimestamp();

    try zstd.decompress(decomp_reader, decomp_writer);

    // Flush again!
    try decomp_writer.flush();

    const end_decomp = std.time.milliTimestamp();

    const decomp_stat = try decompressed_file.stat();
    std.debug.print("Decompressed size: {d} bytes\n", .{decomp_stat.size});
    std.debug.print("Decompression time: {d}ms\n", .{end_decomp - start_decomp});

    // --- VERIFY ---
    // Simple check: File sizes should match (checking content requires reading both again)
    const input_stat = try input_file.stat();
    if (input_stat.size == decomp_stat.size) {
        std.debug.print("SUCCESS: Size matches original ({d} bytes).\n", .{input_stat.size});
    } else {
        std.debug.print("FAILURE: Size mismatch. Original: {d}, Result: {d}\n", .{ input_stat.size, decomp_stat.size });
    }
}
