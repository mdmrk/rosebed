const std = @import("std");

const math = @import("math");

const block = @import("block.zig");
const Block = block.Block;
const constants = @import("constants.zig");
const World = @import("world_map.zig");

const max_decay: i32 = 8;
const falling: u4 = 8;

const Direction = struct { dx: i32, dz: i32 };

const flow_order = [4]Direction{
    .{ .dx = -1, .dz = 0 },
    .{ .dx = 1, .dz = 0 },
    .{ .dx = 0, .dz = -1 },
    .{ .dx = 0, .dz = 1 },
};

const vector_order = [4]Direction{
    .{ .dx = -1, .dz = 0 },
    .{ .dx = 0, .dz = -1 },
    .{ .dx = 1, .dz = 0 },
    .{ .dx = 0, .dz = 1 },
};

pub fn percentAir(meta: u4) f32 {
    const level: u4 = if (meta >= falling) 0 else meta;
    return @as(f32, @floatFromInt(@as(u32, level) + 1)) / 9.0;
}

const Fluid = enum {
    water,
    lava,

    fn of(target: block.Material) ?Fluid {
        return switch (target) {
            .water => .water,
            .lava => .lava,
            else => null,
        };
    }

    fn at(world_map: anytype, x: i32, y: i32, z: i32) ?Fluid {
        return Fluid.of(world_map.getBlock(x, y, z).material());
    }

    fn material(self: Fluid) block.Material {
        return switch (self) {
            .water => .water,
            .lava => .lava,
        };
    }

    fn flowing(self: Fluid) Block {
        return switch (self) {
            .water => .flowing_water,
            .lava => .flowing_lava,
        };
    }

    fn stationary(self: Fluid) Block {
        return switch (self) {
            .water => .stationary_water,
            .lava => .stationary_lava,
        };
    }

    fn spreadPerBlock(self: Fluid) i32 {
        return switch (self) {
            .water => 1,
            .lava => 2,
        };
    }

    fn holds(self: Fluid, id: Block) bool {
        return id.material() == self.material();
    }

    fn flowDecay(self: Fluid, world_map: anytype, x: i32, y: i32, z: i32) i32 {
        if (!self.holds(world_map.getBlock(x, y, z))) return -1;
        return world_map.getBlockMetadata(x, y, z);
    }

    fn effectiveFlowDecay(self: Fluid, world_map: anytype, x: i32, y: i32, z: i32) i32 {
        const decay = self.flowDecay(world_map, x, y, z);
        if (decay >= max_decay) return 0;
        return decay;
    }

    fn isSource(self: Fluid, world_map: *const World, x: i32, y: i32, z: i32) bool {
        return self.holds(world_map.getBlock(x, y, z)) and world_map.getBlockMetadata(x, y, z) == 0;
    }

    fn canDisplace(self: Fluid, world_map: *const World, x: i32, y: i32, z: i32) bool {
        const target = world_map.getBlock(x, y, z).material();
        if (target == self.material()) return false;
        if (target == .lava) return false;
        return !blocksFlow(world_map, x, y, z);
    }

    fn isBlockSolid(self: Fluid, world_map: anytype, x: i32, y: i32, z: i32) bool {
        const target = world_map.getBlock(x, y, z).material();
        if (target == self.material()) return false;
        if (target == .ice) return false;
        return target.isSolid();
    }
};

fn blocksFlow(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const id = world_map.getBlock(x, y, z);
    if (id == .reed) return true;
    return id.isSolid();
}

const Smallest = struct {
    decay: i32,
    adjacent_sources: u32,

    fn merge(self: Smallest, fluid: Fluid, world_map: *const World, x: i32, y: i32, z: i32) Smallest {
        var decay = fluid.flowDecay(world_map, x, y, z);
        if (decay < 0) return self;

        var adjacent_sources = self.adjacent_sources;
        if (decay == 0) adjacent_sources += 1;
        if (decay >= max_decay) decay = 0;

        return .{
            .decay = if (self.decay >= 0 and decay >= self.decay) self.decay else decay,
            .adjacent_sources = adjacent_sources,
        };
    }
};

