pub const Commands = @import("Commands.zig");
pub const discovery = @import("discovery.zig");
pub const Effects = @import("Effects.zig");
pub const Hooks = @import("Hooks.zig");
pub const Hud = @import("Hud.zig");
pub const Input = @import("Input.zig");
pub const load_order = @import("load_order.zig");
pub const Loaded = @import("Loaded.zig");
pub const Manifest = @import("Manifest.zig");
pub const mobs = @import("mobs.zig");
pub const Net = @import("Net.zig");
pub const Player = @import("Player.zig");
pub const registry = @import("registry.zig");
pub const structures = @import("structures.zig");
pub const Vm = @import("Vm.zig");

test {
    _ = Hooks;
    _ = Net;
    _ = Effects;
    _ = Commands;
    _ = Hud;
    _ = Input;
    _ = Player;
    _ = Loaded;
    _ = mobs;
    _ = registry;
    _ = structures;
    _ = Manifest;
    _ = discovery;
    _ = load_order;
    _ = Vm;
}
