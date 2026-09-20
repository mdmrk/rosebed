const std = @import("std");

const assets = @import("assets");
const math = @import("math");
const world = @import("world");
const BlockPos = world.BlockPos;

const Entities = @import("Entities.zig");
const Entity = @import("Entity.zig");
const Animal = @import("entity/Animal.zig");
const Minecart = @import("entity/Minecart.zig");
const Painting = @import("entity/Painting.zig");
const Pig = @import("entity/Pig.zig");
const Sheep = @import("entity/Sheep.zig");
const Thrown = @import("entity/Thrown.zig");
const Wolf = @import("entity/Wolf.zig");
const Inventory = @import("Inventory.zig");
const Level = @import("Level.zig");
const Player = @import("Player.zig");
const raycast = @import("raycast.zig");
const stats = @import("stats.zig");

pub const reach_distance = 4.5;
pub const boat_reach = 5.0;
pub const bucket_reach = 5.0;

pub const Context = struct {
    gpa: std.mem.Allocator,
    frame: std.mem.Allocator,
    level: *Level,
    player: *Player,
    stats: *stats.Stats,
    dimension: world.Dimension,

    pub fn applyBlockChanges(ctx: Context) !void {
        try ctx.level.applyBlockChanges(ctx.gpa, ctx.frame);
    }

    pub fn pickedBlock(ctx: Context) ?raycast.Hit {
        return raycast.cast(
            &ctx.level.world_map,
            ctx.player.eyePosition(),
            ctx.player.lookVector(),
            reach_distance,
        );
    }

    pub fn pickedEntity(ctx: Context, roster: []const *Player) ?Entities.Target {
        var reach: f64 = reach_distance;
        if (ctx.pickedBlock()) |hit| {
            reach = hit.distance;
        }
        reach = @min(reach, Entities.entity_reach);
        return ctx.level.entities.pick(ctx.player.eyePosition(), ctx.player.lookVector(), reach, roster);
    }

    pub fn consumeSelectedStack(ctx: Context) void {
        const slot = &ctx.player.inventory.slots[ctx.player.inventory.selected];
        if (slot.*) |*stack| {
            stack.count -= 1;
            if (stack.count == 0) slot.* = null;
        }
    }

    pub fn damageHeldItem(ctx: Context, cost: u16) !void {
        if (cost == 0) return;

        const slot = &ctx.player.inventory.slots[ctx.player.inventory.selected];
        if (slot.*) |*stack| {
            try ctx.stats.use(ctx.gpa, stack.id);
            stack.damage(cost);
            if (stack.count == 0) {
                try ctx.stats.deplete(ctx.gpa, stack.id);
                slot.* = null;
            }
        }
    }

    pub fn wearHeldItem(ctx: Context, destroyed: world.Block) !void {
        const stack = ctx.player.inventory.selectedStack() orelse return;
        const cost = switch (stack.id) {
            .block => return,
            .item => |id| id.blockDestroyedCost(destroyed),
        };
        try ctx.damageHeldItem(cost);
    }

    pub fn spawnDroppedItem(ctx: Context, pos: BlockPos, stack: Inventory.ItemStack) !void {
        try ctx.level.dropStackAt(ctx.gpa, pos, stack);
    }

    pub fn holdStack(ctx: Context, held: world.Item) void {
        ctx.player.inventory.slots[ctx.player.inventory.selected] =
            .{ .id = .{ .item = held }, .count = 1 };
    }

    pub fn dismount(ctx: Context) void {
        const mount = ctx.player.riding;
        ctx.player.riding = Entity.no_id;
        if (mount == Entity.no_id) return;

        const base: ?Entity = blk: {
            if (ctx.level.entities.minecartById(mount)) |cart| {
                cart.rider = Entity.no_id;
                break :blk cart.base;
            }
            if (ctx.level.entities.boatById(mount)) |boat| break :blk boat.base;
            if (ctx.level.entities.mobById(mount)) |entry| break :blk entry.animal.base;
            break :blk null;
        };

        const stood_on = base orelse return;
        ctx.player.base.position = Entity.dismountPosition(stood_on);
        ctx.player.base.prev_position = ctx.player.base.position;
    }
};

