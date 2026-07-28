const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const Side = block.Side;
const block_update = @import("block_update.zig");
const constants = @import("constants.zig");
const testing_world = @import("testing.zig");
const World = @import("world_map.zig");

var wires_provide_power: bool = true;

const repeater_output_code: [4]u2 = .{ 2, 3, 0, 1 };

pub fn canProvidePower(id: Block) bool {
    return switch (id) {
        .redstone_wire => wires_provide_power,
        .lever, .button, .pressure_plate_stone, .pressure_plate_planks => true,
        .torch_redstone_off, .torch_redstone_on => true,
        else => false,
    };
}

fn isPowerProviderOrWire(world_map: *const World, x: i32, y: i32, z: i32, code: ?u2) bool {
    const id = world_map.getBlock(x, y, z);
    if (id == .redstone_wire) return true;
    if (id == .air) return false;
    if (canProvidePower(id)) return true;
    if (!id.isRepeater()) return false;
    const want = code orelse return false;
    return want == repeater_output_code[block.repeaterFacing(world_map.getBlockMetadata(x, y, z))];
}

pub const WireConnections = struct { west: bool, east: bool, north: bool, south: bool };

pub fn wireConnections(world_map: *const World, x: i32, y: i32, z: i32) WireConnections {
    var links: WireConnections = .{
        .west = isPowerProviderOrWire(world_map, x - 1, y, z, 1) or
            (!world_map.getBlock(x - 1, y, z).isNormalCube() and isPowerProviderOrWire(world_map, x - 1, y - 1, z, null)),
        .east = isPowerProviderOrWire(world_map, x + 1, y, z, 3) or
            (!world_map.getBlock(x + 1, y, z).isNormalCube() and isPowerProviderOrWire(world_map, x + 1, y - 1, z, null)),
        .north = isPowerProviderOrWire(world_map, x, y, z - 1, 2) or
            (!world_map.getBlock(x, y, z - 1).isNormalCube() and isPowerProviderOrWire(world_map, x, y - 1, z - 1, null)),
        .south = isPowerProviderOrWire(world_map, x, y, z + 1, 0) or
            (!world_map.getBlock(x, y, z + 1).isNormalCube() and isPowerProviderOrWire(world_map, x, y - 1, z + 1, null)),
    };

    if (!world_map.getBlock(x, y + 1, z).isNormalCube()) {
        if (world_map.getBlock(x - 1, y, z).isNormalCube() and isPowerProviderOrWire(world_map, x - 1, y + 1, z, null)) links.west = true;
        if (world_map.getBlock(x + 1, y, z).isNormalCube() and isPowerProviderOrWire(world_map, x + 1, y + 1, z, null)) links.east = true;
        if (world_map.getBlock(x, y, z - 1).isNormalCube() and isPowerProviderOrWire(world_map, x, y + 1, z - 1, null)) links.north = true;
        if (world_map.getBlock(x, y, z + 1).isNormalCube() and isPowerProviderOrWire(world_map, x, y + 1, z + 1, null)) links.south = true;
    }

    return links;
}

