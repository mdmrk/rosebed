const std = @import("std");

const assets = @import("assets");

const item = @import("item.zig");
const Item = item.Item;
const JavaRandom = @import("JavaRandom.zig");
const World = @import("World.zig");

pub const Side = enum(u3) {
    down,
    up,
    north,
    south,
    west,
    east,

    pub fn step(self: Side) [3]i32 {
        return switch (self) {
            .down => .{ 0, -1, 0 },
            .up => .{ 0, 1, 0 },
            .north => .{ 0, 0, -1 },
            .south => .{ 0, 0, 1 },
            .west => .{ -1, 0, 0 },
            .east => .{ 1, 0, 0 },
        };
    }
};

pub const Material = enum {
    air,
    fire,
    portal,
    rock,
    iron,
    grass,
    ground,
    sand,
    wood,
    leaves,
    plants,
    sponge,
    cloth,
    glass,
    tnt,
    water,
    lava,
    snow,
    built_snow,
    ice,
    clay,
    pumpkin,
    cactus,
    circuits,
    cake,
    piston,
    web,

    pub fn blocksGrass(self: Material) bool {
        return switch (self) {
            .air, .fire, .portal, .plants, .snow, .circuits => false,
            else => true,
        };
    }

    pub fn isLiquid(self: Material) bool {
        return switch (self) {
            .water, .lava => true,
            else => false,
        };
    }

    pub fn isSolid(self: Material) bool {
        return self.blocksGrass() and !self.isLiquid();
    }

    pub fn buildsNormalCube(self: Material) bool {
        return switch (self) {
            .air, .fire, .portal, .plants, .circuits, .snow, .water, .lava => false,
            .leaves, .glass, .tnt, .ice, .cactus => false,
            else => true,
        };
    }

    pub fn isHarvestable(self: Material) bool {
        return switch (self) {
            .rock, .iron, .snow, .built_snow, .web => false,
            else => true,
        };
    }

    pub fn mapColor(self: Material) MapColor {
        return switch (self) {
            .air, .fire, .circuits, .glass, .portal, .cake => .air,
            .grass => .grass,
            .ground => .dirt,
            .wood => .wood,
            .rock, .piston => .stone,
            .iron => .iron,
            .water => .water,
            .lava, .tnt => .tnt,
            .leaves, .plants, .cactus, .pumpkin => .foliage,
            .sponge, .cloth, .web => .cloth,
            .sand => .sand,
            .ice => .ice,
            .snow, .built_snow => .snow,
            .clay => .clay,
        };
    }
};

pub const MapColor = enum(u4) {
    air = 0,
    grass = 1,
    sand = 2,
    cloth = 3,
    tnt = 4,
    ice = 5,
    iron = 6,
    foliage = 7,
    snow = 8,
    clay = 9,
    dirt = 10,
    stone = 11,
    water = 12,
    wood = 13,

    pub fn rgb(self: MapColor) u32 {
        return switch (self) {
            .air => 0,
            .grass => 8368696,
            .sand => 16247203,
            .cloth => 10987431,
            .tnt => 16711680,
            .ice => 10526975,
            .iron => 10987431,
            .foliage => 31744,
            .snow => 16777215,
            .clay => 10791096,
            .dirt => 12020271,
            .stone => 7368816,
            .water => 4210943,
            .wood => 6837042,
        };
    }
};

pub const Shape = union(enum) {
    cube,
    cross,
    fire,
    portal,
    torch,
    door,
    trapdoor,
    stairs,
    cake,
    bed,
    sign,
    wire,
    rail,
    lever,
    button,
    ladder,
    fence,
    plate,
    repeater,
    piston,
    piston_head,
    piston_moving,
    partial: f32,

    pub fn heightScale(self: Shape) f32 {
        return switch (self) {
            .partial => |height| height,
            else => 1.0,
        };
    }
};

pub const Bounds = struct { min: [3]f32, max: [3]f32 };

pub const Mobility = enum { movable, fragile, immovable };

pub const StepSound = enum {
    powder,
    wood,
    gravel,
    grass,
    stone,
    metal,
    glass,
    cloth,
    sand,

    pub fn walk(self: StepSound) assets.Sound {
        return switch (self) {
            .powder, .stone, .metal, .glass => assets.sounds.step.stone,
            .wood => assets.sounds.step.wood,
            .gravel => assets.sounds.step.gravel,
            .grass => assets.sounds.step.grass,
            .cloth => assets.sounds.step.cloth,
            .sand => assets.sounds.step.sand,
        };
    }

    pub fn destroy(self: StepSound) assets.Sound {
        return switch (self) {
            .glass => assets.sounds.random.glass,
            .sand => assets.sounds.step.gravel,
            else => self.walk(),
        };
    }

    pub fn volume(self: StepSound) f32 {
        _ = self;
        return 1.0;
    }

    pub fn pitch(self: StepSound) f32 {
        return switch (self) {
            .metal => 1.5,
            else => 1.0,
        };
    }
};

pub const Def = struct {
    key: []const u8 = "",
    name: []const u8 = "",
    material: Material = .rock,
    step_sound: StepSound = .powder,
    shape: Shape = .cube,
    face_textures: FaceTextures = FaceTextures.initFill(0),
    item_render_boxes: []const Bounds = &full_cube_box,
    hardness: f32 = 0.0,
    explosion_resistance: f32 = 0.0,
    side_inset: f32 = 0.0,
    tick_rate: u32 = 0,
    opaque_cube: bool = true,
    breakable: bool = false,
    translucent: bool = false,
    falling: bool = false,
    piston_base: bool = false,
    flammable: bool = false,
    replaceable: bool = false,
    drop: ?*const fn (Block, u4, *JavaRandom) ?Stack = null,
    selection_bounds: ?*const fn (Block, u4) Bounds = null,
    cross_tile: ?*const fn (Block, u4) u8 = null,
    display_name: ?*const fn (Block, u4) []const u8 = null,
    on_tick: ?*const fn (*World, i32, i32, i32, Block) std.mem.Allocator.Error!void = null,
    on_random_tick: ?*const fn (*World, i32, i32, i32, Block) std.mem.Allocator.Error!void = null,
    on_neighbor_change: ?*const fn (*World, i32, i32, i32, Block) std.mem.Allocator.Error!void = null,
    on_activated: ?*const fn (*World, i32, i32, i32, Block) std.mem.Allocator.Error!bool = null,
};

const vanilla_keys: [256][]const u8 = keysFromEnum();

fn keysFromEnum() [256][]const u8 {
    var out: [256][]const u8 = @splat("");
    for (@typeInfo(Block).@"enum".fields) |entry| out[entry.value] = entry.name;
    return out;
}

var defs: [256]Def = vanillaDefs();

fn vanillaDefs() [256]Def {
    @setEvalBranchQuota(200_000);
    var out: [256]Def = undefined;
    for (&out, 0..) |*entry, id| {
        const self: Block = @enumFromInt(id);
        entry.* = .{
            .key = vanilla_keys[id],
            .name = self.vanillaName(),
            .material = self.vanillaMaterial(),
            .step_sound = self.vanillaStepSound(),
            .shape = self.vanillaShape(),
            .face_textures = self.vanillaFaceTextures(),
            .item_render_boxes = self.vanillaItemRenderBoxes(),
            .hardness = self.vanillaHardness(),
            .explosion_resistance = self.vanillaExplosionResistance(),
            .side_inset = self.vanillaSideInset(),
            .tick_rate = self.vanillaTickRate(),
            .opaque_cube = self.vanillaOpaqueCube(),
            .breakable = self.vanillaBreakable(),
            .translucent = self.vanillaTranslucent(),
            .falling = self.vanillaFalling(),
            .piston_base = self.vanillaPistonBase(),
            .flammable = self.vanillaFlammable(),
            .replaceable = self.vanillaReplaceable(),
        };
    }
    return out;
}

pub const piston_facing_mask: u4 = 7;
pub const piston_flag: u4 = 8;
pub const piston_head_depth: f32 = 4.0 / 16.0;
pub const piston_shaft_half: f32 = 2.0 / 16.0;

pub fn pistonFacing(metadata: u4) Side {
    return switch (metadata & piston_facing_mask) {
        0 => .down,
        1 => .up,
        2 => .north,
        3 => .south,
        4 => .west,
        else => .east,
    };
}

pub fn pistonFacingValue(side: Side) u4 {
    return switch (side) {
        .down => 0,
        .up => 1,
        .north => 2,
        .south => 3,
        .west => 4,
        .east => 5,
    };
}

pub fn pistonExtended(metadata: u4) bool {
    return metadata & piston_flag != 0;
}

fn shrunkTowards(side: Side, depth: f32) Bounds {
    return switch (side) {
        .down => .{ .min = .{ 0, depth, 0 }, .max = .{ 1, 1, 1 } },
        .up => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1 - depth, 1 } },
        .north => .{ .min = .{ 0, 0, depth }, .max = .{ 1, 1, 1 } },
        .south => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 - depth } },
        .west => .{ .min = .{ depth, 0, 0 }, .max = .{ 1, 1, 1 } },
        .east => .{ .min = .{ 0, 0, 0 }, .max = .{ 1 - depth, 1, 1 } },
    };
}

pub fn pistonBaseBounds(metadata: u4) Bounds {
    if (!pistonExtended(metadata)) return .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    return shrunkTowards(pistonFacing(metadata), piston_head_depth);
}

pub fn pistonHeadPlateBounds(metadata: u4) Bounds {
    const facing = pistonFacing(metadata);
    const opposite: Side = switch (facing) {
        .down => .up,
        .up => .down,
        .north => .south,
        .south => .north,
        .west => .east,
        .east => .west,
    };
    return shrunkTowards(opposite, 1.0 - piston_head_depth);
}

pub fn pistonHeadShaftBounds(metadata: u4) Bounds {
    const q: f32 = 4.0 / 16.0;
    const n: f32 = 6.0 / 16.0;
    const w: f32 = 10.0 / 16.0;
    const t: f32 = 12.0 / 16.0;
    return switch (pistonFacing(metadata)) {
        .down => .{ .min = .{ n, q, n }, .max = .{ w, 1, w } },
        .up => .{ .min = .{ n, 0, n }, .max = .{ w, t, w } },
        .north => .{ .min = .{ q, n, q }, .max = .{ t, w, 1 } },
        .south => .{ .min = .{ q, n, 0 }, .max = .{ t, w, t } },
        .west => .{ .min = .{ n, q, q }, .max = .{ w, t, 1 } },
        .east => .{ .min = .{ 0, n, q }, .max = .{ t, w, t } },
    };
}

const full_cube_box = [1]Bounds{.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } }};

pub const FaceTextures = std.EnumArray(Side, u8);

fn uniform(tile: u8) FaceTextures {
    return FaceTextures.initFill(tile);
}

fn topAndSide(top: u8, bottom: u8, side: u8) FaceTextures {
    return FaceTextures.init(.{
        .down = bottom,
        .up = top,
        .north = side,
        .south = side,
        .west = side,
        .east = side,
    });
}

fn plantBounds(half_width: f32, height: f32) Bounds {
    return .{
        .min = .{ 0.5 - half_width, 0.0, 0.5 - half_width },
        .max = .{ 0.5 + half_width, height, 0.5 + half_width },
    };
}

pub const cactus_inset: f32 = 1.0 / 16.0;

pub const cactus_collision_bounds: Bounds = .{
    .min = .{ cactus_inset, 0.0, cactus_inset },
    .max = .{ 1.0 - cactus_inset, 1.0 - cactus_inset, 1.0 - cactus_inset },
};

pub const soul_sand_sink: f32 = 2.0 / 16.0;

pub const soul_sand_collision_bounds: Bounds = .{
    .min = .{ 0.0, 0.0, 0.0 },
    .max = .{ 1.0, 1.0 - soul_sand_sink, 1.0 },
};

pub const fence_post_bounds: Bounds = .{
    .min = .{ 6.0 / 16.0, 0.0, 6.0 / 16.0 },
    .max = .{ 10.0 / 16.0, 1.0, 10.0 / 16.0 },
};

pub const fence_collision_bounds: Bounds = .{
    .min = .{ 0.0, 0.0, 0.0 },
    .max = .{ 1.0, 1.5, 1.0 },
};

pub fn fenceRailBounds(upper: bool, along_x: bool, links_low: bool, links_high: bool) Bounds {
    const bottom: f32 = if (upper) 12.0 / 16.0 else 6.0 / 16.0;
    const top: f32 = bottom + 3.0 / 16.0;
    const low: f32 = if (links_low) 0.0 else 7.0 / 16.0;
    const high: f32 = if (links_high) 1.0 else 9.0 / 16.0;
    return if (along_x) .{
        .min = .{ low, bottom, 7.0 / 16.0 },
        .max = .{ high, top, 9.0 / 16.0 },
    } else .{
        .min = .{ 7.0 / 16.0, bottom, low },
        .max = .{ 9.0 / 16.0, top, high },
    };
}

pub const ladder_thickness: f32 = 2.0 / 16.0;

pub fn ladderBounds(metadata: u4) Bounds {
    return switch (metadata) {
        2 => .{ .min = .{ 0, 0, 1.0 - ladder_thickness }, .max = .{ 1, 1, 1 } },
        3 => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, ladder_thickness } },
        4 => .{ .min = .{ 1.0 - ladder_thickness, 0, 0 }, .max = .{ 1, 1, 1 } },
        5 => .{ .min = .{ 0, 0, 0 }, .max = .{ ladder_thickness, 1, 1 } },
        else => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } },
    };
}

pub const ladder_climb_cap: f64 = @as(f32, 0.15);
pub const ladder_climb_lift: f64 = 0.2;

pub const soul_sand_drag: f64 = 0.4;

pub const web_drag: f64 = 0.25;
pub const web_vertical_drag: f64 = @as(f32, 0.05);

pub const portal_thickness: f32 = 2.0 / 16.0;

pub fn portalBounds(spans_x: bool) Bounds {
    return if (spans_x)
        .{ .min = .{ 0.0, 0.0, 0.5 - portal_thickness }, .max = .{ 1.0, 1.0, 0.5 + portal_thickness } }
    else
        .{ .min = .{ 0.5 - portal_thickness, 0.0, 0.0 }, .max = .{ 0.5 + portal_thickness, 1.0, 1.0 } };
}

fn torchBounds(metadata: u4) Bounds {
    const wall: f32 = 0.15;
    return switch (metadata & 7) {
        1 => .{ .min = .{ 0.0, 0.2, 0.5 - wall }, .max = .{ wall * 2.0, 0.8, 0.5 + wall } },
        2 => .{ .min = .{ 1.0 - wall * 2.0, 0.2, 0.5 - wall }, .max = .{ 1.0, 0.8, 0.5 + wall } },
        3 => .{ .min = .{ 0.5 - wall, 0.2, 0.0 }, .max = .{ 0.5 + wall, 0.8, wall * 2.0 } },
        4 => .{ .min = .{ 0.5 - wall, 0.2, 1.0 - wall * 2.0 }, .max = .{ 0.5 + wall, 0.8, 1.0 } },
        else => plantBounds(0.1, 0.6),
    };
}

pub const Stack = struct {
    id: Id,
    count: u8,
    meta: u16 = 0,

    pub fn displayName(self: Stack) []const u8 {
        return switch (self.id) {
            .block => |id| id.displayName(self.blockMeta()),
            .item => |id| id.displayName(self.meta),
        };
    }

    pub fn blockMeta(self: Stack) u4 {
        return @truncate(self.meta);
    }

    pub fn maxDamage(self: Stack) u16 {
        return switch (self.id) {
            .block => 0,
            .item => |id| id.maxDamage(),
        };
    }

    pub fn isDamaged(self: Stack) bool {
        return self.maxDamage() > 0 and self.meta > 0;
    }

    pub fn damage(self: *Stack, amount: u16) void {
        if (self.maxDamage() == 0) return;
        self.meta += amount;
        if (self.meta <= self.maxDamage()) return;
        self.count -|= 1;
        self.meta = 0;
    }
};

pub const Id = union(enum) {
    block: Block,
    item: Item,

    pub fn eql(self: Id, other: Id) bool {
        return switch (self) {
            .block => |b| other == .block and other.block == b,
            .item => |i| other == .item and other.item == i,
        };
    }

    pub fn numeric(self: Id) i16 {
        return switch (self) {
            .block => |b| @intCast(@intFromEnum(b)),
            .item => |i| @bitCast(@as(u16, @intFromEnum(i))),
        };
    }

    pub fn fromNumeric(value: i16) Id {
        const raw: u16 = @bitCast(value);
        if (raw < 256) return .{ .block = @enumFromInt(@as(u8, @intCast(raw))) };
        return .{ .item = @enumFromInt(raw) };
    }

    pub fn maxStackSize(self: Id) u8 {
        return switch (self) {
            .block => 64,
            .item => |id| id.maxStackSize(),
        };
    }

    pub fn key(self: Id) []const u8 {
        return switch (self) {
            .block => |id| id.def().key,
            .item => |id| id.def().key,
        };
    }

    pub fn isVanilla(self: Id) bool {
        return switch (self) {
            .block => |id| id.isVanilla(),
            .item => |id| id.isVanilla(),
        };
    }

    pub fn resolve(stored: i16, name: []const u8) ?Id {
        if (name.len == 0) return fromNumeric(stored);
        const raw: u16 = @bitCast(stored);
        if (raw < 256) return .{ .block = Block.fromKey(name) orelse return null };
        return .{ .item = Item.fromKey(name) orelse return null };
    }
};

