--By Mami
local flib_event = require("__flib__.event")
local floor = math.floor


---@param map_data MapData
---@param station Station
---@param manifest Manifest
---@param sign int?
local function set_comb1(map_data, station, manifest, sign)
	local comb = station.entity_comb1
	if comb.valid then
		if manifest then
			local signals = {}
			for i, item in ipairs(manifest) do
				signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = sign*item.count}
			end
			set_combinator_output(map_data, comb, signals)
		else
			set_combinator_output(map_data, comb, nil)
		end
	end
end

---@param map_data MapData
---@param train Train
local function on_failed_delivery(map_data, train)
	--NOTE: must change train status to STATUS_D or remove it from tracked trains after this call
	local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
	if not is_p_delivery_made then
		local station = map_data.stations[train.p_station_id]
		remove_manifest(map_data, station, train.manifest, 1)
		if train.status == STATUS_P then
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
		end
	end
	local is_r_delivery_made = train.status == STATUS_R_TO_D
	if not is_r_delivery_made then
		local station = map_data.stations[train.r_station_id]
		remove_manifest(map_data, station, train.manifest, -1)
		if train.status == STATUS_R then
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
		end
	end
	train.r_station_id = 0
	train.p_station_id = 0
	train.manifest = nil
end


---@param map_data MapData
---@param depot_id uint
---@param train_id uint
local function add_available_train(map_data, depot_id, train_id)
	local depot = map_data.depots[depot_id]
	local train = map_data.trains[train_id]
	local comb = depot.entity_comb
	local network_name = get_comb_network_name(comb)
	if network_name then
		local network = map_data.available_trains[network_name]
		if not network then
			network = {}
			map_data.available_trains[network_name] = network
		end
		network[train_id] = depot_id
	end
	depot.available_train_id = train_id
	train.depot_id = depot_id
	train.depot_name = depot.entity_stop.backer_name
	train.network_name = network_name
	train.network_flag = mod_settings.network_flag
	train.priority = 0
	if network_name then
		local signals = comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
		if signals then
			for k, v in pairs(signals) do
				local item_name = v.signal.name
				local item_count = v.count
				if item_name then
					if item_name == SIGNAL_PRIORITY then
						train.priority = item_count
					end
					if item_name == network_name then
						train.network_flag = item_count
					end
				end
			end
		end
	end
end
---@param map_data MapData
---@param train Train
---@param depot Depot
function remove_available_train(map_data, train, depot)
	---@type uint
	local train_id = depot.available_train_id
	if train.network_name then
		local network = map_data.available_trains[train.network_name]
		if network then
			network[train_id] = nil
			if next(network) == nil then
				map_data.available_trains[train.network_name] = nil
			end
		end
	end
	train.depot_id = nil
	depot.available_train_id = nil
end


---@param map_data MapData
---@param stop LuaEntity
---@param comb LuaEntity
local function on_depot_built(map_data, stop, comb)
	local depot = {
		entity_stop = stop,
		entity_comb = comb,
		--available_train = nil,
	}
	map_data.depots[stop.unit_number] = depot
end

