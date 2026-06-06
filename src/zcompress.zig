const std = @import("std");

pub const options = @import("options.zig");
pub const format = @import("format.zig");

const pipeline = @import("pipeline.zig");
const backends = @import("backends/backends.zig");

pub const Algorithm = options.Algorithm;
pub const CompressionLevel = options.CompressionLevel;
pub const Limits = options.Limits;
pub const Options = options.Options;
pub const DecompressOptions = options.DecompressOptions;

pub fn compress(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    opts: Options,
) !void {
    const normalized = try opts.normalize();
    try format.writeHeader(writer, .{
        .algorithm = normalized.algorithm,
        .chunk_size = @intCast(normalized.chunk_size),
    });

    const chunk_count = switch (normalized.algorithm) {
        .deflate => try compressWith(backends.Deflate, backends.Deflate.init(.deflate), io, allocator, reader, writer, normalized),
        .gzip => try compressWith(backends.Deflate, backends.Deflate.init(.gzip), io, allocator, reader, writer, normalized),
        .zlib => try compressWith(backends.Deflate, backends.Deflate.init(.zlib), io, allocator, reader, writer, normalized),
        .zstd => try compressWith(backends.Zstd, .{}, io, allocator, reader, writer, normalized),
    };

    try format.writeChunkHeader(writer, format.ChunkHeader.end(chunk_count));
}

pub fn decompress(
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    opts: DecompressOptions,
) !void {
    const normalized = try opts.normalize();
    const header = try format.readHeader(reader, normalized.limits);

    switch (header.algorithm) {
        .deflate => try decompressWith(backends.Deflate, backends.Deflate.init(.deflate), io, allocator, reader, writer, normalized, header),
        .gzip => try decompressWith(backends.Deflate, backends.Deflate.init(.gzip), io, allocator, reader, writer, normalized, header),
        .zlib => try decompressWith(backends.Deflate, backends.Deflate.init(.zlib), io, allocator, reader, writer, normalized, header),
        .zstd => try decompressWith(backends.Zstd, .{}, io, allocator, reader, writer, normalized, header),
    }
}

fn compressWith(
    comptime Backend: type,
    backend: Backend,
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    opts: Options,
) !u64 {
    var engine = pipeline.Engine(Backend).init(allocator, backend, opts.threads, opts.chunk_size, opts.level);
    return try engine.compress(io, reader, writer);
}

fn decompressWith(
    comptime Backend: type,
    backend: Backend,
    io: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    opts: DecompressOptions,
    header: format.Header,
) !void {
    var engine = pipeline.Engine(Backend).init(allocator, backend, opts.threads, header.chunk_size, .default);
    try engine.decompress(io, reader, writer, opts.limits);
}

test {
    _ = format;
}

fn roundTrip(algorithm: Algorithm, input: []const u8, chunk_size: usize) !void {
    var compressed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compressed.deinit();

    var source: std.Io.Reader = .fixed(input);
    try compress(std.testing.io, std.testing.allocator, &source, &compressed.writer, .{
        .algorithm = algorithm,
        .chunk_size = chunk_size,
        .threads = 2,
    });
    try compressed.writer.flush();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var encoded: std.Io.Reader = .fixed(compressed.written());
    try decompress(std.testing.io, std.testing.allocator, &encoded, &output.writer, .{ .threads = 2 });
    try output.writer.flush();

    try std.testing.expectEqualSlices(u8, input, output.written());
}

test "roundtrip zstd empty" {
    try roundTrip(.zstd, "", 1024);
}

test "roundtrip all algorithms small" {
    const input = "hello zcompress\n" ** 128;
    try roundTrip(.deflate, input, 127);
    try roundTrip(.gzip, input, 127);
    try roundTrip(.zlib, input, 127);
    try roundTrip(.zstd, input, 127);
}

test "roundtrip multi chunk incompressible-ish" {
    var input: [8192]u8 = undefined;
    for (&input, 0..) |*byte, i| {
        byte.* = @intCast((i * 131 + i / 7) & 0xff);
    }
    try roundTrip(.zstd, &input, 511);
}

test "reject bad magic" {
    var reader: std.Io.Reader = .fixed("bad stream");
    var output: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.BadMagic, decompress(std.testing.io, std.testing.allocator, &reader, &output.writer, .{}));
}