pub const Broken = struct {
    block: world.Block,
    meta: u4,
    harvested: bool,
    lit_tnt: bool,
};

pub var on_block_broken: ?*const fn (*Level, BlockPos, world.Block, u4) void = null;

pub fn breakBlockAt(
    gpa: std.mem.Allocator,
    level: *Level,
    held: ?Inventory.ItemStack,
    pos: BlockPos,
) !?Broken {
    const block = level.world_map.getBlock(pos);
    if (block == .air) return null;

    const meta = level.world_map.getBlockMetadata(pos);
    const broken: Broken = .{
        .block = block,
        .meta = meta,
        .harvested = block.harvestableWith(held),
        .lit_tnt = block == .tnt and world.tnt.isLit(meta),
    };

    try level.world_map.setBlockWithNotify(pos, .air);
    if (broken.lit_tnt) try world.tnt.primeByPlayer(&level.world_map, pos);
    try spillContainers(gpa, level, pos);
    _ = level.world_map.removeSign(pos);
    _ = level.world_map.removeNote(pos);

    if (broken.harvested and !broken.lit_tnt) {
        if (block.harvestDrop(meta, held, &level.world_map.rand)) |dropped| {
            try level.dropStackAt(gpa, pos, .{ .id = dropped.id, .count = dropped.count, .meta = dropped.meta });
        }
        var extra: [3]world.block.Stack = undefined;
        for (block.bonusDrops(meta, &level.world_map.rand, &extra)) |dropped| {
            try level.dropStackAt(gpa, pos, .{ .id = dropped.id, .count = dropped.count, .meta = dropped.meta });
        }
    }

    if (on_block_broken) |hook| hook(level, pos, block, meta);
    return broken;
}

pub var on_block_placed: ?*const fn (*Level, BlockPos, world.Block, u4) void = null;

pub fn placeBlockAt(
    level: *Level,
    player: *const Player,
    placed: world.Block,
    stack_meta: u4,
    target: world.block_update.Placement,
) !bool {
    if (target.pos.y < 0 or target.pos.y >= world.Chunk.height) return false;
    if (!level.world_map.getBlock(target.pos).isReplaceable()) return false;
    if (!world.block_update.canPlaceOnSide(&level.world_map, target.pos, placed, target.face)) return false;
    if (placed == .chest and !level.world_map.canPlaceChestAt(target.pos)) return false;

    const meta = world.block_update.placementMetadata(
        &level.world_map,
        target.pos,
        placed,
        target.face,
        stack_meta,
    );
    try level.world_map.setBlockAndMetadataWithNotify(target.pos, placed, meta);

    const step_sound = placed.stepSound();
    level.world_map.playSoundEffect(
        target.pos.center(),
        step_sound.walk(),
        (step_sound.volume() + 1.0) / 2.0,
        step_sound.pitch() * 0.8,
    );

    if (placed == .furnace) {
        const facing = world.block.furnaceFacingFromYaw(player.yaw);
        try level.world_map.setBlockMetadataWithNotify(target.pos, facing);
        _ = try level.world_map.addFurnace(target.pos);
    }
    if (placed == .chest) _ = try level.world_map.addChest(target.pos);
    if (placed == .dispenser) {
        const facing = world.block.dispenserFacingFromYaw(player.yaw);
        try level.world_map.setBlockMetadataWithNotify(target.pos, facing);
        _ = try level.world_map.addDispenser(target.pos);
    }
    if (placed.isStairs()) {
        const facing = world.block.stairsFacingFromYaw(player.yaw);
        try level.world_map.setBlockMetadataWithNotify(target.pos, facing);
    }
    if (placed == .pumpkin or placed == .jack_o_lantern) {
        const facing = world.block.pumpkinFacingFromYaw(player.yaw);
        try level.world_map.setBlockMetadataWithNotify(target.pos, facing);
    }
    try world.redstone.onBlockPlaced(
        &level.world_map,
        target.pos,
        placed,
        player.base.position,
        player.yaw,
    );

    const settled = level.world_map.getBlockMetadata(target.pos);
    _ = try world.block_update.mergeSlabBelow(&level.world_map, target.pos);

    if (on_block_placed) |hook| hook(level, target.pos, placed, settled);
    return true;
}

