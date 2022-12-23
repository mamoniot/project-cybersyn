--By Mami
local get_distance = require("__flib__.misc").get_distance
local floor = math.floor
local table_insert = table.insert
local DEFINES_WORKING = defines.entity_status.working
local DEFINES_LOW_POWER = defines.entity_status.low_power
local DEFINES_COMBINATOR_INPUT = defines.circuit_connector_id.combinator_input


---@param map_data MapData
---@param item_name string
function get_stack_size(map_data, item_name)
	return game.item_prototypes[item_name].stack_size
end


---@param entity0 LuaEntity
---@param entity1 LuaEntity
function get_stop_dist(entity0, entity1)
	local surface0 = entity0.surface.index
	local surface1 = entity1.surface.index
	return (surface0 == surface1 and get_distance(entity0.position, entity1.position) or DIFFERENT_SURFACE_DISTANCE)--[[@as number]]
end


---@param surface LuaSurface
function se_get_space_elevator_name(surface)
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
function lock_train_to_depot(train)
	local schedule = train.schedule
	if schedule then
		local record = schedule.records[schedule.current]
		if record then
			local wait = record.wait_conditions
			if wait and wait[1] then
				wait[1].ticks = LOCK_TRAIN_TIME
			else
				record.wait_conditions = {{type = "inactivity", compare_type = "and", ticks = LOCK_TRAIN_TIME}}
			end
			train.schedule = schedule
		else
			train.manual_mode = true
		end
	else
		train.manual_mode = true
	end
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

---@param elevator_name string
---@param is_train_in_orbit boolean
function se_create_elevator_order(elevator_name, is_train_in_orbit)
	return {station = elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)}
