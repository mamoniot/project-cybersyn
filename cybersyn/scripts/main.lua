--By Mami
local manager = require("gui.main")
local picker_dollies_compat = require("scripts.mod-compatibility.picker-dollies")
local se_compat = require("scripts.mod-compatibility.space-exploration")

local ceil = math.ceil
local table_insert = table.insert
local table_remove = table.remove

---@param map_data MapData
---@param stop LuaEntity
---@param comb LuaEntity
local function on_depot_built(map_data, stop, comb)
	--NOTE: only place where new Depot
	local depot = {
		entity_stop = stop,
		entity_comb = comb,
		available_train_id = nil,
	}
	local depot_id = stop.unit_number --[[@as uint]]
	map_data.depots[depot_id] = depot
	interface_raise_depot_created(depot_id)
end

---@param map_data MapData
---@param depot_id uint
---@param depot Depot
function on_depot_broken(map_data, depot_id, depot)
	for train_id, train in pairs(map_data.trains) do
		if train.depot_id == depot_id then
			if train.use_any_depot then
				local e = get_any_train_entity(train.entity)
				if e then
					--local stops = e.force.get_train_stops({name = depot.entity_stop.backer_name, surface = e.surface})
					local stops = game.train_manager.get_train_stops({
						station_name = depot.entity_stop.backer_name,
						force = e.force,
					})
					--game.print(serpent.block(stops))
					for stop in rnext_consume, stops do
						local new_depot_id = stop.unit_number
						if new_depot_id ~= depot_id and map_data.depots[new_depot_id] then
							train.depot_id = new_depot_id --[[@as uint]]
							goto continue
						end
					end
				end
			end
			lock_train(train.entity)
			send_alert_depot_of_train_broken(map_data, train.entity)
			remove_train(map_data, train_id, train)
		end
		::continue::
	end
	map_data.depots[depot_id] = nil
	interface_raise_depot_removed(depot_id, depot)
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb LuaEntity
local function on_refueler_built(map_data, stop, comb)
	--NOTE: only place where new Depot
	local refueler = {
		entity_stop = stop,
		entity_comb = comb,
		trains_total = 0,
		accepted_layouts = {},
		layout_pattern = {},
		--allows_all_trains = set_refueler_from_comb,
		--priority = set_refueler_from_comb,
		--network_name = set_refueler_from_comb,
		--network_mask = set_refueler_from_comb,
	}
	local id = stop.unit_number --[[@as uint]]
	map_data.refuelers[id] = refueler
	set_refueler_from_comb(map_data, mod_settings, id, refueler)
	update_stop_if_auto(map_data, refueler, false)
	interface_raise_refueler_created(id)
