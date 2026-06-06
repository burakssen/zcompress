const types = @import("../options.zig");
pub const libdeflate = @cImport(@cInclude("libdeflate.h"));

kind: Kind,

pub const Kind = enum {
    deflate,
    gzip,
    zlib,
};

pub const Context = struct {
    comp: ?*libdeflate.libdeflate_compressor,
    decomp: ?*libdeflate.libdeflate_decompressor,
};

pub fn init(kind: Kind) @This() {
    return .{ .kind = kind };
}

pub fn allocContext(_: @This(), level: types.CompressionLevel) !Context {
    const lvl: c_int = switch (level) {
        .default => 6,
        .min => 1,
        .max => 12,
        .level => |l| @intCast(l),
    };
    const comp = libdeflate.libdeflate_alloc_compressor(lvl) orelse return error.OutOfMemory;
    errdefer libdeflate.libdeflate_free_compressor(comp);
    const decomp = libdeflate.libdeflate_alloc_decompressor() orelse return error.OutOfMemory;

    return .{ .comp = comp, .decomp = decomp };
}

pub fn freeContext(ctx: Context) void {
    if (ctx.comp) |ptr| libdeflate.libdeflate_free_compressor(ptr);
    if (ctx.decomp) |ptr| libdeflate.libdeflate_free_decompressor(ptr);
}

pub fn compressBound(self: @This(), ctx: Context, size: usize) usize {
    return switch (self.kind) {
        .deflate => libdeflate.libdeflate_deflate_compress_bound(ctx.comp, size),
        .gzip => libdeflate.libdeflate_gzip_compress_bound(ctx.comp, size),
        .zlib => libdeflate.libdeflate_zlib_compress_bound(ctx.comp, size),
    };
}

pub fn compress(self: @This(), ctx: Context, input: []const u8, output: []u8, _: types.CompressionLevel) !usize {
    const size = switch (self.kind) {
        .deflate => libdeflate.libdeflate_deflate_compress(ctx.comp, input.ptr, input.len, output.ptr, output.len),
        .gzip => libdeflate.libdeflate_gzip_compress(ctx.comp, input.ptr, input.len, output.ptr, output.len),
        .zlib => libdeflate.libdeflate_zlib_compress(ctx.comp, input.ptr, input.len, output.ptr, output.len),
    };
    if (size == 0) return error.CompressionFailed;
    return size;
}

pub fn decompress(self: @This(), ctx: Context, input: []const u8, output: []u8) !void {
    var actual: usize = undefined;
    const result = switch (self.kind) {
        .deflate => libdeflate.libdeflate_deflate_decompress(ctx.decomp, input.ptr, input.len, output.ptr, output.len, &actual),
        .gzip => libdeflate.libdeflate_gzip_decompress(ctx.decomp, input.ptr, input.len, output.ptr, output.len, &actual),
        .zlib => libdeflate.libdeflate_zlib_decompress(ctx.decomp, input.ptr, input.len, output.ptr, output.len, &actual),
    };
    if (result != libdeflate.LIBDEFLATE_SUCCESS or actual != output.len) return error.DecompressionFailed;
}
