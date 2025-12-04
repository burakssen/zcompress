const std = @import("std");
const zstd = @cImport(@cInclude("zstd.h"));

pub const CompressionLevel = enum(c_int) {
    fastest = 1,
    default = 3,
    good = 9,
    best = 19,
    ultra = 22,
};

const CHUNK_SIZE = 64 * 1024;
// Zstd contexts are larger than deflate, so we might want to keep window tighter or same.
const WINDOW_SIZE = 16;

pub const Zstd = struct {
    allocator: std.mem.Allocator,
    level: CompressionLevel,
    pool: *std.Thread.Pool,
    pool_mutex: std.Thread.Mutex = .{},

    // Resource pools
    // Zstd uses CCtx (Compression Context) and DCtx (Decompression Context)
    comp_pool: std.ArrayList(*zstd.ZSTD_CCtx),
    decomp_pool: std.ArrayList(*zstd.ZSTD_DCtx),

    pub fn init(allocator: std.mem.Allocator, pool: *std.Thread.Pool, level: ?CompressionLevel) Zstd {
        return .{
            .allocator = allocator,
            .level = level orelse .default,
            .pool = pool,
            .comp_pool = .empty,
            .decomp_pool = .empty,
        };
    }

    pub fn deinit(self: *Zstd) void {
        while (self.comp_pool.pop()) |c| _ = zstd.ZSTD_freeCCtx(c);
        while (self.decomp_pool.pop()) |d| _ = zstd.ZSTD_freeDCtx(d);
        self.comp_pool.deinit(self.allocator);
        self.decomp_pool.deinit(self.allocator);
    }

    // --- Unified Job Context ---

    const Job = struct {
        parent: *Zstd,
        raw_in: []u8, // Original allocation for freeing
        raw_out: []u8, // Original allocation for freeing
        data_slice: []u8, // Actual data window (slice of raw_in)
        result_size: usize = 0,
        err: ?anyerror = null,
        done: std.Thread.ResetEvent = .{},

        pub fn runCompress(self: *Job) void {
            const cctx = self.parent.getCCtx() catch |e| return self.fail(e);
            defer self.parent.returnCCtx(cctx);

            const src = self.data_slice;
            const dest = self.raw_out;

            // ZSTD_compressCCtx: Compress src into dest using the context.
            // It automatically resets the context session.
            const size = zstd.ZSTD_compressCCtx(
                cctx,
                dest.ptr,
                dest.len,
                src.ptr,
                src.len,
                @intFromEnum(self.parent.level),
            );

            if (zstd.ZSTD_isError(size) != 0) {
                // Ideally log error name: zstd.ZSTD_getErrorName(size)
                self.err = error.CompressionFailed;
            } else {
                self.result_size = size;
            }
            self.done.set();
        }

        pub fn runDecompress(self: *Job) void {
            const dctx = self.parent.getDCtx() catch |e| return self.fail(e);
            defer self.parent.returnDCtx(dctx);

            const src = self.data_slice;
            const dest = self.raw_out;

            // ZSTD_decompressDCtx: Decompress src into dest using the context.
            const size = zstd.ZSTD_decompressDCtx(
                dctx,
                dest.ptr,
                dest.len,
                src.ptr,
                src.len,
            );

            if (zstd.ZSTD_isError(size) != 0) {
                self.err = error.BadData;
            } else {
                self.result_size = size;
            }
            self.done.set();
        }

        fn fail(self: *Job, err: anyerror) void {
            self.err = err;
            self.done.set();
        }
    };

    // --- Stream API ---

    pub fn compress(self: *Zstd, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        // Calculate Max Output Size for a single chunk
        const bound = zstd.ZSTD_compressBound(CHUNK_SIZE);

        var queue: std.ArrayList(*Job) = .empty;
        defer queue.deinit(self.allocator);

        var eof = false;
        while (true) {
            // 1. Fill Pipeline
            while (queue.items.len < WINDOW_SIZE and !eof) {
                const in_buf = try self.allocator.alloc(u8, CHUNK_SIZE);
                errdefer self.allocator.free(in_buf);
                const n = try reader.readSliceShort(in_buf);
                if (n == 0) {
                    self.allocator.free(in_buf);
                    eof = true;
                    break;
                }

                // Compress job uses 'bound' size for output buffer
                const job = try self.createJob(in_buf, in_buf[0..n], bound);
                try queue.append(self.allocator, job);
                try self.pool.spawn(Job.runCompress, .{job});
            }

            // 2. Drain / Process Oldest
            if (queue.items.len == 0 and eof) break;
            const job = queue.orderedRemove(0);
            defer self.destroyJob(job);

            job.done.wait();
            if (job.err) |err| return err;

            // Write format: [u32 length][compressed blob]
            try writer.writeInt(u32, @intCast(job.result_size), .little);
            try writer.writeAll(job.raw_out[0..job.result_size]);
        }
    }

    pub fn decompress(self: *Zstd, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        var queue: std.ArrayList(*Job) = .empty;
        defer queue.deinit(self.allocator);

        var eof = false;
        while (true) {
            // 1. Fill Pipeline
            while (queue.items.len < WINDOW_SIZE and !eof) {
                const len = reader.takeInt(u32, .little) catch |e| if (e == error.EndOfStream) {
                    eof = true;
                    break;
                } else return e;

                const in_buf = try self.allocator.alloc(u8, len);
                try reader.readSliceAll(in_buf);

                // Decompress job expects CHUNK_SIZE output (since we compress fixed chunks)
                const job = try self.createJob(in_buf, in_buf, CHUNK_SIZE);
                try queue.append(self.allocator, job);
                try self.pool.spawn(Job.runDecompress, .{job});
            }

            // 2. Drain / Process Oldest
            if (queue.items.len == 0 and eof) break;
            const job = queue.orderedRemove(0);
            defer self.destroyJob(job);

            job.done.wait();
            if (job.err) |err| return err;

            try writer.writeAll(job.raw_out[0..job.result_size]);
        }
    }

    // --- Helpers ---

    fn createJob(self: *Zstd, raw_in: []u8, data: []u8, out_cap: usize) !*Job {
        const out_buf = try self.allocator.alloc(u8, out_cap);
        const job = try self.allocator.create(Job);
        job.* = .{ .parent = self, .raw_in = raw_in, .data_slice = data, .raw_out = out_buf };
        return job;
    }

    fn destroyJob(self: *Zstd, job: *Job) void {
        self.allocator.free(job.raw_in);
        self.allocator.free(job.raw_out);
        self.allocator.destroy(job);
    }

    // --- Resource Pooling ---

    fn getCCtx(self: *Zstd) !*zstd.ZSTD_CCtx {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        if (self.comp_pool.pop()) |c| return c;

        // ZSTD_createCCtx is thread-safe, but we pool it to avoid allocation overhead
        return zstd.ZSTD_createCCtx() orelse error.CompressorAllocationFailed;
    }

    fn returnCCtx(self: *Zstd, c: *zstd.ZSTD_CCtx) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        self.comp_pool.append(self.allocator, c) catch {
            _ = zstd.ZSTD_freeCCtx(c);
        };
    }

    fn getDCtx(self: *Zstd) !*zstd.ZSTD_DCtx {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        if (self.decomp_pool.pop()) |d| return d;

        return zstd.ZSTD_createDCtx() orelse error.DecompressorAllocationFailed;
    }

    fn returnDCtx(self: *Zstd, d: *zstd.ZSTD_DCtx) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        self.decomp_pool.append(self.allocator, d) catch {
            _ = zstd.ZSTD_freeDCtx(d);
        };
    }
};