fn wirePoweringTo(world_map: *const World, x: i32, y: i32, z: i32, side: Side) bool {
    if (!wires_provide_power) return false;
    if (world_map.getBlockMetadata(x, y, z) == 0) return false;
    if (side == .up) return true;

    const links = wireConnections(world_map, x, y, z);
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

pub fn isPoweringTo(world_map: *const World, x: i32, y: i32, z: i32, side: Side) bool {
    const metadata = world_map.getBlockMetadata(x, y, z);
    return switch (world_map.getBlock(x, y, z)) {
        .redstone_wire => wirePoweringTo(world_map, x, y, z, side),
        .torch_redstone_on => torchPoweringTo(metadata, side),
        .lever, .button => block.isPowered(metadata),
        .pressure_plate_stone, .pressure_plate_planks => metadata > 0,
        .repeater_on => repeaterPoweringTo(metadata, side),
        else => false,
    };
}

pub fn isIndirectlyPoweringTo(world_map: *const World, x: i32, y: i32, z: i32, side: Side) bool {
    const metadata = world_map.getBlockMetadata(x, y, z);
    return switch (world_map.getBlock(x, y, z)) {
        .redstone_wire => wires_provide_power and wirePoweringTo(world_map, x, y, z, side),
        .torch_redstone_on, .torch_redstone_off => side == .down and isPoweringTo(world_map, x, y, z, side),
        .lever => switchIndirectlyPoweringTo(metadata, side, true),
        .button => switchIndirectlyPoweringTo(metadata, side, false),
        .pressure_plate_stone, .pressure_plate_planks => metadata != 0 and side == .up,
        .repeater_on => repeaterPoweringTo(metadata, side),
        else => false,
    };
}

pub fn isBlockGettingPowered(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return isIndirectlyPoweringTo(world_map, x, y - 1, z, .down) or
        isIndirectlyPoweringTo(world_map, x, y + 1, z, .up) or
        isIndirectlyPoweringTo(world_map, x, y, z - 1, .north) or
        isIndirectlyPoweringTo(world_map, x, y, z + 1, .south) or
        isIndirectlyPoweringTo(world_map, x - 1, y, z, .west) or
        isIndirectlyPoweringTo(world_map, x + 1, y, z, .east);
}

pub fn isBlockIndirectlyProvidingPowerTo(world_map: *const World, x: i32, y: i32, z: i32, side: Side) bool {
    if (world_map.getBlock(x, y, z).isNormalCube()) return isBlockGettingPowered(world_map, x, y, z);
    return isPoweringTo(world_map, x, y, z, side);
}

pub fn isBlockIndirectlyGettingPowered(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return isBlockIndirectlyProvidingPowerTo(world_map, x, y - 1, z, .down) or
        isBlockIndirectlyProvidingPowerTo(world_map, x, y + 1, z, .up) or
        isBlockIndirectlyProvidingPowerTo(world_map, x, y, z - 1, .north) or
        isBlockIndirectlyProvidingPowerTo(world_map, x, y, z + 1, .south) or
        isBlockIndirectlyProvidingPowerTo(world_map, x - 1, y, z, .west) or
        isBlockIndirectlyProvidingPowerTo(world_map, x + 1, y, z, .east);
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

    fn queue(self: *Propagation, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
        const allocator = self.world_map.allocator;
        const pos: World.BlockPos = .{ .x = x, .y = y, .z = z };
        if ((try self.queued.getOrPut(allocator, pos)).found_existing) return;
        try self.pending.append(allocator, pos);
    }
};

fn maxCurrentStrength(world_map: *const World, x: i32, y: i32, z: i32, current: i32) i32 {
    if (world_map.getBlock(x, y, z) != .redstone_wire) return current;
    const strength: i32 = world_map.getBlockMetadata(x, y, z);
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

fn updateStrength(
    prop: *Propagation,
    x: i32,
    y: i32,
    z: i32,
    from_x: i32,
    from_y: i32,
    from_z: i32,
) std.mem.Allocator.Error!void {
    const world_map = prop.world_map;
    const before = world_map.getBlockMetadata(x, y, z);
    var strength: u4 = 0;

    wires_provide_power = false;
    const forced = isBlockIndirectlyGettingPowered(world_map, x, y, z);
    wires_provide_power = true;

    if (forced) {
        strength = 15;
    } else {
        var best: i32 = 0;
        for (0..4) |index| {
            const step = sideStep(index, x, z);
            const nx = step[0];
            const nz = step[1];

            if (nx != from_x or y != from_y or nz != from_z) {
                best = maxCurrentStrength(world_map, nx, y, nz, best);
            }

            if (world_map.getBlock(nx, y, nz).isNormalCube() and !world_map.getBlock(x, y + 1, z).isNormalCube()) {
                if (nx != from_x or y + 1 != from_y or nz != from_z) {
                    best = maxCurrentStrength(world_map, nx, y + 1, nz, best);
                }
            } else if (!world_map.getBlock(nx, y, nz).isNormalCube() and
                (nx != from_x or y - 1 != from_y or nz != from_z))
            {
                best = maxCurrentStrength(world_map, nx, y - 1, nz, best);
            }
        }
        strength = if (best > 0) @intCast(best - 1) else 0;
    }

    if (before == strength) return;

    world_map.editing_blocks = true;
    try world_map.setBlockMetadataWithNotify(x, y, z, strength);
    world_map.editing_blocks = false;

    var decremented: i32 = 0;
    for (0..4) |index| {
        const step = sideStep(index, x, z);
        const nx = step[0];
        const nz = step[1];
        var ny = y - 1;
        if (world_map.getBlock(nx, y, nz).isNormalCube()) ny += 2;

        var found = maxCurrentStrength(world_map, nx, y, nz, -1);
        decremented = world_map.getBlockMetadata(x, y, z);
        if (decremented > 0) decremented -= 1;
        if (found >= 0 and found != decremented) try updateStrength(prop, nx, y, nz, x, y, z);

        found = maxCurrentStrength(world_map, nx, ny, nz, -1);
        decremented = world_map.getBlockMetadata(x, y, z);
        if (decremented > 0) decremented -= 1;
        if (found >= 0 and found != decremented) try updateStrength(prop, nx, ny, nz, x, y, z);
    }

    if (before == 0 or decremented == 0) {
        try prop.queue(x, y, z);
        try prop.queue(x - 1, y, z);
        try prop.queue(x + 1, y, z);
        try prop.queue(x, y - 1, z);
        try prop.queue(x, y + 1, z);
        try prop.queue(x, y, z - 1);
        try prop.queue(x, y, z + 1);
    }
}

fn updateAndPropagateCurrentStrength(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    var prop: Propagation = .{ .world_map = world_map };
    defer prop.deinit();

    try updateStrength(&prop, x, y, z, x, y, z);
    for (prop.pending.items) |pos| {
        try world_map.notifyBlocksOfNeighborChange(pos.x, pos.y, pos.z, .redstone_wire);
    }
}

fn notifyWireNeighbors(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    if (world_map.getBlock(x, y, z) != .redstone_wire) return;
    try world_map.notifyBlocksOfNeighborChange(x, y, z, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(x - 1, y, z, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(x + 1, y, z, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(x, y, z - 1, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(x, y, z + 1, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, .redstone_wire);
    try world_map.notifyBlocksOfNeighborChange(x, y + 1, z, .redstone_wire);
}

fn notifyWireRing(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    try notifyWireNeighbors(world_map, x - 1, y, z);
    try notifyWireNeighbors(world_map, x + 1, y, z);
    try notifyWireNeighbors(world_map, x, y, z - 1);
    try notifyWireNeighbors(world_map, x, y, z + 1);

    if (world_map.getBlock(x - 1, y, z).isNormalCube()) {
        try notifyWireNeighbors(world_map, x - 1, y + 1, z);
    } else {
        try notifyWireNeighbors(world_map, x - 1, y - 1, z);
    }

    if (world_map.getBlock(x + 1, y, z).isNormalCube()) {
        try notifyWireNeighbors(world_map, x + 1, y + 1, z);
    } else {
        try notifyWireNeighbors(world_map, x + 1, y - 1, z);
    }

    if (world_map.getBlock(x, y, z - 1).isNormalCube()) {
        try notifyWireNeighbors(world_map, x, y + 1, z - 1);
    } else {
        try notifyWireNeighbors(world_map, x, y - 1, z - 1);
    }

    if (world_map.getBlock(x, y, z + 1).isNormalCube()) {
        try notifyWireNeighbors(world_map, x, y + 1, z + 1);
    } else {
        try notifyWireNeighbors(world_map, x, y - 1, z + 1);
    }
}

fn notifyAttachment(world_map: *World, x: i32, y: i32, z: i32, id: Block, facing: u4) std.mem.Allocator.Error!void {
    try world_map.notifyBlocksOfNeighborChange(x, y, z, id);
    switch (facing) {
        1 => try world_map.notifyBlocksOfNeighborChange(x - 1, y, z, id),
        2 => try world_map.notifyBlocksOfNeighborChange(x + 1, y, z, id),
        3 => try world_map.notifyBlocksOfNeighborChange(x, y, z - 1, id),
        4 => try world_map.notifyBlocksOfNeighborChange(x, y, z + 1, id),
        else => try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, id),
    }
}

fn notifyAround(world_map: *World, x: i32, y: i32, z: i32, id: Block) std.mem.Allocator.Error!void {
    try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, id);
    try world_map.notifyBlocksOfNeighborChange(x, y + 1, z, id);
    try world_map.notifyBlocksOfNeighborChange(x - 1, y, z, id);
    try world_map.notifyBlocksOfNeighborChange(x + 1, y, z, id);
    try world_map.notifyBlocksOfNeighborChange(x, y, z - 1, id);
    try world_map.notifyBlocksOfNeighborChange(x, y, z + 1, id);
}

fn torchSupportPowered(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return switch (world_map.getBlockMetadata(x, y, z)) {
        5 => isBlockIndirectlyProvidingPowerTo(world_map, x, y - 1, z, .down),
        3 => isBlockIndirectlyProvidingPowerTo(world_map, x, y, z - 1, .north),
        4 => isBlockIndirectlyProvidingPowerTo(world_map, x, y, z + 1, .south),
        1 => isBlockIndirectlyProvidingPowerTo(world_map, x - 1, y, z, .west),
        2 => isBlockIndirectlyProvidingPowerTo(world_map, x + 1, y, z, .east),
        else => false,
    };
}

pub const burnout_window: i64 = 100;
pub const burnout_limit: usize = 8;

fn checkForBurnout(world_map: *World, x: i32, y: i32, z: i32, record: bool) std.mem.Allocator.Error!bool {
    const pos: World.BlockPos = .{ .x = x, .y = y, .z = z };
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

fn torchTick(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    const suppressed = torchSupportPowered(world_map, x, y, z);

    while (world_map.torch_updates.items.len > 0 and
        world_map.time - world_map.torch_updates.items[0].time > burnout_window)
    {
        _ = world_map.torch_updates.orderedRemove(0);
    }

    if (id == .torch_redstone_on) {
        if (!suppressed) return;
        try world_map.setBlockAndMetadataWithNotify(x, y, z, .torch_redstone_off, world_map.getBlockMetadata(x, y, z));
        _ = try checkForBurnout(world_map, x, y, z, true);
        return;
    }

    if (suppressed) return;
    if (try checkForBurnout(world_map, x, y, z, false)) return;
    try world_map.setBlockAndMetadataWithNotify(x, y, z, .torch_redstone_on, world_map.getBlockMetadata(x, y, z));
}

fn repeaterInputPowered(world_map: *const World, x: i32, y: i32, z: i32, metadata: u4) bool {
    const source: [3]i32 = switch (block.repeaterFacing(metadata)) {
        0 => .{ x, y, z + 1 },
        1 => .{ x - 1, y, z },
        2 => .{ x, y, z - 1 },
        3 => .{ x + 1, y, z },
    };
    const side: Side = switch (block.repeaterFacing(metadata)) {
        0 => .south,
        1 => .west,
        2 => .north,
        3 => .east,
    };

    if (isBlockIndirectlyProvidingPowerTo(world_map, source[0], source[1], source[2], side)) return true;
    return world_map.getBlock(source[0], source[1], source[2]) == .redstone_wire and
        world_map.getBlockMetadata(source[0], source[1], source[2]) > 0;
}

fn repeaterTick(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    const metadata = world_map.getBlockMetadata(x, y, z);
    const powered = repeaterInputPowered(world_map, x, y, z, metadata);

    if (id == .repeater_on and !powered) {
        try world_map.setBlockAndMetadataWithNotify(x, y, z, .repeater_off, metadata);
        return;
    }
    if (id == .repeater_on) return;

    try world_map.setBlockAndMetadataWithNotify(x, y, z, .repeater_on, metadata);
    if (!powered) {
        try world_map.scheduleBlockUpdate(x, y, z, .repeater_on, block.repeaterTickRate(metadata));
    }
}

fn plateProbeBox(x: i32, y: i32, z: i32) [2][3]f64 {
    const margin: f64 = 2.0 / 16.0;
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    const fz: f64 = @floatFromInt(z);
    return .{
        .{ fx + margin, fy, fz + margin },
        .{ fx + 1.0 - margin, fy + 0.25, fz + 1.0 - margin },
    };
}

fn plateOccupied(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const probe = world_map.entity_probe orelse return false;
    const box = plateProbeBox(x, y, z);
    const living_only = world_map.getBlock(x, y, z) == .pressure_plate_stone;
    return probe.anyInBox(probe.context, box[0], box[1], living_only);
}

fn plateSettle(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    const was_pressed = world_map.getBlockMetadata(x, y, z) == 1;
    const pressed = plateOccupied(world_map, x, y, z);

    if (pressed != was_pressed) {
        try world_map.setBlockMetadataWithNotify(x, y, z, if (pressed) 1 else 0);
        try world_map.notifyBlocksOfNeighborChange(x, y, z, id);
        try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, id);
    }

    if (pressed) try world_map.scheduleBlockUpdate(x, y, z, id, id.tickRate());
}

fn doorPowerChange(world_map: *World, x: i32, y: i32, z: i32, powered: bool) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    const metadata = world_map.getBlockMetadata(x, y, z);
    if (block.doorIsTop(metadata)) {
        if (world_map.getBlock(x, y - 1, z) == id) try doorPowerChange(world_map, x, y - 1, z, powered);
        return;
    }
    if (block.doorIsOpen(metadata) == powered) return;
    try block_update.toggleDoor(world_map, x, y, z);
}

fn trapdoorPowerChange(world_map: *World, x: i32, y: i32, z: i32, powered: bool) std.mem.Allocator.Error!void {
    if (block.trapdoorIsOpen(world_map.getBlockMetadata(x, y, z)) == powered) return;
    try block_update.toggleTrapdoor(world_map, x, y, z);
}

pub fn onBlockAdded(world_map: *World, x: i32, y: i32, z: i32, id: Block) std.mem.Allocator.Error!void {
    switch (id) {
        .redstone_wire => {
            try updateAndPropagateCurrentStrength(world_map, x, y, z);
            try world_map.notifyBlocksOfNeighborChange(x, y + 1, z, .redstone_wire);
            try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, .redstone_wire);
            try notifyWireRing(world_map, x, y, z);
        },
        .torch_redstone_on => try notifyAround(world_map, x, y, z, id),
        .repeater_off, .repeater_on => try notifyAround(world_map, x, y, z, id),
        else => {},
    }
}

pub fn onBlockRemoved(world_map: *World, x: i32, y: i32, z: i32, id: Block, metadata: u4) std.mem.Allocator.Error!void {
    switch (id) {
        .redstone_wire => {
            try world_map.notifyBlocksOfNeighborChange(x, y + 1, z, .redstone_wire);
            try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, .redstone_wire);
            try updateAndPropagateCurrentStrength(world_map, x, y, z);
            try notifyWireRing(world_map, x, y, z);
        },
        .torch_redstone_on => try notifyAround(world_map, x, y, z, id),
        .lever, .button => {
            if (!block.isPowered(metadata)) return;
            try notifyAttachment(world_map, x, y, z, id, metadata & block.facing_mask);
        },
        .pressure_plate_stone, .pressure_plate_planks => {
            if (metadata == 0) return;
            try world_map.notifyBlocksOfNeighborChange(x, y, z, id);
            try world_map.notifyBlocksOfNeighborChange(x, y - 1, z, id);
        },
        else => {},
    }
}

pub fn onNeighborChange(world_map: *World, x: i32, y: i32, z: i32, source: Block) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    switch (id) {
        .redstone_wire => try updateAndPropagateCurrentStrength(world_map, x, y, z),
        .torch_redstone_off, .torch_redstone_on => {
            try world_map.scheduleBlockUpdate(x, y, z, id, id.tickRate());
        },
        .repeater_off, .repeater_on => {
            const metadata = world_map.getBlockMetadata(x, y, z);
            const powered = repeaterInputPowered(world_map, x, y, z, metadata);
            if ((id == .repeater_on) != powered) {
                try world_map.scheduleBlockUpdate(x, y, z, id, block.repeaterTickRate(metadata));
            }
        },
        .door_wood, .door_iron => {
            if (!canProvidePower(source)) return;
            const metadata = world_map.getBlockMetadata(x, y, z);
            if (block.doorIsTop(metadata)) {
                if (world_map.getBlock(x, y - 1, z) == id) try onNeighborChange(world_map, x, y - 1, z, source);
                return;
            }
            const powered = isBlockIndirectlyGettingPowered(world_map, x, y, z) or
                isBlockIndirectlyGettingPowered(world_map, x, y + 1, z);
            try doorPowerChange(world_map, x, y, z, powered);
        },
        .trapdoor => {
            if (!canProvidePower(source)) return;
            try trapdoorPowerChange(world_map, x, y, z, isBlockIndirectlyGettingPowered(world_map, x, y, z));
        },
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
        => true,
        else => false,
    };
}

