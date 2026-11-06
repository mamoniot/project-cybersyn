-- Incremental snapshot of everything the manager renders, so render code never walks entities or reads
-- circuit signals itself. It only runs while a manager window is open and unpaused (or paused before its first data);
-- after the last close the snapshot is kept, not refreshed, for KEEP_TICKS and then released.
-- Aggregates (inventory_all, starved, station counts) are double-buffered and swap when a pass completes.
-- Station and train records are refilled in place as the pass reaches them, reusing their subtables: a second full
-- copy would roughly double the memory peak (measured ~7.5 MB per copy on a 2,030-station save), and allocating
-- fresh records every pass made the Lua GC run in multi-millisecond steps on large bases.

local rich_name = require("scripts.gui.rich-name")
local diag = require("scripts.diag")
local stats = require("scripts.stats")
local lint = require("scripts.lint")

local collector = {}

-- A full pass over the stations is spread over this many manager updates.
local PASS_UPDATES = 20
local MIN_BATCH = 25
local MAX_BATCH = 200
-- Opening the window on a snapshot older than this starts a fresh pass at BOOST times the batch size, one step per
-- game tick (collector.boost_tick), not per manager update: at the default 1 update/s the pass took 10-11 s of
-- "Collecting…" on a 2,000-station base, while the same 2x step costs 3.7-4.8 ms there, so stepping every tick ends
-- it in 11 ticks. 4x steps took 9-10 ms, past the 5 ms update budget, for 5 ticks less.
local STALE_ON_OPEN_TICKS = 600
local BOOST = 2
-- After the last window closes the snapshot stays this long: a reopen paints its rows at once and the refreshing pass
-- refills records in place (4.6 MB on a 2,000-station base) instead of allocating them (14.6 MB, a GC cycle on most
-- cold opens). Kept, it costs ~10 MB of heap and ~0.3 MB of compressed save there, and no CPU.
collector.KEEP_TICKS = 7200
-- A cold boost shows "Collecting… n %" only once it has run this long: a normal pass ends well before.
collector.NOTE_TICKS = 30
-- Renders owed after a boosted pass completes, one per tick from the next one: the Stations first build needs three
-- (classify, sort, rows), the Trains first page two.
local SETTLE_RENDERS = 4
local IDLE_TICKS = 30 * 60 * 60
local UNLIMITED = TRAIN_LIMIT_UNLIMITED

local WAIT_SIGNAL = defines.train_state.wait_signal
local bor = bit32.bor
local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power

--- Station statuses in severity order: the Stations status sort and chips follow it.
collector.STATUSES = { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok" }
collector.UNLIMITED = UNLIMITED

--- @class SnapshotRequest
--- @field count int negative signal sum
--- @field threshold int effective request threshold in items/fluid units
--- @field active boolean |count| >= threshold

--- @class SnapshotSource
--- @field kind "station"|"inventory"
--- @field index int 0 = station combinator, 1..n = secondary inventory combinators in ascending unit-number order
--- @field unit uint the combinator's unit number
--- @field ok boolean combinator working or low power
--- @field priority int effective priority the planner uses for this source
--- @field read boolean? false for an inventory the planner skips this pass (the station combinator has no input)
--- @field network_mask int|{[string]: int}? the mask (a table of networks on a NETWORK_EACH station) the planner
---   registers this source under; nil for a secondary it does not read (it or the station combinator is off)
--- @field network_name string? the station's network (NETWORK_EACH on such a station, with `networks`)
--- @field mask int? this source's own mask on network_name; nil on NETWORK_EACH, without a network, or unread
--- @field networks {[string]: int}? NETWORK_EACH only: network -> mask this source registers under
--- @field provided {[string]: int} what this combinator advertises; while the station combinator is the only source
---   read these are the record's own st.provided / st.requested / st.ignored (same tables, no copy)
--- @field requested {[string]: SnapshotRequest} active = above this combinator's own threshold, as the planner, which
---   dispatches every inventory as its own stop, reads it
--- @field ignored {[string]: int}
--- @field starved {[string]: true}? active requests of this source nobody provides on its networks, as of the last
---   collector.station_status call
--- @field failed boolean? an inventory combinator whose own request failed to dispatch (station.inv_failed, the red I);
---   nil on the station combinator, whose red S is the station's display_state

--- @class SnapshotInventory one row per combinator, from collector.inventories
--- @field key string collector.row_key: station id .. "@" .. combinator unit number
--- @field st SnapshotStation
--- @field src SnapshotSource
--- @field index int 0 = station combinator, 1.. = inventories in unit-number order
--- @field unit uint
--- @field kind "station"|"inventory"
--- @field priority int the priority the planner uses for this combinator
--- @field ok boolean
--- @field read boolean false for an inventory the planner skips this pass (it advertises nothing then)
--- @field network_name string?
--- @field mask int?
--- @field networks {[string]: int}?
--- @field provided {[string]: int}
--- @field requested {[string]: SnapshotRequest}
--- @field ignored {[string]: int}
--- @field starved {[string]: true}?
--- @field failed boolean the inventory combinator shows the red I (its own request failed); false on the station row
--- @field label LocalisedString collector.source_label of the source

--- @class SnapshotStation
--- @field id uint
--- @field name string full rich-text backer name
--- @field name_lower string
--- @field name_parts RichNameParts parsed from name, looked up again only when the name changes; shared, read-only
--- @field status string one of collector.STATUSES, see collector.station_status
--- @field surface_index uint
--- @field network_name string?
--- @field network_mask int|{[string]: int}
--- @field is_p boolean
--- @field is_r boolean
--- @field is_stack boolean
--- @field comb_ok boolean station combinator working or low power
--- @field comb2_ok boolean? nil when the station has no control combinator
--- @field warming_up boolean
--- @field trains_limit int
--- @field deliveries_total int
--- @field last_delivery_tick int?
--- @field priority int?
--- @field provided {[string]: int}
--- @field requested {[string]: SnapshotRequest}
--- @field deliveries {[string]: int} >0 incoming, <0 outgoing
--- @field control {[string]: int} virtual signals on the station combinator
--- @field control2 {[string]: int} virtual signals on the control combinator
--- @field thresholds {[string]: int} per-item request thresholds from the control combinator, in items
--- @field wait {[string]: uint} request start tick per item hash
--- @field longest_wait_start uint?
--- @field secondary boolean
--- @field secondary_count int
--- @field rows SnapshotInventory[] collector.inventories: one per source, in index order, refilled each pass
--- @field sources SnapshotSource[] all sources, index order (sources[1] is the station combinator)
--- @field ignored {[string]: int} item signals of every source the P/R switch keeps from being advertised (signed sum)
---   (provided / requested / ignored are plain sums over every source)
--- @field read_tick uint game tick this record was last refreshed
--- @field lint int bitmask of setup findings, written by the lint job; 0 until its first pass
--- @field unserved {count: int, worst_reason: int, oldest_first_tick: uint}? copy of the station's diagnostics
---   entries as of read_tick; nil when it has none or diagnostics are off
--- @field throttling boolean an unacknowledged unserved request names this station at its train limit (R_AT_LIMIT as
---   the requester, P_AT_LIMIT as the best provider), as of the start of the pass that read it

--- @class SnapshotTrain
--- @field id uint
--- @field status uint STATUS_*
--- @field layout_id uint?
--- @field depot_id uint?
--- @field depot_name string
--- @field network_name string?
--- @field network_mask int|{[string]: int}
--- @field p_station_id uint?
--- @field r_station_id uint?
--- @field refueler_id uint?
--- @field manifest {name: string, quality: string?, count: int, hash: string}[]
--- @field manifest_hashes {[string]: int}
--- @field surface_index uint?
--- @field is_available boolean
--- @field disable_bypass boolean the train may not skip its depot (Train.disable_bypass)
--- @field state defines.train_state? LuaTrain.state
--- @field state_since uint? tick the train entered `state` (Train.state_tick; the load tick for older trains)
--- @field in_interrupt boolean current schedule record was inserted by an interrupt
--- @field signal_unit_number uint? the signal it waits at, while state is wait_signal
--- @field has_path boolean?
--- @field in_group boolean the train belongs to a vanilla train group (LuaTrain.group ~= "")
--- @field group string? that group's name
--- @field refuel_tick uint? last arrival at a refueler (Train.refuel_tick)
--- @field refuel_from uint? since when refuelling is tracked for this train (lint.refuel_from): a train without a
---   refuel_tick is "not refuelled" only once it is older than the threshold from here

--- @class SnapshotDepotGroup depots sharing one name (the Trains tab's group rows)
--- @field ids uint[] depot stop unit numbers
--- @field limit int sum of the stops' train limits (collector.UNLIMITED when any has none)
--- @field count int sum of the stops' vanilla trains_count
--- @field parked int depots with a train parked
--- @field inbound int trains on their way to one of these depots
--- @field trains_bound int Cybersyn trains whose depot is one of these
--- @field compositions {[uint]: int} layout id -> trains bound
--- @field same_depot_bypass int bound trains that require their own depot with depot bypass on

--- @class Snapshot
--- @field tick uint? game tick the last pass completed; nil = never collected
--- @field started_tick uint
--- @field pass int? counts completed passes; two passes can complete on one tick (collector.run_to_completion)
--- @field boosted true? completed by the opening boost (collector.boost_tick): views may defer a full rebuild to the
---   next render; cleared when the snapshot is kept past a close
--- @field station_count int
--- @field train_count int
--- @field trains_version int bumped whenever trains, fleet, depots and alerts are summarised again
--- @field secondary_count int stations with at least one secondary inventory combinator contributing
--- @field stations {[uint]: SnapshotStation} updated in place during a pass; each record is at most one pass old
--- @field trains {[uint]: SnapshotTrain}
--- @field item_stations {[string]: uint[]}? stations providing, requesting or with a delivery of each item (complete pass)
--- @field inventory_all {provided: {[string]: {count: int, stations: int}}, requested: {[string]: {count: int, stations: int, earliest_wait_start: uint?}}, in_transit: {[string]: {count: int, stations: int}}}
--- @field starved {[string]: true} "network:hash" request keys with no provider on that network, as the planner
---   published them at the end of its last poll
--- @field starved_items {[string]: true}
--- @field starved_version int bumped only when the contents of `starved` change; equal sets keep their table
--- @field fleet SnapshotFleet
--- @field depots {total: int, parked: int}
--- @field depots_by_name {[string]: SnapshotDepotGroup} built in the chunked pass (depot stops) and the fleet summary (trains)
--- @field request_keys {[string]: true} "network:hash" keys of the active requests, as of the pass (Inventory's
---   Dim unrequested reads them against provider_masks)
--- @field provider_masks {[string]: int} "network:hash" -> OR of the network masks of the stations providing it, as of
---   the last complete pass (the lint engine's requester-vs-provider mask check)
--- @field provider_overrides {[string]: number} "network:hash" -> the lowest item threshold (in items or fluid units) a
---   provider of it sets; the dispatcher uses it instead of the requester's when it is lower (the lint's capacity check)
--- @field alerts {train_id: uint, kind: int, since_tick: int}[]
--- @field station_ids uint[]? the station ids this snapshot's pass walked, sorted (a complete pass only)
--- @field depot_ids uint[]? the depot ids, sorted

--- @class SnapshotFleet
--- @field total int
--- @field by_status {[uint]: int}
--- @field available_by_network {[string]: int}
--- @field by_layout {[uint]: int}
--- @field min_available_by_network {[string]: int} fewest available trains per network over the last hour (stats)
--- @field capability {[string]: {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}}} per network
---   and layout: Cybersyn trains, the largest capacities among them and the OR of their masks on that network
--- @field mask_or {[string]: int} OR of every Cybersyn train's mask on the network
--- @field in_interrupt_count {[string]: int} trains inside an interrupt, per network
--- @field group_depots {[string]: int} vanilla train group -> distinct depot names among its Cybersyn trains

local function new_inventory()
	return { provided = {}, requested = {}, in_transit = {} }
end

--- @return Snapshot
function collector.empty()
	return {
		tick = nil,
		started_tick = 0,
		station_count = 0,
		train_count = 0,
		secondary_count = 0,
		stations = {},
		trains = {},
		trains_version = 0,
		inventory_all = new_inventory(),
		starved = {},
		starved_items = {},
		starved_version = 0,
		fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {}, min_available_by_network = {},
			capability = {}, mask_or = {}, in_interrupt_count = {}, group_depots = {} },
		depots = { total = 0, parked = 0 },
		depots_by_name = {},
		provider_masks = {},
		provider_overrides = {},
		request_keys = {},
		alerts = {},
	}
