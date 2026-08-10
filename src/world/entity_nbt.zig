const std = @import("std");

const block = @import("block.zig");
const ItemId = @import("item.zig").Item;
const nbt = @import("nbt.zig");

pub const pig_id = "Pig";
pub const sheep_id = "Sheep";
pub const cow_id = "Cow";
pub const chicken_id = "Chicken";
pub const slime_id = "Slime";
pub const ghast_id = "Ghast";
pub const wolf_id = "Wolf";
pub const wolf_owner = "Player";
pub const item_id = "Item";
pub const arrow_id = "Arrow";
pub const painting_id = "Painting";

pub const max_stored_motion: f64 = 10.0;

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

pub const Slime = struct {
    living: Living,
    size: i32 = 0,
};

pub const Ghast = struct {
    living: Living,
};

pub const Wolf = struct {
    living: Living,
    angry: bool = false,
    sitting: bool = false,
    owner: Owner = .{},
};

pub const Owner = struct {
    bytes: [max_owner]u8 = @splat(0),
    len: u8 = 0,

    pub fn text(self: *const Owner) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn from(name: []const u8) Owner {
        var owner: Owner = .{};
        owner.len = @intCast(@min(name.len, max_owner));
        @memcpy(owner.bytes[0..owner.len], name[0..owner.len]);
        return owner;
    }
};

pub const max_owner = 16;

pub const Base = struct {
    position: [3]f64,
    motion: [3]f64 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    fall_distance: f32 = 0,
    fire: i16 = 0,
    air: i16 = 300,
    on_ground: bool = false,
};

pub const Item = struct {
    base: Base,
    stack: block.Stack,
    health: i16 = 5,
    age: i16 = 0,
};

pub const Arrow = struct {
    base: Base,
    tile: [3]i16 = .{ -1, -1, -1 },
    in_tile: u8 = 0,
    in_data: u8 = 0,
    shake: u8 = 0,
    in_ground: bool = false,
    from_player: bool = false,
};

pub const Painting = struct {
    tile: [3]i32,
    direction: u2,
    motive: []const u8,
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

fn storeBase(gpa: std.mem.Allocator, compound: *nbt.Compound, id: []const u8, base: Base) !void {
    try put(gpa, compound, "id", .{ .string = try gpa.dupe(u8, id) });
    try put(gpa, compound, "Pos", try doubleList(gpa, base.position));
    try put(gpa, compound, "Motion", try doubleList(gpa, base.motion));
    try put(gpa, compound, "Rotation", try floatList(gpa, .{ base.yaw, base.pitch }));
    try put(gpa, compound, "FallDistance", .{ .float = base.fall_distance });
    try put(gpa, compound, "Fire", .{ .short = base.fire });
    try put(gpa, compound, "Air", .{ .short = base.air });
    try put(gpa, compound, "OnGround", .{ .byte = @intFromBool(base.on_ground) });
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

pub fn storeSlime(gpa: std.mem.Allocator, slime: Slime) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, slime_id, slime.living);
    try put(gpa, &compound, "Size", .{ .int = slime.size });

    return .{ .compound = compound };
}

pub fn storeGhast(gpa: std.mem.Allocator, ghast: Ghast) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, ghast_id, ghast.living);

    return .{ .compound = compound };
}

pub fn storeWolf(gpa: std.mem.Allocator, wolf: Wolf) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeLiving(gpa, &compound, wolf_id, wolf.living);
    try put(gpa, &compound, "Angry", .{ .byte = @intFromBool(wolf.angry) });
    try put(gpa, &compound, "Sitting", .{ .byte = @intFromBool(wolf.sitting) });
    try put(gpa, &compound, "Owner", .{ .string = try gpa.dupe(u8, wolf.owner.text()) });

    return .{ .compound = compound };
}

pub fn storeItem(gpa: std.mem.Allocator, item: Item) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeBase(gpa, &compound, item_id, item.base);
    try put(gpa, &compound, "Health", .{ .short = item.health });
    try put(gpa, &compound, "Age", .{ .short = item.age });

    var stack: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = stack };
        nbt.deinit(gpa, &owned);
    }
    try put(gpa, &stack, "id", .{ .short = item.stack.id.numeric() });
    try put(gpa, &stack, "Count", .{ .byte = @bitCast(item.stack.count) });
    try put(gpa, &stack, "Damage", .{ .short = @bitCast(item.stack.meta) });
    if (!item.stack.id.isVanilla() and item.stack.id.key().len != 0) {
        try put(gpa, &stack, "Key", .{ .string = try gpa.dupe(u8, item.stack.id.key()) });
    }
    try put(gpa, &compound, "Item", .{ .compound = stack });

    return .{ .compound = compound };
}

