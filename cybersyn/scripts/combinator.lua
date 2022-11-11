--By Mami
local abs = math.abs
local floor = math.floor

---@param param ArithmeticCombinatorParameters
function get_comb_secondary_state(param)
	local bits = param.second_constant or 0
	return bits%2 == 1, floor(bits/2)%3
end
---@param depot Depot
function set_depot_from_comb_state(depot)
	local param = depot.entity_comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
	local signal = param.first_signal
	depot.network_name = signal and signal.name or nil
end
---@param station Station
function set_station_from_comb_state(station)
	--NOTE: this does nothing to update currently active deliveries
	local param = station.entity_comb1.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
	local bits = param.second_constant or 0
	local is_pr_state = floor(bits/2)%3
	local signal = param.first_signal
	station.network_name = signal and signal.name or nil
	station.allows_all_trains = bits%2 == 1
	station.is_p = is_pr_state == 0 or is_pr_state == 1
	station.is_r = is_pr_state == 0 or is_pr_state == 2
end
---@param control LuaArithmeticCombinatorControlBehavior
function set_comb_allows_all_trains(control, allows_all_trains)
	local param = control.parameters
	local bits = param.second_constant or 0
	param.second_constant = (bits - bits%2) + (allows_all_trains and 1 or 0)
	control.parameters = param
end
---@param control LuaArithmeticCombinatorControlBehavior
function set_comb_is_pr_state(control, is_pr_state)
	local param = control.parameters
	local bits = param.second_constant or 0
	param.second_constant = (bits%2) + (2*is_pr_state)
	control.parameters = param
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
	local a = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local control = a.parameters
	control.operation = op
	a.parameters = control
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
