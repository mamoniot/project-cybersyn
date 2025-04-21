-- Code related to Space Exploration compatibility.

SE_ELEVATOR_STOP_PROTO_NAME = "se-space-elevator-train-stop"
SE_ELEVATOR_ORBIT_SUFFIX = " ↓"
SE_ELEVATOR_PLANET_SUFFIX = " ↑"
SE_ELEVATOR_SUFFIX_LENGTH = #SE_ELEVATOR_ORBIT_SUFFIX
SE_ELEVATOR_PREFIX = "[img=entity/se-space-elevator]  "
SE_ELEVATOR_PREFIX_LENGTH = #SE_ELEVATOR_PREFIX

local table_insert = table.insert
local string_sub = string.sub
local string_len = string.len

---@param record ScheduleRecord|AddRecordData
---@return string? elevator_stop_name
---@return boolean? is_ground_to_orbit
local function se_is_elevator_schedule_record(record)
	local name = record.station
	if not name then return end

	local prefix = string_sub(name, 1, SE_ELEVATOR_PREFIX_LENGTH)
	if prefix == SE_ELEVATOR_PREFIX then
		local suffix = string_sub(name, -SE_ELEVATOR_SUFFIX_LENGTH)
		if suffix == SE_ELEVATOR_ORBIT_SUFFIX then
			return name, false
		elseif suffix == SE_ELEVATOR_PLANET_SUFFIX then
			return name, true
		end
	end
end

local lib = {}

---@param map_data MapData
---@param train Train
---@param schedule LuaSchedule
---@param found_cybersyn_stop ScheduleSearchResult
---@param schedule_offset integer keeps track of modifications to the actual schedule since found_cybersyn_stop was determined
---@return integer updated_schedule_offset
local function se_add_direct_to_station_order(map_data, train, schedule, found_cybersyn_stop, schedule_offset)
	if found_cybersyn_stop.rail_stop then
		return schedule_offset -- already has a rail stop
	end

	local station = nil
	if found_cybersyn_stop.stop_type == STATUS_P and train.p_station_id == found_cybersyn_stop.stop_id then
		station = map_data.stations[train.p_station_id]
	elseif found_cybersyn_stop.stop_type == STATUS_R and train.r_station_id == found_cybersyn_stop.stop_id then
		station = map_data.stations[train.r_station_id]
	elseif found_cybersyn_stop.stop_type == STATUS_F and train.refueler_id == found_cybersyn_stop.stop_id then
		station = map_data.refuelers[train.refueler_id]
	-- Depot records are permanent records at the end of the schedule and are possibly shared by a train group.
	-- As a consequence they cannot have any identifying information on them.
	-- We have to blindly assume that whatever is in the schedule matches with train.depot_id
	elseif found_cybersyn_stop.stop_type == STATUS_D and not train.use_any_depot then
		station = map_data.depots[train.depot_id]
	end

	local stop = station and station.entity_stop
	if not (stop and stop.valid and stop.connected_rail) then
		-- TODO the destination is gone, should the train be stopped? But that would clog the elevator the train just exited.
		return schedule_offset
	end

	local real_index = found_cybersyn_stop.schedule_index + schedule_offset
	local is_current_destination = schedule.current == real_index
	local direct_to_station = create_direct_to_station_order(stop)
	direct_to_station.index = { schedule_index = real_index }
	schedule.add_record(direct_to_station)
	if is_current_destination then
		schedule.go_to_station(real_index)
	end
	return schedule_offset + 1
end

---@param map_data MapData
---@param train Train
local function se_add_direct_to_station_orders(map_data, train)
	-- schedule records can only contain references to rail entities on the same surface as the train
	-- this is why after every surface teleport we need to add the ones that could not be added earlier
	local schedule = train.entity.get_schedule()
	local records = assert(schedule.get_records())
	---@type ScheduleSearchOptions
	local options = {
		search_index = schedule.current,
		abort_condition = se_is_elevator_schedule_record, -- stop at the next elevator transition
		include_depot = true,
	}

	local found_cybersyn_stop = find_next_cybersyn_stop(records, options)
	local schedule_offset = 0 -- we search through the initial snapshot of the schedule so we need to keep track of additions to it

	while found_cybersyn_stop do
		schedule_offset = se_add_direct_to_station_order(map_data, train, schedule, found_cybersyn_stop, schedule_offset)
		options.search_index = found_cybersyn_stop.schedule_index + 1
		found_cybersyn_stop = find_next_cybersyn_stop(records, options)
	end