pub fn tick(world_map: *World, x: i32, y: i32, z: i32, id: Block) std.mem.Allocator.Error!void {
    switch (id) {
        .torch_redstone_off, .torch_redstone_on => try torchTick(world_map, x, y, z),
        .repeater_off, .repeater_on => try repeaterTick(world_map, x, y, z),
        .button => {
            const metadata = world_map.getBlockMetadata(x, y, z);
            if (!block.isPowered(metadata)) return;
            const facing = metadata & block.facing_mask;
            try world_map.setBlockMetadataWithNotify(x, y, z, facing);
            try notifyAttachment(world_map, x, y, z, id, facing);
        },
        .pressure_plate_stone, .pressure_plate_planks => {
            if (world_map.getBlockMetadata(x, y, z) == 0) return;
            try plateSettle(world_map, x, y, z);
        },
        .ore_redstone_glowing => try world_map.setBlockWithNotify(x, y, z, .ore_redstone),
        else => {},
    }
}

pub fn onEntityCollided(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    const id = world_map.getBlock(x, y, z);
    if (id != .pressure_plate_stone and id != .pressure_plate_planks) return;
    if (world_map.getBlockMetadata(x, y, z) == 1) return;
    try plateSettle(world_map, x, y, z);
}

pub fn lightRedstoneOre(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!void {
    if (world_map.getBlock(x, y, z) != .ore_redstone) return;
    try world_map.setBlockWithNotify(x, y, z, .ore_redstone_glowing);
}

pub fn activate(world_map: *World, x: i32, y: i32, z: i32) std.mem.Allocator.Error!bool {
    const id = world_map.getBlock(x, y, z);
    const metadata = world_map.getBlockMetadata(x, y, z);
    switch (id) {
        .lever => {
            const facing = metadata & block.facing_mask;
            const flipped = block.power_bit - (metadata & block.power_bit);
            try world_map.setBlockMetadataWithNotify(x, y, z, facing + flipped);
            try notifyAttachment(world_map, x, y, z, id, facing);
            return true;
        },
        .button => {
            if (block.isPowered(metadata)) return true;
            const facing = metadata & block.facing_mask;
            try world_map.setBlockMetadataWithNotify(x, y, z, facing + block.power_bit);
            try notifyAttachment(world_map, x, y, z, id, facing);
            try world_map.scheduleBlockUpdate(x, y, z, id, id.tickRate());
            return true;
        },
        .repeater_off, .repeater_on => {
            const delay = (@as(u4, block.repeaterDelay(metadata)) + 1) << 2 & 12;
            try world_map.setBlockMetadataWithNotify(x, y, z, delay | (metadata & 3));
            return true;
        },
        else => return false,
    }
}

pub fn onBlockPlaced(
    world_map: *World,
    x: i32,
    y: i32,
    z: i32,
    id: Block,
    yaw: f32,
) std.mem.Allocator.Error!void {
    if (!id.isRepeater()) return;
    const facing = block.repeaterFacingFromYaw(yaw);
    try world_map.setBlockMetadataWithNotify(x, y, z, facing);
    if (repeaterInputPowered(world_map, x, y, z, facing)) {
        try world_map.scheduleBlockUpdate(x, y, z, id, 1);
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
            for (0..constants.chunk_width) |x| {
                for (0..constants.chunk_width) |z| {
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
        try w.setBlockWithNotify(8 + @as(i32, @intCast(i)), 12, 8, .redstone_wire);
    }
    return w;
}

const floor_lever: u4 = 5 + block.power_bit;

test "a lever powers a wire run and the signal fades one level per block" {
    var w = try wireWorld(4);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, floor_lever);

    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 14), w.getBlockMetadata(9, 12, 8));
    try std.testing.expectEqual(@as(u4, 13), w.getBlockMetadata(10, 12, 8));
    try std.testing.expectEqual(@as(u4, 12), w.getBlockMetadata(11, 12, 8));
}

