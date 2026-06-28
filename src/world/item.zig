const std = @import("std");

pub const coal: u16 = 263;
pub const diamond: u16 = 264;
pub const stick: u16 = 280;
pub const seeds: u16 = 295;
pub const flint: u16 = 318;
pub const redstone: u16 = 331;
pub const snowball: u16 = 332;
pub const clay_ball: u16 = 337;
pub const reed: u16 = 338;
pub const dye: u16 = 351;

pub const dye_meta_lapis: u4 = 4;

pub fn iconTile(id: u16) ?u8 {
    return switch (id) {
        coal => 7,
        diamond => 3 * 16 + 7,
        stick => 3 * 16 + 5,
        seeds => 9,
        flint => 6,
        redstone => 3 * 16 + 8,
        snowball => 14,
        clay_ball => 3 * 16 + 9,
        reed => 1 * 16 + 11,
        dye => 4 * 16 + 14,
        else => null,
    };
}

test "iconTile matches the real items.png icon coordinates" {
    try std.testing.expectEqual(@as(?u8, 7), iconTile(coal));
    try std.testing.expectEqual(@as(?u8, 55), iconTile(diamond));
    try std.testing.expectEqual(@as(?u8, 78), iconTile(dye));
    try std.testing.expectEqual(@as(?u8, null), iconTile(0));
}
