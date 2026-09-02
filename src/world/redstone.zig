const std = @import("std");

const assets = @import("assets");
const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const Side = block.Side;
const block_update = @import("block_update.zig");
const BlockPos = @import("BlockPos.zig");
const Chunk = @import("Chunk.zig");
const note = @import("note.zig");
const piston = @import("piston.zig");
const rail = @import("rail.zig");
const testing_world = @import("testing.zig");
const World = @import("World.zig");

var wires_provide_power: bool = true;

const repeater_output_code: [4]u2 = .{ 2, 3, 0, 1 };

const click_on_pitch: f32 = 0.6;
const click_off_pitch: f32 = 0.5;

pub fn canProvidePower(id: Block) bool {
    return switch (id) {
        .redstone_wire => wires_provide_power,
        .lever, .button, .pressure_plate_stone, .pressure_plate_planks => true,
        .rail_detector => true,
        .torch_redstone_off, .torch_redstone_on => true,
        else => false,
    };
}

fn isPowerProviderOrWire(world_map: anytype, pos: BlockPos, code: ?u2) bool {
    const id = world_map.getBlock(pos);
    if (id == .redstone_wire) return true;
    if (id == .air) return false;
    if (canProvidePower(id)) return true;
    if (!id.isRepeater()) return false;
    const want = code orelse return false;
    return want == repeater_output_code[block.repeaterFacing(world_map.getBlockMetadata(pos))];
}

pub const WireConnections = struct { west: bool, east: bool, north: bool, south: bool };

pub fn wireConnections(world_map: anytype, pos: BlockPos) WireConnections {
    var links: WireConnections = .{
        .west = isPowerProviderOrWire(world_map, pos.offset(-1, 0, 0), 1) or
            (!world_map.getBlock(pos.offset(-1, 0, 0)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(-1, -1, 0), null)),
        .east = isPowerProviderOrWire(world_map, pos.offset(1, 0, 0), 3) or
            (!world_map.getBlock(pos.offset(1, 0, 0)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(1, -1, 0), null)),
        .north = isPowerProviderOrWire(world_map, pos.offset(0, 0, -1), 2) or
            (!world_map.getBlock(pos.offset(0, 0, -1)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(0, -1, -1), null)),
        .south = isPowerProviderOrWire(world_map, pos.offset(0, 0, 1), 0) or
            (!world_map.getBlock(pos.offset(0, 0, 1)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(0, -1, 1), null)),
    };

    if (!world_map.getBlock(pos.offset(0, 1, 0)).isNormalCube()) {
        if (world_map.getBlock(pos.offset(-1, 0, 0)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(-1, 1, 0), null)) links.west = true;
        if (world_map.getBlock(pos.offset(1, 0, 0)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(1, 1, 0), null)) links.east = true;
        if (world_map.getBlock(pos.offset(0, 0, -1)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(0, 1, -1), null)) links.north = true;
        if (world_map.getBlock(pos.offset(0, 0, 1)).isNormalCube() and isPowerProviderOrWire(world_map, pos.offset(0, 1, 1), null)) links.south = true;
    }

    return links;
}

fn wirePoweringTo(world_map: *const World, pos: BlockPos, side: Side) bool {
    if (!wires_provide_power) return false;
    if (world_map.getBlockMetadata(pos) == 0) return false;
    if (side == .up) return true;

    const links = wireConnections(world_map, pos);
    if (!links.north and !links.east and !links.west and !links.south) {
        return side != .down and side != .up;
    }
    return switch (side) {
        .north => links.north and !links.west and !links.east,
        .south => links.south and !links.west and !links.east,
        .west => links.west and !links.north and !links.south,
        .east => links.east and !links.north and !links.south,
        else => false,
    };
}

fn torchPoweringTo(metadata: u4, side: Side) bool {
    return switch (metadata) {
        5 => side != .up,
        3 => side != .south,
        4 => side != .north,
        1 => side != .east,
        2 => side != .west,
        else => true,
    };
}

fn repeaterPoweringTo(metadata: u4, side: Side) bool {
    return switch (block.repeaterFacing(metadata)) {
        0 => side == .south,
        1 => side == .west,
        2 => side == .north,
        3 => side == .east,
    };
}

fn switchIndirectlyPoweringTo(metadata: u4, side: Side, floor_faces_up: bool) bool {
    if (!block.isPowered(metadata)) return false;
    return switch (metadata & block.facing_mask) {
        6 => floor_faces_up and side == .up,
        5 => side == .up,
        4 => side == .north,
        3 => side == .south,
        2 => side == .west,
        1 => side == .east,
        else => false,
    };
}

pub fn isPoweringTo(world_map: *const World, pos: BlockPos, side: Side) bool {
    const metadata = world_map.getBlockMetadata(pos);
    return switch (world_map.getBlock(pos)) {
        .redstone_wire => wirePoweringTo(world_map, pos, side),
        .torch_redstone_on => torchPoweringTo(metadata, side),
        .lever, .button => block.isPowered(metadata),
        .rail_detector => metadata & block.rail_flag_bit != 0,
        .pressure_plate_stone, .pressure_plate_planks => metadata > 0,
        .repeater_on => repeaterPoweringTo(metadata, side),
        else => false,
    };
}

pub fn isIndirectlyPoweringTo(world_map: *const World, pos: BlockPos, side: Side) bool {
    const metadata = world_map.getBlockMetadata(pos);
    return switch (world_map.getBlock(pos)) {
        .redstone_wire => wires_provide_power and wirePoweringTo(world_map, pos, side),
        .torch_redstone_on, .torch_redstone_off => side == .down and isPoweringTo(world_map, pos, side),
        .rail_detector => metadata & block.rail_flag_bit != 0 and side == .up,
        .lever => switchIndirectlyPoweringTo(metadata, side, true),
        .button => switchIndirectlyPoweringTo(metadata, side, false),
        .pressure_plate_stone, .pressure_plate_planks => metadata != 0 and side == .up,
        .repeater_on => repeaterPoweringTo(metadata, side),
        else => false,
    };
}

pub fn isBlockGettingPowered(world_map: *const World, pos: BlockPos) bool {
    return isIndirectlyPoweringTo(world_map, pos.offset(0, -1, 0), .down) or
        isIndirectlyPoweringTo(world_map, pos.offset(0, 1, 0), .up) or
        isIndirectlyPoweringTo(world_map, pos.offset(0, 0, -1), .north) or
        isIndirectlyPoweringTo(world_map, pos.offset(0, 0, 1), .south) or
        isIndirectlyPoweringTo(world_map, pos.offset(-1, 0, 0), .west) or
        isIndirectlyPoweringTo(world_map, pos.offset(1, 0, 0), .east);
}