test "wire dies back to zero when the lever is switched off again" {
    var w = try wireWorld(3);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, floor_lever);
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(8, 12, 8));

    _ = try activate(&w, 7, 12, 8);

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(9, 12, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(10, 12, 8));
}

test "a redstone torch goes out when the block it stands on is powered" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 12, 8, .torch_redstone_on, 5);
    try std.testing.expect(isBlockIndirectlyGettingPowered(&w, 8, 13, 8));

    try w.setBlockAndMetadataWithNotify(7, 11, 8, .lever, 2);
    _ = try activate(&w, 7, 11, 8);

    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(.torch_redstone_off, w.getBlock(8, 12, 8));
}

test "a torch under a powered block powers the wire beside it" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(8, 12, 8, .stone);
    try w.setBlockAndMetadataWithNotify(8, 11, 7, .torch_redstone_on, 4);
    try w.setBlockWithNotify(9, 11, 7, .redstone_wire);

    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(9, 11, 7));
}

test "a wire crossing under a normal cube climbs to wire on top of it" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(9, 12, 8, .stone);
    try w.setBlockWithNotify(8, 12, 8, .redstone_wire);
    try w.setBlockWithNotify(9, 13, 8, .redstone_wire);
    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, floor_lever);

    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 14), w.getBlockMetadata(9, 13, 8));
}

