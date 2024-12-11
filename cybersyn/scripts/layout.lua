--By Mami
local area = require("__flib__.bounding-box")
local abs = math.abs
local floor = math.floor
local ceil = math.ceil
local min = math.min
local max = math.max
local bit_extract = bit32.extract
local defines_front = defines.rail_direction.front
local defines_back = defines.rail_direction.back
local defines_straight = defines.rail_connection_direction.straight
local search_type = { "straight-rail", "curved-rail" }

---@param layout_pattern (0|1|2|3)[]
---@param layout (0|1|2)[]
function is_refuel_layout_accepted(layout_pattern, layout)
	local valid = true
	for i, v in ipairs(layout) do
		local p = layout_pattern[i] or 0
		if (v == 1 and (p == 1 or p == 3)) or (v == 2 and (p == 2 or p == 3)) then
			valid = false
			break
		end
	end
	if valid or not layout[0] then return valid end
	for i, v in irpairs(layout) do
		local p = layout_pattern[i] or 0
		if (v == 1 and (p == 1 or p == 3)) or (v == 2 and (p == 2 or p == 3)) then
			valid = false
			break
		end
	end
	return valid
end
---@param layout_pattern (0|1|2|3)[]
---@param layout (0|1|2)[]
function is_layout_accepted(layout_pattern, layout)
	local valid = true
	for i, v in ipairs(layout) do
		local p = layout_pattern[i] or 0
		if (v == 1 and not (p == 1 or p == 3)) or (v == 2 and not (p == 2 or p == 3)) then
			valid = false
			break
		end
	end
	if valid or not layout[0] then return valid end
	for i, v in irpairs(layout) do
		local p = layout_pattern[i] or 0
		if (v == 1 and not (p == 1 or p == 3)) or (v == 2 and not (p == 2 or p == 3)) then
			valid = false
			break
		end
	end
	return valid
end

---@param map_data MapData
---@param train_id uint
---@param train Train
function remove_train(map_data, train_id, train)
	if train.manifest then
		on_failed_delivery(map_data, train_id, train)
	end
	remove_available_train(map_data, train_id, train)

	local layout_id = train.layout_id
	local count = storage.layout_train_count[layout_id]
	if count <= 1 then
		storage.layout_train_count[layout_id] = nil
		storage.layouts[layout_id] = nil
		for _, stop in pairs(storage.stations) do
			stop.accepted_layouts[layout_id] = nil
		end
		for _, stop in pairs(storage.refuelers) do
			stop.accepted_layouts[layout_id] = nil
		end
	else
		storage.layout_train_count[layout_id] = count - 1
	end

	map_data.trains[train_id] = nil
	interface_raise_train_removed(train_id, train)
end

