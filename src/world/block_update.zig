const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const Chunk = @import("Chunk.zig");
const item = @import("item.zig");
const light = @import("light.zig");
const portal = @import("portal.zig");
const rail = @import("rail.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

const fall_check_radius: i32 = 32;

fn plantGrowsOn(id: Block, below: Block) bool {
    return switch (id) {
        .dead_bush => below == .sand,
        .mushroom_brown, .mushroom_red => below.isOpaqueCube(),
        else => below == .grass or below == .dirt,
    };
}

fn reedCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const below = world_map.getBlock(x, y - 1, z);
    if (below == .reed) return true;
    if (below != .grass and below != .dirt) return false;
    return world_map.getBlock(x - 1, y - 1, z).material() == .water or
        world_map.getBlock(x + 1, y - 1, z).material() == .water or
        world_map.getBlock(x, y - 1, z - 1).material() == .water or
        world_map.getBlock(x, y - 1, z + 1).material() == .water;
}

fn cactusCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (world_map.getBlock(x - 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x + 1, y, z).isSolid()) return false;
    if (world_map.getBlock(x, y, z - 1).isSolid()) return false;
    if (world_map.getBlock(x, y, z + 1).isSolid()) return false;

    const below = world_map.getBlock(x, y - 1, z);
    return below == .cactus or below == .sand;
}

fn torchSupport(metadata: u4) ?[3]i32 {
    return switch (metadata) {
        1 => .{ -1, 0, 0 },
        2 => .{ 1, 0, 0 },
        3 => .{ 0, 0, -1 },
        4 => .{ 0, 0, 1 },
        5 => .{ 0, -1, 0 },
        else => null,
    };
}

fn torchHolds(world_map: *const World, x: i32, y: i32, z: i32, metadata: u4) bool {
    const offset = torchSupport(metadata) orelse return false;
    return world_map.getBlock(x + offset[0], y + offset[1], z + offset[2]).isOpaqueCube();
}

fn torchAnySupport(world_map: *const World, x: i32, y: i32, z: i32) ?u4 {
    for ([5]u4{ 1, 2, 3, 4, 5 }) |metadata| {
        if (torchHolds(world_map, x, y, z, metadata)) return metadata;
    }
    return null;
}

fn torchCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const metadata = world_map.getBlockMetadata(x, y, z);
    if (torchSupport(metadata) == null) return torchAnySupport(world_map, x, y, z) != null;
    return torchHolds(world_map, x, y, z, metadata);
}

fn doorCanStay(world_map: *const World, x: i32, y: i32, z: i32, id: Block) bool {
    if (block.doorIsTop(world_map.getBlockMetadata(x, y, z))) {
        return world_map.getBlock(x, y - 1, z) == id;
    }
    return world_map.getBlock(x, y + 1, z) == id and world_map.getBlock(x, y - 1, z).isOpaqueCube();
}

fn normalCubesBeside(world_map: *const World, x: i32, y: i32, z: i32) u8 {
    var count: u8 = 0;
    if (world_map.getBlock(x, y, z).isOpaqueCube()) count += 1;
    if (world_map.getBlock(x, y + 1, z).isOpaqueCube()) count += 1;
    return count;
}

fn doorBeside(world_map: *const World, x: i32, y: i32, z: i32, id: Block) bool {
    return world_map.getBlock(x, y, z) == id or world_map.getBlock(x, y + 1, z) == id;
}

pub fn canPlaceDoorAt(world_map: *const World, x: i32, y: i32, z: i32) bool {
    if (y < 1 or y + 1 >= Chunk.height) return false;
    if (!world_map.getBlock(x, y - 1, z).isOpaqueCube()) return false;
    return world_map.getBlock(x, y, z).isReplaceable() and world_map.getBlock(x, y + 1, z).isReplaceable();
}

pub fn placeDoor(world_map: *World, x: i32, y: i32, z: i32, id: Block, yaw: f32) !bool {
    if (!canPlaceDoorAt(world_map, x, y, z)) return false;

    const facing = block.doorFacingFromYaw(yaw);
    const step = block.doorHingeStep(facing);
    const behind_x = x - step[0];
    const behind_z = z - step[1];
    const ahead_x = x + step[0];
    const ahead_z = z + step[1];

    const behind_solid = normalCubesBeside(world_map, behind_x, y, behind_z);
    const ahead_solid = normalCubesBeside(world_map, ahead_x, y, ahead_z);
    const behind_door = doorBeside(world_map, behind_x, y, behind_z, id);
    const ahead_door = doorBeside(world_map, ahead_x, y, ahead_z, id);

    const hinged_right = (behind_door and !ahead_door) or ahead_solid > behind_solid;
    const metadata: u4 = if (hinged_right)
        (@as(u4, facing) -% 1 & 3) + block.door_open_bit
    else
        facing;

    try world_map.setBlockAndMetadataWithNotify(x, y, z, id, metadata);
    try world_map.setBlockAndMetadataWithNotify(x, y + 1, z, id, metadata + block.door_top_bit);
    return true;
}

pub fn toggleDoor(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    const metadata = world_map.getBlockMetadata(x, y, z);

    if (block.doorIsTop(metadata)) {
        if (world_map.getBlock(x, y - 1, z) == id) try toggleDoor(world_map, x, y - 1, z);
        return;
    }

    if (world_map.getBlock(x, y + 1, z) == id) {
        try world_map.setBlockMetadataWithNotify(x, y + 1, z, (metadata ^ block.door_open_bit) + block.door_top_bit);
    }
    try world_map.setBlockMetadataWithNotify(x, y, z, metadata ^ block.door_open_bit);
    world_map.playDoorToggle(x, y, z);
}

fn trapdoorHolds(world_map: *const World, x: i32, y: i32, z: i32, metadata: u4) bool {
    const step = block.trapdoorSupportStep(metadata);
    return world_map.getBlock(x + step[0], y + step[1], z + step[2]).isOpaqueCube();
}

fn trapdoorCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return trapdoorHolds(world_map, x, y, z, world_map.getBlockMetadata(x, y, z));
}

pub fn toggleTrapdoor(world_map: *World, x: i32, y: i32, z: i32) !void {
    const metadata = world_map.getBlockMetadata(x, y, z);
    try world_map.setBlockMetadataWithNotify(x, y, z, metadata ^ block.trapdoor_open_bit);
    world_map.playDoorToggle(x, y, z);
}

pub fn mergeSlabBelow(world_map: *World, x: i32, y: i32, z: i32) !bool {
    if (world_map.getBlock(x, y, z) != .slab) return false;
    if (world_map.getBlock(x, y - 1, z) != .slab) return false;

    const metadata = world_map.getBlockMetadata(x, y, z);
    if (metadata != world_map.getBlockMetadata(x, y - 1, z)) return false;

    try world_map.setBlockWithNotify(x, y, z, .air);
    try world_map.setBlockAndMetadataWithNotify(x, y - 1, z, .slab_double, metadata);
    return true;
}

