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
