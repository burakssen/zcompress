# zcompress

A general-purpose compression library for Zig.

## Features

- Generic compression and decompression interfaces.
- Support for the following compression algorithms:
  - Deflate
  - Gzip
  - Zlib
  - Zstandard (Zstd)

## Installation

To use `zcompress` in your project, run the following command to add it as a dependency and generate its hash in your `build.zig.zon` file:

```sh
zig fetch --save "git+https://github.com/burakssen/zcompress"
```

Then, in your `build.zig` file, add the dependency and link it to your executable:

```zig
const zcompress = b.dependency("zcompress", .{
    .target = target,
    .optimize = optimize,
});

exe.addModule("zcompress", zcompress.module("zcompress"));
```

## Usage

Here's a simple example of how to use `zcompress` to compress and decompress data with Deflate:

````zig
const std = @import("std");
const zc = @import("zcompress");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const input = "Hello, zcompress!";

    var deflate = zc.Deflate.init(allocator, .deflate, .best);
    var compressor = zc.Compressor.init(&deflate);
    var decompressor = zc.Decompressor.init(&deflate);

    const compressed = try compressor.compress(input);
    defer allocator.free(compressed);

    const decompressed = try decompressor.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}
```

## Building

To build the project and run the tests, use the following command:

```sh
zig build test
````