pub const Block = enum(u8) {
    air = 0,
    stone = 1,
    grass = 2,
    dirt = 3,
    cobblestone = 4,
    planks = 5,
    sapling = 6,
    bedrock = 7,
    flowing_water = 8,
    stationary_water = 9,
    flowing_lava = 10,
    stationary_lava = 11,
    sand = 12,
    gravel = 13,
    ore_gold = 14,
    ore_iron = 15,
    ore_coal = 16,
    log = 17,
    leaves = 18,
    sponge = 19,
    glass = 20,
    ore_lapis = 21,
    block_lapis = 22,
    dispenser = 23,
    sandstone = 24,
    note_block = 25,
    bed = 26,
    rail_powered = 27,
    rail_detector = 28,
    piston_sticky = 29,
    web = 30,
    ladder = 65,
    tall_grass = 31,
    fence = 85,
    dead_bush = 32,
    piston = 33,
    piston_head = 34,
    wool = 35,
    piston_moving = 36,
    dandelion = 37,
    rose = 38,
    mushroom_brown = 39,
    mushroom_red = 40,
    block_gold = 41,
    block_iron = 42,
    slab_double = 43,
    slab = 44,
    brick = 45,
    tnt = 46,
    bookshelf = 47,
    cobblestone_mossy = 48,
    obsidian = 49,
    torch = 50,
    fire = 51,
    mob_spawner = 52,
    stairs_wood = 53,
    chest = 54,
    redstone_wire = 55,
    ore_diamond = 56,
    block_diamond = 57,
    workbench = 58,
    furnace = 61,
    burning_furnace = 62,
    sign_post = 63,
    door_wood = 64,
    rail = 66,
    stairs_cobblestone = 67,
    wall_sign = 68,
    lever = 69,
    pressure_plate_stone = 70,
    door_iron = 71,
    pressure_plate_planks = 72,
    ore_redstone = 73,
    ore_redstone_glowing = 74,
    torch_redstone_off = 75,
    torch_redstone_on = 76,
    button = 77,
    snow_layer = 78,
    ice = 79,
    snow_block = 80,
    cactus = 81,
    clay = 82,
    reed = 83,
    jukebox = 84,
    pumpkin = 86,
    netherrack = 87,
    soul_sand = 88,
    glowstone = 89,
    portal = 90,
    jack_o_lantern = 91,
    cake = 92,
    repeater_off = 93,
    repeater_on = 94,
    trapdoor = 96,
    _,

    pub fn def(self: Block) *const Def {
        return &defs[@intFromEnum(self)];
    }

    pub fn register(self: Block, definition: Def) void {
        defs[@intFromEnum(self)] = definition;
    }

    pub fn resetRegistry() void {
        defs = vanillaDefs();
    }

    pub fn isVanilla(self: Block) bool {
        return vanilla_keys[@intFromEnum(self)].len != 0;
    }

    pub fn fromKey(key: []const u8) ?Block {
        if (key.len == 0) return null;
        for (defs, 0..) |entry, id| {
            if (std.mem.eql(u8, entry.key, key)) return @enumFromInt(id);
        }
        return null;
    }

    pub fn material(self: Block) Material {
        return self.def().material;
    }

    pub fn stepSound(self: Block) StepSound {
        return self.def().step_sound;
    }

    fn vanillaStepSound(self: Block) StepSound {
        return switch (self) {
            .stone, .cobblestone, .bedrock, .ore_gold, .ore_iron, .ore_coal => .stone,
            .ore_lapis, .block_lapis, .dispenser, .sandstone, .slab_double, .slab => .stone,
            .brick, .cobblestone_mossy, .obsidian, .ore_diamond, .furnace => .stone,
            .burning_furnace, .pressure_plate_stone, .button, .jukebox, .netherrack => .stone,
            .ore_redstone, .ore_redstone_glowing => .stone,
            .planks, .log, .bookshelf, .torch, .chest, .workbench, .sign_post => .wood,
            .door_wood, .wall_sign, .lever, .pressure_plate_planks, .torch_redstone_off => .wood,
            .torch_redstone_on, .fire, .pumpkin, .jack_o_lantern, .repeater_off => .wood,
            .repeater_on, .trapdoor, .ladder, .fence => .wood,
            .dirt, .gravel, .clay => .gravel,
            .grass, .sapling, .leaves, .sponge, .tall_grass, .dead_bush, .dandelion => .grass,
            .rose, .mushroom_brown, .mushroom_red, .tnt, .reed => .grass,
            .rail_powered, .rail_detector, .block_gold, .block_iron, .mob_spawner => .metal,
            .rail, .door_iron, .block_diamond => .metal,
            .glass, .ice, .glowstone, .portal => .glass,
            .wool, .snow_layer, .snow_block, .cactus, .cake => .cloth,
            .sand, .soul_sand => .sand,
            else => .powder,
        };
    }

    fn vanillaMaterial(self: Block) Material {
        return switch (self) {
            .air => .air,
            .stone, .cobblestone, .cobblestone_mossy, .bedrock, .mob_spawner, .stairs_cobblestone => .rock,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => .rock,
            .ore_redstone_glowing, .pressure_plate_stone => .rock,
            .block_lapis, .sandstone, .brick, .obsidian, .netherrack, .glowstone => .rock,
            .slab, .slab_double => .rock,
            .furnace, .burning_furnace, .dispenser => .rock,
            .block_gold, .block_iron, .block_diamond, .door_iron => .iron,
            .grass => .grass,
            .dirt => .ground,
            .sand, .gravel, .soul_sand => .sand,
            .planks, .log, .note_block, .bookshelf, .workbench, .jukebox, .chest, .door_wood, .trapdoor, .stairs_wood, .sign_post, .wall_sign => .wood,
            .pressure_plate_planks => .wood,
            .leaves => .leaves,
            .sponge => .sponge,
            .wool => .cloth,
            .glass => .glass,
            .tnt => .tnt,
            .ice => .ice,
            .snow_block => .built_snow,
            .sapling, .tall_grass, .dead_bush, .dandelion, .rose, .mushroom_brown, .mushroom_red, .reed => .plants,
            .flowing_water, .stationary_water => .water,
            .flowing_lava, .stationary_lava => .lava,
            .snow_layer => .snow,
            .clay => .clay,
            .cactus => .cactus,
            .pumpkin, .jack_o_lantern => .pumpkin,
            .bed => .cloth,
            .cake => .cake,
            .torch, .torch_redstone_off, .torch_redstone_on => .circuits,
            .redstone_wire, .lever, .button, .repeater_off, .repeater_on => .circuits,
            .rail, .rail_powered, .rail_detector, .ladder => .circuits,
            .fence => .wood,
            .fire => .fire,
            .portal => .portal,
            .piston, .piston_sticky, .piston_head, .piston_moving => .piston,
            else => .rock,
        };
    }

    pub fn shape(self: Block) Shape {
        return self.def().shape;
    }

    fn vanillaShape(self: Block) Shape {
        return switch (self) {
            .sapling, .tall_grass, .dead_bush, .dandelion, .rose, .mushroom_brown, .mushroom_red, .reed, .web => .cross,
            .fire => .fire,
            .portal => .portal,
            .torch, .torch_redstone_off, .torch_redstone_on => .torch,
            .redstone_wire => .wire,
            .rail, .rail_powered, .rail_detector => .rail,
            .lever => .lever,
            .button => .button,
            .pressure_plate_stone, .pressure_plate_planks => .plate,
            .ladder => .ladder,
            .fence => .fence,
            .repeater_off, .repeater_on => .repeater,
            .door_wood, .door_iron => .door,
            .trapdoor => .trapdoor,
            .bed => .bed,
            .sign_post, .wall_sign => .sign,
            .stairs_wood, .stairs_cobblestone => .stairs,
            .cake => .cake,
            .snow_layer => .{ .partial = 0.125 },
            .slab => .{ .partial = 0.5 },
            .piston, .piston_sticky => .piston,
            .piston_head => .piston_head,
            .piston_moving => .piston_moving,
            else => .cube,
        };
    }

    pub fn isCross(self: Block) bool {
        return self.shape() == .cross;
    }

    pub fn isDoor(self: Block) bool {
        return self.shape() == .door;
    }

    pub fn isTrapdoor(self: Block) bool {
        return self.shape() == .trapdoor;
    }

    pub fn isSign(self: Block) bool {
        return self.shape() == .sign;
    }

    pub fn hasCollision(self: Block) bool {
        if (self.shape() == .plate or self == .web) return false;
        if (self == .ladder) return true;
        return self.isSolid() and !self.isSign();
    }

    pub fn isTorch(self: Block) bool {
        return self.shape() == .torch;
    }

    pub fn isRepeater(self: Block) bool {
        return self.shape() == .repeater;
    }

    pub fn isCake(self: Block) bool {
        return self.shape() == .cake;
    }

    pub fn isStairs(self: Block) bool {
        return self.shape() == .stairs;
    }

    pub fn heightScale(self: Block) f32 {
        return self.shape().heightScale();
    }

    pub fn sideInset(self: Block) f32 {
        return self.def().side_inset;
    }

    fn vanillaSideInset(self: Block) f32 {
        return switch (self) {
            .cactus => 1.0 / 16.0,
            else => 0.0,
        };
    }

    pub fn isOpaque(self: Block) bool {
        return self.material().blocksGrass();
    }

    pub fn isLiquid(self: Block) bool {
        return self.material().isLiquid();
    }

    pub fn isSolid(self: Block) bool {
        return self.material().isSolid();
    }

    pub fn tickRate(self: Block) u32 {
        return self.def().tick_rate;
    }

    fn vanillaTickRate(self: Block) u32 {
        if (self.vanillaFalling()) return 3;
        return switch (self) {
            .torch_redstone_off, .torch_redstone_on => 2,
            .dispenser => 4,
            .rail_detector => 20,
            .button, .pressure_plate_stone, .pressure_plate_planks => 20,
            .ore_redstone_glowing => 30,
            else => switch (self.vanillaMaterial()) {
                .water => 5,
                .lava => 30,
                else => 0,
            },
        };
    }

    pub fn isOpaqueCube(self: Block) bool {
        return self.def().opaque_cube;
    }

    fn vanillaOpaqueCube(self: Block) bool {
        return switch (self) {
            .leaves, .glass, .ice, .cactus, .door_wood, .door_iron, .trapdoor, .cake, .bed => false,
            .sign_post, .wall_sign => false,
            .web, .ladder, .fence => false,
            .stairs_wood, .stairs_cobblestone => false,
            .slab => false,
            .pressure_plate_stone, .pressure_plate_planks => false,
            .piston, .piston_sticky, .piston_head, .piston_moving => false,
            else => self.vanillaMaterial().blocksGrass() and !self.vanillaMaterial().isLiquid(),
        };
    }

    pub fn mobility(self: Block) Mobility {
        return switch (self.material()) {
            .water, .lava, .leaves, .plants, .circuits => .fragile,
            .snow, .cactus, .pumpkin, .cake, .fire, .web => .fragile,
            .piston => .immovable,
            else => .movable,
        };
    }

    pub fn isPistonBase(self: Block) bool {
        return self.def().piston_base;
    }

    fn vanillaPistonBase(self: Block) bool {
        return self == .piston or self == .piston_sticky;
    }

    pub fn isNormalCube(self: Block) bool {
        if (!self.material().buildsNormalCube()) return false;
        return self.shape() == .cube;
    }

    pub fn isBreakable(self: Block) bool {
        return self.def().breakable;
    }

    fn vanillaBreakable(self: Block) bool {
        return self == .glass or self == .ice;
    }

    pub fn isTranslucent(self: Block) bool {
        return self.def().translucent;
    }

    fn vanillaTranslucent(self: Block) bool {
        return self.vanillaMaterial() == .water or self == .ice or self == .portal;
    }

    pub fn isFalling(self: Block) bool {
        return self.def().falling;
    }

    fn vanillaFalling(self: Block) bool {
        return self == .sand or self == .gravel;
    }

    pub fn isFlammable(self: Block) bool {
        return self.def().flammable;
    }

    fn vanillaFlammable(self: Block) bool {
        return switch (self) {
            .planks, .stairs_wood, .log, .leaves, .bookshelf, .tnt, .tall_grass, .wool, .fence => true,
            else => false,
        };
    }

    pub fn canFallInto(self: Block) bool {
        return self == .air or self.isLiquid();
    }

    pub fn isReplaceable(self: Block) bool {
        return self.def().replaceable;
    }

    fn vanillaReplaceable(self: Block) bool {
        return self == .air or self.vanillaMaterial().isLiquid() or self == .snow_layer;
    }

    pub fn selectionBounds(self: Block, metadata: u4) Bounds {
        if (self.def().selection_bounds) |hook| return hook(self, metadata);
        return self.vanillaSelectionBounds(metadata);
    }

    fn vanillaSelectionBounds(self: Block, metadata: u4) Bounds {
        return switch (self) {
            .tall_grass, .dead_bush => plantBounds(0.4, 0.8),
            .dandelion, .rose => plantBounds(0.2, 0.6),
            .mushroom_brown, .mushroom_red => plantBounds(0.2, 0.4),
            .reed => plantBounds(6.0 / 16.0, 1.0),
            .cactus => plantBounds(7.0 / 16.0, 1.0),
            .torch, .torch_redstone_off, .torch_redstone_on => torchBounds(metadata),
            .portal => portalBounds(false),
            .redstone_wire => wire_bounds,
            .rail, .rail_powered, .rail_detector => railBounds(metadata),
            .lever => leverBounds(metadata),
            .button => buttonBounds(metadata),
            .pressure_plate_stone, .pressure_plate_planks => plateBounds(metadata),
            .repeater_off, .repeater_on => repeater_bounds,
            .door_wood, .door_iron => doorBounds(metadata),
            .trapdoor => trapdoorBounds(metadata),
            .ladder => ladderBounds(metadata),
            .cake => cakeBounds(metadata),
            .bed => bed_bounds,
            .sign_post => sign_post_bounds,
            .wall_sign => wallSignBounds(metadata),
            .piston, .piston_sticky => pistonBaseBounds(metadata),
            .piston_head => pistonHeadPlateBounds(metadata),
            else => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, self.heightScale(), 1 } },
        };
    }

    pub fn itemRenderBoxes(self: Block) []const Bounds {
        return self.def().item_render_boxes;
    }

    fn vanillaItemRenderBoxes(self: Block) []const Bounds {
        return switch (self) {
            .cake => &cake_item_boxes,
            .trapdoor => &trapdoor_item_boxes,
            .slab => &slab_item_boxes,
            .button => &button_item_boxes,
            .pressure_plate_stone, .pressure_plate_planks => &plate_item_boxes,
            .stairs_wood, .stairs_cobblestone => &stairs_item_boxes,
            .fence => &fence_item_boxes,
            else => &full_cube_box,
        };
    }

    pub fn shouldRenderFace(self: Block, neighbor: Block, side: Side, fancy: bool) bool {
        if (self.isLiquid()) {
            if (neighbor.material() == self.material()) return false;
            if (neighbor.material() == .ice) return false;
            if (side == .up) return true;
        }
        if (self == .leaves and !fancy and neighbor == .leaves) return false;
        if (self.isBreakable() and neighbor == self) return false;
        if (self == .slab or self == .slab_double) {
            if (side == .up) return true;
            if (!neighbor.isOpaqueCube()) return side == .down or neighbor != self;
            return false;
        }
        return !neighbor.isOpaqueCube();
    }

    pub fn faceTextures(self: Block) FaceTextures {
        return self.def().face_textures;
    }

    fn vanillaFaceTextures(self: Block) FaceTextures {
        return switch (self) {
            .stone => uniform(1),
            .grass => topAndSide(0, 2, 3),
            .dirt => uniform(2),
            .planks => uniform(4),
            .bedrock => uniform(17),
            .flowing_water, .stationary_water => topAndSide(205, 205, 206),
            .flowing_lava, .stationary_lava => topAndSide(237, 237, 238),
            .sand => uniform(18),
            .gravel => uniform(19),
            .ore_gold => uniform(32),
            .ore_iron => uniform(33),
            .ore_coal => uniform(34),
            .log => topAndSide(21, 21, 20),
            .leaves => uniform(52),
            .ore_lapis => uniform(160),
            .ore_diamond => uniform(50),
            .ore_redstone => uniform(51),
            .clay => uniform(72),
            .cactus => topAndSide(69, 71, 70),
            .pumpkin => pumpkinTextures(self, pumpkin_default_facing),
            .snow_layer => uniform(66),
            .cobblestone => uniform(16),
            .cobblestone_mossy => uniform(36),
            .mob_spawner => uniform(65),
            .sponge => uniform(48),
            .glass => uniform(49),
            .block_lapis => uniform(144),
            .sandstone => topAndSide(176, 208, 192),
            .note_block => uniform(74),
            .wool => uniform(woolTile(0)),
            .block_gold => uniform(23),
            .block_iron => uniform(22),
            .brick => uniform(7),
            .tnt => topAndSide(9, 10, 8),
            .bookshelf => topAndSide(4, 4, 35),
            .obsidian => uniform(37),
            .torch => uniform(80),
            .fire => uniform(31),
            .ore_redstone_glowing => uniform(51),
            .redstone_wire => uniform(wire_cross_tile),
            .rail => uniform(rail_straight_tile),
            .rail_powered => uniform(rail_powered_off_tile),
            .rail_detector => uniform(rail_detector_tile),
            .lever => uniform(lever_tile),
            .button, .pressure_plate_stone => uniform(1),
            .pressure_plate_planks => uniform(4),
            .torch_redstone_off => uniform(torch_redstone_off_tile),
            .torch_redstone_on => uniform(torch_redstone_on_tile),
            .repeater_off, .repeater_on => repeaterTextures(self),
            .block_diamond => uniform(24),
            .workbench => FaceTextures.init(.{
                .down = 4,
                .up = 43,
                .north = 60,
                .south = 59,
                .west = 60,
                .east = 59,
            }),
            .furnace, .burning_furnace => furnaceTextures(self, furnace_default_facing),
            .dispenser => dispenserTextures(dispenser_default_facing),
            .chest => chestItemTextures(),
            .door_wood => uniform(door_bottom_tile),
            .door_iron => uniform(door_bottom_tile + 1),
            .trapdoor => uniform(trapdoor_tile),
            .slab, .slab_double => slabTextures(0),
            .stairs_wood => uniform(4),
            .stairs_cobblestone => uniform(16),
            .ice => uniform(67),
            .snow_block => uniform(66),
            .jukebox => topAndSide(75, 74, 74),
            .netherrack => uniform(103),
            .ladder => uniform(83),
            .fence => uniform(4),
            .soul_sand => uniform(104),
            .glowstone => uniform(105),
            .portal => uniform(14),
            .cake => cakeTextures(0),
            .bed => bedTextures(0),
            .sign_post, .wall_sign => uniform(sign_particle_tile),
            .jack_o_lantern => pumpkinTextures(self, pumpkin_default_facing),
            .piston, .piston_sticky => pistonBaseTextures(self, piston_item_metadata),
            .piston_head => pistonHeadTextures(piston_item_metadata),
            .piston_moving => uniform(piston_side_tile),
            else => uniform(0),
        };
    }

    pub fn crossTile(self: Block, metadata: u4) u8 {
        if (self.def().cross_tile) |hook| return hook(self, metadata);
        if (!self.isVanilla()) return self.def().face_textures.get(.down);
        return self.vanillaCrossTile(metadata);
    }

    fn vanillaCrossTile(self: Block, metadata: u4) u8 {
        return switch (self) {
            .sapling => switch (metadata & 3) {
                1 => 63,
                2 => 79,
                else => 15,
            },
            .tall_grass => if (metadata == 2) 56 else 39,
            .web => 11,
            .dead_bush => 55,
            .dandelion => 13,
            .rose => 12,
            .mushroom_brown => 29,
            .mushroom_red => 28,
            .reed => 73,
            else => 0,
        };
    }

    pub fn flatItemTile(self: Block, metadata: u4) ?u8 {
        return switch (self.shape()) {
            .cross => self.crossTile(metadata),
            .torch, .fire, .wire, .lever, .repeater, .rail, .ladder => self.faceTextures().get(.down),
            else => null,
        };
    }

    pub fn particleTile(self: Block, metadata: u4) u8 {
        return switch (self.shape()) {
            .cross => self.crossTile(metadata),
            else => self.faceTextures().get(.down),
        };
    }

    fn hardness(self: Block) f32 {
        return self.def().hardness;
    }

    fn vanillaHardness(self: Block) f32 {
        return switch (self) {
            .stone => 1.5,
            .grass => 0.6,
            .dirt => 0.5,
            .planks => 2.0,
            .bedrock => -1.0,
            .flowing_water, .stationary_water => 100.0,
            .flowing_lava => 0.0,
            .stationary_lava => 100.0,
            .sand => 0.5,
            .gravel => 0.6,
            .ore_gold, .ore_iron, .ore_coal, .ore_lapis, .ore_diamond, .ore_redstone => 3.0,
            .ore_redstone_glowing => 3.0,
            .redstone_wire, .torch_redstone_off, .torch_redstone_on, .repeater_off, .repeater_on => 0.0,
            .lever, .button, .pressure_plate_stone, .pressure_plate_planks => 0.5,
            .log => 2.0,
            .leaves => 0.2,
            .clay => 0.6,
            .cactus => 0.4,
            .pumpkin => 1.0,
            .snow_layer => 0.1,
            .cobblestone, .cobblestone_mossy => 2.0,
            .stairs_wood, .stairs_cobblestone => 2.0,
            .slab, .slab_double => 2.0,
            .mob_spawner => 5.0,
            .sponge => 0.6,
            .glass => 0.3,
            .block_lapis => 3.0,
            .sandstone => 0.8,
            .note_block => 0.8,
            .wool => 0.8,
            .block_gold => 3.0,
            .block_iron => 5.0,
            .brick => 2.0,
            .tnt => 0.0,
            .bookshelf => 1.5,
            .obsidian => 10.0,
            .torch => 0.0,
            .rail, .rail_powered, .rail_detector => 0.7,
            .block_diamond => 5.0,
            .workbench => 2.5,
            .chest => 2.5,
            .furnace, .burning_furnace, .dispenser => 3.5,
            .door_wood, .trapdoor => 3.0,
            .door_iron => 5.0,
            .ice => 0.5,
            .snow_block => 0.2,
            .jukebox => 2.0,
            .netherrack => 0.4,
            .soul_sand => 0.5,
            .web => 4.0,
            .ladder => 0.4,
            .fence => 2.0,
            .glowstone => 0.3,
            .jack_o_lantern => 1.0,
            .cake => 0.5,
            .bed => 0.2,
            .sign_post, .wall_sign => 1.0,
            .piston, .piston_sticky, .piston_head => 0.5,
            .piston_moving, .portal => -1.0,
            else => 0.0,
        };
    }

    pub fn explosionResistance(self: Block) f32 {
        return self.def().explosion_resistance;
    }

    fn vanillaExplosionResistance(self: Block) f32 {
        return switch (self) {
            .bedrock => 3600000.0,
            .obsidian => 1200.0,
            .stone,
            .cobblestone,
            .cobblestone_mossy,
            .brick,
            .slab,
            .slab_double,
            .stairs_cobblestone,
            .block_gold,
            .block_iron,
            .block_diamond,
            .jukebox,
            => 6.0,
            .planks,
            .stairs_wood,
            .fence,
            .block_lapis,
            .ore_gold,
            .ore_iron,
            .ore_coal,
            .ore_lapis,
            .ore_diamond,
            .ore_redstone,
            .ore_redstone_glowing,
            => 3.0,
            else => @max(self.vanillaHardness(), 0.0),
        };
    }

    pub fn isUnbreakable(self: Block) bool {
        return self.hardness() < 0.0;
    }

    pub fn harvestableWith(self: Block, held: ?Stack) bool {
        if (self.material().isHarvestable()) return true;
        const stack = held orelse return false;
        return switch (stack.id) {
            .block => false,
            .item => |id| id.canHarvestBlock(self),
        };
    }

    pub fn strVsBlock(self: Block, held: ?Stack) f32 {
        const stack = held orelse return 1.0;
        return switch (stack.id) {
            .block => 1.0,
            .item => |id| id.strVsBlock(self),
        };
    }

    pub fn strength(self: Block, held: ?Stack, speed_factor: f32) f32 {
        const h = self.hardness();
        if (h < 0.0) return 0.0;
        if (!self.harvestableWith(held)) return 1.0 / h / 100.0;
        return self.strVsBlock(held) * speed_factor / h / 30.0;
    }

    pub fn displayName(self: Block, metadata: u4) []const u8 {
        if (self.def().display_name) |hook| return hook(self, metadata);
        return switch (self) {
            .wool => wool_names[~metadata],
            .slab, .slab_double => slabName(metadata),
            else => self.def().name,
        };
    }

    fn vanillaName(self: Block) []const u8 {
        return switch (self) {
            .stone => "Stone",
            .grass => "Grass",
            .dirt => "Dirt",
            .cobblestone => "Cobblestone",
            .planks => "Wooden Planks",
            .sapling => "Sapling",
            .bedrock => "Bedrock",
            .flowing_water, .stationary_water => "Water",
            .flowing_lava, .stationary_lava => "Lava",
            .sand => "Sand",
            .gravel => "Gravel",
            .ore_gold => "Gold Ore",
            .ore_iron => "Iron Ore",
            .ore_coal => "Coal Ore",
            .log => "Wood",
            .leaves => "Leaves",
            .ore_lapis => "Lapis Lazuli Ore",
            .dandelion => "Flower",
            .rose => "Rose",
            .mushroom_brown, .mushroom_red => "Mushroom",
            .cobblestone_mossy => "Moss Stone",
            .mob_spawner => "Monster Spawner",
            .ore_diamond => "Diamond Ore",
            .ore_redstone, .ore_redstone_glowing => "Redstone Ore",
            .redstone_wire => "Redstone Dust",
            .rail => "Rail",
            .rail_powered => "Powered Rail",
            .rail_detector => "Detector Rail",
            .lever => "Lever",
            .button => "Button",
            .pressure_plate_stone, .pressure_plate_planks => "Pressure Plate",
            .torch_redstone_off, .torch_redstone_on => "Redstone Torch",
            .repeater_off, .repeater_on => "Redstone Repeater",
            .snow_layer => "Snow",
            .clay => "Clay",
            .cactus => "Cactus",
            .reed => "Sugar cane",
            .pumpkin => "Pumpkin",
            .sponge => "Sponge",
            .glass => "Glass",
            .block_lapis => "Lapis Lazuli Block",
            .sandstone => "Sandstone",
            .note_block => "Note Block",
            .block_gold => "Block of Gold",
            .block_iron => "Block of Iron",
            .brick => "Bricks",
            .tnt => "TNT",
            .bookshelf => "Bookshelf",
            .obsidian => "Obsidian",
            .torch => "Torch",
            .block_diamond => "Block of Diamond",
            .workbench => "Crafting Table",
            .furnace, .burning_furnace => "Furnace",
            .dispenser => "Dispenser",
            .door_wood => "Wooden Door",
            .trapdoor => "Trapdoor",
            .stairs_wood => "Wooden Stairs",
            .stairs_cobblestone => "Stone Stairs",
            .door_iron => "Iron Door",
            .ice => "Ice",
            .snow_block => "Snow",
            .jukebox => "Jukebox",
            .chest => "Chest",
            .fire => "Fire",
            .portal => "Portal",
            .netherrack => "Netherrack",
            .soul_sand => "Soul Sand",
            .web => "Cobweb",
            .ladder => "Ladder",
            .fence => "Fence",
            .glowstone => "Glowstone",
            .jack_o_lantern => "Jack 'o' Lantern",
            .cake => "Cake",
            .bed => "Bed",
            .sign_post, .wall_sign => "Sign",
            else => "",
        };
    }

    pub fn drop(self: Block, meta: u4, rand: *JavaRandom) ?Stack {
        if (self.def().drop) |hook| return hook(self, meta, rand);
        return self.vanillaDrop(meta, rand);
    }

    pub fn harvestDrop(self: Block, meta: u4, held: ?Stack, rand: *JavaRandom) ?Stack {
        if (self == .snow_layer) return .{ .id = .{ .item = .snowball }, .count = 1 };
        return self.shearedDrop(meta, held) orelse self.drop(meta, rand);
    }

    pub fn shearedDrop(self: Block, meta: u4, held: ?Stack) ?Stack {
        const stack = held orelse return null;
        switch (stack.id) {
            .block => return null,
            .item => |id| if (id != .shears) return null,
        }
        return switch (self) {
            .leaves => .{ .id = .{ .block = .leaves }, .count = 1, .meta = meta & 3 },
            else => null,
        };
    }

    fn vanillaDrop(self: Block, meta: u4, rand: *JavaRandom) ?Stack {
        return switch (self) {
            .stone => .{ .id = .{ .block = .cobblestone }, .count = 1 },
            .grass => .{ .id = .{ .block = .dirt }, .count = 1 },
            .sign_post, .wall_sign => .{ .id = .{ .item = .sign }, .count = 1 },
            .slab => .{ .id = .{ .block = .slab }, .count = 1, .meta = meta },
            .slab_double => .{ .id = .{ .block = .slab }, .count = 2, .meta = meta },
            .stairs_wood => .{ .id = .{ .block = .planks }, .count = 1 },
            .stairs_cobblestone => .{ .id = .{ .block = .cobblestone }, .count = 1 },
            .gravel => if (rand.nextIntBound(10) == 0)
                .{ .id = .{ .item = .flint }, .count = 1 }
            else
                .{ .id = .{ .block = .gravel }, .count = 1 },
            .ore_coal => .{ .id = .{ .item = .coal }, .count = 1 },
            .ore_diamond => .{ .id = .{ .item = .diamond }, .count = 1 },
            .ore_redstone, .ore_redstone_glowing => .{ .id = .{ .item = .redstone }, .count = @intCast(4 + rand.nextIntBound(2)) },
            .redstone_wire => .{ .id = .{ .item = .redstone }, .count = 1 },
            .rail_powered => .{ .id = .{ .block = .rail_powered }, .count = 1 },
            .rail_detector => .{ .id = .{ .block = .rail_detector }, .count = 1 },
            .torch_redstone_off, .torch_redstone_on => .{ .id = .{ .block = .torch_redstone_on }, .count = 1 },
            .repeater_off, .repeater_on => .{ .id = .{ .item = .repeater }, .count = 1 },
            .ore_lapis => .{ .id = .{ .item = .dye }, .count = @intCast(4 + rand.nextIntBound(5)), .meta = item.dye_meta_lapis },
            .log => .{ .id = .{ .block = .log }, .count = 1, .meta = meta },
            .leaves => if (rand.nextIntBound(20) == 0) .{ .id = .{ .block = .sapling }, .count = 1, .meta = meta & 3 } else null,
            .clay => .{ .id = .{ .item = .clay_ball }, .count = 4 },
            .tall_grass => if (rand.nextIntBound(8) == 0) .{ .id = .{ .item = .seeds }, .count = 1 } else null,
            .dead_bush => null,
            .web => .{ .id = .{ .item = .string }, .count = 1 },
            .reed => .{ .id = .{ .item = .reed }, .count = 1 },
            .snow_layer => null,
            .snow_block => .{ .id = .{ .item = .snowball }, .count = 4 },
            .glowstone => .{ .id = .{ .item = .glowstone_dust }, .count = @intCast(2 + rand.nextIntBound(3)) },
            .wool => .{ .id = .{ .block = .wool }, .count = 1, .meta = meta },
            .furnace, .burning_furnace => .{ .id = .{ .block = .furnace }, .count = 1 },
            .door_wood => if (meta & door_top_bit != 0) null else .{ .id = .{ .item = .door_wood }, .count = 1 },
            .door_iron => if (meta & door_top_bit != 0) null else .{ .id = .{ .item = .door_iron }, .count = 1 },
            .glass, .bookshelf, .ice => null,
            .fire, .portal => null,
            .mob_spawner => null,
            .cake => null,
            .bed => if (bedIsPillow(meta)) null else .{ .id = .{ .item = .bed }, .count = 1 },
            .flowing_water, .stationary_water, .flowing_lava, .stationary_lava => null,
            .piston_head, .piston_moving => null,
            else => .{ .id = .{ .block = self }, .count = 1 },
        };
    }
};