pub fn scoopLiquid(world_map: *World, x: i32, y: i32, z: i32) !?item.Fill {
    if (world_map.getBlockMetadata(x, y, z) != 0) return null;
    const filled: item.Fill = switch (world_map.getBlock(x, y, z).material()) {
        .water => .water,
        .lava => .lava,
        else => return null,
    };
    try world_map.setBlockWithNotify(x, y, z, .air);
    return filled;
}

pub fn pourLiquid(world_map: *World, x: i32, y: i32, z: i32, fill: item.Fill) !bool {
    const poured = fill.poured() orelse return false;
    const target = world_map.getBlock(x, y, z);
    if (target != .air and target.material().isSolid()) return false;
    try world_map.setBlockAndMetadataWithNotify(x, y, z, poured, 0);
    return true;
}

pub fn placementMetadata(world_map: *World, x: i32, y: i32, z: i32, id: Block, face: block.Side, metadata: u4) u4 {
    if (id == .trapdoor) return block.trapdoorFacingFromFace(face) orelse 0;
    if (id == .lever) return leverPlacementFacing(world_map, x, y, z, face) orelse 0;
    if (id == .button) return buttonPlacementFacing(world_map, x, y, z, face);
    if (id == .ladder) return ladderPlacementFacing(world_map, x, y, z, face) orelse ladderAnySupport(world_map, x, y, z);
    if (!id.isTorch()) return metadata;

    const facing: u4 = switch (face) {
        .up => 5,
        .north => 4,
        .south => 3,
        .west => 2,
        .east => 1,
        .down => 0,
    };
    if (torchHolds(world_map, x, y, z, facing)) return facing;
    return torchAnySupport(world_map, x, y, z) orelse 0;
}

fn wallFacing(world_map: *const World, x: i32, y: i32, z: i32, face: block.Side) ?u4 {
    return switch (face) {
        .north => if (world_map.getBlock(x, y, z + 1).isNormalCube()) 4 else null,
        .south => if (world_map.getBlock(x, y, z - 1).isNormalCube()) 3 else null,
        .west => if (world_map.getBlock(x + 1, y, z).isNormalCube()) 2 else null,
        .east => if (world_map.getBlock(x - 1, y, z).isNormalCube()) 1 else null,
        else => null,
    };
}

fn leverCanPlaceOnSide(world_map: *const World, x: i32, y: i32, z: i32, face: block.Side) bool {
    if (face == .up) return world_map.getBlock(x, y - 1, z).isNormalCube();
    return wallFacing(world_map, x, y, z, face) != null;
}

fn leverPlacementFacing(world_map: *World, x: i32, y: i32, z: i32, face: block.Side) ?u4 {
    if (face == .up) {
        if (!world_map.getBlock(x, y - 1, z).isNormalCube()) return null;
        return 5 + @as(u4, @intCast(world_map.rand.nextIntBound(2)));
    }
    return wallFacing(world_map, x, y, z, face);
}

fn buttonPlacementFacing(world_map: *const World, x: i32, y: i32, z: i32, face: block.Side) u4 {
    if (wallFacing(world_map, x, y, z, face)) |facing| return facing;
    if (world_map.getBlock(x - 1, y, z).isNormalCube()) return 1;
    if (world_map.getBlock(x + 1, y, z).isNormalCube()) return 2;
    if (world_map.getBlock(x, y, z - 1).isNormalCube()) return 3;
    if (world_map.getBlock(x, y, z + 1).isNormalCube()) return 4;
    return 1;
}

fn fenceStandsOn(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const below = world_map.getBlock(x, y - 1, z);
    return below == .fence or below.material().isSolid();
}

fn ladderPlacementFacing(world_map: *const World, x: i32, y: i32, z: i32, face: block.Side) ?u4 {
    return switch (face) {
        .north => if (world_map.getBlock(x, y, z + 1).isNormalCube()) 2 else null,
        .south => if (world_map.getBlock(x, y, z - 1).isNormalCube()) 3 else null,
        .west => if (world_map.getBlock(x + 1, y, z).isNormalCube()) 4 else null,
        .east => if (world_map.getBlock(x - 1, y, z).isNormalCube()) 5 else null,
        else => null,
    };
}

fn ladderAnySupport(world_map: *const World, x: i32, y: i32, z: i32) u4 {
    if (world_map.getBlock(x, y, z + 1).isNormalCube()) return 2;
    if (world_map.getBlock(x, y, z - 1).isNormalCube()) return 3;
    if (world_map.getBlock(x + 1, y, z).isNormalCube()) return 4;
    if (world_map.getBlock(x - 1, y, z).isNormalCube()) return 5;
    return 0;
}

fn ladderCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return switch (world_map.getBlockMetadata(x, y, z)) {
        2 => world_map.getBlock(x, y, z + 1).isNormalCube(),
        3 => world_map.getBlock(x, y, z - 1).isNormalCube(),
        4 => world_map.getBlock(x + 1, y, z).isNormalCube(),
        5 => world_map.getBlock(x - 1, y, z).isNormalCube(),
        else => false,
    };
}

fn ladderHasAnySupport(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x - 1, y, z).isNormalCube() or
        world_map.getBlock(x + 1, y, z).isNormalCube() or
        world_map.getBlock(x, y, z - 1).isNormalCube() or
        world_map.getBlock(x, y, z + 1).isNormalCube();
}

fn leverCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return switch (world_map.getBlockMetadata(x, y, z) & block.facing_mask) {
        1 => world_map.getBlock(x - 1, y, z).isNormalCube(),
        2 => world_map.getBlock(x + 1, y, z).isNormalCube(),
        3 => world_map.getBlock(x, y, z - 1).isNormalCube(),
        4 => world_map.getBlock(x, y, z + 1).isNormalCube(),
        else => world_map.getBlock(x, y - 1, z).isNormalCube(),
    };
}

fn leverHasAnySupport(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x - 1, y, z).isNormalCube() or
        world_map.getBlock(x + 1, y, z).isNormalCube() or
        world_map.getBlock(x, y, z - 1).isNormalCube() or
        world_map.getBlock(x, y, z + 1).isNormalCube() or
        world_map.getBlock(x, y - 1, z).isNormalCube();
}

fn buttonCanStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return switch (world_map.getBlockMetadata(x, y, z) & block.facing_mask) {
        1 => world_map.getBlock(x - 1, y, z).isNormalCube(),
        2 => world_map.getBlock(x + 1, y, z).isNormalCube(),
        3 => world_map.getBlock(x, y, z - 1).isNormalCube(),
        4 => world_map.getBlock(x, y, z + 1).isNormalCube(),
        else => false,
    };
}

