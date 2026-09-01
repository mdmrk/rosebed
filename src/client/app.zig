const std = @import("std");
const builtin = @import("builtin");

const assets = @import("assets");
const font_png = assets.font.default_png.bytes;
const audio = @import("audio");
const core = @import("core");
const Timer = core.Timer;
const game = @import("game");
const gl = @import("gl");
const math = @import("math");
const net = @import("net");
const remote = @import("remote");
const render = @import("render");
const sdl3 = @import("sdl3");
const world = @import("world");

const Link = @import("Link.zig");

const ticks_per_second = 20.0;
const screen_width = 854;
const screen_height = 480;
const init_flags = sdl3.InitFlags{ .video = true, .audio = true };
const fov_y_radians = 70.0 * std.math.pi / 180.0;
const near_plane = 0.05;
const far_plane = 1000.0;
const reach_distance = 4.5;
const boat_reach = 5.0;
const bucket_reach = 5.0;
const chunk_load_budget_ns = 8 * std.time.ns_per_ms;
const chunk_stream_budget_ns = 4 * std.time.ns_per_ms;
const spawn_position = math.Vec3.init(8, 90, 8);
const wasm = builtin.cpu.arch.isWasm();
const android = builtin.abi == .android or builtin.abi == .androideabi;
const gles = wasm or android;
const touch_ui = android;
const touch_dig_delay_ms = 180;
const touch_drag_slop = 12.0;
const max_touches = 4;

const splashes: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const []const u8 = &.{};
    var it = std.mem.tokenizeAny(u8, assets.title.splashes_txt.bytes, "\r\n");
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

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var frame_arena: std.heap.ArenaAllocator = undefined;
var io_threaded: std.Io.Threaded = undefined;

const Touch = struct {
    id: u64 = 0,
    role: Role = .none,
    control: render.touch.Control = .move,
    still_since_ms: u64 = 0,
    travel: f32 = 0,
    digging: bool = false,

    const Role = enum { none, move, button, world };
};

pub const AppState = struct {
    gpa: std.mem.Allocator,
    frame: std.mem.Allocator,
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    gl_context: sdl3.video.gl.Context,
    gl_procs: gl.ProcTable,
    textures: render.Textures,
    map_surface: render.map_render.Surface,
    texture_fx: render.TextureFx,
    sound: ?audio.Manager = null,
    colorizer: render.Colorizer,
    sky: render.SkyRenderer,
    font: render.Font,
    shader: render.Shader,
    level: game.Level,
    chunks: render.ChunkRenderer = .{},
    timer: Timer,
    frame_started_ns: u64 = 0,
    chunk_stream_deadline_ns: u64 = 0,
    chunk_stream_cost_ns: u64 = 0,
    chunk_streamed_this_frame: bool = false,
    cloud_offset: u64 = 0,
    fog_brightness: f32 = 0,
    prev_fog_brightness: f32 = 0,
    chunks_drawn: u32 = 0,
    equip: render.held_item.Equip = .{},
    player: game.Player = playerAtSpawn(),
    touches: [max_touches]Touch = @splat(.{}),
    touch_stick: ?[2]f32 = null,
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
    github_icon: ?render.Atlas = null,
    touch_atlas: ?render.Atlas = null,
    mojang_until_ms: u64 = 0,
    inventory_open: bool = false,
    sign_edit: ?render.screen.edit_sign.State = null,
    workbench_open: bool = false,
    furnace_open: ?world.World.BlockPos = null,
    chest_open: ?world.World.BlockPos = null,
    dispenser_open: ?world.World.BlockPos = null,
    minecart_open: game.Entity.Id = game.Entity.no_id,
    paused: bool = false,
    dead: bool = false,
    options_open: bool = false,
    video_open: bool = false,
    controls_open: bool = false,
    rebinding: ?game.Settings.Binding = null,
    show_debug: bool = false,
    debug_graph: render.debug_graph.Samples = .{},
    anaglyph_pass: render.anaglyph.Pass = null,
    third_person: bool = false,
    freecam: game.Freecam = .{},
    frames_this_second: u32 = 0,
    chunk_updates_this_second: u32 = 0,
    debug_fps: u32 = 0,
    debug_chunk_updates: u32 = 0,
    debug_latched_ms: u64 = 0,
    options_parent: OptionsParent = .title,
    dragging_slider: ?render.screen.options.Slider = null,
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
    pack_scroll: f32 = 0,
    save_handle: ?world.save.Save = null,
    open_folder: NameBuffer = .{},
    open_name: NameBuffer = .{},
    summaries: []world.save.Summary = &.{},
    selected_world: ?usize = null,
    last_list_click_ms: u64 = 0,
    list_scroll: f32 = 0,
    create_state: render.screen.create_world.State = undefined,
    multiplayer_state: render.screen.multiplayer.State = undefined,
    loading: Loading = .{},
    dimension: world.Dimension = .overworld,
    needs_spawn: bool = false,
    pending_portal: bool = false,
    ticks_since_save: u32 = 0,
    rain_sound_ticks: u32 = 0,
    pause_save_frames: u32 = 0,
    pause_ticks: u32 = 0,
    pause_saving: bool = false,
    link: ?*Link = null,
    stats: game.stats.Stats = .{},
    stats_open: bool = false,
    achievements_open: bool = false,
    achievements_view: render.screen.achievements.State = .{},
    achievements_grabbing: bool = false,
    achievement_toast: render.achievement_toast.State = .{},
    stats_view: render.screen.stats.State = .{},
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
    center: [2]i32 = .{ 0, 0 },
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
    sound_ticks: u32 = 0,
};

fn playerAtSpawn() game.Player {
    var player = game.Player.spawn(spawn_position);
    player.inventory = starterInventory();
    return player;
}

fn starterInventory() game.Inventory {
    const inv: game.Inventory = .{};
    // inv.slots[0] = .{ .id = .{ .block = .stone }, .count = 64 };
    // inv.slots[1] = .{ .id = .{ .item = .coal }, .count = 64 };
    // inv.slots[2] = .{ .id = .{ .block = .cobblestone }, .count = 64 };
    // inv.slots[3] = .{ .id = .{ .item = .stick }, .count = 64 };
    // inv.slots[4] = .{ .id = .{ .block = .workbench }, .count = 64 };
    // inv.slots[5] = .{ .id = .{ .block = .log }, .count = 64 };
    // inv.slots[6] = .{ .id = .{ .item = .ingot_iron }, .count = 64 };
    return inv;
}

fn debugStats(app_state: *const AppState) render.debug_overlay.Stats {
    const loaded: u32 = @intCast(app_state.chunks.loadedCount());
    const entities: u32 = @intCast(app_state.level.entities.count());
    const memory = core.process.sample();
    return .{
        .fps = app_state.debug_fps,
        .chunk_updates = app_state.debug_chunk_updates,
        .renderers_rendered = app_state.chunks_drawn,
        .renderers_loaded = loaded,
        .entities_rendered = entities,
        .entities_total = entities,
        .particles = @intCast(app_state.level.entities.particles.items.len + app_state.level.entities.pickups.items.len),
        .chunk_cache = @intCast(app_state.level.world_map.chunks.count()),
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
    const centre = if (app_state.freecam.active)
        app_state.freecam.position
    else
        app_state.player.base.position;
    const x: i32 = @intFromFloat(@floor(centre.x));
    const z: i32 = @intFromFloat(@floor(centre.z));
    return .{
        .x = @divFloor(x, world.Chunk.width),
        .z = @divFloor(z, world.Chunk.width),
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
            if (app_state.level.world_map.isDecorated(cx, cz)) {
                if (!app_state.chunks.hasMesh(cx, cz) and neighborhoodDecorated(&app_state.level.world_map, cx, cz)) {
                    try app_state.chunks.markDirty(app_state.gpa, cx, cz);
                }
                continue;
            }
            if (app_state.link != null) continue;
            const dx: i64 = cx - center.x;
            const dz: i64 = cz - center.z;
            try pending.append(app_state.frame, .{
                .coord = .{ .x = cx, .z = cz },
                .distance = dx * dx + dz * dz,
            });
        }
    }

    std.mem.sort(Pending, pending.items, {}, Pending.nearestFirst);

    for (pending.items) |entry| {
        while (true) {
            const started = sdl3.timer.getNanosecondsSinceInit();
            if (app_state.chunk_streamed_this_frame and
                started +% app_state.chunk_stream_cost_ns > app_state.chunk_stream_deadline_ns) return;

            const step = try app_state.level.world_map.stepDecorate(
                &app_state.level.generator,
                entry.coord.x,
                entry.coord.z,
            );

            app_state.chunk_stream_cost_ns = sdl3.timer.getNanosecondsSinceInit() -% started;
            app_state.chunk_streamed_this_frame = true;
            if (step != .generated) break;
        }
        try markMeshableAround(app_state, entry.coord);
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
            if (app_state.chunks.hasMesh(cx, cz) or neighborhoodDecorated(&app_state.level.world_map, cx, cz)) {
                try app_state.chunks.markDirty(app_state.gpa, cx, cz);
            }
        }
    }
}

const persist_root = "/rosebed";
const repository_url = "https://github.com/mdmrk/rosebed";

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

fn internalStoragePath() ![:0]const u8 {
    const path = sdl3.c.SDL_GetAndroidInternalStoragePath() orelse return error.NoInternalStorage;
    return std.mem.span(path);
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

    if (android) try sdl3.hints.set(.orientations, "LandscapeLeft LandscapeRight");
    if (android) try sdl3.hints.set(.android_trap_back_button, "1");

    try sdl3.video.gl.setAttribute(.depth_size, 24);
    try sdl3.video.gl.setAttribute(.context_major_version, 3);
    try sdl3.video.gl.setAttribute(.context_minor_version, if (gles) 0 else 3);
    try sdl3.video.gl.setAttribute(.context_profile_mask, @intFromEnum(
        if (gles) sdl3.video.gl.Profile.es else sdl3.video.gl.Profile.core,
    ));

    const window = try sdl3.video.Window.init("Rosebed", screen_width, screen_height, .{
        .open_gl = true,
        .resizable = true,
        .fill_document = wasm,
    });
    errdefer window.deinit();

    if (!wasm and !android) setIcon(window) catch |err| {
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
    const base_path = if (wasm) persist_root else if (android) try internalStoragePath() else try sdl3.filesystem.getBasePath();
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
        .map_surface = undefined,
        .texture_fx = .init(@bitCast(sdl3.timer.getNanosecondsSinceInit())),
        .colorizer = undefined,
        .sky = undefined,
        .font = undefined,
        .shader = undefined,
        .level = .{ .world_map = world.World.init(gpa), .generator = undefined },
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
        .io = io,
        .base_path = base_path,
        .base_dir = base_dir,
        .saves_dir = saves_dir,
        .packs_dir = packs_dir,
    };
    app_state.settings = game.options_file.load(gpa, io, base_dir);
    if (app_state.settings.fullscreen) applyFullscreen(&app_state);
    if (!app_state.gl_procs.init(glGetProcAddress)) return error.GlInitFailed;
    gl.makeProcTableCurrent(&app_state.gl_procs);
    gl.DepthFunc(gl.LEQUAL);

    app_state.stats = try game.stats_file.load(gpa, io, base_dir, game.stats_file.default_username);
    errdefer app_state.stats.deinit(gpa);

    app_state.level.world_map.rand.setSeed(@bitCast(sdl3.timer.getNanosecondsSinceInit()));
    app_state.splash = pickSplash(&app_state.level.world_map.rand);

    const startup_pack = render.Textures.openArchive(gpa, io, packs_dir, app_state.settings.skin.text());
    defer if (startup_pack) |bytes| gpa.free(bytes);
    app_state.textures = try render.Textures.load(gpa, startup_pack, app_state.settings.anaglyph);
    app_state.map_surface = render.map_render.Surface.init();
    errdefer app_state.textures.deinit();

    if (wasm) app_state.github_icon = try render.Atlas.load(@embedFile("github_png"), app_state.settings.anaglyph);
    errdefer if (app_state.github_icon) |icon| icon.deinit();

    if (touch_ui) app_state.touch_atlas = try render.Atlas.load(@embedFile("touch_png"), app_state.settings.anaglyph);
    errdefer if (app_state.touch_atlas) |atlas| atlas.deinit();

    app_state.colorizer = try render.Colorizer.load(gpa);
    errdefer app_state.colorizer.deinit(gpa);

    app_state.font = try render.Font.load(font_png, app_state.settings.anaglyph);
    errdefer app_state.font.deinit();

    try app_state.texture_fx.loadSprites(assets.gui.items_png.bytes, assets.misc.dial_png.bytes);

    app_state.shader = try render.terrain_shader.init();
    errdefer app_state.shader.deinit();

    try render.screen.mojang.draw(uiContext(&app_state, guiSize(&app_state)));
    try sdl3.video.gl.swapWindow(window);
    app_state.mojang_until_ms = sdl3.timer.getMillisecondsSinceInit() + render.screen.mojang.hold_ms;

    app_state.sky = try render.SkyRenderer.init(gpa);
    errdefer app_state.sky.deinit();

    app_state.sound = audio.Manager.init(gpa, @bitCast(sdl3.timer.getNanosecondsSinceInit())) catch null;
    if (app_state.sound) |*sound| {
        const resources = try std.fs.path.join(gpa, &.{ base_path, audio.Manager.folder_name });
        defer gpa.free(resources);
        try sound.loadResources(gpa, io, resources);
        try sound.setVolumes(app_state.settings.sound_volume, app_state.settings.music_volume);
    }
    errdefer if (app_state.sound) |*sound| sound.deinit(gpa);

    app_state.level.generator = try world.Generator.init(gpa, .overworld, 0);
    errdefer app_state.level.deinit(gpa);

    return .{ app_state, .run };
}

const missed_click_ticks = 10;

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

    if (app_state.link) |link| {
        const id = switch (target) {
            inline else => |entity_id| entity_id,
        };
        return link.connection.reportUse(app_state.gpa, id, true);
    }

    if (target == .painting) return game.interact.breakPainting(interactContext(app_state), target.painting);

    _ = app_state.level.entities.hurtTarget(&app_state.level.world_map, target, damage, .{
        .position = app_state.player.base.position,
        .player = app_state.player.base.id,
    }, &app_state.level.world_map.rand);
    try app_state.stats.add(app_state.gpa, .{ .general = .damage_dealt }, damage);
}

fn clickLeft(app_state: *AppState) !void {
    if (app_state.freecam.active) return;
    if (app_state.missed_click_cooldown > 0) return;
    swingArm(app_state);
    if (pickedEntity(app_state)) |target| {
        try attackEntity(app_state, target);
        return;
    }
    const hit = pickedBlock(app_state) orelse {
        app_state.missed_click_cooldown = missed_click_ticks;
        return;
    };
    if (app_state.digging != null) return;
    switch (app_state.level.world_map.getBlock(hit.x, hit.y, hit.z)) {
        .door_wood => {
            try world.block_update.toggleDoor(&app_state.level.world_map, hit.x, hit.y, hit.z);
            try applyBlockChanges(app_state);
        },
        .trapdoor => {
            try world.block_update.toggleTrapdoor(&app_state.level.world_map, hit.x, hit.y, hit.z);
            try applyBlockChanges(app_state);
        },
        .cake => try game.interact.eatCakeSlice(interactContext(app_state), hit.x, hit.y, hit.z),
        .lever, .button => {
            _ = try world.redstone.activate(&app_state.level.world_map, hit.x, hit.y, hit.z);
            try applyBlockChanges(app_state);
        },
        .ore_redstone => try game.interact.lightRedstoneOre(interactContext(app_state), hit.x, hit.y, hit.z),
        else => {},
    }
}

fn digStep(app_state: *AppState) !void {
    if (!app_state.mouse_left_down) {
        app_state.digging = null;
        return;
    }
    if (app_state.missed_click_cooldown > 0) return;

    const hit = pickedBlock(app_state) orelse {
        app_state.digging = null;
        return;
    };

    if (app_state.digging == null or app_state.digging.?.x != hit.x or app_state.digging.?.y != hit.y or app_state.digging.?.z != hit.z) {
        app_state.digging = .{ .x = hit.x, .y = hit.y, .z = hit.z, .progress = 0 };
        try startDigging(app_state, hit);
    }

    const block_id = app_state.level.world_map.getBlock(hit.x, hit.y, hit.z);
    const strength = block_id.strength(
        app_state.player.inventory.selectedStack(),
        app_state.player.digSpeedFactor(&app_state.level.world_map),
    );
    if (strength <= 0.0) return;
    if (strength >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try applyBlockChanges(app_state);
        return;
    }

    app_state.digging.?.progress += strength;
    if (app_state.digging.?.sound_ticks % 4 == 0) {
        const step_sound = block_id.stepSound();
        app_state.level.world_map.playSoundEffect(
            @as(f64, @floatFromInt(hit.x)) + 0.5,
            @as(f64, @floatFromInt(hit.y)) + 0.5,
            @as(f64, @floatFromInt(hit.z)) + 0.5,
            step_sound.walk(),
            (step_sound.volume() + 1.0) / 8.0,
            step_sound.pitch() * 0.5,
        );
    }
    app_state.digging.?.sound_ticks += 1;
    try app_state.level.entities.spawnBlockHitParticle(
        app_state.gpa,
        hit.x,
        hit.y,
        hit.z,
        hit.face,
        block_id.selectionBounds(app_state.level.world_map.getBlockMetadata(hit.x, hit.y, hit.z)),
        block_id.particleTile(app_state.level.world_map.getBlockMetadata(hit.x, hit.y, hit.z)),
        particleTint(app_state, block_id, hit.x, hit.y, hit.z),
        &app_state.level.world_map.rand,
    );
    if (app_state.digging.?.progress >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try applyBlockChanges(app_state);
    }
}

fn particleTint(app_state: *const AppState, id: world.Block, x: i32, y: i32, z: i32) [3]u8 {
    if (id == .grass) return .{ 255, 255, 255 };
    const width = world.Chunk.width;
    const chunk = app_state.level.world_map.getChunk(@divFloor(x, width), @divFloor(z, width)) orelse return .{ 255, 255, 255 };
    const lx: u32 = @intCast(@mod(x, width));
    const lz: u32 = @intCast(@mod(z, width));
    return render.chunk_mesher.blockTint(
        app_state.colorizer,
        id,
        app_state.level.world_map.getBlockMetadata(x, y, z),
        world.Side.up,
        chunk.getTemperature(lx, lz),
        chunk.getHumidity(lx, lz),
    );
}

fn markBlockNeedsUpdate(context: *anyopaque, x: i32, _: i32, z: i32) std.mem.Allocator.Error!void {
    const app_state: *AppState = @ptrCast(@alignCast(context));
    try app_state.chunks.markBlockDirty(app_state.gpa, x, z);
}

fn updateAllRenderers(context: *anyopaque) std.mem.Allocator.Error!void {
    const app_state: *AppState = @ptrCast(@alignCast(context));
    try app_state.chunks.markAllDirty(app_state.gpa);
}

fn playNote(
    context: *anyopaque,
    x: i32,
    y: i32,
    z: i32,
    instrument: world.note.Instrument,
    pitch: u8,
) void {
    _ = instrument;
    const app_state: *AppState = @ptrCast(@alignCast(context));
    const at = math.Vec3.init(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + note_particle_lift,
        @as(f64, @floatFromInt(z)) + 0.5,
    );
    const tone = @as(f32, @floatFromInt(pitch)) / note_tone_span;
    app_state.level.entities.particles.append(
        app_state.gpa,
        game.Particle.spawnNote(at, tone, &app_state.level.world_map.rand),
    ) catch {};
}

const note_particle_lift: f64 = 1.2;
const note_tone_span: f32 = 24.0;

fn noteSink(app_state: *AppState) world.World.NoteSink {
    return .{ .context = app_state, .playNote = playNote };
}

fn worldAccess(app_state: *AppState) world.World.Access {
    return .{
        .context = app_state,
        .markBlockNeedsUpdate = markBlockNeedsUpdate,
        .updateAllRenderers = updateAllRenderers,
    };
}

fn clickSound(app_state: *AppState) void {
    if (app_state.sound) |*sound| sound.playSoundFx(assets.sounds.random.click, 1.0, 1.0) catch {};
}

fn soundSink(app_state: *AppState) world.World.SoundSink {
    return .{
        .context = app_state,
        .playSound = playSound,
        .playRecord = playRecord,
    };
}

fn playSound(context: *anyopaque, sound: assets.Sound, x: f64, y: f64, z: f64, volume: f32, pitch: f32) void {
    const app_state: *AppState = @ptrCast(@alignCast(context));
    if (app_state.sound) |*device| device.playSound(sound, x, y, z, volume, pitch) catch {};
}

fn playRecord(context: *anyopaque, name: ?[]const u8, x: i32, y: i32, z: i32) void {
    const app_state: *AppState = @ptrCast(@alignCast(context));
    if (app_state.sound) |*sound| sound.playStreaming(
        name,
        @floatFromInt(x),
        @floatFromInt(y),
        @floatFromInt(z),
        1.0,
    ) catch {};
}

fn faceIndex(face: world.block.Side) u8 {
    return switch (face) {
        .down => 0,
        .up => 1,
        .north => 2,
        .south => 3,
        .west => 4,
        .east => 5,
    };
}

