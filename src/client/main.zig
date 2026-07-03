const builtin = @import("builtin");
const std = @import("std");

const assets = @import("assets");
const game = @import("game");
const gl = @import("gl");
const math = @import("math");
const render = @import("render");
const Atlas = render.Atlas;
const sdl3 = @import("sdl3");
const Timer = @import("core").Timer;
const world = @import("world");

const fps = 60;
const ticks_per_second = 20.0;
const screen_width = 1280;
const screen_height = 720;
const init_flags = sdl3.InitFlags{ .video = true };
const terrain_png = assets.terrain_png;
const pig_png = assets.mob.pig_png;
const char_png = assets.mob.char_png;
const gui_png = assets.gui.gui_png;
const icons_png = assets.gui.icons_png;
const items_png = assets.gui.items_png;
const font_png = assets.font.default_png;
const inventory_png = assets.gui.inventory_png;
const dirt_png = assets.gui.background_png;
const logo_png = assets.title.mclogo_png;
const fov_y_radians = 70.0 * std.math.pi / 180.0;
const near_plane = 0.05;
const far_plane = 1000.0;
const world_seed = 1;
const reach_distance = 4.5;
const view_radius = 1;
const pig_texture_width = 64;
const pig_texture_height = 32;
const char_texture_width = 64;
const char_texture_height = 32;

const splashes: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const []const u8 = &.{};
    var it = std.mem.tokenizeAny(u8, assets.title.splashes_txt, "\r\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0) list = list ++ [_][]const u8{trimmed};
    }
    break :blk list;
};

fn pickSplash(rand: *world.JavaRandom) []const u8 {
    const chosen = splashes[@intCast(rand.nextIntBound(@intCast(splashes.len)))];
    const now = sdl3.time.Time.getCurrent() catch return chosen;
    const date = sdl3.time.DateTime.fromTime(now, true) catch return chosen;
    const month = @intFromEnum(date.month);
    if (month == 11 and date.day == 9) return "Happy birthday, ez!";
    if (month == 6 and date.day == 1) return "Happy birthday, Notch!";
    if (month == 12 and date.day == 24) return "Merry X-mas!";
    if (month == 1 and date.day == 1) return "Happy new year!";
    return chosen;
}

const pig_parts = [6]render.mob_model.Part{
    .{ .box = .{ .origin = .{ -4, -4, -8 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, 12, -6 } },
    .{ .box = .{ .origin = .{ -5, -10, -7 }, .size = .{ 10, 16, 8 }, .tex_u = 28, .tex_v = 8 }, .pivot = .{ 0, 11, 2 }, .rotate_x = std.math.pi * 0.5 },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, 18, 7 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, 18, 7 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -3, 18, -5 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 6, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 3, 18, -5 } },
};

const biped_head_index = 5;
const biped_parts = [6]render.mob_model.Part{
    .{ .box = .{ .origin = .{ -4, 0, -2 }, .size = .{ 8, 12, 4 }, .tex_u = 16, .tex_v = 16 }, .pivot = .{ 0, -24, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ -2, -12, 0 } },
    .{ .box = .{ .origin = .{ -2, 0, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 0, .tex_v = 16 }, .pivot = .{ 2, -12, 0 } },
    .{ .box = .{ .origin = .{ -3, -2, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ -5, -22, 0 } },
    .{ .box = .{ .origin = .{ -1, -2, -2 }, .size = .{ 4, 12, 4 }, .tex_u = 40, .tex_v = 16 }, .pivot = .{ 5, -22, 0 } },
    .{ .box = .{ .origin = .{ -4, -8, -4 }, .size = .{ 8, 8, 8 }, .tex_u = 0, .tex_v = 0 }, .pivot = .{ 0, -24, 0 } },
};

comptime {
    _ = sdl3.main_callbacks;
}
pub const _start = void;
pub const WinMainCRTStartup = void;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var frame_arena: std.heap.ArenaAllocator = undefined;

const ChunkMeshMap = std.AutoHashMapUnmanaged(world.World.ChunkCoord, render.GpuMesh);

const AppState = struct {
    gpa: std.mem.Allocator,
    frame: std.mem.Allocator,
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    gl_context: sdl3.video.gl.Context,
    gl_procs: gl.ProcTable,
    atlas: Atlas,
    pig_texture: Atlas,
    char_texture: Atlas,
    gui_texture: Atlas,
    icons_texture: Atlas,
    items_texture: Atlas,
    inventory_texture: Atlas,
    dirt_texture: Atlas,
    logo_texture: Atlas,
    font: render.Font,
    shader: render.Shader,
    generator: world.TerrainGenerator,
    world_map: world.World,
    chunk_meshes: ChunkMeshMap,
    item_entities: std.ArrayListUnmanaged(game.ItemEntity) = .empty,
    falling_blocks: std.ArrayListUnmanaged(game.FallingBlock) = .empty,
    pigs: std.ArrayListUnmanaged(game.Pig) = .empty,
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
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    screen: Screen = .title,
    splash: []const u8 = splashes[0],
    inventory_open: bool = false,
    paused: bool = false,
    options_open: bool = false,
    video_open: bool = false,
    show_debug: bool = false,
    frames_this_second: u32 = 0,
    chunk_updates_this_second: u32 = 0,
    debug_fps: u32 = 0,
    debug_chunk_updates: u32 = 0,
    debug_latched_ms: u64 = 0,
    options_parent: OptionsParent = .title,
    dragging_slider: ?render.options_screen.Slider = null,
    settings: game.Settings = .{},
    held_stack: ?game.Inventory.ItemStack = null,
    crafting_grid: [game.crafting.grid_size * game.crafting.grid_size]?game.Inventory.ItemStack = @splat(null),
};

const Screen = enum { title, playing };
const OptionsParent = enum { title, pause };

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

fn readProcFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, buf.ptr, buf.len);
    if (@as(isize, @bitCast(n)) < 0) return null;
    return buf[0..n];
}

