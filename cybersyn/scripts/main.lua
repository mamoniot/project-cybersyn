--By Mami



local function on_failed_delivery(map_data, train)
	--NOTE: must change train status to STATUS_D or remove it from tracked trains after this call
	local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
	if not is_p_delivery_made then
		local station = map_data.stations[train.p_station_id]
		for i, item in ipairs(train.manifest) do
			station.deliveries[item.name] = station.deliveries[item.name] + item.count
			if station.deliveries[item.name] == 0 then
				station.deliveries[item.name] = nil
			end
		end
		station.deliveries_total = station.deliveries_total - 1
		if train.status == STATUS_P then
			--change circuit outputs
			station.entity_out.get_control_behavior().parameters = nil
		end
	end
	local is_r_delivery_made = train.status == STATUS_R_TO_D
	if not is_r_delivery_made then
		local station = map_data.stations[train.r_station_id]
		for i, item in ipairs(train.manifest) do
			station.deliveries[item.name] = station.deliveries[item.name] - item.count
			if station.deliveries[item.name] == 0 then
				station.deliveries[item.name] = nil
			end
		end
		station.deliveries_total = station.deliveries_total - 1
		if train.status == STATUS_R then
			--change circuit outputs
			station.entity_out.get_control_behavior().parameters = nil
		end
	end
	train.r_station_id = 0
	train.p_station_id = 0
	train.manifest = nil
end

local function remove_train(map_data, train, train_id)
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
	else
		map_data.layout_train_count[layout_id] = count - 1
	end
end