pub fn isBlockIndirectlyProvidingPowerTo(world_map: *const World, pos: BlockPos, side: Side) bool {
    if (world_map.getBlock(pos).isNormalCube()) return isBlockGettingPowered(world_map, pos);
    return isPoweringTo(world_map, pos, side);
}

pub fn isBlockIndirectlyGettingPowered(world_map: *const World, pos: BlockPos) bool {
    return isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, -1, 0), .down) or
        isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, 1, 0), .up) or
        isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, 0, -1), .north) or
        isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, 0, 1), .south) or
        isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(-1, 0, 0), .west) or
        isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(1, 0, 0), .east);
}

const Propagation = struct {
    world_map: *World,
    pending: std.ArrayList(World.BlockPos) = .empty,
    queued: std.AutoHashMapUnmanaged(World.BlockPos, void) = .{},

    fn deinit(self: *Propagation) void {
        const allocator = self.world_map.allocator;
        self.pending.deinit(allocator);
        self.queued.deinit(allocator);
    }

    fn queue(self: *Propagation, pos: BlockPos) std.mem.Allocator.Error!void {
        const allocator = self.world_map.allocator;
        if ((try self.queued.getOrPut(allocator, pos)).found_existing) return;
        try self.pending.append(allocator, pos);
    }
};

fn maxCurrentStrength(world_map: *const World, pos: BlockPos, current: i32) i32 {
    if (world_map.getBlock(pos) != .redstone_wire) return current;
    const strength: i32 = world_map.getBlockMetadata(pos);
    return @max(strength, current);
}

fn sideStep(index: usize, x: i32, z: i32) [2]i32 {
    return switch (index) {
        0 => .{ x - 1, z },
        1 => .{ x + 1, z },
        2 => .{ x, z - 1 },
        else => .{ x, z + 1 },
    };
}

fn updateStrength(prop: *Propagation, pos: BlockPos, from: BlockPos) std.mem.Allocator.Error!void {
    const world_map = prop.world_map;
    const before = world_map.getBlockMetadata(pos);
    var strength: u4 = 0;

    wires_provide_power = false;
    const forced = isBlockIndirectlyGettingPowered(world_map, pos);
    wires_provide_power = true;

    if (forced) {
        strength = 15;
    } else {
        var best: i32 = 0;
        for (0..4) |index| {
            const step = sideStep(index, pos.x, pos.z);
            const side: BlockPos = .init(step[0], pos.y, step[1]);

            if (!std.meta.eql(side, from)) {
                best = maxCurrentStrength(world_map, side, best);
            }

            if (world_map.getBlock(side).isNormalCube() and !world_map.getBlock(pos.offset(0, 1, 0)).isNormalCube()) {
                const above = side.offset(0, 1, 0);
                if (!std.meta.eql(above, from)) {
                    best = maxCurrentStrength(world_map, above, best);
                }
            } else if (!world_map.getBlock(side).isNormalCube()) {
                const below = side.offset(0, -1, 0);
                if (!std.meta.eql(below, from)) {
                    best = maxCurrentStrength(world_map, below, best);
                }
            }
        }
        strength = if (best > 0) @intCast(best - 1) else 0;
    }

    if (before == strength) return;

    world_map.editing_blocks = true;
    try world_map.setBlockMetadataWithNotify(pos, strength);
    world_map.editing_blocks = false;

    var decremented: i32 = 0;
    for (0..4) |index| {
        const step = sideStep(index, pos.x, pos.z);
        const nx = step[0];
        const nz = step[1];
        var ny = pos.y - 1;
        if (world_map.getBlock(.init(nx, pos.y, nz)).isNormalCube()) ny += 2;

        var found = maxCurrentStrength(world_map, .init(nx, pos.y, nz), -1);
        decremented = world_map.getBlockMetadata(pos);
        if (decremented > 0) decremented -= 1;
        if (found >= 0 and found != decremented) try updateStrength(prop, .init(nx, pos.y, nz), pos);

        found = maxCurrentStrength(world_map, .init(nx, ny, nz), -1);
        decremented = world_map.getBlockMetadata(pos);
        if (decremented > 0) decremented -= 1;
        if (found >= 0 and found != decremented) try updateStrength(prop, .init(nx, ny, nz), pos);
    }

    if (before == 0 or decremented == 0) {
        try prop.queue(pos);
        try prop.queue(pos.offset(-1, 0, 0));
        try prop.queue(pos.offset(1, 0, 0));
        try prop.queue(pos.offset(0, -1, 0));
        try prop.queue(pos.offset(0, 1, 0));
        try prop.queue(pos.offset(0, 0, -1));
        try prop.queue(pos.offset(0, 0, 1));
    }
}

fn updateAndPropagateCurrentStrength(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    var prop: Propagation = .{ .world_map = world_map };
    defer prop.deinit();

    try updateStrength(&prop, pos, pos);
    for (prop.pending.items) |wire| {
        try world_map.notifyBlocksOfNeighborChange(wire, .redstone_wire);
    }
}

fn notifyWireNeighbors(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    if (world_map.getBlock(pos) != .redstone_wire) return;
    try world_map.notifyBlocksOfNeighborChange(pos, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(-1, 0, 0), .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(1, 0, 0), .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 0, -1), .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 0, 1), .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 1, 0), .redstone_wire);
}

fn notifyWireRing(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    try notifyWireNeighbors(world_map, pos.offset(-1, 0, 0));
    try notifyWireNeighbors(world_map, pos.offset(1, 0, 0));
    try notifyWireNeighbors(world_map, pos.offset(0, 0, -1));
    try notifyWireNeighbors(world_map, pos.offset(0, 0, 1));

    if (world_map.getBlock(pos.offset(-1, 0, 0)).isNormalCube()) {
        try notifyWireNeighbors(world_map, pos.offset(-1, 1, 0));
    } else {
        try notifyWireNeighbors(world_map, pos.offset(-1, -1, 0));
    }

    if (world_map.getBlock(pos.offset(1, 0, 0)).isNormalCube()) {
        try notifyWireNeighbors(world_map, pos.offset(1, 1, 0));
    } else {
        try notifyWireNeighbors(world_map, pos.offset(1, -1, 0));
    }

    if (world_map.getBlock(pos.offset(0, 0, -1)).isNormalCube()) {
        try notifyWireNeighbors(world_map, pos.offset(0, 1, -1));
    } else {
        try notifyWireNeighbors(world_map, pos.offset(0, -1, -1));
    }

    if (world_map.getBlock(pos.offset(0, 0, 1)).isNormalCube()) {
        try notifyWireNeighbors(world_map, pos.offset(0, 1, 1));
    } else {
        try notifyWireNeighbors(world_map, pos.offset(0, -1, 1));
    }
}