fn spillContainers(gpa: std.mem.Allocator, level: *Level, pos: BlockPos) !void {
    if (level.world_map.removeFurnace(pos)) |taken| {
        var removed = taken;
        for (0..world.furnace.slot_count) |index| {
            const stack = removed.slot(index).* orelse continue;
            try level.dropStackAt(gpa, pos, stack);
        }
    }
    if (level.world_map.removeDispenser(pos)) |taken| {
        var removed = taken;
        for (0..world.dispenser.slot_count) |index| {
            const stack = removed.slot(index).* orelse continue;
            try level.dropStackAt(gpa, pos, stack);
        }
    }
    if (level.world_map.removeJukebox(pos)) |removed| {
        if (removed.record) |record| {
            try level.entities.ejectRecord(gpa, pos, .{ .id = .{ .item = record }, .count = 1 }, &level.world_map.rand);
        }
    }
}

pub fn ejectJukeboxRecord(ctx: Context, pos: BlockPos) !bool {
    if (ctx.level.world_map.getBlockMetadata(pos) == 0) return false;

    const taken = try world.jukebox.takeRecord(&ctx.level.world_map, pos);
    const record = taken orelse return true;
    try ctx.level.entities.ejectRecord(
        ctx.gpa,
        pos,
        .{ .id = .{ .item = record }, .count = 1 },
        &ctx.level.world_map.rand,
    );
    try ctx.applyBlockChanges();
    return true;
}

pub fn lightRedstoneOre(ctx: Context, pos: BlockPos) !void {
    try ctx.level.entities.spawnRedstoneOreParticles(
        ctx.gpa,
        &ctx.level.world_map,
        pos,
        &ctx.level.world_map.rand,
    );
    try world.redstone.lightRedstoneOre(&ctx.level.world_map, pos);
    try ctx.applyBlockChanges();
}

pub fn eatCakeSlice(ctx: Context, pos: BlockPos) !void {
    if (ctx.player.health >= 20) return;
    ctx.player.heal(3);

    const eaten = ctx.level.world_map.getBlockMetadata(pos) + 1;
    if (eaten >= world.block.cake_slices) {
        try ctx.level.world_map.setBlockWithNotify(pos, .air);
    } else {
        try ctx.level.world_map.setBlockMetadataWithNotify(pos, @intCast(eaten));
    }
    try ctx.applyBlockChanges();
}

pub fn breakPainting(ctx: Context, id: Entity.Id) !void {
    const painting = ctx.level.entities.removePainting(id) orelse return;
    try ctx.level.entities.dropStackAt(
        ctx.gpa,
        painting.position,
        .{ .id = .{ .item = .painting }, .count = 1 },
        &ctx.level.world_map.rand,
    );
}

pub fn hangPaintingAtTarget(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;

    const direction = Painting.directionFromFace(hit.face) orelse return false;
    const hung = Painting.pickArt(
        .{ hit.pos.x, hit.pos.y, hit.pos.z },
        direction,
        &ctx.level.world_map,
        ctx.level.entities.paintings.items,
        &ctx.level.world_map.rand,
    ) orelse return true;

    try ctx.level.entities.spawnPainting(ctx.gpa, hung);
    try ctx.stats.use(ctx.gpa, .{ .item = .painting });
    ctx.consumeSelectedStack();
    return true;
}

pub fn useHeldItem(ctx: Context) !void {
    const held: ?world.Item = switch ((ctx.player.inventory.selectedStack() orelse return).id) {
        .item => |id| id,
        .block => null,
    };
    const item = held orelse return;
    if (item.healAmount()) |amount| {
        eatHeldFood(ctx, item, amount);
        return;
    }
    if (Entities.thrownKind(item)) |kind| return throwHeld(ctx, kind);
    if (item != .bow) return;
    if (!ctx.player.inventory.consumeItem(.{ .item = .arrow })) return;

    const at = ctx.player.eyePosition();
    ctx.level.world_map.playSoundEffect(
        at,
        assets.sounds.random.bow,
        bow_volume,
        bowPitch(&ctx.level.world_map.rand),
    );
    try ctx.level.entities.shootArrow(ctx.gpa, ctx.player, &ctx.level.world_map.rand);
    try ctx.stats.use(ctx.gpa, .{ .item = .bow });
}