test "a repeater relays a signal only in the direction it faces" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockWithNotify(8, 12, 8, .redstone_wire);
    try w.setBlockAndMetadataWithNotify(9, 12, 8, .repeater_off, 1);
    try w.setBlockWithNotify(10, 12, 8, .redstone_wire);
    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, floor_lever);

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(10, 12, 8));

    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(.repeater_on, w.getBlock(9, 12, 8));
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(10, 12, 8));
}

test "a repeater ignores a signal arriving at its output side" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(9, 12, 8, .repeater_off, 1);
    try w.setBlockWithNotify(10, 12, 8, .redstone_wire);
    try w.setBlockAndMetadataWithNotify(11, 12, 8, .lever, floor_lever);

    w.time += 4;
    try w.tickUpdates();

    try std.testing.expectEqual(.repeater_off, w.getBlock(9, 12, 8));
}

test "right-clicking a repeater cycles its delay through four settings" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 12, 8, .repeater_off, 3);

    for ([4]u4{ 1, 2, 3, 0 }) |expected| {
        _ = try activate(&w, 8, 12, 8);
        try std.testing.expectEqual(expected, block.repeaterDelay(w.getBlockMetadata(8, 12, 8)));
        try std.testing.expectEqual(@as(u2, 3), block.repeaterFacing(w.getBlockMetadata(8, 12, 8)));
    }
}

