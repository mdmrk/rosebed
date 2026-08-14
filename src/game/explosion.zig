const std = @import("std");

const math = @import("math");
const world = @import("world");

const Entity = @import("entity.zig");
const Particle = @import("particle.zig");
const Player = @import("player.zig");
const raycast = @import("raycast.zig");

pub const shell_resolution: usize = 16;
pub const ray_step: f32 = 0.3;
pub const ray_falloff: f32 = 12.0 / 16.0;
pub const strength_spread_low: f32 = 0.7;
pub const strength_spread_high: f32 = 0.6;
pub const damage_radius_scale: f32 = 2.0;
pub const damage_scale: f64 = 8.0;
pub const drop_chance: f32 = 0.3;
pub const fire_chance: i32 = 3;
pub const particle_spread: f64 = 0.5;
pub const particle_falloff: f64 = 0.1;

pub const Destroyed = std.ArrayList(world.World.BlockPos);

pub fn detonate(
    gpa: std.mem.Allocator,
    entities: anytype,
    world_map: *world.World,
    roster: []const *Player,
    at: math.Vec3,
    size: f32,
    flaming: bool,
    rand: *world.JavaRandom,
) !void {
    var destroyed: Destroyed = .empty;
    defer destroyed.deinit(gpa);

    try carveBlocks(gpa, world_map, at, size, rand, &destroyed);
    throwEntities(entities, world_map, roster, at, size, rand);
    if (flaming) try lightFires(world_map, destroyed.items, rand);
    try scatterRubble(gpa, entities, world_map, at, size, destroyed.items, rand);
    try entities.recordBlast(gpa, at, size, destroyed.items);
}

fn carveBlocks(
    gpa: std.mem.Allocator,
    world_map: *const world.World,
    at: math.Vec3,
    size: f32,
    rand: *world.JavaRandom,
    destroyed: *Destroyed,
) !void {
    var seen: std.AutoHashMapUnmanaged(world.World.BlockPos, void) = .{};
    defer seen.deinit(gpa);

    const span: f32 = @floatFromInt(shell_resolution - 1);
    for (0..shell_resolution) |ix| {
        for (0..shell_resolution) |iy| {
            for (0..shell_resolution) |iz| {
                if (!onShell(ix, iy, iz)) continue;

                var dx: f64 = @as(f32, @floatFromInt(ix)) / span * 2.0 - 1.0;
                var dy: f64 = @as(f32, @floatFromInt(iy)) / span * 2.0 - 1.0;
                var dz: f64 = @as(f32, @floatFromInt(iz)) / span * 2.0 - 1.0;
                const length = @sqrt(dx * dx + dy * dy + dz * dz);
                dx /= length;
                dy /= length;
                dz /= length;

                var strength = size * (strength_spread_low + rand.nextFloat() * strength_spread_high);
                var x = at.x;
                var y = at.y;
                var z = at.z;

                while (strength > 0.0) : (strength -= ray_step * ray_falloff) {
                    const cell: world.World.BlockPos = .{
                        .x = math.util.floorDouble(x),
                        .y = math.util.floorDouble(y),
                        .z = math.util.floorDouble(z),
                    };

                    const id = world_map.getBlock(cell.x, cell.y, cell.z);
                    if (id != .air) strength -= (id.explosionResistance() + ray_step) * ray_step;
                    if (strength > 0.0 and !(try seen.getOrPut(gpa, cell)).found_existing) {
                        try destroyed.append(gpa, cell);
                    }

                    x += dx * ray_step;
                    y += dy * ray_step;
                    z += dz * ray_step;
                }
            }
        }
    }
}

fn onShell(ix: usize, iy: usize, iz: usize) bool {
    const last = shell_resolution - 1;
    return ix == 0 or ix == last or iy == 0 or iy == last or iz == 0 or iz == last;
}

fn throwEntities(
    entities: anytype,
    world_map: *const world.World,
    roster: []const *Player,
    at: math.Vec3,
    size: f32,
    rand: *world.JavaRandom,
) void {
    const reach: f64 = size * damage_radius_scale;

    for (entities.mobs.items) |entry| {
        const impact = impactOn(world_map, at, reach, entry.animal.base) orelse continue;
        _ = entry.animal.hurt(impactDamage(impact.strength, reach), null, rand);
        pushBack(&entry.animal.base, impact);
    }

    for (roster) |player| {
        const impact = impactOn(world_map, at, reach, player.base) orelse continue;
        player.hurt(impactDamage(impact.strength, reach));
        pushBack(&player.base, impact);
    }
}

const Impact = struct {
    strength: f64,
    along: [3]f64,
};

fn impactOn(world_map: *const world.World, at: math.Vec3, reach: f64, base: Entity) ?Impact {
    var dx = base.position.x - at.x;
    var dy = base.position.y - at.y;
    var dz = base.position.z - at.z;

    const away: f64 = @as(f32, @floatCast(@sqrt(dx * dx + dy * dy + dz * dz)));
    if (away / reach > 1.0) return null;

    dx /= away;
    dy /= away;
    dz /= away;

    const exposure: f64 = blockDensity(world_map, at, base.boundingBox());
    return .{ .strength = (1.0 - away / reach) * exposure, .along = .{ dx, dy, dz } };
}

