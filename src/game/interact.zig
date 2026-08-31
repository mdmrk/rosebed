const std = @import("std");

const assets = @import("assets");
const world = @import("world");

const Entities = @import("Entities.zig");
const Entity = @import("Entity.zig");
const Animal = @import("entity/Animal.zig");
const Minecart = @import("entity/Minecart.zig");
const Painting = @import("entity/Painting.zig");
const Pig = @import("entity/Pig.zig");
const Sheep = @import("entity/Sheep.zig");
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

    pub fn pickedEntity(ctx: Context) ?Entities.Target {
        var reach: f64 = reach_distance;
        if (ctx.pickedBlock()) |hit| {
            reach = hit.distance;
        }
        reach = @min(reach, Entities.entity_reach);
        return ctx.level.entities.pick(ctx.player.eyePosition(), ctx.player.lookVector(), reach);
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

    pub fn spawnDroppedItem(ctx: Context, x: i32, y: i32, z: i32, stack: Inventory.ItemStack) !void {
        try ctx.level.dropStackAt(ctx.gpa, x, y, z, stack);
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

pub fn ejectJukeboxRecord(ctx: Context, x: i32, y: i32, z: i32) !bool {
    if (ctx.level.world_map.getBlockMetadata(x, y, z) == 0) return false;

    const taken = try world.jukebox.takeRecord(&ctx.level.world_map, x, y, z);
    const record = taken orelse return true;
    try ctx.level.entities.ejectRecord(
        ctx.gpa,
        x,
        y,
        z,
        .{ .id = .{ .item = record }, .count = 1 },
        &ctx.level.world_map.rand,
    );
    try ctx.applyBlockChanges();
    return true;
}

pub fn lightRedstoneOre(ctx: Context, x: i32, y: i32, z: i32) !void {
    try ctx.level.entities.spawnRedstoneOreParticles(
        ctx.gpa,
        &ctx.level.world_map,
        x,
        y,
        z,
        &ctx.level.world_map.rand,
    );
    try world.redstone.lightRedstoneOre(&ctx.level.world_map, x, y, z);
    try ctx.applyBlockChanges();
}

pub fn eatCakeSlice(ctx: Context, x: i32, y: i32, z: i32) !void {
    if (ctx.player.health >= 20) return;
    ctx.player.heal(3);

    const eaten = ctx.level.world_map.getBlockMetadata(x, y, z) + 1;
    if (eaten >= world.block.cake_slices) {
        try ctx.level.world_map.setBlockWithNotify(x, y, z, .air);
    } else {
        try ctx.level.world_map.setBlockMetadataWithNotify(x, y, z, @intCast(eaten));
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
        .{ hit.x, hit.y, hit.z },
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
    if (item == .egg) return throwHeldEgg(ctx);
    if (item != .bow) return;
    if (!ctx.player.inventory.consumeItem(.{ .item = .arrow })) return;

    try ctx.level.entities.shootArrow(ctx.gpa, ctx.player, &ctx.level.world_map.rand);
    try ctx.stats.use(ctx.gpa, .{ .item = .bow });
}

const egg_throw_volume: f32 = 0.5;

fn eggThrowPitch(rand: *world.JavaRandom) f32 {
    return 0.4 / (rand.nextFloat() * 0.4 + 0.8);
}

pub fn throwHeldEgg(ctx: Context) !void {
    ctx.consumeSelectedStack();

    const rand = &ctx.level.world_map.rand;
    const at = ctx.player.eyePosition();
    ctx.level.world_map.playSoundEffect(
        at.x,
        at.y,
        at.z,
        assets.sounds.random.bow,
        egg_throw_volume,
        eggThrowPitch(rand),
    );

    try ctx.level.entities.throwEgg(ctx.gpa, ctx.player, rand);
    try ctx.stats.use(ctx.gpa, .{ .item = .egg });
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

    const target = world.block_update.placementTarget(&ctx.level.world_map, hit.x, hit.y, hit.z, hit.face);
    if (target.y < 0 or target.y >= world.Chunk.height) return false;

    if (ctx.level.world_map.getBlock(target.x, target.y, target.z) == .air) {
        ctx.level.world_map.playIgniteAt(target.x, target.y, target.z);
        try ctx.level.world_map.setBlockWithNotify(target.x, target.y, target.z, .fire);
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
            const scooped = try world.block_update.scoopLiquid(&ctx.level.world_map, hit.x, hit.y, hit.z) orelse return false;
            ctx.holdStack(scooped.bucketItem());
        },
        .milk => ctx.holdStack(.bucket),
        .water, .lava => {
            const step = hit.face.step();
            const px = hit.x + step[0];
            const py = hit.y + step[1];
            const pz = hit.z + step[2];
            if (!try world.block_update.pourLiquid(&ctx.level.world_map, px, py, pz, fill)) return false;
            ctx.holdStack(.bucket);
        },
    }

    try ctx.stats.use(ctx.gpa, .{ .item = held });
    try ctx.applyBlockChanges();
    return true;
}

pub fn tillWithHoe(ctx: Context, held: world.Item) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!try world.farming.till(&ctx.level.world_map, hit.x, hit.y, hit.z, hit.face)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = held });
    try ctx.damageHeldItem(1);
    try ctx.applyBlockChanges();
    return true;
}

