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

pub fn signPacket(pos: world.BlockPos, post: *const world.sign.Sign) net.packet.Packet {
    return .{ .update_sign = .{
        .x = pos.x,
        .y = @intCast(pos.y),
        .z = pos.z,
        .lines = .{ post.line(0), post.line(1), post.line(2), post.line(3) },
    } };
}
