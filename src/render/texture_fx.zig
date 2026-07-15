const std = @import("std");
const gl = @import("gl");
const math = @import("math");
const world = @import("world");

const Atlas = @import("atlas.zig");

const TextureFx = @This();

const tile = 16;
const cells = tile * tile;

const water_still_tile = world.Block.stationary_water.faceTextures().get(.up);
const water_flow_tile = world.Block.stationary_water.faceTextures().get(.north);
const lava_still_tile = world.Block.stationary_lava.faceTextures().get(.up);
const lava_flow_tile = world.Block.stationary_lava.faceTextures().get(.north);

fn wrapped(x: i32, y: i32) usize {
    return @intCast((x & 15) + (y & 15) * tile);
}

fn scrolled(index: usize, rows: i32) usize {
    return @intCast((@as(i32, @intCast(index)) -% rows *% tile) & 255);
}

pub const Water = struct {
    current: [cells]f32 = @splat(0.0),
    next: [cells]f32 = @splat(0.0),
    heat: [cells]f32 = @splat(0.0),
    velocity: [cells]f32 = @splat(0.0),
    counter: i32 = 0,
    flowing: bool,
    image: [cells * 4]u8 = @splat(0),

    pub fn tick(self: *Water, rand: *world.JavaRandom) void {
        const divisor: f32 = if (self.flowing) 3.2 else 3.3;
        const gravity: f32 = if (self.flowing) 0.3 else 0.1;
        const spawn_chance: f64 = if (self.flowing) 0.2 else 0.05;

        self.counter +%= 1;

        for (0..tile) |xi| {
            for (0..tile) |yi| {
                const x: i32 = @intCast(xi);
                const y: i32 = @intCast(yi);
                var sum: f32 = 0.0;
                if (self.flowing) {
                    var k = y - 2;
                    while (k <= y) : (k += 1) sum += self.current[wrapped(x, k)];
                } else {
                    var k = x - 1;
                    while (k <= x + 1) : (k += 1) sum += self.current[wrapped(k, y)];
                }
                self.next[xi + yi * tile] = sum / divisor + self.heat[xi + yi * tile] * 0.8;
            }
        }

        for (0..tile) |xi| {
            for (0..tile) |yi| {
                const i = xi + yi * tile;
                self.heat[i] += self.velocity[i] * 0.05;
                if (self.heat[i] < 0.0) self.heat[i] = 0.0;
                self.velocity[i] -= gravity;
                if (rand.nextDouble() < spawn_chance) self.velocity[i] = 0.5;
            }
        }

        std.mem.swap([cells]f32, &self.current, &self.next);

        for (0..cells) |i| {
            const source = if (self.flowing) scrolled(i, self.counter) else i;
            const level = std.math.clamp(self.current[source], 0.0, 1.0);
            const shade = level * level;
            self.image[i * 4 + 0] = @intFromFloat(32.0 + shade * 32.0);
            self.image[i * 4 + 1] = @intFromFloat(50.0 + shade * 64.0);
            self.image[i * 4 + 2] = 255;
            self.image[i * 4 + 3] = @intFromFloat(146.0 + shade * 50.0);
        }
    }
};

pub const Lava = struct {
    current: [cells]f32 = @splat(0.0),
    next: [cells]f32 = @splat(0.0),
    heat: [cells]f32 = @splat(0.0),
    velocity: [cells]f32 = @splat(0.0),
    counter: i32 = 0,
    flowing: bool,
    image: [cells * 4]u8 = @splat(0),

    pub fn tick(self: *Lava, rand: *world.JavaRandom) void {
        self.counter +%= 1;

        for (0..tile) |xi| {
            for (0..tile) |yi| {
                const x: i32 = @intCast(xi);
                const y: i32 = @intCast(yi);
                var sum: f32 = 0.0;
                const swirl_x: i32 = @intFromFloat(math.util.sin(@as(f32, @floatFromInt(y)) * std.math.pi * 2.0 / 16.0) * 1.2);
                const swirl_y: i32 = @intFromFloat(math.util.sin(@as(f32, @floatFromInt(x)) * std.math.pi * 2.0 / 16.0) * 1.2);

                var a = x - 1;
                while (a <= x + 1) : (a += 1) {
                    var b = y - 1;
                    while (b <= y + 1) : (b += 1) sum += self.current[wrapped(a + swirl_x, b + swirl_y)];
                }

                const neighbours = self.heat[wrapped(x, y)] +
                    self.heat[wrapped(x + 1, y)] +
                    self.heat[wrapped(x + 1, y + 1)] +
                    self.heat[wrapped(x, y + 1)];
                self.next[xi + yi * tile] = sum / 10.0 + neighbours / 4.0 * 0.8;

                const i = xi + yi * tile;
                self.heat[i] += self.velocity[i] * 0.01;
                if (self.heat[i] < 0.0) self.heat[i] = 0.0;
                self.velocity[i] -= 0.06;
                if (rand.nextDouble() < 0.005) self.velocity[i] = 1.5;
            }
        }

        std.mem.swap([cells]f32, &self.current, &self.next);

        for (0..cells) |i| {
            const source = if (self.flowing) scrolled(i, @divTrunc(self.counter, 3)) else i;
            const level = std.math.clamp(self.current[source] * 2.0, 0.0, 1.0);
            self.image[i * 4 + 0] = @intFromFloat(level * 100.0 + 155.0);
            self.image[i * 4 + 1] = @intFromFloat(level * level * 255.0);
            self.image[i * 4 + 2] = @intFromFloat(level * level * level * level * 128.0);
            self.image[i * 4 + 3] = 255;
        }
    }
};

