const std = @import("std");

const gl = @import("gl");
const math = @import("math");
const sdl3 = @import("sdl3");
const world = @import("world");

const Atlas = @import("atlas.zig");

const TextureFx = @This();

const tile = 16;
const cells = tile * tile;

fn waterStillTile() u8 {
    return world.Block.stationary_water.faceTextures().get(.up);
}

fn waterFlowTile() u8 {
    return world.Block.stationary_water.faceTextures().get(.north);
}

fn lavaStillTile() u8 {
    return world.Block.stationary_lava.faceTextures().get(.up);
}

fn lavaFlowTile() u8 {
    return world.Block.stationary_lava.faceTextures().get(.north);
}

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

pub const fire_tile: u8 = 31;

const flame_rows = 20;
const flame_cells = tile * flame_rows;

pub const Flames = struct {
    current: [flame_cells]f32 = @splat(0.0),
    next: [flame_cells]f32 = @splat(0.0),
    image: [cells * 4]u8 = @splat(0),

    pub fn tick(self: *Flames, rand: *world.JavaRandom) void {
        for (0..tile) |xi| {
            for (0..flame_rows) |yi| {
                const x: i32 = @intCast(xi);
                const y: i32 = @intCast(yi);
                var divisor: i32 = 18;
                var sum = self.current[xi + (yi + 1) % flame_rows * tile] * @as(f32, @floatFromInt(divisor));

                var a = x - 1;
                while (a <= x + 1) : (a += 1) {
                    var b = y;
                    while (b <= y + 1) : (b += 1) {
                        if (a >= 0 and b >= 0 and a < tile and b < flame_rows) {
                            sum += self.current[@intCast(a + b * tile)];
                        }
                        divisor += 1;
                    }
                }

                self.next[xi + yi * tile] = sum / (@as(f32, @floatFromInt(divisor)) * 1.06);
                if (yi >= flame_rows - 1) {
                    const spark = rand.nextDouble() * rand.nextDouble() * rand.nextDouble() * 4.0 +
                        rand.nextDouble() * 0.1 + 0.2;
                    self.next[xi + yi * tile] = @floatCast(spark);
                }
            }
        }

        std.mem.swap([flame_cells]f32, &self.current, &self.next);

        for (0..cells) |i| {
            const level = std.math.clamp(self.current[i] * 1.8, 0.0, 1.0);
            const squared = level * level;
            self.image[i * 4 + 0] = @intFromFloat(level * 155.0 + 100.0);
            self.image[i * 4 + 1] = @intFromFloat(squared * 255.0);
            self.image[i * 4 + 2] = @intFromFloat(squared * squared * squared * squared * squared * 255.0);
            self.image[i * 4 + 3] = if (level < 0.5) 0 else 255;
        }
    }
};

pub const portal_tile: u8 = 14;

const portal_frames = 32;

fn wrapByte(value: f32) u8 {
    return @truncate(@as(u32, @bitCast(@as(i32, @intFromFloat(value)))));
}

