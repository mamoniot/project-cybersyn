--By Mami
local area = require("__flib__.area")
local abs = math.abs
local floor = math.floor
local ceil = math.ceil
local string_find = string.find
local string_sub = string.sub

local function iterr(a, i)
	i = i + 1
	if i <= #a then
		return i, a[#a - i + 1]
	end
end

local function irpairs(a)
	return iterr, a, 0
end


---@param map_data MapData
---@param train Train
---@param train_id uint
function remove_train(map_data, train, train_id)
	map_data.trains[train_id] = nil
	local depot = train.depot
	if depot then
		remove_available_train(map_data, depot)
	end
	local layout_id = train.layout_id
	local count = map_data.layout_train_count[layout_id]
	if count <= 1 then
		map_data.layout_train_count[layout_id] = nil
		map_data.layouts[layout_id] = nil
		for station_id, station in pairs(map_data.stations) do
			station.accepted_layouts[layout_id] = nil
		end
	else
		map_data.layout_train_count[layout_id] = count - 1
	end
end

---@param map_data MapData
---@param train Train
function update_train_layout(map_data, train)
	local carriages = train.entity.carriages
	local layout = ""
	local i = 1
	local item_slot_capacity = 0
	local fluid_capacity = 0
	for _, carriage in pairs(carriages) do
		if carriage.type == "cargo-wagon" then
			layout = layout..TRAIN_LAYOUT_CARGO
			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			item_slot_capacity = item_slot_capacity + #inv
		elseif carriage.type == "fluid-wagon" then
			layout = layout..TRAIN_LAYOUT_FLUID
			fluid_capacity = fluid_capacity + carriage.prototype.fluid_capacity
			--elseif carriage.type == "artillery-wagon" then
			--layout = layout..TRAIN_LAYOUT_ARTILLERY
		else
			layout = layout..TRAIN_LAYOUT_NA
		end
		i = i + 1
	end
	local layout_id = 0
	for id, cur_layout in pairs(map_data.layouts) do
		if layout == cur_layout then
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
		for _, station in pairs(map_data.stations) do
			if station.layout_pattern and string.find(layout, station.layout_pattern) ~= nil then
				station.accepted_layouts[layout_id] = true
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
	local back_rail = train.back_rail

	if back_rail then
		local back_pos = back_rail.position
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
	local manifest = train.manifest

	local is_reversed = get_train_direction(station.entity_stop, train.entity)

	local item_i = 1
	local item = manifest[item_i]
	local item_count = item.count
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
		if carriage.type == "cargo-wagon" and item_i <= #manifest then
			local signals = {}

			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			if inv then
				local inv_filter_i = 1
				local item_slots_capacity = #inv - station.locked_slots
				while item_slots_capacity > 0 do
					local do_inc = false
					if item.type == "item" then
						local stack_size = game.item_prototypes[item.name].stack_size
						local item_slots = ceil(item_count/stack_size)
						local i = #signals + 1
						local slots_to_filter
						if item_slots > item_slots_capacity then
							if comb then
								signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = item_slots_capacity*stack_size}
							end
							item_slots_capacity = 0
							item_count = item_count - item_slots_capacity*stack_size
							slots_to_filter = item_slots_capacity
						else
							if comb then
								signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = item_count}
							end
							item_slots_capacity = item_slots_capacity - item_slots
							do_inc = true
							slots_to_filter = item_slots
						end
						for j = 1, slots_to_filter do
							inv.set_filter(inv_filter_i, item.name)
							inv_filter_i = inv_filter_i + 1
						end
						train.has_filtered_wagon = true
					else
						do_inc = true
					end
					if do_inc then
						item_i = item_i + 1
						if item_i <= #manifest then
							item = manifest[item_i]
							item_count = item.count
						else
							break
						end
					end
				end

				if comb then
					set_combinator_output(map_data, comb, signals)
				end
			end
		elseif carriage.type == "fluid-wagon" and fluid_i <= #manifest then
			local fluid_capacity = carriage.prototype.fluid_capacity
			local signals = {}

			while fluid_capacity > 0 do
				local do_inc = false
				if fluid.type == "fluid" then
					if fluid_count > fluid_capacity then
						if comb then
							signals[1] = {index = 1, signal = {type = fluid.type, name = fluid.name}, count = fluid_capacity}
						end
						fluid_capacity = 0
						fluid_count = fluid_count - fluid_capacity
					else
						if comb then
							signals[1] = {index = 1, signal = {type = fluid.type, name = fluid.name}, count = item_count}
						end
						fluid_capacity = fluid_capacity - fluid_count
						fluid_i = fluid_i + 1
						if fluid_i <= #manifest then
							fluid = manifest[fluid_i]
							fluid_count = fluid.count
						end
					end
					break
				else
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
						signals[i] = {index = i, signal = {type = stack.type, name = stack.name}, count = -stack.count}
					end
				end
				set_combinator_output(map_data, comb, signals)
			end
		elseif comb and carriage.type == "fluid-wagon" then
			local signals = {}

			local inv = carriage.get_fluid_contents()
			for fluid_name, count in pairs(inv) do
				local i = #signals + 1
				signals[i] = {index = i, signal = {type = "fluid", name = fluid_name}, count = -floor(count)}
			end
			set_combinator_output(map_data, comb, signals)
		end
	end
