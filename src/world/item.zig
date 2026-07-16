const std = @import("std");
const Block = @import("block.zig").Block;

pub const dye_meta_cactus: u16 = 2;
pub const dye_meta_lapis: u16 = 4;
pub const coal_meta_charcoal: u16 = 1;

pub const ToolMaterial = enum {
    wood,
    stone,
    iron,
    diamond,
    gold,

    pub fn harvestLevel(self: ToolMaterial) u8 {
        return switch (self) {
            .wood, .gold => 0,
            .stone => 1,
            .iron => 2,
            .diamond => 3,
        };
    }

    pub fn maxUses(self: ToolMaterial) u16 {
        return switch (self) {
            .wood => 59,
            .stone => 131,
            .iron => 250,
            .diamond => 1561,
            .gold => 32,
        };
    }

    pub fn efficiency(self: ToolMaterial) f32 {
        return switch (self) {
            .wood => 2.0,
            .stone => 4.0,
            .iron => 6.0,
            .diamond => 8.0,
            .gold => 12.0,
        };
    }
};

pub const ToolKind = enum { sword, shovel, pickaxe, axe, hoe };

pub const Tool = struct {
    kind: ToolKind,
    material: ToolMaterial,

    fn isEffectiveAgainst(self: Tool, target: Block) bool {
        return switch (self.kind) {
            .pickaxe => switch (target) {
                .cobblestone,
                .stone,
                .sandstone,
                .cobblestone_mossy,
                .ore_iron,
                .block_iron,
                .ore_coal,
                .block_gold,
                .ore_gold,
                .ore_diamond,
                .block_diamond,
                .ice,
                .netherrack,
                .ore_lapis,
                .block_lapis,
                => true,
                else => false,
            },
            .axe => switch (target) {
                .planks, .bookshelf, .log => true,
                else => false,
            },
            .shovel => switch (target) {
                .grass, .dirt, .sand, .gravel, .snow_layer, .snow_block, .clay => true,
                else => false,
            },
            .sword, .hoe => false,
        };
    }

    pub fn strVsBlock(self: Tool, target: Block) f32 {
        return switch (self.kind) {
            .sword => 1.5,
            .hoe => 1.0,
            else => if (self.isEffectiveAgainst(target)) self.material.efficiency() else 1.0,
        };
    }

    pub fn canHarvestBlock(self: Tool, target: Block) bool {
        const level = self.material.harvestLevel();
        return switch (self.kind) {
            .pickaxe => switch (target) {
                .obsidian => level == 3,
                .block_diamond, .ore_diamond, .block_gold, .ore_gold, .ore_redstone => level >= 2,
                .block_iron, .ore_iron, .block_lapis, .ore_lapis => level >= 1,
                else => switch (target.material()) {
                    .rock, .iron => true,
                    else => false,
                },
            },
            .shovel => target == .snow_layer or target == .snow_block,
            else => false,
        };
    }

    pub fn blockDestroyedCost(self: Tool) u16 {
        return switch (self.kind) {
            .sword => 2,
            .hoe => 0,
            else => 1,
        };
    }
};

pub const ArmorSlot = enum(u2) { helmet, chestplate, leggings, boots };

pub const ArmorMaterial = enum {
    leather,
    chain,
    iron,
    diamond,
    gold,

    pub fn level(self: ArmorMaterial) u2 {
        return switch (self) {
            .leather => 0,
            .chain, .gold => 1,
            .iron => 2,
            .diamond => 3,
        };
    }
};

pub const Armor = struct {
    slot: ArmorSlot,
    material: ArmorMaterial,

    pub fn damageReduction(self: Armor) i32 {
        return switch (self.slot) {
            .helmet => 3,
            .chestplate => 8,
            .leggings => 6,
            .boots => 3,
        };
    }

    pub fn maxDamage(self: Armor) u16 {
        const base: u16 = switch (self.slot) {
            .helmet => 11,
            .chestplate => 16,
            .leggings => 15,
            .boots => 13,
        };
        return (base * 3) << self.material.level();
    }
};

