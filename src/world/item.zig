const std = @import("std");

const Block = @import("block.zig").Block;
const Side = @import("block.zig").Side;
const World = @import("world_map.zig");

const shears_max_damage: u16 = 238;
const flint_and_steel_max_damage: u16 = 64;

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

    pub fn damageVsEntity(self: ToolMaterial) i32 {
        return switch (self) {
            .wood, .gold => 0,
            .stone => 1,
            .iron => 2,
            .diamond => 3,
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

pub const Fill = enum {
    empty,
    water,
    lava,
    milk,

    pub fn poured(self: Fill) ?Block {
        return switch (self) {
            .water => .flowing_water,
            .lava => .flowing_lava,
            .empty, .milk => null,
        };
    }

    pub fn bucketItem(self: Fill) Item {
        return switch (self) {
            .empty => .bucket,
            .water => .bucket_water,
            .lava => .bucket_lava,
            .milk => .bucket_milk,
        };
    }
};

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
                .planks, .bookshelf, .log, .chest => true,
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
                .block_diamond, .ore_diamond, .block_gold, .ore_gold, .ore_redstone, .ore_redstone_glowing => level >= 2,
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

pub const MinecartKind = enum(u2) { empty, chest, furnace };

pub const Def = struct {
    key: []const u8 = "",
    name: []const u8 = "",
    icon: ?u8 = null,
    tool: ?Tool = null,
    armor: ?Armor = null,
    placed_block: ?Block = null,
    bucket_fill: ?Fill = null,
    record_name: ?[]const u8 = null,
    minecart_kind: ?MinecartKind = null,
    heal_amount: ?u8 = null,
    max_damage: ?u16 = null,
    max_stack_size: u8 = 64,
    icon_tile: ?*const fn (Item, u16) ?u8 = null,
    display_name: ?*const fn (Item, u16) []const u8 = null,
    on_use: ?*const fn (*World, i32, i32, i32, Side, Item, u16) std.mem.Allocator.Error!bool = null,
};

pub const first_item_id: u16 = 256;
pub const def_capacity: u16 = 2048;

const vanilla_keys: [def_capacity][]const u8 = keysFromEnum();

fn keysFromEnum() [def_capacity][]const u8 {
    var out: [def_capacity][]const u8 = @splat("");
    for (@typeInfo(Item).@"enum".fields) |entry| {
        if (entry.value < first_item_id or entry.value - first_item_id >= def_capacity) continue;
        out[entry.value - first_item_id] = entry.name;
    }
    return out;
}

var defs: [def_capacity]Def = vanillaDefs();
const unregistered: Def = .{};

fn vanillaDefs() [def_capacity]Def {
    @setEvalBranchQuota(2_000_000);
    var out: [def_capacity]Def = undefined;
    for (&out, 0..) |*entry, offset| {
        const self: Item = @enumFromInt(first_item_id + offset);
        entry.* = .{
            .key = vanilla_keys[offset],
            .name = self.vanillaName(),
            .icon = self.vanillaIcon(),
            .tool = self.vanillaTool(),
            .armor = self.vanillaArmor(),
            .placed_block = self.vanillaPlacedBlock(),
            .bucket_fill = self.vanillaBucketFill(),
            .record_name = self.vanillaRecordName(),
            .minecart_kind = self.vanillaMinecartKind(),
            .heal_amount = self.vanillaHealAmount(),
            .max_damage = self.vanillaMaxDamage(),
            .max_stack_size = self.vanillaMaxStackSize(),
        };
    }
    return out;
}

pub const Item = enum(u16) {
    shovel_iron = 256,
    pickaxe_iron = 257,
    axe_iron = 258,
    flint_and_steel = 259,
    apple = 260,
    bow = 261,
    arrow = 262,
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
    painting = 321,
    apple_gold = 322,
    sign = 323,
    door_wood = 324,
    bucket = 325,
    bucket_water = 326,
    bucket_lava = 327,
    minecart = 328,
    door_iron = 330,
    redstone = 331,
    snowball = 332,
    boat = 333,
    leather = 334,
    bucket_milk = 335,
    brick = 336,
    clay_ball = 337,
    reed = 338,
    paper = 339,
    book = 340,
    slime_ball = 341,
    minecart_chest = 342,
    minecart_furnace = 343,
    egg = 344,
    compass = 345,
    clock = 347,
    glowstone_dust = 348,
    dye = 351,
    bone = 352,
    sugar = 353,
    cake = 354,
    bed = 355,
    repeater = 356,
    shears = 359,
    record_13 = 2256,
    record_cat = 2257,
    _,

    pub fn def(self: Item) *const Def {
        const raw = @intFromEnum(self);
        if (raw < first_item_id or raw - first_item_id >= def_capacity) return &unregistered;
        return &defs[raw - first_item_id];
    }

    pub fn register(self: Item, definition: Def) void {
        const raw = @intFromEnum(self);
        std.debug.assert(raw >= first_item_id and raw - first_item_id < def_capacity);
        defs[raw - first_item_id] = definition;
    }

    pub fn resetRegistry() void {
        defs = vanillaDefs();
    }

    pub fn isVanilla(self: Item) bool {
        const raw = @intFromEnum(self);
        if (raw < first_item_id or raw - first_item_id >= def_capacity) return false;
        return vanilla_keys[raw - first_item_id].len != 0;
    }

    pub fn fromKey(key: []const u8) ?Item {
        if (key.len == 0) return null;
        for (defs, 0..) |entry, offset| {
            if (std.mem.eql(u8, entry.key, key)) return @enumFromInt(first_item_id + offset);
        }
        return null;
    }

    pub fn tool(self: Item) ?Tool {
        return self.def().tool;
    }

    fn vanillaTool(self: Item) ?Tool {
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
        return self.def().armor;
    }

    fn vanillaArmor(self: Item) ?Armor {
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
        if (self.def().max_damage) |uses| return uses;
        if (self.tool()) |t| return t.material.maxUses();
        if (self.armor()) |a| return a.maxDamage();
        return 0;
    }

    pub fn isDamageable(self: Item) bool {
        return self.maxDamage() > 0;
    }

    pub fn maxStackSize(self: Item) u8 {
        return self.def().max_stack_size;
    }

    fn vanillaMaxDamage(self: Item) ?u16 {
        if (self == .shears) return shears_max_damage;
        if (self == .flint_and_steel) return flint_and_steel_max_damage;
        if (self.vanillaTool()) |t| return t.material.maxUses();
        if (self.vanillaArmor()) |a| return a.maxDamage();
        return null;
    }

    fn vanillaMaxStackSize(self: Item) u8 {
        if (self == .door_wood or self == .door_iron or self == .cake or self == .bed or self == .bow or self == .sign) return 1;
        if (self == .boat) return 1;
        if (self.vanillaMinecartKind() != null) return 1;
        if (self.vanillaBucketFill() != null) return 1;
        if (self.vanillaRecordName() != null) return 1;
        if (self.vanillaHealAmount() != null) return 1;
        return if (self.vanillaMaxDamage() != null) 1 else 64;
    }

    pub fn placedBlock(self: Item) ?Block {
        return self.def().placed_block;
    }

    fn vanillaPlacedBlock(self: Item) ?Block {
        return switch (self) {
            .cake => .cake,
            .redstone => .redstone_wire,
            .repeater => .repeater_off,
            else => null,
        };
    }

    pub fn bucketFill(self: Item) ?Fill {
        return self.def().bucket_fill;
    }

    fn vanillaBucketFill(self: Item) ?Fill {
        return switch (self) {
            .bucket => .empty,
            .bucket_water => .water,
            .bucket_lava => .lava,
            .bucket_milk => .milk,
            else => null,
        };
    }

    pub fn minecartKind(self: Item) ?MinecartKind {
        return self.def().minecart_kind;
    }

    fn vanillaMinecartKind(self: Item) ?MinecartKind {
        return switch (self) {
            .minecart => .empty,
            .minecart_chest => .chest,
            .minecart_furnace => .furnace,
            else => null,
        };
    }

    pub fn recordName(self: Item) ?[]const u8 {
        return self.def().record_name;
    }

    fn vanillaRecordName(self: Item) ?[]const u8 {
        return switch (self) {
            .record_13 => "13",
            .record_cat => "cat",
            else => null,
        };
    }

    pub fn healAmount(self: Item) ?u8 {
        return self.def().heal_amount;
    }

    fn vanillaHealAmount(self: Item) ?u8 {
        return switch (self) {
            .apple => 4,
            .apple_gold => 42,
            .mushroom_stew => 10,
            .bread => 5,
            .pork_raw => 3,
            .pork_cooked => 8,
            else => null,
        };
    }

    pub fn damageVsEntity(self: Item) i32 {
        const t = self.tool() orelse return 1;
        return switch (t.kind) {
            .sword => 4 + t.material.damageVsEntity() * 2,
            .axe => 3 + t.material.damageVsEntity(),
            .pickaxe => 2 + t.material.damageVsEntity(),
            .shovel => 1 + t.material.damageVsEntity(),
            .hoe => 1,
        };
    }

    pub fn strVsBlock(self: Item, target: Block) f32 {
        if (self == .shears) return switch (target) {
            .leaves => 15.0,
            .wool => 5.0,
            else => 1.0,
        };
        const t = self.tool() orelse return 1.0;
        return t.strVsBlock(target);
    }

    pub fn canHarvestBlock(self: Item, target: Block) bool {
        const t = self.tool() orelse return false;
        return t.canHarvestBlock(target);
    }

    pub fn blockDestroyedCost(self: Item, target: Block) u16 {
        if (self == .shears) return if (target == .leaves) 1 else 0;
        const t = self.tool() orelse return 0;
        return t.blockDestroyedCost();
    }

    pub fn iconTile(self: Item, damage: u16) ?u8 {
        if (self.def().icon_tile) |hook| return hook(self, damage);
        const dye_color: u8 = @as(u4, @truncate(damage));
        return switch (self) {
            .dye => 4 * 16 + 14 + dye_color % 8 * 16 + dye_color / 8,
            else => self.def().icon,
        };
    }

    fn vanillaIcon(self: Item) ?u8 {
        return switch (self) {
            .bucket => 4 * 16 + 10,
            .bucket_water => 4 * 16 + 11,
            .bucket_lava => 4 * 16 + 12,
            .bucket_milk => 4 * 16 + 13,
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
            .apple_gold => 11,
            .bow => 1 * 16 + 5,
            .arrow => 2 * 16 + 5,
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
            .repeater => 5 * 16 + 6,
            .snowball => 14,
            .brick => 1 * 16 + 6,
            .clay_ball => 3 * 16 + 9,
            .reed => 1 * 16 + 11,
            .paper => 3 * 16 + 10,
            .book => 3 * 16 + 11,
            .slime_ball => 1 * 16 + 14,
            .egg => 12,
            .painting => 1 * 16 + 10,
            .sign => 2 * 16 + 10,
            .boat => 8 * 16 + 8,
            .minecart => 8 * 16 + 7,
            .minecart_chest => 9 * 16 + 7,
            .minecart_furnace => 10 * 16 + 7,
            .compass => 3 * 16 + 6,
            .clock => 4 * 16 + 6,
            .glowstone_dust => 4 * 16 + 9,
            .bone => 1 * 16 + 12,
            .sugar => 13,
            .cake => 1 * 16 + 13,
            .bed => 2 * 16 + 13,
            .shears => 5 * 16 + 13,
            .record_13 => 15 * 16 + 0,
            .record_cat => 15 * 16 + 1,
            .flint_and_steel => 5,
            else => null,
        };
    }

    pub fn displayName(self: Item, metadata: u16) []const u8 {
        if (self.def().display_name) |hook| return hook(self, metadata);
        return switch (self) {
            .coal => if (metadata == coal_meta_charcoal) "Charcoal" else "Coal",
            .dye => dye_names[@as(u4, @truncate(metadata))],
            else => self.def().name,
        };
    }

    fn vanillaName(self: Item) []const u8 {
        return switch (self) {
            .bucket => "Bucket",
            .bucket_water => "Water Bucket",
            .bucket_lava => "Lava bucket",
            .bucket_milk => "Milk",
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
            .apple_gold => "Golden apple",
            .bow => "Bow",
            .arrow => "Arrow",
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
            .repeater => "Redstone Repeater",
            .snowball => "Snowball",
            .brick => "Brick",
            .clay_ball => "Clay",
            .reed => "Sugar Canes",
            .paper => "Paper",
            .book => "Book",
            .slime_ball => "Slimeball",
            .egg => "Egg",
            .painting => "Painting",
            .sign => "Sign",
            .boat => "Boat",
            .minecart => "Minecart",
            .minecart_chest => "Minecart with Chest",
            .minecart_furnace => "Minecart with Furnace",
            .compass => "Compass",
            .clock => "Clock",
            .glowstone_dust => "Glowstone Dust",
            .bone => "Bone",
            .sugar => "Sugar",
            .cake => "Cake",
            .bed => "Bed",
            .shears => "Shears",
            .record_13, .record_cat => "Music Disc",
            .flint_and_steel => "Flint and Steel",
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

test "buckets do not stack, and each names the liquid it carries" {
    for ([_]Item{ .bucket, .bucket_water, .bucket_lava, .bucket_milk }) |id| {
        try std.testing.expectEqual(@as(u8, 1), id.maxStackSize());
        try std.testing.expect(id.bucketFill() != null);
    }
    try std.testing.expect(Item.ingot_iron.bucketFill() == null);

    try std.testing.expectEqualStrings("Bucket", Item.bucket.displayName(0));
    try std.testing.expectEqualStrings("Water Bucket", Item.bucket_water.displayName(0));
    try std.testing.expectEqualStrings("Lava bucket", Item.bucket_lava.displayName(0));
    try std.testing.expectEqualStrings("Milk", Item.bucket_milk.displayName(0));
}

test "bucket icons sit along row four of items.png" {
    try std.testing.expectEqual(@as(?u8, 74), Item.bucket.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 75), Item.bucket_water.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 76), Item.bucket_lava.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 77), Item.bucket_milk.iconTile(0));
}

test "a fill and its bucket item name each other both ways" {
    for ([_]Item{ .bucket, .bucket_water, .bucket_lava, .bucket_milk }) |id| {
        try std.testing.expectEqual(id, id.bucketFill().?.bucketItem());
    }
}

test "only a filled bucket pours, and milk pours nothing" {
    try std.testing.expectEqual(.flowing_water, Fill.water.poured().?);
    try std.testing.expectEqual(.flowing_lava, Fill.lava.poured().?);
    try std.testing.expect(Fill.empty.poured() == null);
    try std.testing.expect(Fill.milk.poured() == null);
}

test "food heals the amount ItemFood was built with, and never stacks" {
    try std.testing.expectEqual(@as(?u8, 4), Item.apple.healAmount());
    try std.testing.expectEqual(@as(?u8, 10), Item.mushroom_stew.healAmount());
    try std.testing.expectEqual(@as(?u8, 5), Item.bread.healAmount());
    try std.testing.expectEqual(@as(?u8, 3), Item.pork_raw.healAmount());
    try std.testing.expectEqual(@as(?u8, 8), Item.pork_cooked.healAmount());

    for ([_]Item{ .apple, .mushroom_stew, .bread, .pork_raw, .pork_cooked }) |id| {
        try std.testing.expectEqual(@as(u8, 1), id.maxStackSize());
    }

    try std.testing.expect(Item.bowl.healAmount() == null);
    try std.testing.expect(Item.wheat.healAmount() == null);
    try std.testing.expect(Item.bone.healAmount() == null);
}

test "weapon damage follows ItemSword and ItemTool over the material bonus" {
    try std.testing.expectEqual(@as(i32, 4), Item.sword_wood.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 6), Item.sword_stone.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 8), Item.sword_iron.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 10), Item.sword_diamond.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 4), Item.sword_gold.damageVsEntity());

    try std.testing.expectEqual(@as(i32, 3), Item.axe_wood.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 5), Item.axe_iron.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 2), Item.pickaxe_wood.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 4), Item.pickaxe_iron.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 1), Item.shovel_wood.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 3), Item.shovel_iron.damageVsEntity());
}