fn notifyAttachment(world_map: *World, pos: BlockPos, id: Block, facing: u4) std.mem.Allocator.Error!void {
    try world_map.notifyBlocksOfNeighborChange(pos, id);
    switch (facing) {
        1 => try world_map.notifyBlocksOfNeighborChange(pos.offset(-1, 0, 0), id),
        2 => try world_map.notifyBlocksOfNeighborChange(pos.offset(1, 0, 0), id),
        3 => try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 0, -1), id),
        4 => try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 0, 1), id),
        else => try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), id),
    }
}

fn notifyAround(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), id);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 1, 0), id);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(-1, 0, 0), id);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(1, 0, 0), id);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 0, -1), id);
    try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 0, 1), id);
}

fn torchSupportPowered(world_map: *const World, pos: BlockPos) bool {
    return switch (world_map.getBlockMetadata(pos)) {
        5 => isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, -1, 0), .down),
        3 => isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, 0, -1), .north),
        4 => isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(0, 0, 1), .south),
        1 => isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(-1, 0, 0), .west),
        2 => isBlockIndirectlyProvidingPowerTo(world_map, pos.offset(1, 0, 0), .east),
        else => false,
    };
}

pub const burnout_window: i64 = 100;
pub const burnout_limit: usize = 8;

fn checkForBurnout(world_map: *World, pos: BlockPos, record: bool) std.mem.Allocator.Error!bool {
    if (record) {
        try world_map.torch_updates.append(world_map.allocator, .{ .pos = pos, .time = world_map.time });
    }

    var seen: usize = 0;
    for (world_map.torch_updates.items) |entry| {
        if (!std.meta.eql(entry.pos, pos)) continue;
        seen += 1;
        if (seen >= burnout_limit) return true;
    }
    return false;
}

fn torchTick(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(pos);
    const suppressed = torchSupportPowered(world_map, pos);

    while (world_map.torch_updates.items.len > 0 and
        world_map.time - world_map.torch_updates.items[0].time > burnout_window)
    {
        _ = world_map.torch_updates.orderedRemove(0);
    }

    if (id == .torch_redstone_on) {
        if (!suppressed) return;
        try world_map.setBlockAndMetadataWithNotify(pos, .torch_redstone_off, world_map.getBlockMetadata(pos));
        if (try checkForBurnout(world_map, pos, true)) {
            world_map.playFizzAt(pos);
            try world_map.burnt_out.append(world_map.allocator, .{ .x = pos.x, .y = pos.y, .z = pos.z });
        }
        return;
    }

    if (suppressed) return;
    if (try checkForBurnout(world_map, pos, false)) return;
    try world_map.setBlockAndMetadataWithNotify(pos, .torch_redstone_on, world_map.getBlockMetadata(pos));
}

fn repeaterInputPowered(world_map: *const World, pos: BlockPos, metadata: u4) bool {
    const source: [3]i32 = switch (block.repeaterFacing(metadata)) {
        0 => .{ pos.x, pos.y, pos.z + 1 },
        1 => .{ pos.x - 1, pos.y, pos.z },
        2 => .{ pos.x, pos.y, pos.z - 1 },
        3 => .{ pos.x + 1, pos.y, pos.z },
    };
    const side: Side = switch (block.repeaterFacing(metadata)) {
        0 => .south,
        1 => .west,
        2 => .north,
        3 => .east,
    };

    if (isBlockIndirectlyProvidingPowerTo(world_map, .init(source[0], source[1], source[2]), side)) return true;
    return world_map.getBlock(.init(source[0], source[1], source[2])) == .redstone_wire and
        world_map.getBlockMetadata(.init(source[0], source[1], source[2])) > 0;
}

fn repeaterTick(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(pos);
    const metadata = world_map.getBlockMetadata(pos);
    const powered = repeaterInputPowered(world_map, pos, metadata);

    if (id == .repeater_on and !powered) {
        try world_map.setBlockAndMetadataWithNotify(pos, .repeater_off, metadata);
        return;
    }
    if (id == .repeater_on) return;

    try world_map.setBlockAndMetadataWithNotify(pos, .repeater_on, metadata);
    if (!powered) {
        try world_map.scheduleBlockUpdate(pos, .repeater_on, block.repeaterTickRate(metadata));
    }
}

fn plateProbeBox(pos: BlockPos) math.Aabb {
    const margin: f64 = 2.0 / 16.0;
    const fx: f64 = @floatFromInt(pos.x);
    const fy: f64 = @floatFromInt(pos.y);
    const fz: f64 = @floatFromInt(pos.z);
    return math.Aabb.init(
        fx + margin,
        fy,
        fz + margin,
        fx + 1.0 - margin,
        fy + 0.25,
        fz + 1.0 - margin,
    );
}

fn plateOccupied(world_map: *const World, pos: BlockPos) bool {
    const probe = world_map.entity_probe orelse return false;
    const box = plateProbeBox(pos);
    const living_only = world_map.getBlock(pos) == .pressure_plate_stone;
    return probe.anyInBox(probe.context, box, living_only);
}

fn plateSettle(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(pos);
    const was_pressed = world_map.getBlockMetadata(pos) == 1;
    const pressed = plateOccupied(world_map, pos);

    if (pressed != was_pressed) {
        try world_map.setBlockMetadataWithNotify(pos, if (pressed) 1 else 0);
        try world_map.notifyBlocksOfNeighborChange(pos, id);
        try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), id);
        world_map.playSwitchClick(pos, 0.1, if (pressed) click_on_pitch else click_off_pitch);
    }

    if (pressed) try world_map.scheduleBlockUpdate(pos, id, id.tickRate());
}

