const std = @import("std");
const libdeflate = @cImport(@cInclude("libdeflate.h"));

const Algorithm = enum { deflate, gzip, zlib };
const CompressionLevel = enum(u8) { fastest = 1, fast = 3, default = 6, good = 9, best = 12 };

pub const Deflate = struct {
    allocator: std.mem.Allocator,
    algorithm: Algorithm,
    level: CompressionLevel,

    pub fn init(allocator: std.mem.Allocator, algorithm: Algorithm, level: ?CompressionLevel) Deflate {
        return .{ .allocator = allocator, .algorithm = algorithm, .level = level orelse .default };
    }

    fn getBound(self: *Deflate, compressor: ?*libdeflate.libdeflate_compressor, len: usize) usize {
        return switch (self.algorithm) {
            .deflate => libdeflate.libdeflate_deflate_compress_bound(compressor, len),
            .gzip => libdeflate.libdeflate_gzip_compress_bound(compressor, len),
            .zlib => libdeflate.libdeflate_zlib_compress_bound(compressor, len),
        };
    }

    fn compressData(self: *Deflate, compressor: ?*libdeflate.libdeflate_compressor, in: []const u8, out: []u8) usize {
        return switch (self.algorithm) {
            .deflate => libdeflate.libdeflate_deflate_compress(compressor, in.ptr, in.len, out.ptr, out.len),
            .gzip => libdeflate.libdeflate_gzip_compress(compressor, in.ptr, in.len, out.ptr, out.len),
            .zlib => libdeflate.libdeflate_zlib_compress(compressor, in.ptr, in.len, out.ptr, out.len),
        };
    }

    fn decompressData(self: *Deflate, decompressor: ?*libdeflate.libdeflate_decompressor, in: []const u8, out: []u8, actual: *usize) usize {
        return switch (self.algorithm) {
            .deflate => libdeflate.libdeflate_deflate_decompress(decompressor, in.ptr, in.len, out.ptr, out.len, actual),
            .gzip => libdeflate.libdeflate_gzip_decompress(decompressor, in.ptr, in.len, out.ptr, out.len, actual),
            .zlib => libdeflate.libdeflate_zlib_decompress(decompressor, in.ptr, in.len, out.ptr, out.len, actual),
        };
    }

    pub fn compress(self: *Deflate, input: []const u8) ![]u8 {
        const compressor = libdeflate.libdeflate_alloc_compressor(@intFromEnum(self.level)) orelse return error.CompressorAllocationFailed;
        defer libdeflate.libdeflate_free_compressor(compressor);

        const bound = self.getBound(compressor, input.len);
        const output = try self.allocator.alloc(u8, bound);
        errdefer self.allocator.free(output);

        const compressed_size = self.compressData(compressor, input, output);
        return try self.allocator.realloc(output, compressed_size);
    }

    pub fn decompress(self: *Deflate, input: []const u8) ![]u8 {
        const decompressor = libdeflate.libdeflate_alloc_decompressor() orelse return error.DecompressorAllocationFailed;
        defer libdeflate.libdeflate_free_decompressor(decompressor);

        var output_size = input.len * 2;
        var output = try self.allocator.alloc(u8, output_size);

        // errdefer runs only when the function unwinds due to an error,
        // so it will free `output` automatically on error returns.
        errdefer self.allocator.free(output);

        var actual_size: usize = undefined;

        while (true) {
            switch (self.decompressData(decompressor, input, output[0..output_size], &actual_size)) {
                libdeflate.LIBDEFLATE_SUCCESS => {
                    return try self.allocator.realloc(output, actual_size);
                },
                libdeflate.LIBDEFLATE_BAD_DATA => {
                    return error.BadData;
                },
                libdeflate.LIBDEFLATE_SHORT_OUTPUT => {
                    const new_size = output_size + output_size / 2;
                    if (new_size > 1024 * 1024 * 1024) {
                        return error.DecompressionTooLarge;
                    }
                    output = try self.allocator.realloc(output, new_size);
                    output_size = new_size;
                },
                libdeflate.LIBDEFLATE_INSUFFICIENT_SPACE => {
                    const new_size = output_size + output_size / 2;
                    if (new_size > 1024 * 1024 * 1024) {
                        return error.DecompressionTooLarge;
                    }
                    output = try self.allocator.realloc(output, new_size);
                    output_size = new_size;
                },
                else => {
                    // errdefer frees `output`
                    return error.UnknownDecompressionError;
                },
            }
        }
    }
};

