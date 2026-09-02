const BlockPos = @This();

x: i32,
y: i32,
z: i32,

pub fn init(x: i32, y: i32, z: i32) BlockPos {
    return .{ .x = x, .y = y, .z = z };
}

pub fn offset(self: BlockPos, dx: i32, dy: i32, dz: i32) BlockPos {
    return .{ .x = self.x + dx, .y = self.y + dy, .z = self.z + dz };
}

pub fn distanceTo(self: BlockPos, other: BlockPos) f32 {
    const dx: f32 = @floatFromInt(other.x - self.x);
    const dy: f32 = @floatFromInt(other.y - self.y);
    const dz: f32 = @floatFromInt(other.z - self.z);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}