fn impactDamage(strength: f64, reach: f64) i32 {
    return @intFromFloat((strength * strength + strength) / 2.0 * damage_scale * reach + 1.0);
}

fn pushBack(base: *Entity, impact: Impact) void {
    base.motion.x += impact.along[0] * impact.strength;
    base.motion.y += impact.along[1] * impact.strength;
    base.motion.z += impact.along[2] * impact.strength;
}

pub fn blockDensity(world_map: *const world.World, at: math.Vec3, box: math.AABB) f32 {
    const step_x = 1.0 / ((box.max_x - box.min_x) * 2.0 + 1.0);
    const step_y = 1.0 / ((box.max_y - box.min_y) * 2.0 + 1.0);
    const step_z = 1.0 / ((box.max_z - box.min_z) * 2.0 + 1.0);

    var clear: u32 = 0;
    var total: u32 = 0;

    var fx: f32 = 0.0;
    while (fx <= 1.0) : (fx = @floatCast(@as(f64, fx) + step_x)) {
        var fy: f32 = 0.0;
        while (fy <= 1.0) : (fy = @floatCast(@as(f64, fy) + step_y)) {
            var fz: f32 = 0.0;
            while (fz <= 1.0) : (fz = @floatCast(@as(f64, fz) + step_z)) {
                const from = math.Vec3.init(
                    box.min_x + (box.max_x - box.min_x) * @as(f64, fx),
                    box.min_y + (box.max_y - box.min_y) * @as(f64, fy),
                    box.min_z + (box.max_z - box.min_z) * @as(f64, fz),
                );
                if (!isObstructedBetween(world_map, from, at)) clear += 1;
                total += 1;
            }
        }
    }

    return @as(f32, @floatFromInt(clear)) / @as(f32, @floatFromInt(total));
}

fn isObstructedBetween(world_map: *const world.World, from: math.Vec3, to: math.Vec3) bool {
    const along = [3]f64{ to.x - from.x, to.y - from.y, to.z - from.z };
    const reach = @sqrt(along[0] * along[0] + along[1] * along[1] + along[2] * along[2]);
    if (reach == 0.0) return false;

    const unit = [3]f64{ along[0] / reach, along[1] / reach, along[2] / reach };
    return raycast.castBlocks(world_map, from, unit, reach) != null;
}

fn lightFires(
    world_map: *world.World,
    destroyed: []const world.World.BlockPos,
    rand: *world.JavaRandom,
) !void {
    var index = destroyed.len;
    while (index > 0) {
        index -= 1;
        const cell = destroyed[index];
        if (world_map.getBlock(cell.x, cell.y, cell.z) != .air) continue;
        if (!world_map.getBlock(cell.x, cell.y - 1, cell.z).isOpaqueCube()) continue;
        if (rand.nextIntBound(fire_chance) != 0) continue;
        try world_map.setBlockWithNotify(cell.x, cell.y, cell.z, .fire);
    }
}

fn scatterRubble(
    gpa: std.mem.Allocator,
    entities: anytype,
    world_map: *world.World,
    at: math.Vec3,
    size: f32,
    destroyed: []const world.World.BlockPos,
    rand: *world.JavaRandom,
) !void {
    var index = destroyed.len;
    while (index > 0) {
        index -= 1;
        const cell = destroyed[index];
        const id = world_map.getBlock(cell.x, cell.y, cell.z);

        const puff_x = @as(f64, @as(f32, @floatFromInt(cell.x)) + rand.nextFloat());
        const puff_y = @as(f64, @as(f32, @floatFromInt(cell.y)) + rand.nextFloat());
        const puff_z = @as(f64, @as(f32, @floatFromInt(cell.z)) + rand.nextFloat());

        var dx = puff_x - at.x;
        var dy = puff_y - at.y;
        var dz = puff_z - at.z;
        const away: f64 = @as(f32, @floatCast(@sqrt(dx * dx + dy * dy + dz * dz)));
        dx /= away;
        dy /= away;
        dz /= away;

        var speed = particle_spread / (away / @as(f64, size) + particle_falloff);
        speed *= @as(f64, rand.nextFloat() * rand.nextFloat() + 0.3);
        const drift = math.Vec3.init(dx * speed, dy * speed, dz * speed);

        try entities.particles.append(gpa, Particle.spawnExplode(math.Vec3.init(
            (puff_x + at.x) / 2.0,
            (puff_y + at.y) / 2.0,
            (puff_z + at.z) / 2.0,
        ), drift, rand));
        try entities.particles.append(gpa, Particle.spawnSmoke(math.Vec3.init(puff_x, puff_y, puff_z), drift, rand));

        if (id == .air) continue;

        if (id.drop(world_map.getBlockMetadata(cell.x, cell.y, cell.z), rand)) |stack| {
            var kept: u8 = 0;
            for (0..stack.count) |_| {
                if (rand.nextFloat() <= drop_chance) kept += 1;
            }
            if (kept > 0) {
                try world_map.dropped.append(world_map.allocator, .{
                    .pos = cell,
                    .stack = .{ .id = stack.id, .count = kept, .meta = stack.meta },
                });
            }
        }
        if (id.isSign()) _ = world_map.removeSign(cell.x, cell.y, cell.z);
        try world_map.setBlockWithNotify(cell.x, cell.y, cell.z, .air);
    }
}
