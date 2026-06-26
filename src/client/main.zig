const std = @import("std");

const gl = @import("gl");
const sdl3 = @import("sdl3");

const Timer = @import("core").Timer;
const math = @import("math");
const world = @import("world");
const render = @import("render");
const game = @import("game");
const Atlas = render.Atlas;

const fps = 60;
const ticks_per_second = 20.0;
const screen_width = 640;
const screen_height = 480;
const init_flags = sdl3.InitFlags{ .video = true };
const terrain_path = "../decompilation/assets/terrain.png";
const fov_y_radians = 70.0 * std.math.pi / 180.0;
const near_plane = 0.05;
const far_plane = 1000.0;
const world_seed = 1;
const reach_distance = 4.5;
const place_block_id = world.block.stone;

comptime {
    _ = sdl3.main_callbacks;
}
pub const _start = void;
pub const WinMainCRTStartup = void;

const AppState = struct {
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    gl_context: sdl3.video.gl.Context,
    gl_procs: gl.ProcTable,
    atlas: Atlas,
    shader: render.Shader,
    chunk_mesh: render.GpuMesh,
    chunk: world.Chunk,
    timer: Timer,
    tick_count: u64 = 0,
    player: game.Player = .{ .position = math.Vec3.init(8, 90, 8), .prev_position = math.Vec3.init(8, 90, 8) },
    keys: struct {
        forward: bool = false,
        back: bool = false,
        left: bool = false,
        right: bool = false,
        jump: bool = false,
    } = .{},
};

fn buildTestChunk() !world.Chunk {
    const gpa = std.heap.page_allocator;
    const generator = try world.TerrainGenerator.init(gpa, world_seed);
    defer generator.deinit(gpa);
    return generator.generateChunk(0, 0);
}

fn glGetProcAddress(name: [*:0]const u8) ?gl.PROC {
    return @ptrCast(@alignCast(sdl3.video.gl.getProcAddress(std.mem.span(name))));
}

pub fn init(
    init_data: sdl3.Init,
) !struct { AppState, sdl3.AppResult } {
    _ = init_data;

    try sdl3.init(init_flags);
    errdefer sdl3.quit(init_flags);

    try sdl3.video.gl.setAttribute(.context_major_version, 3);
    try sdl3.video.gl.setAttribute(.context_minor_version, 3);
    try sdl3.video.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl3.video.gl.Profile.core));

    const window = try sdl3.video.Window.init("Rosebed", screen_width, screen_height, .{
        .open_gl = true,
        .resizable = true,
    });
    errdefer window.deinit();

    const gl_context = try sdl3.video.gl.Context.init(window);
    errdefer gl_context.deinit() catch {};

    try sdl3.mouse.setWindowRelativeMode(window, true);

    var app_state: AppState = .{
        .fps_capper = .{ .mode = .{ .limited = fps } },
        .window = window,
        .gl_context = gl_context,
        .gl_procs = undefined,
        .atlas = undefined,
        .shader = undefined,
        .chunk_mesh = undefined,
        .chunk = try buildTestChunk(),
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
    };
    if (!app_state.gl_procs.init(glGetProcAddress)) return error.GlInitFailed;
    gl.makeProcTableCurrent(&app_state.gl_procs);

    app_state.atlas = try Atlas.load(terrain_path);
    errdefer app_state.atlas.deinit();

    app_state.shader = try render.terrain_shader.init();
    errdefer app_state.shader.deinit();

    var mesh = try render.chunk_mesher.build(std.heap.page_allocator, &app_state.chunk);
    defer mesh.deinit(std.heap.page_allocator);
    app_state.chunk_mesh = render.GpuMesh.upload(&mesh);

    return .{ app_state, .run };
}

fn rebuildMesh(app_state: *AppState) !void {
    var mesh = try render.chunk_mesher.build(std.heap.page_allocator, &app_state.chunk);
    defer mesh.deinit(std.heap.page_allocator);
    app_state.chunk_mesh.deinit();
    app_state.chunk_mesh = render.GpuMesh.upload(&mesh);
}

