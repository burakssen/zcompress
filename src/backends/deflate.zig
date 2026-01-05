const std = @import("std");
const types = @import("../types.zig");
pub const libdeflate = @cImport(@cInclude("libdeflate.h"));

type: enum { deflate, gzip, zlib },

pub const Context = struct {
    comp: ?*libdeflate.libdeflate_compressor,
    decomp: ?*libdeflate.libdeflate_decompressor,
};

pub fn allocContext(_: @This(), level: types.CompressionLevel) Context {
    const lvl: c_int = switch (level) {
        .Default => 6,
        .Min => 1,
        .Max => 12,
        .Level => |l| @intCast(l),
    };
    return .{
        .comp = libdeflate.libdeflate_alloc_compressor(lvl),
        .decomp = libdeflate.libdeflate_alloc_decompressor(),
    };
}

pub fn freeContext(ctx: Context) void {
    if (ctx.comp) |p| libdeflate.libdeflate_free_compressor(p);
    if (ctx.decomp) |p| libdeflate.libdeflate_free_decompressor(p);
}

pub fn compressBound(self: @This(), ctx: Context, size: usize) usize {
    return switch (self.type) {
        .deflate => libdeflate.libdeflate_deflate_compress_bound(ctx.comp, size),
        .gzip => libdeflate.libdeflate_gzip_compress_bound(ctx.comp, size),
        .zlib => libdeflate.libdeflate_zlib_compress_bound(ctx.comp, size),
    };
}

pub fn compress(self: @This(), ctx: Context, in: []const u8, out: []u8, _: types.CompressionLevel) !usize {
    const size = switch (self.type) {
        .deflate => libdeflate.libdeflate_deflate_compress(ctx.comp, in.ptr, in.len, out.ptr, out.len),
        .gzip => libdeflate.libdeflate_gzip_compress(ctx.comp, in.ptr, in.len, out.ptr, out.len),
        .zlib => libdeflate.libdeflate_zlib_compress(ctx.comp, in.ptr, in.len, out.ptr, out.len),
    };
    if (size == 0) return error.CompressionFailed;
    return size;
}

pub fn decompress(self: @This(), ctx: Context, in: []const u8, out: []u8) !void {
    var actual: usize = undefined;
    const res = switch (self.type) {
        .deflate => libdeflate.libdeflate_deflate_decompress(ctx.decomp, in.ptr, in.len, out.ptr, out.len, &actual),
        .gzip => libdeflate.libdeflate_gzip_decompress(ctx.decomp, in.ptr, in.len, out.ptr, out.len, &actual),
        .zlib => libdeflate.libdeflate_zlib_decompress(ctx.decomp, in.ptr, in.len, out.ptr, out.len, &actual),
    };
    if (res != libdeflate.LIBDEFLATE_SUCCESS or actual != out.len) return error.DecompressionFailed;
}
