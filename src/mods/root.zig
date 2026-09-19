pub const Manifest = @import("Manifest.zig");
pub const Vm = @import("Vm.zig");
pub const discovery = @import("discovery.zig");
pub const load_order = @import("load_order.zig");
pub const mobs = @import("mobs.zig");
pub const registry = @import("registry.zig");
pub const structures = @import("structures.zig");
pub const Loaded = @import("Loaded.zig");
pub const Hooks = @import("Hooks.zig");
pub const Hud = @import("Hud.zig");
pub const Input = @import("Input.zig");

test {
    _ = Hooks;
    _ = Hud;
    _ = Input;
    _ = Loaded;
    _ = mobs;
    _ = registry;
    _ = structures;
    _ = Manifest;
    _ = discovery;
    _ = load_order;
    _ = Vm;
}
