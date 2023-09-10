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

--- Builds a valid sprite path or returns nil
--- @param item string
--- @return string, string, LocalizedString
function util.generate_item_references(item)
  local sprite = nil
  local image_path = ""
  local item_name
  if game.is_valid_sprite_path("item/" .. item) then
    sprite = "item/" .. item
    image_path = "[img=item." .. item .. "]"
    item_name = {"?", { "item-name." .. item }, { "entity-name." .. item }, "LocalizedString failure: " .. item }
  elseif game.is_valid_sprite_path("fluid/" .. item) then
    sprite = "fluid/" .. item
    image_path = "[img=fluid." .. item .. "]"
    item_name = {"?", { "fluid-name." .. item }, "LocalizedString failure: " .. item }
  elseif game.is_valid_sprite_path("virtual-signal/" .. item) then
    sprite = "virtual-signal/" .. item
    image_path = "[img=virtual-signal." .. item .. "]"
    item_name = {"?", { "virtual-signal." .. item }, "LocalizedString failure: " .. item }
  end
  return sprite, image_path, item_name
end


--- Updates a slot table based on the passed criteria.
--- @param manifest Manifest?
--- @param color string
--- @return GuiElemDef[]
function util.slot_table_build_from_manifest(manifest, color)
  ---@type GuiElemDef[]
  local children = {}
  if manifest then
    for _, item in pairs(manifest) do
      local name = item.name
      local count = item.count
      local sprite, img_path, item_string = util.generate_item_references(name)
      if game.is_valid_sprite_path(sprite) then
        children[#children + 1] = {
          type = "sprite-button",
          enabled = false,
          style = "ltnm_small_slot_button_" .. color,
          sprite = sprite,
          number = count,
          tooltip = {
            "",
            img_path,
            item_string,
            "\n"..format.number(count),
          },
        }
      end
    end
  end
  return children
end

--- @param station Station
--- @param color string
--- @return GuiElemDef[]
function util.slot_table_build_from_station(station)
  ---@type GuiElemDef[]
  local children = {}
  local comb1_signals, comb2_signals = get_signals(station)
  if comb1_signals then
    for _, v in pairs(comb1_signals) do
      local item = v.signal
      if item.type == "virtual" then
        goto continue
      end
      local count = v.count
      local name = item.name
      local sprite, img_path, item_string = util.generate_item_references(name)
      if sprite ~= nil then
        local color
        if count > 0 then
          color = "green"
        else
          color = "red"
        end
        if game.is_valid_sprite_path(sprite) then
          children[#children + 1] = {
            type = "sprite-button",
            enabled = false,
            style = "ltnm_small_slot_button_" .. color,
            sprite = sprite,
            tooltip = {
              "",
              img_path,
              item_string,
              "\n"..format.number(count),
            },
            number = count
          }
        end
      end
      ::continue::
    end
  end
  return children
end

function util.slot_table_build_from_deliveries(station)
  ---@type GuiElemDef[]
  local children = {}
  local deliveries = station.deliveries

  for item, count in pairs(deliveries) do

    local sprite, img_path, item_string = util.generate_item_references(item)
    if sprite ~= nil then
      local color
      if count > 0 then
        color = "green"
      else
        color = "blue"
      end
      if game.is_valid_sprite_path(sprite) then
        children[#children + 1] = {
          type = "sprite-button",
          enabled = false,
          style = "ltnm_small_slot_button_" .. color,
          sprite = sprite,
          tooltip = {
            "",
            img_path,
            item_string,
            "\n"..format.number(count),
          },
          number = count
        }
      end
    end
  end
  return children
end

--- @param station Station
--- @return GuiElemDef[]
function util.slot_table_build_from_control_signals(station, map_data)
  ---@type GuiElemDef[]
  local children = {}
  local comb1_signals, comb2_signals = get_signals(station)

  if comb1_signals then
    for _, v in pairs(comb1_signals) do
      local item = v.signal
      local count = v.count
      local name = item.name
      local sprite = ""
      local color = "default"
      if item.type ~= "virtual" then
        goto continue
      else
        sprite = "virtual-signal" .. "/" .. name
      end
      if game.is_valid_sprite_path(sprite) then
        children[#children + 1] = {
          type = "sprite-button",
          enabled = false,
          style = "ltnm_small_slot_button_" .. color,
          sprite = sprite,
          tooltip = {
            "",
            "[img=virtual-signal." .. name  .. "]",
            { "virtual-signal-name." .. name },
            "\n"..format.number(count),
          },
          number = count
        }
      end
      ::continue::
    end
  end

  if comb2_signals then
    for _, v in pairs(comb2_signals) do
      local item = v.signal
      local count = v.count
      local name = item.name
      local sprite = ""
      local color = "default"

      if item.type == "item" or item.type == "fluid" then
        local sprite, img_path, item_string = util.generate_item_references(name)
        if sprite ~= nil then
          local color
          if count > 0 then
            color = "green"
          else
            color = "blue"
          end
        end

        if station.is_stack and item.type == "item" then
          count = count * get_stack_size(map_data, name)
        end

        if game.is_valid_sprite_path(sprite) then
          children[#children + 1] = {
            type = "sprite-button",
            enabled = false,
            style = "ltnm_small_slot_button_" .. color,
            sprite = sprite,
            tooltip = {
              "",
              img_path,
              item_string,
              "\n"..format.number(count),
            },
            number = count
          }
        end

      elseif item.type == "virtual" then
        sprite = "virtual-signal" .. "/" .. name
        if game.is_valid_sprite_path(sprite) then
          children[#children + 1] = {
            type = "sprite-button",
            enabled = false,
            style = "ltnm_small_slot_button_" .. color,
            sprite = sprite,
            tooltip = {
              "",
              "[img=virtual-signal." .. name  .. "]",
              { "virtual-signal-name." .. name },
              "\n"..format.number(count),
            },
            number = count
          }
        end
      end
      ::continue::
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

function util.close_manager_window(player, player_data, refs)
  if player_data.pinning then
		return
	end

	refs.manager_window.visible = false
	player_data.visible = false

	if player.opened == refs.manager_window then
		player.opened = nil
	end

	player_data.is_manager_open = false
	player.set_shortcut_toggled("cybersyn-toggle-gui", false)

end

function util.build_train_layout_table(map_data)
  local layouts = map_data.layouts
  local layouts_table = {}
  for i, v in pairs(layouts) do
    local layout_string = table.concat(v, ",")
    layout_string = layout_string.gsub(layout_string, "0", "[item=locomotive]")
    layout_string = layout_string.gsub(layout_string, "1", "[item=cargo-wagon]")
    layout_string = layout_string.gsub(layout_string, "2", "[item=fluid-wagon]")
    layout_string = layout_string.gsub(layout_string, ",", "")
    layouts_table[i] = layout_string
  end
  return layouts_table


end

return util
