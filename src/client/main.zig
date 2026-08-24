const sdl3 = @import("sdl3");

const app = @import("app.zig");

comptime {
    _ = sdl3.main_callbacks;
}
pub const _start = void;
pub const WinMainCRTStartup = void;

pub fn init(init_data: sdl3.Init) !struct { app.AppState, sdl3.AppResult } {
    return app.init(init_data);
}

pub fn iterate(app_state: *app.AppState) !sdl3.AppResult {
    return app.iterate(app_state);
}

pub fn event(app_state: *app.AppState, curr_event: sdl3.events.Event) !sdl3.AppResult {
    return app.event(app_state, curr_event);
}

pub fn quit(app_state: ?*app.AppState, result: sdl3.AppResult) void {
    app.quit(app_state, result);
}
