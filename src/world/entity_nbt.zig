const std = @import("std");
const nbt = @import("nbt.zig");

pub const pig_id = "Pig";
pub const sheep_id = "Sheep";
pub const cow_id = "Cow";
pub const chicken_id = "Chicken";

pub const max_stored_motion: f64 = 10.0;

/// What `EntityLiving.writeEntityToNBT` writes for every mob.
pub const Living = struct {
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
};

pub const Pig = struct {
    living: Living,
    saddled: bool = false,
};

pub const Sheep = struct {
    living: Living,
    sheared: bool = false,
    color: u4 = 0,
};

pub const Cow = struct {
    living: Living,
};

pub const Chicken = struct {
    living: Living,
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

fn storeLiving(gpa: std.mem.Allocator, compound: *nbt.Compound, id: []const u8, living: Living) !void {
    try put(gpa, compound, "id", .{ .string = try gpa.dupe(u8, id) });
    try put(gpa, compound, "Pos", try doubleList(gpa, living.position));
    try put(gpa, compound, "Motion", try doubleList(gpa, living.motion));
    try put(gpa, compound, "Rotation", try floatList(gpa, .{ living.yaw, living.pitch }));
    try put(gpa, compound, "FallDistance", .{ .float = living.fall_distance });
    try put(gpa, compound, "Fire", .{ .short = living.fire });
    try put(gpa, compound, "Air", .{ .short = living.air });
    try put(gpa, compound, "OnGround", .{ .byte = @intFromBool(living.on_ground) });
    try put(gpa, compound, "Health", .{ .short = living.health });
    try put(gpa, compound, "HurtTime", .{ .short = living.hurt_time });
    try put(gpa, compound, "DeathTime", .{ .short = living.death_time });
    try put(gpa, compound, "AttackTime", .{ .short = 0 });
}

pub fn storePig(gpa: std.mem.Allocator, pig: Pig) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, pig_id, pig.living);
    try put(gpa, &compound, "Saddle", .{ .byte = @intFromBool(pig.saddled) });

    return .{ .compound = compound };
}

pub fn storeSheep(gpa: std.mem.Allocator, sheep: Sheep) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, sheep_id, sheep.living);
    try put(gpa, &compound, "Sheared", .{ .byte = @intFromBool(sheep.sheared) });
    try put(gpa, &compound, "Color", .{ .byte = sheep.color });

    return .{ .compound = compound };
}

pub fn storeCow(gpa: std.mem.Allocator, cow: Cow) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, cow_id, cow.living);

    return .{ .compound = compound };
}

pub fn storeChicken(gpa: std.mem.Allocator, chicken: Chicken) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, chicken_id, chicken.living);

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