fn doorPowerChange(world_map: *World, pos: BlockPos, powered: bool) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(pos);
    const metadata = world_map.getBlockMetadata(pos);
    if (block.doorIsTop(metadata)) {
        if (world_map.getBlock(pos.offset(0, -1, 0)) == id) try doorPowerChange(world_map, pos.offset(0, -1, 0), powered);
        return;
    }
    if (block.doorIsOpen(metadata) == powered) return;
    try block_update.toggleDoor(world_map, pos);
}

fn railIsPowered(world_map: *const World, pos: BlockPos) bool {
    return isBlockIndirectlyGettingPowered(world_map, pos) or
        isBlockIndirectlyGettingPowered(world_map, pos.offset(0, 1, 0));
}

fn poweredRailChain(world_map: *const World, pos: BlockPos, metadata: u4, ahead: bool, depth: u8) bool {
    if (depth >= 8) return false;

    var cx = pos.x;
    var cy = pos.y;
    var cz = pos.z;
    var shape = metadata & block.rail_shape_mask;
    var level = true;

    switch (shape) {
        0 => if (ahead) {
            cz += 1;
        } else {
            cz -= 1;
        },
        1 => if (ahead) {
            cx -= 1;
        } else {
            cx += 1;
        },
        2 => {
            if (ahead) {
                cx -= 1;
            } else {
                cx += 1;
                cy += 1;
                level = false;
            }
            shape = 1;
        },
        3 => {
            if (ahead) {
                cx -= 1;
                cy += 1;
                level = false;
            } else {
                cx += 1;
            }
            shape = 1;
        },
        4 => {
            if (ahead) {
                cz += 1;
            } else {
                cz -= 1;
                cy += 1;
                level = false;
            }
            shape = 0;
        },
        5 => {
            if (ahead) {
                cz += 1;
                cy += 1;
                level = false;
            } else {
                cz -= 1;
            }
            shape = 0;
        },
        else => {},
    }

    if (poweredRailLink(world_map, .init(cx, cy, cz), ahead, depth, shape)) return true;
    return level and poweredRailLink(world_map, .init(cx, cy - 1, cz), ahead, depth, shape);
}

fn poweredRailLink(world_map: *const World, pos: BlockPos, ahead: bool, depth: u8, axis: u4) bool {
    if (world_map.getBlock(pos) != .rail_powered) return false;

    const metadata = world_map.getBlockMetadata(pos);
    const shape = metadata & block.rail_shape_mask;
    if (axis == 1 and (shape == 0 or shape == 4 or shape == 5)) return false;
    if (axis == 0 and (shape == 1 or shape == 2 or shape == 3)) return false;

    if (metadata & block.rail_flag_bit == 0) return false;
    if (railIsPowered(world_map, pos)) return true;
    return poweredRailChain(world_map, pos, metadata, ahead, depth + 1);
}

fn railNeighborChange(
    world_map: *World,
    pos: BlockPos,
    id: Block,
    source: Block,
) std.mem.Allocator.Error!void {
    if (!rail.canStay(world_map, pos)) return;

    if (id == .rail_powered) {
        const metadata = world_map.getBlockMetadata(pos);
        const shape = metadata & block.rail_shape_mask;
        const live = railIsPowered(world_map, pos) or
            poweredRailChain(world_map, pos, metadata, true, 0) or
            poweredRailChain(world_map, pos, metadata, false, 0);

        var changed = false;
        if (live and metadata & block.rail_flag_bit == 0) {
            try world_map.setBlockMetadataWithNotify(pos, shape | block.rail_flag_bit);
            changed = true;
        } else if (!live and metadata & block.rail_flag_bit != 0) {
            try world_map.setBlockMetadataWithNotify(pos, shape);
            changed = true;
        }

        if (changed) {
            try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), id);
            if (block.railIsSloped(shape)) try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 1, 0), id);
        }
        return;
    }

    if (id != .rail) return;
    if (!canProvidePower(source)) return;

    var logic = rail.Logic.at(world_map, pos);
    if (logic.adjacentTracks() != 3) return;
    try rail.refreshAt(world_map, pos, false);
}

fn dispenserIsPowered(world_map: *const World, pos: BlockPos) bool {
    return isBlockIndirectlyGettingPowered(world_map, pos) or
        isBlockIndirectlyGettingPowered(world_map, pos.offset(0, 1, 0));
}

fn trapdoorPowerChange(world_map: *World, pos: BlockPos, powered: bool) std.mem.Allocator.Error!void {
    if (block.trapdoorIsOpen(world_map.getBlockMetadata(pos)) == powered) return;
    try block_update.toggleTrapdoor(world_map, pos);
}

pub fn onBlockAdded(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    switch (id) {
        .redstone_wire => {
            try updateAndPropagateCurrentStrength(world_map, pos);
            try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 1, 0), .redstone_wire);
            try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), .redstone_wire);
            try notifyWireRing(world_map, pos);
        },
        .torch_redstone_on => try notifyAround(world_map, pos, id),
        .repeater_off, .repeater_on => try notifyAround(world_map, pos, id),
        .piston, .piston_sticky => try piston.onBlockAdded(world_map, pos),
        else => {},
    }
}

pub fn onBlockRemoved(world_map: *World, pos: BlockPos, id: Block, metadata: u4) std.mem.Allocator.Error!void {
    switch (id) {
        .redstone_wire => {
            try world_map.notifyBlocksOfNeighborChange(pos.offset(0, 1, 0), .redstone_wire);
            try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), .redstone_wire);
            try updateAndPropagateCurrentStrength(world_map, pos);
            try notifyWireRing(world_map, pos);
        },
        .torch_redstone_on => try notifyAround(world_map, pos, id),
        .lever, .button => {
            if (!block.isPowered(metadata)) return;
            try notifyAttachment(world_map, pos, id, metadata & block.facing_mask);
        },
        .pressure_plate_stone, .pressure_plate_planks => {
            if (metadata == 0) return;
            try world_map.notifyBlocksOfNeighborChange(pos, id);
            try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), id);
        },
        .piston_head => try piston.onHeadRemoved(world_map, pos, metadata),
        else => {},
    }
}

