local table_insert = table.insert

local lib = {}

---@param schedule TrainSchedule
---@param stop LuaEntity
---@param old_surface_index uint
---@param search_start uint
local function se_add_direct_to_station_order(schedule, stop, old_surface_index, search_start)
	--assert(search_start ~= 1 or schedule.current == 1)
	local surface_i = stop.surface.index
	if surface_i ~= old_surface_index then
		local name = stop.backer_name
		local records = schedule.records
		for i = search_start, #records do
			if records[i].station == name then
				if i == 1 then
					--i == search_start == 1 only if schedule.current == 1, so we can append this order to the very end of the list and let it wrap around
					records[#records + 1] = create_direct_to_station_order(stop)
					schedule.current = #records --[[@as uint]]
					return 2
				else
					table_insert(records, i, create_direct_to_station_order(stop))
					return i + 2 --[[@as uint]]
				end
			end
		end
	end
	return search_start
end

function lib.setup_se_compat()
	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
	if not IS_SE_PRESENT then return end

	local se_on_train_teleport_finished_event = remote.call("space-exploration", "get_on_train_teleport_finished_event") --[[@as string]]
	local se_on_train_teleport_started_event = remote.call("space-exploration", "get_on_train_teleport_started_event") --[[@as string]]

	---@param event {}
	script.on_event(se_on_train_teleport_started_event, function(event)
		---@type MapData
		local map_data = storage
		local old_id = event.old_train_id_1

		local train = map_data.trains[old_id]
		if not train then return end
		--NOTE: IMPORTANT, until se_on_train_teleport_finished_event is called map_data.trains[old_id] will reference an invalid train entity; our events have either been set up to account for this or should be impossible to trigger until teleportation is finished
		train.se_is_being_teleported = true
		interface_raise_train_teleport_started(old_id)
	end)
	---@param event {}
	script.on_event(se_on_train_teleport_finished_event, function(event)
		---@type MapData
		local map_data = storage
		---@type LuaTrain
		local train_entity = event.train
		---@type uint
		local new_id = train_entity.id
		local old_surface_index = event.old_surface_index

		local old_id = event.old_train_id_1
		local train = map_data.trains[old_id]
		if not train then return end

		if train.is_available then
			local f, a
			if train.network_name == NETWORK_EACH then
				f, a = next, train.network_mask
			else
				f, a = once, train.network_name
			end
			for network_name in f, a do
				local network = map_data.available_trains[network_name]
				if network then
					network[new_id] = true
					network[old_id] = nil
					if next(network) == nil then
						map_data.available_trains[network_name] = nil
					end
				end
			end
		end

		map_data.trains[new_id] = train
		map_data.trains[old_id] = nil
		train.se_is_being_teleported = nil
		train.entity = train_entity

		if train.se_awaiting_removal then
			remove_train(map_data, train.se_awaiting_removal, train)
			lock_train(train.entity)
			send_alert_station_of_train_broken(map_data, train.entity)
			return
		elseif train.se_awaiting_rename then
			rename_manifest_schedule(train.entity, train.se_awaiting_rename[1], train.se_awaiting_rename[2])
			train.se_awaiting_rename = nil
		end

		local schedule = train_entity.schedule
		if schedule then
			--this code relies on train chedules being in this specific order to work
			local start = schedule.current
			--check depot
			if not train.use_any_depot then
				local stop = map_data.depots[train.depot_id].entity_stop
				if stop.valid then
					start = se_add_direct_to_station_order(schedule, stop, old_surface_index, start)
				end
			end
			--check provider
			if train.status == STATUS_TO_P then
				local stop = map_data.stations[train.p_station_id].entity_stop
				if stop.valid then
					start = se_add_direct_to_station_order(schedule, stop, old_surface_index, start)
				end
			end
			--check requester
			if train.status == STATUS_TO_P or train.status == STATUS_TO_R then
				local stop = map_data.stations[train.r_station_id].entity_stop
				if stop.valid then
					start = se_add_direct_to_station_order(schedule, stop, old_surface_index, start)
				end
			end
			--check refueler
			if train.status == STATUS_TO_F then
				local stop = map_data.refuelers[train.refueler_id].entity_stop
				if stop.valid then
					start = se_add_direct_to_station_order(schedule, stop, old_surface_index, start)
				end
			end
			train_entity.schedule = schedule
		end
		interface_raise_train_teleported(new_id, old_id)
	end)
end

return lib
