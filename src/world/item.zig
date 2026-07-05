const std = @import("std");

pub const dye_meta_lapis: u4 = 4;

pub const Item = enum(u16) {
    apple = 260,
    coal = 263,
    diamond = 264,
    ingot_iron = 265,
    ingot_gold = 266,
    stick = 280,
    bowl = 281,
    mushroom_stew = 282,
    string = 287,
    feather = 288,
    gunpowder = 289,
    seeds = 295,
    wheat = 296,
    bread = 297,
    flint = 318,
    pork_raw = 319,
    pork_cooked = 320,
    redstone = 331,
    snowball = 332,
    brick = 336,
    clay_ball = 337,
    reed = 338,
    paper = 339,
    book = 340,
    slime_ball = 341,
    egg = 344,
    glowstone_dust = 348,
    dye = 351,
    bone = 352,
    sugar = 353,
    _,

    pub fn iconTile(self: Item) ?u8 {
        return switch (self) {
            .apple => 10,
            .coal => 7,
            .diamond => 3 * 16 + 7,
            .ingot_iron => 1 * 16 + 7,
            .ingot_gold => 2 * 16 + 7,
            .stick => 3 * 16 + 5,
            .bowl => 4 * 16 + 7,
            .mushroom_stew => 4 * 16 + 8,
            .string => 8,
            .feather => 1 * 16 + 8,
            .gunpowder => 2 * 16 + 8,
            .seeds => 9,
            .wheat => 1 * 16 + 9,
            .bread => 2 * 16 + 9,
            .flint => 6,
            .pork_raw => 5 * 16 + 7,
            .pork_cooked => 5 * 16 + 8,
            .redstone => 3 * 16 + 8,
            .snowball => 14,
            .brick => 1 * 16 + 6,
            .clay_ball => 3 * 16 + 9,
            .reed => 1 * 16 + 11,
            .paper => 3 * 16 + 10,
            .book => 3 * 16 + 11,
            .slime_ball => 1 * 16 + 14,
            .egg => 12,
            .glowstone_dust => 4 * 16 + 9,
            .dye => 4 * 16 + 14,
            .bone => 1 * 16 + 12,
            .sugar => 13,
            else => null,
        };
    }

    pub fn displayName(self: Item, metadata: u4) []const u8 {
        return switch (self) {
            .apple => "Apple",
            .coal => "Coal",
            .diamond => "Diamond",
            .ingot_iron => "Iron Ingot",
            .ingot_gold => "Gold Ingot",
            .stick => "Stick",
            .bowl => "Bowl",
            .mushroom_stew => "Mushroom Stew",
            .string => "String",
            .feather => "Feather",
            .gunpowder => "Gunpowder",
            .seeds => "Seeds",
            .wheat => "Wheat",
            .bread => "Bread",
            .flint => "Flint",
            .pork_raw => "Raw Porkchop",
            .pork_cooked => "Cooked Porkchop",
            .redstone => "Redstone",
            .snowball => "Snowball",
            .brick => "Brick",
            .clay_ball => "Clay",
            .reed => "Sugar Canes",
            .paper => "Paper",
            .book => "Book",
            .slime_ball => "Slimeball",
            .egg => "Egg",
            .glowstone_dust => "Glowstone Dust",
            .dye => dye_names[metadata],
            .bone => "Bone",
            .sugar => "Sugar",
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

test "the new items match their real items.png icon coordinates" {
    try std.testing.expectEqual(@as(?u8, 23), Item.ingot_iron.iconTile());
    try std.testing.expectEqual(@as(?u8, 39), Item.ingot_gold.iconTile());
    try std.testing.expectEqual(@as(?u8, 8), Item.string.iconTile());
    try std.testing.expectEqual(@as(?u8, 87), Item.pork_raw.iconTile());
    try std.testing.expectEqual(@as(?u8, 88), Item.pork_cooked.iconTile());
    try std.testing.expectEqual(@as(?u8, 73), Item.glowstone_dust.iconTile());
    try std.testing.expectEqual(@as(?u8, 13), Item.sugar.iconTile());
}
