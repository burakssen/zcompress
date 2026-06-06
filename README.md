# zcompress

A small framed compression library for Zig.

## Features

- Clean options-based API.
- Framed zcompress container with magic, version, algorithm, and chunk metadata.
- Parallel chunk compression/decompression with ordered output.
- Strict decode limits by default.
- Backend support for deflate, gzip, zlib, and zstd.

## Installation

```sh
zig fetch --save "git+https://github.com/burakssen/zcompress"
```

```zig
const zcompress = b.dependency("zcompress", .{
    .target = target,
    .optimize = optimize,
});

exe.addModule("zcompress", zcompress.module("zcompress"));
```

## Usage

```zig
const std = @import("std");
const zc = @import("zcompress");

pub fn main(init: std.process.Init) !void {
    const input = "Hello, zcompress!";

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

    std.debug.print("{s}\n", .{decoded.written()});
}
```

## Building

```sh
zig build test
zig build run-basic
zig build run-stress
```
