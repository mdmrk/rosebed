const std = @import("std");

const gl = @import("gl");
const math = @import("math");

const anaglyph = @import("anaglyph.zig");
const GpuMesh = @import("GpuMesh.zig");
const MeshBuilder = @import("MeshBuilder.zig");
const Shader = @import("Shader.zig");
const sky = @import("sky.zig");
const Textures = @import("Textures.zig");

const SkyRenderer = @This();

const degrees = std.math.pi / 180.0;
const opaque_white: [4]f32 = .{ 1, 1, 1, 1 };

dome: GpuMesh,
void_plane: GpuMesh,
stars: GpuMesh,
sun: GpuMesh,
moon: GpuMesh,

fn uploadOnce(gpa: std.mem.Allocator, build: *const fn (*MeshBuilder, std.mem.Allocator) anyerror!void) !GpuMesh {
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try build(&mesh, gpa);
    return GpuMesh.upload(&mesh);
}

fn buildSun(mesh: *MeshBuilder, gpa: std.mem.Allocator) anyerror!void {
    try sky.appendBody(mesh, gpa, sky.sun_radius, true);
}

fn buildMoon(mesh: *MeshBuilder, gpa: std.mem.Allocator) anyerror!void {
    try sky.appendBody(mesh, gpa, sky.moon_radius, false);
}

fn buildDome(mesh: *MeshBuilder, gpa: std.mem.Allocator) anyerror!void {
    try sky.appendDome(mesh, gpa);
}

fn buildVoid(mesh: *MeshBuilder, gpa: std.mem.Allocator) anyerror!void {
    try sky.appendVoidPlane(mesh, gpa);
}

fn buildStars(mesh: *MeshBuilder, gpa: std.mem.Allocator) anyerror!void {
    try sky.appendStars(mesh, gpa);
}

pub fn init(gpa: std.mem.Allocator) !SkyRenderer {
    return .{
        .dome = try uploadOnce(gpa, buildDome),
        .void_plane = try uploadOnce(gpa, buildVoid),
        .stars = try uploadOnce(gpa, buildStars),
        .sun = try uploadOnce(gpa, buildSun),
        .moon = try uploadOnce(gpa, buildMoon),
    };
}

pub fn deinit(self: SkyRenderer) void {
    self.dome.deinit();
    self.void_plane.deinit();
    self.stars.deinit();
    self.sun.deinit();
    self.moon.deinit();
}

pub fn visibleAt(render_distance: u5) bool {
    return render_distance < 2;
}

pub const Frame = struct {
    shader: Shader,
    textures: Textures,
    gpa: std.mem.Allocator,
    projection: math.Mat4,
    view_rotation: math.Mat4,
    celestial_angle: f32,
    sky_color: sky.Color,
    fog_color: sky.Color,
    far_plane_distance: f32,
    fog_density: ?f32 = null,
    pass: anaglyph.Pass = null,
};

pub fn voidPlaneColor(sky_color: sky.Color) [4]f32 {
    return .{
        sky_color[0] * 0.2 + 0.04,
        sky_color[1] * 0.2 + 0.04,
        sky_color[2] * 0.6 + 0.1,
        1.0,
    };
}

