const std = @import("std");
const nbt = @import("nbt.zig");

pub const pig_id = "Pig";

pub const max_stored_motion: f64 = 10.0;

pub const Pig = struct {
    position: [3]f64,
    motion: [3]f64 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    fall_distance: f32 = 0,
    fire: i16 = 0,
    air: i16 = 300,
    on_ground: bool = false,
    health: i16 = 10,
    hurt_time: i16 = 0,
    death_time: i16 = 0,
    saddled: bool = false,
};

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

fn doubleList(gpa: std.mem.Allocator, values: [3]f64) !nbt.Tag {
    const items = try gpa.alloc(nbt.Tag, values.len);
    for (items, values) |*item, value| item.* = .{ .double = value };
    return .{ .list = .{ .element_type = .double, .items = items } };
}

fn floatList(gpa: std.mem.Allocator, values: [2]f32) !nbt.Tag {
    const items = try gpa.alloc(nbt.Tag, values.len);
    for (items, values) |*item, value| item.* = .{ .float = value };
    return .{ .list = .{ .element_type = .float, .items = items } };
}

pub fn storePig(gpa: std.mem.Allocator, pig: Pig) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, pig_id) });
    try put(gpa, &compound, "Pos", try doubleList(gpa, pig.position));
    try put(gpa, &compound, "Motion", try doubleList(gpa, pig.motion));
    try put(gpa, &compound, "Rotation", try floatList(gpa, .{ pig.yaw, pig.pitch }));
    try put(gpa, &compound, "FallDistance", .{ .float = pig.fall_distance });
    try put(gpa, &compound, "Fire", .{ .short = pig.fire });
    try put(gpa, &compound, "Air", .{ .short = pig.air });
    try put(gpa, &compound, "OnGround", .{ .byte = @intFromBool(pig.on_ground) });
    try put(gpa, &compound, "Health", .{ .short = pig.health });
    try put(gpa, &compound, "HurtTime", .{ .short = pig.hurt_time });
    try put(gpa, &compound, "DeathTime", .{ .short = pig.death_time });
    try put(gpa, &compound, "AttackTime", .{ .short = 0 });
    try put(gpa, &compound, "Saddle", .{ .byte = @intFromBool(pig.saddled) });

    return .{ .compound = compound };
}

fn shortField(compound: nbt.Compound, key: []const u8, fallback: i16) i16 {
    const tag = compound.get(key) orelse return fallback;
    return switch (tag) {
        .short => |value| value,
        else => fallback,
    };
}

fn floatField(compound: nbt.Compound, key: []const u8, fallback: f32) f32 {
    const tag = compound.get(key) orelse return fallback;
    return switch (tag) {
        .float => |value| value,
        else => fallback,
    };
}

fn boolField(compound: nbt.Compound, key: []const u8) bool {
    const tag = compound.get(key) orelse return false;
    return switch (tag) {
        .byte => |value| value != 0,
        else => false,
    };
}

fn doublesField(compound: nbt.Compound, key: []const u8, out: *[3]f64) bool {
    const tag = compound.get(key) orelse return false;
    const list = switch (tag) {
        .list => |value| value,
        else => return false,
    };
    if (list.items.len < out.len) return false;

    for (out, list.items[0..out.len]) |*slot, item| {
        slot.* = switch (item) {
            .double => |value| value,
            else => return false,
        };
    }
    return true;
}

fn floatsField(compound: nbt.Compound, key: []const u8, out: *[2]f32) void {
    const tag = compound.get(key) orelse return;
    const list = switch (tag) {
        .list => |value| value,
        else => return,
    };
    if (list.items.len < out.len) return;

    for (out, list.items[0..out.len]) |*slot, item| {
        slot.* = switch (item) {
            .float => |value| value,
            else => return,
        };
    }
}

pub fn isPig(compound: nbt.Compound) bool {
    const tag = compound.get("id") orelse return false;
    return switch (tag) {
        .string => |value| std.mem.eql(u8, value, pig_id),
        else => false,
    };
}

pub fn loadPig(compound: nbt.Compound) ?Pig {
    if (!isPig(compound)) return null;

    var pig: Pig = .{ .position = .{ 0, 0, 0 } };
    if (!doublesField(compound, "Pos", &pig.position)) return null;
    _ = doublesField(compound, "Motion", &pig.motion);
    for (&pig.motion) |*component| {
        if (@abs(component.*) > max_stored_motion) component.* = 0;
    }

    var rotation = [2]f32{ 0, 0 };
    floatsField(compound, "Rotation", &rotation);
    pig.yaw = rotation[0];
    pig.pitch = rotation[1];

    pig.fall_distance = floatField(compound, "FallDistance", 0);
    pig.fire = shortField(compound, "Fire", 0);
    pig.air = shortField(compound, "Air", 300);
    pig.on_ground = boolField(compound, "OnGround");
    pig.health = shortField(compound, "Health", 10);
    pig.hurt_time = shortField(compound, "HurtTime", 0);
    pig.death_time = shortField(compound, "DeathTime", 0);
    pig.saddled = boolField(compound, "Saddle");

    return pig;
}

test "a pig survives a round trip through its NBT compound" {
    const gpa = std.testing.allocator;
    const original = Pig{
        .position = .{ 12.5, 64.0, -3.25 },
        .motion = .{ 0.1, -0.2, 0.3 },
        .yaw = 137.5,
        .pitch = -12.0,
        .fall_distance = 2.5,
        .fire = 40,
        .air = 280,
        .on_ground = true,
        .health = 7,
        .hurt_time = 4,
        .death_time = 0,
        .saddled = true,
    };

    var tag = try storePig(gpa, original);
    defer nbt.deinit(gpa, &tag);

    const loaded = loadPig(tag.compound).?;
    try std.testing.expectEqual(original, loaded);
}

test "an entity of another kind is not read as a pig" {
    const gpa = std.testing.allocator;
    var tag = try storePig(gpa, .{ .position = .{ 0, 0, 0 } });
    defer nbt.deinit(gpa, &tag);

    const id = tag.compound.getPtr("id").?;
    gpa.free(id.string);
    id.string = try gpa.dupe(u8, "Sheep");

    try std.testing.expect(!isPig(tag.compound));
    try std.testing.expect(loadPig(tag.compound) == null);
}

test "absurd stored motion is discarded rather than launching the pig" {
    const gpa = std.testing.allocator;
    var tag = try storePig(gpa, .{ .position = .{ 0, 64, 0 }, .motion = .{ 99.0, -50.0, 0.5 } });
    defer nbt.deinit(gpa, &tag);

    const loaded = loadPig(tag.compound).?;
    try std.testing.expectEqual(@as(f64, 0), loaded.motion[0]);
    try std.testing.expectEqual(@as(f64, 0), loaded.motion[1]);
    try std.testing.expectEqual(@as(f64, 0.5), loaded.motion[2]);
}

test "a pig compound missing its position is rejected" {
    const gpa = std.testing.allocator;
    var tag = try storePig(gpa, .{ .position = .{ 1, 2, 3 } });
    defer nbt.deinit(gpa, &tag);

    var removed = tag.compound.fetchOrderedRemove("Pos").?;
    gpa.free(removed.key);
    nbt.deinit(gpa, &removed.value);

    try std.testing.expect(loadPig(tag.compound) == null);
}