end
---@param map_data MapData
---@param refueler_id uint
---@param refueler Refueler
function on_refueler_broken(map_data, refueler_id, refueler)
	if refueler.trains_total > 0 then
		--search for trains coming to the destroyed refueler
		for train_id, train in pairs(map_data.trains) do
			local is_f = train.refueler_id == refueler_id
			if is_f then
				if not train.se_is_being_teleported then
					remove_train(map_data, train_id, train)
					lock_train(train.entity)
					send_alert_refueler_of_train_broken(map_data, train.entity)
				else
					train.se_awaiting_removal = train_id
				end
			end
		end
	end
	local f, a
	if refueler.network_name == NETWORK_EACH then
		f, a = pairs(refueler.network_mask --[[@as {[string]: int}]])
	else
		f, a = once, refueler.network_name
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if network then
			network[refueler_id] = nil
			if next(network) == nil then
				map_data.to_refuelers[network_name] = nil
			end
		end
	end
	map_data.each_refuelers[refueler_id] = nil
	map_data.refuelers[refueler_id] = nil
	interface_raise_refueler_removed(refueler_id, refueler)
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb1 LuaEntity
---@param comb2 LuaEntity?
local function on_station_built(map_data, stop, comb1, comb2)
	--NOTE: only place where new Station
	local station = {
		entity_stop = stop,
		entity_comb1 = comb1,
		entity_comb2 = comb2,
		--is_p = set_station_from_comb,
		--is_r = set_station_from_comb,
		--allows_all_trains = set_station_from_comb,
		deliveries_total = 0,
		last_delivery_tick = map_data.total_ticks,
		trains_limit = math.huge,
		priority = 0,
		item_priotity = nil,
		r_threshold = 0,
		locked_slots = 0,
		--network_name = set_station_from_comb,
		network_mask = 0,
		wagon_combs = nil,
		deliveries = {},
		accepted_layouts = {},
		layout_pattern = nil,
		tick_signals = nil,
		item_p_counts = {},
		item_thresholds = nil,
		display_state = 0,
		is_warming_up = true,
	}
	local id = stop.unit_number --[[@as uint]]

	map_data.stations[id] = station

	--prevent the same station from warming up multiple times
	if map_data.warmup_station_cycles[id] then
		--enforce FIFO
		for i, v in ipairs(map_data.warmup_station_ids) do
			if v == id then
				table_remove(map_data.warmup_station_ids, i)
				break
			end
		end
	end
	map_data.warmup_station_ids[#map_data.warmup_station_ids + 1] = id
	map_data.warmup_station_cycles[id] = 0

	queue_station_for_combinator_update(map_data, id)
	update_stop_if_auto(map_data, station, true)
	interface_raise_station_created(id)
end
---@param map_data MapData
---@param station_id uint
---@param station Station
function on_station_broken(map_data, station_id, station)
	if station.deliveries_total > 0 then
		--search for trains coming to the destroyed station
		for train_id, train in pairs(map_data.trains) do
			local is_r = train.r_station_id == station_id
			local is_p = train.p_station_id == station_id
			if is_p or is_r then
				local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
				local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
				if (is_p and is_p_in_progress) or (is_r and is_r_in_progress) then
					--train is attempting delivery to a stop that was destroyed, stop it
					if not train.se_is_being_teleported then
						remove_train(map_data, train_id, train)
						lock_train(train.entity)
						send_alert_station_of_train_broken(map_data, train.entity)
					else
						train.se_awaiting_removal = train_id
					end
				end
			end
		end
	end
	map_data.stations[station_id] = nil
	interface_raise_station_removed(station_id, station)
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb_operation string
---@param comb_forbidden LuaEntity?
local function search_for_station_combinator(map_data, stop, comb_operation, comb_forbidden)
	local pos_x = stop.position.x
	local pos_y = stop.position.y
	local search_area = {
		{ pos_x - 2, pos_y - 2 },
		{ pos_x + 2, pos_y + 2 },
	}
	local entities = stop.surface.find_entities_filtered({ area = search_area, name = COMBINATOR_NAME })
	for _, entity in pairs(entities) do
		if entity.valid and entity ~= comb_forbidden and map_data.to_stop[entity.unit_number] == stop then
			local param = get_comb_params(entity)
			if param.operation == comb_operation then
				return entity
			end
		end
	end
end

---@param map_data MapData
---@param comb LuaEntity
---@param tags Tags?
---@return string? op
function combinator_build_init(map_data, comb, tags)
	local control = get_comb_control(comb)
	local params = control.parameters
	local op = params.operation

	if op == MODE_DEFAULT then
		op = MODE_PRIMARY_IO
		params.operation = op
		params.first_signal = NETWORK_SIGNAL_DEFAULT
		control.parameters = params
	elseif op ~= MODE_PRIMARY_IO and op ~= MODE_SECONDARY_IO and op ~= MODE_DEPOT and op ~= MODE_REFUELER and op ~= MODE_WAGON then
		op = MODE_PRIMARY_IO
		params.operation = op
		control.parameters = params
	end

	local unit_number = comb.unit_number --[[@as uint]]

	if tags and tags.ghost_unit_number then
		local old_unit_number = tags.ghost_unit_number
		map_data.to_comb[old_unit_number] = nil
		map_data.to_comb_params[old_unit_number] = nil
	end

	map_data.to_comb[unit_number] = comb
	map_data.to_comb_params[unit_number] = params

	return op
end

---@param map_data MapData
---@param comb LuaEntity
---@param tags Tags?
local function on_combinator_built(map_data, comb, tags)
	local pos_x = comb.position.x
	local pos_y = comb.position.y

	if tags and tags.ghost_unit_number then
		gui_entity_destroyed(tags.ghost_unit_number --[[@as integer]], true)
	end

	local search_area
	if comb.direction == defines.direction.north or comb.direction == defines.direction.south then
		search_area = {
			{ pos_x - 1.5, pos_y - 2 },
			{ pos_x + 1.5, pos_y + 2 },
		}
	else
		search_area = {
			{ pos_x - 2, pos_y - 1.5 },
			{ pos_x + 2, pos_y + 1.5 },
		}
	end
	local stop = nil
	local rail = nil
	local entities = comb.surface.find_entities_filtered({ area = search_area, name = { "train-stop", "straight-rail" } })
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
		force = comb.force,
	})
	assert(out, "cybersyn: could not spawn combinator controller")
	local comb_red = comb.get_wire_connector(defines.wire_connector_id.combinator_output_red, true)
	local out_red = out.get_wire_connector(defines.wire_connector_id.circuit_red, true)
	out_red.connect_to(comb_red, false, defines.wire_origin.script)

	local comb_green = comb.get_wire_connector(defines.wire_connector_id.combinator_output_green, true)
	local out_green = out.get_wire_connector(defines.wire_connector_id.circuit_green, true)
	out_green.connect_to(comb_green, false, defines.wire_origin.script)

	local op = combinator_build_init(map_data, comb, tags)

	local unit_number = comb.unit_number --[[@as uint]]
	map_data.to_output[unit_number] = out
	map_data.to_stop[unit_number] = stop

	if op == MODE_WAGON then
		if rail then
			update_stop_from_rail(map_data, rail, nil, true)
		end
	elseif stop then
		local id = stop.unit_number --[[@as uint]]
		local station = map_data.stations[id]
		local depot = map_data.depots[id]
		local refueler = map_data.refuelers[id]
		if op == MODE_DEPOT then
			if refueler then
				on_refueler_broken(map_data, id, refueler)
			end
			if not station and not depot then
				on_depot_built(map_data, stop, comb)
			end
		elseif op == MODE_REFUELER then
			if not station and not depot and not refueler then
				on_refueler_built(map_data, stop, comb)
			end
		elseif op == MODE_SECONDARY_IO then
			if station and not station.entity_comb2 then
				station.entity_comb2 = comb
				queue_station_for_combinator_update(map_data, id)
			end
		elseif op == MODE_PRIMARY_IO then
			if refueler then
				on_refueler_broken(map_data, id, refueler)
			end
			if depot then
				on_depot_broken(map_data, id, depot)
			end
			if not station then
				local comb2 = search_for_station_combinator(map_data, stop, MODE_SECONDARY_IO, comb)
				on_station_built(map_data, stop, comb, comb2)
			end
		end
	end
