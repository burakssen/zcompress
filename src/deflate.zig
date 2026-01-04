const std = @import("std");
const libdeflate = @cImport(@cInclude("libdeflate.h"));

const Algorithm = enum { deflate, gzip, zlib };
const CompressionLevel = enum(u8) { fastest = 1, fast = 3, default = 6, good = 9, best = 12 };

const CHUNK_SIZE = 64 * 1024;
const WINDOW_SIZE = 16;

pub const Deflate = struct {
    allocator: std.mem.Allocator,
    algorithm: Algorithm,
    level: CompressionLevel,
    pool: ?*std.Thread.Pool = null,
    pool_mutex: std.Thread.Mutex = .{},

    // Resource pools
    comp_pool: std.ArrayList(*libdeflate.libdeflate_compressor),
    decomp_pool: std.ArrayList(*libdeflate.libdeflate_decompressor),

    pub fn init(allocator: std.mem.Allocator, algo: Algorithm, level: ?CompressionLevel) Deflate {
        return .{
            .allocator = allocator,
            .algorithm = algo,
            .level = level orelse .default,
            .comp_pool = .empty,
            .decomp_pool = .empty,
        };
    }

    pub fn initThreaded(allocator: std.mem.Allocator, pool: *std.Thread.Pool, algo: Algorithm, level: ?CompressionLevel) Deflate {
        return .{
            .allocator = allocator,
            .algorithm = algo,
            .level = level orelse .default,
            .pool = pool,
            .comp_pool = .empty,
            .decomp_pool = .empty,
        };
    }

    pub fn deinit(self: *Deflate) void {
        while (self.comp_pool.pop()) |c| libdeflate.libdeflate_free_compressor(c);
        while (self.decomp_pool.pop()) |d| libdeflate.libdeflate_free_decompressor(d);
        self.comp_pool.deinit(self.allocator);
        self.decomp_pool.deinit(self.allocator);
    }

    // --- Unified Job Context ---

    const Job = struct {
        parent: *Deflate,
        raw_in: []u8,
        raw_out: []u8,
        data_slice: []u8,
        result_size: usize = 0,
        err: ?anyerror = null,
        done: std.Thread.ResetEvent = .{},

        pub fn runCompress(self: *Job) void {
            const comp = self.parent.getCompressor() catch |e| return self.fail(e);
            defer self.parent.returnCompressor(comp);

            // Note: input is self.data_slice (subset of raw_in), output is raw_out
            const size = switch (self.parent.algorithm) {
                .deflate => libdeflate.libdeflate_deflate_compress(comp, self.data_slice.ptr, self.data_slice.len, self.raw_out.ptr, self.raw_out.len),
                .gzip => libdeflate.libdeflate_gzip_compress(comp, self.data_slice.ptr, self.data_slice.len, self.raw_out.ptr, self.raw_out.len),
                .zlib => libdeflate.libdeflate_zlib_compress(comp, self.data_slice.ptr, self.data_slice.len, self.raw_out.ptr, self.raw_out.len),
            };

            if (size == 0) {
                self.err = error.CompressionFailed;
            } else {
                self.result_size = size;
            }
            self.done.set();
        }

        pub fn runDecompress(self: *Job) void {
            const decomp = self.parent.getDecompressor() catch |e| return self.fail(e);
            defer self.parent.returnDecompressor(decomp);

            var actual: usize = 0;
            const res = switch (self.parent.algorithm) {
                .deflate => libdeflate.libdeflate_deflate_decompress(decomp, self.data_slice.ptr, self.data_slice.len, self.raw_out.ptr, self.raw_out.len, &actual),
                .gzip => libdeflate.libdeflate_gzip_decompress(decomp, self.data_slice.ptr, self.data_slice.len, self.raw_out.ptr, self.raw_out.len, &actual),
                .zlib => libdeflate.libdeflate_zlib_decompress(decomp, self.data_slice.ptr, self.data_slice.len, self.raw_out.ptr, self.raw_out.len, &actual),
            };

            if (res != libdeflate.LIBDEFLATE_SUCCESS) {
                self.err = error.BadData;
            } else {
                self.result_size = actual;
            }
            self.done.set();
        }

        fn fail(self: *Job, err: anyerror) void {
            self.err = err;
            self.done.set();
        }
    };

    pub fn compress(self: *Deflate, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        const bound = bound: {
            const c = try self.getCompressor();
            defer self.returnCompressor(c);
            break :bound switch (self.algorithm) {
                .deflate => libdeflate.libdeflate_deflate_compress_bound(c, CHUNK_SIZE),
                .gzip => libdeflate.libdeflate_gzip_compress_bound(c, CHUNK_SIZE),
                .zlib => libdeflate.libdeflate_zlib_compress_bound(c, CHUNK_SIZE),
            };
        };

        var queue: std.ArrayList(*Job) = .empty;
        // FIX 3: Proper cleanup of jobs on error
        defer {
            for (queue.items) |j| self.destroyJob(j);
            queue.deinit(self.allocator);
        }

        var eof = false;
        while (true) {
            // 1. Fill Pipeline
            while (queue.items.len < WINDOW_SIZE and !eof) {
                const in_buf = try self.allocator.alloc(u8, CHUNK_SIZE);
                // We cannot use errdefer free(in_buf) easily here because createJob takes ownership.
                // Instead we rely on the createJob logic or manual cleanup if read fails.

                // Use readAtLeast to try filling the chunk, or just readAll for simplicity with slice
                const n = try reader.readSliceShort(in_buf);
                if (n == 0) {
                    self.allocator.free(in_buf);
                    eof = true;
                    break;
                }

                // If n < CHUNK_SIZE, we just shrink the slice passed to createJob, but keep buffer size
                const job = try self.createJob(in_buf, in_buf[0..n], bound);
                try queue.append(self.allocator, job);

                if (self.pool) |p| {
                    try p.spawn(Job.runCompress, .{job});
                } else {
                    job.runCompress();
                }
            }

            // 2. Drain / Process Oldest
            if (queue.items.len == 0 and eof) break;

            // Wait for the oldest job
            const job = queue.items[0];
            job.done.wait();

            // Pop only after wait is done (though order is preserved anyway)
            _ = queue.orderedRemove(0);
            defer self.destroyJob(job);

            if (job.err) |err| return err;

            try writer.writeInt(u32, @intCast(job.result_size), .little);
            try writer.writeAll(job.raw_out[0..job.result_size]);
        }
    }

    pub fn decompress(self: *Deflate, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        var queue: std.ArrayList(*Job) = .empty;
        defer {
            for (queue.items) |j| self.destroyJob(j);
            queue.deinit(self.allocator);
        }

        var eof = false;
        while (true) {
            while (queue.items.len < WINDOW_SIZE and !eof) {
                const len = reader.takeInt(u32, .little) catch |e| if (e == error.EndOfStream) {
                    eof = true;
                    break;
                } else return e;

                const in_buf = try self.allocator.alloc(u8, len);
                // If read fails, we must free in_buf
                errdefer self.allocator.free(in_buf);

                const n = try reader.readSliceShort(in_buf);
                if (n == 0) {
                    self.allocator.free(in_buf);
                    eof = true;
                    break;
                }

                // FIX 1: Allocate output buffer based on CHUNK_SIZE (Max uncompressed size), not 'len' (compressed size)
                const job = try self.createJob(in_buf, in_buf[0..n], CHUNK_SIZE);
                try queue.append(self.allocator, job);
                if (self.pool) |p| {
                    try p.spawn(Job.runDecompress, .{job});
                } else {
                    job.runDecompress();
                }
            }

            if (queue.items.len == 0 and eof) break;

            const job = queue.items[0];
            job.done.wait();
            _ = queue.orderedRemove(0);
            defer self.destroyJob(job);

            if (job.err) |err| return err;

            try writer.writeAll(job.raw_out[0..job.result_size]);
        }
    }

    // --- Helpers ---

    fn createJob(self: *Deflate, raw_in: []u8, data: []u8, out_cap: usize) !*Job {
        // We catch allocation failure to ensure raw_in is cleaned up if we fail to create the job
        const out_buf = self.allocator.alloc(u8, out_cap) catch |err| {
            self.allocator.free(raw_in);
            return err;
        };
        const job = self.allocator.create(Job) catch |err| {
            self.allocator.free(raw_in);
            self.allocator.free(out_buf);
            return err;
        };

        job.* = .{ .parent = self, .raw_in = raw_in, .data_slice = data, .raw_out = out_buf };
        return job;
    }

    fn destroyJob(self: *Deflate, job: *Job) void {
        self.allocator.free(job.raw_in);
        self.allocator.free(job.raw_out);
        self.allocator.destroy(job);
    }

    fn getCompressor(self: *Deflate) !*libdeflate.libdeflate_compressor {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        if (self.comp_pool.pop()) |c| return c;
        // intFromEnum is correct for recent Zig
        return libdeflate.libdeflate_alloc_compressor(@intFromEnum(self.level)) orelse error.CompressorAllocationFailed;
    }

    fn returnCompressor(self: *Deflate, c: *libdeflate.libdeflate_compressor) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        self.comp_pool.append(self.allocator, c) catch libdeflate.libdeflate_free_compressor(c);
    }

    fn getDecompressor(self: *Deflate) !*libdeflate.libdeflate_decompressor {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        if (self.decomp_pool.pop()) |d| return d;
        return libdeflate.libdeflate_alloc_decompressor() orelse error.DecompressorAllocationFailed;
    }

    fn returnDecompressor(self: *Deflate, d: *libdeflate.libdeflate_decompressor) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        self.decomp_pool.append(self.allocator, d) catch libdeflate.libdeflate_free_decompressor(d);
    }
};

test "Deflate: multithreaded stream roundtrip" {
    const allocator = std.testing.allocator;

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = 4,
    });
    defer pool.deinit();

    var def = Deflate.initThreaded(allocator, &pool, .zlib, .fast);
    defer def.deinit();

    // Reduce size for faster test execution
    const large_size = 1 * 1024 * 1024;
    const big_msg = try allocator.alloc(u8, large_size);
    defer allocator.free(big_msg);
    for (big_msg, 0..) |*b, i| b.* = @intCast(i % 255);

    var compressed_out = std.ArrayList(u8).init(allocator);
    defer compressed_out.deinit();

    var in_stream = std.io.fixedBufferStream(big_msg);
    try def.compress(in_stream.reader(), compressed_out.writer());

    var decompressed_out = std.ArrayList(u8).init(allocator);
    defer decompressed_out.deinit();

    var comp_stream = std.io.fixedBufferStream(compressed_out.items);
    try def.decompress(comp_stream.reader(), decompressed_out.writer());

    try std.testing.expectEqual(big_msg.len, decompressed_out.items.len);
    try std.testing.expectEqualSlices(u8, big_msg, decompressed_out.items);
}
