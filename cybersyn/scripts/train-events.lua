--By Mami
local min = math.min
local INF = math.huge
local band = bit32.band
local analytics = require("scripts.analytics")
local stats = require("scripts.stats")
local diag = require("scripts.diag")

local NO_FLUIDS = {}

-- One filter table for every count of check_cargo (the engine reads it during the call and keeps nothing).
local COUNT_FILTER = { name = "", quality = "normal" }
-- Percent of a fluid manifest that may be short at the provider or left at the requester before the log records it:
-- fluid transfers rarely end on the exact amount. Items count any shortfall.
local FLUID_TOLERANCE = 2

--- Cargo against the manifest as the train leaves its provider (`at_r` false) or requester. The P side also drives
--- the unexpected-cargo alert, so the log keeps one row for it (the unexpected_cargo event, not an alert event).
--- @param map_data MapData
--- @param train Train
--- @param station Station?
--- @param at_r boolean
local function check_cargo(map_data, train_id, train, station, at_r)
	local manifest = train.manifest
	if not manifest then return end
	local d = map_data.diag
	local alert = not at_r and mod_settings.alert_unexpected_cargo
	if not (d or alert) then return end
	if not at_r and not station.entity_stop.valid then return end
	local entity = train.entity
	local has_fluid = (train.fluid_capacity or 0) > 0
	-- The usual departure has nothing to report: a few counts prove that without building the contents tables.
	if at_r then
		if entity.get_item_count() == 0 and not (has_fluid and entity.get_fluid_count() >= 1) then return end
	else
		local items, fluid, clean = 0, 0, true
		for _, m in ipairs(manifest) do
			if m.type == "fluid" then
				local n = entity.get_fluid_count(m.name)
				if n < m.count * (1 - FLUID_TOLERANCE / 100) then
					clean = false
					break
				end
				fluid = fluid + n
			else
				local q = COUNT_FILTER
				q.name, q.quality = m.name, m.quality or "normal"
				local n = entity.get_item_count(q)
				if n < m.count then
					clean = false
					break
				end
				items = items + n
			end
		end
		if clean and entity.get_item_count() == items and not (has_fluid and entity.get_fluid_count() >= fluid + 1) then
			return
		end
	end
	local contents = entity.get_contents()
	local fluids = has_fluid and entity.get_fluid_contents() or NO_FLUIDS
	local findings, item_extra = diag.cargo_check(manifest, contents, fluids, FLUID_TOLERANCE, at_r)
	if not findings[1] then return end
	if alert and station and item_extra then
		send_alert_unexpected_cargo(map_data, entity, station.entity_stop)
	end
	if d then
		if at_r then
			diag.cargo_events(d, findings, train_id, train, train.r_station_id, train.p_station_id)
		else
			diag.cargo_events(d, findings, train_id, train, train.p_station_id, train.r_station_id)
		end
	end
end

---@param map_data MapData
---@param station Station
---@param manifest Manifest?
---@param sign int?
local function set_comb1(map_data, station, manifest, sign)
	local comb = station.entity_comb1
	if comb.valid then
		if manifest then
			local signals = {}
			for i, item in ipairs(manifest) do
				signals[i] = {
					value = { type = item.type, name = item.name, quality = item.quality or "normal", comparator = "=" },
					min = sign * item.count,
				}
			end
			set_combinator_output(map_data, comb, signals)
		else
			set_combinator_output(map_data, comb, nil)
		end
	end
end

