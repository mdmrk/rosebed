const std = @import("std");

pub const air: u8 = 0;
pub const stone: u8 = 1;
pub const grass: u8 = 2;
pub const dirt: u8 = 3;
pub const bedrock: u8 = 7;
pub const sand: u8 = 12;

pub fn isOpaque(id: u8) bool {
    return id != air;
}

pub const down = 0;
pub const up = 1;
pub const north = 2;
pub const south = 3;
pub const west = 4;
pub const east = 5;

pub fn faceTextures(id: u8) [6]u8 {
    return switch (id) {
        stone => .{ 1, 1, 1, 1, 1, 1 },
        grass => .{ 2, 0, 3, 3, 3, 3 },
        dirt => .{ 2, 2, 2, 2, 2, 2 },
        bedrock => .{ 17, 17, 17, 17, 17, 17 },
        sand => .{ 18, 18, 18, 18, 18, 18 },
        else => .{ 0, 0, 0, 0, 0, 0 },
    };
}

test "grass has a distinct top, bottom and side texture" {
    const textures = faceTextures(grass);
    try std.testing.expectEqual(@as(u8, 0), textures[up]);
    try std.testing.expectEqual(@as(u8, 2), textures[down]);
    try std.testing.expectEqual(@as(u8, 3), textures[north]);
    try std.testing.expectEqual(@as(u8, 3), textures[east]);
}

test "air is the only non-opaque registered block" {
    try std.testing.expect(!isOpaque(air));
    try std.testing.expect(isOpaque(stone));
    try std.testing.expect(isOpaque(bedrock));
}
