local gui = require("__flib__.gui")
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
  if helpers.is_valid_sprite_path("item/" .. item) then
    sprite = "item/" .. item
    image_path = "[img=item." .. item .. "]"
    item_name = {"?", { "item-name." .. item }, { "entity-name." .. item }, "LocalizedString failure: " .. item }
  elseif helpers.is_valid_sprite_path("fluid/" .. item) then
    sprite = "fluid/" .. item
    image_path = "[img=fluid." .. item .. "]"
    item_name = {"?", { "fluid-name." .. item }, "LocalizedString failure: " .. item }
  elseif helpers.is_valid_sprite_path("virtual-signal/" .. item) then
    sprite = "virtual-signal/" .. item
    image_path = "[img=virtual-signal." .. item .. "]"
    item_name = {"?", { "virtual-signal." .. item }, "LocalizedString failure: " .. item }
  end
  return sprite, image_path, item_name
end

--- Turns SignalID into a valid rich-text definition of the signal icon.
--- @param signal SignalID
--- @return string
function util.rich_text_from_signal(signal)
  local quality = signal.quality or ""
  local type = signal.type or "item" -- if type is nil, it is item
  return "[" .. type .. "=" .. signal.name .. ",quality=" .. quality .. "]"
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
      local signal = {
        type=item.type,
        name=item.name,
        quality=item.quality,
      }
      children[#children + 1] = {
        type = "choose-elem-button",
        elem_type = "signal",
        signal = signal,
        enabled = false,
        style = "ltnm_small_slot_button_" .. color,
        tooltip = {
          "",
          util.rich_text_from_signal(signal),
          " shipped",
          "\n Amount: "..format.number(item.count),
        },
        children = {
          {
            type = "label",
            style = "ltnm_label_signal_count",
            ignored_by_interaction = true,
            caption = format_signal_count(item.count)
          }
        },
      }
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
      -- ignore negative if provide only and positive if request only
      if (not station.is_r and count < 0) or (not station.is_p and count > 0) then
        goto continue
      end
      local color
      if count > 0 then
        color = "green"
      else
        -- color sub-threshold requests orange, others red
        local r_threshold = station.item_thresholds and station.item_thresholds[name] or station.r_threshold
        if station.is_stack and item.type ~= "fluid" then
          r_threshold = r_threshold*get_stack_size(nil, item.name) --first argument never used
        end
        if -count < r_threshold then
          color = "orange"
        else
          color = "red"
        end
      end
      children[#children + 1] = {
        type = "choose-elem-button",
        elem_type = "signal",
        signal = item,
        enabled = false,
        style = "ltnm_small_slot_button_" .. color,
        tooltip = {
          "",
          util.rich_text_from_signal(item),
          color == "red" and " requested" or
          color == "green" and " provided" or
          color == "orange" and " requested (below threshold)" or
          "",
          "\n Amount: "..format.number(count),
        },
        children = {
          {
            type = "label",
            style = "ltnm_label_signal_count",
            ignored_by_interaction = true,
            caption = format_signal_count(count)
          }
        },
      }
      ::continue::
    end
  end
  return children
end

function util.slot_table_build_from_deliveries(station)
  ---@type GuiElemDef[]
  local children = {}
  local deliveries = station.deliveries

  for item_hash, count in pairs(deliveries) do
    item, quality = unhash_signal(item_hash)
    local signal = {
      type = prototypes.item[item] == nil and "fluid" or "item",
      name=item,
      quality=quality,
    }

    local color
    if count > 0 then
      color = "green"
    else
      color = "blue"
    end
    children[#children + 1] = {
      type = "choose-elem-button",
      elem_type = "signal",
      signal = signal,
      enabled = false,
      tooltip = {
        "",
        util.rich_text_from_signal(signal),
        color == "green" and " incoming" or
        color == "blue" and " outgoing" or
        "",
        "\n Amount: "..format.number(count),
      },
      style = "ltnm_small_slot_button_" .. color,
      children = {
        {
          type = "label",
          style = "ltnm_label_signal_count",
          ignored_by_interaction = true,
          caption = format_signal_count(count)
        }
      },
    }
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
      local color = "default"
      if item.type ~= "virtual" then
        goto continue
      end
      children[#children + 1] = {
        type = "choose-elem-button",
        elem_type = "signal",
        signal = item,
        enabled = false,
        ignored_by_interaction = true,
        style = "ltnm_small_slot_button_" .. color,
        children = {
          {
            type = "label",
            style = "ltnm_label_signal_count",
            ignored_by_interaction = true,
            caption = format_signal_count(count)
          }
        },
      }
      ::continue::
    end
  end

  if comb2_signals then
    for _, v in pairs(comb2_signals) do
      local item = v.signal
      local count = v.count
      local name = item.name
      local color = "default"

      if station.is_stack and (not item.type or item.type == "item") then
        count = count * get_stack_size(map_data, name)
      end

      children[#children + 1] = {
        type = "choose-elem-button",
        elem_type = "signal",
        signal = item,
        enabled = false,
        ignored_by_interaction = true,
        style = "ltnm_small_slot_button_" .. color,
        children = {
          {
            type = "label",
            style = "ltnm_label_signal_count",
            ignored_by_interaction = true,
            caption = format_signal_count(count)
          }
        },
      }
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