fn startDigging(app_state: *AppState, hit: game.raycast.Hit) !void {
    if (app_state.link) |link| {
        return link.connection.reportDigStart(app_state.gpa, hit.x, hit.y, hit.z, faceIndex(hit.face));
    }
    const punched = app_state.level.world_map.getBlock(hit.x, hit.y, hit.z);
    if (punched == .tnt and holdingFlintAndSteel(app_state)) {
        world.tnt.markLit(&app_state.level.world_map, hit.x, hit.y, hit.z);
        return;
    }
    if (punched != .note_block) return;
    try world.note.onPunched(&app_state.level.world_map, hit.x, hit.y, hit.z);
}

fn holdingFlintAndSteel(app_state: *const AppState) bool {
    const stack = app_state.player.inventory.selectedStack() orelse return false;
    return stack.id.eql(.{ .item = .flint_and_steel });
}

fn breakBlock(app_state: *AppState, x: i32, y: i32, z: i32, block_id: world.Block) !void {
    if (app_state.link) |link| {
        try link.connection.reportDig(app_state.gpa, x, y, z, 1);
        app_state.digging = null;
        try wearHeldItem(app_state, block_id);
        return;
    }

    const meta = app_state.level.world_map.getBlockMetadata(x, y, z);
    const held = app_state.player.inventory.selectedStack();
    const harvested = block_id.harvestableWith(held);
    const step_sound = block_id.stepSound();
    app_state.level.world_map.playSoundEffect(
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @as(f64, @floatFromInt(z)) + 0.5,
        step_sound.destroy(),
        (step_sound.volume() + 1.0) / 2.0,
        step_sound.pitch() * 0.8,
    );
    try app_state.level.entities.spawnBlockDestroyParticles(
        app_state.gpa,
        x,
        y,
        z,
        block_id.particleTile(meta),
        particleTint(app_state, block_id, x, y, z),
        &app_state.level.world_map.rand,
    );
    const lit_tnt = block_id == .tnt and world.tnt.isLit(meta);
    try app_state.level.world_map.setBlockWithNotify(x, y, z, .air);
    if (lit_tnt) try world.tnt.primeByPlayer(&app_state.level.world_map, x, y, z);
    try spillFurnace(app_state, x, y, z);
    try spillDispenser(app_state, x, y, z);
    try ejectBrokenJukebox(app_state, x, y, z);
    try closeBrokenChest(app_state, x, y, z);
    _ = app_state.level.world_map.removeSign(x, y, z);
    _ = app_state.level.world_map.removeNote(x, y, z);
    app_state.digging = null;
    try wearHeldItem(app_state, block_id);

    if (harvested) {
        try app_state.stats.mine(app_state.gpa, block_id);
        const dropped = if (lit_tnt) null else block_id.harvestDrop(meta, held, &app_state.level.world_map.rand);
        if (dropped) |d| {
            try spawnDroppedItem(app_state, x, y, z, .{ .id = d.id, .count = d.count, .meta = d.meta });
        }
        if (!lit_tnt) {
            var extra: [3]world.block.Stack = undefined;
            for (block_id.bonusDrops(meta, &app_state.level.world_map.rand, &extra)) |d| {
                try spawnDroppedItem(app_state, x, y, z, .{ .id = d.id, .count = d.count, .meta = d.meta });
            }
        }
    }
}

fn spillFurnace(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    var removed = app_state.level.world_map.removeFurnace(x, y, z) orelse return;

    if (app_state.furnace_open) |open| {
        if (open.x == x and open.y == y and open.z == z) try closeContainer(app_state);
    }

    for (0..world.furnace.slot_count) |index| {
        const stack = removed.slot(index).* orelse continue;
        try spawnDroppedItem(app_state, x, y, z, stack);
    }
}

fn spillDispenser(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    var removed = app_state.level.world_map.removeDispenser(x, y, z) orelse return;

    if (app_state.dispenser_open) |open| {
        if (open.x == x and open.y == y and open.z == z) try closeContainer(app_state);
    }

    for (0..world.dispenser.slot_count) |index| {
        const stack = removed.slot(index).* orelse continue;
        try spawnDroppedItem(app_state, x, y, z, stack);
    }
}

fn ejectBrokenJukebox(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    const removed = app_state.level.world_map.removeJukebox(x, y, z) orelse return;
    const record = removed.record orelse return;
    try app_state.level.entities.ejectRecord(
        app_state.gpa,
        x,
        y,
        z,
        .{ .id = .{ .item = record }, .count = 1 },
        &app_state.level.world_map.rand,
    );
}

fn closeBrokenChest(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    const open = app_state.chest_open orelse return;
    if (y != open.y) return;
    const reach = @abs(x - open.x) + @abs(z - open.z);
    if (reach > 1) return;
    try closeContainer(app_state);
}

fn dropSelectedItem(app_state: *AppState) !void {
    const inventory = &app_state.player.inventory;
    const slot = &inventory.slots[inventory.selected];
    var stack = slot.* orelse return;
    try app_state.level.entities.throwFromPlayer(
        app_state.gpa,
        &app_state.player,
        .{ .id = stack.id, .count = 1, .meta = stack.meta },
        &app_state.level.world_map.rand,
    );
    stack.count -= 1;
    slot.* = if (stack.count == 0) null else stack;
    try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
}

fn dropHeldStack(app_state: *AppState, click_type: game.Window.Click) !void {
    const thrown = game.Window.throwCarried(click_type, &app_state.held_stack) orelse return;
    try app_state.level.entities.throwFromPlayer(
        app_state.gpa,
        &app_state.player,
        thrown,
        &app_state.level.world_map.rand,
    );
    if (app_state.link == null) try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
}

fn currentWindow(app_state: *AppState) game.Window {
    var window: game.Window = .{};

    if (openedFurnace(app_state)) |fire| {
        window.add(.{ .stack = &fire.input });
        window.add(.{ .stack = &fire.fuel });
        window.add(.{ .stack = &fire.output, .kind = .output });
        window.store_count = window.count;
    } else if (openedChest(app_state)) |open| {
        window.addStore(&open.upper.items, .chest);
        if (open.lower) |lower| window.addStore(&lower.items, .chest);
    } else if (openedDispenser(app_state)) |trap| {
        window.addStore(&trap.items, .chest);
    } else if (openedMinecart(app_state)) |cart| {
        window.addStore(&cart.items, .chest);
    } else if (app_state.workbench_open) {
        window.addGrid(&app_state.workbench_grid, game.Window.workbench_side);
    } else {
        window.addGrid(&app_state.crafting_grid, game.Window.crafting_side);
        for (0..game.Inventory.armor_size) |piece| {
            window.add(.{
                .stack = &app_state.player.inventory.armor[piece],
                .kind = .armor,
                .armor = @enumFromInt(piece),
            });
        }
    }

    window.addPlayer(&app_state.player.inventory);
    return window;
}

fn mintCraftedMap(app_state: *AppState, window: *game.Window) !void {
    if (app_state.link != null) return;
    if (window.grid.len == 0) return;

    const result = game.crafting.findMatch(window.grid, window.grid_side) orelse return;
    if (!result.id.eql(.{ .item = .map })) return;

    const id = try app_state.level.world_map.nextMapId();
    window.minted_map = @bitCast(id);

    const data = try app_state.level.world_map.mapData(id);
    data.center_x = math.util.floorDouble(app_state.player.base.position.x);
    data.center_z = math.util.floorDouble(app_state.player.base.position.z);
    data.scale = world.map.default_scale;
    data.dimension = @intFromEnum(app_state.dimension);
    data.markDirty();
}

fn containerClickAt(app_state: *AppState, aimed: i16, click_type: game.Window.Click, shift: bool) !void {
    if (aimed == no_window_slot) return;

    var window = currentWindow(app_state);
    if (window.count == 0) return;
    try mintCraftedMap(app_state, &window);

    const outcome = window.click(aimed, click_type, shift, &app_state.held_stack);

    if (outcome.thrown) |stack| {
        try app_state.level.entities.throwFromPlayer(
            app_state.gpa,
            &app_state.player,
            stack,
            &app_state.level.world_map.rand,
        );
        if (app_state.link == null) try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
    }

    if (outcome.crafted) |made| {
        if (app_state.link == null) try app_state.stats.craft(app_state.gpa, made.id, made.count);
        if (game.achievements.forCrafted(made.id)) |earned| try awardAchievement(app_state, earned);
    }

    if (outcome.smelted) |made| {
        try app_state.stats.craft(app_state.gpa, made.id, made.count);
        if (game.achievements.forSmelted(made.id)) |earned| try awardAchievement(app_state, earned);
    }
}

fn shiftHeld() bool {
    const mods = sdl3.keyboard.getModState();
    return mods.left_shift or mods.right_shift;
}

fn openContainerClickAt(app_state: *AppState, click_type: game.Window.Click) !void {
    const shift = shiftHeld();
    if (app_state.furnace_open != null) {
        const layout = render.screen.furnace.slots();
        try windowClickAt(app_state, &layout, click_type, render.screen.container.height, shift);
    } else if (openedChest(app_state)) |open| {
        const rows = open.rows();
        var buffer: [render.screen.chest.max_slot_count]render.screen.container.Slot = undefined;
        const layout = render.screen.chest.slots(rows, &buffer, .chest);
        try windowClickAt(app_state, layout, click_type, render.screen.chest.height(rows), shift);
    } else if (openedDispenser(app_state) != null) {
        const layout = render.screen.dispenser.slots();
        try windowClickAt(app_state, &layout, click_type, render.screen.container.height, shift);
    } else if (openedMinecart(app_state) != null) {
        var buffer: [render.screen.chest.max_slot_count]render.screen.container.Slot = undefined;
        const layout = render.screen.chest.slots(game.Minecart.chest_rows, &buffer, .minecart);
        try windowClickAt(app_state, layout, click_type, render.screen.chest.height(game.Minecart.chest_rows), shift);
    } else if (app_state.workbench_open) {
        const layout = render.screen.crafting.slots();
        try windowClickAt(app_state, &layout, click_type, render.screen.container.height, shift);
    } else {
        const layout = render.screen.inventory.slots();
        try windowClickAt(app_state, &layout, click_type, render.screen.container.height, shift);
    }
}

fn windowClickAt(
    app_state: *AppState,
    slots: []const render.screen.container.Slot,
    click_type: game.Window.Click,
    box_height: f32,
    shift: bool,
) !void {
    const aimed = aimedWindowSlot(app_state, slots, box_height);
    try containerClickAt(app_state, aimed, click_type, shift);
    try reportWindowClick(app_state, aimed, click_type, shift);
}

fn aimedWindowSlot(
    app_state: *AppState,
    slots: []const render.screen.container.Slot,
    box_height: f32,
) i16 {
    const gui = guiSize(app_state);
    if (render.screen.container.slotAt(slots, app_state.mouse_x, app_state.mouse_y, gui, box_height)) |index| {
        return @intCast(index);
    }
    if (render.screen.container.isOutside(app_state.mouse_x, app_state.mouse_y, gui, box_height)) {
        return remote.Connection.outside_slot;
    }
    return no_window_slot;
}

const no_window_slot: i16 = std.math.minInt(i16);

fn reportWindowClick(app_state: *AppState, slot: i16, click_type: game.Window.Click, shift: bool) !void {
    if (slot == no_window_slot) return;
    const link = app_state.link orelse return;
    try link.connection.reportWindowClick(
        app_state.gpa,
        slot,
        click_type == .right,
        shift,
        app_state.held_stack,
    );
    link.connection.carried = app_state.held_stack;
    link.connection.crafting = app_state.crafting_grid;
    link.connection.workbench = app_state.workbench_grid;
}

fn adoptServerWindow(app_state: *AppState, link: *Link) void {
    app_state.held_stack = link.connection.carried;
    app_state.crafting_grid = link.connection.crafting;
    app_state.workbench_grid = link.connection.workbench;
}

fn dropGrid(app_state: *AppState, grid: []?game.Inventory.ItemStack) !void {
    for (grid) |*slot| {
        const stack = slot.* orelse continue;
        try app_state.level.entities.throwFromPlayer(
            app_state.gpa,
            &app_state.player,
            stack,
            &app_state.level.world_map.rand,
        );
        slot.* = null;
        try app_state.stats.add(app_state.gpa, .{ .general = .drop }, 1);
    }
}

fn containerOpen(app_state: *const AppState) bool {
    return app_state.inventory_open or app_state.workbench_open or app_state.furnace_open != null or
        app_state.chest_open != null or app_state.dispenser_open != null or
        app_state.minecart_open != game.Entity.no_id or app_state.sign_edit != null;
}

fn openSignEditor(app_state: *AppState, x: i32, y: i32, z: i32) void {
    app_state.sign_edit = .{ .x = x, .y = y, .z = z };
    sdl3.keyboard.startTextInput(app_state.window) catch {};
    updateMouseMode(app_state) catch {};
}

fn closeSignEditor(app_state: *AppState) !void {
    if (app_state.link) |link| {
        if (app_state.sign_edit) |open| {
            if (app_state.level.world_map.signAt(open.x, open.y, open.z)) |post| {
                link.connection.reportSign(app_state.gpa, open.x, open.y, open.z, post) catch {};
            }
        }
    }
    app_state.sign_edit = null;
    try sdl3.keyboard.stopTextInput(app_state.window);
    try updateMouseMode(app_state);
}

fn editedSign(app_state: *AppState) ?*world.sign.Sign {
    const open = app_state.sign_edit orelse return null;
    return app_state.level.world_map.signAt(open.x, open.y, open.z);
}

fn worldFocused(app_state: *const AppState) bool {
    return app_state.screen == .playing and !containerOpen(app_state) and !app_state.paused and !app_state.dead and !app_state.options_open and !app_state.chat.open;
}

fn updateMouseMode(app_state: *AppState) !void {
    try sdl3.mouse.setWindowRelativeMode(app_state.window, !touch_ui and worldFocused(app_state));
}

fn closeContainer(app_state: *AppState) !void {
    if (app_state.link) |link| {
        link.connection.reportCloseWindow(app_state.gpa) catch {};
        app_state.inventory_open = false;
        app_state.workbench_open = false;
        app_state.furnace_open = null;
        app_state.chest_open = null;
        app_state.dispenser_open = null;
        app_state.minecart_open = game.Entity.no_id;
        return updateMouseMode(app_state);
    }

    app_state.inventory_open = false;
    app_state.workbench_open = false;
    app_state.furnace_open = null;
    app_state.chest_open = null;
    app_state.dispenser_open = null;
    app_state.minecart_open = game.Entity.no_id;
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
    _ = try app_state.level.world_map.addFurnace(x, y, z);
    app_state.furnace_open = .{ .x = x, .y = y, .z = z };
    try updateMouseMode(app_state);
}

fn openedFurnace(app_state: *AppState) ?*world.furnace.Furnace {
    const pos = app_state.furnace_open orelse return null;
    return app_state.level.world_map.furnaceAt(pos.x, pos.y, pos.z);
}

fn openedMinecart(app_state: *AppState) ?*game.Minecart {
    if (app_state.minecart_open == game.Entity.no_id) return null;
    return app_state.level.entities.minecartById(app_state.minecart_open);
}

fn openDispenser(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    _ = try app_state.level.world_map.addDispenser(x, y, z);
    app_state.dispenser_open = .{ .x = x, .y = y, .z = z };
    try updateMouseMode(app_state);
}

fn openedDispenser(app_state: *AppState) ?*world.dispenser.Dispenser {
    const pos = app_state.dispenser_open orelse return null;
    if (app_state.level.world_map.getBlock(pos.x, pos.y, pos.z) != .dispenser) return null;
    return app_state.level.world_map.dispenserAt(pos.x, pos.y, pos.z);
}

fn openChest(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    if (app_state.level.world_map.chestIsBlocked(x, y, z)) return;

    const pair = app_state.level.world_map.chestPairAt(x, y, z);
    _ = try app_state.level.world_map.addChest(pair.upper.x, pair.upper.y, pair.upper.z);
    if (pair.lower) |lower| _ = try app_state.level.world_map.addChest(lower.x, lower.y, lower.z);

    app_state.chest_open = .{ .x = x, .y = y, .z = z };
    try updateMouseMode(app_state);
}

const OpenChest = struct {
    upper: *world.chest.Chest,
    lower: ?*world.chest.Chest,

    fn rows(self: OpenChest) u8 {
        return if (self.lower == null) world.chest.rows else world.chest.rows * 2;
    }
};

fn openedChest(app_state: *AppState) ?OpenChest {
    const pos = app_state.chest_open orelse return null;
    const world_map = &app_state.level.world_map;
    if (world_map.getBlock(pos.x, pos.y, pos.z) != .chest) return null;

    const pair = world_map.chestPairAt(pos.x, pos.y, pos.z);
    const upper = world_map.chestAt(pair.upper.x, pair.upper.y, pair.upper.z) orelse return null;
    const half = pair.lower orelse return .{ .upper = upper, .lower = null };
    const lower = world_map.chestAt(half.x, half.y, half.z) orelse return null;
    return .{ .upper = upper, .lower = lower };
}

fn openedChestSlot(app_state: *AppState, index: usize) ?*?game.Inventory.ItemStack {
    const open = openedChest(app_state) orelse return null;
    const half = if (index < world.chest.slot_count) open.upper else open.lower orelse return null;
    return half.slot(index % world.chest.slot_count);
}

fn toggleInventory(app_state: *AppState) !void {
    if (containerOpen(app_state)) {
        try closeContainer(app_state);
        return;
    }
    app_state.inventory_open = true;
    try awardAchievement(app_state, .open_inventory);
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
        try app_state.level.world_map.beginSaveRound();
    }
    app_state.pause_save_frames += 1;
    app_state.pause_saving = try app_state.level.world_map.saveQueuedChunks(save_chunks_per_pass) > 0;
}

fn killPlayer(app_state: *AppState) !void {
    app_state.dead = true;
    app_state.level.setOccupantActive(false);
    if (containerOpen(app_state)) try closeContainer(app_state);
    app_state.keys = .{};
    app_state.mouse_left_down = false;
    app_state.digging = null;
    try updateMouseMode(app_state);

    // The server empties the pockets and keeps the tally in multiplayer.
    if (app_state.link != null) return;
    try dropInventoryOnDeath(app_state);
    try app_state.stats.add(app_state.gpa, .{ .general = .deaths }, 1);
}

fn dropInventoryOnDeath(app_state: *AppState) !void {
    for (&app_state.player.inventory.slots) |*slot| try scatterSlotOnDeath(app_state, slot);
    for (&app_state.player.inventory.armor) |*slot| try scatterSlotOnDeath(app_state, slot);
}

fn scatterSlotOnDeath(app_state: *AppState, slot: *?game.Inventory.ItemStack) !void {
    const stack = slot.* orelse return;
    try app_state.level.entities.scatterFromPlayer(
        app_state.gpa,
        &app_state.player,
        stack,
        &app_state.level.world_map.rand,
    );
    slot.* = null;
}

fn respawnPlayer(app_state: *AppState) !void {
    if (app_state.link) |link| {
        try link.connection.reportRespawn(app_state.gpa);
        app_state.dead = false;
        app_state.level.setOccupantActive(true);
        try updateMouseMode(app_state);
        return;
    }

    if (app_state.player.spawn_point) |bed| {
        if (world.block_update.bedRespawnSpot(&app_state.level.world_map, bed[0], bed[1], bed[2], 0)) |spot| {
            app_state.player.respawn(spawnPlacement(&app_state.level.world_map, spot));
            app_state.dead = false;
            app_state.level.setOccupantActive(true);
            try updateMouseMode(app_state);
            return;
        }
        app_state.chat.addMessage(app_state.font, bed_not_valid_line);
        app_state.player.spawn_point = null;
    }

    try adjustSpawnLocation(app_state);
    app_state.player.respawn(spawnPlacement(&app_state.level.world_map, app_state.level.spawn));
    app_state.dead = false;
    app_state.level.setOccupantActive(true);
    try updateMouseMode(app_state);
}

fn deathScreenClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const action = render.screen.death.actionAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    clickSound(app_state);
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
        } else if (app_state.link) |link| {
            try link.connection.say(app_state.gpa, trimmed);
        } else {
            var buf: [render.chat.max_message_length + 32]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "<{s}> {s}", .{ game.stats_file.default_username, trimmed }) catch trimmed;
            app_state.chat.addMessage(app_state.font, line);
        }
        app_state.chat.pushHistory(trimmed);
    }
    try closeChat(app_state);
}

fn reply(app_state: *AppState, comptime format: []const u8, args: anytype) void {
    var buf: [render.chat.max_message_length * 2]u8 = undefined;
    app_state.chat.addMessage(app_state.font, std.fmt.bufPrint(&buf, format, args) catch return);
}

fn lookedAtPosition(app_state: *AppState) math.Vec3 {
    const hit = pickedBlock(app_state) orelse return app_state.player.base.position;

    const target = world.block_update.placementTarget(&app_state.level.world_map, hit.x, hit.y, hit.z, hit.face);
    return math.Vec3.init(
        @as(f64, @floatFromInt(target.x)) + 0.5,
        @floatFromInt(target.y),
        @as(f64, @floatFromInt(target.z)) + 0.5,
    );
}