pub fn onNeighborChange(world_map: *World, pos: BlockPos, source: Block) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(pos);
    switch (id) {
        .redstone_wire => try updateAndPropagateCurrentStrength(world_map, pos),
        .torch_redstone_off, .torch_redstone_on => {
            try world_map.scheduleBlockUpdate(pos, id, id.tickRate());
        },
        .repeater_off, .repeater_on => {
            const metadata = world_map.getBlockMetadata(pos);
            const powered = repeaterInputPowered(world_map, pos, metadata);
            if ((id == .repeater_on) != powered) {
                try world_map.scheduleBlockUpdate(pos, id, block.repeaterTickRate(metadata));
            }
        },
        .door_wood, .door_iron => {
            if (!canProvidePower(source)) return;
            const metadata = world_map.getBlockMetadata(pos);
            if (block.doorIsTop(metadata)) {
                if (world_map.getBlock(pos.offset(0, -1, 0)) == id) try onNeighborChange(world_map, pos.offset(0, -1, 0), source);
                return;
            }
            const powered = isBlockIndirectlyGettingPowered(world_map, pos) or
                isBlockIndirectlyGettingPowered(world_map, pos.offset(0, 1, 0));
            try doorPowerChange(world_map, pos, powered);
        },
        .trapdoor => {
            if (!canProvidePower(source)) return;
            try trapdoorPowerChange(world_map, pos, isBlockIndirectlyGettingPowered(world_map, pos));
        },
        .dispenser => {
            if (!canProvidePower(source)) return;
            if (!dispenserIsPowered(world_map, pos)) return;
            try world_map.scheduleBlockUpdate(pos, id, id.tickRate());
        },
        .note_block => {
            if (!canProvidePower(source)) return;
            try note.onPowerChange(world_map, pos, isBlockGettingPowered(world_map, pos));
        },
        .rail, .rail_powered, .rail_detector => try railNeighborChange(world_map, pos, id, source),
        .piston, .piston_sticky => try piston.onNeighborChange(world_map, pos),
        .piston_head => try piston.onHeadNeighborChange(world_map, pos),
        else => {},
    }
}

pub fn handlesTick(id: Block) bool {
    return switch (id) {
        .torch_redstone_off,
        .torch_redstone_on,
        .repeater_off,
        .repeater_on,
        .button,
        .pressure_plate_stone,
        .pressure_plate_planks,
        .ore_redstone_glowing,
        .dispenser,
        .rail_detector,
        => true,
        else => false,
    };
}

pub fn tick(world_map: *World, pos: BlockPos, id: Block) std.mem.Allocator.Error!void {
    switch (id) {
        .torch_redstone_off, .torch_redstone_on => try torchTick(world_map, pos),
        .repeater_off, .repeater_on => try repeaterTick(world_map, pos),
        .button => {
            const metadata = world_map.getBlockMetadata(pos);
            if (!block.isPowered(metadata)) return;
            const facing = metadata & block.facing_mask;
            try world_map.setBlockMetadataWithNotify(pos, facing);
            try notifyAttachment(world_map, pos, id, facing);
            world_map.playSwitchClick(pos, 0.5, click_off_pitch);
        },
        .pressure_plate_stone, .pressure_plate_planks => {
            if (world_map.getBlockMetadata(pos) == 0) return;
            try plateSettle(world_map, pos);
        },
        .ore_redstone_glowing => try world_map.setBlockWithNotify(pos, .ore_redstone),
        .dispenser => {
            if (dispenserIsPowered(world_map, pos)) try world_map.dispense(pos);
        },
        .rail_detector => {
            if (world_map.getBlockMetadata(pos) & block.rail_flag_bit == 0) return;
            const occupied = detectorOccupied(world_map, pos);
            try setDetectorRail(world_map, pos, occupied);
        },
        else => {},
    }
}

const detector_inset: f64 = 2.0 / 16.0;
const detector_height: f64 = 0.25;

pub fn detectorBox(pos: BlockPos) math.Aabb {
    const fx: f64 = @floatFromInt(pos.x);
    const fy: f64 = @floatFromInt(pos.y);
    const fz: f64 = @floatFromInt(pos.z);
    return math.Aabb.init(
        fx + detector_inset,
        fy,
        fz + detector_inset,
        fx + 1.0 - detector_inset,
        fy + detector_height,
        fz + 1.0 - detector_inset,
    );
}

pub fn onMinecartOverRail(world_map: *World, cart: math.Aabb) std.mem.Allocator.Error!void {
    var x = math.util.floorDouble(cart.min_x);
    const max_x = math.util.floorDouble(cart.max_x);
    const max_y = math.util.floorDouble(cart.max_y);
    const max_z = math.util.floorDouble(cart.max_z);
    while (x <= max_x) : (x += 1) {
        var y = math.util.floorDouble(cart.min_y);
        while (y <= max_y) : (y += 1) {
            var z = math.util.floorDouble(cart.min_z);
            while (z <= max_z) : (z += 1) {
                if (world_map.getBlock(.init(x, y, z)) != .rail_detector) continue;
                if (!detectorBox(.init(x, y, z)).intersects(cart)) continue;
                try setDetectorRail(world_map, .init(x, y, z), true);
            }
        }
    }
}

fn detectorOccupied(world_map: *const World, pos: BlockPos) bool {
    const probe = world_map.entity_probe orelse return false;
    const box = detectorBox(pos);
    return probe.anyInBox(probe.context, box, false);
}

fn setDetectorRail(world_map: *World, pos: BlockPos, occupied: bool) std.mem.Allocator.Error!void {
    const metadata = world_map.getBlockMetadata(pos);
    const live = metadata & block.rail_flag_bit != 0;

    if (occupied and !live) {
        try world_map.setBlockMetadataWithNotify(pos, metadata | block.rail_flag_bit);
        try world_map.notifyBlocksOfNeighborChange(pos, .rail_detector);
        try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), .rail_detector);
    }

    if (!occupied and live) {
        try world_map.setBlockMetadataWithNotify(pos, metadata & block.rail_shape_mask);
        try world_map.notifyBlocksOfNeighborChange(pos, .rail_detector);
        try world_map.notifyBlocksOfNeighborChange(pos.offset(0, -1, 0), .rail_detector);
    }

    if (occupied) {
        try world_map.scheduleBlockUpdate(pos, .rail_detector, Block.rail_detector.tickRate());
    }
}

pub fn onEntityCollided(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(pos);
    if (id != .pressure_plate_stone and id != .pressure_plate_planks) return;
    if (world_map.getBlockMetadata(pos) == 1) return;
    try plateSettle(world_map, pos);
}