fn buttonHasAnySupport(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x - 1, y, z).isNormalCube() or
        world_map.getBlock(x + 1, y, z).isNormalCube() or
        world_map.getBlock(x, y, z - 1).isNormalCube() or
        world_map.getBlock(x, y, z + 1).isNormalCube();
}

pub fn canStayAt(world_map: *const World, x: i32, y: i32, z: i32, id: Block) bool {
    return switch (id) {
        .sapling, .dandelion, .rose, .tall_grass, .dead_bush => (light.levelAt(world_map, x, y, z) >= 8 or
            world_map.canBlockSeeTheSky(x, y, z)) and plantGrowsOn(id, world_map.getBlock(x, y - 1, z)),
        .mushroom_brown, .mushroom_red => light.levelAt(world_map, x, y, z) <= 13 and
            plantGrowsOn(id, world_map.getBlock(x, y - 1, z)),
        .reed => reedCanStay(world_map, x, y, z),
        .cactus => cactusCanStay(world_map, x, y, z),
        .snow_layer => world_map.getBlock(x, y - 1, z).isOpaqueCube(),
        .torch, .torch_redstone_off, .torch_redstone_on => torchCanStay(world_map, x, y, z),
        .redstone_wire, .pressure_plate_stone, .pressure_plate_planks => world_map.getBlock(x, y - 1, z).isNormalCube(),
        .rail, .rail_powered, .rail_detector => rail.canStay(world_map, x, y, z),
        .repeater_off, .repeater_on => world_map.getBlock(x, y - 1, z).isNormalCube(),
        .lever => leverCanStay(world_map, x, y, z) and leverHasAnySupport(world_map, x, y, z),
        .button => buttonCanStay(world_map, x, y, z) and buttonHasAnySupport(world_map, x, y, z),
        .door_wood, .door_iron => doorCanStay(world_map, x, y, z, id),
        .trapdoor => trapdoorCanStay(world_map, x, y, z),
        .ladder => ladderCanStay(world_map, x, y, z),
        .cake => world_map.getBlock(x, y - 1, z).material().isSolid(),
        .sign_post => world_map.getBlock(x, y - 1, z).material().isSolid(),
        .wall_sign => wallSignHangsOn(world_map, x, y, z),
        .bed => bedPartnerStands(world_map, x, y, z),
        else => true,
    };
}

fn wallSignHangsOn(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return switch (world_map.getBlockMetadata(x, y, z)) {
        2 => world_map.getBlock(x, y, z + 1).material().isSolid(),
        3 => world_map.getBlock(x, y, z - 1).material().isSolid(),
        4 => world_map.getBlock(x + 1, y, z).material().isSolid(),
        5 => world_map.getBlock(x - 1, y, z).material().isSolid(),
        else => false,
    };
}

fn bedPartnerStands(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const metadata = world_map.getBlockMetadata(x, y, z);
    const step = block.bedStep(block.bedFacing(metadata));
    return if (block.bedIsPillow(metadata))
        world_map.getBlock(x - step[0], y, z - step[1]) == .bed
    else
        world_map.getBlock(x + step[0], y, z + step[1]) == .bed;
}

pub fn bedPartner(world_map: *const World, x: i32, y: i32, z: i32) ?[3]i32 {
    if (world_map.getBlock(x, y, z) != .bed) return null;
    const metadata = world_map.getBlockMetadata(x, y, z);
    const step = block.bedStep(block.bedFacing(metadata));
    const other: [3]i32 = if (block.bedIsPillow(metadata))
        .{ x - step[0], y, z - step[1] }
    else
        .{ x + step[0], y, z + step[1] };
    return if (world_map.getBlock(other[0], other[1], other[2]) == .bed) other else null;
}

pub const Pillow = struct {
    at: [3]i32,
    metadata: u4,
};

pub fn bedPillowAt(world_map: *const World, x: i32, y: i32, z: i32) ?Pillow {
    var at: [3]i32 = .{ x, y, z };
    var metadata = world_map.getBlockMetadata(at[0], at[1], at[2]);
    if (!block.bedIsPillow(metadata)) {
        at = bedPartner(world_map, x, y, z) orelse return null;
        metadata = world_map.getBlockMetadata(at[0], at[1], at[2]);
    }
    return .{ .at = at, .metadata = metadata };
}

pub fn setBedOccupied(world_map: *World, x: i32, y: i32, z: i32, occupied: bool) !void {
    const metadata = world_map.getBlockMetadata(x, y, z);
    try world_map.setBlockMetadataWithNotify(x, y, z, block.bedOccupied(metadata, occupied));
}

pub fn bedRespawnSpot(world_map: *const World, x: i32, y: i32, z: i32, skip: i32) ?[3]i32 {
    if (world_map.getBlock(x, y, z) != .bed) return null;

    const step = block.bedStep(block.bedFacing(world_map.getBlockMetadata(x, y, z)));
    var remaining = skip;

    var ring: i32 = 0;
    while (ring <= 1) : (ring += 1) {
        const from_x = x - step[0] * ring - 1;
        const from_z = z - step[1] * ring - 1;

        var sx = from_x;
        while (sx <= from_x + 2) : (sx += 1) {
            var sz = from_z;
            while (sz <= from_z + 2) : (sz += 1) {
                if (world_map.getBlock(sx, y - 1, sz).isOpaqueCube() and
                    world_map.getBlock(sx, y, sz) == .air and
                    world_map.getBlock(sx, y + 1, sz) == .air)
                {
                    if (remaining <= 0) return .{ sx, y, sz };
                    remaining -= 1;
                }
            }
        }
    }

    return null;
}

pub fn canPlaceBedAt(world_map: *const World, x: i32, y: i32, z: i32, facing: u2) bool {
    const step = block.bedStep(facing);
    if (!world_map.getBlock(x, y, z).isReplaceable()) return false;
    if (!world_map.getBlock(x + step[0], y, z + step[1]).isReplaceable()) return false;
    if (!world_map.getBlock(x, y - 1, z).isOpaqueCube()) return false;
    if (!world_map.getBlock(x + step[0], y - 1, z + step[1]).isOpaqueCube()) return false;
    return true;
}

pub fn placeBed(world_map: *World, x: i32, y: i32, z: i32, yaw: f32) !bool {
    const facing = block.bedFacingFromYaw(yaw);
    if (!canPlaceBedAt(world_map, x, y, z, facing)) return false;

    const step = block.bedStep(facing);
    try world_map.setBlockAndMetadataWithNotify(x, y, z, .bed, facing);
    try world_map.setBlockAndMetadataWithNotify(x + step[0], y, z + step[1], .bed, facing + block.bed_pillow_bit);
    return true;
}

