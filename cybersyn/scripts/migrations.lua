--By Mami
local manager_gui = require("gui.main")
local debug_revision = require("info")
local analytics = require("scripts.analytics")
local check_debug_revision

local version_pattern = "%d+"
local version_format = "%03d"

---@param version string?
---@param format string?
---@return string?
local function format_version(version, format)
	if version then
		format = format or version_format
		local parts = {}
		for part in string.gmatch(version, version_pattern) do
			parts[#parts + 1] = string.format(format, part)
		end
		if next(parts) then
			return table.concat(parts, ".")
		end
	end
	return nil
end

---@param old_version string?
---@param current_version string?
---@return boolean
local function is_newer_version(old_version, current_version)
	local old_normalized = format_version(old_version)
	local current_normalized = format_version(current_version)
	return old_normalized ~= nil and current_normalized ~= nil and current_normalized > old_normalized
end

---@param config_change_data ConfigurationChangedData
---@param migrations table<string, fun()>
local function run_versioned_migrations(config_change_data, migrations)
	local mod_change = config_change_data.mod_changes and config_change_data.mod_changes["cybersyn"]
	local old_version = mod_change and mod_change.old_version
	local new_version = mod_change and mod_change.new_version
	if not old_version or not new_version then return end

	local migration_versions = {}
	for version, _ in pairs(migrations) do
		migration_versions[#migration_versions + 1] = version
	end
	table.sort(migration_versions, is_newer_version)

	for _, version in ipairs(migration_versions) do
		if is_newer_version(old_version, version) and not is_newer_version(new_version, version) then
			migrations[version]()
		end
	end
end

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
		if setting then
			setting.value = true
			settings.global["cybersyn-invert-sign"] = setting
		end

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
						local stops = game.train_manager.get_train_stops({ station_name = train.depot_name, surface = e.surface, force = e.force })
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
		if setting then
			setting.value = true
			settings.global["cybersyn-invert-sign"] = setting
		end

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
	["2.0.21"] = function() -- migrate to the new schedule layout with temporary schedule records
		for _, cybersyn_train in pairs(storage.trains) do
			local train = cybersyn_train.entity --[[@as LuaTrain]]
			if not train or not train.valid or train.manual_mode then
				goto next_train
			end

			local schedule = train.get_schedule()
			if schedule.get_record_count() <= 1 then -- not on a delivery
				goto next_train
			end

			local current = schedule.current
			if current == 1 then -- heading back to the depot
				schedule.set_records({ schedule.get_record({ schedule_index = 1 }) })
				goto next_train
			end

			local old_records = schedule.get_records() --[[@as AddRecordData[] ]]
			local new_records = {}

			-- drop stations that have already been visited and make the rest temporary
			for i = current, #old_records do
				local new_record = old_records[i]
				new_record.temporary = true
				table.insert(new_records, new_record)
			end

			table.insert(new_records, old_records[1]) -- move the depot from the top to the bottom

			schedule.set_records(new_records)
			schedule.go_to_station(1)

			::next_train::
		end
	end,
	["2.0.27"] = function()
		local map_data = storage --[[@as MapData]]

		get_or_create(map_data, "se_elevators")
		get_or_create(map_data, "connected_surfaces")

		for _, cybersyn_train in pairs(map_data.trains) do
			local train = cybersyn_train.entity
			if train and train.valid then
				local depot = map_data.depots[cybersyn_train.depot_id]
				local depot_stop = depot and depot.entity_stop
				cybersyn_train.depot_surface_id = depot_stop and depot_stop.surface_index or train.front_stock.surface_index
			end
		end
	end,
	["2.0.33"] = function()
		-- Add request_start_ticks field to existing stations
		---@type MapData
		local map_data = storage
		for _, station in pairs(map_data.stations) do
			if not station.request_start_ticks then
				station.request_start_ticks = {}
			end
		end
	end,
	["2.0.38"] = function()
		-- Initialize analytics for existing saves (only if enabled)
		if analytics.is_enabled() then
			---@type MapData
			local map_data = storage
			analytics.init(map_data)
		end
	end,
	["2.2.0"] = function()
		---@type MapData
		local map_data = storage

		map_data.recent_external_items = nil
		-- warmup_station_cycles holds every warming station on its own.
		map_data.warmup_station_ids = nil
		-- tick_init refills the economy under the per-stop keys; the per-station ones would only linger.
		map_data.economy = { all_r_stops = {}, all_p_stops = {}, all_names = {}, starved = {} }

		for _, station in pairs(map_data.stations) do
			station.secondary_inv_combs = station.secondary_inv_combs or {}
			-- Moved onto each stop's StopInfo, rebuilt by every poll.
			station.tick_signals = nil
			station.item_p_counts = nil
			-- Wait tracking was optional before and its cleanup hung on the same setting, so entries left from a time
			-- it was on would read as hours-long waits.
			station.request_start_ticks = {}
		end

		-- A network with no available trains has no table; older saves could keep an empty one.
		for network_name, trains in pairs(map_data.available_trains) do
			if next(trains) == nil then map_data.available_trains[network_name] = nil end
		end

		local tick = game.tick
		for _, train in pairs(map_data.trains) do
			local entity = train.entity
			if entity and entity.valid then
				train.last_state = entity.state
				train.state_tick = tick
			end
		end

		local players = map_data.manager and map_data.manager.players
		for _, pd in pairs(players or {}) do
			pd.stations_sort, pd.trains_sort, pd.auto_refresh, pd.pinned = nil, nil, nil, nil
			pd.recent_panel_dirty, pd.disable_top_left_button = nil, nil
			pd.delivery_times_interval, pd.delivery_times_mode, pd.delivery_times_selected = nil, nil, nil
			pd.breakdown_registered = nil
			-- Moved into pd.filters; only transient filter state, so it starts empty.
			pd.search_query, pd.search_network_name, pd.search_network_mask = nil, nil, nil
			pd.search_surface_idx, pd.search_item = nil, nil
			-- The tabs' choices move under pd.tabs; the view caches are rebuilt into pd.cache.
			pd.tabs = pd.tabs or {
				utilization_tab = { interval = pd.utilization_interval, selected = pd.utilization_selected },
				delivery_breakdown_tab = { interval = pd.breakdown_interval },
			}
			pd.utilization_interval, pd.utilization_selected, pd.breakdown_interval = nil, nil, nil
			pd.cache = {}
			pd.utilization_cache, pd.breakdown_cache, pd.utilization_registered, pd.visible = nil, nil, nil, nil
		end
	end,
}

--- Moves each item-hash key of `t` to its migrated name and quality; drops the keys whose name or quality was removed.
---@param t {[string]: any}?
---@param migrations {[string]: {[string]: string}}
---@param removed {[string]: true}? collects the removed names
---@return int gone entries dropped: their item or quality was removed, or their new key was already taken
local function rename_keys(t, migrations, removed)
	if not t then return 0 end
	local moved, gone = {}, 0
	for hash, v in pairs(t) do
		local name, quality = unhash_signal(hash)
		local new_name = migrations.item[name] or migrations.fluid[name]
		local new_quality = quality and migrations.quality[quality]
		if new_name == "" or new_quality == "" then
			t[hash] = nil
			gone = gone + 1
			if removed then removed[name] = true end
		elseif new_name or new_quality then
			local new_hash = hash_item(new_name or name, new_quality or quality)
			if moved[new_hash] then gone = gone + 1 end
			moved[new_hash] = v
			t[hash] = nil
		end
	end
	-- Added after the walk: a key inserted during `pairs` makes the traversal undefined.
	for hash, v in pairs(moved) do
		if t[hash] ~= nil then gone = gone + 1 end
		t[hash] = v
	end
	return gone
end

---@param config_change_data ConfigurationChangedData
function sanitize_economy_names(config_change_data)
	local migrations = config_change_data.migrations --[[@as {[string]: {[string]: string}}]]

	-- migrations seems to have empty tables even for IDTypes without changes but there's no documented guarantee for it
	migrations.fluid = migrations.fluid or {}
	migrations.item = migrations.item or {}
	migrations.quality = migrations.quality or {}
	if not (next(migrations.fluid) or next(migrations.item) or next(migrations.quality)) then return end

	---@type MapData
	local map_data = storage
	local removed = {}

	-- no need to migrate map_data.economy, on_config_changed() sets map_data.tick_state = STATE_INIT which will wipe it

	for _, station in pairs(map_data.stations) do
		rename_keys(station.deliveries, migrations, removed)
	end

	if next(removed) then
		log("Migrated names removed from economy: "..serpent.block(removed, {sortkeys = true}))
	end

	local stats = map_data.stats
	if stats then
		for _, ring in pairs({ stats.minute, stats.hour }) do
			for _, b in pairs(ring) do rename_keys(b.items, migrations) end
		end
		rename_keys(stats.trip_ema, migrations)
	end
	local acks = map_data.acks
	if acks then
		for id, by_hash in pairs(acks.request) do
			acks.n = acks.n - rename_keys(by_hash, migrations)
			if next(by_hash) == nil then acks.request[id] = nil end
		end
	end

	for train_id, train in pairs(map_data.trains) do
		if train.manifest then
			for _, entry in pairs(train.manifest) do
				local type_migrations = migrations[entry.type]
				if not type_migrations then
					local msg = string.format(
						"[Cybersyn] Economy sanitization: no migration data for prototype type '%s' (name: '%s')",
						entry.type, entry.name
					)
					log(msg)
					game.print(msg)
				end
				local new_name = type_migrations and type_migrations[entry.name]
				local new_quality = entry.quality and migrations.quality[entry.quality]
				if new_name == "" or new_quality == "" then
					local msg = string.format("%s delivery aborted: %s/%s no longer exists", train_richtext(train.entity), entry.name, entry.quality or "normal")
					log(msg)
					game.print(msg)
					remove_train(map_data, train_id, train)
				elseif new_name or new_quality then
					entry.name = new_name or entry.name
					entry.quality = new_quality or entry.quality
				end
			end
		end
	end
end

--STATUS_R_TO_D = 5
---@param config_change_data ConfigurationChangedData
function on_config_changed(config_change_data)
	storage.tick_state = STATE_INIT
	storage.tick_data = {}
	storage.perf_cache = {}

	run_versioned_migrations(config_change_data, migrations_table)

	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil

	if storage.debug_revision ~= debug_revision then
		storage.debug_revision = debug_revision
		if debug_revision then
			on_debug_revision_change()
		end
	end

	if config_change_data.migration_applied then
		sanitize_economy_names(config_change_data)
	end

	-- Reshapes the utilization series, moves every chart onto fresh chunks and drops the series no tab draws; on any
	-- change, also for a table an older version left when factorio-charts was missing during the upgrade, so the
	-- samples taken before a tab opens go into the current series.
	if analytics.is_library_available() and (storage.analytics or analytics.is_enabled()) then
		analytics.migrate(storage)
	end

	-- Ensure analytics surface is hidden from map view for all forces
	if storage.analytics and storage.analytics.surface then
		for _, force in pairs(game.forces) do
			force.set_surface_hidden(storage.analytics.surface, true)
		end
		-- Only a factorio-charts update can leave chunks in an older library's style: a chunk allocated since is styled.
		if config_change_data.mod_changes and config_change_data.mod_changes["factorio-charts"] then
			analytics.restyle_chunks(storage)
		end
	end

	retrigger_train_calculation(false)
end

---NOTE: this runs before on_config_changed
---It does not have access to game
---NOTE 2: Everything in this section must be idempotent
function on_debug_revision_change()
	local map_data = storage
end
