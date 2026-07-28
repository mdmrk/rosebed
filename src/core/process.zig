const std = @import("std");
const builtin = @import("builtin");

pub const Usage = struct {
    used: u64,
    allocated: u64,
    max: u64,
};

const unknown: Usage = .{ .used = 0, .allocated = 0, .max = 1 };

pub fn sample() Usage {
    return switch (builtin.os.tag) {
        .linux => sampleLinux(),
        .windows => sampleWindows(),
        .macos => sampleMacos(),
        .emscripten => sampleEmscripten(),
        else => unknown,
    };
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    const n = std.os.linux.read(fd, buf.ptr, buf.len);
    if (@as(isize, @bitCast(n)) < 0) return null;
    return buf[0..n];
}

fn sampleLinux() Usage {
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

const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: std.os.windows.DWORD,
    PageFaultCount: std.os.windows.DWORD,
    PeakWorkingSetSize: std.os.windows.SIZE_T,
    WorkingSetSize: std.os.windows.SIZE_T,
    QuotaPeakPagedPoolUsage: std.os.windows.SIZE_T,
    QuotaPagedPoolUsage: std.os.windows.SIZE_T,
    QuotaPeakNonPagedPoolUsage: std.os.windows.SIZE_T,
    QuotaNonPagedPoolUsage: std.os.windows.SIZE_T,
    PagefileUsage: std.os.windows.SIZE_T,
    PeakPagefileUsage: std.os.windows.SIZE_T,
};

const MEMORYSTATUSEX = extern struct {
    dwLength: std.os.windows.DWORD,
    dwMemoryLoad: std.os.windows.DWORD,
    ullTotalPhys: std.os.windows.ULONGLONG,
    ullAvailPhys: std.os.windows.ULONGLONG,
    ullTotalPageFile: std.os.windows.ULONGLONG,
    ullAvailPageFile: std.os.windows.ULONGLONG,
    ullTotalVirtual: std.os.windows.ULONGLONG,
    ullAvailVirtual: std.os.windows.ULONGLONG,
    ullAvailExtendedVirtual: std.os.windows.ULONGLONG,
};

extern "kernel32" fn K32GetProcessMemoryInfo(
    Process: std.os.windows.HANDLE,
    ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
    cb: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) std.os.windows.BOOL;

fn sampleWindows() Usage {
    var counters: PROCESS_MEMORY_COUNTERS = undefined;
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
    if (K32GetProcessMemoryInfo(std.os.windows.GetCurrentProcess(), &counters, counters.cb) == .FALSE) return unknown;

    var status: MEMORYSTATUSEX = undefined;
    status.dwLength = @sizeOf(MEMORYSTATUSEX);
    const max: u64 = if (GlobalMemoryStatusEx(&status) == .FALSE) 0 else status.ullTotalPhys;

    return .{
        .used = counters.WorkingSetSize,
        .allocated = @max(counters.PagefileUsage, counters.WorkingSetSize),
        .max = @max(max, 1),
    };
}

fn sampleMacos() Usage {
    var info: std.c.task_vm_info_data_t = undefined;
    var count: std.c.mach_msg_type_number_t = std.c.TASK.VM.INFO_COUNT;
    if (std.c.task_info(std.c.mach_task_self(), std.c.TASK.VM.INFO, @ptrCast(&info), &count) != 0) return unknown;

    var max: u64 = 0;
    var max_len: usize = @sizeOf(u64);
    if (std.c.sysctlbyname("hw.memsize", &max, &max_len, null, 0) != 0) max = 0;

    return .{ .used = info.resident_size, .allocated = info.virtual_size, .max = @max(max, 1) };
}

const mallinfo_t = extern struct {
    arena: usize,
    ordblks: usize,
    smblks: usize,
    hblks: usize,
    hblkhd: usize,
    usmblks: usize,
    fsmblks: usize,
    uordblks: usize,
    fordblks: usize,
    keepcost: usize,
};

extern fn mallinfo() mallinfo_t;
extern fn emscripten_get_heap_size() usize;
extern fn emscripten_get_heap_max() usize;

fn sampleEmscripten() Usage {
    return .{
        .used = mallinfo().uordblks,
        .allocated = emscripten_get_heap_size(),
        .max = @max(emscripten_get_heap_max(), 1),
    };
}

test "a sample never reports a zero total, so callers can divide by it" {
    const usage = sample();
    try std.testing.expect(usage.max >= 1);
    try std.testing.expect(usage.allocated >= usage.used);
}
