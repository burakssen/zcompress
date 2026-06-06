const std = @import("std");
const options = @import("options.zig");

pub const magic: [4]u8 = .{ 'Z', 'C', 'M', 'P' };
pub const version: u8 = 1;

pub const Header = struct {
    algorithm: options.Algorithm,
    chunk_size: u32,
    flags: u16 = 0,
};

pub const ChunkHeader = struct {
    sequence: u64,
    original_size: u32,
    compressed_size: u32,
    flags: u16 = 0,

    pub fn end(sequence: u64) ChunkHeader {
        return .{
            .sequence = sequence,
            .original_size = 0,
            .compressed_size = 0,
            .flags = 1,
        };
    }

    pub fn isEnd(self: ChunkHeader) bool {
        return self.flags & 1 == 1 and self.original_size == 0 and self.compressed_size == 0;
    }
};

pub fn writeHeader(writer: *std.Io.Writer, header: Header) !void {
    try writer.writeAll(&magic);
    try writer.writeByte(version);
    try writer.writeByte(@intFromEnum(header.algorithm));
    try writer.writeInt(u16, header.flags, .little);
    try writer.writeInt(u32, header.chunk_size, .little);
    try writer.writeInt(u32, 0, .little);
}

pub fn readHeader(reader: *std.Io.Reader, limits: options.Limits) !Header {
    var got_magic: [4]u8 = undefined;
    try reader.readSliceAll(&got_magic);
    if (!std.mem.eql(u8, &got_magic, &magic)) return error.BadMagic;

    const got_version = try reader.takeByte();
    if (got_version != version) return error.UnsupportedVersion;

    const algorithm_id = try reader.takeByte();
    const algorithm: options.Algorithm = switch (algorithm_id) {
        @intFromEnum(options.Algorithm.deflate) => .deflate,
        @intFromEnum(options.Algorithm.gzip) => .gzip,
        @intFromEnum(options.Algorithm.zlib) => .zlib,
        @intFromEnum(options.Algorithm.zstd) => .zstd,
        else => return error.UnknownAlgorithm,
    };
    const flags = try reader.takeInt(u16, .little);
    const chunk_size = try reader.takeInt(u32, .little);
    _ = try reader.takeInt(u32, .little);

    if (chunk_size == 0) return error.InvalidChunkSize;
    if (chunk_size > limits.max_chunk_size) return error.ChunkSizeLimitExceeded;

    return .{
        .algorithm = algorithm,
        .chunk_size = chunk_size,
        .flags = flags,
    };
}

pub fn writeChunkHeader(writer: *std.Io.Writer, header: ChunkHeader) !void {
    try writer.writeInt(u64, header.sequence, .little);
    try writer.writeInt(u32, header.original_size, .little);
    try writer.writeInt(u32, header.compressed_size, .little);
    try writer.writeInt(u16, header.flags, .little);
    try writer.writeInt(u16, 0, .little);
}

pub fn readChunkHeader(reader: *std.Io.Reader, limits: options.Limits) !ChunkHeader {
    const header = ChunkHeader{
        .sequence = try reader.takeInt(u64, .little),
        .original_size = try reader.takeInt(u32, .little),
        .compressed_size = try reader.takeInt(u32, .little),
        .flags = try reader.takeInt(u16, .little),
    };
    _ = try reader.takeInt(u16, .little);

    if (header.isEnd()) return header;
    if (header.original_size == 0) return error.InvalidChunkHeader;
    if (header.compressed_size == 0) return error.InvalidChunkHeader;
    if (header.original_size > limits.max_chunk_size) return error.ChunkSizeLimitExceeded;
    if (header.compressed_size > limits.max_compressed_chunk_size) return error.CompressedChunkSizeLimitExceeded;
    return header;
}

test "format header roundtrip" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeHeader(&writer.writer, .{ .algorithm = .zstd, .chunk_size = 4096 });
    try writer.writer.flush();

    var reader: std.Io.Reader = .fixed(writer.written());
    const decoded = try readHeader(&reader, .{});

    try std.testing.expectEqual(options.Algorithm.zstd, decoded.algorithm);
    try std.testing.expectEqual(@as(u32, 4096), decoded.chunk_size);
}