const bow_volume: f32 = 1.0;
const throw_volume: f32 = 0.5;

fn bowPitch(rand: *world.JavaRandom) f32 {
    return 1.0 / (rand.nextFloat() * 0.4 + 0.8);
}

fn throwPitch(rand: *world.JavaRandom) f32 {
    return 0.4 / (rand.nextFloat() * 0.4 + 0.8);
}

pub fn throwHeld(ctx: Context, kind: Thrown.Kind) !void {
    ctx.consumeSelectedStack();

    const rand = &ctx.level.world_map.rand;
    const at = ctx.player.eyePosition();
    ctx.level.world_map.playSoundEffect(
        at,
        assets.sounds.random.bow,
        throw_volume,
        throwPitch(rand),
    );

    try ctx.level.entities.throwItem(ctx.gpa, kind, ctx.player, rand);
    try ctx.stats.use(ctx.gpa, .{ .item = kind.item() });
}

pub fn eatHeldFood(ctx: Context, held: world.Item, heal_amount: u8) void {
    ctx.player.heal(heal_amount);
    ctx.consumeSelectedStack();
    if (held == .mushroom_stew) ctx.holdStack(.bowl);
}

pub fn interactWithPig(ctx: Context, animal: *Animal, held: ?world.Item) !bool {
    const pig: *Pig = @fieldParentPtr("animal", animal);
    if (pig.saddled) {
        ctx.player.riding = animal.base.id;
        return true;
    }

    if ((held orelse return false) != .saddle) return false;
    pig.saddled = true;
    try ctx.stats.use(ctx.gpa, .{ .item = .saddle });
    ctx.consumeSelectedStack();
    return true;
}

pub fn interactWithSheep(ctx: Context, animal: *Animal, held: ?world.Item) !bool {
    if ((held orelse return false) != .shears) return false;

    const sheep: *Sheep = @fieldParentPtr("animal", animal);
    const drops = sheep.shear(&ctx.level.world_map.rand) orelse return false;
    try ctx.level.entities.dropShearedWool(
        ctx.gpa,
        sheep,
        drops,
        &ctx.level.world_map.rand,
    );
    try ctx.damageHeldItem(1);
    return true;
}

pub fn interactWithWolf(ctx: Context, animal: *Animal, held: ?world.Item) !bool {
    const wolf: *Wolf = @fieldParentPtr("animal", animal);
    const used = wolf.interactWith(ctx.gpa, Entities.viewOf(ctx.player), held, &ctx.level.world_map.rand) orelse return false;

    switch (used) {
        .tamed, .refused => {
            ctx.consumeSelectedStack();
            try ctx.level.entities.spawnTreatReaction(
                ctx.gpa,
                wolf.animal,
                used == .tamed,
                &ctx.level.world_map.rand,
            );
            try ctx.stats.use(ctx.gpa, .{ .item = .bone });
        },
        .fed => {
            ctx.consumeSelectedStack();
            try ctx.stats.use(ctx.gpa, .{ .item = held.? });
        },
        .sat, .stood => {},
    }
    return true;
}

pub fn strikeFlintAtTarget(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;

    const target = world.block_update.placementTarget(&ctx.level.world_map, hit.pos, hit.face);
    if (target.pos.y < 0 or target.pos.y >= world.Chunk.height) return false;

    if (ctx.level.world_map.getBlock(target.pos) == .air) {
        ctx.level.world_map.playIgniteAt(target.pos);
        try ctx.level.world_map.setBlockWithNotify(target.pos, .fire);
        try ctx.applyBlockChanges();
    }

    try ctx.damageHeldItem(1);
    return true;
}