pub fn plantSeedsAtTarget(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!try world.farming.plant(&ctx.level.world_map, hit.x, hit.y, hit.z, hit.face)) return false;

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
    if (!try world.block_update.placeDoor(&ctx.level.world_map, hit.x, hit.y + 1, hit.z, placed, ctx.player.yaw)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = held });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn placeBedAtTarget(ctx: Context) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (hit.face != .up) return false;
    if (!try world.block_update.placeBed(&ctx.level.world_map, hit.x, hit.y + 1, hit.z, ctx.player.yaw)) return false;

    try ctx.stats.use(ctx.gpa, .{ .item = .bed });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn insertRecordAtTarget(ctx: Context, record: world.Item) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (ctx.level.world_map.getBlock(hit.x, hit.y, hit.z) != .jukebox) return false;
    if (ctx.level.world_map.getBlockMetadata(hit.x, hit.y, hit.z) != 0) return false;

    try world.jukebox.insertRecord(&ctx.level.world_map, hit.x, hit.y, hit.z, record);
    try ctx.stats.use(ctx.gpa, .{ .item = record });
    ctx.consumeSelectedStack();
    try ctx.applyBlockChanges();
    return true;
}

pub fn placeBoatAtTarget(ctx: Context) !bool {
    const hit = raycast.cast(
        &ctx.level.world_map,
        ctx.player.eyePosition(),
        ctx.player.lookVector(),
        boat_reach,
    ) orelse return false;

    const on_snow = ctx.level.world_map.getBlock(hit.x, hit.y, hit.z) == .snow_layer;
    const floor = if (on_snow) hit.y - 1 else hit.y;

    _ = try ctx.level.entities.spawnBoat(
        ctx.gpa,
        @as(f64, @floatFromInt(hit.x)) + 0.5,
        @as(f64, @floatFromInt(floor)) + 1.0,
        @as(f64, @floatFromInt(hit.z)) + 0.5,
    );
    try ctx.stats.use(ctx.gpa, .{ .item = .boat });
    ctx.consumeSelectedStack();
    return true;
}

pub fn placeMinecartAtTarget(ctx: Context, kind: Minecart.Kind) !bool {
    const hit = ctx.pickedBlock() orelse return false;
    if (!world.block.isRail(ctx.level.world_map.getBlock(hit.x, hit.y, hit.z))) return false;

    _ = try ctx.level.entities.spawnMinecart(
        ctx.gpa,
        @as(f64, @floatFromInt(hit.x)) + 0.5,
        @as(f64, @floatFromInt(hit.y)) + 0.5,
        @as(f64, @floatFromInt(hit.z)) + 0.5,
        kind,
    );
    try ctx.stats.use(ctx.gpa, ctx.player.inventory.selectedStack().?.id);
    ctx.consumeSelectedStack();
    return true;
}