test "a hoe and anything that is not a tool swing for one" {
    try std.testing.expectEqual(@as(i32, 1), Item.hoe_diamond.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 1), Item.bucket.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 1), Item.ingot_iron.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 1), Item.bone.damageVsEntity());
}

test "a gold sword hits no harder than a wooden one" {
    try std.testing.expectEqual(Item.sword_wood.damageVsEntity(), Item.sword_gold.damageVsEntity());
    try std.testing.expectEqual(@as(i32, 0), ToolMaterial.gold.damageVsEntity());
}

test "every constant item fact reaches its caller through the registry table" {
    try std.testing.expectEqual(ToolKind.pickaxe, Item.pickaxe_iron.tool().?.kind);
    try std.testing.expectEqual(ArmorSlot.boots, Item.boots_gold.armor().?.slot);
    try std.testing.expectEqual(Block.redstone_wire, Item.redstone.placedBlock().?);
    try std.testing.expectEqual(Fill.lava, Item.bucket_lava.bucketFill().?);
    try std.testing.expectEqual(@as(u8, 1), Item.bed.maxStackSize());
    try std.testing.expectEqual(@as(u8, 64), Item.stick.maxStackSize());
    try std.testing.expectEqual(@as(?u8, 55), Item.diamond.iconTile(0));
    try std.testing.expectEqualStrings("Gold Ingot", Item.ingot_gold.displayName(0));
}