const ProcessMemory = struct { used: u64, allocated: u64, max: u64 };

fn processMemory() ProcessMemory {
    const page_size: u64 = 4096;
    const empty: ProcessMemory = .{ .used = 0, .allocated = 0, .max = 1 };

    var statm_buf: [256]u8 = undefined;
    const statm = readProcFile("/proc/self/statm", &statm_buf) orelse return empty;
    var fields = std.mem.tokenizeAny(u8, statm, " \n");
    const size = std.fmt.parseInt(u64, fields.next() orelse return empty, 10) catch return empty;
    const resident = std.fmt.parseInt(u64, fields.next() orelse return empty, 10) catch return empty;

    var meminfo_buf: [256]u8 = undefined;
    var max: u64 = 1;
    if (readProcFile("/proc/meminfo", &meminfo_buf)) |meminfo| {
        var lines = std.mem.tokenizeScalar(u8, meminfo, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            _ = parts.next();
            max = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
            max *= 1024;
            break;
        }
    }

    return .{ .used = resident * page_size, .allocated = size * page_size, .max = @max(max, 1) };
}

fn debugStats(app_state: *const AppState) render.debug_overlay.Stats {
    const loaded: u32 = @intCast(app_state.chunk_meshes.count());
    const entities: u32 = @intCast(app_state.pigs.items.len + app_state.item_entities.items.len + app_state.falling_blocks.items.len);
    const memory = processMemory();
    return .{
        .fps = app_state.debug_fps,
        .chunk_updates = app_state.debug_chunk_updates,
        .renderers_rendered = loaded,
        .renderers_loaded = loaded,
        .entities_rendered = entities,
        .entities_total = entities,
        .particles = 0,
        .chunk_cache = @intCast(app_state.world_map.chunks.count()),
        .x = app_state.player.position.x,
        .y = app_state.player.position.y,
        .z = app_state.player.position.z,
        .yaw = app_state.player.yaw,
        .used_memory = memory.used,
        .allocated_memory = memory.allocated,
        .max_memory = memory.max,
    };
}

fn buildChunkMesh(gpa: std.mem.Allocator, world_map: *const world.World, chunk_x: i32, chunk_z: i32) !render.GpuMesh {
    const chunk = world_map.getChunk(chunk_x, chunk_z).?;
    var mesh = try render.chunk_mesher.build(gpa, world_map, chunk);
    defer mesh.deinit(gpa);
    return render.GpuMesh.upload(&mesh);
}

fn playerChunkCoord(app_state: *const AppState) world.World.ChunkCoord {
    const x: i32 = @intFromFloat(@floor(app_state.player.position.x));
    const z: i32 = @intFromFloat(@floor(app_state.player.position.z));
    return .{
        .x = @divFloor(x, world.constants.chunk_width),
        .z = @divFloor(z, world.constants.chunk_width),
    };
}

