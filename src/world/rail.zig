const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const World = @import("World.zig");

pub const Pos = struct { x: i32, y: i32, z: i32 };

const max_links = 4;

pub const Logic = struct {
    world_map: *World,
    x: i32,
    y: i32,
    z: i32,
    flagged: bool,
    links: [max_links]Pos = undefined,
    count: usize = 0,

    pub fn at(world_map: *World, x: i32, y: i32, z: i32) Logic {
        const id = world_map.getBlock(x, y, z);
        const flagged = block.railIsFlagged(id);
        const metadata = world_map.getBlockMetadata(x, y, z);
        var self: Logic = .{
            .world_map = world_map,
            .x = x,
            .y = y,
            .z = z,
            .flagged = flagged,
        };
        self.setConnections(if (flagged) metadata & block.rail_shape_mask else metadata);
        return self;
    }

    fn add(self: *Logic, x: i32, y: i32, z: i32) void {
        if (self.count == max_links) return;
        self.links[self.count] = .{ .x = x, .y = y, .z = z };
        self.count += 1;
    }

    fn removeAt(self: *Logic, index: usize) void {
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.links[i] = self.links[i + 1];
        self.count -= 1;
    }

    fn setConnections(self: *Logic, shape: u4) void {
        self.count = 0;
        switch (shape) {
            0 => {
                self.add(self.x, self.y, self.z - 1);
                self.add(self.x, self.y, self.z + 1);
            },
            1 => {
                self.add(self.x - 1, self.y, self.z);
                self.add(self.x + 1, self.y, self.z);
            },
            2 => {
                self.add(self.x - 1, self.y, self.z);
                self.add(self.x + 1, self.y + 1, self.z);
            },
            3 => {
                self.add(self.x - 1, self.y + 1, self.z);
                self.add(self.x + 1, self.y, self.z);
            },
            4 => {
                self.add(self.x, self.y + 1, self.z - 1);
                self.add(self.x, self.y, self.z + 1);
            },
            5 => {
                self.add(self.x, self.y, self.z - 1);
                self.add(self.x, self.y + 1, self.z + 1);
            },
            6 => {
                self.add(self.x + 1, self.y, self.z);
                self.add(self.x, self.y, self.z + 1);
            },
            7 => {
                self.add(self.x - 1, self.y, self.z);
                self.add(self.x, self.y, self.z + 1);
            },
            8 => {
                self.add(self.x - 1, self.y, self.z);
                self.add(self.x, self.y, self.z - 1);
            },
            9 => {
                self.add(self.x + 1, self.y, self.z);
                self.add(self.x, self.y, self.z - 1);
            },
            else => {},
        }
    }

    fn refresh(self: *Logic) void {
        var index: usize = 0;
        while (index < self.count) {
            if (self.logicAt(self.links[index])) |neighbour| {
                var found = neighbour;
                if (found.isConnectedTo(self)) {
                    self.links[index] = .{ .x = found.x, .y = found.y, .z = found.z };
                    index += 1;
                    continue;
                }
            }
            self.removeAt(index);
        }
    }

    fn isTrack(self: *const Logic, x: i32, y: i32, z: i32) bool {
        if (block.isRail(self.world_map.getBlock(x, y, z))) return true;
        if (block.isRail(self.world_map.getBlock(x, y + 1, z))) return true;
        return block.isRail(self.world_map.getBlock(x, y - 1, z));
    }

    fn logicAt(self: *const Logic, pos: Pos) ?Logic {
        if (block.isRail(self.world_map.getBlock(pos.x, pos.y, pos.z))) {
            return Logic.at(self.world_map, pos.x, pos.y, pos.z);
        }
        if (block.isRail(self.world_map.getBlock(pos.x, pos.y + 1, pos.z))) {
            return Logic.at(self.world_map, pos.x, pos.y + 1, pos.z);
        }
        if (block.isRail(self.world_map.getBlock(pos.x, pos.y - 1, pos.z))) {
            return Logic.at(self.world_map, pos.x, pos.y - 1, pos.z);
        }
        return null;
    }

    fn isConnectedTo(self: *const Logic, other: *const Logic) bool {
        for (self.links[0..self.count]) |link| {
            if (link.x == other.x and link.z == other.z) return true;
        }
        return false;
    }

    fn linksTo(self: *const Logic, x: i32, z: i32) bool {
        for (self.links[0..self.count]) |link| {
            if (link.x == x and link.z == z) return true;
        }
        return false;
    }

    pub fn adjacentTracks(self: *const Logic) u8 {
        var found: u8 = 0;
        if (self.isTrack(self.x, self.y, self.z - 1)) found += 1;
        if (self.isTrack(self.x, self.y, self.z + 1)) found += 1;
        if (self.isTrack(self.x - 1, self.y, self.z)) found += 1;
        if (self.isTrack(self.x + 1, self.y, self.z)) found += 1;
        return found;
    }

    fn canConnect(self: *const Logic, other: *const Logic) bool {
        if (self.isConnectedTo(other)) return true;
        return self.count != 2;
    }

    fn connectTo(self: *Logic, other: *const Logic) std.mem.Allocator.Error!void {
        self.add(other.x, other.y, other.z);
        const north = self.linksTo(self.x, self.z - 1);
        const south = self.linksTo(self.x, self.z + 1);
        const west = self.linksTo(self.x - 1, self.z);
        const east = self.linksTo(self.x + 1, self.z);

        var shape: i8 = -1;
        if (north or south) shape = 0;
        if (west or east) shape = 1;

        if (!self.flagged) {
            if (south and east and !north and !west) shape = 6;
            if (south and west and !north and !east) shape = 7;
            if (north and west and !south and !east) shape = 8;
            if (north and east and !south and !west) shape = 9;
        }

        shape = self.slopeFor(shape);
        if (shape < 0) shape = 0;

        try self.writeShape(@intCast(shape));
    }

    fn slopeFor(self: *const Logic, shape: i8) i8 {
        var out = shape;
        if (out == 0) {
            if (block.isRail(self.world_map.getBlock(self.x, self.y + 1, self.z - 1))) out = 4;
            if (block.isRail(self.world_map.getBlock(self.x, self.y + 1, self.z + 1))) out = 5;
        }
        if (out == 1) {
            if (block.isRail(self.world_map.getBlock(self.x + 1, self.y + 1, self.z))) out = 2;
            if (block.isRail(self.world_map.getBlock(self.x - 1, self.y + 1, self.z))) out = 3;
        }
        return out;
    }

    fn writeShape(self: *Logic, shape: u4) std.mem.Allocator.Error!void {
        const kept = self.world_map.getBlockMetadata(self.x, self.y, self.z) & block.rail_flag_bit;
        const metadata = if (self.flagged) kept | shape else shape;
        try self.world_map.setBlockMetadataWithNotify(self.x, self.y, self.z, metadata);
    }

    fn probe(self: *Logic, x: i32, y: i32, z: i32) bool {
        var neighbour = self.logicAt(.{ .x = x, .y = y, .z = z }) orelse return false;
        neighbour.refresh();
        return neighbour.canConnect(self);
    }

    pub fn place(self: *Logic, powered: bool, force: bool) std.mem.Allocator.Error!void {
        const north = self.probe(self.x, self.y, self.z - 1);
        const south = self.probe(self.x, self.y, self.z + 1);
        const west = self.probe(self.x - 1, self.y, self.z);
        const east = self.probe(self.x + 1, self.y, self.z);

        var shape: i8 = -1;
        if ((north or south) and !west and !east) shape = 0;
        if ((west or east) and !north and !south) shape = 1;

        if (!self.flagged) {
            if (south and east and !north and !west) shape = 6;
            if (south and west and !north and !east) shape = 7;
            if (north and west and !south and !east) shape = 8;
            if (north and east and !south and !west) shape = 9;
        }

        if (shape == -1) {
            if (north or south) shape = 0;
            if (west or east) shape = 1;

            if (!self.flagged) {
                if (powered) {
                    if (south and east) shape = 6;
                    if (west and south) shape = 7;
                    if (east and north) shape = 9;
                    if (north and west) shape = 8;
                } else {
                    if (north and west) shape = 8;
                    if (east and north) shape = 9;
                    if (west and south) shape = 7;
                    if (south and east) shape = 6;
                }
            }
        }

        shape = self.slopeFor(shape);
        if (shape < 0) shape = 0;

        self.setConnections(@intCast(shape));
        const kept = self.world_map.getBlockMetadata(self.x, self.y, self.z) & block.rail_flag_bit;
        const written: u4 = if (self.flagged) kept | @as(u4, @intCast(shape)) else @intCast(shape);

        if (!force and self.world_map.getBlockMetadata(self.x, self.y, self.z) == written) return;
        try self.world_map.setBlockMetadataWithNotify(self.x, self.y, self.z, written);

        for (self.links[0..self.count]) |link| {
            var neighbour = self.logicAt(link) orelse continue;
            neighbour.refresh();
            if (neighbour.canConnect(self)) try neighbour.connectTo(self);
        }
    }
};