end
---@param map_data MapData
---@param train LuaTrain
---@param depot_name string
---@param d_surface_i int
---@param p_stop LuaEntity
---@param r_stop LuaEntity
---@param manifest Manifest
---@param start_at_depot boolean?
function set_manifest_schedule(map_data, train, depot_name, d_surface_i, p_stop, r_stop, manifest, start_at_depot)
	--NOTE: can only return false if start_at_depot is false, it should be incredibly rare that this function returns false
	local old_schedule
	if not start_at_depot then
		old_schedule = train.schedule
	end
	local t_surface = train.front_stock.surface
	local p_surface = p_stop.surface
	local r_surface = r_stop.surface
	local t_surface_i = t_surface.index
	local p_surface_i = p_surface.index
	local r_surface_i = r_surface.index
	local is_p_on_t = t_surface_i == p_surface_i
	local is_r_on_t = t_surface_i == r_surface_i
	local is_d_on_t = t_surface_i == d_surface_i
	if is_p_on_t and is_r_on_t and is_d_on_t then
		train.schedule = {
			current = start_at_depot and 1 or 2--[[@as uint]],
			records = {
				create_inactivity_order(depot_name),
				create_direct_to_station_order(p_stop),
				create_loading_order(p_stop, manifest),
				create_direct_to_station_order(r_stop),
				create_unloading_order(r_stop),
			}
		}
		if old_schedule and not train.has_path then
			train.schedule = old_schedule
			return false
		else
			return true
		end
	elseif IS_SE_PRESENT then
		local other_surface_i = (not is_p_on_t and p_surface_i) or (not is_r_on_t and r_surface_i) or d_surface_i
		if (is_p_on_t or p_surface_i == other_surface_i) and (is_r_on_t or r_surface_i == other_surface_i) and (is_d_on_t or d_surface_i == other_surface_i) then
			local t_zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = t_surface_i})--[[@as {}]]
			local other_zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = other_surface_i})--[[@as {}]]
			local is_train_in_orbit = other_zone.orbit_index == t_zone.index
			if is_train_in_orbit or t_zone.orbit_index == other_zone.index then
				local elevator_name = se_get_space_elevator_name(t_surface)
				if elevator_name then
					local records = {create_inactivity_order(depot_name)}
					if t_surface_i == p_surface_i then
						records[#records + 1] = create_direct_to_station_order(p_stop)
					else
						records[#records + 1] = se_create_elevator_order(elevator_name, is_train_in_orbit)
						is_train_in_orbit = not is_train_in_orbit
					end
					records[#records + 1] = create_loading_order(p_stop, manifest)

					if p_surface_i ~= r_surface_i then
						records[#records + 1] = se_create_elevator_order(elevator_name, is_train_in_orbit)
						is_train_in_orbit = not is_train_in_orbit
					elseif t_surface_i == r_surface_i then
						records[#records + 1] = create_direct_to_station_order(r_stop)
					end
					records[#records + 1] = create_unloading_order(r_stop)
					if r_surface_i ~= d_surface_i then
						records[#records + 1] = se_create_elevator_order(elevator_name, is_train_in_orbit)
						is_train_in_orbit = not is_train_in_orbit
					end

					train.schedule = {current = start_at_depot and 1 or 2--[[@as uint]], records = records}
					if old_schedule and not train.has_path then
						train.schedule = old_schedule
						return false
					else
						return true
					end
				end
			end
		end
	end
	--NOTE: create a schedule that cannot be fulfilled, the train will be stuck but it will give the player information what went wrong
	train.schedule = {current = 1, records = {
		create_inactivity_order(depot_name),
		create_loading_order(p_stop, manifest),
		create_unloading_order(r_stop),
	}}
	lock_train(train)
	send_alert_cannot_path_between_surfaces(map_data, train)
	return true
end

---@param map_data MapData
---@param train LuaTrain
---@param stop LuaEntity
function add_refueler_schedule(map_data, train, stop)
	local schedule = train.schedule or {current = 1, records = {}}
	local i = schedule.current
	if i == 1 then
		i = #schedule.records + 1--[[@as uint]]
		schedule.current = i
	end

	local t_surface = train.front_stock.surface
	local f_surface = stop.surface
	local t_surface_i = t_surface.index
	local f_surface_i = f_surface.index
	if t_surface_i == f_surface_i then
		table_insert(schedule.records, i, create_direct_to_station_order(stop))
		i = i + 1
		table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))

		train.schedule = schedule
		return
	elseif IS_SE_PRESENT then
		local t_zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = t_surface_i})--[[@as {}]]
		local other_zone = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = f_surface_i})--[[@as {}]]
		local is_train_in_orbit = other_zone.orbit_index == t_zone.index
		if is_train_in_orbit or t_zone.orbit_index == other_zone.index then
			local elevator_name = se_get_space_elevator_name(t_surface)
			local cur_order = schedule.records[i]
			local is_elevator_in_orders_already = cur_order and cur_order.station == elevator_name..(is_train_in_orbit and SE_ELEVATOR_ORBIT_SUFFIX or SE_ELEVATOR_PLANET_SUFFIX)
			if not is_elevator_in_orders_already then
				table_insert(schedule.records, i, se_create_elevator_order(elevator_name, is_train_in_orbit))
			end
			i = i + 1
			is_train_in_orbit = not is_train_in_orbit
			table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))
			i = i + 1
			if not is_elevator_in_orders_already then
				table_insert(schedule.records, i, se_create_elevator_order(elevator_name, is_train_in_orbit))
				i = i + 1
				is_train_in_orbit = not is_train_in_orbit
			end

			train.schedule = schedule
			return
		end
	end
	--create an order that probably cannot be fulfilled and alert the player
	table_insert(schedule.records, i, create_inactivity_order(stop.backer_name))
	lock_train(train)
	train.schedule = schedule
	send_alert_cannot_path_between_surfaces(map_data, train)
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
function get_comb_network_name(comb)
	local params = get_comb_params(comb)
	local signal = params.first_signal

	return signal and signal.name or nil
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param id uint
function set_refueler_from_comb(map_data, mod_settings, id)
	--NOTE: this does nothing to update currently active deliveries
	local refueler = map_data.refuelers[id]
	local params = get_comb_params(refueler.entity_comb)
	local bits = params.second_constant or 0
	local signal = params.first_signal

	local f, a
	if refueler.network_name == NETWORK_ANY then
		f, a = pairs(refueler.network_flag--[[@as {[string]: int}]])
	else
		f, a = once, refueler.network_name
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if network then
			network[id] = nil
			if next(network) == nil then
				map_data.to_refuelers[network_name] = nil
			end
		end
	end

	refueler.network_name = signal and signal.name or nil
	refueler.allows_all_trains = (bits%2 == 1) or nil

	local signals = refueler.entity_comb.get_merged_signals(DEFINES_COMBINATOR_INPUT)
	refueler.priority = 0
	if refueler.network_name == NETWORK_ANY then
		refueler.network_flag = {}
	else
		refueler.network_flag = mod_settings.network_flag
	end
	if not signals then return end
	for k, v in pairs(signals) do
		local item_name = v.signal.name
		local item_type = v.signal.type
		local item_count = v.count
		if item_name then
			if item_type == "virtual" then
				if item_name == SIGNAL_PRIORITY then
					refueler.priority = item_count
				elseif refueler.network_name == NETWORK_ANY then
					refueler.network_flag[item_name] = item_count
				end
			end
			if item_name == refueler.network_name then
				refueler.network_flag = item_count
			end
		end
	end

	if refueler.network_name == NETWORK_ANY then
		f, a = pairs(refueler.network_flag--[[@as {[string]: int}]])
	else
		f, a = once, refueler.network_name
	end
	for network_name, _ in f, a do
		local network = map_data.to_refuelers[network_name]
		if not network then
			network = {}
			map_data.to_refuelers[network_name] = network
		end
		network[id] = true
	end