fn ensureChunksAroundPlayer(app_state: *AppState) !void {
    const center = playerChunkCoord(app_state);

    var cx = center.x - view_radius;
    while (cx <= center.x + view_radius) : (cx += 1) {
        var cz = center.z - view_radius;
        while (cz <= center.z + view_radius) : (cz += 1) {
            const coord = world.World.ChunkCoord{ .x = cx, .z = cz };
            if (app_state.chunk_meshes.contains(coord)) continue;
            try app_state.world_map.ensureDecorated(app_state.generator, cx, cz);
            const mesh = try buildChunkMesh(app_state.gpa, &app_state.world_map, cx, cz);
            try app_state.chunk_meshes.put(app_state.gpa, coord, mesh);
            app_state.chunk_updates_this_second += 1;
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

    try sdl3.mouse.setWindowRelativeMode(window, false);

    const gpa = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    frame_arena = .init(gpa);

    var app_state: AppState = .{
        .gpa = gpa,
        .frame = frame_arena.allocator(),
        .fps_capper = .{ .mode = .{ .limited = fps } },
        .window = window,
        .gl_context = gl_context,
        .gl_procs = undefined,
        .atlas = undefined,
        .pig_texture = undefined,
        .char_texture = undefined,
        .gui_texture = undefined,
        .icons_texture = undefined,
        .items_texture = undefined,
        .inventory_texture = undefined,
        .dirt_texture = undefined,
        .logo_texture = undefined,
        .font = undefined,
        .shader = undefined,
        .generator = undefined,
        .world_map = world.World.init(gpa),
        .chunk_meshes = .{},
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
    };
    if (!app_state.gl_procs.init(glGetProcAddress)) return error.GlInitFailed;
    gl.makeProcTableCurrent(&app_state.gl_procs);

    app_state.world_map.rand.setSeed(@bitCast(sdl3.timer.getNanosecondsSinceInit()));
    app_state.splash = pickSplash(&app_state.world_map.rand);

    app_state.atlas = try Atlas.load(terrain_png);
    errdefer app_state.atlas.deinit();

    app_state.pig_texture = try Atlas.load(pig_png);
    errdefer app_state.pig_texture.deinit();

    app_state.char_texture = try Atlas.load(char_png);
    errdefer app_state.char_texture.deinit();

    app_state.gui_texture = try Atlas.load(gui_png);
    errdefer app_state.gui_texture.deinit();

    app_state.icons_texture = try Atlas.load(icons_png);
    errdefer app_state.icons_texture.deinit();

    app_state.items_texture = try Atlas.load(items_png);
    errdefer app_state.items_texture.deinit();

    app_state.inventory_texture = try Atlas.load(inventory_png);
    errdefer app_state.inventory_texture.deinit();

    app_state.dirt_texture = try Atlas.loadRepeat(dirt_png);
    errdefer app_state.dirt_texture.deinit();

    app_state.logo_texture = try Atlas.load(logo_png);
    errdefer app_state.logo_texture.deinit();

    app_state.font = try render.Font.load(font_png);
    errdefer app_state.font.deinit();

    try app_state.pigs.append(app_state.gpa, game.Pig.spawn(math.Vec3.init(10, 90, 8)));

    app_state.shader = try render.terrain_shader.init();
    errdefer app_state.shader.deinit();

    app_state.generator = try world.TerrainGenerator.init(gpa, world_seed);
    errdefer app_state.generator.deinit(gpa);

    return .{ app_state, .run };
}

fn rebuildChunkMesh(app_state: *AppState, chunk_x: i32, chunk_z: i32) !void {
    if (app_state.world_map.getChunk(chunk_x, chunk_z) == null) return;
    const mesh = try buildChunkMesh(app_state.gpa, &app_state.world_map, chunk_x, chunk_z);
    const coord = world.World.ChunkCoord{ .x = chunk_x, .z = chunk_z };
    if (app_state.chunk_meshes.getPtr(coord)) |old| old.deinit();
    try app_state.chunk_meshes.put(app_state.gpa, coord, mesh);
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
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try rebuildMeshesAround(app_state, hit.x, hit.z);
        return;
    }

    app_state.digging.?.progress += 1.0 / ticks_required;
    if (app_state.digging.?.progress >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try rebuildMeshesAround(app_state, hit.x, hit.z);
    }
}

fn spawnDroppedItem(app_state: *AppState, x: i32, y: i32, z: i32, stack: game.Inventory.ItemStack) !void {
    const rand = &app_state.world_map.rand;
    const jitter_x = @as(f64, rand.nextFloat()) * 0.7 + 0.15;
    const jitter_y = @as(f64, rand.nextFloat()) * 0.7 + 0.15;
    const jitter_z = @as(f64, rand.nextFloat()) * 0.7 + 0.15;
    const position = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + jitter_x,
        @as(f64, @floatFromInt(y)) + jitter_y,
        @as(f64, @floatFromInt(z)) + jitter_z,
    );
    const item = game.ItemEntity.spawn(position, stack, rand);
    try app_state.item_entities.append(app_state.gpa, item);
}