// --- Tests ---

test "Zstd: multithreaded stream roundtrip" {
    const allocator = std.testing.allocator;

    var pool = std.Thread.Pool{ .allocator = allocator };
    try pool.init(.{ .n_jobs = 4 });
    defer pool.deinit();

    // Init Zstd instead of Deflate
    var zs = Zstd.init(allocator, &pool, .fast);
    defer zs.deinit();

    const large_size = 20 * 1024 * 1024;
    const big_msg = try allocator.alloc(u8, large_size);
    defer allocator.free(big_msg);
    // Fill with pattern
    for (big_msg, 0..) |*b, i| b.* = @intCast(i % 255);

    var compressed_out: std.Io.Writer.Allocating = .init(allocator);
    defer compressed_out.deinit();

    var in_stream: std.Io.Reader = .fixed(big_msg);
    try zs.compress(&in_stream, &compressed_out.writer);

    std.debug.print("Zstd Compressed size: {d}\n", .{compressed_out.written().len});

    var decompressed_out: std.Io.Writer.Allocating = .init(allocator);
    defer decompressed_out.deinit();

    var comp_stream: std.Io.Reader = .fixed(compressed_out.written());
    try zs.decompress(&comp_stream, &decompressed_out.writer);

    try std.testing.expectEqual(big_msg.len, decompressed_out.written().len);
    try std.testing.expectEqualSlices(u8, big_msg, decompressed_out.written());
}