end


---@param map_data MapData
---@param comb LuaEntity
local function on_combinator_ghost_built(map_data, comb)
	combinator_build_init(map_data, comb)
	comb.tags = { ghost_unit_number = comb.unit_number }
end

---@param map_data MapData
---@param comb LuaEntity
---@param unit_number uint
---@return uint, uint, Station|Depot|Refueler|nil, LuaEntity?
--Returns the internal entity associated with the given combinator, if one exists.
--`unit_number` must be equal to `comb.unit_number`.
--Returns 1 if `comb` is `entity_comb1` of a station.
--Returns 2 if `comb` is `entity_comb2` of a station.
--Returns 3 if `comb` defines a depot.
--Returns 4 if `comb` defines a refueler.
--Returns 0 if `comb` is not a core component of any entity.
local function comb_to_internal_entity(map_data, comb, unit_number)
	local stop = map_data.to_stop[unit_number]
	if stop and stop.valid then
		local id = stop.unit_number --[[@as uint]]
		local station = map_data.stations[id]
		if station then
			if station.entity_comb1 == comb then
				return 1, id, station, stop
			elseif station.entity_comb2 == comb then
				return 2, id, station, stop
			end
		else
			local depot = map_data.depots[id]
			if depot then
				if depot.entity_comb == comb then
					return 3, id, depot, stop
				end
			else
				local refueler = map_data.refuelers[id]
				if refueler then
					if refueler.entity_comb == comb then
						return 4, id, refueler, stop
					end
				end
			end
		end
	end
	return 0, 0, nil, nil