test "a button pops back out after its twenty tick hold" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(7, 12, 8, .stone);
    try w.setBlockAndMetadataWithNotify(8, 12, 8, .button, 1);

    _ = try activate(&w, 8, 12, 8);
    try std.testing.expect(block.isPowered(w.getBlockMetadata(8, 12, 8)));

    w.time += 20;
    try w.tickUpdates();

    try std.testing.expect(!block.isPowered(w.getBlockMetadata(8, 12, 8)));
}

test "a powered wire opens a wooden door and closes it again" {
    var w = try flatWorld(12);
    defer w.deinit();

    _ = try block_update.placeDoor(&w, 9, 12, 8, .door_wood, 0);
    try w.setBlockWithNotify(8, 12, 8, .redstone_wire);
    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, 5);
    _ = try activate(&w, 7, 12, 8);

    try std.testing.expect(block.doorIsOpen(w.getBlockMetadata(9, 12, 8)));

    _ = try activate(&w, 7, 12, 8);

    try std.testing.expect(!block.doorIsOpen(w.getBlockMetadata(9, 12, 8)));
}

test "breaking a lever drops the power it was holding up" {
    var w = try wireWorld(2);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, floor_lever);
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(8, 12, 8));

    try w.setBlockWithNotify(7, 12, 8, .air);

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(9, 12, 8));
}