---@param map_data MapData
---@param train_id uint
---@param train Train
---@param cause DiagFail? DIAG_FAIL_* for the diagnostics log
function on_failed_delivery(map_data, train_id, train, cause)
	--NOTE: must either change this train's status or remove it after this call
	local p_station_id = train.p_station_id --[[@as uint]]
	local r_station_id = train.r_station_id --[[@as uint]]
	local manifest = train.manifest --[[@as Manifest]]
	local is_p_in_progress = train.status == STATUS_TO_P or train.status == STATUS_P
	local is_r_in_progress = is_p_in_progress or train.status == STATUS_TO_R or train.status == STATUS_R
	if is_p_in_progress then
		local station = map_data.stations[p_station_id]
		if station then
			remove_manifest(map_data, station, manifest, 1)
			if train.status == STATUS_P then
				set_comb1(map_data, station, nil)
				unset_wagon_combs(map_data, station)
			end
		end
	end
	if is_r_in_progress then
		local station = map_data.stations[r_station_id]
		if station then
			remove_manifest(map_data, station, manifest, -1)
			if train.status == STATUS_R then
				set_comb1(map_data, station, nil)
				unset_wagon_combs(map_data, station)
			end
		end
	end
	if train.has_filtered_wagon then
		train.has_filtered_wagon = nil
		for carriage_i, carriage in ipairs(train.entity.cargo_wagons) do
			local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
			if inv then
				---@type uint
				for i = 1, inv.get_bar() - 1 do
					inv.set_filter(i, nil)
				end
				inv.set_bar()
			end
		end
	end
	if map_data.diag then
		diag.delivery_failed(cause, train_id, train, p_station_id, r_station_id, is_p_in_progress, is_r_in_progress)
	end
	train.r_station_id = nil
	train.p_station_id = nil
	train.manifest = nil
	interface_raise_train_failed_delivery(train_id, is_p_in_progress, p_station_id, is_r_in_progress, r_station_id,
		manifest)
end

---@param map_data MapData
---@param train_id uint
---@param train Train
function add_available_train(map_data, train_id, train)
	if train.network_name then
		local f, a
		if train.network_name == NETWORK_EACH then
			f, a = next, train.network_mask
		else
			f, a = once, train.network_name
		end
		for network_name in f, a do
			local network = map_data.available_trains[network_name]
			if not network then
				network = {}
				map_data.available_trains[network_name] = network
			end
			if not network[train_id] then
				network[train_id] = true
				stats.available_changed(network_name, 1)
			end
		end
		train.is_available = true
		interface_raise_train_available(train_id)
	end
end
---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param depot_id uint
---@param depot Depot
---@param train_id uint
---@param train Train
function add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, depot)
	local comb = depot.entity_comb
	if comb.valid then
		stats.train_networks_changed(train, -1)
		set_train_from_comb(mod_settings, train, comb)
		stats.train_networks_changed(train, 1)
	end
	depot.available_train_id = train_id
	train.depot_id = depot_id
	train.depot_surface_id = depot.entity_stop.surface_index
	train.status = STATUS_D

	add_available_train(map_data, train_id, train)
	if map_data.diag and map_data.diag.full then diag.train_event(DIAG_KIND_RETURNED, train_id, train, depot_id) end
end
---@param map_data MapData
---@param train_id uint
---@param train Train
function remove_available_train(map_data, train_id, train)
	if train.is_available then
		train.is_available = nil
		local f, a
		if train.network_name == NETWORK_EACH then
			f, a = next, train.network_mask
		else
			f, a = once, train.network_name
		end
		for network_name in f, a do
			local network = map_data.available_trains[network_name]
			if network then
				if network[train_id] then
					network[train_id] = nil
					stats.available_changed(network_name, -1)
				end
				if next(network) == nil then
					map_data.available_trains[network_name] = nil
				end
			end
		end
		local depot = map_data.depots[train.depot_id]
		if depot.available_train_id == train_id then
			depot.available_train_id = nil
			return true
		end
	end
	return false
end