fn checkFall(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    const id = app_state.world_map.getBlockId(x, y, z);
    if (!world.block.isFalling(id)) return;
    if (!world.block.canFallInto(app_state.world_map.getBlockId(x, y - 1, z))) return;

    app_state.world_map.setBlockId(x, y, z, world.block.air);
    try rebuildMeshesAround(app_state, x, z);

    const position = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + 0.5,
        @floatFromInt(y),
        @as(f64, @floatFromInt(z)) + 0.5,
    );
    try app_state.falling_blocks.append(app_state.gpa, game.FallingBlock.spawn(position, id));
}

fn breakBlock(app_state: *AppState, x: i32, y: i32, z: i32, block_id: u8) !void {
    const meta = app_state.world_map.getBlockMetadata(x, y, z);
    const dropped = world.block.drop(block_id, meta, &app_state.world_map.rand);
    app_state.world_map.setBlockId(x, y, z, world.block.air);
    app_state.digging = null;
    if (dropped) |d| try spawnDroppedItem(app_state, x, y, z, .{ .id = d.id, .count = d.count, .meta = d.meta });
    try checkFall(app_state, x, y + 1, z);
}

fn tickFallingBlocks(app_state: *AppState) !void {
    var i: usize = 0;
    while (i < app_state.falling_blocks.items.len) {
        const block = &app_state.falling_blocks.items[i];
        const outcome = block.tick(&app_state.world_map);

        if (outcome == .falling) {
            i += 1;
            continue;
        }

        const x: i32 = @intFromFloat(@floor(block.position.x));
        const y: i32 = @intFromFloat(@floor(block.position.y));
        const z: i32 = @intFromFloat(@floor(block.position.z));

        const landing_empty = !world.block.isOpaque(app_state.world_map.getBlockId(x, y, z));
        const support_solid = !world.block.canFallInto(app_state.world_map.getBlockId(x, y - 1, z));
        if (outcome == .landed and landing_empty and support_solid) {
            app_state.world_map.setBlockId(x, y, z, block.block_id);
            try rebuildMeshesAround(app_state, x, z);
        } else {
            try spawnDroppedItem(app_state, x, y, z, .{ .id = block.block_id, .count = 1 });
        }

        _ = app_state.falling_blocks.swapRemove(i);
    }
}

