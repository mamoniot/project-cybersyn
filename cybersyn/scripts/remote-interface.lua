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
local on_refueler_created = nil
local on_refueler_removed = nil
local on_train_created = nil
local on_train_removed = nil
local on_train_available = nil
local on_train_nonempty_in_depot = nil
local on_train_dispatch_failed = nil
local on_train_failed_delivery = nil
local on_train_status_changed = nil
local on_train_stuck = nil
local on_train_teleport_started = nil
local on_train_teleported = nil
local on_tick_init = nil
local on_mod_settings_changed = nil

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
function interface.get_on_refueler_created()
	if not on_refueler_created then on_refueler_created = script_generate_event_name() end
	return on_refueler_created
end
function interface.get_on_refueler_removed()
	if not on_refueler_removed then on_refueler_removed = script_generate_event_name() end
	return on_refueler_removed
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
function interface.get_on_train_dispatch_failed()
	if not on_train_dispatch_failed then on_train_dispatch_failed = script_generate_event_name() end
	return on_train_dispatch_failed
end
function interface.get_on_train_failed_delivery()
	if not on_train_failed_delivery then on_train_failed_delivery = script_generate_event_name() end
	return on_train_failed_delivery
end
function interface.get_on_train_status_changed()
	if not on_train_status_changed then on_train_status_changed = script_generate_event_name() end
	return on_train_status_changed
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
function interface.get_on_mod_settings_changed()
	if not on_mod_settings_changed then on_mod_settings_changed = script_generate_event_name() end
	return on_mod_settings_changed
end

------------------------------------------------------------------
--[[helper functions]]
------------------------------------------------------------------
--NOTE: the policy of cybersyn is to give modders access to as much of the raw data of the mod as possible. Factorio only allows me to return copies of the original data rather than the actual thing, which sucks. The unsafe api has some tools to help you bypass this limitation.
--Some of these functions are so simplistic I'd recommend not even using them and just copy-pasting their internal code.

function interface.get_mod_settings()
	return mod_settings
end
---@param key string
function interface.read_setting(key)
	return mod_settings[key]
