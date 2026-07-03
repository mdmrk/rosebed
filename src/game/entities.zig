const std = @import("std");
const math = @import("math");
const world = @import("world");

const FallingBlock = @import("falling_block.zig");
const Inventory = @import("inventory.zig");
const ItemEntity = @import("item_entity.zig");
const Pig = @import("pig.zig");
const Player = @import("player.zig");

const Entities = @This();

items: std.ArrayList(ItemEntity) = .empty,
falling_blocks: std.ArrayList(FallingBlock) = .empty,
pigs: std.ArrayList(Pig) = .empty,

pub fn deinit(self: *Entities, gpa: std.mem.Allocator) void {
    self.items.deinit(gpa);
    self.falling_blocks.deinit(gpa);
    self.pigs.deinit(gpa);
}

pub fn count(self: *const Entities) usize {
    return self.items.items.len + self.falling_blocks.items.len + self.pigs.items.len;
}

pub fn dropStack(
    self: *Entities,
    gpa: std.mem.Allocator,
    x: i32,
    y: i32,
    z: i32,
    stack: Inventory.ItemStack,
    rand: *world.JavaRandom,
) !void {
    const position = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + @as(f64, rand.nextFloat()) * 0.7 + 0.15,
        @as(f64, @floatFromInt(y)) + @as(f64, rand.nextFloat()) * 0.7 + 0.15,
        @as(f64, @floatFromInt(z)) + @as(f64, rand.nextFloat()) * 0.7 + 0.15,
    );
    try self.items.append(gpa, ItemEntity.spawn(position, stack, rand));
}

pub fn spawnFallingBlock(self: *Entities, gpa: std.mem.Allocator, x: i32, y: i32, z: i32, block_id: u8) !void {
    const position = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + 0.5,
        @floatFromInt(y),
        @as(f64, @floatFromInt(z)) + 0.5,
    );
    try self.falling_blocks.append(gpa, FallingBlock.spawn(position, block_id));
}

pub fn spawnPig(self: *Entities, gpa: std.mem.Allocator, position: math.Vec3) !void {
    try self.pigs.append(gpa, Pig.spawn(position));
}

pub fn tickItems(self: *Entities, world_map: *const world.World, player: *Player) void {
    var i: usize = 0;
    while (i < self.items.items.len) {
        const item = &self.items.items[i];
        item.tick(world_map);

        var picked_up = false;
        if (item.canPickUp() and item.base.boundingBox().intersects(player.base.boundingBox())) {
            const leftover = player.inventory.addStack(item.stack);
            if (leftover == 0) {
                picked_up = true;
            } else {
                item.stack.count = leftover;
            }
        }

        if (picked_up or item.isExpired()) {
            _ = self.items.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn tickPigs(self: *Entities, world_map: *const world.World, rand: *world.JavaRandom) void {
    for (self.pigs.items) |*pig| pig.tick(world_map, rand);
}

test "walking over a dropped stack picks it up" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = world.block.stone, .count = 3 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 0), entities.items.items.len);
    try std.testing.expectEqual(@as(u8, 3), player.inventory.slots[0].?.count);
}

test "a stack that does not fit keeps whatever is left over on the ground" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(8, 1, 8));
    for (&player.inventory.slots) |*slot| {
        slot.* = .{ .id = world.block.stone, .count = Inventory.max_stack_size };
    }
    player.inventory.slots[0].?.count = Inventory.max_stack_size - 1;

    try entities.dropStack(gpa, 8, 1, 8, .{ .id = world.block.stone, .count = 5 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;
    entities.items.items[0].base.position = player.base.position;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expectEqual(@as(u8, 4), entities.items.items[0].stack.count);
}

test "an item out of reach of the player is left alone" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    var player = Player.spawn(math.Vec3.init(0, 1, 0));
    try entities.dropStack(gpa, 8, 1, 8, .{ .id = world.block.stone, .count = 1 }, &w.rand);
    entities.items.items[0].pickup_delay = 0;

    entities.tickItems(&w, &player);

    try std.testing.expectEqual(@as(usize, 1), entities.items.items.len);
    try std.testing.expect(player.inventory.slots[0] == null);
}

test "count sums every kind of entity" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var entities: Entities = .{};
    defer entities.deinit(gpa);

    try entities.dropStack(gpa, 0, 1, 0, .{ .id = world.block.stone, .count = 1 }, &w.rand);
    try entities.spawnFallingBlock(gpa, 0, 5, 0, world.block.sand);
    try entities.spawnPig(gpa, math.Vec3.init(0, 1, 0));

    try std.testing.expectEqual(@as(usize, 3), entities.count());
}
