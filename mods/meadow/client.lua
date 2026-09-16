local line_height = 10
local panel_width = 164
local toggle_key = "H"

local lines = {
  { "Meadow", 0xFFD040 },
  { "planks + 3 comb: beehive", 0xE0E0E0 },
  { "comb: 2 wax", 0xE0E0E0 },
  { "comb + bowl: honey", 0xE0E0E0 },
  { "wax over birch log: smoker", 0xE0E0E0 },
  { "2 pollen + sugar: comb", 0xE0E0E0 },
  { toggle_key .. " hides this", 0x909090 },
}

local shown = true

rosebed.input.on_key(function(key, pressed)
  if key == toggle_key and pressed then
    shown = not shown
  end
end)

rosebed.hud.on_draw(function(width, height)
  if not shown then
    return
  end
  rosebed.hud.rect(2, 2, panel_width, #lines * line_height + 4, 0x80000000)
  for index, line in ipairs(lines) do
    rosebed.hud.text(line[1], 6, 4 + (index - 1) * line_height, line[2])
  end
end)
