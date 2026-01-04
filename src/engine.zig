const std = @import("std");
const types = @import("types.zig");

pub fn Engine(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const Context = Backend.Context;

        const Job = struct {
            in: []const u8,
            out: []u8,
            header: types.ChunkHeader = undefined, // Populated after compression
            ctx: Context,
            backend: Backend,
            config: types.JobConfig,
            done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            err: ?anyerror = null,

            fn runCompress(self: *Job) void {
                defer self.done.store(true, .release);
                const size = self.backend.compress(self.ctx, self.in, self.out, self.config.level) catch |e| {
                    self.err = e;
                    return;
                };
                self.header = .{ .original_size = @intCast(self.in.len), .compressed_size = @intCast(size) };
            }

            fn runDecompress(self: *Job) void {
                defer self.done.store(true, .release);
                self.backend.decompress(self.ctx, self.in, self.out) catch |e| {
                    self.err = e;
                };
            }
        };

        allocator: std.mem.Allocator,
        backend: Backend,
        chunk_size: usize = 64 * 1024,
        threads: usize,

        pub fn init(allocator: std.mem.Allocator, backend: Backend) Self {
            return .{
                .allocator = allocator,
                .backend = backend,
                .threads = std.Thread.getCpuCount() catch 4,
            };
        }

        pub fn compress(self: *Self, reader: anytype, writer: anytype, level: c_int) !void {
            var chunks: std.ArrayList([]u8) = .empty;
            defer {
                for (chunks.items) |c| self.allocator.free(c);
                chunks.deinit(self.allocator);
            }

            // 1. Read All Chunks
            while (true) {
                const buf = try self.allocator.alloc(u8, self.chunk_size);
                const n = try reader.readSliceShort(buf);
                if (n == 0) {
                    self.allocator.free(buf);
                    break;
                }
                try chunks.append(self.allocator, if (n < buf.len) try self.allocator.realloc(buf, n) else buf);
            }

            if (chunks.items.len == 0) return writeHeader(writer, types.ChunkHeader.end());

            // 2. Setup Thread Pool & Jobs
            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = self.allocator, .n_jobs = self.threads });
            defer pool.deinit();

            // Create one context per thread to reuse (optimization) or per job
            // For simplicity/correctness with blocking pool, we allocate per job here,
            // but in a real pool you'd use thread-local storage or a resource pool.
            // Given the original code's structure, we alloc context per job.

            const jobs = try self.allocator.alloc(Job, chunks.items.len);
            defer self.allocator.free(jobs);

            const out_bufs = try self.allocator.alloc([]u8, chunks.items.len);
            defer {
                for (out_bufs) |b| self.allocator.free(b);
                self.allocator.free(out_bufs);
            }

            // 3. Spawn
            // Temp Context for bound calc
            const tmp_ctx = self.backend.allocContext(level);
            defer Backend.freeContext(tmp_ctx);
            const max_out = self.backend.compressBound(tmp_ctx, self.chunk_size);

            for (chunks.items, 0..) |chunk, i| {
                out_bufs[i] = try self.allocator.alloc(u8, max_out);
                jobs[i] = .{
                    .in = chunk,
                    .out = out_bufs[i],
                    .ctx = self.backend.allocContext(level),
                    .backend = self.backend,
                    .config = .{ .level = level },
                };
                try pool.spawn(Job.runCompress, .{&jobs[i]});
            }

            waitAndCleanup(jobs);

            // 4. Write
            for (jobs) |job| {
                if (job.err) |e| return e;
                try writeHeader(writer, job.header);
                try writer.writeAll(job.out[0..job.header.compressed_size]);
            }
            try writeHeader(writer, types.ChunkHeader.end());
        }

        pub fn decompress(self: *Self, reader: anytype, writer: anytype) !void {
            var input_data: std.ArrayList([]u8) = .empty;
            defer {
                for (input_data.items) |b| self.allocator.free(b);
                input_data.deinit(self.allocator);
            }

            var headers: std.ArrayList(types.ChunkHeader) = .empty;
            defer headers.deinit(self.allocator);

            // 1. Read All Metadata
            while (true) {
                var h_bytes: [8]u8 = undefined;
                if (try reader.readSliceShort(&h_bytes) != 8) break;

                var h: types.ChunkHeader = undefined;
                h = std.mem.bytesToValue(types.ChunkHeader, &h_bytes); // Simpler than manual packing
                if (h.isEnd()) break;

                const buf = try self.allocator.alloc(u8, h.compressed_size);
                if (try reader.readSliceShort(buf) != h.compressed_size) return error.IncompleteChunk;

                try headers.append(self.allocator, h);
                try input_data.append(self.allocator, buf);
            }

            if (headers.items.len == 0) return;

            // 2. Setup
            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = self.allocator, .n_jobs = self.threads });
            defer pool.deinit();

            const jobs = try self.allocator.alloc(Job, headers.items.len);
            defer self.allocator.free(jobs);

            const out_bufs = try self.allocator.alloc([]u8, headers.items.len);
            defer {
                for (out_bufs) |b| self.allocator.free(b);
                self.allocator.free(out_bufs);
            }

            // 3. Spawn
            for (headers.items, 0..) |h, i| {
                out_bufs[i] = try self.allocator.alloc(u8, h.original_size);
                jobs[i] = .{
                    .in = input_data.items[i],
                    .out = out_bufs[i],
                    .ctx = self.backend.allocContext(0), // Level 0 for decomp
                    .backend = self.backend,
                    .config = .{ .level = 0 },
                };
                try pool.spawn(Job.runDecompress, .{&jobs[i]});
            }

            waitAndCleanup(jobs);

            // 4. Write
            for (jobs) |job| {
                if (job.err) |e| return e;
                try writer.writeAll(job.out);
            }
        }

        fn waitAndCleanup(jobs: []Job) void {
            while (true) {
                var all = true;
                for (jobs) |*j| if (!j.done.load(.acquire)) {
                    all = false;
                    break;
                };
                if (all) break;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            for (jobs) |j| Backend.freeContext(j.ctx);
        }

        fn writeHeader(w: anytype, h: types.ChunkHeader) !void {
            const bytes = std.mem.toBytes(h);
            try w.writeAll(&bytes);
        }
    };
}