fn tickItemEntities(app_state: *AppState) void {
    var i: usize = 0;
    while (i < app_state.item_entities.items.len) {
        const item = &app_state.item_entities.items[i];
        item.tick(&app_state.world_map);

        var picked_up = false;
        if (item.canPickUp() and item.boundingBox().intersects(app_state.player.boundingBox())) {
            const leftover = app_state.player.inventory.addStack(item.stack);
            if (leftover == 0) {
                picked_up = true;
            } else {
                item.stack.count = leftover;
            }
        }

        if (picked_up or item.isExpired()) {
            _ = app_state.item_entities.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

const ClickType = enum { left, right };

fn dropHeldStack(app_state: *AppState, click_type: ClickType) !void {
    const held = app_state.held_stack orelse return;
    const drop_count = if (click_type == .left) held.count else 1;
    try spawnDroppedItem(
        app_state,
        @intFromFloat(@floor(app_state.player.position.x)),
        @intFromFloat(@floor(app_state.player.position.y)),
        @intFromFloat(@floor(app_state.player.position.z)),
        .{ .id = held.id, .count = drop_count, .meta = held.meta },
    );
    const remaining = held.count - drop_count;
    app_state.held_stack = if (remaining == 0) null else .{ .id = held.id, .count = remaining, .meta = held.meta };
}

fn slotClick(app_state: *AppState, slot: *?game.Inventory.ItemStack, click_type: ClickType) void {
    if (slot.*) |*existing| {
        if (app_state.held_stack) |*held| {
            if (existing.id == held.id and existing.meta == held.meta) {
                const amount = @min(if (click_type == .left) held.count else 1, game.Inventory.max_stack_size - existing.count);
                existing.count += amount;
                held.count -= amount;
                if (held.count == 0) app_state.held_stack = null;
            } else {
                const swapped = existing.*;
                slot.* = held.*;
                app_state.held_stack = swapped;
            }
        } else {
            const amount = if (click_type == .left) existing.count else (existing.count + 1) / 2;
            app_state.held_stack = .{ .id = existing.id, .count = amount, .meta = existing.meta };
            existing.count -= amount;
            if (existing.count == 0) slot.* = null;
        }
    } else if (app_state.held_stack) |*held| {
        const amount = if (click_type == .left) held.count else 1;
        slot.* = .{ .id = held.id, .count = amount, .meta = held.meta };
        held.count -= amount;
        if (held.count == 0) app_state.held_stack = null;
    }
}

fn resultSlotClick(app_state: *AppState) void {
    const result = game.crafting.findMatch(app_state.crafting_grid) orelse return;
    if (app_state.held_stack) |*held| {
        if (held.id != result.id or held.meta != result.meta) return;
        if (@as(u16, held.count) + result.count > game.Inventory.max_stack_size) return;
        held.count += result.count;
    } else {
        app_state.held_stack = result;
    }
    game.crafting.consume(&app_state.crafting_grid);
}

fn inventoryClickAt(app_state: *AppState, click_type: ClickType) !void {
    const gui = guiSize(app_state);
    const slot = render.inventory_screen.slotAt(app_state.mouse_x, app_state.mouse_y, gui) orelse {
        try dropHeldStack(app_state, click_type);
        return;
    };
    switch (slot.kind) {
        .inventory => slotClick(app_state, &app_state.player.inventory.slots[slot.index], click_type),
        .craft_input => slotClick(app_state, &app_state.crafting_grid[slot.index], click_type),
        .craft_result => resultSlotClick(app_state),
    }
}

fn dropCraftingGrid(app_state: *AppState) !void {
    for (&app_state.crafting_grid) |*slot| {
        const stack = slot.* orelse continue;
        try spawnDroppedItem(
            app_state,
            @intFromFloat(@floor(app_state.player.position.x)),
            @intFromFloat(@floor(app_state.player.position.y)),
            @intFromFloat(@floor(app_state.player.position.z)),
            stack,
        );
        slot.* = null;
    }
}

fn worldFocused(app_state: *const AppState) bool {
    return app_state.screen == .playing and !app_state.inventory_open and !app_state.paused and !app_state.options_open;
}

fn updateMouseMode(app_state: *AppState) !void {
    try sdl3.mouse.setWindowRelativeMode(app_state.window, worldFocused(app_state));
}

fn toggleInventory(app_state: *AppState) !void {
    app_state.inventory_open = !app_state.inventory_open;
    try updateMouseMode(app_state);
    if (!app_state.inventory_open) {
        try dropHeldStack(app_state, .left);
        try dropCraftingGrid(app_state);
    }
}

fn togglePause(app_state: *AppState) !void {
    app_state.paused = !app_state.paused;
    try updateMouseMode(app_state);
}

fn enterWorld(app_state: *AppState) !void {
    app_state.screen = .playing;
    try updateMouseMode(app_state);
}

fn quitToTitle(app_state: *AppState) !void {
    app_state.screen = .title;
    app_state.paused = false;
    app_state.splash = pickSplash(&app_state.world_map.rand);
    try updateMouseMode(app_state);
}

fn openOptions(app_state: *AppState, parent: OptionsParent) !void {
    app_state.options_open = true;
    app_state.options_parent = parent;
    try updateMouseMode(app_state);
}

fn closeOptions(app_state: *AppState) !void {
    app_state.options_open = false;
    app_state.video_open = false;
    app_state.dragging_slider = null;
    try updateMouseMode(app_state);
}

fn setSlider(app_state: *AppState, which: render.options_screen.Slider, value: f32) void {
    switch (which) {
        .music => app_state.settings.music_volume = value,
        .sound => app_state.settings.sound_volume = value,
        .sensitivity => app_state.settings.sensitivity = value,
    }
}

fn pauseMenuClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const action = render.menu.actionAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    switch (action) {
        .resume_game => try togglePause(app_state),
        .options => try openOptions(app_state, .pause),
        .quit_to_title => try quitToTitle(app_state),
    }
}

fn optionsClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.options_screen.hitAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    switch (hit) {
        .slider => |s| {
            app_state.dragging_slider = s;
            setSlider(app_state, s, render.options_screen.sliderValueAt(s, app_state.mouse_x, gui));
        },
        .toggle_invert => app_state.settings.invert_mouse = !app_state.settings.invert_mouse,
        .cycle_difficulty => app_state.settings.difficulty = app_state.settings.difficulty.next(),
        .video => app_state.video_open = true,
        .done => try closeOptions(app_state),
    }
}

fn videoClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.video_settings_screen.hitAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    if (hit == .done) {
        app_state.video_open = false;
    } else {
        render.video_settings_screen.cycle(&app_state.settings, hit);
    }
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
    if (stack.id > 255) return;
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return;
    const offset = faceOffset(hit.face);
    const px = hit.x + offset[0];
    const py = hit.y + offset[1];
    const pz = hit.z + offset[2];
    if (py < 0 or py >= world.constants.chunk_height) return;
    if (world.block.isOpaque(app_state.world_map.getBlockId(px, py, pz))) return;
    app_state.world_map.setBlockId(px, py, pz, @intCast(stack.id));
    app_state.world_map.setBlockMetadata(px, py, pz, stack.meta);
    consumeSelectedStack(app_state);
    try rebuildMeshesAround(app_state, px, pz);
    try checkFall(app_state, px, py, pz);
}

