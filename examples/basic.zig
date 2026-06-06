const std = @import("std");
const zc = @import("zcompress");

pub fn main(init: std.process.Init) !void {
    const input = "Hello, zcompress!\n" ** 64;

    var compressed: std.Io.Writer.Allocating = .init(init.gpa);
    defer compressed.deinit();

    var source: std.Io.Reader = .fixed(input);
    try zc.compress(init.io, init.gpa, &source, &compressed.writer, .{
        .algorithm = .zstd,
        .level = .default,
    });
    try compressed.writer.flush();

    var decoded: std.Io.Writer.Allocating = .init(init.gpa);
    defer decoded.deinit();

    var encoded: std.Io.Reader = .fixed(compressed.written());
    try zc.decompress(init.io, init.gpa, &encoded, &decoded.writer, .{});
    try decoded.writer.flush();

    std.debug.print("input={d} compressed={d} decoded_ok={}\n", .{
        input.len,
        compressed.written().len,
        std.mem.eql(u8, input, decoded.written()),
    });
}
