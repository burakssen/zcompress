const std = @import("std");
const types = @import("types.zig");
const backends = @import("backends/backends.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;

pub const ZCompressionLevel = types.CompressionLevel;
pub const ZCompressionType = types.CompressionType;

pub const ZCompress = union(ZCompressionType) {
    deflate: Engine(backends.Deflate),
    gzip: Engine(backends.Deflate),
    zlib: Engine(backends.Deflate),
    zstd: Engine(backends.Zstd),

    pub fn init(allocator: std.mem.Allocator, mode: ZCompressionType) ZCompress {
        return switch (mode) {
            .deflate => .{ .deflate = Engine(backends.Deflate).init(allocator, .{ .type = .deflate }) },
            .gzip => .{ .gzip = Engine(backends.Deflate).init(allocator, .{ .type = .gzip }) },
            .zlib => .{ .zlib = Engine(backends.Deflate).init(allocator, .{ .type = .zlib }) },
            .zstd => .{ .zstd = Engine(backends.Zstd).init(allocator, .{}) },
        };
    }

    pub fn setThreadCount(self: *ZCompress, count: usize) void {
        const n = @max(1, count);
        switch (self.*) {
            inline else => |*impl| impl.threads = n,
        }
    }

    pub fn compress(self: *ZCompress, r: *std.Io.Reader, w: *std.Io.Writer, level: types.CompressionLevel) !void {
        switch (self.*) {
            inline else => |*impl| try impl.compress(r, w, level),
        }
    }

    pub fn decompress(self: *ZCompress, r: *std.Io.Reader, w: *std.Io.Writer) !void {
        switch (self.*) {
            inline else => |*impl| try impl.decompress(r, w),
        }
    }
};