test "a lever with nothing to hang on pops off the wall" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(7, 12, 8, .stone);
    try w.setBlockAndMetadataWithNotify(8, 12, 8, .lever, 1);
    try std.testing.expectEqual(.lever, w.getBlock(8, 12, 8));

    try w.setBlockWithNotify(7, 12, 8, .air);

    try std.testing.expectEqual(.air, w.getBlock(8, 12, 8));
}

test "redstone ore lights up when touched and goes dark on its own" {
    var w = try flatWorld(12);
    defer w.deinit();

    w.setBlock(8, 12, 8, .ore_redstone);
    try lightRedstoneOre(&w, 8, 12, 8);
    try std.testing.expectEqual(.ore_redstone_glowing, w.getBlock(8, 12, 8));

    try w.scheduleBlockUpdate(8, 12, 8, .ore_redstone_glowing, Block.ore_redstone_glowing.tickRate());
    w.time += 30;
    try w.tickUpdates();

    try std.testing.expectEqual(.ore_redstone, w.getBlock(8, 12, 8));
}

const ProbeStub = struct {
    occupied: bool = false,
    asked_living_only: bool = false,

    fn anyInBox(context: *anyopaque, _: [3]f64, _: [3]f64, living_only: bool) bool {
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

    try w.setBlockWithNotify(8, 12, 8, .pressure_plate_planks);
    try w.setBlockWithNotify(9, 12, 8, .redstone_wire);

    stub.occupied = true;
    try onEntityCollided(&w, 8, 12, 8);

    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 15), w.getBlockMetadata(9, 12, 8));

    stub.occupied = false;
    w.time += 20;
    try w.tickUpdates();

    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(9, 12, 8));
}