pub const Portal = struct {
    frames: [portal_frames][cells * 4]u8 = @splat(@splat(0)),
    image: [cells * 4]u8 = @splat(0),
    counter: u32 = 0,

    pub fn init() Portal {
        var self: Portal = .{};
        var rand: world.JavaRandom = .init(100);

        for (0..portal_frames) |frame| {
            for (0..tile) |x| {
                for (0..tile) |y| {
                    var level: f32 = 0.0;

                    for (0..2) |lobe| {
                        const offset: f32 = @floatFromInt(lobe * 8);
                        var dx = (@as(f32, @floatFromInt(x)) - offset) / 16.0 * 2.0;
                        var dy = (@as(f32, @floatFromInt(y)) - offset) / 16.0 * 2.0;
                        if (dx < -1.0) dx += 2.0;
                        if (dx >= 1.0) dx -= 2.0;
                        if (dy < -1.0) dy += 2.0;
                        if (dy >= 1.0) dy -= 2.0;

                        const radius = dx * dx + dy * dy;
                        const bearing: f32 = @floatCast(std.math.atan2(@as(f64, dy), @as(f64, dx)));
                        const spin = (@as(f32, @floatFromInt(frame)) / 32.0 * std.math.pi * 2.0 -
                            radius * 10.0 + @as(f32, @floatFromInt(lobe * 2))) *
                            @as(f32, @floatFromInt(@as(i32, @intCast(lobe)) * 2 - 1));

                        var wave = (math.util.sin(bearing + spin) + 1.0) / 2.0;
                        wave /= radius + 1.0;
                        level += wave * 0.5;
                    }

                    level += rand.nextFloat() * 0.1;

                    const at = (y * tile + x) * 4;
                    self.frames[frame][at + 0] = wrapByte(level * level * 200.0 + 55.0);
                    self.frames[frame][at + 1] = wrapByte(level * level * level * level * 255.0);
                    self.frames[frame][at + 2] = wrapByte(level * 100.0 + 155.0);
                    self.frames[frame][at + 3] = wrapByte(level * 100.0 + 155.0);
                }
            }
        }
        return self;
    }

    pub fn tick(self: *Portal) void {
        self.counter +%= 1;
        self.image = self.frames[self.counter & (portal_frames - 1)];
    }
};

pub const compass_tile: u8 = 54;

const compass_needle_grey: [4]u8 = .{ 100, 100, 100, 255 };
const compass_needle_red: [4]u8 = .{ 255, 20, 20, 255 };

pub const Spring = struct {
    angle: f64 = 0.0,
    velocity: f64 = 0.0,

    pub fn ease(self: *Spring, target: f64) void {
        var delta = target - self.angle;
        while (delta < -std.math.pi) delta += std.math.pi * 2.0;
        while (delta >= std.math.pi) delta -= std.math.pi * 2.0;
        delta = std.math.clamp(delta, -1.0, 1.0);

        self.velocity += delta * 0.1;
        self.velocity *= 0.8;
        self.angle += self.velocity;
    }
};

