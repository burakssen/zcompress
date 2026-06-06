const std = @import("std");

pub const Algorithm = enum(u8) {
    deflate = 1,
    gzip = 2,
    zlib = 3,
    zstd = 4,
};

pub const CompressionLevel = union(enum) {
    default,
    min,
    max,
    level: i32,
};

pub const Limits = struct {
    max_chunk_size: usize = 16 * 1024 * 1024,
    max_compressed_chunk_size: usize = 32 * 1024 * 1024,
    max_threads: usize = 64,

    pub fn validate(self: Limits) !void {
        if (self.max_chunk_size == 0) return error.InvalidLimit;
        if (self.max_compressed_chunk_size == 0) return error.InvalidLimit;
        if (self.max_threads == 0) return error.InvalidLimit;
    }
};

pub const Options = struct {
    algorithm: Algorithm = .zstd,
    level: CompressionLevel = .default,
    chunk_size: usize = 64 * 1024,
    threads: usize = 0,
    limits: Limits = .{},

    pub fn normalize(self: Options) !Options {
        try self.limits.validate();
        if (self.chunk_size == 0) return error.InvalidChunkSize;
        if (self.chunk_size > self.limits.max_chunk_size) return error.ChunkSizeLimitExceeded;

        var out = self;
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const requested = if (self.threads == 0) cpu_count else self.threads;
        out.threads = @max(1, @min(requested, self.limits.max_threads));
        return out;
    }
};

pub const DecompressOptions = struct {
    limits: Limits = .{},
    threads: usize = 0,

    pub fn normalize(self: DecompressOptions) !DecompressOptions {
        try self.limits.validate();
        var out = self;
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const requested = if (self.threads == 0) cpu_count else self.threads;
        out.threads = @max(1, @min(requested, self.limits.max_threads));
        return out;
    }
};
