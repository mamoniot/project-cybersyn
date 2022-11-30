--By Mami
local get_distance = require("__flib__.misc").get_distance
local abs = math.abs
local floor = math.floor


---@param map_data MapData
---@param item_name string
function get_stack_size(map_data, item_name)
	return game.item_prototypes[item_name].stack_size
end


---@param stop0 LuaEntity
---@param stop1 LuaEntity
function get_stop_dist(stop0, stop1)
	local surface0 = stop0.surface.index
	local surface1 = stop1.surface.index
	return (surface0 == surface1 and get_distance(stop0.position, stop1.position) or DIFFERENT_SURFACE_DISTANCE)
end


---@param surface LuaSurface
local function se_get_space_elevator_name(surface)
	--TODO: check how expensive the following is and potentially cache it's results
	local entity = surface.find_entities_filtered({
		name = SE_ELEVATOR_STOP_PROTO_NAME,
		type = "train-stop",
		limit = 1,
	})[1]
	if entity and entity.valid then
		return string.sub(entity.backer_name, 1, string.len(entity.backer_name) - SE_ELEVATOR_SUFFIX_LENGTH)
	end
end


------------------------------------------------------------------------------
--[[train schedules]]--
------------------------------------------------------------------------------


local create_loading_order_condition = {type = "inactivity", compare_type = "and", ticks = INACTIVITY_TIME}
---@param stop LuaEntity
---@param manifest Manifest
function create_loading_order(stop, manifest)
	local condition = {}
	for _, item in ipairs(manifest) do
		local cond_type
		if item.type == "fluid" then
			cond_type = "fluid_count"
		else
			cond_type = "item_count"
		end

		condition[#condition + 1] = {
			type = cond_type,
			compare_type = "and",
			condition = {comparator = "≥", first_signal = {type = item.type, name = item.name}, constant = item.count}
		}
	end
	condition[#condition + 1] = create_loading_order_condition
	return {station = stop.backer_name, wait_conditions = condition}
end

local create_unloading_order_condition = {{type = "empty", compare_type = "and"}}
---@param stop LuaEntity
function create_unloading_order(stop)
	return {station = stop.backer_name, wait_conditions = create_unloading_order_condition}
end

local create_inactivity_order_condition = {{type = "inactivity", compare_type = "and", ticks = INACTIVITY_TIME}}
---@param depot_name string
function create_inactivity_order(depot_name)
	return {station = depot_name, wait_conditions = create_inactivity_order_condition}
end

local create_direct_to_station_order_condition = {{type = "time", compare_type = "and", ticks = 1}}
---@param stop LuaEntity
function create_direct_to_station_order(stop)
	return {rail = stop.connected_rail, rail_direction = stop.connected_rail_direction, wait_conditions = create_direct_to_station_order_condition}
end

---@param train LuaTrain
---@param depot_name string
function set_depot_schedule(train, depot_name)
	train.schedule = {current = 1, records = {create_inactivity_order(depot_name)}}
end

---@param train LuaTrain
function lock_train(train)
	train.manual_mode = true
end

---@param train LuaTrain
---@param stop LuaEntity
---@param old_name string
function rename_manifest_schedule(train, stop, old_name)
	local new_name = stop.backer_name
	local schedule = train.schedule
	if not schedule then return end
	for i, record in ipairs(schedule.records) do
		if record.station == old_name then
			record.station = new_name
		end
	end
	train.schedule = schedule
end

---@param train LuaTrain
---@param depot_stop LuaEntity
---@param p_stop LuaEntity
---@param r_stop LuaEntity
---@param manifest Manifest
function set_manifest_schedule(train, depot_stop, p_stop, r_stop, manifest)
	--NOTE: train must be on same surface as depot_stop
	local d_surface = depot_stop.surface
	local p_surface = p_stop.surface
	local r_surface = r_stop.surface
	local d_surface_i = d_surface.index
	local p_surface_i = p_surface.index
	local r_surface_i = r_surface.index
	if d_surface_i == p_surface_i and p_surface_i == r_surface_i then
		train.schedule = {current = 1, records = {
			create_inactivity_order(depot_stop.backer_name),
			create_direct_to_station_order(p_stop),
			create_loading_order(p_stop, manifest),
			create_direct_to_station_order(r_stop),
			create_unloading_order(r_stop),
		}}
		return
	elseif IS_SE_PRESENT and (d_surface_i == p_surface_i or p_surface_i == r_surface_i or r_surface_i == d_surface_i) then
		local d_zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = d_surface_i})
		local other_zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = (d_surface_i == p_surface_i) and r_surface_i or p_surface_i})
		local is_train_in_orbit = other_zone.orbit_index == d_zone.index
		if is_train_in_orbit or d_zone.orbit_index == other_zone.index then
			local elevator_name = se_get_space_elevator_name(d_surface)
			if elevator_name then
				local records = {create_inactivity_order(depot_stop.backer_name)}
				if d_surface_i == p_surface_i then
					records[#records + 1] = create_direct_to_station_order(p_stop)
				else
					records[#records + 1] = {station = elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)}
					is_train_in_orbit = not is_train_in_orbit
				end
				records[#records + 1] = create_loading_order(p_stop, manifest)
				if p_surface_i ~= r_surface_i then
					records[#records + 1] = {station = elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)}
					is_train_in_orbit = not is_train_in_orbit
				end
				records[#records + 1] = create_unloading_order(r_stop)
				if r_surface_i ~= d_surface_i then
					records[#records + 1] = {station = elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)}
					is_train_in_orbit = not is_train_in_orbit
				end

				train.schedule = {current = 1, records = records}
				return
			end
		end
	end
	--NOTE: create a schedule that cannot be fulfilled, the train will be stuck but it will give the player information what went wrong
	train.schedule = {current = 1, records = {
		create_inactivity_order(depot_stop.backer_name),
		create_loading_order(p_stop, manifest),
		create_unloading_order(r_stop),
	}}
	lock_train(train)
	send_lost_train_alert(train, depot_stop.backer_name)
end


------------------------------------------------------------------------------
--[[combinators]]--
------------------------------------------------------------------------------


---@param comb LuaEntity
function get_comb_control(comb)
	--NOTE: using this as opposed to get_comb_params gives you R/W access
	return comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
end
---@param comb LuaEntity
function get_comb_params(comb)
	return comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
end
---@param comb LuaEntity
function get_comb_gui_settings(comb)
	local params = get_comb_params(comb)
	local op = params.operation

	local selected_index = 0
	local switch_state = "none"
	local bits = params.second_constant or 0
	local allows_all_trains = bits%2 == 1
	local is_pr_state = floor(bits/2)%3
	if is_pr_state == 0 then
		switch_state = "none"
	elseif is_pr_state == 1 then
		switch_state = "left"
	elseif is_pr_state == 2 then
		switch_state = "right"
	end

	if op == OPERATION_PRIMARY_IO or op == OPERATION_PRIMARY_IO_ACTIVE or op == OPERATION_PRIMARY_IO_FAILED_REQUEST then
		selected_index = 1
	elseif op == OPERATION_SECONDARY_IO then
		selected_index = 2
	elseif op == OPERATION_DEPOT then
		selected_index = 3
	elseif op == OPERATION_WAGON_MANIFEST then
		selected_index = 4
	end
	return selected_index, params.first_signal, not allows_all_trains, switch_state
end
---@param comb LuaEntity
function get_comb_network_name(comb)
	local params = get_comb_params(comb)
	local signal = params.first_signal

	return signal and signal.name or nil
end
---@param station Station
function set_station_from_comb_state(station)
	--NOTE: this does nothing to update currently active deliveries
	local params = get_comb_params(station.entity_comb1)
	local bits = params.second_constant or 0
	local is_pr_state = floor(bits/2)%3
	local signal = params.first_signal
	station.network_name = signal and signal.name or nil
	station.allows_all_trains = bits%2 == 1
	station.is_p = is_pr_state == 0 or is_pr_state == 1
	station.is_r = is_pr_state == 0 or is_pr_state == 2
end
---@param map_data MapData
---@param unit_number uint
---@param params ArithmeticCombinatorParameters
function has_comb_params_changed(map_data, unit_number, params)
	local old_params = map_data.to_comb_params[unit_number]

	if params.operation ~= old_params.operation then
		if (old_params.operation == OPERATION_PRIMARY_IO) and (params.operation == OPERATION_PRIMARY_IO_ACTIVE or params.operation == OPERATION_PRIMARY_IO_FAILED_REQUEST) then
		else
			return true
		end
	end
	local new_signal = params.first_signal
	local old_signal = old_params.first_signal
	local new_network = new_signal and new_signal.name or nil
	local old_network = old_signal and old_signal.name or nil
	if new_network ~= old_network then
		return true
	end
	if params.second_constant ~= old_params.second_constant then
		return true
	end
	return false
end
---@param map_data MapData
---@param comb LuaEntity
---@param op string
function set_comb_operation_with_check(map_data, comb, op)
	---@type uint
	local unit_number = comb.unit_number
	local control = get_comb_control(comb)
	local params = control.parameters
	if not has_comb_params_changed(map_data, unit_number, params) then
		params.operation = op
		control.parameters = params
		if (op == OPERATION_PRIMARY_IO_ACTIVE or op == OPERATION_PRIMARY_IO_FAILED_REQUEST) then
			params.operation = OPERATION_PRIMARY_IO
		end
		map_data.to_comb_params[unit_number] = params
	end
end
---@param map_data MapData
---@param comb LuaEntity
---@param is_failed boolean
function update_combinator_display(map_data, comb, is_failed)
	---@type uint
	local unit_number = comb.unit_number
	local control = get_comb_control(comb)
	local params = control.parameters
	if not has_comb_params_changed(map_data, unit_number, params) then
		if is_failed then
			if params.operation == OPERATION_PRIMARY_IO then
				params.operation = OPERATION_PRIMARY_IO_FAILED_REQUEST
				control.parameters = params
				params.operation = OPERATION_PRIMARY_IO
				map_data.to_comb_params[unit_number] = params
			end
		elseif params.operation == OPERATION_PRIMARY_IO_FAILED_REQUEST then
			params.operation = OPERATION_PRIMARY_IO
			control.parameters = params
			map_data.to_comb_params[unit_number] = params
		end
	end
end
---@param comb LuaEntity
---@param allows_all_trains boolean
function set_comb_allows_all_trains(comb, allows_all_trains)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0
	param.second_constant = (bits - bits%2) + (allows_all_trains and 1 or 0)
	control.parameters = param
end
---@param comb LuaEntity
---@param is_pr_state 0|1|2
function set_comb_is_pr_state(comb, is_pr_state)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0
	param.second_constant = (bits%2) + (2*is_pr_state)
	control.parameters = param
end
---@param comb LuaEntity
---@param signal SignalID?
function set_comb_network_name(comb, signal)
	local control = get_comb_control(comb)
	local param = control.parameters

	param.first_signal = signal
	control.parameters = param
end
---@param comb LuaEntity
---@param op string
function set_comb_operation(comb, op)
	local control = get_comb_control(comb)
	local params = control.parameters
	params.operation = op
	control.parameters = params
end


---@param map_data MapData
---@param comb LuaEntity
---@param signals ConstantCombinatorParameters[]?
function set_combinator_output(map_data, comb, signals)
	local out = map_data.to_output[comb.unit_number]
	if out.valid then
		out.get_or_create_control_behavior().parameters = signals
	end
end

local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power
---@param station Station
function get_signals(station)
	local comb = station.entity_comb1
	if comb.valid then
		local status = comb.status
		if status == WORKING or status == LOW_POWER then
			return comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
		end
	else
		return nil
	end
end

---@param map_data MapData
---@param station Station
function set_comb2(map_data, station)
	if station.entity_comb2 then
		local deliveries = station.deliveries
		local signals = {}
		for item_name, count in pairs(deliveries) do
			local i = #signals + 1
			local is_fluid = game.item_prototypes[item_name] == nil--NOTE: this is expensive
			signals[i] = {index = i, signal = {type = is_fluid and "fluid" or "item", name = item_name}, count = -count}
		end
		set_combinator_output(map_data, station.entity_comb2, signals)
	end
end


---@param map_data MapData
---@param station Station
---@param signal SignalID
function get_threshold(map_data, station, signal)
	local comb2 = station.entity_comb2
	if comb2 and comb2.valid then
		local count = comb2.get_merged_signal(signal, defines.circuit_connector_id.combinator_input)
		if count ~= 0 then
			return abs(count)
		end
	end
	return station.r_threshold
end


------------------------------------------------------------------------------
--[[alerts]]--
------------------------------------------------------------------------------


local send_missing_train_alert_for_stop_icon = {name = MISSING_TRAIN_NAME, type = "fluid"}
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_missing_train_alert_for_stops(r_stop, p_stop)
	for _, player in pairs(r_stop.force.players) do
		player.add_custom_alert(
		r_stop,
		send_missing_train_alert_for_stop_icon,
		{"cybersyn-messages.missing-trains", r_stop.backer_name, p_stop.backer_name},
		true)
	end
end

local send_lost_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param train LuaTrain
---@param depot_name string
function send_lost_train_alert(train, depot_name)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			send_lost_train_alert_icon,
			{"cybersyn-messages.lost-train", depot_name},
			true)
			player.play_sound({path = ALERT_SOUND})
		end
	end
end
---@param train LuaTrain
function send_unexpected_train_alert(train)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			send_lost_train_alert_icon,
			{"cybersyn-messages.unexpected-train"},
			true)
		end
	end
end


local send_nonempty_train_in_depot_alert_icon = {name = NONEMPTY_TRAIN_NAME, type = "fluid"}
---@param train LuaTrain
function send_nonempty_train_in_depot_alert(train)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			send_nonempty_train_in_depot_alert_icon,
			{"cybersyn-messages.nonempty-train"},
			true)
			player.play_sound({path = ALERT_SOUND})
		end
	end
end


local send_stuck_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param train LuaTrain
---@param depot_name string
function send_stuck_train_alert(train, depot_name)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			send_stuck_train_alert_icon,
			{"cybersyn-messages.stuck-train", depot_name},
			true)
		end
	end
end
