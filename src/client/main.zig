const std = @import("std");
const builtin = @import("builtin");

const assets = @import("assets");
const font_png = assets.font.default_png;
const core = @import("core");
const Timer = core.Timer;
const game = @import("game");
const gl = @import("gl");
const math = @import("math");
const render = @import("render");
const sdl3 = @import("sdl3");
const world = @import("world");

const ticks_per_second = 20.0;
const screen_width = 854;
const screen_height = 480;
const init_flags = sdl3.InitFlags{ .video = true };
const fov_y_radians = 70.0 * std.math.pi / 180.0;
const near_plane = 0.05;
const far_plane = 1000.0;
const reach_distance = 4.5;
const bucket_reach = 5.0;
const chunk_load_budget_ns = 8 * std.time.ns_per_ms;
const spawn_position = math.Vec3.init(8, 90, 8);
const wasm = builtin.cpu.arch.isWasm();

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

comptime {
    _ = sdl3.main_callbacks;
}
pub const _start = void;
pub const WinMainCRTStartup = void;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var frame_arena: std.heap.ArenaAllocator = undefined;
var io_threaded: std.Io.Threaded = undefined;

const AppState = struct {
    gpa: std.mem.Allocator,
    frame: std.mem.Allocator,
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    gl_context: sdl3.video.gl.Context,
    gl_procs: gl.ProcTable,
    textures: render.Textures,
    texture_fx: render.TextureFx,
    colorizer: render.Colorizer,
    sky: render.SkyRenderer,
    font: render.Font,
    shader: render.Shader,
    generator: world.TerrainGenerator,
    world_map: world.World,
    chunks: render.ChunkRenderer = .{},
    entities: game.Entities = .{},
    timer: Timer,
    tick_count: u64 = 0,
    frame_end_ns: u64 = 0,
    cloud_offset: u64 = 0,
    fog_brightness: f32 = 0,
    prev_fog_brightness: f32 = 0,
    chunks_drawn: u32 = 0,
    equip: render.held_item.Equip = .{},
    player: game.Player = playerAtSpawn(),
    keys: struct {
        forward: bool = false,
        back: bool = false,
        left: bool = false,
        right: bool = false,
        jump: bool = false,
        sneak: bool = false,
    } = .{},
    mouse_left_down: bool = false,
    last_held_swing_tick: u64 = 0,
    missed_click_cooldown: u32 = 0,
    digging: ?Digging = null,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    screen: Screen = .title,
    splash: []const u8 = splashes[0],
    mojang_until_ms: u64 = 0,
    inventory_open: bool = false,
    sign_edit: ?render.edit_sign_screen.State = null,
    workbench_open: bool = false,
    furnace_open: ?world.World.BlockPos = null,
    paused: bool = false,
    dead: bool = false,
    options_open: bool = false,
    video_open: bool = false,
    controls_open: bool = false,
    rebinding: ?game.Settings.Binding = null,
    show_debug: bool = false,
    third_person: bool = false,
    frames_this_second: u32 = 0,
    chunk_updates_this_second: u32 = 0,
    debug_fps: u32 = 0,
    debug_chunk_updates: u32 = 0,
    debug_latched_ms: u64 = 0,
    options_parent: OptionsParent = .title,
    dragging_slider: ?render.options_screen.Slider = null,
    dragging_scrollbar: bool = false,
    settings: game.Settings = .{},
    held_stack: ?game.Inventory.ItemStack = null,
    crafting_grid: [game.crafting.player_grid_size * game.crafting.player_grid_size]?game.Inventory.ItemStack = @splat(null),
    workbench_grid: [game.crafting.workbench_grid_size * game.crafting.workbench_grid_size]?game.Inventory.ItemStack = @splat(null),
    io: std.Io,
    base_path: [:0]const u8,
    base_dir: std.Io.Dir,
    saves_dir: std.Io.Dir,
    packs_dir: std.Io.Dir,
    packs: []render.texture_pack.Pack = &.{},
    pack_thumbnails: []render.Atlas = &.{},
    selected_pack: NameBuffer = .{},
    pack_scroll: f32 = 0,
    save_handle: ?world.save.Save = null,
    open_folder: NameBuffer = .{},
    open_name: NameBuffer = .{},
    summaries: []world.save.Summary = &.{},
    selected_world: ?usize = null,
    last_list_click_ms: u64 = 0,
    list_scroll: f32 = 0,
    create_state: render.create_world_screen.State = undefined,
    multiplayer_state: render.multiplayer_screen.State = undefined,
    loading: Loading = .{},
    needs_spawn: bool = false,
    spawn: [3]i32 = .{ 0, 64, 0 },
    ticks_since_save: u32 = 0,
    pause_save_frames: u32 = 0,
    pause_ticks: u32 = 0,
    pause_saving: bool = false,
    stats: game.stats.Stats = .{},
    stats_open: bool = false,
    stats_view: render.stats_screen.State = .{},
    chat: render.chat.State = .{},
};

const Screen = enum { title, select_world, create_world, multiplayer, texture_packs, confirm_delete, loading, playing };

const NameBuffer = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn text(self: *const NameBuffer) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *NameBuffer, value: []const u8) void {
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
    }
};

const Loading = struct {
    done: usize = 0,
    total: usize = 0,
    next: i32 = 0,
    title: []const u8 = "Loading level",
};

const spawn_load_radius: i32 = 3;
const autosave_interval_ticks: u32 = 40;
const save_chunks_per_pass: usize = 24;
const OptionsParent = enum { title, pause };

const Digging = struct {
    x: i32,
    y: i32,
    z: i32,
    progress: f32,
};

fn playerAtSpawn() game.Player {
    var player = game.Player.spawn(spawn_position);
    player.inventory = starterInventory();
    return player;
}

fn starterInventory() game.Inventory {
    var inv: game.Inventory = .{};
    inv.slots[0] = .{ .id = .{ .block = .stone }, .count = 64 };
    inv.slots[1] = .{ .id = .{ .item = .coal }, .count = 64 };
    inv.slots[2] = .{ .id = .{ .block = .cobblestone }, .count = 64 };
    inv.slots[3] = .{ .id = .{ .item = .stick }, .count = 64 };
    inv.slots[4] = .{ .id = .{ .block = .workbench }, .count = 64 };
    inv.slots[5] = .{ .id = .{ .block = .log }, .count = 64 };
    inv.slots[6] = .{ .id = .{ .item = .ingot_iron }, .count = 64 };
    return inv;
}

fn debugStats(app_state: *const AppState) render.debug_overlay.Stats {
    const loaded: u32 = @intCast(app_state.chunks.loadedCount());
    const entities: u32 = @intCast(app_state.entities.count());
    const memory = core.process.sample();
    return .{
        .fps = app_state.debug_fps,
        .chunk_updates = app_state.debug_chunk_updates,
        .renderers_rendered = app_state.chunks_drawn,
        .renderers_loaded = loaded,
        .entities_rendered = entities,
        .entities_total = entities,
        .particles = @intCast(app_state.entities.particles.items.len + app_state.entities.pickups.items.len),
        .chunk_cache = @intCast(app_state.world_map.chunks.count()),
        .x = app_state.player.base.position.x,
        .y = app_state.player.base.position.y,
        .z = app_state.player.base.position.z,
        .yaw = app_state.player.yaw,
        .used_memory = memory.used,
        .allocated_memory = memory.allocated,
        .max_memory = memory.max,
    };
}

fn playerChunkCoord(app_state: *const AppState) world.World.ChunkCoord {
    const x: i32 = @intFromFloat(@floor(app_state.player.base.position.x));
    const z: i32 = @intFromFloat(@floor(app_state.player.base.position.z));
    return .{
        .x = @divFloor(x, world.constants.chunk_width),
        .z = @divFloor(z, world.constants.chunk_width),
    };
}

fn viewRadius(app_state: *const AppState) i32 {
    return render.ChunkRenderer.radiusFor(@intFromEnum(app_state.settings.render_distance));
}

const Pending = struct {
    coord: world.World.ChunkCoord,
    distance: i64,

    fn nearestFirst(_: void, a: Pending, b: Pending) bool {
        return a.distance < b.distance;
    }
};

fn ensureChunksAroundPlayer(app_state: *AppState) !void {
    const center = playerChunkCoord(app_state);
    const radius = viewRadius(app_state);

    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(app_state.frame);

    var cx = center.x - radius - 1;
    while (cx <= center.x + radius + 1) : (cx += 1) {
        var cz = center.z - radius - 1;
        while (cz <= center.z + radius + 1) : (cz += 1) {
            if (app_state.world_map.isDecorated(cx, cz)) {
                if (!app_state.chunks.hasMesh(cx, cz) and neighborhoodDecorated(&app_state.world_map, cx, cz)) {
                    try app_state.chunks.markDirty(app_state.gpa, cx, cz);
                }
                continue;
            }
            const dx: i64 = cx - center.x;
            const dz: i64 = cz - center.z;
            try pending.append(app_state.frame, .{
                .coord = .{ .x = cx, .z = cz },
                .distance = dx * dx + dz * dz,
            });
        }
    }

    std.mem.sort(Pending, pending.items, {}, Pending.nearestFirst);

    const started = sdl3.timer.getNanosecondsSinceInit();
    for (pending.items) |entry| {
        try app_state.world_map.ensureDecorated(app_state.generator, entry.coord.x, entry.coord.z);
        try markMeshableAround(app_state, entry.coord);
        if (sdl3.timer.getNanosecondsSinceInit() -% started >= chunk_load_budget_ns) break;
    }
}

fn neighborhoodDecorated(world_map: *const world.World, chunk_x: i32, chunk_z: i32) bool {
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            if (!world_map.isDecorated(chunk_x + dx, chunk_z + dz)) return false;
        }
    }
    return true;
}

fn markMeshableAround(app_state: *AppState, coord: world.World.ChunkCoord) !void {
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            const cx = coord.x + dx;
            const cz = coord.z + dz;
            if (app_state.chunks.hasMesh(cx, cz) or neighborhoodDecorated(&app_state.world_map, cx, cz)) {
                try app_state.chunks.markDirty(app_state.gpa, cx, cz);
            }
        }
    }
}

const persist_root = "/rosebed";

extern fn rosebed_persist() void;

fn persist() void {
    if (wasm) rosebed_persist();
}

fn glGetProcAddress(name: [*:0]const u8) ?gl.PROC {
    const proc = sdl3.c.SDL_GL_GetProcAddress(name) orelse {
        std.log.err("GL proc unavailable: {s}", .{name});
        return null;
    };
    return @ptrCast(@alignCast(proc));
}

fn setIcon(window: sdl3.video.Window) !void {
    const icon = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(@embedFile("icon_png")), true);
    defer icon.deinit();
    try window.setIcon(icon);
}

pub fn init(
    init_data: sdl3.Init,
) !struct { AppState, sdl3.AppResult } {
    _ = init_data;

    try sdl3.init(init_flags);
    errdefer sdl3.quit(init_flags);

    try sdl3.video.gl.setAttribute(.context_major_version, 3);
    try sdl3.video.gl.setAttribute(.context_minor_version, if (wasm) 0 else 3);
    try sdl3.video.gl.setAttribute(.context_profile_mask, @intFromEnum(
        if (wasm) sdl3.video.gl.Profile.es else sdl3.video.gl.Profile.core,
    ));

    const window = try sdl3.video.Window.init("Rosebed", screen_width, screen_height, .{
        .open_gl = true,
        .resizable = true,
        .fill_document = wasm,
    });
    errdefer window.deinit();

    if (!wasm) setIcon(window) catch |err| {
        std.log.warn("could not set the window icon: {t}", .{err});
    };

    const gl_context = try sdl3.video.gl.Context.init(window);
    errdefer gl_context.deinit() catch {};

    try sdl3.mouse.setWindowRelativeMode(window, false);

    const gpa = if (wasm)
        std.heap.c_allocator
    else if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;
    frame_arena = .init(gpa);
    io_threaded = .init(gpa, .{});
    const io = io_threaded.io();
    const base_path = if (wasm) persist_root else try sdl3.filesystem.getBasePath();
    const base_dir = try std.Io.Dir.cwd().openDir(io, base_path, .{});
    const saves_dir = try world.save.openSavesDir(io, base_dir);
    const packs_dir = try render.texture_pack.open(io, base_dir);

    var app_state: AppState = .{
        .gpa = gpa,
        .frame = frame_arena.allocator(),
        .fps_capper = .{ .mode = .{ .unlimited = {} } },
        .window = window,
        .gl_context = gl_context,
        .gl_procs = undefined,
        .textures = undefined,
        .texture_fx = .init(@bitCast(sdl3.timer.getNanosecondsSinceInit())),
        .colorizer = undefined,
        .sky = undefined,
        .font = undefined,
        .shader = undefined,
        .generator = undefined,
        .world_map = world.World.init(gpa),
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
        .io = io,
        .base_path = base_path,
        .base_dir = base_dir,
        .saves_dir = saves_dir,
        .packs_dir = packs_dir,
    };
    app_state.selected_pack.set(render.texture_pack.default_name);
    if (!app_state.gl_procs.init(glGetProcAddress)) return error.GlInitFailed;
    gl.makeProcTableCurrent(&app_state.gl_procs);
    gl.DepthFunc(gl.LEQUAL);

    app_state.stats = try game.stats_file.load(gpa, io, base_dir, game.stats_file.default_username);
    errdefer app_state.stats.deinit(gpa);

    app_state.world_map.rand.setSeed(@bitCast(sdl3.timer.getNanosecondsSinceInit()));
    app_state.splash = pickSplash(&app_state.world_map.rand);

    app_state.textures = try render.Textures.load(gpa, null);
    errdefer app_state.textures.deinit();

    app_state.colorizer = try render.Colorizer.load(gpa);
    errdefer app_state.colorizer.deinit(gpa);

    app_state.font = try render.Font.load(font_png);
    errdefer app_state.font.deinit();

    try app_state.texture_fx.loadSprites(assets.gui.items_png, assets.misc.dial_png);

    app_state.shader = try render.terrain_shader.init();
    errdefer app_state.shader.deinit();

    try render.mojang_screen.draw(uiContext(&app_state, guiSize(&app_state)));
    try sdl3.video.gl.swapWindow(window);
    app_state.mojang_until_ms = sdl3.timer.getMillisecondsSinceInit() + render.mojang_screen.hold_ms;

    app_state.sky = try render.SkyRenderer.init(gpa);
    errdefer app_state.sky.deinit();

    app_state.generator = try world.TerrainGenerator.init(gpa, 0);
    errdefer app_state.generator.deinit(gpa);

    return .{ app_state, .run };
}

const missed_click_ticks = 10;

fn pickedEntity(app_state: *AppState) ?game.Entities.Target {
    var reach: f64 = reach_distance;
    if (game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance)) |hit| {
        reach = hit.distance;
    }
    reach = @min(reach, game.Entities.entity_reach);
    return app_state.entities.pick(app_state.player.eyePosition(), app_state.player.lookVector(), reach);
}

fn attackEntity(app_state: *AppState, target: game.Entities.Target) !void {
    var damage: i32 = 1;
    if (app_state.player.inventory.selectedStack()) |stack| {
        damage = switch (stack.id) {
            .item => |held| held.damageVsEntity(),
            .block => 1,
        };
    }
    if (damage <= 0) return;
    if (app_state.player.base.motion.y < 0.0) damage += 1;

    if (target == .painting) return breakPainting(app_state, target.painting);

    _ = app_state.entities.hurtTarget(target, damage, app_state.player.base.position, &app_state.world_map.rand);
    try app_state.stats.add(app_state.gpa, .{ .general = .damage_dealt }, damage);
}