end
---@param ... string|int
function interface.read_global(...)
	--this can read anything off of cybersyn's map_data
	--so interface.read_global("trains", 31415, "manifest") == storage.trains[31415].manifest (or nil if train 31415 does not exist)
	--the second return value is how many parameters could be processed before a nil value was encountered (in the above example it's useful for telling apart storage.trains[31415] == nil vs storage.trains[31415].manifest == nil)
	local base = storage
	local depth = 0
	for i, v in ipairs({ ... }) do
		depth = i
		base = base[v]
		if not base then break end
	end
	return base, depth
end
---@param id uint
function interface.get_station(id)
	return storage.stations[id]
end
---@param id uint
function interface.get_depot(id)
	return storage.depots[id]
end
---@param id uint
function interface.get_refueler(id)
	return storage.refuelers[id]
end
---@param id uint
function interface.get_train(id)
	return storage.trains[id]
end
---@param train_entity LuaTrain
function interface.get_train_id_from_luatrain(train_entity)
	return train_entity.id
end
---@param stop LuaEntity
function interface.get_id_from_stop(stop)
	return stop.unit_number
end
---@param comb LuaEntity
function interface.get_id_from_comb(comb)
	local stop = storage.to_stop[comb.unit_number]
	if stop then
		return stop.unit_number
	end
end

------------------------------------------------------------------
--[[safe API]]
------------------------------------------------------------------
--NOTE: These functions can be called whenever however so long as their parameters have the correct types. Their ability to cause harm is extremely minimal.

---@param key string
---@param value any
function interface.write_setting(key, value)
	--be careful that the value you write is of the correct type specified in storage.lua
	--these settings are not saved and have to be set on load and on init
	mod_settings[key] = value
end

---@param comb LuaEntity
function interface.combinator_update(comb)
	combinator_update(storage, comb)
end

---@param train_id uint
function interface.update_train_layout(train_id)
	local train = storage.trains[train_id]
	assert(train)
	local old_layout_id = train.layout_id
	local count = storage.layout_train_count[old_layout_id]
	if count <= 1 then
		storage.layout_train_count[old_layout_id] = nil
		storage.layouts[old_layout_id] = nil
		for _, stop in pairs(storage.stations) do
			stop.accepted_layouts[old_layout_id] = nil
		end
		for _, stop in pairs(storage.refuelers) do
			stop.accepted_layouts[old_layout_id] = nil
		end
	else
		storage.layout_train_count[old_layout_id] = count - 1
	end
	set_train_layout(storage, train)
end
---@param layout_pattern (0|1|2|3)[]
---@param layout (0|1|2)[]
function interface.is_layout_accepted(layout_pattern, layout)
	return is_layout_accepted(layout_pattern, layout)
end
---@param layout_pattern (0|1|2|3)[]
---@param layout (0|1|2)[]
function interface.is_refuel_layout_accepted(layout_pattern, layout)
	return is_refuel_layout_accepted(layout_pattern, layout)
end
---@param stop_id uint
---@param forbidden_entity LuaEntity?
---@param force_update boolean?
function interface.reset_stop_layout(stop_id, forbidden_entity, force_update)
	local is_station = true
	---@type Refueler|Station
	local stop = storage.stations[stop_id]
	if not stop then
		is_station = false
		stop = storage.refuelers[stop_id]
	end
	assert(stop)
	if force_update or not stop.allows_all_trains then
		reset_stop_layout(storage, stop, is_station, forbidden_entity)
	end
end
---@param rail LuaEntity
---@param forbidden_entity LuaEntity?
---@param force_update boolean?
function interface.update_stop_from_rail(rail, forbidden_entity, force_update)
	update_stop_from_rail(storage, rail, forbidden_entity, force_update)
end

------------------------------------------------------------------
--[[unsafe API]]
------------------------------------------------------------------
--NOTE: The following functions can cause serious longterm damage to someone's world if they are given bad parameters. Please refer to storage.lua for type information. Use caution.
--If there is any useful function missing from this API I'd be happy to add it. Join the Cybersyn discord to request it be added.

---@param value any
---@param ... string|int
function interface.write_global(value, ...)
	--this can write anything into cybersyn's map_data, please be very careful with anything you write, it can cause permanent damage
	--so interface.write_global(nil, "trains", 31415, "manifest") will cause storage.trains[31415].manifest = nil (or return false if train 31415 does not exist)
	local params = { ... }
	local size = #params
	local key = params[size]
	assert(key ~= nil)
	local base = storage
	for i = 1, size - 1 do
		base = base[params[i]]
		if not base then return false end
	end
	base[key] = value
	return true
end

---@param station_id Station
---@param manifest Manifest
---@param sign -1|1
function interface.remove_manifest_from_station_deliveries(station_id, manifest, sign)
	local station = storage.stations[station_id]
	assert(station)
	return remove_manifest(storage, station, manifest, sign)
end
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
function interface.create_manifest(r_station_id, p_station_id, train_id)
	local train = storage.trains[train_id]
	assert(storage.stations[r_station_id] and storage.stations[p_station_id] and train and train.is_available)
	return create_manifest(storage, r_station_id, p_station_id, train_id)
end
---@param r_station_id uint
---@param p_station_id uint
---@param train_id uint
---@param manifest Manifest
function interface.create_delivery(r_station_id, p_station_id, train_id, manifest)
	local train = storage.trains[train_id]
	local p_station = storage.stations[r_station_id]
	local r_station = storage.stations[p_station_id]
	assert(p_station and r_station and train and train.is_available and manifest)

	local p_surface = p_station.entity_stop.surface_index
	local r_surface = r_station.entity_stop.surface_index
	local surface_connections = Surfaces.find_surface_connections(p_surface, r_surface)
	if surface_connections then
		return create_delivery(storage, r_station_id, p_station_id, train_id, manifest, surface_connections)
	end
end

---@param train_id uint
function interface.fail_delivery(train_id)
	local train = storage.trains[train_id]
	assert(train)
	return on_failed_delivery(storage, train_id, train)
end
---@param train_id uint
function interface.remove_train(train_id)
	local train = storage.trains[train_id]
	assert(train)
	return remove_train(storage, train_id, train)
end

---@param train_id uint
function interface.add_available_train(train_id)
	--This function marks a train as available but not in a depot so it can do depot bypass, be sure the train has no active deliveries before calling this
	--available trains can be chosen by the dispatcher to be rescheduled and dispatched for a new delivery
	--when this train parks at a depot add_available_train_to_depot will be called on it automatically
	local train = storage.trains[train_id]
	assert(train)
	add_available_train(storage, train_id, train)
end
---@param depot_id uint
---@param train_id uint
function interface.add_available_train_to_depot(train_id, depot_id)
	--This function marks a train as available and in a depot, be sure the train has no active deliveries before calling this
	--available trains can be chosen by the dispatcher to be rescheduled and dispatched for a new delivery
	local train = storage.trains[train_id]
	local depot = storage.depots[depot_id]
	assert(train and depot)
	return add_available_train_to_depot(storage, mod_settings, train_id, train, depot_id, depot)
end
---@param train_id uint
function interface.remove_available_train(train_id)
	--this function removes a train from the available trains list so it cannot be rescheduled and dispatched. if the train was not already available nothing will happen
	local train = storage.trains[train_id]
	assert(train)
	return remove_available_train(storage, train_id, train)
end

------------------------------------------------------------------
--[[train schedule]]
------------------------------------------------------------------

interface.create_loading_order = create_loading_order
interface.create_unloading_order = create_unloading_order
interface.create_inactivity_order = create_inactivity_order
interface.create_direct_to_station_order = create_direct_to_station_order
interface.set_depot_schedule = set_depot_schedule
interface.lock_train = lock_train
interface.rename_manifest_schedule = rename_manifest_schedule
interface.set_manifest_schedule = set_manifest_schedule
interface.add_refueler_schedule = add_refueler_schedule

------------------------------------------------------------------
--[[alerts]]
------------------------------------------------------------------

interface.send_alert_missing_train = send_alert_missing_train
interface.send_alert_unexpected_train = send_alert_unexpected_train
interface.send_alert_nonempty_train_in_depot = send_alert_nonempty_train_in_depot
interface.send_alert_stuck_train = send_alert_stuck_train
interface.send_alert_cannot_path_between_surfaces = send_alert_cannot_path_between_surfaces
interface.send_alert_depot_of_train_broken = send_alert_depot_of_train_broken
interface.send_alert_refueler_of_train_broken = send_alert_refueler_of_train_broken
interface.send_alert_station_of_train_broken = send_alert_station_of_train_broken
interface.send_alert_train_at_incorrect_station = send_alert_train_at_incorrect_station

remote.add_interface("cybersyn", interface)

------------------------------------------------------------------
--[[internal event calls]]
------------------------------------------------------------------

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
			old_station = old_station,    --this is the data that used to be stored at the old id
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
			old_depot = old_depot,    --this is the data that used to be stored at the old id
		})
	end