fn calculateFlowCost(fluid: Fluid, world_map: *const World, x: i32, y: i32, z: i32, distance: u32, came_from: usize) u32 {
    var cost: u32 = 1000;

    for (flow_order, 0..) |direction, index| {
        if (index / 2 == came_from / 2 and index != came_from) continue;

        const nx = x + direction.dx;
        const nz = z + direction.dz;
        if (blocksFlow(world_map, nx, y, nz)) continue;
        if (fluid.isSource(world_map, nx, y, nz)) continue;

        if (!blocksFlow(world_map, nx, y - 1, nz)) return distance;
        if (distance < 4) cost = @min(cost, calculateFlowCost(fluid, world_map, nx, y, nz, distance + 1, index));
    }

    return cost;
}

fn optimalFlowDirections(fluid: Fluid, world_map: *const World, x: i32, y: i32, z: i32) [4]bool {
    var costs: [4]u32 = undefined;

    for (flow_order, 0..) |direction, index| {
        costs[index] = 1000;

        const nx = x + direction.dx;
        const nz = z + direction.dz;
        if (blocksFlow(world_map, nx, y, nz)) continue;
        if (fluid.isSource(world_map, nx, y, nz)) continue;

        costs[index] = if (!blocksFlow(world_map, nx, y - 1, nz))
            0
        else
            calculateFlowCost(fluid, world_map, nx, y, nz, 1, index);
    }

    const cheapest = @min(@min(costs[0], costs[1]), @min(costs[2], costs[3]));

    var optimal: [4]bool = undefined;
    for (costs, 0..) |cost, index| optimal[index] = cost == cheapest;
    return optimal;
}

fn flowInto(fluid: Fluid, world_map: *World, x: i32, y: i32, z: i32, decay: u4) !void {
    if (!fluid.canDisplace(world_map, x, y, z)) return;

    const washed_away = world_map.getBlock(x, y, z);
    if (washed_away != .air and fluid == .water) {
        const meta = world_map.getBlockMetadata(x, y, z);
        if (washed_away.drop(meta, &world_map.rand)) |stack| {
            try world_map.dropped.append(world_map.allocator, .{
                .pos = .{ .x = x, .y = y, .z = z },
                .stack = stack,
            });
        }
    }

    try world_map.setBlockAndMetadataWithNotify(x, y, z, fluid.flowing(), decay);
}

fn settle(fluid: Fluid, world_map: *World, x: i32, y: i32, z: i32) !void {
    const meta = world_map.getBlockMetadata(x, y, z);
    world_map.setBlock(x, y, z, fluid.stationary());
    world_map.setBlockMetadata(x, y, z, meta);
    try world_map.markChanged(x, y, z);
}