fn runCommand(app_state: *AppState, line: []const u8) !void {
    switch (game.commands.parse(line)) {
        .nothing => {},
        .help => for (game.commands.help_lines) |help_line| {
            app_state.chat.addMessage(app_state.font, help_line);
        },
        .freecam => {
            if (app_state.freecam.active) {
                app_state.freecam.leave();
                app_state.chat.addMessage(app_state.font, game.commands.freecam_off_line);
            } else {
                const eye = app_state.player.eyePosition();
                app_state.freecam.enter(eye, app_state.player.yaw, app_state.player.pitch);
                app_state.digging = null;
                app_state.mouse_left_down = false;
                app_state.chat.addMessage(app_state.font, game.commands.freecam_on_line);
            }
        },
        .kill => {
            app_state.player.kill();
            app_state.chat.addMessage(app_state.font, game.commands.kill_line);
        },
        .seed => |seed| {
            var buffer: [64]u8 = undefined;
            const world_seed = try std.fmt.bufPrintSentinel(&buffer, "{d}", .{app_state.level.generator.worldSeed()}, 0);
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
            const leftover = app_state.player.inventory.addStack(.{ .id = give.id, .count = give.count });
            if (leftover > 0) {
                try app_state.level.entities.throwFromPlayer(
                    app_state.gpa,
                    &app_state.player,
                    .{ .id = give.id, .count = leftover },
                    &app_state.level.world_map.rand,
                );
            }
            reply(app_state, "Giving you some {d}", .{give.raw_id});
        },
        .spawn => |spawn| {
            const position = lookedAtPosition(app_state);
            for (0..spawn.count) |_| switch (spawn.mob) {
                .pig => try app_state.level.entities.spawnPig(app_state.gpa, position),
                .cow => try app_state.level.entities.spawnCow(app_state.gpa, position),
                .sheep => try app_state.level.entities.spawnSheep(app_state.gpa, position, &app_state.level.world_map.rand),
                .chicken => try app_state.level.entities.spawnChicken(app_state.gpa, position, &app_state.level.world_map.rand),
                .slime => try app_state.level.entities.spawnSlime(app_state.gpa, position, &app_state.level.world_map.rand),
                .wolf => try app_state.level.entities.spawnWolf(app_state.gpa, position, &app_state.level.world_map.rand),
                .ghast => try app_state.level.entities.spawnGhast(app_state.gpa, position),
                .creeper => try app_state.level.entities.spawnCreeper(app_state.gpa, position),
                .skeleton => try app_state.level.entities.spawnSkeleton(app_state.gpa, position),
                .spider => try app_state.level.entities.spawnSpider(app_state.gpa, position),
                .zombie => try app_state.level.entities.spawnZombie(app_state.gpa, position),
                .pigzombie => try app_state.level.entities.spawnPigZombie(app_state.gpa, position),
                .squid => try app_state.level.entities.spawnSquid(app_state.gpa, position, &app_state.level.world_map.rand),
            };
            reply(app_state, "Spawning {d} {s}", .{ spawn.count, @tagName(spawn.mob) });
        },
        .time => |time| {
            switch (time.method) {
                .add => {
                    app_state.level.world_map.setTime(app_state.level.world_map.time + time.amount);
                    reply(app_state, "Added {d} to time", .{time.amount});
                },
                .set => {
                    app_state.level.world_map.setTime(time.amount);
                    reply(app_state, "Set time to {d}", .{time.amount});
                },
            }
        },
        .tp => |tp| {
            var player = &app_state.player;
            player.tp(.{ .x = tp.x, .y = tp.y, .z = tp.z });
        },
        .weather => |asked| {
            if (app_state.link) |link| return link.connection.say(app_state.gpa, line);
            if (!app_state.dimension.hasSky()) {
                reply(app_state, "{s}", .{game.commands.no_sky_line});
                return;
            }
            game.commands.applyWeather(&app_state.level.world_map.weather, asked);
            reply(app_state, game.commands.set_weather_line, .{@tagName(asked.sky)});
        },
        .unparsed_item => |text| reply(app_state, "There's no item with id {s}", .{text}),
        .missing_item => |raw| reply(app_state, "There's no item with id {d}", .{raw}),
        .missing_mob => |name| reply(app_state, "There's no mob called {s}", .{name}),
        .unparsed => |text| reply(app_state, "Unable to parse value, {s}", .{text}),
        .unknown_method => |text| reply(app_state, "Unknown method, use {s}", .{text}),
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
    app_state.level.setOccupantActive(true);
    app_state.splash = pickSplash(&app_state.level.world_map.rand);
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

fn openRepository() void {
    sdl3.openURL(repository_url) catch |err| std.log.warn("could not open {s}: {t}", .{ repository_url, err });
}

fn openMultiplayer(app_state: *AppState) !void {
    app_state.multiplayer_state = render.screen.multiplayer.init(app_state.settings.last_server.text());
    app_state.screen = .multiplayer;
    try sdl3.keyboard.startTextInput(app_state.window);
}

fn closeMultiplayer(app_state: *AppState) !void {
    try sdl3.keyboard.stopTextInput(app_state.window);
    app_state.screen = .title;
}

fn connectToServer(app_state: *AppState) !void {
    if (!app_state.multiplayer_state.canConnect()) return;
    if (wasm) {
        reply(app_state, "Multiplayer is not available in the browser", .{});
        return;
    }

    var stored: [128]u8 = undefined;
    const typed = app_state.multiplayer_state.address.text();
    app_state.settings.last_server.set(render.screen.multiplayer.storedName(typed, &stored));
    saveOptions(app_state);

    const address = render.screen.multiplayer.parseAddress(typed);

    closeWorld(app_state);
    app_state.level.world_map.access = worldAccess(app_state);
    app_state.level.world_map.sound_sink = soundSink(app_state);
    app_state.level.world_map.note_sink = noteSink(app_state);
    app_state.level.world_map.remote = true;
    app_state.player = playerAtSpawn();
    try app_state.level.enter(app_state.gpa, &app_state.player);

    app_state.link = Link.connect(
        app_state.gpa,
        app_state.io,
        address.host,
        address.port,
        game.stats_file.default_username,
    ) catch |err| {
        reply(app_state, "Could not reach {s}: {s}", .{ typed, @errorName(err) });
        closeWorld(app_state);
        return;
    };

    app_state.dead = false;
    app_state.needs_spawn = false;
    app_state.ticks_since_save = 0;
    try sdl3.keyboard.stopTextInput(app_state.window);
    app_state.screen = .playing;
    try updateMouseMode(app_state);
}

fn multiplayerClick(app_state: *AppState) !void {
    const hit = render.screen.multiplayer.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        guiSize(app_state),
        &app_state.multiplayer_state,
    ) orelse return;

    switch (hit) {
        .address_field => {},
        else => clickSound(app_state),
    }

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
        const fallback = if (render.texture_pack.isDefault(pack)) assets.pack_png.bytes else assets.gui.unknown_pack_png.bytes;
        thumbnail.* = render.Atlas.load(pack.thumbnail orelse fallback, app_state.settings.anaglyph) catch
            try render.Atlas.load(assets.gui.unknown_pack_png.bytes, app_state.settings.anaglyph);
    }
    app_state.pack_thumbnails = thumbnails;

    app_state.pack_scroll = 0;
    app_state.screen = .texture_packs;
    try updateMouseMode(app_state);
}

fn applyFullscreen(app_state: *AppState) void {
    app_state.window.setFullscreen(app_state.settings.fullscreen) catch |err| {
        std.log.warn("could not change the fullscreen state: {t}", .{err});
        app_state.settings.fullscreen = !app_state.settings.fullscreen;
    };
}

fn saveOptions(app_state: *AppState) void {
    game.options_file.save(app_state.gpa, app_state.io, app_state.base_dir, &app_state.settings) catch |err| {
        std.log.warn("could not save {s}: {t}", .{ game.options_file.file_name, err });
    };
}

fn refreshTextures(app_state: *AppState) !void {
    const archive = render.Textures.openArchive(app_state.gpa, app_state.io, app_state.packs_dir, app_state.settings.skin.text());
    defer if (archive) |bytes| app_state.gpa.free(bytes);

    const reloaded = try render.Textures.load(app_state.gpa, archive, app_state.settings.anaglyph);
    app_state.textures.deinit();
    app_state.textures = reloaded;

    const font = try render.Font.load(font_png, app_state.settings.anaglyph);
    app_state.font.deinit();
    app_state.font = font;

    try app_state.chunks.markAllDirty(app_state.gpa);
}

fn selectTexturePack(app_state: *AppState, index: usize) !void {
    const name = app_state.packs[index].name;
    if (std.mem.eql(u8, name, app_state.settings.skin.text())) return;

    const archive = render.Textures.openArchive(app_state.gpa, app_state.io, app_state.packs_dir, name);
    defer if (archive) |bytes| app_state.gpa.free(bytes);

    const reloaded = try render.Textures.load(app_state.gpa, archive, app_state.settings.anaglyph);
    app_state.textures.deinit();
    app_state.textures = reloaded;
    app_state.settings.skin.set(name);
    saveOptions(app_state);
}

fn texturePacksClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.screen.texture_packs.scrollbarAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.packs.len)) {
        app_state.dragging_scrollbar = true;
        return;
    }

    const hit = render.screen.texture_packs.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        gui,
        app_state.packs.len,
        app_state.pack_scroll,
    ) orelse return;

    switch (hit) {
        .entry => {},
        else => clickSound(app_state),
    }

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
    app_state.create_state = render.screen.create_world.init(.create);
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
        .pos = position,
        .motion = app_state.player.base.motion,
        .yaw = app_state.player.yaw,
        .pitch = app_state.player.pitch,
        .dimension = app_state.dimension,
        .fall_distance = app_state.player.fall_distance,
        .fire = @intCast(app_state.player.fire),
        .air = @intCast(app_state.player.air),
        .on_ground = app_state.player.base.on_ground,
        .health = @intCast(app_state.player.health),
        .hurt_time = @intCast(app_state.player.hurt_time),
        .death_time = @intCast(app_state.player.death_time),
        .spawn = app_state.player.spawn_point,
        .sleeping = app_state.player.sleeping,
        .sleep_timer = @intCast(app_state.player.sleep_timer),
        .inventory = entries.items,
    };
}

fn applyPlayerState(app_state: *AppState, state: world.save.PlayerState) void {
    app_state.player.base.position = state.pos;
    app_state.player.base.motion = state.motion;
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
    app_state.player.sleep_timer = state.sleep_timer;
    if (state.sleeping) {
        app_state.player.sleeping = true;
        app_state.player.wake_pending = true;
        app_state.player.bed = .{
            math.util.floorDouble(app_state.player.base.position.x),
            math.util.floorDouble(app_state.player.anchorY()),
            math.util.floorDouble(app_state.player.base.position.z),
        };
    }

    app_state.player.inventory.loadSaveEntries(state.inventory);
}

fn saveWorld(app_state: *AppState) !void {
    if (app_state.save_handle == null) return;
    try app_state.level.world_map.saveDirtyMaps();
    try app_state.level.world_map.saveLoadedChunks();
    try saveLevel(app_state);
    persist();
}

fn saveLevel(app_state: *AppState) !void {
    const handle = if (app_state.save_handle) |*h| h else return;

    var entries: std.ArrayList(world.save.InventoryEntry) = .empty;
    defer entries.deinit(app_state.gpa);
    const player = try playerState(app_state, &entries);

    const info: world.save.LevelInfo = .{
        .seed = app_state.level.generator.worldSeed(),
        .spawn = app_state.level.spawn,
        .time = app_state.level.world_map.time,
        .raining = app_state.level.world_map.weather.raining,
        .rain_time = app_state.level.world_map.weather.rain_time,
        .thundering = app_state.level.world_map.weather.thundering,
        .thunder_time = app_state.level.world_map.weather.thunder_time,
        .last_played = world.RegionFile.unixMilliseconds(app_state.io),
        .size_on_disk = @intCast(handle.diskSize(app_state.io)),
        .name = @constCast(app_state.open_name.text()),
        .player = player,
    };
    try handle.writeLevel(app_state.gpa, app_state.io, info);
}

fn dropLink(app_state: *AppState) void {
    const link = app_state.link orelse return;
    app_state.link = null;
    link.deinit();
}

fn closeWorld(app_state: *AppState) void {
    dropLink(app_state);
    app_state.level.world_map.remote = false;
    app_state.freecam.leave();
    app_state.dimension = .overworld;
    app_state.pending_portal = false;
    if (app_state.save_handle) |*handle| handle.close(app_state.gpa, app_state.io);
    app_state.save_handle = null;
    app_state.level.closeWorld(app_state.gpa);
    app_state.chunks.deinit(app_state.gpa);
    app_state.chunks = .{};
}

fn startWorld(app_state: *AppState, folder: []const u8, name: []const u8, seed: ?i64) !void {
    closeWorld(app_state);

    app_state.open_folder.set(folder);
    app_state.open_name.set(name);

    app_state.save_handle = try world.save.open(app_state.io, app_state.saves_dir, folder);
    const handle = &app_state.save_handle.?;

    var stored = handle.readLevel(app_state.gpa, app_state.io) catch null;
    defer if (stored) |*info| info.deinit(app_state.gpa);

    const level_seed = if (stored) |info| info.seed else seed orelse app_state.level.world_map.rand.nextLong();

    try app_state.level.reseed(app_state.gpa, .overworld, level_seed);

    app_state.level.world_map.persistence = .{ .handle = handle, .io = app_state.io };
    app_state.level.world_map.access = worldAccess(app_state);
    app_state.level.world_map.sound_sink = soundSink(app_state);
    app_state.level.world_map.note_sink = noteSink(app_state);
    app_state.player = playerAtSpawn();
    try app_state.level.enter(app_state.gpa, &app_state.player);

    try app_state.stats.add(app_state.gpa, .{ .general = if (stored == null) .create_world else .load_world }, 1);
    try app_state.stats.add(app_state.gpa, .{ .general = .start_game }, 1);

    app_state.needs_spawn = true;
    if (stored) |info| {
        app_state.open_name.set(info.name);
        app_state.level.world_map.time = info.time;
        app_state.level.world_map.weather = .{
            .raining = info.raining,
            .rain_time = info.rain_time,
            .thundering = info.thundering,
            .thunder_time = info.thunder_time,
        };
        app_state.level.world_map.weather.settle();
        app_state.level.spawn = info.spawn;
        if (info.player) |player| {
            applyPlayerState(app_state, player);
            app_state.needs_spawn = false;
            if (player.dimension != .overworld) try enterSavedDimension(app_state, player.dimension);
        }
    } else {
        app_state.level.world_map.time = 0;
        app_state.level.spawn = try findInitialSpawn(app_state);
    }

    const load_center: [2]i32 = if (app_state.needs_spawn)
        .{ app_state.level.spawn[0], app_state.level.spawn[2] }
    else
        .{ @intFromFloat(@floor(app_state.player.base.position.x)), @intFromFloat(@floor(app_state.player.base.position.z)) };

    app_state.loading = .{
        .total = @intCast((spawn_load_radius * 2 + 1) * (spawn_load_radius * 2 + 1)),
        .center = load_center,
        .title = if (stored == null) "Generating level" else "Loading level",
    };
    app_state.screen = .loading;
    app_state.ticks_since_save = 0;
    try updateMouseMode(app_state);
}

fn enterSavedDimension(app_state: *AppState, target: world.Dimension) !void {
    app_state.level.leave(&app_state.player);
    try app_state.level.reseed(app_state.gpa, target, app_state.level.generator.worldSeed());
    app_state.dimension = target;

    if (app_state.save_handle) |*handle| {
        try handle.useDimension(app_state.gpa, app_state.io, target);
        app_state.level.world_map.persistence = .{ .handle = handle, .io = app_state.io };
    }
    app_state.level.world_map.brightness = world.light.brightnessTable(target.ambientLight());
    app_state.level.world_map.has_sky = target.hasSky();
    try app_state.level.enter(app_state.gpa, &app_state.player);
}

fn loadingChunkCoord(app_state: *const AppState, index: i32) world.World.ChunkCoord {
    const side = spawn_load_radius * 2 + 1;
    const center_x = @divFloor(app_state.loading.center[0], world.Chunk.width);
    const center_z = @divFloor(app_state.loading.center[1], world.Chunk.width);
    return .{
        .x = center_x + @mod(index, side) - spawn_load_radius,
        .z = center_z + @divFloor(index, side) - spawn_load_radius,
    };
}

fn stepLoading(app_state: *AppState) !void {
    const started = sdl3.timer.getNanosecondsSinceInit();

    while (app_state.loading.done < app_state.loading.total) {
        const coord = loadingChunkCoord(app_state, app_state.loading.next);
        try app_state.level.world_map.ensureDecorated(&app_state.level.generator, coord.x, coord.z);
        app_state.loading.next += 1;
        app_state.loading.done += 1;
        if (sdl3.timer.getNanosecondsSinceInit() -% started >= chunk_load_budget_ns) return;
    }

    try finishLoading(app_state);
}

fn firstUncoveredBlock(app_state: *AppState, x: i32, z: i32) !world.Block {
    const width = world.Chunk.width;
    try app_state.level.world_map.ensureDecorated(&app_state.level.generator, @divFloor(x, width), @divFloor(z, width));

    var y: i32 = 63;
    while (app_state.level.world_map.getBlock(x, y + 1, z) != .air) : (y += 1) {}
    return app_state.level.world_map.getBlock(x, y, z);
}

fn findInitialSpawn(app_state: *AppState) ![3]i32 {
    var x: i32 = 0;
    var z: i32 = 0;
    while ((try firstUncoveredBlock(app_state, x, z)) != .sand) {
        x += app_state.level.world_map.rand.nextIntBound(64) - app_state.level.world_map.rand.nextIntBound(64);
        z += app_state.level.world_map.rand.nextIntBound(64) - app_state.level.world_map.rand.nextIntBound(64);
    }
    return .{ x, 64, z };
}

fn adjustSpawnLocation(app_state: *AppState) !void {
    if (app_state.level.spawn[1] <= 0) app_state.level.spawn[1] = 64;
    while ((try firstUncoveredBlock(app_state, app_state.level.spawn[0], app_state.level.spawn[2])) == .air) {
        app_state.level.spawn[0] += app_state.level.world_map.rand.nextIntBound(8) - app_state.level.world_map.rand.nextIntBound(8);
        app_state.level.spawn[2] += app_state.level.world_map.rand.nextIntBound(8) - app_state.level.world_map.rand.nextIntBound(8);
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

fn placePlayerAt(app_state: *AppState, x: f64, y: f64, z: f64) void {
    const player = &app_state.player;
    player.base.position = math.Vec3.init(x, y, z);
    player.base.prev_position = player.base.position;
    player.base.motion = math.Vec3.init(0, 0, 0);
    player.base.on_ground = false;
}

fn usePortal(app_state: *AppState) !void {
    const target = app_state.dimension.other();
    const scale = world.Dimension.nether.coordinateScale();

    const from = app_state.player.base.position;
    const x = if (target == .nether) from.x / scale else from.x * scale;
    const z = if (target == .nether) from.z / scale else from.z * scale;

    try switchDimension(app_state, target, x, from.y, z);
}

fn switchDimension(app_state: *AppState, target: world.Dimension, x: f64, y: f64, z: f64) !void {
    try saveWorld(app_state);

    app_state.level.closeWorld(app_state.gpa);
    app_state.chunks.deinit(app_state.gpa);
    app_state.chunks = .{};

    try app_state.level.reseed(app_state.gpa, target, app_state.level.generator.worldSeed());
    app_state.dimension = target;

    if (app_state.save_handle) |*handle| {
        try handle.useDimension(app_state.gpa, app_state.io, target);
        app_state.level.world_map.persistence = .{ .handle = handle, .io = app_state.io };
    }
    app_state.level.world_map.access = worldAccess(app_state);
    app_state.level.world_map.sound_sink = soundSink(app_state);
    app_state.level.world_map.note_sink = noteSink(app_state);
    app_state.level.world_map.brightness = world.light.brightnessTable(target.ambientLight());
    app_state.level.world_map.has_sky = target.hasSky();

    placePlayerAt(app_state, x, y, z);
    try app_state.level.enter(app_state.gpa, &app_state.player);

    app_state.pending_portal = true;
    app_state.needs_spawn = false;
    app_state.loading = .{
        .total = @intCast((spawn_load_radius * 2 + 1) * (spawn_load_radius * 2 + 1)),
        .center = .{ @intFromFloat(@floor(x)), @intFromFloat(@floor(z)) },
        .title = if (target == .nether) "Entering the Nether" else "Leaving the Nether",
    };
    app_state.screen = .loading;
    try updateMouseMode(app_state);
}

fn finishLoading(app_state: *AppState) !void {
    if (app_state.pending_portal) {
        app_state.pending_portal = false;
        const landed = try world.portal.placeInto(
            &app_state.level.world_map,
            &app_state.level.world_map.rand,
            app_state.player.base.position.x,
            app_state.player.base.position.y,
            app_state.player.base.position.z,
        );
        placePlayerAt(app_state, landed.x, landed.y, landed.z);
        try applyBlockChanges(app_state);
    }

    if (app_state.needs_spawn) {
        app_state.player.base.position = spawnPlacement(&app_state.level.world_map, app_state.level.spawn);
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
    saveOptions(app_state);
    app_state.options_open = false;
    app_state.video_open = false;
    app_state.controls_open = false;
    app_state.rebinding = null;
    app_state.dragging_slider = null;
    try updateMouseMode(app_state);
}

fn selectWorldClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.screen.select_world.scrollbarAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.summaries.len)) {
        app_state.dragging_scrollbar = true;
        return;
    }

    const hit = render.screen.select_world.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        gui,
        app_state.summaries.len,
        app_state.list_scroll,
        app_state.selected_world != null,
    ) orelse return;

    switch (hit) {
        .entry => {},
        else => clickSound(app_state),
    }

    switch (hit) {
        .entry => |index| {
            const now = sdl3.timer.getMillisecondsSinceInit();
            const double = render.screen.select_world.isDoubleClick(
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
    app_state.create_state = render.screen.create_world.init(.rename);
    app_state.create_state.name.setText(app_state.summaries[index].name);
    app_state.screen = .create_world;
    try sdl3.keyboard.startTextInput(app_state.window);
}

fn createWorldClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.screen.create_world.hitAt(app_state.mouse_x, app_state.mouse_y, gui, &app_state.create_state) orelse return;
    switch (hit) {
        .name_field, .seed_field => {},
        else => clickSound(app_state),
    }

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

            const random_seed = app_state.level.world_map.rand.nextLong();
            const seed = render.screen.create_world.seedFromText(app_state.create_state.seed.text(), random_seed);
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
    const hit = render.screen.confirm.hitAt(app_state.mouse_x, app_state.mouse_y, gui, "Delete") orelse return;
    clickSound(app_state);
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

fn setSlider(app_state: *AppState, which: render.screen.options.Slider, value: f32) void {
    switch (which) {
        .music => app_state.settings.music_volume = value,
        .sound => app_state.settings.sound_volume = value,
        .sensitivity => app_state.settings.sensitivity = value,
    }
    if (app_state.sound) |*sound| {
        sound.setVolumes(app_state.settings.sound_volume, app_state.settings.music_volume) catch {};
    }
}

fn dragScrollbar(app_state: *AppState, dy_pixels: f32) void {
    const gui = guiSize(app_state);
    const dy = dy_pixels / gui.factor;

    if (app_state.stats_open) {
        const view = &app_state.stats_view;
        view.scroll.set(view.tab, render.screen.stats.dragScroll(gui, view.*, dy));
    } else if (app_state.screen == .select_world) {
        app_state.list_scroll = render.screen.select_world.dragScroll(gui, app_state.summaries.len, app_state.list_scroll, dy);
    } else if (app_state.screen == .texture_packs) {
        app_state.pack_scroll = render.screen.texture_packs.dragScroll(gui, app_state.packs.len, app_state.pack_scroll, dy);
    }
}

fn pauseMenuClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const action = render.menu.actionAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    clickSound(app_state);
    switch (action) {
        .resume_game => try togglePause(app_state),
        .achievements => try openAchievements(app_state),
        .statistics => try openStats(app_state),
        .options => try openOptions(app_state, .pause),
        .quit_to_title => try quitToTitle(app_state),
    }
}

fn openStats(app_state: *AppState) !void {
    app_state.stats_view.deinit(app_state.gpa);
    app_state.stats_view = try render.screen.stats.State.init(app_state.gpa, &app_state.stats);
    app_state.stats_open = true;
}

fn openAchievements(app_state: *AppState) !void {
    app_state.achievements_view = .{};
    app_state.achievements_open = true;
}

fn closeAchievements(app_state: *AppState) void {
    app_state.achievements_open = false;
}

fn achievementsClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.screen.achievements.hitAt(app_state.mouse_x, app_state.mouse_y, gui) == null) return;
    clickSound(app_state);
    closeAchievements(app_state);
    try togglePause(app_state);
}

