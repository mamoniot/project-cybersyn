--By Mami
local flib_migration = require("__flib__.migration")
local manager_gui = require("gui.main")
local debug_revision = require("info")
local check_debug_revision

local migrations_table = {
	["1.0.6"] = function()
		---@type MapData
		local map_data = storage
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
		local map_data = storage
		map_data.available_trains = {}
		for id, v in pairs(map_data.trains) do
			v.parked_at_depot_id = v.depot_id
			v.depot_id = nil
			v.se_is_being_teleported = not v.entity and true or nil
			--NOTE: we are guessing here because this information was never saved
			v.se_depot_surface_i = v.entity.front_stock.surface.index
			v.is_available = nil
			if v.parked_at_depot_id and v.network_name then
				local network = map_data.available_trains[ v.network_name --[[@as string]] ]
				if not network then
					network = {}
					map_data.available_trains[ v.network_name --[[@as string]] ] = network
				end
				network[id] = true
				v.is_available = true
			end
		end
	end,
	["1.0.8"] = function()
		---@type MapData
		local map_data = storage
		for id, station in pairs(map_data.stations) do
			local params = get_comb_params(station.entity_comb1)
			if params.operation == MODE_PRIMARY_IO_FAILED_REQUEST then
				station.display_state = 1
			elseif params.operation == MODE_PRIMARY_IO_ACTIVE then
				station.display_state = 2
			else
				station.display_state = 0
			end
			station.display_failed_request = nil
			station.update_display = nil
		end
	end,
	["1.1.0"] = function()
		---@type MapData
		local map_data = storage
		map_data.refuelers = {}
		map_data.to_refuelers = {}
		for id, station in pairs(map_data.stations) do
			station.p_count_or_r_threshold_per_item = nil
		end

		local OLD_STATUS_R_TO_D = 5
		local NEW_STATUS_TO_D = 5
		local NEW_STATUS_TO_D_BYPASS = 6
		for id, train in pairs(map_data.trains) do
			if train.status == OLD_STATUS_R_TO_D then
				train.manifest = nil
				train.p_station_id = nil
				train.r_station_id = nil
				if train.is_available then
					train.status = NEW_STATUS_TO_D_BYPASS
				else
					train.status = NEW_STATUS_TO_D
				end
			end
		end
	end,
	["1.1.2"] = function()
		---@type MapData
		local map_data = storage
		map_data.refuelers = map_data.refuelers or {}
		map_data.to_refuelers = map_data.to_refuelers or {}
	end,
	["1.1.3"] = function()
		---@type MapData
		local map_data = storage
		for k, v in pairs(map_data.refuelers) do
			if not v.entity_comb.valid or not v.entity_stop.valid then
				map_data.refuelers[k] = nil
			end
		end
	end,
	["1.2.0"] = function()
		---@type MapData
		local map_data = storage

		map_data.each_refuelers = {}
		map_data.se_tele_old_id = nil

		for id, comb in pairs(map_data.to_comb) do
			local control = get_comb_control(comb)
			local params = control.parameters
			local params_old = map_data.to_comb_params[id]
			local bits = params.second_constant or 0
			local bits_old = params_old.second_constant or 0

			local allows_all_trains = bits % 2
			local is_pr_state = math.floor(bits / 2) % 3
			local allows_all_trains_old = bits_old % 2
			local is_pr_state_old = math.floor(bits_old / 2) % 3

			bits = bit32.bor(is_pr_state, allows_all_trains * 4)
			bits_old = bit32.bor(is_pr_state_old, allows_all_trains_old * 4)
			params.second_constant = bits
			params_old.second_constant = bits_old

			control.parameters = params
			map_data.to_comb_params[id] = params_old
		end
		for id, station in pairs(map_data.stations) do
			station.display_state = (station.display_state >= 2 and 1 or 0) + (station.display_state % 2) * 2

			local params = get_comb_params(station.entity_comb1)

			local bits = params.second_constant or 0
			local is_pr_state = bit32.extract(bits, 0, 2)
			local allows_all_trains = bit32.extract(bits, SETTING_DISABLE_ALLOW_LIST) > 0
			local is_stack = bit32.extract(bits, SETTING_IS_STACK) > 0

			station.allows_all_trains = allows_all_trains
			station.is_stack = is_stack
			station.is_p = (is_pr_state == 0 or is_pr_state == 1) or nil
			station.is_r = (is_pr_state == 0 or is_pr_state == 2) or nil
		end

		map_data.layout_train_count = {}
		for id, train in pairs(map_data.trains) do
			map_data.layout_train_count[train.layout_id] = (map_data.layout_train_count[train.layout_id] or 0) + 1
		end
		for layout_id, _ in pairs(map_data.layouts) do
			if not map_data.layout_train_count[layout_id] then
				map_data.layouts[layout_id] = nil
				for id, station in pairs(map_data.stations) do
					station.accepted_layouts[layout_id] = nil
				end
			end
		end
	end,
	["1.2.2"] = function()
		---@type MapData
		local map_data = storage
		local setting = settings.global["cybersyn-invert-sign"]
		setting.value = true
		settings.global["cybersyn-invert-sign"] = setting

		for id, comb in pairs(map_data.to_comb) do
			if comb.valid then
				local control = get_comb_control(comb)
				local params = control.parameters
				local params_old = map_data.to_comb_params[id]
				local bits = params.second_constant or 0
				local bits_old = params_old.second_constant or 0

				bits = bit32.replace(bits, 1, SETTING_ENABLE_INACTIVE) --[[@as int]]
				bits = bit32.replace(bits, 1, SETTING_USE_ANY_DEPOT) --[[@as int]]
				bits_old = bit32.replace(bits_old, 1, SETTING_ENABLE_INACTIVE) --[[@as int]]
				bits_old = bit32.replace(bits_old, 1, SETTING_USE_ANY_DEPOT) --[[@as int]]
				params.second_constant = bits
				params_old.second_constant = bits_old

				control.parameters = params
				map_data.to_comb_params[id] = params_old
			end
		end
		for _, station in pairs(map_data.stations) do
			station.enable_inactive = true
		end
		for train_id, train in pairs(map_data.trains) do
			train.depot_id = train.parked_at_depot_id
			if not train.depot_id then
				if train.entity.valid then
					local e = get_any_train_entity(train.entity)
					if e then
						local stops = e.force.get_train_stops({ name = train.depot_name, surface = e.surface })
						for stop in rnext_consume, stops do
							local new_depot_id = stop.unit_number
							if map_data.depots[new_depot_id] then
								train.depot_id = new_depot_id --[[@as uint]]
								break
							end
						end
					end
				end
			end
			if not train.depot_id then
				train.depot_id = next(map_data.depots)
			end
			if not train.depot_id then
				train.entity.manual_mode = true
				if train.entity.valid then
					send_alert_depot_of_train_broken(map_data, train.entity)
				end
				local layout_id = train.layout_id
				local count = storage.layout_train_count[layout_id]
				if count <= 1 then
					storage.layout_train_count[layout_id] = nil
					storage.layouts[layout_id] = nil
					for _, stop in pairs(storage.stations) do
						stop.accepted_layouts[layout_id] = nil
					end
					for _, stop in pairs(storage.refuelers) do
						stop.accepted_layouts[layout_id] = nil
					end
				else
					storage.layout_train_count[layout_id] = count - 1
				end
				map_data.trains[train_id] = nil
			end

			train.use_any_depot = true
			train.disable_bypass = nil

			train.depot_name = nil
			train.se_depot_surface_i = nil
			train.parked_at_depot_id = nil
		end
	end,
	["1.2.3"] = function()
		---@type MapData
		local map_data = storage
		for _, station in pairs(map_data.stations) do
			set_station_from_comb(station)
		end
	end,
	["1.2.5"] = function()
		---@type MapData
		local map_data = storage
		local setting = settings.global["cybersyn-invert-sign"]
		setting.value = true
		settings.global["cybersyn-invert-sign"] = setting

		for id, comb in pairs(map_data.to_comb) do
			if comb.valid then
				local control = get_comb_control(comb)
				local params = control.parameters
				local params_old = map_data.to_comb_params[id]
				local bits = params.second_constant or 0
				local bits_old = params_old.second_constant or 0

				bits = bit32.replace(bits, 1, SETTING_USE_ANY_DEPOT) --[[@as int]]
				bits_old = bit32.replace(bits_old, 1, SETTING_USE_ANY_DEPOT) --[[@as int]]
				params.second_constant = bits
				params_old.second_constant = bits_old

				control.parameters = params
				map_data.to_comb_params[id] = params_old
			end
		end
		for train_id, train in pairs(map_data.trains) do
			train.use_any_depot = true
		end
	end,
	["1.2.10"] = function()
		---@type MapData
		local map_data = storage
		map_data.warmup_station_cycles = {}

		local is_registered = {}

		for i = #map_data.warmup_station_ids, 1, -1 do
			local id = map_data.warmup_station_ids[i]
			if is_registered[id] then
				table.remove(map_data.warmup_station_ids, i)
			else
				is_registered[id] = true
				map_data.warmup_station_cycles[id] = 0
			end
		end

		for i = #map_data.active_station_ids, 1, -1 do
			local id = map_data.active_station_ids[i]
			if is_registered[id] then
				table.remove(map_data.active_station_ids, i)
			else
				is_registered[id] = true
			end
		end
	end,
	["1.2.15"] = function()
		---@type MapData
		local map_data = storage

		for _, e in pairs(map_data.refuelers) do
			if e.network_flag then
				e.network_mask = e.network_flag
				e.network_flag = nil
			end
		end
		for _, e in pairs(map_data.stations) do
			if e.network_flag then
				e.network_mask = e.network_flag
				e.network_flag = nil
			end
		end
		for _, e in pairs(map_data.trains) do
			if e.network_flag then
				e.network_mask = e.network_flag
				e.network_flag = nil
			end
		end
	end,
	["1.2.16"] = function()
		---@type MapData
		local map_data = storage
		if not map_data.manager then
			map_data.manager = {
				players = {},
			}
			for i, v in pairs(game.players) do
				manager_gui.on_player_created({ player_index = i })
			end
		end
	end,
}
--STATUS_R_TO_D = 5
---@param data ConfigurationChangedData
function on_config_changed(data)
	storage.tick_state = STATE_INIT
	storage.tick_data = {}
	storage.perf_cache = {}

	flib_migration.on_config_changed(data, migrations_table)

	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil

	if storage.debug_revision ~= debug_revision then
		storage.debug_revision = debug_revision
		if debug_revision then
			on_debug_revision_change()
		end
	end
end

---NOTE: this runs before on_config_changed
---It does not have access to game
---NOTE 2: Everything in this section must be idempotent
function on_debug_revision_change()
	local map_data = storage
end