pub const Item = enum(u16) {
    shovel_iron = 256,
    pickaxe_iron = 257,
    axe_iron = 258,
    apple = 260,
    coal = 263,
    diamond = 264,
    ingot_iron = 265,
    ingot_gold = 266,
    sword_iron = 267,
    sword_wood = 268,
    shovel_wood = 269,
    pickaxe_wood = 270,
    axe_wood = 271,
    sword_stone = 272,
    shovel_stone = 273,
    pickaxe_stone = 274,
    axe_stone = 275,
    sword_diamond = 276,
    shovel_diamond = 277,
    pickaxe_diamond = 278,
    axe_diamond = 279,
    stick = 280,
    bowl = 281,
    mushroom_stew = 282,
    sword_gold = 283,
    shovel_gold = 284,
    pickaxe_gold = 285,
    axe_gold = 286,
    string = 287,
    feather = 288,
    gunpowder = 289,
    hoe_wood = 290,
    hoe_stone = 291,
    hoe_iron = 292,
    hoe_diamond = 293,
    hoe_gold = 294,
    seeds = 295,
    wheat = 296,
    bread = 297,
    helmet_leather = 298,
    chestplate_leather = 299,
    leggings_leather = 300,
    boots_leather = 301,
    helmet_chain = 302,
    chestplate_chain = 303,
    leggings_chain = 304,
    boots_chain = 305,
    helmet_iron = 306,
    chestplate_iron = 307,
    leggings_iron = 308,
    boots_iron = 309,
    helmet_diamond = 310,
    chestplate_diamond = 311,
    leggings_diamond = 312,
    boots_diamond = 313,
    helmet_gold = 314,
    chestplate_gold = 315,
    leggings_gold = 316,
    boots_gold = 317,
    flint = 318,
    pork_raw = 319,
    pork_cooked = 320,
    door_wood = 324,
    door_iron = 330,
    redstone = 331,
    snowball = 332,
    leather = 334,
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

    pub fn tool(self: Item) ?Tool {
        return switch (self) {
            .sword_wood => .{ .kind = .sword, .material = .wood },
            .shovel_wood => .{ .kind = .shovel, .material = .wood },
            .pickaxe_wood => .{ .kind = .pickaxe, .material = .wood },
            .axe_wood => .{ .kind = .axe, .material = .wood },
            .hoe_wood => .{ .kind = .hoe, .material = .wood },
            .sword_stone => .{ .kind = .sword, .material = .stone },
            .shovel_stone => .{ .kind = .shovel, .material = .stone },
            .pickaxe_stone => .{ .kind = .pickaxe, .material = .stone },
            .axe_stone => .{ .kind = .axe, .material = .stone },
            .hoe_stone => .{ .kind = .hoe, .material = .stone },
            .sword_iron => .{ .kind = .sword, .material = .iron },
            .shovel_iron => .{ .kind = .shovel, .material = .iron },
            .pickaxe_iron => .{ .kind = .pickaxe, .material = .iron },
            .axe_iron => .{ .kind = .axe, .material = .iron },
            .hoe_iron => .{ .kind = .hoe, .material = .iron },
            .sword_diamond => .{ .kind = .sword, .material = .diamond },
            .shovel_diamond => .{ .kind = .shovel, .material = .diamond },
            .pickaxe_diamond => .{ .kind = .pickaxe, .material = .diamond },
            .axe_diamond => .{ .kind = .axe, .material = .diamond },
            .hoe_diamond => .{ .kind = .hoe, .material = .diamond },
            .sword_gold => .{ .kind = .sword, .material = .gold },
            .shovel_gold => .{ .kind = .shovel, .material = .gold },
            .pickaxe_gold => .{ .kind = .pickaxe, .material = .gold },
            .axe_gold => .{ .kind = .axe, .material = .gold },
            .hoe_gold => .{ .kind = .hoe, .material = .gold },
            else => null,
        };
    }

    pub fn armor(self: Item) ?Armor {
        return switch (self) {
            .helmet_leather => .{ .slot = .helmet, .material = .leather },
            .chestplate_leather => .{ .slot = .chestplate, .material = .leather },
            .leggings_leather => .{ .slot = .leggings, .material = .leather },
            .boots_leather => .{ .slot = .boots, .material = .leather },
            .helmet_chain => .{ .slot = .helmet, .material = .chain },
            .chestplate_chain => .{ .slot = .chestplate, .material = .chain },
            .leggings_chain => .{ .slot = .leggings, .material = .chain },
            .boots_chain => .{ .slot = .boots, .material = .chain },
            .helmet_iron => .{ .slot = .helmet, .material = .iron },
            .chestplate_iron => .{ .slot = .chestplate, .material = .iron },
            .leggings_iron => .{ .slot = .leggings, .material = .iron },
            .boots_iron => .{ .slot = .boots, .material = .iron },
            .helmet_diamond => .{ .slot = .helmet, .material = .diamond },
            .chestplate_diamond => .{ .slot = .chestplate, .material = .diamond },
            .leggings_diamond => .{ .slot = .leggings, .material = .diamond },
            .boots_diamond => .{ .slot = .boots, .material = .diamond },
            .helmet_gold => .{ .slot = .helmet, .material = .gold },
            .chestplate_gold => .{ .slot = .chestplate, .material = .gold },
            .leggings_gold => .{ .slot = .leggings, .material = .gold },
            .boots_gold => .{ .slot = .boots, .material = .gold },
            else => null,
        };
    }

    pub fn maxDamage(self: Item) u16 {
        if (self.tool()) |t| return t.material.maxUses();
        if (self.armor()) |a| return a.maxDamage();
        return 0;
    }

    pub fn isDamageable(self: Item) bool {
        return self.maxDamage() > 0;
    }

    pub fn maxStackSize(self: Item) u8 {
        if (self == .door_wood or self == .door_iron) return 1;
        return if (self.isDamageable()) 1 else 64;
    }

    pub fn strVsBlock(self: Item, target: Block) f32 {
        const t = self.tool() orelse return 1.0;
        return t.strVsBlock(target);
    }

    pub fn canHarvestBlock(self: Item, target: Block) bool {
        const t = self.tool() orelse return false;
        return t.canHarvestBlock(target);
    }

    pub fn iconTile(self: Item, damage: u16) ?u8 {
        const dye_color: u8 = @as(u4, @truncate(damage));
        return switch (self) {
            .dye => 4 * 16 + 14 + dye_color % 8 * 16 + dye_color / 8,
            .sword_wood => 4 * 16 + 0,
            .shovel_wood => 5 * 16 + 0,
            .pickaxe_wood => 6 * 16 + 0,
            .axe_wood => 7 * 16 + 0,
            .hoe_wood => 8 * 16 + 0,
            .sword_stone => 4 * 16 + 1,
            .shovel_stone => 5 * 16 + 1,
            .pickaxe_stone => 6 * 16 + 1,
            .axe_stone => 7 * 16 + 1,
            .hoe_stone => 8 * 16 + 1,
            .sword_iron => 4 * 16 + 2,
            .shovel_iron => 5 * 16 + 2,
            .pickaxe_iron => 6 * 16 + 2,
            .axe_iron => 7 * 16 + 2,
            .hoe_iron => 8 * 16 + 2,
            .sword_diamond => 4 * 16 + 3,
            .shovel_diamond => 5 * 16 + 3,
            .pickaxe_diamond => 6 * 16 + 3,
            .axe_diamond => 7 * 16 + 3,
            .hoe_diamond => 8 * 16 + 3,
            .sword_gold => 4 * 16 + 4,
            .shovel_gold => 5 * 16 + 4,
            .pickaxe_gold => 6 * 16 + 4,
            .axe_gold => 7 * 16 + 4,
            .hoe_gold => 8 * 16 + 4,
            .helmet_leather => 0 * 16 + 0,
            .chestplate_leather => 1 * 16 + 0,
            .leggings_leather => 2 * 16 + 0,
            .boots_leather => 3 * 16 + 0,
            .helmet_chain => 0 * 16 + 1,
            .chestplate_chain => 1 * 16 + 1,
            .leggings_chain => 2 * 16 + 1,
            .boots_chain => 3 * 16 + 1,
            .helmet_iron => 0 * 16 + 2,
            .chestplate_iron => 1 * 16 + 2,
            .leggings_iron => 2 * 16 + 2,
            .boots_iron => 3 * 16 + 2,
            .helmet_diamond => 0 * 16 + 3,
            .chestplate_diamond => 1 * 16 + 3,
            .leggings_diamond => 2 * 16 + 3,
            .boots_diamond => 3 * 16 + 3,
            .helmet_gold => 0 * 16 + 4,
            .chestplate_gold => 1 * 16 + 4,
            .leggings_gold => 2 * 16 + 4,
            .boots_gold => 3 * 16 + 4,
            .leather => 6 * 16 + 7,
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
            .door_wood => 2 * 16 + 11,
            .door_iron => 2 * 16 + 12,
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
            .bone => 1 * 16 + 12,
            .sugar => 13,
            else => null,
        };
    }

    pub fn displayName(self: Item, metadata: u16) []const u8 {
        return switch (self) {
            .sword_wood => "Wooden Sword",
            .shovel_wood => "Wooden Shovel",
            .pickaxe_wood => "Wooden Pickaxe",
            .axe_wood => "Wooden Axe",
            .hoe_wood => "Wooden Hoe",
            .sword_stone => "Stone Sword",
            .shovel_stone => "Stone Shovel",
            .pickaxe_stone => "Stone Pickaxe",
            .axe_stone => "Stone Axe",
            .hoe_stone => "Stone Hoe",
            .sword_iron => "Iron Sword",
            .shovel_iron => "Iron Shovel",
            .pickaxe_iron => "Iron Pickaxe",
            .axe_iron => "Iron Axe",
            .hoe_iron => "Iron Hoe",
            .sword_diamond => "Diamond Sword",
            .shovel_diamond => "Diamond Shovel",
            .pickaxe_diamond => "Diamond Pickaxe",
            .axe_diamond => "Diamond Axe",
            .hoe_diamond => "Diamond Hoe",
            .sword_gold => "Golden Sword",
            .shovel_gold => "Golden Shovel",
            .pickaxe_gold => "Golden Pickaxe",
            .axe_gold => "Golden Axe",
            .hoe_gold => "Golden Hoe",
            .helmet_leather => "Leather Cap",
            .chestplate_leather => "Leather Tunic",
            .leggings_leather => "Leather Pants",
            .boots_leather => "Leather Boots",
            .helmet_chain => "Chain Helmet",
            .chestplate_chain => "Chain Chestplate",
            .leggings_chain => "Chain Leggings",
            .boots_chain => "Chain Boots",
            .helmet_iron => "Iron Helmet",
            .chestplate_iron => "Iron Chestplate",
            .leggings_iron => "Iron Leggings",
            .boots_iron => "Iron Boots",
            .helmet_diamond => "Diamond Helmet",
            .chestplate_diamond => "Diamond Chestplate",
            .leggings_diamond => "Diamond Leggings",
            .boots_diamond => "Diamond Boots",
            .helmet_gold => "Golden Helmet",
            .chestplate_gold => "Golden Chestplate",
            .leggings_gold => "Golden Leggings",
            .boots_gold => "Golden boots",
            .leather => "Leather",
            .apple => "Apple",
            .coal => if (metadata == coal_meta_charcoal) "Charcoal" else "Coal",
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
            .door_wood => "Wooden Door",
            .door_iron => "Iron Door",
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
            .dye => dye_names[@as(u4, @truncate(metadata))],
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
    try std.testing.expectEqual(@as(?u8, 7), Item.coal.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 55), Item.diamond.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 78), Item.dye.iconTile(0));
    try std.testing.expectEqual(@as(?u8, null), (@as(Item, @enumFromInt(0))).iconTile(0));
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
    try std.testing.expectEqual(@as(?u8, 23), Item.ingot_iron.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 39), Item.ingot_gold.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 8), Item.string.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 87), Item.pork_raw.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 88), Item.pork_cooked.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 73), Item.glowstone_dust.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 13), Item.sugar.iconTile(0));
}

