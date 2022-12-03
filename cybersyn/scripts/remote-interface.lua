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
local on_train_stuck = nil
local on_train_teleport_started = nil
local on_train_teleported = nil
local on_tick_init = nil

---@param entity LuaEntity
---@param old_parameters ArithmeticCombinatorParameters
function interface_raise_combinator_changed(entity, old_parameters)
	if on_combinator_changed then
		raise_event(on_combinator_changed, {
			entity = entity,
			old_parameters = old_parameters,
		})
	end
end

---@param station_id uint
function interface_raise_station_created(station_id)
	if on_station_created then
		raise_event(on_station_created, {
			station_id = station_id,
		})
	end
end
---@param old_station_id uint
---@param old_station Station
function interface_raise_station_removed(old_station_id, old_station)
	if on_station_removed then
		raise_event(on_station_removed, {
			old_station_id = old_station_id, --this id is now invalid
			old_station = old_station, --this is the data that used to be stored at the old id
		})
	end
end

---@param depot_id uint
function interface_raise_depot_created(depot_id)
	if on_depot_created then
		raise_event(on_depot_created, {
			depot_id = depot_id,
		})
	end
end
---@param old_depot_id uint
---@param old_depot Depot
function interface_raise_depot_removed(old_depot_id, old_depot)
	if on_depot_removed then
		raise_event(on_depot_removed, {
			old_depot_id = old_depot_id, --this id is now invalid
			old_depot = old_depot, --this is the data that used to be stored at the old id
		})
	end
end

---@param train_id uint
---@param depot_id uint
function interface_raise_train_created(train_id, depot_id)
	if on_train_created then
		raise_event(on_train_created, {
			train_id = train_id,
			depot_id = depot_id,
		})
	end
end
---@param old_train_id uint
---@param old_train Train
function interface_raise_train_removed(old_train_id, old_train)
	if on_train_removed then
		raise_event(on_train_removed, {
			old_train_id = old_train_id, --this id is now invalid
			old_train = old_train, --this is the data that used to be stored at the old id
		})
	end
end
---@param train_id uint
function interface_raise_train_available(train_id)
	if on_train_available then
		raise_event(on_train_available, {
			train_id = train_id,
		})
	end
end
---@param depot_id uint
---@param train_entity LuaTrain
---@param train_id uint?
function interface_raise_train_nonempty_in_depot(depot_id, train_entity, train_id)
	if on_train_nonempty_in_depot then
		raise_event(on_train_nonempty_in_depot, {
			train_entity = train_entity,
			train_id = train_id,
			depot_id = depot_id,
		})
	end
end

---@param train_id uint
function interface_raise_train_dispatched(train_id)
	if on_train_dispatched then
		raise_event(on_train_dispatched, {
			train_id = train_id,
		})
	end
end
---@param train_id uint
function interface_raise_train_dispatch_failed(train_id)
	--this event is rare, it can only occur when a train is bypassing the depot and can't find a path to the provide station, that train is marked as unavailable but not dispatched
	if on_train_dispatch_failed then
		raise_event(on_train_dispatch_failed, {
			train_id = train_id,
		})
	end
end
---@param train_id uint
---@param was_p_in_progress boolean
---@param p_station_id uint
---@param was_r_in_progress boolean
---@param r_station_id uint
---@param manifest Manifest
function interface_raise_train_failed_delivery(train_id, was_p_in_progress, p_station_id, was_r_in_progress, r_station_id, manifest)
	if on_train_failed_delivery then
		raise_event(on_train_failed_delivery, {
			train_id = train_id,
			was_p_in_progress = was_p_in_progress,
			p_station_id = p_station_id,
			was_r_in_progress = was_r_in_progress,
			r_station_id = r_station_id,
			manifest = manifest,
		})
	end
end
---@param train_id uint
function interface_raise_train_completed_provide(train_id)
	if on_train_completed_provide then
		raise_event(on_train_completed_provide, {
			train_id = train_id,
		})
	end
end
---@param train_id uint
function interface_raise_train_completed_request(train_id)
	if on_train_completed_request then
		raise_event(on_train_completed_request, {
			train_id = train_id,
		})
	end
end
---@param train_id uint
---@param depot_id uint
function interface_raise_train_parked_at_depot(train_id, depot_id)
	if on_train_parked_at_depot then
		raise_event(on_train_parked_at_depot, {
			train_id = train_id,
			depot_id = depot_id,
		})
	end