end

local function se_on_train_teleport_started(event)
	---@type MapData
	local map_data = storage
	local old_id = event.old_train_id_1

	local train = map_data.trains[old_id]
	if not train then return end
	-- NOTE: IMPORTANT, until se_on_train_teleport_finished_event is called map_data.trains[old_id] will reference an invalid train entity
	-- our events have either been set up to account for this or should be impossible to trigger until teleportation is finished
	train.se_is_being_teleported = true
	interface_raise_train_teleport_started(old_id)
end

local function se_on_train_teleport_finished(event)
	---@type MapData
	local map_data = storage
	---@type LuaTrain
	local train_entity = event.train
	---@type uint
	local new_id = train_entity.id

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

	se_add_direct_to_station_orders(map_data, train)
	interface_raise_train_teleported(new_id, old_id)
end

function lib.setup_se_compat()
	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
	if not IS_SE_PRESENT then return end

	script.on_event(remote.call("space-exploration", "get_on_train_teleport_finished_event"), se_on_train_teleport_finished)
	script.on_event(remote.call("space-exploration", "get_on_train_teleport_started_event"), se_on_train_teleport_started)
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

---@param target { network_masks : { [string] : integer }? }
---@param network_masks { [string] : integer }?
function has_network_match(target, network_masks)
	local target_masks = target and target.network_masks
	if not (target_masks and network_masks) then return true end

	for network, mask in pairs(network_masks) do
		if bit32.btest(target_masks[network] or 0, mask) then return true end
	end
	return false
end

---@param surface_connections Cybersyn.SurfaceConnection[]
---@param network_masks { [string] : integer }?
---@return Cybersyn.ElevatorData[]?
local function se_get_elevators(surface_connections, network_masks)
	local elevators, i = {}, 0
	for _, connection in pairs(surface_connections) do
		if connection.entity1.name == Elevators.name_stop then
			local elevator = Elevators.from_unit_number(connection.entity1.unit_number)
			if elevator and has_network_match(elevator, network_masks) then
				i = i + 1
				elevators[i] = elevator
			end
		end
	end
	return i > 0 and elevators or nil
end

---@param elevator_name string
---@param is_train_in_orbit boolean
---@return AddRecordData
function lib.se_create_elevator_order(elevator_name, is_train_in_orbit)
	return {
		station = elevator_name .. (is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX),
		temporary = true,
	}
end

---Creates a schedule record for the elevator that is closest to the given entity
---@param elevators Cybersyn.ElevatorData[] must be elevators on the surface of the given entity
---@param from LuaEntity
---@return AddRecordData?
local function se_create_closest_elevator_travel(elevators, from)
	local closest, elevator_stop = 2100000000, nil
	local f_surface = from.surface_index

	for _, elevator in ipairs(elevators) do
		local stop = elevator[f_surface].stop
		local dist = get_dist(from, stop)
		if dist < closest then
			elevator_stop = stop
		end
	end

	assert(elevator_stop, "travel_data had no elevators")
	return {
		station = elevator_stop.backer_name,
		temporary = true,
	}
end

---@class ScheduleBuilder : Class
---@field public records AddRecordData[]
---@field private i integer
---@field private same_surface boolean
local ScheduleBuilder = Class:derive()

---@protected
function ScheduleBuilder:new()
	local instance = self:derive(Class:new())
	instance.records = {}
	instance.i = 0
	instance.same_surface = true
	return instance
end

---Adds the given record.
---@param record AddRecordData? nil values are skipped
function ScheduleBuilder:add(record)
	if record then
		local i = self.i + 1
		self.records[i] = record
		self.i = i
	end