end

--- Queue a station's internal state to be updated from combinator data on
--- next logistics loop.
---@param map_data MapData
---@param station_id integer
function queue_station_for_combinator_update(map_data, station_id)
	if not map_data.queue_station_update then
		map_data.queue_station_update = {}
	end
	map_data.queue_station_update[station_id] = true
end

---@param map_data MapData
---@param comb LuaEntity
---@param skip_gui_events boolean?
function on_combinator_broken(map_data, comb, skip_gui_events)
	--NOTE: we do not check for wagon manifest combinators and update their stations, it is assumed they will be lazy deleted later
	---@type uint
	local comb_id = comb.unit_number

	if not skip_gui_events then
		gui_entity_destroyed(comb_id, false)
	end

	local out = map_data.to_output[comb_id]

	local type, id, entity, stop = comb_to_internal_entity(map_data, comb, comb_id)
	if type == 1 then
		on_station_broken(map_data, id, entity --[[@as Station]])
		on_stop_built_or_updated(map_data, stop --[[@as LuaEntity]], comb)
	elseif type == 2 then
		local station = entity --[[@as Station]]
		station.entity_comb2 = search_for_station_combinator(map_data, stop --[[@as LuaEntity]], MODE_SECONDARY_IO, comb)
		queue_station_for_combinator_update(map_data, id)
	elseif type == 3 then
		on_depot_broken(map_data, id, entity --[[@as Depot]])
		on_stop_built_or_updated(map_data, stop --[[@as LuaEntity]], comb)
	elseif type == 4 then
		on_refueler_broken(map_data, id, entity --[[@as Refueler]])
		on_stop_built_or_updated(map_data, stop --[[@as LuaEntity]], comb)
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
---@param skip_gui_events boolean?
function on_combinator_ghost_broken(map_data, comb, skip_gui_events)
	---@type uint
	local comb_id = comb.unit_number

	if not skip_gui_events then
		gui_entity_destroyed(comb_id, true)
	end

	map_data.to_comb[comb_id] = nil
	map_data.to_comb_params[comb_id] = nil
end

