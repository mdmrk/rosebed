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
const view_radius = 1;

comptime {
    _ = sdl3.main_callbacks;
}
pub const _start = void;
pub const WinMainCRTStartup = void;

const ChunkMeshMap = std.AutoHashMapUnmanaged(world.World.ChunkCoord, render.GpuMesh);

const AppState = struct {
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    gl_context: sdl3.video.gl.Context,
    gl_procs: gl.ProcTable,
    atlas: Atlas,
    shader: render.Shader,
    world_map: world.World,
    chunk_meshes: ChunkMeshMap,
    timer: Timer,
    tick_count: u64 = 0,
    player: game.Player = .{
        .position = math.Vec3.init(8, 90, 8),
        .prev_position = math.Vec3.init(8, 90, 8),
        .inventory = starterInventory(),
    },
    keys: struct {
        forward: bool = false,
        back: bool = false,
        left: bool = false,
        right: bool = false,
        jump: bool = false,
    } = .{},
    mouse_left_down: bool = false,
    digging: ?Digging = null,
};

const Digging = struct {
    x: i32,
    y: i32,
    z: i32,
    progress: f32,
};

fn starterInventory() game.Inventory {
    var inv: game.Inventory = .{};
    inv.slots[0] = .{ .id = world.block.stone, .count = 64 };
    inv.slots[1] = .{ .id = world.block.dirt, .count = 64 };
    inv.slots[2] = .{ .id = world.block.cobblestone, .count = 64 };
    inv.slots[3] = .{ .id = world.block.sand, .count = 64 };
    inv.slots[4] = .{ .id = world.block.gravel, .count = 64 };
    inv.slots[5] = .{ .id = world.block.log, .count = 64 };
    return inv;
}

fn generateWorld(world_map: *world.World) !void {
    const gpa = std.heap.page_allocator;
    const generator = try world.TerrainGenerator.init(gpa, world_seed);
    defer generator.deinit(gpa);

    var cx: i32 = -view_radius;
    while (cx <= view_radius) : (cx += 1) {
        var cz: i32 = -view_radius;
        while (cz <= view_radius) : (cz += 1) {
            try world_map.ensureDecorated(generator, cx, cz);
        }
    }
}

fn buildChunkMesh(world_map: *const world.World, chunk_x: i32, chunk_z: i32) !render.GpuMesh {
    const chunk = world_map.getChunk(chunk_x, chunk_z).?;
    var mesh = try render.chunk_mesher.build(std.heap.page_allocator, world_map, chunk);
    defer mesh.deinit(std.heap.page_allocator);
    return render.GpuMesh.upload(&mesh);
}

fn buildAllChunkMeshes(app_state: *AppState) !void {
    var cx: i32 = -view_radius;
    while (cx <= view_radius) : (cx += 1) {
        var cz: i32 = -view_radius;
        while (cz <= view_radius) : (cz += 1) {
            const mesh = try buildChunkMesh(&app_state.world_map, cx, cz);
            try app_state.chunk_meshes.put(std.heap.page_allocator, .{ .x = cx, .z = cz }, mesh);
        }
    }
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
        .world_map = world.World.init(std.heap.page_allocator),
        .chunk_meshes = .{},
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
    };
    if (!app_state.gl_procs.init(glGetProcAddress)) return error.GlInitFailed;
    gl.makeProcTableCurrent(&app_state.gl_procs);

    app_state.atlas = try Atlas.load(terrain_path);
    errdefer app_state.atlas.deinit();

    app_state.shader = try render.terrain_shader.init();
    errdefer app_state.shader.deinit();

    try generateWorld(&app_state.world_map);
    try buildAllChunkMeshes(&app_state);

    return .{ app_state, .run };
}

fn rebuildChunkMesh(app_state: *AppState, chunk_x: i32, chunk_z: i32) !void {
    if (app_state.world_map.getChunk(chunk_x, chunk_z) == null) return;
    const mesh = try buildChunkMesh(&app_state.world_map, chunk_x, chunk_z);
    const coord = world.World.ChunkCoord{ .x = chunk_x, .z = chunk_z };
    if (app_state.chunk_meshes.getPtr(coord)) |old| old.deinit();
    try app_state.chunk_meshes.put(std.heap.page_allocator, coord, mesh);
}