end

--- Called from on_init and on_migration; a stored snapshot may hold an outdated shape, and migration closes
--- every window anyway, so both buffers start over.
function collector.init()
	local manager = storage.manager
	manager.snapshot = collector.empty()
	manager.snapshot_build = nil
	manager.collect_boost = nil
	manager.collect_quiet = nil
	manager.collect_spare = nil
	manager.name_parts = nil
	manager.release_at = nil
	manager.settle = nil
	manager.settle_tick = nil
	-- A Stations query cache indexes records of the snapshot just replaced.
	for _, player_data in pairs(manager.players or {}) do player_data.cache.stations = nil end
	collector.reset_log()
end

--- Starts a new change log epoch: readers holding a position from an older epoch must rebuild from scratch.
function collector.reset_log()
	local manager = storage.manager
	local old = manager.collect_log
	manager.collect_log = { epoch = (old and old.epoch or 0) + 1, base = 0, ids = {} }
end

--- Ids of station records replaced or removed since `pos`, so per-player caches can update only those.
--- Returns nil when the caller's position is from another epoch or no longer covered by the log.
--- @param epoch int?
--- @param pos int?
--- @return uint[]? ids
--- @return integer first index into ids
--- @return integer last index into ids
function collector.changed_since(epoch, pos)
	local log = storage.manager.collect_log
	if not log or not epoch or not pos or log.epoch ~= epoch then return nil, 0, 0 end
	local n = #log.ids
	if pos < log.base or pos > log.base + n then return nil, 0, 0 end
	return log.ids, pos - log.base + 1, n
end

--- Stations the running pass refilled since the last completed pass, nil before the log exists.
--- @return uint[]? ids
function collector.changed_this_pass()
	local log = storage.manager.collect_log
	return log and log.ids
end

--- @return int epoch
--- @return int pos
function collector.log_position()
	local log = storage.manager.collect_log
	if not log then
		collector.reset_log()
		log = storage.manager.collect_log
	end
	return log.epoch, log.base + #log.ids
end