pub fn leafTile(metadata: u4, fancy: bool) u8 {
    const base: u8 = if (fancy) 52 else 53;
    return if (metadata & 3 == 1) base + 80 else base;
}

const wool_names: [16][]const u8 = .{
    "Black Wool",
    "Red Wool",
    "Green Wool",
    "Brown Wool",
    "Blue Wool",
    "Purple Wool",
    "Cyan Wool",
    "Light Gray Wool",
    "Gray Wool",
    "Pink Wool",
    "Lime Wool",
    "Yellow Wool",
    "Light Blue Wool",
    "Magenta Wool",
    "Orange Wool",
    "Wool",
};

fn slabName(metadata: u4) []const u8 {
    return switch (metadata) {
        slab_sandstone => "Sandstone Slab",
        slab_wood => "Wooden Slab",
        else => "Stone Slab",
    };
}

pub fn woolTile(metadata: u4) u8 {
    if (metadata == 0) return 64;
    const inverted: u8 = ~metadata;
    return 113 + ((inverted & 8) >> 3) + (inverted & 7) * 16;
}

pub const grass_side_tile: u8 = 3;
pub const grass_side_overlay_tile: u8 = 38;
const snow_side_tile: u8 = 68;

pub fn grassSideTile(above: Block) u8 {
    return switch (above.material()) {
        .snow, .built_snow => snow_side_tile,
        else => grass_side_tile,
    };
}

pub fn logSideTile(metadata: u4) u8 {
    return switch (metadata) {
        1 => 116,
        2 => 117,
        else => 20,
    };
}

const furnace_side_tile: u8 = 45;
const furnace_top_tile: u8 = 62;
const furnace_front_tile: u8 = 44;
const furnace_front_lit_tile: u8 = 61;
pub const furnace_default_facing: u4 = @intFromEnum(Side.south);

pub fn furnaceFacing(metadata: u4) Side {
    return switch (metadata) {
        @intFromEnum(Side.north), @intFromEnum(Side.west), @intFromEnum(Side.east) => @enumFromInt(metadata),
        else => .south,
    };
}

pub fn furnaceFacingFromYaw(yaw: f32) u4 {
    const quarter = @floor(@mod(yaw, 360.0) * 4.0 / 360.0 + 0.5);
    return switch (@as(u2, @intFromFloat(@mod(quarter, 4.0)))) {
        0 => @intFromEnum(Side.north),
        1 => @intFromEnum(Side.east),
        2 => @intFromEnum(Side.south),
        3 => @intFromEnum(Side.west),
    };
}

pub fn signPostFacingFromYaw(yaw: f32) u4 {
    const sixteenths: f32 = (yaw + 180.0) * 16.0 / 360.0;
    const stepped: i64 = @intFromFloat(@floor(@as(f64, sixteenths) + 0.5));
    return @intCast(stepped & 15);
}

pub const door_open_bit: u4 = 4;
pub const door_top_bit: u4 = 8;
pub const door_thickness: f32 = 3.0 / 16.0;
const door_bottom_tile: u8 = 97;
const door_tile_row: u8 = 16;

pub fn doorState(metadata: u4) u2 {
    return @truncate(if (metadata & door_open_bit == 0) metadata -% 1 else metadata);
}

pub fn doorIsTop(metadata: u4) bool {
    return metadata & door_top_bit != 0;
}

pub fn doorIsOpen(metadata: u4) bool {
    return metadata & door_open_bit != 0;
}

pub fn doorBounds(metadata: u4) Bounds {
    return switch (doorState(metadata)) {
        0 => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, door_thickness } },
        1 => .{ .min = .{ 1 - door_thickness, 0, 0 }, .max = .{ 1, 1, 1 } },
        2 => .{ .min = .{ 0, 0, 1 - door_thickness }, .max = .{ 1, 1, 1 } },
        3 => .{ .min = .{ 0, 0, 0 }, .max = .{ door_thickness, 1, 1 } },
    };
}

pub const DoorFace = struct { tile: u8, mirrored: bool };

pub fn doorFaceTile(id: Block, side: Side, metadata: u4) DoorFace {
    const bottom: u8 = if (id == .door_iron) door_bottom_tile + 1 else door_bottom_tile;
    if (side == .down or side == .up) return .{ .tile = bottom, .mirrored = false };

    const state: u8 = doorState(metadata);
    const index: u8 = @intFromEnum(side);
    if ((state == 0 or state == 2) != (index <= @intFromEnum(Side.south))) {
        return .{ .tile = bottom, .mirrored = false };
    }

    const opened: u8 = if (doorIsOpen(metadata)) 1 else 0;
    const turned = state / 2 + ((index & 1) ^ state) + opened;
    return .{
        .tile = if (doorIsTop(metadata)) bottom - door_tile_row else bottom,
        .mirrored = turned & 1 != 0,
    };
}

pub fn doorFacingFromYaw(yaw: f32) u2 {
    const quarter = @floor((@mod(yaw, 360.0) + 180.0) * 4.0 / 360.0 - 0.5);
    return @intCast(@mod(@as(i32, @intFromFloat(quarter)), 4));
}

pub fn doorHingeStep(facing: u2) [2]i32 {
    return switch (facing) {
        0 => .{ 0, 1 },
        1 => .{ -1, 0 },
        2 => .{ 0, -1 },
        3 => .{ 1, 0 },
    };
}

pub const trapdoor_open_bit: u4 = 4;
pub const trapdoor_thickness: f32 = 3.0 / 16.0;
const trapdoor_tile: u8 = 84;

const trapdoor_item_boxes = [1]Bounds{.{
    .min = .{ 0, 0.5 - trapdoor_thickness / 2.0, 0 },
    .max = .{ 1, 0.5 + trapdoor_thickness / 2.0, 1 },
}};

pub fn trapdoorIsOpen(metadata: u4) bool {
    return metadata & trapdoor_open_bit != 0;
}

pub fn trapdoorBounds(metadata: u4) Bounds {
    if (!trapdoorIsOpen(metadata)) {
        return .{ .min = .{ 0, 0, 0 }, .max = .{ 1, trapdoor_thickness, 1 } };
    }
    return switch (@as(u2, @truncate(metadata))) {
        0 => .{ .min = .{ 0, 0, 1 - trapdoor_thickness }, .max = .{ 1, 1, 1 } },
        1 => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, trapdoor_thickness } },
        2 => .{ .min = .{ 1 - trapdoor_thickness, 0, 0 }, .max = .{ 1, 1, 1 } },
        3 => .{ .min = .{ 0, 0, 0 }, .max = .{ trapdoor_thickness, 1, 1 } },
    };
}

pub fn trapdoorSupportStep(metadata: u4) [3]i32 {
    return switch (@as(u2, @truncate(metadata))) {
        0 => .{ 0, 0, 1 },
        1 => .{ 0, 0, -1 },
        2 => .{ 1, 0, 0 },
        3 => .{ -1, 0, 0 },
    };
}

pub fn trapdoorFacingFromFace(face: Side) ?u4 {
    return switch (face) {
        .north => 0,
        .south => 1,
        .west => 2,
        .east => 3,
        .up, .down => null,
    };
}

const stairs_item_boxes = [2]Bounds{
    .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0.5 } },
    .{ .min = .{ 0, 0, 0.5 }, .max = .{ 1, 0.5, 1 } },
};

pub fn stairsBoxes(metadata: u4) [2]Bounds {
    return switch (@as(u2, @truncate(metadata))) {
        0 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 0.5, 0.5, 1 } },
            .{ .min = .{ 0.5, 0, 0 }, .max = .{ 1, 1, 1 } },
        },
        1 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 0.5, 1, 1 } },
            .{ .min = .{ 0.5, 0, 0 }, .max = .{ 1, 0.5, 1 } },
        },
        2 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 0.5 } },
            .{ .min = .{ 0, 0, 0.5 }, .max = .{ 1, 1, 1 } },
        },
        3 => .{
            .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0.5 } },
            .{ .min = .{ 0, 0, 0.5 }, .max = .{ 1, 0.5, 1 } },
        },
    };
}

pub fn stairsFacingFromYaw(yaw: f32) u4 {
    const quarter = @floor(@mod(yaw, 360.0) * 4.0 / 360.0 + 0.5);
    return switch (@as(u2, @intFromFloat(@mod(quarter, 4.0)))) {
        0 => 2,
        1 => 1,
        2 => 3,
        3 => 0,
    };
}

const fence_item_boxes = [4]Bounds{
    .{ .min = .{ 0.5 - 2.0 / 16.0, 0.0, 0.0 }, .max = .{ 0.5 + 2.0 / 16.0, 1.0, 4.0 / 16.0 } },
    .{ .min = .{ 0.5 - 2.0 / 16.0, 0.0, 1.0 - 4.0 / 16.0 }, .max = .{ 0.5 + 2.0 / 16.0, 1.0, 1.0 } },
    .{ .min = .{ 0.5 - 1.0 / 16.0, 1.0 - 3.0 / 16.0, -2.0 / 16.0 }, .max = .{ 0.5 + 1.0 / 16.0, 1.0 - 1.0 / 16.0, 1.0 + 2.0 / 16.0 } },
    .{ .min = .{ 0.5 - 1.0 / 16.0, 0.5 - 3.0 / 16.0, -2.0 / 16.0 }, .max = .{ 0.5 + 1.0 / 16.0, 0.5 - 1.0 / 16.0, 1.0 + 2.0 / 16.0 } },
};

const slab_item_boxes = [1]Bounds{.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } }};

pub const cake_margin: f32 = 1.0 / 16.0;
pub const cake_height: f32 = 0.5;
pub const cake_slices = 6;

pub fn cakeEaten(metadata: u4) f32 {
    return @as(f32, @floatFromInt(1 + @as(u8, metadata) * 2)) / 16.0;
}

pub fn cakeBounds(metadata: u4) Bounds {
    return .{
        .min = .{ cakeEaten(metadata), 0, cake_margin },
        .max = .{ 1 - cake_margin, cake_height, 1 - cake_margin },
    };
}

pub fn cakeCollisionBounds(metadata: u4) Bounds {
    var bounds = cakeBounds(metadata);
    bounds.max[1] -= cake_margin;
    return bounds;
}

const cake_item_boxes = [1]Bounds{.{
    .min = .{ cake_margin, 0, cake_margin },
    .max = .{ 1 - cake_margin, cake_height, 1 - cake_margin },
}};

pub const bed_facing_mask: u4 = 3;
pub const bed_occupied_bit: u4 = 4;
pub const bed_pillow_bit: u4 = 8;

pub const bed_height: f32 = 9.0 / 16.0;
pub const bed_leg_height: f32 = 3.0 / 16.0;
const bed_bounds: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, bed_height, 1 } };

pub const sign_particle_tile: u8 = 4;
const sign_post_bounds: Bounds = .{ .min = .{ 0.25, 0, 0.25 }, .max = .{ 0.75, 1, 0.75 } };
const wall_sign_low: f32 = 9.0 / 32.0;
const wall_sign_high: f32 = 25.0 / 32.0;
const wall_sign_depth: f32 = 2.0 / 16.0;

pub fn wallSignBounds(metadata: u4) Bounds {
    return switch (metadata) {
        2 => .{ .min = .{ 0, wall_sign_low, 1.0 - wall_sign_depth }, .max = .{ 1, wall_sign_high, 1 } },
        3 => .{ .min = .{ 0, wall_sign_low, 0 }, .max = .{ 1, wall_sign_high, wall_sign_depth } },
        4 => .{ .min = .{ 1.0 - wall_sign_depth, wall_sign_low, 0 }, .max = .{ 1, wall_sign_high, 1 } },
        5 => .{ .min = .{ 0, wall_sign_low, 0 }, .max = .{ wall_sign_depth, wall_sign_high, 1 } },
        else => .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } },
    };
}
const bed_tile: u8 = 134;

pub fn bedFacing(metadata: u4) u2 {
    return @truncate(metadata & bed_facing_mask);
}