fn rebuildMeshesAround(app_state: *AppState, x: i32, z: i32) !void {
    const chunk_x = @divFloor(x, world.constants.chunk_width);
    const chunk_z = @divFloor(z, world.constants.chunk_width);
    const local_x = @mod(x, world.constants.chunk_width);
    const local_z = @mod(z, world.constants.chunk_width);

    try rebuildChunkMesh(app_state, chunk_x, chunk_z);
    if (local_x == 0) try rebuildChunkMesh(app_state, chunk_x - 1, chunk_z);
    if (local_x == world.constants.chunk_width - 1) try rebuildChunkMesh(app_state, chunk_x + 1, chunk_z);
    if (local_z == 0) try rebuildChunkMesh(app_state, chunk_x, chunk_z - 1);
    if (local_z == world.constants.chunk_width - 1) try rebuildChunkMesh(app_state, chunk_x, chunk_z + 1);
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

fn digStep(app_state: *AppState) !void {
    if (!app_state.mouse_left_down) {
        app_state.digging = null;
        return;
    }

    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse {
        app_state.digging = null;
        return;
    };

    if (app_state.digging == null or app_state.digging.?.x != hit.x or app_state.digging.?.y != hit.y or app_state.digging.?.z != hit.z) {
        app_state.digging = .{ .x = hit.x, .y = hit.y, .z = hit.z, .progress = 0 };
    }

    const block_id = app_state.world_map.getBlockId(hit.x, hit.y, hit.z);
    const ticks_required = world.block.digTicksRequired(block_id) orelse return;
    if (ticks_required <= 0.0) {
        breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try rebuildMeshesAround(app_state, hit.x, hit.z);
        return;
    }

    app_state.digging.?.progress += 1.0 / ticks_required;
    if (app_state.digging.?.progress >= 1.0) {
        breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try rebuildMeshesAround(app_state, hit.x, hit.z);
    }
}

fn breakBlock(app_state: *AppState, x: i32, y: i32, z: i32, block_id: u8) void {
    const meta = app_state.world_map.getBlockMetadata(x, y, z);
    app_state.world_map.setBlockId(x, y, z, world.block.air);
    app_state.digging = null;
    _ = app_state.player.inventory.addStack(.{ .id = block_id, .count = 1, .meta = meta });
}

fn consumeSelectedStack(app_state: *AppState) void {
    const slot = &app_state.player.inventory.slots[app_state.player.inventory.selected];
    if (slot.*) |*stack| {
        stack.count -= 1;
        if (stack.count == 0) slot.* = null;
    }
}

fn placeBlockAtTarget(app_state: *AppState) !void {
    const stack = app_state.player.inventory.selectedStack() orelse return;
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return;
    const offset = faceOffset(hit.face);
    const px = hit.x + offset[0];
    const py = hit.y + offset[1];
    const pz = hit.z + offset[2];
    if (py < 0 or py >= world.constants.chunk_height) return;
    if (world.block.isOpaque(app_state.world_map.getBlockId(px, py, pz))) return;
    app_state.world_map.setBlockId(px, py, pz, stack.id);
    app_state.world_map.setBlockMetadata(px, py, pz, stack.meta);
    consumeSelectedStack(app_state);
    try rebuildMeshesAround(app_state, px, pz);
}

fn tick(app_state: *AppState) !void {
    app_state.tick_count += 1;

    const forward: f32 = (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    app_state.player.tick(&app_state.world_map, strafe, forward, app_state.keys.jump);
    try digStep(app_state);
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
        try tick(app_state);
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
    var mesh_it = app_state.chunk_meshes.valueIterator();
    while (mesh_it.next()) |mesh| mesh.draw();

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

fn selectHotbarFromKey(app_state: *AppState, key: ?sdl3.keycode.Keycode) void {
    const index: u8 = switch (key orelse return) {
        .one => 0,
        .two => 1,
        .three => 2,
        .four => 3,
        .five => 4,
        .six => 5,
        .seven => 6,
        .eight => 7,
        .nine => 8,
        else => return,
    };
    app_state.player.inventory.selectHotbar(index);
}

pub fn event(
    app_state: *AppState,
    curr_event: sdl3.events.Event,
) !sdl3.AppResult {
    gl.makeProcTableCurrent(&app_state.gl_procs);
    switch (curr_event) {
        .quit, .terminating => return .success,
        .key_down => |k| {
            setKeyState(app_state, k.key, true);
            selectHotbarFromKey(app_state, k.key);
        },
        .key_up => |k| setKeyState(app_state, k.key, false),
        .mouse_motion => |m| app_state.player.turn(m.x_rel, m.y_rel),
        .mouse_wheel => |w| app_state.player.inventory.cycleHotbar(if (w.scroll_y > 0) 1 else if (w.scroll_y < 0) -1 else 0),
        .mouse_button_down => |m| switch (m.button) {
            .left => app_state.mouse_left_down = true,
            .right => try placeBlockAtTarget(app_state),
            else => {},
        },
        .mouse_button_up => |m| switch (m.button) {
            .left => app_state.mouse_left_down = false,
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
        var mesh_it = state.chunk_meshes.valueIterator();
        while (mesh_it.next()) |mesh| mesh.deinit();
        state.chunk_meshes.deinit(std.heap.page_allocator);
        state.world_map.deinit();
        state.shader.deinit();
        state.atlas.deinit();
        state.gl_context.deinit() catch {};
        state.window.deinit();
    }
    sdl3.quit(init_flags);
    sdl3.shutdown();
}