local function on_station_built(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local in_pos
	local out_pos
	local direction
	local search_area
	if stop.direction == 0 then
		direction = 0
		in_pos = {pos_x, pos_y - 1}
		out_pos = {pos_x - 1, pos_y - 1}
		search_area = {
			{pos_x + DELTA - 1, pos_y + DELTA - 1},
			{pos_x - DELTA + 1, pos_y - DELTA}
		}
	elseif stop.direction == 2 then
		direction = 2
		in_pos = {pos_x, pos_y}
		out_pos = {pos_x, pos_y - 1}
		search_area = {
			{pos_x + DELTA, pos_y + DELTA - 1},
			{pos_x - DELTA + 1, pos_y - DELTA + 1}
		}
	elseif stop.direction == 4 then
		direction = 4
		in_pos = {pos_x - 1, pos_y}
		out_pos = {pos_x, pos_y}
		search_area = {
			{pos_x + DELTA - 1, pos_y + DELTA},
			{pos_x - DELTA + 1, pos_y - DELTA + 1}
		}
	elseif stop.direction == 6 then
		direction = 6
		in_pos = {pos_x - 1, pos_y - 1}
		out_pos = {pos_x - 1, pos_y}
		search_area = {
			{pos_x + DELTA - 1, pos_y + DELTA - 1},
			{pos_x - DELTA, pos_y - DELTA + 1}
		}
	else
		assert(false, "cybersyn: invalid direction of train stop")
	end

	local entity_in = nil
	local entity_out = nil
	local entities = stop.surface.find_entities(search_area)
	for _, cur_entity in pairs (entities) do
		if cur_entity.valid then
			if cur_entity.name == "entity-ghost" then
				if cur_entity.ghost_name == STATION_IN_NAME then
					_, entity_in = cur_entity.revive()
				elseif cur_entity.ghost_name == STATION_OUT_NAME then
					_, entity_out = cur_entity.revive()
				end
			elseif cur_entity.name == STATION_IN_NAME then
				entity_in = cur_entity
			elseif cur_entity.name == STATION_OUT_NAME then
				entity_out = cur_entity
			end
		end
	end

	if entity_in == nil then -- create new
		entity_in = stop.surface.create_entity({
			name = STATION_IN_NAME,
			position = in_pos,
			force = stop.force
		})
	end
	entity_in.operable = false
	entity_in.minable = false
	entity_in.destructible = false

	if entity_out == nil then -- create new
		entity_out = stop.surface.create_entity({
			name = STATION_OUT_NAME,
			position = out_pos,
			direction = direction,
			force = stop.force
		})
	end
	entity_out.operable = false
	entity_out.minable = false
	entity_out.destructible = false

	local station = {
		entity = stop,
		entity_in = entity_in,
		entity_out = entity_out,
		deliveries_total = 0,
		train_limit = 100,
		priority = 0,
		last_delivery_tick = 0,
		r_threshold = 0,
		p_threshold = 0,
		accepted_layouts = {}
	}

	map_data.stations[stop.unit_number] = station
end
local function on_station_broken(map_data, stop)
	--search for trains coming to the destroyed station
	local station_id = stop.unit_number
	local station = map_data.stations[station_id]
	for train_id, train in pairs(map_data.trains) do
		if station.deliveries_total <= 0 then
			break
		end
		local is_p = train.r_station_id == station_id
		local is_r = train.p_station_id == station_id
		if is_p or is_r then
			local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
			local is_r_delivery_made = train.status == STATUS_R_TO_D
			if (is_r and not is_r_delivery_made) or (is_p and not is_p_delivery_made) then
				--train is attempting delivery to a stop that was destroyed, stop it
				on_failed_delivery(map_data, train)
				train.entity.schedule = nil
				remove_train(map_data, train, train_id)
				--TODO: mark train as lost in the alerts system
			end
		end
	end
	map_data.stations[station_id] = nil
end

local function on_station_rename(map_data, stop)
	--search for trains coming to the renamed station
	local station_id = stop.unit_number
	local station = map_data.stations[station_id]
	for train_id, train in pairs(map_data.trains) do
		if station.deliveries_total <= 0 then
			break
		end
		local is_p = train.r_station_id == station_id
		local is_r = train.p_station_id == station_id
		if is_p or is_r then
			local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
			local is_r_delivery_made = train.status == STATUS_R_TO_D
			if (is_r and not is_r_delivery_made) or (is_p and not is_p_delivery_made) then
				--train is attempting delivery to a stop that was renamed
				--TODO: test to make sure this code actually works
				local record = train.entity.schedule.records
				if is_p then
					record[3] = create_loading_order(station.entity, train.manifest)
				else
					record[5] = create_unloading_order(station.entity)
				end
			end
		end
	end
end


local function find_and_add_all_stations(map_data)
	for _, surface in pairs(game.surfaces) do
		local stops = surface.find_entities_filtered({type="train-stop"})
		if stops then
			for k, stop in pairs(stops) do
				if stop.name == BUFFER_STATION_NAME then
					local station = map_data.stations[stop.unit_number]
					if not station then
						on_station_built(map_data, stop)
					end
				end
			end
		end
	end
end

local function update_train_layout(map_data, train)
	local carriages = train.entity.carriages
	local layout = ""
	local i = 1
	local item_slot_capacity = 0
	local fluid_capacity = 0
	for _, carriage in pairs(carriages) do
		if carriage.type == "cargo-wagon" then
			layout = layout.."C"
			item_slot_capacity = item_slot_capacity + carriage.prototype.inventory_size
		elseif carriage.type == "fluid-wagon" then
			layout = layout.."F"
			fluid_capacity = fluid_capacity + carriage.prototype.capacity
		else
			layout = layout.."?"
		end
		i = i + 1
	end
	local layout_id = 0
	for id, cur_layout in pairs(map_data.layouts) do
		if layout == cur_layout then
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
		--for station_id, station in pairs(map_data.stations) do
		--	if #layout >= #station.train_layout then
		--		local is_approved = true
		--		for i, v in ipairs(station.train_layout) do
		--			local c = string.sub(layout, i, i)
		--			if v == "C" then
		--				if c ~= "C" and c ~= "?" then
		--					is_approved = false
		--					break
		--				end
		--			elseif v == "F" then
		--				if c ~= "F" then
		--					is_approved = false
		--					break
		--				end
		--			end
		--		end
		--		for i = #station.train_layout, #layout do
		--			local c = string.sub(layout, i, i)
		--			if c ~= "?" then
		--				is_approved = false
		--				break
		--			end
		--		end
		--		if is_approved then
		--			station.accepted_layouts[layout_id] = true
		--		end
		--	end
		--end
	else
		map_data.layout_train_count[layout_id] = map_data.layout_train_count[layout_id] + 1
	end
	train.layout_id = layout_id
	train.item_slot_capacity = item_slot_capacity
	train.fluid_capacity = fluid_capacity
end


local function on_train_arrives_depot(map_data, train_entity)
	local train = map_data.trains[train_entity.id]
	if train then
		if train.manifest then
			if train.status == STATUS_R_TO_D then
				--succeeded delivery
				train.p_station_id = 0
				train.r_station_id = 0
				train.manifest = nil
				train.depot_name = train_entity.station.backer_name
				train.status = STATUS_D
				train.entity.schedule = {current = 1, records = {create_inactivity_order(train.depot_name)}}
				map_data.trains_available[train_entity.id] = true
			else
				on_failed_delivery(map_data, train)
				local contents = train.entity.get_contents()
				if next(contents) == nil then
					train.depot_name = train_entity.station.backer_name
					train.status = STATUS_D
					map_data.trains_available[train_entity.id] = true
				else--train still has cargo
					train.entity.schedule = nil
					remove_train(map_data, train, train_entity.id)
					--TODO: mark train as lost in the alerts system
				end
			end
		end
	else
		train = {
			depot_name = train_entity.station.backer_name,
			status = STATUS_D,
			entity = train_entity,
			layout_id = 0,
			item_slot_capacity = 0,
			fluid_capacity = 0,
			p_station = 0,
			r_station = 0,
			manifest = nil,
		}
		update_train_layout(train)
		map_data.trains[train_entity.id] = train
		map_data.trains_available[train_entity.id] = true
	end
end

local function on_train_arrives_buffer(map_data, station_id, train)
	if train.manifest then
		if train.status == STATUS_D_TO_P then
			if train.p_station_id == station_id then
				train.status = STATUS_P
				--change circuit outputs
				local station = map_data.stations[station_id]
				local signals = {}
				for i, item in ipairs(train.manifest) do
					signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = item.count}
				end
				station.entity_out.get_control_behavior().parameters = signals
			end
		elseif train.status == STATUS_P_TO_R then
			if train.r_station_id == station_id then
				train.status = STATUS_R
				--change circuit outputs
				local station = map_data.stations[station_id]
				local signals = {}
				for i, item in ipairs(train.manifest) do
					signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = -1}
				end
				station.entity_out.get_control_behavior().parameters = signals
			end
		else
			on_failed_delivery(map_data, train)
			remove_train(map_data, train, train.entity.id)
		end
	else
		--train is lost somehow, probably from player intervention
		remove_train(map_data, train, train.entity.id)
	end
