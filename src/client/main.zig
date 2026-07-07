const builtin = @import("builtin");
const std = @import("std");

const assets = @import("assets");
const game = @import("game");
const gl = @import("gl");
const math = @import("math");
const render = @import("render");
const sdl3 = @import("sdl3");
const core = @import("core");
const Timer = core.Timer;
const world = @import("world");

const fps = 60;
const ticks_per_second = 20.0;
const screen_width = 854;
const screen_height = 480;
const init_flags = sdl3.InitFlags{ .video = true };
const font_png = assets.font.default_png;
const fov_y_radians = 70.0 * std.math.pi / 180.0;
const near_plane = 0.05;
const far_plane = 1000.0;
const reach_distance = 4.5;
const chunk_load_budget_ns = 8 * std.time.ns_per_ms;
const spawn_position = math.Vec3.init(8, 90, 8);

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
    cloud_offset: u64 = 0,
    chunks_drawn: u32 = 0,
    equip: render.held_item.Equip = .{},
    player: game.Player = .{
        .base = game.Entity.init(spawn_position, game.Player.width, game.Player.height),
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
    workbench_open: bool = false,
    paused: bool = false,
    options_open: bool = false,
    video_open: bool = false,
    controls_open: bool = false,
    rebinding: ?game.Settings.Binding = null,
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
    crafting_grid: [game.crafting.player_grid_size * game.crafting.player_grid_size]?game.Inventory.ItemStack = @splat(null),
    workbench_grid: [game.crafting.workbench_grid_size * game.crafting.workbench_grid_size]?game.Inventory.ItemStack = @splat(null),
    io: std.Io,
    saves_dir: std.Io.Dir,
    save_handle: ?world.save.Save = null,
    open_folder: NameBuffer = .{},
    open_name: NameBuffer = .{},
    summaries: []world.save.Summary = &.{},
    selected_world: ?usize = null,
    list_scroll: f32 = 0,
    create_state: render.create_world_screen.State = undefined,
    loading: Loading = .{},
    needs_spawn: bool = false,
    spawn: [3]i32 = .{ 0, 64, 0 },
    ticks_since_save: u32 = 0,
};

const Screen = enum { title, select_world, create_world, confirm_delete, loading, playing };

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
const autosave_interval_ticks: u32 = 900;
const save_chunks_per_tick: usize = 1;
const OptionsParent = enum { title, pause };

const Digging = struct {
    x: i32,
    y: i32,
    z: i32,
    progress: f32,
};

fn starterInventory() game.Inventory {
    var inv: game.Inventory = .{};
    inv.slots[0] = .{ .id = .{ .block = .stone }, .count = 64 };
    inv.slots[1] = .{ .id = .{ .block = .dirt }, .count = 64 };
    inv.slots[2] = .{ .id = .{ .block = .cobblestone }, .count = 64 };
    inv.slots[3] = .{ .id = .{ .block = .sand }, .count = 64 };
    inv.slots[4] = .{ .id = .{ .block = .workbench }, .count = 64 };
    inv.slots[5] = .{ .id = .{ .block = .log }, .count = 64 };
    return inv;
}

