const types = @import("../options.zig");
const zstd = @cImport(@cInclude("zstd.h"));

pub const Context = struct {
    cctx: ?*zstd.ZSTD_CCtx,
    dctx: ?*zstd.ZSTD_DCtx,
};

pub fn allocContext(_: @This(), _: types.CompressionLevel) !Context {
    const cctx = zstd.ZSTD_createCCtx() orelse return error.OutOfMemory;
    errdefer _ = zstd.ZSTD_freeCCtx(cctx);
    const dctx = zstd.ZSTD_createDCtx() orelse return error.OutOfMemory;
    return .{ .cctx = cctx, .dctx = dctx };
}

pub fn freeContext(ctx: Context) void {
    _ = zstd.ZSTD_freeCCtx(ctx.cctx);
    _ = zstd.ZSTD_freeDCtx(ctx.dctx);
}

pub fn compressBound(_: @This(), _: Context, size: usize) usize {
    return zstd.ZSTD_compressBound(size);
}

pub fn compress(_: @This(), ctx: Context, input: []const u8, output: []u8, level: types.CompressionLevel) !usize {
    const lvl: c_int = switch (level) {
        .default => 3,
        .min => zstd.ZSTD_minCLevel(),
        .max => zstd.ZSTD_maxCLevel(),
        .level => |l| @intCast(l),
    };
    const size = zstd.ZSTD_compressCCtx(ctx.cctx, output.ptr, output.len, input.ptr, input.len, lvl);
    if (zstd.ZSTD_isError(size) == 1) return error.CompressionFailed;
    return size;
}

pub fn decompress(_: @This(), ctx: Context, input: []const u8, output: []u8) !void {
    const size = zstd.ZSTD_decompressDCtx(ctx.dctx, output.ptr, output.len, input.ptr, input.len);
    if (zstd.ZSTD_isError(size) == 1 or size != output.len) return error.DecompressionFailed;
}