fn checkForHarden(fluid: Fluid, world_map: *World, x: i32, y: i32, z: i32) !void {
    if (fluid != .lava) return;

    const touches_water = for ([_][3]i32{
        .{ 0, 0, -1 },
        .{ 0, 0, 1 },
        .{ -1, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
    }) |offset| {
        if (world_map.getBlock(x + offset[0], y + offset[1], z + offset[2]).material() == .water) break true;
    } else false;
    if (!touches_water) return;

    const meta = world_map.getBlockMetadata(x, y, z);
    if (meta == 0) {
        try world_map.setBlockWithNotify(x, y, z, .obsidian);
    } else if (meta <= 4) {
        try world_map.setBlockWithNotify(x, y, z, .cobblestone);
    }

    triggerLavaMixEffects(world_map, x, y, z);
}

fn triggerLavaMixEffects(world_map: *World, x: i32, y: i32, z: i32) void {
    world_map.playFizzAt(x, y, z);
}

pub fn onBlockAdded(world_map: *World, x: i32, y: i32, z: i32) !void {
    const fluid = Fluid.at(world_map, x, y, z) orelse return;
    try checkForHarden(fluid, world_map, x, y, z);

    if (world_map.getBlock(x, y, z) != fluid.flowing()) return;
    try world_map.scheduleBlockUpdate(x, y, z, fluid.flowing(), fluid.flowing().tickRate());
}

pub fn onNeighborChange(world_map: *World, x: i32, y: i32, z: i32) !void {
    const fluid = Fluid.at(world_map, x, y, z) orelse return;
    try checkForHarden(fluid, world_map, x, y, z);

    if (world_map.getBlock(x, y, z) != fluid.stationary()) return;

    const meta = world_map.getBlockMetadata(x, y, z);
    world_map.setBlock(x, y, z, fluid.flowing());
    world_map.setBlockMetadata(x, y, z, meta);
    try world_map.markChanged(x, y, z);
    try world_map.scheduleBlockUpdate(x, y, z, fluid.flowing(), fluid.flowing().tickRate());
}

pub fn tick(world_map: *World, x: i32, y: i32, z: i32) !void {
    const fluid = Fluid.at(world_map, x, y, z) orelse return;
    const spread_per_block = fluid.spreadPerBlock();

    var decay = fluid.flowDecay(world_map, x, y, z);
    var settles = true;

    if (decay > 0) {
        var smallest: Smallest = .{ .decay = -100, .adjacent_sources = 0 };
        smallest = smallest.merge(fluid, world_map, x - 1, y, z);
        smallest = smallest.merge(fluid, world_map, x + 1, y, z);
        smallest = smallest.merge(fluid, world_map, x, y, z - 1);
        smallest = smallest.merge(fluid, world_map, x, y, z + 1);

        var settled = smallest.decay + spread_per_block;
        if (settled >= max_decay or smallest.decay < 0) settled = -1;

        const above = fluid.flowDecay(world_map, x, y + 1, z);
        if (above >= 0) settled = if (above >= max_decay) above else above + max_decay;

        if (smallest.adjacent_sources >= 2 and fluid == .water) {
            const below = world_map.getBlock(x, y - 1, z).material();
            if (below.isSolid()) {
                settled = 0;
            } else if (below == fluid.material() and world_map.getBlockMetadata(x, y, z) == 0) {
                settled = 0;
            }
        }

        if (fluid == .lava and decay < max_decay and settled < max_decay and settled > decay and world_map.rand.nextIntBound(4) != 0) {
            settled = decay;
            settles = false;
        }

        if (settled != decay) {
            decay = settled;
            if (settled < 0) {
                try world_map.setBlockWithNotify(x, y, z, .air);
            } else {
                try world_map.setBlockMetadataWithNotify(x, y, z, @intCast(settled));
                try world_map.scheduleBlockUpdate(x, y, z, fluid.flowing(), fluid.flowing().tickRate());
                try world_map.notifyBlocksOfNeighborChange(x, y, z, fluid.flowing());
            }
        } else if (settles) {
            try settle(fluid, world_map, x, y, z);
        }
    } else {
        try settle(fluid, world_map, x, y, z);
    }

    if (fluid.canDisplace(world_map, x, y - 1, z)) {
        const below_decay = if (decay >= max_decay) decay else decay + max_decay;
        try world_map.setBlockAndMetadataWithNotify(x, y - 1, z, fluid.flowing(), @intCast(below_decay));
        return;
    }

    if (decay < 0) return;
    if (decay != 0 and !blocksFlow(world_map, x, y - 1, z)) return;

    const spread_decay: i32 = if (decay >= max_decay) 1 else decay + spread_per_block;
    if (spread_decay >= max_decay) return;

    const optimal = optimalFlowDirections(fluid, world_map, x, y, z);
    for (flow_order, optimal) |direction, allowed| {
        if (!allowed) continue;
        try flowInto(fluid, world_map, x + direction.dx, y, z + direction.dz, @intCast(spread_decay));
    }
}

pub fn flowVector(world_map: anytype, x: i32, y: i32, z: i32) math.Vec3 {
    var vector = math.Vec3.init(0, 0, 0);
    const fluid = Fluid.at(world_map, x, y, z) orelse return vector;
    const decay = fluid.effectiveFlowDecay(world_map, x, y, z);

    for (vector_order) |direction| {
        const nx = x + direction.dx;
        const nz = z + direction.dz;
        var neighbor_decay = fluid.effectiveFlowDecay(world_map, nx, y, nz);

        if (neighbor_decay < 0) {
            if (world_map.getBlock(nx, y, nz).material().isSolid()) continue;
            neighbor_decay = fluid.effectiveFlowDecay(world_map, nx, y - 1, nz);
            if (neighbor_decay < 0) continue;
            const difference: f64 = @floatFromInt(neighbor_decay - (decay - max_decay));
            vector = vector.add(math.Vec3.init(
                @as(f64, @floatFromInt(direction.dx)) * difference,
                0,
                @as(f64, @floatFromInt(direction.dz)) * difference,
            ));
        } else {
            const difference: f64 = @floatFromInt(neighbor_decay - decay);
            vector = vector.add(math.Vec3.init(
                @as(f64, @floatFromInt(direction.dx)) * difference,
                0,
                @as(f64, @floatFromInt(direction.dz)) * difference,
            ));
        }
    }

    if (world_map.getBlockMetadata(x, y, z) >= falling) {
        const blocked = fluid.isBlockSolid(world_map, x, y, z - 1) or
            fluid.isBlockSolid(world_map, x, y, z + 1) or
            fluid.isBlockSolid(world_map, x - 1, y, z) or
            fluid.isBlockSolid(world_map, x + 1, y, z) or
            fluid.isBlockSolid(world_map, x, y + 1, z - 1) or
            fluid.isBlockSolid(world_map, x, y + 1, z + 1) or
            fluid.isBlockSolid(world_map, x - 1, y + 1, z) or
            fluid.isBlockSolid(world_map, x + 1, y + 1, z);
        if (blocked) vector = vector.normalize().add(math.Vec3.init(0, -6, 0));
    }

    return vector.normalize();
}

pub fn flowAngle(world_map: anytype, x: i32, y: i32, z: i32) ?f32 {
    const vector = flowVector(world_map, x, y, z);
    if (vector.x == 0.0 and vector.z == 0.0) return null;
    return @floatCast(std.math.atan2(vector.z, vector.x) - std.math.pi * 0.5);
}

fn testWorld(floor_top_y: u32) !World {
    var world_map = World.init(std.testing.allocator);
    errdefer world_map.deinit();

    var chunk_x: i32 = -1;
    while (chunk_x <= 1) : (chunk_x += 1) {
        var chunk_z: i32 = -1;
        while (chunk_z <= 1) : (chunk_z += 1) {
            const chunk = try world_map.createChunk(chunk_x, chunk_z);
            for (0..constants.chunk_width) |x| {
                for (0..constants.chunk_width) |z| {
                    var y: u32 = 0;
                    while (y < floor_top_y) : (y += 1) {
                        chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
                    }
                }
            }
        }
    }
    return world_map;
}

fn runTicks(world_map: *World, count: usize) !void {
    for (0..count) |_| {
        world_map.time += 1;
        try world_map.tickUpdates();
        world_map.changed.clearRetainingCapacity();
        world_map.dropped.clearRetainingCapacity();
    }
}

fn placeSource(world_map: *World, x: i32, y: i32, z: i32) !void {
    try world_map.setBlockAndMetadataWithNotify(x, y, z, .flowing_water, 0);
}

fn placeLava(world_map: *World, x: i32, y: i32, z: i32, decay: u4) !void {
    try world_map.setBlockAndMetadataWithNotify(x, y, z, .flowing_lava, decay);
}

test "getPercentAir matches BlockFluid's level-to-height table" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 9.0), percentAir(0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 9.0), percentAir(7), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 9.0), percentAir(8), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 9.0), percentAir(15), 1.0e-6);
}