---@param map_data MapData
---@param depot_id uint
---@param depot Depot
---@param train_entity LuaTrain
local function on_train_arrives_depot(map_data, depot_id, depot, train_entity)
	local is_train_empty = next(train_entity.get_contents()) == nil and next(train_entity.get_fluid_contents()) == nil
	local train_id = train_entity.id
	local train = map_data.trains[train_id]
	if train then
		if train.status == STATUS_TO_D then
			--shouldn't be possible to get train.status == STATUS_D
		elseif train.status == STATUS_TO_D_BYPASS or train.status == STATUS_D then
			remove_available_train(map_data, train_id, train)
		elseif mod_settings.react_to_train_early_to_depot then
			if train.manifest then
				on_failed_delivery(map_data, train_id, train, DIAG_FAIL_EARLY_TO_DEPOT)
			end
			send_alert_unexpected_train(train.entity)
		else
			return
		end
		if is_train_empty or mod_settings.allow_cargo_in_depot then
			local old_status = train.status
			add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, depot)
			set_depot_schedule(train_entity, depot.entity_stop.backer_name)
			interface_raise_train_status_changed(train_id, old_status, STATUS_D)
		else
			--train still has cargo
			lock_train_to_depot(train_entity, depot.entity_stop.backer_name)
			remove_train(map_data, train_id, train)
			send_alert_nonempty_train_in_depot(map_data, train_entity)
		end
	elseif is_train_empty or mod_settings.allow_cargo_in_depot then
		--NOTE: only place where new Train
		train = {
			entity = train_entity,
			--layout_id = set_train_layout,
			--item_slot_capacity = set_train_layout,
			--fluid_capacity = set_train_layout,
			--status = add_available_train_to_depot,
			p_station_id = 0,
			r_station_id = 0,
			manifest = nil,
			last_manifest_tick = map_data.total_ticks,
			has_filtered_wagon = nil,
			--is_available = add_available_train_to_depot,
			--depot_id = add_available_train_to_depot,
			--use_any_depot = add_available_train_to_depot,
			--disable_bypass = add_available_train_to_depot,
			--network_name = add_available_train_to_depot,
			--network_mask = add_available_train_to_depot,
			--priority = add_available_train_to_depot,
			last_state = train_entity.state,
			state_tick = game.tick,
			seen_tick = game.tick,
			in_interrupt = train_in_interrupt(train_entity),
		} --[[@as Train]]
		set_train_layout(map_data, train)
		map_data.trains[train_id] = train
		add_available_train_to_depot(map_data, mod_settings, train_id, train, depot_id, depot)

		set_depot_schedule(train_entity, depot.entity_stop.backer_name)
		interface_raise_train_created(train_id, depot_id)
	else
		lock_train_to_depot(train_entity, depot.entity_stop.backer_name)
		send_alert_nonempty_train_in_depot(map_data, train_entity)
	end
	if not is_train_empty then
		interface_raise_train_nonempty_in_depot(depot_id, train_entity)
	end
end
---@param map_data MapData
---@param station Station
---@param train_id uint
---@param train Train
local function on_train_arrives_station(map_data, station, train_id, train)
	---@type uint
	if train.status == STATUS_TO_P then
		train.status = STATUS_P
		set_comb1(map_data, station, train.manifest, -1)
		set_p_wagon_combs(map_data, station, train)
		-- Record phase: arrived at provider
		analytics.record_phase_arrive_provider(map_data, train_id)
		if map_data.diag and map_data.diag.full then diag.train_event(DIAG_KIND_ARRIVE_P, train_id, train, train.p_station_id) end
		interface_raise_train_status_changed(train_id, STATUS_TO_P, STATUS_P)
	elseif train.status == STATUS_TO_R then
		train.status = STATUS_R
		set_comb1(map_data, station, train.manifest, 1)
		set_r_wagon_combs(map_data, station, train)
		-- Record phase: arrived at requester
		analytics.record_phase_arrive_requester(map_data, train_id)
		if map_data.diag and map_data.diag.full then diag.train_event(DIAG_KIND_ARRIVE_R, train_id, train, train.r_station_id) end
		interface_raise_train_status_changed(train_id, STATUS_TO_R, STATUS_R)
	end
end

---@param map_data MapData
---@param refueler Refueler
---@param train_id uint
---@param train Train
local function on_train_arrives_refueler(map_data, refueler, train_id, train)
	if train.status == STATUS_TO_F then
		train.status = STATUS_F
		train.refuel_tick = game.tick
		set_refueler_combs(map_data, refueler, train)
		interface_raise_train_status_changed(train_id, STATUS_TO_F, STATUS_F)
	end
end

---@param map_data MapData
---@param train_id uint
---@param train Train
---@param old_status uint
---@param status uint? STATUS_TO_D (the default) or STATUS_TO_D_BYPASS
function send_train_to_depot(map_data, train_id, train, old_status, status)
	train.status = status or STATUS_TO_D
	if not train.use_any_depot then
		-- train using same depot, coord. station was inserted -> we need to color
		color_train_by_stop(train.entity, map_data.depots[train.depot_id].entity_stop)
	end
	interface_raise_train_status_changed(train_id, old_status, train.status)
