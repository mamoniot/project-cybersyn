local gui = require("__flib__.gui-lite")
local format = require("__flib__.format")

local util = {}

--- Create a flying text at the player's cursor with an error sound.
--- @param player LuaPlayer
--- @param message LocalisedString
function util.error_flying_text(player, message)
  player.create_local_flying_text({ create_at_cursor = true, text = message })
  player.play_sound({ path = "utility/cannot_build" })
end

function util.gui_list(parent, iterator, test, build, update, ...)
  local children = parent.children
  local i = 0

  for k, v in table.unpack(iterator) do
    local passed = test(v, k, i, ...)
    if passed then
      i = i + 1
      local child = children[i]
      if not child then
        gui.build(parent, { build(...) })
        child = parent.children[i]
      end
      gui.update(child, update(v, k, i, ...))
    end
  end

  for j = i + 1, #children do
    children[j].destroy()
  end
end

--- Updates a slot table based on the passed criteria.
--- @param manifest Manifest
--- @param color string
--- @return GuiElemDef[]
function util.slot_table_build(manifest, color)
  local children = {}
  local i = 1
  for _, item in pairs(manifest) do
    local name = item.name
    local sprite
    if item.type then
      sprite = item.type .. "/" .. name
    else
      sprite = string.gsub(name, ",", "/")
    end
    if game.is_valid_sprite_path(sprite) then
      children[i] = {
        type = "sprite-button",
        enabled = false,
        style = "ltnm_small_slot_button_" .. color,
        sprite = sprite,
        tooltip = {
          "",
          "[img=" .. sprite  .. "]",
          { "item-name." .. name },
          "\n"..format.number(count),
        },
      }
      i = i + 1
    end
  end
  return children
end

function util.sorted_iterator(arr, src_tbl, sort_state)
  local step = sort_state and 1 or -1
  local i = sort_state and 1 or #arr

  return function()
    local j = i + step
    if arr[j] then
      i = j
      local arr_value = arr[j]
      return arr_value, src_tbl[arr_value]
    end
  end,
  arr
end

local MAX_INT = 2147483648 -- math.pow(2, 31)
function util.signed_int32(val)
  return (val >= MAX_INT and val - (2 * MAX_INT)) or val
end

return util
