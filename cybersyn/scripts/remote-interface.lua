--By Mami
local raise_event = script.raise_event
local script_generate_event_name = script.generate_event_name

------------------------------------------------------------------
--[[all events]]
------------------------------------------------------------------
--NOTE: events only start to be raised when a mod has called its associated "get" function
--NOTE: if there is a useful event missing you may submit a request for it to be added on the mod portal.

local on_combinator_changed = nil
local on_station_created = nil
local on_station_removed = nil
local on_depot_created = nil
local on_depot_removed = nil
local on_train_created = nil
local on_train_removed = nil
local on_train_available = nil
local on_train_nonempty_in_depot = nil
local on_train_dispatched = nil
local on_train_dispatch_failed = nil
local on_train_failed_delivery = nil
local on_train_completed_provide = nil
local on_train_completed_request = nil
local on_train_parked_at_depot = nil
local on_train_teleport_started = nil
local on_train_teleported = nil
local on_train_stuck = nil
local on_tick_init = nil

---@param map_data MapData
---@param entity LuaEntity
---@param old_parameters ArithmeticCombinatorParameters
function interface_raise_combinator_changed(map_data, entity, old_parameters)
	if on_combinator_changed then
		raise_event(on_combinator_changed, {
			map_data = map_data,
			entity = entity,
			old_parameters = old_parameters,
		})
	end
end

---@param map_data MapData
---@param station_id uint
function interface_raise_station_created(map_data, station_id)
	if on_station_created then
		raise_event(on_station_created, {
			map_data = map_data,
			station_id = station_id,
		})
	end
end
---@param map_data MapData
---@param old_station_id uint
---@param old_station Station
function interface_raise_station_removed(map_data, old_station_id, old_station)
	if on_station_removed then
		raise_event(on_station_removed, {
			map_data = map_data,
			old_station_id = old_station_id, --this id is now invalid
			old_station = old_station, --this is the data that used to be stored at the old id
		})
	end
end

---@param map_data MapData
---@param depot_id uint
function interface_raise_depot_created(map_data, depot_id)
	if on_depot_created then
		raise_event(on_depot_created, {
			map_data = map_data,
			depot_id = depot_id,
		})
	end
end
---@param map_data MapData
---@param old_depot_id uint
---@param old_depot Depot
function interface_raise_depot_removed(map_data, old_depot_id, old_depot)
	if on_depot_removed then
		raise_event(on_depot_removed, {
			map_data = map_data,
			old_depot_id = old_depot_id, --this id is now invalid
			old_depot = old_depot, --this is the data that used to be stored at the old id
		})
	end
end

---@param map_data MapData
---@param train_id uint
---@param depot_id uint
function interface_raise_train_created(map_data, train_id, depot_id)
	if on_train_created then
		raise_event(on_train_created, {
			map_data = map_data,
			train_id = train_id,
			depot_id = depot_id,
		})
	end
end
---@param map_data MapData
---@param old_train_id uint
---@param old_train Train
function interface_raise_train_removed(map_data, old_train_id, old_train)
	if on_train_removed then
		raise_event(on_train_removed, {
			map_data = map_data,
			old_train_id = old_train_id, --this id is now invalid
			old_train = old_train, --this is the data that used to be stored at the old id
		})
	end
end
---@param map_data MapData
---@param train_id uint
function interface_raise_train_available(map_data, train_id)
	if on_train_available then
		raise_event(on_train_available, {
			map_data = map_data,
			train_id = train_id,
		})
	end
end
---@param map_data MapData
---@param depot_id uint
---@param train_entity LuaTrain
---@param train_id uint?
function interface_raise_train_nonempty_in_depot(map_data, depot_id, train_entity, train_id)
	if on_train_nonempty_in_depot then
		raise_event(on_train_nonempty_in_depot, {
			map_data = map_data,
			train_entity = train_entity,
			train_id = train_id,
			depot_id = depot_id,
		})
	end
end

---@param map_data MapData
---@param train_id uint
function interface_raise_train_dispatched(map_data, train_id)
	if on_train_dispatched then
		raise_event(on_train_dispatched, {
			map_data = map_data,
			train_id = train_id,
		})
	end
