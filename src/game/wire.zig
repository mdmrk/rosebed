const net = @import("net");
const world = @import("world");

pub fn toStack(stack: ?world.Stack) ?net.packet.Stack {
    const held = stack orelse return null;
    return .{
        .id = held.id.numeric(),
        .count = @intCast(held.count),
        .damage = @bitCast(held.meta),
    };
}

pub fn fromStack(stack: ?net.packet.Stack) ?world.Stack {
    const held = stack orelse return null;
    if (held.count <= 0) return null;
    return .{
        .id = world.Id.fromNumeric(held.id),
        .count = @intCast(held.count),
        .meta = @bitCast(held.damage),
    };
}