fn clickLeft(app_state: *AppState) !void {
    if (app_state.missed_click_cooldown > 0) return;
    app_state.player.swingItem();
    if (pickedEntity(app_state)) |target| {
        try attackEntity(app_state, target);
        return;
    }
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse {
        app_state.missed_click_cooldown = missed_click_ticks;
        return;
    };
    if (app_state.digging != null) return;
    switch (app_state.world_map.getBlock(hit.x, hit.y, hit.z)) {
        .door_wood => {
            try world.block_update.toggleDoor(&app_state.world_map, hit.x, hit.y, hit.z);
            try applyBlockChanges(app_state);
        },
        .trapdoor => {
            try world.block_update.toggleTrapdoor(&app_state.world_map, hit.x, hit.y, hit.z);
            try applyBlockChanges(app_state);
        },
        .cake => try eatCakeSlice(app_state, hit.x, hit.y, hit.z),
        .lever, .button => {
            _ = try world.redstone.activate(&app_state.world_map, hit.x, hit.y, hit.z);
            try applyBlockChanges(app_state);
        },
        .ore_redstone => try lightRedstoneOre(app_state, hit.x, hit.y, hit.z),
        else => {},
    }
}

fn digStep(app_state: *AppState) !void {
    if (!app_state.mouse_left_down) {
        app_state.digging = null;
        return;
    }
    if (app_state.missed_click_cooldown > 0) return;

    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse {
        app_state.digging = null;
        return;
    };

    if (app_state.digging == null or app_state.digging.?.x != hit.x or app_state.digging.?.y != hit.y or app_state.digging.?.z != hit.z) {
        app_state.digging = .{ .x = hit.x, .y = hit.y, .z = hit.z, .progress = 0 };
    }

    const block_id = app_state.world_map.getBlock(hit.x, hit.y, hit.z);
    const strength = block_id.strength(
        app_state.player.inventory.selectedStack(),
        app_state.player.digSpeedFactor(&app_state.world_map),
    );
    if (strength <= 0.0) return;
    if (strength >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try applyBlockChanges(app_state);
        return;
    }

    app_state.digging.?.progress += strength;
    try app_state.entities.spawnBlockHitParticle(
        app_state.gpa,
        hit.x,
        hit.y,
        hit.z,
        hit.face,
        block_id.selectionBounds(app_state.world_map.getBlockMetadata(hit.x, hit.y, hit.z)),
        block_id.particleTile(app_state.world_map.getBlockMetadata(hit.x, hit.y, hit.z)),
        particleTint(app_state, block_id, hit.x, hit.y, hit.z),
        &app_state.world_map.rand,
    );
    if (app_state.digging.?.progress >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try applyBlockChanges(app_state);
    }
}

fn particleTint(app_state: *const AppState, id: world.Block, x: i32, y: i32, z: i32) [3]u8 {
    if (id == .grass) return .{ 255, 255, 255 };
    const width = world.constants.chunk_width;
    const chunk = app_state.world_map.getChunk(@divFloor(x, width), @divFloor(z, width)) orelse return .{ 255, 255, 255 };
    const lx: u32 = @intCast(@mod(x, width));
    const lz: u32 = @intCast(@mod(z, width));
    return render.chunk_mesher.blockTint(
        app_state.colorizer,
        id,
        app_state.world_map.getBlockMetadata(x, y, z),
        world.Side.up,
        chunk.getTemperature(lx, lz),
        chunk.getHumidity(lx, lz),
    );
}

fn applyBlockChanges(app_state: *AppState) !void {
    const width = world.constants.chunk_width;
    var columns: std.AutoHashMapUnmanaged(world.World.ChunkCoord, void) = .{};
    defer columns.deinit(app_state.frame);

    for (app_state.world_map.changed.items) |pos| {
        const chunk_x = @divFloor(pos.x, width);
        const chunk_z = @divFloor(pos.z, width);
        const local_x = @mod(pos.x, width);
        const local_z = @mod(pos.z, width);

        try columns.put(app_state.frame, .{ .x = chunk_x, .z = chunk_z }, {});
        if (local_x == 0) try columns.put(app_state.frame, .{ .x = chunk_x - 1, .z = chunk_z }, {});
        if (local_x == width - 1) try columns.put(app_state.frame, .{ .x = chunk_x + 1, .z = chunk_z }, {});
        if (local_z == 0) try columns.put(app_state.frame, .{ .x = chunk_x, .z = chunk_z - 1 }, {});
        if (local_z == width - 1) try columns.put(app_state.frame, .{ .x = chunk_x, .z = chunk_z + 1 }, {});

        try app_state.chunks.markBlockDirty(app_state.gpa, pos.x, pos.z);
    }
    app_state.world_map.changed.clearRetainingCapacity();

    var it = columns.keyIterator();
    while (it.next()) |coord| try world.light.relightChunk(app_state.gpa, &app_state.world_map, coord.x, coord.z);

    for (app_state.world_map.dropped.items) |drop| {
        try spawnDroppedItem(app_state, drop.pos.x, drop.pos.y, drop.pos.z, .{
            .id = drop.stack.id,
            .count = drop.stack.count,
            .meta = drop.stack.meta,
        });
    }
    app_state.world_map.dropped.clearRetainingCapacity();

    for (app_state.world_map.falling.items) |fall| {
        try app_state.entities.spawnFallingBlock(app_state.gpa, fall.pos.x, fall.pos.y, fall.pos.z, fall.id);
    }
    app_state.world_map.falling.clearRetainingCapacity();
}

fn spawnDroppedItem(app_state: *AppState, x: i32, y: i32, z: i32, stack: game.Inventory.ItemStack) !void {
    try app_state.entities.dropStack(app_state.gpa, x, y, z, stack, &app_state.world_map.rand);
}

fn wearHeldItem(app_state: *AppState) !void {
    const slot = &app_state.player.inventory.slots[app_state.player.inventory.selected];
    if (slot.*) |*stack| {
        const cost = switch (stack.id) {
            .block => return,
            .item => |id| if (id.tool()) |t| t.blockDestroyedCost() else 0,
        };
        if (cost == 0) return;

        try app_state.stats.use(app_state.gpa, stack.id);
        stack.damage(cost);
        if (stack.count == 0) {
            try app_state.stats.deplete(app_state.gpa, stack.id);
            slot.* = null;
        }
    }
}

fn breakBlock(app_state: *AppState, x: i32, y: i32, z: i32, block_id: world.Block) !void {
    const meta = app_state.world_map.getBlockMetadata(x, y, z);
    const harvested = block_id.harvestableWith(app_state.player.inventory.selectedStack());
    try app_state.entities.spawnBlockDestroyParticles(
        app_state.gpa,
        x,
        y,
        z,
        block_id.particleTile(meta),
        particleTint(app_state, block_id, x, y, z),
        &app_state.world_map.rand,
    );
    try app_state.world_map.setBlockWithNotify(x, y, z, .air);
    try spillFurnace(app_state, x, y, z);
    _ = app_state.world_map.removeSign(x, y, z);
    app_state.digging = null;
    try wearHeldItem(app_state);

    if (harvested) {
        try app_state.stats.mine(app_state.gpa, block_id);
        if (block_id.drop(meta, &app_state.world_map.rand)) |d| {
            try spawnDroppedItem(app_state, x, y, z, .{ .id = d.id, .count = d.count, .meta = d.meta });
        }
    }
}

fn spillFurnace(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    var removed = app_state.world_map.removeFurnace(x, y, z) orelse return;

    if (app_state.furnace_open) |open| {
        if (open.x == x and open.y == y and open.z == z) try closeContainer(app_state);
    }

    for (0..world.furnace.slot_count) |index| {
        const stack = removed.slot(index).* orelse continue;
        try spawnDroppedItem(app_state, x, y, z, stack);
    }
}

fn tickFallingBlocks(app_state: *AppState) !void {
    var i: usize = 0;
    while (i < app_state.entities.falling_blocks.items.len) {
        const block = &app_state.entities.falling_blocks.items[i];
        const outcome = block.tick(&app_state.world_map);

        if (outcome == .falling) {
            i += 1;
            continue;
        }

        const x: i32 = @intFromFloat(@floor(block.base.position.x));
        const y: i32 = @intFromFloat(@floor(block.base.position.y));
        const z: i32 = @intFromFloat(@floor(block.base.position.z));

        const landing_empty = !app_state.world_map.getBlock(x, y, z).isSolid();
        const support_solid = !app_state.world_map.getBlock(x, y - 1, z).canFallInto();
        if (outcome == .landed and landing_empty and support_solid) {
            try app_state.world_map.setBlockWithNotify(x, y, z, block.block_id);
        } else {
            try spawnDroppedItem(app_state, x, y, z, .{ .id = .{ .block = block.block_id }, .count = 1 });
        }

        _ = app_state.entities.falling_blocks.swapRemove(i);
    }
}

fn dropSelectedItem(app_state: *AppState) !void {
    const inventory = &app_state.player.inventory;
    const slot = &inventory.slots[inventory.selected];
    var stack = slot.* orelse return;
    try app_state.entities.throwFromPlayer(
        app_state.gpa,
        &app_state.player,
        .{ .id = stack.id, .count = 1, .meta = stack.meta },
        &app_state.world_map.rand,
    );
    stack.count -= 1;
    slot.* = if (stack.count == 0) null else stack;
    try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
}

const ClickType = enum { left, right };

fn dropHeldStack(app_state: *AppState, click_type: ClickType) !void {
    const held = app_state.held_stack orelse return;
    const drop_count = if (click_type == .left) held.count else 1;
    try spawnDroppedItem(
        app_state,
        @intFromFloat(@floor(app_state.player.base.position.x)),
        @intFromFloat(@floor(app_state.player.base.position.y)),
        @intFromFloat(@floor(app_state.player.base.position.z)),
        .{ .id = held.id, .count = drop_count, .meta = held.meta },
    );
    const remaining = held.count - drop_count;
    app_state.held_stack = if (remaining == 0) null else .{ .id = held.id, .count = remaining, .meta = held.meta };
    try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
}

const SlotRules = struct {
    armor: ?world.item.ArmorSlot = null,

    fn accepts(self: SlotRules, stack: game.Inventory.ItemStack) bool {
        const piece = self.armor orelse return true;
        return game.Inventory.fitsArmorSlot(stack, piece);
    }

    fn limit(self: SlotRules, stack: game.Inventory.ItemStack) u8 {
        if (self.armor != null) return 1;
        return stack.id.maxStackSize();
    }
};

