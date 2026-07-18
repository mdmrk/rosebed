const std = @import("std");

const gl = @import("gl");

const gui = @import("gui.zig");
const MeshBuilder = @import("mesh_builder.zig");

const white: [4]u8 = .{ 255, 255, 255, 255 };
const grey: [4]u8 = .{ 224, 224, 224, 255 };
const megabyte = 1024 * 1024;

pub const Stats = struct {
    fps: u32,
    chunk_updates: u32,
    renderers_rendered: u32,
    renderers_loaded: u32,
    entities_rendered: u32,
    entities_total: u32,
    particles: u32,
    chunk_cache: u32,
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    used_memory: u64,
    allocated_memory: u64,
    max_memory: u64,
};

pub fn facing(yaw: f32) u32 {
    const quarter: f64 = @as(f64, yaw) * 4.0 / 360.0 + 0.5;
    return @intCast(@as(i64, @intFromFloat(@floor(quarter))) & 3);
}

pub fn draw(
    ui: gui.Ui,
    stats: Stats,
) !void {
    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    var buf: [128]u8 = undefined;

    const version = std.fmt.bufPrint(&buf, "Minecraft Beta 1.7.3 ({d} fps, {d} chunk updates)", .{ stats.fps, stats.chunk_updates }) catch "Minecraft Beta 1.7.3";
    try gui.appendTextColor(&text, ui.gpa, ui.font, version, 2, 2, white, ui.res);

    var renderers_buf: [128]u8 = undefined;
    const renderers = std.fmt.bufPrint(&renderers_buf, "C: {d}/{d}. F: 0, O: 0, E: 0", .{ stats.renderers_rendered, stats.renderers_loaded }) catch "C: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, renderers, 2, 12, white, ui.res);

    var entities_buf: [128]u8 = undefined;
    const entities = std.fmt.bufPrint(&entities_buf, "E: {d}/{d}. B: 0, I: 0", .{ stats.entities_rendered, stats.entities_total }) catch "E: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, entities, 2, 22, white, ui.res);

    var particles_buf: [128]u8 = undefined;
    const particles = std.fmt.bufPrint(&particles_buf, "P: {d}. T: All: {d}", .{ stats.particles, stats.entities_total }) catch "P: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, particles, 2, 32, white, ui.res);

    var cache_buf: [64]u8 = undefined;
    const cache = std.fmt.bufPrint(&cache_buf, "ChunkCache: {d}", .{stats.chunk_cache}) catch "ChunkCache: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, cache, 2, 42, white, ui.res);

    var used_buf: [128]u8 = undefined;
    const used = std.fmt.bufPrint(&used_buf, "Used memory: {d}% ({d}MB) of {d}MB", .{
        stats.used_memory * 100 / @max(stats.max_memory, 1),
        stats.used_memory / megabyte,
        stats.max_memory / megabyte,
    }) catch "Used memory: ";
    const used_width: f32 = @floatFromInt(ui.font.stringWidth(used));
    try gui.appendTextColor(&text, ui.gpa, ui.font, used, ui.res.width - used_width - 2, 2, grey, ui.res);

    var allocated_buf: [128]u8 = undefined;
    const allocated = std.fmt.bufPrint(&allocated_buf, "Allocated memory: {d}% ({d}MB)", .{
        stats.allocated_memory * 100 / @max(stats.max_memory, 1),
        stats.allocated_memory / megabyte,
    }) catch "Allocated memory: ";
    const allocated_width: f32 = @floatFromInt(ui.font.stringWidth(allocated));
    try gui.appendTextColor(&text, ui.gpa, ui.font, allocated, ui.res.width - allocated_width - 2, 12, grey, ui.res);

    var x_buf: [64]u8 = undefined;
    const x_line = std.fmt.bufPrint(&x_buf, "x: {d}", .{stats.x}) catch "x: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, x_line, 2, 64, grey, ui.res);

    var y_buf: [64]u8 = undefined;
    const y_line = std.fmt.bufPrint(&y_buf, "y: {d}", .{stats.y}) catch "y: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, y_line, 2, 72, grey, ui.res);

    var z_buf: [64]u8 = undefined;
    const z_line = std.fmt.bufPrint(&z_buf, "z: {d}", .{stats.z}) catch "z: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, z_line, 2, 80, grey, ui.res);

    var f_buf: [64]u8 = undefined;
    const f_line = std.fmt.bufPrint(&f_buf, "f: {d}", .{facing(stats.yaw)}) catch "f: ";
    try gui.appendTextColor(&text, ui.gpa, ui.font, f_line, 2, 88, grey, ui.res);

    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "facing quantises yaw into the original's four compass buckets" {
    try std.testing.expectEqual(@as(u32, 0), facing(0));
    try std.testing.expectEqual(@as(u32, 1), facing(90));
    try std.testing.expectEqual(@as(u32, 2), facing(180));
    try std.testing.expectEqual(@as(u32, 3), facing(270));
    try std.testing.expectEqual(@as(u32, 0), facing(360));
}

test "facing wraps negative yaw the way a floor-and-mask does" {
    try std.testing.expectEqual(@as(u32, 3), facing(-90));
    try std.testing.expectEqual(@as(u32, 2), facing(-180));
}