end
---@param train_id uint
function interface_raise_train_stuck(train_id)
	if on_train_stuck then
		raise_event(on_train_stuck, {
			train_id = train_id,
		})
	end
end
---@param old_train_id uint
function interface_raise_train_teleport_started(old_train_id)
	if on_train_teleport_started then
		raise_event(on_train_teleport_started, {
			old_train_id = old_train_id,--this id is currently valid but will become valid just before on_train_teleported is raised
		})
	end
end
---@param new_train_id uint
---@param old_train_id uint
function interface_raise_train_teleported(new_train_id, old_train_id)
	if on_train_teleported then
		raise_event(on_train_teleported, {
			new_train_id = new_train_id,--this id stores the train
			old_train_id = old_train_id,--this id is now invalid
		})
	end
end

function interface_raise_tick_init()
	if on_tick_init then
		raise_event(on_tick_init, {
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
--[[safe API]]
------------------------------------------------------------------
--NOTE: These functions can be called whenever however so long as their parameters have the correct types. Their ability to cause harm is extremely minimal.

---@param comb LuaEntity
function interface.combinator_update(comb)
	combinator_update(global, comb)
end

---@param train_id uint
function interface.update_train_layout(train_id)
	local train = global.trains[train_id]
	assert(train)
	local old_layout_id = train.layout_id
	local count = global.layout_train_count[old_layout_id]
	if count <= 1 then
		global.layout_train_count[old_layout_id] = nil
		global.layouts[old_layout_id] = nil
		for station_id, station in pairs(global.stations) do
			station.accepted_layouts[old_layout_id] = nil
		end
	else
		global.layout_train_count[old_layout_id] = count - 1
	end
	set_train_layout(global, train)
end
---@param layout_pattern (0|1|2|3)[]
---@param layout (0|1|2)[]
function interface.is_layout_accepted(layout_pattern, layout)
	return is_layout_accepted(layout_pattern, layout)
end
---@param station_id uint
---@param forbidden_entity LuaEntity?
---@param force_update boolean?
function interface.reset_station_layout(station_id, forbidden_entity, force_update)
	local station = global.stations[station_id]
	assert(station)
	if force_update or not station.allows_all_trains then
		reset_station_layout(global, station, forbidden_entity)
	end
end
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
---@param force_update boolean?
function interface.update_station_from_rail(rail, forbidden_entity, force_update)
	update_station_from_rail(global, rail, forbidden_entity, force_update)
end

------------------------------------------------------------------
--[[unsafe API]]
------------------------------------------------------------------
--NOTE: The following functions can cause serious longterm damage to someone's world if they are given bad parameters. Use caution.

---@param station_id Station
---@param manifest Manifest
---@param sign -1|1
function interface.remove_manifest_from_station_deliveries(station_id, manifest, sign)
	local station = global.stations[station_id]
	assert(station)
	remove_manifest(global, station, manifest, sign)
end
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param primary_item_name string?
function interface.create_new_delivery_between_stations(r_station_id, p_station_id, train_id, primary_item_name)
	local train = global.trains[train_id]
	assert(global.stations[r_station_id] and global.stations[p_station_id] and train and train.is_available)
	send_train_between(global, r_station_id, p_station_id, train_id, primary_item_name)
end
---@param train_id uint
function interface.fail_delivery(train_id)
	local train = global.trains[train_id]
	assert(train)
	on_failed_delivery(global, train_id, train)
end
---@param train_id uint
function interface.remove_train(train_id)
	local train = global.trains[train_id]
	assert(train)
	remove_train(global, train_id, train)
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


------------------------------------------------------------------
--[[alerts]]
------------------------------------------------------------------

interface.send_missing_train_alert = send_missing_train_alert
interface.send_lost_train_alert = send_lost_train_alert
interface.send_unexpected_train_alert = send_unexpected_train_alert
interface.send_nonempty_train_in_depot_alert = send_nonempty_train_in_depot_alert
interface.send_stuck_train_alert = send_stuck_train_alert

------------------------------------------------------------------
--[[helper functions]]
------------------------------------------------------------------
--NOTE: the policy of cybersyn is to give modders access to the raw data of the mod, please either treat all tables returned from the modding interface as "read only", or if you do modify them take responsibility that your modification does not result in an error occuring in cybersyn later on.
--NOTE: the follow functions aren't strictly necessary; they are provided more as a guide how the mod api works rather than as practical functions.

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