test "shears carry ItemShears' own durability, icon and name, without being a tool" {
    try std.testing.expectEqual(@as(u16, 238), Item.shears.maxDamage());
    try std.testing.expectEqual(@as(u8, 1), Item.shears.maxStackSize());
    try std.testing.expect(Item.shears.isDamageable());
    try std.testing.expectEqual(@as(?u8, 93), Item.shears.iconTile(0));
    try std.testing.expectEqualStrings("Shears", Item.shears.displayName(0));
    try std.testing.expect(Item.shears.tool() == null);
    try std.testing.expectEqual(@as(i32, 1), Item.shears.damageVsEntity());
}

test "shears cut leaves fastest and wool next, and swing at everything else bare-handed" {
    try std.testing.expectEqual(@as(f32, 15.0), Item.shears.strVsBlock(.leaves));
    try std.testing.expectEqual(@as(f32, 5.0), Item.shears.strVsBlock(.wool));
    try std.testing.expectEqual(@as(f32, 1.0), Item.shears.strVsBlock(.stone));
    try std.testing.expectEqual(@as(f32, 1.0), Item.shears.strVsBlock(.tall_grass));
}

test "only leaves wear shears down, where a tool wears on anything it breaks" {
    try std.testing.expectEqual(@as(u16, 1), Item.shears.blockDestroyedCost(.leaves));
    try std.testing.expectEqual(@as(u16, 0), Item.shears.blockDestroyedCost(.wool));
    try std.testing.expectEqual(@as(u16, 0), Item.shears.blockDestroyedCost(.stone));

    try std.testing.expectEqual(@as(u16, 1), Item.pickaxe_iron.blockDestroyedCost(.stone));
    try std.testing.expectEqual(@as(u16, 2), Item.sword_iron.blockDestroyedCost(.stone));
    try std.testing.expectEqual(@as(u16, 0), Item.hoe_iron.blockDestroyedCost(.stone));
    try std.testing.expectEqual(@as(u16, 0), Item.stick.blockDestroyedCost(.stone));
}