fn tick(app_state: *AppState) !void {
    app_state.tick_count += 1;

    const moving_allowed = !app_state.inventory_open;
    const forward: f32 = if (!moving_allowed) 0 else (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = if (!moving_allowed) 0 else (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    app_state.player.tick(&app_state.world_map, strafe, forward, moving_allowed and app_state.keys.jump);
    try digStep(app_state);
    tickItemEntities(app_state);
    try tickFallingBlocks(app_state);
    for (app_state.pigs.items) |*pig| pig.tick(&app_state.world_map, &app_state.world_map.rand);
    try ensureChunksAroundPlayer(app_state);
}

fn buildItemEntityMesh(gpa: std.mem.Allocator, app_state: *const AppState, partial_ticks: f32) !render.MeshBuilder {
    var mesh: render.MeshBuilder = .{};
    errdefer mesh.deinit(gpa);

    for (app_state.item_entities.items) |item| {
        if (item.stack.id > 255) continue;

        const pos = item.renderPosition(partial_ticks);
        const tile = world.block.faceTextures(@intCast(item.stack.id))[world.block.up];
        const uv = render.Atlas.tileUv(tile);
        const uvs = [4][2]f32{
            .{ uv.u0, uv.v1 }, .{ uv.u1, uv.v1 }, .{ uv.u1, uv.v0 }, .{ uv.u0, uv.v0 },
        };

        const half: f32 = @floatCast(game.ItemEntity.width / 2.0);
        const cx: f32 = @floatCast(pos.x);
        const cz: f32 = @floatCast(pos.z);
        const y0: f32 = @floatCast(pos.y);
        const y1: f32 = @floatCast(pos.y + game.ItemEntity.height);
        const minx = cx - half;
        const maxx = cx + half;
        const minz = cz - half;
        const maxz = cz + half;

        try mesh.quad(gpa, .{
            .{ minx, y0, minz }, .{ maxx, y0, maxz }, .{ maxx, y1, maxz }, .{ minx, y1, minz },
        }, uvs, .{ 255, 255, 255, 255 });
        try mesh.quad(gpa, .{
            .{ maxx, y0, minz }, .{ minx, y0, maxz }, .{ minx, y1, maxz }, .{ maxx, y1, minz },
        }, uvs, .{ 255, 255, 255, 255 });
    }

    return mesh;
}

fn buildFallingBlockMesh(gpa: std.mem.Allocator, app_state: *const AppState, partial_ticks: f32) !render.MeshBuilder {
    var mesh: render.MeshBuilder = .{};
    errdefer mesh.deinit(gpa);

    for (app_state.falling_blocks.items) |block| {
        const pos = block.renderPosition(partial_ticks);
        const size: f32 = @floatCast(game.FallingBlock.size);
        const half = size / 2.0;
        const cx: f32 = @floatCast(pos.x);
        const cy: f32 = @floatCast(pos.y);
        const cz: f32 = @floatCast(pos.z);
        try render.chunk_mesher.buildCube(
            &mesh,
            gpa,
            .{ cx - half, cy, cz - half },
            .{ cx + half, cy + size, cz + half },
            world.block.faceTextures(block.block_id),
        );
    }

    return mesh;
}

fn buildPigMesh(gpa: std.mem.Allocator, app_state: *const AppState, partial_ticks: f32) !render.MeshBuilder {
    var mesh: render.MeshBuilder = .{};
    errdefer mesh.deinit(gpa);

    for (app_state.pigs.items) |pig| {
        const pos = pig.renderPosition(partial_ticks);
        const entity_pos = [3]f32{ @floatCast(pos.x), @floatCast(pos.y), @floatCast(pos.z) };
        const yaw_rad = pig.yaw * std.math.pi / 180.0;
        const swing = @cos(pig.walk_distance * 0.6662) * 1.4;

        for (pig_parts, 0..) |part, i| {
            var p = part;
            if (i >= 2) p.rotate_x = if (i == 2 or i == 5) swing else -swing;
            try render.mob_model.appendPart(&mesh, gpa, p, pig_texture_width, pig_texture_height, entity_pos, yaw_rad);
        }
    }

    return mesh;
}

fn drawableSize(app_state: *const AppState) struct { w: gl.sizei, h: gl.sizei } {
    const s = app_state.window.getSizeInPixels() catch return .{ .w = screen_width, .h = screen_height };
    return .{ .w = @intCast(@max(s[0], 1)), .h = @intCast(@max(s[1], 1)) };
}

fn guiSize(app_state: *const AppState) render.hud.Scaled {
    const px = drawableSize(app_state);
    return render.hud.scaledResolution(
        @floatFromInt(px.w),
        @floatFromInt(px.h),
        app_state.settings.gui_scale.limit(),
    );
}

fn renderWorld(app_state: *AppState) !void {
    const px = drawableSize(app_state);
    const aspect: f32 = @as(f32, @floatFromInt(px.w)) / @as(f32, @floatFromInt(px.h));
    const proj = math.Mat4.perspective(fov_y_radians, aspect, near_plane, far_plane);
    const partial = app_state.timer.render_partial_ticks;
    const camera = app_state.player.viewMatrix(partial);
    const view = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial).mul(camera)
    else
        camera;
    const view_proj = proj.mul(view);

    app_state.shader.use();
    app_state.shader.setMat4("u_view_proj", view_proj.m);
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.atlas.bind();
    app_state.shader.setInt("u_atlas", 0);
    var mesh_it = app_state.chunk_meshes.valueIterator();
    while (mesh_it.next()) |mesh| mesh.draw();

    var item_mesh = try buildItemEntityMesh(app_state.frame, app_state, app_state.timer.render_partial_ticks);
    defer item_mesh.deinit(app_state.frame);
    if (item_mesh.vertices.items.len > 0) {
        var item_gpu = render.GpuMesh.upload(&item_mesh);
        defer item_gpu.deinit();
        item_gpu.draw();
    }

    var falling_mesh = try buildFallingBlockMesh(app_state.frame, app_state, app_state.timer.render_partial_ticks);
    defer falling_mesh.deinit(app_state.frame);
    if (falling_mesh.vertices.items.len > 0) {
        var falling_gpu = render.GpuMesh.upload(&falling_mesh);
        defer falling_gpu.deinit();
        falling_gpu.draw();
    }

    var pig_mesh = try buildPigMesh(app_state.frame, app_state, app_state.timer.render_partial_ticks);
    defer pig_mesh.deinit(app_state.frame);
    if (pig_mesh.vertices.items.len > 0) {
        var pig_gpu = render.GpuMesh.upload(&pig_mesh);
        defer pig_gpu.deinit();
        app_state.pig_texture.bind();
        pig_gpu.draw();
        app_state.atlas.bind();
    }
}

pub fn iterate(
    app_state: *AppState,
) !sdl3.AppResult {
    gl.makeProcTableCurrent(&app_state.gl_procs);
    _ = frame_arena.reset(.retain_capacity);
    const px = drawableSize(app_state);
    gl.Viewport(0, 0, px.w, px.h);
    const gui = guiSize(app_state);

    const dt = app_state.fps_capper.delay();
    _ = dt;

    app_state.frames_this_second += 1;
    const now_ms = sdl3.timer.getMillisecondsSinceInit();
    if (now_ms -% app_state.debug_latched_ms >= 1000) {
        app_state.debug_fps = app_state.frames_this_second;
        app_state.debug_chunk_updates = app_state.chunk_updates_this_second;
        app_state.frames_this_second = 0;
        app_state.chunk_updates_this_second = 0;
        app_state.debug_latched_ms = now_ms;
    }

    app_state.timer.advance(sdl3.timer.getNanosecondsSinceInit());
    if (app_state.screen == .playing and !app_state.paused) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| {
            try tick(app_state);
        }
    }

    gl.Enable(gl.DEPTH_TEST);
    gl.ClearColor(0.502, 0.118, 1.0, 1.0);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    if (app_state.screen == .playing) try renderWorld(app_state);

    if (app_state.screen == .playing and app_state.show_debug) {
        try render.debug_overlay.draw(
            app_state.frame,
            app_state.shader,
            app_state.font,
            debugStats(app_state),
            gui,
        );
    }

    if (app_state.video_open) {
        try render.video_settings_screen.draw(
            app_state.frame,
            app_state.shader,
            app_state.dirt_texture,
            app_state.gui_texture,
            app_state.font,
            app_state.settings,
            if (app_state.options_parent == .pause) .veil else .dirt,
            app_state.mouse_x,
            app_state.mouse_y,
            gui,
        );
    } else if (app_state.options_open) {
        try render.options_screen.draw(
            app_state.frame,
            app_state.shader,
            app_state.dirt_texture,
            app_state.gui_texture,
            app_state.font,
            app_state.settings,
            if (app_state.options_parent == .pause) .veil else .dirt,
            app_state.mouse_x,
            app_state.mouse_y,
            gui,
        );
    } else if (app_state.screen == .title) {
        try render.title_screen.draw(
            app_state.frame,
            app_state.shader,
            app_state.dirt_texture,
            app_state.logo_texture,
            app_state.gui_texture,
            app_state.font,
            app_state.splash,
            sdl3.timer.getMillisecondsSinceInit(),
            app_state.mouse_x,
            app_state.mouse_y,
            gui,
        );
    } else if (app_state.paused) {
        try render.menu.draw(
            app_state.frame,
            app_state.shader,
            app_state.gui_texture,
            app_state.font,
            app_state.mouse_x,
            app_state.mouse_y,
            gui,
        );
    } else if (app_state.inventory_open) {
        try render.inventory_screen.draw(
            app_state.frame,
            app_state.shader,
            app_state.inventory_texture,
            app_state.atlas,
            app_state.items_texture,
            app_state.font,
            app_state.char_texture,
            &biped_parts,
            biped_head_index,
            char_texture_width,
            char_texture_height,
            app_state.player.inventory,
            app_state.crafting_grid,
            app_state.held_stack,
            app_state.mouse_x,
            app_state.mouse_y,
            gui,
        );
    } else {
        try render.hud.draw(
            app_state.frame,
            app_state.shader,
            app_state.atlas,
            app_state.gui_texture,
            app_state.icons_texture,
            app_state.items_texture,
            app_state.font,
            app_state.player.inventory,
            gui,
        );
    }

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
        .key_down => |k| if (app_state.video_open) {
            if (k.key == .escape) app_state.video_open = false;
        } else if (app_state.options_open) {
            if (k.key == .escape) try closeOptions(app_state);
        } else if (app_state.screen == .playing) {
            if (k.key == .escape) {
                if (app_state.inventory_open) {
                    try toggleInventory(app_state);
                } else {
                    try togglePause(app_state);
                }
            } else if (k.key == .func3) {
                app_state.show_debug = !app_state.show_debug;
            } else if (k.key == .e and !app_state.paused) {
                try toggleInventory(app_state);
            } else {
                setKeyState(app_state, k.key, true);
                selectHotbarFromKey(app_state, k.key);
            }
        },
        .key_up => |k| setKeyState(app_state, k.key, false),
        .mouse_motion => |m| {
            app_state.mouse_x = m.x;
            app_state.mouse_y = m.y;
            if (app_state.dragging_slider) |s| {
                const gui = guiSize(app_state);
                setSlider(app_state, s, render.options_screen.sliderValueAt(s, m.x, gui));
            } else if (worldFocused(app_state)) {
                app_state.player.turn(m.x_rel, m.y_rel, app_state.settings.sensitivity, app_state.settings.invert_mouse);
            }
        },
        .mouse_wheel => |w| if (worldFocused(app_state)) {
            app_state.player.inventory.cycleHotbar(if (w.scroll_y > 0) 1 else if (w.scroll_y < 0) -1 else 0);
        },
        .mouse_button_down => |m| switch (m.button) {
            .left => if (app_state.video_open) {
                try videoClick(app_state);
            } else if (app_state.options_open) {
                try optionsClick(app_state);
            } else if (app_state.screen == .title) {
                const gui = guiSize(app_state);
                if (render.title_screen.actionAt(app_state.mouse_x, app_state.mouse_y, gui)) |action| switch (action) {
                    .singleplayer => try enterWorld(app_state),
                    .options => try openOptions(app_state, .title),
                    .quit => return .success,
                };
            } else if (app_state.paused) {
                try pauseMenuClick(app_state);
            } else if (app_state.inventory_open) {
                try inventoryClickAt(app_state, .left);
            } else {
                app_state.mouse_left_down = true;
            },
            .right => if (app_state.video_open or app_state.options_open or app_state.screen == .title or app_state.paused) {} else if (app_state.inventory_open) {
                try inventoryClickAt(app_state, .right);
            } else {
                try placeBlockAtTarget(app_state);
            },
            else => {},
        },
        .mouse_button_up => |m| switch (m.button) {
            .left => {
                app_state.mouse_left_down = false;
                app_state.dragging_slider = null;
            },
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
        state.chunk_meshes.deinit(state.gpa);
        state.item_entities.deinit(state.gpa);
        state.falling_blocks.deinit(state.gpa);
        state.pigs.deinit(state.gpa);
        state.world_map.deinit();
        state.generator.deinit(state.gpa);
        state.shader.deinit();
        state.atlas.deinit();
        state.pig_texture.deinit();
        state.char_texture.deinit();
        state.gui_texture.deinit();
        state.icons_texture.deinit();
        state.items_texture.deinit();
        state.inventory_texture.deinit();
        state.dirt_texture.deinit();
        state.logo_texture.deinit();
        state.font.deinit();
        state.gl_context.deinit() catch {};
        state.window.deinit();
        frame_arena.deinit();
    }
    sdl3.quit(init_flags);
    sdl3.shutdown();
    if (builtin.mode == .Debug) _ = debug_allocator.deinit();
}