end

---@param refueler_id uint
function interface_raise_refueler_created(refueler_id)
	if on_refueler_created then
		raise_event(on_refueler_created, {
			refueler_id = refueler_id,
		})
	end
end
---@param old_refueler_id uint
---@param old_refueler Refueler
function interface_raise_refueler_removed(old_refueler_id, old_refueler)
	if on_refueler_removed then
		raise_event(on_refueler_removed, {
			old_refueler_id = old_refueler_id, --this id is now invalid
			old_refueler = old_refueler,    --this is the data that used to be stored at the old id
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
			old_train = old_train,    --this is the data that used to be stored at the old id
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
function interface_raise_train_failed_delivery(
		train_id,
		was_p_in_progress,
		p_station_id,
		was_r_in_progress,
		r_station_id,
		manifest)
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
---@param old_status uint
---@param new_status uint
function interface_raise_train_status_changed(train_id, old_status, new_status)
	if on_train_status_changed then
		raise_event(on_train_status_changed, {
			train_id = train_id,
			old_status = old_status,
			new_status = new_status,
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
			old_train_id = old_train_id, --this id is currently valid but will become invalid just before on_train_teleported is raised
		})
	end
end
---@param new_train_id uint
---@param old_train_id uint
function interface_raise_train_teleported(new_train_id, old_train_id)
	if on_train_teleported then
		raise_event(on_train_teleported, {
			new_train_id = new_train_id, --this id stores the train
			old_train_id = old_train_id, --this id is now invalid
		})
	end
end

function interface_raise_tick_init()
	if on_tick_init then
		raise_event(on_tick_init, {
		})
	end
end
function interface_raise_on_mod_settings_changed(e)
	if on_mod_settings_changed then
		raise_event(on_mod_settings_changed, e)
	end
end
