const std = @import("std");
const math = @import("math");
const world = @import("world");
const Animal = @import("animal.zig");

const Pig = @This();

animal: Animal,
saddled: bool = false,
pending_drops: u8 = 0,
drops_cooked: bool = false,

pub const width: f64 = 0.9;
pub const height: f64 = 0.9;
pub const max_health: i32 = 10;

pub const spec: Animal.Spec = .{ .width = width, .height = height, .max_health = max_health };

pub fn spawn(position: math.Vec3) Pig {
    var pig: Pig = .{ .animal = Animal.spawn(position, spec) };
    pig.animal.on_death = dropFewItems;
    return pig;
}

pub fn deinit(self: *Pig, gpa: std.mem.Allocator) void {
    self.animal.deinit(gpa);
}

/// `EntityPig.dropFewItems`: nought to two porkchops, cooked if the pig died alight.
fn dropFewItems(animal: *Animal, rand: *world.JavaRandom) void {
    const self: *Pig = @fieldParentPtr("animal", animal);
    self.pending_drops = @intCast(rand.nextIntBound(3));
    self.drops_cooked = animal.fire > 0;
}

pub const Drops = struct {
    count: u8,
    id: world.Item,

    pub fn stack(self: Drops) world.Stack {
        return .{ .id = .{ .item = self.id }, .count = 1 };
    }
};

pub fn takeDrops(self: *Pig) ?Drops {
    if (self.pending_drops == 0) return null;
    const drops: Drops = .{
        .count = self.pending_drops,
        .id = if (self.drops_cooked) world.Item.pork_cooked else world.Item.pork_raw,
    };
    self.pending_drops = 0;
    return drops;
}

pub fn toRecord(self: Pig) world.entity_nbt.Pig {
    return .{ .living = self.animal.toRecord(), .saddled = self.saddled };
}

pub fn fromRecord(record: world.entity_nbt.Pig) Pig {
    var pig = Pig.spawn(math.Vec3.init(
        record.living.position[0],
        record.living.position[1],
        record.living.position[2],
    ));
    pig.animal.restore(record.living);
    pig.saddled = record.saddled;
    return pig;
}

test "a dying pig drops nought to two porkchops" {
    var dropped_nothing = false;
    var dropped_something = false;

    for (0..20) |seed| {
        var rand = world.JavaRandom.init(@intCast(seed));
        var pig = Pig.spawn(math.Vec3.init(8, 1, 8));

        _ = pig.animal.hurt(max_health, null, &rand);
        try std.testing.expect(!pig.animal.isAlive());

        if (pig.takeDrops()) |drops| {
            try std.testing.expect(drops.count >= 1 and drops.count <= 2);
            try std.testing.expectEqual(world.Item.pork_raw, drops.id);
            dropped_something = true;
        } else {
            dropped_nothing = true;
        }

        try std.testing.expect(pig.takeDrops() == null);
    }

    try std.testing.expect(dropped_nothing);
    try std.testing.expect(dropped_something);
}

test "a pig that burned to death drops its porkchops cooked" {
    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8, 1, 8));
    pig.animal.fire = 5;

    _ = pig.animal.hurt(max_health, null, &rand);
    pig.pending_drops = 1;

    try std.testing.expectEqual(world.Item.pork_cooked, pig.takeDrops().?.id);
}

test "a pig that died of something other than a hit still drops" {
    const gpa = std.testing.allocator;
    var w = try world.testing.flatWorld(gpa, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(0);
    var pig = Pig.spawn(math.Vec3.init(8.5, 90, 8.5));
    defer pig.deinit(gpa);

    for (0..200) |_| {
        try pig.animal.tick(gpa, &w, null, &rand);
        if (!pig.animal.isAlive()) break;
    }

    try std.testing.expect(!pig.animal.isAlive());
    try std.testing.expect(pig.pending_drops <= 2);
}

test "a pig keeps its saddle and its wounds across a record round trip" {
    var pig = Pig.spawn(math.Vec3.init(12.5, 64.0, -3.25));
    pig.animal.health = 6;
    pig.animal.yaw = 42.0;
    pig.animal.fire = 40;
    pig.animal.base.on_ground = true;
    pig.saddled = true;

    const restored = Pig.fromRecord(pig.toRecord());

    try std.testing.expectEqual(@as(i32, 6), restored.animal.health);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), restored.animal.yaw, 1.0e-6);
    try std.testing.expectEqual(@as(i32, 40), restored.animal.fire);
    try std.testing.expect(restored.animal.base.on_ground);
    try std.testing.expect(restored.saddled);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), restored.animal.base.position.x, 1.0e-9);
}

test "a pig is the size EntityPig sets itself to" {
    const pig = Pig.spawn(math.Vec3.init(0, 0, 0));
    try std.testing.expectEqual(@as(f64, 0.9), pig.animal.base.width);
    try std.testing.expectEqual(@as(f64, 0.9), pig.animal.base.height);
    try std.testing.expectEqual(max_health, pig.animal.health);
}