pub fn storeArrow(gpa: std.mem.Allocator, arrow: Arrow) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try storeBase(gpa, &compound, arrow_id, arrow.base);
    try put(gpa, &compound, "xTile", .{ .short = arrow.tile[0] });
    try put(gpa, &compound, "yTile", .{ .short = arrow.tile[1] });
    try put(gpa, &compound, "zTile", .{ .short = arrow.tile[2] });
    try put(gpa, &compound, "inTile", .{ .byte = @bitCast(arrow.in_tile) });
    try put(gpa, &compound, "inData", .{ .byte = @bitCast(arrow.in_data) });
    try put(gpa, &compound, "shake", .{ .byte = @bitCast(arrow.shake) });
    try put(gpa, &compound, "inGround", .{ .byte = @intFromBool(arrow.in_ground) });
    try put(gpa, &compound, "player", .{ .byte = @intFromBool(arrow.from_player) });

    return .{ .compound = compound };
}

pub fn storePainting(gpa: std.mem.Allocator, painting: Painting) !nbt.Tag {
    var compound: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = compound };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &compound, "id", .{ .string = try gpa.dupe(u8, painting_id) });
    try put(gpa, &compound, "Dir", .{ .byte = painting.direction });
    try put(gpa, &compound, "Motive", .{ .string = try gpa.dupe(u8, painting.motive) });
    try put(gpa, &compound, "TileX", .{ .int = painting.tile[0] });
    try put(gpa, &compound, "TileY", .{ .int = painting.tile[1] });
    try put(gpa, &compound, "TileZ", .{ .int = painting.tile[2] });

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

fn byteField(compound: nbt.Compound, key: []const u8, fallback: u8) u8 {
    const tag = compound.get(key) orelse return fallback;
    return switch (tag) {
        .byte => |value| @bitCast(value),
        else => fallback,
    };
}

fn intField(compound: nbt.Compound, key: []const u8, fallback: i32) i32 {
    const tag = compound.get(key) orelse return fallback;
    return switch (tag) {
        .int => |value| value,
        else => fallback,
    };
}

fn stringField(compound: nbt.Compound, key: []const u8) ?[]const u8 {
    const tag = compound.get(key) orelse return null;
    return switch (tag) {
        .string => |value| value,
        else => null,
    };
}

