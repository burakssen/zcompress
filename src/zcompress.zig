const std = @import("std");
const backends = @import("backends/backends.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;

pub const ZCompress = union(enum) {
    deflate: Engine(backends.Deflate),
    gzip: Engine(backends.Deflate),
    zlib: Engine(backends.Deflate),
    zstd: Engine(backends.Zstd),

    pub fn init(allocator: std.mem.Allocator, mode: enum { deflate, gzip, zlib, zstd }) ZCompress {
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

    pub fn compress(self: *ZCompress, r: anytype, w: anytype, level: c_int) !void {
        switch (self.*) {
            inline else => |*impl| try impl.compress(r, w, level),
        }
    }

    pub fn decompress(self: *ZCompress, r: anytype, w: anytype) !void {
        switch (self.*) {
            inline else => |*impl| try impl.decompress(r, w),
        }
    }
};