pub fn useBucket(ctx: Context, held: world.Item, fill: world.item.Fill) !bool {
    const hit = raycast.castWith(
        &ctx.level.world_map,
        ctx.player.eyePosition(),
        ctx.player.lookVector(),
        bucket_reach,
        fill == .empty,
    ) orelse return false;

    switch (fill) {
        .empty => {
            const scooped = try world.block_update.scoopLiquid(&ctx.level.world_map, hit.pos) orelse return false;
            ctx.holdStack(scooped.bucketItem());
        },
        .milk => ctx.holdStack(.bucket),
        .water, .lava => {
            const step = hit.face.step();
            const px = hit.pos.x + step[0];
            const py = hit.pos.y + step[1];
            const pz = hit.pos.z + step[2];
            if (!try world.block_update.pourLiquid(&ctx.level.world_map, .init(px, py, pz), fill)) return false;
            ctx.holdStack(.bucket);
        },
    }

    try ctx.stats.use(ctx.gpa, .{ .item = held });
    try ctx.applyBlockChanges();
    return true;
}

pub fn tillWithHoe(ctx: Context, held: world.Item) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!try world.farming.till(&ctx.level.world_map, hit.pos, hit.face)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = held });
    try ctx.damageHeldItem(1);
    try ctx.applyBlockChanges();
    return true;
}

pub fn applyBoneMeal(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!try world.farming.applyBoneMeal(&ctx.level.world_map, hit.pos)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = .dye });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn plantSeedsAtTarget(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!try world.farming.plant(&ctx.level.world_map, hit.pos, hit.face)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = .seeds });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn placeDoorAtTarget(ctx: Context, held: world.Item) !bool {
    const placed: world.Block = switch (held) {
        .door_wood => .door_wood,
        .door_iron => .door_iron,
        else => return false,
    };
    const hit = ctx.pickedBlock() orelse return false;
    if (hit.face != .up) return false;
    if (!try world.block_update.placeDoor(&ctx.level.world_map, hit.pos.offset(0, 1, 0), placed, ctx.player.yaw)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = held });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn placeBedAtTarget(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (hit.face != .up) return false;
    if (!try world.block_update.placeBed(&ctx.level.world_map, hit.pos.offset(0, 1, 0), ctx.player.yaw)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = .bed });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn insertRecordAtTarget(ctx: Context, record: world.Item) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (ctx.level.world_map.getBlock(hit.pos) != .jukebox) return false;
    if (ctx.level.world_map.getBlockMetadata(hit.pos) != 0) return false;

    try world.jukebox.insertRecord(&ctx.level.world_map, hit.pos, record);
    try ctx.stats.use(ctx.gpa, .{ .item = record });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn placeBoatAtTarget(ctx: Context) !bool {
    const hit = raycast.castWith(
        &ctx.level.world_map,
        ctx.player.eyePosition(),
        ctx.player.lookVector(),
        boat_reach,
        true,
    ) orelse return false;

    const on_snow = ctx.level.world_map.getBlock(hit.pos) == .snow_layer;
    const floor = if (on_snow) hit.pos.y - 1 else hit.pos.y;

    _ = try ctx.level.entities.spawnBoat(ctx.gpa, math.Vec3.init(
        @as(f64, @floatFromInt(hit.pos.x)) + 0.5,
        @as(f64, @floatFromInt(floor)) + 1.0,
        @as(f64, @floatFromInt(hit.pos.z)) + 0.5,
    ));
    try ctx.stats.use(ctx.gpa, .{ .item = .boat });
    ctx.consumeSelectedStack();
    return true;
}

pub fn placeMinecartAtTarget(ctx: Context, kind: Minecart.Kind) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!world.block.isRail(ctx.level.world_map.getBlock(hit.pos))) return false;

    _ = try ctx.level.entities.spawnMinecart(ctx.gpa, hit.pos.center(), kind);
    try ctx.stats.use(ctx.gpa, ctx.player.inventory.selectedStack().?.id);
    ctx.consumeSelectedStack();
    return true;
}

const BowSound = struct {
    key: []const u8 = "",
    volume: f32 = 0,
    pitch: f32 = 0,
    count: usize = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: math.Vec3, volume: f32, pitch: f32) void {
        const self: *BowSound = @ptrCast(@alignCast(context));
        self.key = sound.key;
        self.volume = volume;
        self.pitch = pitch;
        self.count += 1;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: BlockPos) void {}

    fn sink(self: *BowSound) world.World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }
};

