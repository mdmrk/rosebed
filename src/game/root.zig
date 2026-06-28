pub const Player = @import("player.zig");
pub const physics = @import("physics.zig");
pub const raycast = @import("raycast.zig");
pub const Inventory = @import("inventory.zig");
pub const ItemEntity = @import("item_entity.zig");
pub const FallingBlock = @import("falling_block.zig");
pub const Pig = @import("pig.zig");
pub const crafting = @import("crafting.zig");

test {
    _ = Player;
    _ = physics;
    _ = raycast;
    _ = Inventory;
    _ = ItemEntity;
    _ = FallingBlock;
    _ = Pig;
    _ = crafting;
}