end

---@param map_data MapData
---@param station Station
function update_display(map_data, station)
	local comb = station.entity_comb1
	if comb.valid then
		local control = get_comb_control(comb)
		local params = control.parameters
		--NOTE: the following check can cause a bug where the display desyncs if the player changes the operation of the combinator and then changes it back before the mod can notice, however removing it causes a bug where the user's change is overwritten and ignored. Everything's bad we need an event to catch copy-paste by blueprint.
		if params.operation == MODE_PRIMARY_IO or params.operation == MODE_PRIMARY_IO_ACTIVE or params.operation == MODE_PRIMARY_IO_FAILED_REQUEST then
			if station.display_state >= 2 then
				params.operation = MODE_PRIMARY_IO_ACTIVE
			elseif station.display_state == 1 then
				params.operation = MODE_PRIMARY_IO_FAILED_REQUEST
			else
				params.operation = MODE_PRIMARY_IO
			end
			control.parameters = params
		end
	end
end


---@param station Station
function set_station_from_comb_state(station)
	--NOTE: this does nothing to update currently active deliveries
	local params = get_comb_params(station.entity_comb1)
	local signal = params.first_signal

	local bits = params.second_constant or 0
	local is_pr_state = bit32.extract(bits, 0, 2)
	local allows_all_trains = bit32.extract(bits, 2) > 0
	local is_stack = bit32.extract(bits, 3) > 0

	station.network_name = signal and signal.name or nil
	station.allows_all_trains = allows_all_trains
	station.is_stack = is_stack
	station.is_p = (is_pr_state == 0 or is_pr_state == 1) or nil
	station.is_r = (is_pr_state == 0 or is_pr_state == 2) or nil
end
---@param comb LuaEntity
function get_comb_gui_settings(comb)
	local params = get_comb_params(comb)
	local op = params.operation

	local selected_index = 0
	local switch_state = "none"
	local bits = params.second_constant or 0
	local is_pr_state = bit32.extract(bits, 0, 2)
	local allows_all_trains = bit32.extract(bits, 2) > 0
	local is_stack = bit32.extract(bits, 3) > 0
	if is_pr_state == 0 then
		switch_state = "none"
	elseif is_pr_state == 1 then
		switch_state = "left"
	elseif is_pr_state == 2 then
		switch_state = "right"
	end

	if op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST then
		selected_index = 1
	elseif op == MODE_DEPOT then
		selected_index = 2
	elseif op == MODE_REFUELER then
		selected_index = 3
	elseif op == MODE_SECONDARY_IO then
		selected_index = 4
	elseif op == MODE_WAGON_MANIFEST then
		selected_index = 5
	end
	return selected_index, params.first_signal, switch_state, not allows_all_trains, is_stack
end
---@param comb LuaEntity
---@param is_pr_state 0|1|2
function set_comb_is_pr_state(comb, is_pr_state)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit32.replace(bits, is_pr_state, 0, 2)
	control.parameters = param
end
---@param comb LuaEntity
---@param allows_all_trains boolean
function set_comb_allows_all_trains(comb, allows_all_trains)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit32.replace(bits, allows_all_trains and 1 or 0, 2)
	control.parameters = param