pub fn lightRedstoneOre(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!void {
    if (world_map.getBlock(pos) != .ore_redstone) return;
    try world_map.setBlockWithNotify(pos, .ore_redstone_glowing);
}

pub fn activate(world_map: *World, pos: BlockPos) std.mem.Allocator.Error!bool {
    const id = world_map.getBlock(pos);
    const metadata = world_map.getBlockMetadata(pos);
    switch (id) {
        .lever => {
            const facing = metadata & block.facing_mask;
            const flipped = block.power_bit - (metadata & block.power_bit);
            try world_map.setBlockMetadataWithNotify(pos, facing + flipped);
            world_map.playSwitchClick(pos, 0.5, if (flipped > 0) click_on_pitch else click_off_pitch);
            try notifyAttachment(world_map, pos, id, facing);
            return true;
        },
        .button => {
            if (block.isPowered(metadata)) return true;
            const facing = metadata & block.facing_mask;
            try world_map.setBlockMetadataWithNotify(pos, facing + block.power_bit);
            world_map.playSwitchClick(pos, 0.5, click_on_pitch);
            try notifyAttachment(world_map, pos, id, facing);
            try world_map.scheduleBlockUpdate(pos, id, id.tickRate());
            return true;
        },
        .repeater_off, .repeater_on => {
            const delay = (@as(u4, block.repeaterDelay(metadata)) + 1) << 2 & 12;
            try world_map.setBlockMetadataWithNotify(pos, delay | (metadata & 3));
            return true;
        },
        else => return false,
    }
}

pub fn onBlockPlaced(
    world_map: *World,
    pos: BlockPos,
    id: Block,
    player: math.Vec3,
    yaw: f32,
) std.mem.Allocator.Error!void {
    if (id.isPistonBase()) return piston.onBlockPlaced(world_map, pos, player, yaw);
    if (!id.isRepeater()) return;
    const facing = block.repeaterFacingFromYaw(yaw);
    try world_map.setBlockMetadataWithNotify(pos, facing);
    if (repeaterInputPowered(world_map, pos, facing)) {
        try world_map.scheduleBlockUpdate(pos, id, 1);
    }
}

fn flatWorld(floor_height: u32) !World {
    var w = World.init(std.testing.allocator);
    errdefer w.deinit();

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..Chunk.width) |x| {
                for (0..Chunk.width) |z| {
                    var y: u32 = 0;
                    while (y < floor_height) : (y += 1) {
                        chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
                    }
                }
            }
        }
    }
    return w;
}

fn wireWorld(dust: usize) !World {
    var w = try flatWorld(12);
    errdefer w.deinit();

    var i: usize = 0;
    while (i < dust) : (i += 1) {
        try w.setBlockWithNotify(.init(8 + @as(i32, @intCast(i)), 12, 8), .redstone_wire);
    }
    return w;
}

const floor_lever: u4 = 5 + block.power_bit;

test "a lever powers a wire run and the signal fades one level per block" {
    var w = try wireWorld(4);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, floor_lever);

    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 14), w.getBlockMetadata(.init(9, 12, 8)));
    try std.testing.expectEqual(@as(u4, 13), w.getBlockMetadata(.init(10, 12, 8)));
    try std.testing.expectEqual(@as(u4, 12), w.getBlockMetadata(.init(11, 12, 8)));
}

test "wire dies back to zero when the lever is switched off again" {
    var w = try wireWorld(3);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, floor_lever);
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(8, 12, 8)));

    _ = try activate(&w, .init(7, 12, 8));

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(9, 12, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(10, 12, 8)));
}

test "a redstone torch goes out when the block it stands on is powered" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .torch_redstone_on, 5);
    try std.testing.expect(isBlockIndirectlyGettingPowered(&w, .init(8, 13, 8)));

    try w.setBlockAndMetadataWithNotify(.init(7, 11, 8), .lever, 2);
    _ = try activate(&w, .init(7, 11, 8));

    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(.torch_redstone_off, w.getBlock(.init(8, 12, 8)));
}

test "a torch under a powered block powers the wire beside it" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(8, 12, 8), .stone);
    try w.setBlockAndMetadataWithNotify(.init(8, 11, 7), .torch_redstone_on, 4);
    try w.setBlockWithNotify(.init(9, 11, 7), .redstone_wire);

    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(9, 11, 7)));
}

test "a wire crossing under a normal cube climbs to wire on top of it" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(9, 12, 8), .stone);
    try w.setBlockWithNotify(.init(8, 12, 8), .redstone_wire);
    try w.setBlockWithNotify(.init(9, 13, 8), .redstone_wire);
    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, floor_lever);

    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 14), w.getBlockMetadata(.init(9, 13, 8)));
}

test "a repeater relays a signal only in the direction it faces" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockWithNotify(.init(8, 12, 8), .redstone_wire);
    try w.setBlockAndMetadataWithNotify(.init(9, 12, 8), .repeater_off, 1);
    try w.setBlockWithNotify(.init(10, 12, 8), .redstone_wire);
    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, floor_lever);

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(10, 12, 8)));

    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(.repeater_on, w.getBlock(.init(9, 12, 8)));
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(10, 12, 8)));
}

test "a repeater ignores a signal arriving at its output side" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(9, 12, 8), .repeater_off, 1);
    try w.setBlockWithNotify(.init(10, 12, 8), .redstone_wire);
    try w.setBlockAndMetadataWithNotify(.init(11, 12, 8), .lever, floor_lever);

    w.time += 4;
    try w.tickUpdates();

    try std.testing.expectEqual(.repeater_off, w.getBlock(.init(9, 12, 8)));
}

test "right-clicking a repeater cycles its delay through four settings" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .repeater_off, 3);

    for ([4]u4{ 1, 2, 3, 0 }) |expected| {
        _ = try activate(&w, .init(8, 12, 8));
        try std.testing.expectEqual(expected, block.repeaterDelay(w.getBlockMetadata(.init(8, 12, 8))));
        try std.testing.expectEqual(@as(u2, 3), block.repeaterFacing(w.getBlockMetadata(.init(8, 12, 8))));
    }
}

test "a button pops back out after its twenty tick hold" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(7, 12, 8), .stone);
    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .button, 1);

    _ = try activate(&w, .init(8, 12, 8));
    try std.testing.expect(block.isPowered(w.getBlockMetadata(.init(8, 12, 8))));

    w.time += 20;
    try w.tickUpdates();

    try std.testing.expect(!block.isPowered(w.getBlockMetadata(.init(8, 12, 8))));
}

