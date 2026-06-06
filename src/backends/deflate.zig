const types = @import("../options.zig");
pub const libdeflate = @cImport(@cInclude("libdeflate.h"));

kind: Kind,
level: types.CompressionLevel,

pub const Kind = enum {
    deflate,
    gzip,
    zlib,
};

pub const CompressContext = struct {
    ptr: *libdeflate.libdeflate_compressor,
};

pub const DecompressContext = struct {
    ptr: *libdeflate.libdeflate_decompressor,
};

pub fn init(kind: Kind, level: types.CompressionLevel) @This() {
    return .{
        .kind = kind,
        .level = level,
    };
}

pub fn allocCompressContext(self: @This()) !CompressContext {
    const lvl: c_int = switch (self.level) {
        .default => 6,
        .min => 1,
        .max => 12,
        .level => |l| @intCast(l),
    };
    const ptr = libdeflate.libdeflate_alloc_compressor(lvl) orelse return error.OutOfMemory;
    return .{ .ptr = ptr };
}

pub fn freeCompressContext(_: @This(), ctx: CompressContext) void {
    libdeflate.libdeflate_free_compressor(ctx.ptr);
}

pub fn allocDecompressContext(_: @This()) !DecompressContext {
    const ptr = libdeflate.libdeflate_alloc_decompressor() orelse return error.OutOfMemory;
    return .{ .ptr = ptr };
}

pub fn freeDecompressContext(_: @This(), ctx: DecompressContext) void {
    libdeflate.libdeflate_free_decompressor(ctx.ptr);
}

pub fn compressBound(self: @This(), ctx: CompressContext, size: usize) usize {
    return switch (self.kind) {
        .deflate => libdeflate.libdeflate_deflate_compress_bound(ctx.ptr, size),
        .gzip => libdeflate.libdeflate_gzip_compress_bound(ctx.ptr, size),
        .zlib => libdeflate.libdeflate_zlib_compress_bound(ctx.ptr, size),
    };
}

pub fn compress(self: @This(), ctx: CompressContext, input: []const u8, output: []u8) !usize {
    const size = switch (self.kind) {
        .deflate => libdeflate.libdeflate_deflate_compress(ctx.ptr, input.ptr, input.len, output.ptr, output.len),
        .gzip => libdeflate.libdeflate_gzip_compress(ctx.ptr, input.ptr, input.len, output.ptr, output.len),
        .zlib => libdeflate.libdeflate_zlib_compress(ctx.ptr, input.ptr, input.len, output.ptr, output.len),
    };
    if (size == 0) return error.CompressionFailed;
    return size;
}

pub fn decompress(self: @This(), ctx: DecompressContext, input: []const u8, output: []u8) !void {
    var actual: usize = undefined;
    const result = switch (self.kind) {
        .deflate => libdeflate.libdeflate_deflate_decompress(ctx.ptr, input.ptr, input.len, output.ptr, output.len, &actual),
        .gzip => libdeflate.libdeflate_gzip_decompress(ctx.ptr, input.ptr, input.len, output.ptr, output.len, &actual),
        .zlib => libdeflate.libdeflate_zlib_decompress(ctx.ptr, input.ptr, input.len, output.ptr, output.len, &actual),
    };
    if (result != libdeflate.LIBDEFLATE_SUCCESS or actual != output.len) return error.DecompressionFailed;
}
