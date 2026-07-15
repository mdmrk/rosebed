const std = @import("std");
const constants = @import("constants.zig");
const nbt = @import("nbt.zig");
const Chunk = @import("chunk.zig");

pub const level_key = "Level";

pub const Error = error{
    MissingLevel,
    MissingField,
    WrongFieldType,
    WrongArrayLength,
};

fn put(gpa: std.mem.Allocator, compound: *nbt.Compound, key: []const u8, tag: nbt.Tag) !void {
    try nbt.putDuped(gpa, compound, key, tag);
}

fn field(compound: nbt.Compound, key: []const u8) !nbt.Tag {
    return compound.get(key) orelse Error.MissingField;
}

fn intField(compound: nbt.Compound, key: []const u8) !i32 {
    return switch (try field(compound, key)) {
        .int => |value| value,
        else => Error.WrongFieldType,
    };
}

fn bytesField(compound: nbt.Compound, key: []const u8, expected: usize) ![]u8 {
    const bytes = switch (try field(compound, key)) {
        .byte_array => |value| value,
        else => return Error.WrongFieldType,
    };
    if (bytes.len != expected) return Error.WrongArrayLength;
    return bytes;
}

pub fn store(
    gpa: std.mem.Allocator,
    chunk: *const Chunk,
    world_time: i64,
    populated: bool,
    entities: []nbt.Tag,
) !nbt.Tag {
    var level: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = level };
        nbt.deinit(gpa, &owned);
    }

    try put(gpa, &level, "xPos", .{ .int = chunk.x });
    try put(gpa, &level, "zPos", .{ .int = chunk.z });
    try put(gpa, &level, "LastUpdate", .{ .long = world_time });
    try put(gpa, &level, "Blocks", .{ .byte_array = try gpa.dupe(u8, std.mem.asBytes(&chunk.blocks)) });
    try put(gpa, &level, "Data", .{ .byte_array = try gpa.dupe(u8, &chunk.metadata.data) });
    try put(gpa, &level, "SkyLight", .{ .byte_array = try gpa.dupe(u8, &chunk.sky_light.data) });
    try put(gpa, &level, "BlockLight", .{ .byte_array = try gpa.dupe(u8, &chunk.block_light.data) });
    try put(gpa, &level, "HeightMap", .{ .byte_array = try gpa.dupe(u8, &chunk.height_map) });
    try put(gpa, &level, "TerrainPopulated", .{ .byte = @intFromBool(populated) });
    try put(gpa, &level, "Entities", .{ .list = .{ .element_type = .compound, .items = entities } });
    try put(gpa, &level, "TileEntities", .{ .list = .{ .element_type = .compound, .items = try gpa.alloc(nbt.Tag, 0) } });

    var root: nbt.Compound = .{};
    errdefer {
        var owned: nbt.Tag = .{ .compound = root };
        nbt.deinit(gpa, &owned);
    }
    try put(gpa, &root, level_key, .{ .compound = level });
    return .{ .compound = root };
}

pub const Loaded = struct {
    chunk: Chunk,
    populated: bool,
    entities: []const nbt.Tag,
};

fn entityList(level: nbt.Compound) []const nbt.Tag {
    const tag = level.get("Entities") orelse return &.{};
    return switch (tag) {
        .list => |list| list.items,
        else => &.{},
    };
}

pub fn load(root: nbt.Tag) !Loaded {
    const outer = switch (root) {
        .compound => |c| c,
        else => return Error.WrongFieldType,
    };
    const level = switch (outer.get(level_key) orelse return Error.MissingLevel) {
        .compound => |c| c,
        else => return Error.WrongFieldType,
    };

    var chunk = Chunk.init(try intField(level, "xPos"), try intField(level, "zPos"));

    @memcpy(std.mem.asBytes(&chunk.blocks), try bytesField(level, "Blocks", constants.chunk_volume));
    @memcpy(&chunk.metadata.data, try bytesField(level, "Data", constants.chunk_volume / 2));
    @memcpy(&chunk.sky_light.data, try bytesField(level, "SkyLight", constants.chunk_volume / 2));
    @memcpy(&chunk.block_light.data, try bytesField(level, "BlockLight", constants.chunk_volume / 2));
    @memcpy(&chunk.height_map, try bytesField(level, "HeightMap", Chunk.width * Chunk.width));

    const populated = switch (try field(level, "TerrainPopulated")) {
        .byte => |value| value != 0,
        else => return Error.WrongFieldType,
    };

    return .{ .chunk = chunk, .populated = populated, .entities = entityList(level) };
}

const block = @import("block.zig");
const Block = @import("block.zig").Block;

