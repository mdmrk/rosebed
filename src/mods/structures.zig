const std = @import("std");

const world = @import("world");
const width = world.Chunk.width;

pub const max_radius = 8;
pub const max_spacing = 4096;
pub const cache_size = 32;

pub const Structure = struct {
    ref: i32,
    salt: i64,
    spacing: i32,
    chance: f64,
    radius: i32,
    dimension: world.Dimension,
    biomes: ?world.biome.Set = null,
    warned: bool = false,
};

pub const Instance = struct {
    chunk_x: i32,
    chunk_z: i32,
    origin_x: i32,
    origin_z: i32,
    rand: world.JavaRandom,
};

pub fn instanceIn(structure: Structure, seed: i64, cell_x: i32, cell_z: i32) ?Instance {
    var rand = world.JavaRandom.init(seed +% @as(i64, cell_x) *% 341873128712 +% @as(i64, cell_z) *% 132897987541 +% structure.salt);
    if (!(rand.nextDouble() < structure.chance)) return null;
    const chunk_x = cell_x *% structure.spacing +% rand.nextIntBound(structure.spacing);
    const chunk_z = cell_z *% structure.spacing +% rand.nextIntBound(structure.spacing);
    const origin_x = chunk_x *% width +% rand.nextIntBound(width);
    const origin_z = chunk_z *% width +% rand.nextIntBound(width);
    return .{ .chunk_x = chunk_x, .chunk_z = chunk_z, .origin_x = origin_x, .origin_z = origin_z, .rand = rand };
}

pub fn cellRange(structure: Structure, chunk: i32) [2]i32 {
    return .{
        @divFloor(chunk - structure.radius, structure.spacing),
        @divFloor(chunk + 1 + structure.radius, structure.spacing),
    };
}

pub fn reaches(structure: Structure, instance: Instance, chunk_x: i32, chunk_z: i32) bool {
    return instance.chunk_x >= chunk_x - structure.radius and instance.chunk_x <= chunk_x + 1 + structure.radius and
        instance.chunk_z >= chunk_z - structure.radius and instance.chunk_z <= chunk_z + 1 + structure.radius;
}

pub const Placed = struct {
    block: ?world.Block = null,
    meta: ?u4 = null,
};

pub const Placement = struct {
    pos: world.BlockPos,
    placed: Placed,
};

pub const ChestItem = struct {
    pos: world.BlockPos,
    slot: usize,
    stack: ?world.Stack,
};

pub const SpawnerMob = struct {
    pos: world.BlockPos,
    name: [world.mob_spawner.max_mob_name]u8,
    len: u8,
};

