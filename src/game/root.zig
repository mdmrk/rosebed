pub const Entity = @import("entity.zig");
pub const Entities = @import("entities.zig");
pub const Player = @import("player.zig");
pub const physics = @import("physics.zig");
pub const raycast = @import("raycast.zig");
pub const Inventory = @import("inventory.zig");
pub const ItemEntity = @import("item_entity.zig");
pub const Particle = @import("particle.zig");
pub const FallingBlock = @import("falling_block.zig");
pub const Pig = @import("pig.zig");
pub const crafting = @import("crafting.zig");
pub const Settings = @import("settings.zig");
pub const stats = @import("stats.zig");
pub const stats_file = @import("stats_file.zig");

test {
    _ = Entity;
    _ = Entities;
    _ = Player;
    _ = physics;
    _ = raycast;
    _ = Inventory;
    _ = ItemEntity;
    _ = Particle;
    _ = FallingBlock;
    _ = Pig;
    _ = crafting;
    _ = Settings;
    _ = stats;
    _ = stats_file;
}
