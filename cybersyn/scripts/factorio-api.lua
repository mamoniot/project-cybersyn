--By Mami
local abs = math.abs
local floor = math.floor


---@param map_data MapData
---@param item_name string
function get_stack_size(map_data, item_name)
	return game.item_prototypes[item_name].stack_size
end


local create_loading_order_condition = {type = "inactivity", compare_type = "and", ticks = 120}
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

local create_inactivity_order_condition = {{type = "inactivity", compare_type = "and", ticks = 120}}
---@param depot_name string
function create_inactivity_order(depot_name)
	return {station = depot_name, wait_conditions = create_inactivity_order_condition}
end

local create_direct_to_station_order_condition = {{type = "time", compare_type = "and", ticks = 1}}
---@param stop LuaEntity
local function create_direct_to_station_order(stop)
	return {rail = stop.connected_rail, rail_direction = stop.connected_rail_direction,wait_conditions = create_direct_to_station_order_condition}
end

---@param depot_name string
function create_depot_schedule(depot_name)
	return {current = 1, records = {create_inactivity_order(depot_name)}}
end

---@param depot_name string
---@param p_stop LuaEntity
---@param r_stop LuaEntity
---@param manifest Manifest
function create_manifest_schedule(depot_name, p_stop, r_stop, manifest)
	return {current = 1, records = {
		create_inactivity_order(depot_name),
		create_direct_to_station_order(p_stop),
		create_loading_order(p_stop, manifest),
		create_direct_to_station_order(r_stop),
		create_unloading_order(r_stop),
	}}
end

function get_comb_params(comb)
	return comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
end
---@param param ArithmeticCombinatorParameters
function get_comb_secondary_state(param)
	local bits = param.second_constant or 0
	return bits%2 == 1, floor(bits/2)%3
end
---@param depot Depot
function set_depot_from_comb_state(depot)
	local param = get_comb_params(depot.entity_comb)
	local signal = param.first_signal
	depot.network_name = signal and signal.name or nil
end
---@param station Station
function set_station_from_comb_state(station)
	--NOTE: this does nothing to update currently active deliveries
	local param = get_comb_params(station.entity_comb1)
	local bits = param.second_constant or 0
	local is_pr_state = floor(bits/2)%3
	local signal = param.first_signal
	station.network_name = signal and signal.name or nil
	station.allows_all_trains = bits%2 == 1
	station.is_p = is_pr_state == 0 or is_pr_state == 1
	station.is_r = is_pr_state == 0 or is_pr_state == 2
end
---@param comb LuaEntity
---@param allows_all_trains boolean
function set_comb_allows_all_trains(comb, allows_all_trains)
	local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local param = control.parameters
	local bits = param.second_constant or 0
	param.second_constant = (bits - bits%2) + (allows_all_trains and 1 or 0)
	control.parameters = param
	return param
end
---@param comb LuaEntity
---@param is_pr_state 0|1|2
function set_comb_is_pr_state(comb, is_pr_state)
	local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local param = control.parameters
	local bits = param.second_constant or 0
	param.second_constant = (bits%2) + (2*is_pr_state)
	control.parameters = param
	return param
end

---@param comb LuaEntity
---@param signal SignalID?
function set_comb_network_name(comb, signal)
	local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local param = control.parameters

	param.first_signal = signal
	control.parameters = param
	return param
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
---@param comb LuaEntity
---@param op string
function set_combinator_operation(comb, op)
	local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local param = control.parameters
	param.operation = op
	control.parameters = param
	return param
end
---@param comb LuaEntity
---@param is_failed boolean
function update_combinator_display(comb, is_failed)
	local control = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local param = control.parameters
	if is_failed then
		if param.operation == OPERATION_PRIMARY_IO then
			param.operation = OPERATION_PRIMARY_IO_REQUEST_FAILED
			control.parameters = param
		end
	elseif param.operation == OPERATION_PRIMARY_IO_REQUEST_FAILED then
		param.operation = OPERATION_PRIMARY_IO
		control.parameters = param
	end
end


---@param station Station
function get_signals(station)
	local comb = station.entity_comb1
	if comb.valid and (comb.status == defines.entity_status.working or comb.status == defines.entity_status.low_power) then
		return comb.get_merged_signals(defines.circuit_connector_id.combinator_input)
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
function send_lost_train_alert(train)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
			loco,
			send_lost_train_alert_icon,
			{"cybersyn-messages.lost-train"},
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
