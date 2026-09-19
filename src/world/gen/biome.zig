const std = @import("std");

const Block = @import("../block.zig").Block;
const JavaRandom = @import("../JavaRandom.zig");
const PerlinNoise = @import("PerlinNoise.zig");

pub const vanilla_count = 10;
pub const capacity = 32;

pub const Set = std.StaticBitSet(capacity);

pub const Def = struct {
    key: []const u8,
    parent: Biome,
    share: f64,
    top: Block,
    filler: Block,
    snows: bool,
    rains: bool,
    trees: ?i32 = null,
    grass: ?i32 = null,
    flowers: ?i32 = null,
};

var defs: [capacity - vanilla_count]Def = undefined;
var registered: usize = 0;
var split_parents: Set = .initEmpty();

pub const Biome = enum(u8) {
    tundra,
    savanna,
    desert,
    swampland,
    taiga,
    shrubland,
    forest,
    plains,
    seasonal_forest,
    rainforest,
    _,

    pub fn def(self: Biome) ?*const Def {
        const raw = @intFromEnum(self);
        if (raw < vanilla_count or raw - vanilla_count >= registered) return null;
        return &defs[raw - vanilla_count];
    }

    pub fn vanilla(self: Biome) Biome {
        if (self.def()) |entry| return entry.parent;
        return if (@intFromEnum(self) < vanilla_count) self else .plains;
    }

    pub fn name(self: Biome) []const u8 {
        if (self.def()) |entry| return entry.key;
        return std.enums.tagName(Biome, self.vanilla()).?;
    }

    pub fn fromName(text: []const u8) ?Biome {
        if (std.meta.stringToEnum(Biome, text)) |found| return found;
        for (defs[0..registered], 0..) |*entry, slot| {
            if (std.mem.eql(u8, entry.key, text)) return @enumFromInt(vanilla_count + slot);
        }
        return null;
    }

    pub fn topBlock(self: Biome) Block {
        if (self.def()) |entry| return entry.top;
        return switch (self) {
            .desert => .sand,
            else => .grass,
        };
    }

    pub fn fillerBlock(self: Biome) Block {
        if (self.def()) |entry| return entry.filler;
        return switch (self) {
            .desert => .sand,
            else => .dirt,
        };
    }

    pub fn snows(self: Biome) bool {
        if (self.def()) |entry| return entry.snows;
        return switch (self) {
            .tundra, .taiga => true,
            else => false,
        };
    }

    pub fn rains(self: Biome) bool {
        if (self.def()) |entry| return entry.rains;
        return self != .desert;
    }

    pub fn canSpawnLightningBolt(self: Biome) bool {
        return !self.snows() and self.rains();
    }
};

fn classifyExact(temperature: f32, humidity: f32) Biome {
    const rainfall = humidity * temperature;
    if (temperature < 0.1) return .tundra;
    if (rainfall < 0.2) {
        if (temperature < 0.5) return .tundra;
        if (temperature < 0.95) return .savanna;
        return .desert;
    }
    if (rainfall > 0.5 and temperature < 0.7) return .swampland;
    if (temperature < 0.5) return .taiga;
    if (temperature < 0.97) {
        if (rainfall < 0.35) return .shrubland;
        return .forest;
    }
    if (rainfall < 0.45) return .plains;
    if (rainfall < 0.9) return .seasonal_forest;
    return .rainforest;
}

pub const RegisterError = error{ DuplicateKey, RegistryFull, NoShareLeft };

pub fn register(entry: Def) RegisterError!Biome {
    if (Biome.fromName(entry.key) != null) return error.DuplicateKey;
    if (registered == defs.len) return error.RegistryFull;
    var taken: f64 = 0;
    for (defs[0..registered]) |*other| {
        if (other.parent == entry.parent) taken += other.share;
    }
    if (taken + entry.share > 1.0 + 1e-9) return error.NoShareLeft;
    defs[registered] = entry;
    registered += 1;
    split_parents.set(@intFromEnum(entry.parent));
    return @enumFromInt(vanilla_count + registered - 1);
}

pub fn resetRegistry() void {
    registered = 0;
    split_parents = .initEmpty();
}

const selector_salt: i64 = 0x62696f6d6573;
const cell_size: f64 = 96.0;
const warp_scale: f64 = 1.0 / 64.0;
const warp_reach: f64 = 40.0;

const Warp = struct {
    seed: i64,
    x: PerlinNoise,
    z: PerlinNoise,
};

var warp: ?Warp = null;

fn selector(seed: i64, x: i32, z: i32) f64 {
    if (warp == null or warp.?.seed != seed) {
        var rand = JavaRandom.init(seed ^ selector_salt);
        warp = .{ .seed = seed, .x = .init(&rand), .z = .init(&rand) };
    }
    const noise = &warp.?;
    const fx: f64 = @floatFromInt(x);
    const fz: f64 = @floatFromInt(z);
    const warped_x = fx + noise.x.noise(fx * warp_scale, 0, fz * warp_scale) * warp_reach;
    const warped_z = fz + noise.z.noise(fx * warp_scale, 0, fz * warp_scale) * warp_reach;
    const cell_x: i64 = @intFromFloat(@floor(warped_x / cell_size));
    const cell_z: i64 = @intFromFloat(@floor(warped_z / cell_size));
    var rand = JavaRandom.init(seed ^ (cell_x *% 341873128712) ^ (cell_z *% 132897987541) ^ selector_salt);
    return rand.nextDouble();
}

