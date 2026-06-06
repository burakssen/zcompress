const types = @import("../options.zig");
const zstd = @cImport(@cInclude("zstd.h"));

pub const CompressContext = struct {
    ptr: *zstd.ZSTD_CCtx,
};

pub const DecompressContext = struct {
    ptr: *zstd.ZSTD_DCtx,
};

pub fn allocCompressContext(_: @This(), _: types.CompressionLevel) !CompressContext {
    const ptr = zstd.ZSTD_createCCtx() orelse return error.OutOfMemory;
    return .{ .ptr = ptr };
}

pub fn freeCompressContext(_: @This(), ctx: CompressContext) void {
    _ = zstd.ZSTD_freeCCtx(ctx.ptr);
}

pub fn allocDecompressContext(_: @This()) !DecompressContext {
    const ptr = zstd.ZSTD_createDCtx() orelse return error.OutOfMemory;
    return .{ .ptr = ptr };
}

pub fn freeDecompressContext(_: @This(), ctx: DecompressContext) void {
    _ = zstd.ZSTD_freeDCtx(ctx.ptr);
}

pub fn compressBound(_: @This(), _: CompressContext, size: usize) usize {
    return zstd.ZSTD_compressBound(size);
}

pub fn compress(_: @This(), ctx: CompressContext, input: []const u8, output: []u8, level: types.CompressionLevel) !usize {
    const lvl: c_int = switch (level) {
        .default => 3,
        .min => zstd.ZSTD_minCLevel(),
        .max => zstd.ZSTD_maxCLevel(),
        .level => |l| @intCast(l),
    };
    const size = zstd.ZSTD_compressCCtx(ctx.ptr, output.ptr, output.len, input.ptr, input.len, lvl);
    if (zstd.ZSTD_isError(size) == 1) return error.CompressionFailed;
    return size;
}

pub fn decompress(_: @This(), ctx: DecompressContext, input: []const u8, output: []u8) !void {
    const size = zstd.ZSTD_decompressDCtx(ctx.ptr, output.ptr, output.len, input.ptr, input.len);
    if (zstd.ZSTD_isError(size) == 1 or size != output.len) return error.DecompressionFailed;
}
