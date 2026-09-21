local player = rosebed.player
local hud = rosebed.hud

local wings = "elytra:wings"
local reach = 432
local top_speed = 1.6
local wear_period = 20

local gliding = false
local worn = 0
local left = reach

local function look(yaw, pitch)
    local ry, rp = math.rad(yaw), math.rad(pitch)
    local cp = math.cos(rp)
    return -math.sin(ry) * cp, -math.sin(rp), math.cos(ry) * cp
end

local function wearing()
    return player.equipped("chestplate") == wings
end

local function spread(pitch)
    return {
        pitch = math.pi * 0.5 + math.rad(pitch) * 0.5,
        lift = 0.3,
        limbs = {
            right_arm = { -0.2, 0, -1.3 },
            left_arm = { -0.2, 0, 1.3 },
            right_leg = { 0.15, 0, -0.05 },
            left_leg = { 0.15, 0, 0.05 },
        },
    }
end

local function land()
    if gliding then
        player.set_pose()
    end
    gliding = false
    worn = 0
end

player.on_tick(function(jump)
    if player.on_ground() or not wearing() then
        land()
        return false
    end
    if jump then
        gliding = true
    end
    if not gliding then
        return false
    end

    local yaw, pitch = player.look()
    local lx, ly, lz = look(yaw, pitch)
    local vx, vy, vz = player.motion()

    vy = vy - 0.05 + ly * 0.06
    if vy < 0 then
        vx = vx + lx * -vy * 0.6
        vz = vz + lz * -vy * 0.6
    end
    if ly > 0 then
        vx = vx * 0.97
        vz = vz * 0.97
    end

    vx, vy, vz = vx * 0.99, vy * 0.98, vz * 0.99

    local speed = math.sqrt(vx * vx + vz * vz)
    if speed > top_speed then
        local damp = top_speed / speed
        vx, vz = vx * damp, vz * damp
    end

    player.set_motion(vx, vy, vz)
    player.set_fall_distance(0)
    player.set_pose(spread(pitch))

    local _, _, damage = player.equipped("chestplate")
    left = reach - damage

    worn = worn + 1
    if worn >= wear_period then
        worn = 0
        if player.damage_equipped("chestplate") then
            land()
        end
    end
    return true
end)

player.on_peer_pose(function()
    if player.equipped("chestplate") ~= wings then
        return
    end
    local _, y = player.position()
    if y < 1 then
        return
    end
    local _, pitch = player.look()
    player.set_pose(spread(pitch))
end)

hud.on_draw(function(width, height)
    if not gliding then
        return
    end
    local bar = 60
    local filled = math.floor(bar * left / reach + 0.5)
    local x = math.floor(width / 2) - math.floor(bar / 2)
    local y = height - 64
    hud.rect(x - 1, y - 1, bar + 2, 5, 0xC0000000)
    hud.rect(x, y, filled, 3, 0xFF7ACBE0)
end)