fn slotClick(app_state: *AppState, slot: *?game.Inventory.ItemStack, click_type: ClickType, rules: SlotRules) void {
    if (slot.*) |*existing| {
        if (app_state.held_stack) |*held| {
            if (existing.id.eql(held.id) and existing.meta == held.meta) {
                const amount = @min(if (click_type == .left) held.count else 1, rules.limit(existing.*) -| existing.count);
                existing.count += amount;
                held.count -= amount;
                if (held.count == 0) app_state.held_stack = null;
            } else {
                if (!rules.accepts(held.*)) return;
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
        if (!rules.accepts(held.*)) return;
        const amount = @min(if (click_type == .left) held.count else 1, rules.limit(held.*));
        slot.* = .{ .id = held.id, .count = amount, .meta = held.meta };
        held.count -= amount;
        if (held.count == 0) app_state.held_stack = null;
    }
}

fn resultSlotClick(app_state: *AppState, grid: []?game.Inventory.ItemStack, size: u8) !void {
    const result = game.crafting.findMatch(grid, size) orelse return;
    if (app_state.held_stack) |*held| {
        if (!held.id.eql(result.id) or held.meta != result.meta) return;
        if (@as(u16, held.count) + result.count > result.id.maxStackSize()) return;
        held.count += result.count;
    } else {
        app_state.held_stack = result;
    }
    game.crafting.consume(grid);
    try app_state.stats.craft(app_state.gpa, result.id, result.count);
}

fn containerClickAt(
    app_state: *AppState,
    slots: []const render.container_screen.Slot,
    grid: []?game.Inventory.ItemStack,
    size: u8,
    click_type: ClickType,
) !void {
    const gui = guiSize(app_state);
    const index = render.container_screen.slotAt(slots, app_state.mouse_x, app_state.mouse_y, gui) orelse {
        if (render.container_screen.isOutside(app_state.mouse_x, app_state.mouse_y, gui)) {
            try dropHeldStack(app_state, click_type);
        }
        return;
    };
    const slot = slots[index];
    switch (slot.kind) {
        .inventory => slotClick(app_state, &app_state.player.inventory.slots[slot.index], click_type, .{}),
        .craft_input => slotClick(app_state, &grid[slot.index], click_type, .{}),
        .craft_result => try resultSlotClick(app_state, grid, size),
        .armor => slotClick(
            app_state,
            &app_state.player.inventory.armor[slot.index],
            click_type,
            .{ .armor = @enumFromInt(slot.index) },
        ),
        .furnace_input, .furnace_fuel => {
            const furnace = openedFurnace(app_state) orelse return;
            slotClick(app_state, furnace.slot(slot.index), click_type, .{});
        },
        .furnace_output => try furnaceOutputClick(app_state, click_type),
    }
}

fn furnaceOutputClick(app_state: *AppState, click_type: ClickType) !void {
    const furnace = openedFurnace(app_state) orelse return;
    const output = furnace.output orelse return;

    const taken = if (click_type == .left) output.count else (output.count + 1) / 2;
    if (app_state.held_stack) |*held| {
        if (!held.id.eql(output.id) or held.meta != output.meta) return;
        if (@as(u16, held.count) + taken > output.id.maxStackSize()) return;
        held.count += taken;
    } else {
        app_state.held_stack = .{ .id = output.id, .count = taken, .meta = output.meta };
    }

    furnace.output.?.count -= taken;
    if (furnace.output.?.count == 0) furnace.output = null;
    try app_state.stats.craft(app_state.gpa, output.id, taken);
}

fn openContainerClickAt(app_state: *AppState, click_type: ClickType) !void {
    if (app_state.furnace_open != null) {
        const layout = render.furnace_screen.slots();
        try containerClickAt(app_state, &layout, &.{}, 0, click_type);
    } else if (app_state.workbench_open) {
        const layout = render.crafting_screen.slots();
        try containerClickAt(app_state, &layout, &app_state.workbench_grid, game.crafting.workbench_grid_size, click_type);
    } else {
        const layout = render.inventory_screen.slots();
        try containerClickAt(app_state, &layout, &app_state.crafting_grid, game.crafting.player_grid_size, click_type);
    }
}

fn dropGrid(app_state: *AppState, grid: []?game.Inventory.ItemStack) !void {
    for (grid) |*slot| {
        const stack = slot.* orelse continue;
        try spawnDroppedItem(
            app_state,
            @intFromFloat(@floor(app_state.player.base.position.x)),
            @intFromFloat(@floor(app_state.player.base.position.y)),
            @intFromFloat(@floor(app_state.player.base.position.z)),
            stack,
        );
        slot.* = null;
        try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
    }
}

fn containerOpen(app_state: *const AppState) bool {
    return app_state.inventory_open or app_state.workbench_open or app_state.furnace_open != null or
        app_state.sign_edit != null;
}

fn openSignEditor(app_state: *AppState, x: i32, y: i32, z: i32) void {
    app_state.sign_edit = .{ .x = x, .y = y, .z = z };
    sdl3.keyboard.startTextInput(app_state.window) catch {};
    updateMouseMode(app_state) catch {};
}

fn closeSignEditor(app_state: *AppState) !void {
    app_state.sign_edit = null;
    try sdl3.keyboard.stopTextInput(app_state.window);
    try updateMouseMode(app_state);
}

fn editedSign(app_state: *AppState) ?*world.sign.Sign {
    const open = app_state.sign_edit orelse return null;
    return app_state.world_map.signAt(open.x, open.y, open.z);
}

fn worldFocused(app_state: *const AppState) bool {
    return app_state.screen == .playing and !containerOpen(app_state) and !app_state.paused and !app_state.dead and !app_state.options_open and !app_state.chat.open;
}

fn updateMouseMode(app_state: *AppState) !void {
    try sdl3.mouse.setWindowRelativeMode(app_state.window, worldFocused(app_state));
}

fn closeContainer(app_state: *AppState) !void {
    app_state.inventory_open = false;
    app_state.workbench_open = false;
    app_state.furnace_open = null;
    try updateMouseMode(app_state);
    try dropHeldStack(app_state, .left);
    try dropGrid(app_state, &app_state.crafting_grid);
    try dropGrid(app_state, &app_state.workbench_grid);
}

fn openWorkbench(app_state: *AppState) !void {
    app_state.workbench_open = true;
    try updateMouseMode(app_state);
}

fn openFurnace(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    _ = try app_state.world_map.addFurnace(x, y, z);
    app_state.furnace_open = .{ .x = x, .y = y, .z = z };
    try updateMouseMode(app_state);
}

fn openedFurnace(app_state: *AppState) ?*world.furnace.Furnace {
    const pos = app_state.furnace_open orelse return null;
    return app_state.world_map.furnaceAt(pos.x, pos.y, pos.z);
}

fn toggleInventory(app_state: *AppState) !void {
    if (containerOpen(app_state)) {
        try closeContainer(app_state);
        return;
    }
    app_state.inventory_open = true;
    try updateMouseMode(app_state);
}

fn togglePause(app_state: *AppState) !void {
    app_state.paused = !app_state.paused;
    if (app_state.paused) {
        app_state.pause_save_frames = 0;
        app_state.pause_ticks = 0;
        app_state.pause_saving = true;
    }
    try updateMouseMode(app_state);
}

fn stepPauseSave(app_state: *AppState) !void {
    if (app_state.save_handle == null) {
        app_state.pause_saving = false;
        return;
    }
    if (app_state.pause_save_frames == 0) {
        try saveLevel(app_state);
        try app_state.world_map.beginSaveRound();
    }
    app_state.pause_save_frames += 1;
    app_state.pause_saving = try app_state.world_map.saveQueuedChunks(save_chunks_per_pass) > 0;
}

fn killPlayer(app_state: *AppState) !void {
    app_state.dead = true;
    if (containerOpen(app_state)) try closeContainer(app_state);
    try dropInventoryOnDeath(app_state);
    app_state.keys = .{};
    app_state.mouse_left_down = false;
    app_state.digging = null;
    try app_state.stats.add(app_state.gpa, .{ .general = .deaths }, 1);
    try updateMouseMode(app_state);
}

fn dropInventoryOnDeath(app_state: *AppState) !void {
    for (&app_state.player.inventory.slots) |*slot| try scatterSlotOnDeath(app_state, slot);
    for (&app_state.player.inventory.armor) |*slot| try scatterSlotOnDeath(app_state, slot);
}

fn scatterSlotOnDeath(app_state: *AppState, slot: *?game.Inventory.ItemStack) !void {
    const stack = slot.* orelse return;
    try app_state.entities.scatterFromPlayer(
        app_state.gpa,
        &app_state.player,
        stack,
        &app_state.world_map.rand,
    );
    slot.* = null;
}

fn respawnPlayer(app_state: *AppState) !void {
    if (app_state.player.spawn_point) |bed| {
        if (world.block_update.bedRespawnSpot(&app_state.world_map, bed[0], bed[1], bed[2])) |spot| {
            app_state.player.respawn(spawnPlacement(&app_state.world_map, spot));
            app_state.dead = false;
            try updateMouseMode(app_state);
            return;
        }
        app_state.chat.addMessage(app_state.font, bed_not_valid_line);
        app_state.player.spawn_point = null;
    }

    try adjustSpawnLocation(app_state);
    app_state.player.respawn(spawnPlacement(&app_state.world_map, app_state.spawn));
    app_state.dead = false;
    try updateMouseMode(app_state);
}

fn deathScreenClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const action = render.death_screen.actionAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    switch (action) {
        .respawn => try respawnPlayer(app_state),
        .title_menu => try quitToTitle(app_state),
    }
}

fn openChat(app_state: *AppState) !void {
    app_state.chat.openInput();
    app_state.keys = .{};
    try sdl3.keyboard.startTextInput(app_state.window);
    try updateMouseMode(app_state);
}

fn closeChat(app_state: *AppState) !void {
    app_state.chat.closeInput();
    try sdl3.keyboard.stopTextInput(app_state.window);
    try updateMouseMode(app_state);
}

fn sendChat(app_state: *AppState) !void {
    const trimmed = std.mem.trim(u8, app_state.chat.message(), " ");
    if (trimmed.len > 0) {
        if (trimmed[0] == '/') {
            try runCommand(app_state, trimmed);
        } else {
            var buf: [render.chat.max_message_length + 32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "<{s}> {s}", .{ game.stats_file.default_username, trimmed }) catch trimmed;
            app_state.chat.addMessage(app_state.font, line);
        }
    }
    try closeChat(app_state);
}

fn reply(app_state: *AppState, comptime format: []const u8, args: anytype) void {
    var buf: [render.chat.max_message_length * 2]u8 = undefined;
    app_state.chat.addMessage(app_state.font, std.fmt.bufPrint(&buf, format, args) catch return);
}

fn lookedAtPosition(app_state: *AppState) math.Vec3 {
    const hit = game.raycast.cast(
        &app_state.world_map,
        app_state.player.eyePosition(),
        app_state.player.lookVector(),
        reach_distance,
    ) orelse return app_state.player.base.position;

    const target = world.block_update.placementTarget(&app_state.world_map, hit.x, hit.y, hit.z, hit.face);
    return math.Vec3.init(
        @as(f64, @floatFromInt(target.x)) + 0.5,
        @floatFromInt(target.y),
        @as(f64, @floatFromInt(target.z)) + 0.5,
    );
}

fn runCommand(app_state: *AppState, line: []const u8) !void {
    switch (game.commands.parse(line, game.stats_file.default_username)) {
        .nothing => {},
        .help => for (game.commands.help_lines) |help_line| {
            app_state.chat.addMessage(app_state.font, help_line);
        },
        .kill => {
            app_state.player.kill();
            app_state.chat.addMessage(app_state.font, game.commands.kill_line);
        },
        .seed => |seed| {
            var buffer: [64]u8 = undefined;
            const world_seed = try std.fmt.bufPrintSentinel(&buffer, "{d}", .{app_state.generator.world_seed}, 0);
            const copy_msg = if (seed.copy)
                " (Copied to clipboard)"
            else
                "";

            if (seed.copy) {
                try sdl3.clipboard.setText(world_seed);
            }
            reply(app_state, "{s}{s}", .{ world_seed, copy_msg });
        },
        .give => |give| {
            try app_state.entities.throwFromPlayer(
                app_state.gpa,
                &app_state.player,
                .{ .id = give.id, .count = give.count },
                &app_state.world_map.rand,
            );
            reply(app_state, "Giving {s} some {d}", .{ give.user, give.raw_id });
        },
        .spawn => |spawn| {
            const position = lookedAtPosition(app_state);
            for (0..spawn.count) |_| switch (spawn.mob) {
                .pig => try app_state.entities.spawnPig(app_state.gpa, position),
                .cow => try app_state.entities.spawnCow(app_state.gpa, position),
                .sheep => try app_state.entities.spawnSheep(app_state.gpa, position, &app_state.world_map.rand),
                .chicken => try app_state.entities.spawnChicken(app_state.gpa, position, &app_state.world_map.rand),
                .slime => try app_state.entities.spawnSlime(app_state.gpa, position, &app_state.world_map.rand),
                .wolf => try app_state.entities.spawnWolf(app_state.gpa, position, &app_state.world_map.rand),
            };
            reply(app_state, "Spawning {d} {s}", .{ spawn.count, @tagName(spawn.mob) });
        },
        .time => |command| {
            switch (command.method) {
                .add => {
                    app_state.world_map.setTime(app_state.world_map.time + command.amount);
                    reply(app_state, "Added {d} to time", .{command.amount});
                },
                .set => {
                    app_state.world_map.setTime(command.amount);
                    reply(app_state, "Set time to {d}", .{command.amount});
                },
            }
        },
        .unparsed_item => |text| reply(app_state, "There's no item with id {s}", .{text}),
        .missing_item => |raw| reply(app_state, "There's no item with id {d}", .{raw}),
        .missing_user => |name| reply(app_state, "Can't find user {s}", .{name}),
        .missing_mob => |name| reply(app_state, "There's no mob called {s}", .{name}),
        .unparsed_time => |text| reply(app_state, "Unable to convert time value, {s}", .{text}),
        .unknown_method => |text| reply(app_state, "{s}{s}", .{ game.commands.unknown_method_line, text }),
        .unknown => app_state.chat.addMessage(app_state.font, game.commands.unknown_command_line),
    }
}

fn quitToTitle(app_state: *AppState) !void {
    try app_state.stats.add(app_state.gpa, .{ .general = .leave_game }, 1);
    game.stats_file.save(app_state.gpa, app_state.io, app_state.base_dir, game.stats_file.default_username, &app_state.stats) catch {};
    if (app_state.save_handle != null) try saveWorld(app_state);
    persist();
    closeWorld(app_state);
    app_state.chat.clear();
    app_state.screen = .title;
    app_state.paused = false;
    app_state.dead = false;
    app_state.splash = pickSplash(&app_state.world_map.rand);
    try updateMouseMode(app_state);
}

fn refreshWorldList(app_state: *AppState) !void {
    world.save.freeList(app_state.gpa, app_state.summaries);
    app_state.summaries = try world.save.list(app_state.gpa, app_state.io, app_state.saves_dir);
    app_state.selected_world = null;
    app_state.list_scroll = 0;
}

fn openSelectWorld(app_state: *AppState) !void {
    try refreshWorldList(app_state);
    app_state.screen = .select_world;
    try updateMouseMode(app_state);
}

fn freeTexturePacks(app_state: *AppState) void {
    for (app_state.pack_thumbnails) |thumbnail| thumbnail.deinit();
    app_state.gpa.free(app_state.pack_thumbnails);
    app_state.pack_thumbnails = &.{};

    render.texture_pack.deinitAll(app_state.gpa, app_state.packs);
    app_state.packs = &.{};
}

fn openMultiplayer(app_state: *AppState) !void {
    app_state.multiplayer_state = render.multiplayer_screen.init(app_state.settings.last_server.text());
    app_state.screen = .multiplayer;
    try sdl3.keyboard.startTextInput(app_state.window);
}

fn closeMultiplayer(app_state: *AppState) !void {
    try sdl3.keyboard.stopTextInput(app_state.window);
    app_state.screen = .title;
}

fn connectToServer(app_state: *AppState) !void {
    if (!app_state.multiplayer_state.canConnect()) return;

    var stored: [128]u8 = undefined;
    const typed = app_state.multiplayer_state.address.text();
    app_state.settings.last_server.set(render.multiplayer_screen.storedName(typed, &stored));

    _ = render.multiplayer_screen.parseAddress(typed);
}

fn multiplayerClick(app_state: *AppState) !void {
    const hit = render.multiplayer_screen.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        guiSize(app_state),
        &app_state.multiplayer_state,
    ) orelse return;

    switch (hit) {
        .address_field => app_state.multiplayer_state.address.focused = true,
        .connect => try connectToServer(app_state),
        .cancel => try closeMultiplayer(app_state),
    }
}

fn openTexturePacks(app_state: *AppState) !void {
    freeTexturePacks(app_state);

    app_state.packs = try render.texture_pack.scan(app_state.gpa, app_state.io, app_state.packs_dir);
    errdefer freeTexturePacks(app_state);

    const thumbnails = try app_state.gpa.alloc(render.Atlas, app_state.packs.len);
    for (app_state.packs, thumbnails) |pack, *thumbnail| {
        const fallback = if (render.texture_pack.isDefault(pack)) assets.pack_png else assets.gui.unknown_pack_png;
        thumbnail.* = render.Atlas.load(pack.thumbnail orelse fallback) catch
            try render.Atlas.load(assets.gui.unknown_pack_png);
    }
    app_state.pack_thumbnails = thumbnails;

    app_state.pack_scroll = 0;
    app_state.screen = .texture_packs;
    try updateMouseMode(app_state);
}

fn selectTexturePack(app_state: *AppState, index: usize) !void {
    const name = app_state.packs[index].name;
    if (std.mem.eql(u8, name, app_state.selected_pack.text())) return;

    const archive = render.Textures.openArchive(app_state.gpa, app_state.io, app_state.packs_dir, name);
    defer if (archive) |bytes| app_state.gpa.free(bytes);

    const reloaded = try render.Textures.load(app_state.gpa, archive);
    app_state.textures.deinit();
    app_state.textures = reloaded;
    app_state.selected_pack.set(name);
}

fn texturePacksClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.texture_packs_screen.scrollbarAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.packs.len)) {
        app_state.dragging_scrollbar = true;
        return;
    }

    const hit = render.texture_packs_screen.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        gui,
        app_state.packs.len,
        app_state.pack_scroll,
    ) orelse return;

    switch (hit) {
        .entry => |index| try selectTexturePack(app_state, index),
        .open_folder => openTexturePackFolder(app_state),
        .done => {
            freeTexturePacks(app_state);
            app_state.screen = .title;
            try updateMouseMode(app_state);
        },
    }
}

fn openTexturePackFolder(app_state: *AppState) void {
    const url = std.fmt.allocPrintSentinel(app_state.frame, "file://{s}{s}", .{ app_state.base_path, render.texture_pack.folder_name }, 0) catch return;
    sdl3.openURL(url) catch {};
}

fn openCreateWorld(app_state: *AppState) !void {
    app_state.create_state = render.create_world_screen.init(.create);
    app_state.create_state.name.setText("New World");
    updateCreateFolder(app_state);
    app_state.screen = .create_world;
    try sdl3.keyboard.startTextInput(app_state.window);
    try updateMouseMode(app_state);
}

fn updateCreateFolder(app_state: *AppState) void {
    var buffer: [world.save.max_name_len]u8 = undefined;
    const sanitized = world.save.sanitizeFolderName(&buffer, app_state.create_state.name.text());
    app_state.create_state.setFolderName(sanitized);
}

fn playerState(app_state: *AppState, entries: *std.ArrayList(world.save.InventoryEntry)) !world.save.PlayerState {
    try app_state.player.inventory.appendSaveEntries(app_state.gpa, entries);
    const position = app_state.player.base.position;
    return .{
        .pos = .{ position.x, position.y, position.z },
        .motion = .{ app_state.player.base.motion.x, app_state.player.base.motion.y, app_state.player.base.motion.z },
        .yaw = app_state.player.yaw,
        .pitch = app_state.player.pitch,
        .fall_distance = app_state.player.fall_distance,
        .fire = @intCast(app_state.player.fire),
        .air = @intCast(app_state.player.air),
        .on_ground = app_state.player.base.on_ground,
        .health = @intCast(app_state.player.health),
        .hurt_time = @intCast(app_state.player.hurt_time),
        .death_time = @intCast(app_state.player.death_time),
        .spawn = app_state.player.spawn_point,
        .inventory = entries.items,
    };
}

fn applyPlayerState(app_state: *AppState, state: world.save.PlayerState) void {
    app_state.player.base.position = math.Vec3.init(
        @floatCast(state.pos[0]),
        @floatCast(state.pos[1]),
        @floatCast(state.pos[2]),
    );
    app_state.player.base.motion = math.Vec3.init(
        @floatCast(state.motion[0]),
        @floatCast(state.motion[1]),
        @floatCast(state.motion[2]),
    );
    app_state.player.base.prev_position = app_state.player.base.position;
    app_state.player.yaw = state.yaw;
    app_state.player.pitch = state.pitch;
    app_state.player.prev_yaw = state.yaw;
    app_state.player.prev_pitch = state.pitch;
    app_state.player.render_yaw = state.yaw;
    app_state.player.prev_render_yaw = state.yaw;
    app_state.player.base.on_ground = state.on_ground;
    app_state.player.fall_distance = state.fall_distance;
    app_state.player.fire = state.fire;
    app_state.player.air = state.air;
    app_state.player.health = state.health;
    app_state.player.prev_health = state.health;
    app_state.player.hurt_time = state.hurt_time;
    app_state.player.death_time = state.death_time;
    app_state.player.spawn_point = state.spawn;

    app_state.player.inventory.loadSaveEntries(state.inventory);
}

fn saveWorld(app_state: *AppState) !void {
    if (app_state.save_handle == null) return;
    try app_state.world_map.saveLoadedChunks();
    try saveLevel(app_state);
    persist();
}