fn debugStats(app_state: *const AppState) render.debug_overlay.Stats {
    const loaded: u32 = @intCast(app_state.chunks.loadedCount());
    const entities: u32 = @intCast(app_state.entities.count());
    const memory = core.process_memory.sample();
    return .{
        .fps = app_state.debug_fps,
        .chunk_updates = app_state.debug_chunk_updates,
        .renderers_rendered = app_state.chunks_drawn,
        .renderers_loaded = loaded,
        .entities_rendered = entities,
        .entities_total = entities,
        .particles = @intCast(app_state.entities.particles.items.len),
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
    io_threaded = .init(gpa, .{});
    const io = io_threaded.io();
    const saves_dir = try world.save.openSavesDir(io);

    var app_state: AppState = .{
        .gpa = gpa,
        .frame = frame_arena.allocator(),
        .fps_capper = .{ .mode = .{ .limited = fps } },
        .window = window,
        .gl_context = gl_context,
        .gl_procs = undefined,
        .textures = undefined,
        .colorizer = undefined,
        .sky = undefined,
        .font = undefined,
        .shader = undefined,
        .generator = undefined,
        .world_map = world.World.init(gpa),
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
        .io = io,
        .saves_dir = saves_dir,
    };
    if (!app_state.gl_procs.init(glGetProcAddress)) return error.GlInitFailed;
    gl.makeProcTableCurrent(&app_state.gl_procs);

    app_state.world_map.rand.setSeed(@bitCast(sdl3.timer.getNanosecondsSinceInit()));
    app_state.splash = pickSplash(&app_state.world_map.rand);

    app_state.textures = try render.Textures.load();
    errdefer app_state.textures.deinit();

    app_state.colorizer = try render.Colorizer.load(gpa);
    errdefer app_state.colorizer.deinit(gpa);

    app_state.font = try render.Font.load(font_png);
    errdefer app_state.font.deinit();

    try app_state.entities.spawnPig(app_state.gpa, math.Vec3.init(10, 90, 8));

    app_state.shader = try render.terrain_shader.init();
    errdefer app_state.shader.deinit();

    app_state.sky = try render.SkyRenderer.init(gpa);
    errdefer app_state.sky.deinit();

    app_state.generator = try world.TerrainGenerator.init(gpa, 0);
    errdefer app_state.generator.deinit(gpa);

    return .{ app_state, .run };
}

fn faceOffset(face: world.Side) [3]i32 {
    return switch (face) {
        .down => .{ 0, -1, 0 },
        .up => .{ 0, 1, 0 },
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .east => .{ 1, 0, 0 },
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

    const block_id = app_state.world_map.getBlock(hit.x, hit.y, hit.z);
    const ticks_required = block_id.digTicksRequired() orelse return;
    if (ticks_required <= 0.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try applyBlockChanges(app_state);
        return;
    }

    app_state.digging.?.progress += 1.0 / ticks_required;
    try app_state.entities.spawnBlockHitParticle(
        app_state.gpa,
        hit.x,
        hit.y,
        hit.z,
        hit.face,
        block_id.faceTextures().get(.down),
        particleTint(app_state, block_id, hit.x, hit.y, hit.z),
        &app_state.world_map.rand,
    );
    if (app_state.digging.?.progress >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try applyBlockChanges(app_state);
    }
}

fn particleTint(app_state: *const AppState, id: world.Block, x: i32, y: i32, z: i32) [3]u8 {
    if (id == world.Block.grass) return .{ 255, 255, 255 };
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
}

fn spawnDroppedItem(app_state: *AppState, x: i32, y: i32, z: i32, stack: game.Inventory.ItemStack) !void {
    try app_state.entities.dropStack(app_state.gpa, x, y, z, stack, &app_state.world_map.rand);
}

fn checkFall(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    const id = app_state.world_map.getBlock(x, y, z);
    if (!id.isFalling()) return;
    if (!app_state.world_map.getBlock(x, y - 1, z).canFallInto()) return;

    try app_state.world_map.setBlockWithNotify(x, y, z, world.Block.air);
    try app_state.entities.spawnFallingBlock(app_state.gpa, x, y, z, id);
}

fn breakBlock(app_state: *AppState, x: i32, y: i32, z: i32, block_id: world.Block) !void {
    const meta = app_state.world_map.getBlockMetadata(x, y, z);
    try app_state.entities.spawnBlockDestroyParticles(
        app_state.gpa,
        x,
        y,
        z,
        block_id.faceTextures().get(.down),
        particleTint(app_state, block_id, x, y, z),
        &app_state.world_map.rand,
    );
    const dropped = block_id.drop(meta, &app_state.world_map.rand);
    try app_state.world_map.setBlockWithNotify(x, y, z, world.Block.air);
    app_state.digging = null;
    if (dropped) |d| try spawnDroppedItem(app_state, x, y, z, .{ .id = d.id, .count = d.count, .meta = d.meta });
    try checkFall(app_state, x, y + 1, z);
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
}

fn slotClick(app_state: *AppState, slot: *?game.Inventory.ItemStack, click_type: ClickType) void {
    if (slot.*) |*existing| {
        if (app_state.held_stack) |*held| {
            if (existing.id.eql(held.id) and existing.meta == held.meta) {
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

fn resultSlotClick(app_state: *AppState, grid: []?game.Inventory.ItemStack, size: u8) void {
    const result = game.crafting.findMatch(grid, size) orelse return;
    if (app_state.held_stack) |*held| {
        if (!held.id.eql(result.id) or held.meta != result.meta) return;
        if (@as(u16, held.count) + result.count > game.Inventory.max_stack_size) return;
        held.count += result.count;
    } else {
        app_state.held_stack = result;
    }
    game.crafting.consume(grid);
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
        .inventory => slotClick(app_state, &app_state.player.inventory.slots[slot.index], click_type),
        .craft_input => slotClick(app_state, &grid[slot.index], click_type),
        .craft_result => resultSlotClick(app_state, grid, size),
    }
}

fn openContainerClickAt(app_state: *AppState, click_type: ClickType) !void {
    if (app_state.workbench_open) {
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
    }
}

fn containerOpen(app_state: *const AppState) bool {
    return app_state.inventory_open or app_state.workbench_open;
}

fn worldFocused(app_state: *const AppState) bool {
    return app_state.screen == .playing and !containerOpen(app_state) and !app_state.paused and !app_state.options_open;
}

fn updateMouseMode(app_state: *AppState) !void {
    try sdl3.mouse.setWindowRelativeMode(app_state.window, worldFocused(app_state));
}

fn closeContainer(app_state: *AppState) !void {
    app_state.inventory_open = false;
    app_state.workbench_open = false;
    try updateMouseMode(app_state);
    try dropHeldStack(app_state, .left);
    try dropGrid(app_state, &app_state.crafting_grid);
    try dropGrid(app_state, &app_state.workbench_grid);
}

fn openWorkbench(app_state: *AppState) !void {
    app_state.workbench_open = true;
    try updateMouseMode(app_state);
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
    try updateMouseMode(app_state);
}

fn quitToTitle(app_state: *AppState) !void {
    if (app_state.save_handle != null) try saveWorld(app_state);
    closeWorld(app_state);
    app_state.screen = .title;
    app_state.paused = false;
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
        .on_ground = app_state.player.base.on_ground,
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
    app_state.player.base.on_ground = state.on_ground;

    app_state.player.inventory.loadSaveEntries(state.inventory);
}

fn saveWorld(app_state: *AppState) !void {
    if (app_state.save_handle == null) return;
    try app_state.world_map.saveLoadedChunks();
    try saveLevel(app_state);
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
        .last_played = world.RegionFile.unixSeconds(app_state.io),
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
    app_state.player = .{
        .base = game.Entity.init(spawn_position, game.Player.width, game.Player.height),
        .inventory = starterInventory(),
    };

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
        app_state.spawn = .{ 8, 64, 8 };
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

fn findSpawnY(app_state: *AppState, x: i32, z: i32) i32 {
    var y: i32 = world.constants.chunk_height - 1;
    while (y > 0) : (y -= 1) {
        if (app_state.world_map.getBlock(x, y, z).isSolid()) return y + 1;
    }
    return 64;
}

fn finishLoading(app_state: *AppState) !void {
    if (app_state.needs_spawn) {
        const x = app_state.spawn[0];
        const z = app_state.spawn[2];
        const y = findSpawnY(app_state, x, z);
        app_state.spawn = .{ x, y, z };
        app_state.player.base.position = math.Vec3.init(
            @as(f64, @floatFromInt(x)) + 0.5,
            @floatFromInt(y),
            @as(f64, @floatFromInt(z)) + 0.5,
        );
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
    const hit = render.select_world_screen.hitAt(
        app_state.mouse_x,
        app_state.mouse_y,
        gui,
        app_state.summaries.len,
        app_state.list_scroll,
        app_state.selected_world != null,
    ) orelse return;

    switch (hit) {
        .entry => |index| app_state.selected_world = index,
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

fn useBlockOrPlace(app_state: *AppState) !void {
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse {
        return placeBlockAtTarget(app_state);
    };
    if (app_state.world_map.getBlock(hit.x, hit.y, hit.z) == .workbench) {
        try openWorkbench(app_state);
        return;
    }
    try placeBlockAtTarget(app_state);
}

fn placeBlockAtTarget(app_state: *AppState) !void {
    const stack = app_state.player.inventory.selectedStack() orelse return;
    const placed = switch (stack.id) {
        .block => |b| b,
        .item => return,
    };
    const hit = game.raycast.cast(&app_state.world_map, app_state.player.eyePosition(), app_state.player.lookVector(), reach_distance) orelse return;
    const offset = faceOffset(hit.face);
    const px = hit.x + offset[0];
    const py = hit.y + offset[1];
    const pz = hit.z + offset[2];
    if (py < 0 or py >= world.constants.chunk_height) return;
    if (app_state.world_map.getBlock(px, py, pz).isSolid()) return;
    try app_state.world_map.setBlockAndMetadataWithNotify(px, py, pz, placed, stack.meta);
    consumeSelectedStack(app_state);
    try checkFall(app_state, px, py, pz);
    try applyBlockChanges(app_state);
}

fn tick(app_state: *AppState) !void {
    app_state.tick_count += 1;

    const moving_allowed = !containerOpen(app_state);
    const forward: f32 = if (!moving_allowed) 0 else (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = if (!moving_allowed) 0 else (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    app_state.player.tick(&app_state.world_map, strafe, forward, moving_allowed and app_state.keys.jump);
    app_state.player.tickSwing();
    app_state.equip.tick(app_state.player.inventory.selectedStack());
    try digStep(app_state);
    app_state.entities.tickItems(&app_state.world_map, &app_state.player);
    try tickFallingBlocks(app_state);
    try app_state.world_map.tickUpdates();
    try applyBlockChanges(app_state);
    app_state.entities.tickPigs(&app_state.world_map, &app_state.world_map.rand);
    app_state.entities.tickParticles(&app_state.world_map);
    try ensureChunksAroundPlayer(app_state);
    try advanceWorldTime(app_state);

    app_state.ticks_since_save += 1;
    if (app_state.ticks_since_save >= autosave_interval_ticks) {
        app_state.ticks_since_save = 0;
        try app_state.world_map.beginSaveRound();
        try saveLevel(app_state);
    }
    _ = try app_state.world_map.saveQueuedChunks(save_chunks_per_tick);
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

fn cameraSubmerged(app_state: *const AppState) bool {
    return app_state.player.isSubmerged(&app_state.world_map);
}

fn horizonColor(app_state: *const AppState) render.sky.Color {
    if (cameraSubmerged(app_state)) return underwater_fog_color;
    const temperature: f32 = @floatCast(app_state.generator.climate.temperatureAt(
        math.util.floorDouble(app_state.player.base.position.x),
        math.util.floorDouble(app_state.player.base.position.z),
    ));
    const render_distance = @intFromEnum(app_state.settings.render_distance);
    const angle = app_state.world_map.celestialAngle(app_state.timer.render_partial_ticks);
    return render.sky.blendedFogColor(
        render.sky.skyColor(temperature, angle),
        render.sky.fogColor(angle),
        render_distance,
    );
}

fn setupFog(app_state: *const AppState, horizon: render.sky.Color) void {
    app_state.shader.setInt("u_fog_enabled", 1);
    app_state.shader.setVec3("u_fog_color", horizon);

    if (cameraSubmerged(app_state)) {
        app_state.shader.setInt("u_fog_exponential", 1);
        app_state.shader.setFloat("u_fog_density", underwater_fog_density);
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
    }, app_state.player.base.position.x, app_state.player.base.position.z);

    const px = drawableSize(app_state);
    const aspect: f32 = @as(f32, @floatFromInt(px.w)) / @as(f32, @floatFromInt(px.h));
    const fov = if (cameraSubmerged(app_state))
        underwater_fov_degrees * std.math.pi / 180.0
    else
        fov_y_radians;
    const proj = math.Mat4.perspective(fov, aspect, near_plane, far_plane);
    const partial = app_state.timer.render_partial_ticks;
    const camera = app_state.player.viewMatrix(partial);
    const view = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial).mul(camera)
    else
        camera;
    const view_proj = proj.mul(view);
    const eye = app_state.player.base.renderPosition(partial);

    app_state.shader.use();
    try drawSky(app_state, proj, partial);

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
    app_state.chunks_drawn = app_state.chunks.drawSolid(frustum);

    var atlas_mesh: render.MeshBuilder = .{};
    defer atlas_mesh.deinit(app_state.frame);
    for (app_state.entities.items.items) |item| {
        try render.entity_render.appendItem(&atlas_mesh, app_state.frame, &app_state.world_map, item, partial);
    }
    for (app_state.entities.falling_blocks.items) |block| {
        try render.entity_render.appendFallingBlock(&atlas_mesh, app_state.frame, &app_state.world_map, block, partial);
    }
    const basis = render.entity_render.CameraBasis.fromLook(app_state.player.yaw, app_state.player.pitch);
    for (app_state.entities.particles.items) |particle| {
        try render.entity_render.appendParticle(&atlas_mesh, app_state.frame, &app_state.world_map, particle, basis, partial);
    }
    drawEntityMesh(&atlas_mesh);

    var pig_mesh: render.MeshBuilder = .{};
    defer pig_mesh.deinit(app_state.frame);
    for (app_state.entities.pigs.items) |pig| {
        try render.entity_render.appendPig(&pig_mesh, app_state.frame, &app_state.world_map, pig, partial);
    }
    var icon_mesh: render.MeshBuilder = .{};
    defer icon_mesh.deinit(app_state.frame);
    for (app_state.entities.items.items) |item| {
        try render.entity_render.appendItemIcon(&icon_mesh, app_state.frame, &app_state.world_map, item, app_state.player.yaw, partial);
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

    try drawSelectionOutline(app_state);
    try drawBreakingCrack(app_state);

    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    app_state.shader.setInt("u_alpha_test", 0);
    try app_state.chunks.drawTranslucent(app_state.frame, frustum, eye.x, eye.z);
    app_state.shader.setInt("u_alpha_test", 1);
    gl.Disable(gl.BLEND);

    try drawClouds(app_state, proj, partial);
    try drawHeldItem(app_state, proj, partial);
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

    var transform = proj.mul(bob);
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
    const rotation = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial).mul(app_state.player.viewRotation())
    else
        app_state.player.viewRotation();

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

fn drawSky(app_state: *AppState, proj: math.Mat4, partial: f32) !void {
    const render_distance = @intFromEnum(app_state.settings.render_distance);
    if (!render.SkyRenderer.visibleAt(render_distance)) return;

    const angle = app_state.world_map.celestialAngle(partial);
    const temperature: f32 = @floatCast(app_state.generator.climate.temperatureAt(
        math.util.floorDouble(app_state.player.base.position.x),
        math.util.floorDouble(app_state.player.base.position.z),
    ));
    const rotation = if (app_state.settings.view_bobbing)
        app_state.player.bobMatrix(partial).mul(app_state.player.viewRotation())
    else
        app_state.player.viewRotation();

    try app_state.sky.draw(.{
        .shader = app_state.shader,
        .textures = app_state.textures,
        .gpa = app_state.frame,
        .projection = proj,
        .view_rotation = rotation,
        .celestial_angle = angle,
        .sky_color = render.sky.skyColor(temperature, angle),
        .fog_color = render.sky.fogColor(angle),
        .far_plane_distance = render.sky.farPlaneDistance(render_distance),
    });
}

fn drawBreakingCrack(app_state: *AppState) !void {
    const digging = app_state.digging orelse return;
    if (digging.progress <= 0.0) return;

    const id = app_state.world_map.getBlock(digging.x, digging.y, digging.z);
    if (id == world.Block.air) return;

    var mesh: render.MeshBuilder = .{};
    defer mesh.deinit(app_state.frame);
    try render.selection.appendCrack(&mesh, app_state.frame, id, digging.x, digging.y, digging.z, digging.progress);

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
    try render.selection.appendOutline(&mesh, app_state.frame, id, hit.x, hit.y, hit.z);

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
    } else if (app_state.screen == .create_world) {
        for (0..@intCast(app_state.timer.elapsed_ticks)) |_| app_state.create_state.tick();
    }

    if (app_state.screen == .loading) try stepLoading(app_state);

    const horizon = horizonColor(app_state);
    gl.Enable(gl.DEPTH_TEST);
    gl.ClearColor(horizon[0], horizon[1], horizon[2], 1.0);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    if (app_state.screen == .playing) try renderWorld(app_state, horizon);

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
        try render.hud.draw(ui, app_state.player.inventory, app_state.player.health);
        if (app_state.show_debug) try render.debug_overlay.draw(ui, debugStats(app_state));
    }

    if (app_state.controls_open) {
        try render.controls_screen.draw(ui, app_state.settings, backdrop, app_state.rebinding);
    } else if (app_state.video_open) {
        try render.video_settings_screen.draw(ui, app_state.settings, backdrop);
    } else if (app_state.options_open) {
        try render.options_screen.draw(ui, app_state.settings, backdrop);
    } else if (app_state.screen == .title) {
        try render.title_screen.draw(ui, app_state.splash, sdl3.timer.getMillisecondsSinceInit());
    } else if (app_state.screen == .select_world) {
        app_state.list_scroll = std.math.clamp(app_state.list_scroll, 0, render.select_world_screen.maxScroll(gui, app_state.summaries.len));
        try render.select_world_screen.draw(ui, app_state.summaries, app_state.selected_world, app_state.list_scroll);
    } else if (app_state.screen == .create_world) {
        try render.create_world_screen.draw(ui, &app_state.create_state);
    } else if (app_state.screen == .confirm_delete) {
        var message: [96]u8 = undefined;
        const name = if (app_state.selected_world) |index| app_state.summaries[index].name else "";
        const line = std.fmt.bufPrint(&message, "'{s}' will be lost forever! (A long time!)", .{name}) catch "This world will be lost forever! (A long time!)";
        try render.confirm_screen.draw(ui, "Are you sure you want to delete this world?", line, "Delete");
    } else if (app_state.screen == .loading) {
        const total = app_state.loading.total;
        const progress: i32 = if (total == 0) 0 else @intCast(app_state.loading.done * 100 / total);
        try render.loading_screen.draw(ui, app_state.loading.title, "Building terrain", progress);
    } else if (app_state.paused) {
        try render.menu.draw(ui);
    } else if (app_state.workbench_open) {
        try render.crafting_screen.draw(
            ui,
            app_state.player.inventory,
            app_state.workbench_grid,
            app_state.held_stack,
        );
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
        } else if (app_state.screen == .confirm_delete) {
            if (k.key == .escape) app_state.screen = .select_world;
        } else if (app_state.screen == .playing) {
            if (k.key == .escape) {
                if (containerOpen(app_state)) {
                    try closeContainer(app_state);
                } else {
                    try togglePause(app_state);
                }
            } else if (k.key == .func3) {
                app_state.show_debug = !app_state.show_debug;
            } else if (boundTo(app_state, .inventory, k.key) and !app_state.paused) {
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
        } else if (app_state.screen == .select_world) {
            const limit = render.select_world_screen.maxScroll(guiSize(app_state), app_state.summaries.len);
            app_state.list_scroll = std.math.clamp(app_state.list_scroll - w.scroll_y * render.select_world_screen.entry_height, 0, limit);
        },
        .text_input => |t| if (app_state.screen == .create_world) {
            app_state.create_state.typeText(t.text);
            updateCreateFolder(app_state);
        },
        .mouse_button_down => |m| switch (m.button) {
            .left => if (app_state.controls_open) {
                controlsClick(app_state);
            } else if (app_state.video_open) {
                try videoClick(app_state);
            } else if (app_state.options_open) {
                try optionsClick(app_state);
            } else if (app_state.screen == .title) {
                const gui = guiSize(app_state);
                if (render.title_screen.actionAt(app_state.mouse_x, app_state.mouse_y, gui)) |action| switch (action) {
                    .singleplayer => try openSelectWorld(app_state),
                    .options => try openOptions(app_state, .title),
                    .quit => return .success,
                };
            } else if (app_state.screen == .select_world) {
                try selectWorldClick(app_state);
            } else if (app_state.screen == .create_world) {
                try createWorldClick(app_state);
            } else if (app_state.screen == .confirm_delete) {
                try confirmDeleteClick(app_state);
            } else if (app_state.screen == .loading) {
                // the loading screen swallows clicks until the spawn area is ready
            } else if (app_state.paused) {
                try pauseMenuClick(app_state);
            } else if (containerOpen(app_state)) {
                try openContainerClickAt(app_state, .left);
            } else {
                app_state.mouse_left_down = true;
                app_state.player.swingItem();
            },
            .right => if (app_state.controls_open or app_state.video_open or app_state.options_open or app_state.screen == .title or app_state.paused) {} else if (containerOpen(app_state)) {
                try openContainerClickAt(app_state, .right);
            } else {
                try useBlockOrPlace(app_state);
                app_state.player.swingItem();
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
        if (state.save_handle != null) saveWorld(state) catch {};
        if (state.save_handle) |*handle| handle.close(state.gpa, state.io);
        world.save.freeList(state.gpa, state.summaries);
        state.saves_dir.close(state.io);
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
    if (builtin.mode == .Debug) _ = debug_allocator.deinit();
}