test "loosing an arrow from a bow twangs it" {
    const gpa = std.testing.allocator;

    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    defer level.deinit(gpa);
    level.attach();
    _ = try level.world_map.createChunk(0, 0);

    var heard: BowSound = .{};
    level.world_map.sound_sink = heard.sink();

    var tally: stats.Stats = .{};
    defer tally.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 40, 8));
    try level.enter(gpa, &player);
    player.inventory.slots[player.inventory.selected] = .{ .id = .{ .item = .bow }, .count = 1 };
    player.inventory.slots[1] = .{ .id = .{ .item = .arrow }, .count = 2 };

    try useHeldItem(.{
        .gpa = gpa,
        .frame = gpa,
        .level = &level,
        .player = &player,
        .stats = &tally,
        .dimension = .overworld,
    });

    try std.testing.expectEqual(@as(usize, 1), level.entities.arrows.items.len);
    try std.testing.expectEqual(@as(u8, 1), player.inventory.slots[1].?.count);
    try std.testing.expectEqual(@as(usize, 1), heard.count);
    try std.testing.expectEqualStrings(assets.sounds.random.bow.key, heard.key);
    try std.testing.expectEqual(bow_volume, heard.volume);
    try std.testing.expect(heard.pitch >= 1.0 / 1.2 and heard.pitch <= 1.0 / 0.8);
}

test "right-clicking a held snowball throws it" {
    const gpa = std.testing.allocator;

    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    defer level.deinit(gpa);
    level.attach();
    _ = try level.world_map.createChunk(0, 0);

    var tally: stats.Stats = .{};
    defer tally.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 40, 8));
    try level.enter(gpa, &player);
    player.inventory.slots[player.inventory.selected] = .{ .id = .{ .item = .snowball }, .count = 3 };

    try useHeldItem(.{
        .gpa = gpa,
        .frame = gpa,
        .level = &level,
        .player = &player,
        .stats = &tally,
        .dimension = .overworld,
    });

    try std.testing.expectEqual(@as(usize, 1), level.entities.thrown.items.len);
    try std.testing.expectEqual(Thrown.Kind.snowball, level.entities.thrown.items[0].kind);
    try std.testing.expectEqual(@as(u8, 2), player.inventory.slots[player.inventory.selected].?.count);
}

test "a boat aimed at open water lands on the surface, not the seabed" {
    const gpa = std.testing.allocator;

    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    defer level.deinit(gpa);
    level.attach();
    _ = try level.world_map.createChunk(0, 0);
    level.world_map.setBlock(.init(8, 7, 8), .stone);
    level.world_map.setBlock(.init(8, 8, 8), .stationary_water);

    var tally: stats.Stats = .{};
    defer tally.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8.5, 10.5, 8.5));
    player.pitch = 90;
    try level.enter(gpa, &player);
    player.inventory.slots[player.inventory.selected] = .{ .id = .{ .item = .boat }, .count = 1 };

    try std.testing.expect(try placeBoatAtTarget(.{
        .gpa = gpa,
        .frame = gpa,
        .level = &level,
        .player = &player,
        .stats = &tally,
        .dimension = .overworld,
    }));

    try std.testing.expectEqual(@as(usize, 1), level.entities.boats.items.len);
    const boat = level.entities.boats.items[0];
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), boat.base.position.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), boat.base.position.x, 1.0e-9);
    try std.testing.expect(player.inventory.slots[player.inventory.selected] == null);
}

var broken_seen: usize = 0;
var broken_last: struct { pos: BlockPos, block: world.Block, meta: u4 } = undefined;

fn recordBroken(_: *Level, pos: BlockPos, block: world.Block, meta: u4) void {
    broken_seen += 1;
    broken_last = .{ .pos = pos, .block = block, .meta = meta };
}

