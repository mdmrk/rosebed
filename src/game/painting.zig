const std = @import("std");

const math = @import("math");
const world = @import("world");

const game_physics = @import("physics.zig");

const Painting = @This();

pub const Art = enum {
    kebab,
    aztec,
    alban,
    aztec2,
    bomb,
    plant,
    wasteland,
    pool,
    courbet,
    sea,
    sunset,
    creebet,
    wanderer,
    graham,
    match,
    bust,
    stage,
    void,
    skull_and_roses,
    fighters,
    pointer,
    pigscene,
    burning_skull,
    skeleton,
    donkey_kong,

    pub const Info = struct {
        size_x: u8,
        size_y: u8,
        offset_x: u16,
        offset_y: u16,
        title: []const u8,
    };

    pub fn info(self: Art) Info {
        return switch (self) {
            .kebab => .{ .size_x = 16, .size_y = 16, .offset_x = 0, .offset_y = 0, .title = "Kebab" },
            .aztec => .{ .size_x = 16, .size_y = 16, .offset_x = 16, .offset_y = 0, .title = "Aztec" },
            .alban => .{ .size_x = 16, .size_y = 16, .offset_x = 32, .offset_y = 0, .title = "Alban" },
            .aztec2 => .{ .size_x = 16, .size_y = 16, .offset_x = 48, .offset_y = 0, .title = "Aztec2" },
            .bomb => .{ .size_x = 16, .size_y = 16, .offset_x = 64, .offset_y = 0, .title = "Bomb" },
            .plant => .{ .size_x = 16, .size_y = 16, .offset_x = 80, .offset_y = 0, .title = "Plant" },
            .wasteland => .{ .size_x = 16, .size_y = 16, .offset_x = 96, .offset_y = 0, .title = "Wasteland" },
            .pool => .{ .size_x = 32, .size_y = 16, .offset_x = 0, .offset_y = 32, .title = "Pool" },
            .courbet => .{ .size_x = 32, .size_y = 16, .offset_x = 32, .offset_y = 32, .title = "Courbet" },
            .sea => .{ .size_x = 32, .size_y = 16, .offset_x = 64, .offset_y = 32, .title = "Sea" },
            .sunset => .{ .size_x = 32, .size_y = 16, .offset_x = 96, .offset_y = 32, .title = "Sunset" },
            .creebet => .{ .size_x = 32, .size_y = 16, .offset_x = 128, .offset_y = 32, .title = "Creebet" },
            .wanderer => .{ .size_x = 16, .size_y = 32, .offset_x = 0, .offset_y = 64, .title = "Wanderer" },
            .graham => .{ .size_x = 16, .size_y = 32, .offset_x = 16, .offset_y = 64, .title = "Graham" },
            .match => .{ .size_x = 32, .size_y = 32, .offset_x = 0, .offset_y = 128, .title = "Match" },
            .bust => .{ .size_x = 32, .size_y = 32, .offset_x = 32, .offset_y = 128, .title = "Bust" },
            .stage => .{ .size_x = 32, .size_y = 32, .offset_x = 64, .offset_y = 128, .title = "Stage" },
            .void => .{ .size_x = 32, .size_y = 32, .offset_x = 96, .offset_y = 128, .title = "Void" },
            .skull_and_roses => .{ .size_x = 32, .size_y = 32, .offset_x = 128, .offset_y = 128, .title = "SkullAndRoses" },
            .fighters => .{ .size_x = 64, .size_y = 32, .offset_x = 0, .offset_y = 96, .title = "Fighters" },
            .pointer => .{ .size_x = 64, .size_y = 64, .offset_x = 0, .offset_y = 192, .title = "Pointer" },
            .pigscene => .{ .size_x = 64, .size_y = 64, .offset_x = 64, .offset_y = 192, .title = "Pigscene" },
            .burning_skull => .{ .size_x = 64, .size_y = 64, .offset_x = 128, .offset_y = 192, .title = "BurningSkull" },
            .skeleton => .{ .size_x = 64, .size_y = 48, .offset_x = 192, .offset_y = 64, .title = "Skeleton" },
            .donkey_kong => .{ .size_x = 64, .size_y = 48, .offset_x = 192, .offset_y = 112, .title = "DonkeyKong" },
        };
    }

    pub fn fromTitle(title: []const u8) ?Art {
        for (std.enums.values(Art)) |art| {
            if (std.mem.eql(u8, art.info().title, title)) return art;
        }
        return null;
    }
};

pub const recheck_ticks = 100;
const hang_depth: f32 = 9.0 / 16.0;
const box_shrink: f64 = 0.1 / 16.0;

