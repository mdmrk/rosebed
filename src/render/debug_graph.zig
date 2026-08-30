const std = @import("std");

const gl = @import("gl");

const gui = @import("gui.zig");
const MeshBuilder = @import("MeshBuilder.zig");
const Shader = @import("Shader.zig");

pub const sample_count = 512;

const target_frame_ns: u64 = 16_666_666;
const ns_per_pixel: u64 = 200_000;

const under_target: [4]u8 = .{ 0, 0, 0, 255 };
const over_target: [4]u8 = .{ 32, 0, 0, 255 };
const average: [4]u8 = .{ 64, 0, 0, 255 };

const no_uv: [4][2]f32 = @splat(.{ 0, 0 });

pub const Samples = struct {
    frame: [sample_count]u64 = @splat(0),
    tick: [sample_count]u64 = @splat(0),
    recorded: u32 = 0,
    previous_ns: ?u64 = null,

    pub fn record(self: *Samples, now_ns: u64, tick_ns: u64) void {
        const previous = self.previous_ns orelse now_ns;
        const slot = self.recorded % sample_count;
        self.tick[slot] = tick_ns;
        self.frame[slot] = now_ns -% previous;
        self.recorded +%= 1;
        self.previous_ns = now_ns;
    }

    pub fn skip(self: *Samples, now_ns: u64) void {
        self.previous_ns = now_ns;
    }

    pub fn averageHeight(self: *const Samples) u64 {
        var total: u64 = 0;
        for (self.frame) |value| total +%= value;
        return total / ns_per_pixel / sample_count;
    }
};

pub fn height(nanoseconds: u64) f32 {
    return @floatFromInt(nanoseconds / ns_per_pixel);
}

pub fn shadeOf(slot: u32, recorded: u32) u8 {
    const age = (slot -% recorded) % sample_count * 255 / sample_count;
    const squared = age * age / 255;
    return @intCast(squared * squared / 255);
}

pub fn barColor(frame_ns: u64, shade: u8) [4]u8 {
    return if (frame_ns > target_frame_ns) .{ shade, 0, 0, 255 } else .{ 0, shade, 0, 255 };
}

fn band(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    x: f32,
    width: f32,
    top: f32,
    bottom: f32,
    color: [4]u8,
    res: gui.Scaled,
) !void {
    const tl = gui.toNdc(x, top, res);
    const tr = gui.toNdc(x + width, top, res);
    const br = gui.toNdc(x + width, bottom, res);
    const bl = gui.toNdc(x, bottom, res);
    try mesh.quad(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, no_uv, color);
}

pub fn draw(
    gpa: std.mem.Allocator,
    shader: Shader,
    samples: *const Samples,
    pixel_width: f32,
    pixel_height: f32,
) !void {
    const res: gui.Scaled = .{
        .factor = 1,
        .ortho_width = pixel_width,
        .ortho_height = pixel_height,
        .width = pixel_width,
        .height = pixel_height,
    };

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);

    const unit = height(target_frame_ns);
    const span: f32 = @floatFromInt(sample_count);
    try band(&mesh, gpa, 0, span, pixel_height - unit, pixel_height, under_target, res);
    try band(&mesh, gpa, 0, span, pixel_height - unit * 2, pixel_height - unit, over_target, res);
    try band(&mesh, gpa, 0, span, pixel_height - height(samples.averageHeight() * ns_per_pixel), pixel_height, average, res);

    for (samples.frame, samples.tick, 0..) |frame_ns, tick_ns, slot| {
        const shade = shadeOf(@intCast(slot), samples.recorded);
        const x: f32 = @floatFromInt(slot);
        const top = pixel_height - height(frame_ns);
        try band(&mesh, gpa, x, 1, top, pixel_height, barColor(frame_ns, shade), res);
        try band(&mesh, gpa, x, 1, top, top + height(tick_ns), .{ shade, shade, shade, 255 }, res);
    }

    gl.Disable(gl.DEPTH_TEST);
    try gui.drawColorMesh(&mesh, shader);
    gl.Enable(gl.DEPTH_TEST);
}

test "the first recorded frame has no gap to measure against" {
    var samples: Samples = .{};
    samples.record(1_000_000, 250_000);
    try std.testing.expectEqual(@as(u64, 0), samples.frame[0]);
    try std.testing.expectEqual(@as(u64, 250_000), samples.tick[0]);
    try std.testing.expectEqual(@as(u32, 1), samples.recorded);
}

test "each frame measures the gap since the previous one" {
    var samples: Samples = .{};
    samples.record(1_000_000, 0);
    samples.record(1_020_000_000, 5_000_000);
    try std.testing.expectEqual(@as(u64, 1_019_000_000), samples.frame[1]);
    try std.testing.expectEqual(@as(u64, 5_000_000), samples.tick[1]);
}

test "skipped frames leave no spike behind when recording resumes" {
    var samples: Samples = .{};
    samples.record(1_000_000, 0);
    samples.skip(60_000_000_000);
    samples.record(60_016_000_000, 0);
    try std.testing.expectEqual(@as(u64, 16_000_000), samples.frame[1]);
}

test "the ring wraps after the last slot" {
    var samples: Samples = .{};
    samples.recorded = sample_count - 1;
    samples.record(0, 7);
    samples.record(0, 9);
    try std.testing.expectEqual(@as(u64, 7), samples.tick[sample_count - 1]);
    try std.testing.expectEqual(@as(u64, 9), samples.tick[0]);
    try std.testing.expectEqual(@as(u32, sample_count + 1), samples.recorded);
}

test "a frame is one pixel per fifth of a millisecond" {
    try std.testing.expectEqual(@as(f32, 83), height(target_frame_ns));
    try std.testing.expectEqual(@as(f32, 0), height(199_999));
    try std.testing.expectEqual(@as(f32, 5), height(1_000_000));
}

test "a frame slower than sixty a second turns the bar red" {
    try std.testing.expectEqual([4]u8{ 0, 200, 0, 255 }, barColor(target_frame_ns, 200));
    try std.testing.expectEqual([4]u8{ 200, 0, 0, 255 }, barColor(target_frame_ns + 1, 200));
}

test "the newest column is the brightest and the oldest the dimmest" {
    try std.testing.expectEqual(@as(u8, 0), shadeOf(10, 10));
    try std.testing.expect(shadeOf(9, 10) > 200);
    try std.testing.expect(shadeOf(300, 10) < shadeOf(9, 10));
    try std.testing.expect(shadeOf(100, 10) < shadeOf(300, 10));
}

test "the average band tracks the mean frame time" {
    var samples: Samples = .{};
    @memset(&samples.frame, 2_000_000);
    try std.testing.expectEqual(@as(u64, 10), samples.averageHeight());
}