fn closeStats(app_state: *AppState) void {
    app_state.stats_view.deinit(app_state.gpa);
    app_state.stats_open = false;
}

fn statsClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    if (render.screen.stats.scrollbarAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.stats_view)) {
        app_state.dragging_scrollbar = true;
        return;
    }

    const hit = render.screen.stats.hitAt(app_state.mouse_x, app_state.mouse_y, gui, app_state.stats_view) orelse return;
    clickSound(app_state);
    switch (hit) {
        .done => closeStats(app_state),
        .tab => |tab| app_state.stats_view.tab = tab,
        .header => |column| {
            app_state.stats_view.pressed = column;
            render.screen.stats.applySort(&app_state.stats_view, &app_state.stats, column);
        },
    }
}

fn optionsClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.screen.options.hitAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    clickSound(app_state);
    switch (hit) {
        .slider => |s| {
            app_state.dragging_slider = s;
            setSlider(app_state, s, render.screen.options.sliderValueAt(s, app_state.mouse_x, gui));
        },
        .toggle_invert => {
            app_state.settings.invert_mouse = !app_state.settings.invert_mouse;
            saveOptions(app_state);
        },
        .cycle_difficulty => {
            app_state.settings.difficulty = app_state.settings.difficulty.next();
            saveOptions(app_state);
        },
        .video => app_state.video_open = true,
        .controls => app_state.controls_open = true,
        .done => try closeOptions(app_state),
    }
}

fn videoClick(app_state: *AppState) !void {
    const gui = guiSize(app_state);
    const hit = render.screen.video_settings.hitAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    clickSound(app_state);
    if (hit == .done) {
        app_state.video_open = false;
    } else {
        render.screen.video_settings.cycle(&app_state.settings, hit);
        switch (hit) {
            .ambient_occlusion, .graphics => try app_state.chunks.markAllDirty(app_state.gpa),
            .anaglyph => try refreshTextures(app_state),
            .fullscreen => applyFullscreen(app_state),
            else => {},
        }
        saveOptions(app_state);
    }
}

fn controlsClick(app_state: *AppState) void {
    const gui = guiSize(app_state);
    const hit = render.screen.controls.hitAt(app_state.mouse_x, app_state.mouse_y, gui) orelse return;
    clickSound(app_state);
    switch (hit) {
        .binding => |binding| app_state.rebinding = binding,
        .done => {
            app_state.controls_open = false;
            app_state.rebinding = null;
        },
    }
}

fn interactContext(app_state: *AppState) game.interact.Context {
    return .{
        .gpa = app_state.gpa,
        .frame = app_state.frame,
        .level = &app_state.level,
        .player = &app_state.player,
        .stats = &app_state.stats,
        .dimension = app_state.dimension,
    };
}

fn pickedBlock(app_state: *AppState) ?game.raycast.Hit {
    return interactContext(app_state).pickedBlock();
}

fn pickedEntity(app_state: *AppState) ?game.Entities.Target {
    return interactContext(app_state).pickedEntity();
}

fn applyBlockChanges(app_state: *AppState) !void {
    return interactContext(app_state).applyBlockChanges();
}

fn consumeSelectedStack(app_state: *AppState) void {
    interactContext(app_state).consumeSelectedStack();
}

fn damageHeldItem(app_state: *AppState, cost: u16) !void {
    return interactContext(app_state).damageHeldItem(cost);
}

fn wearHeldItem(app_state: *AppState, destroyed: world.Block) !void {
    return interactContext(app_state).wearHeldItem(destroyed);
}

fn spawnDroppedItem(app_state: *AppState, x: i32, y: i32, z: i32, stack: game.Inventory.ItemStack) !void {
    return interactContext(app_state).spawnDroppedItem(x, y, z, stack);
}

fn holdStack(app_state: *AppState, held: world.Item) void {
    interactContext(app_state).holdStack(held);
}

fn dismount(app_state: *AppState) void {
    interactContext(app_state).dismount();
}