test "a source settles into stationary water and spreads to its four neighbours" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 100);

    try std.testing.expectEqual(.stationary_water, world_map.getBlock(8, 64, 8));
    try std.testing.expectEqual(@as(u4, 0), world_map.getBlockMetadata(8, 64, 8));

    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| {
        const x = 8 + offset[0];
        const z = 8 + offset[1];
        try std.testing.expect(Fluid.water.holds(world_map.getBlock(x, 64, z)));
        try std.testing.expectEqual(@as(u4, 1), world_map.getBlockMetadata(x, 64, z));
    }
}

test "water spreads exactly seven blocks from a source" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 100);

    try std.testing.expect(Fluid.water.holds(world_map.getBlock(15, 64, 8)));
    try std.testing.expectEqual(@as(u4, 7), world_map.getBlockMetadata(15, 64, 8));
    try std.testing.expectEqual(.air, world_map.getBlock(16, 64, 8));
}

test "water falls straight down and marks the falling metadata bit" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(8, 63, 8, .air);
    world_map.setBlock(8, 62, 8, .air);
    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 20);

    for ([_]i32{ 63, 62 }) |y| {
        try std.testing.expect(Fluid.water.holds(world_map.getBlock(8, y, 8)));
        try std.testing.expect(world_map.getBlockMetadata(8, y, 8) >= falling);
    }
}

