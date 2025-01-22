-- Code related to Space Exploration compatibility.

SE_ELEVATOR_STOP_PROTO_NAME = "se-space-elevator-train-stop"
SE_ELEVATOR_ORBIT_SUFFIX = " ↓"
SE_ELEVATOR_PLANET_SUFFIX = " ↑"
SE_ELEVATOR_SUFFIX_LENGTH = 4

local table_insert = table.insert
local string_sub = string.sub
local string_len = string.len

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

---@param cache PerfCache
---@param surface LuaSurface
function lib.se_get_space_elevator_name(cache, surface)
	---@type LuaEntity?
	local entity = nil
	local cache_idx = surface.index
	if cache.se_get_space_elevator_name then
		entity = cache.se_get_space_elevator_name[cache_idx]
	else
		cache.se_get_space_elevator_name = {}
	end

	if not entity or not entity.valid then
		--Caching failed, default to expensive lookup
		entity = surface.find_entities_filtered({
			name = SE_ELEVATOR_STOP_PROTO_NAME,
			type = "train-stop",
			limit = 1,
		})[1]

		if entity then
			cache.se_get_space_elevator_name[cache_idx] = entity
		end
	end

	if entity and entity.valid then
		return string_sub(entity.backer_name, 1, string_len(entity.backer_name) - SE_ELEVATOR_SUFFIX_LENGTH)
	else
		return nil
	end
end

---@param cache PerfCache
---@param surface_index uint
function lib.se_get_zone_from_surface_index(cache, surface_index)
	---@type uint?
	local zone_index = nil
	---@type uint?
	local zone_orbit_index = nil
	local cache_idx = 2 * surface_index
	if cache.se_get_zone_from_surface_index then
		zone_index = cache.se_get_zone_from_surface_index[cache_idx - 1] --[[@as uint]]
		--zones may not have an orbit_index
		zone_orbit_index = cache.se_get_zone_from_surface_index[cache_idx] --[[@as uint?]]
	else
		cache.se_get_zone_from_surface_index = {}
	end

	if not zone_index then
		zone = remote.call("space-exploration", "get_zone_from_surface_index", { surface_index = surface_index })

		if zone and type(zone.index) == "number" then
			zone_index = zone.index --[[@as uint]]
			zone_orbit_index = zone.orbit_index --[[@as uint?]]
			--NOTE: caching these indices could be a problem if SE is not deterministic in choosing them
			cache.se_get_zone_from_surface_index[cache_idx - 1] = zone_index
			cache.se_get_zone_from_surface_index[cache_idx] = zone_orbit_index
		end
	end

	return zone_index, zone_orbit_index
end

---@param elevator_name string
---@param is_train_in_orbit boolean
---@return ScheduleRecord
function lib.se_create_elevator_order(elevator_name, is_train_in_orbit)
	return { station = elevator_name .. (is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX) }
end

---@param cache PerfCache
---@param train LuaTrain
---@param depot_stop LuaEntity
---@param same_depot boolean
---@param p_stop LuaEntity
---@param p_schedule_settings Cybersyn.StationScheduleSettings
---@param r_stop LuaEntity
---@param r_schedule_settings Cybersyn.StationScheduleSettings
---@param manifest Manifest
---@param start_at_depot boolean?
---@return (ScheduleRecord[])?
function lib.se_set_manifest_schedule(
		cache,
		train,
		depot_stop,
		same_depot,
		p_stop,
		p_schedule_settings,
		r_stop,
		r_schedule_settings,
		manifest,
		start_at_depot)
	local t_surface = train.front_stock.surface
	local p_surface = p_stop.surface
	local r_surface = r_stop.surface
	local d_surface_i = depot_stop.surface.index
	local t_surface_i = t_surface.index
	local p_surface_i = p_surface.index
	local r_surface_i = r_surface.index
	local is_p_on_t = t_surface_i == p_surface_i
	local is_r_on_t = t_surface_i == r_surface_i
	local is_d_on_t = t_surface_i == d_surface_i

	local other_surface_i = (not is_p_on_t and p_surface_i) or (not is_r_on_t and r_surface_i) or d_surface_i
	if (is_p_on_t or p_surface_i == other_surface_i) and (is_r_on_t or r_surface_i == other_surface_i) and (is_d_on_t or d_surface_i == other_surface_i) then
		local t_zone_index, t_zone_orbit_index = lib.se_get_zone_from_surface_index(cache, t_surface_i)
		local other_zone_index, other_zone_orbit_index = lib.se_get_zone_from_surface_index(cache,
			other_surface_i)
		if t_zone_index and other_zone_index then
			local is_train_in_orbit = other_zone_orbit_index == t_zone_index
			if is_train_in_orbit or t_zone_orbit_index == other_zone_index then
				local elevator_name = lib.se_get_space_elevator_name(cache, t_surface)
				if elevator_name then
					local records = { create_inactivity_order(depot_stop.backer_name) }
					if t_surface_i == p_surface_i then
						records[#records + 1] = create_direct_to_station_order(p_stop)
					else
						records[#records + 1] = lib.se_create_elevator_order(elevator_name, is_train_in_orbit)
						is_train_in_orbit = not is_train_in_orbit
					end
					records[#records + 1] = create_loading_order(p_stop, manifest, p_schedule_settings)

					if p_surface_i ~= r_surface_i then
						records[#records + 1] = lib.se_create_elevator_order(elevator_name, is_train_in_orbit)
						is_train_in_orbit = not is_train_in_orbit
					elseif t_surface_i == r_surface_i then
						records[#records + 1] = create_direct_to_station_order(r_stop)
					end
					records[#records + 1] = create_unloading_order(r_stop, r_schedule_settings)
					if r_surface_i ~= d_surface_i then
						records[#records + 1] = lib.se_create_elevator_order(elevator_name, is_train_in_orbit)
						is_train_in_orbit = not is_train_in_orbit
					end

					return records
				end
			end
		end
	end
end

---@param cache PerfCache
---@param train LuaTrain
---@param stop LuaEntity
---@param schedule TrainSchedule Pre-existing schedule. Will be mutated by this function.
---@return boolean?
function lib.se_add_refueler_schedule(cache, train, stop, schedule)
	local t_surface = train.front_stock.surface
	local f_surface = stop.surface
	local t_surface_i = t_surface.index
	local f_surface_i = f_surface.index

	local t_zone_index, t_zone_orbit_index = lib.se_get_zone_from_surface_index(cache, t_surface_i)
	local other_zone_index, other_zone_orbit_index = lib.se_get_zone_from_surface_index(cache, f_surface_i)
	if t_zone_index and other_zone_index then
		local is_train_in_orbit = other_zone_orbit_index == t_zone_index
		if is_train_in_orbit or t_zone_orbit_index == other_zone_index then
			local elevator_name = lib.se_get_space_elevator_name(cache, t_surface)
			if elevator_name then
				local cur_order = schedule.records[i]
				local is_elevator_in_orders_already = cur_order and
						cur_order.station ==
						elevator_name .. (is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)
				if not is_elevator_in_orders_already then
					table_insert(schedule.records, i, lib.se_create_elevator_order(elevator_name, is_train_in_orbit))
				end
				i = i + 1
				is_train_in_orbit = not is_train_in_orbit
				table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))
				i = i + 1
				if not is_elevator_in_orders_already then
					table_insert(schedule.records, i, lib.se_create_elevator_order(elevator_name, is_train_in_orbit))
					i = i + 1
					is_train_in_orbit = not is_train_in_orbit
				end

				return true
			end
		end
	end
end

return lib