fn useBlockOrPlace(app_state: *AppState) !bool {
    if (pickedEntity(app_state)) |target| return interactWithEntity(app_state, target);
    if (app_state.link) |link| return useBlockRemote(app_state, link);
    if (pickedBlock(app_state)) |hit| {
        switch (app_state.level.world_map.getBlock(hit.x, hit.y, hit.z)) {
            .workbench => {
                try openWorkbench(app_state);
                return true;
            },
            .furnace, .burning_furnace => {
                try openFurnace(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .chest => {
                try openChest(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .dispenser => {
                try openDispenser(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .door_wood => {
                try world.block_update.toggleDoor(&app_state.level.world_map, hit.x, hit.y, hit.z);
                try applyBlockChanges(app_state);
                return true;
            },
            .door_iron => return true,
            .trapdoor => {
                try world.block_update.toggleTrapdoor(&app_state.level.world_map, hit.x, hit.y, hit.z);
                try applyBlockChanges(app_state);
                return true;
            },
            .cake => {
                try game.interact.eatCakeSlice(interactContext(app_state), hit.x, hit.y, hit.z);
                return true;
            },
            .bed => {
                try sleepInBed(app_state, hit.x, hit.y, hit.z);
                return true;
            },
            .lever, .button, .repeater_off, .repeater_on => {
                _ = try world.redstone.activate(&app_state.level.world_map, hit.x, hit.y, hit.z);
                try applyBlockChanges(app_state);
                return true;
            },
            .note_block => {
                _ = try world.note.onActivated(&app_state.level.world_map, hit.x, hit.y, hit.z, .note_block);
                try applyBlockChanges(app_state);
                return true;
            },
            .jukebox => {
                if (try game.interact.ejectJukeboxRecord(interactContext(app_state), hit.x, hit.y, hit.z)) return true;
            },
            .ore_redstone => try game.interact.lightRedstoneOre(interactContext(app_state), hit.x, hit.y, hit.z),
            else => |id| {
                if (id.def().on_activated) |hook| {
                    if (try hook(&app_state.level.world_map, hit.x, hit.y, hit.z, id)) {
                        try applyBlockChanges(app_state);
                        return true;
                    }
                }
            },
        }
    }
    return placeBlockAtTarget(app_state);
}

const bed_not_valid_line = "Your home bed was missing or obstructed";

fn sleepInBed(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    const found = world.block_update.bedPillowAt(&app_state.level.world_map, x, y, z) orelse return;
    const pillow = found.at;

    if (app_state.dimension == .nether) {
        try game.bed.blowUp(app_state.gpa, &app_state.level, pillow, found.metadata);
        return try applyBlockChanges(app_state);
    }

    if (world.block.bedIsOccupied(found.metadata)) {
        if (app_state.player.sleeping and std.meta.eql(app_state.player.bed, pillow)) {
            app_state.chat.addMessage(app_state.font, game.bed.occupied_line);
            return;
        }
        try world.block_update.setBedOccupied(&app_state.level.world_map, pillow[0], pillow[1], pillow[2], false);
    }

    switch (app_state.player.sleepInBedAt(&app_state.level.world_map, app_state.dimension, pillow[0], pillow[1], pillow[2])) {
        .ok => {
            try world.block_update.setBedOccupied(&app_state.level.world_map, pillow[0], pillow[1], pillow[2], true);
            try applyBlockChanges(app_state);
        },
        .not_possible_now => app_state.chat.addMessage(app_state.font, game.bed.no_sleep_line),
        else => {},
    }
}

fn interactWithEntity(app_state: *AppState, target: game.Entities.Target) !bool {
    if (app_state.link) |link| {
        const id = switch (target) {
            inline else => |entity_id| entity_id,
        };
        if (target == .minecart) link.connection.aimAtMinecart(id);
        try link.connection.reportUse(app_state.gpa, id, false);
        return true;
    }
    if (target == .boat) {
        const boat = app_state.level.entities.boatById(target.boat) orelse return false;
        app_state.player.riding = boat.base.id;
        return true;
    }
    if (target == .minecart) return interactWithMinecart(app_state, target.minecart);
    const entry = app_state.level.entities.mobAt(target) orelse return false;
    const held: ?world.Item = if (app_state.player.inventory.selectedStack()) |stack| switch (stack.id) {
        .item => |id| id,
        .block => null,
    } else null;

    if (entry.type_id == game.mob.pig) return game.interact.interactWithPig(interactContext(app_state), entry.animal, held);
    if (entry.type_id == game.mob.wolf) return game.interact.interactWithWolf(interactContext(app_state), entry.animal, held);
    if (entry.type_id == game.mob.sheep) return game.interact.interactWithSheep(interactContext(app_state), entry.animal, held);
    if (entry.type_id != game.mob.cow) return false;

    const milked = game.Cow.interact(held orelse return false) orelse return false;
    holdStack(app_state, milked);
    try app_state.stats.use(app_state.gpa, .{ .item = held.? });
    return true;
}

fn interactWithMinecart(app_state: *AppState, id: game.Entity.Id) !bool {
    const cart = app_state.level.entities.minecartById(id) orelse return false;
    switch (cart.kind) {
        .empty => {
            if (!app_state.level.entities.boardMinecart(cart, app_state.player.base.id)) return true;
            app_state.player.riding = cart.base.id;
        },
        .chest => {
            app_state.minecart_open = cart.base.id;
            try updateMouseMode(app_state);
        },
        .furnace => {
            const held = app_state.player.inventory.selectedStack();
            if (held) |stack| {
                if (stack.id.eql(.{ .item = .coal })) {
                    consumeSelectedStack(app_state);
                    cart.fuel += game.Minecart.coal_fuel;
                }
            }
            cart.push = math.Vec3.init(
                cart.base.position.x - app_state.player.base.position.x,
                0,
                cart.base.position.z - app_state.player.base.position.z,
            );
        },
    }
    return true;
}

fn placeSignAtTarget(app_state: *AppState) !bool {
    const hit = pickedBlock(app_state) orelse return false;
    if (hit.face == .down) return false;
    if (!app_state.level.world_map.getBlock(hit.x, hit.y, hit.z).material().isSolid()) return false;

    const target = world.block_update.placementTarget(&app_state.level.world_map, hit.x, hit.y, hit.z, hit.face);
    if (target.y < 0 or target.y >= world.Chunk.height) return false;
    if (!app_state.level.world_map.getBlock(target.x, target.y, target.z).isReplaceable()) return false;

    if (hit.face == .up) {
        const facing = world.block.signPostFacingFromYaw(app_state.player.yaw);
        try app_state.level.world_map.setBlockAndMetadataWithNotify(target.x, target.y, target.z, .sign_post, facing);
    } else {
        try app_state.level.world_map.setBlockAndMetadataWithNotify(
            target.x,
            target.y,
            target.z,
            .wall_sign,
            @intFromEnum(hit.face),
        );
    }

    _ = try app_state.level.world_map.addSign(target.x, target.y, target.z);
    try app_state.stats.use(app_state.gpa, .{ .item = .sign });
    consumeSelectedStack(app_state);
    try applyBlockChanges(app_state);
    openSignEditor(app_state, target.x, target.y, target.z);
    return true;
}

fn useFishingRod(app_state: *AppState) !bool {
    const caught = try app_state.level.entities.reelHook(
        app_state.gpa,
        &app_state.player,
        &app_state.level.world_map.rand,
    );

    if (caught) |what| {
        if (what == .fish) try app_state.stats.add(app_state.gpa, .{ .general = .fish_caught }, 1);
        try damageHeldItem(app_state, @intFromEnum(what));
        swingArm(app_state);
        return true;
    }

    try app_state.level.entities.castHook(
        app_state.gpa,
        &app_state.player,
        &app_state.level.world_map.rand,
    );
    swingArm(app_state);
    return true;
}

fn useBlockRemote(app_state: *AppState, link: *Link) !bool {
    const held: ?net.packet.Stack = if (app_state.player.inventory.selectedStack()) |stack| .{
        .id = stack.id.numeric(),
        .count = @intCast(stack.count),
        .damage = @bitCast(@as(u16, stack.meta)),
    } else null;

    const hit = pickedBlock(app_state) orelse {
        try link.connection.reportUseInAir(app_state.gpa, held);
        return true;
    };

    try link.connection.reportPlace(app_state.gpa, hit.x, hit.y, hit.z, faceIndex(hit.face), held);
    try openRemoteSignEditor(app_state, hit);
    return true;
}

fn enterServerDimension(app_state: *AppState, target: world.Dimension) !void {
    app_state.level.closeWorld(app_state.gpa);
    app_state.chunks.deinit(app_state.gpa);
    app_state.chunks = .{};

    try app_state.level.reseed(app_state.gpa, target, app_state.level.generator.worldSeed());
    app_state.dimension = target;
    app_state.level.world_map.access = worldAccess(app_state);
    app_state.level.world_map.sound_sink = soundSink(app_state);
    app_state.level.world_map.note_sink = noteSink(app_state);
    app_state.level.world_map.brightness = world.light.brightnessTable(target.ambientLight());
    app_state.level.world_map.has_sky = target.hasSky();

    try app_state.level.enter(app_state.gpa, &app_state.player);
    app_state.held_stack = null;
    try closeContainer(app_state);
}

fn adoptServerScreen(app_state: *AppState, link: *Link) !void {
    const open = link.connection.opened orelse {
        if (!containerOpen(app_state)) return;
        if (app_state.sign_edit != null) return;
        app_state.inventory_open = false;
        app_state.workbench_open = false;
        app_state.furnace_open = null;
        app_state.chest_open = null;
        app_state.dispenser_open = null;
        app_state.minecart_open = game.Entity.no_id;
        try updateMouseMode(app_state);
        return;
    };

    switch (open.kind) {
        remote.Connection.window_workbench => {
            if (app_state.workbench_open) return;
            app_state.workbench_open = true;
        },
        remote.Connection.window_furnace => {
            if (app_state.furnace_open != null) return;
            app_state.furnace_open = .{ .x = open.at[0], .y = open.at[1], .z = open.at[2] };
        },
        remote.Connection.window_dispenser => {
            if (app_state.dispenser_open != null) return;
            app_state.dispenser_open = .{ .x = open.at[0], .y = open.at[1], .z = open.at[2] };
        },
        remote.Connection.window_chest => {
            if (open.cart != game.Entity.no_id) {
                if (app_state.minecart_open == open.cart) return;
                app_state.minecart_open = open.cart;
            } else {
                if (app_state.chest_open != null) return;
                app_state.chest_open = .{ .x = open.at[0], .y = open.at[1], .z = open.at[2] };
            }
        },
        else => return,
    }
    app_state.inventory_open = false;
    try updateMouseMode(app_state);
}

fn openRemoteSignEditor(app_state: *AppState, hit: game.raycast.Hit) !void {
    const stack = app_state.player.inventory.selectedStack() orelse return;
    if (stack.id != .item or stack.id.item != .sign) return;
    if (hit.face == .down) return;

    const target = world.block_update.placementTarget(&app_state.level.world_map, hit.x, hit.y, hit.z, hit.face);
    if (target.y < 0 or target.y >= world.Chunk.height) return;
    _ = try app_state.level.world_map.addSign(target.x, target.y, target.z);
    openSignEditor(app_state, target.x, target.y, target.z);
}

fn placeBlockAtTarget(app_state: *AppState) !bool {
    const stack = app_state.player.inventory.selectedStack() orelse return false;
    const placed = switch (stack.id) {
        .block => |b| b,
        .item => |held| blk: {
            if (held.bucketFill()) |fill| return game.interact.useBucket(interactContext(app_state), held, fill);
            if (held == .flint_and_steel) return game.interact.strikeFlintAtTarget(interactContext(app_state));
            if (held == .seeds) return game.interact.plantSeedsAtTarget(interactContext(app_state));
            if (held.tool()) |tool| {
                if (tool.kind == .hoe) return game.interact.tillWithHoe(interactContext(app_state), held);
            }
            if (held == .painting) return game.interact.hangPaintingAtTarget(interactContext(app_state));
            if (held == .bed) return game.interact.placeBedAtTarget(interactContext(app_state));
            if (held == .sign) return placeSignAtTarget(app_state);
            if (held == .boat) return game.interact.placeBoatAtTarget(interactContext(app_state));
            if (held == .fishing_rod) return useFishingRod(app_state);
            if (held.recordName() != null) return game.interact.insertRecordAtTarget(interactContext(app_state), held);
            if (held.minecartKind()) |kind| return game.interact.placeMinecartAtTarget(interactContext(app_state), kind);
            break :blk held.placedBlock() orelse {
                if (held.def().on_use) |hook| {
                    if (pickedBlock(app_state)) |hit| {
                        if (try hook(&app_state.level.world_map, hit.x, hit.y, hit.z, hit.face, held, stack.meta)) {
                            try applyBlockChanges(app_state);
                            return true;
                        }
                    }
                }
                return game.interact.placeDoorAtTarget(interactContext(app_state), held);
            };
        },
    };
    const hit = pickedBlock(app_state) orelse return false;

    if (app_state.link) |link| {
        try link.connection.reportPlace(app_state.gpa, hit.x, hit.y, hit.z, faceIndex(hit.face), .{
            .id = stack.id.numeric(),
            .count = @intCast(stack.count),
            .damage = @bitCast(@as(u16, stack.meta)),
        });
        consumeSelectedStack(app_state);
        return true;
    }

    const target = world.block_update.placementTarget(&app_state.level.world_map, hit.x, hit.y, hit.z, hit.face);
    const px = target.x;
    const py = target.y;
    const pz = target.z;
    if (py < 0 or py >= world.Chunk.height) return false;
    if (!app_state.level.world_map.getBlock(px, py, pz).isReplaceable()) return false;
    if (!world.block_update.canPlaceOnSide(&app_state.level.world_map, px, py, pz, placed, target.face)) return false;
    if (placed == .chest and !app_state.level.world_map.canPlaceChestAt(px, py, pz)) return false;
    const meta = world.block_update.placementMetadata(&app_state.level.world_map, px, py, pz, placed, target.face, stack.blockMeta());
    try app_state.level.world_map.setBlockAndMetadataWithNotify(px, py, pz, placed, meta);
    const step_sound = placed.stepSound();
    app_state.level.world_map.playSoundEffect(
        @as(f64, @floatFromInt(px)) + 0.5,
        @as(f64, @floatFromInt(py)) + 0.5,
        @as(f64, @floatFromInt(pz)) + 0.5,
        step_sound.walk(),
        (step_sound.volume() + 1.0) / 2.0,
        step_sound.pitch() * 0.8,
    );
    if (placed == .furnace) {
        const facing = world.block.furnaceFacingFromYaw(app_state.player.yaw);
        try app_state.level.world_map.setBlockMetadataWithNotify(px, py, pz, facing);
        _ = try app_state.level.world_map.addFurnace(px, py, pz);
    }
    if (placed == .chest) _ = try app_state.level.world_map.addChest(px, py, pz);
    if (placed == .dispenser) {
        const facing = world.block.dispenserFacingFromYaw(app_state.player.yaw);
        try app_state.level.world_map.setBlockMetadataWithNotify(px, py, pz, facing);
        _ = try app_state.level.world_map.addDispenser(px, py, pz);
    }
    if (placed.isStairs()) {
        const facing = world.block.stairsFacingFromYaw(app_state.player.yaw);
        try app_state.level.world_map.setBlockMetadataWithNotify(px, py, pz, facing);
    }
    if (placed == .pumpkin or placed == .jack_o_lantern) {
        const facing = world.block.pumpkinFacingFromYaw(app_state.player.yaw);
        try app_state.level.world_map.setBlockMetadataWithNotify(px, py, pz, facing);
    }
    try world.redstone.onBlockPlaced(
        &app_state.level.world_map,
        px,
        py,
        pz,
        placed,
        app_state.player.base.position,
        app_state.player.yaw,
    );
    _ = try world.block_update.mergeSlabBelow(&app_state.level.world_map, px, py, pz);
    try app_state.stats.use(app_state.gpa, stack.id);
    consumeSelectedStack(app_state);
    try applyBlockChanges(app_state);
    return true;
}

fn centimetres(value: f64) i32 {
    return @intFromFloat(@round(@as(f32, @floatCast(value)) * 100.0));
}

fn awardAchievement(app_state: *AppState, id: game.achievements.Id) !void {
    if (!try app_state.stats.award(app_state.gpa, id)) return;
    app_state.achievement_toast.announce(id, @floatFromInt(sdl3.timer.getMillisecondsSinceInit()));
}

fn drainEarnedAchievements(app_state: *AppState) !void {
    var claimed = app_state.player.takeEarned().iterator();
    while (claimed.next()) |id| try awardAchievement(app_state, id);
}

fn inventoryKeyName(app_state: *const AppState) []const u8 {
    return render.screen.controls.keyName(app_state.settings.keys.get(.inventory));
}

fn recordMountedMovement(app_state: *AppState, dx: f64, dy: f64, dz: f64) !void {
    const gpa = app_state.gpa;
    const travelled = centimetres(@sqrt(dx * dx + dy * dy + dz * dz));
    if (travelled <= 0) return;

    const mount = app_state.player.riding;
    if (app_state.level.entities.minecartById(mount) != null) {
        try app_state.stats.add(gpa, .{ .general = .distance_by_minecart }, travelled);
        const at = [3]i32{
            math.util.floorDouble(app_state.player.base.position.x),
            math.util.floorDouble(app_state.player.base.position.y),
            math.util.floorDouble(app_state.player.base.position.z),
        };
        if (app_state.player.minecart_start) |start| {
            if (blockDistance(start, at) >= minecart_ride_reach) try awardAchievement(app_state, .on_a_rail);
        } else {
            app_state.player.minecart_start = at;
        }
    } else if (app_state.level.entities.boatById(mount) != null) {
        try app_state.stats.add(gpa, .{ .general = .distance_by_boat }, travelled);
    } else if (app_state.level.entities.mobById(mount)) |entry| {
        if (entry.type_id == game.mob.pig) {
            try app_state.stats.add(gpa, .{ .general = .distance_by_pig }, travelled);
        }
    }
}

const minecart_ride_reach: f64 = 1000.0;

fn blockDistance(from: [3]i32, to: [3]i32) f64 {
    const dx: f64 = @floatFromInt(from[0] - to[0]);
    const dy: f64 = @floatFromInt(from[1] - to[1]);
    const dz: f64 = @floatFromInt(from[2] - to[2]);
    return @sqrt(dx * dx + dy * dy + dz * dz);
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

    if (player.riding != game.Entity.no_id) {
        try recordMountedMovement(app_state, dx, dy, dz);
    } else {
        player.minecart_start = null;
        if (player.isSubmerged(&app_state.level.world_map)) {
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

    try recordFlyingPig(app_state);
    try drainEarnedAchievements(app_state);
    if (!app_state.stats.hasAchievement(.open_inventory)) {
        app_state.achievement_toast.hint(.open_inventory, @floatFromInt(sdl3.timer.getMillisecondsSinceInit()));
    }
}

fn recordFlyingPig(app_state: *AppState) !void {
    const entry = app_state.level.entities.mobById(app_state.player.riding) orelse return;
    if (entry.type_id != game.mob.pig) return;
    if (entry.animal.last_fall <= pig_flight_drop) return;
    try awardAchievement(app_state, .fly_pig);
}

const pig_flight_drop: f32 = 5.0;

fn swingArm(app_state: *AppState) void {
    app_state.player.swingItem();
    const link = app_state.link orelse return;
    link.connection.reportSwing(app_state.gpa) catch {};
}

fn tickRemote(app_state: *AppState, link: *Link) !void {
    try link.pump(&app_state.level);

    const lines = try link.connection.takeChat(app_state.gpa);
    defer app_state.gpa.free(lines);
    for (lines) |line| app_state.chat.addMessage(app_state.font, line.text());

    const awards = try link.connection.takeAwards(app_state.gpa);
    defer app_state.gpa.free(awards);
    for (awards) |given| try app_state.stats.add(app_state.gpa, given.stat, given.amount);

    if (link.connection.takeDimensionChange()) |target| {
        try enterServerDimension(app_state, target);
        return;
    }

    adoptServerWindow(app_state, link);
    try adoptServerScreen(app_state, link);
    app_state.level.tick_count += 1;
    try link.connection.tickBodies(app_state.gpa, &app_state.level);
    try app_state.level.applyBlockChanges(app_state.gpa, app_state.frame);

    try link.connection.reportSneak(app_state.gpa, app_state.player.base.sneaking);
    try link.connection.reportHeldSlot(app_state.gpa, app_state.player.inventory.selected);
    if (link.connection.placed) try link.connection.reportPosition(app_state.gpa, &app_state.player);
    try link.flush();

    if (!link.isOpen()) try leaveServer(app_state);
}

fn leaveServer(app_state: *AppState) !void {
    const link = app_state.link orelse return;
    const reason = link.disconnectReason();
    if (reason) |text| app_state.chat.addMessage(app_state.font, text);

    app_state.link = null;
    link.deinit();

    closeWorld(app_state);
    app_state.screen = .title;
    try updateMouseMode(app_state);
}

fn tickSleep(app_state: *AppState) !void {
    app_state.player.tickSleep();
    if (app_state.link != null) return;
    if (!try app_state.player.tickSleepWake(&app_state.level.world_map)) return;

    try applyBlockChanges(app_state);
}

fn heldMapData(app_state: *AppState, stack: game.Inventory.ItemStack) !?*world.map.MapData {
    if (!stack.id.eql(.{ .item = .map })) return null;
    return try app_state.level.world_map.mapData(@bitCast(stack.meta));
}

fn tickCarriedMaps(app_state: *AppState) !void {
    if (app_state.link != null) return;

    const viewers = [_]world.map.ViewerState{.{
        .id = app_state.player.base.id,
        .x = app_state.player.base.position.x,
        .z = app_state.player.base.position.z,
        .dimension = @intFromEnum(app_state.dimension),
        .alive = !app_state.player.isDead(),
        .holding = true,
    }};

    for (app_state.player.inventory.slots, 0..) |carried, slot| {
        const stack = carried orelse continue;
        const data = try heldMapData(app_state, stack) orelse continue;
        try data.updateMarkers(app_state.gpa, app_state.player.yaw, &viewers);
        if (slot != app_state.player.inventory.selected) continue;
        data.updateColors(
            &app_state.level.world_map,
            @intFromEnum(app_state.dimension),
            app_state.dimension.hasSky(),
            app_state.player.base.position.x,
            app_state.player.base.position.z,
        );
    }
}

fn tick(app_state: *AppState) !void {
    stepFogBrightness(app_state);
    if (touch_ui) try touchTick(app_state);
    if (app_state.sound) |*sound| sound.playRandomMusicIfReady() catch {};
    app_state.chat.tick();
    if (app_state.sign_edit) |*open| open.tick();

    try tickSleep(app_state);
    if (app_state.freecam.active) {
        app_state.freecam.beginTick();
        app_state.freecam.move(
            (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0),
            (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0),
            (if (app_state.keys.jump) @as(f32, 1) else 0) - (if (app_state.keys.sneak) @as(f32, 1) else 0),
        );
    }
    const moving_allowed = !containerOpen(app_state) and !app_state.dead and
        !app_state.player.isMovementBlocked() and !app_state.freecam.active;
    const forward: f32 = if (!moving_allowed) 0 else (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = if (!moving_allowed) 0 else (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    const before_move = app_state.player.base.position;
    const was_in_water = app_state.player.base.in_water;
    if (app_state.player.riding != game.Entity.no_id) {
        app_state.player.tickRidden(strafe, forward);
        if (moving_allowed and app_state.keys.sneak) dismount(app_state);
    } else {
        app_state.player.tick(
            &app_state.level.world_map,
            strafe,
            forward,
            moving_allowed and app_state.keys.jump,
            moving_allowed and app_state.keys.sneak,
        );
    }
    try recordPlayerTick(app_state, before_move);
    if (app_state.player.isDead() and !app_state.dead) try killPlayer(app_state);
    if (!was_in_water and app_state.player.base.in_water and app_state.level.tick_count > 0) {
        try app_state.level.entities.spawnWaterSplash(app_state.gpa, &app_state.level.world_map, app_state.player.base, &app_state.level.world_map.rand);
    }
    if (app_state.player.drowned) {
        try app_state.level.entities.spawnDrowningBubbles(
            app_state.gpa,
            app_state.player.eyePosition(),
            app_state.player.base.motion,
            &app_state.level.world_map.rand,
        );
    }
    if (app_state.missed_click_cooldown > 0) app_state.missed_click_cooldown -= 1;
    if (app_state.mouse_left_down and app_state.level.tick_count - app_state.last_held_swing_tick >= 5) {
        try clickLeft(app_state);
        app_state.last_held_swing_tick = app_state.level.tick_count;
    }
    app_state.player.tickSwing();
    try tickCarriedMaps(app_state);
    app_state.equip.tick(app_state.player.inventory.selectedStack());
    try digStep(app_state);

    app_state.level.world_map.difficulty =
        if (app_state.link != null) .hard else app_state.settings.difficulty;

    if (app_state.link) |link| {
        app_state.level.standInPortals();
        _ = app_state.player.tickPortal();
        try tickRemote(app_state, link);
    } else {
        try app_state.level.tick(app_state.gpa, app_state.frame);
        if (app_state.player.tickPortal() == .travel) {
            try usePortal(app_state);
            return;
        }
    }

    app_state.cloud_offset += 1;

    try app_state.level.entities.tickParticles(app_state.gpa, &app_state.level.world_map, &app_state.level.world_map.rand);
    app_state.level.entities.tickPickups();
    try spawnDisplayParticles(app_state);
    try spawnRainParticles(app_state);
    try ensureChunksAroundPlayer(app_state);

    if (app_state.link != null) return;

    app_state.ticks_since_save += 1;
    if (app_state.ticks_since_save >= autosave_interval_ticks) {
        app_state.ticks_since_save = 0;
        try app_state.level.world_map.saveDirtyMaps();
        try saveLevel(app_state);
        try app_state.level.world_map.beginSaveRound();
        _ = try app_state.level.world_map.saveQueuedChunks(save_chunks_per_pass);
    }
}

const display_particle_samples = 1000;
const display_particle_range = 16;

const rain_particle_reach: i32 = 10;
const rain_particle_samples: f32 = 100.0;
const rain_sound_near: f32 = 0.2;
const rain_sound_far: f32 = 0.1;

fn spawnRainParticles(app_state: *AppState) !void {
    if (!app_state.dimension.hasSky()) return;

    var strength = app_state.level.world_map.weather.rainStrength(1.0);
    if (!app_state.settings.fancy_graphics) strength /= 2.0;
    if (strength <= 0.0) return;

    const rand = &app_state.level.world_map.rand;
    const feet = app_state.player.base.position;
    const px = math.util.floorDouble(feet.x);
    const py = math.util.floorDouble(feet.y);
    const pz = math.util.floorDouble(feet.z);

    var heard: u32 = 0;
    var loudest = math.Vec3.init(0, 0, 0);

    const attempts: usize = @intFromFloat(rain_particle_samples * strength * strength);
    for (0..attempts) |_| {
        const x = px + rand.nextIntBound(rain_particle_reach) - rand.nextIntBound(rain_particle_reach);
        const z = pz + rand.nextIntBound(rain_particle_reach) - rand.nextIntBound(rain_particle_reach);
        const top = app_state.level.world_map.findTopSolidBlock(x, z);
        if (top > py + rain_particle_reach or top < py - rain_particle_reach) continue;
        if (!app_state.level.world_map.biomeAt(x, z).canSpawnLightningBolt()) continue;

        const under = app_state.level.world_map.getBlock(x, top - 1, z);
        if (under == .air) continue;

        const at = math.Vec3.init(
            @as(f64, @floatFromInt(x)) + rand.nextFloat(),
            @as(f64, @floatFromInt(top)) + 0.1,
            @as(f64, @floatFromInt(z)) + rand.nextFloat(),
        );

        if (under == .flowing_lava or under == .stationary_lava) {
            try app_state.level.entities.particles.append(
                app_state.gpa,
                game.Particle.spawnSmoke(at, math.Vec3.init(0, 0, 0), rand),
            );
            continue;
        }

        heard += 1;
        if (rand.nextIntBound(@intCast(heard)) == 0) loudest = at;
        try app_state.level.entities.particles.append(
            app_state.gpa,
            game.Particle.spawnRain(at, rand),
        );
    }

    if (heard == 0) return;
    if (rand.nextIntBound(3) >= @as(i32, @intCast(app_state.rain_sound_ticks))) {
        app_state.rain_sound_ticks += 1;
        return;
    }
    app_state.rain_sound_ticks = 0;

    const overhead = loudest.y > feet.y + 1.0 and
        app_state.level.world_map.findTopSolidBlock(px, pz) > py;
    app_state.level.world_map.playSoundEffect(
        loudest.x,
        loudest.y,
        loudest.z,
        assets.sounds.ambient.weather.rain,
        if (overhead) rain_sound_far else rain_sound_near,
        if (overhead) 0.5 else 1.0,
    );
}

const fire_sound_chance = 24;
const portal_sound_chance = 100;
const water_sound_chance = 64;

fn spawnDisplayParticles(app_state: *AppState) !void {
    const rand = &app_state.level.world_map.rand;
    const px = math.util.floorDouble(app_state.player.base.position.x);
    const py = math.util.floorDouble(app_state.player.base.position.y);
    const pz = math.util.floorDouble(app_state.player.base.position.z);
    for (0..display_particle_samples) |_| {
        const x = px + rand.nextIntBound(display_particle_range) - rand.nextIntBound(display_particle_range);
        const y = py + rand.nextIntBound(display_particle_range) - rand.nextIntBound(display_particle_range);
        const z = pz + rand.nextIntBound(display_particle_range) - rand.nextIntBound(display_particle_range);
        switch (app_state.level.world_map.getBlock(x, y, z)) {
            .flowing_lava, .stationary_lava => {
                if (app_state.level.world_map.getBlock(x, y + 1, z) != .air) continue;
                if (rand.nextIntBound(100) != 0) continue;
                const position = math.Vec3.init(
                    @as(f64, @floatFromInt(x)) + @as(f64, rand.nextFloat()),
                    @as(f64, @floatFromInt(y)) + 1.0,
                    @as(f64, @floatFromInt(z)) + @as(f64, rand.nextFloat()),
                );
                try app_state.level.entities.particles.append(app_state.gpa, game.Particle.spawnLava(position, rand));
            },
            .portal => {
                if (rand.nextIntBound(portal_sound_chance) == 0) {
                    app_state.level.world_map.playSoundEffect(
                        @as(f64, @floatFromInt(x)) + 0.5,
                        @as(f64, @floatFromInt(y)) + 0.5,
                        @as(f64, @floatFromInt(z)) + 0.5,
                        assets.sounds.portal.portal,
                        1.0,
                        rand.nextFloat() * 0.4 + 0.8,
                    );
                }
                try app_state.level.entities.spawnPortalParticles(
                    app_state.gpa,
                    x,
                    y,
                    z,
                    world.portal.spansX(&app_state.level.world_map, x, y, z),
                    rand,
                );
            },
            .flowing_water, .stationary_water => {
                if (rand.nextIntBound(water_sound_chance) != 0) continue;
                const meta = app_state.level.world_map.getBlockMetadata(x, y, z);
                if (meta == 0 or meta >= 8) continue;
                app_state.level.world_map.playSoundEffect(
                    @as(f64, @floatFromInt(x)) + 0.5,
                    @as(f64, @floatFromInt(y)) + 0.5,
                    @as(f64, @floatFromInt(z)) + 0.5,
                    assets.sounds.liquid.water,
                    rand.nextFloat() * 0.25 + 12.0 / 16.0,
                    rand.nextFloat() * 1.0 + 0.5,
                );
            },
            .fire => {
                if (rand.nextIntBound(fire_sound_chance) == 0) {
                    app_state.level.world_map.playSoundEffect(
                        @as(f64, @floatFromInt(x)) + 0.5,
                        @as(f64, @floatFromInt(y)) + 0.5,
                        @as(f64, @floatFromInt(z)) + 0.5,
                        assets.sounds.fire.fire,
                        1.0 + rand.nextFloat(),
                        rand.nextFloat() * 0.7 + 0.3,
                    );
                }
                try app_state.level.entities.spawnFireParticles(
                    app_state.gpa,
                    &app_state.level.world_map,
                    x,
                    y,
                    z,
                    rand,
                );
            },
            .torch => try app_state.level.entities.spawnTorchParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.level.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .redstone_wire => try app_state.level.entities.spawnWireParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.level.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .torch_redstone_on => try app_state.level.entities.spawnRedstoneTorchParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.level.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .repeater_on => try app_state.level.entities.spawnRepeaterParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.level.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            .ore_redstone_glowing => try app_state.level.entities.spawnRedstoneOreParticles(
                app_state.gpa,
                &app_state.level.world_map,
                x,
                y,
                z,
                rand,
            ),
            .burning_furnace => try app_state.level.entities.spawnFurnaceParticles(
                app_state.gpa,
                x,
                y,
                z,
                app_state.level.world_map.getBlockMetadata(x, y, z),
                rand,
            ),
            else => {},
        }
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
    if (app_state.freecam.active) {
        const eye = app_state.freecam.position;
        return game.physics.isInsideWater(&app_state.level.world_map, eye.x, eye.y, eye.z);
    }
    return app_state.player.isSubmerged(&app_state.level.world_map);
}

fn cameraInLava(app_state: *const AppState) bool {
    if (app_state.freecam.active) {
        const eye = app_state.freecam.position;
        return game.physics.isInsideMaterial(&app_state.level.world_map, .lava, eye.x, eye.y, eye.z);
    }
    return app_state.player.isEyeInLava(&app_state.level.world_map);
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
        &app_state.level.world_map,
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
    const to_spawn_x = @as(f64, @floatFromInt(app_state.level.spawn[0])) - app_state.player.base.position.x;
    const to_spawn_z = @as(f64, @floatFromInt(app_state.level.spawn[2])) - app_state.player.base.position.z;
    return @as(f64, app_state.player.yaw - 90.0) * std.math.pi / 180.0 - std.math.atan2(to_spawn_z, to_spawn_x);
}

fn clockAngle(app_state: *const AppState) f64 {
    if (app_state.screen != .playing) return 0.0;
    return -@as(f64, app_state.level.world_map.celestialAngle(1.0)) * std.math.pi * 2.0;
}

fn horizonColor(app_state: *const AppState) render.sky.Color {
    const near = if (cameraSubmerged(app_state))
        underwater_fog_color
    else if (cameraInLava(app_state))
        lava_fog_color
    else if (!app_state.dimension.hasSky())
        app_state.dimension.fogColor()
    else blended: {
        const temperature: f32 = @floatCast(app_state.level.generator.temperatureAt(
            math.util.floorDouble(app_state.player.base.position.x),
            math.util.floorDouble(app_state.player.base.position.z),
        ));
        const render_distance = @intFromEnum(app_state.settings.render_distance);
        const partial = app_state.timer.render_partial_ticks;
        const angle = app_state.level.world_map.celestialAngle(partial);
        const weather = app_state.level.world_map.weather;
        break :blended render.sky.weatheredFogColor(
            render.sky.blendedFogColor(
                render.sky.skyColor(temperature, angle),
                render.sky.fogColor(angle),
                render_distance,
            ),
            weather.rainStrength(partial),
            weather.thunderStrength(partial),
        );
    };

    return render.anaglyph.color(app_state.settings.anaglyph, render.sky.dimmed(near, fogBrightness(app_state)));
}

fn setupFog(app_state: *const AppState, horizon: render.sky.Color) void {
    app_state.shader.setInt(.u_fog_enabled, 1);
    app_state.shader.setVec3(.u_fog_color, horizon);

    if (cameraFogDensity(app_state)) |density| {
        app_state.shader.setInt(.u_fog_exponential, 1);
        app_state.shader.setFloat(.u_fog_density, density);
        return;
    }

    const far = render.sky.farPlaneDistance(@intFromEnum(app_state.settings.render_distance));
    app_state.shader.setInt(.u_fog_exponential, 0);
    app_state.shader.setFloat(.u_fog_start, far * 0.25);
    app_state.shader.setFloat(.u_fog_end, far);
}

fn updateListener(app_state: *AppState) void {
    const sound = if (app_state.sound) |*value| value else return;
    const player = &app_state.player;
    const partial = app_state.timer.render_partial_ticks;
    if (app_state.freecam.active) {
        const camera = app_state.freecam.renderPosition(partial);
        const camera_yaw = app_state.freecam.prev_yaw +
            (app_state.freecam.yaw - app_state.freecam.prev_yaw) * partial;
        sound.setListener(.init(camera.x, camera.y, camera.z), camera_yaw) catch {};
        return;
    }
    const position = player.base.renderPosition(partial);
    const yaw = player.prev_yaw + (player.yaw - player.prev_yaw) * partial;
    sound.setListener(.init(position.x, position.y + game.Player.eye_height, position.z), yaw) catch {};
}

fn renderWorld(app_state: *AppState, horizon: render.sky.Color) !void {
    const pass = app_state.anaglyph_pass;
    updateListener(app_state);
    if (pass == null or pass.? == 0) {
        app_state.chunk_updates_this_second += try app_state.chunks.flush(app_state.gpa, &app_state.level.world_map, app_state.colorizer, .{
            .smooth = app_state.settings.ambient_occlusion,
            .fancy = app_state.settings.fancy_graphics,
            .anaglyph = app_state.settings.anaglyph,
        }, app_state.player.base.position.x, app_state.player.base.position.z, app_state.settings.framerate_limit.rebuildDeadlineNs(app_state.frame_started_ns));
    }

    const px = drawableSize(app_state);
    const aspect: f32 = @as(f32, @floatFromInt(px.w)) / @as(f32, @floatFromInt(px.h));
    const fov = if (cameraSubmerged(app_state))
        underwater_fov_degrees * std.math.pi / 180.0
    else
        fov_y_radians;
    const proj = render.anaglyph.projection(pass, math.Mat4.perspective(fov, aspect, near_plane, far_plane));
    const partial = app_state.timer.render_partial_ticks;
    const eye_view = app_state.player.viewMatrix(partial);
    const camera = if (app_state.freecam.active)
        app_state.freecam.viewMatrix(partial)
    else if (app_state.player.sleeping)
        app_state.player.sleepViewMatrix(&app_state.level.world_map, partial)
    else if (app_state.third_person) pulled: {
        const distance = app_state.player.thirdPersonDistance(&app_state.level.world_map, partial);
        break :pulled math.Mat4.translation(0, 0, @floatCast(-distance)).mul(eye_view);
    } else eye_view;
    const hurt = app_state.player.hurtMatrix(partial);
    const warp = portalWarp(app_state, partial);
    const view = render.anaglyph.view(pass, if (app_state.freecam.active)
        camera
    else if (app_state.settings.view_bobbing)
        hurt.mul(app_state.player.bobMatrix(partial)).mul(warp).mul(camera)
    else
        hurt.mul(warp).mul(camera));
    const view_proj = proj.mul(view);
    const eye = app_state.player.base.renderPosition(partial);
    const camera_eye = if (app_state.freecam.active)
        app_state.freecam.renderPosition(partial)
    else
        math.Vec3.init(eye.x, eye.y + game.Player.eye_height, eye.z);

    app_state.shader.use();
    try drawSky(app_state, proj, partial, horizon);

    app_state.shader.setMat4(.u_view_proj, view_proj.m);
    app_state.shader.setVec3(.u_camera_pos, .{
        @floatCast(camera_eye.x),
        @floatCast(camera_eye.y),
        @floatCast(camera_eye.z),
    });
    setupFog(app_state, horizon);
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.textures.terrain.bind();
    app_state.shader.setInt(.u_atlas, 0);
    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.shader.setInt(.u_textured, 1);
    app_state.shader.setVec4(.u_tint, .{ 1, 1, 1, 1 });
    const frustum = math.Frustum.fromViewProjection(view_proj);
    gl.Enable(gl.CULL_FACE);
    app_state.chunks_drawn = try app_state.chunks.drawSolid(
        app_state.frame,
        app_state.shader,
        frustum,
        .{ .x = camera_eye.x, .y = camera_eye.y, .z = camera_eye.z },
        app_state.settings.advanced_opengl and pass == null,
        app_state.cloud_offset,
    );

    var atlas_mesh: render.MeshBuilder = .{};
    defer atlas_mesh.deinit(app_state.frame);
    var shadow_mesh: render.MeshBuilder = .{};
    defer shadow_mesh.deinit(app_state.frame);
    for (app_state.level.entities.items.items) |item| {
        try render.entity_render.appendItem(&atlas_mesh, app_state.frame, &app_state.level.world_map, item, partial);
        if (app_state.settings.fancy_graphics) {
            try render.entity_render.appendItemShadow(&shadow_mesh, app_state.frame, &app_state.level.world_map, item, camera_eye, partial);
        }
    }
    if (app_state.settings.fancy_graphics) {
        for (app_state.level.entities.mobs.items) |mob| {
            try render.entity_render.appendEntityShadow(
                &shadow_mesh,
                app_state.frame,
                &app_state.level.world_map,
                mob.animal.base,
                render.entity_render.mobShadowSize(mob.type_id),
                render.entity_render.shadow_opacity,
                camera_eye,
                partial,
            );
        }
    }
    for (app_state.level.entities.pickups.items) |fx| {
        const swallowed = fx.swallowed(&app_state.player, partial);
        try render.entity_render.appendItem(&atlas_mesh, app_state.frame, &app_state.level.world_map, swallowed, partial);
    }
    for (app_state.level.entities.falling_blocks.items) |block| {
        try render.entity_render.appendFallingBlock(&atlas_mesh, app_state.frame, &app_state.level.world_map, block, partial);
    }
    for (app_state.level.entities.primed.items) |lit| {
        try render.entity_render.appendPrimedTnt(&atlas_mesh, app_state.frame, &app_state.level.world_map, lit, partial);
    }
    var moving_pistons = app_state.level.world_map.pistons.iterator();
    while (moving_pistons.next()) |entry| {
        try render.entity_render.appendMovingPiston(
            &atlas_mesh,
            app_state.frame,
            &app_state.level.world_map,
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
    for (app_state.level.entities.particles.items) |particle| {
        const target = switch (particle.kind) {
            .digging => &atlas_mesh,
            .slime => &item_particle_mesh,
            else => &particle_mesh,
        };
        try render.entity_render.appendParticle(target, app_state.frame, &app_state.level.world_map, particle, basis, partial);
    }
    for (app_state.level.entities.hooks.items) |hook| {
        if (hook.dead) continue;
        try render.entity_render.appendFishHook(&particle_mesh, app_state.frame, &app_state.level.world_map, hook, basis, partial);
    }
    var item_billboard_mesh: render.MeshBuilder = .{};
    defer item_billboard_mesh.deinit(app_state.frame);
    for (app_state.level.entities.fireballs.items) |fireball| {
        if (fireball.dead) continue;
        try render.entity_render.appendFireball(&item_billboard_mesh, app_state.frame, fireball, basis, partial);
        try render.entity_render.appendEntityFire(&atlas_mesh, app_state.frame, fireball.base, basis, partial);
    }
    for (app_state.level.entities.thrown.items) |projectile| {
        if (projectile.dead) continue;
        try render.entity_render.appendThrown(&item_billboard_mesh, app_state.frame, projectile, basis, partial);
    }
    for (app_state.level.entities.mobs.items) |mob| {
        if (mob.animal.fire <= 0) continue;
        try render.entity_render.appendEntityFire(&atlas_mesh, app_state.frame, mob.animal.base, basis, partial);
    }
    drawEntityMesh(&atlas_mesh);
    if (shadow_mesh.vertices.items.len > 0) {
        app_state.textures.shadow.bind();
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.DepthMask(gl.FALSE);
        drawEntityMesh(&shadow_mesh);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        app_state.textures.terrain.bind();
    }
    try drawPrimedTntFlash(app_state, partial);
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
    if (item_billboard_mesh.vertices.items.len > 0) {
        app_state.textures.items.bind();
        drawEntityMesh(&item_billboard_mesh);
        app_state.textures.terrain.bind();
    }

    var cart_mesh: render.MeshBuilder = .{};
    defer cart_mesh.deinit(app_state.frame);
    var cargo_mesh: render.MeshBuilder = .{};
    defer cargo_mesh.deinit(app_state.frame);
    for (app_state.level.entities.minecarts.items) |cart| {
        if (cart.dead) continue;
        try render.entity_render.appendMinecart(&cart_mesh, app_state.frame, &app_state.level.world_map, cart, partial);
        try render.entity_render.appendMinecartCargo(&cargo_mesh, app_state.frame, &app_state.level.world_map, cart, partial);
    }

    var boat_mesh: render.MeshBuilder = .{};
    defer boat_mesh.deinit(app_state.frame);
    for (app_state.level.entities.boats.items) |boat| {
        if (boat.dead) continue;
        try render.entity_render.appendBoat(&boat_mesh, app_state.frame, &app_state.level.world_map, boat, partial);
    }

    var pig_mesh: render.MeshBuilder = .{};
    defer pig_mesh.deinit(app_state.frame);
    var saddle_mesh: render.MeshBuilder = .{};
    defer saddle_mesh.deinit(app_state.frame);
    var pigs = app_state.level.entities.of(game.Pig, game.mob.pig);
    while (pigs.next()) |pig| {
        try render.entity_render.appendPig(&pig_mesh, app_state.frame, &app_state.level.world_map, pig.*, partial);
        if (pig.saddled) {
            try render.entity_render.appendPigSaddle(&saddle_mesh, app_state.frame, &app_state.level.world_map, pig.*, partial);
        }
    }
    var cow_mesh: render.MeshBuilder = .{};
    defer cow_mesh.deinit(app_state.frame);
    var cows = app_state.level.entities.of(game.Cow, game.mob.cow);
    while (cows.next()) |cow| {
        try render.entity_render.appendCow(&cow_mesh, app_state.frame, &app_state.level.world_map, cow.*, partial);
    }
    var chicken_mesh: render.MeshBuilder = .{};
    defer chicken_mesh.deinit(app_state.frame);
    var chickens = app_state.level.entities.of(game.Chicken, game.mob.chicken);
    while (chickens.next()) |chicken| {
        try render.entity_render.appendChicken(&chicken_mesh, app_state.frame, &app_state.level.world_map, chicken.*, partial);
    }
    var sheep_mesh: render.MeshBuilder = .{};
    defer sheep_mesh.deinit(app_state.frame);
    var fleece_mesh: render.MeshBuilder = .{};
    defer fleece_mesh.deinit(app_state.frame);
    var flock = app_state.level.entities.of(game.Sheep, game.mob.sheep);
    while (flock.next()) |sheep| {
        try render.entity_render.appendSheep(&sheep_mesh, app_state.frame, &app_state.level.world_map, sheep.*, partial);
        if (!sheep.sheared) {
            try render.entity_render.appendSheepFur(&fleece_mesh, app_state.frame, &app_state.level.world_map, sheep.*, partial);
        }
    }
    var slime_mesh: render.MeshBuilder = .{};
    defer slime_mesh.deinit(app_state.frame);
    var slime_shell_mesh: render.MeshBuilder = .{};
    defer slime_shell_mesh.deinit(app_state.frame);
    var slimes = app_state.level.entities.of(game.Slime, game.mob.slime);
    while (slimes.next()) |slime| {
        try render.entity_render.appendSlime(&slime_mesh, app_state.frame, &app_state.level.world_map, slime.*, partial);
        try render.entity_render.appendSlimeShell(&slime_shell_mesh, app_state.frame, &app_state.level.world_map, slime.*, partial);
    }
    var squid_mesh: render.MeshBuilder = .{};
    defer squid_mesh.deinit(app_state.frame);
    var shoal = app_state.level.entities.of(game.Squid, game.mob.squid);
    while (shoal.next()) |squid| {
        try render.entity_render.appendSquid(&squid_mesh, app_state.frame, &app_state.level.world_map, squid.*, partial);
    }
    var ghast_mesh: render.MeshBuilder = .{};
    defer ghast_mesh.deinit(app_state.frame);
    var ghast_fire_mesh: render.MeshBuilder = .{};
    defer ghast_fire_mesh.deinit(app_state.frame);
    var ghasts = app_state.level.entities.of(game.Ghast, game.mob.ghast);
    while (ghasts.next()) |ghast| {
        const face = if (ghast.isAttacking()) &ghast_fire_mesh else &ghast_mesh;
        try render.entity_render.appendGhast(face, app_state.frame, &app_state.level.world_map, ghast.*, partial);
    }
    var wolf_mesh: render.MeshBuilder = .{};
    defer wolf_mesh.deinit(app_state.frame);
    var wolf_tame_mesh: render.MeshBuilder = .{};
    defer wolf_tame_mesh.deinit(app_state.frame);
    var wolf_angry_mesh: render.MeshBuilder = .{};
    defer wolf_angry_mesh.deinit(app_state.frame);
    var pack = app_state.level.entities.of(game.Wolf, game.mob.wolf);
    while (pack.next()) |wolf| {
        const coat = if (wolf.tamed) &wolf_tame_mesh else if (wolf.angry) &wolf_angry_mesh else &wolf_mesh;
        try render.entity_render.appendWolf(coat, app_state.frame, &app_state.level.world_map, wolf.*, partial);
    }
    var spider_mesh: render.MeshBuilder = .{};
    defer spider_mesh.deinit(app_state.frame);
    var spider_eyes_mesh: render.MeshBuilder = .{};
    defer spider_eyes_mesh.deinit(app_state.frame);
    var spiders = app_state.level.entities.of(game.Spider, game.mob.spider);
    while (spiders.next()) |spider| {
        try render.entity_render.appendSpider(&spider_mesh, app_state.frame, &app_state.level.world_map, spider.*, partial);
        try render.entity_render.appendSpiderEyes(&spider_eyes_mesh, app_state.frame, &app_state.level.world_map, spider.*, partial);
    }
    var skeleton_mesh: render.MeshBuilder = .{};
    defer skeleton_mesh.deinit(app_state.frame);
    var bow_mesh: render.MeshBuilder = .{};
    defer bow_mesh.deinit(app_state.frame);
    var skeletons = app_state.level.entities.of(game.Skeleton, game.mob.skeleton);
    while (skeletons.next()) |skeleton| {
        try render.entity_render.appendSkeleton(&skeleton_mesh, app_state.frame, &app_state.level.world_map, skeleton.*, partial);
        try render.entity_render.appendSkeletonBow(&bow_mesh, app_state.frame, &app_state.level.world_map, skeleton.*, partial);
    }
    var creeper_mesh: render.MeshBuilder = .{};
    defer creeper_mesh.deinit(app_state.frame);
    var creepers = app_state.level.entities.of(game.Creeper, game.mob.creeper);
    while (creepers.next()) |creeper| {
        try render.entity_render.appendCreeper(&creeper_mesh, app_state.frame, &app_state.level.world_map, creeper.*, partial);
    }
    var zombie_mesh: render.MeshBuilder = .{};
    defer zombie_mesh.deinit(app_state.frame);
    var shamblers = app_state.level.entities.of(game.Zombie, game.mob.zombie);
    while (shamblers.next()) |zombie| {
        try render.entity_render.appendZombie(&zombie_mesh, app_state.frame, &app_state.level.world_map, zombie.*, partial);
    }
    var pig_zombie_mesh: render.MeshBuilder = .{};
    defer pig_zombie_mesh.deinit(app_state.frame);
    var horde = app_state.level.entities.of(game.PigZombie, game.mob.pig_zombie);
    while (horde.next()) |pig_zombie| {
        try render.entity_render.appendPigZombie(&pig_zombie_mesh, app_state.frame, &app_state.level.world_map, pig_zombie.*, partial);
    }
    var painting_mesh: render.MeshBuilder = .{};
    defer painting_mesh.deinit(app_state.frame);
    for (app_state.level.entities.paintings.items) |painting| {
        try render.entity_render.appendPainting(&painting_mesh, app_state.frame, &app_state.level.world_map, painting);
    }
    if (painting_mesh.vertices.items.len > 0) {
        app_state.textures.art.bind();
        drawEntityMesh(&painting_mesh);
        app_state.textures.terrain.bind();
    }

    var arrow_mesh: render.MeshBuilder = .{};
    defer arrow_mesh.deinit(app_state.frame);
    for (app_state.level.entities.arrows.items) |arrow| {
        try render.entity_render.appendArrow(&arrow_mesh, app_state.frame, &app_state.level.world_map, arrow, partial);
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
    var signs = app_state.level.world_map.signs.iterator();
    while (signs.next()) |entry| {
        const pos = entry.key_ptr.*;
        const id = app_state.level.world_map.getBlock(pos.x, pos.y, pos.z);
        if (!id.isSign()) continue;
        const meta = app_state.level.world_map.getBlockMetadata(pos.x, pos.y, pos.z);
        try render.sign_render.appendBoard(
            &sign_mesh,
            app_state.frame,
            &app_state.level.world_map,
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
    for (app_state.level.entities.items.items) |item| {
        try render.entity_render.appendItemIcon(&icon_mesh, app_state.frame, &app_state.level.world_map, item, app_state.player.yaw, partial);
    }
    for (app_state.level.entities.pickups.items) |fx| {
        const swallowed = fx.swallowed(&app_state.player, partial);
        try render.entity_render.appendItemIcon(&icon_mesh, app_state.frame, &app_state.level.world_map, swallowed, app_state.player.yaw, partial);
    }
    if (icon_mesh.vertices.items.len > 0) {
        app_state.textures.items.bind();
        drawEntityMesh(&icon_mesh);
        app_state.textures.terrain.bind();
    }

    if (boat_mesh.vertices.items.len > 0) {
        app_state.textures.boat.bind();
        drawEntityMesh(&boat_mesh);
    }
    if (cargo_mesh.vertices.items.len > 0) {
        app_state.textures.terrain.bind();
        drawEntityMesh(&cargo_mesh);
    }
    if (cart_mesh.vertices.items.len > 0) {
        app_state.textures.cart.bind();
        drawEntityMesh(&cart_mesh);
        app_state.textures.terrain.bind();
    }
    gl.Disable(gl.CULL_FACE);
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

    if (squid_mesh.vertices.items.len > 0) {
        app_state.textures.squid.bind();
        drawEntityMesh(&squid_mesh);
        app_state.textures.terrain.bind();
    }

    inline for (.{
        .{ &ghast_mesh, "ghast" },
        .{ &ghast_fire_mesh, "ghast_fire" },
    }) |face| {
        if (face[0].vertices.items.len > 0) {
            @field(app_state.textures, face[1]).bind();
            drawEntityMesh(face[0]);
            app_state.textures.terrain.bind();
        }
    }

    if (spider_mesh.vertices.items.len > 0) {
        app_state.textures.spider.bind();
        drawEntityMesh(&spider_mesh);
        app_state.textures.spider_eyes.bind();
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        drawEntityMesh(&spider_eyes_mesh);
        gl.Disable(gl.BLEND);
        app_state.textures.terrain.bind();
    }

    if (skeleton_mesh.vertices.items.len > 0) {
        app_state.textures.skeleton.bind();
        drawEntityMesh(&skeleton_mesh);
        app_state.textures.terrain.bind();
    }

    if (bow_mesh.vertices.items.len > 0) {
        app_state.textures.items.bind();
        drawEntityMesh(&bow_mesh);
        app_state.textures.terrain.bind();
    }

    if (creeper_mesh.vertices.items.len > 0) {
        app_state.textures.creeper.bind();
        drawEntityMesh(&creeper_mesh);
        app_state.textures.terrain.bind();
    }

    if (zombie_mesh.vertices.items.len > 0) {
        app_state.textures.zombie.bind();
        drawEntityMesh(&zombie_mesh);
        app_state.textures.terrain.bind();
    }

    if (pig_zombie_mesh.vertices.items.len > 0) {
        app_state.textures.pig_zombie.bind();
        drawEntityMesh(&pig_zombie_mesh);
        app_state.textures.terrain.bind();
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

    try drawPeers(app_state, partial);
    if (app_state.third_person or app_state.player.sleeping or app_state.freecam.active) try drawPlayer(app_state, partial);
    gl.Enable(gl.CULL_FACE);
    try drawFishLines(app_state, partial);

    try drawSelectionOutline(app_state);
    try drawBreakingCrack(app_state);

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.Disable(gl.CULL_FACE);
    app_state.shader.setInt(.u_alpha_test, 0);
    try app_state.chunks.drawTranslucent(app_state.frame, frustum, eye.x, eye.z);
    app_state.shader.setInt(.u_alpha_test, 1);
    gl.Disable(gl.BLEND);

    try drawLightning(app_state, view_proj);
    try drawWeather(app_state, view_proj, partial);
    try drawClouds(app_state, proj, partial);
    if (!app_state.third_person and !app_state.player.sleeping and !app_state.freecam.active) {
        try drawHeldItem(app_state, proj, partial);
        if (app_state.player.fire > 0) try drawFireOverlay(app_state, proj);
    }
}

fn drawFireOverlay(app_state: *AppState, proj: math.Mat4) !void {
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    app_state.shader.setInt(.u_fog_enabled, 0);
    app_state.shader.setInt(.u_alpha_test, 0);
    app_state.shader.setInt(.u_textured, 1);
    app_state.shader.setVec4(.u_tint, .{ 1, 1, 1, 1 });
    app_state.shader.setVec3(.u_camera_pos, .{ 0, 0, 0 });
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.shader.setInt(.u_atlas, 0);
    app_state.textures.terrain.bind();

    for (0..render.held_item.fire_quads) |quad| {
        var mesh: render.MeshBuilder = .{};
        defer mesh.deinit(app_state.frame);

        const tile: u8 = render.TextureFx.fire_tile + @as(u8, @intCast(quad)) * render.Atlas.tiles_per_row;
        try render.held_item.appendFire(&mesh, app_state.frame, tile);
        app_state.shader.setMat4(.u_view_proj, proj.mul(render.anaglyph.view(app_state.anaglyph_pass, render.held_item.fireMatrix(quad))).m);

        var gpu = render.GpuMesh.upload(&mesh);
        defer gpu.deinit();
        gpu.draw();
    }

    app_state.shader.setInt(.u_alpha_test, 1);
    gl.Disable(gl.BLEND);
}

fn drawPeers(app_state: *AppState, partial: f32) !void {
    const link = app_state.link orelse return;
    if (link.connection.peers.items.len == 0) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);

    var heads: render.MeshBuilder = .{};
    defer heads.deinit(app_state.frame);

    for (link.connection.peers.items) |*peer| {
        try render.entity_render.appendPlayer(
            &mesh,
            app_state.frame,
            &app_state.level.world_map,
            peer.player,
            false,
            partial,
        );
        if (wornBlock(peer.player)) |id| {
            try render.entity_render.appendPlayerHeadBlock(
                &heads,
                app_state.frame,
                &app_state.level.world_map,
                peer.player,
                false,
                partial,
                id,
            );
        }
    }

    app_state.textures.char.bind();
    drawEntityMesh(&mesh);
    app_state.textures.terrain.bind();
    drawEntityMesh(&heads);
}

fn drawPlayer(app_state: *AppState, partial: f32) !void {
    const player = app_state.player;
    const holding_item = player.inventory.selectedStack() != null;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    try render.entity_render.appendPlayer(&mesh, app_state.frame, &app_state.level.world_map, player, holding_item, partial);
    app_state.textures.char.bind();
    drawEntityMesh(&mesh);

    for (player.inventory.armor) |stack| {
        const worn = stack orelse continue;
        if (worn.id != .item) continue;
        const piece = worn.id.item.armor() orelse continue;
        const layer = render.mob_model.bipedArmor(piece.slot);

        var armor_mesh: render.MeshBuilder = .{};
        defer armor_mesh.deinit(app_state.frame);
        try render.entity_render.appendPlayerArmor(&armor_mesh, app_state.frame, &app_state.level.world_map, player, holding_item, partial, layer);
        app_state.textures.armor(piece.material, layer.second_texture).bind();
        drawEntityMesh(&armor_mesh);
    }

    app_state.textures.terrain.bind();

    if (wornBlock(player)) |id| {
        var head_mesh: render.MeshBuilder = .{};
        defer head_mesh.deinit(app_state.frame);
        try render.entity_render.appendPlayerHeadBlock(&head_mesh, app_state.frame, &app_state.level.world_map, player, holding_item, partial, id);
        drawEntityMesh(&head_mesh);
    }
}

fn wornBlock(player: game.Player) ?world.Block {
    const worn = player.inventory.armor[@intFromEnum(world.item.ArmorSlot.helmet)] orelse return null;
    return switch (worn.id) {
        .block => |id| if (id == .air) null else id,
        .item => null,
    };
}

fn drawMapPass(mesh: *render.MeshBuilder, texture: anytype) void {
    if (mesh.vertices.items.len == 0) return;
    texture.bind();
    var gpu = render.GpuMesh.upload(mesh);
    defer gpu.deinit();
    gpu.draw();
}

fn handBrightness(app_state: *const AppState) f32 {
    const eye = app_state.player.base.position;
    return world.light.brightnessAt(
        &app_state.level.world_map,
        math.util.floorDouble(eye.x),
        math.util.floorDouble(eye.y + game.Player.eye_height),
        math.util.floorDouble(eye.z),
        0,
    );
}

fn handLightRotation(player: game.Player, partial: f32) math.Mat4 {
    const degrees = std.math.pi / 180.0;
    const pitch = player.prev_pitch + (player.pitch - player.prev_pitch) * partial;
    const yaw = player.prev_yaw + (player.yaw - player.prev_yaw) * partial;
    return math.Mat4.rotationY(-yaw * degrees).mul(math.Mat4.rotationX(-pitch * degrees));
}

fn drawHeldMap(app_state: *AppState, proj: math.Mat4, partial: f32, stack: game.Inventory.ItemStack) !void {
    const data = try app_state.level.world_map.mapData(@bitCast(stack.meta));

    const bob = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial)
    else
        math.Mat4.identity;
    const swing = app_state.player.swingProgress(partial);
    const equipped = app_state.equip.interpolated(partial);
    const pitch = app_state.player.prev_pitch + (app_state.player.pitch - app_state.player.prev_pitch) * partial;

    const brightness = handBrightness(app_state);

    const placed = render.anaglyph.view(app_state.anaglyph_pass, app_state.player.hurtMatrix(partial)
        .mul(bob)
        .mul(render.map_render.baseMatrix(swing, equipped, pitch)));
    const base = proj.mul(placed);
    const lit = handLightRotation(app_state.player, partial).mul(placed);

    gl.Clear(gl.DEPTH_BUFFER_BIT);
    app_state.shader.setVec3(.u_camera_pos, .{ 0, 0, 0 });
    app_state.shader.setInt(.u_fog_enabled, 0);
    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.shader.setInt(.u_textured, 1);
    app_state.shader.setVec4(.u_tint, .{ brightness, brightness, brightness, 1 });
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.shader.setInt(.u_atlas, 0);

    for (render.map_render.arm_sides) |side| {
        var arm: render.MeshBuilder = .{};
        defer arm.deinit(app_state.frame);
        const arm_matrix = render.map_render.armMatrix(side);
        try render.held_item.appendArm(&arm, app_state.frame, 1.0, render.item_lighting.orientOf(lit.mul(arm_matrix)));
        app_state.shader.setMat4(.u_view_proj, base.mul(arm_matrix).m);
        drawMapPass(&arm, app_state.textures.char);
    }

    const board_matrix = render.map_render.boardMatrix(swing);
    const board_shade = render.item_lighting.shade(render.item_lighting.normalized(
        render.item_lighting.turned(render.item_lighting.orientOf(lit.mul(board_matrix)), render.map_render.board_normal),
    ));
    const board_tint = @min(1.0, brightness * board_shade);
    app_state.shader.setVec4(.u_tint, .{ board_tint, board_tint, board_tint, 1 });
    app_state.shader.setMat4(.u_view_proj, base.mul(board_matrix).m);
    gl.Disable(gl.CULL_FACE);

    var background: render.MeshBuilder = .{};
    defer background.deinit(app_state.frame);
    try render.map_render.appendBackground(&background, app_state.frame);
    drawMapPass(&background, app_state.textures.map_background);

    app_state.map_surface.upload(&data.colors, app_state.settings.anaglyph);
    var face: render.MeshBuilder = .{};
    defer face.deinit(app_state.frame);
    try render.map_render.appendFace(&face, app_state.frame);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    app_state.shader.setInt(.u_alpha_test, 0);
    drawMapPass(&face, app_state.map_surface);
    app_state.shader.setInt(.u_alpha_test, 1);
    gl.Disable(gl.BLEND);

    var markers: render.MeshBuilder = .{};
    defer markers.deinit(app_state.frame);
    try render.map_render.appendMarkers(&markers, app_state.frame, data.markers.items);
    drawMapPass(&markers, app_state.textures.map_icons);

    var label: render.MeshBuilder = .{};
    defer label.deinit(app_state.frame);
    var name: [16]u8 = undefined;
    try render.map_render.appendLabel(&label, app_state.frame, app_state.font, render.map_render.labelText(&name, data.id));
    drawMapPass(&label, app_state.font);

    app_state.textures.terrain.bind();
}

fn drawHeldItem(app_state: *AppState, proj: math.Mat4, partial: f32) !void {
    const brightness = handBrightness(app_state);

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);

    const bob = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial)
    else
        math.Mat4.identity;
    const swing = app_state.player.swingProgress(partial);
    const equipped = app_state.equip.interpolated(partial);
    if (app_state.equip.shown) |shown| {
        if (shown.id.eql(.{ .item = .map })) return drawHeldMap(app_state, proj, partial, shown);
    }
    const shape = render.held_item.heldShape(app_state.equip.shown);

    const placed = render.anaglyph.view(app_state.anaglyph_pass, app_state.player.hurtMatrix(partial).mul(bob));
    const lamps = handLightRotation(app_state.player, partial).mul(placed);
    var transform = proj.mul(placed);
    if (shape) |held| {
        var held_matrix = render.held_item.handMatrix(swing, equipped);
        if (render.held_item.turnsAroundInHand(app_state.equip.shown)) {
            held_matrix = held_matrix.mul(math.Mat4.rotationY(std.math.pi));
        }
        transform = transform.mul(held_matrix);
        const material = render.item_lighting.material(brightness, .{ 1, 1, 1 });
        switch (held) {
            .cube => |id| try render.held_item.appendBlock(&mesh, app_state.frame, id, .{
                .orient = render.item_lighting.orientOf(lamps.mul(held_matrix)),
                .material = material,
            }),
            .sprite => |sprite| {
                const sprite_matrix = render.held_item.spriteMatrix();
                try render.held_item.appendSprite(&mesh, app_state.frame, sprite.tile, .{
                    .orient = render.item_lighting.orientOf(lamps.mul(held_matrix).mul(sprite_matrix)),
                    .material = material,
                });
                transform = transform.mul(sprite_matrix);
            },
        }
    } else {
        const arm_matrix = render.held_item.armMatrix(swing, equipped);
        transform = transform.mul(arm_matrix);
        try render.held_item.appendArm(
            &mesh,
            app_state.frame,
            brightness,
            render.item_lighting.orientOf(lamps.mul(arm_matrix)),
        );
    }

    gl.Clear(gl.DEPTH_BUFFER_BIT);
    app_state.shader.setMat4(.u_view_proj, transform.m);
    app_state.shader.setVec3(.u_camera_pos, .{ 0, 0, 0 });
    app_state.shader.setInt(.u_fog_enabled, 0);
    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.shader.setInt(.u_textured, 1);
    app_state.shader.setVec4(.u_tint, .{ 1, 1, 1, 1 });
    gl.ActiveTexture(gl.TEXTURE0);
    app_state.shader.setInt(.u_atlas, 0);
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

fn drawPrimedTntFlash(app_state: *AppState, partial: f32) !void {
    if (app_state.level.entities.primed.items.len == 0) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    for (app_state.level.entities.primed.items) |lit| {
        try render.entity_render.appendPrimedTntFlash(&mesh, app_state.frame, lit, partial);
    }
    if (mesh.vertices.items.len == 0) return;

    app_state.shader.setInt(.u_textured, 0);
    app_state.shader.setInt(.u_alpha_test, 0);
    app_state.shader.setVec4(.u_tint, .{ 1, 1, 1, 1 });
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.DST_ALPHA);

    drawEntityMesh(&mesh);

    gl.Disable(gl.BLEND);
    app_state.shader.setInt(.u_textured, 1);
    app_state.shader.setInt(.u_alpha_test, 1);
}

fn drawLightning(app_state: *AppState, view_proj: math.Mat4) !void {
    if (app_state.level.entities.bolts.items.len == 0) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);

    for (app_state.level.entities.bolts.items) |bolt| {
        if (!bolt.isVisible()) continue;
        try render.lightning.append(&mesh, app_state.frame, bolt.base.position, bolt.seed);
    }
    if (mesh.vertices.items.len == 0) return;

    app_state.shader.setMat4(.u_view_proj, view_proj.m);
    app_state.shader.setInt(.u_textured, 0);
    app_state.shader.setInt(.u_alpha_test, 0);
    app_state.shader.setVec4(.u_tint, .{ 1, 1, 1, 1 });
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE);
    gl.Disable(gl.CULL_FACE);
    gl.DepthMask(gl.FALSE);

    var gpu = render.GpuMesh.upload(&mesh);
    defer gpu.deinit();
    gpu.draw();

    gl.DepthMask(gl.TRUE);
    gl.Disable(gl.BLEND);
    app_state.shader.setInt(.u_textured, 1);
    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.textures.terrain.bind();
}

fn drawWeather(app_state: *AppState, view_proj: math.Mat4, partial: f32) !void {
    if (!app_state.dimension.hasSky()) return;

    const strength = app_state.level.world_map.weather.rainStrength(partial);
    if (strength <= 0.0) return;

    const eye = app_state.player.base.renderPosition(partial);
    const view: render.weather.View = .{
        .world_map = &app_state.level.world_map,
        .eye = math.Vec3.init(eye.x, eye.y + game.Player.eye_height, eye.z),
        .tick_count = @intCast(app_state.level.tick_count),
        .partial_ticks = partial,
        .strength = strength,
        .fancy = app_state.settings.fancy_graphics,
    };

    app_state.shader.setMat4(.u_view_proj, view_proj.m);
    app_state.shader.setInt(.u_alpha_test, 0);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.Disable(gl.CULL_FACE);

    try drawWeatherLayer(app_state, view, &app_state.textures.snow, render.weather.appendSnow);
    try drawWeatherLayer(app_state, view, &app_state.textures.rain, render.weather.appendRain);

    gl.Disable(gl.BLEND);
    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.textures.terrain.bind();
}

fn drawWeatherLayer(
    app_state: *AppState,
    view: render.weather.View,
    atlas: *const render.Atlas,
    append: *const fn (*render.MeshBuilder, std.mem.Allocator, render.weather.View) anyerror!void,
) !void {
    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);

    try append(&mesh, app_state.frame, view);
    if (mesh.vertices.items.len == 0) return;

    atlas.bind();
    var gpu = render.GpuMesh.upload(&mesh);
    defer gpu.deinit();
    gpu.draw();
}

fn drawClouds(app_state: *AppState, proj: math.Mat4, partial: f32) !void {
    if (!app_state.dimension.hasSky()) return;

    const angle = app_state.level.world_map.celestialAngle(partial);
    const eye = app_state.player.base.renderPosition(partial);
    const hurt = app_state.player.hurtMatrix(partial);
    const warp = portalWarp(app_state, partial);
    const rotation = render.anaglyph.view(app_state.anaglyph_pass, if (app_state.settings.view_bobbing)
        hurt.mul(app_state.player.bobMatrix(partial)).mul(warp).mul(app_state.player.cameraRotation(&app_state.level.world_map))
    else
        hurt.mul(warp).mul(app_state.player.cameraRotation(&app_state.level.world_map)));

    const ticks: f64 = @floatFromInt(app_state.cloud_offset);
    try render.SkyRenderer.drawClouds(.{
        .shader = app_state.shader,
        .textures = app_state.textures,
        .gpa = app_state.frame,
        .view_proj = proj.mul(rotation),
        .eye = math.Vec3.init(eye.x, eye.y + game.Player.eye_height, eye.z),
        .scroll = (ticks + partial) * render.sky.cloud_scroll_per_tick,
        .color = render.sky.cloudColor(angle),
    }, app_state.settings.fancy_graphics, app_state.anaglyph_pass);
}

fn portalWarp(app_state: *const AppState, partial: f32) math.Mat4 {
    return app_state.player.portalMatrix(partial, app_state.level.tick_count);
}

fn weatheredSky(app_state: *const AppState, color: render.sky.Color, partial: f32) render.sky.Color {
    const weather = app_state.level.world_map.weather;
    const flash = @as(f32, @floatFromInt(weather.flash)) - partial;
    return render.sky.weatheredSkyColor(
        color,
        weather.rainStrength(partial),
        weather.thunderStrength(partial),
        flash,
    );
}

fn drawSky(app_state: *AppState, proj: math.Mat4, partial: f32, horizon: render.sky.Color) !void {
    if (!app_state.dimension.hasSky()) return;

    const render_distance = @intFromEnum(app_state.settings.render_distance);
    if (!render.SkyRenderer.visibleAt(render_distance)) return;

    const angle = app_state.level.world_map.celestialAngle(partial);
    const temperature: f32 = @floatCast(app_state.level.generator.temperatureAt(
        math.util.floorDouble(app_state.player.base.position.x),
        math.util.floorDouble(app_state.player.base.position.z),
    ));
    const hurt = app_state.player.hurtMatrix(partial);
    const warp = portalWarp(app_state, partial);
    const rotation = render.anaglyph.view(app_state.anaglyph_pass, if (app_state.settings.view_bobbing)
        hurt.mul(app_state.player.bobMatrix(partial)).mul(warp).mul(app_state.player.cameraRotation(&app_state.level.world_map))
    else
        hurt.mul(warp).mul(app_state.player.cameraRotation(&app_state.level.world_map)));

    try app_state.sky.draw(.{
        .shader = app_state.shader,
        .textures = app_state.textures,
        .gpa = app_state.frame,
        .projection = proj,
        .view_rotation = rotation,
        .celestial_angle = angle,
        .sky_color = weatheredSky(app_state, render.sky.skyColor(temperature, angle), partial),
        .fog_color = horizon,
        .far_plane_distance = render.sky.farPlaneDistance(render_distance),
        .fog_density = cameraFogDensity(app_state),
        .pass = app_state.anaglyph_pass,
    });
}

fn drawBreakingCrack(app_state: *AppState) !void {
    const digging = app_state.digging orelse return;
    if (digging.progress <= 0.0) return;

    const id = app_state.level.world_map.getBlock(digging.x, digging.y, digging.z);
    if (id == .air) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    try render.selection.appendCrack(
        &mesh,
        app_state.frame,
        &app_state.level.world_map,
        app_state.colorizer,
        id,
        app_state.level.world_map.getBlockMetadata(digging.x, digging.y, digging.z),
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

fn drawFishLines(app_state: *AppState, partial: f32) !void {
    if (app_state.level.entities.hooks.items.len == 0) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);

    const player = &app_state.player;
    const angler: game.FishHook.Angler = .{
        .eye = player.renderEyePosition(partial),
        .yaw = player.prev_yaw + (player.yaw - player.prev_yaw) * partial,
        .pitch = player.prev_pitch + (player.pitch - player.prev_pitch) * partial,
        .body_yaw = player.prev_render_yaw + (player.render_yaw - player.prev_render_yaw) * partial,
        .swing = player.swingProgress(partial),
        .third_person = app_state.third_person,
    };

    for (app_state.level.entities.hooks.items) |hook| {
        if (hook.dead or hook.angler != player.base.id) continue;
        try render.entity_render.appendFishLine(&mesh, app_state.frame, hook, angler, partial);
    }
    if (mesh.vertices.items.len == 0) return;

    gl.LineWidth(2.0);
    app_state.shader.setInt(.u_textured, 0);
    app_state.shader.setInt(.u_alpha_test, 0);

    var gpu = render.GpuMesh.uploadLines(&mesh);
    defer gpu.deinit();
    gpu.draw();

    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.shader.setInt(.u_textured, 1);
    gl.LineWidth(1.0);
}

fn drawSelectionOutline(app_state: *AppState) !void {
    const hit = pickedBlock(app_state) orelse return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    const id = app_state.level.world_map.getBlock(hit.x, hit.y, hit.z);
    try render.selection.appendOutline(&mesh, app_state.frame, id, app_state.level.world_map.getBlockMetadata(hit.x, hit.y, hit.z), hit.x, hit.y, hit.z);

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.DepthMask(gl.FALSE);
    gl.LineWidth(2.0);
    app_state.shader.setInt(.u_textured, 0);
    app_state.shader.setInt(.u_alpha_test, 0);

    var gpu = render.GpuMesh.uploadLines(&mesh);
    defer gpu.deinit();
    gpu.draw();

    app_state.shader.setInt(.u_alpha_test, 1);
    app_state.shader.setInt(.u_textured, 1);
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

    app_state.frame_started_ns = sdl3.timer.getNanosecondsSinceInit();
    app_state.chunk_stream_deadline_ns = app_state.frame_started_ns +% chunk_stream_budget_ns;
    app_state.chunk_streamed_this_frame = false;

    if (sdl3.timer.getMillisecondsSinceInit() < app_state.mojang_until_ms) {
        try render.screen.mojang.draw(uiContext(app_state, gui));
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

    const ticks_started_ns = sdl3.timer.getNanosecondsSinceInit();
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
        if (app_state.achievements_open) {
            for (0..@intCast(app_state.timer.elapsed_ticks)) |_| app_state.achievements_view.tick();
        }
        try stepPauseSave(app_state);
    }

    if (!app_state.paused and app_state.timer.elapsed_ticks > 0) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| app_state.texture_fx.tick(compassAngle(app_state), clockAngle(app_state));
        app_state.texture_fx.upload(app_state.textures.terrain, app_state.textures.items, app_state.settings.anaglyph);
    }
    const tick_ns = sdl3.timer.getNanosecondsSinceInit() -% ticks_started_ns;

    if (app_state.screen == .loading) try stepLoading(app_state);

    const horizon = horizonColor(app_state);
    gl.Enable(gl.DEPTH_TEST);
    gl.ClearColor(horizon[0], horizon[1], horizon[2], 1.0);

    if (app_state.third_person and app_state.player.isInsideOpaqueBlock(&app_state.level.world_map)) {
        app_state.third_person = false;
    }

    if (app_state.settings.anaglyph and app_state.screen == .playing) {
        for (0..2) |eye| {
            app_state.anaglyph_pass = @intCast(eye);
            render.anaglyph.beginPass(app_state.anaglyph_pass);
            gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
            try renderWorld(app_state, horizon);
        }
        app_state.anaglyph_pass = null;
        render.anaglyph.endPasses();
    } else {
        render.anaglyph.beginPass(null);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        if (app_state.screen == .playing) try renderWorld(app_state, horizon);
    }

    const ui = uiContext(app_state, gui);
    const backdrop: render.screen.options.Backdrop = if (app_state.options_parent == .pause) .veil else .dirt;

    if (app_state.screen == .playing) {
        if (cameraSubmerged(app_state) and !app_state.player.sleeping) {
            const sample = app_state.player.base.lightSamplePosition();
            try render.underwater.draw(
                app_state.frame,
                app_state.shader,
                app_state.textures.water,
                app_state.player.yaw,
                app_state.player.pitch,
                world.light.brightnessAt(&app_state.level.world_map, sample[0], sample[1], sample[2], 0),
            );
        }
        const blurred = if (wornBlock(app_state.player)) |id| id == .pumpkin else false;
        if (blurred and !app_state.third_person and !app_state.freecam.active) {
            try render.pumpkin_blur.draw(app_state.frame, app_state.shader, app_state.textures.pumpkin_blur);
        }
        try render.hud.draw(ui, app_state.player.inventory, app_state.player, cameraSubmerged(app_state), @truncate(@as(i64, @bitCast(app_state.level.tick_count))));
        if (touch_ui and worldFocused(app_state)) {
            if (app_state.touch_atlas) |atlas| try render.touch.draw(ui, .{
                .stick = app_state.touch_stick,
                .jump = app_state.keys.jump,
                .attack = touchHeld(app_state, .attack),
                .sneak = app_state.keys.sneak,
            }, atlas);
        }
        if (app_state.show_debug) try render.debug_overlay.draw(ui, debugStats(app_state));
        try render.chat.draw(ui, &app_state.chat);
    }

    if (app_state.controls_open) {
        try render.screen.controls.draw(ui, app_state.settings, backdrop, app_state.rebinding);
    } else if (app_state.video_open) {
        try render.screen.video_settings.draw(ui, app_state.settings, backdrop);
    } else if (app_state.options_open) {
        try render.screen.options.draw(ui, app_state.settings, backdrop);
    } else if (app_state.stats_open) {
        const view = &app_state.stats_view;
        view.scroll.set(view.tab, render.screen.stats.clampScroll(gui, view.*, view.scrollOf()));
        try render.screen.stats.draw(ui, view.*, &app_state.stats);
    } else if (app_state.achievements_open) {
        app_state.achievements_view.drag(
            app_state.mouse_x,
            app_state.mouse_y,
            gui,
            app_state.achievements_grabbing,
        );
        try render.screen.achievements.draw(
            ui,
            app_state.achievements_view,
            &app_state.stats,
            1.0,
            @floatFromInt(sdl3.timer.getMillisecondsSinceInit()),
            inventoryKeyName(app_state),
        );
    } else if (app_state.screen == .title) {
        try render.screen.title.draw(ui, app_state.splash, sdl3.timer.getMillisecondsSinceInit(), app_state.github_icon);
    } else if (app_state.screen == .select_world) {
        app_state.list_scroll = render.screen.select_world.clampScroll(gui, app_state.summaries.len, app_state.list_scroll);
        try render.screen.select_world.draw(ui, app_state.summaries, app_state.selected_world, app_state.list_scroll);
    } else if (app_state.screen == .create_world) {
        try render.screen.create_world.draw(ui, &app_state.create_state);
    } else if (app_state.screen == .multiplayer) {
        try render.screen.multiplayer.draw(ui, &app_state.multiplayer_state);
    } else if (app_state.screen == .texture_packs) {
        app_state.pack_scroll = render.screen.texture_packs.clampScroll(gui, app_state.packs.len, app_state.pack_scroll);
        try render.screen.texture_packs.draw(
            ui,
            app_state.packs,
            app_state.pack_thumbnails,
            render.texture_pack.indexOf(app_state.packs, app_state.settings.skin.text()),
            app_state.pack_scroll,
        );
    } else if (app_state.screen == .confirm_delete) {
        var message: [96]u8 = undefined;
        const name = if (app_state.selected_world) |index| app_state.summaries[index].name else "";
        const line = std.fmt.bufPrint(&message, "'{s}' will be lost forever! (A long time!)", .{name}) catch "This world will be lost forever! (A long time!)";
        try render.screen.confirm.draw(ui, "Are you sure you want to delete this world?", line, "Delete");
    } else if (app_state.screen == .loading) {
        const total = app_state.loading.total;
        const progress: i32 = if (total == 0) 0 else @intCast(app_state.loading.done * 100 / total);
        try render.screen.loading.draw(ui, app_state.loading.title, "Building terrain", progress);
    } else if (app_state.dead) {
        try render.screen.death.draw(ui);
    } else if (app_state.paused) {
        try render.menu.draw(ui, app_state.pause_saving, app_state.pause_ticks, app_state.timer.render_partial_ticks);
    } else if (openedFurnace(app_state)) |furnace| {
        try render.screen.furnace.draw(
            ui,
            app_state.player.inventory,
            furnace.*,
            app_state.held_stack,
        );
    } else if (openedChest(app_state)) |open| {
        try render.screen.chest.draw(ui, app_state.player.inventory, open.upper, open.lower, app_state.held_stack);
    } else if (openedDispenser(app_state)) |open| {
        try render.screen.dispenser.draw(ui, app_state.player.inventory, open, app_state.held_stack);
    } else if (openedMinecart(app_state)) |cart| {
        try render.screen.chest.drawCargo(
            ui,
            app_state.player.inventory,
            &cart.items,
            game.Minecart.inventory_name,
            app_state.held_stack,
        );
    } else if (app_state.workbench_open) {
        try render.screen.crafting.draw(
            ui,
            app_state.player.inventory,
            app_state.workbench_grid,
            app_state.held_stack,
        );
    } else if (app_state.sign_edit) |open| {
        const id = app_state.level.world_map.getBlock(open.x, open.y, open.z);
        const meta = app_state.level.world_map.getBlockMetadata(open.x, open.y, open.z);
        const state = app_state.level.world_map.signAt(open.x, open.y, open.z);
        try render.screen.edit_sign.draw(ui, open, id, meta, if (state) |value| value.* else .{});
    } else if (app_state.inventory_open) {
        try render.screen.inventory.draw(
            ui,
            render.mob_model.biped,
            app_state.player.inventory,
            app_state.crafting_grid,
            app_state.held_stack,
        );
    }

    if (app_state.screen == .playing) {
        try render.achievement_toast.draw(
            uiContext(app_state, gui),
            app_state.achievement_toast,
            @floatFromInt(sdl3.timer.getMillisecondsSinceInit()),
            inventoryKeyName(app_state),
        );
    }

    const now_ns = sdl3.timer.getNanosecondsSinceInit();
    if (app_state.show_debug) {
        app_state.debug_graph.record(now_ns, tick_ns);
        try render.debug_graph.draw(
            app_state.frame,
            app_state.shader,
            &app_state.debug_graph,
            @floatFromInt(px.w),
            @floatFromInt(px.h),
        );
    } else {
        app_state.debug_graph.skip(now_ns);
    }

    try sdl3.video.gl.swapWindow(app_state.window);

    return .run;
}

fn typeText(app_state: *AppState, text: []const u8) void {
    if (app_state.sign_edit) |open| {
        if (editedSign(app_state)) |state| {
            for (text) |c| {
                if (!render.chat.isAllowed(c)) continue;
                state.append(open.line, c);
            }
        }
    } else if (app_state.screen == .create_world) {
        app_state.create_state.typeText(text);
        updateCreateFolder(app_state);
    } else if (app_state.screen == .multiplayer) {
        app_state.multiplayer_state.typeText(text);
    } else if (app_state.chat.open) {
        app_state.chat.typeText(text);
    }
}

fn typingSomewhere(app_state: *const AppState) bool {
    return app_state.sign_edit != null or
        app_state.screen == .create_world or
        app_state.screen == .multiplayer or
        app_state.chat.open;
}

fn pasteRequested(key: sdl3.events.Keyboard) bool {
    return key.key == .v and (key.mod.left_control or key.mod.right_control);
}

fn pasteClipboard(app_state: *AppState) void {
    const clipped = sdl3.clipboard.getText() catch return;
    defer sdl3.free(clipped);
    typeText(app_state, clipped);
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

fn touchSlot(app_state: *AppState, id: u64) ?*Touch {
    for (&app_state.touches) |*touch| {
        if (touch.role != .none and touch.id == id) return touch;
    }
    return null;
}

fn applyStick(app_state: *AppState, stick: ?[2]f32) void {
    app_state.touch_stick = stick;
    const value = stick orelse [2]f32{ 0, 0 };
    app_state.keys.forward = value[1] <= -render.touch.dead_zone;
    app_state.keys.back = value[1] >= render.touch.dead_zone;
    app_state.keys.left = value[0] <= -render.touch.dead_zone;
    app_state.keys.right = value[0] >= render.touch.dead_zone;
}

fn releaseTouches(app_state: *AppState) void {
    app_state.touches = @splat(.{});
    applyStick(app_state, null);
    app_state.keys.jump = false;
    app_state.keys.sneak = false;
    app_state.mouse_left_down = false;
    app_state.missed_click_cooldown = 0;
}

fn touchTap(app_state: *AppState) !void {
    if (app_state.freecam.active) return;
    if (pickedEntity(app_state) != null) return clickLeft(app_state);
    if (try useBlockOrPlace(app_state)) {
        swingArm(app_state);
    } else if (app_state.link == null) {
        try game.interact.useHeldItem(interactContext(app_state));
    }
}

fn touchDown(app_state: *AppState, finger: sdl3.events.TouchFinger) !void {
    if (!worldFocused(app_state)) return;
    const res = guiSize(app_state);
    const gx = finger.x * res.width;
    const gy = finger.y * res.height;

    if (render.touch.controlAt(gx, gy, res)) |control| {
        switch (control) {
            .move => applyStick(app_state, render.touch.stickAt(gx, gy, res)),
            .jump => app_state.keys.jump = true,
            .sneak => app_state.keys.sneak = true,
            .attack => {
                app_state.mouse_left_down = true;
                app_state.last_held_swing_tick = app_state.level.tick_count;
                try clickLeft(app_state);
            },
            .inventory => {
                releaseTouches(app_state);
                return toggleInventory(app_state);
            },
            .pause => {
                releaseTouches(app_state);
                return togglePause(app_state);
            },
        }
        const slot = freeTouch(app_state) orelse return;
        slot.* = .{
            .id = finger.finger_id.value,
            .role = if (control == .move) .move else .button,
            .control = control,
        };
        return;
    }

    if (render.hud.hotbarSlotAt(gx, gy, res)) |index| {
        app_state.player.inventory.selectHotbar(index);
        return;
    }

    const slot = freeTouch(app_state) orelse return;
    slot.* = .{
        .id = finger.finger_id.value,
        .role = .world,
        .still_since_ms = sdl3.timer.getMillisecondsSinceInit(),
    };
}

fn freeTouch(app_state: *AppState) ?*Touch {
    for (&app_state.touches) |*touch| {
        if (touch.role == .none) return touch;
    }
    return null;
}

fn touchMotion(app_state: *AppState, finger: sdl3.events.TouchFinger) !void {
    const slot = touchSlot(app_state, finger.finger_id.value) orelse return;
    const res = guiSize(app_state);
    switch (slot.role) {
        .move => applyStick(app_state, render.touch.stickAt(finger.x * res.width, finger.y * res.height, res)),
        .world => {
            const px = drawableSize(app_state);
            const dx = finger.dx * @as(f32, @floatFromInt(px.w));
            const dy = finger.dy * @as(f32, @floatFromInt(px.h));
            slot.travel += @abs(dx) + @abs(dy);
            if (@abs(dx) + @abs(dy) > 0) slot.still_since_ms = sdl3.timer.getMillisecondsSinceInit();
            if (app_state.freecam.active) {
                app_state.freecam.turn(dx, dy, app_state.settings.sensitivity, app_state.settings.invert_mouse);
            } else {
                app_state.player.turn(dx, dy, app_state.settings.sensitivity, app_state.settings.invert_mouse);
            }
        },
        .button, .none => {},
    }
}

fn touchUp(app_state: *AppState, finger: sdl3.events.TouchFinger) !void {
    const slot = touchSlot(app_state, finger.finger_id.value) orelse return;
    const role = slot.role;
    const control = slot.control;
    const tapped = slot.travel < touch_drag_slop and !slot.digging;
    slot.* = .{};

    switch (role) {
        .move => applyStick(app_state, null),
        .button => switch (control) {
            .jump => app_state.keys.jump = false,
            .sneak => app_state.keys.sneak = false,
            .attack => {
                app_state.mouse_left_down = touchAttacking(app_state);
                if (!app_state.mouse_left_down) app_state.missed_click_cooldown = 0;
            },
            else => {},
        },
        .world => {
            app_state.mouse_left_down = touchAttacking(app_state);
            if (!app_state.mouse_left_down) app_state.missed_click_cooldown = 0;
            if (tapped and worldFocused(app_state)) try touchTap(app_state);
        },
        .none => {},
    }
}

fn touchHeld(app_state: *const AppState, control: render.touch.Control) bool {
    for (app_state.touches) |touch| {
        if (touch.role == .button and touch.control == control) return true;
    }
    return false;
}

fn touchAttacking(app_state: *const AppState) bool {
    for (app_state.touches) |touch| {
        if (touch.role == .world and touch.digging) return true;
        if (touch.role == .button and touch.control == .attack) return true;
    }
    return false;
}

fn touchTick(app_state: *AppState) !void {
    if (!worldFocused(app_state)) return;
    const now = sdl3.timer.getMillisecondsSinceInit();
    for (&app_state.touches) |*touch| {
        if (touch.role != .world or touch.digging) continue;
        if (now - touch.still_since_ms < touch_dig_delay_ms) continue;
        touch.digging = true;
        app_state.mouse_left_down = true;
        app_state.last_held_swing_tick = app_state.level.tick_count;
        try clickLeft(app_state);
    }
}

fn backAsEscape(current: *sdl3.events.Event) void {
    switch (current.*) {
        .key_down, .key_up => |*k| if (k.key == .ac_back) {
            k.key = .escape;
        },
        else => {},
    }
}

fn fromTouchMouse(curr_event: sdl3.events.Event) bool {
    const id = switch (curr_event) {
        .mouse_motion => |m| m.id,
        .mouse_button_down, .mouse_button_up => |m| m.id,
        else => return false,
    } orelse return false;
    return id.value == sdl3.mouse.Id.touch.value;
}

pub fn event(
    app_state: *AppState,
    curr_event: sdl3.events.Event,
) !sdl3.AppResult {
    gl.makeProcTableCurrent(&app_state.gl_procs);
    if (touch_ui and worldFocused(app_state) and fromTouchMouse(curr_event)) return .run;
    var current = curr_event;
    // Without a keyboard the back gesture is the only way off a screen.
    if (touch_ui) backAsEscape(&current);
    switch (current) {
        .quit, .terminating => return .success,
        .finger_down => |f| if (touch_ui) try touchDown(app_state, f),
        .finger_motion => |f| if (touch_ui) try touchMotion(app_state, f),
        .finger_up, .finger_canceled => |f| if (touch_ui) try touchUp(app_state, f),
        .key_down => |k| if (!wasm and !android and k.key == .func11 and !k.repeat) {
            app_state.settings.fullscreen = !app_state.settings.fullscreen;
            applyFullscreen(app_state);
            saveOptions(app_state);
        } else if (pasteRequested(k) and typingSomewhere(app_state)) {
            pasteClipboard(app_state);
        } else if (app_state.controls_open) {
            if (app_state.rebinding) |binding| {
                if (k.key) |key| {
                    app_state.settings.keys.set(binding, @intFromEnum(key));
                    saveOptions(app_state);
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
        } else if (app_state.achievements_open) {
            if (k.key == .escape or boundTo(app_state, .inventory, k.key)) {
                closeAchievements(app_state);
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
                    app_state.chat.backspace(k.mod.left_control);
                } else if (k.key == .up) {
                    app_state.chat.setTextFromHistory(-1);
                } else if (k.key == .down) {
                    app_state.chat.setTextFromHistory(1);
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
                setSlider(app_state, s, render.screen.options.sliderValueAt(s, m.x, gui));
            } else if (worldFocused(app_state)) {
                if (app_state.freecam.active) {
                    app_state.freecam.turn(m.x_rel, m.y_rel, app_state.settings.sensitivity, app_state.settings.invert_mouse);
                } else {
                    app_state.player.turn(m.x_rel, m.y_rel, app_state.settings.sensitivity, app_state.settings.invert_mouse);
                }
            }
        },
        .mouse_wheel => |w| if (worldFocused(app_state)) {
            app_state.player.inventory.cycleHotbar(if (w.scroll_y > 0) 1 else if (w.scroll_y < 0) -1 else 0);
        } else if (app_state.stats_open) {
            const view = &app_state.stats_view;
            const step = render.screen.stats.scrollStep(view.tab);
            view.scroll.set(view.tab, render.screen.stats.clampScroll(guiSize(app_state), view.*, view.scrollOf() - w.scroll_y * step));
        } else if (app_state.screen == .select_world) {
            const step = w.scroll_y * render.screen.select_world.entry_height;
            app_state.list_scroll = render.screen.select_world.clampScroll(guiSize(app_state), app_state.summaries.len, app_state.list_scroll - step);
        } else if (app_state.screen == .texture_packs) {
            const step = w.scroll_y * render.screen.texture_packs.entry_height;
            app_state.pack_scroll = render.screen.texture_packs.clampScroll(guiSize(app_state), app_state.packs.len, app_state.pack_scroll - step);
        },
        .text_input => |t| typeText(app_state, t.text),
        .mouse_button_down => |m| switch (m.button) {
            .left => if (app_state.controls_open) {
                controlsClick(app_state);
            } else if (app_state.video_open) {
                try videoClick(app_state);
            } else if (app_state.options_open) {
                try optionsClick(app_state);
            } else if (app_state.stats_open) {
                try statsClick(app_state);
            } else if (app_state.achievements_open) {
                app_state.achievements_grabbing = true;
                try achievementsClick(app_state);
            } else if (app_state.screen == .title) {
                const gui = guiSize(app_state);
                if (render.screen.title.actionAt(app_state.mouse_x, app_state.mouse_y, gui)) |action| {
                    clickSound(app_state);
                    switch (action) {
                        .singleplayer => try openSelectWorld(app_state),
                        .multiplayer => try openMultiplayer(app_state),
                        .texture_packs => try openTexturePacks(app_state),
                        .options => try openOptions(app_state, .title),
                        .github => openRepository(),
                        .quit => return .success,
                    }
                }
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
                if (render.screen.edit_sign.hitAt(app_state.mouse_x, app_state.mouse_y, guiSize(app_state))) |hit| {
                    clickSound(app_state);
                    switch (hit) {
                        .done => try closeSignEditor(app_state),
                    }
                }
            } else if (containerOpen(app_state)) {
                try openContainerClickAt(app_state, .left);
            } else {
                app_state.mouse_left_down = true;
                app_state.last_held_swing_tick = app_state.level.tick_count;
                try clickLeft(app_state);
            },
            .right => if (app_state.controls_open or app_state.video_open or app_state.options_open or app_state.stats_open or app_state.screen == .title or app_state.paused or app_state.dead or app_state.chat.open) {} else if (containerOpen(app_state)) {
                try openContainerClickAt(app_state, .right);
            } else if (!app_state.freecam.active) {
                if (try useBlockOrPlace(app_state)) {
                    swingArm(app_state);
                } else if (app_state.link == null) {
                    try game.interact.useHeldItem(interactContext(app_state));
                }
            },
            else => {},
        },
        .mouse_button_up => |m| switch (m.button) {
            .left => {
                app_state.mouse_left_down = false;
                app_state.missed_click_cooldown = 0;
                if (app_state.dragging_slider != null) saveOptions(app_state);
                app_state.dragging_slider = null;
                app_state.dragging_scrollbar = false;
                app_state.stats_view.pressed = null;
                app_state.achievements_grabbing = false;
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
        state.level.deinit(state.gpa);
        if (state.sound) |*sound| sound.deinit(state.gpa);
        state.sky.deinit();
        state.colorizer.deinit(state.gpa);
        state.shader.deinit();
        state.textures.deinit();
        if (state.github_icon) |icon| icon.deinit();
        if (state.touch_atlas) |atlas| atlas.deinit();
        state.font.deinit();
        state.gl_context.deinit() catch {};
        state.window.deinit();
        frame_arena.deinit();
    }
    sdl3.quit(init_flags);
    sdl3.shutdown();
    if (builtin.mode == .Debug and !wasm) _ = debug_allocator.deinit();
}
