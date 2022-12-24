--By Mami
local area = require("__flib__.area")
local abs = math.abs
local floor = math.floor
local ceil = math.ceil


local function table_compare(t0, t1)
	if #t0 ~= #t1 then
		return false
	end
	for i = 0, #t0 do
		if t0[i] ~= t1[i] then
			return false
		end
	end
	return true
end

---@param a any[]
---@param i uint
local function iterr(a, i)
	i = i + 1
	if i <= #a then
		local r = a[#a - i + 1]
		return i, r
	else
		return nil, nil
	end
end

---@param a any[]
local function irpairs(a)
	return iterr, a, 0
end

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
	local parked_at_depot_id = train.parked_at_depot_id
	if parked_at_depot_id then
		local depot = map_data.depots[parked_at_depot_id]
		depot.available_train_id = nil
	end
	remove_available_train(map_data, train_id, train)

	local layout_id = train.layout_id
	local count = global.layout_train_count[layout_id]
	if count <= 1 then
		global.layout_train_count[layout_id] = nil
		global.layouts[layout_id] = nil
		for _, station in pairs(global.stations) do
			station.accepted_layouts[layout_id] = nil
		end
	else
		global.layout_train_count[layout_id] = count - 1
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
		for _, station in pairs(map_data.stations) do
			if station.layout_pattern then
				station.accepted_layouts[layout_id] = is_layout_accepted(station.layout_pattern, layout) or nil
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
	local manifest = train.manifest--[[@as Manifest]]

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
						local stack_size = get_stack_size(map_data, item.name)
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
						signals[i] = {index = i, signal = {type = "item", name = stack.name}, count = -stack.count}
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
					if game.item_prototypes[name] then
						wagon_signals[1] = {index = 1, signal = {type = "item", name = a.name}, count = 1}
					end
				end
			end
			for stack_i = 1, #inv do
				local stack = inv[stack_i]
				if stack.valid_for_read then
					if comb then
						local i = #wagon_signals + 1
						wagon_signals[i] = {index = i, signal = {type = "item", name = stack.name}, count = stack.count}
					end
					local j = #signals + 1
					signals[j] = {index = j, signal = {type = "item", name = stack.name}, count = stack.count}
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
	if stop.entity_stop.connected_rail_direction == defines.rail_direction.front then
		rail_direction_from_stop = defines.rail_direction.back
	else
		rail_direction_from_stop = defines.rail_direction.front
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
		search_area = {left_top = {x = middle_x - reach, y = middle_y}, right_bottom = {x = middle_x + reach, y = middle_y + 6}}
		area_delta = {x = 0, y = 7}
		is_ver = true
	elseif stop_direction == defines.direction.east then
		search_area = {left_top = {y = middle_y - reach, x = middle_x - 6}, right_bottom = {y = middle_y + reach, x = middle_x}}
		area_delta = {x = -7, y = 0}
		is_ver = false
	elseif stop_direction == defines.direction.south then
		search_area = {left_top = {x = middle_x - reach, y = middle_y - 6}, right_bottom = {x = middle_x + reach, y = middle_y}}
		area_delta = {x = 0, y = -7}
		is_ver = true
	elseif stop_direction == defines.direction.west then
		search_area = {left_top = {y = middle_y - reach, x = middle_x}, right_bottom = {y = middle_y + reach, x = middle_x + 6}}
		area_delta = {x = 7, y = 0}
		is_ver = false
	else
		assert(false, "cybersyn: invalid stop direction")
	end
	local length = 2
	local pre_rail = stop_rail
	local layout_pattern = {0}
	local type_filter = {"inserter", "pump", "arithmetic-combinator"}
	local wagon_number = 0
	for i = 1, 112 do
		local rail, rail_direction, rail_connection_direction = pre_rail.get_connected_rail({rail_direction = rail_direction_from_stop, rail_connection_direction = defines.rail_connection_direction.straight})
		if not rail or rail_connection_direction ~= defines.rail_connection_direction.straight or not rail.valid then
			is_break = true
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
						if param.operation == MODE_WAGON_MANIFEST then
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
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
---@param force boolean?
function update_stop_from_rail(map_data, rail, forbidden_entity, force)
	--NOTE: is this a correct way to figure out the direction?
	---@type defines.rail_direction
	local rail_direction = defines.rail_direction.back
	local entity = rail.get_rail_segment_entity(rail_direction, false)
	if not entity then
		rail_direction = defines.rail_direction.front
		entity = rail.get_rail_segment_entity(rail_direction, false)
	end
	for i = 1, 112 do
		if not entity or not entity.valid then
			return
		end
		if entity.name == "train-stop" then
			local id = entity.unit_number
			local is_station = true
			local stop = map_data.stations[id]
			if not stop then
				stop = map_data.refuelers[id]
				is_station = false
			end
			if stop then
				if force then
					reset_stop_layout(map_data, stop, is_station, forbidden_entity)
				elseif not stop.allows_all_trains then
					reset_stop_layout(map_data, stop, is_station, forbidden_entity)
				end
			end
			return
		end

		rail = rail.get_connected_rail({rail_direction = rail_direction, rail_connection_direction = defines.rail_connection_direction.straight})--[[@as LuaEntity]]
		if not rail or not rail.valid then
			return
		end
		entity = rail.get_rail_segment_entity(rail_direction, false)
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

	--NOTE: we don't use find_entity solely for miniloader compat
	local rails = surface.find_entities_filtered({
		type = "straight-rail",
		position = inserter.pickup_position,
		radius = 1,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
	end
	rails = surface.find_entities_filtered({
		type = "straight-rail",
		position = inserter.drop_position,
		radius = 1,
	})
	if rails[1] then
		update_stop_from_rail(map_data, rails[1], forbidden_entity)
	end
end
