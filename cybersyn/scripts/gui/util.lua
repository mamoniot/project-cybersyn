local gui = require("__flib__.gui-lite")
local format = require("__flib__.format")

local util = {}

--- Create a flying text at the player's cursor with an error sound.
---@param player LuaPlayer
---@param message LocalisedString
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
---@param name string
---@return string?, string?, LocalisedString?
function util.generate_item_references(name)
	local sprite_path, image_path, item_string = nil, nil, nil
	if game.is_valid_sprite_path("item/"..name) then
		sprite_path = "item/"..name
		image_path = "[img=item."..name.."]"
		item_string = {"?", {"item-name."..name}, {"entity-name."..name}, "LocalisedString failure: "..name}
	elseif game.is_valid_sprite_path("fluid/"..name) then
		sprite_path = "fluid/"..name
		image_path = "[img=fluid."..name.."]"
		item_string = {"?", {"fluid-name."..name}, "LocalisedString failure: "..name}
	elseif game.is_valid_sprite_path("virtual-signal/"..name) then
		sprite_path = "virtual-signal/"..name
		image_path = "[img=virtual-signal."..name.."]"
		item_string = {"?", {"virtual-signal-name."..name}, "LocalisedString failure: "..name}
	end
	return sprite_path, image_path, item_string
end

---@param children GuiElemDef[]
---@param name string
---@param count int
---@param style string
local function slot_table_add_child(children, name, count, style)
	local sprite_path, image_path, item_string = util.generate_item_references(name)
	if sprite_path then
		children[#children+1] = {
			type = "sprite-button",
			enabled = false,
			style = style,
			sprite = sprite_path,
			number = count,
			tooltip = {"", image_path, item_string, "\n"..format.number(count)},
		}
	end
end

---@param manifest Manifest?
---@param status int
---@return GuiElemDef[]
function util.slot_table_build_from_manifest(manifest, status)
	local children = {}
	if manifest then
		local style = "ltnm_small_slot_button_default"
		if status == STATUS_TO_P or status == STATUS_P then
			style = "ltnm_small_slot_button_red"
		elseif status == STATUS_TO_R or status == STATUS_R then
			style = "ltnm_small_slot_button_green"
		end
		for _, item in ipairs(manifest) do
			slot_table_add_child(children, item.name, item.count, style)
		end
	end
	return children
end

---@param station Station
---@return GuiElemDef[]
function util.slot_table_build_from_station(station)
	local children = {}
	for name, count in pairs(station.p_item_counts) do
		slot_table_add_child(children, name, count, "ltnm_small_slot_button_green")
	end
	for name, count in pairs(station.r_item_counts) do
		slot_table_add_child(children, name, count, "ltnm_small_slot_button_red")
	end
	return children
end

---@param station Station
---@return GuiElemDef[]
function util.slot_table_build_from_deliveries(station)
	local children = {}
	for name, count in pairs(station.deliveries) do
		if count > 0 then
			slot_table_add_child(children, name, count, "ltnm_small_slot_button_green")
		end
	end
	for name, count in pairs(station.deliveries) do
		if count < 0 then
			slot_table_add_child(children, name, count, "ltnm_small_slot_button_red")
		end
	end
	return children
end

---@param station Station
---@return GuiElemDef[]
function util.slot_table_build_from_control_signals(station)
	local children = {}
	local comb1_signals = get_comb1_signals(station)
	for _, v in pairs(comb1_signals) do
		local item_name, item_type, item_count = v.signal.name, v.signal.type, v.count
		if item_name and item_type == "virtual" then
			slot_table_add_child(children, item_name, item_count, "ltnm_small_slot_button_green")
		end
	end
	local comb2_signals = get_comb2_signals(station)
	if comb2_signals then
		for _, v in pairs(comb2_signals) do
			local item_name, item_type, item_count = v.signal.name, v.signal.type, v.count
			if item_name then
				if item_type == "virtual" then
					slot_table_add_child(children, item_name, item_count, "ltnm_small_slot_button_red")
				else
					if item_type == "item" and station.is_stack then
						item_count = item_count * game.item_prototypes[item_name].stack_size
					end
					slot_table_add_child(children, item_name, item_count, "ltnm_small_slot_button_blue")
				end
			end
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

---@param player LuaPlayer
---@param player_data PlayerData
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

---@param map_data MapData
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
