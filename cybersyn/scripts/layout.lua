--By Mami
local area = require("__flib__.area")

---@param map_data MapData
---@param train Train
---@param train_id uint
function remove_train(map_data, train, train_id)
	map_data.trains[train_id] = nil
	map_data.trains_available[train_id] = nil
	local layout_id = train.layout_id
	local count = map_data.layout_train_count[layout_id]
	if count <= 1 then
		map_data.layout_train_count[layout_id] = nil
		map_data.layouts[layout_id] = nil
		for station_id, station in pairs(map_data.stations) do
			station.accepted_layouts[layout_id] = nil
		end
		map_data.train_classes[TRAIN_CLASS_ALL][layout_id] = nil
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
		map_data.train_classes[TRAIN_CLASS_ALL][layout_id] = true
	else
		map_data.layout_train_count[layout_id] = map_data.layout_train_count[layout_id] + 1
	end
	train.layout_id = layout_id
	train.item_slot_capacity = item_slot_capacity
	train.fluid_capacity = fluid_capacity
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
	--local center_line
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
						local control = entity.get_or_create_control_behavior().parameters
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
					--TODO: needs to allow misc wagons as well
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
	layout_pattern = string.sub(layout_pattern, 1, pattern_length)..STATION_LAYOUT_NA.."*$"
	station.layout_pattern = layout_pattern
	local accepted_layouts = station.accepted_layouts
	for id, layout in pairs(map_data.layouts) do
		if string.find(layout, layout_pattern) ~= nil then
			accepted_layouts[id] = true
		else
			accepted_layouts[id] = nil
		end
	end
end

---@param map_data MapData
---@param station Station
---@param train_class SignalID
function set_station_train_class(map_data, station, train_class)
	if train_class.name == TRAIN_CLASS_AUTO.name then
		if station.train_class.name ~= TRAIN_CLASS_AUTO.name then
			station.train_class = TRAIN_CLASS_AUTO
			station.accepted_layouts = {}
		end
		reset_station_layout(map_data, station, nil)
	else
		station.train_class = train_class
		station.accepted_layouts = map_data.train_classes[train_class.name]
		assert(station.accepted_layouts ~= nil)
		station.layout_pattern = nil
	end
end

---@param map_data MapData
---@param station Station
---@param forbidden_entity LuaEntity?
function update_station_if_auto(map_data, station, forbidden_entity)
	if station.train_class.name == TRAIN_CLASS_AUTO.name then
		reset_station_layout(map_data, station, forbidden_entity)
	end
end

---@param map_data MapData
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
function update_station_from_rail(map_data, rail, forbidden_entity)
	--TODO: search further or better?
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
	--TODO: check if correct
	local surface = inserter.surface

	local rail = surface.find_entity("straight-rail", inserter.pickup_position)
	if rail then
		update_station_from_rail(map_data, rail, forbidden_entity)
	end
	rail = surface.find_entity("straight-rail", inserter.drop_position)
	if rail then
		update_station_from_rail(map_data, rail, forbidden_entity)
	end
end