end

local function on_train_leaves_station(map_data, train)
	if train.manifest then
		if train.status == STATUS_P then
			train.status = STATUS_P_TO_R
			local station = map_data.stations[train.p_station_id]
			for i, item in ipairs(train.manifest) do
				station.deliveries[item.name] = station.deliveries[item.name] + item.count
				if station.deliveries[item.name] == 0 then
					station.deliveries[item.name] = nil
				end
			end
			station.deliveries_total = station.deliveries_total - 1
			--change circuit outputs
			station.entity_out.get_control_behavior().parameters = nil
		elseif train.status == STATUS_R then
			train.status = STATUS_R_TO_D
			local station = map_data.stations[train.r_station_id]
			for i, item in ipairs(train.manifest) do
				station.deliveries[item.name] = station.deliveries[item.name] - item.count
				if station.deliveries[item.name] == 0 then
					station.deliveries[item.name] = nil
				end
			end
			station.deliveries_total = station.deliveries_total - 1
			--change circuit outputs
			station.entity_out.get_control_behavior().parameters = nil
		end
	end
end

local function on_train_broken(map_data, train)
	if train.manifest then
		on_failed_delivery(map_data, train)
		remove_train(map_data, train, train.entity.id)
	end
end

local function on_train_modified(map_data, pre_train_id, train_entity)
	local train = map_data.trains[pre_train_id]
	if train then

		if train.manifest then
			on_failed_delivery(map_data, train)
			remove_train(map_data, train, pre_train_id)
		else--train is in depot
			remove_train(map_data, train, pre_train_id)
			train.entity = train_entity
			update_train_layout(map_data, train)
			--TODO: update train stats

			map_data.trains[train_entity.id] = train
			map_data.trains_available[train_entity.id] = true
		end
	end
