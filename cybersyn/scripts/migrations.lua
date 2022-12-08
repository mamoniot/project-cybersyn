local flib_migration = require("__flib__.migration")


local migrations_table = {
	["1.0.3"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		map_data.tick_data = {}
	end,
	["1.0.6"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		map_data.tick_data = {}
		for k, v in pairs(map_data.available_trains) do
			for id, _ in pairs(v) do
				local train = map_data.trains[id]
				train.is_available = true
			end
		end
		for k, v in pairs(map_data.trains) do
			v.depot = nil
			if not v.is_available then
				v.depot_id = nil
			end
		end
	end,
	["1.0.7"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		map_data.tick_data = {}
		map_data.available_trains = {}
		for id, v in pairs(map_data.trains) do
			v.parked_at_depot_id = v.depot_id
			v.depot_id = nil
			v.se_is_being_teleported = not v.entity and true or nil
			--NOTE: we are guessing here because this information was never saved
			v.se_depot_surface_i = v.entity.front_stock.surface.index
			v.is_available = nil
			if v.parked_at_depot_id and v.network_name then
				local network = map_data.available_trains[v.network_name--[[@as string]]]
				if not network then
					network = {}
					map_data.available_trains[v.network_name--[[@as string]]] = network
				end
				network[id] = true
				v.is_available = true
			end
		end
	end,
	["1.0.8"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		map_data.tick_data = {}
		for id, station in pairs(map_data.stations) do
			local params = get_comb_params(station.entity_comb1)
			if params.operation == OPERATION_PRIMARY_IO_FAILED_REQUEST then
				station.display_state = 1
			elseif params.operation == OPERATION_PRIMARY_IO_ACTIVE then
				station.display_state = 2
			else
				station.display_state = 0
			end
			station.display_failed_request = nil
			station.update_display = nil
		end
	end,
	["1.0.10"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		map_data.tick_data = {}
		for id, station in pairs(map_data.stations) do
			station.p_count_or_r_threshold_per_item = nil
		end
	end,
}
--STATUS_R_TO_D = 5

---@param data ConfigurationChangedData
function on_config_changed(data)
	flib_migration.on_config_changed(data, migrations_table)

	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
	if IS_SE_PRESENT and not global.se_tele_old_id then
		global.se_tele_old_id = {}
	end
end