end

---Adds the given record and prevents further direct_to_stop records.
---@param record AddRecordData? nil values are skipped and dont prevent further direct_to_station records
function ScheduleBuilder:add_surface_travel(record)
	if record then
		local i = self.i + 1
		self.records[i] = record
		self.i = i
		self.same_surface = false
	end
end

---Adds a temporary rail record for the given train stop if there was no previous surface travel.
---@param stop LuaEntity? invalid stops are skipped
function ScheduleBuilder:add_direct_to_stop(stop)
	if self.same_surface and stop and stop.valid then
		local i = self.i + 1
		self.records[i] = create_direct_to_station_order(stop)
		self.i = i
	end
end

---@class SeScheduleBuilder : ScheduleBuilder
---@field private elevators Cybersyn.ElevatorData[]
local SeScheduleBuilder = ScheduleBuilder:derive()

---@protected
---@param elevators Cybersyn.ElevatorData[]
function SeScheduleBuilder:new(elevators)
	local instance = self:derive(ScheduleBuilder:new())
	instance.elevators = elevators
	return instance
end

---@param surface_from uint
---@param surface_to uint
---@param from LuaEntity
function SeScheduleBuilder:add_elevator_if_necessary(surface_from, surface_to, from)
	if surface_from ~= surface_to then
		self:add_surface_travel(se_create_closest_elevator_travel(self.elevators, from))
		-- TODO se-ltn-glue has the option to add an additional clearance station that mitigates "destination limit stutter". Still needed with SE >= 0.7.13 / Factorio >= 2.0.45?
	end
end

---@param train LuaTrain
---@param depot_stop LuaEntity
---@param same_depot boolean
---@param p_stop LuaEntity
---@param p_schedule_settings Cybersyn.StationScheduleSettings
---@param r_stop LuaEntity
---@param r_schedule_settings Cybersyn.StationScheduleSettings
---@param manifest Manifest
---@param surface_connections Cybersyn.SurfaceConnection[]
---@param start_at_depot boolean?
---@return (ScheduleRecord[])?
function lib.se_set_manifest_schedule(
		train,
		depot_stop,
		same_depot,
		p_stop,
		p_schedule_settings,
		r_stop,
		r_schedule_settings,
		manifest,
		surface_connections,
		start_at_depot)

	local t_entity = train.front_stock
	if not t_entity then return end

	local elevators = se_get_elevators(surface_connections)
	if not elevators then return end -- surface_connections contained no elevators

	local d_surface = depot_stop.surface_index
	local t_surface = t_entity.surface_index
	local p_surface = p_stop.surface_index
	local r_surface = r_stop.surface_index

	assert( -- tick_dispatch must discard this scenario
		(t_surface == r_surface or t_surface == p_surface) and
		(d_surface == r_surface or d_surface == p_surface),
		"invalid surface travel, trains can only travel to surfaces adjacent to their home surface")

	local builder = SeScheduleBuilder:new(elevators)

	builder:add_elevator_if_necessary(t_surface, p_surface, t_entity)
	builder:add_direct_to_stop(p_stop)
	builder:add(create_loading_order(p_stop, manifest, p_schedule_settings, true))

	builder:add_elevator_if_necessary(p_surface, r_surface, p_stop)
	builder:add_direct_to_stop(r_stop)
	builder:add(create_unloading_order(r_stop, r_schedule_settings, true))

	builder:add_elevator_if_necessary(r_surface, d_surface, r_stop)
	builder:add_direct_to_stop(same_depot and depot_stop or nil)

	return builder.records
end

---@param cache PerfCache
---@param train LuaTrain
---@param stop LuaEntity
---@param schedule LuaSchedule Pre-existing schedule. Will be mutated by this function.
---@return boolean?
function lib.se_add_refueler_schedule(cache, train, stop, schedule)
	local t_surface = train.front_stock.surface
	local f_surface = stop.surface
	local t_surface_i = t_surface.index
	local f_surface_i = f_surface.index

	-- FIXME i is not defined anymore, this lost context when the code got moved to a separate module

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