tile: [3]i32,
direction: u2,
art: Art,
position: math.Vec3,
box: math.AABB,
age: u32 = 0,

fn centreOffset(size: u8) f32 {
    return if (size == 32 or size == 64) 0.5 else 0.0;
}

pub fn place(tile: [3]i32, direction: u2, art: Art) Painting {
    const size = art.info();

    var half_x: f32 = @floatFromInt(size.size_x);
    const half_y: f32 = @as(f32, @floatFromInt(size.size_y)) / 32.0;
    var half_z: f32 = @floatFromInt(size.size_x);
    if (direction != 0 and direction != 2) half_x = 0.5 else half_z = 0.5;
    half_x /= 32.0;
    half_z /= 32.0;

    var x: f32 = @as(f32, @floatFromInt(tile[0])) + 0.5;
    var y: f32 = @as(f32, @floatFromInt(tile[1])) + 0.5;
    var z: f32 = @as(f32, @floatFromInt(tile[2])) + 0.5;

    switch (direction) {
        0 => z -= hang_depth,
        1 => x -= hang_depth,
        2 => z += hang_depth,
        3 => x += hang_depth,
    }
    switch (direction) {
        0 => x -= centreOffset(size.size_x),
        1 => z += centreOffset(size.size_x),
        2 => x += centreOffset(size.size_x),
        3 => z -= centreOffset(size.size_x),
    }
    y += centreOffset(size.size_y);

    return .{
        .tile = tile,
        .direction = direction,
        .art = art,
        .position = math.Vec3.init(x, y, z),
        .box = math.AABB.init(
            @as(f64, x - half_x) + box_shrink,
            @as(f64, y - half_y) + box_shrink,
            @as(f64, z - half_z) + box_shrink,
            @as(f64, x + half_x) - box_shrink,
            @as(f64, y + half_y) - box_shrink,
            @as(f64, z + half_z) - box_shrink,
        ),
    };
}

pub fn yaw(self: Painting) f32 {
    return @as(f32, @floatFromInt(self.direction)) * 90.0;
}

pub fn dueForRecheck(self: *Painting) bool {
    if (self.age == recheck_ticks) {
        self.age = 0;
        return true;
    }
    self.age += 1;
    return false;
}

pub fn fits(self: Painting, world_map: *const world.World, others: []const Painting, skip: ?usize) bool {
    if (game_physics.isBoxObstructed(world_map, self.box)) return false;

    const size = self.art.info();
    const across = size.size_x / 16;
    const down = size.size_y / 16;

    var origin_x = self.tile[0];
    var origin_z = self.tile[2];
    const half_across: f64 = @as(f64, @floatFromInt(size.size_x)) / 32.0;
    switch (self.direction) {
        0, 2 => origin_x = math.util.floorDouble(self.position.x - half_across),
        1, 3 => origin_z = math.util.floorDouble(self.position.z - half_across),
    }
    const origin_y = math.util.floorDouble(self.position.y - @as(f64, @floatFromInt(size.size_y)) / 32.0);

    for (0..across) |column| {
        for (0..down) |row| {
            const step: i32 = @intCast(column);
            const lift: i32 = @intCast(row);
            const material = switch (self.direction) {
                0, 2 => world_map.getBlock(origin_x + step, origin_y + lift, self.tile[2]).material(),
                1, 3 => world_map.getBlock(self.tile[0], origin_y + lift, origin_z + step).material(),
            };
            if (!material.isSolid()) return false;
        }
    }

    for (others, 0..) |other, index| {
        if (skip != null and index == skip.?) continue;
        if (self.box.intersects(other.box)) return false;
    }
    return true;
}

pub fn pickArt(
    tile: [3]i32,
    direction: u2,
    world_map: *const world.World,
    others: []const Painting,
    rand: *world.JavaRandom,
) ?Painting {
    var fitting: [std.enums.values(Art).len]Art = undefined;
    var count: usize = 0;
    for (std.enums.values(Art)) |art| {
        if (place(tile, direction, art).fits(world_map, others, null)) {
            fitting[count] = art;
            count += 1;
        }
    }
    if (count == 0) return null;

    const chosen = fitting[@intCast(rand.nextIntBound(@intCast(count)))];
    return place(tile, direction, chosen);
}

pub fn directionFromFace(face: world.Side) ?u2 {
    return switch (face) {
        .down, .up => null,
        .north => 0,
        .west => 1,
        .south => 2,
        .east => 3,
    };
}