---@param map_data MapData
---@param depot Depot
local function on_depot_broken(map_data, depot)
	local train_id = depot.available_train_id
	if train_id then
		local train = map_data.trains[train_id]
		train.entity.schedule = nil
		send_lost_train_alert(train.entity, depot.entity_stop.backer_name)
		remove_available_train(map_data, train, depot)
		map_data.trains[train_id] = nil
	end
	map_data.depots[depot.entity_stop.unit_number] = nil
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb1 LuaEntity
---@param comb2 LuaEntity
local function on_station_built(map_data, stop, comb1, comb2)
	local station = {
		entity_stop = stop,
		entity_comb1 = comb1,
		entity_comb2 = comb2,
		wagon_combs = nil,
		deliveries_total = 0,
		last_delivery_tick = map_data.total_ticks,
		priority = 0,
		r_threshold = 0,
		locked_slots = 0,
		--network_name = param.first_signal and param.first_signal.name or nil,
		network_flag = 0,
		deliveries = {},
		--allows_all_trains = param.second_constant == 1,
		accepted_layouts = {},
		layout_pattern = nil,
		p_count_or_r_threshold_per_item = {},
	}
	set_station_from_comb_state(station)
	local id = stop.unit_number--[[@as uint]]
	map_data.stations[id] = station
	map_data.warmup_station_ids[#map_data.warmup_station_ids + 1] = id

	update_station_if_auto(map_data, station, nil)
end
---@param map_data MapData
---@param station_id uint
---@param station Station
local function on_station_broken(map_data, station_id, station)
	if station.deliveries_total > 0 then
		--search for trains coming to the destroyed station
		for train_id, train in pairs(map_data.trains) do
			local is_r = train.r_station_id == station_id
			local is_p = train.p_station_id == station_id
			if is_p or is_r then
				local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
				local is_r_delivery_made = train.status == STATUS_R_TO_D
				if (is_r and not is_r_delivery_made) or (is_p and not is_p_delivery_made) then
					--train is attempting delivery to a stop that was destroyed, stop it
					on_failed_delivery(map_data, train)
					train.entity.schedule = nil
					remove_train(map_data, train, train_id)
					send_lost_train_alert(train.entity, train.depot_name)
				end
			end
		end
	end
	map_data.stations[station_id] = nil
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb_operation string
---@param comb_forbidden LuaEntity?
local function search_for_station_combinator(map_data, stop, comb_operation, comb_forbidden)
	local pos_x = stop.position.x
	local pos_y = stop.position.y
	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if
		entity.valid and entity.name == COMBINATOR_NAME and
		entity ~= comb_forbidden and map_data.to_stop[entity.unit_number] == stop
		then
			local param = get_comb_params(entity)
			if param.operation == comb_operation then
				return entity
			end
		end
	end
end

---@param map_data MapData
---@param comb LuaEntity
local function on_combinator_built(map_data, comb)
	local pos_x = comb.position.x
	local pos_y = comb.position.y

	local search_area
	if comb.direction == defines.direction.north or comb.direction == defines.direction.south then
		search_area = {
			{pos_x - 1.5, pos_y - 2},
			{pos_x + 1.5, pos_y + 2}
		}
	else
		search_area = {
			{pos_x - 2, pos_y - 1.5},
			{pos_x + 2, pos_y + 1.5}
		}
	end
	local stop = nil
	local rail = nil
	local entities = comb.surface.find_entities(search_area)
	for _, cur_entity in pairs(entities) do
		if cur_entity.valid then
			if cur_entity.name == "train-stop" then
				--NOTE: if there are multiple stops we take the later one
				stop = cur_entity
			elseif cur_entity.type == "straight-rail" then
				rail = cur_entity
			end
		end
	end

	local out = comb.surface.create_entity({
		name = COMBINATOR_OUT_NAME,
		position = comb.position,
		force = comb.force
	})
	assert(out, "cybersyn: could not spawn combinator controller")
	comb.connect_neighbour({
		target_entity = out,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
		wire = defines.wire_type.green,
	})
	comb.connect_neighbour({
		target_entity = out,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
		wire = defines.wire_type.red,
	})

	local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local param = control.parameters
	local op = param.operation

	if op == OPERATION_DEFAULT then
		op = OPERATION_PRIMARY_IO
		param.operation = op
		param.first_signal = NETWORK_SIGNAL_DEFAULT
		control.parameters = param
	elseif op == OPERATION_PRIMARY_IO_ACTIVE or op == OPERATION_PRIMARY_IO_FAILED_REQUEST then
		op = OPERATION_PRIMARY_IO
		param.operation = op
		control.parameters = param
	end

	map_data.to_comb[comb.unit_number] = comb
	map_data.to_output[comb.unit_number] = out
	map_data.to_stop[comb.unit_number] = stop
	map_data.to_comb_params[comb.unit_number] = param

	if op == OPERATION_WAGON_MANIFEST then
		if rail then
			force_update_station_from_rail(map_data, rail, nil)
		end
	elseif op == OPERATION_DEPOT then
		if stop then
			local station = map_data.stations[stop.unit_number]
			---@type Depot
			local depot = map_data.depots[stop.unit_number]
			if depot or station then
				--NOTE: repeated combinators are ignored
			else
				on_depot_built(map_data, stop, comb)
			end
		end
	elseif op == OPERATION_SECONDARY_IO then
		if stop then
			local station = map_data.stations[stop.unit_number]
			if station and not station.entity_comb2 then
				station.entity_comb2 = comb
			end
		end
	elseif op == OPERATION_PRIMARY_IO then
		if stop then
			local station = map_data.stations[stop.unit_number]
			if station then
				--NOTE: repeated combinators are ignored
			else
				local depot = map_data.depots[stop.unit_number]
				if depot then
					on_depot_broken(map_data, depot)
				end
				--no station or depot
				--add station

				local comb2 = search_for_station_combinator(map_data, stop, OPERATION_SECONDARY_IO, comb)

				on_station_built(map_data, stop, comb, comb2)
			end
		end
	end
end
---@param map_data MapData
---@param comb LuaEntity
---@param network_name string?
function on_combinator_network_updated(map_data, comb, network_name)
	local stop = map_data.to_stop[comb.unit_number]

	if stop and stop.valid then
		local station = map_data.stations[stop.unit_number]
		if station then
			if station.entity_comb1 == comb then
				station.network_name = network_name
			end
		else
			local depot_id = stop.unit_number
			local depot = map_data.depots[depot_id]
			if depot and depot.entity_comb == comb then
				local train_id = depot.available_train_id
				if train_id then
					local train = map_data.trains[train_id]
					remove_available_train(map_data, train, depot)
					add_available_train(map_data, depot_id, train_id)
				end
			end
		end
	end
end
---@param map_data MapData
---@param comb LuaEntity
local function on_combinator_broken(map_data, comb)
	--NOTE: we do not check for wagon manifest combinators and update their stations, it is assumed they will be lazy deleted later
	---@type uint
	local comb_id = comb.unit_number
	local out = map_data.to_output[comb_id]
	local stop = map_data.to_stop[comb_id]

	if stop and stop.valid then
		local station = map_data.stations[stop.unit_number]
		if station then
			if station.entity_comb1 == comb then
				local comb1 = search_for_station_combinator(map_data, stop, OPERATION_PRIMARY_IO, comb)
				if comb1 then
					station.entity_comb1 = comb1
					set_station_from_comb_state(station)
					update_station_if_auto(map_data, station)
				else
					on_station_broken(map_data, stop.unit_number, station)
					local depot_comb = search_for_station_combinator(map_data, stop, OPERATION_DEPOT, comb)
					if depot_comb then
						on_depot_built(map_data, stop, depot_comb)
					end
				end
			elseif station.entity_comb2 == comb then
				station.entity_comb2 = search_for_station_combinator(map_data, stop, OPERATION_SECONDARY_IO, comb)
			end
		else
			local depot = map_data.depots[stop.unit_number]
			if depot and depot.entity_comb == comb then
				--NOTE: this will disrupt deliveries in progress that where dispatched from this station in a minor way
				local depot_comb = search_for_station_combinator(map_data, stop, OPERATION_DEPOT, comb)
				if depot_comb then
					depot.entity_comb = depot_comb
				else
					on_depot_broken(map_data, depot)
				end
			end
		end
	end

	if out and out.valid then
		out.destroy()
	end
	map_data.to_comb[comb_id] = nil
	map_data.to_output[comb_id] = nil
	map_data.to_stop[comb_id] = nil
	map_data.to_comb_params[comb_id] = nil
end

---@param map_data MapData
---@param comb LuaEntity
---@param new_params ArithmeticCombinatorParameters
function on_combinator_updated(map_data, comb, new_params)
	local old_params = map_data.to_comb_params[comb.unit_number]
	if new_params.operation ~= old_params.operation then
		if (new_params.operation == OPERATION_PRIMARY_IO_ACTIVE or new_params.operation == OPERATION_PRIMARY_IO_FAILED_REQUEST or new_params.operation == OPERATION_PRIMARY_IO) and (old_params.operation == OPERATION_PRIMARY_IO_ACTIVE or old_params.operation == OPERATION_PRIMARY_IO_FAILED_REQUEST or old_params.operation == OPERATION_PRIMARY_IO) then
			set_combinator_operation(comb, old_params.operation)
			new_params.operation = old_params.operation
		else
			--NOTE: This is rather dangerous, we may need to actually implement operation changing
			on_combinator_broken(map_data, comb)
			on_combinator_built(map_data, comb)
			return
		end
	end
	local new_signal = new_params.first_signal
	local old_signal = old_params.first_signal
	local new_network = new_signal and new_signal.name or nil
	local old_network = old_signal and old_signal.name or nil
	if new_network ~= old_network then
		on_combinator_network_updated(map_data, comb, new_network)
	end
	if new_params.second_constant ~= old_params.second_constant then
		local stop = global.to_stop[comb.unit_number]
		if stop then
			local station = global.stations[stop.unit_number]
			if station then
				local bits = new_params.second_constant
				local is_pr_state = floor(bits/2)%3
				station.is_p = is_pr_state == 0 or is_pr_state == 1
				station.is_r = is_pr_state == 0 or is_pr_state == 2
				local allows_all_trains = bits%2 == 1
				if station.allows_all_trains ~= allows_all_trains then
					station.allows_all_trains = allows_all_trains
					update_station_if_auto(map_data, station)
				end
			end
		end
	end
	map_data.to_comb_params[comb.unit_number] = new_params
end

---@param map_data MapData
---@param stop LuaEntity
local function on_stop_built(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local comb2 = nil
	local comb1 = nil
	local depot_comb = nil
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if entity.valid and entity.name == COMBINATOR_NAME and map_data.to_stop[entity.unit_number] == nil then
			map_data.to_stop[entity.unit_number] = stop
			local param = get_comb_params(entity)
			local op = param.operation
			if op == OPERATION_PRIMARY_IO then
				comb1 = entity
			elseif op == OPERATION_SECONDARY_IO then
				comb2 = entity
			elseif op == OPERATION_DEPOT then
				depot_comb = entity
			end
		end
	end
	if comb1 then
		on_station_built(map_data, stop, comb1, comb2)
	elseif depot_comb then
		on_depot_built(map_data, stop, depot_comb)
	end
end
---@param map_data MapData
---@param stop LuaEntity
local function on_stop_broken(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if entity.valid and map_data.to_stop[entity.unit_number] == stop then
			map_data.to_stop[entity.unit_number] = nil
		end
	end

	local station = map_data.stations[stop.unit_number]
	if station then
		on_station_broken(map_data, stop.unit_number, station)
	else
		local depot = map_data.depots[stop.unit_number]
		if depot then
			on_depot_broken(map_data, depot)
		end
	end
end
---@param map_data MapData
---@param stop LuaEntity
local function on_station_rename(map_data, stop)
	--search for trains coming to the renamed station
	local station_id = stop.unit_number
	local station = map_data.stations[station_id]
	if station and station.deliveries_total > 0 then
		for train_id, train in pairs(map_data.trains) do
			local is_p = train.p_station_id == station_id
			local is_r = train.r_station_id == station_id
			if is_p or is_r then
				local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
				local is_r_delivery_made = train.status == STATUS_R_TO_D
				if (is_r and not is_r_delivery_made) or (is_p and not is_p_delivery_made) then
					--train is attempting delivery to a stop that was renamed
					local p_station = map_data.stations[train.p_station_id]
					local r_station = map_data.stations[train.r_station_id]
					local schedule = create_manifest_schedule(train.depot_name, p_station.entity_stop, r_station.entity_stop, train.manifest)
					schedule.current = train.entity.schedule.current
					train.entity.schedule = schedule
				end
			end
		end
	else
		local depot = map_data.depots[station_id]
		if depot and depot.available_train_id then
			local train = map_data.trains[depot.available_train_id]
			train.depot_name = stop.backer_name
		end
	end
end


---@param map_data MapData
local function find_and_add_all_stations_from_nothing(map_data)
	for _, surface in pairs(game.surfaces) do
		local entities = surface.find_entities_filtered({name = COMBINATOR_NAME})
		for k, comb in pairs(entities) do
			if comb.valid then
				on_combinator_built(map_data, comb)
			end
		end
	end
end

---@param map_data MapData
---@param depot_id uint
---@param train_entity LuaTrain
local function on_train_arrives_depot(map_data, depot_id, train_entity)
	local contents = train_entity.get_contents()
	local train_id = train_entity.id
	local train = map_data.trains[train_id]
	if train then
		if train.manifest and train.status == STATUS_R_TO_D then
			--succeeded delivery
			train.p_station_id = 0
			train.r_station_id = 0
			train.manifest = nil
			train.status = STATUS_D
			add_available_train(map_data, depot_id, train_id)
		else
			if train.manifest then
				on_failed_delivery(map_data, train)
				send_unexpected_train_alert(train.entity)
			end
			train.status = STATUS_D
			add_available_train(map_data, depot_id, train_id)
		end
		if next(contents) ~= nil then
			--train still has cargo
			train_entity.schedule = nil
			remove_train(map_data, train, train_id)
			send_nonempty_train_in_depot_alert(train_entity)
		else
			train_entity.schedule = create_depot_schedule(train.depot_name)
		end
	elseif next(contents) == nil then
		train = {
			status = STATUS_D,
			entity = train_entity,
			layout_id = 0,
			item_slot_capacity = 0,
			fluid_capacity = 0,
			p_station_id = 0,
			r_station_id = 0,
			manifest = nil,
		}
		update_train_layout(map_data, train)
		map_data.trains[train_id] = train
		add_available_train(map_data, depot_id, train_id)

		local schedule = create_depot_schedule(train.depot_name)
		train_entity.schedule = schedule
	else
		send_nonempty_train_in_depot_alert(train_entity)
	end
end
---@param map_data MapData
---@param stop LuaEntity
---@param train Train
local function on_train_arrives_buffer(map_data, stop, train)
	if train.manifest then
		---@type uint
		local station_id = stop.unit_number
		if train.status == STATUS_D_TO_P then
			if train.p_station_id == station_id then
				train.status = STATUS_P
				local station = map_data.stations[station_id]
				set_comb1(map_data, station, train.manifest, 1)
				set_p_wagon_combs(map_data, station, train)
			end
		elseif train.status == STATUS_P_TO_R then
			if train.r_station_id == station_id then
				train.status = STATUS_R
				local station = map_data.stations[station_id]
				set_comb1(map_data, station, train.manifest, -1)
				set_r_wagon_combs(map_data, station, train)
			end
		elseif train.status == STATUS_P and train.p_station_id == station_id then
		elseif train.status == STATUS_R and train.r_station_id == station_id then
		else
			on_failed_delivery(map_data, train)
			remove_train(map_data, train, train.entity.id)
			train.entity.schedule = nil
			send_lost_train_alert(train.entity, train.depot_name)
		end
	else
		--train is lost somehow, probably from player intervention
		remove_train(map_data, train, train.entity.id)
	end
end
---@param map_data MapData
---@param train Train
local function on_train_leaves_station(map_data, train)
	if train.manifest then
		if train.status == STATUS_P then
			train.status = STATUS_P_TO_R
			local station = map_data.stations[train.p_station_id]
			remove_manifest(map_data, station, train.manifest, 1)
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
			if train.has_filtered_wagon then
				train.has_filtered_wagon = false
				for carriage_i, carriage in ipairs(train.entity.carriages) do
					if carriage.type == "cargo-wagon" then
						local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
						if inv and inv.is_filtered() then
							---@type uint
							for i = 1, #inv do
								inv.set_filter(i, nil)
							end
						end
					end
				end
			end
		elseif train.status == STATUS_R then
			train.status = STATUS_R_TO_D
			local station = map_data.stations[train.r_station_id]
			remove_manifest(map_data, station, train.manifest, -1)
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
		end
	elseif train.depot_id then
		local depot = map_data.depots[train.depot_id]
		remove_available_train(map_data, train, depot)
	end
end


---@param map_data MapData
---@param train Train
local function on_train_broken(map_data, train)
	if train.manifest then
		on_failed_delivery(map_data, train)
		remove_train(map_data, train, train.entity.id)
		if train.entity.valid then
			train.entity.schedule = nil
		end
	end
end
---@param map_data MapData
---@param pre_train_id uint
---@param train_entity LuaEntity
local function on_train_modified(map_data, pre_train_id, train_entity)
	local train = map_data.trains[pre_train_id]
	if train then
		if train.manifest then
			on_failed_delivery(map_data, train)
		end
		remove_train(map_data, train, pre_train_id)
		if train.entity.valid then
			train.entity.schedule = nil
		end
	end
end


local function on_built(event)
	local entity = event.entity or event.created_entity or event.destination
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_built(global, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_built(global, entity)
	elseif entity.type == "inserter" then
		update_station_from_inserter(global, entity)
	elseif entity.type == "pump" then
		update_station_from_pump(global, entity)
	elseif entity.type == "straight-rail" then
		update_station_from_rail(global, entity)
	end
end
local function on_broken(event)
	local entity = event.entity
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_broken(global, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_broken(global, entity)
	elseif entity.type == "inserter" then
		update_station_from_inserter(global, entity, entity)
	elseif entity.type == "pump" then
		update_station_from_pump(global, entity, entity)
	elseif entity.type == "straight-rail" then
		update_station_from_rail(global, entity, nil)
	elseif entity.train then
		local train = global.trains[entity.train.id]
		if train then
			on_train_broken(global, train)
		end
	end
end
local function on_rename(event)
	if event.entity.name == "train-stop" then
		on_station_rename(global, event.entity)
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
local function on_train_changed(event)
	local train_e = event.train
	if train_e.valid then
		local train = global.trains[train_e.id]
		if train_e.state == defines.train_state.wait_station then
			local stop = train_e.station
			if stop and stop.valid and stop.name == "train-stop" then
				if global.stations[stop.unit_number] then
					if train then
						on_train_arrives_buffer(global, stop, train)
					end
				else
					local depot_id = stop.unit_number
					if global.depots[depot_id] then
						on_train_arrives_depot(global, depot_id, train_e)
					end
				end
			end
		elseif event.old_state == defines.train_state.wait_station then
			if train then
				on_train_leaves_station(global, train)
			end
		end
	end
end

local function on_surface_removed(event)
	local surface = game.surfaces[event.surface_index]
	if surface then
		local train_stops = surface.find_entities_filtered({type = "train-stop"})
		for _, entity in pairs(train_stops) do
			if entity.name == "train-stop" then
				on_stop_broken(global, entity)
			end
		end
	end
end


local function on_paste(event)
	local entity = event.destination
	if not entity or not entity.valid then return end

	if entity.name == COMBINATOR_NAME then
		on_combinator_updated(global, entity, get_comb_params(entity))
	end
end

local function on_cursor_stack_changed(event)
	local i = event.player_index
	local player = game.get_player(i)
	if not player then return end
	local cursor = player.cursor_stack

	if global.is_player_cursor_blueprint[i] then
		--TODO: check if we can limit this search somehow?
		for id, comb in pairs(global.to_comb) do
			on_combinator_updated(global, comb, get_comb_params(comb))
		end
	end
	local contains_comb = nil
	if cursor and cursor.valid_for_read and cursor.type == "blueprint" then
		local cost_to_build = cursor.cost_to_build
		for k, v in pairs(cost_to_build) do
			if k == COMBINATOR_NAME then
				contains_comb = true
				break
			end
		end
	end
	global.is_player_cursor_blueprint[i] = contains_comb
end


local function on_settings_changed(event)
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value--[[@as int]]
	mod_settings.network_flag = settings.global["cybersyn-network-flag"].value--[[@as int]]
	mod_settings.warmup_time = settings.global["cybersyn-warmup-time"].value--[[@as int]]
	if event.setting == "cybersyn-ticks-per-second" then
		local nth_tick = math.ceil(60/mod_settings.tps);
		flib_event.on_nth_tick(nil)
		flib_event.on_nth_tick(nth_tick, function()
			tick(global, mod_settings)
		end)
	end
end


local filter_built = {
	{filter = "name", name = "train-stop"},
	{filter = "name", name = COMBINATOR_NAME},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "type", type = "straight-rail"},
}
local filter_broken = {
	{filter = "name", name = "train-stop"},
	{filter = "name", name = COMBINATOR_NAME},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "type", type = "straight-rail"},
	{filter = "rolling-stock"},
}
local function main()
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value--[[@as int]]
	mod_settings.network_flag = settings.global["cybersyn-network-flag"].value--[[@as int]]
	mod_settings.warmup_time = settings.global["cybersyn-warmup-time"].value--[[@as int]]

	--NOTE: There is a concern that it is possible to build or destroy important entities without one of these events being triggered, in which case the mod will have undefined behavior
	flib_event.register(defines.events.on_built_entity, on_built, filter_built)
	flib_event.register(defines.events.on_robot_built_entity, on_built, filter_built)
	flib_event.register({defines.events.script_raised_built, defines.events.script_raised_revive, defines.events.on_entity_cloned}, on_built)

	flib_event.register(defines.events.on_pre_player_mined_item, on_broken, filter_broken)
	flib_event.register(defines.events.on_robot_pre_mined, on_broken, filter_broken)
	flib_event.register(defines.events.on_entity_died, on_broken, filter_broken)
	flib_event.register(defines.events.script_raised_destroy, on_broken)

	flib_event.register({defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared}, on_surface_removed)

	--flib_event.register(defines.events.on_entity_settings_pasted, on_paste)
	--flib_event.register(defines.events.on_player_cursor_stack_changed, on_cursor_stack_changed)

	local nth_tick = math.ceil(60/mod_settings.tps);
	flib_event.on_nth_tick(nth_tick, function()
		tick(global, mod_settings)
	end)

	flib_event.register(defines.events.on_train_created, on_train_built)
	flib_event.register(defines.events.on_train_changed_state, on_train_changed)

	flib_event.register(defines.events.on_entity_renamed, on_rename)

	flib_event.register(defines.events.on_runtime_mod_setting_changed, on_settings_changed)

	register_gui_actions()

	flib_event.on_init(init_global)

	flib_event.on_configuration_changed(on_config_changed)
end


main()