fn nibbleField(compound: nbt.Compound, key: []const u8) u4 {
    const tag = compound.get(key) orelse return 0;
    return switch (tag) {
        .byte => |value| @truncate(@as(u8, @bitCast(value))),
        else => 0,
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

fn hasId(compound: nbt.Compound, id: []const u8) bool {
    const tag = compound.get("id") orelse return false;
    return switch (tag) {
        .string => |value| std.mem.eql(u8, value, id),
        else => false,
    };
}

pub fn isPig(compound: nbt.Compound) bool {
    return hasId(compound, pig_id);
}

pub fn isSheep(compound: nbt.Compound) bool {
    return hasId(compound, sheep_id);
}

pub fn isCow(compound: nbt.Compound) bool {
    return hasId(compound, cow_id);
}

pub fn isChicken(compound: nbt.Compound) bool {
    return hasId(compound, chicken_id);
}

fn loadLiving(compound: nbt.Compound) ?Living {
    var living: Living = .{ .position = .{ 0, 0, 0 } };
    if (!doublesField(compound, "Pos", &living.position)) return null;
    _ = doublesField(compound, "Motion", &living.motion);
    for (&living.motion) |*component| {
        if (@abs(component.*) > max_stored_motion) component.* = 0;
    }

    var rotation = [2]f32{ 0, 0 };
    floatsField(compound, "Rotation", &rotation);
    living.yaw = rotation[0];
    living.pitch = rotation[1];

    living.fall_distance = floatField(compound, "FallDistance", 0);
    living.fire = shortField(compound, "Fire", 0);
    living.air = shortField(compound, "Air", 300);
    living.on_ground = boolField(compound, "OnGround");
    living.health = shortField(compound, "Health", 10);
    living.hurt_time = shortField(compound, "HurtTime", 0);
    living.death_time = shortField(compound, "DeathTime", 0);

    return living;
}

pub fn loadPig(compound: nbt.Compound) ?Pig {
    if (!isPig(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    return .{ .living = living, .saddled = boolField(compound, "Saddle") };
}

pub fn loadSheep(compound: nbt.Compound) ?Sheep {
    if (!isSheep(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    return .{
        .living = living,
        .sheared = boolField(compound, "Sheared"),
        .color = nibbleField(compound, "Color"),
    };
}

pub fn loadCow(compound: nbt.Compound) ?Cow {
    if (!isCow(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    return .{ .living = living };
}

pub fn loadChicken(compound: nbt.Compound) ?Chicken {
    if (!isChicken(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    return .{ .living = living };
}

const sample_living = Living{
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
};

test "a pig survives a round trip through its NBT compound" {
    const gpa = std.testing.allocator;
    const original = Pig{ .living = sample_living, .saddled = true };

    var tag = try storePig(gpa, original);
    defer nbt.deinit(gpa, &tag);

    const loaded = loadPig(tag.compound).?;
    try std.testing.expectEqual(original, loaded);
}

test "a sheep survives a round trip through its NBT compound" {
    const gpa = std.testing.allocator;
    const original = Sheep{ .living = sample_living, .sheared = true, .color = 15 };

    var tag = try storeSheep(gpa, original);
    defer nbt.deinit(gpa, &tag);

    const loaded = loadSheep(tag.compound).?;
    try std.testing.expectEqual(original, loaded);
}

test "a sheep is stored under the id the original writes, and colours survive it" {
    const gpa = std.testing.allocator;

    for (0..16) |color| {
        var tag = try storeSheep(gpa, .{ .living = .{ .position = .{ 0, 64, 0 } }, .color = @intCast(color) });
        defer nbt.deinit(gpa, &tag);

        try std.testing.expectEqualStrings("Sheep", tag.compound.get("id").?.string);
        try std.testing.expectEqual(@as(u4, @intCast(color)), loadSheep(tag.compound).?.color);
    }
}

test "a cow survives a round trip through its NBT compound" {
    const gpa = std.testing.allocator;
    const original = Cow{ .living = sample_living };

    var tag = try storeCow(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqualStrings("Cow", tag.compound.get("id").?.string);
    try std.testing.expectEqual(original, loadCow(tag.compound).?);
}

test "a chicken survives a round trip through its NBT compound" {
    const gpa = std.testing.allocator;
    const original = Chicken{ .living = sample_living };

    var tag = try storeChicken(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqualStrings("Chicken", tag.compound.get("id").?.string);
    try std.testing.expectEqual(original, loadChicken(tag.compound).?);
}

test "each mob is read back only as its own kind" {
    const gpa = std.testing.allocator;
    const living = Living{ .position = .{ 0, 64, 0 } };

    var pig = try storePig(gpa, .{ .living = living });
    defer nbt.deinit(gpa, &pig);
    var sheep = try storeSheep(gpa, .{ .living = living });
    defer nbt.deinit(gpa, &sheep);
    var cow = try storeCow(gpa, .{ .living = living });
    defer nbt.deinit(gpa, &cow);
    var chicken = try storeChicken(gpa, .{ .living = living });
    defer nbt.deinit(gpa, &chicken);

    const compounds = [_]nbt.Compound{ pig.compound, sheep.compound, cow.compound, chicken.compound };
    for (compounds, 0..) |compound, kind| {
        try std.testing.expectEqual(kind == 0, loadPig(compound) != null);
        try std.testing.expectEqual(kind == 1, loadSheep(compound) != null);
        try std.testing.expectEqual(kind == 2, loadCow(compound) != null);
        try std.testing.expectEqual(kind == 3, loadChicken(compound) != null);
    }
}

test "an entity of a kind we do not know is read as nothing at all" {
    const gpa = std.testing.allocator;
    var tag = try storePig(gpa, .{ .living = .{ .position = .{ 0, 0, 0 } } });
    defer nbt.deinit(gpa, &tag);

    const id = tag.compound.getPtr("id").?;
    gpa.free(id.string);
    id.string = try gpa.dupe(u8, "Squid");

    try std.testing.expect(!isPig(tag.compound));
    try std.testing.expect(loadPig(tag.compound) == null);
    try std.testing.expect(loadSheep(tag.compound) == null);
    try std.testing.expect(loadCow(tag.compound) == null);
    try std.testing.expect(loadChicken(tag.compound) == null);
}

test "absurd stored motion is discarded rather than launching the pig" {
    const gpa = std.testing.allocator;
    var tag = try storePig(gpa, .{ .living = .{ .position = .{ 0, 64, 0 }, .motion = .{ 99.0, -50.0, 0.5 } } });
    defer nbt.deinit(gpa, &tag);

    const loaded = loadPig(tag.compound).?;
    try std.testing.expectEqual(@as(f64, 0), loaded.living.motion[0]);
    try std.testing.expectEqual(@as(f64, 0), loaded.living.motion[1]);
    try std.testing.expectEqual(@as(f64, 0.5), loaded.living.motion[2]);
}

test "a pig compound missing its position is rejected" {
    const gpa = std.testing.allocator;
    var tag = try storePig(gpa, .{ .living = .{ .position = .{ 1, 2, 3 } } });
    defer nbt.deinit(gpa, &tag);

    var removed = tag.compound.fetchOrderedRemove("Pos").?;
    gpa.free(removed.key);
    nbt.deinit(gpa, &removed.value);

    try std.testing.expect(loadPig(tag.compound) == null);
}