test "tool materials carry EnumToolMaterial's four numbers" {
    try std.testing.expectEqual(@as(u16, 59), ToolMaterial.wood.maxUses());
    try std.testing.expectEqual(@as(u16, 1561), ToolMaterial.diamond.maxUses());
    try std.testing.expectEqual(@as(u16, 32), ToolMaterial.gold.maxUses());
    try std.testing.expectEqual(@as(f32, 12.0), ToolMaterial.gold.efficiency());
    try std.testing.expectEqual(@as(u8, 0), ToolMaterial.gold.harvestLevel());
    try std.testing.expectEqual(@as(u8, 3), ToolMaterial.diamond.harvestLevel());
}

test "a tool's durability is its material's, whatever the tool is" {
    try std.testing.expectEqual(@as(u16, 131), Item.pickaxe_stone.maxDamage());
    try std.testing.expectEqual(@as(u16, 131), Item.hoe_stone.maxDamage());
    try std.testing.expectEqual(@as(u16, 131), Item.sword_stone.maxDamage());
}

test "armour durability is the piece's base times three, doubled per material level" {
    try std.testing.expectEqual(@as(u16, 33), Item.helmet_leather.maxDamage());
    try std.testing.expectEqual(@as(u16, 192), Item.chestplate_iron.maxDamage());
    try std.testing.expectEqual(@as(u16, 384), Item.chestplate_diamond.maxDamage());
    try std.testing.expectEqual(@as(u16, 78), Item.boots_gold.maxDamage());
}