test "a golden apple is ItemFood's single-stack heal of forty-two" {
    try std.testing.expectEqual(@as(?u8, 42), Item.apple_gold.healAmount());
    try std.testing.expectEqual(@as(?u8, 11), Item.apple_gold.iconTile(0));
    try std.testing.expectEqual(@as(u8, 1), Item.apple_gold.maxStackSize());
    try std.testing.expectEqualStrings("Golden apple", Item.apple_gold.displayName(0));
    try std.testing.expectEqual(@as(?u8, 4), Item.apple.healAmount());
}

test "the three minecarts read the icon column setIconCoord puts them in" {
    try std.testing.expectEqual(@as(?u8, 135), Item.minecart.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 151), Item.minecart_chest.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 167), Item.minecart_furnace.iconTile(0));
    try std.testing.expectEqual(@as(u8, 1), Item.minecart.maxStackSize());
    try std.testing.expectEqualStrings("Minecart", Item.minecart.displayName(0));
}

test "both records sit one after the other on the bottom row and never stack" {
    try std.testing.expectEqualStrings("13", Item.record_13.recordName().?);
    try std.testing.expectEqualStrings("cat", Item.record_cat.recordName().?);
    try std.testing.expectEqual(@as(?u8, 240), Item.record_13.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 241), Item.record_cat.iconTile(0));
    try std.testing.expectEqual(@as(u8, 1), Item.record_13.maxStackSize());
    try std.testing.expectEqual(@as(u8, 1), Item.record_cat.maxStackSize());
    try std.testing.expectEqualStrings("Music Disc", Item.record_13.displayName(0));
    try std.testing.expectEqualStrings("Music Disc", Item.record_cat.displayName(0));
    try std.testing.expect(Item.record_13.isVanilla() and Item.record_cat.isVanilla());
    try std.testing.expect(Item.diamond.recordName() == null);
}