pub fn refreshAt(world_map: *World, x: i32, y: i32, z: i32, force: bool) std.mem.Allocator.Error!void {
    if (!block.isRail(world_map.getBlock(x, y, z))) return;
    var logic = Logic.at(world_map, x, y, z);
    const redstone = @import("redstone.zig");
    try logic.place(redstone.isBlockIndirectlyGettingPowered(world_map, x, y, z), force);
}

pub fn canStay(world_map: *const World, x: i32, y: i32, z: i32) bool {
    const id = world_map.getBlock(x, y, z);
    if (!world_map.getBlock(x, y - 1, z).isNormalCube()) return false;

    const shape = block.railShape(id, world_map.getBlockMetadata(x, y, z));
    return switch (shape) {
        2 => world_map.getBlock(x + 1, y, z).isNormalCube(),
        3 => world_map.getBlock(x - 1, y, z).isNormalCube(),
        4 => world_map.getBlock(x, y, z - 1).isNormalCube(),
        5 => world_map.getBlock(x, y, z + 1).isNormalCube(),
        else => true,
    };
}

pub fn canPlaceAt(world_map: *const World, x: i32, y: i32, z: i32) bool {
    return world_map.getBlock(x, y - 1, z).isNormalCube();
}

test "a lone rail lies flat along z" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockWithNotify(8, 12, 8, .rail);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8));
}