end
---@param comb LuaEntity
---@param is_stack boolean
function set_comb_is_stack(comb, is_stack)
	local control = get_comb_control(comb)
	local param = control.parameters
	local bits = param.second_constant or 0

	param.second_constant = bit32.replace(bits, is_stack and 1 or 0, 3)
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

---@param station Station
function get_signals(station)
	--NOTE: the combinator must be valid, but checking for valid every time is too slow
	local comb1 = station.entity_comb1
	local status1 = comb1.status
	---@type Signal[]?
	local comb1_signals = nil
	---@type Signal[]?
	local comb2_signals = nil
	if status1 == DEFINES_WORKING or status1 == DEFINES_LOW_POWER then
		comb1_signals = comb1.get_merged_signals(DEFINES_COMBINATOR_INPUT)
	end
	local comb2 = station.entity_comb2
	if comb2 then
		local status2 = comb2.status
		if status2 == DEFINES_WORKING or status2 == DEFINES_LOW_POWER then
			comb2_signals = comb2.get_merged_signals(DEFINES_COMBINATOR_INPUT)
		end
	end
	return comb1_signals, comb2_signals
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

------------------------------------------------------------------------------
--[[alerts]]--
------------------------------------------------------------------------------

---@param train LuaTrain
---@param icon {}
---@param message string
local function send_alert_for_train(train, icon, message)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			icon,
			{message},
			true)
			player.play_sound({path = ALERT_SOUND})
		end
	end
end
local send_alert_about_missing_train_icon = {name = MISSING_TRAIN_NAME, type = "fluid"}
---@param r_stop LuaEntity
---@param p_stop LuaEntity
---@param message string
function send_alert_about_missing_train(r_stop, p_stop, message)
	for _, player in pairs(r_stop.force.players) do
		player.add_custom_alert(
		r_stop,
		send_alert_about_missing_train_icon,
		{message, r_stop.backer_name, p_stop.backer_name},
		true)
	end
end

---@param train LuaTrain
function send_alert_sounds(train)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.play_sound({path = ALERT_SOUND})
		end
	end
end


---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_missing_train(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.missing-train")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_has_capacity(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-has-capacity")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_matches_r_layout(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-matches-r-layout")
end
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_alert_no_train_matches_p_layout(r_stop, p_stop)
	send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.no-train-matches-p-layout")
end


local send_stuck_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param map_data MapData
---@param train LuaTrain
function send_alert_stuck_train(map_data, train)
	send_alert_for_train(train, send_stuck_train_alert_icon, "cybersyn-messages.stuck-train")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 1
end

local send_nonempty_train_in_depot_alert_icon = {name = NONEMPTY_TRAIN_NAME, type = "fluid"}
---@param map_data MapData
---@param train LuaTrain
function send_alert_nonempty_train_in_depot(map_data, train)
	send_alert_for_train(train, send_nonempty_train_in_depot_alert_icon, "cybersyn-messages.nonempty-train")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 2
end

local send_lost_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param map_data MapData
---@param train LuaTrain
function send_alert_depot_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.depot-broken")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 3
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_station_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.station-broken")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 4
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_refueler_of_train_broken(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.refueler-broken")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 5
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_train_at_incorrect_station(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-at-incorrect")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 6
end
---@param map_data MapData
---@param train LuaTrain
function send_alert_cannot_path_between_surfaces(map_data, train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.cannot-path-between-surfaces")
	map_data.active_alerts = map_data.active_alerts or {}
	map_data.active_alerts[train] = 7
end

---@param train LuaTrain
function send_alert_unexpected_train(train)
	send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.unexpected-train")
end


---@param map_data MapData
function process_active_alerts(map_data)
	for train, id in pairs(map_data.active_alerts) do
		if id == 1 then
			send_alert_for_train(train, send_stuck_train_alert_icon, "cybersyn-messages.stuck-train")
		elseif id == 2 then
			send_alert_for_train(train, send_nonempty_train_in_depot_alert_icon, "cybersyn-messages.nonempty-train")
		elseif id == 3 then
			send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.depot-broken")
		elseif id == 4 then
			send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.station-broken")
		elseif id == 5 then
			send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.refueler-broken")
		elseif id == 6 then
			send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.train-at-incorrect")
		elseif id == 7 then
			send_alert_for_train(train, send_lost_train_alert_icon, "cybersyn-messages.cannot-path-between-surfaces")
		end
	end
end