test "an id no vanilla item claims falls back to the empty definition" {
    for ([_]u16{ 0, 255, 400, first_item_id + def_capacity }) |raw| {
        const unclaimed: Item = @enumFromInt(raw);
        try std.testing.expect(unclaimed.tool() == null);
        try std.testing.expect(unclaimed.armor() == null);
        try std.testing.expect(unclaimed.placedBlock() == null);
        try std.testing.expect(unclaimed.bucketFill() == null);
        try std.testing.expectEqual(@as(u8, 64), unclaimed.maxStackSize());
        try std.testing.expectEqual(@as(?u8, null), unclaimed.iconTile(0));
        try std.testing.expectEqualStrings("", unclaimed.displayName(0));
    }
}

test "registering over an unclaimed id changes what every caller sees" {
    const custom: Item = @enumFromInt(400);
    const restore = custom.def().*;
    defer custom.register(restore);

    custom.register(.{
        .name = "Quartz Pickaxe",
        .icon = 6 * 16 + 5,
        .tool = .{ .kind = .pickaxe, .material = .diamond },
        .max_stack_size = 1,
    });

    try std.testing.expectEqualStrings("Quartz Pickaxe", custom.displayName(0));
    try std.testing.expectEqual(@as(?u8, 101), custom.iconTile(0));
    try std.testing.expectEqual(@as(u8, 1), custom.maxStackSize());
    try std.testing.expectEqual(@as(u16, 1561), custom.maxDamage());
    try std.testing.expect(custom.isDamageable());
    try std.testing.expectEqual(@as(i32, 5), custom.damageVsEntity());
    try std.testing.expect(custom.canHarvestBlock(.obsidian));
}

