const std = @import("std");

const Chunk = @import("Chunk.zig");

const NibbleArray = @This();

data: [Chunk.volume / 2]u8 = @splat(0),

fn index(x: u32, y: u32, z: u32) usize {
    return (x << 11) | (z << 7) | y;
}

pub fn get(self: *const NibbleArray, x: u32, y: u32, z: u32) u4 {
    const i = index(x, y, z);
    const byte = self.data[i >> 1];
    return @truncate(if (i & 1 == 0) byte else byte >> 4);
}

pub fn set(self: *NibbleArray, x: u32, y: u32, z: u32, value: u4) void {
    const i = index(x, y, z);
    const b = i >> 1;
    if (i & 1 == 0) {
        self.data[b] = (self.data[b] & 0xF0) | value;
    } else {
        self.data[b] = (self.data[b] & 0x0F) | (@as(u8, value) << 4);
    }
}
