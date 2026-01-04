pub const ChunkHeader = packed struct {
    original_size: u32,
    compressed_size: u32,

    pub fn isEnd(self: ChunkHeader) bool {
        return self.original_size == 0 and self.compressed_size == 0;
    }
    pub fn end() ChunkHeader {
        return .{ .original_size = 0, .compressed_size = 0 };
    }
};

pub const JobConfig = struct {
    level: c_int,
};