end

---@param map_data MapData
---@param mod_settings CybersynModSettings
---@param train_id uint
---@param train Train
local function on_train_leaves_stop(map_data, mod_settings, train_id, train)
	if train.status == STATUS_P then
		train.status = STATUS_TO_R
		local p_station = map_data.stations[train.p_station_id]
		if p_station then
			remove_manifest(map_data, p_station, train.manifest, 1)
			set_comb1(map_data, p_station, nil)
			unset_wagon_combs(map_data, p_station)

			check_cargo(map_data, train_id, train, p_station, false)
		end
		if train.has_filtered_wagon then
			train.has_filtered_wagon = nil
			for carriage_i, carriage in ipairs(train.entity.cargo_wagons) do
				local inv = carriage.get_inventory(defines.inventory.cargo_wagon)
				if inv then
					---@type uint
					for i = 1, inv.get_bar() - 1 do
						inv.set_filter(i, nil)
					end
					inv.set_bar()
				end
			end
		end
		local r_station = map_data.stations[train.r_station_id]
		if not r_station then
			-- Requester station removed, delivery cannot continue
			remove_train(map_data, train_id, train)
			lock_train(train.entity)
			send_alert_station_of_train_broken(map_data, train.entity)
			return
		end
		color_train_by_stop(train.entity, r_station.entity_stop)
		-- Record phase: left provider (loading complete)
		analytics.record_phase_leave_provider(map_data, train_id)
		if map_data.diag and map_data.diag.full then diag.train_event(DIAG_KIND_LEAVE_P, train_id, train, train.p_station_id) end
		interface_raise_train_status_changed(train_id, STATUS_P, STATUS_TO_R)
	elseif train.status == STATUS_R then
		local station = map_data.stations[train.r_station_id]
		if station then
			remove_manifest(map_data, station, train.manifest, -1)
			set_comb1(map_data, station, nil)
			unset_wagon_combs(map_data, station)
		end
		--complete delivery
		-- Record delivery completion for analytics (after unloading)
		analytics.record_delivery_complete(map_data, train_id)
		local slow, slow_hash, slow_ticks, slow_avg = stats.record_delivery_complete(train)
		if slow then diag.slow_delivery(train, slow_hash, slow_ticks, slow_avg) end
		if map_data.diag then check_cargo(map_data, train_id, train, station, true) end
		if map_data.diag and map_data.diag.full then diag.train_event(DIAG_KIND_LEAVE_R, train_id, train, train.r_station_id) end
		train.p_station_id = nil
		train.r_station_id = nil
		train.manifest = nil
		--add to available trains for depot bypass
		if not validate_train_base_schedule(map_data, train_id, train) then
			return -- train already removed from Cybersyn
		end

		local fuel_fill = 1
		if mod_settings.fuel_threshold < 1 then
			for _, v in pairs(train.entity.locomotives) do
				for _, loco in pairs(v) do
					local inv = loco.get_fuel_inventory()
					if inv then
						local inv_size = #inv
						if inv_size > 0 then
							local fuel_total = 0
							---@type uint
							for i = 1, inv_size do
								local item = inv[i]
								if item.valid_for_read then
									fuel_total = fuel_total + item.count / get_stack_size(map_data, item.name)
								end
							end
							fuel_fill = min(fuel_fill, fuel_total / inv_size)
						end
					end
				end
			end
		end
		if fuel_fill > mod_settings.fuel_threshold then
			--if fuel_fill == 1, it's probably a modded electric train
			if not train.disable_bypass then
				train.status = STATUS_TO_D_BYPASS
				add_available_train(map_data, train_id, train)
				if not train.use_any_depot then
					-- train using same depot, coord. station was inserted -> we need to color
					color_train_by_stop(train.entity, map_data.depots[train.depot_id].entity_stop)
				end
				interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_D_BYPASS)
				return
			end
		else
			-- Train needs refueled. Locate matching refueler.
			local t_stock = assert(train.entity.front_stock, "train without stock in a train event")
			local t_surface = t_stock.surface_index
			local d_surface = train.depot_surface_id

			local f, a
			if train.network_name == NETWORK_EACH then
				f, a = next, train.network_mask
			else
				f, a = once, train.network_name
			end
			for network_name in f, a do
				local refuelers = map_data.to_refuelers[network_name]
				if refuelers then
					local best_refueler_id = nil
					local best_dist = INF
					local best_prior = -INF
					local best_f_surface
					local best_surface_connections

					for id, _ in pairs(refuelers) do
						local refueler = map_data.refuelers[id]
						if not refueler.entity_stop.valid or not refueler.entity_comb.valid then
							on_refueler_broken(map_data, id, refueler)
						else
							set_refueler_from_comb(map_data, mod_settings, id, refueler)

							local refueler_network_mask = get_network_mask(refueler, network_name)
							local train_network_mask = get_network_mask(train, network_name)
							local netand = band(train_network_mask, refueler_network_mask)
							-- Verify refueler compatibility with train.
							if
								netand ~= 0 and
								(refueler.allows_all_trains or refueler.accepted_layouts[train.layout_id]) and
								refueler.trains_total < refueler.entity_stop.trains_limit
							then
								local f_surface = refueler.entity_stop.surface_index
								if is_train_allowed_to_travel(t_surface, f_surface, d_surface) then
									-- Surface connections are first obtained without a netmask because if there is a refueler the train needs to go there.
									-- If travel is not possible, the train must stop and not head back to the depot where it probably won't be refueled.
									local surface_connections = t_surface == f_surface
										and Surfaces.find_surface_connections(t_surface, d_surface) -- will return {} if all on same surface
										or Surfaces.find_surface_connections(t_surface, f_surface)

									if surface_connections and refueler.priority >= best_prior then
										local t = get_any_train_entity(train.entity)
										local dist = t and get_dist(t, refueler.entity_stop) or INF
										if refueler.priority > best_prior or dist < best_dist then
											best_refueler_id = id
											best_dist = dist
											best_prior = refueler.priority
											best_f_surface = f_surface
											-- now filter by network mask
											best_surface_connections = Surfaces.filter_by_network(surface_connections, network_name, netand)
										end
									end
								end
							end
						end
					end
					if best_refueler_id then
						local refueler = map_data.refuelers[best_refueler_id]

						---@type RefuelSchedulingData
						local data = { -- don't make API calls for information we already have
							train = train, t_id = train_id, t_surface = t_surface,
							t_entity = train.entity,
							t_stock = t_stock,
							t_schedule = train.entity.get_schedule(),

							refueler = refueler, f_id = best_refueler_id, f_surface = best_f_surface,
							f_stop = refueler.entity_stop,

							all_same_surface = t_surface == best_f_surface and t_surface == d_surface,
							surface_connections = best_surface_connections,
						}

						if add_refueler_schedule(map_data, data) then
							train.status = STATUS_TO_F
							train.refueler_id = best_refueler_id
							refueler.trains_total = refueler.trains_total + 1
							color_train_by_stop(train.entity, map_data.refuelers[train.refueler_id].entity_stop)
							interface_raise_train_status_changed(train_id, STATUS_R, STATUS_TO_F)
							return
						end
					end
				end
			end
		end
		--the train has not qualified for depot bypass nor refueling
		send_train_to_depot(map_data, train_id, train, STATUS_R)
	elseif train.status == STATUS_F then
		local refueler = map_data.refuelers[train.refueler_id]
		train.refueler_id = nil
		refueler.trains_total = refueler.trains_total - 1
		unset_wagon_combs(map_data, refueler)
		if refueler.entity_comb.valid then
			set_combinator_output(map_data, refueler.entity_comb, nil)
		end
		if not train.disable_bypass then
			train.status = STATUS_TO_D_BYPASS
			add_available_train(map_data, train_id, train)
		else
			train.status = STATUS_TO_D
		end
		send_train_to_depot(map_data, train_id, train, STATUS_F, train.status)
	elseif train.status == STATUS_D then
		--The train is leaving the depot without a manifest, the player likely intervened
		remove_train(map_data, train_id, train)
	end