test "a stone plate only listens for mobs where a wooden one listens for anything" {
    var w = try flatWorld(12);
    defer w.deinit();

    var stub: ProbeStub = .{};
    w.entity_probe = .{ .context = &stub, .anyInBox = ProbeStub.anyInBox };

    try w.setBlockWithNotify(8, 12, 8, .pressure_plate_stone);
    try onEntityCollided(&w, 8, 12, 8);
    try std.testing.expect(stub.asked_living_only);

    try w.setBlockWithNotify(9, 12, 8, .pressure_plate_planks);
    try onEntityCollided(&w, 9, 12, 8);
    try std.testing.expect(!stub.asked_living_only);
}

test "a redstone torch flicked on and off too many times burns out" {
    var w = try flatWorld(12);
    defer w.deinit();

    try w.setBlockAndMetadataWithNotify(8, 12, 8, .torch_redstone_on, 5);
    try w.setBlockAndMetadataWithNotify(7, 11, 8, .lever, 2);

    for (0..7) |_| {
        _ = try activate(&w, 7, 11, 8);
        w.time += 2;
        try w.tickUpdates();
        try std.testing.expectEqual(.torch_redstone_off, w.getBlock(8, 12, 8));

        _ = try activate(&w, 7, 11, 8);
        w.time += 2;
        try w.tickUpdates();
        try std.testing.expectEqual(.torch_redstone_on, w.getBlock(8, 12, 8));
    }

    _ = try activate(&w, 7, 11, 8);
    w.time += 2;
    try w.tickUpdates();
    _ = try activate(&w, 7, 11, 8);
    w.time += 2;
    try w.tickUpdates();

    try std.testing.expectEqual(.torch_redstone_off, w.getBlock(8, 12, 8));
}
