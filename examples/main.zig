const std = @import("std");
// Assuming zcompress is available in your build.zig as a module
const zc = @import("zcompress");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var compressor = zc.ZCompress.init(allocator, .zstd);

    const line = "This is some example data to be compressed using the ZCompress module.\n" ** 1000;

    var data: std.Io.Writer.Allocating = .init(allocator);
    defer data.deinit();

    try data.writer.writeAll(line);

    var reader: std.Io.Reader = .fixed(data.written());
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try compressor.compress(&reader, &writer.writer, 15);

    try writer.writer.flush();

    //std.debug.print("{s}\n", .{writer.written()});

    var reader2: std.Io.Reader = .fixed(writer.written());
    var writer2: std.Io.Writer.Allocating = .init(allocator);
    defer writer2.deinit();

    try compressor.decompress(&reader2, &writer2.writer);
    try writer2.writer.flush();

    std.debug.print("Decompressed data matches original: \n{s}\n", .{writer2.written()});
}
