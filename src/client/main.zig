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
const screen_width = 1280;
const screen_height = 720;
const init_flags = sdl3.InitFlags{ .video = true };
const font_png = assets.font.default_png;
const fov_y_radians = 70.0 * std.math.pi / 180.0;
const near_plane = 0.05;
const far_plane = 1000.0;
const world_seed = 1;
const reach_distance = 4.5;
const view_radius = 1;
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

const AppState = struct {
    gpa: std.mem.Allocator,
    frame: std.mem.Allocator,
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    gl_context: sdl3.video.gl.Context,
    gl_procs: gl.ProcTable,
    textures: render.Textures,
    colorizer: render.Colorizer,
    font: render.Font,
    shader: render.Shader,
    generator: world.TerrainGenerator,
    world_map: world.World,
    chunks: render.ChunkRenderer = .{},
    entities: game.Entities = .{},
    timer: Timer,
    tick_count: u64 = 0,
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

fn debugStats(app_state: *const AppState) render.debug_overlay.Stats {
    const loaded: u32 = @intCast(app_state.chunks.loadedCount());
    const entities: u32 = @intCast(app_state.entities.count());
    const memory = core.process_memory.sample();
    return .{
        .fps = app_state.debug_fps,
        .chunk_updates = app_state.debug_chunk_updates,
        .renderers_rendered = loaded,
        .renderers_loaded = loaded,
        .entities_rendered = entities,
        .entities_total = entities,
        .particles = 0,
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

fn ensureChunksAroundPlayer(app_state: *AppState) !void {
    const center = playerChunkCoord(app_state);

    var cx = center.x - view_radius;
    while (cx <= center.x + view_radius) : (cx += 1) {
        var cz = center.z - view_radius;
        while (cz <= center.z + view_radius) : (cz += 1) {
            if (app_state.chunks.hasMesh(cx, cz)) continue;
            try app_state.world_map.ensureDecorated(app_state.generator, cx, cz);
            try app_state.chunks.markDirty(app_state.gpa, cx, cz);
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
        .textures = undefined,
        .colorizer = undefined,
        .font = undefined,
        .shader = undefined,
        .generator = undefined,
        .world_map = world.World.init(gpa),
        .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
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

    app_state.generator = try world.TerrainGenerator.init(gpa, world_seed);
    errdefer app_state.generator.deinit(gpa);

    return .{ app_state, .run };
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
        try markBlockChanged(app_state, hit.x, hit.z);
        return;
    }

    app_state.digging.?.progress += 1.0 / ticks_required;
    if (app_state.digging.?.progress >= 1.0) {
        try breakBlock(app_state, hit.x, hit.y, hit.z, block_id);
        try markBlockChanged(app_state, hit.x, hit.z);
    }
}

fn markBlockChanged(app_state: *AppState, x: i32, z: i32) !void {
    try world.light.relightAround(app_state.gpa, &app_state.world_map, x, z);
    try app_state.chunks.markBlockDirty(app_state.gpa, x, z);
}

fn spawnDroppedItem(app_state: *AppState, x: i32, y: i32, z: i32, stack: game.Inventory.ItemStack) !void {
    try app_state.entities.dropStack(app_state.gpa, x, y, z, stack, &app_state.world_map.rand);
}

fn checkFall(app_state: *AppState, x: i32, y: i32, z: i32) !void {
    const id = app_state.world_map.getBlockId(x, y, z);
    if (!world.block.isFalling(id)) return;
    if (!world.block.canFallInto(app_state.world_map.getBlockId(x, y - 1, z))) return;

    app_state.world_map.setBlockId(x, y, z, world.block.air);
    try markBlockChanged(app_state, x, z);

    try app_state.entities.spawnFallingBlock(app_state.gpa, x, y, z, id);
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

        const landing_empty = !world.block.isOpaque(app_state.world_map.getBlockId(x, y, z));
        const support_solid = !world.block.canFallInto(app_state.world_map.getBlockId(x, y - 1, z));
        if (outcome == .landed and landing_empty and support_solid) {
            app_state.world_map.setBlockId(x, y, z, block.block_id);
            try markBlockChanged(app_state, x, z);
        } else {
            try spawnDroppedItem(app_state, x, y, z, .{ .id = block.block_id, .count = 1 });
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
            @intFromFloat(@floor(app_state.player.base.position.x)),
            @intFromFloat(@floor(app_state.player.base.position.y)),
            @intFromFloat(@floor(app_state.player.base.position.z)),
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
    try markBlockChanged(app_state, px, pz);
    try checkFall(app_state, px, py, pz);
}

fn tick(app_state: *AppState) !void {
    app_state.tick_count += 1;

    const moving_allowed = !app_state.inventory_open;
    const forward: f32 = if (!moving_allowed) 0 else (if (app_state.keys.forward) @as(f32, 1) else 0) - (if (app_state.keys.back) @as(f32, 1) else 0);
    const strafe: f32 = if (!moving_allowed) 0 else (if (app_state.keys.left) @as(f32, 1) else 0) - (if (app_state.keys.right) @as(f32, 1) else 0);
    app_state.player.tick(&app_state.world_map, strafe, forward, moving_allowed and app_state.keys.jump);
    try digStep(app_state);
    app_state.entities.tickItems(&app_state.world_map, &app_state.player);
    try tickFallingBlocks(app_state);
    app_state.entities.tickPigs(&app_state.world_map, &app_state.world_map.rand);
    try ensureChunksAroundPlayer(app_state);
    try advanceWorldTime(app_state);
}

fn advanceWorldTime(app_state: *AppState) !void {
    app_state.world_map.time += 1;

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

fn horizonColor(app_state: *const AppState) render.sky.Color {
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
    const far = render.sky.farPlaneDistance(@intFromEnum(app_state.settings.render_distance));
    app_state.shader.setInt("u_fog_enabled", 1);
    app_state.shader.setVec3("u_fog_color", horizon);
    app_state.shader.setFloat("u_fog_start", far * 0.25);
    app_state.shader.setFloat("u_fog_end", far);
}

fn renderWorld(app_state: *AppState, horizon: render.sky.Color) !void {
    app_state.chunk_updates_this_second += try app_state.chunks.flush(app_state.gpa, &app_state.world_map, app_state.colorizer);

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
    const eye = app_state.player.base.renderPosition(partial);

    app_state.shader.use();
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
    app_state.chunks.drawSolid();

    var atlas_mesh: render.MeshBuilder = .{};
    defer atlas_mesh.deinit(app_state.frame);
    for (app_state.entities.items.items) |item| {
        try render.entity_render.appendItem(&atlas_mesh, app_state.frame, item, partial);
    }
    for (app_state.entities.falling_blocks.items) |block| {
        try render.entity_render.appendFallingBlock(&atlas_mesh, app_state.frame, block, partial);
    }
    drawEntityMesh(&atlas_mesh);

    var pig_mesh: render.MeshBuilder = .{};
    defer pig_mesh.deinit(app_state.frame);
    for (app_state.entities.pigs.items) |pig| {
        try render.entity_render.appendPig(&pig_mesh, app_state.frame, pig, partial);
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
    try app_state.chunks.drawTranslucent(app_state.frame, eye.x, eye.z);
    app_state.shader.setInt("u_alpha_test", 1);
    gl.Disable(gl.BLEND);
}

fn drawBreakingCrack(app_state: *AppState) !void {
    const digging = app_state.digging orelse return;
    if (digging.progress <= 0.0) return;

    const id = app_state.world_map.getBlockId(digging.x, digging.y, digging.z);
    if (id == world.block.air) return;

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
    const id = app_state.world_map.getBlockId(hit.x, hit.y, hit.z);
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
    }

    const horizon = horizonColor(app_state);
    gl.Enable(gl.DEPTH_TEST);
    gl.ClearColor(horizon[0], horizon[1], horizon[2], 1.0);
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    if (app_state.screen == .playing) try renderWorld(app_state, horizon);

    const ui = uiContext(app_state, gui);
    const backdrop: render.options_screen.Backdrop = if (app_state.options_parent == .pause) .veil else .dirt;

    if (app_state.screen == .playing and app_state.show_debug) {
        try render.debug_overlay.draw(ui, debugStats(app_state));
    }

    if (app_state.video_open) {
        try render.video_settings_screen.draw(ui, app_state.settings, backdrop);
    } else if (app_state.options_open) {
        try render.options_screen.draw(ui, app_state.settings, backdrop);
    } else if (app_state.screen == .title) {
        try render.title_screen.draw(ui, app_state.splash, sdl3.timer.getMillisecondsSinceInit());
    } else if (app_state.paused) {
        try render.menu.draw(ui);
    } else if (app_state.inventory_open) {
        try render.inventory_screen.draw(
            ui,
            render.mob_model.biped,
            app_state.player.inventory,
            app_state.crafting_grid,
            app_state.held_stack,
        );
    } else {
        try render.hud.draw(ui, app_state.player.inventory);
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
        state.chunks.deinit(state.gpa);
        state.entities.deinit(state.gpa);
        state.world_map.deinit();
        state.generator.deinit(state.gpa);
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
