const std = @import("std");

pub const dye_meta_lapis: u4 = 4;

pub const Item = enum(u16) {
    coal = 263,
    diamond = 264,
    stick = 280,
    seeds = 295,
    flint = 318,
    redstone = 331,
    snowball = 332,
    clay_ball = 337,
    reed = 338,
    dye = 351,
    _,

    pub fn iconTile(self: Item) ?u8 {
        return switch (self) {
            .coal => 7,
            .diamond => 3 * 16 + 7,
            .stick => 3 * 16 + 5,
            .seeds => 9,
            .flint => 6,
            .redstone => 3 * 16 + 8,
            .snowball => 14,
            .clay_ball => 3 * 16 + 9,
            .reed => 1 * 16 + 11,
            .dye => 4 * 16 + 14,
            else => null,
        };
    }

    pub fn displayName(self: Item, metadata: u4) []const u8 {
        return switch (self) {
            .coal => "Coal",
            .diamond => "Diamond",
            .stick => "Stick",
            .seeds => "Seeds",
            .flint => "Flint",
            .redstone => "Redstone",
            .snowball => "Snowball",
            .clay_ball => "Clay",
            .reed => "Sugar Canes",
            .dye => dye_names[metadata],
            else => "",
        };
    }
};

const dye_names: [16][]const u8 = .{
    "Ink Sac",
    "Rose Red",
    "Cactus Green",
    "Cocoa Beans",
    "Lapis Lazuli",
    "Purple Dye",
    "Cyan Dye",
    "Light Gray Dye",
    "Gray Dye",
    "Pink Dye",
    "Lime Dye",
    "Dandelion Yellow",
    "Light Blue Dye",
    "Magenta Dye",
    "Orange Dye",
    "Bone Meal",
};

test "iconTile matches the real items.png icon coordinates" {
    try std.testing.expectEqual(@as(?u8, 7), Item.coal.iconTile());
    try std.testing.expectEqual(@as(?u8, 55), Item.diamond.iconTile());
    try std.testing.expectEqual(@as(?u8, 78), Item.dye.iconTile());
    try std.testing.expectEqual(@as(?u8, null), (@as(Item, @enumFromInt(0))).iconTile());
}

test "dye display names are selected by metadata" {
    try std.testing.expectEqualStrings("Lapis Lazuli", Item.dye.displayName(dye_meta_lapis));
    try std.testing.expectEqualStrings("Ink Sac", Item.dye.displayName(0));
    try std.testing.expectEqualStrings("Bone Meal", Item.dye.displayName(15));
}

test "an item's display name ignores metadata unless it is a dye" {
    try std.testing.expectEqualStrings("Diamond", Item.diamond.displayName(0));
    try std.testing.expectEqualStrings("Diamond", Item.diamond.displayName(7));
    try std.testing.expectEqualStrings("", (@as(Item, @enumFromInt(0))).displayName(0));
}
