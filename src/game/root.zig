pub const Player = @import("player.zig");
pub const physics = @import("physics.zig");
pub const raycast = @import("raycast.zig");
pub const Inventory = @import("inventory.zig");
pub const ItemEntity = @import("item_entity.zig");

test {
    _ = Player;
    _ = physics;
    _ = raycast;
    _ = Inventory;
    _ = ItemEntity;
}