end
---@param map_data MapData
---@param train_id uint
function interface_raise_train_dispatch_failed(map_data, train_id)
	if on_train_dispatch_failed then
		raise_event(on_train_dispatch_failed, {
			map_data = map_data,
			train_id = train_id,
		})
	end
end
---@param map_data MapData
---@param train_id uint
---@param is_p_delivery_made boolean
---@param is_r_delivery_made boolean
function interface_raise_train_failed_delivery(map_data, train_id, is_p_delivery_made, is_r_delivery_made)
	if on_train_failed_delivery then
		raise_event(on_train_failed_delivery, {
			map_data = map_data,
			train_id = train_id,
			is_p_delivery_made = is_p_delivery_made,
			is_r_delivery_made = is_r_delivery_made,
		})
	end
end
---@param map_data MapData
---@param train_id uint
function interface_raise_train_completed_provide(map_data, train_id)
	if on_train_completed_provide then
		raise_event(on_train_completed_provide, {
			map_data = map_data,
			train_id = train_id,
		})
	end
end
---@param map_data MapData
---@param train_id uint
function interface_raise_train_completed_request(map_data, train_id)
	if on_train_completed_request then
		raise_event(on_train_completed_request, {
			map_data = map_data,
			train_id = train_id,
		})
	end
end
---@param map_data MapData
---@param train_id uint
---@param depot_id uint
function interface_raise_train_parked_at_depot(map_data, train_id, depot_id)
	if on_train_parked_at_depot then
		raise_event(on_train_parked_at_depot, {
			map_data = map_data,
			train_id = train_id,
			depot_id = depot_id,
		})
	end
end
---@param map_data MapData
---@param train_id uint
function interface_raise_train_stuck(map_data, train_id)
	if on_train_stuck then
		raise_event(on_train_stuck, {
			map_data = map_data,
			train_id = train_id,
		})
	end
end
---@param map_data MapData
---@param old_train_id uint
function interface_raise_train_teleport_started(map_data, old_train_id)
	if on_train_teleport_started then
		raise_event(on_train_teleport_started, {
			map_data = map_data,
			old_train_id = old_train_id,--this id is currently valid but will become valid just before on_train_teleported is raised
		})
	end
end
---@param map_data MapData
---@param new_train_id uint
---@param old_train_id uint
function interface_raise_train_teleported(map_data, new_train_id, old_train_id)
	if on_train_teleported then
		raise_event(on_train_teleported, {
			map_data = map_data,
			new_train_id = new_train_id,--this id stores the train
			old_train_id = old_train_id,--this id is now invalid
		})
	end
end

---@param map_data MapData
function interface_raise_tick_init(map_data)
	if on_tick_init then
		raise_event(on_tick_init, {
			map_data = map_data,
		})
	end
end


local interface = {}

------------------------------------------------------------------
--[[get event id functions]]
------------------------------------------------------------------

function interface.get_on_combinator_changed()
	if not on_combinator_changed then on_combinator_changed = script_generate_event_name() end
	return on_combinator_changed
end
function interface.get_on_station_created()
	if not on_station_created then on_station_created = script_generate_event_name() end
	return on_station_created
end
function interface.get_on_station_removed()
	if not on_station_removed then on_station_removed = script_generate_event_name() end
	return on_station_removed
end
function interface.get_on_depot_created()
	if not on_depot_created then on_depot_created = script_generate_event_name() end
	return on_depot_created
end
function interface.get_on_depot_removed()
	if not on_depot_removed then on_depot_removed = script_generate_event_name() end
	return on_depot_removed
end
function interface.get_on_train_created()
	if not on_train_created then on_train_created = script_generate_event_name() end
	return on_train_created
end
function interface.get_on_train_removed()
	if not on_train_removed then on_train_removed = script_generate_event_name() end
	return on_train_removed
end
function interface.get_on_train_available()
	if not on_train_available then on_train_available = script_generate_event_name() end
	return on_train_available
end
function interface.get_on_train_nonempty_in_depot()
	if not on_train_nonempty_in_depot then on_train_nonempty_in_depot = script_generate_event_name() end
	return on_train_nonempty_in_depot
end
function interface.get_on_train_dispatched()
	if not on_train_dispatched then on_train_dispatched = script_generate_event_name() end
	return on_train_dispatched