fn sampleChunk() Chunk {
    var chunk = Chunk.init(-3, 7);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            chunk.setBlock(@intCast(x), 0, @intCast(z), Block.bedrock);
            chunk.setBlock(@intCast(x), 1, @intCast(z), Block.stone);
            chunk.setBlockMetadata(@intCast(x), 1, @intCast(z), @intCast(x % 16));
            chunk.setSkyLight(@intCast(x), 2, @intCast(z), 15);
            chunk.setBlockLight(@intCast(x), 1, @intCast(z), @intCast(z % 16));
            chunk.setHeightValue(@intCast(x), @intCast(z), @intCast(2 + x));
        }
    }
    return chunk;
}

test "a chunk survives a round trip through NBT tags" {
    const gpa = std.testing.allocator;
    const original = sampleChunk();

    var tag = try store(gpa, &original, 1234, true, try gpa.alloc(nbt.Tag, 0));
    defer nbt.deinit(gpa, &tag);

    const loaded = try load(tag);
    try std.testing.expectEqual(original.x, loaded.chunk.x);
    try std.testing.expectEqual(original.z, loaded.chunk.z);
    try std.testing.expect(loaded.populated);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original.blocks), std.mem.asBytes(&loaded.chunk.blocks));
    try std.testing.expectEqualSlices(u8, &original.metadata.data, &loaded.chunk.metadata.data);
    try std.testing.expectEqualSlices(u8, &original.sky_light.data, &loaded.chunk.sky_light.data);
    try std.testing.expectEqualSlices(u8, &original.block_light.data, &loaded.chunk.block_light.data);
    try std.testing.expectEqualSlices(u8, &original.height_map, &loaded.chunk.height_map);
}

test "a chunk survives a round trip through the NBT wire format" {
    const gpa = std.testing.allocator;
    const original = sampleChunk();

    var tag = try store(gpa, &original, 99, false, try gpa.alloc(nbt.Tag, 0));
    defer nbt.deinit(gpa, &tag);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var writer = std.Io.Writer.Allocating.fromArrayList(gpa, &buffer);
    defer buffer = writer.toArrayList();
    try nbt.writeNamed(&writer.writer, "", tag);

    var reader = std.Io.Reader.fixed(writer.written());
    var decoded = try nbt.readNamed(gpa, &reader);
    defer {
        gpa.free(decoded.name);
        nbt.deinit(gpa, &decoded.tag);
    }

    const loaded = try load(decoded.tag);
    try std.testing.expectEqual(original.x, loaded.chunk.x);
    try std.testing.expect(!loaded.populated);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original.blocks), std.mem.asBytes(&loaded.chunk.blocks));
    try std.testing.expectEqualSlices(u8, &original.sky_light.data, &loaded.chunk.sky_light.data);
}

test "the stored layout is the original's Level compound" {
    const gpa = std.testing.allocator;
    const original = sampleChunk();

    var tag = try store(gpa, &original, 5, true, try gpa.alloc(nbt.Tag, 0));
    defer nbt.deinit(gpa, &tag);

    const level = tag.compound.get(level_key).?.compound;
    try std.testing.expectEqual(@as(i32, -3), level.get("xPos").?.int);
    try std.testing.expectEqual(@as(i32, 7), level.get("zPos").?.int);
    try std.testing.expectEqual(@as(i64, 5), level.get("LastUpdate").?.long);
    try std.testing.expectEqual(@as(usize, constants.chunk_volume), level.get("Blocks").?.byte_array.len);
    try std.testing.expectEqual(@as(usize, constants.chunk_volume / 2), level.get("Data").?.byte_array.len);
    try std.testing.expectEqual(@as(usize, 256), level.get("HeightMap").?.byte_array.len);
    try std.testing.expectEqual(@as(usize, 0), level.get("Entities").?.list.items.len);
}

test "a compound without a Level is rejected rather than half-loaded" {
    const gpa = std.testing.allocator;
    var tag: nbt.Tag = .{ .compound = .{} };
    defer nbt.deinit(gpa, &tag);

    try std.testing.expectError(Error.MissingLevel, load(tag));
}

test "a truncated block array is rejected" {
    const gpa = std.testing.allocator;
    const original = sampleChunk();

    var tag = try store(gpa, &original, 0, true, try gpa.alloc(nbt.Tag, 0));
    defer nbt.deinit(gpa, &tag);

    const level = tag.compound.getPtr(level_key).?;
    const blocks = level.compound.getPtr("Blocks").?;
    gpa.free(blocks.byte_array);
    blocks.byte_array = try gpa.dupe(u8, &.{ 1, 2, 3 });

    try std.testing.expectError(Error.WrongArrayLength, load(tag));
}