pub fn bedIsPillow(metadata: u4) bool {
    return metadata & bed_pillow_bit != 0;
}

pub fn bedIsOccupied(metadata: u4) bool {
    return metadata & bed_occupied_bit != 0;
}

pub fn bedOccupied(metadata: u4, occupied: bool) u4 {
    return if (occupied) metadata | bed_occupied_bit else metadata & ~bed_occupied_bit;
}

pub fn bedStep(facing: u2) [2]i32 {
    return switch (facing) {
        0 => .{ 0, 1 },
        1 => .{ -1, 0 },
        2 => .{ 0, -1 },
        3 => .{ 1, 0 },
    };
}

pub fn bedFacingFromYaw(yaw: f32) u2 {
    const quarters = yaw * 4.0 / 360.0 + 0.5;
    const floored: i32 = @intFromFloat(@floor(quarters));
    return @truncate(@as(u32, @bitCast(floored)) & 3);
}

const bed_side_lookup = [4][6]u8{
    .{ 1, 0, 3, 2, 5, 4 },
    .{ 1, 0, 5, 4, 2, 3 },
    .{ 1, 0, 2, 3, 4, 5 },
    .{ 1, 0, 4, 5, 3, 2 },
};

pub fn bedTile(side: Side, metadata: u4) u8 {
    if (side == .down) return 4;

    const turned = bed_side_lookup[bedFacing(metadata)][@intFromEnum(side)];
    if (bedIsPillow(metadata)) {
        if (turned == 2) return bed_tile + 2 + 16;
        if (turned == 5 or turned == 4) return bed_tile + 1 + 16;
        return bed_tile + 1;
    }
    if (turned == 3) return bed_tile - 1 + 16;
    if (turned == 5 or turned == 4) return bed_tile + 16;
    return bed_tile;
}

pub fn bedTextures(metadata: u4) FaceTextures {
    var textures: FaceTextures = undefined;
    for (std.enums.values(Side)) |side| textures.set(side, bedTile(side, metadata));
    return textures;
}

const cake_tile: u8 = 121;

pub fn cakeTextures(metadata: u4) FaceTextures {
    var textures = FaceTextures.init(.{
        .down = cake_tile + 3,
        .up = cake_tile,
        .north = cake_tile + 1,
        .south = cake_tile + 1,
        .west = cake_tile + 1,
        .east = cake_tile + 1,
    });
    if (metadata > 0) textures.set(.west, cake_tile + 2);
    return textures;
}

pub const slab_stone: u4 = 0;
pub const slab_sandstone: u4 = 1;
pub const slab_wood: u4 = 2;
pub const slab_cobblestone: u4 = 3;

pub fn slabTextures(metadata: u4) FaceTextures {
    return switch (metadata) {
        slab_sandstone => topAndSide(176, 208, 192),
        slab_wood => uniform(4),
        slab_cobblestone => uniform(16),
        else => topAndSide(6, 6, 5),
    };
}

pub const piston_item_metadata: u4 = 1;
pub const piston_top_sticky_tile: u8 = 106;
pub const piston_top_tile: u8 = 107;
pub const piston_side_tile: u8 = 108;
pub const piston_back_tile: u8 = 109;
pub const piston_inner_tile: u8 = 110;

fn oppositeSide(side: Side) Side {
    return switch (side) {
        .down => .up,
        .up => .down,
        .north => .south,
        .south => .north,
        .west => .east,
        .east => .west,
    };
}

pub const TileTurn = struct { turns: u2 = 0, mirrored: bool = false };

pub fn pistonSideTurn(facing: Side, face: Side) TileTurn {
    return switch (facing) {
        .up => .{},
        .down => switch (face) {
            .down, .up => .{},
            else => .{ .turns = 2 },
        },
        .north => switch (face) {
            .down, .up, .north, .south => .{},
            .west => .{ .turns = 3 },
            .east => .{ .turns = 3, .mirrored = true },
        },
        .south => switch (face) {
            .down, .up => .{ .turns = 2 },
            .north, .south => .{},
            .west => .{ .turns = 1 },
            .east => .{ .turns = 1, .mirrored = true },
        },
        .west => switch (face) {
            .down, .up, .south => .{ .turns = 3 },
            .north => .{ .turns = 3, .mirrored = true },
            .west, .east => .{},
        },
        .east => switch (face) {
            .down, .up, .south => .{ .turns = 1 },
            .north => .{ .turns = 1, .mirrored = true },
            .west, .east => .{},
        },
    };
}

pub fn pistonBaseTextures(id: Block, metadata: u4) FaceTextures {
    const facing = pistonFacing(metadata);
    var textures = FaceTextures.initFill(piston_side_tile);
    textures.set(oppositeSide(facing), piston_back_tile);
    textures.set(facing, if (pistonExtended(metadata))
        piston_inner_tile
    else if (id == .piston_sticky)
        piston_top_sticky_tile
    else
        piston_top_tile);
    return textures;
}

pub fn pistonHeadTextures(metadata: u4) FaceTextures {
    const facing = pistonFacing(metadata);
    var textures = FaceTextures.initFill(piston_side_tile);
    textures.set(oppositeSide(facing), piston_top_tile);
    textures.set(facing, if (metadata & piston_flag != 0) piston_top_sticky_tile else piston_top_tile);
    return textures;
}

const dispenser_side_tile: u8 = 45;
const dispenser_top_tile: u8 = 62;
const dispenser_front_tile: u8 = 46;
pub const dispenser_default_facing: u4 = @intFromEnum(Side.south);

pub const rail_straight_tile: u8 = 128;
pub const rail_curved_tile: u8 = 112;
pub const rail_powered_off_tile: u8 = 163;
pub const rail_powered_on_tile: u8 = 179;
pub const rail_detector_tile: u8 = 195;
pub const rail_flag_bit: u4 = 8;
pub const rail_shape_mask: u4 = 7;

pub fn isRail(id: Block) bool {
    return id == .rail or id == .rail_powered or id == .rail_detector;
}

pub fn railIsFlagged(id: Block) bool {
    return id == .rail_powered or id == .rail_detector;
}

pub fn railShape(id: Block, metadata: u4) u4 {
    return if (railIsFlagged(id)) metadata & rail_shape_mask else metadata;
}

pub fn railIsSloped(shape: u4) bool {
    return shape >= 2 and shape <= 5;
}

pub fn railTile(id: Block, metadata: u4) u8 {
    return switch (id) {
        .rail_powered => if (metadata & rail_flag_bit == 0) rail_powered_off_tile else rail_powered_on_tile,
        .rail_detector => rail_detector_tile,
        else => if (metadata >= 6) rail_curved_tile else rail_straight_tile,
    };
}

const rail_flat_height: f32 = 2.0 / 16.0;
const rail_slope_height: f32 = 10.0 / 16.0;

fn railBounds(metadata: u4) Bounds {
    const tall = metadata >= 2 and metadata <= 5;
    return .{
        .min = .{ 0, 0, 0 },
        .max = .{ 1, if (tall) rail_slope_height else rail_flat_height, 1 },
    };
}

pub fn dispenserStep(metadata: u4) [2]i32 {
    return switch (metadata) {
        @intFromEnum(Side.south) => .{ 0, 1 },
        @intFromEnum(Side.north) => .{ 0, -1 },
        @intFromEnum(Side.east) => .{ 1, 0 },
        else => .{ -1, 0 },
    };
}

pub fn dispenserFacingFromYaw(yaw: f32) u4 {
    return furnaceFacingFromYaw(yaw);
}

pub fn dispenserTextures(metadata: u4) FaceTextures {
    var textures = FaceTextures.initFill(dispenser_side_tile);
    textures.set(.down, dispenser_top_tile);
    textures.set(.up, dispenser_top_tile);
    if (metadata >= @intFromEnum(Side.north) and metadata <= @intFromEnum(Side.east)) {
        textures.set(@enumFromInt(metadata), dispenser_front_tile);
    }
    return textures;
}

pub fn furnaceTextures(id: Block, metadata: u4) FaceTextures {
    var textures = FaceTextures.initFill(furnace_side_tile);
    textures.set(.down, furnace_top_tile);
    textures.set(.up, furnace_top_tile);
    textures.set(
        furnaceFacing(metadata),
        if (id == .burning_furnace) furnace_front_lit_tile else furnace_front_tile,
    );
    return textures;
}

const pumpkin_top_tile: u8 = 102;
const pumpkin_side_tile: u8 = 118;
const pumpkin_face_tile: u8 = 119;
const pumpkin_face_lit_tile: u8 = 120;
pub const pumpkin_default_facing: u4 = 0;

pub fn pumpkinFacing(metadata: u4) ?Side {
    return switch (metadata) {
        0 => .south,
        1 => .west,
        2 => .north,
        3 => .east,
        else => null,
    };
}

pub fn pumpkinFacingFromYaw(yaw: f32) u4 {
    const quarter = @floor(@mod(yaw, 360.0) * 4.0 / 360.0 + 2.5);
    return @intFromFloat(@mod(quarter, 4.0));
}

pub fn pumpkinTextures(id: Block, metadata: u4) FaceTextures {
    var textures = FaceTextures.initFill(pumpkin_side_tile);
    textures.set(.down, pumpkin_top_tile);
    textures.set(.up, pumpkin_top_tile);
    if (pumpkinFacing(metadata)) |facing| {
        textures.set(facing, if (id == .jack_o_lantern) pumpkin_face_lit_tile else pumpkin_face_tile);
    }
    return textures;
}

const chest_top_tile: u8 = 25;
const chest_side_tile: u8 = 26;
const chest_front_tile: u8 = 27;
const chest_large_front_tile: u8 = 42;
const chest_large_back_tile: u8 = 58;

pub const ChestRing = struct {
    north: Block = .air,
    south: Block = .air,
    west: Block = .air,
    east: Block = .air,
    north_west: Block = .air,
    north_east: Block = .air,
    south_west: Block = .air,
    south_east: Block = .air,
};

fn chestItemTextures() FaceTextures {
    var textures = FaceTextures.initFill(chest_side_tile);
    textures.set(.down, chest_top_tile);
    textures.set(.up, chest_top_tile);
    textures.set(.south, chest_front_tile);
    return textures;
}

fn chestTile(ring: ChestRing, side: Side) u8 {
    if (side == .up or side == .down) return chest_top_tile;

    const paired_north = ring.north == .chest;
    const paired_south = ring.south == .chest;
    const paired_west = ring.west == .chest;
    const paired_east = ring.east == .chest;

    if (!paired_north and !paired_south) {
        if (!paired_west and !paired_east) {
            var front: Side = .south;
            if (ring.north.isOpaqueCube() and !ring.south.isOpaqueCube()) front = .south;
            if (ring.south.isOpaqueCube() and !ring.north.isOpaqueCube()) front = .north;
            if (ring.west.isOpaqueCube() and !ring.east.isOpaqueCube()) front = .east;
            if (ring.east.isOpaqueCube() and !ring.west.isOpaqueCube()) front = .west;
            return if (side == front) chest_front_tile else chest_side_tile;
        }

        if (side != .west and side != .east) {
            const behind_north = if (paired_west) ring.north_west else ring.north_east;
            const behind_south = if (paired_west) ring.south_west else ring.south_east;
            var half: u8 = if (paired_west) 1 else 0;
            if (side == .south) half = 1 - half;

            var front: Side = .south;
            if ((ring.north.isOpaqueCube() or behind_north.isOpaqueCube()) and
                !ring.south.isOpaqueCube() and !behind_south.isOpaqueCube()) front = .south;
            if ((ring.south.isOpaqueCube() or behind_south.isOpaqueCube()) and
                !ring.north.isOpaqueCube() and !behind_north.isOpaqueCube()) front = .north;

            const base = if (side == front) chest_large_front_tile else chest_large_back_tile;
            return base - half;
        }

        return chest_side_tile;
    }

    if (side != .north and side != .south) {
        const behind_west = if (paired_north) ring.north_west else ring.south_west;
        const behind_east = if (paired_north) ring.north_east else ring.south_east;
        var half: u8 = if (paired_north) 1 else 0;
        if (side == .west) half = 1 - half;

        var front: Side = .east;
        if ((ring.west.isOpaqueCube() or behind_west.isOpaqueCube()) and
            !ring.east.isOpaqueCube() and !behind_east.isOpaqueCube()) front = .east;
        if ((ring.east.isOpaqueCube() or behind_east.isOpaqueCube()) and
            !ring.west.isOpaqueCube() and !behind_west.isOpaqueCube()) front = .west;

        const base = if (side == front) chest_large_front_tile else chest_large_back_tile;
        return base - half;
    }

    return chest_side_tile;
}

pub fn chestTextures(ring: ChestRing) FaceTextures {
    var textures = FaceTextures.initFill(chest_side_tile);
    var it = textures.iterator();
    while (it.next()) |entry| entry.value.* = chestTile(ring, entry.key);
    return textures;
}

pub const wire_particle_tint: [3]u8 = .{ 128, 0, 0 };
pub const wire_cross_tile: u8 = 164;
pub const wire_line_tile: u8 = 165;
pub const lever_tile: u8 = 96;
pub const cobblestone_tile: u8 = 16;
pub const torch_redstone_off_tile: u8 = 115;
pub const torch_redstone_on_tile: u8 = 99;
const repeater_top_off_tile: u8 = 131;
const repeater_top_on_tile: u8 = 147;
const repeater_side_tile: u8 = 5;

pub const power_bit: u4 = 8;
pub const facing_mask: u4 = 7;

pub fn isPowered(metadata: u4) bool {
    return metadata & power_bit != 0;
}

const wire_bounds: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1.0 / 16.0, 1 } };

pub const repeater_height: f32 = 2.0 / 16.0;
const repeater_bounds: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, repeater_height, 1 } };

pub fn repeaterTextures(id: Block) FaceTextures {
    var textures = FaceTextures.initFill(repeater_side_tile);
    const on = id == .repeater_on;
    textures.set(.down, if (on) torch_redstone_on_tile else torch_redstone_off_tile);
    textures.set(.up, if (on) repeater_top_on_tile else repeater_top_off_tile);
    return textures;
}

pub fn repeaterFacing(metadata: u4) u2 {
    return @truncate(metadata & 3);
}

pub fn repeaterDelay(metadata: u4) u2 {
    return @truncate((metadata & 12) >> 2);
}

pub fn repeaterTickRate(metadata: u4) u32 {
    return (@as(u32, repeaterDelay(metadata)) + 1) * 2;
}

pub fn repeaterFacingFromYaw(yaw: f32) u4 {
    const quarter = @floor(@as(f64, yaw) * 4.0 / 360.0 + 0.5);
    const wrapped: u2 = @intFromFloat(@mod(quarter, 4.0));
    return (@as(u4, wrapped) + 2) % 4;
}

pub const repeater_torch_offsets: [4]f32 = .{ -1.0 / 16.0, 1.0 / 16.0, 3.0 / 16.0, 5.0 / 16.0 };

pub fn leverBounds(metadata: u4) Bounds {
    const wall: f32 = 3.0 / 16.0;
    return switch (metadata & facing_mask) {
        1 => .{ .min = .{ 0.0, 0.2, 0.5 - wall }, .max = .{ wall * 2.0, 0.8, 0.5 + wall } },
        2 => .{ .min = .{ 1.0 - wall * 2.0, 0.2, 0.5 - wall }, .max = .{ 1.0, 0.8, 0.5 + wall } },
        3 => .{ .min = .{ 0.5 - wall, 0.2, 0.0 }, .max = .{ 0.5 + wall, 0.8, wall * 2.0 } },
        4 => .{ .min = .{ 0.5 - wall, 0.2, 1.0 - wall * 2.0 }, .max = .{ 0.5 + wall, 0.8, 1.0 } },
        else => .{ .min = .{ 0.25, 0.0, 0.25 }, .max = .{ 0.75, 0.6, 0.75 } },
    };
}

pub fn leverBaseBounds(metadata: u4) Bounds {
    const half: f32 = 0.25;
    const side: f32 = 3.0 / 16.0;
    const depth: f32 = 3.0 / 16.0;
    return switch (metadata & facing_mask) {
        1 => .{ .min = .{ 0.0, 0.5 - half, 0.5 - side }, .max = .{ depth, 0.5 + half, 0.5 + side } },
        2 => .{ .min = .{ 1.0 - depth, 0.5 - half, 0.5 - side }, .max = .{ 1.0, 0.5 + half, 0.5 + side } },
        3 => .{ .min = .{ 0.5 - side, 0.5 - half, 0.0 }, .max = .{ 0.5 + side, 0.5 + half, depth } },
        4 => .{ .min = .{ 0.5 - side, 0.5 - half, 1.0 - depth }, .max = .{ 0.5 + side, 0.5 + half, 1.0 } },
        6 => .{ .min = .{ 0.5 - half, 0.0, 0.5 - side }, .max = .{ 0.5 + half, depth, 0.5 + side } },
        else => .{ .min = .{ 0.5 - side, 0.0, 0.5 - half }, .max = .{ 0.5 + side, depth, 0.5 + half } },
    };
}

pub fn buttonBounds(metadata: u4) Bounds {
    const low: f32 = 6.0 / 16.0;
    const high: f32 = 10.0 / 16.0;
    const half: f32 = 3.0 / 16.0;
    const depth: f32 = if (isPowered(metadata)) 1.0 / 16.0 else 2.0 / 16.0;
    return switch (metadata & facing_mask) {
        1 => .{ .min = .{ 0.0, low, 0.5 - half }, .max = .{ depth, high, 0.5 + half } },
        2 => .{ .min = .{ 1.0 - depth, low, 0.5 - half }, .max = .{ 1.0, high, 0.5 + half } },
        3 => .{ .min = .{ 0.5 - half, low, 0.0 }, .max = .{ 0.5 + half, high, depth } },
        else => .{ .min = .{ 0.5 - half, low, 1.0 - depth }, .max = .{ 0.5 + half, high, 1.0 } },
    };
}

const button_item_boxes = [1]Bounds{.{
    .min = .{ 0.5 - 3.0 / 16.0, 0.5 - 2.0 / 16.0, 0.5 - 2.0 / 16.0 },
    .max = .{ 0.5 + 3.0 / 16.0, 0.5 + 2.0 / 16.0, 0.5 + 2.0 / 16.0 },
}};

const plate_item_boxes = [1]Bounds{.{
    .min = .{ 0.0, 0.5 - 2.0 / 16.0, 0.0 },
    .max = .{ 1.0, 0.5 + 2.0 / 16.0, 1.0 },
}};

pub fn plateBounds(metadata: u4) Bounds {
    const margin: f32 = 1.0 / 16.0;
    const height: f32 = if (metadata == 1) 1.0 / 32.0 else 1.0 / 16.0;
    return .{
        .min = .{ margin, 0.0, margin },
        .max = .{ 1.0 - margin, height, 1.0 - margin },
    };
}

test "the furnace turns its face towards the side its metadata names" {
    const idle = furnaceTextures(.furnace, @intFromEnum(Side.west));
    try std.testing.expectEqual(@as(u8, 44), idle.get(.west));
    try std.testing.expectEqual(@as(u8, 45), idle.get(.south));
    try std.testing.expectEqual(@as(u8, 62), idle.get(.up));
    try std.testing.expectEqual(@as(u8, 62), idle.get(.down));

    const lit = furnaceTextures(.burning_furnace, @intFromEnum(Side.north));
    try std.testing.expectEqual(@as(u8, 61), lit.get(.north));
    try std.testing.expectEqual(@as(u8, 45), lit.get(.east));
}

test "a lone chest keeps its latch on the south face until a wall turns it" {
    const open = chestTextures(.{});
    try std.testing.expectEqual(@as(u8, 25), open.get(.up));
    try std.testing.expectEqual(@as(u8, 25), open.get(.down));
    try std.testing.expectEqual(@as(u8, 27), open.get(.south));
    try std.testing.expectEqual(@as(u8, 26), open.get(.north));
    try std.testing.expectEqual(@as(u8, 26), open.get(.west));
    try std.testing.expectEqual(@as(u8, 26), open.get(.east));

    const walled_north = chestTextures(.{ .north = .stone });
    try std.testing.expectEqual(@as(u8, 27), walled_north.get(.south));

    const walled_south = chestTextures(.{ .south = .stone });
    try std.testing.expectEqual(@as(u8, 27), walled_south.get(.north));
    try std.testing.expectEqual(@as(u8, 26), walled_south.get(.south));

    const walled_east = chestTextures(.{ .east = .stone });
    try std.testing.expectEqual(@as(u8, 27), walled_east.get(.west));

    const boxed_in = chestTextures(.{ .north = .stone, .south = .stone });
    try std.testing.expectEqual(@as(u8, 27), boxed_in.get(.south));
}