pub fn breakBedPartner(world_map: *World, x: i32, y: i32, z: i32) !void {
    const other = bedPartner(world_map, x, y, z) orelse return;
    try world_map.setBlockWithNotify(other[0], other[1], other[2], .air);
}

pub const Placement = struct {
    x: i32,
    y: i32,
    z: i32,
    face: block.Side,
};

pub fn placementTarget(world_map: *const World, x: i32, y: i32, z: i32, face: block.Side) Placement {
    if (world_map.getBlock(x, y, z) == .snow_layer) return .{ .x = x, .y = y, .z = z, .face = .down };

    return switch (face) {
        .down => .{ .x = x, .y = y - 1, .z = z, .face = face },
        .up => .{ .x = x, .y = y + 1, .z = z, .face = face },
        .north => .{ .x = x, .y = y, .z = z - 1, .face = face },
        .south => .{ .x = x, .y = y, .z = z + 1, .face = face },
        .west => .{ .x = x - 1, .y = y, .z = z, .face = face },
        .east => .{ .x = x + 1, .y = y, .z = z, .face = face },
    };
}

pub fn canPlaceAt(world_map: *const World, x: i32, y: i32, z: i32, id: Block) bool {
    return switch (id) {
        .sapling, .dandelion, .rose, .tall_grass, .dead_bush, .mushroom_brown, .mushroom_red => plantGrowsOn(id, world_map.getBlock(x, y - 1, z)),
        .torch, .torch_redstone_off, .torch_redstone_on => torchAnySupport(world_map, x, y, z) != null,
        .lever => leverHasAnySupport(world_map, x, y, z),
        .button => buttonHasAnySupport(world_map, x, y, z),
        .ladder => ladderHasAnySupport(world_map, x, y, z),
        .fence => fenceStandsOn(world_map, x, y, z),
        else => canStayAt(world_map, x, y, z, id),
    };
}

pub fn canPlaceOnSide(world_map: *const World, x: i32, y: i32, z: i32, id: Block, face: block.Side) bool {
    if (id == .lever) return leverCanPlaceOnSide(world_map, x, y, z, face);
    if (id == .button) return wallFacing(world_map, x, y, z, face) != null;
    if (id == .ladder) return ladderHasAnySupport(world_map, x, y, z);
    if (id != .trapdoor) return canPlaceAt(world_map, x, y, z, id);
    const facing = block.trapdoorFacingFromFace(face) orelse return false;
    return trapdoorHolds(world_map, x, y, z, facing);
}

pub fn onNeighborChange(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    if (id == .portal) return portal.onNeighborChange(world_map, x, y, z);
    if (id.def().on_neighbor_change) |hook| {
        try hook(world_map, x, y, z, id);
        if (world_map.getBlock(x, y, z) != id) return;
    }

    if (canStayAt(world_map, x, y, z, id)) return;

    if (id.drop(world_map.getBlockMetadata(x, y, z), &world_map.rand)) |stack| {
        try world_map.dropped.append(world_map.allocator, .{
            .pos = .{ .x = x, .y = y, .z = z },
            .stack = stack,
        });
    }
    if (id.isSign()) _ = world_map.removeSign(x, y, z);
    try world_map.setBlockWithNotify(x, y, z, .air);
}

pub fn tickFalling(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    if (y < 0) return;
    if (!world_map.getBlock(x, y - 1, z).canFallInto()) return;
    const id = world_map.getBlock(x, y, z);

    if (!world_map.scheduled_updates_are_immediate and world_map.chunksExist(
        x - fall_check_radius,
        y - fall_check_radius,
        z - fall_check_radius,
        x + fall_check_radius,
        y + fall_check_radius,
        z + fall_check_radius,
    )) {
        try world_map.falling.append(world_map.allocator, .{
            .pos = .{ .x = x, .y = y, .z = z },
            .id = id,
        });
        try world_map.setBlockWithNotify(x, y, z, .air);
        return;
    }

    try world_map.setBlockWithNotify(x, y, z, .air);
    var rest = y;
    while (rest > 0 and world_map.getBlock(x, rest - 1, z).canFallInto()) rest -= 1;
    if (rest > 0) try world_map.setBlockWithNotify(x, rest, z, id);
}

fn reedWorld(height: i32) !World {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    errdefer w.deinit();

    w.setBlock(8, 11, 8, .grass);
    w.setBlock(7, 11, 8, .stationary_water);
    var y: i32 = 0;
    while (y < height) : (y += 1) w.setBlock(8, 12 + y, 8, .reed);
    return w;
}

test "breaking the bottom of a sugar cane column takes the whole column with it" {
    var w = try reedWorld(3);
    defer w.deinit();

    try w.setBlockWithNotify(8, 12, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 14, 8));
    try std.testing.expectEqual(@as(usize, 2), w.dropped.items.len);
}

test "breaking the middle of a sugar cane column leaves the part below standing" {
    var w = try reedWorld(3);
    defer w.deinit();

    try w.setBlockWithNotify(8, 13, 8, .air);

    try std.testing.expectEqual(.reed, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 14, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
}

test "digging out the soil takes the sugar cane standing on it" {
    var w = try reedWorld(2);
    defer w.deinit();

    try w.setBlockWithNotify(8, 11, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
}

test "a fence needs solid ground or another fence under it, and never pops afterwards" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .fence));
    try std.testing.expect(!canPlaceAt(&w, 8, 14, 8, .fence));

    try w.setBlockWithNotify(8, 12, 8, .fence);
    try std.testing.expect(canPlaceAt(&w, 8, 13, 8, .fence));

    try w.setBlockWithNotify(8, 11, 8, .air);

    try std.testing.expectEqual(.fence, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);
}

test "a ladder takes the facing of the wall it was hung on" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 12, 9, .stone);
    w.setBlock(9, 12, 8, .stone);

    try std.testing.expectEqual(@as(u4, 2), placementMetadata(&w, 8, 12, 8, .ladder, .north, 0));
    try std.testing.expectEqual(@as(u4, 4), placementMetadata(&w, 8, 12, 8, .ladder, .west, 0));

    try std.testing.expectEqual(@as(u4, 2), placementMetadata(&w, 8, 12, 8, .ladder, .up, 0));
    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .ladder));
    try std.testing.expect(!canPlaceAt(&w, 4, 12, 4, .ladder));
}

test "a ladder pops when the wall behind it is dug out" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 12, 9, .stone);
    try w.setBlockAndMetadataWithNotify(8, 12, 8, .ladder, 2);

    try std.testing.expect(canStayAt(&w, 8, 12, 8, .ladder));

    try w.setBlockWithNotify(8, 12, 9, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(.ladder, w.dropped.items[0].stack.id.block);
}