test "two sources one block apart turn the gap between them into a source" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeSource(&world_map, 7, 64, 8);
    try placeSource(&world_map, 9, 64, 8);
    try runTicks(&world_map, 20);

    try std.testing.expectEqual(.stationary_water, world_map.getBlock(8, 64, 8));
    try std.testing.expectEqual(@as(u4, 0), world_map.getBlockMetadata(8, 64, 8));
}

test "removing the source drains every block it filled" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 100);
    try std.testing.expect(Fluid.water.holds(world_map.getBlock(12, 64, 8)));

    try world_map.setBlockWithNotify(8, 64, 8, .air);
    try runTicks(&world_map, 200);

    var x: i32 = 1;
    while (x <= 15) : (x += 1) {
        var z: i32 = 1;
        while (z <= 15) : (z += 1) {
            try std.testing.expectEqual(.air, world_map.getBlock(x, 64, z));
        }
    }
}

test "flowing water prefers the direction with a hole to fall into" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(11, 63, 8, .air);
    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 10);

    try std.testing.expect(Fluid.water.holds(world_map.getBlock(9, 64, 8)));
    try std.testing.expectEqual(.air, world_map.getBlock(7, 64, 8));
    try std.testing.expectEqual(.air, world_map.getBlock(8, 64, 7));
    try std.testing.expectEqual(.air, world_map.getBlock(8, 64, 9));
}

test "a solid wall stops water from spreading through it" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    var z: i32 = 0;
    while (z < 16) : (z += 1) world_map.setBlock(10, 64, z, .stone);

    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 100);

    try std.testing.expect(Fluid.water.holds(world_map.getBlock(9, 64, 8)));
    try std.testing.expectEqual(.stone, world_map.getBlock(10, 64, 8));
    try std.testing.expectEqual(.air, world_map.getBlock(11, 64, 8));
}

test "water washes a flower away and leaves its drop behind" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(9, 64, 8, .rose);
    try placeSource(&world_map, 8, 64, 8);

    for (0..6) |_| {
        world_map.time += 1;
        try world_map.tickUpdates();
    }

    try std.testing.expect(Fluid.water.holds(world_map.getBlock(9, 64, 8)));

    var found_rose = false;
    for (world_map.dropped.items) |drop| {
        if (drop.stack.id.eql(.{ .block = .rose })) found_rose = true;
    }
    try std.testing.expect(found_rose);
}

test "breaking a block beside settled water lets it flow back in" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(8, 64, 8, .stationary_water);
    world_map.setBlock(9, 64, 8, .stone);
    try runTicks(&world_map, 5);
    try std.testing.expectEqual(.stationary_water, world_map.getBlock(8, 64, 8));

    try world_map.setBlockWithNotify(9, 64, 8, .air);
    try runTicks(&world_map, 10);

    try std.testing.expect(Fluid.water.holds(world_map.getBlock(9, 64, 8)));
}

