const std = @import("std");

const gl = @import("gl");
const sdl3 = @import("sdl3");

const Timer = @import("core").Timer;

const fps = 60;
const ticks_per_second = 20.0;
const screen_width = 640;
const screen_height = 480;
const init_flags = sdl3.InitFlags{ .video = true };

comptime {
    _ = sdl3.main_callbacks;
}
pub const _start = void;
pub const WinMainCRTStartup = void;

const AppState = struct {
    fps_capper: sdl3.extras.FramerateCapper(f32),
    window: sdl3.video.Window,
    timer: Timer,
    tick_count: u64 = 0,
};

pub fn init(
    init_data: sdl3.Init,
) !struct { AppState, sdl3.AppResult } {
    _ = init_data;

    try sdl3.init(init_flags);
    errdefer sdl3.quit(init_flags);

    const window = try sdl3.video.Window.init("Rosebed", screen_width, screen_height, .{
        .open_gl = true,
        .resizable = true,
    });
    errdefer window.deinit();

    return .{
        .{
            .fps_capper = .{ .mode = .{ .limited = fps } },
            .window = window,
            .timer = Timer.init(ticks_per_second, sdl3.timer.getNanosecondsSinceInit()),
        },
        .run,
    };
}

fn tick(app_state: *AppState) void {
    app_state.tick_count += 1;
}

pub fn iterate(
    app_state: *AppState,
) !sdl3.AppResult {
    const dt = app_state.fps_capper.delay();
    _ = dt;

    app_state.timer.advance(sdl3.timer.getNanosecondsSinceInit());
    for (0..@intCast(app_state.timer.elapsed_ticks)) |_| {
        tick(app_state);
    }

    const surface = try app_state.window.getSurface();
    try surface.fillRect(null, surface.mapRgb(128, 30, 255));
    try app_state.window.updateSurface();

    return .run;
}

pub fn event(
    app_state: *AppState,
    curr_event: sdl3.events.Event,
) !sdl3.AppResult {
    _ = app_state;

    return switch (curr_event) {
        .quit => .success,
        .terminating => .success,
        else => .run,
    };
}

pub fn quit(
    app_state: ?*AppState,
    result: sdl3.AppResult,
) void {
    _ = result;

    if (app_state) |state| {
        state.window.deinit();
    }
    sdl3.quit(init_flags);
    sdl3.shutdown();
}
