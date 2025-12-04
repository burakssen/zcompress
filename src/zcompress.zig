const std = @import("std");

pub const Deflate = @import("deflate.zig").Deflate;
pub const Zstd = @import("zstd.zig").Zstd;

pub const Compressor = struct {
    ptr: *anyopaque,
    compressOpaquePtr: *const fn (self: *anyopaque, reader: *std.Io.Reader, writer: *std.Io.Writer) anyerror!void,

    pub fn init(compressor_ptr: anytype) Compressor {
        const T = @TypeOf(compressor_ptr);
        const gen = struct {
            pub fn compressOpaque(ptr: *anyopaque, reader: *std.Io.Reader, writer: *std.Io.Writer) anyerror!void {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.compress(reader, writer);
            }
        };

        return .{
            .ptr = compressor_ptr,
            .compressOpaquePtr = gen.compressOpaque,
        };
    }

    pub fn compress(self: *const Compressor, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        return self.compressOpaquePtr(self.ptr, reader, writer);
    }
};

pub const Decompressor = struct {
    ptr: *anyopaque,
    decompressOpaquePtr: *const fn (self: *anyopaque, reader: *std.Io.Reader, writer: *std.Io.Writer) anyerror!void,

    pub fn init(decompressor_ptr: anytype) Decompressor {
        const T = @TypeOf(decompressor_ptr);
        const gen = struct {
            pub fn decompressOpaque(ptr: *anyopaque, reader: *std.Io.Reader, writer: *std.Io.Writer) anyerror!void {
                const self: T = @ptrCast(@alignCast(ptr));
                return self.decompress(reader, writer);
            }
        };

        return .{
            .ptr = decompressor_ptr,
            .decompressOpaquePtr = gen.decompressOpaque,
        };
    }

    pub fn decompress(self: *const Decompressor, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        return self.decompressOpaquePtr(self.ptr, reader, writer);
    }
};

test {
    _ = Deflate;
}