pub const Compass = struct {
    spin: Spring = .{},
    base: [cells * 4]u8 = @splat(0),
    image: [cells * 4]u8 = @splat(0),

    pub fn tick(self: *Compass, target: f64) void {
        self.spin.ease(target);

        @memcpy(&self.image, &self.base);

        const sin = @sin(self.spin.angle);
        const cos = @cos(self.spin.angle);

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

pub const clock_tile: u8 = 70;

pub const Clock = struct {
    spin: Spring = .{},
    base: [cells * 4]u8 = @splat(0),
    dial: [cells * 4]u8 = @splat(0),
    image: [cells * 4]u8 = @splat(0),

    fn showsDial(red: u8, green: u8, blue: u8) bool {
        return red == blue and green == 0 and blue > 0;
    }

    pub fn tick(self: *Clock, target: f64) void {
        self.spin.ease(target);

        const sin = @sin(self.spin.angle);
        const cos = @cos(self.spin.angle);

        for (0..cells) |i| {
            const red = self.base[i * 4 + 0];
            const green = self.base[i * 4 + 1];
            const blue = self.base[i * 4 + 2];

            if (!showsDial(red, green, blue)) {
                @memcpy(self.image[i * 4 ..][0..4], self.base[i * 4 ..][0..4]);
                continue;
            }

            const across = -(@as(f64, @floatFromInt(i % tile)) / 15.0 - 0.5);
            const down = @as(f64, @floatFromInt(i / tile)) / 15.0 - 0.5;
            const turned_x: i32 = @intFromFloat((across * cos + down * sin + 0.5) * 16.0);
            const turned_y: i32 = @intFromFloat((down * cos - across * sin + 0.5) * 16.0);
            const source: usize = @intCast((turned_x & 15) + (turned_y & 15) * tile);

            const tint: u32 = red;
            for (0..3) |channel| {
                self.image[i * 4 + channel] = @intCast(@as(u32, self.dial[source * 4 + channel]) * tint / 255);
            }
            self.image[i * 4 + 3] = self.dial[source * 4 + 3];
        }
    }
};

water: Water = .{ .flowing = false },
water_flow: Water = .{ .flowing = true },
lava: Lava = .{ .flowing = false },
lava_flow: Lava = .{ .flowing = true },
flames: Flames = .{},
flames_back: Flames = .{},
portal: Portal = .{},
compass: Compass = .{},
clock: Clock = .{},
rand: world.JavaRandom,

pub fn init(seed: i64) TextureFx {
    return .{ .rand = .init(seed), .portal = Portal.init() };
}

fn readTile(png: []const u8, index: u8, out: *[cells * 4]u8) !void {
    const surface = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(png), true);
    defer surface.deinit();
    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();

    const width = converted.getWidth();
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;

    const left = @as(usize, index % Atlas.tiles_per_row) * tile;
    const top = @as(usize, index / Atlas.tiles_per_row) * tile;
    for (0..tile) |row| {
        const source = ((top + row) * width + left) * 4;
        @memcpy(out[row * tile * 4 ..][0 .. tile * 4], pixels[source..][0 .. tile * 4]);
    }
}

pub fn loadSprites(self: *TextureFx, items_png: []const u8, dial_png: []const u8) !void {
    try readTile(items_png, compass_tile, &self.compass.base);
    try readTile(items_png, clock_tile, &self.clock.base);
    try readTile(dial_png, 0, &self.clock.dial);
}

pub fn tick(self: *TextureFx, compass_target: f64, clock_target: f64) void {
    self.compass.tick(compass_target);
    self.clock.tick(clock_target);
    self.lava.tick(&self.rand);
    self.water.tick(&self.rand);
    self.water_flow.tick(&self.rand);
    self.lava_flow.tick(&self.rand);
    self.flames.tick(&self.rand);
    self.flames_back.tick(&self.rand);
    self.portal.tick();
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
    uploadTile(&self.water.image, waterStillTile(), 1);
    uploadTile(&self.water_flow.image, waterFlowTile(), 2);
    uploadTile(&self.lava.image, lavaStillTile(), 1);
    uploadTile(&self.lava_flow.image, lavaFlowTile(), 2);
    uploadTile(&self.flames.image, fire_tile, 1);
    uploadTile(&self.flames_back.image, fire_tile + Atlas.tiles_per_row, 1);
    uploadTile(&self.portal.image, portal_tile, 1);

    items.bind();
    uploadTile(&self.compass.image, compass_tile, 1);
    uploadTile(&self.clock.image, clock_tile, 1);
}

test "the animated tiles are the ones the fluid blocks draw with" {
    try std.testing.expectEqual(@as(u8, 205), waterStillTile());
    try std.testing.expectEqual(@as(u8, 206), waterFlowTile());
    try std.testing.expectEqual(@as(u8, 237), lavaStillTile());
    try std.testing.expectEqual(@as(u8, 238), lavaFlowTile());
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

    try std.testing.expectApproxEqAbs(@as(f64, 0.08), fx.spin.velocity, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), fx.spin.angle, 1.0e-9);

    for (0..200) |_| fx.tick(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fx.spin.angle, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), fx.spin.velocity, 1.0e-6);
}

test "a bearing behind the needle is taken the short way round" {
    var fx: Compass = .{};
    fx.spin.angle = std.math.pi - 0.1;
    fx.tick(-std.math.pi + 0.1);

    try std.testing.expect(fx.spin.velocity > 0.0);
}

