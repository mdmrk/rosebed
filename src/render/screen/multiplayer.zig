const std = @import("std");

const gl = @import("gl");

const button = @import("../button.zig");
const gui = @import("../gui.zig");
const MeshBuilder = @import("../MeshBuilder.zig");
const text_field = @import("../text_field.zig");

const title_color: [4]u8 = .{ 255, 255, 255, 255 };
const info_color: [4]u8 = .{ 160, 160, 160, 255 };

pub const field_width: f32 = 200;
pub const default_port: u16 = 25565;

const title = "Play Multiplayer";
const info1 = "Minecraft Multiplayer is currently not finished, but there";
const info2 = "is some buggy early testing going on.";
const ipinfo = "Enter the IP of a server to connect to it:";

pub const Hit = enum { address_field, connect, cancel };

pub const State = struct {
    address: text_field.TextField = .{ .focused = true, .charset = .address },

    pub fn tick(self: *State) void {
        self.address.tick();
    }

    pub fn typeText(self: *State, value: []const u8) void {
        self.address.insert(value);
    }

    pub fn backspace(self: *State) void {
        self.address.backspace();
    }

    pub fn canConnect(self: *const State) bool {
        return self.address.text().len > 0;
    }
};

pub fn init(last_server: []const u8) State {
    var state: State = .{};
    var typed: [text_field.max_length]u8 = undefined;
    const length = @min(last_server.len, typed.len);
    for (last_server[0..length], typed[0..length]) |c, *out| out.* = if (c == '_') ':' else c;
    state.address.setText(typed[0..length]);
    return state;
}

pub const Address = struct {
    host: []const u8,
    port: u16,
};

pub fn parseAddress(text: []const u8) Address {
    const trimmed = std.mem.trim(u8, text, " ");

    if (trimmed.len > 0 and trimmed[0] == '[') {
        if (std.mem.indexOfScalar(u8, trimmed, ']')) |close| {
            if (close > 0) {
                const host = trimmed[1..close];
                const rest = std.mem.trim(u8, trimmed[close + 1 ..], " ");
                if (rest.len > 0 and rest[0] == ':') return .{ .host = host, .port = parsePort(rest[1..]) };
                return .{ .host = host, .port = default_port };
            }
        }
    }

    var parts = std.mem.splitScalar(u8, trimmed, ':');
    const host = parts.next() orelse trimmed;
    const port_text = parts.next() orelse return .{ .host = trimmed, .port = default_port };
    if (parts.next() != null) return .{ .host = trimmed, .port = default_port };
    return .{ .host = host, .port = parsePort(port_text) };
}

fn parsePort(text: []const u8) u16 {
    return std.fmt.parseInt(u16, std.mem.trim(u8, text, " "), 10) catch default_port;
}

pub fn storedName(text: []const u8, out: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " ");
    const length = @min(trimmed.len, out.len);
    for (trimmed[0..length], out[0..length]) |c, *stored| stored.* = if (c == ':') '_' else c;
    return out[0..length];
}

pub fn addressRect(res: gui.Scaled) text_field.Rect {
    return .{
        .x = @floor(res.width / 2.0) - field_width / 2.0,
        .y = @floor(res.height / 4.0) + 58,
        .w = field_width,
    };
}

fn buttons(res: gui.Scaled, can_connect: bool) [2]struct { button: button.Button, hit: Hit } {
    const cx = @floor(res.width / 2.0);
    const quarter = @floor(res.height / 4.0);
    return .{
        .{ .button = .{ .x = cx - 100, .y = quarter + 96 + 12, .w = 200, .label = "Connect", .enabled = can_connect }, .hit = .connect },
        .{ .button = .{ .x = cx - 100, .y = quarter + 120 + 12, .w = 200, .label = "Cancel", .enabled = true }, .hit = .cancel },
    };
}

pub fn hitAt(mouse_x: f32, mouse_y: f32, res: gui.Scaled, state: *const State) ?Hit {
    const gx = mouse_x / res.factor;
    const gy = mouse_y / res.factor;

    if (text_field.contains(addressRect(res), gx, gy)) return .address_field;

    for (buttons(res, state.canConnect())) |entry| {
        if (entry.button.enabled and button.contains(entry.button, gx, gy)) return entry.hit;
    }
    return null;
}