fn saveLevel(app_state: *AppState) !void {
    const handle = if (app_state.save_handle) |*h| h else return;

    var entries: std.ArrayList(world.save.InventoryEntry) = .empty;
    defer entries.deinit(app_state.gpa);
    const player = try playerState(app_state, &entries);

    const info: world.save.LevelInfo = .{
        .seed = app_state.generator.world_seed,
        .spawn = app_state.spawn,
        .time = app_state.world_map.time,
        .last_played = world.RegionFile.unixMilliseconds(app_state.io),
        .size_on_disk = @intCast(handle.diskSize(app_state.io)),
        .name = @constCast(app_state.open_name.text()),
        .player = player,
    };
    try handle.writeLevel(app_state.gpa, app_state.io, info);
}

fn closeWorld(app_state: *AppState) void {
    if (app_state.save_handle) |*handle| handle.close(app_state.gpa, app_state.io);
    app_state.save_handle = null;
    app_state.world_map.persistence = null;
    const rand = app_state.world_map.rand;
    app_state.world_map.deinit();
    app_state.world_map = world.World.init(app_state.gpa);
    app_state.world_map.rand = rand;
    app_state.chunks.deinit(app_state.gpa);
    app_state.chunks = .{};
    app_state.entities.deinit(app_state.gpa);
    app_state.entities = .{};
}

fn startWorld(app_state: *AppState, folder: []const u8, name: []const u8, seed: ?i64) !void {
    closeWorld(app_state);

    app_state.open_folder.set(folder);
    app_state.open_name.set(name);

    app_state.save_handle = try world.save.open(app_state.io, app_state.saves_dir, folder);
    const handle = &app_state.save_handle.?;

    var stored = handle.readLevel(app_state.gpa, app_state.io) catch null;
    defer if (stored) |*info| info.deinit(app_state.gpa);

    const level_seed = if (stored) |info| info.seed else seed orelse app_state.world_map.rand.nextLong();

    app_state.generator.deinit(app_state.gpa);
    app_state.generator = try world.TerrainGenerator.init(app_state.gpa, level_seed);

    app_state.world_map.persistence = .{ .handle = handle, .io = app_state.io };
    app_state.world_map.entity_io = app_state.entities.entityIo();
    app_state.world_map.entity_probe = .{ .context = app_state, .anyInBox = anyEntityInBox };
    app_state.player = playerAtSpawn();

    try app_state.stats.add(app_state.gpa, .{ .general = if (stored == null) .create_world else .load_world }, 1);
    try app_state.stats.add(app_state.gpa, .{ .general = .start_game }, 1);

    app_state.needs_spawn = true;
    if (stored) |info| {
        app_state.open_name.set(info.name);
        app_state.world_map.time = info.time;
        app_state.spawn = info.spawn;
        if (info.player) |player| {
            applyPlayerState(app_state, player);
            app_state.needs_spawn = false;
        }
    } else {
        app_state.world_map.time = 0;
        app_state.spawn = try findInitialSpawn(app_state);
    }

    app_state.loading = .{
        .total = @intCast((spawn_load_radius * 2 + 1) * (spawn_load_radius * 2 + 1)),
        .title = if (stored == null) "Generating level" else "Loading level",
    };
    app_state.screen = .loading;
    app_state.ticks_since_save = 0;
    try updateMouseMode(app_state);
}

fn loadingChunkCoord(app_state: *const AppState, index: i32) world.World.ChunkCoord {
    const side = spawn_load_radius * 2 + 1;
    const center_x = @divFloor(app_state.spawn[0], world.constants.chunk_width);
    const center_z = @divFloor(app_state.spawn[2], world.constants.chunk_width);
    return .{
        .x = center_x + @mod(index, side) - spawn_load_radius,
        .z = center_z + @divFloor(index, side) - spawn_load_radius,
    };
}

fn stepLoading(app_state: *AppState) !void {
    const started = sdl3.timer.getNanosecondsSinceInit();

    while (app_state.loading.done < app_state.loading.total) {
        const coord = loadingChunkCoord(app_state, app_state.loading.next);
        try app_state.world_map.ensureDecorated(app_state.generator, coord.x, coord.z);
        app_state.loading.next += 1;
        app_state.loading.done += 1;
        if (sdl3.timer.getNanosecondsSinceInit() -% started >= chunk_load_budget_ns) return;
    }

    try finishLoading(app_state);
}

fn firstUncoveredBlock(app_state: *AppState, x: i32, z: i32) !world.Block {
    const width = world.constants.chunk_width;
    try app_state.world_map.ensureDecorated(app_state.generator, @divFloor(x, width), @divFloor(z, width));

    var y: i32 = 63;
    while (app_state.world_map.getBlock(x, y + 1, z) != .air) : (y += 1) {}
    return app_state.world_map.getBlock(x, y, z);
}

fn findInitialSpawn(app_state: *AppState) ![3]i32 {
    var x: i32 = 0;
    var z: i32 = 0;
    while ((try firstUncoveredBlock(app_state, x, z)) != .sand) {
        x += app_state.world_map.rand.nextIntBound(64) - app_state.world_map.rand.nextIntBound(64);
        z += app_state.world_map.rand.nextIntBound(64) - app_state.world_map.rand.nextIntBound(64);
    }
    return .{ x, 64, z };
}

fn adjustSpawnLocation(app_state: *AppState) !void {
    if (app_state.spawn[1] <= 0) app_state.spawn[1] = 64;
    while ((try firstUncoveredBlock(app_state, app_state.spawn[0], app_state.spawn[2])) == .air) {
        app_state.spawn[0] += app_state.world_map.rand.nextIntBound(8) - app_state.world_map.rand.nextIntBound(8);
        app_state.spawn[2] += app_state.world_map.rand.nextIntBound(8) - app_state.world_map.rand.nextIntBound(8);
    }
}

fn spawnPlacement(world_map: *const world.World, spawn: [3]i32) math.Vec3 {
    var position = math.Vec3.init(
        @as(f64, @floatFromInt(spawn[0])) + 0.5,
        @as(f64, @floatFromInt(spawn[1] + 1)) - game.Player.eye_height,
        @as(f64, @floatFromInt(spawn[2])) + 0.5,
    );
    while (position.y + game.Player.eye_height > 0) : (position.y += 1) {
        const box = game.Entity.init(position, game.Player.width, game.Player.height).boundingBox();
        if (!game.physics.isBoxObstructed(world_map, box)) break;
    }
    return position;
}

fn finishLoading(app_state: *AppState) !void {
    if (app_state.needs_spawn) {
        app_state.player.base.position = spawnPlacement(&app_state.world_map, app_state.spawn);
        app_state.player.base.prev_position = app_state.player.base.position;
        app_state.needs_spawn = false;
    }

    try app_state.chunks.markAllDirty(app_state.gpa);
    app_state.screen = .playing;
    try saveWorld(app_state);
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
    app_state.controls_open = false;
    app_state.rebinding = null;
    app_state.dragging_slider = null;
    try updateMouseMode(app_state);
}

fn selectWorldClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.select_world_screen.scrollbarAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.summaries.len)) {
        app_state.dragging_scrollbar = true;
        return;
    }

    const hit = render.select_world_screen.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        gui,
        app_state.summaries.len,
        app_state.list_scroll,
        app_state.selected_world != null,
    ) orelse return;

    switch (hit) {
        .entry => |index| {
            const now = sdl3.timer.getMillisecondsSinceInit();
            const double = render.select_world_screen.isDoubleClick(
                app_state.selected_world,
                index,
                now,
                app_state.last_list_click_ms,
            );
            app_state.selected_world = index;
            app_state.last_list_click_ms = now;
            if (double) try playSelectedWorld(app_state);
        },
        .select => try playSelectedWorld(app_state),
        .rename => try openRenameWorld(app_state),
        .delete => app_state.screen = .confirm_delete,
        .create => try openCreateWorld(app_state),
        .cancel => {
            app_state.screen = .title;
            try updateMouseMode(app_state);
        },
    }
}

fn playSelectedWorld(app_state: *AppState) !void {
    const index = app_state.selected_world orelse return;
    const summary = app_state.summaries[index];
    try startWorld(app_state, summary.folder, summary.name, null);
}

fn openRenameWorld(app_state: *AppState) !void {
    const index = app_state.selected_world orelse return;
    app_state.create_state = render.create_world_screen.init(.rename);
    app_state.create_state.name.setText(app_state.summaries[index].name);
    app_state.screen = .create_world;
    try sdl3.keyboard.startTextInput(app_state.window);
}

fn createWorldClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.create_world_screen.hitAt(app_state.mouse_x, app_state.mouse_y, gui, &app_state.create_state) orelse return;

    switch (hit) {
        .name_field, .seed_field => app_state.create_state.focus(hit),
        .confirm => try confirmCreateWorld(app_state),
        .cancel => {
            try sdl3.keyboard.stopTextInput(app_state.window);
            try openSelectWorld(app_state);
        },
    }
}

fn confirmCreateWorld(app_state: *AppState) !void {
    const name = app_state.create_state.name.text();
    if (name.len == 0) return;
    try sdl3.keyboard.stopTextInput(app_state.window);

    switch (app_state.create_state.mode) {
        .create => {
            const folder = try world.save.unusedFolderName(app_state.gpa, app_state.io, app_state.saves_dir, name);
            defer app_state.gpa.free(folder);

            const random_seed = app_state.world_map.rand.nextLong();
            const seed = render.create_world_screen.seedFromText(app_state.create_state.seed.text(), random_seed);
            try startWorld(app_state, folder, name, seed);
        },
        .rename => {
            const index = app_state.selected_world orelse return;
            var handle = try world.save.open(app_state.io, app_state.saves_dir, app_state.summaries[index].folder);
            defer handle.close(app_state.gpa, app_state.io);

            var info = try handle.readLevel(app_state.gpa, app_state.io);
            defer info.deinit(app_state.gpa);

            app_state.gpa.free(info.name);
            info.name = try app_state.gpa.dupe(u8, name);
            try handle.writeLevel(app_state.gpa, app_state.io, info);

            try openSelectWorld(app_state);
        },
    }
}

fn confirmDeleteClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.confirm_screen.hitAt(app_state.mouse_x, app_state.mouse_y, gui, "Delete") orelse return;
    switch (hit) {
        .confirm => {
            if (app_state.selected_world) |index| {
                try world.save.deleteWorld(app_state.io, app_state.saves_dir, app_state.summaries[index].folder);
            }
            try openSelectWorld(app_state);
        },
        .cancel => app_state.screen = .select_world,
    }
}

fn setSlider(app_state: *AppState, which: render.options_screen.Slider, value: f32) void {
    switch (which) {
        .music => app_state.settings.music_volume = value,
        .sound => app_state.settings.sound_volume = value,
        .sensitivity => app_state.settings.sensitivity = value,
    }
}

fn dragScrollbar(app_state: *AppState, dy_pixels: f32) void {
    const gui = guiSize(app_state);
    const dy = dy_pixels / gui.factor;

    if (app_state.stats_open) {
        const view = &app_state.stats_view;
        view.scroll.set(view.tab, render.stats_screen.dragScroll(gui, view.*, dy));
    } else if (app_state.screen == .select_world) {
        app_state.list_scroll = render.select_world_screen.dragScroll(gui, app_state.summaries.len, app_state.list_scroll, dy);
    } else if (app_state.screen == .texture_packs) {
        app_state.pack_scroll = render.texture_packs_screen.dragScroll(gui, app_state.packs.len, app_state.pack_scroll, dy);
    }
}

fn pauseMenuClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const action = render.menu.actionAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    switch (action) {
        .resume_game => try togglePause(app_state),
        .statistics => try openStats(app_state),
        .options => try openOptions(app_state, .pause),
        .quit_to_title => try quitToTitle(app_state),
    }
}

fn openStats(app_state: *AppState) !void {
    app_state.stats_view.deinit(app_state.gpa);
    app_state.stats_view = try render.stats_screen.State.init(app_state.gpa, &app_state.stats);
    app_state.stats_open = true;
}

fn closeStats(app_state: *AppState) void {
    app_state.stats_view.deinit(app_state.gpa);
    app_state.stats_open = false;
}

fn statsClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.stats_screen.scrollbarAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.stats_view)) {
        app_state.dragging_scrollbar = true;
        return;
    }

    const hit = render.stats_screen.hitAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.stats_view) orelse return;
    switch (hit) {
        .done => closeStats(app_state),
        .tab => |tab| app_state.stats_view.tab = tab,
        .header => |column| {
            app_state.stats_view.pressed = column;
            render.stats_screen.applySort(&app_state.stats_view, &app_state.stats, column);
        },
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
        .controls => app_state.controls_open = true,
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
        switch (hit) {
            .ambient_occlusion, .graphics => try app_state.chunks.markAllDirty(app_state.gpa),
            else => {},
        }
    }
}

fn controlsClick(app_state: *AppState) void {
    const gui = guiSize(app_state);
    const hit = render.controls_screen.hitAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    switch (hit) {
        .binding => |binding| app_state.rebinding = binding,
        .done => {
            app_state.controls_open = false;
            app_state.rebinding = null;
        },
    }
}

fn consumeSelectedStack(app_state: *AppState) void {
    const slot = &app_state.player.inventory.slots[app_state.player.inventory.selected];
    if (slot.*) |*stack| {
        stack.count -= 1;
        if (stack.count == 0) slot.* = null;
    }
}