end


---@param map_data MapData
---@param train_id uint
---@param train Train
function on_train_broken(map_data, train_id, train)
	--NOTE: train.entity is only absent if the train is climbing a space elevator as of 0.5.0
	if not train.se_is_being_teleported then
		remove_train(map_data, train_id, train)
	end
end
---@param map_data MapData
---@param pre_train_id uint
local function on_train_modified(map_data, pre_train_id)
	local train = map_data.trains[pre_train_id]
	--NOTE: train.entity is only absent if the train is climbing a space elevator as of 0.5.0
	if train and not train.se_is_being_teleported then
		remove_train(map_data, pre_train_id, train)
	end
end


---Whether the train is inside an interrupt: any of its schedule records was inserted by one. Interrupt records exist
---exactly from the insert event to the removal event, while `current` still points at the record being left when the
---insert event fires, so the current record alone would read false for the whole interrupt (measured on 2.1.23).
---@param entity LuaTrain
---@return boolean
function train_in_interrupt(entity)
	local schedule = entity.get_schedule()
	local count = schedule.get_record_count()
	if count == 0 then return false end
	for i = 1, count do
		local record = schedule.get_record({ schedule_index = i })
		if record and record.created_by_interrupt then return true end
	end
	return false
end

---Schedule changes made while the mod was not loaded raised no event, so every cached flag is recomputed.
---@param map_data MapData
function refresh_train_interrupts(map_data)
	for _, train in pairs(map_data.trains) do
		local entity = train.entity
		if entity and entity.valid then train.in_interrupt = train_in_interrupt(entity) end
	end
