const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));

pub const CLevel = c_int;

pub const Context = struct {
    cctx: ?*zstd.ZSTD_CCtx,
    dctx: ?*zstd.ZSTD_DCtx,
};

pub fn allocContext(_: @This(), _: CLevel) Context {
    return .{
        .cctx = zstd.ZSTD_createCCtx(),
        .dctx = zstd.ZSTD_createDCtx(),
    };
}

pub fn freeContext(ctx: Context) void {
    _ = zstd.ZSTD_freeCCtx(ctx.cctx);
    _ = zstd.ZSTD_freeDCtx(ctx.dctx);
}

pub fn compressBound(_: @This(), _: Context, size: usize) usize {
    return zstd.ZSTD_compressBound(size);
}

pub fn compress(_: @This(), ctx: Context, in: []const u8, out: []u8, level: CLevel) !usize {
    const size = zstd.ZSTD_compressCCtx(ctx.cctx, out.ptr, out.len, in.ptr, in.len, level);
    if (zstd.ZSTD_isError(size) == 1) return error.CompressionFailed;
    return size;
}

pub fn decompress(_: @This(), ctx: Context, in: []const u8, out: []u8) !void {
    const size = zstd.ZSTD_decompressDCtx(ctx.dctx, out.ptr, out.len, in.ptr, in.len);
    if (zstd.ZSTD_isError(size) == 1 or size != out.len) return error.DecompressionFailed;
}
