const std = @import("std");

pub const Deflate = @import("deflate.zig").Deflate;
pub const Zstd = @import("zstd.zig").Zstd;

pub const Compressor = struct {
    ptr: *anyopaque,
    compressOpaquePtr: *const fn (self: *anyopaque, input: []const u8) anyerror![]u8,

    pub fn init(compressor_ptr: anytype) Compressor {
        const T = @TypeOf(compressor_ptr);
        const gen = struct {
            pub fn compressOpaque(ptr: *anyopaque, input: []const u8) anyerror![]u8 {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.compress(input);
            }
        };

        return .{
            .ptr = compressor_ptr,
            .compressOpaquePtr = gen.compressOpaque,
        };
    }

    pub fn compress(self: *const Compressor, input: []const u8) ![]u8 {
        return self.compressOpaquePtr(self.ptr, input);
    }
};

pub const Decompressor = struct {
    ptr: *anyopaque,
    decompressOpaquePtr: *const fn (self: *anyopaque, input: []const u8) anyerror![]u8,

    pub fn init(decompressor_ptr: anytype) Decompressor {
        const T = @TypeOf(decompressor_ptr);
        const gen = struct {
            pub fn decompressOpaque(ptr: *anyopaque, input: []const u8) anyerror![]u8 {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.decompress(input);
            }
        };

        return .{
            .ptr = decompressor_ptr,
            .decompressOpaquePtr = gen.decompressOpaque,
        };
    }

    pub fn decompress(self: *const Decompressor, input: []const u8) ![]u8 {
        return self.decompressOpaquePtr(self.ptr, input);
    }
};

pub const StreamCompressor = struct {
    ptr: *anyopaque,
    compressStreamOpaquePtr: *const fn (self: *anyopaque, input: []const u8) anyerror![]u8,

    pub fn init(compressor_ptr: anytype) StreamCompressor {
        const T = @TypeOf(compressor_ptr);
        const gen = struct {
            pub fn compressStreamOpaque(ptr: *anyopaque, input: []const u8) anyerror![]u8 {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.compressStream(input);
            }
        };
        return .{
            .ptr = compressor_ptr,
            .compressStreamOpaquePtr = gen.compressStreamOpaque,
        };
    }

    pub fn compressStream(self: *const StreamCompressor, input: []const u8) ![]u8 {
        return self.compressStreamOpaquePtr(self.ptr, input);
    }
};

pub const StreamDecompressor = struct {
    ptr: *anyopaque,
    decompressStreamOpaquePtr: *const fn (self: *anyopaque, input: []const u8) anyerror![]u8,

    pub fn init(decompressor_ptr: anytype) StreamDecompressor {
        const T = @TypeOf(decompressor_ptr);
        const gen = struct {
            pub fn decompressStreamOpaque(ptr: *anyopaque, input: []const u8) anyerror![]u8 {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.decompressStream(input);
            }
        };
        return .{
            .ptr = decompressor_ptr,
            .decompressStreamOpaquePtr = gen.decompressStreamOpaque,
        };
    }

    pub fn decompressStream(self: *const StreamDecompressor, input: []const u8) ![]u8 {
        return self.decompressStreamOpaquePtr(self.ptr, input);
    }
};

test {
    _ = Deflate;
}