test "a flower pops and drops itself when the dirt under it is dug out" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .dirt);
    w.setBlock(8, 12, 8, .rose);

    try w.setBlockWithNotify(8, 11, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(.rose, w.dropped.items[0].stack.id.block);
}

test "a mushroom needs an opaque cube under it, a flower needs grass or dirt" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try std.testing.expect(canStayAt(&w, 8, 12, 8, .mushroom_brown));
    try std.testing.expect(!canStayAt(&w, 8, 12, 8, .rose));
    try std.testing.expect(!canStayAt(&w, 8, 12, 8, .dead_bush));

    w.setBlock(8, 11, 8, .grass);
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .rose));
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .tall_grass));

    w.setBlock(8, 11, 8, .sand);
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .dead_bush));
    try std.testing.expect(!canStayAt(&w, 8, 12, 8, .rose));
}

test "a cactus pops when a solid block is put beside it" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .sand);
    w.setBlock(8, 12, 8, .cactus);
    w.setBlock(8, 13, 8, .cactus);

    try w.setBlockWithNotify(9, 12, 8, .stone);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(@as(usize, 2), w.dropped.items.len);
}

test "a snow layer pops when the block holding it up goes away" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 12, 8, .snow_layer);

    try std.testing.expect(canStayAt(&w, 8, 12, 8, .snow_layer));
    try w.setBlockWithNotify(8, 11, 8, .air);
    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
}

test "placing ignores the light level but still needs the right block below" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 11, 8, .grass);

    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .rose));
    try std.testing.expect(!canPlaceAt(&w, 8, 12, 8, .reed));
    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .stone));

    w.setBlock(7, 11, 8, .stationary_water);
    try std.testing.expect(canPlaceAt(&w, 8, 12, 8, .reed));
}

fn pillarWorld() !World {
    var w = World.init(std.testing.allocator);
    errdefer w.deinit();

    var chunk_x: i32 = -3;
    while (chunk_x <= 3) : (chunk_x += 1) {
        var chunk_z: i32 = -3;
        while (chunk_z <= 3) : (chunk_z += 1) _ = try w.createChunk(chunk_x, chunk_z);
    }

    var y: i32 = 0;
    while (y < 12) : (y += 1) w.setBlock(8, y, 8, .stone);
    return w;
}

test "digging out the block under a sand column drops the column one at a time" {
    var w = try pillarWorld();
    defer w.deinit();
    w.setBlock(8, 12, 8, .sand);
    w.setBlock(8, 13, 8, .sand);

    try w.setBlockWithNotify(8, 11, 8, .air);
    try std.testing.expectEqual(@as(usize, 0), w.falling.items.len);

    w.time += 3;
    try w.tickUpdates();
    try std.testing.expectEqual(@as(usize, 1), w.falling.items.len);
    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));

    w.time += 3;
    try w.tickUpdates();
    try std.testing.expectEqual(@as(usize, 2), w.falling.items.len);
    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
}

test "with immediate updates sand slides down to its resting place at once" {
    var w = try pillarWorld();
    defer w.deinit();
    w.scheduled_updates_are_immediate = true;

    try w.setBlockWithNotify(8, 20, 8, .sand);

    try std.testing.expectEqual(.air, w.getBlock(8, 20, 8));
    try std.testing.expectEqual(.sand, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 0), w.falling.items.len);
}

fn torchWorld() !World {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    errdefer w.deinit();
    w.setBlock(8, 12, 8, .stone);
    return w;
}

test "the clicked face decides which wall a torch attaches to" {
    var w = try torchWorld();
    defer w.deinit();

    try std.testing.expectEqual(@as(u4, 1), placementMetadata(&w, 9, 12, 8, .torch, .east, 0));
    try std.testing.expectEqual(@as(u4, 2), placementMetadata(&w, 7, 12, 8, .torch, .west, 0));
    try std.testing.expectEqual(@as(u4, 3), placementMetadata(&w, 8, 12, 9, .torch, .south, 0));
    try std.testing.expectEqual(@as(u4, 4), placementMetadata(&w, 8, 12, 7, .torch, .north, 0));
    try std.testing.expectEqual(@as(u4, 5), placementMetadata(&w, 8, 13, 8, .torch, .up, 0));
}

test "a torch placed against a face with nothing behind it falls back to any wall" {
    var w = try torchWorld();
    defer w.deinit();

    try std.testing.expectEqual(@as(u4, 1), placementMetadata(&w, 9, 12, 8, .torch, .down, 0));
    try std.testing.expectEqual(@as(u4, 5), placementMetadata(&w, 8, 12, 8, .torch, .down, 0));
}

test "only a torch takes its metadata from the face, other blocks keep the stack's" {
    var w = try torchWorld();
    defer w.deinit();
    try std.testing.expectEqual(@as(u4, 3), placementMetadata(&w, 8, 13, 8, .log, .up, 3));
}

test "a torch needs one of the five faces around it to be a normal cube" {
    var w = try torchWorld();
    defer w.deinit();

    try std.testing.expect(canPlaceAt(&w, 9, 12, 8, .torch));
    try std.testing.expect(canPlaceAt(&w, 8, 13, 8, .torch));
    try std.testing.expect(!canPlaceAt(&w, 8, 14, 8, .torch));

    w.setBlock(8, 13, 8, .glass);
    try std.testing.expect(!canPlaceAt(&w, 9, 13, 8, .torch));
}

test "a wall torch pops when its own wall goes, even with another wall left" {
    var w = try torchWorld();
    defer w.deinit();
    w.setBlock(10, 12, 8, .stone);
    try w.setBlockAndMetadataWithNotify(9, 12, 8, .torch, 1);

    try std.testing.expect(canStayAt(&w, 9, 12, 8, .torch));
    try w.setBlockWithNotify(8, 12, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(9, 12, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(.torch, w.dropped.items[0].stack.id.block);
}

test "a standing torch ignores the walls beside it and only watches the floor" {
    var w = try torchWorld();
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 13, 8, .torch, 5);

    try w.setBlockWithNotify(9, 13, 8, .stone);
    try std.testing.expectEqual(.torch, w.getBlock(8, 13, 8));

    try w.setBlockWithNotify(8, 12, 8, .air);
    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
}

test "putting a second torch on the same wall leaves the first one alone" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 12, 8, .stone);
    w.setBlock(8, 13, 8, .stone);

    try w.setBlockAndMetadataWithNotify(9, 12, 8, .torch, 1);
    try w.setBlockAndMetadataWithNotify(9, 13, 8, .torch, 1);

    try std.testing.expectEqual(.torch, w.getBlock(9, 12, 8));
    try std.testing.expectEqual(.torch, w.getBlock(9, 13, 8));
    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(9, 12, 8));
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);
}