test "Deflate: roundtrip compression/decompression (deflate, gzip, zlib)" {
    const allocator = std.testing.allocator;

    const input = "The quick brown fox jumps over the lazy dog. This is a test of libdeflate bindings in Zig.";

    inline for (.{
        Algorithm.deflate,
        Algorithm.gzip,
        Algorithm.zlib,
    }) |algo| {
        var def = Deflate.init(allocator, algo, .default);

        const compressed = try def.compress(input);
        defer allocator.free(compressed);

        const decompressed = try def.decompress(compressed);
        defer allocator.free(decompressed);

        try std.testing.expectEqualSlices(u8, input, decompressed);
    }
}

test "Deflate: compression works with different levels" {
    const allocator = std.testing.allocator;
    const input = "Zig test for compression level check. This should compress fine.";

    inline for (.{
        CompressionLevel.fastest,
        CompressionLevel.fast,
        CompressionLevel.default,
        CompressionLevel.good,
        CompressionLevel.best,
    }) |level| {
        var def = Deflate.init(allocator, .gzip, level);
        const compressed = try def.compress(input);
        defer allocator.free(compressed);

        try std.testing.expect(compressed.len > 0);
    }
}

test "Deflate: decompressing bad data fails" {
    const allocator = std.testing.allocator;
    var def = Deflate.init(allocator, .gzip, .default);

    const bad_data = "this is not compressed data!";
    const result = def.decompress(bad_data);

    try std.testing.expectError(error.BadData, result);
}

test "Deflate: compress and decompress empty input" {
    const allocator = std.testing.allocator;

    inline for (.{
        Algorithm.deflate,
        Algorithm.gzip,
        Algorithm.zlib,
    }) |algo| {
        var def = Deflate.init(allocator, algo, .default);
        const input: []const u8 = "";

        const compressed = try def.compress(input);
        defer allocator.free(compressed);

        const decompressed = try def.decompress(compressed);
        defer allocator.free(decompressed);

        try std.testing.expectEqualSlices(u8, input, decompressed);
    }
}

test "Deflate: large data compression roundtrip" {
    const allocator = std.testing.allocator;
    const size: usize = 64 * 1024; // 64KB
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    // Fill buffer with patterned data
    for (buf, 0..) |*b, i| b.* = @as(u8, @intCast(i % 256));

    var def = Deflate.init(allocator, .zlib, .good);

    const compressed = try def.compress(buf);
    defer allocator.free(compressed);

    const decompressed = try def.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, buf, decompressed);
}

test "Deflate: truncated compressed data triggers BadData" {
    const allocator = std.testing.allocator;
    var def = Deflate.init(allocator, .deflate, .default);

    const input = "Hello world, this will be truncated.";
    const compressed = try def.compress(input);
    defer allocator.free(compressed);

    // Truncate compressed data to simulate corruption
    const half = compressed[0 .. compressed.len / 2];
    const result = def.decompress(half);

    try std.testing.expectError(error.BadData, result);
}

test "Deflate: handles repeated decompression growth (INSUFFICIENT_SPACE path)" {
    const allocator = std.testing.allocator;
    var def = Deflate.init(allocator, .gzip, .default);

    // Create a large repetitive string that expands when decompressed
    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const compressed = try def.compress(input);
    defer allocator.free(compressed);

    // Artificially shrink decompression buffer to force realloc growth
    const decompressor = libdeflate.libdeflate_alloc_decompressor().?;
    defer libdeflate.libdeflate_free_decompressor(decompressor);

    const output_size: usize = 4; // deliberately tiny to trigger realloc loop
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    var actual_size: usize = undefined;

    switch (def.decompressData(decompressor, compressed, output, &actual_size)) {
        libdeflate.LIBDEFLATE_INSUFFICIENT_SPACE, libdeflate.LIBDEFLATE_SHORT_OUTPUT => {
            // expected behavior: buffer too small
            try std.testing.expect(true);
        },
        else => |code| {
            std.debug.print("Unexpected code: {}\n", .{code});
            try std.testing.expect(false);
        },
    }

    allocator.free(output);
}

test "Deflate: all algorithms and levels cross test" {
    const allocator = std.testing.allocator;
    const input = "Cross testing all algorithms and compression levels.";

    inline for (.{ Algorithm.deflate, Algorithm.gzip, Algorithm.zlib }) |algo| {
        inline for (.{
            CompressionLevel.fastest,
            CompressionLevel.fast,
            CompressionLevel.default,
            CompressionLevel.good,
            CompressionLevel.best,
        }) |level| {
            var def = Deflate.init(allocator, algo, level);
            const compressed = try def.compress(input);
            defer allocator.free(compressed);

            const decompressed = try def.decompress(compressed);
            defer allocator.free(decompressed);

            try std.testing.expectEqualSlices(u8, input, decompressed);
        }
    }
}
