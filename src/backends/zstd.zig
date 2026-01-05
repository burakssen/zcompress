const std = @import("std");
const types = @import("../types.zig");
const zstd = @cImport(@cInclude("zstd.h"));

pub const Context = struct {
    cctx: ?*zstd.ZSTD_CCtx,
    dctx: ?*zstd.ZSTD_DCtx,
};

pub fn allocContext(_: @This(), _: types.CompressionLevel) Context {
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

pub fn compress(_: @This(), ctx: Context, in: []const u8, out: []u8, level: types.CompressionLevel) !usize {
    const lvl: c_int = switch (level) {
        .Default => 3,
        .Min => zstd.ZSTD_minCLevel(),
        .Max => zstd.ZSTD_maxCLevel(),
        .Level => |l| @intCast(l),
    };
    const size = zstd.ZSTD_compressCCtx(ctx.cctx, out.ptr, out.len, in.ptr, in.len, lvl);
    if (zstd.ZSTD_isError(size) == 1) return error.CompressionFailed;
    return size;
}

pub fn decompress(_: @This(), ctx: Context, in: []const u8, out: []u8) !void {
    const size = zstd.ZSTD_decompressDCtx(ctx.dctx, out.ptr, out.len, in.ptr, in.len);
    if (zstd.ZSTD_isError(size) == 1 or size != out.len) return error.DecompressionFailed;
}