test "registry keys come straight off the enum tags, so they cannot drift" {
    try std.testing.expectEqualStrings("diamond", Item.diamond.def().key);
    try std.testing.expectEqualStrings("pickaxe_iron", Item.pickaxe_iron.def().key);
    try std.testing.expectEqual(Item.bucket_lava, Item.fromKey("bucket_lava").?);
    try std.testing.expect(Item.fromKey("nothing_of_the_sort") == null);
    try std.testing.expect(Item.fromKey("") == null);

    try std.testing.expect(Item.diamond.isVanilla());
    try std.testing.expect(!(@as(Item, @enumFromInt(400))).isVanilla());
    try std.testing.expect(!(@as(Item, @enumFromInt(0))).isVanilla());
}

test "a registered item answers to its own key without shadowing a vanilla one" {
    defer Item.resetRegistry();

    const custom: Item = @enumFromInt(400);
    custom.register(.{ .key = "rosebed:quartz_pickaxe", .name = "Quartz Pickaxe" });

    try std.testing.expectEqual(custom, Item.fromKey("rosebed:quartz_pickaxe").?);
    try std.testing.expectEqual(Item.diamond, Item.fromKey("diamond").?);
    try std.testing.expect(!custom.isVanilla());
}

fn quartzIcon(_: Item, damage: u16) ?u8 {
    return @intCast(100 + damage);
}

fn quartzLabel(_: Item, damage: u16) []const u8 {
    return if (damage == 0) "Quartz Pickaxe" else "Chipped Quartz Pickaxe";
}

test "a registered item's metadata hooks answer in place of the vanilla switch" {
    defer Item.resetRegistry();

    const custom: Item = @enumFromInt(400);
    custom.register(.{
        .key = "rosebed:quartz_pickaxe",
        .name = "Quartz Pickaxe",
        .icon = 12,
        .icon_tile = quartzIcon,
        .display_name = quartzLabel,
        .tool = .{ .kind = .pickaxe, .material = .diamond },
    });

    try std.testing.expectEqual(@as(?u8, 105), custom.iconTile(5));
    try std.testing.expectEqualStrings("Chipped Quartz Pickaxe", custom.displayName(2));
    try std.testing.expectEqualStrings("Quartz Pickaxe", custom.displayName(0));
    try std.testing.expectEqual(@as(u16, 1561), custom.maxDamage());
}

test "a vanilla item ignores the hooks and keeps the switch it always had" {
    try std.testing.expectEqual(@as(?u8, 78), Item.dye.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 142), Item.dye.iconTile(dye_meta_lapis));
    try std.testing.expectEqualStrings("Charcoal", Item.coal.displayName(coal_meta_charcoal));
    try std.testing.expectEqualStrings("Coal", Item.coal.displayName(0));
    try std.testing.expectEqualStrings("Diamond", Item.diamond.displayName(0));
}

test "a registered item with no hooks falls back to its constant icon and name" {
    defer Item.resetRegistry();

    const custom: Item = @enumFromInt(401);
    custom.register(.{ .key = "rosebed:marble", .name = "Marble", .icon = 55 });

    try std.testing.expectEqual(@as(?u8, 55), custom.iconTile(0));
    try std.testing.expectEqual(@as(?u8, 55), custom.iconTile(9));
    try std.testing.expectEqualStrings("Marble", custom.displayName(3));
    try std.testing.expect(custom.def().on_use == null);
}