test "a double chest splits its latch across the pair" {
    const west_half = chestTextures(.{ .east = .chest });
    const east_half = chestTextures(.{ .west = .chest });

    try std.testing.expectEqual(@as(u8, 41), west_half.get(.south));
    try std.testing.expectEqual(@as(u8, 42), east_half.get(.south));
    try std.testing.expectEqual(@as(u8, 58), west_half.get(.north));
    try std.testing.expectEqual(@as(u8, 57), east_half.get(.north));
    try std.testing.expectEqual(@as(u8, 26), west_half.get(.west));
    try std.testing.expectEqual(@as(u8, 26), east_half.get(.east));
    try std.testing.expectEqual(@as(u8, 25), west_half.get(.up));

    const north_half = chestTextures(.{ .south = .chest });
    const south_half = chestTextures(.{ .north = .chest });
    try std.testing.expectEqual(@as(u8, 42), north_half.get(.east));
    try std.testing.expectEqual(@as(u8, 41), south_half.get(.east));
    try std.testing.expectEqual(@as(u8, 57), north_half.get(.west));
    try std.testing.expectEqual(@as(u8, 58), south_half.get(.west));
    try std.testing.expectEqual(@as(u8, 26), north_half.get(.north));
}

test "a wall behind a double chest turns the pair around together" {
    const west_half = chestTextures(.{ .east = .chest, .north = .stone, .north_east = .stone });
    const east_half = chestTextures(.{ .west = .chest, .north = .stone, .north_west = .stone });
    try std.testing.expectEqual(@as(u8, 41), west_half.get(.south));
    try std.testing.expectEqual(@as(u8, 42), east_half.get(.south));

    const flipped_west = chestTextures(.{ .east = .chest, .south = .stone, .south_east = .stone });
    const flipped_east = chestTextures(.{ .west = .chest, .south = .stone, .south_west = .stone });
    try std.testing.expectEqual(@as(u8, 42), flipped_west.get(.north));
    try std.testing.expectEqual(@as(u8, 41), flipped_east.get(.north));
    try std.testing.expectEqual(@as(u8, 57), flipped_west.get(.south));
}

test "the chest item icon is the plain south-facing chest" {
    const textures = Block.chest.faceTextures();
    try std.testing.expectEqual(@as(u8, 25), textures.get(.up));
    try std.testing.expectEqual(@as(u8, 25), textures.get(.down));
    try std.testing.expectEqual(@as(u8, 27), textures.get(.south));
    try std.testing.expectEqual(@as(u8, 26), textures.get(.north));
    try std.testing.expectEqual(@as(f32, 2.5), Block.chest.hardness());
    try std.testing.expectEqualStrings("Chest", Block.chest.displayName(0));
}

test "a furnace faces the player who placed it, whichever way they were turned" {
    try std.testing.expectEqual(@intFromEnum(Side.north), furnaceFacingFromYaw(0));
    try std.testing.expectEqual(@intFromEnum(Side.east), furnaceFacingFromYaw(90));
    try std.testing.expectEqual(@intFromEnum(Side.south), furnaceFacingFromYaw(180));
    try std.testing.expectEqual(@intFromEnum(Side.west), furnaceFacingFromYaw(270));
    try std.testing.expectEqual(@intFromEnum(Side.west), furnaceFacingFromYaw(-90));
    try std.testing.expectEqual(@intFromEnum(Side.north), furnaceFacingFromYaw(-720));
    try std.testing.expectEqual(@intFromEnum(Side.east), furnaceFacingFromYaw(3690));
}

test "a furnace with no facing yet still shows its front, as GuiFurnace's item does" {
    try std.testing.expectEqual(@as(u8, 44), Block.furnace.faceTextures().get(.south));
    try std.testing.expectEqual(@as(u8, 61), Block.burning_furnace.faceTextures().get(.south));
    try std.testing.expectEqual(@as(u8, 45), Block.furnace.faceTextures().get(.north));
}

test "every pumpkin wears a carved face on the side its metadata names" {
    const carved = pumpkinTextures(.pumpkin, 2);
    try std.testing.expectEqual(@as(u8, 119), carved.get(.north));
    try std.testing.expectEqual(@as(u8, 118), carved.get(.south));
    try std.testing.expectEqual(@as(u8, 102), carved.get(.up));
    try std.testing.expectEqual(@as(u8, 102), carved.get(.down));

    const lit = pumpkinTextures(.jack_o_lantern, 3);
    try std.testing.expectEqual(@as(u8, 120), lit.get(.east));
    try std.testing.expectEqual(@as(u8, 118), lit.get(.west));

    const texs = Block.pumpkin.faceTextures();
    try std.testing.expectEqual(@as(u8, 119), texs.get(.south));
    try std.testing.expectEqual(@as(u8, 118), texs.get(.north));
    try std.testing.expectEqual(@as(u8, 120), Block.jack_o_lantern.faceTextures().get(.south));

    const uncarved = pumpkinTextures(.pumpkin, 7);
    try std.testing.expectEqual(@as(u8, 118), uncarved.get(.north));
    try std.testing.expectEqual(@as(u8, 118), uncarved.get(.south));
    try std.testing.expectEqual(@as(u8, 118), uncarved.get(.west));
    try std.testing.expectEqual(@as(u8, 118), uncarved.get(.east));
}

test "a pumpkin turns its face towards the player who set it down" {
    try std.testing.expectEqual(@as(u4, 2), pumpkinFacingFromYaw(0));
    try std.testing.expectEqual(@as(u4, 3), pumpkinFacingFromYaw(90));
    try std.testing.expectEqual(@as(u4, 0), pumpkinFacingFromYaw(180));
    try std.testing.expectEqual(@as(u4, 1), pumpkinFacingFromYaw(270));
    try std.testing.expectEqual(Side.north, pumpkinFacing(pumpkinFacingFromYaw(0)).?);
    try std.testing.expectEqual(Side.south, pumpkinFacing(pumpkinFacingFromYaw(-180)).?);
}

test "both furnace states drop the idle block" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .furnace }, Block.furnace.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .furnace }, Block.burning_furnace.drop(3, &rand).?.id);
}

test "leaf tiles follow the graphics level, and pine has its own" {
    try std.testing.expectEqual(@as(u8, 52), leafTile(0, true));
    try std.testing.expectEqual(@as(u8, 53), leafTile(0, false));
    try std.testing.expectEqual(@as(u8, 132), leafTile(1, true));
    try std.testing.expectEqual(@as(u8, 133), leafTile(1, false));
    try std.testing.expectEqual(@as(u8, 52), leafTile(2, true));
    try std.testing.expectEqual(@as(u8, 52), leafTile(8, true));
}

test "leaves are not an opaque cube, so they never cull a neighbour" {
    try std.testing.expect(!Block.leaves.isOpaqueCube());
    try std.testing.expect(Block.leaves.isOpaque());
    try std.testing.expect(Block.stone.shouldRenderFace(.leaves, .up, true));
    try std.testing.expect(Block.stone.shouldRenderFace(.leaves, .up, false));
}

test "only fast graphics culls the face between two leaf blocks" {
    try std.testing.expect(Block.leaves.shouldRenderFace(.leaves, .up, true));
    try std.testing.expect(!Block.leaves.shouldRenderFace(.leaves, .up, false));
    try std.testing.expect(!Block.leaves.shouldRenderFace(.stone, .up, true));
}

test "a material decides whether its blocks are opaque and liquid" {
    try std.testing.expect(!Material.air.blocksGrass());
    try std.testing.expect(!Material.plants.blocksGrass());
    try std.testing.expect(!Material.snow.blocksGrass());
    try std.testing.expect(Material.rock.blocksGrass());
    try std.testing.expect(Material.water.blocksGrass());
    try std.testing.expect(Material.water.isLiquid());
    try std.testing.expect(!Material.rock.isLiquid());
}

test "shape carries the partial height instead of a separate lookup" {
    try std.testing.expectEqual(Shape.cube, Block.stone.shape());
    try std.testing.expectEqual(Shape.cross, Block.tall_grass.shape());
    try std.testing.expectEqual(@as(f32, 0.125), Block.snow_layer.shape().heightScale());
    try std.testing.expectEqual(@as(f32, 1.0), Block.stone.heightScale());
}

fn digTicks(id: Block, held: ?Stack) f32 {
    return 1.0 / id.strength(held, 1.0);
}

test "bare hands take hardness*30 ticks on a hand-harvestable block" {
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), digTicks(.dirt, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), digTicks(.log, null), 1.0e-4);
}

test "bare hands take hardness*100 on a block that needs a tool, and drop nothing" {
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), digTicks(.ore_diamond, null), 1.0e-4);
    try std.testing.expect(!Block.stone.harvestableWith(null));
    try std.testing.expect(!Block.ore_diamond.harvestableWith(null));
}

test "an effective tool divides the dig time by its material's efficiency" {
    const wood: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    const diamond: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 22.5), digTicks(.stone, wood), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.625), digTicks(.stone, diamond), 1.0e-4);
}

test "the wrong tool still harvests rock, only no faster than a hand" {
    const shovel: Stack = .{ .id = .{ .item = .shovel_iron }, .count = 1 };
    try std.testing.expect(!Block.stone.harvestableWith(shovel));
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, shovel), 1.0e-4);

    const axe: Stack = .{ .id = .{ .item = .axe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), digTicks(.log, axe), 1.0e-4);
}

test "an ore only drops for a pickaxe at or above its harvest level" {
    const wood: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    const stone: Stack = .{ .id = .{ .item = .pickaxe_stone }, .count = 1 };
    const iron: Stack = .{ .id = .{ .item = .pickaxe_iron }, .count = 1 };
    const diamond: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };

    try std.testing.expect(Block.stone.harvestableWith(wood));
    try std.testing.expect(Block.ore_coal.harvestableWith(wood));
    try std.testing.expect(!Block.ore_iron.harvestableWith(wood));
    try std.testing.expect(Block.ore_iron.harvestableWith(stone));
    try std.testing.expect(!Block.ore_diamond.harvestableWith(stone));
    try std.testing.expect(Block.ore_diamond.harvestableWith(iron));
    try std.testing.expect(!Block.obsidian.harvestableWith(iron));
    try std.testing.expect(Block.obsidian.harvestableWith(diamond));
}

test "swimming or airborne slows a tool down, but not a bare-handed dig" {
    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 28.125), 1.0 / Block.stone.strength(pickaxe, 0.2), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), 1.0 / Block.stone.strength(null, 0.2), 1.0e-4);
}

test "a gold pickaxe digs fastest but harvests least, matching its level of zero" {
    const gold: Stack = .{ .id = .{ .item = .pickaxe_gold }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 3.75), digTicks(.stone, gold), 1.0e-4);
    try std.testing.expect(!Block.ore_iron.harvestableWith(gold));
}

test "snow only drops for a shovel, which is the one thing a shovel harvests" {
    const shovel: Stack = .{ .id = .{ .item = .shovel_wood }, .count = 1 };
    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_diamond }, .count = 1 };
    try std.testing.expect(!Block.snow_layer.harvestableWith(null));
    try std.testing.expect(!Block.snow_block.harvestableWith(pickaxe));
    try std.testing.expect(Block.snow_layer.harvestableWith(shovel));
    try std.testing.expect(Block.snow_block.harvestableWith(shovel));
}

test "a sword digs everything at 1.5x, but not what it cannot harvest" {
    const sword: Stack = .{ .id = .{ .item = .sword_diamond }, .count = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), digTicks(.dirt, sword), 1.0e-4);
    try std.testing.expect(!Block.stone.harvestableWith(sword));
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), digTicks(.stone, sword), 1.0e-4);
}

test "bedrock is unbreakable" {
    try std.testing.expectEqual(@as(f32, 0.0), Block.bedrock.strength(null, 1.0));
}

test "a stack wears out after exactly its material's uses" {
    var pickaxe: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    for (0..59) |_| pickaxe.damage(1);
    try std.testing.expectEqual(@as(u8, 1), pickaxe.count);
    try std.testing.expectEqual(@as(u16, 59), pickaxe.meta);
    pickaxe.damage(1);
    try std.testing.expectEqual(@as(u8, 0), pickaxe.count);
    try std.testing.expectEqual(@as(u16, 0), pickaxe.meta);
}

test "an undamageable stack ignores wear, so block metadata survives" {
    var log: Stack = .{ .id = .{ .block = .log }, .count = 5, .meta = 2 };
    log.damage(3);
    try std.testing.expectEqual(@as(u16, 2), log.meta);
    try std.testing.expectEqual(@as(u8, 5), log.count);
}

test "only tools and armour stack alone" {
    try std.testing.expectEqual(@as(u8, 1), (Id{ .item = .pickaxe_iron }).maxStackSize());
    try std.testing.expectEqual(@as(u8, 1), (Id{ .item = .chestplate_diamond }).maxStackSize());
    try std.testing.expectEqual(@as(u8, 64), (Id{ .item = .ingot_iron }).maxStackSize());
    try std.testing.expectEqual(@as(u8, 64), (Id{ .block = .stone }).maxStackSize());
}

test "snow layers are thin and non-opaque, unlike regular blocks" {
    try std.testing.expectEqual(@as(f32, 0.125), Block.snow_layer.heightScale());
    try std.testing.expectEqual(@as(f32, 1.0), Block.stone.heightScale());
    try std.testing.expect(!Block.snow_layer.isOpaque());
}

test "grass has a distinct top, bottom and side texture" {
    const textures = Block.grass.faceTextures();
    try std.testing.expectEqual(@as(u8, 0), textures.get(.up));
    try std.testing.expectEqual(@as(u8, 2), textures.get(.down));
    try std.testing.expectEqual(@as(u8, 3), textures.get(.north));
    try std.testing.expectEqual(@as(u8, 3), textures.get(.east));
}

test "air and cross-shaped plants are the only non-opaque blocks" {
    try std.testing.expect(!Block.air.isOpaque());
    try std.testing.expect(!Block.tall_grass.isOpaque());
    try std.testing.expect(Block.stone.isOpaque());
    try std.testing.expect(Block.bedrock.isOpaque());
}

test "tall grass picks the fern tile only at metadata 2" {
    try std.testing.expectEqual(@as(u8, 39), Block.tall_grass.crossTile(1));
    try std.testing.expectEqual(@as(u8, 56), Block.tall_grass.crossTile(2));
}

test "log side texture varies by wood type metadata" {
    try std.testing.expectEqual(@as(u8, 20), logSideTile(0));
    try std.testing.expectEqual(@as(u8, 116), logSideTile(1));
    try std.testing.expectEqual(@as(u8, 117), logSideTile(2));
}

test "stone drops cobblestone, not itself" {
    var rand = JavaRandom.init(0);
    const dropped = Block.stone.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .block = .cobblestone }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
}

test "grass drops dirt" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .dirt }, Block.grass.drop(0, &rand).?.id);
}

test "ore blocks drop their raw item form" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .coal }, Block.ore_coal.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .diamond }, Block.ore_diamond.drop(0, &rand).?.id);
}

test "gold and iron ore self-drop, unlike coal/diamond/lapis/redstone" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .ore_gold }, Block.ore_gold.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .ore_iron }, Block.ore_iron.drop(0, &rand).?.id);
}

test "lapis ore drops 4-8 lapis dye" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = Block.ore_lapis.drop(0, &rand).?;
        try std.testing.expectEqual(Id{ .item = .dye }, dropped.id);
        try std.testing.expectEqual(item.dye_meta_lapis, dropped.meta);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 8);
    }
}

test "redstone ore drops 4-5 redstone" {
    var rand = JavaRandom.init(0);
    for (0..50) |_| {
        const dropped = Block.ore_redstone.drop(0, &rand).?;
        try std.testing.expectEqual(Id{ .item = .redstone }, dropped.id);
        try std.testing.expect(dropped.count >= 4 and dropped.count <= 5);
    }
}

test "log preserves its wood-type metadata when dropped" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(@as(u4, 1), Block.log.drop(1, &rand).?.meta);
}

test "gravel occasionally drops flint instead of itself" {
    var rand = JavaRandom.init(0);
    var saw_flint = false;
    var saw_gravel = false;
    for (0..200) |_| {
        const dropped = Block.gravel.drop(0, &rand).?;
        try std.testing.expectEqual(@as(u8, 1), dropped.count);
        if (dropped.id.eql(.{ .item = .flint })) saw_flint = true;
        if (dropped.id.eql(.{ .block = .gravel })) saw_gravel = true;
    }
    try std.testing.expect(saw_flint);
    try std.testing.expect(saw_gravel);
}

test "leaves rarely drop a sapling, preserving wood type in its metadata" {
    var rand = JavaRandom.init(0);
    var saw_sapling = false;
    var saw_nothing = false;
    for (0..200) |_| {
        if (Block.leaves.drop(1, &rand)) |dropped| {
            try std.testing.expectEqual(Id{ .block = .sapling }, dropped.id);
            try std.testing.expectEqual(@as(u4, 1), dropped.meta);
            saw_sapling = true;
        } else {
            saw_nothing = true;
        }
    }
    try std.testing.expect(saw_sapling);
    try std.testing.expect(saw_nothing);
}

test "leaves cut with shears come back whole, keeping their wood type" {
    const shears: Stack = .{ .id = .{ .item = .shears }, .count = 1 };

    const cut = Block.leaves.shearedDrop(0b1101, shears).?;
    try std.testing.expectEqual(Id{ .block = .leaves }, cut.id);
    try std.testing.expectEqual(@as(u16, 1), cut.meta);
    try std.testing.expectEqual(@as(u8, 1), cut.count);
    try std.testing.expectEqual(@as(u16, 2), Block.leaves.shearedDrop(2, shears).?.meta);

    try std.testing.expect(Block.leaves.shearedDrop(0, null) == null);
    try std.testing.expect(Block.leaves.shearedDrop(0, .{ .id = .{ .item = .axe_iron }, .count = 1 }) == null);
    try std.testing.expect(Block.leaves.shearedDrop(0, .{ .id = .{ .block = .wool }, .count = 1 }) == null);
    try std.testing.expect(Block.tall_grass.shearedDrop(0, shears) == null);
    try std.testing.expect(Block.stone.shearedDrop(0, shears) == null);
}

test "tall grass rarely drops seeds, otherwise nothing" {
    var rand = JavaRandom.init(0);
    var saw_seeds = false;
    var saw_nothing = false;
    for (0..200) |_| {
        if (Block.tall_grass.drop(0, &rand)) |dropped| {
            try std.testing.expectEqual(Id{ .item = .seeds }, dropped.id);
            saw_seeds = true;
        } else {
            saw_nothing = true;
        }
    }
    try std.testing.expect(saw_seeds);
    try std.testing.expect(saw_nothing);
}

test "dead bush, the mob spawner and liquids never drop anything" {
    var rand = JavaRandom.init(0);
    try std.testing.expect(Block.dead_bush.drop(0, &rand) == null);
    try std.testing.expect(Block.mob_spawner.drop(0, &rand) == null);
    try std.testing.expect(Block.stationary_water.drop(0, &rand) == null);
    try std.testing.expect(Block.flowing_lava.drop(0, &rand) == null);
}

test "clay always drops 4 clay balls" {
    var rand = JavaRandom.init(0);
    const dropped = Block.clay.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .clay_ball }, dropped.id);
    try std.testing.expectEqual(@as(u8, 4), dropped.count);
}

test "reed drops its item form and a snow layer drops nothing on its own" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .reed }, Block.reed.drop(0, &rand).?.id);
    try std.testing.expectEqual(@as(?Stack, null), Block.snow_layer.drop(0, &rand));
}

test "a harvested snow layer hands over one snowball" {
    var rand = JavaRandom.init(0);
    const shovel = Stack{ .id = .{ .item = .shovel_iron }, .count = 1 };
    const harvested = Block.snow_layer.harvestDrop(0, shovel, &rand).?;
    try std.testing.expectEqual(Id{ .item = .snowball }, harvested.id);
    try std.testing.expectEqual(@as(u8, 1), harvested.count);
}

test "blocks without a special drop rule self-drop with metadata reset to 0" {
    var rand = JavaRandom.init(0);
    const dropped = Block.pumpkin.drop(3, &rand).?;
    try std.testing.expectEqual(Id{ .block = .pumpkin }, dropped.id);
    try std.testing.expectEqual(@as(u4, 0), dropped.meta);
}

