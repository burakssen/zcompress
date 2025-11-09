const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));

pub const CompressionLevel = enum(i32) {
    fastest = 1,
    fast = 3,
    good = 9,
    best = 19,
    ultra = 22, // Max with --ultra flag

    pub fn toInt(self: CompressionLevel) i32 {
        return @intFromEnum(self);
    }
};

pub const Zstd = struct {
    allocator: std.mem.Allocator,
    level: CompressionLevel,

    pub fn init(allocator: std.mem.Allocator, level: ?CompressionLevel) Zstd {
        return .{
            .allocator = allocator,
            .level = level orelse .fast,
        };
    }

    pub fn compress(self: *Zstd, input: []const u8) ![]u8 {
        const bound = zstd.ZSTD_compressBound(input.len);
        const output = try self.allocator.alloc(u8, bound);
        errdefer self.allocator.free(output);

        const compressed_size = zstd.ZSTD_compress(
            output.ptr,
            output.len,
            input.ptr,
            input.len,
            self.level.toInt(),
        );

        if (zstd.ZSTD_isError(compressed_size) != 0) {
            const err_name = zstd.ZSTD_getErrorName(compressed_size);
            std.log.err("ZSTD compression error: {s}", .{err_name});
            self.allocator.free(output);
            return error.CompressionFailed;
        }

        return try self.allocator.realloc(output, compressed_size);
    }

    pub fn decompress(self: *Zstd, input: []const u8) ![]u8 {
        // Get the decompressed size from the frame header
        const decompressed_size = zstd.ZSTD_getFrameContentSize(input.ptr, input.len);

        // ZSTD_CONTENTSIZE_ERROR is (unsigned long long)-2
        // ZSTD_CONTENTSIZE_UNKNOWN is (unsigned long long)-1
        const CONTENTSIZE_ERROR: c_ulonglong = @bitCast(@as(c_longlong, -2));
        const CONTENTSIZE_UNKNOWN: c_ulonglong = @bitCast(@as(c_longlong, -1));

        if (decompressed_size == CONTENTSIZE_ERROR) {
            return error.InvalidFrameHeader;
        }

        // If size is unknown, use streaming decompression with growing buffer
        if (decompressed_size == CONTENTSIZE_UNKNOWN) {
            return self.decompressUnknownSize(input);
        }

        // Allocate exact size needed
        const output = try self.allocator.alloc(u8, decompressed_size);
        errdefer self.allocator.free(output);

        const result = zstd.ZSTD_decompress(
            output.ptr,
            output.len,
            input.ptr,
            input.len,
        );

        if (zstd.ZSTD_isError(result) != 0) {
            const err_name = zstd.ZSTD_getErrorName(result);
            std.log.err("ZSTD decompression error: {s}", .{err_name});
            self.allocator.free(output);
            return error.DecompressionFailed;
        }

        return output;
    }

    fn decompressUnknownSize(self: *Zstd, input: []const u8) ![]u8 {
        var output_size = input.len * 2;
        var output = try self.allocator.alloc(u8, output_size);
        errdefer self.allocator.free(output);

        while (true) {
            const result = zstd.ZSTD_decompress(
                output.ptr,
                output_size,
                input.ptr,
                input.len,
            );

            if (zstd.ZSTD_isError(result) == 0) {
                // Success
                return try self.allocator.realloc(output, result);
            }

            const error_code = zstd.ZSTD_getErrorCode(result);

            // Check for buffer too small error (error code 70)
            if (error_code == @as(c_uint, @intCast(70))) {
                // Need larger buffer
                const new_size = output_size + output_size / 2;
                if (new_size > 1024 * 1024 * 1024) {
                    self.allocator.free(output);
                    return error.DecompressionTooLarge;
                }
                output = try self.allocator.realloc(output, new_size);
                output_size = new_size;
            } else {
                // Other error
                const err_name = zstd.ZSTD_getErrorName(result);
                std.log.err("ZSTD decompression error: {s}", .{err_name});
                self.allocator.free(output);
                return error.DecompressionFailed;
            }
        }
    }

    // Streaming compression for large data
    pub fn compressStream(self: *Zstd, input: []const u8) ![]u8 {
        const cctx = zstd.ZSTD_createCCtx() orelse return error.ContextCreationFailed;
        defer _ = zstd.ZSTD_freeCCtx(cctx);

        const bound = zstd.ZSTD_compressBound(input.len);
        const output = try self.allocator.alloc(u8, bound);
        errdefer self.allocator.free(output);

        var in_buf = zstd.ZSTD_inBuffer_s{
            .src = input.ptr,
            .size = input.len,
            .pos = 0,
        };

        var out_buf = zstd.ZSTD_outBuffer_s{
            .dst = output.ptr,
            .size = output.len,
            .pos = 0,
        };

        _ = zstd.ZSTD_CCtx_setParameter(cctx, zstd.ZSTD_c_compressionLevel, self.level.toInt());

        const remaining = zstd.ZSTD_compressStream2(cctx, &out_buf, &in_buf, zstd.ZSTD_e_end);

        if (zstd.ZSTD_isError(remaining) != 0) {
            const err_name = zstd.ZSTD_getErrorName(remaining);
            std.log.err("ZSTD streaming compression error: {s}", .{err_name});
            self.allocator.free(output);
            return error.CompressionFailed;
        }

        return try self.allocator.realloc(output, out_buf.pos);
    }

    // Streaming decompression for large data
    // Streaming decompression for large data
    pub fn decompressStream(self: *Zstd, input: []const u8) ![]u8 {
        const dctx = zstd.ZSTD_createDCtx() orelse return error.ContextCreationFailed;
        defer _ = zstd.ZSTD_freeDCtx(dctx);

        // Try to get the decompressed size hint
        const size_hint = zstd.ZSTD_getFrameContentSize(input.ptr, input.len);
        const CONTENTSIZE_ERROR: c_ulonglong = @bitCast(@as(c_longlong, -2));
        const CONTENTSIZE_UNKNOWN: c_ulonglong = @bitCast(@as(c_longlong, -1));

        // Start with a reasonable size based on hint or fallback
        var output_size: usize = blk: {
            if (size_hint != CONTENTSIZE_ERROR and size_hint != CONTENTSIZE_UNKNOWN) {
                // Use the exact size from the frame header
                break :blk size_hint;
            } else {
                // Fallback: start with 64x the compressed size (common ratio)
                const initial = input.len * 64;
                break :blk @min(initial, 128 * 1024 * 1024); // Cap at 128MB initial
            }
        };

        // Check size limit upfront
        if (output_size > 2 * 1024 * 1024 * 1024) {
            return error.DecompressionTooLarge;
        }

        var output = try self.allocator.alloc(u8, output_size);
        errdefer self.allocator.free(output);

        var in_buf = zstd.ZSTD_inBuffer_s{
            .src = input.ptr,
            .size = input.len,
            .pos = 0,
        };

        var out_buf = zstd.ZSTD_outBuffer_s{
            .dst = output.ptr,
            .size = output_size,
            .pos = 0,
        };

        while (true) {
            // Ensure we have at least 64KB of space before decompressing
            if (out_buf.size - out_buf.pos < 65536) {
                const new_size = output_size + @max(output_size / 2, 1024 * 1024);

                // Check limit before attempting reallocation
                if (new_size > 2 * 1024 * 1024 * 1024) {
                    self.allocator.free(output);
                    return error.DecompressionTooLarge;
                }

                output = try self.allocator.realloc(output, new_size);
                out_buf.dst = output.ptr;
                out_buf.size = new_size;
                output_size = new_size;
            }

            const result = zstd.ZSTD_decompressStream(dctx, &out_buf, &in_buf);

            if (zstd.ZSTD_isError(result) != 0) {
                const err_name = zstd.ZSTD_getErrorName(result);
                std.log.err("ZSTD streaming decompression error: {s}", .{err_name});
                self.allocator.free(output);
                return error.DecompressionFailed;
            }

            // result == 0 means the frame is complete
            if (result == 0) {
                break;
            }

            // If we've consumed all input and zstd wants more, we have an incomplete frame
            if (in_buf.pos >= in_buf.size and result > 0) {
                self.allocator.free(output);
                return error.IncompleteFrame;
            }
        }

        return try self.allocator.realloc(output, out_buf.pos);
    }
};