water: Water = .{ .flowing = false },
water_flow: Water = .{ .flowing = true },
lava: Lava = .{ .flowing = false },
lava_flow: Lava = .{ .flowing = true },
rand: world.JavaRandom,

pub fn init(seed: i64) TextureFx {
    return .{ .rand = .init(seed) };
}

pub fn tick(self: *TextureFx) void {
    self.lava.tick(&self.rand);
    self.water.tick(&self.rand);
    self.water_flow.tick(&self.rand);
    self.lava_flow.tick(&self.rand);
}

fn uploadTile(image: []const u8, index: u8, span: gl.int) void {
    const x: gl.int = @as(gl.int, index % Atlas.tiles_per_row) * tile;
    const y: gl.int = @as(gl.int, index / Atlas.tiles_per_row) * tile;
    var dx: gl.int = 0;
    while (dx < span) : (dx += 1) {
        var dy: gl.int = 0;
        while (dy < span) : (dy += 1) {
            gl.TexSubImage2D(gl.TEXTURE_2D, 0, x + dx * tile, y + dy * tile, tile, tile, gl.RGBA, gl.UNSIGNED_BYTE, image.ptr);
        }
    }
}

pub fn upload(self: *const TextureFx, terrain: Atlas) void {
    terrain.bind();
    uploadTile(&self.water.image, water_still_tile, 1);
    uploadTile(&self.water_flow.image, water_flow_tile, 2);
    uploadTile(&self.lava.image, lava_still_tile, 1);
    uploadTile(&self.lava_flow.image, lava_flow_tile, 2);
}

test "the animated tiles are the ones the fluid blocks draw with" {
    try std.testing.expectEqual(@as(u8, 205), water_still_tile);
    try std.testing.expectEqual(@as(u8, 206), water_flow_tile);
    try std.testing.expectEqual(@as(u8, 237), lava_still_tile);
    try std.testing.expectEqual(@as(u8, 238), lava_flow_tile);
}

test "a settled water tile is the flat blue TextureWaterFX starts from" {
    var rand = world.JavaRandom.init(0);
    var fx: Water = .{ .flowing = false };
    fx.tick(&rand);

    try std.testing.expectEqual([4]u8{ 32, 50, 255, 146 }, fx.image[0..4].*);
}

test "a settled lava tile is the opaque orange TextureLavaFX starts from" {
    var rand = world.JavaRandom.init(0);
    var fx: Lava = .{ .flowing = false };
    fx.tick(&rand);

    try std.testing.expectEqual([4]u8{ 155, 0, 0, 255 }, fx.image[0..4].*);
}

test "flowing tiles scroll their sample row by row" {
    try std.testing.expectEqual(@as(usize, 0), scrolled(16, 1));
    try std.testing.expectEqual(@as(usize, 240), scrolled(0, 1));
    try std.testing.expectEqual(@as(usize, 5), scrolled(5, 16));
}

test "ticking never leaves a fully transparent water tile" {
    var rand = world.JavaRandom.init(12345);
    var fx: Water = .{ .flowing = true };
    for (0..200) |_| fx.tick(&rand);

    for (0..cells) |i| try std.testing.expect(fx.image[i * 4 + 3] >= 146);
}
