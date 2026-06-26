const std = @import("std");

pub const air: u8 = 0;
pub const stone: u8 = 1;
pub const grass: u8 = 2;
pub const dirt: u8 = 3;
pub const bedrock: u8 = 7;
pub const stationary_water: u8 = 9;
pub const flowing_lava: u8 = 10;
pub const sand: u8 = 12;
pub const gravel: u8 = 13;
pub const ore_gold: u8 = 14;
pub const ore_iron: u8 = 15;
pub const ore_coal: u8 = 16;
pub const log: u8 = 17;
pub const leaves: u8 = 18;
pub const ore_lapis: u8 = 21;
pub const ore_diamond: u8 = 56;
pub const ore_redstone: u8 = 73;

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
        stationary_water => .{ 205, 205, 205, 205, 205, 205 },
        flowing_lava => .{ 237, 237, 237, 237, 237, 237 },
        sand => .{ 18, 18, 18, 18, 18, 18 },
        gravel => .{ 19, 19, 19, 19, 19, 19 },
        ore_gold => .{ 32, 32, 32, 32, 32, 32 },
        ore_iron => .{ 33, 33, 33, 33, 33, 33 },
        ore_coal => .{ 34, 34, 34, 34, 34, 34 },
        log => .{ 21, 21, 20, 20, 20, 20 },
        leaves => .{ 52, 52, 52, 52, 52, 52 },
        ore_lapis => .{ 160, 160, 160, 160, 160, 160 },
        ore_diamond => .{ 50, 50, 50, 50, 50, 50 },
        ore_redstone => .{ 51, 51, 51, 51, 51, 51 },
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