end




local function on_tick(event)
	tick(global, mod_settings)
	global.total_ticks = global.total_ticks + 1
end

local function on_built(event)
	local entity = event.entity or event.created_entity or event.destination
	if not entity or not entity.valid then return end
	if entity.name == BUFFER_STATION_NAME then
		on_station_built(global, entity)
	elseif entity.type == "inserter" then
	elseif entity.type == "pump" then
		if entity.pump_rail_target then

		end
	end
end
local function on_broken(event)
	local entity = event.entity
	if not entity or not entity.valid then return end

	if entity.train then
		local train = global.trains[entity.id]
		if train then
			on_train_broken(global, entity.train)
		end
	elseif entity.name == BUFFER_STATION_NAME then
		on_station_broken(global, entity)
	elseif entity.type == "inserter" then
	elseif entity.type == "pump" then
	end
end

local function on_train_changed(event)
	local train_e = event.train
	local train = global.trains[train_e.id]
	if train_e.state == defines.train_state.wait_station and train_e.station ~= nil then
		if train_e.station.name == DEPOT_STATION_NAME then
			on_train_arrives_depot(global, train_e)
		elseif train_e.station.name == BUFFER_STATION_NAME then
			if train then
				on_train_arrives_buffer(global, train_e.station.unit_number, train)
			end
		end
	elseif event.old_state == defines.train_state.wait_station then
		if train then
			on_train_leaves_station(global, train)
		end
	end
end

local function on_train_built(event)
	local train_e = event.train
	if event.old_train_id_1 then
		on_train_modified(global, event.old_train_id_1, train_e)
	end
	if event.old_train_id_2 then
		on_train_modified(global, event.old_train_id_2, train_e)
	end
end

local function on_surface_removed(event)
	local surface = game.surfaces[event.surface_index]
	if surface then
		local train_stops = surface.find_entities_filtered({type = "train-stop"})
		for _, entity in pairs(train_stops) do
			if entity.name == BUFFER_STATION_NAME then
				on_station_broken(global, entity)
			end
		end
	end
end

local function on_rename(event)
	if event.entity.name == BUFFER_STATION_NAME then
		on_station_rename(global, event.entity)
	end
end

local filter_built = {
	{filter = "type", type = "train-stop"},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
}
local filter_broken = {
	{filter = "type", type = "train-stop"},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "rolling-stock"},
}
local function register_events()
	--NOTE: I have no idea if this correctly registers all events once in all situations
	script.on_event(defines.events.on_built_entity, on_built, filter_built)
	script.on_event(defines.events.on_robot_built_entity, on_built, filter_built)
	script.on_event({defines.events.script_raised_built, defines.events.script_raised_revive, defines.events.on_entity_cloned}, on_built)

	script.on_event(defines.events.on_pre_player_mined_item, on_broken, filter_broken)
	script.on_event(defines.events.on_robot_pre_mined, on_broken, filter_broken)
	script.on_event(defines.events.on_entity_died, on_broken, filter_broken)
	script.on_event(defines.events.script_raised_destroy, on_broken)

	script.on_event({defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared}, on_surface_removed)

	local nth_tick = math.ceil(60/mod_settings.tps);
	script.on_nth_tick(nil)
	script.on_nth_tick(nth_tick, on_tick)

	script.on_event(defines.events.on_train_created, on_train_built)
	script.on_event(defines.events.on_train_changed_state, on_train_changed)

	script.on_event(defines.events.on_entity_renamed, on_rename)
end

script.on_load(function()
	register_events()
end)

script.on_init(function()
	--TODO: we are not checking changed cargo capacities
	find_and_add_all_stations(global)
	register_events()
end)

script.on_configuration_changed(function(data)
	--TODO: we are not checking changed cargo capacities
	find_and_add_all_stations(global)
	register_events()
end)