local function log_change(id)
	local log = storage.manager.collect_log
	if not log then
		collector.reset_log()
		log = storage.manager.collect_log
	end
	log.ids[#log.ids + 1] = id
end

local function any_open(manager)
	for _, player_data in pairs(manager.players) do
		if player_data.is_manager_open then return true end
	end
	return false
end

-- A half-done lint pass holds an occupancy index of this moment and gap timestamps nobody refreshes while the window
-- is closed; resumed hours later they would turn stale counts into findings. The masks of the last complete pass
-- stay, so a reopened window shows them until the next pass ends.
local function drop_lint_job(manager)
	local s = manager.lint
	if s then
		s.job = nil
		s.occupancy_since = {}
		s.phantom_since = {}
	end
end

local function release(manager)
	drop_lint_job(manager)
	-- Kept past the close with the snapshot it indexes (nav.close_manager_window).
	for _, player_data in pairs(manager.players) do player_data.cache.stations = nil end
	manager.snapshot = collector.empty()
	manager.snapshot_build = nil
	manager.collect_boost = nil
	manager.collect_quiet = nil
	manager.collect_spare = nil
	manager.name_parts = nil
	manager.release_at = nil
	manager.settle = nil
	manager.settle_tick = nil
	collector.reset_log()
end

--- Drops both buffers at once when no window is open (a removed player): the snapshot is several MB on large bases
--- and would otherwise be written into every save. Opening a window rebuilds it through ensure_fresh.
function collector.release_if_unused()
	local manager = storage.manager
	if not manager or any_open(manager) then return end
	if manager.snapshot and manager.snapshot.tick == nil and not manager.snapshot_build then
		-- A cold open closed before its first step: the boost would keep the per-tick handler busy, and a later
		-- open would inherit its start tick and show the note at once.
		manager.release_at = nil
		manager.collect_boost = nil
		manager.collect_quiet = nil
		manager.settle = nil
		return
	end
	release(manager)
end

--- The last window closed: the lint job and a running pass stop, the snapshot, its name parts and the change log
--- stay until collector.release_due frees them KEEP_TICKS later.
function collector.on_last_close()
	local manager = storage.manager
	if not manager or any_open(manager) then return end
	local snapshot = manager.snapshot
	if not (snapshot and snapshot.tick) then
		collector.release_if_unused()
		return
	end
	drop_lint_job(manager)
	manager.snapshot_build = nil
	manager.collect_boost = nil
	manager.collect_quiet = nil
	manager.settle = nil
	-- The views' deferral of a first build follows a boosted pass that just completed, not one from before the close.
	snapshot.boosted = nil
	manager.release_at = game.tick + collector.KEEP_TICKS
end

--- Frees a kept snapshot once its grace period is over and no window is open (the per-tick handler, only while
--- storage.manager.release_at is set).
function collector.release_due()
	local manager = storage.manager
	local at = manager and manager.release_at
	if not at or game.tick < at then return end
	if any_open(manager) then
		manager.release_at = nil
		return
	end
	release(manager)
end

--- The snapshot while some window keeps it current (collector.wanted), else nil: a panel showing a stop while the
--- manager is closed reads the stop live rather than a snapshot kept from before the close.
--- @return Snapshot?
function collector.live()
	local manager = storage.manager
	local snapshot = manager and manager.snapshot
	if snapshot and snapshot.tick and collector.wanted() then return snapshot end
	return nil
end

--- The last complete snapshot (never nil).
--- @return Snapshot
function collector.get()
	local manager = storage.manager
	local snapshot = manager.snapshot
	if not snapshot then
		snapshot = collector.empty()
		manager.snapshot = snapshot
		collector.reset_log()
	end
	return snapshot
end

local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

--- Makes `dst` hold exactly the entries of `src` (nil = none) without replacing it; keys it already had keep their
--- place in its iteration order.
--- @param dst table
--- @param src table?
--- @return table dst
local function refill(dst, src)
	if src then
		for k in pairs(dst) do
			if src[k] == nil then dst[k] = nil end
		end
		for k, v in pairs(src) do
			if dst[k] ~= v then dst[k] = v end
		end
	else
		for k in pairs(dst) do dst[k] = nil end
	end
	return dst
end

--- A network mask is a number or {[network]: mask}; an equal table keeps the old copy.
--- @param old int|{[string]: int}?
--- @param new int|{[string]: int}?
local function mask_of(old, new)
	if type(new) ~= "table" then return new end
	if type(old) == "table" then
		local same = true
		for k, v in pairs(new) do
			if old[k] ~= v then same = false break end
		end
		if same then
			for k in pairs(old) do
				if new[k] == nil then same = false break end
			end
		end
		if same then return old end
	end
	return copy(new)
end

-- In-place refills of count maps: mark every entry, let the read overwrite what is still there, drop the rest.
-- Provided counts are > 0 and request counts < 0, so 0 marks a stale entry; signal maps use false.
local function mark_counts(t)
	for k in pairs(t) do t[k] = 0 end
end
local function sweep_counts(t)
	for k, v in pairs(t) do
		if v == 0 then t[k] = nil end
	end
end
local function mark_requests(t)
	for _, req in pairs(t) do req.count = 0 end
end
local function sweep_requests(t)
	for k, req in pairs(t) do
		if req.count == 0 then t[k] = nil end
	end
end
local function mark_signals(t)
	for k in pairs(t) do t[k] = false end
end
local function sweep_signals(t)
	for k, v in pairs(t) do
		if v == false then t[k] = nil end
	end
end

-- The networks of the combinator being read. Only indices 1..nets_n are ever read, so what earlier calls left behind
-- cannot reach game state.
local nets = {}
local net_masks = {}
local nets_n = 0

local function push_network(name, mask)
	nets_n = nets_n + 1
	nets[nets_n] = name
	net_masks[nets_n] = mask
end

--- @param network_name string?
--- @param network_mask any
local function set_networks(network_name, network_mask)
	nets_n = 0
	each_network(network_name, network_mask, push_network)
end

local function has_active_request(st)
	for _, req in pairs(st.requested) do
		if req.active then return true end
	end
	return false
end

--- Game ticks per planner tick, the nth register_tick runs the planner on; nil at 0 tps, where total_ticks stops and
--- planner-tick stamps cannot be turned into ages. Uses the current setting, so a tps change rescales old stamps.
--- @return integer?
local function ticks_per_planner_tick()
	local tps = mod_settings.tps
	return tps and tps > 0 and math.ceil(60 / tps) or nil
end

--- Game ticks since the station's last delivery; last_delivery_tick counts planner ticks, not game ticks.
--- @param st SnapshotStation
--- @return number?
function collector.delivery_age(st)
	local last = st.last_delivery_tick
	local factor = ticks_per_planner_tick()
	if not last or not factor then return nil end
	return math.max(0, (storage.total_ticks or 0) - last) * factor
end

--- The station-wide check, for records without rows (hand-built ones).
--- @param st SnapshotStation
--- @param hash string
--- @param starved {[string]: true}
local function request_starved(st, hash, starved)
	local name = st.network_name
	if name == NETWORK_EACH then
		local mask = st.network_mask
		if type(mask) == "table" then
			for net in pairs(mask) do
				if starved[net .. ":" .. hash] then return true end
			end
		end
		return false
	end
	return starved[name .. ":" .. hash] == true
end

--- Whether `row`'s networks hold `hash` in `starved`: a NETWORK_EACH combinator registers under each of its own
--- networks, every other one under the station's network.
--- @param row SnapshotInventory
--- @param hash string
--- @param starved {[string]: true}
local function row_key_starved(row, hash, starved)
	local nets = row.networks
	if nets then
		for net in pairs(nets) do
			if starved[net .. ":" .. hash] then return true end
		end
		return false
	end
	local name = row.network_name
	if not name or name == NETWORK_EACH then return false end
	return starved[name .. ":" .. hash] == true
end

--- Whether a combinator with an active request for `hash` finds no provider on its own networks: the planner
--- dispatches every inventory as its own stop, so one inventory can starve while another provides nothing of it.
--- @param rows SnapshotInventory[]
local function rows_starved(rows, hash, starved)
	for i = 1, #rows do
		local row = rows[i]
		local req = row.requested[hash]
		if req and req.active and row_key_starved(row, hash, starved) then return true end
	end
	return false
end

--- Active requests of `st` with no provider on the networks of a combinator requesting them, in `requested` order;
--- false when none.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string[]|false
function collector.starved_hashes(st, starved)
	if not st.network_name or st.warming_up or not next(starved) then return false end
	local rows = st.rows
	local hashes = false
	for hash, req in pairs(st.requested) do
		if req.active then
			local hit
			if rows then
				hit = rows_starved(rows, hash, starved)
			else
				hit = request_starved(st, hash, starved)
			end
			if hit then
				hashes = hashes or {}
				hashes[#hashes + 1] = hash
			end
		end
	end
	return hashes
end

--- Refills every row's (and its source's) `starved` against `starved`; a source keeps its table while it stays
--- starved.
--- @return boolean any
local function refresh_row_starved(st, starved)
	local rows = st.rows
	local check = st.network_name ~= nil and not st.warming_up and next(starved) ~= nil
	local any = false
	for i = 1, #rows do
		local row = rows[i]
		local src = row.src
		local out = src.starved
		if out then
			for k in pairs(out) do out[k] = nil end
		end
		if check then
			for hash, req in pairs(row.requested) do
				if req.active and row_key_starved(row, hash, starved) then
					if not out then
						out = {}
						src.starved = out
					end
					out[hash] = true
					any = true
				end
			end
		end
		if out and next(out) == nil then
			out = nil
			src.starved = nil
		end
		if row.starved ~= out then row.starved = out end
	end
	return any
end

local function is_starved(st, starved)
	if not st.network_name or st.warming_up or not next(starved) then return false end
	for hash, req in pairs(st.requested) do
		if req.active and request_starved(st, hash, starved) then return true end
	end
	return false
end

--- The one station status every view shows, first match in collector.STATUSES order. "saturated" means
--- the station's deliveries reached a finite train limit.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string
function collector.station_status(st, starved)
	-- Before the early returns, so no row keeps the starved requests of an earlier set.
	local starving
	if st.rows then
		starving = refresh_row_starved(st, starved)
	end
	if not st.comb_ok then return "no_power" end
	if st.trains_limit == 0 then return "disabled" end
	if st.warming_up then return "warming_up" end
	if starving == nil then starving = is_starved(st, starved) end
	if starving then return "starved" end
	local limit = st.trains_limit
	if limit < UNLIMITED and st.deliveries_total >= limit then return "saturated" end
	if st.deliveries_total == 0 and not has_active_request(st) then
		local age = collector.delivery_age(st)
		if age and age > IDLE_TICKS then return "idle" end
	end
	return "ok"
end

local function same_manifest(old, manifest)
	local n = manifest and #manifest or 0
	if #old ~= n then return false end
	for i = 1, n do
		local a, m = old[i], manifest[i]
		if a.name ~= m.name or a.quality ~= m.quality or a.count ~= m.count then return false end
	end
	return true
end

--- Adds one train to the per-network fleet facts on `network`, whose mask for the train is `mask`.
local function add_capability(fleet, network, mask, train)
	local by_layout = fleet.capability[network]
	if not by_layout then
		by_layout = {}
		fleet.capability[network] = by_layout
	end
	local layout_id = train.layout_id or 0
	local c = by_layout[layout_id]
	if not c then
		c = { count = 0, item_capacity = 0, fluid_capacity = 0, mask_or = 0 }
		by_layout[layout_id] = c
	end
	c.count = c.count + 1
	local items, fluid = train.item_slot_capacity or 0, train.fluid_capacity or 0
	if items > c.item_capacity then c.item_capacity = items end
	if fluid > c.fluid_capacity then c.fluid_capacity = fluid end
	c.mask_or = bor(c.mask_or, mask)
	fleet.mask_or[network] = bor(fleet.mask_or[network] or 0, mask)
	if train.in_interrupt then
		fleet.in_interrupt_count[network] = (fleet.in_interrupt_count[network] or 0) + 1
	end
end

local function summarize_trains(b)
	-- Refilled straight in the live snapshot for the same memory reason as station records.
	local live = collector.get()
	local trains = live.trains
	local fleet = { total = 0, by_status = {}, available_by_network = {}, by_layout = {},
		min_available_by_network = stats.min_available(60), capability = {}, mask_or = {}, in_interrupt_count = {},
		group_depots = {} }
	local group_names = {}
	local by_name = {}
	b.depots_by_name = by_name
	local depot_names = {}
	local depots = storage.depots
	local storage_trains = storage.trains
	for id in pairs(trains) do
		local train = storage_trains[id]
		local entity = train and train.entity
		if not (entity and entity.valid) then trains[id] = nil end
	end
	for id, train in pairs(storage_trains) do
		local entity = train.entity
		if entity and entity.valid then
			local depot_id = train.depot_id
			local depot_name = depot_id and depot_names[depot_id]
			if depot_id and not depot_name then
				local depot = depots[depot_id]
				local stop = depot and depot.entity_stop
				depot_name = (stop and stop.valid) and stop.backer_name or ""
				depot_names[depot_id] = depot_name
			end
			local tr = trains[id]
			if not tr then
				tr = { id = id, manifest = {}, manifest_hashes = {} }
				trains[id] = tr
			end
			if not same_manifest(tr.manifest, train.manifest) then
				local manifest = {}
				local manifest_hashes = {}
				if train.manifest then
					for i, item in ipairs(train.manifest) do
						local hash = hash_item(item.name, item.quality)
						manifest[i] = { name = item.name, quality = item.quality, count = item.count, hash = hash }
						manifest_hashes[hash] = (manifest_hashes[hash] or 0) + item.count
					end
				end
				tr.manifest = manifest
				tr.manifest_hashes = manifest_hashes
			end
			local any = get_any_train_entity(entity)
			tr.status = train.status
			tr.layout_id = train.layout_id
			tr.depot_id = depot_id
			-- Collectable values are written only when they change: rewriting a table during a GC cycle queues it for
			-- the collector's atomic step again.
			depot_name = depot_name or ""
			if tr.depot_name ~= depot_name then tr.depot_name = depot_name end
			if tr.network_name ~= train.network_name then tr.network_name = train.network_name end
			local mask = mask_of(tr.network_mask, train.network_mask)
			if tr.network_mask ~= mask then tr.network_mask = mask end
			tr.p_station_id = train.p_station_id
			tr.r_station_id = train.r_station_id
			tr.refueler_id = train.refueler_id
			tr.surface_index = any and any.surface_index or nil
			tr.is_available = train.is_available == true
			tr.disable_bypass = train.disable_bypass == true
			local state = entity.state
			tr.state = state
			tr.state_since = train.state_tick
			tr.in_interrupt = train.in_interrupt == true
			if state == WAIT_SIGNAL then
				local signal = entity.signal
				tr.signal_unit_number = signal and signal.valid and signal.unit_number or nil
			else
				tr.signal_unit_number = nil
			end
			tr.has_path = entity.has_path
			local group = entity.group
			tr.in_group = group ~= nil and group ~= ""
			if tr.group ~= group then tr.group = group end
			if tr.in_group then
				local names = group_names[group]
				if not names then
					names = {}
					group_names[group] = names
					fleet.group_depots[group] = 0
				end
				local home = depot_name
				if home ~= "" and not names[home] then
					names[home] = true
					fleet.group_depots[group] = fleet.group_depots[group] + 1
				end
			end
			local refuel_tick = train.refuel_tick
			tr.refuel_tick = refuel_tick
			local refuel_from = lint.refuel_from(train)
			tr.refuel_from = refuel_from
			each_network(train.network_name, train.network_mask, function(name, m) add_capability(fleet, name, m, train) end)
			if depot_name ~= "" then
				local g = by_name[depot_name]
				if not g then
					g = { ids = {}, limit = 0, count = 0, parked = 0, inbound = 0, trains_bound = 0, compositions = {},
						same_depot_bypass = 0 }
					by_name[depot_name] = g
				end
				g.trains_bound = g.trains_bound + 1
				local layout_id = train.layout_id
				if layout_id then g.compositions[layout_id] = (g.compositions[layout_id] or 0) + 1 end
				local status = train.status
				if status == STATUS_TO_D or status == STATUS_TO_D_BYPASS then g.inbound = g.inbound + 1 end
				if not train.use_any_depot and not train.disable_bypass then
					g.same_depot_bypass = g.same_depot_bypass + 1
				end
			end
			fleet.total = fleet.total + 1
			local status = train.status or STATUS_D
			fleet.by_status[status] = (fleet.by_status[status] or 0) + 1
			if train.layout_id then
				fleet.by_layout[train.layout_id] = (fleet.by_layout[train.layout_id] or 0) + 1
			end
		end
	end
	for network_name, ids in pairs(storage.available_trains or {}) do
		local n = 0
		for _ in pairs(ids) do
			n = n + 1
		end
		fleet.available_by_network[network_name] = n
	end

	local depot_total, parked = 0, 0
	for _, depot in pairs(depots) do
		depot_total = depot_total + 1
		if depot.available_train_id then parked = parked + 1 end
	end

	local alerts = {}
	-- At 0 tps an alert's age freezes at what it was when the planner stopped.
	local factor = ticks_per_planner_tick() or 1
	for train_id, data in pairs(storage.active_alerts or {}) do
		local since = data[3] and (game.tick - (storage.total_ticks - data[3]) * factor) or game.tick
		alerts[#alerts + 1] = { train_id = train_id, kind = data[2], since_tick = since }
	end
	table.sort(alerts, function(a, c) return a.train_id < c.train_id end)

	live.train_count = fleet.total
	live.trains_version = (live.trains_version or 0) + 1
	live.fleet = fleet
	live.depots = { total = depot_total, parked = parked }
	live.depots_by_name = live.depots_by_name or {}
	live.provider_masks = live.provider_masks or {}
	live.request_keys = live.request_keys or {}
	live.provider_overrides = live.provider_overrides or {}
	live.alerts = alerts
	b.trains = nil
end

--- Pass bookkeeping tables (seen ids, request and provide keys) are handed from one pass to the next and cleared
--- instead of being allocated again.
--- @param manager Manager
--- @param name string
local function spare(manager, name)
	local spares = manager.collect_spare
	local t = spares and spares[name]
	if not t then return {} end
	spares[name] = nil
	for k in pairs(t) do t[k] = nil end
	return t
end

--- Stations a live, unacknowledged unserved request names at a train limit: the requester for R_AT_LIMIT, the
--- best provider for P_AT_LIMIT. One walk over the diagnostics state per pass (~135 entries on a 2,000-station base).
--- @return {[uint]: true}
local function throttled_stations()
	local out = {}
	local d = storage.diag
	if not d then return out end
	local acks = storage.acks
	local ack_requests = acks and acks.request
	local hashes = d.item_hash
	for r_id, by_item in pairs(d.unserved) do
		local by_ack = ack_requests and ack_requests[r_id]
		for ix, e in pairs(by_item) do
			local reason = e.reason
			local target = reason == REASON_R_AT_LIMIT and r_id or reason == REASON_P_AT_LIMIT and e.p_station_id or nil
			if target and not out[target] then
				local hash = by_ack and hashes[ix]
				if not (hash and by_ack[hash] and diag.is_acked("request", r_id, hash)) then out[target] = true end
			end
		end
	end
	return out
end

local function start_pass(manager)
	local ids = {}
	for id in pairs(storage.stations) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	local b = collector.empty()
	b.stations = nil
	b.started_tick = game.tick
	b.pass = (collector.get().pass or 0) + 1
	b.ids = ids
	b.i = 0
	b.seen = spare(manager, "seen")
	b.r_keys = spare(manager, "r_keys")
	b.p_keys = spare(manager, "p_keys")
	b.p_over = spare(manager, "p_over")
	-- Every reader is at most one update behind, so entries from the previous pass are no longer needed.
	local log = manager.collect_log
	if log then
		log.base = log.base + #log.ids
		log.ids = {}
	end
	local depot_ids = {}
	for id in pairs(storage.depots) do
		depot_ids[#depot_ids + 1] = id
	end
	table.sort(depot_ids)
	b.depot_ids = depot_ids
	b.di = 0
	b.trains_pending = true
	b.throttled = throttled_stations()
	manager.snapshot_build = b
	return b
end

--- Adds one depot stop to its name's group (the trains half was filled by summarize_trains).
--- @param by_name {[string]: SnapshotDepotGroup}
--- @param id uint
--- @param depot Depot
local function collect_depot(by_name, id, depot)
	local stop = depot.entity_stop
	if not (stop and stop.valid) then return end
	local name = stop.backer_name
	local g = by_name[name]
	if not g then
		g = { ids = {}, limit = 0, count = 0, parked = 0, inbound = 0, trains_bound = 0, compositions = {},
			same_depot_bypass = 0 }
		by_name[name] = g
	end
	g.ids[#g.ids + 1] = id
	local limit = stop.trains_limit
	if limit >= UNLIMITED or g.limit >= UNLIMITED then
		g.limit = UNLIMITED
	else
		g.limit = g.limit + limit
	end
	g.count = g.count + stop.trains_count
	if depot.available_train_id then g.parked = g.parked + 1 end
end

--- @return boolean? working nil for a missing or invalid combinator
local function working(entity)
	if entity and entity.valid then
		local status = entity.status
		return status == WORKING or status == LOW_POWER
	end
	return nil
end

--- Adds one source's request into a record whose old requests are marked with count 0 (see mark_requests).
--- @param active boolean the planner registered the request
--- @param mask int? the requesting combinator's network mask (one network; nil on a NETWORK_EACH station)
local function add_request(requested, hash, count, threshold, active, mask)
	local req = requested[hash]
	if req and req.count ~= 0 then
		req.count = req.count + count
		if threshold < req.threshold then req.threshold = threshold end
		req.active = req.active or active
		if mask then req.mask = bor(req.mask or 0, mask) end
	elseif req then
		req.count, req.threshold, req.active, req.mask = count, threshold, active, mask
	else
		requested[hash] = { count = count, threshold = threshold, active = active, mask = mask }
	end
end

--- Sorts one combinator's signals, as the planner's last poll kept them on its stop, into the record: negative on a
--- requester is requested (active when the poll registered it), positive on a provider is provided, anything else the
--- switches rule out is ignored. Writes the merged record and, unless they are the record's own tables, `src`'s lists.
--- With `b`, also records the network:item pairs the stop registered, under the networks in `nets`.
--- @param stop StopInfo
--- @param src SnapshotSource the combinator `stop` belongs to
local function classify(station, stop, st, control, b, src)
	local network_name = station.network_name
	local is_r, is_p = station.is_r, station.is_p
	local registered, p_counts = stop.requested, stop.item_p_counts
	local base_item, base_fluid = stop.r_threshold, stop.r_fluid_threshold
	local r_keys, p_keys, p_over = b and b.r_keys, b and b.p_keys, b and b.p_over
	local overrides = station.item_thresholds
	local provided, requested, ignored = st.provided, st.requested, st.ignored
	local sp, sr, si = src.provided, src.requested, src.ignored
	local own = sp ~= provided
	local src_mask = src.mask
	local req_mask = network_name ~= NETWORK_EACH and nets_n == 1 and net_masks[1] or nil
	for _, v in pairs(stop.tick_signals) do
		local signal = v.signal
		local name = signal.name
		local item_type = signal.type or "item"
		local count = v.count
		if name and name ~= network_name then
			if item_type == "virtual" then
				if control then control[name] = count end
			elseif item_type == "item" or item_type == "fluid" then
				local hash = hash_signal(signal)
				if count < 0 and is_r then
					local threshold = registered and registered[hash]
					local active = threshold ~= nil
					if not active then
						threshold = get_item_threshold(nil, station, hash, name, item_type, base_item, base_fluid)
					end
					add_request(requested, hash, count, threshold, active, req_mask)
					if own then add_request(sr, hash, count, threshold, active, src_mask) end
					if active and r_keys then
						for i = 1, nets_n do
							r_keys[nets[i] .. ":" .. hash] = true
						end
					end
				elseif count > 0 and is_p then
					provided[hash] = (provided[hash] or 0) + count
					if own then sp[hash] = (sp[hash] or 0) + count end
					if p_keys and p_counts[hash] then
						-- The provider's masks, OR-ed per key: the lint's requester-vs-provider mask check reads them.
						for i = 1, nets_n do
							local key = nets[i] .. ":" .. hash
							p_keys[key] = bor(p_keys[key] or 0, net_masks[i])
						end
						local over = overrides and get_item_threshold(nil, station, hash, name, item_type)
						if over then
							for i = 1, nets_n do
								local key = nets[i] .. ":" .. hash
								local prev = p_over[key]
								if not prev or over < prev then p_over[key] = over end
							end
						end
					end
				elseif count ~= 0 then
					ignored[hash] = (ignored[hash] or 0) + count
					if own then si[hash] = (si[hash] or 0) + count end
				end
			end
		end
	end
end

--- @param b Snapshot
--- Parsed names are shared by every station with that name (read-only; one base has 1,254 distinct names among 2,030
--- stations). The map lives as long as the snapshot, so names renamed away stay in it until the last window closes.
--- @param name string
--- @return RichNameParts
local function parsed_name(name)
	local manager = storage.manager
	local names = manager.name_parts
	if not names then
		names = {}
		manager.name_parts = names
	end
	local parts = names[name]
	if not parts then
		parts = rich_name.parse(name)
		names[name] = parts
	end
	return parts
end

--- @param id uint
--- @return SnapshotStation
local function new_record(id)
	return { id = id, provided = {}, requested = {}, deliveries = {}, control = {}, control2 = {}, thresholds = {}, wait = {},
		ignored = {}, sources = {}, rows = {} }
end

--- @param sources SnapshotSource[]
--- @param i int
--- @return SnapshotSource
local function source_at(sources, i)
	local src = sources[i]
	if not src then
		src = { kind = i == 1 and "station" or "inventory", provided = {}, requested = {}, ignored = {} }
		sources[i] = src
	end
	return src
end

--- @param src SnapshotSource
--- @param name string?
--- @param mask int|{[string]: int}? a table on NETWORK_EACH; nil for an unread inventory
local function set_source_network(src, name, mask)
	if src.network_name ~= name then src.network_name = name end
	if name == NETWORK_EACH then
		src.mask = nil
		local nets = type(mask) == "table" and mask or nil
		if src.networks ~= nets then src.networks = nets end
	else
		if src.networks then src.networks = nil end
		if mask ~= nil then mask = type(mask) == "number" and mask or 0 end
		src.mask = name and mask or nil
	end
end

--- @param st SnapshotStation
--- @param src SnapshotSource
--- @return string
function collector.row_key(st, src)
	return st.id .. "@" .. tostring(src.unit)
end

-- One label shared by every station row (about 2,000 on a large base): rows live as long as the snapshot.
local STATION_LABEL = { "cybersyn-gui.source-station" }

--- Refills st.rows from st.sources in place: one row per combinator, index order. Readers get them through
--- collector.inventories, so a render never rebuilds them.
--- @param st SnapshotStation
--- @param sources SnapshotSource[]
local function fill_rows(st, sources)
	local rows = st.rows
	for i = 1, #sources do
		local src = sources[i]
		local row = rows[i]
		if not row then
			row = { st = st }
			rows[i] = row
		end
		if row.src ~= src then row.src = src end
		if row.index ~= src.index or row.kind ~= src.kind or not row.label then
			row.index, row.kind = src.index, src.kind
			row.label = src.kind == "station" and STATION_LABEL or collector.source_label(src)
		end
		if row.unit ~= src.unit or not row.key then
			row.unit = src.unit
			row.key = collector.row_key(st, src)
		end
		row.priority = src.priority
		row.ok = src.ok == true
		row.read = src.read ~= false
		if row.network_name ~= src.network_name then row.network_name = src.network_name end
		row.mask = src.mask
		if row.networks ~= src.networks then row.networks = src.networks end
		if row.provided ~= src.provided then row.provided = src.provided end
		if row.requested ~= src.requested then row.requested = src.requested end
		if row.ignored ~= src.ignored then row.ignored = src.ignored end
		if row.starved ~= src.starved then row.starved = src.starved end
		row.failed = src.failed == true
	end
	for i = #rows, #sources + 1, -1 do rows[i] = nil end
end

collector.fill_rows = fill_rows

local NO_ROWS = {}

--- The station's rows from its last pass: the station combinator, then each secondary inventory combinator in
--- unit-number order, each with its own lists, priority and network.
--- @param st SnapshotStation
--- @return SnapshotInventory[]
function collector.inventories(st)
	return st.rows or NO_ROWS
end

local function by_unit(a, b) return (a.unit_number or 0) < (b.unit_number or 0) end

-- The valid secondary combinators of the station being read, by unit number, and their stops (false = not read).
local sec_list = {}
local sec_stops = {}

--- Refills a station record from the station and what the planner's last poll kept of its combinators: the manager
--- never reads combinator signals itself, so it can lag the circuit network by one planner cycle. With `b`, also
--- records the pass's provide and request keys (see classify).
--- @param st SnapshotStation
--- @param station Station
--- @param stop LuaEntity
--- @param comb1 LuaEntity
--- @param b Snapshot?
--- @param parse fun(name: string): RichNameParts
local function fill_station(st, id, station, stop, comb1, b, parse)
	local name = stop.backer_name
	if st.name ~= name or not st.name_parts then
		st.name = name
		st.name_lower = helpers.multilingual_to_lower(name)
		st.name_parts = parse(name)
	end
	st.surface_index = stop.surface_index
	-- Collectable values are written only when they change: rewriting a table during a GC cycle queues it for the
	-- collector's atomic step again.
	if st.network_name ~= station.network_name then st.network_name = station.network_name end
	local mask = mask_of(st.network_mask, station.network_mask)
	if st.network_mask ~= mask then st.network_mask = mask end
	st.is_p = station.is_p == true
	st.is_r = station.is_r == true
	st.is_stack = station.is_stack == true
	st.comb_ok = false
	st.comb2_ok = nil
	st.warming_up = station.is_warming_up == true
	st.trains_limit = station.trains_limit or 0
	st.deliveries_total = station.deliveries_total or 0
	st.last_delivery_tick = station.last_delivery_tick
	st.priority = station.priority
	st.longest_wait_start = nil
	st.secondary = false
	st.secondary_count = 0
	st.read_tick = game.tick
	-- The lint job's last result for this stop, which outlives the snapshot (a reopened window shows it at once).
	st.lint = lint.bits_of(id)
	-- A live single-station read (relative panel while the collector is released) has no pass buffer and keeps the
	-- flag from the last pass: the throttled set is one walk over every unserved entry, not a per-station lookup.
	if b then
		local throttled = b.throttled
		st.throttling = throttled ~= nil and throttled[id] == true
	end
	local n_unserved, worst, oldest = diag.unserved_summary(id)
	if n_unserved > 0 then
		local u = st.unserved
		if not u then
			u = {}
			st.unserved = u
		end
		u.count, u.worst_reason, u.oldest_first_tick = n_unserved, worst, oldest
	elseif st.unserved then
		st.unserved = nil
	end
	refill(st.deliveries, station.deliveries)
	refill(st.wait, station.request_start_ticks)
	if not st.ignored then st.ignored = {} end
	if not st.sources then st.sources = {} end
	if not st.rows then st.rows = {} end
	local provided, requested, ignored = st.provided, st.requested, st.ignored
	mark_counts(provided)
	mark_requests(requested)
	mark_counts(ignored)
	mark_signals(st.control)
	mark_signals(st.control2)
	mark_signals(st.thresholds)

	-- The planner skips warming-up stations and stations without a network: they neither provide nor starve, and a stop
	-- kept from before would show signals it no longer reads.
	local polled = not st.warming_up and st.network_name ~= nil
	local keyed = polled and b or nil
	local p_stop = polled and station.primary_stop or nil
	st.comb_ok = working(comb1) == true

	local comb2 = station.entity_comb2
	if comb2 then
		st.comb2_ok = working(comb2) == true
		local signals2 = polled and station.comb2_signals
		if signals2 then
			local control2, thresholds = st.control2, st.thresholds
			for _, v in pairs(signals2) do
				local signal = v.signal
				local name = signal.name
				local item_type = signal.type or "item"
				if name then
					if item_type == "virtual" then
						control2[name] = v.count
					elseif item_type == "item" or item_type == "fluid" then
						local hash = hash_signal(signal)
						thresholds[hash] = get_item_threshold(nil, station, hash, name, item_type)
					end
				end
			end
		end
	end

	-- Keyed by unit number; pairs() order is undefined, so the index follows unit-number order and rows keep their
	-- place across passes.
	local n_sec = 0
	for _, sec in pairs(station.secondary_inv_combs) do
		if sec and sec.valid then
			n_sec = n_sec + 1
			sec_list[n_sec] = sec
		end
	end
	if n_sec > 1 then table.sort(sec_list, by_unit) end

	local station_priority = station.priority or mod_settings.priority or 0
	local sources = st.sources
	local src0 = source_at(sources, 1)
	src0.index, src0.unit, src0.ok, src0.priority = 0, comb1.unit_number, st.comb_ok, station_priority
	src0.failed = nil
	local inv_failed = station.inv_failed
	if src0.network_mask ~= st.network_mask then src0.network_mask = st.network_mask end
	set_source_network(src0, st.network_name, st.network_mask)

	-- The planner reads secondaries only while the station combinator has input signals (a working combinator with
	-- an empty input reads as nil too): the rest stay in st.sources with empty lists.
	local inv_stops = p_stop and station.inv_stops
	local n_read = 0
	for i = 1, n_sec do
		local sec = sec_list[i]
		local src = source_at(sources, i + 1)
		local inv = inv_stops and inv_stops[sec.unit_number]
		src.index, src.unit, src.priority = i, sec.unit_number, inv and inv.priority or station_priority
		src.failed = inv_failed ~= nil and inv_failed[sec.unit_number] == true or nil
		src.ok = working(sec) == true
		src.read = p_stop ~= nil
		if inv then
			n_read = n_read + 1
			sec_stops[i] = inv
		else
			sec_stops[i] = false
			src.network_mask = nil
			set_source_network(src, st.network_name, nil)
		end
	end
	for i = #sources, n_sec + 2, -1 do sources[i] = nil end

	-- While it is the only source read, the station combinator's lists are the record's own; with an inventory read
	-- it needs lists of its own.
	if n_read == 0 then
		if src0.provided ~= provided then src0.provided, src0.requested, src0.ignored = provided, requested, ignored end
	elseif src0.provided == provided then
		src0.provided, src0.requested, src0.ignored = {}, {}, {}
	end
	for i = 1, #sources do
		local src = sources[i]
		if src.provided ~= provided then
			mark_counts(src.provided)
			mark_requests(src.requested)
			mark_counts(src.ignored)
		end
	end

	if p_stop then
		set_networks(st.network_name, st.network_mask)
		classify(station, p_stop, st, st.control, keyed, src0)
	end
	for i = 1, n_sec do
		local inv = sec_stops[i]
		if inv then
			local src = sources[i + 1]
			local mask = mask_of(src.network_mask, inv.network_mask)
			src.network_mask = mask
			set_source_network(src, st.network_name, mask)
			set_networks(st.network_name, mask)
			classify(station, inv, st, nil, keyed, src)
			st.secondary_count = st.secondary_count + 1
			st.secondary = true
		end
		sec_stops[i] = nil
	end
	for i = 1, n_sec do sec_list[i] = nil end

	for i = 1, #sources do
		local src = sources[i]
		if src.provided ~= provided then
			sweep_counts(src.provided)
			sweep_requests(src.requested)
			sweep_counts(src.ignored)
		end
	end
	sweep_counts(provided)
	sweep_requests(requested)
	sweep_counts(ignored)
	sweep_signals(st.control)
	sweep_signals(st.control2)
	sweep_signals(st.thresholds)
	fill_rows(st, sources)
end

--- Appends a station to an item's list once (a station's items are visited one station at a time).
--- @param index {[string]: uint[]}
--- @param hash string
--- @param id uint
local function index_add(index, hash, id)
	local list = index[hash]
	if not list then
		index[hash] = { id }
	elseif list[#list] ~= id then
		list[#list + 1] = id
	end
end

--- @param id uint
--- @param station Station
local function collect_station(b, id, station)
	local stop = station.entity_stop
	if not (stop and stop.valid) then return end
	local comb1 = station.entity_comb1
	if not (comb1 and comb1.valid) then return end

	local live = collector.get()
	--- @type SnapshotStation
	local st = live.stations[id] or new_record(id)
	fill_station(st, id, station, stop, comb1, b, parsed_name)
	local provided, requested = st.provided, st.requested

	local inv = b.inventory_all
	-- Stations by item, for the drill-down (item-model.build): the few stations of one item instead of all of them.
	local index = b.item_stations
	if not index then
		index = {}
		b.item_stations = index
	end

	for hash, count in pairs(provided) do
		index_add(index, hash, id)
		local agg = inv.provided[hash]
		if agg then
			agg.count = agg.count + count
			agg.stations = agg.stations + 1
		else
			inv.provided[hash] = { count = count, stations = 1 }
		end
	end

	local wait = st.wait
	for hash, req in pairs(requested) do
		index_add(index, hash, id)
		if req.active then
			local start = wait[hash]
			if start and (not st.longest_wait_start or start < st.longest_wait_start) then
				st.longest_wait_start = start
			end
			local agg = inv.requested[hash]
			if agg then
				agg.count = agg.count + req.count
				agg.stations = agg.stations + 1
				if start and (not agg.earliest_wait_start or start < agg.earliest_wait_start) then
					agg.earliest_wait_start = start
				end
			else
				inv.requested[hash] = { count = req.count, stations = 1, earliest_wait_start = start }
			end
		end
	end

	for hash, count in pairs(st.deliveries) do
		if count ~= 0 then index_add(index, hash, id) end
		if count > 0 then
			local agg = inv.in_transit[hash]
			if agg then
				agg.count = agg.count + count
				agg.stations = agg.stations + 1
			else
				inv.in_transit[hash] = { count = count, stations = 1 }
			end
		end
	end

	-- Against the live starved set; finish_pass reclassifies the stations a change of that set affects.
	local status = collector.station_status(st, live.starved)
	if st.status ~= status then st.status = status end

	if live.stations[id] ~= st then live.stations[id] = st end
	log_change(id)
	b.seen[id] = true
	b.station_count = b.station_count + 1
	if st.secondary then b.secondary_count = b.secondary_count + 1 end
end

local NO_STARVED = {}

--- One station read on its own, outside any pass: the stop panel's live record while no manager window holds a
--- snapshot. `st` is the caller's own record (never a snapshot record), refilled in place; the pass aggregates are not
--- touched.
--- @param id uint
--- @param st SnapshotStation? reused when given
--- @param starved {[string]: true}? "network:hash" keys nobody provides, for the status
--- @return SnapshotStation?
function collector.read_station(id, st, starved)
	local station = storage.stations[id]
	local stop = station and station.entity_stop
	if not (stop and stop.valid) then return nil end
	local comb1 = station.entity_comb1
	if not (comb1 and comb1.valid) then return nil end
	st = st or new_record(id)
	fill_station(st, id, station, stop, comb1, nil, rich_name.parse)
	st.status = collector.station_status(st, starved or NO_STARVED)
	return st
end

local function same_keys(a, b)
	if not a or not b then return false end
	for k in pairs(a) do
		if b[k] == nil then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function hash_of_key(key)
	local s = string.find(key, ":", 1, true)
	return s and string.sub(key, s + 1) or key
end

local NO_NETWORKS = {}

--- This station's active request keys on `networks` or on its rows' networks that the planner published as starved;
--- for a stop read live.
--- @param st SnapshotStation
--- @param networks {name: string}[]?
--- @return {[string]: true}
function collector.economy_starved(st, networks)
	local published = storage.economy.starved
	local starved = {}
	for _, net in ipairs(networks or NO_NETWORKS) do
		for hash, req in pairs(st.requested) do
			if req.active then
				local key = net.name .. ":" .. hash
				if published[key] then starved[key] = true end
			end
		end
	end
	-- A NETWORK_EACH station's secondaries request on networks the station combinator may not name.
	local rows = st.rows
	if rows then
		for i = 1, #rows do
			local row = rows[i]
			local nets, name = row.networks, row.network_name
			if nets or (name and name ~= NETWORK_EACH) then
				for hash, req in pairs(row.requested) do
					if req.active then
						if nets then
							for net in pairs(nets) do
								local key = net .. ":" .. hash
								if published[key] then starved[key] = true end
							end
						else
							local key = name .. ":" .. hash
							if published[key] then starved[key] = true end
						end
					end
				end
			end
		end
	end
	return starved
end

--- After the starved set changed, the status of stations with an active request for an item that became or stopped
--- being starved is recomputed against the new set; every other status cannot have changed.
local function reclassify_starved(stations, old, new)
	local items, any = {}, false
	for key in pairs(old) do
		if not new[key] then
			items[hash_of_key(key)] = true
			any = true
		end
	end
	for key in pairs(new) do
		if not old[key] then
			items[hash_of_key(key)] = true
			any = true
		end
	end
	if not any then return end
	for id, st in pairs(stations) do
		for hash, req in pairs(st.requested) do
			if req.active and items[hash] then
				local status = collector.station_status(st, new)
				if status ~= st.status then
					st.status = status
					log_change(id)
				end
				break
			end
		end
	end
end

local function finish_pass(manager, b)
	local live = collector.get()
	local starved = storage.economy.starved
	local changed = false
	if starved == live.starved or same_keys(starved, live.starved) then
		b.starved = live.starved
		b.starved_items = live.starved_items
		b.starved_version = live.starved_version
	else
		local items = {}
		for key in pairs(starved) do items[hash_of_key(key)] = true end
		b.starved = starved
		b.starved_items = items
		b.starved_version = (live.starved_version or 0) + 1
		changed = true
	end
	local stations = live.stations
	local seen = b.seen
	for id in pairs(stations) do
		if not seen[id] then
			stations[id] = nil
			log_change(id)
		end
	end
	if changed then reclassify_starved(stations, live.starved, b.starved) end
	-- This pass's provider keys become the live provider masks; the previous live set is cleared for the next pass.
	manager.collect_spare = { seen = seen, r_keys = live.request_keys, p_keys = live.provider_masks,
		p_over = live.provider_overrides }
	b.request_keys = b.r_keys
	b.provider_masks = b.p_keys
	b.provider_overrides = b.p_over
	b.stations = stations
	b.trains = live.trains
	b.trains_version = live.trains_version
	b.train_count = live.train_count
	b.fleet = live.fleet
	b.depots = live.depots
	b.alerts = live.alerts
	-- The sorted id lists of this pass stay with the snapshot: the lint job walks them instead of listing storage
	-- again. Never changed after this point, so a job may hold them past the next pass.
	b.station_ids = b.ids
	b.ids = nil
	b.i = nil
	b.di = nil
	b.seen = nil
	b.r_keys = nil
	b.p_keys = nil
	b.p_over = nil
	b.throttled = nil
	b.tick = game.tick
	manager.snapshot = b
	manager.snapshot_build = nil
end

--- @param n integer stations in the pass
--- @return integer
local function batch_size(n)
	return math.min(math.max(math.ceil(n / PASS_UPDATES), MIN_BATCH), MAX_BATCH)
end

--- Advances the current pass by up to `budget` stations (default: the per-update batch size times `scale`).
--- @param budget number?
--- @param scale number? only without budget: a multiple of the batch size, in one call with listing and trains
--- @return boolean completed
function collector.step(budget, scale)
	local manager = storage.manager
	local b = manager.snapshot_build
	-- Listing the stations and summarising the fleet each cost about as much as a batch of stations, so a default
	-- step does only one of them and a boosted step both, but no stations on top.
	if not b then
		b = start_pass(manager)
		if not (budget or scale) then return false end
	end
	if b.trains_pending then
		b.trains_pending = nil
		summarize_trains(b)
		if not budget then return false end
	end
	local ids = b.ids
	local n = #ids
	budget = budget or batch_size(n) * (scale or 1)
	local stations = storage.stations
	local i = b.i
	local stop = math.min(n, i + budget)
	while i < stop do
		i = i + 1
		local id = ids[i]
		local station = stations[id]
		if station then
			collect_station(b, id, station)
		end
	end
	b.i = i
	-- Depot stops go at the same pace as the stations (two stop reads each).
	local depot_ids = b.depot_ids
	local nd = #depot_ids
	local di = b.di
	local dstop = math.min(nd, di + (budget == math.huge and nd or math.ceil(budget * nd / math.max(n, 1))))
	if i >= n then dstop = nd end
	local depots = storage.depots
	local by_name = b.depots_by_name
	while di < dstop do
		di = di + 1
		local id = depot_ids[di]
		local depot = depots[id]
		if depot then collect_depot(by_name, id, depot) end
	end
	b.di = di
	if i >= n and di >= nd then
		finish_pass(manager, b)
		return true
	end
	return false
end

function collector.run_to_completion()
	while not collector.step(math.huge) do end
	storage.manager.collect_boost = nil
	storage.manager.collect_quiet = nil
end

--- Opening a window on a missing or stale snapshot does not collect synchronously (65 ms cold on a 2,000-station
--- base): the window shows the last snapshot, or placeholders, while the next ticks run a pass at BOOST times the
--- batch size. With a snapshot kept from before the close the boost is quiet: no placeholders and no note, the kept
--- rows stay until the pass swaps the fresh ones in.
function collector.ensure_fresh()
	local manager = storage.manager
	local snapshot = collector.get()
	if manager.release_at then
		manager.release_at = nil
		-- The closed windows' Stations caches stayed for their own reopen inside the grace; the log they would fold
		-- in is trimmed by the passes this window runs, so they could only pin old records until the next release.
		for _, player_data in pairs(manager.players) do
			if not player_data.is_manager_open then player_data.cache.stations = nil end
		end
	end
	if not snapshot.tick or game.tick - snapshot.tick > STALE_ON_OPEN_TICKS then
		local b = manager.snapshot_build
		if b and game.tick - b.started_tick > STALE_ON_OPEN_TICKS then
			manager.snapshot_build = nil
		end
		if not manager.collect_boost then
			manager.collect_boost = game.tick
			manager.collect_quiet = snapshot.tick ~= nil or nil
		end
	end
end

--- Fraction of the boosted pass done while a window waits for its first data, else nil (also during a quiet boost).
--- @return number?
function collector.collecting()
	local manager = storage.manager
	if not (manager and manager.collect_boost) or manager.collect_quiet then return nil end
	local b = manager.snapshot_build
	if not (b and b.ids) or #b.ids == 0 then return 0 end
	return b.i / #b.ids
end

--- collecting(), but only once the boost has run NOTE_TICKS: the progress the subheaders show.
--- @return number?
function collector.collecting_note()
	local progress = collector.collecting()
	if not progress then return nil end
	if game.tick - storage.manager.collect_boost >= collector.NOTE_TICKS then return progress end
	return nil
end

--- True when any open manager is unpaused, or paused but still waiting for its first data: pausing freezes what a
--- window shows, and a window reopened paused shows nothing until one pass completes.
--- @return boolean
function collector.wanted()
	for _, player_data in pairs(storage.manager.players) do
		if player_data.is_manager_open and (not player_data.paused or not player_data.rendered_snapshot_tick) then
			return true
		end
	end
	return false
end

--- One step of the opening boost: the per-tick handler's, so it never shares a tick with a render. No-op unless a
--- boost runs and a window wants data, and on the tick the boost started (the open's own render ran on it). On the
--- tick it completes the pass it leaves SETTLE_RENDERS renders owed (storage.manager.settle) to the following ticks.
--- @param any_tick boolean? step on the open's tick too (the unit tests, which run on one game tick)
--- @return boolean completed
function collector.boost_tick(any_tick)
	local manager = storage.manager
	local started = manager and manager.collect_boost
	if not started or (started == game.tick and not any_tick) or not collector.wanted() then return false end
	if not collector.step(nil, BOOST) then return false end
	manager.collect_boost = nil
	manager.collect_quiet = nil
	manager.snapshot.boosted = true
	manager.settle = SETTLE_RENDERS
	return true
end

--- Owes one render to the next tick (the per-tick handler's settle path) unless renders are owed already: a tab that
--- splits its first build over several renders finishes in as many ticks instead of as many manager updates. The
--- render that owes it ran on this tick (a click's, an update's or a settle render), so the owed one waits a tick.
function collector.owe_render()
	local manager = storage.manager
	if manager and not manager.settle then
		manager.settle = 1
		manager.settle_tick = game.tick
	end
end

--- One manager update's worth of collection; no-op unless collector.wanted(), while the opening boost runs
--- (collector.boost_tick steps it then, and the lint job waits for its result) and while its renders are owed.
--- @return boolean ran
function collector.tick()
	local manager = storage.manager
	if not manager then return false end
	if manager.collect_boost or manager.settle or not collector.wanted() then return false end
	collector.step()
	lint.step()
	return true
end

--- Aggregates provided/requested/in-transit over the stations accepted by `pred`, in the inventory_all shape.
--- @param snapshot Snapshot
--- @param pred fun(st: SnapshotStation): boolean
function collector.aggregate(snapshot, pred)
	local inv = new_inventory()
	for _, st in pairs(snapshot.stations) do
		if pred(st) then
			for hash, count in pairs(st.provided) do
				local agg = inv.provided[hash]
				if agg then
					agg.count = agg.count + count
					agg.stations = agg.stations + 1
				else
					inv.provided[hash] = { count = count, stations = 1 }
				end
			end
			for hash, req in pairs(st.requested) do
				if req.active then
					local start = st.wait[hash]
					local agg = inv.requested[hash]
					if agg then
						agg.count = agg.count + req.count
						agg.stations = agg.stations + 1
						if start and (not agg.earliest_wait_start or start < agg.earliest_wait_start) then
							agg.earliest_wait_start = start
						end
					else
						inv.requested[hash] = { count = req.count, stations = 1, earliest_wait_start = start }
					end
				end
			end
			for hash, count in pairs(st.deliveries) do
				if count > 0 then
					local agg = inv.in_transit[hash]
					if agg then
						agg.count = agg.count + count
						agg.stations = agg.stations + 1
					else
						inv.in_transit[hash] = { count = count, stations = 1 }
					end
				end
			end
		end
	end
	return inv
end

--- A mask as the Network columns print it: "3".
--- @param mask int
--- @return string
function collector.mask_label(mask)
	return tostring(mask)
end

--- @param source SnapshotSource
--- @return LocalisedString
function collector.source_label(source)
	if source.kind == "inventory" then return { "cybersyn-gui.source-inventory", source.index } end
	return { "cybersyn-gui.source-station" }
end

return collector