end
function interface.get_on_train_dispatch_failed()
	if not on_train_dispatch_failed then on_train_dispatch_failed = script_generate_event_name() end
	return on_train_dispatch_failed
end
function interface.get_on_train_failed_delivery()
	if not on_train_failed_delivery then on_train_failed_delivery = script_generate_event_name() end
	return on_train_failed_delivery
end
function interface.get_on_train_completed_provide()
	if not on_train_completed_provide then on_train_completed_provide = script_generate_event_name() end
	return on_train_completed_provide
end
function interface.get_on_train_completed_request()
	if not on_train_completed_request then on_train_completed_request = script_generate_event_name() end
	return on_train_completed_request
end
function interface.get_on_train_parked_at_depot()
	if not on_train_parked_at_depot then on_train_parked_at_depot = script_generate_event_name() end
	return on_train_parked_at_depot
end
function interface.get_on_train_stuck()
	if not on_train_stuck then on_train_stuck = script_generate_event_name() end
	return on_train_stuck
end
function interface.get_on_train_teleport_started()
	if not on_train_teleport_started then on_train_teleport_started = script_generate_event_name() end
	return on_train_teleport_started
end
function interface.get_on_train_teleported()
	if not on_train_teleported then on_train_teleported = script_generate_event_name() end
	return on_train_teleported
end
function interface.get_on_tick_init()
	if not on_tick_init then on_tick_init = script_generate_event_name() end
	return on_tick_init
end


------------------------------------------------------------------
--[[internal API access]]
------------------------------------------------------------------
--NOTE: The following, while they can be called from outside the mod safely, can cause serious longterm damage if they are given bad parameters. Extercise caution.

---@param station_id Station
---@param manifest Manifest
---@param sign -1|1
function interface.remove_manifest(station_id, manifest, sign)
	local station = global.stations[station_id]
	assert(station)
	remove_manifest(global, station, manifest, sign)
end
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param primary_item_name string?
function interface.send_train_between(r_station_id, p_station_id, train_id, primary_item_name)
	local train = global.trains[train_id]
	assert(global.stations[r_station_id] and global.stations[p_station_id] and train and train.is_available)
	send_train_between(global, r_station_id, p_station_id, train_id, primary_item_name)
end
---@param train_id uint
function interface.failed_delivery(train_id)
	local train = global.trains[train_id]
	assert(train)
	on_failed_delivery(global, train_id, train)
end

---@param train_id uint
function interface.add_available_train(train_id)
	local train = global.trains[train_id]
	assert(train)
	add_available_train(global, train_id, train)
end
---@param depot_id uint
---@param train_id uint
function interface.add_available_train_to_depot(train_id, depot_id)
	local train = global.trains[train_id]
	local depot = global.depots[depot_id]
	assert(train and depot)
	add_available_train_to_depot(global, mod_settings, train_id, train, depot_id, depot)
end
---@param train_id uint
function interface.remove_available_train(train_id)
	local train = global.trains[train_id]
	assert(train)
	remove_available_train(global, train_id, train)
end
---@param comb LuaEntity
function interface.combinator_update(comb)
	combinator_update(global, comb)
end

------------------------------------------------------------------
--[[helper functions]]
------------------------------------------------------------------
--NOTE: the policy of cybersyn is to give modders access to the raw data of the mod, please either treat all tables returned from the modding interface as "read only", or if you do modify them take responsibility that your modification does not result in an error occuring in cybersyn later on.
--NOTE: the follow functions are unnecessary, the are provided more as a guide how the mod api works rather than as practical functions.

function interface.get_map_data()
	return global
end
function interface.get_mod_settings()
	return mod_settings
end
---@param id uint
function interface.get_station(id)
	return global.stations[id]
end
---@param id uint
function interface.get_depot(id)
	return global.depots[id]
end
---@param id uint
function interface.get_train(id)
	return global.trains[id]
end
---@param train_entity LuaTrain
function interface.get_train_id_from_luatrain(train_entity)
	return train_entity.id
end
---@param stop LuaEntity
function interface.get_station_or_depot_id_from_stop(stop)
	return stop.unit_number
end
---@param comb LuaEntity
function interface.get_station_or_depot_id_from_comb(comb)
	local stop = global.to_stop[comb.unit_number]
	if stop then
		return stop.unit_number
	end
end


remote.add_interface("cybersyn", interface)
