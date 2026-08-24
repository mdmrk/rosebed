const std = @import("std");

const math = @import("math");
const world = @import("world");

const ItemEntity = @import("ItemEntity.zig");
const Player = @import("../Player.zig");

const PickupFx = @This();

item: ItemEntity,
age: u8 = 0,

pub const duration: u8 = 3;
pub const target_offset: f64 = -0.5;

pub fn spawn(item: ItemEntity) PickupFx {
    var frozen = item;
    frozen.base.prev_position = frozen.base.position;
    return .{ .item = frozen };
}

pub fn tick(self: *PickupFx) void {
    self.age += 1;
}

pub fn isExpired(self: PickupFx) bool {
    return self.age >= duration;
}

pub fn swallowed(self: PickupFx, player: *const Player, partial_ticks: f32) ItemEntity {
    const linear = (@as(f32, @floatFromInt(self.age)) + partial_ticks) / @as(f32, duration);
    const eased: f64 = linear * linear;

    const from = self.item.base.position;
    const mouth = player.base.renderPosition(partial_ticks);
    const to = math.Vec3.init(
        mouth.x,
        mouth.y + Player.eye_height + target_offset - ItemEntity.height / 2.0,
        mouth.z,
    );

    var drawn = self.item;
    drawn.base.position = from.add(to.sub(from).scale(eased));
    drawn.base.prev_position = drawn.base.position;
    return drawn;
}

fn testItem(position: math.Vec3) ItemEntity {
    var rand = world.JavaRandom.init(0);
    var item = ItemEntity.spawn(position, .{ .id = .{ .block = .stone }, .count = 1 }, &rand);
    item.base.motion = math.Vec3.init(0, 0, 0);
    return item;
}

test "the effect freezes the item where it was swallowed" {
    var item = testItem(math.Vec3.init(8, 5, 8));
    item.base.prev_position = math.Vec3.init(1, 1, 1);
    const fx = PickupFx.spawn(item);
    try std.testing.expectEqual(fx.item.base.position, fx.item.base.prev_position);
}

test "the effect dies after three ticks" {
    var fx = PickupFx.spawn(testItem(math.Vec3.init(8, 5, 8)));
    for (0..2) |_| {
        fx.tick();
        try std.testing.expect(!fx.isExpired());
    }
    fx.tick();
    try std.testing.expect(fx.isExpired());
}

test "the swallowed item accelerates towards the player's chest" {
    const player = Player.spawn(math.Vec3.init(8, 5, 8));
    const fx = PickupFx.spawn(testItem(math.Vec3.init(12, 5, 8)));

    const start = fx.swallowed(&player, 0).base.position;
    const middle = fx.swallowed(&player, 0.5).base.position;
    const landed: PickupFx = .{ .item = fx.item, .age = duration };
    const arrival = landed.swallowed(&player, 0).base.position;

    try std.testing.expectApproxEqAbs(@as(f64, 12.0), start.x, 1.0e-9);
    try std.testing.expect(middle.x > 11.5);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), arrival.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(
        5.0 + Player.eye_height + target_offset - ItemEntity.height / 2.0,
        arrival.y,
        1.0e-9,
    );
}

test "the swallowed item renders without any interpolation of its own" {
    const player = Player.spawn(math.Vec3.init(8, 5, 8));
    var fx = PickupFx.spawn(testItem(math.Vec3.init(12, 5, 8)));
    fx.tick();

    const drawn = fx.swallowed(&player, 0.5);
    try std.testing.expectEqual(drawn.base.position, drawn.base.renderPosition(1.0));
}