test "only sand and gravel are falling blocks" {
    try std.testing.expect(Block.sand.isFalling());
    try std.testing.expect(Block.gravel.isFalling());
    try std.testing.expect(!Block.stone.isFalling());
    try std.testing.expect(!Block.dirt.isFalling());
}

test "a falling block can fall into air or liquid, not solid ground" {
    try std.testing.expect(Block.air.canFallInto());
    try std.testing.expect(Block.stationary_water.canFallInto());
    try std.testing.expect(Block.flowing_lava.canFallInto());
    try std.testing.expect(!Block.stone.canFallInto());
}

test "display names come from the real en_US lang keys, not the enum names" {
    try std.testing.expectEqualStrings("Cobblestone", Block.cobblestone.displayName(0));
    try std.testing.expectEqualStrings("Wooden Planks", Block.planks.displayName(0));
    try std.testing.expectEqualStrings("Wood", Block.log.displayName(0));
    try std.testing.expectEqualStrings("Flower", Block.dandelion.displayName(0));
    try std.testing.expectEqualStrings("Moss Stone", Block.cobblestone_mossy.displayName(0));
}

test "blocks with no lang entry have no display name" {
    try std.testing.expectEqualStrings("", Block.tall_grass.displayName(0));
    try std.testing.expectEqualStrings("", Block.dead_bush.displayName(0));
}

test "log wood types all share one display name" {
    for (0..4) |meta| {
        const stack: Stack = .{ .id = .{ .block = .log }, .count = 1, .meta = @intCast(meta) };
        try std.testing.expectEqualStrings("Wood", stack.displayName());
    }
}

test "woolTile matches BlockCloth's inverted-metadata tile formula" {
    const want = [16]u8{ 64, 210, 194, 178, 162, 146, 130, 114, 225, 209, 193, 177, 161, 145, 129, 113 };
    for (want, 0..) |tile, meta| {
        try std.testing.expectEqual(tile, woolTile(@intCast(meta)));
    }
}

test "breakable blocks hide only the face they share with their own kind" {
    for ([_]Block{ .glass, .ice }) |id| {
        try std.testing.expect(!id.shouldRenderFace(id, .up, true));
        try std.testing.expect(id.shouldRenderFace(.air, .up, true));
        try std.testing.expect(!id.isOpaqueCube());
    }
    try std.testing.expect(Block.glass.shouldRenderFace(.ice, .up, true));
    try std.testing.expect(Block.stone.shouldRenderFace(.glass, .up, true));
}

test "glass, bookshelves and ice drop nothing when broken" {
    var rand = JavaRandom.init(0);
    for ([_]Block{ .glass, .bookshelf, .ice }) |id| {
        try std.testing.expectEqual(@as(?Stack, null), id.drop(0, &rand));
    }
}

test "snow blocks and glowstone drop their item form, wool keeps its colour" {
    var rand = JavaRandom.init(0);
    const snow = Block.snow_block.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .snowball }, snow.id);
    try std.testing.expectEqual(@as(u8, 4), snow.count);

    const dust = Block.glowstone.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .glowstone_dust }, dust.id);
    try std.testing.expect(dust.count >= 2 and dust.count <= 4);

    const wool = Block.wool.drop(9, &rand).?;
    try std.testing.expectEqual(Id{ .block = .wool }, wool.id);
    try std.testing.expectEqual(@as(u16, 9), wool.meta);
}

test "rock and iron blocks need a tool, other new blocks do not" {
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), digTicks(.brick, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), digTicks(.block_iron, null), 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), digTicks(.wool, null), 1.0e-4);
}

test "liquids and plants are not solid, so nothing collides with them" {
    try std.testing.expect(!Block.stationary_water.isSolid());
    try std.testing.expect(!Block.flowing_water.isSolid());
    try std.testing.expect(!Block.flowing_lava.isSolid());
    try std.testing.expect(!Block.air.isSolid());
    try std.testing.expect(!Block.rose.isSolid());
    try std.testing.expect(!Block.snow_layer.isSolid());
    try std.testing.expect(Block.stone.isSolid());
    try std.testing.expect(Block.leaves.isSolid());
}

test "both water blocks share one material, texture and tick rate" {
    try std.testing.expectEqual(Material.water, Block.flowing_water.material());
    try std.testing.expectEqual(Material.water, Block.stationary_water.material());
    try std.testing.expectEqual(Block.stationary_water.faceTextures(), Block.flowing_water.faceTextures());
    try std.testing.expectEqual(@as(u32, 5), Block.flowing_water.tickRate());
    try std.testing.expectEqual(@as(u32, 30), Block.flowing_lava.tickRate());
    try std.testing.expect(Block.flowing_water.isTranslucent());
}

test "a liquid culls the face it shares with its own material or with ice" {
    try std.testing.expect(!Block.flowing_water.shouldRenderFace(.stationary_water, .north, true));
    try std.testing.expect(!Block.stationary_water.shouldRenderFace(.flowing_water, .north, true));
    try std.testing.expect(!Block.stationary_water.shouldRenderFace(.ice, .north, true));
    try std.testing.expect(Block.stationary_water.shouldRenderFace(.flowing_lava, .north, true));
    try std.testing.expect(Block.stationary_water.shouldRenderFace(.air, .north, true));
}

test "a liquid always draws its top face unless the same liquid sits above it" {
    try std.testing.expect(Block.stationary_water.shouldRenderFace(.stone, .up, true));
    try std.testing.expect(!Block.stationary_water.shouldRenderFace(.stationary_water, .up, true));
}

test "a piston reads its facing and extension out of the low nibble" {
    try std.testing.expectEqual(Side.down, pistonFacing(0));
    try std.testing.expectEqual(Side.up, pistonFacing(1));
    try std.testing.expectEqual(Side.north, pistonFacing(2));
    try std.testing.expectEqual(Side.south, pistonFacing(3));
    try std.testing.expectEqual(Side.west, pistonFacing(4));
    try std.testing.expectEqual(Side.east, pistonFacing(5));

    try std.testing.expect(!pistonExtended(5));
    try std.testing.expect(pistonExtended(5 | piston_flag));
    try std.testing.expectEqual(Side.east, pistonFacing(5 | piston_flag));

    for (std.enums.values(Side)) |side| {
        try std.testing.expectEqual(side, pistonFacing(pistonFacingValue(side)));
    }
}

test "an extended piston pulls its face back by four pixels" {
    const retracted = pistonBaseBounds(pistonFacingValue(.up));
    try std.testing.expectEqual(Bounds{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } }, retracted);

    const up = pistonBaseBounds(pistonFacingValue(.up) | piston_flag);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), up.max[1], 1.0e-6);

    const down = pistonBaseBounds(pistonFacingValue(.down) | piston_flag);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 16.0), down.min[1], 1.0e-6);

    const east = pistonBaseBounds(pistonFacingValue(.east) | piston_flag);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), east.max[0], 1.0e-6);
}

test "the piston head plate sits at the end it faces" {
    const up = pistonHeadPlateBounds(pistonFacingValue(.up));
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), up.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), up.max[1], 1.0e-6);

    const down = pistonHeadPlateBounds(pistonFacingValue(.down));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), down.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 16.0), down.max[1], 1.0e-6);

    const north = pistonHeadPlateBounds(pistonFacingValue(.north));
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 16.0), north.max[2], 1.0e-6);
}

test "the head shaft reaches from the plate back to the base" {
    const up = pistonHeadShaftBounds(pistonFacingValue(.up));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), up.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), up.max[1], 1.0e-6);

    const east = pistonHeadShaftBounds(pistonFacingValue(.east));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), east.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), east.max[0], 1.0e-6);
}

test "a fence is a wooden post whose rails reach out only to other fences" {
    try std.testing.expectEqual(Shape.fence, Block.fence.shape());
    try std.testing.expectEqual(@as(u8, 4), Block.fence.faceTextures().get(.down));
    try std.testing.expectEqual(@as(f32, 2.0), Block.fence.hardness());
    try std.testing.expectEqual(@as(f32, 3.0), Block.fence.explosionResistance());
    try std.testing.expectEqual(StepSound.wood, Block.fence.stepSound());
    try std.testing.expect(Block.fence.isFlammable());
    try std.testing.expect(!Block.fence.isOpaqueCube());
    try std.testing.expect(!Block.fence.isNormalCube());
    try std.testing.expectEqualStrings("Fence", Block.fence.displayName(0));

    const lone = fenceRailBounds(true, true, false, false);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0 / 16.0), lone.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0 / 16.0), lone.max[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 16.0), lone.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0 / 16.0), lone.max[1], 1.0e-6);

    const reaching = fenceRailBounds(false, true, true, true);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), reaching.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), reaching.max[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0 / 16.0), reaching.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0 / 16.0), reaching.max[1], 1.0e-6);

    const across_z = fenceRailBounds(true, false, true, false);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0 / 16.0), across_z.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), across_z.min[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0 / 16.0), across_z.max[2], 1.0e-6);

    try std.testing.expectEqual(@as(usize, 4), Block.fence.itemRenderBoxes().len);
}

test "a ladder is a thin wooden panel pinned to the wall its metadata names" {
    try std.testing.expectEqual(Shape.ladder, Block.ladder.shape());
    try std.testing.expectEqual(@as(u8, 83), Block.ladder.faceTextures().get(.down));
    try std.testing.expectEqual(@as(f32, 0.4), Block.ladder.hardness());
    try std.testing.expectEqual(StepSound.wood, Block.ladder.stepSound());
    try std.testing.expect(!Block.ladder.isOpaqueCube());
    try std.testing.expect(!Block.ladder.isNormalCube());
    try std.testing.expectEqualStrings("Ladder", Block.ladder.displayName(0));

    const against_south = ladderBounds(2);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 2.0 / 16.0), against_south.min[2], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), against_south.max[2], 1.0e-6);

    const against_west = ladderBounds(5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), against_west.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 16.0), against_west.max[0], 1.0e-6);

    var rand = JavaRandom.init(1);
    try std.testing.expectEqual(Id{ .block = .ladder }, Block.ladder.drop(2, &rand).?.id);
}

test "a ladder keeps a collision box even though its material is not solid" {
    try std.testing.expectEqual(Material.circuits, Block.ladder.material());
    try std.testing.expect(!Block.ladder.isSolid());
    try std.testing.expect(Block.ladder.hasCollision());
    try std.testing.expect(!Block.rail.hasCollision());
    try std.testing.expect(!Block.lever.hasCollision());
}

test "a cobweb is a cross-rendered, hand-breakable snag that drops string" {
    try std.testing.expectEqual(Shape.cross, Block.web.shape());
    try std.testing.expectEqual(@as(u8, 11), Block.web.crossTile(0));
    try std.testing.expectEqual(@as(f32, 4.0), Block.web.hardness());
    try std.testing.expect(!Block.web.isOpaqueCube());
    try std.testing.expect(!Block.web.hasCollision());
    try std.testing.expectEqualStrings("Cobweb", Block.web.displayName(0));
    try std.testing.expect(!Block.web.harvestableWith(null));
    try std.testing.expect(Block.web.harvestableWith(.{ .id = .{ .item = .shears }, .count = 1 }));

    var rand = JavaRandom.init(1);
    const dropped = Block.web.drop(0, &rand).?;
    try std.testing.expectEqual(Id{ .item = .string }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
}

test "what a piston can shove follows the material mobility the original gives it" {
    try std.testing.expectEqual(Mobility.movable, Block.stone.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.wool.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.ice.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.snow_block.mobility());

    try std.testing.expectEqual(Mobility.fragile, Block.torch.mobility());
    try std.testing.expectEqual(Mobility.fragile, Block.redstone_wire.mobility());
    try std.testing.expectEqual(Mobility.fragile, Block.rose.mobility());
    try std.testing.expectEqual(Mobility.fragile, Block.snow_layer.mobility());
    try std.testing.expectEqual(Mobility.fragile, Block.cactus.mobility());
    try std.testing.expectEqual(Mobility.fragile, Block.pumpkin.mobility());
    try std.testing.expectEqual(Mobility.fragile, Block.cake.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.bed.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.door_wood.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.door_iron.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.pressure_plate_stone.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.pressure_plate_planks.mobility());
    try std.testing.expectEqual(Mobility.movable, Block.workbench.mobility());

    try std.testing.expectEqual(Mobility.immovable, Block.piston.mobility());
    try std.testing.expectEqual(Mobility.immovable, Block.piston_head.mobility());
    try std.testing.expectEqual(Mobility.immovable, Block.piston_moving.mobility());
}

test "only the piston base is worth picking up" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .piston }, Block.piston.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .piston_sticky }, Block.piston_sticky.drop(0, &rand).?.id);
    try std.testing.expect(Block.piston_head.drop(0, &rand) == null);
    try std.testing.expect(Block.piston_moving.drop(0, &rand) == null);

    try std.testing.expect(Block.piston_moving.isUnbreakable());
    try std.testing.expect(!Block.piston.isUnbreakable());
}

test "a piston in the hand shows its face, not the grass tile at index zero" {
    const plain = Block.piston.faceTextures();
    try std.testing.expectEqual(piston_top_tile, plain.get(.up));
    try std.testing.expectEqual(piston_back_tile, plain.get(.down));
    try std.testing.expectEqual(piston_side_tile, plain.get(.north));
    try std.testing.expectEqual(piston_side_tile, plain.get(.east));

    const sticky = Block.piston_sticky.faceTextures();
    try std.testing.expectEqual(piston_top_sticky_tile, sticky.get(.up));
    try std.testing.expectEqual(piston_back_tile, sticky.get(.down));
}

test "a piston's faces take the turns RenderBlocks gives them, mirrors and all" {
    const sides = [6]Side{ .down, .up, .north, .south, .west, .east };

    const expected = [6][6]TileTurn{
        .{ .{}, .{}, .{ .turns = 2 }, .{ .turns = 2 }, .{ .turns = 2 }, .{ .turns = 2 } },
        .{ .{}, .{}, .{}, .{}, .{}, .{} },
        .{ .{}, .{}, .{}, .{}, .{ .turns = 3 }, .{ .turns = 3, .mirrored = true } },
        .{ .{ .turns = 2 }, .{ .turns = 2 }, .{}, .{}, .{ .turns = 1 }, .{ .turns = 1, .mirrored = true } },
        .{ .{ .turns = 3 }, .{ .turns = 3 }, .{ .turns = 3, .mirrored = true }, .{ .turns = 3 }, .{}, .{} },
        .{ .{ .turns = 1 }, .{ .turns = 1 }, .{ .turns = 1, .mirrored = true }, .{ .turns = 1 }, .{}, .{} },
    };

    for (sides, 0..) |facing, f| {
        for (sides, 0..) |face, n| {
            try std.testing.expectEqual(expected[f][n], pistonSideTurn(facing, face));
        }
    }
}

test "a piston is not a normal cube, so it carries no redstone through itself" {
    try std.testing.expect(!Block.piston.isNormalCube());
    try std.testing.expect(!Block.piston_sticky.isNormalCube());
    try std.testing.expect(!Block.piston_head.isNormalCube());
    try std.testing.expect(!Block.piston.isOpaqueCube());
    try std.testing.expect(Block.piston.isSolid());
    try std.testing.expect(Block.piston.isPistonBase() and Block.piston_sticky.isPistonBase());
    try std.testing.expect(!Block.piston_head.isPistonBase());
}

test "the piston face shows sticky, plain or the drawn-back inner ring" {
    const plain = pistonBaseTextures(.piston, pistonFacingValue(.up));
    try std.testing.expectEqual(piston_top_tile, plain.get(.up));
    try std.testing.expectEqual(piston_back_tile, plain.get(.down));
    try std.testing.expectEqual(piston_side_tile, plain.get(.north));

    const sticky = pistonBaseTextures(.piston_sticky, pistonFacingValue(.up));
    try std.testing.expectEqual(piston_top_sticky_tile, sticky.get(.up));

    const extended = pistonBaseTextures(.piston_sticky, pistonFacingValue(.up) | piston_flag);
    try std.testing.expectEqual(piston_inner_tile, extended.get(.up));

    const head = pistonHeadTextures(pistonFacingValue(.up));
    try std.testing.expectEqual(piston_top_tile, head.get(.up));
    try std.testing.expectEqual(piston_top_tile, head.get(.down));

    const sticky_head = pistonHeadTextures(pistonFacingValue(.up) | piston_flag);
    try std.testing.expectEqual(piston_top_sticky_tile, sticky_head.get(.up));
}

test "saplings draw as a cross, with a tile per tree kind" {
    try std.testing.expect(Block.sapling.isCross());
    try std.testing.expectEqual(@as(u8, 15), Block.sapling.crossTile(0));
    try std.testing.expectEqual(@as(u8, 63), Block.sapling.crossTile(1));
    try std.testing.expectEqual(@as(u8, 79), Block.sapling.crossTile(2));
    try std.testing.expectEqual(@as(u8, 15), Block.sapling.crossTile(3));
}

test "a torch is not solid, so nothing collides with it or plants on it" {
    try std.testing.expect(!Block.torch.isSolid());
    try std.testing.expect(!Block.torch.isOpaque());
    try std.testing.expect(!Block.torch.isOpaqueCube());
    try std.testing.expectEqual(Material.circuits, Block.torch.material());
}

test "a torch breaks instantly and drops itself" {
    var rand = JavaRandom.init(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), digTicks(.torch, null), 1.0e-4);
    const dropped = Block.torch.drop(5, &rand).?;
    try std.testing.expectEqual(Id{ .block = .torch }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
    try std.testing.expectEqualStrings("Torch", Block.torch.displayName(0));
}

test "a wall torch stands in the quarter of the block its wall is on" {
    const west = Block.torch.selectionBounds(1);
    try std.testing.expectEqual(@as(f32, 0.0), west.min[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), west.max[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), west.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), west.max[1], 1.0e-6);

    const east = Block.torch.selectionBounds(2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), east.min[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), east.max[0]);

    const north = Block.torch.selectionBounds(3);
    try std.testing.expectEqual(@as(f32, 0.0), north.min[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), north.max[2], 1.0e-6);

    const south = Block.torch.selectionBounds(4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), south.min[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), south.max[2]);
}

test "a broken plant sheds its own sprite, not the grass top" {
    try std.testing.expectEqual(Block.rose.crossTile(0), Block.rose.particleTile(0));
    try std.testing.expectEqual(Block.dandelion.crossTile(0), Block.dandelion.particleTile(0));
    try std.testing.expectEqual(Block.tall_grass.crossTile(2), Block.tall_grass.particleTile(2));
    try std.testing.expectEqual(Block.stone.faceTextures().get(.down), Block.stone.particleTile(0));
}

test "a standing torch is a thin column in the middle of the block" {
    const standing = Block.torch.selectionBounds(5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), standing.min[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), standing.max[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 0.0), standing.min[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), standing.max[1], 1.0e-6);
    try std.testing.expectEqual(standing, Block.torch.selectionBounds(0));
}

test "a torch leaves the world as a flat sprite, like a plant does" {
    try std.testing.expectEqual(@as(?u8, 80), Block.torch.flatItemTile(2));
    try std.testing.expectEqual(@as(?u8, Block.rose.crossTile(0)), Block.rose.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), Block.stone.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), Block.snow_layer.flatItemTile(0));
}

test "fire stands in the world without filling it, and leaves nothing behind" {
    var rand = JavaRandom.init(0);

    try std.testing.expectEqual(Material.fire, Block.fire.material());
    try std.testing.expect(!Block.fire.isOpaque());
    try std.testing.expect(!Block.fire.isOpaqueCube());
    try std.testing.expect(!Block.fire.isNormalCube());
    try std.testing.expect(!Block.fire.material().isSolid());
    try std.testing.expectEqual(@as(f32, 0.0), Block.fire.hardness());
    try std.testing.expectEqual(Mobility.fragile, Block.fire.mobility());
    try std.testing.expect(Block.fire.drop(0, &rand) == null);
    try std.testing.expectEqual(Shape.fire, Block.fire.shape());
    try std.testing.expectEqual(@as(u8, 31), Block.fire.faceTextures().get(.down));
    try std.testing.expectEqualStrings("Fire", Block.fire.displayName(0));
}

test "fire does not stop grass growing under it, the way a solid block would" {
    try std.testing.expect(!Block.fire.material().blocksGrass());
    try std.testing.expect(Block.netherrack.material().blocksGrass());
}

test "only air, liquids and snow give way to a block placed on top of them" {
    try std.testing.expect(Block.air.isReplaceable());
    try std.testing.expect(Block.stationary_water.isReplaceable());
    try std.testing.expect(Block.flowing_water.isReplaceable());
    try std.testing.expect(Block.flowing_lava.isReplaceable());
    try std.testing.expect(Block.snow_layer.isReplaceable());

    try std.testing.expect(!Block.torch.isReplaceable());
    try std.testing.expect(!Block.stone.isReplaceable());
    try std.testing.expect(!Block.tall_grass.isReplaceable());
    try std.testing.expect(!Block.rose.isReplaceable());
}