---@param map_data MapData
---@param comb LuaEntity
---@param reset_display boolean?
function combinator_update(map_data, comb, reset_display)
	local unit_number = comb.unit_number --[[@as uint]]
	local control = get_comb_control(comb)
	local params = control.parameters
	local old_params = map_data.to_comb_params[unit_number]
	local has_changed = false
	local type, id, entity = nil, 0, nil
	local is_ghost = comb.name == "entity-ghost"

	if (old_params == nil) then
		--should be generated after this tick, but in case it persists it is better to let the player know to replace it
		game.print("cybersyn combinator lacking internal data @ " .. comb.gps_tag)
	end

	local op = params.operation
	--handle the combinator's display, if it is part of a station
	if op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST then
		--the follow is only present to fix combinators that have been copy-pasted by blueprint with the wrong operation
		local set_control_params = true

		if reset_display then
			type, id, entity = comb_to_internal_entity(map_data, comb, unit_number)

			if type == 1 then
				local station = entity --[[@as Station]]
				if station.display_state == 0 then
					params.operation = MODE_PRIMARY_IO
				elseif station.display_state % 2 == 1 then
					params.operation = MODE_PRIMARY_IO_ACTIVE
				else
					params.operation = MODE_PRIMARY_IO_FAILED_REQUEST
				end
				set_control_params = false
				control.parameters = params
			end
		end
		--make sure only MODE_PRIMARY_IO gets stored on map_data.to_comb_params
		params.operation = MODE_PRIMARY_IO
		if set_control_params then
			control.parameters = params
		end
	end

	if old_params ~= nil and params.operation ~= old_params.operation then
		--NOTE: This is rather dangerous, we may need to actually implement operation changing
		if is_ghost then
			on_combinator_ghost_broken(map_data, comb, true)
			on_combinator_ghost_built(map_data, comb)
		else
			on_combinator_broken(map_data, comb, true)
			on_combinator_built(map_data, comb)
			-- If anyone actually needs notification of changed ghosts, perhaps a new event can be added for that
			interface_raise_combinator_changed(comb, old_params)
		end
		return
	end

	if is_ghost then return end

	local new_signal = params.first_signal
	local old_signal = old_params ~= nil and old_params.first_signal
	local new_network = new_signal and new_signal.name or nil
	local old_network = old_signal and old_signal.name or nil
	if new_network ~= old_network then
		has_changed = true

		if type == nil then
			type, id, entity = comb_to_internal_entity(map_data, comb, unit_number)
		end
		if type == 1 or type == 2 then
			--NOTE: these updates have to be queued to occur at tick init since central planning is expecting them not to change between ticks
			queue_station_for_combinator_update(map_data, id)
		elseif type == 3 then
			local depot = entity --[[@as Depot]]
			local train_id = depot.available_train_id
			if train_id then
				local train = map_data.trains[train_id]
				remove_available_train(map_data, train_id, train)
				add_available_train_to_depot(map_data, mod_settings, train_id, train, id, depot)
				interface_raise_train_status_changed(train_id, STATUS_D, STATUS_D)
			end
		elseif type == 4 then
			set_refueler_from_comb(map_data, mod_settings, id, entity --[[@as Refueler]])
		end
	end

	if old_params ~= nil and params.second_constant ~= old_params.second_constant then
		has_changed = true

		if type == nil then
			type, id, entity = comb_to_internal_entity(map_data, comb, unit_number)
		end
		--depots do not cache any combinator values so we don't have to update them here
		if type == 1 or type == 2 then
			--NOTE: these updates have to be queued to occur at tick init since central planning is expecting them not to change between ticks
			queue_station_for_combinator_update(map_data, id)
		elseif type == 4 then
			local refueler = entity --[[@as Refueler]]
			local pre = refueler.allows_all_trains
			set_refueler_from_comb(map_data, mod_settings, id, refueler)
			if refueler.allows_all_trains ~= pre then
				update_stop_if_auto(map_data, refueler, false)
			end
		end
	end

	if has_changed then
		map_data.to_comb_params[unit_number] = params
		if old_params ~= nil then
			interface_raise_combinator_changed(comb, old_params)
		end
	end
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb_forbidden LuaEntity?
function on_stop_built_or_updated(map_data, stop, comb_forbidden)
	--NOTE: this stop must not be a part of any station before entering this function
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{ pos_x - 2, pos_y - 2 },
		{ pos_x + 2, pos_y + 2 },
	}
	local comb2 = nil
	local comb1 = nil
	local depot_comb = nil
	local refueler_comb = nil
	local entities = stop.surface.find_entities_filtered({ area = search_area, name = COMBINATOR_NAME })
	for _, entity in pairs(entities) do
		if entity.valid and entity ~= comb_forbidden then
			local id = entity.unit_number --[[@as uint]]
			local adj_stop = map_data.to_stop[id]
			if adj_stop == nil or adj_stop == stop then
				map_data.to_stop[id] = stop
				local param = get_comb_params(entity)
				local op = param.operation
				if op == MODE_PRIMARY_IO then
					comb1 = entity
				elseif op == MODE_SECONDARY_IO then
					comb2 = entity
				elseif op == MODE_DEPOT then
					depot_comb = entity
				elseif op == MODE_REFUELER then
					refueler_comb = entity
				end
			end
		end
	end
	if comb1 then
		on_station_built(map_data, stop, comb1, comb2)
	elseif depot_comb then
		on_depot_built(map_data, stop, depot_comb)
	elseif refueler_comb then
		on_refueler_built(map_data, stop, refueler_comb)
	end