test "a powered wire opens a wooden door and closes it again" {
    var w = try flatWorld(12);
    defer w.deinit();

    _ = try block_update.placeDoor(&w, .init(9, 12, 8), .door_wood, 0);
    try w.setBlockWithNotify(.init(8, 12, 8), .redstone_wire);
    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, 5);
    _ = try activate(&w, .init(7, 12, 8));

    try std.testing.expect(block.doorIsOpen(w.getBlockMetadata(.init(9, 12, 8))));

    _ = try activate(&w, .init(7, 12, 8));

    try std.testing.expect(!block.doorIsOpen(w.getBlockMetadata(.init(9, 12, 8))));
}

test "breaking a lever drops the power it was holding up" {
    var w = try wireWorld(2);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, floor_lever);
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(8, 12, 8)));

    try w.setBlockWithNotify(.init(7, 12, 8), .air);

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(9, 12, 8)));
}

test "a lever with nothing to hang on pops off the wall" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(7, 12, 8), .stone);
    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .lever, 1);
    try std.testing.expectEqual(.lever, w.getBlock(.init(8, 12, 8)));

    try w.setBlockWithNotify(.init(7, 12, 8), .air);

    try std.testing.expectEqual(.air, w.getBlock(.init(8, 12, 8)));
}

fn armedDispenser(w: *World, facing: u4) !void {
    try w.setBlockWithNotify(.init(8, 12, 8), .dispenser);
    try w.setBlockMetadataWithNotify(.init(8, 12, 8), facing);
    const state = try w.addDispenser(.init(8, 12, 8));
    state.slot(0).* = .{ .id = .{ .block = .cobblestone }, .count = 3 };
}

test "a lever powering a dispenser makes it hand one item out four ticks later" {
    var w = try flatWorld(12);
    defer w.deinit();
    try armedDispenser(&w, @intFromEnum(block.Side.south));

    w.setBlock(.init(7, 12, 8), .stone);
    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, 5 | block.power_bit);
    try std.testing.expectEqual(@as(usize, 0), w.dispensed.items.len);

    w.time += Block.dispenser.tickRate();
    try w.tickUpdates();

    try std.testing.expectEqual(@as(usize, 1), w.dispensed.items.len);
    const shot = w.dispensed.items[0];
    try std.testing.expectEqual(Block.cobblestone, shot.stack.id.block);
    try std.testing.expectEqual(@as(u8, 1), shot.stack.count);
    try std.testing.expectEqual([2]i32{ 0, 1 }, shot.step);
    try std.testing.expectEqual(@as(u8, 2), w.dispenserAt(.init(8, 12, 8)).?.items[0].?.count);
}

const SoundLog = struct {
    key: []const u8 = "",
    pitch: f32 = 0,
    count: usize = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: f64, _: f64, _: f64, _: f32, pitch: f32) void {
        const self: *SoundLog = @ptrCast(@alignCast(context));
        self.key = sound.key;
        self.pitch = pitch;
        self.count += 1;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: BlockPos) void {}

    fn sink(self: *SoundLog) World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }
};

test "a dispenser clicks over an item, twangs over an arrow and clicks higher over nothing" {
    var w = try flatWorld(12);
    defer w.deinit();
    try armedDispenser(&w, @intFromEnum(block.Side.south));

    var heard: SoundLog = .{};
    w.sound_sink = heard.sink();

    try w.dispense(.init(8, 12, 8));
    try std.testing.expectEqualStrings(assets.sounds.random.click.key, heard.key);
    try std.testing.expectEqual(@as(f32, 1.0), heard.pitch);

    w.dispenserAt(.init(8, 12, 8)).?.slot(0).* = .{ .id = .{ .item = .arrow }, .count = 1 };
    try w.dispense(.init(8, 12, 8));
    try std.testing.expectEqualStrings(assets.sounds.random.bow.key, heard.key);
    try std.testing.expectEqual(@as(f32, 1.2), heard.pitch);

    try w.dispense(.init(8, 12, 8));
    try std.testing.expectEqualStrings(assets.sounds.random.click.key, heard.key);
    try std.testing.expectEqual(@as(f32, 1.2), heard.pitch);

    try std.testing.expectEqual(@as(usize, 3), heard.count);
}

test "an unpowered dispenser is never scheduled and an empty one queues nothing" {
    var w = try flatWorld(12);
    defer w.deinit();
    try armedDispenser(&w, @intFromEnum(block.Side.west));

    w.setBlock(.init(7, 12, 8), .stone);
    w.time += Block.dispenser.tickRate();
    try w.tickUpdates();
    try std.testing.expectEqual(@as(usize, 0), w.dispensed.items.len);

    w.dispenserAt(.init(8, 12, 8)).?.slot(0).* = null;
    try w.setBlockAndMetadataWithNotify(.init(7, 12, 8), .lever, 5 | block.power_bit);
    w.time += Block.dispenser.tickRate();
    try w.tickUpdates();
    try std.testing.expectEqual(@as(usize, 0), w.dispensed.items.len);
}

test "a dispenser fires the way its metadata points" {
    var w = try flatWorld(12);
    defer w.deinit();

    try std.testing.expectEqual([2]i32{ 0, 1 }, block.dispenserStep(@intFromEnum(block.Side.south)));
    try std.testing.expectEqual([2]i32{ 0, -1 }, block.dispenserStep(@intFromEnum(block.Side.north)));
    try std.testing.expectEqual([2]i32{ 1, 0 }, block.dispenserStep(@intFromEnum(block.Side.east)));
    try std.testing.expectEqual([2]i32{ -1, 0 }, block.dispenserStep(@intFromEnum(block.Side.west)));
    try std.testing.expectEqual([2]i32{ -1, 0 }, block.dispenserStep(0));
}

test "a dispenser walled in on one side turns away from the wall when it is placed" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(8, 12, 7), .stone);
    try w.setBlockWithNotify(.init(8, 12, 8), .dispenser);
    try std.testing.expectEqual(@as(u4, @intFromEnum(block.Side.south)), w.getBlockMetadata(.init(8, 12, 8)));

    try w.setBlockWithNotify(.init(8, 12, 8), .air);
    w.setBlock(.init(8, 12, 7), .air);
    w.setBlock(.init(9, 12, 8), .stone);
    try w.setBlockWithNotify(.init(8, 12, 8), .dispenser);
    try std.testing.expectEqual(@as(u4, @intFromEnum(block.Side.west)), w.getBlockMetadata(.init(8, 12, 8)));
}