test "a torch is no support for another torch, only a normal cube is" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();
    w.setBlock(8, 13, 8, .stone);

    try w.setBlockAndMetadataWithNotify(9, 13, 8, .torch, 1);
    try std.testing.expect(!canPlaceAt(&w, 10, 13, 8, .torch));
    try std.testing.expect(!canPlaceAt(&w, 9, 14, 8, .torch));
}

fn doorWorld() !World {
    return testing_world.flatWorld(std.testing.allocator, 12);
}

test "a door goes up as two halves, the upper one flagged in its metadata" {
    var w = try doorWorld();
    defer w.deinit();

    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));

    try std.testing.expectEqual(.door_wood, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(.door_wood, w.getBlock(8, 13, 8));
    const lower = w.getBlockMetadata(8, 12, 8);
    try std.testing.expect(!block.doorIsTop(lower));
    try std.testing.expectEqual(lower + block.door_top_bit, w.getBlockMetadata(8, 13, 8));
    try std.testing.expectEqual(block.doorFacingFromYaw(0), @as(u2, @truncate(lower)));
}

test "a door needs a normal cube under it and two free cells above" {
    var w = try doorWorld();
    defer w.deinit();

    try std.testing.expect(canPlaceDoorAt(&w, 8, 12, 8));

    w.setBlock(8, 13, 8, .stone);
    try std.testing.expect(!canPlaceDoorAt(&w, 8, 12, 8));
    w.setBlock(8, 13, 8, .air);

    w.setBlock(8, 11, 8, .glass);
    try std.testing.expect(!canPlaceDoorAt(&w, 8, 12, 8));

    w.setBlock(8, 11, 8, .air);
    try std.testing.expect(!canPlaceDoorAt(&w, 8, 12, 8));
    try std.testing.expect(!try placeDoor(&w, 8, 12, 8, .door_wood, 0));
    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
}

test "a door hung beside another one takes the opposite hinge" {
    var w = try doorWorld();
    defer w.deinit();

    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));
    const first = w.getBlockMetadata(8, 12, 8);

    const step = block.doorHingeStep(block.doorFacingFromYaw(0));
    const beside_x = 8 + step[0];
    const beside_z = 8 + step[1];
    try std.testing.expect(try placeDoor(&w, beside_x, 12, beside_z, .door_wood, 0));

    const second = w.getBlockMetadata(beside_x, 12, beside_z);
    try std.testing.expect(!block.doorIsOpen(first));
    try std.testing.expect(block.doorIsOpen(second));
    try std.testing.expectEqual(block.doorState(first), block.doorState(second));
}

test "a wall on one side of the doorway pushes the hinge to the other" {
    var w = try doorWorld();
    defer w.deinit();

    const step = block.doorHingeStep(block.doorFacingFromYaw(0));
    w.setBlock(8 + step[0], 12, 8 + step[1], .stone);
    w.setBlock(8 + step[0], 13, 8 + step[1], .stone);

    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));
    try std.testing.expect(block.doorIsOpen(w.getBlockMetadata(8, 12, 8)));
}

test "opening a door from either half swings both of them" {
    var w = try doorWorld();
    defer w.deinit();
    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));
    const closed = w.getBlockMetadata(8, 12, 8);

    try toggleDoor(&w, 8, 13, 8);
    try std.testing.expectEqual(closed ^ block.door_open_bit, w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual((closed ^ block.door_open_bit) + block.door_top_bit, w.getBlockMetadata(8, 13, 8));

    try toggleDoor(&w, 8, 12, 8);
    try std.testing.expectEqual(closed, w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(closed + block.door_top_bit, w.getBlockMetadata(8, 13, 8));
}

test "an open door stands across the doorway it filled when closed" {
    var w = try doorWorld();
    defer w.deinit();
    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));

    const closed = Block.door_wood.selectionBounds(w.getBlockMetadata(8, 12, 8));
    try toggleDoor(&w, 8, 12, 8);
    const opened = Block.door_wood.selectionBounds(w.getBlockMetadata(8, 12, 8));

    try std.testing.expect(closed.max[0] - closed.min[0] != opened.max[0] - opened.min[0]);
}

test "breaking one half of a door takes the other, dropping a single door" {
    var w = try doorWorld();
    defer w.deinit();
    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));

    try w.setBlockWithNotify(8, 13, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(block.Id{ .item = .door_wood }, w.dropped.items[0].stack.id);
}

test "breaking the lower half leaves nothing for the upper one to drop" {
    var w = try doorWorld();
    defer w.deinit();
    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_iron, 0));

    try w.setBlockWithNotify(8, 12, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(@as(usize, 0), w.dropped.items.len);
}

test "digging out the block under a door drops the door and clears both halves" {
    var w = try doorWorld();
    defer w.deinit();
    try std.testing.expect(try placeDoor(&w, 8, 12, 8, .door_wood, 0));

    try w.setBlockWithNotify(8, 11, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(block.Id{ .item = .door_wood }, w.dropped.items[0].stack.id);
}

fn trapdoorWorld() !World {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    errdefer w.deinit();
    w.setBlock(8, 12, 9, .stone);
    return w;
}

test "a trapdoor takes its hinge from the wall it was clicked onto" {
    var w = try trapdoorWorld();
    defer w.deinit();

    try std.testing.expectEqual(@as(u4, 0), placementMetadata(&w, 8, 12, 8, .trapdoor, .north, 0));
    try std.testing.expectEqual(@as(u4, 1), placementMetadata(&w, 8, 12, 10, .trapdoor, .south, 0));
    try std.testing.expectEqual(@as(u4, 2), placementMetadata(&w, 7, 12, 9, .trapdoor, .west, 0));
    try std.testing.expectEqual(@as(u4, 3), placementMetadata(&w, 9, 12, 9, .trapdoor, .east, 0));
}

test "a trapdoor only goes on a wall, never on a floor or a ceiling" {
    var w = try trapdoorWorld();
    defer w.deinit();

    try std.testing.expect(canPlaceOnSide(&w, 8, 12, 8, .trapdoor, .north));
    try std.testing.expect(!canPlaceOnSide(&w, 8, 12, 8, .trapdoor, .up));
    try std.testing.expect(!canPlaceOnSide(&w, 8, 12, 8, .trapdoor, .down));
    try std.testing.expect(!canPlaceOnSide(&w, 8, 12, 8, .trapdoor, .south));

    try std.testing.expect(canPlaceOnSide(&w, 8, 13, 8, .stone, .up));
}

test "a glass wall is no support for a trapdoor" {
    var w = try trapdoorWorld();
    defer w.deinit();
    w.setBlock(8, 12, 9, .glass);

    try std.testing.expect(!canPlaceOnSide(&w, 8, 12, 8, .trapdoor, .north));
}

test "swinging a trapdoor keeps the wall it hangs on" {
    var w = try trapdoorWorld();
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 12, 8, .trapdoor, 0);

    try toggleTrapdoor(&w, 8, 12, 8);
    try std.testing.expectEqual(block.trapdoor_open_bit, w.getBlockMetadata(8, 12, 8));
    try std.testing.expect(block.trapdoorIsOpen(w.getBlockMetadata(8, 12, 8)));
    try std.testing.expectEqual(.trapdoor, w.getBlock(8, 12, 8));

    try toggleTrapdoor(&w, 8, 12, 8);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));
}