end
---@param map_data MapData
---@param stop LuaEntity
local function on_stop_broken(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{ pos_x - 2, pos_y - 2 },
		{ pos_x + 2, pos_y + 2 },
	}
	local entities = stop.surface.find_entities_filtered({ area = search_area, name = COMBINATOR_NAME })
	for _, entity in pairs(entities) do
		if entity.valid and map_data.to_stop[entity.unit_number] == stop then
			map_data.to_stop[entity.unit_number] = nil
		end
	end

	local id = stop.unit_number --[[@as uint]]
	local station = map_data.stations[id]
	if station then
		on_station_broken(map_data, id, station)
	else
		local depot = map_data.depots[id]
		if depot then
			on_depot_broken(map_data, id, depot)
		else
			local refueler = map_data.refuelers[id]
			if refueler then
				on_refueler_broken(map_data, id, refueler)
			end
		end
	end
end
---@param map_data MapData
---@param stop LuaEntity
---@param old_name string
local function on_stop_rename(map_data, stop, old_name)
	--search for trains coming to the renamed station
	local station_id = stop.unit_number --[[@as uint]]
	local station = map_data.stations[station_id]
	if station and station.deliveries_total > 0 then
		for train_id, train in pairs(map_data.trains) do
			local is_p = train.p_station_id == station_id
			local is_r = train.r_station_id == station_id
			if is_p or is_r then
				local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
				local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
				if is_r and is_r_in_progress then
					local r_station = map_data.stations[train.r_station_id]
					if not train.se_is_being_teleported then
						rename_manifest_schedule(train.entity, r_station.entity_stop, old_name)
					else
						train.se_awaiting_rename = { r_station.entity_stop, old_name }
					end
				elseif is_p and is_p_in_progress then
					--train is attempting delivery to a stop that was renamed
					local p_station = map_data.stations[train.p_station_id]
					if not train.se_is_being_teleported then
						rename_manifest_schedule(train.entity, p_station.entity_stop, old_name)
					else
						train.se_awaiting_rename = { p_station.entity_stop, old_name }
					end
				end
			end
		end
	end
end


---@param map_data MapData
local function find_and_add_all_stations_from_nothing(map_data)
	for _, surface in pairs(game.surfaces) do
		local entities = surface.find_entities_filtered({ name = COMBINATOR_NAME })
		for k, comb in pairs(entities) do
			if comb.valid then
				on_combinator_built(map_data, comb)
			end
		end
	end
end