test "redstone ore lights up when touched and goes dark on its own" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(8, 12, 8), .ore_redstone);
    try lightRedstoneOre(&w, .init(8, 12, 8));
    try std.testing.expectEqual(.ore_redstone_glowing, w.getBlock(.init(8, 12, 8)));

    try w.scheduleBlockUpdate(.init(8, 12, 8), .ore_redstone_glowing, Block.ore_redstone_glowing.tickRate());
    w.time += 30;
    try w.tickUpdates();

    try std.testing.expectEqual(.ore_redstone, w.getBlock(.init(8, 12, 8)));
}

const ProbeStub = struct {
    occupied: bool = false,
    asked_living_only: bool = false,

    fn anyInBox(context: *anyopaque, _: math.Aabb, living_only: bool) bool {
        const self: *ProbeStub = @ptrCast(@alignCast(context));
        self.asked_living_only = living_only;
        return self.occupied;
    }
};

test "a pressure plate holds power while it is stood on and springs back after" {
    var w = try flatWorld(12);
    defer w.deinit();

    var stub: ProbeStub = .{};
    w.entity_probe = .{ .context = &stub, .anyInBox = ProbeStub.anyInBox };

    try w.setBlockWithNotify(.init(8, 12, 8), .pressure_plate_planks);
    try w.setBlockWithNotify(.init(9, 12, 8), .redstone_wire);

    stub.occupied = true;
    try onEntityCollided(&w, .init(8, 12, 8));

    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(.init(9, 12, 8)));

    stub.occupied = false;
    w.time += 20;
    try w.tickUpdates();

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(.init(9, 12, 8)));
}

test "a stone plate only listens for mobs where a wooden one listens for anything" {
    var w = try flatWorld(12);
    defer w.deinit();

    var stub: ProbeStub = .{};
    w.entity_probe = .{ .context = &stub, .anyInBox = ProbeStub.anyInBox };

    try w.setBlockWithNotify(.init(8, 12, 8), .pressure_plate_stone);
    try onEntityCollided(&w, .init(8, 12, 8));
    try std.testing.expect(stub.asked_living_only);

    try w.setBlockWithNotify(.init(9, 12, 8), .pressure_plate_planks);
    try onEntityCollided(&w, .init(9, 12, 8));
    try std.testing.expect(!stub.asked_living_only);
}

test "a redstone torch flicked on and off too many times burns out" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .torch_redstone_on, 5);
    try w.setBlockAndMetadataWithNotify(.init(7, 11, 8), .lever, 2);

    for (0..7) |_| {
        _ = try activate(&w, .init(7, 11, 8));
        w.time += 2;
        try w.tickUpdates();
        try std.testing.expectEqual(.torch_redstone_off, w.getBlock(.init(8, 12, 8)));

        _ = try activate(&w, .init(7, 11, 8));
        w.time += 2;
        try w.tickUpdates();
        try std.testing.expectEqual(.torch_redstone_on, w.getBlock(.init(8, 12, 8)));
    }

    _ = try activate(&w, .init(7, 11, 8));
    w.time += 2;
    try w.tickUpdates();
    _ = try activate(&w, .init(7, 11, 8));
    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(.torch_redstone_off, w.getBlock(.init(8, 12, 8)));
}

test "a lever clicks up when it is thrown and down again when it is dropped" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .lever, 5);

    var heard: SoundLog = .{};
    w.sound_sink = heard.sink();

    _ = try activate(&w, .init(8, 12, 8));
    try std.testing.expectEqualStrings(assets.sounds.random.click.key, heard.key);
    try std.testing.expectEqual(click_on_pitch, heard.pitch);

    _ = try activate(&w, .init(8, 12, 8));
    try std.testing.expectEqual(click_off_pitch, heard.pitch);
    try std.testing.expectEqual(@as(usize, 2), heard.count);
}

test "a button clicks in when it is pressed and out again when it pops back" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(.init(7, 12, 8), .stone);
    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .button, 1);

    var heard: SoundLog = .{};
    w.sound_sink = heard.sink();

    _ = try activate(&w, .init(8, 12, 8));
    try std.testing.expectEqualStrings(assets.sounds.random.click.key, heard.key);
    try std.testing.expectEqual(click_on_pitch, heard.pitch);

    w.time += 20;
    try w.tickUpdates();

    try std.testing.expectEqual(click_off_pitch, heard.pitch);
    try std.testing.expectEqual(@as(usize, 2), heard.count);
}

test "a pressure plate clicks down under a step and up again when it springs back" {
    var w = try flatWorld(12);
    defer w.deinit();

    var stub: ProbeStub = .{};
    w.entity_probe = .{ .context = &stub, .anyInBox = ProbeStub.anyInBox };
    try w.setBlockWithNotify(.init(8, 12, 8), .pressure_plate_planks);

    var heard: SoundLog = .{};
    w.sound_sink = heard.sink();

    stub.occupied = true;
    try onEntityCollided(&w, .init(8, 12, 8));
    try std.testing.expectEqualStrings(assets.sounds.random.click.key, heard.key);
    try std.testing.expectEqual(click_on_pitch, heard.pitch);

    stub.occupied = false;
    w.time += 20;
    try w.tickUpdates();

    try std.testing.expectEqual(click_off_pitch, heard.pitch);
    try std.testing.expectEqual(@as(usize, 2), heard.count);
}

test "a torch that burns out leaves a puff of smoke where it stood" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(.init(8, 12, 8), .torch_redstone_on, 5);
    try w.setBlockAndMetadataWithNotify(.init(7, 11, 8), .lever, 2);

    for (0..8) |_| {
        _ = try activate(&w, .init(7, 11, 8));
        w.time += 2;
        try w.tickUpdates();

        _ = try activate(&w, .init(7, 11, 8));
        w.time += 2;
        try w.tickUpdates();
    }

    try std.testing.expectEqual(.torch_redstone_off, w.getBlock(.init(8, 12, 8)));
    try std.testing.expectEqual(@as(usize, 1), w.burnt_out.items.len);
    try std.testing.expectEqual(World.BlockPos{ .x = 8, .y = 12, .z = 8 }, w.burnt_out.items[0]);
}