end

---Keeps Train.in_interrupt current for the dispatcher, which reads it instead of the schedule. Fires on every record
---insert and removal, interrupts and Cybersyn's own schedule writes included, before the writing call returns; an
---interrupt's insert fires before `current` moves, and go_to_station raises nothing (measured on 2.1.23).
---@param event EventData.on_train_schedule_changed
function on_train_schedule_changed(event)
	local train_e = event.train
	if not (train_e and train_e.valid) then return end
	local train = storage.trains[train_e.id]
	if train then
		train.in_interrupt = train_in_interrupt(train_e)
		-- Script writes (Cybersyn's own, interrupts) carry no player; only a player's edit goes to the log.
		local player_index = event.player_index
		if player_index then
			local d = storage.diag
			if d then diag.schedule_edited(d, train_e.id, train, player_index, train_e.group) end
		end
	end
end

function on_train_built(event)
	local train_e = event.train
	if event.old_train_id_1 then
		on_train_modified(storage, event.old_train_id_1)
	end
	if event.old_train_id_2 then
		on_train_modified(storage, event.old_train_id_2)
	end
	local train = train_e and train_e.valid and storage.trains[train_e.id]
	if train then
		train.in_interrupt = train_in_interrupt(train_e)
	end
end
function on_train_changed(event)
	---@type MapData
	local map_data = storage
	local train_e = event.train --[[@as LuaTrain]]
	if not train_e.valid then return end
	local train_id = train_e.id

	local cybersyn_train = map_data.trains[train_id]
	if cybersyn_train then
		local state = train_e.state
		local old_state = cybersyn_train.last_state
		-- process_active_alerts calls this with a made-up event, so only a real change moves the timestamp.
		if state ~= old_state then
			local since = cybersyn_train.state_tick
			cybersyn_train.last_state = state
			cybersyn_train.state_tick = game.tick
			local d = map_data.diag
			if d and d.full then diag.train_state(train_id, cybersyn_train, old_state, since, state) end
		end
	end

	if map_data.active_alerts then
		--remove the alert if the train is interacted with at all
		local data = map_data.active_alerts[train_id]
		if data then
			--we need to wait for the train to come to a stop from being locked
			if data[3] + 10 * mod_settings.tps < map_data.total_ticks then
				map_data.active_alerts[train_id] = nil
				if next(map_data.active_alerts) == nil then
					map_data.active_alerts = nil
				end
			end
		end
	end

	if train_e.state == defines.train_state.wait_station then
		local stop = train_e.station
		if stop and stop.valid and stop.name == "train-stop" then
			-- Arrived at explicitly named stop
			local id = stop.unit_number --[[@as uint]]
			local depot = map_data.depots[id]
			if depot then
				if depot.entity_comb.valid and depot.entity_stop.valid then
					on_train_arrives_depot(map_data, id, depot, train_e)
				else
					on_depot_broken(map_data, id, depot)
				end
			end

			-- Check for invalid usage of priority
			if stop.train_stop_priority ~= 50 then
				-- If train under control of Cybersyn arrives at non default priority station, alert user.
				local train = map_data.trains[train_id]
				if train then
					send_alert_station_non_default_priority(stop)
				end
			end
		else
			-- Arrived at stop specified by coordinates. This event fires
			-- slightly before the train arrives at the real target stop.
			-- NOTE: if Factorio API ever allows sending trains to particular
			-- stops, this will have to be changed.
			local train = map_data.trains[train_id]
			if train then
				local schedule = train_e.get_schedule()
				if schedule then
					local rail = schedule.get_record({schedule_index = schedule.current}).rail
					if rail then
						local id, station, is_station
						if train.status == STATUS_TO_P then
							id = train.p_station_id
							station = map_data.stations[id]
							is_station = true
						elseif train.status == STATUS_TO_R then
							id = train.r_station_id
							station = map_data.stations[id]
							is_station = true
						elseif train.status == STATUS_TO_F then
							id = train.refueler_id
							station = map_data.refuelers[id]
							is_station = false
						end
						if id and station and station.entity_stop.valid and station.entity_stop.connected_rail == rail then
							if is_station then
								if station.entity_comb1 and (not station.entity_comb2 or station.entity_comb2.valid) then
									on_train_arrives_station(map_data, station, train_id, train)
								end
							elseif station.entity_comb.valid then
								on_train_arrives_refueler(map_data, station, train_id, train)
							end
						elseif is_station ~= nil then -- STATUS_TO_(P|R|F) but station is gone
							local record = schedule.get_record({schedule_index = schedule.current})
							if record and record.temporary and not record.station then
								-- Allow temporary stops without removing the train from the network.
								-- This is required for mods like Space Exploration, which insert temporary
								-- waypoints when elevator exits are blocked.
								-- If the train waits here too long, the standard 'stuck train' timeout will still trigger.
								return
							end
							remove_train(map_data, train_id, train)
							lock_train(train_e)
							if is_station then
								send_alert_station_of_train_broken(map_data, train_e)
							else
								send_alert_refueler_of_train_broken(map_data, train_e)
							end
						end
					end
				end
			end
		end
	elseif event.old_state == defines.train_state.wait_station then
		local train = map_data.trains[train_id]
		if train then
			local path = train_e.path
			if path and path.total_distance > 4 then
				-- Check if train has been misdirected along a long rail path due to
				-- the priority of the station at the end.
				local last_rail = path.rails[#path.rails]
				local to_stop = (last_rail and last_rail.valid) and
						(last_rail.get_rail_segment_stop(defines.rail_direction.front) or last_rail.get_rail_segment_stop(defines.rail_direction.back))
				if to_stop and to_stop.train_stop_priority ~= 50 then
					send_alert_station_non_default_priority(to_stop)
					-- Fallthrough: still executing normal cybersyn behavior here even
					-- though it will probably cause a wrong delivery. (This may be
					-- a case where we want to lock the train or give it an invalid
					-- schedule as is done elsewhere in the code.)
				end

				on_train_leaves_stop(map_data, mod_settings, train_id, train)
			elseif not path and (train_e.state == defines.train_state.no_path or train_e.state == defines.train_state.destination_full) then
				-- There is no path to the next stop because path is broken/blocked
				-- or all candidate stops are full. Mark train and do cleanup later
				-- when the train becomes unblocked.
				train.stuck_departure = true
			elseif train_e.get_schedule().get_record_count() == 0 then
				-- There is no path when the schedule runs empty
				on_train_leaves_stop(map_data, mod_settings, train_id, train)
			end
		end
	elseif event.old_state == defines.train_state.no_path or event.old_state == defines.train_state.destination_full then
		local train = map_data.trains[train_id]
		if train and train.stuck_departure then
			if train_e.state == defines.train_state.on_the_path or train_e.state == defines.train_state.manual_control then
				-- finish delayed cleanup
				train.stuck_departure = nil
				on_train_leaves_stop(map_data, mod_settings, train_id, train)
			end
		end
	end
end