pub fn draw(self: SkyRenderer, frame: Frame) !void {
    const view_proj = frame.projection.mul(frame.view_rotation);
    const sky_color = anaglyph.color(frame.pass != null, frame.sky_color);

    gl.DepthMask(gl.FALSE);
    frame.shader.use();
    frame.shader.setMat4(.u_view_proj, view_proj.m);
    frame.shader.setVec3(.u_camera_pos, .{ 0, 0, 0 });
    frame.shader.setInt(.u_textured, 0);
    frame.shader.setInt(.u_alpha_test, 0);

    frame.shader.setInt(.u_fog_enabled, 1);
    frame.shader.setVec3(.u_fog_color, frame.fog_color);
    if (frame.fog_density) |density| {
        frame.shader.setInt(.u_fog_exponential, 1);
        frame.shader.setFloat(.u_fog_density, density);
    } else {
        frame.shader.setInt(.u_fog_exponential, 0);
        frame.shader.setFloat(.u_fog_start, 0.0);
        frame.shader.setFloat(.u_fog_end, frame.far_plane_distance * 0.8);
    }
    frame.shader.setVec4(.u_tint, .{ sky_color[0], sky_color[1], sky_color[2], 1.0 });
    self.dome.draw();
    frame.shader.setInt(.u_fog_enabled, 0);

    if (sky.sunriseColors(frame.celestial_angle)) |sunrise| {
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

        const glow_color = anaglyph.color(frame.pass != null, .{ sunrise.color[0], sunrise.color[1], sunrise.color[2] });
        var glow: MeshBuilder = .{};
        defer glow.deinit(frame.gpa);
        try sky.appendSunriseGlow(&glow, frame.gpa, .{
            .color = .{ glow_color[0], glow_color[1], glow_color[2], sunrise.color[3] },
            .angle = sunrise.angle,
        });

        const flip: f32 = if (frame.celestial_angle > 0.5) 180.0 else 0.0;
        const oriented = view_proj
            .mul(math.Mat4.rotationX(90.0 * degrees))
            .mul(math.Mat4.rotationZ(flip * degrees));
        frame.shader.setMat4(.u_view_proj, oriented.m);
        frame.shader.setVec4(.u_tint, opaque_white);

        var gpu = GpuMesh.upload(&glow);
        defer gpu.deinit();
        gpu.draw();
    }

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE);

    const spun = view_proj.mul(math.Mat4.rotationX(frame.celestial_angle * 360.0 * degrees));
    frame.shader.setMat4(.u_view_proj, spun.m);
    frame.shader.setVec4(.u_tint, opaque_white);
    frame.shader.setInt(.u_textured, 1);
    gl.ActiveTexture(gl.TEXTURE0);
    frame.shader.setInt(.u_atlas, 0);
    frame.textures.sun.bind();
    self.sun.draw();
    frame.textures.moon.bind();
    self.moon.draw();
    frame.shader.setInt(.u_textured, 0);

    const brightness = sky.starBrightness(frame.celestial_angle);
    if (brightness > 0.0) {
        frame.shader.setVec4(.u_tint, .{ brightness, brightness, brightness, brightness });
        self.stars.draw();
    }

    gl.Disable(gl.BLEND);

    frame.shader.setMat4(.u_view_proj, view_proj.m);
    frame.shader.setInt(.u_fog_enabled, 1);
    frame.shader.setVec4(.u_tint, voidPlaneColor(sky_color));
    self.void_plane.draw();

    frame.shader.setInt(.u_fog_enabled, 0);
    frame.shader.setInt(.u_alpha_test, 1);
    frame.shader.setInt(.u_textured, 1);
    frame.shader.setVec4(.u_tint, opaque_white);
    frame.textures.terrain.bind();
    gl.DepthMask(gl.TRUE);
}

pub const Clouds = struct {
    shader: Shader,
    textures: Textures,
    gpa: std.mem.Allocator,
    view_proj: math.Mat4,
    eye: math.Vec3,
    scroll: f64,
    color: sky.Color,
};

pub fn drawClouds(frame: Clouds, fancy: bool, pass: anaglyph.Pass) !void {
    const color = anaglyph.color(pass != null, frame.color);
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(frame.gpa);
    if (fancy) {
        try sky.appendFancyClouds(&mesh, frame.gpa, frame.eye, frame.scroll, color);
    } else {
        try sky.appendClouds(&mesh, frame.gpa, frame.eye, frame.scroll, color);
    }

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    frame.shader.setMat4(.u_view_proj, frame.view_proj.m);
    frame.shader.setVec3(.u_camera_pos, .{ 0, 0, 0 });
    frame.shader.setInt(.u_alpha_test, 1);
    frame.shader.setInt(.u_textured, 1);
    frame.shader.setVec4(.u_tint, opaque_white);
    gl.ActiveTexture(gl.TEXTURE0);
    frame.shader.setInt(.u_atlas, 0);
    frame.textures.clouds.bind();

    var gpu = GpuMesh.upload(&mesh);
    defer gpu.deinit();

    if (fancy) {
        gl.ColorMask(gl.FALSE, gl.FALSE, gl.FALSE, gl.FALSE);
        gpu.draw();
        anaglyph.restoreMask(pass);
        gpu.draw();
    } else {
        gpu.draw();
    }

    frame.textures.terrain.bind();
    gl.Disable(gl.BLEND);
}

test "the sky is only drawn at the two longest render distances" {
    try std.testing.expect(visibleAt(0));
    try std.testing.expect(visibleAt(1));
    try std.testing.expect(!visibleAt(2));
    try std.testing.expect(!visibleAt(3));
}

test "the void plane is darker and bluer than the sky above it" {
    const above: sky.Color = .{ 0.5, 0.6, 0.9 };
    const below = voidPlaneColor(above);
    try std.testing.expect(below[0] < above[0]);
    try std.testing.expect(below[1] < above[1]);
    try std.testing.expect(below[2] < above[2]);
    try std.testing.expect(below[2] > below[0]);
}
