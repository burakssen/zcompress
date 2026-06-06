const std = @import("std");
const format = @import("format.zig");
const options = @import("options.zig");

pub fn Engine(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const Context = Backend.Context;

        const Direction = enum { compress, decompress };

        const Chunk = struct {
            sequence: u64,
            input: []u8,
            input_full: []u8,
            output: []u8,
            header: format.ChunkHeader,
        };

        const ChunkQueue = std.Io.Queue(*Chunk);
        const VoidFuture = std.Io.Future(anyerror!void);
        const CountFuture = std.Io.Future(anyerror!u64);

        const Pipeline = struct {
            io: std.Io,
            allocator: std.mem.Allocator,
            backend: Backend,
            in_queue: *ChunkQueue,
            out_queue: *ChunkQueue,
            direction: Direction,
            level: options.CompressionLevel,

            fn worker(self: *Pipeline) anyerror!void {
                const ctx = try self.backend.allocContext(self.level);
                defer Backend.freeContext(ctx);

                while (true) {
                    const chunk = self.in_queue.getOne(self.io) catch |err| switch (err) {
                        error.Closed => return,
                        else => return err,
                    };

                    switch (self.direction) {
                        .compress => {
                            const written = self.backend.compress(ctx, chunk.input, chunk.output, self.level) catch |err| {
                                self.in_queue.close(self.io);
                                destroyChunk(self.allocator, chunk);
                                return err;
                            };
                            chunk.header.compressed_size = @intCast(written);
                        },
                        .decompress => {
                            self.backend.decompress(ctx, chunk.input, chunk.output) catch |err| {
                                self.in_queue.close(self.io);
                                destroyChunk(self.allocator, chunk);
                                return err;
                            };
                        },
                    }

                    self.out_queue.putOne(self.io, chunk) catch |err| {
                        destroyChunk(self.allocator, chunk);
                        return err;
                    };
                }
            }
        };

        allocator: std.mem.Allocator,
        backend: Backend,
        threads: usize,
        chunk_size: usize,
        level: options.CompressionLevel,

        pub fn init(allocator: std.mem.Allocator, backend: Backend, threads: usize, chunk_size: usize, level: options.CompressionLevel) Self {
            return .{
                .allocator = allocator,
                .backend = backend,
                .threads = @max(1, threads),
                .chunk_size = chunk_size,
                .level = level,
            };
        }

        pub fn compress(self: *Self, io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer) !u64 {
            const queue_capacity = @max(1, self.threads * 2);
            const in_storage = try self.allocator.alloc(*Chunk, queue_capacity);
            defer self.allocator.free(in_storage);
            const out_storage = try self.allocator.alloc(*Chunk, queue_capacity);
            defer self.allocator.free(out_storage);

            var in_queue = ChunkQueue.init(in_storage);
            var out_queue = ChunkQueue.init(out_storage);
            defer drainQueue(&in_queue, io, self.allocator);
            defer drainQueue(&out_queue, io, self.allocator);

            var pipeline = Pipeline{
                .io = io,
                .allocator = self.allocator,
                .backend = self.backend,
                .in_queue = &in_queue,
                .out_queue = &out_queue,
                .direction = .compress,
                .level = self.level,
            };

            var worker_futures = try self.allocator.alloc(VoidFuture, self.threads);
            defer self.allocator.free(worker_futures);
            var workers_started: usize = 0;

            for (worker_futures) |*future| {
                future.* = io.concurrent(Pipeline.worker, .{&pipeline}) catch |err| {
                    in_queue.close(io);
                    out_queue.close(io);
                    cancelVoidFutures(io, worker_futures[0..workers_started]);
                    return err;
                };
                workers_started += 1;
            }

            var writer_future = io.concurrent(compressWriter, .{ &pipeline, writer }) catch |err| {
                in_queue.close(io);
                out_queue.close(io);
                cancelVoidFutures(io, worker_futures[0..workers_started]);
                return err;
            };

            var reader_future = io.concurrent(compressReader, .{ &pipeline, self, reader }) catch |err| {
                in_queue.close(io);
                out_queue.close(io);
                cancelVoidFutures(io, worker_futures[0..workers_started]);
                _ = writer_future.cancel(io) catch {};
                return err;
            };

            var result_error: ?anyerror = null;
            rememberError(&result_error, reader_future.await(io) catch |err| err);
            in_queue.close(io);

            for (worker_futures[0..workers_started]) |*future| {
                rememberError(&result_error, future.await(io) catch |err| err);
            }
            out_queue.close(io);

            const chunk_count = writer_future.await(io) catch |err| blk: {
                rememberError(&result_error, err);
                break :blk 0;
            };

            if (result_error) |err| return err;
            return chunk_count;
        }

        pub fn decompress(self: *Self, io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer, limits: options.Limits) !void {
            const queue_capacity = @max(1, self.threads * 2);
            const in_storage = try self.allocator.alloc(*Chunk, queue_capacity);
            defer self.allocator.free(in_storage);
            const out_storage = try self.allocator.alloc(*Chunk, queue_capacity);
            defer self.allocator.free(out_storage);

            var in_queue = ChunkQueue.init(in_storage);
            var out_queue = ChunkQueue.init(out_storage);
            defer drainQueue(&in_queue, io, self.allocator);
            defer drainQueue(&out_queue, io, self.allocator);

            var pipeline = Pipeline{
                .io = io,
                .allocator = self.allocator,
                .backend = self.backend,
                .in_queue = &in_queue,
                .out_queue = &out_queue,
                .direction = .decompress,
                .level = self.level,
            };

            var worker_futures = try self.allocator.alloc(VoidFuture, self.threads);
            defer self.allocator.free(worker_futures);
            var workers_started: usize = 0;

            for (worker_futures) |*future| {
                future.* = io.concurrent(Pipeline.worker, .{&pipeline}) catch |err| {
                    in_queue.close(io);
                    out_queue.close(io);
                    cancelVoidFutures(io, worker_futures[0..workers_started]);
                    return err;
                };
                workers_started += 1;
            }

            var writer_future = io.concurrent(decompressWriter, .{ &pipeline, writer }) catch |err| {
                in_queue.close(io);
                out_queue.close(io);
                cancelVoidFutures(io, worker_futures[0..workers_started]);
                return err;
            };

            var reader_future = io.concurrent(decompressReader, .{ &pipeline, reader, limits }) catch |err| {
                in_queue.close(io);
                out_queue.close(io);
                cancelVoidFutures(io, worker_futures[0..workers_started]);
                _ = writer_future.cancel(io) catch {};
                return err;
            };

            var result_error: ?anyerror = null;
            rememberError(&result_error, reader_future.await(io) catch |err| err);
            in_queue.close(io);

            for (worker_futures[0..workers_started]) |*future| {
                rememberError(&result_error, future.await(io) catch |err| err);
            }
            out_queue.close(io);

            rememberError(&result_error, writer_future.await(io) catch |err| err);
            if (result_error) |err| return err;
        }

        fn compressReader(p: *Pipeline, s: *Self, reader: *std.Io.Reader) anyerror!void {
            defer p.in_queue.close(p.io);

            var sequence: u64 = 0;
            const tmp_ctx = try p.backend.allocContext(s.level);
            defer Backend.freeContext(tmp_ctx);
            const max_output = p.backend.compressBound(tmp_ctx, s.chunk_size);

            while (true) {
                const input = try p.allocator.alloc(u8, s.chunk_size);
                errdefer p.allocator.free(input);

                const read = try reader.readSliceShort(input);
                if (read == 0) {
                    p.allocator.free(input);
                    return;
                }

                const output = try p.allocator.alloc(u8, max_output);
                errdefer p.allocator.free(output);

                const chunk = try p.allocator.create(Chunk);
                errdefer p.allocator.destroy(chunk);

                chunk.* = .{
                    .sequence = sequence,
                    .input = input[0..read],
                    .input_full = input,
                    .output = output,
                    .header = .{
                        .sequence = sequence,
                        .original_size = @intCast(read),
                        .compressed_size = 0,
                    },
                };
                sequence += 1;

                p.in_queue.putOne(p.io, chunk) catch |err| {
                    destroyChunk(p.allocator, chunk);
                    return err;
                };
            }
        }

        fn decompressReader(p: *Pipeline, reader: *std.Io.Reader, limits: options.Limits) anyerror!void {
            defer p.in_queue.close(p.io);

            var expected_sequence: u64 = 0;
            while (true) {
                const chunk_header = try format.readChunkHeader(reader, limits);

                if (chunk_header.isEnd()) {
                    if (chunk_header.sequence != expected_sequence) return error.OutOfOrderChunk;
                    return;
                }
                if (chunk_header.sequence != expected_sequence) return error.OutOfOrderChunk;
                expected_sequence += 1;

                const input = try p.allocator.alloc(u8, chunk_header.compressed_size);
                errdefer p.allocator.free(input);
                try reader.readSliceAll(input);

                const output = try p.allocator.alloc(u8, chunk_header.original_size);
                errdefer p.allocator.free(output);

                const chunk = try p.allocator.create(Chunk);
                errdefer p.allocator.destroy(chunk);

                chunk.* = .{
                    .sequence = chunk_header.sequence,
                    .input = input,
                    .input_full = input,
                    .output = output,
                    .header = chunk_header,
                };

                p.in_queue.putOne(p.io, chunk) catch |err| {
                    destroyChunk(p.allocator, chunk);
                    return err;
                };
            }
        }

        fn compressWriter(p: *Pipeline, writer: *std.Io.Writer) anyerror!u64 {
            return try orderedWrite(p, writer, .compress);
        }

        fn decompressWriter(p: *Pipeline, writer: *std.Io.Writer) anyerror!void {
            _ = try orderedWrite(p, writer, .decompress);
        }

        fn orderedWrite(p: *Pipeline, writer: *std.Io.Writer, direction: Direction) anyerror!u64 {
            var next_sequence: u64 = 0;
            var pending = std.AutoHashMap(u64, *Chunk).init(p.allocator);
            defer {
                var it = pending.valueIterator();
                while (it.next()) |chunk_ptr| destroyChunk(p.allocator, chunk_ptr.*);
                pending.deinit();
            }

            while (true) {
                if (pending.get(next_sequence)) |chunk| {
                    _ = pending.remove(next_sequence);
                    switch (direction) {
                        .compress => {
                            format.writeChunkHeader(writer, chunk.header) catch |err| {
                                p.in_queue.close(p.io);
                                p.out_queue.close(p.io);
                                destroyChunk(p.allocator, chunk);
                                return err;
                            };
                            writer.writeAll(chunk.output[0..chunk.header.compressed_size]) catch |err| {
                                p.in_queue.close(p.io);
                                p.out_queue.close(p.io);
                                destroyChunk(p.allocator, chunk);
                                return err;
                            };
                        },
                        .decompress => {
                            writer.writeAll(chunk.output) catch |err| {
                                p.in_queue.close(p.io);
                                p.out_queue.close(p.io);
                                destroyChunk(p.allocator, chunk);
                                return err;
                            };
                        },
                    }
                    destroyChunk(p.allocator, chunk);
                    next_sequence += 1;
                    continue;
                }

                const chunk = p.out_queue.getOne(p.io) catch |err| switch (err) {
                    error.Closed => break,
                    else => return err,
                };

                pending.put(chunk.sequence, chunk) catch |err| {
                    destroyChunk(p.allocator, chunk);
                    return err;
                };
            }

            return next_sequence;
        }

        fn cancelVoidFutures(io: std.Io, futures: []VoidFuture) void {
            for (futures) |*future| {
                _ = future.cancel(io) catch {};
            }
        }

        fn rememberError(slot: *?anyerror, err: anyerror!void) void {
            err catch |actual| {
                if (slot.* == null or (isInternalFlowError(slot.*.?) and !isInternalFlowError(actual))) {
                    slot.* = actual;
                }
            };
        }

        fn isInternalFlowError(err: anyerror) bool {
            return err == error.Closed or err == error.Canceled;
        }

        fn drainQueue(queue: *ChunkQueue, io: std.Io, allocator: std.mem.Allocator) void {
            queue.close(io);
            while (true) {
                const chunk = queue.getOneUncancelable(io) catch |err| switch (err) {
                    error.Closed => break,
                };
                destroyChunk(allocator, chunk);
            }
        }

        fn destroyChunk(allocator: std.mem.Allocator, chunk: *Chunk) void {
            allocator.free(chunk.input_full);
            allocator.free(chunk.output);
            allocator.destroy(chunk);
        }
    };
}