fn useBlockOrPlace(app_state: *AppState) !bool {
    if (pickedEntity(app_state)) |target| return interactWithEntity(app_state, target);
    if (game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance)) |hit| {
        switch (app_state.world_map.getBlock(hit.x, hit.y, hit.z)) {
            .workbench => {
                try openWorkbench(app_state);
                return true;
            },
            .furnace, .burning_furnace => {
                try openFurnace(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .door_wood => {
                try world.block_update.toggleDoor(&app_state.world_map, hit.x, hit.y, hit.z);
                try applyBlockChanges(app_state);
                return true;
            },
            .door_iron => return true,
            .trapdoor => {
                try world.block_update.toggleTrapdoor(&app_state.world_map, hit.x, hit.y, hit.z);
                try applyBlockChanges(app_state);
                return true;
            },
            .cake => {
                try eatCakeSlice(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .bed => {
                try sleepInBed(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .lever, .button, .repeater_off, .repeater_on => {
                _ = try world.redstone.activate(&app_state.world_map, hit.x, hit.y, hit.z);
                try applyBlockChanges(app_state);
                return true;
            },
            .ore_redstone => try lightRedstoneOre(app_state, hit.x, hit.y, hit.z),
            else => |id| {
                if (id.def().on_activated) |hook| {
                    if (try hook(&app_state.world_map, hit.x, hit.y, hit.z, id)) {
                        try applyBlockChanges(app_state);
                        return true;
                    }
                }
            },
        }
    }
    return placeBlockAtTarget(app_state);
}

fn lightRedstoneOre(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    try app_state.entities.spawnRedstoneOreParticles(
        app_state.gpa,
        &app_state.world_map,
        x,
        y,
        z,
        &app_state.world_map.rand,
    );
    try world.redstone.lightRedstoneOre(&app_state.world_map, x, y, z);
    try applyBlockChanges(app_state);
}

fn eatCakeSlice(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    if (app_state.player.health >= 20) return;
    app_state.player.heal(3);

    const eaten = app_state.world_map.getBlockMetadata(x, y, z) + 1;
    if (eaten >= world.block.cake_slices) {
        try app_state.world_map.setBlockWithNotify(x, y, z, .air);
    } else {
        try app_state.world_map.setBlockMetadataWithNotify(x, y, z, @intCast(eaten));
    }
    try applyBlockChanges(app_state);
}

fn breakPainting(app_state: *AppState, index: usize) !void {
    const painting = app_state.entities.paintings.orderedRemove(index);
    try app_state.entities.dropStackAt(
        app_state.gpa,
        painting.position,
        .{ .id = .{ .item = .painting }, .count = 1 },
        &app_state.world_map.rand,
    );
}

fn hangPaintingAtTarget(app_state: *AppState) !bool {
    const hit = game.raycast.cast(
        &app_state.world_map,
        app_state.player.eyePosition(),
        app_state.player.lookVector(),
        reach_distance,
    ) orelse return false;

    const direction = game.Painting.directionFromFace(hit.face) orelse return false;
    const hung = game.Painting.pickArt(
        .{ hit.x, hit.y, hit.z },
        direction,
        &app_state.world_map,
        app_state.entities.paintings.items,
        &app_state.world_map.rand,
    ) orelse return true;

    try app_state.entities.spawnPainting(app_state.gpa, hung);
    try app_state.stats.use(app_state.gpa, .{ .item = .painting });
    consumeSelectedStack(app_state);
    return true;
}

const bed_not_valid_line = "Your home bed was missing or obstructed";
const bed_reach_x: f64 = 3.0;
const bed_reach_y: f64 = 2.0;

fn sleepInBed(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    var pillow: [3]i32 = .{ x, y, z };
    if (!world.block.bedIsPillow(app_state.world_map.getBlockMetadata(x, y, z))) {
        pillow = world.block_update.bedPartner(&app_state.world_map, x, y, z) orelse return;
    }

    if (app_state.world_map.isDaytime()) {
        app_state.chat.addMessage(app_state.font, "You can only sleep at night");
        return;
    }

    const position = app_state.player.base.position;
    if (@abs(position.x - @as(f64, @floatFromInt(pillow[0]))) > bed_reach_x) return;
    if (@abs(position.y - @as(f64, @floatFromInt(pillow[1]))) > bed_reach_y) return;
    if (@abs(position.z - @as(f64, @floatFromInt(pillow[2]))) > bed_reach_x) return;

    app_state.world_map.skipToDawn();
    app_state.player.spawn_point = pillow;
}

fn useHeldItem(app_state: *AppState) !void {
    const held: ?world.Item = switch ((app_state.player.inventory.selectedStack() orelse return).id) {
        .item => |id| id,
        .block => null,
    };
    if (held != .bow) return;
    if (!app_state.player.inventory.consumeItem(.{ .item = .arrow })) return;

    try app_state.entities.shootArrow(app_state.gpa, &app_state.player, &app_state.world_map.rand);
    try app_state.stats.use(app_state.gpa, .{ .item = .bow });
}

fn interactWithEntity(app_state: *AppState, target: game.Entities.Target) !bool {
    const entry = app_state.entities.mobAt(target) orelse return false;
    const held: ?world.Item = if (app_state.player.inventory.selectedStack()) |stack| switch (stack.id) {
        .item => |id| id,
        .block => null,
    } else null;

    if (entry.type_id == game.mob.wolf) return interactWithWolf(app_state, entry.animal, held);
    if (entry.type_id != game.mob.cow) return false;

    const milked = game.Cow.interact(held orelse return false) orelse return false;
    holdStack(app_state, milked);
    try app_state.stats.use(app_state.gpa, .{ .item = held.? });
    return true;
}

fn interactWithWolf(app_state: *AppState, animal: *game.Animal, held: ?world.Item) !bool {
    const wolf: *game.Wolf = @fieldParentPtr("animal", animal);
    const used = wolf.interact(app_state.gpa, held, &app_state.world_map.rand) orelse return false;

    switch (used) {
        .tamed, .refused => {
            consumeSelectedStack(app_state);
            try app_state.entities.spawnTreatReaction(
                app_state.gpa,
                wolf.animal,
                used == .tamed,
                &app_state.world_map.rand,
            );
            try app_state.stats.use(app_state.gpa, .{ .item = .bone });
        },
        .fed => {
            consumeSelectedStack(app_state);
            try app_state.stats.use(app_state.gpa, .{ .item = held.? });
        },
        .sat, .stood => {},
    }
    return true;
}

fn holdStack(app_state: *AppState, held: world.Item) void {
    app_state.player.inventory.slots[app_state.player.inventory.selected] =
        .{ .id = .{ .item = held }, .count = 1 };
}

fn useBucket(app_state: *AppState, held: world.Item, fill: world.item.Fill) !bool {
    const hit = game.raycast.castWith(
        &app_state.world_map,
        app_state.player.eyePosition(),
        app_state.player.lookVector(),
        bucket_reach,
        fill == .empty,
    ) orelse return false;

    switch (fill) {
        .empty => {
            const scooped = try world.block_update.scoopLiquid(&app_state.world_map, hit.x, hit.y, hit.z) orelse return false;
            holdStack(app_state, scooped.bucketItem());
        },
        .milk => holdStack(app_state, .bucket),
        .water, .lava => {
            const step = bucketPourStep(hit.face);
            const px = hit.x + step[0];
            const py = hit.y + step[1];
            const pz = hit.z + step[2];
            if (!try world.block_update.pourLiquid(&app_state.world_map, px, py, pz, fill)) return false;
            holdStack(app_state, .bucket);
        },
    }

    try app_state.stats.use(app_state.gpa, .{ .item = held });
    try applyBlockChanges(app_state);
    return true;
}

fn bucketPourStep(face: world.Side) [3]i32 {
    return switch (face) {
        .down => .{ 0, -1, 0 },
        .up => .{ 0, 1, 0 },
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .east => .{ 1, 0, 0 },
    };
}

fn placeDoorAtTarget(app_state: *AppState, held: world.Item) !bool {
    const placed: world.Block = switch (held) {
        .door_wood => .door_wood,
        .door_iron => .door_iron,
        else => return false,
    };
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return false;
    if (hit.face != .up) return false;
    if (!try world.block_update.placeDoor(&app_state.world_map, hit.x, hit.y + 1, hit.z, placed, app_state.player.yaw)) return false;

    try app_state.stats.use(app_state.gpa, .{ .item = held });
    consumeSelectedStack(app_state);
    try applyBlockChanges(app_state);
    return true;
}

fn placeSignAtTarget(app_state: *AppState) !bool {
    const hit = game.raycast.cast(
        &app_state.world_map,
        app_state.player.eyePosition(),
        app_state.player.lookVector(),
        reach_distance,
    ) orelse return false;
    if (hit.face == .down) return false;
    if (!app_state.world_map.getBlock(hit.x, hit.y, hit.z).material().isSolid()) return false;

    const target = world.block_update.placementTarget(&app_state.world_map, hit.x, hit.y, hit.z, hit.face);
    if (target.y < 0 or target.y >= world.constants.chunk_height) return false;
    if (!app_state.world_map.getBlock(target.x, target.y, target.z).isReplaceable()) return false;

    if (hit.face == .up) {
        const facing = world.block.signPostFacingFromYaw(app_state.player.yaw);
        try app_state.world_map.setBlockAndMetadataWithNotify(target.x, target.y, target.z, .sign_post, facing);
    } else {
        try app_state.world_map.setBlockAndMetadataWithNotify(
            target.x,
            target.y,
            target.z,
            .wall_sign,
            @intFromEnum(hit.face),
        );
    }

    _ = try app_state.world_map.addSign(target.x, target.y, target.z);
    try app_state.stats.use(app_state.gpa, .{ .item = .sign });
    consumeSelectedStack(app_state);
    try applyBlockChanges(app_state);
    openSignEditor(app_state, target.x, target.y, target.z);
    return true;
}

fn placeBedAtTarget(app_state: *AppState) !bool {
    const hit = game.raycast.cast(
        &app_state.world_map,
        app_state.player.eyePosition(),
        app_state.player.lookVector(),
        reach_distance,
    ) orelse return false;
    if (hit.face != .up) return false;
    if (!try world.block_update.placeBed(&app_state.world_map, hit.x, hit.y + 1, hit.z, app_state.player.yaw)) return false;

    try app_state.stats.use(app_state.gpa, .{ .item = .bed });
    consumeSelectedStack(app_state);
    try applyBlockChanges(app_state);
    return true;
}

fn placeBlockAtTarget(app_state: *AppState) !bool {
    const stack = app_state.player.inventory.selectedStack() orelse return false;
    const placed = switch (stack.id) {
        .block => |b| b,
        .item => |held| blk: {
            if (held.bucketFill()) |fill| return useBucket(app_state, held, fill);
            if (held == .painting) return hangPaintingAtTarget(app_state);
            if (held == .bed) return placeBedAtTarget(app_state);
            if (held == .sign) return placeSignAtTarget(app_state);
            break :blk held.placedBlock() orelse {
                if (held.def().on_use) |hook| {
                    if (game.raycast.cast(
                        &app_state.world_map,
                        app_state.player.eyePosition(),
                        app_state.player.lookVector(),
                        reach_distance,
                    )) |hit| {
                        if (try hook(&app_state.world_map, hit.x, hit.y, hit.z, hit.face, held, stack.meta)) {
                            try applyBlockChanges(app_state);
                            return true;
                        }
                    }
                }
                return placeDoorAtTarget(app_state, held);
            };
        },
    };
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return false;
    const target = world.block_update.placementTarget(&app_state.world_map, hit.x, hit.y, hit.z, hit.face);
    const px = target.x;
    const py = target.y;
    const pz = target.z;
    if (py < 0 or py >= world.constants.chunk_height) return false;
    if (!app_state.world_map.getBlock(px, py, pz).isReplaceable()) return false;
    if (!world.block_update.canPlaceOnSide(&app_state.world_map, px, py, pz, placed, target.face)) return false;
    const meta = world.block_update.placementMetadata(&app_state.world_map, px, py, pz, placed, target.face, stack.blockMeta());
    try app_state.world_map.setBlockAndMetadataWithNotify(px, py, pz, placed, meta);
    if (placed == .furnace) {
        const facing = world.block.furnaceFacingFromYaw(app_state.player.yaw);
        try app_state.world_map.setBlockMetadataWithNotify(px, py, pz, facing);
        _ = try app_state.world_map.addFurnace(px, py, pz);
    }
    if (placed.isStairs()) {
        const facing = world.block.stairsFacingFromYaw(app_state.player.yaw);
        try app_state.world_map.setBlockMetadataWithNotify(px, py, pz, facing);
    }
    try world.redstone.onBlockPlaced(
        &app_state.world_map,
        px,
        py,
        pz,
        placed,
        .{ app_state.player.base.position.x, app_state.player.base.position.y, app_state.player.base.position.z },
        app_state.player.yaw,
    );
    _ = try world.block_update.mergeSlabBelow(&app_state.world_map, px, py, pz);
    try app_state.stats.use(app_state.gpa, stack.id);
    consumeSelectedStack(app_state);
    try applyBlockChanges(app_state);
    return true;
}

fn centimetres(value: f64) i32 {
    return @intFromFloat(@round(@as(f32, @floatCast(value)) * 100.0));
}

fn recordPlayerTick(app_state: *AppState, before: math.Vec3) !void {
    const gpa = app_state.gpa;
    const player = &app_state.player;

    try app_state.stats.add(gpa, .{ .general = .minutes_played }, 1);
    if (player.jumped) try app_state.stats.add(gpa, .{ .general = .jump }, 1);
    if (player.damage_taken > 0) {
        try app_state.stats.add(gpa, .{ .general = .damage_taken }, player.damage_taken);
        player.damage_taken = 0;
    }
    if (player.distance_fallen > 0) {
        try app_state.stats.add(gpa, .{ .general = .distance_fallen }, centimetres(player.distance_fallen));
        player.distance_fallen = 0;
    }

    const dx = player.base.position.x - before.x;
    const dy = player.base.position.y - before.y;
    const dz = player.base.position.z - before.z;
    const horizontal = centimetres(@sqrt(dx * dx + dz * dz));

    if (player.isSubmerged(&app_state.world_map)) {
        const travelled = centimetres(@sqrt(dx * dx + dy * dy + dz * dz));
        if (travelled > 0) try app_state.stats.add(gpa, .{ .general = .distance_dove }, travelled);
    } else if (player.base.in_water) {
        if (horizontal > 0) try app_state.stats.add(gpa, .{ .general = .distance_swum }, horizontal);
    } else if (player.base.on_ground) {
        if (horizontal > 0) try app_state.stats.add(gpa, .{ .general = .distance_walked }, horizontal);
    } else if (horizontal > 25) {
        try app_state.stats.add(gpa, .{ .general = .distance_flown }, horizontal);
    }
}

fn anyEntityInBox(context: *anyopaque, min: [3]f64, max: [3]f64, living_only: bool) bool {
    const app_state: *AppState = @ptrCast(@alignCast(context));
    const box = math.AABB.init(min[0], min[1], min[2], max[0], max[1], max[2]);
    if (!app_state.dead and app_state.player.base.boundingBox().intersects(box)) return true;
    return app_state.entities.anyInBox(box, living_only);
}

fn collideWithBlocks(app_state: *AppState, box: math.AABB) !void {
    var x = math.util.floorDouble(box.min_x);
    const max_x = math.util.floorDouble(box.max_x);
    const max_y = math.util.floorDouble(box.max_y);
    const max_z = math.util.floorDouble(box.max_z);
    while (x <= max_x) : (x += 1) {
        var y = math.util.floorDouble(box.min_y);
        while (y <= max_y) : (y += 1) {
            var z = math.util.floorDouble(box.min_z);
            while (z <= max_z) : (z += 1) {
                try world.redstone.onEntityCollided(&app_state.world_map, x, y, z);
            }
        }
    }
}

fn pressPressurePlates(app_state: *AppState) !void {
    if (!app_state.dead) try collideWithBlocks(app_state, app_state.player.base.boundingBox());
    for (app_state.entities.mobs.items) |entry| try collideWithBlocks(app_state, entry.animal.base.boundingBox());
    for (app_state.entities.items.items) |*dropped| try collideWithBlocks(app_state, dropped.base.boundingBox());
}

fn tick(app_state: *AppState) !void {
    app_state.tick_count += 1;
    stepFogBrightness(app_state);
    app_state.chat.tick();
    if (app_state.sign_edit) |*open| open.tick();

    const moving_allowed = !containerOpen(app_state) and !app_state.dead;
    const forward: f32 = if (!moving_allowed) 0 else (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = if (!moving_allowed) 0 else (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    const before_move = app_state.player.base.position;
    const was_in_water = app_state.player.base.in_water;
    app_state.player.tick(
        &app_state.world_map,
        strafe,
        forward,
        moving_allowed and app_state.keys.jump,
        moving_allowed and app_state.keys.sneak,
    );
    try recordPlayerTick(app_state, before_move);
    if (app_state.player.isDead() and !app_state.dead) try killPlayer(app_state);
    if (!was_in_water and app_state.player.base.in_water and app_state.tick_count > 1) {
        try app_state.entities.spawnWaterSplash(app_state.gpa, app_state.player.base, &app_state.world_map.rand);
    }
    if (app_state.player.drowned) {
        try app_state.entities.spawnDrowningBubbles(
            app_state.gpa,
            app_state.player.eyePosition(),
            app_state.player.base.motion,
            &app_state.world_map.rand,
        );
    }
    if (app_state.missed_click_cooldown > 0) app_state.missed_click_cooldown -= 1;
    if (app_state.mouse_left_down and app_state.tick_count - app_state.last_held_swing_tick >= 5) {
        try clickLeft(app_state);
        app_state.last_held_swing_tick = app_state.tick_count;
    }
    try app_state.entities.tickArrows(
        app_state.gpa,
        &app_state.world_map,
        &app_state.player,
        &app_state.world_map.rand,
    );
    app_state.player.tickSwing();
    app_state.equip.tick(app_state.player.inventory.selectedStack());
    try digStep(app_state);
    try app_state.entities.tickItems(app_state.gpa, &app_state.world_map, &app_state.player);
    try tickFallingBlocks(app_state);
    const player_chunk = playerChunkCoord(app_state);
    try app_state.world_map.tickRandomBlocks(player_chunk.x, player_chunk.z);
    try pressPressurePlates(app_state);
    try app_state.world_map.tickUpdates();
    try app_state.world_map.tickFurnaces();
    try app_state.world_map.tickPistons();
    try app_state.entities.applyPistonShoves(&app_state.world_map, &app_state.player);
    try applyBlockChanges(app_state);
    try app_state.entities.tickMobs(
        app_state.gpa,
        &app_state.world_map,
        &app_state.player,
        &app_state.world_map.rand,
    );
    _ = try game.spawner.performSpawning(
        app_state.gpa,
        &app_state.entities,
        &app_state.world_map,
        app_state.player.base.position,
        app_state.spawn,
        app_state.generator.world_seed,
        &app_state.world_map.rand,
    );
    try app_state.entities.tickPaintings(app_state.gpa, &app_state.world_map, &app_state.world_map.rand);
    try app_state.entities.tickParticles(app_state.gpa, &app_state.world_map, &app_state.world_map.rand);
    app_state.entities.tickPickups();
    try spawnDisplayParticles(app_state);
    try ensureChunksAroundPlayer(app_state);
    try advanceWorldTime(app_state);

    app_state.ticks_since_save += 1;
    if (app_state.ticks_since_save >= autosave_interval_ticks) {
        app_state.ticks_since_save = 0;
        try saveLevel(app_state);
        try app_state.world_map.beginSaveRound();
        _ = try app_state.world_map.saveQueuedChunks(save_chunks_per_pass);
    }
}

const display_particle_samples = 1000;
const display_particle_range = 16;

fn spawnDisplayParticles(app_state: *AppState) !void {
    const rand = &app_state.world_map.rand;
    const px = math.util.floorDouble(app_state.player.base.position.x);
    const py = math.util.floorDouble(app_state.player.base.position.y);
    const pz = math.util.floorDouble(app_state.player.base.position.z);
    for (0..display_particle_samples) |_| {
        const x = px + rand.nextIntBound(display_particle_range) - rand.nextIntBound(display_particle_range);
        const y = py + rand.nextIntBound(display_particle_range) - rand.nextIntBound(display_particle_range);
        const z = pz + rand.nextIntBound(display_particle_range) - rand.nextIntBound(display_particle_range);
        switch (app_state.world_map.getBlock(x, y, z)) {
            .flowing_lava, .stationary_lava => {
                if (app_state.world_map.getBlock(x, y + 1, z) != .air) continue;
                if (rand.nextIntBound(100) != 0) continue;
                const position = math.Vec3.init(
                    @as(f64, @floatFromInt(x)) + @as(f64, rand.nextFloat()),
                    @as(f64, @floatFromInt(y)) + 1.0,
                    @as(f64, @floatFromInt(z)) + @as(f64, rand.nextFloat()),
                );
                try app_state.entities.particles.append(app_state.gpa, game.Particle.spawnLava(position, rand));
            },
            .torch => try app_state.entities.spawnTorchParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .redstone_wire => try app_state.entities.spawnWireParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .torch_redstone_on => try app_state.entities.spawnRedstoneTorchParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .repeater_on => try app_state.entities.spawnRepeaterParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .ore_redstone_glowing => try app_state.entities.spawnRedstoneOreParticles(
                app_state.gpa,
                &app_state.world_map,
                x,
                y,
                z,
                rand,
            ),
            .burning_furnace => try app_state.entities.spawnFurnaceParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            else => {},
        }
    }
}

fn advanceWorldTime(app_state: *AppState) !void {
    app_state.world_map.time += 1;
    app_state.cloud_offset += 1;

    const subtracted = app_state.world_map.calculateSkylightSubtracted(1.0);
    if (subtracted != app_state.world_map.skylight_subtracted) {
        app_state.world_map.skylight_subtracted = subtracted;
        try app_state.chunks.markAllDirty(app_state.gpa);
    }
}

fn drawableSize(app_state: *const AppState) struct { w: gl.sizei, h: gl.sizei } {
    const s = app_state.window.getSizeInPixels() catch return .{ .w = screen_width, .h = screen_height };
    return .{ .w = @intCast(@max(s[0], 1)), .h = @intCast(@max(s[1], 1)) };
}

fn refreshRate(app_state: *const AppState) ?f32 {
    const display = app_state.window.getDisplayForWindow() catch return null;
    const mode = display.getCurrentMode() catch return null;
    return mode.refresh_rate;
}

fn guiSize(app_state: *const AppState) render.gui.Scaled {
    const px = drawableSize(app_state);
    return render.gui.scaledResolution(
        @floatFromInt(px.w),
        @floatFromInt(px.h),
        app_state.settings.gui_scale.limit(),
    );
}

fn uiContext(app_state: *const AppState, res: render.gui.Scaled) render.Ui {
    return .{
        .gpa = app_state.frame,
        .shader = app_state.shader,
        .textures = app_state.textures,
        .font = app_state.font,
        .mouse_x = app_state.mouse_x,
        .mouse_y = app_state.mouse_y,
        .res = res,
    };
}

fn drawEntityMesh(mesh: *const render.MeshBuilder) void {
    if (mesh.vertices.items.len == 0) return;
    var gpu = render.GpuMesh.upload(mesh);
    defer gpu.deinit();
    gpu.draw();
}

const underwater_fog_color = render.sky.Color{ 0.02, 0.02, 0.2 };
const underwater_fog_density: f32 = 0.1;
const underwater_fov_degrees: f32 = 60.0;
const lava_fog_color = render.sky.Color{ 0.6, 0.1, 0.0 };
const lava_fog_density: f32 = 2.0;

fn cameraSubmerged(app_state: *const AppState) bool {
    return app_state.player.isSubmerged(&app_state.world_map);
}

fn cameraInLava(app_state: *const AppState) bool {
    return app_state.player.isEyeInLava(&app_state.world_map);
}

fn cameraFogDensity(app_state: *const AppState) ?f32 {
    if (cameraSubmerged(app_state)) return underwater_fog_density;
    if (cameraInLava(app_state)) return lava_fog_density;
    return null;
}

fn fogBrightness(app_state: *const AppState) f32 {
    const partial = app_state.timer.render_partial_ticks;
    return app_state.prev_fog_brightness + (app_state.fog_brightness - app_state.prev_fog_brightness) * partial;
}

fn stepFogBrightness(app_state: *AppState) void {
    const position = app_state.player.base.position;
    const light = world.light.brightnessAt(
        &app_state.world_map,
        math.util.floorDouble(position.x),
        math.util.floorDouble(position.y),
        math.util.floorDouble(position.z),
        0,
    );
    const target = render.sky.fogBrightnessTarget(light, @intFromEnum(app_state.settings.render_distance));

    app_state.prev_fog_brightness = app_state.fog_brightness;
    app_state.fog_brightness += (target - app_state.fog_brightness) * render.sky.fog_brightness_step;
}

fn compassAngle(app_state: *const AppState) f64 {
    if (app_state.screen != .playing) return 0.0;
    const to_spawn_x = @as(f64, @floatFromInt(app_state.spawn[0])) - app_state.player.base.position.x;
    const to_spawn_z = @as(f64, @floatFromInt(app_state.spawn[2])) - app_state.player.base.position.z;
    return @as(f64, app_state.player.yaw - 90.0) * std.math.pi / 180.0 - std.math.atan2(to_spawn_z, to_spawn_x);
}

fn clockAngle(app_state: *const AppState) f64 {
    if (app_state.screen != .playing) return 0.0;
    return -@as(f64, app_state.world_map.celestialAngle(1.0)) * std.math.pi * 2.0;
}

fn horizonColor(app_state: *const AppState) render.sky.Color {
    const near = if (cameraSubmerged(app_state))
        underwater_fog_color
    else if (cameraInLava(app_state))
        lava_fog_color
    else blended: {
        const temperature: f32 = @floatCast(app_state.generator.climate.temperatureAt(
            math.util.floorDouble(app_state.player.base.position.x),
            math.util.floorDouble(app_state.player.base.position.z),
        ));
        const render_distance = @intFromEnum(app_state.settings.render_distance);
        const angle = app_state.world_map.celestialAngle(app_state.timer.render_partial_ticks);
        break :blended render.sky.blendedFogColor(
            render.sky.skyColor(temperature, angle),
            render.sky.fogColor(angle),
            render_distance,
        );
    };

    return render.sky.dimmed(near, fogBrightness(app_state));
}

fn setupFog(app_state: *const AppState, horizon: render.sky.Color) void {
    app_state.shader.setInt("u_fog_enabled", 1);
    app_state.shader.setVec3("u_fog_color", horizon);

    if (cameraFogDensity(app_state)) |density| {
        app_state.shader.setInt("u_fog_exponential", 1);
        app_state.shader.setFloat("u_fog_density", density);
        return;
    }

    const far = render.sky.farPlaneDistance(@intFromEnum(app_state.settings.render_distance));
    app_state.shader.setInt("u_fog_exponential", 0);
    app_state.shader.setFloat("u_fog_start", far * 0.25);
    app_state.shader.setFloat("u_fog_end", far);
}

fn renderWorld(app_state: *AppState, horizon: render.sky.Color) !void {
    app_state.chunk_updates_this_second += try app_state.chunks.flush(app_state.gpa, &app_state.world_map, app_state.colorizer, .{
        .smooth = app_state.settings.ambient_occlusion,
        .fancy = app_state.settings.fancy_graphics,
    }, app_state.player.base.position.x, app_state.player.base.position.z, app_state.settings.framerate_limit.rebuildDeadlineNs(app_state.frame_end_ns));

    const px = drawableSize(app_state);
    const aspect: f32 = @as(f32, @floatFromInt(px.w)) / @as(f32, @floatFromInt(px.h));
    const fov = if (cameraSubmerged(app_state))
        underwater_fov_degrees * std.math.pi / 180.0
    else
        fov_y_radians;
    const proj = math.Mat4.perspective(fov, aspect, near_plane, far_plane);
    const partial = app_state.timer.render_partial_ticks;
    const eye_view = app_state.player.viewMatrix(partial);
    const camera = if (app_state.third_person) pulled: {
        const distance = app_state.player.thirdPersonDistance(&app_state.world_map, partial);
        break :pulled math.Mat4.translation(0, 0, @floatCast(-distance)).mul(eye_view);
    } else eye_view;
    const hurt = app_state.player.hurtMatrix(partial);
    const view = if (app_state.settings.view_bobbing)
        hurt.mul(app_state.player.bobMatrix(partial)).mul(camera)
    else
        hurt.mul(camera);
    const view_proj = proj.mul(view);
    const eye = app_state.player.base.renderPosition(partial);

    app_state.shader.use();
    try drawSky(app_state, proj, partial, horizon);

    app_state.shader.setMat4("u_view_proj", view_proj.m);
    app_state.shader.setVec3("u_camera_pos", .{
        @floatCast(eye.x),
        @floatCast(eye.y + game.Player.eye_height),
        @floatCast(eye.z),
    });
    setupFog(app_state, horizon);
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.textures.terrain.bind();
    app_state.shader.setInt("u_atlas", 0);
    app_state.shader.setInt("u_alpha_test", 1);
    app_state.shader.setInt("u_textured", 1);
    app_state.shader.setVec4("u_tint", .{ 1, 1, 1, 1 });
    const frustum = math.Frustum.fromViewProjection(view_proj);
    gl.Enable(gl.CULL_FACE);
    app_state.chunks_drawn = app_state.chunks.drawSolid(frustum);

    var atlas_mesh: render.MeshBuilder = .{};
    defer atlas_mesh.deinit(app_state.frame);
    for (app_state.entities.items.items) |item| {
        try render.entity_render.appendItem(&atlas_mesh, app_state.frame, &app_state.world_map, item, partial);
    }
    for (app_state.entities.pickups.items) |fx| {
        const swallowed = fx.swallowed(&app_state.player, partial);
        try render.entity_render.appendItem(&atlas_mesh, app_state.frame, &app_state.world_map, swallowed, partial);
    }
    for (app_state.entities.falling_blocks.items) |block| {
        try render.entity_render.appendFallingBlock(&atlas_mesh, app_state.frame, &app_state.world_map, block, partial);
    }
    var moving_pistons = app_state.world_map.pistons.iterator();
    while (moving_pistons.next()) |entry| {
        try render.entity_render.appendMovingPiston(
            &atlas_mesh,
            app_state.frame,
            &app_state.world_map,
            app_state.colorizer,
            entry.key_ptr.*,
            entry.value_ptr.*,
            partial,
        );
    }
    const basis = render.entity_render.CameraBasis.fromLook(app_state.player.yaw, app_state.player.pitch);
    var particle_mesh: render.MeshBuilder = .{};
    defer particle_mesh.deinit(app_state.frame);
    var item_particle_mesh: render.MeshBuilder = .{};
    defer item_particle_mesh.deinit(app_state.frame);
    for (app_state.entities.particles.items) |particle| {
        const target = switch (particle.kind) {
            .digging => &atlas_mesh,
            .slime => &item_particle_mesh,
            else => &particle_mesh,
        };
        try render.entity_render.appendParticle(target, app_state.frame, &app_state.world_map, particle, basis, partial);
    }
    drawEntityMesh(&atlas_mesh);
    if (particle_mesh.vertices.items.len > 0) {
        app_state.textures.particles.bind();
        drawEntityMesh(&particle_mesh);
        app_state.textures.terrain.bind();
    }
    if (item_particle_mesh.vertices.items.len > 0) {
        app_state.textures.items.bind();
        drawEntityMesh(&item_particle_mesh);
        app_state.textures.terrain.bind();
    }

    var pig_mesh: render.MeshBuilder = .{};
    defer pig_mesh.deinit(app_state.frame);
    var saddle_mesh: render.MeshBuilder = .{};
    defer saddle_mesh.deinit(app_state.frame);
    var pigs = app_state.entities.of(game.Pig, game.mob.pig);
    while (pigs.next()) |pig| {
        try render.entity_render.appendPig(&pig_mesh, app_state.frame, &app_state.world_map, pig.*, partial);
        if (pig.saddled) {
            try render.entity_render.appendPigSaddle(&saddle_mesh, app_state.frame, &app_state.world_map, pig.*, partial);
        }
    }
    var cow_mesh: render.MeshBuilder = .{};
    defer cow_mesh.deinit(app_state.frame);
    var cows = app_state.entities.of(game.Cow, game.mob.cow);
    while (cows.next()) |cow| {
        try render.entity_render.appendCow(&cow_mesh, app_state.frame, &app_state.world_map, cow.*, partial);
    }
    var chicken_mesh: render.MeshBuilder = .{};
    defer chicken_mesh.deinit(app_state.frame);
    var chickens = app_state.entities.of(game.Chicken, game.mob.chicken);
    while (chickens.next()) |chicken| {
        try render.entity_render.appendChicken(&chicken_mesh, app_state.frame, &app_state.world_map, chicken.*, partial);
    }
    var sheep_mesh: render.MeshBuilder = .{};
    defer sheep_mesh.deinit(app_state.frame);
    var fleece_mesh: render.MeshBuilder = .{};
    defer fleece_mesh.deinit(app_state.frame);
    var flock = app_state.entities.of(game.Sheep, game.mob.sheep);
    while (flock.next()) |sheep| {
        try render.entity_render.appendSheep(&sheep_mesh, app_state.frame, &app_state.world_map, sheep.*, partial);
        if (!sheep.sheared) {
            try render.entity_render.appendSheepFur(&fleece_mesh, app_state.frame, &app_state.world_map, sheep.*, partial);
        }
    }
    var slime_mesh: render.MeshBuilder = .{};
    defer slime_mesh.deinit(app_state.frame);
    var slime_shell_mesh: render.MeshBuilder = .{};
    defer slime_shell_mesh.deinit(app_state.frame);
    var slimes = app_state.entities.of(game.Slime, game.mob.slime);
    while (slimes.next()) |slime| {
        try render.entity_render.appendSlime(&slime_mesh, app_state.frame, &app_state.world_map, slime.*, partial);
        try render.entity_render.appendSlimeShell(&slime_shell_mesh, app_state.frame, &app_state.world_map, slime.*, partial);
    }
    var wolf_mesh: render.MeshBuilder = .{};
    defer wolf_mesh.deinit(app_state.frame);
    var wolf_tame_mesh: render.MeshBuilder = .{};
    defer wolf_tame_mesh.deinit(app_state.frame);
    var wolf_angry_mesh: render.MeshBuilder = .{};
    defer wolf_angry_mesh.deinit(app_state.frame);
    var pack = app_state.entities.of(game.Wolf, game.mob.wolf);
    while (pack.next()) |wolf| {
        const coat = if (wolf.tamed) &wolf_tame_mesh else if (wolf.angry) &wolf_angry_mesh else &wolf_mesh;
        try render.entity_render.appendWolf(coat, app_state.frame, &app_state.world_map, wolf.*, partial);
    }
    var painting_mesh: render.MeshBuilder = .{};
    defer painting_mesh.deinit(app_state.frame);
    for (app_state.entities.paintings.items) |painting| {
        try render.entity_render.appendPainting(&painting_mesh, app_state.frame, &app_state.world_map, painting);
    }
    if (painting_mesh.vertices.items.len > 0) {
        app_state.textures.art.bind();
        drawEntityMesh(&painting_mesh);
        app_state.textures.terrain.bind();
    }

    var arrow_mesh: render.MeshBuilder = .{};
    defer arrow_mesh.deinit(app_state.frame);
    for (app_state.entities.arrows.items) |arrow| {
        try render.entity_render.appendArrow(&arrow_mesh, app_state.frame, &app_state.world_map, arrow, partial);
    }
    if (arrow_mesh.vertices.items.len > 0) {
        app_state.textures.arrows.bind();
        drawEntityMesh(&arrow_mesh);
        app_state.textures.terrain.bind();
    }

    var sign_mesh: render.MeshBuilder = .{};
    defer sign_mesh.deinit(app_state.frame);
    var sign_text_mesh: render.MeshBuilder = .{};
    defer sign_text_mesh.deinit(app_state.frame);
    var signs = app_state.world_map.signs.iterator();
    while (signs.next()) |entry| {
        const pos = entry.key_ptr.*;
        const id = app_state.world_map.getBlock(pos.x, pos.y, pos.z);
        if (!id.isSign()) continue;
        const meta = app_state.world_map.getBlockMetadata(pos.x, pos.y, pos.z);
        try render.sign_render.appendBoard(
            &sign_mesh,
            app_state.frame,
            &app_state.world_map,
            id,
            meta,
            pos.x,
            pos.y,
            pos.z,
        );
        try render.sign_render.appendText(
            &sign_text_mesh,
            app_state.frame,
            app_state.font,
            id,
            meta,
            pos.x,
            pos.y,
            pos.z,
            entry.value_ptr.*,
            null,
        );
    }
    if (sign_mesh.vertices.items.len > 0) {
        app_state.textures.sign.bind();
        drawEntityMesh(&sign_mesh);
        app_state.textures.terrain.bind();
    }
    if (sign_text_mesh.vertices.items.len > 0) {
        app_state.font.bind();
        gl.Disable(gl.CULL_FACE);
        gl.DepthMask(gl.FALSE);
        drawEntityMesh(&sign_text_mesh);
        gl.DepthMask(gl.TRUE);
        gl.Enable(gl.CULL_FACE);
        app_state.textures.terrain.bind();
    }

    var icon_mesh: render.MeshBuilder = .{};
    defer icon_mesh.deinit(app_state.frame);
    for (app_state.entities.items.items) |item| {
        try render.entity_render.appendItemIcon(&icon_mesh, app_state.frame, &app_state.world_map, item, app_state.player.yaw, partial);
    }
    for (app_state.entities.pickups.items) |fx| {
        const swallowed = fx.swallowed(&app_state.player, partial);
        try render.entity_render.appendItemIcon(&icon_mesh, app_state.frame, &app_state.world_map, swallowed, app_state.player.yaw, partial);
    }
    if (icon_mesh.vertices.items.len > 0) {
        app_state.textures.items.bind();
        drawEntityMesh(&icon_mesh);
        app_state.textures.terrain.bind();
    }

    if (pig_mesh.vertices.items.len > 0) {
        app_state.textures.pig.bind();
        drawEntityMesh(&pig_mesh);
        app_state.textures.terrain.bind();
    }

    if (saddle_mesh.vertices.items.len > 0) {
        app_state.textures.saddle.bind();
        drawEntityMesh(&saddle_mesh);
        app_state.textures.terrain.bind();
    }

    if (sheep_mesh.vertices.items.len > 0) {
        app_state.textures.sheep.bind();
        drawEntityMesh(&sheep_mesh);
        app_state.textures.terrain.bind();
    }

    if (fleece_mesh.vertices.items.len > 0) {
        app_state.textures.sheep_fur.bind();
        drawEntityMesh(&fleece_mesh);
        app_state.textures.terrain.bind();
    }

    if (cow_mesh.vertices.items.len > 0) {
        app_state.textures.cow.bind();
        drawEntityMesh(&cow_mesh);
        app_state.textures.terrain.bind();
    }

    if (chicken_mesh.vertices.items.len > 0) {
        app_state.textures.chicken.bind();
        drawEntityMesh(&chicken_mesh);
        app_state.textures.terrain.bind();
    }

    inline for (.{
        .{ &wolf_mesh, "wolf" },
        .{ &wolf_tame_mesh, "wolf_tame" },
        .{ &wolf_angry_mesh, "wolf_angry" },
    }) |coat| {
        if (coat[0].vertices.items.len > 0) {
            @field(app_state.textures, coat[1]).bind();
            drawEntityMesh(coat[0]);
            app_state.textures.terrain.bind();
        }
    }

    if (slime_mesh.vertices.items.len > 0) {
        app_state.textures.slime.bind();
        drawEntityMesh(&slime_mesh);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        drawEntityMesh(&slime_shell_mesh);
        gl.Disable(gl.BLEND);
        app_state.textures.terrain.bind();
    }

    if (app_state.third_person) try drawPlayer(app_state, partial);

    try drawSelectionOutline(app_state);
    try drawBreakingCrack(app_state);

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.Disable(gl.CULL_FACE);
    app_state.shader.setInt("u_alpha_test", 0);
    try app_state.chunks.drawTranslucent(app_state.frame, frustum, eye.x, eye.z);
    app_state.shader.setInt("u_alpha_test", 1);
    gl.Disable(gl.BLEND);

    try drawClouds(app_state, proj, partial);
    if (!app_state.third_person) {
        try drawHeldItem(app_state, proj, partial);
        if (app_state.player.fire > 0) try drawFireOverlay(app_state, proj);
    }
}

fn drawFireOverlay(app_state: *AppState, proj: math.Mat4) !void {
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    app_state.shader.setInt("u_fog_enabled", 0);
    app_state.shader.setInt("u_alpha_test", 0);
    app_state.shader.setInt("u_textured", 1);
    app_state.shader.setVec4("u_tint", .{ 1, 1, 1, 1 });
    app_state.shader.setVec3("u_camera_pos", .{ 0, 0, 0 });
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.shader.setInt("u_atlas", 0);
    app_state.textures.terrain.bind();

    for (0..render.held_item.fire_quads) |quad| {
        var mesh: render.MeshBuilder = .{};
        defer mesh.deinit(app_state.frame);

        const tile: u8 = render.TextureFx.fire_tile + @as(u8, @intCast(quad)) * render.Atlas.tiles_per_row;
        try render.held_item.appendFire(&mesh, app_state.frame, tile);
        app_state.shader.setMat4("u_view_proj", proj.mul(render.held_item.fireMatrix(quad)).m);

        var gpu = render.GpuMesh.upload(&mesh);
        defer gpu.deinit();
        gpu.draw();
    }

    app_state.shader.setInt("u_alpha_test", 1);
    gl.Disable(gl.BLEND);
}

fn drawPlayer(app_state: *AppState, partial: f32) !void {
    const player = app_state.player;
    const holding_item = player.inventory.selectedStack() != null;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    try render.entity_render.appendPlayer(&mesh, app_state.frame, &app_state.world_map, player, holding_item, partial);
    app_state.textures.char.bind();
    drawEntityMesh(&mesh);

    for (player.inventory.armor) |stack| {
        const worn = stack orelse continue;
        if (worn.id != .item) continue;
        const piece = worn.id.item.armor() orelse continue;
        const layer = render.mob_model.bipedArmor(piece.slot);

        var armor_mesh: render.MeshBuilder = .{};
        defer armor_mesh.deinit(app_state.frame);
        try render.entity_render.appendPlayerArmor(&armor_mesh, app_state.frame, &app_state.world_map, player, holding_item, partial, layer);
        app_state.textures.armor(piece.material, layer.second_texture).bind();
        drawEntityMesh(&armor_mesh);
    }

    app_state.textures.terrain.bind();
}

fn drawHeldItem(app_state: *AppState, proj: math.Mat4, partial: f32) !void {
    const feet = app_state.player.base.position;
    const brightness = world.light.brightnessAt(
        &app_state.world_map,
        math.util.floorDouble(feet.x),
        math.util.floorDouble(feet.y),
        math.util.floorDouble(feet.z),
        0,
    );

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);

    const bob = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial)
    else
        math.Mat4.identity;
    const swing = app_state.player.swingProgress(partial);
    const equipped = app_state.equip.interpolated(partial);
    const shape = render.held_item.heldShape(app_state.equip.shown);

    var transform = proj.mul(app_state.player.hurtMatrix(partial)).mul(bob);
    if (shape) |held| {
        transform = transform.mul(render.held_item.handMatrix(swing, equipped));
        switch (held) {
            .cube => |id| try render.held_item.appendBlock(&mesh, app_state.frame, id, brightness),
            .sprite => |sprite| {
                try render.held_item.appendSprite(&mesh, app_state.frame, sprite.tile, brightness);
                transform = transform.mul(render.held_item.spriteMatrix());
            },
        }
    } else {
        transform = transform.mul(render.held_item.armMatrix(swing, equipped));
        try render.held_item.appendArm(&mesh, app_state.frame, brightness);
    }

    gl.Clear(gl.DEPTH_BUFFER_BIT);
    app_state.shader.setMat4("u_view_proj", transform.m);
    app_state.shader.setVec3("u_camera_pos", .{ 0, 0, 0 });
    app_state.shader.setInt("u_fog_enabled", 0);
    app_state.shader.setInt("u_alpha_test", 1);
    app_state.shader.setInt("u_textured", 1);
    app_state.shader.setVec4("u_tint", .{ 1, 1, 1, 1 });
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.shader.setInt("u_atlas", 0);
    if (shape) |held| switch (held) {
        .cube => app_state.textures.terrain.bind(),
        .sprite => |sprite| switch (sprite.atlas) {
            .terrain => app_state.textures.terrain.bind(),
            .items => app_state.textures.items.bind(),
        },
    } else {
        app_state.textures.char.bind();
    }

    var gpu = render.GpuMesh.upload(&mesh);
    defer gpu.deinit();
    gpu.draw();
    app_state.textures.terrain.bind();
}

fn drawClouds(app_state: *AppState, proj: math.Mat4, partial: f32) !void {
    const angle = app_state.world_map.celestialAngle(partial);
    const eye = app_state.player.base.renderPosition(partial);
    const hurt = app_state.player.hurtMatrix(partial);
    const rotation = if (app_state.settings.view_bobbing)
        hurt.mul(app_state.player.bobMatrix(partial)).mul(app_state.player.viewRotation())
    else
        hurt.mul(app_state.player.viewRotation());

    const ticks: f64 = @floatFromInt(app_state.cloud_offset);
    try render.SkyRenderer.drawClouds(.{
        .shader = app_state.shader,
        .textures = app_state.textures,
        .gpa = app_state.frame,
        .view_proj = proj.mul(rotation),
        .eye = .{ eye.x, eye.y + game.Player.eye_height, eye.z },
        .scroll = (ticks + partial) * render.sky.cloud_scroll_per_tick,
        .color = render.sky.cloudColor(angle),
    }, app_state.settings.fancy_graphics);
}

fn drawSky(app_state: *AppState, proj: math.Mat4, partial: f32, horizon: render.sky.Color) !void {
    const render_distance = @intFromEnum(app_state.settings.render_distance);
    if (!render.SkyRenderer.visibleAt(render_distance)) return;

    const angle = app_state.world_map.celestialAngle(partial);
    const temperature: f32 = @floatCast(app_state.generator.climate.temperatureAt(
        math.util.floorDouble(app_state.player.base.position.x),
        math.util.floorDouble(app_state.player.base.position.z),
    ));
    const hurt = app_state.player.hurtMatrix(partial);
    const rotation = if (app_state.settings.view_bobbing)
        hurt.mul(app_state.player.bobMatrix(partial)).mul(app_state.player.viewRotation())
    else
        hurt.mul(app_state.player.viewRotation());

    try app_state.sky.draw(.{
        .shader = app_state.shader,
        .textures = app_state.textures,
        .gpa = app_state.frame,
        .projection = proj,
        .view_rotation = rotation,
        .celestial_angle = angle,
        .sky_color = render.sky.skyColor(temperature, angle),
        .fog_color = horizon,
        .far_plane_distance = render.sky.farPlaneDistance(render_distance),
        .fog_density = cameraFogDensity(app_state),
    });
}

fn drawBreakingCrack(app_state: *AppState) !void {
    const digging = app_state.digging orelse return;
    if (digging.progress <= 0.0) return;

    const id = app_state.world_map.getBlock(digging.x, digging.y, digging.z);
    if (id == .air) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    try render.selection.appendCrack(
        &mesh,
        app_state.frame,
        &app_state.world_map,
        app_state.colorizer,
        id,
        app_state.world_map.getBlockMetadata(digging.x, digging.y, digging.z),
        digging.x,
        digging.y,
        digging.z,
        digging.progress,
    );

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.DST_COLOR, gl.SRC_COLOR);
    gl.PolygonOffset(-3.0, -3.0);
    gl.Enable(gl.POLYGON_OFFSET_FILL);

    var gpu = render.GpuMesh.upload(&mesh);
    defer gpu.deinit();
    gpu.draw();

    gl.Disable(gl.POLYGON_OFFSET_FILL);
    gl.PolygonOffset(0.0, 0.0);
    gl.Disable(gl.BLEND);
}

fn drawSelectionOutline(app_state: *AppState) !void {
    const hit = game.raycast.cast(
        &app_state.world_map,
        app_state.player.eyePosition(),
        app_state.player.lookVector(),
        reach_distance,
    ) orelse return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    const id = app_state.world_map.getBlock(hit.x, hit.y, hit.z);
    try render.selection.appendOutline(&mesh, app_state.frame, id, app_state.world_map.getBlockMetadata(hit.x, hit.y, hit.z), hit.x, hit.y, hit.z);

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.DepthMask(gl.FALSE);
    gl.LineWidth(2.0);
    app_state.shader.setInt("u_textured", 0);
    app_state.shader.setInt("u_alpha_test", 0);

    var gpu = render.GpuMesh.uploadLines(&mesh);
    defer gpu.deinit();
    gpu.draw();

    app_state.shader.setInt("u_alpha_test", 1);
    app_state.shader.setInt("u_textured", 1);
    gl.LineWidth(1.0);
    gl.DepthMask(gl.TRUE);
    gl.Disable(gl.BLEND);
}

pub fn iterate(
    app_state: *AppState,
) !sdl3.AppResult {
    gl.makeProcTableCurrent(&app_state.gl_procs);
    _ = frame_arena.reset(.retain_capacity);
    const px = drawableSize(app_state);
    gl.Viewport(0, 0, px.w, px.h);
    const gui = guiSize(app_state);

    app_state.fps_capper.mode = if (app_state.settings.framerate_limit.fpsCap(refreshRate(app_state))) |cap|
        .{ .limited = cap }
    else
        .{ .unlimited = {} };
    const dt = app_state.fps_capper.delay();
    _ = dt;

    if (sdl3.timer.getMillisecondsSinceInit() < app_state.mojang_until_ms) {
        try render.mojang_screen.draw(uiContext(app_state, gui));
        try sdl3.video.gl.swapWindow(app_state.window);
        return .run;
    }

    app_state.frames_this_second += 1;
    const now_ms = sdl3.timer.getMillisecondsSinceInit();
    if (now_ms -% app_state.debug_latched_ms >= 1000) {
        app_state.debug_fps = app_state.frames_this_second;
        app_state.debug_chunk_updates = app_state.chunk_updates_this_second;
        app_state.frames_this_second = 0;
        app_state.chunk_updates_this_second = 0;
        app_state.debug_latched_ms = now_ms;
    }

    const world_ticking = app_state.screen == .playing and !app_state.paused;
    if (world_ticking) {
        app_state.timer.advance(sdl3.timer.getNanosecondsSinceInit());
    } else {
        app_state.timer.advanceHoldingPartial(sdl3.timer.getNanosecondsSinceInit());
    }

    if (world_ticking) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| {
            try tick(app_state);
        }
    } else if (app_state.screen == .create_world) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| app_state.create_state.tick();
    } else if (app_state.screen == .multiplayer) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| app_state.multiplayer_state.tick();
    } else if (app_state.screen == .playing and app_state.paused) {
        app_state.pause_ticks +|= @intCast(app_state.timer.elapsed_ticks);
        try stepPauseSave(app_state);
    }

    if (!app_state.paused and app_state.timer.elapsed_ticks > 0) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| app_state.texture_fx.tick(compassAngle(app_state), clockAngle(app_state));
        app_state.texture_fx.upload(app_state.textures.terrain, app_state.textures.items);
    }

    if (app_state.screen == .loading) try stepLoading(app_state);

    const horizon = horizonColor(app_state);
    gl.Enable(gl.DEPTH_TEST);
    gl.ClearColor(horizon[0], horizon[1], horizon[2], 1.0);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    if (app_state.third_person and app_state.player.isInsideOpaqueBlock(&app_state.world_map)) {
        app_state.third_person = false;
    }

    if (app_state.screen == .playing) try renderWorld(app_state, horizon);
    app_state.frame_end_ns = sdl3.timer.getNanosecondsSinceInit();

    const ui = uiContext(app_state, gui);
    const backdrop: render.options_screen.Backdrop = if (app_state.options_parent == .pause) .veil else .dirt;

    if (app_state.screen == .playing) {
        if (cameraSubmerged(app_state)) {
            const sample = app_state.player.base.lightSamplePosition();
            try render.underwater.draw(
                app_state.frame,
                app_state.shader,
                app_state.textures.water,
                app_state.player.yaw,
                app_state.player.pitch,
                world.light.brightnessAt(&app_state.world_map, sample[0], sample[1], sample[2], 0),
            );
        }
        try render.hud.draw(ui, app_state.player.inventory, app_state.player, cameraSubmerged(app_state), @truncate(@as(i64, @bitCast(app_state.tick_count))));
        if (app_state.show_debug) try render.debug_overlay.draw(ui, debugStats(app_state));
        try render.chat.draw(ui, &app_state.chat);
    }

    if (app_state.controls_open) {
        try render.controls_screen.draw(ui, app_state.settings, backdrop, app_state.rebinding);
    } else if (app_state.video_open) {
        try render.video_settings_screen.draw(ui, app_state.settings, backdrop);
    } else if (app_state.options_open) {
        try render.options_screen.draw(ui, app_state.settings, backdrop);
    } else if (app_state.stats_open) {
        const view = &app_state.stats_view;
        view.scroll.set(view.tab, render.stats_screen.clampScroll(gui, view.*, view.scrollOf()));
        try render.stats_screen.draw(ui, view.*, &app_state.stats);
    } else if (app_state.screen == .title) {
        try render.title_screen.draw(ui, app_state.splash, sdl3.timer.getMillisecondsSinceInit());
    } else if (app_state.screen == .select_world) {
        app_state.list_scroll = render.select_world_screen.clampScroll(gui, app_state.summaries.len, app_state.list_scroll);
        try render.select_world_screen.draw(ui, app_state.summaries, app_state.selected_world, app_state.list_scroll);
    } else if (app_state.screen == .create_world) {
        try render.create_world_screen.draw(ui, &app_state.create_state);
    } else if (app_state.screen == .multiplayer) {
        try render.multiplayer_screen.draw(ui, &app_state.multiplayer_state);
    } else if (app_state.screen == .texture_packs) {
        app_state.pack_scroll = render.texture_packs_screen.clampScroll(gui, app_state.packs.len, app_state.pack_scroll);
        try render.texture_packs_screen.draw(
            ui,
            app_state.packs,
            app_state.pack_thumbnails,
            render.texture_pack.indexOf(app_state.packs, app_state.selected_pack.text()),
            app_state.pack_scroll,
        );
    } else if (app_state.screen == .confirm_delete) {
        var message: [96]u8 = undefined;
        const name = if (app_state.selected_world) |index| app_state.summaries[index].name else "";
        const line = std.fmt.bufPrint(&message, "'{s}' will be lost forever! (A long time!)", .{name}) catch "This world will be lost forever! (A long time!)";
        try render.confirm_screen.draw(ui, "Are you sure you want to delete this world?", line, "Delete");
    } else if (app_state.screen == .loading) {
        const total = app_state.loading.total;
        const progress: i32 = if (total == 0) 0 else @intCast(app_state.loading.done * 100 / total);
        try render.loading_screen.draw(ui, app_state.loading.title, "Building terrain", progress);
    } else if (app_state.dead) {
        try render.death_screen.draw(ui);
    } else if (app_state.paused) {
        try render.menu.draw(ui, app_state.pause_saving, app_state.pause_ticks, app_state.timer.render_partial_ticks);
    } else if (openedFurnace(app_state)) |furnace| {
        try render.furnace_screen.draw(
            ui,
            app_state.player.inventory,
            furnace.*,
            app_state.held_stack,
        );
    } else if (app_state.workbench_open) {
        try render.crafting_screen.draw(
            ui,
            app_state.player.inventory,
            app_state.workbench_grid,
            app_state.held_stack,
        );
    } else if (app_state.sign_edit) |open| {
        const id = app_state.world_map.getBlock(open.x, open.y, open.z);
        const meta = app_state.world_map.getBlockMetadata(open.x, open.y, open.z);
        const state = app_state.world_map.signAt(open.x, open.y, open.z);
        try render.edit_sign_screen.draw(ui, open, id, meta, if (state) |value| value.* else .{});
    } else if (app_state.inventory_open) {
        try render.inventory_screen.draw(
            ui,
            render.mob_model.biped,
            app_state.player.inventory,
            app_state.crafting_grid,
            app_state.held_stack,
        );
    }

    try sdl3.video.gl.swapWindow(app_state.window);

    return .run;
}