test "a closed door fills the three-sixteenths strip on the side it was hung" {
    const north = Block.door_wood.selectionBounds(1);
    try std.testing.expectEqual(@as(f32, 0.0), north.min[2]);
    try std.testing.expectApproxEqAbs(door_thickness, north.max[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), north.max[0]);
    try std.testing.expectEqual(@as(f32, 1.0), north.max[1]);

    const east = Block.door_wood.selectionBounds(2);
    try std.testing.expectApproxEqAbs(1.0 - door_thickness, east.min[0], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), east.max[0]);

    const south = Block.door_wood.selectionBounds(3);
    try std.testing.expectApproxEqAbs(1.0 - door_thickness, south.min[2], 1.0e-6);

    const west = Block.door_wood.selectionBounds(0);
    try std.testing.expectApproxEqAbs(door_thickness, west.max[0], 1.0e-6);
}

test "opening a door swings it a quarter turn around its hinge" {
    try std.testing.expectEqual(@as(u2, 3), doorState(0));
    try std.testing.expectEqual(@as(u2, 0), doorState(0 | door_open_bit));
    try std.testing.expectEqual(@as(u2, 0), doorState(1));
    try std.testing.expectEqual(@as(u2, 1), doorState(1 | door_open_bit));
    try std.testing.expectEqual(doorBounds(1), doorBounds(1 | door_top_bit));
}

test "both halves of a door share the state their metadata names" {
    try std.testing.expect(doorIsTop(door_top_bit));
    try std.testing.expect(!doorIsTop(3));
    try std.testing.expect(doorIsOpen(door_open_bit | 2));
    try std.testing.expect(!doorIsOpen(2));
    try std.testing.expectEqual(doorState(2), doorState(2 | door_top_bit));
}

test "a door shows its edge tile on the two sides it is thin against" {
    for ([_]Side{ .west, .east, .up, .down }) |side| {
        const edge = doorFaceTile(.door_wood, side, 1);
        try std.testing.expectEqual(@as(u8, 97), edge.tile);
        try std.testing.expect(!edge.mirrored);
    }
    for ([_]Side{ .north, .south, .up, .down }) |side| {
        try std.testing.expectEqual(@as(u8, 97), doorFaceTile(.door_wood, side, 2).tile);
    }
}

test "the upper half of a door takes the tile a row above the lower one" {
    try std.testing.expectEqual(@as(u8, 97), doorFaceTile(.door_wood, .north, 1).tile);
    try std.testing.expectEqual(@as(u8, 81), doorFaceTile(.door_wood, .north, 1 | door_top_bit).tile);
    try std.testing.expectEqual(@as(u8, 98), doorFaceTile(.door_iron, .north, 1).tile);
    try std.testing.expectEqual(@as(u8, 82), doorFaceTile(.door_iron, .north, 1 | door_top_bit).tile);
}

test "the two faces of a door mirror each other" {
    const north = doorFaceTile(.door_wood, .north, 1);
    const south = doorFaceTile(.door_wood, .south, 1);
    try std.testing.expectEqual(north.tile, south.tile);
    try std.testing.expect(north.mirrored != south.mirrored);

    const west = doorFaceTile(.door_wood, .west, 2);
    const east = doorFaceTile(.door_wood, .east, 2);
    try std.testing.expectEqual(west.tile, east.tile);
    try std.testing.expect(west.mirrored != east.mirrored);
}

test "an open door still shows its face tiles across the way it now stands" {
    const west = doorFaceTile(.door_wood, .west, 1 | door_open_bit);
    const east = doorFaceTile(.door_wood, .east, 1 | door_open_bit);
    try std.testing.expectEqual(@as(u8, 97), west.tile);
    try std.testing.expectEqual(@as(u8, 97), east.tile);
    try std.testing.expect(west.mirrored != east.mirrored);
    try std.testing.expectEqual(@as(u8, 97), doorFaceTile(.door_wood, .north, 1 | door_open_bit).tile);
}

test "a door faces away from the player who placed it, whichever way they were turned" {
    try std.testing.expectEqual(@as(u2, 1), doorFacingFromYaw(0));
    try std.testing.expectEqual(@as(u2, 2), doorFacingFromYaw(90));
    try std.testing.expectEqual(@as(u2, 3), doorFacingFromYaw(180));
    try std.testing.expectEqual(@as(u2, 0), doorFacingFromYaw(270));
    try std.testing.expectEqual(@as(u2, 0), doorFacingFromYaw(-90));
    try std.testing.expectEqual(@as(u2, 1), doorFacingFromYaw(720));
}

test "the hinge step runs across the doorway the facing opens" {
    try std.testing.expectEqual([2]i32{ 0, 1 }, doorHingeStep(0));
    try std.testing.expectEqual([2]i32{ -1, 0 }, doorHingeStep(1));
    try std.testing.expectEqual([2]i32{ 0, -1 }, doorHingeStep(2));
    try std.testing.expectEqual([2]i32{ 1, 0 }, doorHingeStep(3));
}

test "only the lower half of a door drops the item, and iron needs a pickaxe" {
    var rand = JavaRandom.init(0);
    const dropped = Block.door_wood.drop(1, &rand).?;
    try std.testing.expectEqual(Id{ .item = .door_wood }, dropped.id);
    try std.testing.expectEqual(@as(u8, 1), dropped.count);
    try std.testing.expectEqual(@as(?Stack, null), Block.door_wood.drop(1 | door_top_bit, &rand));

    try std.testing.expectEqual(Id{ .item = .door_iron }, Block.door_iron.drop(1, &rand).?.id);
    try std.testing.expectEqual(@as(?Stack, null), Block.door_iron.drop(1 | door_top_bit, &rand));

    const pickaxe: Stack = .{ .id = .{ .item = .pickaxe_wood }, .count = 1 };
    try std.testing.expect(Block.door_wood.harvestableWith(null));
    try std.testing.expect(!Block.door_iron.harvestableWith(null));
    try std.testing.expect(Block.door_iron.harvestableWith(pickaxe));
}

test "a door is solid to walk into but never culls the face beside it" {
    try std.testing.expect(Block.door_wood.isSolid());
    try std.testing.expect(Block.door_iron.isSolid());
    try std.testing.expect(!Block.door_wood.isOpaqueCube());
    try std.testing.expect(!Block.door_iron.isOpaqueCube());
    try std.testing.expect(Block.stone.shouldRenderFace(.door_wood, .north, true));
    try std.testing.expect(Block.door_wood.isDoor());
    try std.testing.expect(!Block.planks.isDoor());
}

test "a slab's metadata picks which block it was cut from" {
    const stone = slabTextures(slab_stone);
    try std.testing.expectEqual(@as(u8, 6), stone.get(.up));
    try std.testing.expectEqual(@as(u8, 6), stone.get(.down));
    try std.testing.expectEqual(@as(u8, 5), stone.get(.north));

    const sand = slabTextures(slab_sandstone);
    try std.testing.expectEqual(@as(u8, 176), sand.get(.up));
    try std.testing.expectEqual(@as(u8, 208), sand.get(.down));
    try std.testing.expectEqual(@as(u8, 192), sand.get(.east));

    try std.testing.expectEqual(uniform(4), slabTextures(slab_wood));
    try std.testing.expectEqual(uniform(16), slabTextures(slab_cobblestone));

    for (4..16) |meta| {
        try std.testing.expectEqual(stone, slabTextures(@intCast(meta)));
    }
}

test "a single slab is the bottom half of its block, a double slab the whole of it" {
    const half = Block.slab.selectionBounds(0);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, half.min);
    try std.testing.expectEqual([3]f32{ 1, 0.5, 1 }, half.max);

    const whole = Block.slab_double.selectionBounds(0);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, whole.max);

    try std.testing.expect(!Block.slab.isOpaqueCube());
    try std.testing.expect(Block.slab_double.isOpaqueCube());
    try std.testing.expect(Block.slab.isSolid() and Block.slab_double.isSolid());
}

test "a slab always draws its top face, even buried" {
    for ([_]Block{ .slab, .slab_double }) |id| {
        try std.testing.expect(id.shouldRenderFace(.stone, .up, true));
        try std.testing.expect(id.shouldRenderFace(id, .up, true));

        try std.testing.expect(!id.shouldRenderFace(.stone, .down, true));
        try std.testing.expect(id.shouldRenderFace(.air, .down, true));
    }

    try std.testing.expect(Block.slab.shouldRenderFace(.slab, .down, true));
    try std.testing.expect(!Block.slab_double.shouldRenderFace(.slab_double, .down, true));
}

test "a slab hides the side it shares with a slab of its own id" {
    try std.testing.expect(!Block.slab.shouldRenderFace(.slab, .north, true));
    try std.testing.expect(!Block.slab_double.shouldRenderFace(.slab_double, .east, true));

    try std.testing.expect(!Block.slab.shouldRenderFace(.slab_double, .north, true));
    try std.testing.expect(Block.slab_double.shouldRenderFace(.slab, .north, true));
    try std.testing.expect(Block.slab.shouldRenderFace(.air, .north, true));
    try std.testing.expect(!Block.slab.shouldRenderFace(.stone, .north, true));
}

test "a double slab drops two single slabs, both keeping the metadata" {
    var rand = JavaRandom.init(0);
    for ([_]u4{ slab_stone, slab_sandstone, slab_wood, slab_cobblestone }) |meta| {
        const single = Block.slab.drop(meta, &rand).?;
        try std.testing.expectEqual(Id{ .block = .slab }, single.id);
        try std.testing.expectEqual(@as(u8, 1), single.count);
        try std.testing.expectEqual(@as(u16, meta), single.meta);

        const double = Block.slab_double.drop(meta, &rand).?;
        try std.testing.expectEqual(Id{ .block = .slab }, double.id);
        try std.testing.expectEqual(@as(u8, 2), double.count);
        try std.testing.expectEqual(@as(u16, meta), double.meta);
    }
}

test "a stair splits into a half-height tread and a full-height back" {
    for (0..4) |facing| {
        const boxes = stairsBoxes(@intCast(facing));
        var half_count: usize = 0;
        for (boxes) |box| {
            try std.testing.expectEqual(@as(f32, 0.0), box.min[1]);
            if (box.max[1] == 0.5) half_count += 1 else try std.testing.expectEqual(@as(f32, 1.0), box.max[1]);

            const width = (box.max[0] - box.min[0]) * (box.max[2] - box.min[2]);
            try std.testing.expectApproxEqAbs(@as(f32, 0.5), width, 1.0e-6);
        }
        try std.testing.expectEqual(@as(usize, 1), half_count);
    }
}

test "the two halves of a stair meet without a gap or an overlap" {
    for (0..4) |facing| {
        const boxes = stairsBoxes(@intCast(facing));
        const split_axis: usize = if (facing < 2) 0 else 2;
        const low = if (boxes[0].min[split_axis] == 0.0) boxes[0] else boxes[1];
        const high = if (boxes[0].min[split_axis] == 0.0) boxes[1] else boxes[0];
        try std.testing.expectEqual(@as(f32, 0.5), low.max[split_axis]);
        try std.testing.expectEqual(@as(f32, 0.5), high.min[split_axis]);
        try std.testing.expectEqual(@as(f32, 1.0), high.max[split_axis]);
    }
}

test "a stair's tall half turns away from the player who placed it" {
    try std.testing.expectEqual(@as(u4, 2), stairsFacingFromYaw(0));
    try std.testing.expectEqual(@as(u4, 1), stairsFacingFromYaw(90));
    try std.testing.expectEqual(@as(u4, 3), stairsFacingFromYaw(180));
    try std.testing.expectEqual(@as(u4, 0), stairsFacingFromYaw(270));
    try std.testing.expectEqual(@as(u4, 0), stairsFacingFromYaw(-90));
    try std.testing.expectEqual(@as(u4, 2), stairsFacingFromYaw(-720));

    const facing_north = stairsBoxes(stairsFacingFromYaw(0));
    try std.testing.expectEqual(@as(f32, 1.0), facing_north[1].max[1]);
    try std.testing.expectEqual(@as(f32, 0.5), facing_north[1].min[2]);
}

test "a stair keeps its neighbours' faces and is selected as a whole block" {
    for ([_]Block{ .stairs_wood, .stairs_cobblestone }) |id| {
        try std.testing.expect(id.isStairs());
        try std.testing.expect(id.isSolid());
        try std.testing.expect(!id.isOpaqueCube());
        try std.testing.expect(Block.stone.shouldRenderFace(id, .north, true));

        const cube: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
        try std.testing.expectEqual(cube, id.selectionBounds(0));
        try std.testing.expectEqual(cube, id.selectionBounds(3));
    }
    try std.testing.expect(!Block.planks.isStairs());
}

test "a stair drops the block it was cut from, not itself" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .planks }, Block.stairs_wood.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .block = .cobblestone }, Block.stairs_cobblestone.drop(0, &rand).?.id);
}

test "a shut trapdoor is the bottom three sixteenths of its block" {
    const shut = Block.trapdoor.selectionBounds(0);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, shut.min);
    try std.testing.expectEqual(@as(f32, 1.0), shut.max[0]);
    try std.testing.expectApproxEqAbs(trapdoor_thickness, shut.max[1], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), shut.max[2]);

    for (0..4) |facing| {
        try std.testing.expectEqual(shut, Block.trapdoor.selectionBounds(@intCast(facing)));
    }
}

test "an open trapdoor stands up against the wall that holds it" {
    const open = trapdoor_open_bit;

    const south = Block.trapdoor.selectionBounds(open);
    try std.testing.expectApproxEqAbs(1.0 - trapdoor_thickness, south.min[2], 1.0e-6);
    try std.testing.expectEqual(@as(f32, 1.0), south.max[1]);

    const north = Block.trapdoor.selectionBounds(open + 1);
    try std.testing.expectApproxEqAbs(trapdoor_thickness, north.max[2], 1.0e-6);

    const east = Block.trapdoor.selectionBounds(open + 2);
    try std.testing.expectApproxEqAbs(1.0 - trapdoor_thickness, east.min[0], 1.0e-6);

    const west = Block.trapdoor.selectionBounds(open + 3);
    try std.testing.expectApproxEqAbs(trapdoor_thickness, west.max[0], 1.0e-6);
}

test "a trapdoor hangs off the wall it was clicked onto" {
    try std.testing.expectEqual(@as(?u4, 0), trapdoorFacingFromFace(.north));
    try std.testing.expectEqual(@as(?u4, 1), trapdoorFacingFromFace(.south));
    try std.testing.expectEqual(@as(?u4, 2), trapdoorFacingFromFace(.west));
    try std.testing.expectEqual(@as(?u4, 3), trapdoorFacingFromFace(.east));
    try std.testing.expectEqual(@as(?u4, null), trapdoorFacingFromFace(.up));
    try std.testing.expectEqual(@as(?u4, null), trapdoorFacingFromFace(.down));
}

test "the wall holding a trapdoor sits opposite the face it was placed against" {
    try std.testing.expectEqual([3]i32{ 0, 0, 1 }, trapdoorSupportStep(0));
    try std.testing.expectEqual([3]i32{ 0, 0, -1 }, trapdoorSupportStep(1));
    try std.testing.expectEqual([3]i32{ 1, 0, 0 }, trapdoorSupportStep(2));
    try std.testing.expectEqual([3]i32{ -1, 0, 0 }, trapdoorSupportStep(3));
    try std.testing.expectEqual(trapdoorSupportStep(2), trapdoorSupportStep(2 | trapdoor_open_bit));
}

test "a trapdoor is wood that drops itself with its swing forgotten" {
    var rand = JavaRandom.init(0);
    const dropped = Block.trapdoor.drop(2 | trapdoor_open_bit, &rand).?;
    try std.testing.expectEqual(Id{ .block = .trapdoor }, dropped.id);
    try std.testing.expectEqual(@as(u16, 0), dropped.meta);

    try std.testing.expectEqual(Material.wood, Block.trapdoor.material());
    try std.testing.expect(Block.trapdoor.harvestableWith(null));
    try std.testing.expect(Block.trapdoor.isTrapdoor());
    try std.testing.expect(!Block.trapdoor.isOpaqueCube());
    try std.testing.expectEqual(@as(u8, 84), Block.trapdoor.faceTextures().get(.down));
    try std.testing.expectEqualStrings("Trapdoor", Block.trapdoor.displayName(0));
}

test "grass wears the snow side texture when snow is piled on it" {
    try std.testing.expectEqual(grass_side_tile, grassSideTile(.air));
    try std.testing.expectEqual(grass_side_tile, grassSideTile(.stone));
    try std.testing.expectEqual(@as(u8, 68), grassSideTile(.snow_layer));
    try std.testing.expectEqual(@as(u8, 68), grassSideTile(.snow_block));
}

test "a full cube is the default model when held, dropped or drawn in a slot" {
    const cube: Bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } };
    for ([_]Block{ .stone, .snow_layer, .door_wood, .cactus, .torch }) |id| {
        try std.testing.expectEqualSlices(Bounds, &.{cube}, id.itemRenderBoxes());
    }

    const plate = Block.trapdoor.itemRenderBoxes()[0];
    try std.testing.expectEqual([2]f32{ 0, 0 }, [2]f32{ plate.min[0], plate.min[2] });
    try std.testing.expectEqual([2]f32{ 1, 1 }, [2]f32{ plate.max[0], plate.max[2] });
    try std.testing.expectApproxEqAbs(trapdoor_thickness, plate.max[1] - plate.min[1], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), (plate.max[1] + plate.min[1]) / 2.0, 1.0e-6);
}

test "each wool colour is named by its inverted metadata, as ItemCloth does" {
    const expected = [16][]const u8{
        "Wool",            "Orange Wool", "Magenta Wool", "Light Blue Wool",
        "Yellow Wool",     "Lime Wool",   "Pink Wool",    "Gray Wool",
        "Light Gray Wool", "Cyan Wool",   "Purple Wool",  "Blue Wool",
        "Brown Wool",      "Green Wool",  "Red Wool",     "Black Wool",
    };
    for (expected, 0..) |name, meta| {
        try std.testing.expectEqualStrings(name, Block.wool.displayName(@intCast(meta)));
    }
}

test "a wool stack carries its colour through to the name shown in a slot" {
    const black: Stack = .{ .id = .{ .block = .wool }, .count = 1, .meta = 15 };
    try std.testing.expectEqualStrings("Black Wool", black.displayName());

    const white: Stack = .{ .id = .{ .block = .wool }, .count = 1, .meta = 0 };
    try std.testing.expectEqualStrings("Wool", white.displayName());
}

test "the sheep's fleece colours all name a wool a player would recognise" {
    try std.testing.expectEqualStrings("Black Wool", Block.wool.displayName(15));
    try std.testing.expectEqualStrings("Gray Wool", Block.wool.displayName(7));
    try std.testing.expectEqualStrings("Light Gray Wool", Block.wool.displayName(8));
    try std.testing.expectEqualStrings("Brown Wool", Block.wool.displayName(12));
    try std.testing.expectEqualStrings("Pink Wool", Block.wool.displayName(6));
    try std.testing.expectEqualStrings("Wool", Block.wool.displayName(0));
}

test "a slab is named after the block it was cut from" {
    try std.testing.expectEqualStrings("Stone Slab", Block.slab.displayName(slab_stone));
    try std.testing.expectEqualStrings("Sandstone Slab", Block.slab.displayName(slab_sandstone));
    try std.testing.expectEqualStrings("Wooden Slab", Block.slab.displayName(slab_wood));
    try std.testing.expectEqualStrings("Stone Slab", Block.slab.displayName(slab_cobblestone));
    try std.testing.expectEqualStrings("Wooden Slab", Block.slab_double.displayName(slab_wood));

    const stack: Stack = .{ .id = .{ .block = .slab }, .count = 1, .meta = slab_sandstone };
    try std.testing.expectEqualStrings("Sandstone Slab", stack.displayName());
}

test "blocks without variants read the same whatever metadata they carry" {
    for (0..16) |meta| {
        try std.testing.expectEqualStrings("Cobblestone", Block.cobblestone.displayName(@intCast(meta)));
        try std.testing.expectEqualStrings("Wood", Block.log.displayName(@intCast(meta)));
    }
}