fn compoundField(compound: nbt.Compound, key: []const u8) ?nbt.Compound {
    const tag = compound.get(key) orelse return null;
    return switch (tag) {
        .compound => |value| value,
        else => null,
    };
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

pub fn isSlime(compound: nbt.Compound) bool {
    return hasId(compound, slime_id);
}

pub fn isGhast(compound: nbt.Compound) bool {
    return hasId(compound, ghast_id);
}

pub fn isWolf(compound: nbt.Compound) bool {
    return hasId(compound, wolf_id);
}

pub fn isItem(compound: nbt.Compound) bool {
    return hasId(compound, item_id);
}

pub fn isArrow(compound: nbt.Compound) bool {
    return hasId(compound, arrow_id);
}

pub fn isPainting(compound: nbt.Compound) bool {
    return hasId(compound, painting_id);
}

fn loadBase(compound: nbt.Compound) ?Base {
    var base: Base = .{ .position = .{ 0, 0, 0 } };
    if (!doublesField(compound, "Pos", &base.position)) return null;
    _ = doublesField(compound, "Motion", &base.motion);
    for (&base.motion) |*component| {
        if (@abs(component.*) > max_stored_motion) component.* = 0;
    }

    var rotation = [2]f32{ 0, 0 };
    floatsField(compound, "Rotation", &rotation);
    base.yaw = rotation[0];
    base.pitch = rotation[1];

    base.fall_distance = floatField(compound, "FallDistance", 0);
    base.fire = shortField(compound, "Fire", 0);
    base.air = shortField(compound, "Air", 300);
    base.on_ground = boolField(compound, "OnGround");

    return base;
}

pub fn loadItem(compound: nbt.Compound) ?Item {
    if (!isItem(compound)) return null;
    const base = loadBase(compound) orelse return null;
    const stored = compoundField(compound, "Item") orelse return null;

    const count = byteField(stored, "Count", 0);
    if (count == 0) return null;

    const id = block.Id.resolve(shortField(stored, "id", 0), stringField(stored, "Key") orelse "") orelse return null;

    return .{
        .base = base,
        .stack = .{
            .id = id,
            .count = count,
            .meta = @bitCast(shortField(stored, "Damage", 0)),
        },
        .health = shortField(compound, "Health", 5),
        .age = shortField(compound, "Age", 0),
    };
}

pub fn loadArrow(compound: nbt.Compound) ?Arrow {
    if (!isArrow(compound)) return null;
    const base = loadBase(compound) orelse return null;
    return .{
        .base = base,
        .tile = .{
            shortField(compound, "xTile", -1),
            shortField(compound, "yTile", -1),
            shortField(compound, "zTile", -1),
        },
        .in_tile = byteField(compound, "inTile", 0),
        .in_data = byteField(compound, "inData", 0),
        .shake = byteField(compound, "shake", 0),
        .in_ground = byteField(compound, "inGround", 0) == 1,
        .from_player = boolField(compound, "player"),
    };
}

pub fn loadPainting(compound: nbt.Compound) ?Painting {
    if (!isPainting(compound)) return null;
    return .{
        .tile = .{
            intField(compound, "TileX", 0),
            intField(compound, "TileY", 0),
            intField(compound, "TileZ", 0),
        },
        .direction = @truncate(byteField(compound, "Dir", 0)),
        .motive = stringField(compound, "Motive") orelse return null,
    };
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

pub fn loadGhast(compound: nbt.Compound) ?Ghast {
    if (!isGhast(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    return .{ .living = living };
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

pub fn loadSlime(compound: nbt.Compound) ?Slime {
    if (!isSlime(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    return .{ .living = living, .size = intField(compound, "Size", 0) };
}

pub fn loadWolf(compound: nbt.Compound) ?Wolf {
    if (!isWolf(compound)) return null;
    const living = loadLiving(compound) orelse return null;
    const owner = stringField(compound, "Owner") orelse "";
    return .{
        .living = living,
        .angry = boolField(compound, "Angry"),
        .sitting = boolField(compound, "Sitting"),
        .owner = Owner.from(owner),
    };
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

test "a dropped item survives a round trip with its stack intact" {
    const gpa = std.testing.allocator;
    const original = Item{
        .base = .{ .position = .{ 8.5, 65.0, -2.5 }, .motion = .{ 0.01, 0.2, -0.01 }, .on_ground = true },
        .stack = .{ .id = .{ .item = .diamond }, .count = 12, .meta = 3 },
        .health = 5,
        .age = 240,
    };

    var tag = try storeItem(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqualStrings("Item", tag.compound.get("id").?.string);
    const loaded = loadItem(tag.compound).?;
    try std.testing.expectEqual(original.stack, loaded.stack);
    try std.testing.expectEqual(original.age, loaded.age);
    try std.testing.expectEqual(original.base.position, loaded.base.position);
}

test "a block stack and an item stack both survive the id split at 256" {
    const gpa = std.testing.allocator;
    const stacks = [_]block.Stack{
        .{ .id = .{ .block = .stone }, .count = 64 },
        .{ .id = .{ .block = .log }, .count = 1, .meta = 2 },
        .{ .id = .{ .item = .diamond }, .count = 5 },
    };

    for (stacks) |stack| {
        var tag = try storeItem(gpa, .{ .base = .{ .position = .{ 0, 64, 0 } }, .stack = stack });
        defer nbt.deinit(gpa, &tag);
        try std.testing.expectEqual(stack, loadItem(tag.compound).?.stack);
    }
}

test "an item compound with an empty stack is read as nothing" {
    const gpa = std.testing.allocator;
    var tag = try storeItem(gpa, .{
        .base = .{ .position = .{ 0, 64, 0 } },
        .stack = .{ .id = .{ .block = .stone }, .count = 0 },
    });
    defer nbt.deinit(gpa, &tag);

    try std.testing.expect(loadItem(tag.compound) == null);
}

test "an arrow survives a round trip stuck in the block it hit" {
    const gpa = std.testing.allocator;
    const original = Arrow{
        .base = .{ .position = .{ -4.5, 70.0, 12.25 }, .yaw = 90.0, .pitch = -45.0 },
        .tile = .{ -5, 70, 12 },
        .in_tile = 1,
        .in_data = 3,
        .shake = 7,
        .in_ground = true,
        .from_player = true,
    };

    var tag = try storeArrow(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqualStrings("Arrow", tag.compound.get("id").?.string);
    try std.testing.expectEqual(original, loadArrow(tag.compound).?);
}

test "a painting survives a round trip through its motive" {
    const gpa = std.testing.allocator;
    const original = Painting{ .tile = .{ 8, 64, -3 }, .direction = 2, .motive = "Pigscene" };

    var tag = try storePainting(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqualStrings("Painting", tag.compound.get("id").?.string);
    const loaded = loadPainting(tag.compound).?;
    try std.testing.expectEqual(original.tile, loaded.tile);
    try std.testing.expectEqual(original.direction, loaded.direction);
    try std.testing.expectEqualStrings(original.motive, loaded.motive);
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
    var wolf = try storeWolf(gpa, .{ .living = living });
    defer nbt.deinit(gpa, &wolf);

    const compounds = [_]nbt.Compound{ pig.compound, sheep.compound, cow.compound, chicken.compound, wolf.compound };
    for (compounds, 0..) |compound, kind| {
        try std.testing.expectEqual(kind == 0, loadPig(compound) != null);
        try std.testing.expectEqual(kind == 1, loadSheep(compound) != null);
        try std.testing.expectEqual(kind == 2, loadCow(compound) != null);
        try std.testing.expectEqual(kind == 3, loadChicken(compound) != null);
        try std.testing.expectEqual(kind == 4, loadWolf(compound) != null);
    }
}

test "a wolf survives a round trip through its NBT compound" {
    const gpa = std.testing.allocator;
    const original = Wolf{ .living = sample_living, .angry = false, .sitting = true, .owner = .from("Notch") };

    var tag = try storeWolf(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqualStrings("Wolf", tag.compound.get("id").?.string);
    try std.testing.expectEqualStrings("Notch", tag.compound.get("Owner").?.string);
    try std.testing.expectEqual(original, loadWolf(tag.compound).?);
}

test "an untamed wolf writes an empty owner and reads back untamed" {
    const gpa = std.testing.allocator;
    const original = Wolf{ .living = sample_living, .angry = true };

    var tag = try storeWolf(gpa, original);
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectEqual(@as(usize, 0), tag.compound.get("Owner").?.string.len);
    try std.testing.expectEqual(original, loadWolf(tag.compound).?);
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

test "a vanilla stack carries no key, so its compound is unchanged" {
    const gpa = std.testing.allocator;
    var tag = try storeItem(gpa, .{
        .base = .{ .position = .{ 0, 64, 0 } },
        .stack = .{ .id = .{ .item = .diamond }, .count = 1 },
    });
    defer nbt.deinit(gpa, &tag);

    try std.testing.expect(tag.compound.get("Item").?.compound.get("Key") == null);
}

test "a dropped modded item comes back at whatever id its key holds now" {
    const gpa = std.testing.allocator;
    defer ItemId.resetRegistry();

    const was: ItemId = @enumFromInt(400);
    was.register(.{ .key = "rosebed:quartz_pickaxe", .name = "Quartz Pickaxe" });

    var tag = try storeItem(gpa, .{
        .base = .{ .position = .{ 0, 64, 0 } },
        .stack = .{ .id = .{ .item = was }, .count = 1, .meta = 7 },
    });
    defer nbt.deinit(gpa, &tag);
    try std.testing.expectEqualStrings("rosebed:quartz_pickaxe", tag.compound.get("Item").?.compound.get("Key").?.string);

    ItemId.resetRegistry();
    const now: ItemId = @enumFromInt(511);
    now.register(.{ .key = "rosebed:quartz_pickaxe", .name = "Quartz Pickaxe" });

    const loaded = loadItem(tag.compound).?;
    try std.testing.expectEqual(block.Id{ .item = now }, loaded.stack.id);
    try std.testing.expectEqual(@as(u16, 7), loaded.stack.meta);
}

test "a dropped item whose mod is gone is read as nothing" {
    const gpa = std.testing.allocator;
    defer ItemId.resetRegistry();

    const was: ItemId = @enumFromInt(400);
    was.register(.{ .key = "rosebed:quartz_pickaxe" });

    var tag = try storeItem(gpa, .{
        .base = .{ .position = .{ 0, 64, 0 } },
        .stack = .{ .id = .{ .item = was }, .count = 1 },
    });
    defer nbt.deinit(gpa, &tag);

    ItemId.resetRegistry();
    try std.testing.expect(loadItem(tag.compound) == null);
}
