const std = @import("std");
const builtin = @import("builtin");

pub const Usage = struct {
    used: u64,
    allocated: u64,
    max: u64,
};

const unknown: Usage = .{ .used = 0, .allocated = 0, .max = 1 };

fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, buf.ptr, buf.len);
    if (@as(isize, @bitCast(n)) < 0) return null;
    return buf[0..n];
}

pub fn sample() Usage {
    if (builtin.os.tag != .linux) return unknown;

    const page_size: u64 = 4096;

    var statm_buf: [256]u8 = undefined;
    const statm = readFile("/proc/self/statm", &statm_buf) orelse return unknown;
    var fields = std.mem.tokenizeAny(u8, statm, " \n");
    const size = std.fmt.parseInt(u64, fields.next() orelse return unknown, 10) catch return unknown;
    const resident = std.fmt.parseInt(u64, fields.next() orelse return unknown, 10) catch return unknown;

    var meminfo_buf: [256]u8 = undefined;
    var max: u64 = 1;
    if (readFile("/proc/meminfo", &meminfo_buf)) |meminfo| {
        var lines = std.mem.tokenizeScalar(u8, meminfo, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            _ = parts.next();
            max = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
            max *= 1024;
            break;
        }
    }

    return .{ .used = resident * page_size, .allocated = size * page_size, .max = @max(max, 1) };
}

test "a sample never reports a zero total, so callers can divide by it" {
    const usage = sample();
    try std.testing.expect(usage.max >= 1);
    try std.testing.expect(usage.allocated >= usage.used);
}