end

---@param map_data MapData
---@param station Station
function unset_wagon_combs(map_data, station)
	if not station.wagon_combs then return end

	for i, comb in pairs(station.wagon_combs) do
		if comb.valid then
			set_combinator_output(map_data, comb, nil)
		else
			station.wagon_combs[i] = nil
		end
	end
	if next(station.wagon_combs) == nil then
		station.wagon_combs = nil
	end
end


---@param map_data MapData
---@param station Station
---@param forbidden_entity LuaEntity?
local function reset_station_layout(map_data, station, forbidden_entity)
	--NOTE: station must be in auto mode
	local station_rail = station.entity_stop.connected_rail
	if station_rail == nil then
		--cannot accept deliveries
		station.layout_pattern = "X"
		station.accepted_layouts = {}
		return
	end
	local rail_direction_from_station
	if station.entity_stop.connected_rail_direction == defines.rail_direction.front then
		rail_direction_from_station = defines.rail_direction.back
	else
		rail_direction_from_station = defines.rail_direction.front
	end
	local station_direction = station.entity_stop.direction
	local surface = station.entity_stop.surface
	local middle_x = station_rail.position.x
	local middle_y = station_rail.position.y
	local reach = LONGEST_INSERTER_REACH + 1
	local search_area
	local area_delta
	local direction_filter
	local is_ver
	if station_direction == defines.direction.north then
		search_area = {left_top = {x = middle_x - reach, y = middle_y}, right_bottom = {x = middle_x + reach, y = middle_y + 6}}
		area_delta = {x = 0, y = 7}
		direction_filter = {defines.direction.east, defines.direction.west}
		is_ver = true
	elseif station_direction == defines.direction.east then
		search_area = {left_top = {y = middle_y - reach, x = middle_x - 6}, right_bottom = {y = middle_y + reach, x = middle_x}}
		area_delta = {x = -7, y = 0}
		direction_filter = {defines.direction.north, defines.direction.south}
		is_ver = false
	elseif station_direction == defines.direction.south then
		search_area = {left_top = {x = middle_x - reach, y = middle_y - 6}, right_bottom = {x = middle_x + reach, y = middle_y}}
		area_delta = {x = 0, y = -7}
		direction_filter = {defines.direction.east, defines.direction.west}
		is_ver = true
	elseif station_direction == defines.direction.west then
		search_area = {left_top = {y = middle_y - reach, x = middle_x}, right_bottom = {y = middle_y + reach, x = middle_x + 6}}
		area_delta = {x = 7, y = 0}
		direction_filter = {defines.direction.north, defines.direction.south}
		is_ver = false
	else
		assert(false, "cybersyn: invalid station direction")
	end
	local length = 2
	local pre_rail = station_rail
	local layout_pattern = "^"
	local type_filter = {"inserter", "pump", "arithmetic-combinator"}
	local wagon_number = 0
	local pattern_length = 1
	for i = 1, 100 do
		local rail, rail_direction, rail_connection_direction = pre_rail.get_connected_rail({rail_direction = rail_direction_from_station, rail_connection_direction = defines.rail_connection_direction.straight})
		if not rail or rail_connection_direction ~= defines.rail_connection_direction.straight or not rail.valid then
			break
		end
		pre_rail = rail
		length = length + 2
		if length%7 <= 1 then
			wagon_number = wagon_number + 1
			local supports_cargo = false
			local supports_fluid = false
			local entities = surface.find_entities_filtered({
				area = search_area,
				type = type_filter,
				direction = direction_filter,
			})
			for _, entity in pairs(entities) do
				if entity.valid and entity ~= forbidden_entity then
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
					elseif entity.type == "pump" then
						if not supports_fluid and entity.pump_rail_target then
							supports_fluid = true
						end
					elseif entity.name == COMBINATOR_NAME then
						local control = entity.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
						if control.operation == OPERATION_WAGON_MANIFEST then
							local pos = entity.position
							local is_there
							if is_ver then
								is_there = middle_x - 2.1 <= pos.x and pos.x <= middle_x + 2.1
							else
								is_there = middle_y - 2.1 <= pos.y and pos.y <= middle_y + 2.1
							end
							if is_there then
								if not station.wagon_combs then
									station.wagon_combs = {}
								end
								station.wagon_combs[wagon_number] = entity
							end
						end
					end
				end
			end

			if supports_cargo then
				if supports_fluid then
					layout_pattern = layout_pattern..STATION_LAYOUT_ALL
				else
					layout_pattern = layout_pattern..STATION_LAYOUT_NOT_FLUID
				end
				pattern_length = #layout_pattern
			elseif supports_fluid then
				layout_pattern = layout_pattern..STATION_LAYOUT_NOT_CARGO
				pattern_length = #layout_pattern
			else
				layout_pattern = layout_pattern..STATION_LAYOUT_NA
			end
			search_area = area.move(search_area, area_delta)
		end
	end
	layout_pattern = string_sub(layout_pattern, 1, pattern_length)..STATION_LAYOUT_NA.."*$"
	station.layout_pattern = layout_pattern
	local accepted_layouts = station.accepted_layouts
	for id, layout in pairs(map_data.layouts) do
		if string_find(layout, layout_pattern) ~= nil then
			accepted_layouts[id] = true
		else
			accepted_layouts[id] = nil
		end
	end