pub fn draw(ui: gui.Ui, state: *const State) !void {
    const gx = ui.mouse_x / ui.res.factor;
    const gy = ui.mouse_y / ui.res.factor;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    try gui.drawDirtBackground(ui);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    for (buttons(ui.res, state.canConnect())) |entry| {
        const hovered = entry.button.enabled and button.contains(entry.button, gx, gy);
        try button.append(&backgrounds, &text, ui.gpa, ui.font, entry.button, hovered, ui.res);
    }

    const cx = @floor(ui.res.width / 2.0);
    const quarter = @floor(ui.res.height / 4.0);

    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, cx - title_width / 2.0, quarter - 40, title_color, ui.res);
    try gui.appendTextColor(&text, ui.gpa, ui.font, info1, cx - 140, quarter, info_color, ui.res);
    try gui.appendTextColor(&text, ui.gpa, ui.font, info2, cx - 140, quarter + 9, info_color, ui.res);
    try gui.appendTextColor(&text, ui.gpa, ui.font, ipinfo, cx - 140, quarter + 36, info_color, ui.res);

    try text_field.append(&backgrounds, &text, ui.gpa, ui.font, &state.address, addressRect(ui.res), ui.res);

    try gui.drawTexturedMesh(&backgrounds, ui.shader, ui.textures.gui);
    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}

test "a bare host connects on the default port" {
    const parsed = parseAddress("localhost");
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(default_port, parsed.port);
}

test "a host and port are split on the colon" {
    const parsed = parseAddress("example.com:1234");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 1234), parsed.port);
}

test "a port that is not a number falls back to the default" {
    try std.testing.expectEqual(default_port, parseAddress("example.com:port").port);
    try std.testing.expectEqual(default_port, parseAddress("example.com:").port);
    try std.testing.expectEqualStrings("example.com", parseAddress("example.com:port").host);
}

test "more than one colon is taken as the whole address, as the original does" {
    const parsed = parseAddress("a:b:c");
    try std.testing.expectEqualStrings("a:b:c", parsed.host);
    try std.testing.expectEqual(default_port, parsed.port);
}

test "a bracketed address keeps its colons as the host" {
    const bare = parseAddress("[::1]");
    try std.testing.expectEqualStrings("::1", bare.host);
    try std.testing.expectEqual(default_port, bare.port);

    const with_port = parseAddress("[::1]:1234");
    try std.testing.expectEqualStrings("::1", with_port.host);
    try std.testing.expectEqual(@as(u16, 1234), with_port.port);
}

test "surrounding spaces are trimmed before the address is read" {
    const parsed = parseAddress("  localhost:1234  ");
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 1234), parsed.port);
}

test "the remembered name holds an underscore where the colon was" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("localhost_1234", storedName("localhost:1234", &buf));
    try std.testing.expectEqualStrings("localhost", storedName("  localhost  ", &buf));
}

test "connect stays dark until the field has something in it" {
    var state = init("");
    try std.testing.expect(!state.canConnect());
    state.typeText("localhost");
    try std.testing.expect(state.canConnect());
}

test "the screen opens on the server it was last pointed at" {
    const state = init("example.com_1234");
    try std.testing.expectEqualStrings("example.com:1234", state.address.text());
    try std.testing.expect(state.address.focused);
}

test "the field lands under the prompt and above the buttons" {
    const res = gui.scaledResolution(640, 480, 1);
    const rect = addressRect(res);
    try std.testing.expectEqual(@as(?Hit, .address_field), hitAt(rect.x + 4, rect.y + 4, res, &init("x")));
    try std.testing.expectEqual(@as(?Hit, null), hitAt(rect.x - 20, rect.y + 4, res, &init("x")));
}

test "cancel is always live, connect only with an address" {
    const res = gui.scaledResolution(640, 480, 1);
    const cx = @floor(res.width / 2.0);
    const quarter = @floor(res.height / 4.0);

    const empty = init("");
    try std.testing.expectEqual(@as(?Hit, null), hitAt(cx, quarter + 96 + 12 + 10, res, &empty));
    try std.testing.expectEqual(@as(?Hit, .cancel), hitAt(cx, quarter + 120 + 12 + 10, res, &empty));

    const filled = init("localhost");
    try std.testing.expectEqual(@as(?Hit, .connect), hitAt(cx, quarter + 96 + 12 + 10, res, &filled));
}