fn boundTo(app_state: *const AppState, binding: game.Settings.Binding, key: ?sdl3.keycode.Keycode) bool {
    return app_state.settings.keys.get(binding) == @intFromEnum(key orelse return false);
}

fn setKeyState(app_state: *AppState, key: ?sdl3.keycode.Keycode, down: bool) void {
    if (boundTo(app_state, .forward, key)) app_state.keys.forward = down;
    if (boundTo(app_state, .back, key)) app_state.keys.back = down;
    if (boundTo(app_state, .left, key)) app_state.keys.left = down;
    if (boundTo(app_state, .right, key)) app_state.keys.right = down;
    if (boundTo(app_state, .jump, key)) app_state.keys.jump = down;
    if (boundTo(app_state, .sneak, key)) app_state.keys.sneak = down;
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
        .key_down => |k| if (app_state.controls_open) {
            if (app_state.rebinding) |binding| {
                if (k.key) |key| {
                    app_state.settings.keys.set(binding, @intFromEnum(key));
                    app_state.rebinding = null;
                }
            } else if (k.key == .escape) {
                app_state.controls_open = false;
            }
        } else if (app_state.video_open) {
            if (k.key == .escape) app_state.video_open = false;
        } else if (app_state.options_open) {
            if (k.key == .escape) try closeOptions(app_state);
        } else if (app_state.stats_open) {
            if (k.key == .escape) {
                closeStats(app_state);
                try togglePause(app_state);
            }
        } else if (app_state.screen == .select_world) {
            if (k.key == .escape) {
                app_state.screen = .title;
            }
        } else if (app_state.screen == .create_world) {
            if (k.key == .escape) {
                try sdl3.keyboard.stopTextInput(app_state.window);
                try openSelectWorld(app_state);
            } else if (k.key == .backspace) {
                app_state.create_state.backspace();
                updateCreateFolder(app_state);
            } else if (k.key == .tab) {
                app_state.create_state.focus(if (app_state.create_state.name.focused) .seed_field else .name_field);
            } else if (k.key == .return_key or k.key == .kp_enter) {
                try confirmCreateWorld(app_state);
            }
        } else if (app_state.screen == .multiplayer) {
            if (k.key == .escape) {
                try closeMultiplayer(app_state);
            } else if (k.key == .backspace) {
                app_state.multiplayer_state.backspace();
            } else if (k.key == .return_key or k.key == .kp_enter) {
                try connectToServer(app_state);
            }
        } else if (app_state.screen == .texture_packs) {
            if (k.key == .escape) {
                freeTexturePacks(app_state);
                app_state.screen = .title;
                try updateMouseMode(app_state);
            }
        } else if (app_state.screen == .confirm_delete) {
            if (k.key == .escape) app_state.screen = .select_world;
        } else if (app_state.sign_edit != null) {
            if (k.key == .up) {
                app_state.sign_edit.?.previousLine();
            } else if (k.key == .down or k.key == .return_key or k.key == .kp_enter) {
                app_state.sign_edit.?.nextLine();
            } else if (k.key == .backspace) {
                if (editedSign(app_state)) |state| state.backspace(app_state.sign_edit.?.line);
            }
        } else if (app_state.screen == .playing) {
            if (app_state.dead) {
                // the game over screen swallows keys until a button is clicked
            } else if (app_state.chat.open) {
                if (k.key == .escape) {
                    try closeChat(app_state);
                } else if (k.key == .return_key or k.key == .kp_enter) {
                    try sendChat(app_state);
                } else if (k.key == .backspace) {
                    app_state.chat.backspace();
                }
            } else if (k.key == .escape) {
                if (containerOpen(app_state)) {
                    try closeContainer(app_state);
                } else {
                    try togglePause(app_state);
                }
            } else if (k.key == .func3) {
                app_state.show_debug = !app_state.show_debug;
            } else if (k.key == .func5 and !k.repeat) {
                app_state.third_person = !app_state.third_person;
            } else if (boundTo(app_state, .inventory, k.key) and !app_state.paused) {
                try toggleInventory(app_state);
            } else if (boundTo(app_state, .drop, k.key) and worldFocused(app_state) and !k.repeat) {
                try dropSelectedItem(app_state);
            } else if (boundTo(app_state, .chat, k.key) and worldFocused(app_state) and !k.repeat) {
                try openChat(app_state);
            } else {
                setKeyState(app_state, k.key, true);
                selectHotbarFromKey(app_state, k.key);
            }
        },
        .key_up => |k| setKeyState(app_state, k.key, false),
        .mouse_motion => |m| {
            app_state.mouse_x = m.x;
            app_state.mouse_y = m.y;
            if (app_state.dragging_scrollbar) {
                dragScrollbar(app_state, m.y_rel);
            } else if (app_state.dragging_slider) |s| {
                const gui = guiSize(app_state);
                setSlider(app_state, s, render.options_screen.sliderValueAt(s, m.x, gui));
            } else if (worldFocused(app_state)) {
                app_state.player.turn(m.x_rel, m.y_rel, app_state.settings.sensitivity, app_state.settings.invert_mouse);
            }
        },
        .mouse_wheel => |w| if (worldFocused(app_state)) {
            app_state.player.inventory.cycleHotbar(if (w.scroll_y > 0) 1 else if (w.scroll_y < 0) -1 else 0);
        } else if (app_state.stats_open) {
            const view = &app_state.stats_view;
            const step = render.stats_screen.scrollStep(view.tab);
            view.scroll.set(view.tab, render.stats_screen.clampScroll(guiSize(app_state), view.*, view.scrollOf() - w.scroll_y * step));
        } else if (app_state.screen == .select_world) {
            const step = w.scroll_y * render.select_world_screen.entry_height;
            app_state.list_scroll = render.select_world_screen.clampScroll(guiSize(app_state), app_state.summaries.len, app_state.list_scroll - step);
        } else if (app_state.screen == .texture_packs) {
            const step = w.scroll_y * render.texture_packs_screen.entry_height;
            app_state.pack_scroll = render.texture_packs_screen.clampScroll(guiSize(app_state), app_state.packs.len, app_state.pack_scroll - step);
        },
        .text_input => |t| if (app_state.sign_edit) |open| {
            if (editedSign(app_state)) |state| {
                for (t.text) |c| {
                    if (!render.chat.isAllowed(c)) continue;
                    state.append(open.line, c);
                }
            }
        } else if (app_state.screen == .create_world) {
            app_state.create_state.typeText(t.text);
            updateCreateFolder(app_state);
        } else if (app_state.screen == .multiplayer) {
            app_state.multiplayer_state.typeText(t.text);
        } else if (app_state.chat.open) {
            app_state.chat.typeText(t.text);
        },
        .mouse_button_down => |m| switch (m.button) {
            .left => if (app_state.controls_open) {
                controlsClick(app_state);
            } else if (app_state.video_open) {
                try videoClick(app_state);
            } else if (app_state.options_open) {
                try optionsClick(app_state);
            } else if (app_state.stats_open) {
                try statsClick(app_state);
            } else if (app_state.screen == .title) {
                const gui = guiSize(app_state);
                if (render.title_screen.actionAt(app_state.mouse_x, app_state.mouse_y, gui)) |action| switch (action) {
                    .singleplayer => try openSelectWorld(app_state),
                    .multiplayer => try openMultiplayer(app_state),
                    .texture_packs => try openTexturePacks(app_state),
                    .options => try openOptions(app_state, .title),
                    .quit => return .success,
                };
            } else if (app_state.screen == .select_world) {
                try selectWorldClick(app_state);
            } else if (app_state.screen == .create_world) {
                try createWorldClick(app_state);
            } else if (app_state.screen == .multiplayer) {
                try multiplayerClick(app_state);
            } else if (app_state.screen == .texture_packs) {
                try texturePacksClick(app_state);
            } else if (app_state.screen == .confirm_delete) {
                try confirmDeleteClick(app_state);
            } else if (app_state.screen == .loading) {
                // the loading screen swallows clicks until the spawn area is ready
            } else if (app_state.dead) {
                try deathScreenClick(app_state);
            } else if (app_state.paused) {
                try pauseMenuClick(app_state);
            } else if (app_state.chat.open) {} else if (app_state.sign_edit != null) {
                if (render.edit_sign_screen.hitAt(app_state.mouse_x, app_state.mouse_y, guiSize(app_state))) |hit| switch (hit) {
                    .done => try closeSignEditor(app_state),
                };
            } else if (containerOpen(app_state)) {
                try openContainerClickAt(app_state, .left);
            } else {
                app_state.mouse_left_down = true;
                app_state.last_held_swing_tick = app_state.tick_count;
                try clickLeft(app_state);
            },
            .right => if (app_state.controls_open or app_state.video_open or app_state.options_open or app_state.stats_open or app_state.screen == .title or app_state.paused or app_state.dead or app_state.chat.open) {} else if (containerOpen(app_state)) {
                try openContainerClickAt(app_state, .right);
            } else {
                if (try useBlockOrPlace(app_state)) {
                    app_state.player.swingItem();
                } else {
                    try useHeldItem(app_state);
                }
            },
            else => {},
        },
        .mouse_button_up => |m| switch (m.button) {
            .left => {
                app_state.mouse_left_down = false;
                app_state.missed_click_cooldown = 0;
                app_state.dragging_slider = null;
                app_state.dragging_scrollbar = false;
                app_state.stats_view.pressed = null;
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
        game.stats_file.save(state.gpa, state.io, state.base_dir, game.stats_file.default_username, &state.stats) catch {};
        state.stats_view.deinit(state.gpa);
        state.stats.deinit(state.gpa);
        if (state.save_handle != null) saveWorld(state) catch {};
        persist();
        if (state.save_handle) |*handle| handle.close(state.gpa, state.io);
        world.save.freeList(state.gpa, state.summaries);
        freeTexturePacks(state);
        state.saves_dir.close(state.io);
        state.packs_dir.close(state.io);
        state.base_dir.close(state.io);
        state.chunks.deinit(state.gpa);
        state.entities.deinit(state.gpa);
        state.world_map.deinit();
        state.generator.deinit(state.gpa);
        state.sky.deinit();
        state.colorizer.deinit(state.gpa);
        state.shader.deinit();
        state.textures.deinit();
        state.font.deinit();
        state.gl_context.deinit() catch {};
        state.window.deinit();
        frame_arena.deinit();
    }
    sdl3.quit(init_flags);
    sdl3.shutdown();
    if (builtin.mode == .Debug and !wasm) _ = debug_allocator.deinit();
}
