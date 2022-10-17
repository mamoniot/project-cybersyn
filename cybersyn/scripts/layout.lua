


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
			if string.find(layout, station.layout_pattern) ~= nil then
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

local area = require("__flib__.area")
function reset_station_layout(map_data, station)
	--station.entity
	local station_rail = station.entity.connected_rail
	local rail_direction_from_station
	if station.entity.connected_rail_direction == defines.rail_direction.front then
		rail_direction_from_station = defines.rail_direction.back
	else
		rail_direction_from_station = defines.rail_direction.front
	end
	local station_direction = station.entity.direction
	local surface = station.entity.surface
	local middle_x = station_rail.position.x
	local middle_y = station_rail.position.y
	local reach = LONGEST_INSERTER_REACH + 1 - DELTA
	local search_area
	local area_delta
	local direction_filter
	if station_direction == defines.direction.north then
		search_area = {left_top = {x = middle_x - reach, y = middle_y}, right_bottom = {x = middle_x + reach, y = middle_y - 6}}
		area_delta = {x = 0, y = -7}
		direction_filter = {defines.direction.east, defines.direction.west}
	elseif station_direction == defines.direction.east then
		search_area = {left_top = {y = middle_y - reach, x = middle_x}, right_bottom = {y = middle_y + reach, x = middle_x - 6}}
		area_delta = {y = 0, x = -7}
		direction_filter = {defines.direction.north, defines.direction.south}
	elseif station_direction == defines.direction.south then
		search_area = {left_top = {x = middle_x - reach, y = middle_y + 6}, right_bottom = {x = middle_x + reach, y = middle_y}}
		area_delta = {x = 0, y = 7}
		direction_filter = {defines.direction.east, defines.direction.west}
	elseif station_direction == defines.direction.west then
		search_area = {left_top = {y = middle_y - reach, x = middle_x + 6}, right_bottom = {y = middle_y + reach, x = middle_x}}
		area_delta = {y = 0, x = 7}
		direction_filter = {defines.direction.north, defines.direction.south}
	else
		assert(false, "cybersyn: invalid station direction")
	end
	local length = 2
	local pre_rail = station_rail
	local layout_pattern = "^"
	local layout_min_size = 10000
	local type_filter = {"inserter", "pump"}
	for i = 1, 100 do
		local rail, rail_direction, rail_connection_direction = pre_rail.get_connected_rail({rail_direction = rail_direction_from_station, rail_connection_direction = defines.rail_connection_direction.straight})
		if rail_connection_direction ~= defines.rail_connection_direction.straight or not rail.valid then
			break
		end
		length = length + 2
		if length%7 <= 1 then
			local supports_cargo = false
			local supports_fluid = false
			local entities = surface.find_entities_filtered({
				area = search_area,
				type = type_filter,
				direction = direction_filter,
			})
			for _, entity in pairs(entities) do
				if entity.type == "inserter" then
					--local pickup_pos = entity.prototype.inserter_pickup_position + entity.position
					--local drop_pos = entity.prototype.inserter_drop_position + entity.position
					--TODO: add further checks
					supports_cargo = true
				elseif entity.type == "pump" then
					if entity.pump_rail_target then
						supports_fluid = true
					end
				end
			end

			if supports_cargo then
				if supports_fluid then
					layout_pattern = layout_pattern..STATION_LAYOUT_BOTH
				else
					layout_pattern = layout_pattern..STATION_LAYOUT_CARGO
				end
			elseif supports_fluid then
				layout_pattern = layout_pattern..STATION_LAYOUT_FLUID
			else
				layout_pattern = layout_pattern..STATION_LAYOUT_NA
			end
			if layout_min_size <= 0 then
				layout_pattern = layout_pattern.."?"
			else
				layout_min_size = layout_min_size - 1
			end
			search_area = area.move(search_area, area_delta)
		end
	end
	layout_pattern = layout_pattern..STATION_LAYOUT_NA.."*$"
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
