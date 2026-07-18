const std = @import("std");

const constants = @import("constants.zig");

const NibbleArray = @This();

data: [constants.chunk_volume / 2]u8 = [_]u8{0} ** (constants.chunk_volume / 2),

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

test "get/set round-trips a value" {
    var arr = NibbleArray{};
    arr.set(3, 5, 7, 9);
    try std.testing.expectEqual(@as(u4, 9), arr.get(3, 5, 7));
}

test "adjacent nibbles packed in the same byte don't clobber each other" {
    var arr = NibbleArray{};
    arr.set(0, 0, 0, 3);
    arr.set(0, 1, 0, 12);
    try std.testing.expectEqual(@as(u4, 3), arr.get(0, 0, 0));
    try std.testing.expectEqual(@as(u4, 12), arr.get(0, 1, 0));
}

test "defaults to all zero" {
    const arr = NibbleArray{};
    try std.testing.expectEqual(@as(u4, 0), arr.get(15, 127, 15));
}