test "the art table matches EnumArt entry for entry" {
    const arts = std.enums.values(Art);
    try std.testing.expectEqual(@as(usize, 25), arts.len);

    try std.testing.expectEqualStrings("Kebab", arts[0].info().title);
    try std.testing.expectEqualStrings("DonkeyKong", arts[arts.len - 1].info().title);
    try std.testing.expectEqualStrings("SkullAndRoses", Art.skull_and_roses.info().title);

    const donkey = Art.donkey_kong.info();
    try std.testing.expectEqual(@as(u8, 64), donkey.size_x);
    try std.testing.expectEqual(@as(u8, 48), donkey.size_y);
    try std.testing.expectEqual(@as(u16, 192), donkey.offset_x);
    try std.testing.expectEqual(@as(u16, 112), donkey.offset_y);
}

test "every painting is a whole number of blocks and sits inside the atlas" {
    for (std.enums.values(Art)) |art| {
        const size = art.info();
        try std.testing.expectEqual(@as(u8, 0), size.size_x % 16);
        try std.testing.expectEqual(@as(u8, 0), size.size_y % 16);
        try std.testing.expect(size.offset_x + size.size_x <= 256);
        try std.testing.expect(size.offset_y + size.size_y <= 256);
    }
}

test "a title round trips, and an unknown one does not resolve" {
    for (std.enums.values(Art)) |art| {
        try std.testing.expectEqual(art, Art.fromTitle(art.info().title).?);
    }
    try std.testing.expectEqual(@as(?Art, null), Art.fromTitle("Mona Lisa"));
}

test "a painting hangs just clear of the block it was placed against" {
    const north = place(.{ 8, 4, 8 }, 0, .kebab);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5 - 9.0 / 16.0), north.position.z, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), north.position.x, 1.0e-6);

    const south = place(.{ 8, 4, 8 }, 2, .kebab);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5 + 9.0 / 16.0), south.position.z, 1.0e-6);

    const west = place(.{ 8, 4, 8 }, 1, .kebab);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5 - 9.0 / 16.0), west.position.x, 1.0e-6);

    const east = place(.{ 8, 4, 8 }, 3, .kebab);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5 + 9.0 / 16.0), east.position.x, 1.0e-6);
}

test "an even sized painting is nudged half a block so it stays on the grid" {
    const small = place(.{ 8, 4, 8 }, 0, .kebab);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), small.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), small.position.y, 1.0e-6);

    const wide = place(.{ 8, 4, 8 }, 0, .pool);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), wide.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), wide.position.y, 1.0e-6);

    const tall = place(.{ 8, 4, 8 }, 0, .wanderer);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), tall.position.x, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), tall.position.y, 1.0e-6);
}

test "a painting is thin along the wall it hangs on" {
    const facing_z = place(.{ 8, 4, 8 }, 0, .fighters);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), facing_z.box.max_x - facing_z.box.min_x, 0.02);
    try std.testing.expect(facing_z.box.max_z - facing_z.box.min_z < 0.05);

    const facing_x = place(.{ 8, 4, 8 }, 1, .fighters);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), facing_x.box.max_z - facing_x.box.min_z, 0.02);
    try std.testing.expect(facing_x.box.max_x - facing_x.box.min_x < 0.05);
}

test "the yaw follows the direction a quarter turn at a time" {
    try std.testing.expectEqual(@as(f32, 0), place(.{ 0, 0, 0 }, 0, .kebab).yaw());
    try std.testing.expectEqual(@as(f32, 90), place(.{ 0, 0, 0 }, 1, .kebab).yaw());
    try std.testing.expectEqual(@as(f32, 180), place(.{ 0, 0, 0 }, 2, .kebab).yaw());
    try std.testing.expectEqual(@as(f32, 270), place(.{ 0, 0, 0 }, 3, .kebab).yaw());
}

test "a painting cannot be hung on the floor or the ceiling" {
    try std.testing.expectEqual(@as(?u2, null), directionFromFace(.up));
    try std.testing.expectEqual(@as(?u2, null), directionFromFace(.down));
    try std.testing.expectEqual(@as(?u2, 0), directionFromFace(.north));
    try std.testing.expectEqual(@as(?u2, 1), directionFromFace(.west));
    try std.testing.expectEqual(@as(?u2, 2), directionFromFace(.south));
    try std.testing.expectEqual(@as(?u2, 3), directionFromFace(.east));
}

fn wallWorld(gpa: std.mem.Allocator) !world.World {
    var w = try world.testing.flatWorld(gpa, 1);
    errdefer w.deinit();
    var x: i32 = 4;
    while (x <= 12) : (x += 1) {
        var y: i32 = 1;
        while (y <= 8) : (y += 1) try w.setBlockWithNotify(x, y, 8, .stone);
    }
    return w;
}