pub const Plan = struct {
    gpa: std.mem.Allocator,
    structure: usize,
    seed: i64,
    cell_x: i32,
    cell_z: i32,
    min_x: i32,
    min_z: i32,
    max_x: i32,
    max_z: i32,
    blocks: std.AutoHashMapUnmanaged(world.BlockPos, Placed) = .{},
    placements: []Placement = &.{},
    chest_items: std.ArrayList(ChestItem) = .empty,
    spawners: std.ArrayList(SpawnerMob) = .empty,

    pub fn init(gpa: std.mem.Allocator, structure_index: usize, structure: Structure, seed: i64, cell_x: i32, cell_z: i32, instance: Instance) Plan {
        return .{
            .gpa = gpa,
            .structure = structure_index,
            .seed = seed,
            .cell_x = cell_x,
            .cell_z = cell_z,
            .min_x = (instance.chunk_x - structure.radius) * width,
            .min_z = (instance.chunk_z - structure.radius) * width,
            .max_x = (instance.chunk_x + structure.radius + 1) * width,
            .max_z = (instance.chunk_z + structure.radius + 1) * width,
        };
    }

    pub fn deinit(self: *Plan) void {
        self.blocks.deinit(self.gpa);
        self.gpa.free(self.placements);
        self.chest_items.deinit(self.gpa);
        self.spawners.deinit(self.gpa);
    }

    pub fn clear(self: *Plan) void {
        self.blocks.clearRetainingCapacity();
        self.chest_items.clearRetainingCapacity();
        self.spawners.clearRetainingCapacity();
    }

    pub fn contains(self: Plan, pos: world.BlockPos) bool {
        return pos.y >= 0 and pos.y < world.Chunk.height and
            pos.x >= self.min_x and pos.x < self.max_x and pos.z >= self.min_z and pos.z < self.max_z;
    }

    fn cell(self: *Plan, pos: world.BlockPos) !*Placed {
        const entry = try self.blocks.getOrPut(self.gpa, pos);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    pub fn setBlock(self: *Plan, pos: world.BlockPos, block: world.Block, meta: ?u4) !void {
        const placed = try self.cell(pos);
        placed.block = block;
        if (meta) |value| placed.meta = value;
    }

    pub fn setMeta(self: *Plan, pos: world.BlockPos, meta: u4) !void {
        (try self.cell(pos)).meta = meta;
    }

    pub fn seal(self: *Plan) !void {
        const placements = try self.gpa.alloc(Placement, self.blocks.count());
        var blocks = self.blocks.iterator();
        for (placements) |*placement| {
            const entry = blocks.next().?;
            placement.* = .{ .pos = entry.key_ptr.*, .placed = entry.value_ptr.* };
        }
        std.mem.sortUnstable(Placement, placements, {}, squareBefore);
        self.blocks.clearAndFree(self.gpa);
        self.placements = placements;
    }

    fn square(pos: world.BlockPos) [2]i32 {
        return .{ @divFloor(pos.x - 8, width), @divFloor(pos.z - 8, width) };
    }

    fn squareBefore(_: void, a: Placement, b: Placement) bool {
        const first = square(a.pos);
        const second = square(b.pos);
        return first[0] < second[0] or (first[0] == second[0] and first[1] < second[1]);
    }

    fn squareOrder(chunk: [2]i32, placement: Placement) std.math.Order {
        const at = square(placement.pos);
        return switch (std.math.order(chunk[0], at[0])) {
            .eq => std.math.order(chunk[1], at[1]),
            else => |order| order,
        };
    }

    pub fn chestItem(self: Plan, pos: world.BlockPos, slot: usize) ?world.Stack {
        var written = std.mem.reverseIterator(self.chest_items.items);
        while (written.next()) |entry| {
            if (std.meta.eql(entry.pos, pos) and entry.slot == slot) return entry.stack;
        }
        return null;
    }

    pub fn apply(self: Plan, world_map: *world.World, chunk_x: i32, chunk_z: i32) !void {
        const square_x = chunk_x * width + 8;
        const square_z = chunk_z * width + 8;

        const first, const last = std.sort.equalRange(Placement, self.placements, [2]i32{ chunk_x, chunk_z }, squareOrder);
        for (self.placements[first..last]) |placement| {
            if (placement.placed.block) |block| world_map.setBlock(placement.pos, block);
            if (placement.placed.meta) |meta| world_map.setBlockMetadata(placement.pos, meta);
        }
        for (self.chest_items.items) |item| {
            if (!inSquare(item.pos, square_x, square_z) or world_map.getBlock(item.pos) != .chest) continue;
            (try world_map.addChest(item.pos)).slot(item.slot).* = item.stack;
        }
        for (self.spawners.items) |spawner| {
            if (!inSquare(spawner.pos, square_x, square_z) or world_map.getBlock(spawner.pos) != .mob_spawner) continue;
            (try world_map.addMobSpawner(spawner.pos)).setMobName(spawner.name[0..spawner.len]);
        }
    }
};

fn inSquare(pos: world.BlockPos, x: i32, z: i32) bool {
    return pos.x >= x and pos.x < x + width and pos.z >= z and pos.z < z + width;
}

pub const Terrain = struct {
    gpa: std.mem.Allocator,
    generator: *world.Generator,
    chunks: std.AutoHashMapUnmanaged([2]i32, *world.Chunk) = .{},

    pub fn deinit(self: *Terrain) void {
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| self.gpa.destroy(chunk.*);
        self.chunks.deinit(self.gpa);
    }

    pub fn column(self: *Terrain, x: i32, z: i32) !struct { *world.Chunk, u32, u32 } {
        const chunk_x = @divFloor(x, width);
        const chunk_z = @divFloor(z, width);
        const entry = try self.chunks.getOrPut(self.gpa, .{ chunk_x, chunk_z });
        if (!entry.found_existing) {
            errdefer _ = self.chunks.remove(.{ chunk_x, chunk_z });
            const chunk = try self.gpa.create(world.Chunk);
            chunk.* = .init(chunk_x, chunk_z);
            self.generator.generateShape(chunk);
            entry.value_ptr.* = chunk;
        }
        return .{ entry.value_ptr.*, @intCast(@mod(x, width)), @intCast(@mod(z, width)) };
    }
};

fn testStructure(chance: f64) Structure {
    return .{ .ref = 0, .salt = 99, .spacing = 4, .chance = chance, .radius = 1, .dimension = .overworld };
}

test "a structure's place in its cell follows the seed alone" {
    const tower = testStructure(1);
    const first = instanceIn(tower, 1234, -3, 5).?;
    const again = instanceIn(tower, 1234, -3, 5).?;
    try std.testing.expectEqual(first.origin_x, again.origin_x);
    try std.testing.expectEqual(first.origin_z, again.origin_z);
    try std.testing.expect(first.chunk_x >= -12 and first.chunk_x < -8);
    try std.testing.expect(first.chunk_z >= 20 and first.chunk_z < 24);
    try std.testing.expectEqual(first.chunk_x, @divFloor(first.origin_x, width));
}

test "chance decides whether a cell holds a structure at all" {
    var never: usize = 0;
    var always: usize = 0;
    var cell: i32 = 0;
    while (cell < 50) : (cell += 1) {
        if (instanceIn(testStructure(0), 7, cell, 0) != null) never += 1;
        if (instanceIn(testStructure(1), 7, cell, 0) != null) always += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), never);
    try std.testing.expectEqual(@as(usize, 50), always);
}

test "every chunk whose decoration square touches a structure's reach sees it" {
    const tower = testStructure(1);
    const instance = instanceIn(tower, 42, 2, 2).?;
    var plan: Plan = .init(std.testing.allocator, 0, tower, 42, 2, 2, instance);
    defer plan.deinit();

    var touching: usize = 0;
    var chunk_x = instance.chunk_x - 4;
    while (chunk_x <= instance.chunk_x + 4) : (chunk_x += 1) {
        var chunk_z = instance.chunk_z - 4;
        while (chunk_z <= instance.chunk_z + 4) : (chunk_z += 1) {
            const square_overlaps = chunk_x * width + 8 < plan.max_x and chunk_x * width + 24 > plan.min_x and
                chunk_z * width + 8 < plan.max_z and chunk_z * width + 24 > plan.min_z;
            try std.testing.expectEqual(square_overlaps, reaches(tower, instance, chunk_x, chunk_z));
            const cells = cellRange(tower, chunk_x);
            if (square_overlaps) {
                touching += 1;
                try std.testing.expect(cells[0] <= 2 and cells[1] >= 2);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 16), touching);
}
