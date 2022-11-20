local flib_migration = require("__flib__.migration")


local migrations_table = {
	["0.2.0"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		map_data.all_station_ids = {}
		for id, station in pairs(map_data.stations) do
			station.p_count_or_r_threshold_per_item = {}
			station.p_threshold = nil
			station.is_all = nil
			set_station_from_comb_state(station)
			set_combinator_operation(station.entity_comb1, OPERATION_PRIMARY_IO)
			map_data.all_station_ids[#map_data.all_station_ids + 1] = id
		end
	end,
	["0.2.1"] = function()
		---@type MapData
		local map_data = global
		for id, station in pairs(map_data.stations) do
			station.p_threshold = nil
		end
	end,
	["0.3.0"] = function()
		---@type MapData
		local map_data = global
		map_data.warmup_station_ids = {}
		map_data.active_station_ids = map_data.all_station_ids
		map_data.all_station_ids = nil
		mod_settings.warmup_time = settings.global["cybersyn-warmup-time"].value--[[@as int]]
	end,
	["0.4.0"] = function()
		---@type MapData
		local map_data = global
		map_data.is_player_cursor_blueprint = {}
		map_data.to_comb_params = {}
		for id, comb in pairs(map_data.to_comb) do
			map_data.to_comb_params[id] = get_comb_params(comb)
		end
	end,
	["0.4.1"] = function()
		---@type MapData
		local map_data = global
		map_data.tick_state = STATE_INIT
		for id, station in pairs(map_data.stations) do
			station.allows_all_trains = station.allow_all_trains or station.allows_all_trains
			station.allow_all_trains = nil
		end
	end,
}

---@param data ConfigurationChangedData
function on_config_changed(data)
	flib_migration.on_config_changed(data, migrations_table)
end