test "the flow vector points away from the source" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 20);

    const flow = flowVector(&world_map, 10, 64, 8);
    try std.testing.expect(flow.x > 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), flow.z, 1.0e-9);
}

test "still water has no flow direction to rotate its surface texture" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeSource(&world_map, 8, 64, 8);
    try runTicks(&world_map, 20);

    try std.testing.expect(flowAngle(&world_map, 8, 64, 8) == null);
    try std.testing.expect(flowAngle(&world_map, 10, 64, 8) != null);
}

test "a lava source spreads exactly three blocks and settles into stationary lava" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeLava(&world_map, 8, 64, 8, 0);
    try runTicks(&world_map, 200);

    try std.testing.expectEqual(.stationary_lava, world_map.getBlock(8, 64, 8));
    try std.testing.expectEqual(@as(u4, 0), world_map.getBlockMetadata(8, 64, 8));

    for ([_]u4{ 2, 4, 6 }, 1..) |expected, distance| {
        const x = 8 + @as(i32, @intCast(distance));
        try std.testing.expect(Fluid.lava.holds(world_map.getBlock(x, 64, 8)));
        try std.testing.expectEqual(expected, world_map.getBlockMetadata(x, 64, 8));
    }
    try std.testing.expectEqual(.air, world_map.getBlock(12, 64, 8));
}

test "lava falls straight down and marks the falling metadata bit" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(8, 63, 8, .air);
    world_map.setBlock(8, 62, 8, .air);
    try placeLava(&world_map, 8, 64, 8, 0);
    try runTicks(&world_map, 200);

    for ([_]i32{ 63, 62 }) |y| {
        try std.testing.expect(Fluid.lava.holds(world_map.getBlock(8, y, 8)));
        try std.testing.expect(world_map.getBlockMetadata(8, y, 8) >= falling);
    }
}

test "water beside a lava source hardens it into obsidian" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeLava(&world_map, 8, 64, 8, 0);
    try world_map.setBlockWithNotify(9, 64, 8, .stationary_water);

    try std.testing.expectEqual(.obsidian, world_map.getBlock(8, 64, 8));
}

test "water beside flowing lava hardens it into cobblestone up to level four" {
    for ([_]u4{ 1, 2, 4 }) |decay| {
        var world_map = try testWorld(64);
        defer world_map.deinit();

        try placeLava(&world_map, 8, 64, 8, decay);
        try world_map.setBlockWithNotify(9, 64, 8, .stationary_water);

        try std.testing.expectEqual(.cobblestone, world_map.getBlock(8, 64, 8));
    }
}

test "water leaves thinner lava molten" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    try placeLava(&world_map, 8, 64, 8, 6);
    try world_map.setBlockWithNotify(9, 64, 8, .stationary_water);

    try std.testing.expect(Fluid.lava.holds(world_map.getBlock(8, 64, 8)));
}

test "lava flowing towards water hardens where the two meet" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(10, 64, 8, .stationary_water);
    try placeLava(&world_map, 8, 64, 8, 0);
    try runTicks(&world_map, 200);

    try std.testing.expectEqual(.cobblestone, world_map.getBlock(9, 64, 8));
    try std.testing.expect(Fluid.lava.holds(world_map.getBlock(8, 64, 8)));
}

test "lava washes water away instead of dropping it as an item" {
    var world_map = try testWorld(64);
    defer world_map.deinit();

    world_map.setBlock(8, 63, 8, .air);
    world_map.setBlock(8, 62, 8, .stationary_water);
    try placeLava(&world_map, 8, 64, 8, 0);
    try runTicks(&world_map, 200);

    try std.testing.expect(Fluid.lava.holds(world_map.getBlock(8, 62, 8)));
    try std.testing.expectEqual(@as(usize, 0), world_map.dropped.items.len);
}