---@param map_data MapData
---@param train Train
function set_train_layout(map_data, train)
	local carriages = train.entity.carriages
	local layout = {}
	local i = 1
	local item_slot_capacity = 0
	local fluid_capacity = 0
	for _, carriage in pairs(carriages) do
		if carriage.type == "cargo-wagon" then
			layout[#layout + 1] = 1
			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			item_slot_capacity = item_slot_capacity + #inv
		elseif carriage.type == "fluid-wagon" then
			layout[#layout + 1] = 2
			fluid_capacity = fluid_capacity + carriage.prototype.fluid_capacity
		else
			layout[#layout + 1] = 0
		end
		i = i + 1
	end
	local back_movers = train.entity.locomotives["back_movers"]
	if #back_movers > 0 then
		--mark the layout as reversible
		layout[0] = true
	end

	local layout_id = 0
	for id, cur_layout in pairs(map_data.layouts) do
		if table_compare(layout, cur_layout) then
			layout = cur_layout
			layout_id = id
			break
		end
	end
	if layout_id == 0 then
		--define new layout
		layout_id = map_data.layout_top_id
		map_data.layout_top_id = map_data.layout_top_id + 1

		map_data.layouts[layout_id] = layout
		map_data.layout_train_count[layout_id] = 1
		for _, stop in pairs(map_data.stations) do
			if stop.layout_pattern then
				stop.accepted_layouts[layout_id] = is_layout_accepted(stop.layout_pattern, layout) or nil
			end
		end
		for _, stop in pairs(map_data.refuelers) do
			if stop.layout_pattern then
				stop.accepted_layouts[layout_id] = is_refuel_layout_accepted(stop.layout_pattern, layout) or nil
			end
		end
	else
		map_data.layout_train_count[layout_id] = map_data.layout_train_count[layout_id] + 1
	end
	train.layout_id = layout_id
	train.item_slot_capacity = item_slot_capacity
	train.fluid_capacity = fluid_capacity
end

---@param stop LuaEntity
---@param train LuaTrain
local function get_train_direction(stop, train)
	local back_end = train.get_rail_end(defines.rail_direction.back)

	if back_end and back_end.rail then
		local back_pos = back_end.rail.position
		local stop_pos = stop.position
		if abs(back_pos.x - stop_pos.x) < 3 and abs(back_pos.y - stop_pos.y) < 3 then
			return true
		end
	end

	return false
end

---@param map_data MapData
---@param station Station
---@param train Train
function set_p_wagon_combs(map_data, station, train)
	if not station.wagon_combs or not next(station.wagon_combs) then return end
	local carriages = train.entity.carriages
	local manifest = train.manifest --[[@as Manifest]]
	if not manifest[1] then return end

	local is_reversed = get_train_direction(station.entity_stop, train.entity)

	local locked_slots = station.locked_slots
	local percent_slots_to_use_per_wagon = 1.0
	if train.item_slot_capacity > 0 then
		local total_item_slots
		if locked_slots > 0 then
			local total_cargo_wagons = #train.entity.cargo_wagons
			total_item_slots = max(train.item_slot_capacity - total_cargo_wagons * locked_slots, 1)
		else
			total_item_slots = train.item_slot_capacity
		end

		local to_be_used_item_slots = 0
		for i, item in ipairs(train.manifest) do
			if not item.type or item.type == "item" then
				to_be_used_item_slots = to_be_used_item_slots + ceil(item.count / get_stack_size(map_data, item.name))
			end
		end
		percent_slots_to_use_per_wagon = min(to_be_used_item_slots / total_item_slots, 1.0)
	end

	local item_i = 1
	local item = manifest[item_i]
	local item_count = item.count
	local item_qual = item.quality or "normal"
	local fluid_i = 1
	local fluid = manifest[fluid_i]
	local fluid_count = fluid.count

	local ivpairs = is_reversed and irpairs or ipairs
	for carriage_i, carriage in ivpairs(carriages) do
		--NOTE: we are not checking valid
		---@type LuaEntity?
		local comb = station.wagon_combs[carriage_i]
		if comb and not comb.valid then
			comb = nil
			station.wagon_combs[carriage_i] = nil
			if next(station.wagon_combs) == nil then
				station.wagon_combs = nil
				break
			end
		end
		if carriage.type == "cargo-wagon" then
			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			if inv then
				---@type LogisticFilter[]
				local signals = {}

				local inv_filter_i = 1
				local item_slots_capacity = max(ceil((#inv - locked_slots) * percent_slots_to_use_per_wagon), 1)
				while item_slots_capacity > 0 and item_i <= #manifest do
					local do_inc
					if not item.type or item.type == "item" then
						local stack_size = get_stack_size(map_data, item.name)
						local i = #signals + 1
						local count_to_fill = min(item_slots_capacity * stack_size, item_count)
						local slots_to_fill = ceil(count_to_fill / stack_size)

						signals[i] = {
							value = { type = item.type, name = item.name, quality = item_qual, comparator = "=" },
							min = -1 * count_to_fill,
						}
						item_count = item_count - count_to_fill
						item_slots_capacity = item_slots_capacity - slots_to_fill
						if comb then
							for j = 1, slots_to_fill do
								inv.set_filter(inv_filter_i, { name = item.name, quality = item_qual, comparator = "=" })
								inv_filter_i = inv_filter_i + 1
							end
							train.has_filtered_wagon = true
						end
						do_inc = item_count == 0
					else
						do_inc = true
					end
					if do_inc then
						item_i = item_i + 1
						if item_i <= #manifest then
							item = manifest[item_i]
							item_count = item.count
							item_qual = item.quality or "normal"
						else
							break
						end
					end
				end

				if comb then
					if bit_extract(get_comb_params(comb).second_constant, SETTING_ENABLE_SLOT_BARRING) > 0 then
						inv.set_bar(inv_filter_i --[[@as uint]])
						train.has_filtered_wagon = true
					end
					set_combinator_output(map_data, comb, signals)
				end
			end
		elseif carriage.type == "fluid-wagon" then
			local fluid_capacity = carriage.prototype.fluid_capacity
			---@type LogisticFilter[]
			local signals = {}

			while fluid_capacity > 0 and fluid_i <= #manifest do
				local do_inc
				if fluid.type == "fluid" then
					local count_to_fill = min(fluid_count, fluid_capacity)

					signals[1] = { index = 1, signal = { type = fluid.type, name = fluid.name }, count = -1 * count_to_fill }
					fluid_count = fluid_count - count_to_fill
					fluid_capacity = 0
					do_inc = fluid_count == 0
				else
					do_inc = true
				end
				if do_inc then
					fluid_i = fluid_i + 1
					if fluid_i <= #manifest then
						fluid = manifest[fluid_i]
						fluid_count = fluid.count
					end
				end
			end

			if comb then
				set_combinator_output(map_data, comb, signals)
			end
		end
	end
end

---@param map_data MapData
---@param station Station
---@param train Train
function set_r_wagon_combs(map_data, station, train)
	if not station.wagon_combs then return end
	local carriages = train.entity.carriages

	local is_reversed = get_train_direction(station.entity_stop, train.entity)

	local ivpairs = is_reversed and irpairs or ipairs
	for carriage_i, carriage in ivpairs(carriages) do
		---@type LuaEntity?
		local comb = station.wagon_combs[carriage_i]
		if comb and not comb.valid then
			comb = nil
			station.wagon_combs[carriage_i] = nil
			if next(station.wagon_combs) == nil then
				station.wagon_combs = nil
				break
			end
		end
		if comb and carriage.type == "cargo-wagon" then
			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			if inv then
				local signals = {}
				for stack_i = 1, #inv do
					local stack = inv[stack_i]
					if stack.valid_for_read then
						local i = #signals + 1
						signals[i] = {
							value = { type = "item", name = stack.name, quality = stack.quality or "normal", comparator = "=" },
							min = stack.count,
						}
					end
				end
				set_combinator_output(map_data, comb, signals)
			end
		elseif comb and carriage.type == "fluid-wagon" then
			local signals = {}

			local inv = carriage.get_fluid_contents()
			for fluid_name, count in pairs(inv) do
				local i = #signals + 1
				-- FIXME ? pump conditions can have quality (but why? fluids can only be produced at normal quality and pump filters ignore quality)
				signals[i] = {
					value = { type = "fluid", name = fluid_name, quality = "normal", comparator = "=" },
					min = floor(count),
				}
			end
			set_combinator_output(map_data, comb, signals)
		end
	end
end

---@param map_data MapData
---@param refueler Refueler
---@param train Train
function set_refueler_combs(map_data, refueler, train)
	if not refueler.wagon_combs then return end
	local carriages = train.entity.carriages

	local signals = {}

	local is_reversed = get_train_direction(refueler.entity_stop, train.entity)
	local ivpairs = is_reversed and irpairs or ipairs
	for carriage_i, carriage in ivpairs(carriages) do
		---@type LuaEntity?
		local comb = refueler.wagon_combs[carriage_i]
		if comb and not comb.valid then
			comb = nil
			refueler.wagon_combs[carriage_i] = nil
			if next(refueler.wagon_combs) == nil then
				refueler.wagon_combs = nil
				break
			end
		end
		local inv = carriage.get_fuel_inventory()
		if inv then
			local wagon_signals
			if comb then
				wagon_signals = {}
				local array = carriage.prototype.items_to_place_this
				if array then
					local a = array[1]
					local name
					if type(a) == "string" then
						name = a
					else
						name = a.name
					end
					if prototypes.item[name] then
						wagon_signals[1] = { value = { type = "item", name = a.name, quality = "normal", comparator = "=" }, min = 1 }
					end
				end
			end
			for stack_i = 1, #inv do
				local stack = inv[stack_i]
				if stack.valid_for_read then
					if comb then
						local i = #wagon_signals + 1
						wagon_signals[i] = {
							value = {
								type = "item",
								name = stack.name,
								quality = stack.quality or "normal",
								comparator = "=",
							},
							min = stack.count,
						}
					end
					local j = #signals + 1
					signals[j] = {
						value = { type = "item", name = stack.name, quality = stack.quality or "normal", comparator = "=" },
						min = stack.count,
					}
				end
			end
			if comb then
				set_combinator_output(map_data, comb, wagon_signals)
			end
		end
	end

	set_combinator_output(map_data, refueler.entity_comb, signals)
end

---@param map_data MapData
---@param stop Station|Refueler
function unset_wagon_combs(map_data, stop)
	if not stop.wagon_combs then return end

	for i, comb in pairs(stop.wagon_combs) do
		if comb.valid then
			set_combinator_output(map_data, comb, nil)
		else
			stop.wagon_combs[i] = nil
		end
	end
	if next(stop.wagon_combs) == nil then
		stop.wagon_combs = nil
	end
end

local type_filter = { "inserter", "pump", "arithmetic-combinator", "loader-1x1", "loader" }
---@param map_data MapData
---@param stop Station|Refueler
---@param is_station_or_refueler boolean
---@param forbidden_entity LuaEntity?
function reset_stop_layout(map_data, stop, is_station_or_refueler, forbidden_entity)
	--NOTE: station must be in auto mode
	local stop_rail = stop.entity_stop.connected_rail
	if stop_rail == nil then
		--cannot accept deliveries
		stop.layout_pattern = nil
		stop.accepted_layouts = {}
		return
	end
	local rail_direction_from_stop
	if stop.entity_stop.connected_rail_direction == defines_front then
		rail_direction_from_stop = defines_back
	else
		rail_direction_from_stop = defines_front
	end
	local stop_direction = stop.entity_stop.direction
	local surface = stop.entity_stop.surface
	local middle_x = stop_rail.position.x
	local middle_y = stop_rail.position.y
	local reach = LONGEST_INSERTER_REACH + 1
	local search_area
	local area_delta
	local is_ver
	if stop_direction == defines.direction.north then
		search_area = { { middle_x - reach, middle_y }, { middle_x + reach, middle_y + 6 } }
		area_delta = { 0, 7 }
		is_ver = true
	elseif stop_direction == defines.direction.east then
		search_area = { { middle_x - 6, middle_y - reach }, { middle_x, middle_y + reach } }
		area_delta = { -7, 0 }
		is_ver = false
	elseif stop_direction == defines.direction.south then
		search_area = { { middle_x - reach, middle_y - 6 }, { middle_x + reach, middle_y } }
		area_delta = { 0, -7 }
		is_ver = true
	elseif stop_direction == defines.direction.west then
		search_area = { { middle_x, middle_y - reach }, { middle_x + 6, middle_y + reach } }
		area_delta = { 7, 0 }
		is_ver = false
	else
		assert(false, "cybersyn: invalid stop direction")
	end
	local length = 1
	---@type LuaEntity?
	local pre_rail = stop_rail
	local layout_pattern = { 0 }
	local wagon_number = 0
	for i = 1, 112 do
		if pre_rail then
			local rail, rail_direction, rail_connection_direction = pre_rail.get_connected_rail({
				rail_direction = rail_direction_from_stop,
				rail_connection_direction = defines_straight,
			})
			if not rail or rail_connection_direction ~= defines_straight then
				-- There is a curved rail or break in the tracks at this point
				-- We are assuming it's a curved rail, maybe that's a bad assumption
				-- We stop searching to expand the allow list after we see a curved rail
				-- We are allowing up to 3 tiles of extra allow list usage on a curved rail
				length = length + 3
				pre_rail = nil
			else
				pre_rail = rail
				length = length + 2
			end
		end
		if length >= 6 or not pre_rail then
			if not pre_rail then
				if length <= 0 then
					-- No point searching nothing
					-- Once we hit a curve and process the 3 extra tiles we break here
					-- This is the only breakpoint in this for loop
					break
				end
				-- Minimize the search_area to include only the straight section of track and the 3 tiles of the curved rail
				local missing_rail_length = 6 - length
				if missing_rail_length > 0 then
					if stop_direction == defines.direction.north then
						search_area[2][2] = search_area[2][2] - missing_rail_length
					elseif stop_direction == defines.direction.east then
						search_area[1][1] = search_area[1][1] + missing_rail_length
					elseif stop_direction == defines.direction.south then
						search_area[1][2] = search_area[1][2] + missing_rail_length
					else
						search_area[2][1] = search_area[2][1] - missing_rail_length
					end
				end
			end
			length = length - 7
			wagon_number = wagon_number + 1
			local supports_cargo = false
			local supports_fluid = false
			local entities = surface.find_entities_filtered({
				area = search_area,
				type = type_filter,
			})
			for _, entity in pairs(entities) do
				if entity ~= forbidden_entity then
					if entity.type == "inserter" then
						if not supports_cargo then
							local pos = entity.pickup_position
							local is_there
							if is_ver then
								is_there = middle_x - 1 <= pos.x and pos.x <= middle_x + 1
							else
								is_there = middle_y - 1 <= pos.y and pos.y <= middle_y + 1
							end
							if is_there then
								supports_cargo = true
							else
								pos = entity.drop_position
								if is_ver then
									is_there = middle_x - 1 <= pos.x and pos.x <= middle_x + 1
								else
									is_there = middle_y - 1 <= pos.y and pos.y <= middle_y + 1
								end
								if is_there then
									supports_cargo = true
								end
							end
						end
					elseif entity.type == "loader-1x1" then
						if not supports_cargo then
							local pos = entity.position
							local direction = entity.direction
							local is_there
							if is_ver then
								is_there = middle_x - 1.5 <= pos.x and pos.x <= middle_x + 1.5
							else
								is_there = middle_y - 1.5 <= pos.y and pos.y <= middle_y + 1.5
							end
							if is_there then
								if is_ver then
									if direction == defines.direction.east or direction == defines.direction.west then
										supports_cargo = true
									end
								elseif direction == defines.direction.north or direction == defines.direction.south then
									supports_cargo = true
								end
							end
						end
					elseif entity.type == "loader" then
						-- TODO: entities of type `loader` are 1x2 loaders. This code
						-- existed in 1.1, but 1x2 loaders are not fully supported elsewhere
						-- in the code. 1x2 loader support is a TODO.
						if not supports_cargo then
							local direction = entity.direction
							if is_ver then
								if direction == defines.direction.east or direction == defines.direction.west then
									supports_cargo = true
								end
							elseif direction == defines.direction.north or direction == defines.direction.south then
								supports_cargo = true
							end
						end
					elseif entity.type == "pump" then
						if not supports_fluid and entity.pump_rail_target then
							local direction = entity.direction
							if is_ver then
								if direction == defines.direction.east or direction == defines.direction.west then
									supports_fluid = true
								end
							elseif direction == defines.direction.north or direction == defines.direction.south then
								supports_fluid = true
							end
						end
					elseif entity.name == COMBINATOR_NAME then
						local param = map_data.to_comb_params[entity.unit_number]
						if param.operation == MODE_WAGON then
							local pos = entity.position
							local is_there
							if is_ver then
								is_there = middle_x - 2.1 <= pos.x and pos.x <= middle_x + 2.1
							else
								is_there = middle_y - 2.1 <= pos.y and pos.y <= middle_y + 2.1
							end
							if is_there then
								if not stop.wagon_combs then
									stop.wagon_combs = {}
								end
								stop.wagon_combs[wagon_number] = entity
							end
						end
					end
				end
			end

			if supports_cargo then
				if supports_fluid then
					layout_pattern[wagon_number] = 3
				else
					layout_pattern[wagon_number] = 1
				end
			elseif supports_fluid then
				layout_pattern[wagon_number] = 2
			else
				--layout_pattern[wagon_number] = nil
			end
			search_area = area.move(search_area, area_delta)
		end
	end
	stop.layout_pattern = layout_pattern
	if is_station_or_refueler then
		for id, layout in pairs(map_data.layouts) do
			stop.accepted_layouts[id] = is_layout_accepted(layout_pattern, layout) or nil
		end
	else
		for id, layout in pairs(map_data.layouts) do
			stop.accepted_layouts[id] = is_refuel_layout_accepted(layout_pattern, layout) or nil
		end
	end
end

---@param map_data MapData
---@param stop Station|Refueler
---@param is_station_or_refueler boolean
---@param forbidden_entity LuaEntity?
function update_stop_if_auto(map_data, stop, is_station_or_refueler, forbidden_entity)
	if not stop.allows_all_trains then
		reset_stop_layout(map_data, stop, is_station_or_refueler, forbidden_entity)
	end
end

---@param map_data MapData
---@param entity LuaEntity
---@param forbidden_entity LuaEntity?
---@param force boolean?
local function resolve_update_stop_from_rail(map_data, entity, forbidden_entity, force)
	local id = entity.unit_number --[[@as uint]]
	local is_station = true
	---@type Station|Refueler
	local stop = map_data.stations[id]
	if not stop then
		stop = map_data.refuelers[id]
		is_station = false
	end
	if stop and stop.entity_stop.valid then
		if force then
			reset_stop_layout(map_data, stop, is_station, forbidden_entity)
		elseif not stop.allows_all_trains then
			reset_stop_layout(map_data, stop, is_station, forbidden_entity)
		end
	end
end
---@param map_data MapData
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
---@param force boolean?
function update_stop_from_rail(map_data, rail, forbidden_entity, force)
	--NOTE: is this a correct way to figure out the direction?
	---@type LuaEntity?
	local stop = rail.get_rail_segment_stop(defines_front)
	if not stop then
		stop = rail.get_rail_segment_stop(defines_back)
	end
	if stop then
		resolve_update_stop_from_rail(map_data, stop, forbidden_entity, force)
	end
end

---@param map_data MapData
---@param pump LuaEntity
---@param forbidden_entity LuaEntity?
function update_stop_from_pump(map_data, pump, forbidden_entity)
	if pump.pump_rail_target then
		update_stop_from_rail(map_data, pump.pump_rail_target, forbidden_entity)
	end
end
---@param map_data MapData
---@param inserter LuaEntity
---@param forbidden_entity LuaEntity?
function update_stop_from_inserter(map_data, inserter, forbidden_entity)
	local surface = inserter.surface
	local pos0 = inserter.position
	local pos1 = inserter.pickup_position
	local pos2 = inserter.drop_position
	local has_found = false

	local rails = surface.find_entities_filtered({
		type = search_type,
		position = pos1,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
		has_found = true
	end
	rails = surface.find_entities_filtered({
		type = search_type,
		position = pos2,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
		has_found = true
	end
	if has_found then
		return
	end
	-- We need to check secondary positions because of weird modded inserters.
	-- Mostly because of miniloaders not aligning with the hitbox of a rail by default.
	pos1.x = pos1.x + 0.2 * (pos1.x - pos0.x)
	pos1.y = pos1.y + 0.2 * (pos1.y - pos0.y)
	pos2.x = pos2.x + 0.2 * (pos2.x - pos0.x)
	pos2.y = pos2.y + 0.2 * (pos2.y - pos0.y)
	rails = surface.find_entities_filtered({
		type = search_type,
		position = pos1,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
	end
	rails = surface.find_entities_filtered({
		type = search_type,
		position = pos2,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
	end
end
---@param map_data MapData
---@param loader LuaEntity
---@param forbidden_entity LuaEntity?
function update_stop_from_loader(map_data, loader, forbidden_entity)
	local surface = loader.surface
	local direction = loader.direction
	local loader_type = loader.loader_type
	local position = loader.position

	-- loader mods can often change the input/output of a loader after it's built
	-- in order to have it "stick" to nearby loadable objects. therefore
	-- we cannot rely on the `loader_type` here. we need to trigger a stop update
	-- any time the loader is within 1 block of a track.
	local area = area.ensure_explicit(area.from_position(position))
	if direction == defines.direction.east or direction == defines.direction.west then
		area.left_top.x = area.left_top.x - 1
		area.right_bottom.x = area.right_bottom.x + 1
	else
		area.left_top.y = area.left_top.y - 1
		area.right_bottom.y = area.right_bottom.y + 1
	end

	local rails = surface.find_entities_filtered({
		type = search_type,
		area = area,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
	end
end