test "a painting needs solid blocks behind every one of its squares" {
    var w = try wallWorld(std.testing.allocator);
    defer w.deinit();

    try std.testing.expect(place(.{ 8, 4, 8 }, 0, .kebab).fits(&w, &.{}, null));

    try w.setBlockWithNotify(8, 4, 8, .air);
    try std.testing.expect(!place(.{ 8, 4, 8 }, 0, .kebab).fits(&w, &.{}, null));
}

test "a wide painting needs the blocks beside it too" {
    var w = try wallWorld(std.testing.allocator);
    defer w.deinit();

    try std.testing.expect(place(.{ 8, 4, 8 }, 0, .pool).fits(&w, &.{}, null));

    try w.setBlockWithNotify(7, 4, 8, .air);
    try std.testing.expect(!place(.{ 8, 4, 8 }, 0, .pool).fits(&w, &.{}, null));
    try std.testing.expect(place(.{ 8, 4, 8 }, 0, .kebab).fits(&w, &.{}, null));
}

test "a painting will not hang over another one" {
    var w = try wallWorld(std.testing.allocator);
    defer w.deinit();

    const hung = place(.{ 8, 4, 8 }, 0, .kebab);
    const others = [_]Painting{hung};
    try std.testing.expect(!place(.{ 8, 4, 8 }, 0, .kebab).fits(&w, &others, null));
    try std.testing.expect(place(.{ 8, 6, 8 }, 0, .kebab).fits(&w, &others, null));
}

test "a painting will not hang where a block already stands" {
    var w = try wallWorld(std.testing.allocator);
    defer w.deinit();

    try std.testing.expect(place(.{ 8, 4, 8 }, 0, .kebab).fits(&w, &.{}, null));
    try w.setBlockWithNotify(8, 4, 7, .stone);
    try std.testing.expect(!place(.{ 8, 4, 8 }, 0, .kebab).fits(&w, &.{}, null));
}

test "the art is chosen only from the ones that fit the space" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    try w.setBlockWithNotify(8, 2, 8, .stone);

    var rand = world.JavaRandom.init(1);
    for (0..40) |_| {
        const hung = pickArt(.{ 8, 2, 8 }, 0, &w, &.{}, &rand).?;
        const size = hung.art.info();
        try std.testing.expectEqual(@as(u8, 16), size.size_x);
        try std.testing.expectEqual(@as(u8, 16), size.size_y);
    }
}

test "nowhere to hang gives no painting at all" {
    var w = try world.testing.flatWorld(std.testing.allocator, 1);
    defer w.deinit();

    var rand = world.JavaRandom.init(1);
    try std.testing.expectEqual(@as(?Painting, null), pickArt(.{ 8, 6, 8 }, 0, &w, &.{}, &rand));
}

test "the support is rechecked every hundred and first tick" {
    var hung = place(.{ 8, 4, 8 }, 0, .kebab);
    for (0..recheck_ticks) |_| try std.testing.expect(!hung.dueForRecheck());
    try std.testing.expect(hung.dueForRecheck());

    try std.testing.expectEqual(@as(u32, 0), hung.age);
    for (0..recheck_ticks) |_| try std.testing.expect(!hung.dueForRecheck());
    try std.testing.expect(hung.dueForRecheck());
}

test "a painting does not count itself as something in the way" {
    var w = try wallWorld(std.testing.allocator);
    defer w.deinit();

    const hung = [_]Painting{place(.{ 8, 4, 8 }, 0, .kebab)};
    try std.testing.expect(!hung[0].fits(&w, &hung, null));
    try std.testing.expect(hung[0].fits(&w, &hung, 0));
}

test "a painting stops fitting once its wall is mined away" {
    var w = try wallWorld(std.testing.allocator);
    defer w.deinit();

    const hung = [_]Painting{place(.{ 8, 4, 8 }, 0, .kebab)};
    try std.testing.expect(hung[0].fits(&w, &hung, 0));

    try w.setBlockWithNotify(8, 4, 8, .air);
    try std.testing.expect(!hung[0].fits(&w, &hung, 0));
}

pub fn toRecord(self: Painting) world.entity_nbt.Painting {
    return .{
        .tile = self.tile,
        .direction = self.direction,
        .motive = self.art.info().title,
    };
}

pub fn fromRecord(record: world.entity_nbt.Painting) ?Painting {
    const art = Art.fromTitle(record.motive) orelse return null;
    return place(record.tile, record.direction, art);
}