pub fn resolve(parent: Biome, seed: i64, x: i32, z: i32) Biome {
    if (!split_parents.isSet(@intFromEnum(parent))) return parent;

    const pick = selector(seed, x, z);
    var reached: f64 = 0;
    for (defs[0..registered], 0..) |*entry, slot| {
        if (entry.parent != parent) continue;
        reached += entry.share;
        if (pick < reached) return @enumFromInt(vanilla_count + slot);
    }
    return parent;
}

pub fn classify(temperature: f64, humidity: f64) Biome {
    const q_temp: i32 = @intFromFloat(temperature * 63.0);
    const q_humidity: i32 = @intFromFloat(humidity * 63.0);
    return classifyExact(@as(f32, @floatFromInt(q_temp)) / 63.0, @as(f32, @floatFromInt(q_humidity)) / 63.0);
}

test "cold and dry is tundra" {
    try std.testing.expectEqual(Biome.tundra, classify(0.05, 0.5));
}

test "hot and dry is desert" {
    try std.testing.expectEqual(Biome.desert, classify(0.98, 0.1));
}

test "hot and very wet is rainforest" {
    try std.testing.expectEqual(Biome.rainforest, classify(0.99, 0.99));
}

test "default 0.5/0.5 climate is taiga after quantization" {
    try std.testing.expectEqual(Biome.taiga, classify(0.5, 0.5));
}

test "desert biome tops with sand, others with grass" {
    try std.testing.expectEqual(.sand, Biome.desert.topBlock());
    try std.testing.expectEqual(.grass, Biome.forest.topBlock());
}

test "snow falls on the cold biomes and rain skips the desert" {
    try std.testing.expect(Biome.tundra.snows());
    try std.testing.expect(Biome.taiga.snows());
    try std.testing.expect(!Biome.forest.snows());

    try std.testing.expect(!Biome.desert.rains());
    try std.testing.expect(Biome.forest.rains());
}

fn testChild(key: []const u8, parent: Biome, share: f64) Def {
    return .{ .key = key, .parent = parent, .share = share, .top = .stone, .filler = .gravel, .snows = true, .rains = true, .trees = 3 };
}

test "a registered biome answers for itself and falls back on its parent" {
    defer resetRegistry();
    const grove = try register(testChild("quartz:grove", .desert, 0.5));
    try std.testing.expectEqual(Biome.desert, grove.vanilla());
    try std.testing.expectEqualStrings("quartz:grove", grove.name());
    try std.testing.expectEqual(grove, Biome.fromName("quartz:grove").?);
    try std.testing.expectEqual(Biome.forest, Biome.fromName("forest").?);
    try std.testing.expectEqual(Block.stone, grove.topBlock());
    try std.testing.expect(grove.snows());
    try std.testing.expect(grove.canSpawnLightningBolt() == false);
    try std.testing.expectError(error.DuplicateKey, register(testChild("quartz:grove", .forest, 0.1)));
    try std.testing.expectError(error.NoShareLeft, register(testChild("quartz:dunes", .desert, 0.6)));
}

test "a child takes about its share of its parent's area, in blobs, and nothing else" {
    defer resetRegistry();
    const grove = try register(testChild("quartz:grove", .forest, 0.3));

    var in_grove: usize = 0;
    var changed_neighbours: usize = 0;
    const samples = 400;
    for (0..samples) |i| {
        for (0..samples) |j| {
            const x: i32 = @as(i32, @intCast(i)) * 8;
            const z: i32 = @as(i32, @intCast(j)) * 8;
            const here = resolve(.forest, 77, x, z);
            if (here == grove) in_grove += 1;
            if (resolve(.forest, 77, x + 1, z) != here) changed_neighbours += 1;
            try std.testing.expectEqual(Biome.plains, resolve(.plains, 77, x, z));
        }
    }
    const fraction = @as(f64, @floatFromInt(in_grove)) / @as(f64, samples * samples);
    try std.testing.expect(fraction > 0.2 and fraction < 0.4);
    try std.testing.expect(changed_neighbours < samples * samples / 20);
    try std.testing.expectEqual(resolve(.forest, 77, 1000, -2000), resolve(.forest, 77, 1000, -2000));
}

test "with nothing registered every biome resolves to itself" {
    try std.testing.expectEqual(Biome.forest, resolve(.forest, 1, 5, 5));
    try std.testing.expectEqual(@as(?*const Def, null), Biome.forest.def());
}

test "lightning needs a biome that rains without freezing" {
    try std.testing.expect(Biome.forest.canSpawnLightningBolt());
    try std.testing.expect(Biome.rainforest.canSpawnLightningBolt());
    try std.testing.expect(!Biome.taiga.canSpawnLightningBolt());
    try std.testing.expect(!Biome.desert.canSpawnLightningBolt());
}