test "a trapdoor pops when the wall behind it goes" {
    var w = try trapdoorWorld();
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 12, 8, .trapdoor, 0);
    try std.testing.expect(canStayAt(&w, 8, 12, 8, .trapdoor));

    try w.setBlockWithNotify(8, 11, 8, .air);
    try std.testing.expectEqual(.trapdoor, w.getBlock(8, 12, 8));

    try w.setBlockWithNotify(8, 12, 9, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expectEqual(block.Id{ .block = .trapdoor }, w.dropped.items[0].stack.id);
}

test "an open trapdoor still watches the same wall" {
    var w = try trapdoorWorld();
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 12, 8, .trapdoor, block.trapdoor_open_bit);

    try std.testing.expect(canStayAt(&w, 8, 12, 8, .trapdoor));
    try w.setBlockWithNotify(8, 12, 9, .air);
    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
}

test "a block placed against a face lands in the cell beyond it" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 4, 8, .stone);

    const on_top = placementTarget(&world_map, 8, 4, 8, .up);
    try std.testing.expectEqual(@as(i32, 5), on_top.y);
    try std.testing.expectEqual(block.Side.up, on_top.face);

    const on_side = placementTarget(&world_map, 8, 4, 8, .east);
    try std.testing.expectEqual(@as(i32, 9), on_side.x);
    try std.testing.expectEqual(@as(i32, 4), on_side.y);
}

test "a block placed on a snow layer takes the snow's own cell" {
    var world_map = World.init(std.testing.allocator);
    defer world_map.deinit();
    const chunk = try world_map.createChunk(0, 0);
    chunk.setBlock(8, 4, 8, .stone);
    chunk.setBlock(8, 5, 8, .snow_layer);

    const target = placementTarget(&world_map, 8, 5, 8, .up);
    try std.testing.expectEqual(@as(i32, 8), target.x);
    try std.testing.expectEqual(@as(i32, 5), target.y);
    try std.testing.expectEqual(@as(i32, 8), target.z);
    try std.testing.expectEqual(block.Side.down, target.face);

    const from_side = placementTarget(&world_map, 8, 5, 8, .north);
    try std.testing.expectEqual(@as(i32, 5), from_side.y);
    try std.testing.expectEqual(@as(i32, 8), from_side.z);
}

test "a slab laid on a matching slab collapses the pair into a double slab" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 12, 8, .slab, block.slab_wood);
    try w.setBlockAndMetadataWithNotify(8, 13, 8, .slab, block.slab_wood);

    try std.testing.expect(try mergeSlabBelow(&w, 8, 13, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(.slab_double, w.getBlock(8, 12, 8));
    try std.testing.expectEqual(block.slab_wood, w.getBlockMetadata(8, 12, 8));
}

test "slabs cut from different blocks stack instead of merging" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 12, 8, .slab, block.slab_stone);
    try w.setBlockAndMetadataWithNotify(8, 13, 8, .slab, block.slab_wood);

    try std.testing.expect(!try mergeSlabBelow(&w, 8, 13, 8));
    try std.testing.expectEqual(.slab, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(.slab, w.getBlock(8, 12, 8));
}

test "a slab merges only downwards, and never into a double slab" {
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 12, 8, .slab_double, block.slab_stone);
    try w.setBlockAndMetadataWithNotify(8, 13, 8, .slab, block.slab_stone);
    try std.testing.expect(!try mergeSlabBelow(&w, 8, 13, 8));

    try w.setBlockAndMetadataWithNotify(8, 14, 8, .slab, block.slab_stone);
    try std.testing.expect(try mergeSlabBelow(&w, 8, 14, 8));
    try std.testing.expectEqual(.slab_double, w.getBlock(8, 13, 8));
    try std.testing.expectEqual(.air, w.getBlock(8, 14, 8));
}

test "an empty bucket scoops a still source and leaves air behind" {
    for ([_]struct { id: Block, fill: item.Fill }{
        .{ .id = .stationary_water, .fill = .water },
        .{ .id = .flowing_water, .fill = .water },
        .{ .id = .stationary_lava, .fill = .lava },
        .{ .id = .flowing_lava, .fill = .lava },
    }) |source| {
        var w = try testing_world.flatWorld(std.testing.allocator, 1);
        defer w.deinit();
        try w.setBlockAndMetadataWithNotify(8, 2, 8, source.id, 0);

        const scooped = try scoopLiquid(&w, 8, 2, 8);
        try std.testing.expectEqual(source.fill, scooped.?);
        try std.testing.expectEqual(.air, w.getBlock(8, 2, 8));
    }
}

test "an empty bucket cannot scoop flowing liquid or dry land" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 2, 8, .flowing_water, 1);
    try std.testing.expect(try scoopLiquid(&w, 8, 2, 8) == null);
    try std.testing.expectEqual(.flowing_water, w.getBlock(8, 2, 8));

    try std.testing.expect(try scoopLiquid(&w, 8, 0, 8) == null);
    try std.testing.expectEqual(.stone, w.getBlock(8, 0, 8));

    try std.testing.expect(try scoopLiquid(&w, 8, 5, 8) == null);
}

test "a full bucket pours a source into air but not into stone" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try std.testing.expect(try pourLiquid(&w, 8, 2, 8, .water));
    try std.testing.expectEqual(.flowing_water, w.getBlock(8, 2, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 2, 8));

    try std.testing.expect(try pourLiquid(&w, 8, 3, 8, .lava));
    try std.testing.expectEqual(.flowing_lava, w.getBlock(8, 3, 8));

    try std.testing.expect(!try pourLiquid(&w, 8, 0, 8, .water));
    try std.testing.expectEqual(.stone, w.getBlock(8, 0, 8));
}

test "a full bucket pours through a plant, which is not solid" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 1, 8, .tall_grass, 1);

    try std.testing.expect(try pourLiquid(&w, 8, 1, 8, .water));
    try std.testing.expectEqual(.flowing_water, w.getBlock(8, 1, 8));
}

test "an empty or milk bucket pours nothing" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try std.testing.expect(!try pourLiquid(&w, 8, 2, 8, .empty));
    try std.testing.expect(!try pourLiquid(&w, 8, 2, 8, .milk));
    try std.testing.expectEqual(.air, w.getBlock(8, 2, 8));
}