test "a cake is eaten away from its west face, a slice at a time" {
    const whole = Block.cake.selectionBounds(0);
    try std.testing.expectEqual(@as(f32, 1.0 / 16.0), whole.min[0]);
    try std.testing.expectEqual(@as(f32, 3.0 / 16.0), Block.cake.selectionBounds(1).min[0]);
    try std.testing.expectEqual(@as(f32, 11.0 / 16.0), Block.cake.selectionBounds(5).min[0]);

    for (0..cake_slices) |meta| {
        const bounds = Block.cake.selectionBounds(@intCast(meta));
        try std.testing.expectEqual(whole.min[1], bounds.min[1]);
        try std.testing.expectEqual(whole.max, bounds.max);
        try std.testing.expectEqual(@as(f32, 1.0 / 16.0), bounds.min[2]);
    }
}

test "a cake stands half a block tall, and is walked on a notch lower" {
    const selected = Block.cake.selectionBounds(0);
    try std.testing.expectEqual(@as(f32, 0.5), selected.max[1]);
    try std.testing.expectEqual(@as(f32, 15.0 / 16.0), selected.max[0]);
    try std.testing.expectEqual(@as(f32, 15.0 / 16.0), selected.max[2]);

    const walked = cakeCollisionBounds(0);
    try std.testing.expectEqual(@as(f32, 7.0 / 16.0), walked.max[1]);
    try std.testing.expectEqual(selected.min, walked.min);
}

test "an uncut cake shows its whole side, a cut one its filling to the west" {
    const whole = cakeTextures(0);
    try std.testing.expectEqual(@as(u8, 121), whole.get(.up));
    try std.testing.expectEqual(@as(u8, 124), whole.get(.down));
    for ([_]Side{ .north, .south, .west, .east }) |side| {
        try std.testing.expectEqual(@as(u8, 122), whole.get(side));
    }

    const cut = cakeTextures(1);
    try std.testing.expectEqual(@as(u8, 123), cut.get(.west));
    for ([_]Side{ .north, .south, .east }) |side| {
        try std.testing.expectEqual(@as(u8, 122), cut.get(side));
    }
    try std.testing.expectEqual(whole.get(.up), cut.get(.up));
    try std.testing.expectEqual(whole.get(.down), cut.get(.down));
}

test "a cake never culls a neighbour's face and never drops itself" {
    var rand = JavaRandom.init(0);
    try std.testing.expect(!Block.cake.isOpaqueCube());
    try std.testing.expect(Block.stone.shouldRenderFace(.cake, .up, true));
    try std.testing.expectEqual(@as(?Stack, null), Block.cake.drop(0, &rand));
    try std.testing.expectEqual(@as(?Stack, null), Block.cake.drop(3, &rand));
}

test "a cake is solid enough to stand on but soft enough to cut by hand" {
    try std.testing.expect(Block.cake.isSolid());
    try std.testing.expect(Block.cake.material().isSolid());
    try std.testing.expect(Block.cake.harvestableWith(null));
    try std.testing.expectEqualStrings("Cake", Block.cake.displayName(0));
}

test "the cake in hand is the whole cake, not a cube" {
    const boxes = Block.cake.itemRenderBoxes();
    try std.testing.expectEqual(@as(usize, 1), boxes.len);
    try std.testing.expectEqual([3]f32{ 1.0 / 16.0, 0, 1.0 / 16.0 }, boxes[0].min);
    try std.testing.expectEqual([3]f32{ 15.0 / 16.0, 0.5, 15.0 / 16.0 }, boxes[0].max);
}

test "the bed's metadata carries a facing, an occupied flag and which end it is" {
    try std.testing.expectEqual(@as(u2, 0), bedFacing(0));
    try std.testing.expectEqual(@as(u2, 3), bedFacing(3));
    try std.testing.expectEqual(@as(u2, 1), bedFacing(1 + bed_pillow_bit));

    try std.testing.expect(!bedIsPillow(2));
    try std.testing.expect(bedIsPillow(2 + bed_pillow_bit));

    try std.testing.expect(!bedIsOccupied(2));
    try std.testing.expect(bedIsOccupied(bedOccupied(2, true)));
    try std.testing.expect(!bedIsOccupied(bedOccupied(2 + bed_occupied_bit, false)));
    try std.testing.expectEqual(@as(u2, 2), bedFacing(bedOccupied(2, true)));
}

test "the step from one end of the bed to the other follows the facing" {
    try std.testing.expectEqual([2]i32{ 0, 1 }, bedStep(0));
    try std.testing.expectEqual([2]i32{ -1, 0 }, bedStep(1));
    try std.testing.expectEqual([2]i32{ 0, -1 }, bedStep(2));
    try std.testing.expectEqual([2]i32{ 1, 0 }, bedStep(3));
}

test "the bed is laid out from the way the player faces" {
    try std.testing.expectEqual(@as(u2, 0), bedFacingFromYaw(0));
    try std.testing.expectEqual(@as(u2, 1), bedFacingFromYaw(90));
    try std.testing.expectEqual(@as(u2, 2), bedFacingFromYaw(180));
    try std.testing.expectEqual(@as(u2, 3), bedFacingFromYaw(270));
    try std.testing.expectEqual(@as(u2, 0), bedFacingFromYaw(360));
    try std.testing.expectEqual(@as(u2, 3), bedFacingFromYaw(-90));
}

test "the pillow end wears the pillow, the other end does not" {
    try std.testing.expectEqual(@as(u8, 134), bedTile(.up, 0));
    try std.testing.expectEqual(@as(u8, 135), bedTile(.up, bed_pillow_bit));
    try std.testing.expectEqual(@as(u8, 4), bedTile(.down, 0));
    try std.testing.expectEqual(@as(u8, 4), bedTile(.down, bed_pillow_bit));
}

test "only the end without the pillow drops the bed" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .item = .bed }, Block.bed.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .bed }, Block.bed.drop(3, &rand).?.id);
    try std.testing.expectEqual(@as(?Stack, null), Block.bed.drop(bed_pillow_bit, &rand));
    try std.testing.expectEqual(@as(?Stack, null), Block.bed.drop(3 + bed_pillow_bit, &rand));
}

test "a bed is a low slab that never culls its neighbours" {
    try std.testing.expect(!Block.bed.isOpaqueCube());
    try std.testing.expect(Block.stone.shouldRenderFace(.bed, .up, true));
    try std.testing.expectEqual(@as(f32, 9.0 / 16.0), Block.bed.selectionBounds(0).max[1]);
    try std.testing.expectEqualStrings("Bed", Block.bed.displayName(0));
}

test "a placed sign post faces back at whoever set it down" {
    try std.testing.expectEqual(@as(u4, 8), signPostFacingFromYaw(0));
    try std.testing.expectEqual(@as(u4, 0), signPostFacingFromYaw(180));
    try std.testing.expectEqual(@as(u4, 12), signPostFacingFromYaw(90));
    try std.testing.expectEqual(@as(u4, 4), signPostFacingFromYaw(-90));
    try std.testing.expectEqual(@as(u4, 0), signPostFacingFromYaw(-180));
}

test "a sign is climbed through, not walked into, and drops itself when broken" {
    var rand = JavaRandom.init(1);
    try std.testing.expect(!Block.sign_post.hasCollision());
    try std.testing.expect(!Block.wall_sign.hasCollision());
    try std.testing.expect(Block.planks.hasCollision());
    try std.testing.expect(Block.sign_post.material().isSolid());

    try std.testing.expectEqual(Id{ .item = .sign }, Block.sign_post.drop(0, &rand).?.id);
    try std.testing.expectEqual(Id{ .item = .sign }, Block.wall_sign.drop(3, &rand).?.id);
    try std.testing.expect(!Block.sign_post.isOpaqueCube());
}

test "a wall sign is a thin plate on the face it hangs from" {
    const north = Block.wall_sign.selectionBounds(2);
    try std.testing.expectEqual(@as(f32, 1.0 - 2.0 / 16.0), north.min[2]);
    try std.testing.expectEqual(@as(f32, 9.0 / 32.0), north.min[1]);
    try std.testing.expectEqual(@as(f32, 25.0 / 32.0), north.max[1]);

    const west = Block.wall_sign.selectionBounds(5);
    try std.testing.expectEqual(@as(f32, 2.0 / 16.0), west.max[0]);

    const post = Block.sign_post.selectionBounds(0);
    try std.testing.expectEqual(@as(f32, 0.25), post.min[0]);
    try std.testing.expectEqual(@as(f32, 0.75), post.max[2]);
    try std.testing.expectEqual(@as(f32, 1.0), post.max[1]);
}

test "dust, levers and repeaters lie flat as items where buttons and plates stay solid" {
    try std.testing.expectEqual(wire_cross_tile, Block.redstone_wire.flatItemTile(0).?);
    try std.testing.expectEqual(lever_tile, Block.lever.flatItemTile(0).?);
    try std.testing.expectEqual(torch_redstone_on_tile, Block.torch_redstone_on.flatItemTile(0).?);
    try std.testing.expectEqual(torch_redstone_off_tile, Block.repeater_off.flatItemTile(0).?);

    try std.testing.expectEqual(@as(?u8, null), Block.button.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, null), Block.pressure_plate_stone.flatItemTile(0));
}

test "every constant block fact reaches its caller through the registry table" {
    try std.testing.expectEqual(Material.rock, Block.stone.material());
    try std.testing.expectEqual(@as(f32, 1.5), Block.stone.hardness());
    try std.testing.expectEqual(@as(u8, 1), Block.stone.faceTextures().get(.up));
    try std.testing.expectEqual(Shape.cross, Block.rose.shape());
    try std.testing.expectEqual(@as(f32, 0.5), Block.slab.shape().heightScale());
    try std.testing.expectEqual(@as(u32, 5), Block.stationary_water.tickRate());
    try std.testing.expectEqual(@as(u32, 3), Block.sand.tickRate());
    try std.testing.expectEqual(@as(f32, 1.0 / 16.0), Block.cactus.sideInset());
    try std.testing.expect(!Block.glass.isOpaqueCube());
    try std.testing.expect(Block.glass.isBreakable());
    try std.testing.expect(Block.stationary_water.isTranslucent());
    try std.testing.expect(Block.gravel.isFalling());
    try std.testing.expect(Block.piston_sticky.isPistonBase());
    try std.testing.expect(Block.snow_layer.isReplaceable());
    try std.testing.expectEqualStrings("Obsidian", Block.obsidian.displayName(0));
    try std.testing.expectEqual(@as(usize, 2), Block.stairs_wood.itemRenderBoxes().len);
}

test "explosion resistance follows the hardness unless the block set one of its own" {
    try std.testing.expectEqual(@as(f32, 0.5), Block.dirt.explosionResistance());
    try std.testing.expectEqual(@as(f32, 2.0), Block.log.explosionResistance());
    try std.testing.expectEqual(@as(f32, 6.0), Block.stone.explosionResistance());
    try std.testing.expectEqual(@as(f32, 6.0), Block.cobblestone.explosionResistance());
    try std.testing.expectEqual(@as(f32, 3.0), Block.planks.explosionResistance());
    try std.testing.expectEqual(@as(f32, 1200.0), Block.obsidian.explosionResistance());
    try std.testing.expectEqual(@as(f32, 3600000.0), Block.bedrock.explosionResistance());

    try std.testing.expectEqual(@as(f32, 0.0), Block.portal.explosionResistance());
    try std.testing.expectEqual(@as(f32, 0.0), Block.piston_moving.explosionResistance());
}

test "a stair block resists like the block it is cut from" {
    try std.testing.expectEqual(Block.cobblestone.explosionResistance(), Block.stairs_cobblestone.explosionResistance());
    try std.testing.expectEqual(Block.planks.explosionResistance(), Block.stairs_wood.explosionResistance());
}

test "an id no vanilla block claims falls back to the empty definition" {
    const unclaimed: Block = @enumFromInt(100);
    try std.testing.expectEqual(Material.rock, unclaimed.material());
    try std.testing.expectEqual(Shape.cube, unclaimed.shape());
    try std.testing.expectEqual(@as(f32, 0.0), unclaimed.hardness());
    try std.testing.expectEqual(@as(u32, 0), unclaimed.tickRate());
    try std.testing.expect(unclaimed.isOpaqueCube());
    try std.testing.expect(!unclaimed.isReplaceable());
    try std.testing.expectEqualStrings("", unclaimed.displayName(0));
}

test "registering over an unclaimed id changes what every caller sees" {
    const custom: Block = @enumFromInt(101);
    const restore = custom.def().*;
    defer custom.register(restore);

    custom.register(.{
        .name = "Rose Quartz",
        .material = .glass,
        .shape = .{ .partial = 0.25 },
        .face_textures = uniform(9),
        .hardness = 2.5,
        .opaque_cube = false,
        .translucent = true,
    });

    try std.testing.expectEqualStrings("Rose Quartz", custom.displayName(0));
    try std.testing.expectEqual(@as(f32, 0.25), custom.heightScale());
    try std.testing.expectEqual(@as(u8, 9), custom.faceTextures().get(.north));
    try std.testing.expect(custom.isTranslucent());
    try std.testing.expect(!custom.isOpaqueCube());
    try std.testing.expect(!custom.isNormalCube());
    try std.testing.expect(custom.isSolid());
    try std.testing.expectEqual(1.0 / 2.5 / 30.0, custom.strength(null, 1.0));
}

test "a rail's inventory icon is its flat sprite, not a cube" {
    try std.testing.expectEqual(@as(?u8, rail_straight_tile), Block.rail.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, rail_powered_off_tile), Block.rail_powered.flatItemTile(0));
    try std.testing.expectEqual(@as(?u8, rail_detector_tile), Block.rail_detector.flatItemTile(0));
    try std.testing.expect(Block.stone.flatItemTile(0) == null);
}

test "registry keys come straight off the enum tags, so they cannot drift" {
    try std.testing.expectEqualStrings("stone", Block.stone.def().key);
    try std.testing.expectEqualStrings("torch_redstone_on", Block.torch_redstone_on.def().key);
    try std.testing.expectEqual(Block.obsidian, Block.fromKey("obsidian").?);
    try std.testing.expect(Block.fromKey("nothing_of_the_sort") == null);
    try std.testing.expect(Block.fromKey("") == null);

    try std.testing.expect(Block.stone.isVanilla());
    try std.testing.expect(!(@as(Block, @enumFromInt(200))).isVanilla());
    try std.testing.expect(!(@as(Block, @enumFromInt(97))).isVanilla());
}

test "a registered block answers to its own key without shadowing a vanilla one" {
    defer Block.resetRegistry();

    const custom: Block = @enumFromInt(200);
    custom.register(.{ .key = "rosebed:quartz", .name = "Rose Quartz" });

    try std.testing.expectEqual(custom, Block.fromKey("rosebed:quartz").?);
    try std.testing.expectEqual(Block.stone, Block.fromKey("stone").?);
    try std.testing.expect(!custom.isVanilla());
}

test "a key is read against the namespace the saved number came from" {
    for ([_][]const u8{ "brick", "cake", "bed", "reed", "door_wood", "door_iron" }) |name| {
        const as_block = Id.resolve(45, name).?;
        const as_item = Id.resolve(336, name).?;
        try std.testing.expect(as_block == .block);
        try std.testing.expect(as_item == .item);
        try std.testing.expectEqualStrings(name, as_block.key());
        try std.testing.expectEqualStrings(name, as_item.key());
    }
}

test "a key that moved id comes back at the id it holds now" {
    defer Block.resetRegistry();
    defer Item.resetRegistry();

    (@as(Block, @enumFromInt(213))).register(.{ .key = "rosebed:quartz" });
    (@as(Item, @enumFromInt(500))).register(.{ .key = "rosebed:quartz_pickaxe" });

    try std.testing.expectEqual(@as(Block, @enumFromInt(213)), Id.resolve(200, "rosebed:quartz").?.block);
    try std.testing.expectEqual(@as(Item, @enumFromInt(500)), Id.resolve(400, "rosebed:quartz_pickaxe").?.item);
}

fn quartzDrop(_: Block, meta: u4, _: *JavaRandom) ?Stack {
    return .{ .id = .{ .item = .diamond }, .count = 1, .meta = meta };
}

fn quartzBounds(_: Block, meta: u4) Bounds {
    const height: f32 = @as(f32, @floatFromInt(meta)) / 16.0;
    return .{ .min = .{ 0, 0, 0 }, .max = .{ 1, height, 1 } };
}

fn quartzSprite(_: Block, meta: u4) u8 {
    return 40 + @as(u8, meta);
}

fn quartzName(_: Block, meta: u4) []const u8 {
    return if (meta == 0) "Rose Quartz" else "Cracked Rose Quartz";
}

test "a registered block's metadata hooks answer in place of the vanilla switch" {
    defer Block.resetRegistry();
    var rand = JavaRandom.init(0);

    const custom: Block = @enumFromInt(200);
    custom.register(.{
        .key = "rosebed:quartz",
        .name = "Rose Quartz",
        .drop = quartzDrop,
        .selection_bounds = quartzBounds,
        .cross_tile = quartzSprite,
        .display_name = quartzName,
    });

    try std.testing.expectEqual(Id{ .item = .diamond }, custom.drop(3, &rand).?.id);
    try std.testing.expectEqual(@as(u16, 3), custom.drop(3, &rand).?.meta);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), custom.selectionBounds(8).max[1], 1.0e-6);
    try std.testing.expectEqual(@as(u8, 42), custom.crossTile(2));
    try std.testing.expectEqualStrings("Cracked Rose Quartz", custom.displayName(1));
    try std.testing.expectEqualStrings("Rose Quartz", custom.displayName(0));
}

test "a vanilla block ignores the hooks entirely and keeps its own switch" {
    var rand = JavaRandom.init(0);
    try std.testing.expectEqual(Id{ .block = .cobblestone }, Block.stone.drop(0, &rand).?.id);
    try std.testing.expectEqual(@as(u8, 12), Block.rose.crossTile(0));
    try std.testing.expectEqualStrings("Obsidian", Block.obsidian.displayName(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), Block.slab.selectionBounds(0).max[1], 1.0e-6);
}

test "a registered sprite with no tile hook draws its own texture, not tile zero" {
    defer Block.resetRegistry();

    const custom: Block = @enumFromInt(201);
    custom.register(.{
        .key = "rosebed:fern",
        .shape = .cross,
        .face_textures = uniform(77),
    });

    try std.testing.expectEqual(@as(u8, 77), custom.crossTile(0));
    try std.testing.expectEqual(@as(u8, 77), custom.particleTile(0));
    try std.testing.expectEqual(@as(u8, 77), custom.flatItemTile(0).?);
}

test "a registered block with no drop hook drops itself, as the vanilla fallthrough does" {
    defer Block.resetRegistry();
    var rand = JavaRandom.init(0);

    const custom: Block = @enumFromInt(202);
    custom.register(.{ .key = "rosebed:marble" });

    try std.testing.expectEqual(Id{ .block = custom }, custom.drop(0, &rand).?.id);
}

test "a portal cannot be broken, dropped, walked into or seen through as a solid" {
    var rand = JavaRandom.init(0);

    try std.testing.expectEqual(Material.portal, Block.portal.material());
    try std.testing.expect(Block.portal.isUnbreakable());
    try std.testing.expect(!Block.portal.hasCollision());
    try std.testing.expect(!Block.portal.isOpaque());
    try std.testing.expect(!Block.portal.isOpaqueCube());
    try std.testing.expect(Block.portal.isTranslucent());
    try std.testing.expect(Block.portal.drop(0, &rand) == null);
    try std.testing.expectEqualStrings("Portal", Block.portal.displayName(0));
}

test "a portal is a thin sheet across whichever axis its neighbours run along" {
    const across_z = portalBounds(false);
    try std.testing.expectEqual(@as(f32, 0.5 - portal_thickness), across_z.min[0]);
    try std.testing.expectEqual(@as(f32, 0.5 + portal_thickness), across_z.max[0]);
    try std.testing.expectEqual(@as(f32, 0.0), across_z.min[2]);
    try std.testing.expectEqual(@as(f32, 1.0), across_z.max[2]);

    const across_x = portalBounds(true);
    try std.testing.expectEqual(@as(f32, 0.0), across_x.min[0]);
    try std.testing.expectEqual(@as(f32, 1.0), across_x.max[0]);
    try std.testing.expectEqual(@as(f32, 0.5 - portal_thickness), across_x.min[2]);
    try std.testing.expectEqual(@as(f32, 0.5 + portal_thickness), across_x.max[2]);

    for ([_]Bounds{ across_x, across_z }) |shape| {
        try std.testing.expectEqual(@as(f32, 0.0), shape.min[1]);
        try std.testing.expectEqual(@as(f32, 1.0), shape.max[1]);
    }
}
