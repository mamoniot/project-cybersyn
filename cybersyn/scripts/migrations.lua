local flib_migration = require("__flib__.migration")


local migrations_table = {
	["0.2.0"] = function()
		---@type MapData
		local map_data = global
		for k, station in pairs(map_data.stations) do
			station.p_count_or_r_threshold_per_item = {}
			station.p_threshold = nil
			station.is_all = nil
			set_station_from_comb_state(station)
			set_combinator_operation(station.entity_comb1, OPERATION_PRIMARY_IO)
		end
		map_data.tick_state = STATE_INIT
	end,
}

---@param data ConfigurationChangedData
function on_config_changed(data)
	flib_migration.on_config_changed(data, migrations_table)
end
