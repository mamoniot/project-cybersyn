--By Monica Moniot
local function on_station_built(map_data, stop)
	local station = {
		deliveries_total = 0,
		train_limit = 100,
		priority = 0,
		last_delivery_tick = 0,
		r_threshold = 0,
		p_threshold = 0,
		entity = stop,
		--train_layout: [ [ {
		--	[car_type]: true|nil
		--} ] ]
		accepted_layouts = {
			--[layout_id]: true|nil
		}
	}
	map_data.stations[stop.unit_number] = station
end
local function on_station_broken(map_data, stop)
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

local function on_failed_delivery(map_data, train)
	if train.status == STATUS_D or train.status == STATUS_D_TO_P or train.status == STATUS_P then
		local station = map_data.stations[train.p_station_id]
		for i, item in ipairs(train.manifest) do
			station.deliveries[item.name] = station.deliveries[item.name] + item.count
		end
	end
	if train.status ~= STATUS_R_TO_D then
		local station = map_data.stations[train.r_station_id]
		for i, item in ipairs(train.manifest) do
			station.deliveries[item.name] = station.deliveries[item.name] - item.count
		end
	end
	--TODO: change circuit outputs
	train.r_station_id = 0
	train.p_station_id = 0
	train.manifest = nil
	--NOTE: must change train status after call or remove it from tracked trains
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
			else
				on_failed_delivery(map_data, train)
			end
		end
		train.depot_id = train_entity.station.unit_number
		train.depot_name = train_entity.station.backer_name
		train.status = STATUS_D
		map_data.trains_available[train_entity.id] = true
	else
		map_data.trains[train_entity.id] = {
			depot_id = train_entity.station.unit_number,
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
	end
	map_data.trains_available[train_entity.id] = true
end

local function on_train_arrives_buffer(map_data, station_id, train)
	if train.manifest then
		if train.status == STATUS_D_TO_P then
			if train.p_station_id == station_id then
				train.status = STATUS_P
				--TODO: change circuit outputs
			end
		elseif train.status == STATUS_P_TO_R then
			if train.r_station_id == station_id then
				train.status = STATUS_R
				--TODO: change circuit outputs
			end
		else
			on_failed_delivery(map_data, train)
			map_data.trains[train.entity.id] = nil
		end
	else
		--train is lost somehow, probably from player intervention
		map_data.trains[train.entity.id] = nil
	end
end

local function on_train_leaves_buffer(map_data, train)
	if train.manifest then
		if train.status == STATUS_P then
			train.status = STATUS_P_TO_R
			local station = map_data.stations[train.p_station_id]
			for i, item in ipairs(train.manifest) do
				station.deliveries[item.name] = station.deliveries[item.name] + item.count
			end
			--TODO: change circuit outputs
		elseif train.status == STATUS_R then
			train.status = STATUS_R_TO_D
			local station = map_data.stations[train.r_station_id]
			for i, item in ipairs(train.manifest) do
				station.deliveries[item.name] = station.deliveries[item.name] - item.count
			end
			--TODO: change circuit outputs
		end
	end
end

local function on_train_broken(map_data, train)
	if train.manifest then
		on_failed_delivery(map_data, train)
		map_data.trains[train.entity.id] = nil
	end
end


local function on_tick(event)
	tick(global.stations, global.trains_available, global.total_ticks)
	global.total_ticks = global.total_ticks + 1
end
local function on_built(event)
	local entity = event.entity or event.created_entity or event.destination
	if not entity or not entity.valid or entity.name ~= BUFFER_STATION_NAME then return end

	on_station_built(global, entity)
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
		on_station_broken(entity.unit_number)
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
		if train and train.is_at_buffer then
			on_train_leaves_buffer(global, train)
		end
	end
end

local filter_built = {{filter = "type", type = "train-stop"}}
local filter_broken = {{filter = "type", type = "train-stop"}, {filter = "rolling-stock"}}
local function register_events()

	script.on_event(defines.events.on_built_entity, on_built, filter_built)
	script.on_event(defines.events.on_robot_built_entity, on_built, filter_built)
	script.on_event({defines.events.script_raised_built, defines.events.script_raised_revive, defines.events.on_entity_cloned}, on_built)

	script.on_event(defines.events.on_pre_player_mined_item, on_broken, filter_broken)
	script.on_event(defines.events.on_robot_pre_mined, on_broken, filter_broken)
	script.on_event(defines.events.on_entity_died, on_broken, filter_broken)
	script.on_event(defines.events.script_raised_destroy, on_broken)

	script.on_event({defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared}, on_surface_removed)

	--  script.on_nth_tick(nil)
	script.on_nth_tick(controller_nth_tick, on_tick)

	script.on_event(defines.events.on_train_created, on_train_built)
	script.on_event(defines.events.on_train_changed_state, on_train_changed)
end

script.on_load(function()
	register_events()
end)

script.on_init(function()
	register_events()
end)

script.on_configuration_changed(function(data)
	register_events()
end)