test "breaking a block reports it once, after the world already lost it" {
    const gpa = std.testing.allocator;
    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    defer level.deinit(gpa);
    _ = try level.world_map.createChunk(0, 0);

    broken_seen = 0;
    on_block_broken = recordBroken;
    defer on_block_broken = null;

    const pos: BlockPos = .init(2, 64, 2);
    try level.world_map.setBlockWithNotify(pos, .stone);
    level.world_map.setBlockMetadata(pos, 3);

    const held: Inventory.ItemStack = .{ .id = .{ .item = .pickaxe_stone }, .count = 1 };
    const broken = (try breakBlockAt(gpa, &level, held, pos)).?;

    try std.testing.expectEqual(@as(usize, 1), broken_seen);
    try std.testing.expectEqual(world.Block.stone, broken_last.block);
    try std.testing.expectEqual(@as(u4, 3), broken_last.meta);
    try std.testing.expectEqual(pos, broken_last.pos);
    try std.testing.expect(broken.harvested);
    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(pos));
}

var placed_seen: usize = 0;
var placed_last: struct { pos: BlockPos, block: world.Block, meta: u4 } = undefined;

fn recordPlaced(_: *Level, pos: BlockPos, block: world.Block, meta: u4) void {
    placed_seen += 1;
    placed_last = .{ .pos = pos, .block = block, .meta = meta };
}

fn floorLevel(gpa: std.mem.Allocator, at: BlockPos) !Level {
    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    errdefer level.deinit(gpa);
    _ = try level.world_map.createChunk(0, 0);
    try level.world_map.setBlockWithNotify(at, .stone);
    return level;
}

test "a placed furnace is given its block entity and the facing the placer had" {
    const gpa = std.testing.allocator;
    const floor: BlockPos = .init(2, 64, 2);
    var level = try floorLevel(gpa, floor);
    defer level.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(2.5, 65, 2.5));
    player.yaw = 0;

    const target = world.block_update.placementTarget(&level.world_map, floor, .up);
    try std.testing.expect(try placeBlockAt(&level, &player, .furnace, 0, target));

    try std.testing.expectEqual(world.Block.furnace, level.world_map.getBlock(.init(2, 65, 2)));
    try std.testing.expect(level.world_map.furnaceAt(.init(2, 65, 2)) != null);
    try std.testing.expectEqual(
        world.block.furnaceFacingFromYaw(0),
        level.world_map.getBlockMetadata(.init(2, 65, 2)),
    );
}

test "a block with nothing to stand on is not placed" {
    const gpa = std.testing.allocator;
    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    defer level.deinit(gpa);
    _ = try level.world_map.createChunk(0, 0);

    var player = Player.spawn(math.Vec3.init(2.5, 65, 2.5));
    const target = world.block_update.placementTarget(&level.world_map, .init(2, 64, 2), .up);
    try std.testing.expect(!try placeBlockAt(&level, &player, .torch, 0, target));

    try std.testing.expectEqual(world.Block.air, level.world_map.getBlock(.init(2, 65, 2)));
}

test "placing a block reports the metadata it settled on" {
    const gpa = std.testing.allocator;
    const floor: BlockPos = .init(2, 64, 2);
    var level = try floorLevel(gpa, floor);
    defer level.deinit(gpa);

    placed_seen = 0;
    on_block_placed = recordPlaced;
    defer on_block_placed = null;

    var player = Player.spawn(math.Vec3.init(2.5, 65, 2.5));
    player.yaw = 0;

    const target = world.block_update.placementTarget(&level.world_map, floor, .up);
    try std.testing.expect(try placeBlockAt(&level, &player, .furnace, 0, target));

    try std.testing.expectEqual(@as(usize, 1), placed_seen);
    try std.testing.expectEqual(world.Block.furnace, placed_last.block);
    try std.testing.expectEqual(BlockPos.init(2, 65, 2), placed_last.pos);
    try std.testing.expectEqual(world.block.furnaceFacingFromYaw(0), placed_last.meta);
}

test "breaking air reports nothing and changes nothing" {
    const gpa = std.testing.allocator;
    var level = Level.init(gpa, try world.Generator.init(gpa, .overworld, 7));
    defer level.deinit(gpa);
    _ = try level.world_map.createChunk(0, 0);

    broken_seen = 0;
    on_block_broken = recordBroken;
    defer on_block_broken = null;

    try std.testing.expect(try breakBlockAt(gpa, &level, null, .init(2, 100, 2)) == null);
    try std.testing.expectEqual(@as(usize, 0), broken_seen);
}