test "scooping and pouring return the world to where it started" {
    var w = try testing_world.flatWorld(std.testing.allocator, 1);
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 2, 8, .stationary_water, 0);

    const scooped = (try scoopLiquid(&w, 8, 2, 8)).?;
    try std.testing.expectEqual(.air, w.getBlock(8, 2, 8));
    try std.testing.expect(try pourLiquid(&w, 8, 2, 8, scooped));

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 2, 8));
    try std.testing.expectEqual(block.Material.water, w.getBlock(8, 2, 8).material());
}

test "a cake needs something solid under it and falls off when that goes" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try std.testing.expect(canStayAt(&w, 8, 2, 8, .cake));

    try w.setBlockWithNotify(8, 1, 8, .air);
    try std.testing.expect(!canStayAt(&w, 8, 2, 8, .cake));

    try w.setBlockWithNotify(8, 1, 8, .tall_grass);
    try std.testing.expect(!canStayAt(&w, 8, 2, 8, .cake));

    try w.setBlockWithNotify(8, 1, 8, .glass);
    try std.testing.expect(canStayAt(&w, 8, 2, 8, .cake));
}

test "a bed needs two free cells with solid ground under both" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try std.testing.expect(canPlaceBedAt(&w, 8, 2, 8, 0));

    try w.setBlockWithNotify(8, 1, 9, .air);
    try std.testing.expect(!canPlaceBedAt(&w, 8, 2, 8, 0));

    try w.setBlockWithNotify(8, 1, 9, .stone);
    try w.setBlockWithNotify(8, 2, 9, .stone);
    try std.testing.expect(!canPlaceBedAt(&w, 8, 2, 8, 0));
    try std.testing.expect(canPlaceBedAt(&w, 8, 2, 8, 2));
}

test "placing a bed lays both ends down facing the same way" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try std.testing.expect(try placeBed(&w, 8, 2, 8, 0));
    try std.testing.expectEqual(.bed, w.getBlock(8, 2, 8));
    try std.testing.expectEqual(.bed, w.getBlock(8, 2, 9));

    try std.testing.expect(!block.bedIsPillow(w.getBlockMetadata(8, 2, 8)));
    try std.testing.expect(block.bedIsPillow(w.getBlockMetadata(8, 2, 9)));
    try std.testing.expectEqual(@as(u2, 0), block.bedFacing(w.getBlockMetadata(8, 2, 9)));
}

test "each end of the bed points at the other" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();
    try std.testing.expect(try placeBed(&w, 8, 2, 8, 0));

    try std.testing.expectEqual([3]i32{ 8, 2, 9 }, bedPartner(&w, 8, 2, 8).?);
    try std.testing.expectEqual([3]i32{ 8, 2, 8 }, bedPartner(&w, 8, 2, 9).?);
    try std.testing.expectEqual(@as(?[3]i32, null), bedPartner(&w, 8, 2, 7));
}

test "breaking one end of a bed takes the other with it" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();
    try std.testing.expect(try placeBed(&w, 8, 2, 8, 0));

    try w.setBlockWithNotify(8, 2, 8, .air);
    try std.testing.expectEqual(.air, w.getBlock(8, 2, 9));
}

test "breaking the pillow end still leaves exactly one bed behind" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();
    try std.testing.expect(try placeBed(&w, 8, 2, 8, 0));
    w.dropped.clearRetainingCapacity();

    try w.setBlockWithNotify(8, 2, 9, .air);
    try std.testing.expectEqual(.air, w.getBlock(8, 2, 8));

    var beds: usize = 0;
    for (w.dropped.items) |drop| {
        if (drop.stack.id.eql(.{ .item = .bed })) beds += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), beds);
}

test "a respawn spot is found beside the bed, on solid ground with headroom" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try w.setBlockWithNotify(8, 2, 8, .bed);
    try w.setBlockMetadataWithNotify(8, 2, 8, block.bed_pillow_bit);
    try w.setBlockWithNotify(8, 2, 7, .bed);

    const spot = bedRespawnSpot(&w, 8, 2, 8, 0).?;
    try std.testing.expectEqual(@as(i32, 2), spot[1]);
    try std.testing.expect(@abs(spot[0] - 8) <= 1);
    try std.testing.expect(w.getBlock(spot[0], spot[1], spot[2]) == .air);
    try std.testing.expect(w.getBlock(spot[0], spot[1] - 1, spot[2]).isOpaqueCube());
}

test "a bed that is gone offers no respawn spot" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try std.testing.expectEqual(@as(?[3]i32, null), bedRespawnSpot(&w, 8, 2, 8, 0));
}

test "a bed walled in on every side offers no respawn spot" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try w.setBlockWithNotify(8, 2, 8, .bed);
    try w.setBlockMetadataWithNotify(8, 2, 8, block.bed_pillow_bit);
    try w.setBlockWithNotify(8, 2, 7, .bed);

    var x: i32 = 5;
    while (x <= 11) : (x += 1) {
        var z: i32 = 4;
        while (z <= 11) : (z += 1) {
            if (w.getBlock(x, 2, z) == .bed) continue;
            try w.setBlockWithNotify(x, 2, z, .stone);
        }
    }

    try std.testing.expectEqual(@as(?[3]i32, null), bedRespawnSpot(&w, 8, 2, 8, 0));
}

test "a sign post falls when the ground under it goes" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();
    try w.setBlockAndMetadataWithNotify(8, 2, 8, .sign_post, 7);
    _ = try w.addSign(8, 2, 8);
    w.dropped.clearRetainingCapacity();

    try w.setBlockWithNotify(8, 1, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 2, 8));
    try std.testing.expectEqual(@as(usize, 1), w.dropped.items.len);
    try std.testing.expect(w.dropped.items[0].stack.id.eql(.{ .item = .sign }));
    try std.testing.expect(w.signAt(8, 2, 8) == null);
}

test "a wall sign falls when the wall behind it goes, and only then" {
    var w = try testing_world.flatWorld(std.testing.allocator, 2);
    defer w.deinit();
    try w.setBlockWithNotify(8, 3, 9, .stone);
    try w.setBlockAndMetadataWithNotify(8, 3, 8, .wall_sign, 2);
    _ = try w.addSign(8, 3, 8);

    try w.setBlockWithNotify(8, 3, 7, .air);
    try std.testing.expectEqual(.wall_sign, w.getBlock(8, 3, 8));

    try w.setBlockWithNotify(8, 3, 9, .air);
    try std.testing.expectEqual(.air, w.getBlock(8, 3, 8));
    try std.testing.expect(w.signAt(8, 3, 8) == null);
}