test "the swing toward a distant bearing is capped at a radian" {
    var straight: Compass = .{};
    straight.tick(1.0);

    var far: Compass = .{};
    far.tick(3.0);

    try std.testing.expectApproxEqAbs(straight.spin.velocity, far.spin.velocity, 1.0e-9);
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
        fx.spin.angle = angle;
        fx.spin.velocity = 0.0;
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

test "the clock is the icon Item.pocketSundial draws with" {
    try std.testing.expectEqual(@as(u8, 6 + 4 * 16), clock_tile);
}

test "only the magenta window of the clock face shows the dial" {
    try std.testing.expect(Clock.showsDial(204, 0, 204));
    try std.testing.expect(Clock.showsDial(255, 0, 255));
    try std.testing.expect(!Clock.showsDial(204, 0, 200));
    try std.testing.expect(!Clock.showsDial(204, 1, 204));
    try std.testing.expect(!Clock.showsDial(0, 0, 0));
}

test "the bezel is copied through untouched and the window is not" {
    var fx: Clock = .{};
    fx.base[0] = 90;
    fx.base[1] = 80;
    fx.base[2] = 70;
    fx.base[3] = 255;
    fx.base[4] = 204;
    fx.base[5] = 0;
    fx.base[6] = 204;
    fx.base[7] = 255;
    for (&fx.dial, 0..) |*channel, i| channel.* = if (i % 4 == 3) 255 else 128;

    fx.tick(0.0);

    try std.testing.expectEqual([4]u8{ 90, 80, 70, 255 }, fx.image[0..4].*);
    try std.testing.expectEqual(@as(u8, 128 * 204 / 255), fx.image[4]);
    try std.testing.expectEqual(@as(u8, 255), fx.image[7]);
}

test "the dial keeps turning and always samples inside itself" {
    var fx: Clock = .{};
    for (&fx.base, 0..) |*channel, i| {
        channel.* = switch (i % 4) {
            0, 2 => 204,
            1 => 0,
            else => 255,
        };
    }
    for (&fx.dial, 0..) |*channel, i| channel.* = @truncate(i);

    var angle: f64 = 0.0;
    while (angle < std.math.pi * 2.0) : (angle += 0.05) {
        fx.spin.angle = angle;
        fx.spin.velocity = 0.0;
        fx.tick(angle);
    }
}

test "the clock and the compass ease the same way, as both FX classes do" {
    var clock: Clock = .{};
    var compass: Compass = .{};
    clock.tick(1.0);
    compass.tick(1.0);

    try std.testing.expectEqual(compass.spin.angle, clock.spin.angle);
    try std.testing.expectEqual(compass.spin.velocity, clock.spin.velocity);
}

test "the flame tile is the one BlockFire draws with, and the second sits below it" {
    try std.testing.expectEqual(@as(u8, 15 + 1 * 16), fire_tile);
    try std.testing.expectEqual(@as(u8, 15 + 2 * 16), fire_tile + Atlas.tiles_per_row);
}

test "flames burn opaque orange at the base and fade to nothing at the top" {
    var rand = world.JavaRandom.init(4321);
    var fx: Flames = .{};
    for (0..100) |_| fx.tick(&rand);

    var lit: usize = 0;
    for (0..tile) |x| {
        const bottom = (tile - 1) * tile + x;
        if (fx.image[bottom * 4 + 3] == 255) lit += 1;
        try std.testing.expect(fx.image[bottom * 4 + 0] >= 100);
    }
    try std.testing.expect(lit > tile / 2);

    for (0..tile) |x| try std.testing.expectEqual(@as(u8, 0), fx.image[x * 4 + 3]);
}

test "the portal builds its thirty-two frames up front and cycles them" {
    var fx: Portal = Portal.init();

    const first = fx.frames[1];
    fx.tick();
    try std.testing.expectEqual(first, fx.image);

    for (0..32) |_| fx.tick();
    try std.testing.expectEqual(first, fx.image);
}

test "a portal frame is the purple TexturePortalFX draws, never fully transparent" {
    const fx: Portal = Portal.init();

    var any_lit = false;
    for (0..cells) |i| {
        const red = fx.frames[0][i * 4 + 0];
        const blue = fx.frames[0][i * 4 + 2];
        if (blue > red) any_lit = true;
    }
    try std.testing.expect(any_lit);
}
