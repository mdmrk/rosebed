const std = @import("std");

const gl = @import("gl");
const math = @import("math");
const sdl3 = @import("sdl3");
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

pub const compass_tile: u8 = 54;

const compass_needle_grey: [4]u8 = .{ 100, 100, 100, 255 };
const compass_needle_red: [4]u8 = .{ 255, 20, 20, 255 };

pub const Compass = struct {
    angle: f64 = 0.0,
    velocity: f64 = 0.0,
    base: [cells * 4]u8 = @splat(0),
    image: [cells * 4]u8 = @splat(0),

    pub fn tick(self: *Compass, target: f64) void {
        var delta = target - self.angle;
        while (delta < -std.math.pi) delta += std.math.pi * 2.0;
        while (delta >= std.math.pi) delta -= std.math.pi * 2.0;
        delta = std.math.clamp(delta, -1.0, 1.0);

        self.velocity += delta * 0.1;
        self.velocity *= 0.8;
        self.angle += self.velocity;

        @memcpy(&self.image, &self.base);

        const sin = @sin(self.angle);
        const cos = @cos(self.angle);

        var along: i32 = -4;
        while (along <= 4) : (along += 1) {
            const reach: f64 = @floatFromInt(along);
            self.plot(8.5 + cos * reach * 0.3, 7.5 - sin * reach * 0.3 * 0.5, compass_needle_grey);
        }

        along = -8;
        while (along <= 16) : (along += 1) {
            const reach: f64 = @floatFromInt(along);
            const colour = if (along >= 0) compass_needle_red else compass_needle_grey;
            self.plot(8.5 + sin * reach * 0.3, 7.5 + cos * reach * 0.3 * 0.5, colour);
        }
    }

    fn plot(self: *Compass, x: f64, y: f64, colour: [4]u8) void {
        const col: i32 = @intFromFloat(x);
        const row: i32 = @intFromFloat(y);
        const index: usize = @intCast(row * tile + col);
        @memcpy(self.image[index * 4 ..][0..4], &colour);
    }
};

water: Water = .{ .flowing = false },
water_flow: Water = .{ .flowing = true },
lava: Lava = .{ .flowing = false },
lava_flow: Lava = .{ .flowing = true },
compass: Compass = .{},
rand: world.JavaRandom,

pub fn init(seed: i64) TextureFx {
    return .{ .rand = .init(seed) };
}

pub fn loadCompassBase(self: *TextureFx, png: []const u8) !void {
    const surface = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(png), true);
    defer surface.deinit();
    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();

    const width = converted.getWidth();
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;

    const left = @as(usize, compass_tile % Atlas.tiles_per_row) * tile;
    const top = @as(usize, compass_tile / Atlas.tiles_per_row) * tile;
    for (0..tile) |row| {
        const source = ((top + row) * width + left) * 4;
        @memcpy(self.compass.base[row * tile * 4 ..][0 .. tile * 4], pixels[source..][0 .. tile * 4]);
    }
}

pub fn tick(self: *TextureFx, compass_target: f64) void {
    self.compass.tick(compass_target);
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

pub fn upload(self: *const TextureFx, terrain: Atlas, items: Atlas) void {
    terrain.bind();
    uploadTile(&self.water.image, water_still_tile, 1);
    uploadTile(&self.water_flow.image, water_flow_tile, 2);
    uploadTile(&self.lava.image, lava_still_tile, 1);
    uploadTile(&self.lava_flow.image, lava_flow_tile, 2);

    items.bind();
    uploadTile(&self.compass.image, compass_tile, 1);
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

test "the compass is the icon Item.compass draws with" {
    try std.testing.expectEqual(@as(u8, 6 + 3 * 16), compass_tile);
}

test "the needle eases onto its bearing instead of snapping to it" {
    var fx: Compass = .{};
    fx.tick(1.0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.08), fx.velocity, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), fx.angle, 1.0e-9);

    for (0..200) |_| fx.tick(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fx.angle, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), fx.velocity, 1.0e-6);
}

test "a bearing behind the needle is taken the short way round" {
    var fx: Compass = .{};
    fx.angle = std.math.pi - 0.1;
    fx.tick(-std.math.pi + 0.1);

    try std.testing.expect(fx.velocity > 0.0);
}

test "the swing toward a distant bearing is capped at a radian" {
    var straight: Compass = .{};
    straight.tick(1.0);

    var far: Compass = .{};
    far.tick(3.0);

    try std.testing.expectApproxEqAbs(straight.velocity, far.velocity, 1.0e-9);
}

test "the needle paints a red half, a grey tail and a grey crossbar" {
    var fx: Compass = .{};
    fx.tick(0.0);

    var red: usize = 0;
    var grey: usize = 0;
    for (0..cells) |i| {
        const pixel = fx.image[i * 4 ..][0..4].*;
        if (std.mem.eql(u8, &pixel, &compass_needle_red)) red += 1;
        if (std.mem.eql(u8, &pixel, &compass_needle_grey)) grey += 1;
    }
    try std.testing.expect(red > 0);
    try std.testing.expect(grey > 0);
}

test "the needle never paints outside its own sixteen by sixteen tile" {
    var fx: Compass = .{};
    var angle: f64 = 0.0;
    while (angle < std.math.pi * 2.0) : (angle += 0.05) {
        fx.angle = angle;
        fx.velocity = 0.0;
        fx.tick(angle);
    }
}

test "the dial underneath survives every tick the needle is drawn on" {
    var fx: Compass = .{};
    for (&fx.base, 0..) |*channel, i| channel.* = @truncate(i);

    const corner = fx.base[0..4].*;
    fx.tick(0.0);
    try std.testing.expectEqual(corner, fx.image[0..4].*);
}