end

---@param map_data MapData
---@param station Station
---@param is_all boolean
function set_station_train_class(map_data, station, is_all)
	if station.is_all ~= is_all then
		station.is_all = is_all
		if not is_all then
			reset_station_layout(map_data, station, nil)
		end
	end
end

---@param map_data MapData
---@param station Station
---@param forbidden_entity LuaEntity?
function update_station_if_auto(map_data, station, forbidden_entity)
	if not station.is_all then
		reset_station_layout(map_data, station, forbidden_entity)
	end
end

---@param map_data MapData
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
function force_update_station_from_rail(map_data, rail, forbidden_entity)
	--NOTE: should we search further or better? it would be more expensive
	local entity = rail.get_rail_segment_entity(defines.rail_direction.back, false)
	if entity and entity.valid and entity.name == "train-stop" then
		local station = map_data.stations[entity.unit_number]
		if station then
			reset_station_layout(map_data, station, forbidden_entity)
		end
	else
		entity = rail.get_rail_segment_entity(defines.rail_direction.front, false)
		if entity and entity.valid and entity.name == "train-stop" then
			local station = map_data.stations[entity.unit_number]
			if station then
				reset_station_layout(map_data, station, forbidden_entity)
			end
		end
	end
end
---@param map_data MapData
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
function update_station_from_rail(map_data, rail, forbidden_entity)
	--NOTE: should we search further or better? it would be more expensive
	local entity = rail.get_rail_segment_entity(defines.rail_direction.back, false)
	if entity and entity.valid and entity.name == "train-stop" then
		local station = map_data.stations[entity.unit_number]
		if station then
			update_station_if_auto(map_data, station, forbidden_entity)
		end
	else
		entity = rail.get_rail_segment_entity(defines.rail_direction.front, false)
		if entity and entity.valid and entity.name == "train-stop" then
			local station = map_data.stations[entity.unit_number]
			if station then
				update_station_if_auto(map_data, station, forbidden_entity)
			end
		end
	end
end
---@param map_data MapData
---@param pump LuaEntity
---@param forbidden_entity LuaEntity?
function update_station_from_pump(map_data, pump, forbidden_entity)
	if pump.pump_rail_target then
		update_station_from_rail(map_data, pump.pump_rail_target, forbidden_entity)
	end
end
---@param map_data MapData
---@param inserter LuaEntity
---@param forbidden_entity LuaEntity?
function update_station_from_inserter(map_data, inserter, forbidden_entity)
	local surface = inserter.surface

	--NOTE: we don't use find_entity solely for miniloader compat
	local rails = surface.find_entities_filtered({
		type = "straight-rail",
		position = inserter.pickup_position,
		radius = 1,
	})
	if rails[1] then
		update_station_from_rail(map_data, rails[1], forbidden_entity)
	end
	rails = surface.find_entities_filtered({
		type = "straight-rail",
		position = inserter.drop_position,
		radius = 1,
	})
	if rails[1] then
		update_station_from_rail(map_data, rails[1], forbidden_entity)
	end
end