test "a second rail beside the first turns the pair along x" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockWithNotify(8, 12, 8, .rail);
    try w.setBlockWithNotify(9, 12, 8, .rail);

    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(8, 12, 8));
    try std.testing.expectEqual(@as(u4, 1), w.getBlockMetadata(9, 12, 8));
}

test "a rail on a corner bends into one of the four curve shapes" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockWithNotify(9, 12, 8, .rail);
    try w.setBlockWithNotify(8, 12, 8, .rail);
    try w.setBlockWithNotify(8, 12, 9, .rail);

    const corner = w.getBlockMetadata(8, 12, 8);
    try std.testing.expectEqual(@as(u4, 6), corner);
}

test "a rail climbs onto the rail one step above it" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    w.setBlock(9, 12, 8, .stone);
    try w.setBlockWithNotify(8, 12, 8, .rail);
    try w.setBlockWithNotify(9, 13, 8, .rail);

    try std.testing.expectEqual(@as(u4, 2), w.getBlockMetadata(8, 12, 8));
}

test "a lever switches a powered rail on, and its shape still follows the track" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockWithNotify(8, 12, 8, .rail_powered);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8) & block.rail_flag_bit);

    try w.setBlockAndMetadataWithNotify(7, 12, 8, .lever, 5 | block.power_bit);
    try std.testing.expectEqual(block.rail_flag_bit, w.getBlockMetadata(8, 12, 8) & block.rail_flag_bit);

    try w.setBlockWithNotify(9, 12, 8, .rail_powered);
    const metadata = w.getBlockMetadata(8, 12, 8);
    try std.testing.expectEqual(@as(u4, 1), metadata & block.rail_shape_mask);
    try std.testing.expectEqual(block.rail_flag_bit, metadata & block.rail_flag_bit);

    try w.setBlockWithNotify(7, 12, 8, .air);
    try std.testing.expectEqual(@as(u4, 0), w.getBlockMetadata(8, 12, 8) & block.rail_flag_bit);
}

test "a powered rail never curves, where a plain rail does" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try w.setBlockWithNotify(9, 12, 8, .rail);
    try w.setBlockWithNotify(8, 12, 9, .rail);
    try w.setBlockWithNotify(8, 12, 8, .rail_powered);

    try std.testing.expect(block.railShape(.rail_powered, w.getBlockMetadata(8, 12, 8)) < 6);
}

test "a rail needs solid ground and reports when it has none" {
    const testing_world = @import("testing.zig");
    var w = try testing_world.flatWorld(std.testing.allocator, 12);
    defer w.deinit();

    try std.testing.expect(canPlaceAt(&w, 8, 12, 8));
    try std.testing.expect(!canPlaceAt(&w, 8, 14, 8));

    try w.setBlockWithNotify(8, 12, 8, .rail);
    try std.testing.expect(canStay(&w, 8, 12, 8));
}