fn faceOffset(face: u3) [3]i32 {
    return switch (face) {
        world.block.down => .{ 0, -1, 0 },
        world.block.up => .{ 0, 1, 0 },
        world.block.north => .{ 0, 0, -1 },
        world.block.south => .{ 0, 0, 1 },
        world.block.west => .{ -1, 0, 0 },
        world.block.east => .{ 1, 0, 0 },
        else => .{ 0, 0, 0 },
    };
}

fn breakTargetedBlock(app_state: *AppState) !void {
    const hit = game.raycast.cast(&app_state.chunk, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return;
    app_state.chunk.setBlockId(@intCast(hit.x), @intCast(hit.y), @intCast(hit.z), world.block.air);
    try rebuildMesh(app_state);
}

fn placeBlockAtTarget(app_state: *AppState) !void {
    const hit = game.raycast.cast(&app_state.chunk, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return;
    const offset = faceOffset(hit.face);
    const px = hit.x + offset[0];
    const py = hit.y + offset[1];
    const pz = hit.z + offset[2];
    if (px < 0 or px >= world.constants.chunk_width or
        py < 0 or py >= world.constants.chunk_height or
        pz < 0 or pz >= world.constants.chunk_width) return;
    if (world.block.isOpaque(app_state.chunk.getBlockId(@intCast(px), @intCast(py), @intCast(pz)))) return;
    app_state.chunk.setBlockId(@intCast(px), @intCast(py), @intCast(pz), place_block_id);
    try rebuildMesh(app_state);
}

fn tick(app_state: *AppState) void {
    app_state.tick_count += 1;

    const forward: f32 = (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    app_state.player.tick(&app_state.chunk, strafe, forward, app_state.keys.jump);
}

pub fn iterate(
    app_state: *AppState,
) !sdl3.AppResult {
    gl.makeProcTableCurrent(&app_state.gl_procs);
    gl.Viewport(0, 0, screen_width, screen_height);

    const dt = app_state.fps_capper.delay();
    _ = dt;

    app_state.timer.advance(sdl3.timer.getNanosecondsSinceInit());
    for (0..@intCast(app_state.timer.elapsed_ticks)) |_| {
        tick(app_state);
    }

    gl.Enable(gl.DEPTH_TEST);
    gl.ClearColor(0.502, 0.118, 1.0, 1.0);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const aspect: f32 = @as(f32, screen_width) / @as(f32, screen_height);
    const proj = math.Mat4.perspective(fov_y_radians, aspect, near_plane, far_plane);
    const view = app_state.player.viewMatrix(app_state.timer.render_partial_ticks);
    const view_proj = proj.mul(view);

    app_state.shader.use();
    app_state.shader.setMat4("u_view_proj", view_proj.m);
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.atlas.bind();
    app_state.shader.setInt("u_atlas", 0);
    app_state.chunk_mesh.draw();

    try sdl3.video.gl.swapWindow(app_state.window);

    return .run;
}

fn setKeyState(app_state: *AppState, key: ?sdl3.keycode.Keycode, down: bool) void {
    switch (key orelse return) {
        .w => app_state.keys.forward = down,
        .s => app_state.keys.back = down,
        .a => app_state.keys.left = down,
        .d => app_state.keys.right = down,
        .space => app_state.keys.jump = down,
        else => {},
    }
}

pub fn event(
    app_state: *AppState,
    curr_event: sdl3.events.Event,
) !sdl3.AppResult {
    gl.makeProcTableCurrent(&app_state.gl_procs);
    switch (curr_event) {
        .quit, .terminating => return .success,
        .key_down => |k| setKeyState(app_state, k.key, true),
        .key_up => |k| setKeyState(app_state, k.key, false),
        .mouse_motion => |m| app_state.player.turn(m.x_rel, m.y_rel),
        .mouse_button_down => |m| switch (m.button) {
            .left => try breakTargetedBlock(app_state),
            .right => try placeBlockAtTarget(app_state),
            else => {},
        },
        else => {},
    }
    return .run;
}

pub fn quit(
    app_state: ?*AppState,
    result: sdl3.AppResult,
) void {
    _ = result;

    if (app_state) |state| {
        gl.makeProcTableCurrent(&state.gl_procs);
        state.chunk_mesh.deinit();
        state.shader.deinit();
        state.atlas.deinit();
        state.gl_context.deinit() catch {};
        state.window.deinit();
    }
    sdl3.quit(init_flags);
    sdl3.shutdown();
}
