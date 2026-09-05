const std = @import("std");

const assets = @import("assets");
const math = @import("math");

const Block = @import("block.zig").Block;
const BlockPos = @import("BlockPos.zig");
const Chunk = @import("Chunk.zig");
const World = @import("World.zig");

pub fn flatWorld(allocator: std.mem.Allocator, floor_height: u32) !World {
    var w = World.init(allocator);
    errdefer w.deinit();

    const chunk = try w.createChunk(0, 0);
    for (0..Chunk.width) |x| {
        for (0..Chunk.width) |z| {
            var y: u32 = 0;
            while (y < floor_height) : (y += 1) {
                chunk.setBlock(@intCast(x), y, @intCast(z), .stone);
            }
        }
    }
    return w;
}

pub fn stoneFloor(gpa: std.mem.Allocator, sky_light: ?u4) !World {
    var w = World.init(gpa);
    errdefer w.deinit();

    var chunk_x: i32 = -2;
    while (chunk_x <= 2) : (chunk_x += 1) {
        var chunk_z: i32 = -2;
        while (chunk_z <= 2) : (chunk_z += 1) {
            const chunk = try w.createChunk(chunk_x, chunk_z);
            for (0..Chunk.width) |x| {
                for (0..Chunk.width) |z| {
                    chunk.setBlock(@intCast(x), 0, @intCast(z), .stone);
                    if (sky_light) |level| chunk.setSkyLight(@intCast(x), 1, @intCast(z), level);
                }
            }
        }
    }
    return w;
}

test "the floor is solid up to the requested height and open above it" {
    var w = try flatWorld(std.testing.allocator, 2);
    defer w.deinit();

    try std.testing.expectEqual(.stone, w.getBlock(.init(8, 0, 8)));
    try std.testing.expectEqual(.stone, w.getBlock(.init(8, 1, 8)));
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 2, 8)));
}

test "a zero-height floor still loads the chunk" {
    var w = try flatWorld(std.testing.allocator, 0);
    defer w.deinit();

    try std.testing.expect(w.getChunk(0, 0) != null);
    try std.testing.expectEqual(.air, w.getBlock(.init(8, 0, 8)));
}

pub const HeardSound = struct {
    key: []const u8 = "",
    volume: f32 = 0,
    pitch: f32 = 0,

    fn record(context: *anyopaque, sound: assets.Sound, _: math.Vec3, volume: f32, pitch: f32) void {
        const self: *HeardSound = @ptrCast(@alignCast(context));
        self.key = sound.key;
        self.volume = volume;
        self.pitch = pitch;
    }

    fn ignoreRecord(_: *anyopaque, _: ?[]const u8, _: BlockPos) void {}

    pub fn sink(self: *HeardSound) World.SoundSink {
        return .{ .context = self, .playSound = record, .playRecord = ignoreRecord };
    }
};