test "the pieces protect by slot, not by material" {
    try std.testing.expectEqual(@as(i32, 8), Item.chestplate_leather.armor().?.damageReduction());
    try std.testing.expectEqual(@as(i32, 8), Item.chestplate_diamond.armor().?.damageReduction());
    try std.testing.expectEqual(@as(i32, 3), Item.helmet_diamond.armor().?.damageReduction());
    try std.testing.expectEqual(@as(i32, 6), Item.leggings_diamond.armor().?.damageReduction());
}

test "sticks and ingots are neither tools nor armour" {
    try std.testing.expectEqual(@as(?Tool, null), Item.stick.tool());
    try std.testing.expectEqual(@as(?Armor, null), Item.ingot_iron.armor());
    try std.testing.expect(!Item.stick.isDamageable());
}

test "the new icons match their real items.png coordinates" {
    try std.testing.expectEqual(@as(?u8, 66), Item.sword_iron.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 98), Item.pickaxe_iron.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 128), Item.hoe_wood.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 51), Item.boots_diamond.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 103), Item.leather.iconTile(0));
}

test "dye icons step through items.png the way getIconFromDamage does" {
    try std.testing.expectEqual(@as(?u8, 78), Item.dye.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 142), Item.dye.iconTile(dye_meta_lapis));
    try std.testing.expectEqual(@as(?u8, 191), Item.dye.iconTile(15));
}

test "door items carry one to a stack and match their items.png coordinates" {
    try std.testing.expectEqual(@as(u8, 1), Item.door_wood.maxStackSize());
    try std.testing.expectEqual(@as(u8, 1), Item.door_iron.maxStackSize());
    try std.testing.expectEqual(@as(?u8, 43), Item.door_wood.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 44), Item.door_iron.iconTile(0));
    try std.testing.expectEqualStrings("Wooden Door", Item.door_wood.displayName(0));
    try std.testing.expectEqualStrings("Iron Door", Item.door_iron.displayName(0));
}