local function on_built(event)
	local entity = event.entity or event.created_entity
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_built_or_updated(storage, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_built(storage, entity, event.tags)
	elseif entity.name == "entity-ghost" and entity.ghost_name == COMBINATOR_NAME then
		on_combinator_ghost_built(storage, entity)
	elseif entity.type == "inserter" then
		update_stop_from_inserter(storage, entity)
	elseif entity.type == "loader-1x1" then
		-- NOTE: only 1x1 loaders supported here.
		update_stop_from_loader(storage, entity)
	elseif entity.type == "pump" then
		update_stop_from_pump(storage, entity)
	elseif entity.type == "straight-rail" or entity.type == "curved-rail" then
		update_stop_from_rail(storage, entity)
	end
end
local function on_broken(event)
	local entity = event.entity
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_broken(storage, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_broken(storage, entity)
	elseif entity.name == "entity-ghost" and entity.ghost_name == COMBINATOR_NAME then
		on_combinator_ghost_broken(storage, entity)
	elseif entity.type == "inserter" then
		update_stop_from_inserter(storage, entity, entity)
	elseif entity.type == "loader-1x1" then
		-- NOTE: only 1x1 loaders supported here.
		update_stop_from_loader(storage, entity, entity)
	elseif entity.type == "pump" then
		update_stop_from_pump(storage, entity, entity)
	elseif entity.type == "straight-rail" or entity.type == "curved-rail" then
		update_stop_from_rail(storage, entity, nil)
	elseif entity.train then
		local train_id = entity.train.id
		local train = storage.trains[train_id]
		if train then
			on_train_broken(storage, train_id, train)
		end
	end
end
local function on_rotate(event)
	local entity = event.entity or event.created_entity
	if not entity or not entity.valid then return end

	if entity.type == "inserter" then
		update_stop_from_inserter(storage, entity)
	end
end

local function on_surface_removed(event)
	local surface = game.surfaces[event.surface_index]
	if surface then
		local train_stops = surface.find_entities_filtered({ type = "train-stop" })
		for _, entity in pairs(train_stops) do
			if entity.valid and entity.name == "train-stop" then
				on_stop_broken(storage, entity)
			end
		end
	end
end


local function on_paste(event)
	local entity = event.destination
	if not entity or not entity.valid then return end

	if entity.name == COMBINATOR_NAME then
		combinator_update(storage, entity, true)
	end
end

local function on_rename(event)
	if event.entity.name == "train-stop" then
		on_stop_rename(storage, event.entity, event.old_name)
	end
end

local function grab_all_settings()
	mod_settings.enable_planner = settings.global["cybersyn-enable-planner"].value --[[@as boolean]]
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as double]]
	mod_settings.update_rate = settings.global["cybersyn-update-rate"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value --[[@as int]]
	mod_settings.priority = settings.global["cybersyn-priority"].value --[[@as int]]
	mod_settings.locked_slots = settings.global["cybersyn-locked-slots"].value --[[@as int]]
	mod_settings.network_mask = settings.global["cybersyn-network-flag"].value --[[@as int]]
	mod_settings.fuel_threshold = settings.global["cybersyn-fuel-threshold"].value --[[@as double]]
	mod_settings.warmup_time = settings.global["cybersyn-warmup-time"].value --[[@as double]]
	mod_settings.stuck_train_time = settings.global["cybersyn-stuck-train-time"].value --[[@as double]]
	mod_settings.allow_cargo_in_depot = settings.global["cybersyn-allow-cargo-in-depot"].value --[[@as boolean]]
	mod_settings.invert_sign = settings.global["cybersyn-invert-sign"].value --[[@as boolean]]
	mod_settings.manager_ups = settings.global["cybersyn-manager-updates-per-second"].value --[[@as double]]
	mod_settings.manager_enabled = settings.startup["cybersyn-manager-enabled"].value --[[@as boolean]]
end
local function register_tick()
	script.on_nth_tick(nil)
	--edge case catch to register both main and manager tick if they're scheduled to run on the same ticks
	if mod_settings.manager_enabled and mod_settings.manager_ups == mod_settings.tps and mod_settings.tps > DELTA then
		local nth_tick = ceil(60 / mod_settings.tps) --[[@as uint]]
		script.on_nth_tick(nth_tick, function()
			tick(storage, mod_settings)
			manager.tick(storage)
		end)
	else
		if mod_settings.tps > DELTA then
			local nth_tick_main = ceil(60 / mod_settings.tps) --[[@as uint]]
			script.on_nth_tick(nth_tick_main, function()
				tick(storage, mod_settings)
			end)
		end
		if mod_settings.manager_enabled and mod_settings.manager_ups > DELTA then
			local nth_tick_manager = ceil(60 / mod_settings.manager_ups) --[[@as uint]]
			script.on_nth_tick(nth_tick_manager, function()
				manager.tick(storage)
			end)
		end
	end
end
local function on_settings_changed(event)
	grab_all_settings()
	if event.setting == "cybersyn-ticks-per-second" or event.setting == "cybersyn-manager-updates-per-second" then
		register_tick()
	end
	manager.on_runtime_mod_setting_changed(event)
	interface_raise_on_mod_settings_changed(event)
end


local filter_built = {
	{ filter = "name", name = "train-stop" },
	{ filter = "name", name = COMBINATOR_NAME },
	{ filter = "ghost", ghost_name = COMBINATOR_NAME },
	{ filter = "type", type = "inserter" },
	{ filter = "type", type = "pump" },
	{ filter = "type", type = "straight-rail" },
	{ filter = "type", type = "curved-rail" },
	{ filter = "type", type = "loader-1x1" },
}
local filter_broken = {
	{ filter = "name", name = "train-stop" },
	{ filter = "name", name = COMBINATOR_NAME },
	{ filter = "ghost", name = COMBINATOR_NAME },
	{ filter = "type", type = "inserter" },
	{ filter = "type", type = "pump" },
	{ filter = "type", type = "straight-rail" },
	{ filter = "type", type = "curved-rail" },
	{ filter = "type", type = "loader-1x1" },
	{ filter = "rolling-stock" },
}
local function main()
	grab_all_settings()

	mod_settings.missing_train_alert_enabled = true
	mod_settings.stuck_train_alert_enabled = true
	mod_settings.react_to_train_at_incorrect_station = true
	mod_settings.react_to_train_early_to_depot = true

	--NOTE: There is a concern that it is possible to build or destroy important entities without one of these events being triggered, in which case the mod will have undefined behavior
	script.on_event(defines.events.on_built_entity, on_built, filter_built)
	script.on_event(defines.events.on_robot_built_entity, on_built, filter_built)
	script.on_event(
		{
			defines.events.script_raised_built,
			defines.events.script_raised_revive,
			defines.events.on_entity_cloned,
		}, on_built)

	script.on_event(defines.events.on_player_rotated_entity, on_rotate)

	script.on_event(defines.events.on_pre_player_mined_item, on_broken, filter_broken)
	script.on_event(defines.events.on_robot_pre_mined, on_broken, filter_broken)
	script.on_event(defines.events.on_entity_died, on_broken, filter_broken)
	script.on_event(defines.events.script_raised_destroy, on_broken)

	script.on_event({ defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared }, on_surface_removed)

	script.on_event(defines.events.on_entity_settings_pasted, on_paste)

	script.on_event(defines.events.on_train_created, on_train_built)
	script.on_event(defines.events.on_train_changed_state, on_train_changed)

	script.on_event(defines.events.on_entity_renamed, on_rename)

	script.on_event(defines.events.on_runtime_mod_setting_changed, on_settings_changed)

	register_gui_actions()

	local MANAGER_ENABLED = mod_settings.manager_enabled

	script.on_init(function()
		local setting = settings.global["cybersyn-invert-sign"]
		setting.value = false
		settings.global["cybersyn-invert-sign"] = setting
		mod_settings.invert_sign = false
		init_global()
		se_compat.setup_se_compat()
		picker_dollies_compat.setup_picker_dollies_compat()
		if MANAGER_ENABLED then
			manager.on_init()
		end
	end)

	script.on_configuration_changed(function(e)
		on_config_changed(e)
		if MANAGER_ENABLED then
			manager.on_migration()
		end
	end)

	script.on_load(function()
		se_compat.setup_se_compat()
		picker_dollies_compat.setup_picker_dollies_compat()
	end)

	if MANAGER_ENABLED then
		script.on_event(defines.events.on_player_removed, manager.on_player_removed)
		script.on_event(defines.events.on_player_created, manager.on_player_created)
		script.on_event(defines.events.on_lua_shortcut, manager.on_lua_shortcut)
		script.on_event(defines.events.on_gui_closed, manager.on_lua_shortcut)
		script.on_event("cybersyn-toggle-gui", manager.on_lua_shortcut)
	end

	register_tick()
end


main()
