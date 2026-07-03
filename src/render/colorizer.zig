const std = @import("std");
const sdl3 = @import("sdl3");
const assets = @import("assets");

const Colorizer = @This();

pub const white: [3]u8 = .{ 255, 255, 255 };
pub const pine: [3]u8 = unpack(6396257);
pub const birch: [3]u8 = unpack(8431445);

const table_size = 256;

grass: []const [3]u8,
foliage: []const [3]u8,

pub const untinted: Colorizer = .{ .grass = &.{}, .foliage = &.{} };

fn unpack(color: u24) [3]u8 {
    return .{
        @intCast(color >> 16 & 255),
        @intCast(color >> 8 & 255),
        @intCast(color & 255),
    };
}

fn loadTable(gpa: std.mem.Allocator, data: []const u8) ![]const [3]u8 {
    const surface = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(data), true);
    defer surface.deinit();

    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();

    if (converted.getWidth() != table_size or converted.getHeight() != table_size) {
        return error.UnexpectedColorTableSize;
    }
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;

    const table = try gpa.alloc([3]u8, table_size * table_size);
    errdefer gpa.free(table);
    for (table, 0..) |*entry, i| {
        entry.* = .{ pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2] };
    }
    return table;
}

pub fn load(gpa: std.mem.Allocator) !Colorizer {
    const grass = try loadTable(gpa, assets.misc.grasscolor_png);
    errdefer gpa.free(grass);
    const foliage = try loadTable(gpa, assets.misc.foliagecolor_png);
    return .{ .grass = grass, .foliage = foliage };
}

pub fn deinit(self: Colorizer, gpa: std.mem.Allocator) void {
    gpa.free(self.grass);
    gpa.free(self.foliage);
}

fn lookup(table: []const [3]u8, temperature: f64, humidity: f64) [3]u8 {
    if (table.len == 0) return white;
    const scaled_humidity = humidity * temperature;
    const column: usize = @intFromFloat((1.0 - temperature) * 255.0);
    const row: usize = @intFromFloat((1.0 - scaled_humidity) * 255.0);
    return table[row << 8 | column];
}

pub fn grassColor(self: Colorizer, temperature: f64, humidity: f64) [3]u8 {
    return lookup(self.grass, temperature, humidity);
}

pub fn foliageColor(self: Colorizer, temperature: f64, humidity: f64) [3]u8 {
    return lookup(self.foliage, temperature, humidity);
}

test "an untinted colorizer leaves every color at full white" {
    try std.testing.expectEqual(white, untinted.grassColor(1.0, 1.0));
    try std.testing.expectEqual(white, untinted.foliageColor(0.0, 0.0));
}

test "the lookup indexes the way ColorizerGrass does" {
    var table: [table_size * table_size][3]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        entry.* = .{ @intCast(i >> 8), @intCast(i & 255), 0 };
    }
    const colorizer: Colorizer = .{ .grass = &table, .foliage = &table };

    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, colorizer.grassColor(1.0, 1.0));
    try std.testing.expectEqual([3]u8{ 255, 255, 0 }, colorizer.grassColor(0.0, 1.0));
    try std.testing.expectEqual([3]u8{ 127, 127, 0 }, colorizer.grassColor(0.5, 1.0));
}

test "the pine and birch constants unpack the original's packed values" {
    try std.testing.expectEqual([3]u8{ 0x61, 0x99, 0x61 }, pine);
    try std.testing.expectEqual([3]u8{ 0x80, 0xa7, 0x55 }, birch);
}
