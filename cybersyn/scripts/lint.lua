-- Setup lint: finds the setups that will never dispatch before a request exists, and names the reason
-- code each one predicts, so tests can hold this model and the dispatcher's to the same answers.
--
-- Two sources of findings, neither on a timer of its own:
--   the setup job runs only while a manager window is open (collector.tick calls lint.step), 50 station, depot and
--   refueler records plus 12 trains per update, from the manager snapshot, the fleet facts the collector builds once
--   per pass, and a few reads of each record's stop; it rebuilds the findings array every pass and writes one `lint`
--   log event per finding that appears or clears. Schedule records are checked against the stop names the snapshot
--   already holds; only a name outside them costs a lookup (a full get_train_stops{} list took 0.85 ms on a
--   2,578-stop base, more than a whole update may).
--   the setup registry (storage.lint_registry) holds what the build, rotate, rename and removal handlers in
--   scripts/main.lua decide about combinators and stops and Cybersyn itself drops: combinators no stop adopted,
--   doubled or conflicting combinators, stops that only control combinators reach, combinator ghosts at stops that
--   are not registered and stops that share a depot's name. It is written when those handlers run and seeded once
--   from to_comb/to_stop/to_comb_params (lint.registry_seed), so nothing ever scans the map for it.
-- Nothing here reads storage.diag except through diag.lint; find_entities_filtered runs only inside the handlers
-- that change what it would find (and once per orphan combinator in the seed).

local diag = require("scripts.diag")

local band = bit32.band
local bor = bit32.bor

local lint = {}

-- Measured on a 2,030-station, 551-train base a station record costs 3-8 µs (up to 47 µs with 80 requested items),
-- so 50 records stay well under a 0.5 ms update. A train's
-- schedule and wagons are read only between deliveries (see check_train), a few µs each.
local RECORDS_PER_UPDATE = 50
local TRAINS_PER_UPDATE = 12
-- A stop name outside the seeded set costs a get_train_stops lookup of tens of µs; the train loop stops for this
-- update once this many were made and resumes at the same train.
local LOOKUPS_PER_UPDATE = 2
-- Station names for the schedule check, read from the snapshot before the train checks start: looking a name up
-- (get_train_stops by name) costs tens of µs on a big base, reading it from a record a fraction of one.
local SEED_PER_UPDATE = 300
local UNLIMITED = TRAIN_LIMIT_UNLIMITED
-- Vanilla's own; any other value misroutes trains Cybersyn sends to stops of the same name.
local DEFAULT_PRIORITY = 50

-- Checks only the registry finds; their acknowledgements end when the registry drops them, not with a pass.
local REGISTRY_CHECKS = LINT_REGISTRY_CHECKS
lint.REGISTRY_CHECKS = REGISTRY_CHECKS

lint.RECORDS_PER_UPDATE = RECORDS_PER_UPDATE
lint.TRAINS_PER_UPDATE = TRAINS_PER_UPDATE
lint.REFUEL_GRACE = REFUEL_GRACE_TICKS

--- @class LintFinding
--- @field subject int LINT_SUBJECT_*
--- @field id uint stop unit number, train id or combinator unit number
--- @field check int LINT_*
--- @field a number? detail numbers for the fix line (see the lint-fix-* locale keys)
--- @field b number?
--- @field network string?
--- @field item string? item hash the finding is about
--- @field c number? CAPACITY: the threshold as typed (items or fluid units) behind the stacks in `a`
--- @field train uint? PHANTOM: the bound train the station does not count; OCCUPANCY: the train Cybersyn did not send
--- @field status int? PHANTOM with `train`: that train's STATUS_*
--- @field fix string? a lint-fix-* key suffix that replaces the check's own fix line (PHANTOM: "phantom-leak")
--- @field entity LuaEntity? registry: the stop or combinator
--- @field message string? registry: the [cybersyn-problems] key the command prints (problems-world-<message>)
--- @field stop LuaEntity? registry, wrong side: the stop the combinator stands next to

--- @class LintJob
--- @field started_tick uint
--- @field setup int? 1 and 2 while the pass is being set up (start_job, setup_job)
--- @field sids uint[] station ids of this pass, then dids (depots) and fids (refuelers): the cursor i runs over all three
--- @field dids uint[]?
--- @field fids uint[]?
--- @field i int
--- @field tids uint[] train ids of this pass
--- @field ti int
--- @field names {[string]: boolean}? stop name -> exists (the snapshot's names, plus lookups made this pass)
--- @field groups {[string]: int}? vanilla train group -> depot names among its Cybersyn trains
--- @field dest {[uint]: int} stop id -> Cybersyn trains heading to or standing at it
--- @field bound {[uint]: int} station id -> trains its deliveries_total should count
--- @field delivered {[uint]: int} station id -> its deliveries_total, read with `bound` (the stations with a sighted gap)
--- @field named {[uint]: uint} station id -> a train bound to it, for the same stations
--- @field findings LintFinding[]
--- @field bits {[uint]: int} this pass's masks, committed with the findings when the pass completes
--- @field train_bits {[uint]: int}
--- @field lookups int stop-name lookups made in the current update
--- @field seeded int? station names already added to `names`, from the front of sids (set up by setup_job)
--- @field updates int updates this pass has taken so far

--- @class LintState
--- @field bits {[uint]: int} stop unit number -> mask of the last completed check
--- @field train_bits {[uint]: int}
--- @field findings LintFinding[] the last complete pass
--- @field train_live {[uint]: {missing: int?, items: int, fluid: int?, dirty: true?}} per train, what its schedule and
---   wagons said when last read between deliveries; dirty after a player's schedule edit, to read it again on a trip
--- @field pass int completed passes
--- @field tick uint? when the last pass completed
--- @field updates int updates the last pass took
--- @field job LintJob?
--- @field removed int? counts station removals that dropped findings between passes (part of the Problems model sig)
--- @field logged {[uint]: int}? masks the log stated during the running (or a dropped) pass, until a pass commits
--- @field train_logged {[uint]: int}?
--- @field occupancy_since {[uint]: uint} stop -> tick the occupancy gap was first seen (cleared when it closes)
--- @field phantom_since {[uint]: uint}

--- @return LintState
function lint.state()
	local manager = storage.manager
	local s = manager.lint
	if not s then
		s = { bits = {}, train_bits = {}, findings = {}, pass = 0, updates = 0, occupancy_since = {}, phantom_since = {},
			train_live = {} }
		manager.lint = s
	end
	return s
end

--- The last completed mask of a station, depot or refueler (0 when clean or not checked yet).
--- @param id uint
--- @return int
function lint.bits_of(id)
	local manager = storage.manager
	local s = manager and manager.lint
	return s and s.bits[id] or 0
end

--- The key a lint acknowledgement is stored under (storage.acks.lint): stops and combinators by unit number, trains by
--- their negated id, so a train id never collides with a unit number.
--- @param subject int LINT_SUBJECT_*
--- @param id uint
--- @return int
function lint.subject_key(subject, id)
	if subject == LINT_SUBJECT_TRAIN then return -id end
	return id
end

--- The tick from which a train's refuelling is tracked: when Cybersyn first saw it, but not before refuel_tick was
--- recorded at all.
--- @param train Train
--- @return uint
function lint.refuel_from(train)
	local since = storage.stats and storage.stats.refuel_since or 0
	local seen = train.seen_tick
	if seen and seen > since then return seen end
	return since
end

--- @param mask int
--- @param check int
--- @return boolean
function lint.has(mask, check)
	return band(mask, LINT_BIT[check]) ~= 0
end

-- ---------------------------------------------------------------- pure checks (no API calls; unit tested)

local NO_LAYOUTS = {}

--- @param out LintFinding[]
local function find(out, mask, subject, id, check, a, b, network, item)
	out[#out + 1] = { subject = subject, id = id, check = check, a = a, b = b, network = network, item = item }
	return bor(mask, LINT_BIT[check])
end

-- Slots per item for the capacity check, by hash: a stack size for items, false for fluids. Prototype data only, so
-- every Lua state computes the same values whether or not it has filled the cache yet.
local stack_of = {}

--- @param hash string
--- @return number|false
local function stack_size(hash)
	local v = stack_of[hash]
	if v == nil then
		v = get_stack_size(nil, (unhash_signal(hash))) or false
		stack_of[hash] = v
	end
	return v
end

--- What the fleet offers a stop on one network: trains whose mask shares a bit with the stop's, the layouts among
--- them the stop accepts, and the largest capacities of those and of all of them. The dispatcher tests capacity
--- before layout, so a train the stop rejects still decides whether the failure is capacity or layout.
--- @param capability {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}}?
--- @param mask int
--- @param allows_all boolean
--- @param accepted {[uint]: true?}
--- @return int trains mask-eligible trains
--- @return int accepted_trains of those, trains with a layout the stop accepts
--- @return int item_capacity largest among the accepted ones
--- @return int fluid_capacity
--- @return int all_items largest among all mask-eligible ones
--- @return int all_fluid
function lint.eligible(capability, mask, allows_all, accepted)
	local trains, ok, items, fluid, all_items, all_fluid = 0, 0, 0, 0, 0, 0
	if not capability then return 0, 0, 0, 0, 0, 0 end
	for layout_id, c in pairs(capability) do
		if band(c.mask_or, mask) ~= 0 then
			trains = trains + c.count
			local ci, cf = c.item_capacity, c.fluid_capacity
			if ci > all_items then all_items = ci end
			if cf > all_fluid then all_fluid = cf end
			if allows_all or accepted[layout_id] then
				ok = ok + c.count
				if ci > items then items = ci end
				if cf > fluid then fluid = cf end
			end
		end
	end
	return trains, ok, items, fluid, all_items, all_fluid
end

--- Mask-eligible layouts the stop's allow list keeps out, counting only those that carry `need` slots (or fluid units
--- with `fluid`) when `need` is given: the trains that would serve the stop if the list accepted them.
--- @param capability {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}}?
--- @param mask int
--- @param allows_all boolean
--- @param accepted {[uint]: true?}
--- @param need number?
--- @param fluid boolean?
--- @return int
function lint.rejected_layouts(capability, mask, allows_all, accepted, need, fluid)
	if not capability or allows_all then return 0 end
	local n = 0
	for layout_id, c in pairs(capability) do
		if band(c.mask_or, mask) ~= 0 and not accepted[layout_id] then
			local have = fluid and c.fluid_capacity or c.item_capacity
			if not need or have >= need then n = n + 1 end
		end
	end
	return n
end

--- The reason code a check predicts for a station in `role`, nil when the dispatcher has none for it.
--- @param check int LINT_*
--- @param role "r"|"p"
--- @return DiagReason?
function lint.predicts(check, role)
	return role == "p" and LINT_PREDICTS_P[check] or LINT_PREDICTS[check]
end

-- A stop without power or switched off is reported as that; a network bit it lacks changes nothing until then.
local NO_MASK_CHECK = { no_power = true, disabled = true }

--- The checks of one network of a station; returns the station's mask with this network's findings added.
--- @param keys {overrides: {[string]: number}?, starved: {[string]: true}}
local function check_network(out, mask, id, st, accepted, allows_all, fleet, keys, net, net_mask)
	local S = LINT_SUBJECT_STATION
	local mask_or = fleet.mask_or[net]
	local trains, ok, items, fluid, all_items, all_fluid = 0, 0, 0, 0, 0, 0
	if not mask_or then
		if band(mask, LINT_BIT[LINT_NO_TRAIN]) == 0 then mask = find(out, mask, S, id, LINT_NO_TRAIN, net_mask, 0, net) end
	elseif net_mask == 0 then
		-- Mask 0 shares no bit with any provider or requester either, and the dispatcher's provider check comes first.
		-- Only mask 0 is a finding: a requester whose bits no provider shares right now may be waiting by design for
		-- providers whose masks follow demand, and the dispatcher reports MASK_MISMATCH live when it is not.
		if band(mask, LINT_BIT[LINT_MASK]) == 0 and not NO_MASK_CHECK[st.status] then
			mask = find(out, mask, S, id, LINT_MASK, 0, mask_or, net)
		end
	elseif band(net_mask, mask_or) == 0 then
		if band(mask, LINT_BIT[LINT_TRAIN_MASK]) == 0 then
			mask = find(out, mask, S, id, LINT_TRAIN_MASK, net_mask, mask_or, net)
		end
	else
		trains, ok, items, fluid, all_items, all_fluid = lint.eligible(fleet.capability[net], net_mask, allows_all,
			accepted)
		if trains > 0 and ok == 0 and band(mask, LINT_BIT[LINT_LAYOUT]) == 0 then
			mask = find(out, mask, S, id, LINT_LAYOUT, (accepted and table_size(accepted) or 0),
				lint.rejected_layouts(fleet.capability[net], net_mask, allows_all, accepted), net)
		end
	end
	if not st.is_r then return mask end
	local overrides, starved = keys.overrides, keys.starved
	local prefix
	for hash, req in pairs(st.requested) do
		prefix = prefix or (net .. ":")
		local key = prefix .. hash
		if req.active and starved[key] then
			if band(mask, LINT_BIT[LINT_NO_PROVIDER]) == 0 then
				mask = find(out, mask, S, id, LINT_NO_PROVIDER, 0, 0, net, hash)
			end
		end
		if trains > 0 and band(mask, LINT_BIT[LINT_CAPACITY]) == 0 then
			-- The dispatcher takes a provider's own item threshold when it is the lower one.
			local threshold = req.threshold
			local override = overrides and overrides[key]
			if override and override < threshold then threshold = override end
			local stack = stack_size(hash)
			local need, have, have_any
			if stack then
				need, have, have_any = math.ceil(threshold / stack), items, all_items
			else
				need, have, have_any = threshold, fluid, all_fluid
			end
			if need > have_any then
				mask = find(out, mask, S, id, LINT_CAPACITY, need, have_any, net, hash)
				out[#out].c = threshold
			elseif need > have and ok > 0 and band(mask, LINT_BIT[LINT_LAYOUT]) == 0 then
				mask = find(out, mask, S, id, LINT_LAYOUT, (accepted and table_size(accepted) or 0),
					lint.rejected_layouts(fleet.capability[net], net_mask, allows_all, accepted, need, not stack), net, hash)
			end
		end
	end
	return mask
end

--- The station checks against one snapshot record.
--- @param out LintFinding[] findings are appended
--- @param id uint
--- @param st SnapshotStation
--- @param station Station
--- @param fleet SnapshotFleet
--- @param keys {overrides: {[string]: number}?, starved: {[string]: true}} the snapshot's per network:item facts:
---   the providers' lowest item threshold, the keys nobody provides
--- @param live LintStationLive
--- @return int mask
function lint.check_station(out, id, st, station, fleet, keys, live)
	local mask = 0
	local S = LINT_SUBJECT_STATION
	if live.limit == 0 then mask = find(out, mask, S, id, LINT_LIMIT_ZERO, 0, 0) end
	if live.occupancy_gap then
		mask = find(out, mask, S, id, LINT_OCCUPANCY, live.occupancy, live.count)
		out[#out].train = live.occupancy_train
	end
	if live.phantom then
		local deliveries, bound = live.deliveries, live.bound
		mask = find(out, mask, S, id, LINT_PHANTOM, deliveries, bound)
		local f = out[#out]
		if deliveries > bound then
			-- Counted deliveries no train serves: the counter leaked, and only a recount repairs it.
			f.fix = "phantom-leak"
		else
			f.train, f.status = live.phantom_train, live.phantom_status
		end
	end
	if live.priority and live.priority ~= DEFAULT_PRIORITY then
		mask = find(out, mask, S, id, LINT_PRIORITY, live.priority, 0)
	end

	-- A stop that provides and requests: an item it has on its way out is not requested (R_IS_PROVIDING), one on its
	-- way in is not provided (P_IS_REQUESTING). The dispatcher skips both whatever the item's own threshold, so an item
	-- threshold is no way out of it; splitting the stop is.
	if st.is_r and st.is_p then
		local requested, provided, deliveries = st.requested, st.provided, st.deliveries
		for hash in pairs(requested) do
			if (deliveries[hash] or 0) < 0 or provided[hash] then
				mask = find(out, mask, S, id, LINT_SAME_ITEM, -(deliveries[hash] or 0), 0, nil, hash)
				break
			end
		end
		if band(mask, LINT_BIT[LINT_SAME_ITEM]) == 0 then
			for hash in pairs(provided) do
				if (deliveries[hash] or 0) > 0 then
					-- b = 1: on its way in (P_IS_REQUESTING), where the requested side above is on its way out.
					mask = find(out, mask, S, id, LINT_SAME_ITEM, deliveries[hash], 1, nil, hash)
					break
				end
			end
		end
	end

	local allows_all = station.allows_all_trains == true
	local accepted = station.accepted_layouts or NO_LAYOUTS
	local name, net_mask = st.network_name, st.network_mask
	if name == NETWORK_EACH then
		if type(net_mask) == "table" then
			for net, m in pairs(net_mask) do
				mask = check_network(out, mask, id, st, accepted, allows_all, fleet, keys, net, m)
			end
		end
	elseif name then
		mask = check_network(out, mask, id, st, accepted, allows_all, fleet, keys, name,
			type(net_mask) == "number" and net_mask or 0)
	end
	return mask
end

--- @param out LintFinding[]
--- @param group SnapshotDepotGroup?
--- @param priority int? the stop's train_stop_priority
--- @return int mask
function lint.check_depot(out, id, limit, group, priority)
	local mask = 0
	if limit ~= 1 then mask = find(out, mask, LINT_SUBJECT_DEPOT, id, LINT_DEPOT_LIMIT, limit >= UNLIMITED and -1 or limit, 0) end
	if group and #group.ids > 1 and group.same_depot_bypass > 0 then
		mask = find(out, mask, LINT_SUBJECT_DEPOT, id, LINT_DEPOT_SHARED_NAME, #group.ids, group.same_depot_bypass)
	end
	if priority and priority ~= DEFAULT_PRIORITY then
		mask = find(out, mask, LINT_SUBJECT_DEPOT, id, LINT_PRIORITY, priority, 0)
	end
	return mask
end

--- @param out LintFinding[]
--- @param refueler {network_name: string?, network_mask: int|{[string]: int}}
--- @param fleet SnapshotFleet
--- @param priority int? the stop's train_stop_priority
--- @return int mask
function lint.check_refueler(out, id, refueler, fleet, priority)
	local mask = 0
	each_network(refueler.network_name, refueler.network_mask, function(net, net_mask)
		local mask_or = fleet.mask_or[net] or 0
		if band(net_mask, mask_or) == 0 and mask == 0 then
			mask = find(out, mask, LINT_SUBJECT_REFUELER, id, LINT_REFUELER_MASK, net_mask, mask_or, net)
		end
	end)
	if priority and priority ~= DEFAULT_PRIORITY then
		mask = find(out, mask, LINT_SUBJECT_REFUELER, id, LINT_PRIORITY, priority, 0)
	end
	return mask
end

--- @param out LintFinding[]
--- @param live {in_group: boolean, group_depots: int?, missing_record: int?, never_refuelled: string?, tracked: int?, items: int, fluid: int?}
---   in_group: the train's vanilla group holds Cybersyn trains of more than one depot name (group_depots of them)
--- @param train Train
--- @return int mask
function lint.check_train(out, id, train, live)
	local mask = 0
	local T = LINT_SUBJECT_TRAIN
	if live.in_group then mask = find(out, mask, T, id, LINT_IN_GROUP, live.group_depots or 0, 0) end
	if live.missing_record then mask = find(out, mask, T, id, LINT_MISSING_STOP, live.missing_record, 0) end
	if live.never_refuelled then
		mask = find(out, mask, T, id, LINT_NEVER_REFUELLED, live.tracked or 0, 0, live.never_refuelled)
	end
	if live.items ~= (train.item_slot_capacity or 0) then
		mask = find(out, mask, T, id, LINT_CAPACITY_DRIFT, train.item_slot_capacity or 0, live.items)
	elseif live.fluid and live.fluid ~= (train.fluid_capacity or 0) then
		mask = find(out, mask, T, id, LINT_CAPACITY_DRIFT, train.fluid_capacity or 0, live.fluid)
	end
	return mask
end

-- ---------------------------------------------------------------- the setup job

--- @param t {[uint]: any}
--- @param out uint[]
--- @return uint[] out
local function keys_into(t, out)
	for id in pairs(t) do out[#out + 1] = id end
	return out
end

--- Trains Cybersyn has heading to or standing at each stop and the deliveries each station's counter should hold.
--- A station is checked up to a whole pass later (about 50 s on a 2,000-station base), and its live counter against
--- this index is only a sighting: a train that left in between makes a gap. The stations with a sighting from the
--- last pass (`phantom_since`) are decided here instead, on their counters read in this update, at the same instant
--- as the index, with a train bound to each named. Reading every station's counter here cost 0.9-1.5 ms in this one
--- update on that base, and recounting a station's trains at its check one walk of every train per update.
--- @param job LintJob
--- @param s LintState
local function occupancy_index(job, s)
	local watch = s.phantom_since
	local dest, bound, named = {}, {}, {}
	local TO_P, AT_P, TO_R, AT_R, TO_F, AT_F = STATUS_TO_P, STATUS_P, STATUS_TO_R, STATUS_R, STATUS_TO_F, STATUS_F
	for train_id, train in pairs(storage.trains) do
		local status = train.status
		local p, r = train.p_station_id, train.r_station_id
		if status == TO_P or status == AT_P then
			if p then
				dest[p] = (dest[p] or 0) + 1
				bound[p] = (bound[p] or 0) + 1
				if watch[p] then named[p] = named[p] or train_id end
			end
			if r then
				bound[r] = (bound[r] or 0) + 1
				if watch[r] then named[r] = named[r] or train_id end
			end
		elseif status == TO_R or status == AT_R then
			if r then
				dest[r] = (dest[r] or 0) + 1
				bound[r] = (bound[r] or 0) + 1
				if watch[r] then named[r] = named[r] or train_id end
			end
		elseif status == TO_F or status == AT_F then
			local f = train.refueler_id
			if f then dest[f] = (dest[f] or 0) + 1 end
		end
	end
	local delivered, stations = {}, storage.stations
	for id in pairs(watch) do
		local station = stations[id]
		delivered[id] = station and station.deliveries_total or 0
	end
	job.dest, job.bound, job.delivered, job.named = dest, bound, delivered, named
end

--- A pass is set up over three updates, so no update lists thousands of ids and indexes them as well: the station
--- and depot ids (the snapshot's own sorted lists), then the refueler and train ids with the names every depot and
--- refueler is known by, then the occupancy index alone (its counters must be read in the update that walks the
--- trains; the names need no such instant, and the index update is the most expensive of the three).
--- @param s LintState
--- @param snap Snapshot
--- @return LintJob
local function start_job(s, snap)
	local job = {
		started_tick = game.tick,
		setup = 1,
		sids = snap.station_ids or keys_into(storage.stations, {}),
		i = 0,
		ti = 0,
		findings = {},
		bits = {},
		train_bits = {},
		updates = 0,
	}
	s.job = job
	return job
end

--- Every stop at a non-default priority that shares a name with a Cybersyn station, depot or refueler, its own
--- included: a vanilla stop of that name pulls in Cybersyn's trains too.
--- @param force LuaForce?
--- @return LuaEntity[]
local function off_priority_stops(force)
	local seen, names = {}, {}
	for _, records in ipairs({ storage.stations, storage.depots, storage.refuelers }) do
		for _, rec in pairs(records) do
			local stop = rec.entity_stop
			local name = stop and stop.valid and stop.backer_name
			if name and not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
	end
	local out = {}
	if not names[1] then return out end
	for _, stop in pairs(game.train_manager.get_train_stops({ station_name = names, force = force })) do
		if stop.train_stop_priority ~= DEFAULT_PRIORITY then out[#out + 1] = stop end
	end
	return out
end

--- The priority to report for a Cybersyn stop: that of an off-priority stop of its name and force seen when the
--- pass started (read live), else its own.
--- @param job LintJob
--- @param stop LuaEntity
--- @return int
local function stop_priority(job, stop)
	local other = job.off_priority[stop.backer_name]
	if other and other.valid and other.force == stop.force then return other.train_stop_priority end
	return stop.train_stop_priority
end

--- @param job LintJob
--- @param snap Snapshot
local function setup_job(job, snap)
	if job.setup == 1 then
		local off = {}
		for _, stop in ipairs(off_priority_stops()) do off[stop.backer_name] = stop end
		job.off_priority = off
		job.dids = snap.depot_ids or keys_into(storage.depots, {})
		job.fids = keys_into(storage.refuelers, {})
		job.tids = keys_into(storage.trains, {})
		-- The names schedules use are the depots', the refuelers' and the stations' (seeded from the station list in
		-- later updates, before the train checks start); any other name is looked up once per pass (stop_exists).
		local names = {}
		for name in pairs(snap.depots_by_name or NO_LAYOUTS) do names[name] = true end
		for _, refueler in pairs(storage.refuelers) do
			local stop = refueler.entity_stop
			if stop and stop.valid then names[stop.backer_name] = true end
		end
		job.names = names
		job.seeded = 0
		job.setup = 2
	else
		occupancy_index(job, lint.state())
		job.setup = nil
	end
end

--- What the log last said about a subject whose mask changed during the running pass: a pass dropped half-way (the
--- last window closed) leaves the committed masks as they were, and the next pass must not log those transitions
--- again. Cleared when a pass commits (the committed masks then say the same).
--- @param s LintState
--- @param field "logged"|"train_logged"
--- @param id uint
--- @param mask int
local function note_logged(s, field, id, mask)
	local t = s[field]
	if not t then
		t = {}
		s[field] = t
	end
	t[id] = mask
end

--- Writes the transitions between `old` and `new` to the log.
--- @param pass uint the running pass's start tick + 1 (diag.lint)
local function transitions(subject, id, old, new, pass)
	if old == new then return end
	for check = 1, LINT_COUNT do
		local bit = LINT_BIT[check]
		local was, is = band(old, bit) ~= 0, band(new, bit) ~= 0
		if was ~= is then diag.lint(check, subject, id, is, pass) end
	end
end

--- A gap between two counts must hold for two planner cycles and across two passes before it is a finding: the
--- counts are read in one update, but a train Cybersyn just sent may not be in the stop's count yet.
--- @param since {[uint]: uint}
--- @return boolean
local function persisted(since, id, gap, job, cycle_ticks)
	if not gap then
		since[id] = nil
		return false
	end
	local now = game.tick
	local first = since[id]
	if not first then
		since[id] = now
		return false
	end
	return first < job.started_tick and now - first >= 2 * cycle_ticks
end

--- The refueler's network and mask as its combinator says now. Cybersyn refreshes its own copy only when a train
--- looks for a refueler, so a mask changed since then would otherwise go unnoticed until the next refuel.
--- @param refueler Refueler
--- @return {network_name: string?, network_mask: int|{[string]: int}}
local function live_refueler(refueler)
	local comb = refueler.entity_comb
	if not (comb and comb.valid) or refueler.network_name == NETWORK_EACH then return refueler end
	local name, mask = read_refueler_network(comb, get_comb_params(comb), mod_settings)
	return { network_name = name, network_mask = mask }
end

--- @class LintStationLive what check_station needs beyond the snapshot record
--- @field limit int
--- @field priority int? the stop's train_stop_priority
--- @field occupancy_gap boolean
--- @field occupancy int Cybersyn trains bound for the stop
--- @field count int the stop's trains_count
--- @field occupancy_train uint? a train at or for the stop that Cybersyn did not send there
--- @field phantom boolean
--- @field deliveries int
--- @field bound int
--- @field phantom_train uint? a train bound to the station (bound > deliveries)
--- @field phantom_status int? its status

--- True when Cybersyn sent `train` to station `id` (heading there or standing at it).
--- @param train Train?
--- @param id uint
--- @return boolean
local function sent_here(train, id)
	if not train then return false end
	local status = train.status
	if status == STATUS_TO_P or status == STATUS_P then return train.p_station_id == id end
	if status == STATUS_TO_R or status == STATUS_R then return train.r_station_id == id end
	return false
end

--- A train the stop counts (standing at it or heading to it) that Cybersyn did not send there, read now: the
--- index's count says only that there may be one. Also the trains among them Cybersyn did send, read at the same
--- instant, for the finding's detail.
--- @param stop LuaEntity
--- @param id uint
--- @return uint? train_id
--- @return int sent
local function foreign_train(stop, id)
	local trains = storage.trains
	local foreign, sent = nil, 0
	for _, t in pairs(stop.get_train_stop_trains()) do
		if t.valid and (t.station == stop or t.path_end_stop == stop) then
			if sent_here(trains[t.id], id) then
				sent = sent + 1
			elseif not foreign then
				foreign = t.id
			end
		end
	end
	return foreign, sent
end
lint.sent_here = sent_here

-- Reused for every station of a pass (the values are copied into findings, never kept).
--- @type LintStationLive
local live = {}
local station_keys = {}

--- @param s LintState
--- @param job LintJob
--- @param snap Snapshot
local function check_record(s, job, snap, k, cycle_ticks)
	local ns, nd = #job.sids, #job.dids
	local id, subject
	if k <= ns then
		id, subject = job.sids[k], LINT_SUBJECT_STATION
	elseif k <= ns + nd then
		id, subject = job.dids[k - ns], LINT_SUBJECT_DEPOT
	else
		id, subject = job.fids[k - ns - nd], LINT_SUBJECT_REFUELER
	end
	local out = job.findings
	local mask
	if subject == LINT_SUBJECT_STATION then
		local station = storage.stations[id]
		local st = snap.stations[id]
		local stop = station and station.entity_stop
		if not (st and stop and stop.valid) then return end
		local count = stop.trains_count
		local occupancy = job.dest[id] or 0
		local bound = job.bound[id] or 0
		local deliveries = job.delivered[id]
		local tid
		if deliveries then
			tid = job.named[id]
		else
			deliveries = station.deliveries_total or 0
		end
		live.limit = stop.trains_limit
		live.priority = stop_priority(job, stop)
		live.count = count
		live.occupancy = occupancy
		-- Only more trains than Cybersyn sent count: one it sent is routed through a rail record first and is not
		-- in the stop's count until it heads for the stop itself, and a delivery Cybersyn counts but no train serves
		-- is the phantom check's. The live count against the pass's index only nominates a candidate (as does a gap
		-- already seen: the index may have counted trains that left since); the stop's trains, compared with what
		-- Cybersyn sent there now, decide it and name the train.
		local foreign
		if count > occupancy or (count > 0 and s.occupancy_since[id]) then
			local sent
			foreign, sent = foreign_train(stop, id)
			if foreign then live.occupancy = sent end
		end
		live.occupancy_train = foreign
		live.occupancy_gap = persisted(s.occupancy_since, id, foreign ~= nil, job, cycle_ticks)
		-- The counter: a station with a gap sighted at the last pass is decided on the counter read with the index
		-- (occupancy_index); any other compares its live counter with the index, which can only sight a gap.
		live.deliveries = deliveries
		live.bound = bound
		live.phantom = persisted(s.phantom_since, id, deliveries ~= bound, job, cycle_ticks)
		if not (live.phantom and bound > deliveries) then tid = nil end
		local train = tid and storage.trains[tid]
		live.phantom_train = tid
		live.phantom_status = train and train.status or nil
		local keys = station_keys
		keys.overrides, keys.starved = snap.provider_overrides, snap.starved or NO_LAYOUTS
		mask = lint.check_station(out, id, st, station, snap.fleet, keys, live)
	elseif subject == LINT_SUBJECT_DEPOT then
		local depot = storage.depots[id]
		local stop = depot and depot.entity_stop
		if not (stop and stop.valid) then return end
		mask = lint.check_depot(out, id, stop.trains_limit, (snap.depots_by_name or NO_LAYOUTS)[stop.backer_name],
			stop_priority(job, stop))
	else
		local refueler = storage.refuelers[id]
		local stop = refueler and refueler.entity_stop
		if not (stop and stop.valid) then return end
		mask = lint.check_refueler(out, id, live_refueler(refueler), snap.fleet, stop_priority(job, stop))
	end
	local logged = s.logged
	local old = logged and logged[id] or s.bits[id] or 0
	if old ~= mask then
		transitions(subject, id, old, mask, job.started_tick + 1)
		note_logged(s, "logged", id, mask)
	end
	if mask ~= 0 then job.bits[id] = mask end
end

-- Reused for every train of a pass, as `live` is for stations.
local train_live = {}

--- @param job LintJob
--- @param name string
--- @param force LuaForce? the train's: a stop of another force with that name does not count
--- @return boolean
local function stop_exists(job, name, force)
	local names = job.names
	-- Seeded with the names of the snapshot's stops, depots and refuelers, which only a schedule of their own force
	-- can reach in practice; any other name is looked up for the train's force and cached per force.
	local known = names[name]
	if known == nil then
		local key = force and (force.index .. "\1" .. name) or name
		known = names[key]
		if known == nil then
			known = #game.train_manager.get_train_stops({ station_name = name, force = force }) > 0
			names[key] = known
			job.lookups = job.lookups + 1
		end
	end
	return known
end

-- On a delivery or refuel trip a train's schedule is the one Cybersyn just built from live stops, and its wagons
-- cannot change without the train becoming a new one; reading them costs up to 120 µs per train (get_records
-- builds every record, rail targets included), so they are read between trips and carried while the train is out.
-- A train first seen on a trip has nothing to carry and is read once it is back.
local ON_TRIP = { [STATUS_TO_F] = true, [STATUS_F] = true }
for status in pairs(STATUS_ON_DELIVERY) do ON_TRIP[status] = true end

--- @param s LintState
--- @param job LintJob
local function check_train(s, job, snap, id)
	local train = storage.trains[id]
	local entity = train and train.entity
	if not (entity and entity.valid) then return end
	local seen = s.train_live[id]
	if not ON_TRIP[train.status] or seen and seen.dirty then
		local missing
		local records = entity.get_schedule().get_records()
		local force
		for k, record in ipairs(records or NO_LAYOUTS) do
			local name = record.station
			if name and not force then
				local front = entity.front_stock
				force = front and front.force or nil
			end
			if name and not stop_exists(job, name, force) then
				missing = k
				break
			end
		end
		local items, fluid = train_capacity(entity)
		if not seen then
			seen = {}
			s.train_live[id] = seen
		end
		seen.missing, seen.items, seen.fluid, seen.dirty = missing, items, fluid, nil
	end
	local never, tracked
	if not train.refuel_tick then
		tracked = game.tick - lint.refuel_from(train)
		if tracked >= REFUEL_GRACE_TICKS then
			each_network(train.network_name, train.network_mask, function(net)
				if not never and storage.to_refuelers[net] then never = net end
			end)
		end
	end
	local tr = snap.trains[id]
	local group = tr and tr.group
	local spans = group and group ~= "" and snap.fleet.group_depots and snap.fleet.group_depots[group] or 0
	local mixed = spans > 1
	local t = train_live
	t.in_group = mixed
	t.group_depots = mixed and spans or nil
	t.never_refuelled = never
	t.tracked = tracked
	if seen then
		t.missing_record, t.items, t.fluid = seen.missing, seen.items, seen.fluid
	else
		t.missing_record, t.items, t.fluid = nil, train.item_slot_capacity or 0, nil
	end
	local mask = lint.check_train(job.findings, id, train, t)
	local logged = s.train_logged
	local old = logged and logged[id] or s.train_bits[id] or 0
	if old ~= mask then
		transitions(LINT_SUBJECT_TRAIN, id, old, mask, job.started_tick + 1)
		note_logged(s, "train_logged", id, mask)
	end
	if mask ~= 0 then job.train_bits[id] = mask end
end

--- Drops the masks of subjects that left Cybersyn (no event: the subject is gone, not fixed).
--- @param s LintState
local function prune(s)
	for id in pairs(s.bits) do
		if not (storage.stations[id] or storage.depots[id] or storage.refuelers[id]) then
			s.bits[id] = nil
		end
	end
	for id in pairs(s.occupancy_since) do
		if not storage.stations[id] then s.occupancy_since[id] = nil end
	end
	for id in pairs(s.phantom_since) do
		if not storage.stations[id] then s.phantom_since[id] = nil end
	end
	for id in pairs(s.train_bits) do
		if not storage.trains[id] then s.train_bits[id] = nil end
	end
	for id in pairs(s.train_live) do
		if not storage.trains[id] then s.train_live[id] = nil end
	end
end

--- Writes a station's committed mask into the snapshot records the views read (the one being collected too, whose
--- records copied the old mask), and enters the station in the collector's change log so per-player caches built
--- from the records (the Stations Setup and Failing chips) pick the new mask up on their next render.
local function set_station_lint(id, mask)
	local manager = storage.manager
	local changed = false
	for _, snap in pairs({ manager.snapshot, manager.snapshot_build }) do
		local st = snap.stations and snap.stations[id]
		if st and st.lint ~= mask then
			st.lint = mask
			changed = true
		end
	end
	-- The log is the collector's (collector.changed_since); it requires this module, so it is appended to directly.
	local log = changed and manager.collect_log
	if log then log.ids[#log.ids + 1] = id end
end

--- Ends the acknowledgements of setup findings that cleared with this pass (the registry ends its own).
--- @param s LintState
local function resolve_acks(s)
	local acks = storage.acks
	if not (acks and next(acks.lint)) then return end
	local ended = {}
	for key, by in pairs(acks.lint) do
		local mask = key < 0 and s.train_bits[-key] or s.bits[key] or 0
		for check in pairs(by) do
			if not REGISTRY_CHECKS[check] and band(mask, LINT_BIT[check] or 0) == 0 then
				ended[#ended + 1] = { key, check }
			end
		end
	end
	for _, e in ipairs(ended) do diag.resolve_lint_ack(e[1], e[2]) end
end

--- A pass's masks become the current ones together with its findings, so st.lint, the Stations Setup chip, the
--- Overview's misconfigured line and the Stations Problems view always count the same pass.
--- @param s LintState
--- @param job LintJob
local function commit(s, job)
	local old, new = s.bits, job.bits
	for id, m in pairs(new) do
		if old[id] ~= m and storage.stations[id] then set_station_lint(id, m) end
	end
	for id in pairs(old) do
		if not new[id] and storage.stations[id] then set_station_lint(id, 0) end
	end
	s.bits = new
	s.train_bits = job.train_bits
	s.logged, s.train_logged = nil, nil
	resolve_acks(s)
end

--- Advances the setup job by one update's worth: the cursor lists in the first update of a pass, the per-pass
--- indexes in the second, then up to `records` station/depot/refueler records and `trains` trains per update.
--- @param records int?
--- @param trains int?
--- @return boolean completed a pass
function lint.step(records, trains)
	local snap = storage.manager.snapshot
	-- The fleet facts and station records come from a complete pass.
	if not (snap and snap.tick) then return false end
	local s = lint.state()
	local job = s.job
	if not job then
		job = start_job(s, snap)
		job.updates = 1
		if not records then return false end
	end
	while job.setup do
		setup_job(job, snap)
		if not records then
			job.updates = job.updates + 1
			return false
		end
	end
	job.updates = job.updates + 1
	job.lookups = 0
	local cycle = storage.stats and storage.stats.cycle
	local cycle_ticks = math.max(cycle and cycle.ticks_last or 0, 1)
	local n = #job.sids + #job.dids + #job.fids
	local stop_at = math.min(n, job.i + (records or RECORDS_PER_UPDATE))
	while job.i < stop_at do
		job.i = job.i + 1
		check_record(s, job, snap, job.i, cycle_ticks)
	end
	local nt = #job.tids
	local sids = job.sids
	if job.seeded < #sids then
		local names, stations = job.names, snap.stations
		local last = math.min(#sids, job.seeded + (records and records * 10 or SEED_PER_UPDATE))
		for k = job.seeded + 1, last do
			local st = stations[sids[k]]
			if st then names[st.name] = true end
		end
		job.seeded = last
	else
		local last = math.min(nt, job.ti + (trains or TRAINS_PER_UPDATE))
		local lookups = trains and math.huge or LOOKUPS_PER_UPDATE
		while job.ti < last and job.lookups < lookups do
			job.ti = job.ti + 1
			check_train(s, job, snap, job.tids[job.ti])
		end
	end
	if job.i >= n and job.ti >= nt and job.seeded >= #sids then
		commit(s, job)
		s.findings = job.findings
		s.pass = s.pass + 1
		s.tick = game.tick
		s.updates = job.updates
		s.job = nil
		prune(s)
		return true
	end
	return false
end

--- Progress of the first pass: nil once a pass completed, else 0..1 (0 while none runs yet). Until then every station
--- reads clean, so the tabs show progress rather than a confident 0.
--- @return number?
function lint.progress()
	local s = storage.manager.lint
	if s and s.tick then return nil end
	local job = s and s.job
	if not job then return 0 end
	local n = #(job.sids or {}) + #(job.dids or {}) + #(job.fids or {}) + #(job.tids or {})
	local done = (job.i or 0) + (job.ti or 0)
	return math.min(done / math.max(n, 1), 1)
end

-- lint.findings' last merge, by the identity of its two inputs (both are replaced, never edited, when they change);
-- a joining client starts with none and merges the same lists.
local merged = { pass = nil, registry = nil, list = nil }

--- Findings of the last complete pass, then the registry's (read only).
--- @return LintFinding[]
function lint.findings()
	local manager = storage.manager
	local s = manager and manager.lint
	local pass = s and s.findings or NO_LAYOUTS
	local reg = lint.registry_findings()
	if #reg == 0 then return pass end
	if #pass == 0 then return reg end
	if merged.pass == pass and merged.registry == reg then return merged.list end
	local list = {}
	for i, f in ipairs(pass) do list[i] = f end
	local n = #pass
	for i, f in ipairs(reg) do list[n + i] = f end
	merged.pass, merged.registry, merged.list = pass, reg, list
	return list
end

-- ---------------------------------------------------------------- the setup registry

--- @class LintRegistry
--- @field entries {[uint]: LintRegistryEntry} by the stop's or combinator's unit number
--- @field version int counts the changes (caches and render sigs)
--- @field findings LintFinding[]? built from the entries on demand, dropped on every change

--- @class LintRegistryEntry
--- @field entity LuaEntity the stop or combinator
--- @field subject int LINT_SUBJECT_STOP or LINT_SUBJECT_COMBINATOR
--- @field msgs {[string]: true} [cybersyn-problems] keys, each one finding
--- @field stop LuaEntity? wrong side: the stop the combinator stands next to

local MESSAGE_CHECK = LINT_MESSAGE_CHECK
lint.MESSAGE_CHECK = MESSAGE_CHECK

-- What one evaluation decides: eval_stop the combinator facts of a stop, eval_name the name overlap (per name, so
-- a depot's creation reaches every stop of its name), eval_comb an orphan combinator's.
local STOP_MESSAGES = { "double-station", "double-station-control", "double-depot", "double-refueler",
	"station-and-depot", "station-and-refueler", "depot-and-refueler", "ghost-combinator", "stop-no-combinator" }
local OVERLAP_MESSAGES = { "name-overlap-with-depot" }
local COMB_MESSAGES = { "derelict-combinator", "wrong-side-combinator" }
local OVERLAP = { ["name-overlap-with-depot"] = true }
local DERELICT = { ["derelict-combinator"] = true }
local WRONG_SIDE = { ["wrong-side-combinator"] = true }

local PRIMARY = {
	[MODE_PRIMARY_IO] = true,
	[MODE_PRIMARY_IO_ACTIVE] = true,
	[MODE_PRIMARY_IO_FAILED_REQUEST] = true,
}

-- Cybersyn adopts the combinators within 2 tiles of a stop (scripts/main.lua); one tile more also finds those that
-- stand beside the stop but face away from it, and the ghosts waiting to be built there.
local REACH = 3

--- @param pos MapPosition
--- @return BoundingBox
local function reach_box(pos)
	return { { pos.x - REACH, pos.y - REACH }, { pos.x + REACH, pos.y + REACH } }
end

--- @return LintRegistry
local function registry()
	local reg = storage.lint_registry
	if not reg then
		reg = { entries = {}, version = 0 }
		storage.lint_registry = reg
	end
	return reg
end

--- @param reg LintRegistry
local function changed(reg)
	reg.version = reg.version + 1
	reg.findings = nil
end

--- Ends the acknowledgements of `checks` on `unit` that no remaining message still finds.
--- @param unit uint
--- @param msgs {[string]: true}
--- @param checks int[]
local function end_acks(unit, msgs, checks)
	local acks = storage.acks
	if not (acks and acks.lint[unit]) then return end
	for _, check in ipairs(checks) do
		local still = false
		for m in pairs(msgs) do
			if MESSAGE_CHECK[m] == check then
				still = true
				break
			end
		end
		if not still then diag.resolve_lint_ack(unit, check) end
	end
end

--- Replaces what one evaluation decides about `entity` (the messages in `owned`) with `found`.
--- @param entity LuaEntity
--- @param subject int
--- @param owned string[]
--- @param found {[string]: true}?
--- @param stop LuaEntity? COMB_MESSAGES only: the stop of a wrong-side finding
local function set(entity, subject, owned, found, stop)
	local reg = registry()
	local unit = entity.unit_number --[[@as uint]]
	local entry = reg.entries[unit]
	if not entry then
		if not (found and next(found)) then return end
		entry = { entity = entity, subject = subject, msgs = {} }
		reg.entries[unit] = entry
		-- Covers what no removal handler sees: a script's destroy without raise_destroy, a deleted surface.
		script.register_on_object_destroyed(entity)
	end
	local msgs = entry.msgs
	local dirty, gone = false, nil
	for _, m in ipairs(owned) do
		local want = found and found[m] or nil
		if msgs[m] ~= want then
			msgs[m] = want
			dirty = true
			if not want then
				gone = gone or {}
				gone[#gone + 1] = MESSAGE_CHECK[m]
			end
		end
	end
	if owned == COMB_MESSAGES and entry.stop ~= stop then
		entry.stop = stop
		dirty = true
	end
	if not next(msgs) then reg.entries[unit] = nil end
	if gone then end_acks(unit, msgs, gone) end
	if dirty then changed(reg) end
end

--- Forgets a removed stop or combinator.
--- @param unit uint
local function drop(unit)
	local reg = storage.lint_registry
	local entry = reg and reg.entries[unit]
	if not entry then return end
	reg.entries[unit] = nil
	local checks = {}
	for m in pairs(entry.msgs) do checks[#checks + 1] = MESSAGE_CHECK[m] end
	end_acks(unit, {}, checks)
	changed(reg)
end

--- The stop's combinator facts from the combinators Cybersyn attached to it (`c`, counted by mode), whether it is
--- registered and whether a combinator ghost stands within reach.
--- @param c {primary: int, secondary: int, depot: int, refueler: int, attached: int}
--- @param registered boolean
--- @param ghost boolean
--- @return {[string]: true}? found
function lint.stop_facts(c, registered, ghost)
	local primary, depot, refueler = c.primary, c.depot, c.refueler
	-- The common case, one station, depot or refueler combinator and at most one control combinator, allocates nothing.
	if registered and primary + depot + refueler <= 1 and c.secondary <= 1 then return nil end
	local found = {}
	if primary > 1 then found["double-station"] = true end
	if c.secondary > 1 then found["double-station-control"] = true end
	if depot > 1 then found["double-depot"] = true end
	if refueler > 1 then found["double-refueler"] = true end
	if primary > 0 and depot > 0 then found["station-and-depot"] = true end
	if primary > 0 and refueler > 0 then found["station-and-refueler"] = true end
	if depot > 0 and refueler > 0 then found["depot-and-refueler"] = true end
	if not registered then
		if ghost then
			found["ghost-combinator"] = true
		elseif c.attached > 0 then
			found["stop-no-combinator"] = true
		end
	end
	return next(found) and found or nil
end

--- @return {primary: int, secondary: int, depot: int, refueler: int, attached: int}
local function new_counts()
	return { primary = 0, secondary = 0, depot = 0, refueler = 0, attached = 0 }
end

--- @param c {primary: int, secondary: int, depot: int, refueler: int, attached: int}
--- @param params {operation: string}?
local function count(c, params)
	local op = params and params.operation
	c.attached = c.attached + 1
	if PRIMARY[op] then
		c.primary = c.primary + 1
	elseif op == MODE_SECONDARY_IO then
		c.secondary = c.secondary + 1
	elseif op == MODE_DEPOT then
		c.depot = c.depot + 1
	elseif op == MODE_REFUELER then
		c.refueler = c.refueler + 1
	end
end

--- @param unit uint
--- @return boolean
local function registered(unit)
	return (storage.stations[unit] or storage.depots[unit] or storage.refuelers[unit]) ~= nil
end

--- A combinator no stop owns: wrong side when a stop stands within reach (it faces away), derelict otherwise.
--- Clears both when a stop owns it again or it is a wagon combinator, which needs no stop.
--- @param comb LuaEntity
--- @param except LuaEntity? a stop being removed
local function eval_comb(comb, except)
	if not comb.valid then return end
	local unit = comb.unit_number --[[@as uint]]
	local stop = storage.to_stop[unit]
	local params = storage.to_comb_params[unit]
	if (stop and stop.valid) or (params and params.operation == MODE_WAGON) then
		set(comb, LINT_SUBJECT_COMBINATOR, COMB_MESSAGES, nil)
		return
	end
	local near
	for _, e in pairs(comb.surface.find_entities_filtered({ area = reach_box(comb.position), name = "train-stop" })) do
		if e.valid and e ~= except then
			near = e
			break
		end
	end
	set(comb, LINT_SUBJECT_COMBINATOR, COMB_MESSAGES, near and WRONG_SIDE or DERELICT, near)
end

--- A stop's combinator facts, from the combinators and ghosts within reach (`except` is one being removed), and
--- the facts of every combinator there that no stop owns or that the registry holds (a stop built or removed
--- next to them changes those).
--- @param stop LuaEntity
--- @param except LuaEntity?
local function eval_stop(stop, except)
	if not stop.valid then return end
	local to_stop, params, entries = storage.to_stop, storage.to_comb_params, registry().entries
	local c = new_counts()
	local ghost = false
	local recheck
	local found = stop.surface.find_entities_filtered({ area = reach_box(stop.position),
		name = { COMBINATOR_NAME, "entity-ghost" } })
	for _, e in pairs(found) do
		if e.valid and e ~= except then
			if e.name == "entity-ghost" then
				if e.ghost_name == COMBINATOR_NAME then ghost = true end
			else
				local unit = e.unit_number --[[@as uint]]
				local owner = to_stop[unit]
				if owner == stop then count(c, params[unit]) end
				if entries[unit] or not (owner and owner.valid) then
					recheck = recheck or {}
					recheck[#recheck + 1] = e
				end
			end
		end
	end
	set(stop, LINT_SUBJECT_STOP, STOP_MESSAGES, lint.stop_facts(c, registered(stop.unit_number --[[@as uint]]), ghost))
	if recheck then
		for _, e in ipairs(recheck) do eval_comb(e) end
	end
end

--- Every stop within reach of `pos`.
--- @param surface LuaSurface
--- @param pos MapPosition
--- @param except LuaEntity?
local function eval_around(surface, pos, except)
	for _, stop in pairs(surface.find_entities_filtered({ area = reach_box(pos), name = "train-stop" })) do
		if stop ~= except then eval_stop(stop, except) end
	end
end

--- The name overlap of every stop of `force` called `name`: set on the stops that are not depots while a depot has
--- the name (trains route by name within their own force only).
--- @param name string?
--- @param force LuaForce
local function eval_name(name, force)
	if not name then return end
	local stops = game.train_manager.get_train_stops({ station_name = name, force = force })
	local depots = storage.depots
	local any = false
	for _, stop in pairs(stops) do
		if depots[stop.unit_number] then
			any = true
			break
		end
	end
	for _, stop in pairs(stops) do
		set(stop, LINT_SUBJECT_STOP, OVERLAP_MESSAGES, any and not depots[stop.unit_number] and OVERLAP or nil)
	end
end

-- The handlers in scripts/main.lua call these once Cybersyn's own handling of the event is done, so what they read
-- (to_stop, to_comb_params, stations, depots, refuelers) is what the event left.

--- A combinator was built, rebuilt (a mode change or a rotation that changed its stop) or revived from a ghost.
--- @param comb LuaEntity
function lint.on_combinator_built(comb)
	eval_comb(comb)
	eval_around(comb.surface, comb.position)
end

--- A combinator is being removed (it is still in the world).
--- @param comb LuaEntity
function lint.on_combinator_removed(comb)
	drop(comb.unit_number --[[@as uint]])
	eval_around(comb.surface, comb.position, comb)
end

--- A combinator ghost was placed, or is being removed (`removed`; it is still in the world).
--- @param ghost LuaEntity
--- @param removed boolean?
function lint.on_ghost_changed(ghost, removed)
	eval_around(ghost.surface, ghost.position, removed and ghost or nil)
end

--- @param stop LuaEntity
function lint.on_stop_built(stop)
	eval_stop(stop)
	eval_name(stop.backer_name, stop.force)
end

--- A stop is being removed (it is still in the world); `orphans` are the combinators it owned. A combinator facing
--- away from it is no stop's either and was wrong side only because of it, so every combinator within reach that no
--- other stop owns, or that the registry holds, is looked at again (the rule eval_stop uses).
--- @param stop LuaEntity
--- @param orphans LuaEntity[]
function lint.on_stop_removed(stop, orphans)
	local seen = {}
	for _, comb in ipairs(orphans) do
		seen[comb] = true
		eval_comb(comb, stop)
	end
	local to_stop, entries = storage.to_stop, registry().entries
	for _, e in pairs(stop.surface.find_entities_filtered({ area = reach_box(stop.position), name = COMBINATOR_NAME })) do
		if e.valid and not seen[e] then
			local unit = e.unit_number --[[@as uint]]
			local owner = to_stop[unit]
			if entries[unit] or not (owner and owner.valid and owner ~= stop) then eval_comb(e, stop) end
		end
	end
	drop(stop.unit_number --[[@as uint]])
end

--- @param stop LuaEntity
--- @param old_name string
function lint.on_stop_renamed(stop, old_name)
	eval_name(old_name, stop.force)
	eval_name(stop.backer_name, stop.force)
end

--- A depot was created or removed at `stop`: the stops sharing its name gain or lose the overlap.
--- @param stop LuaEntity?
function lint.on_depot_changed(stop)
	if stop and stop.valid then eval_name(stop.backer_name, stop.force) end
end

--- @param e EventData.on_train_schedule_changed
function lint.on_train_schedule_changed(e)
	local s = e.player_index and storage.manager.lint
	local seen = s and e.train.valid and s.train_live[e.train.id]
	if seen then seen.dirty = true end
end

--- @param e EventData.on_object_destroyed
function lint.on_object_destroyed(e)
	if e.type == defines.target_type.entity then drop(e.useful_id) end
end

--- Ends the acknowledgements of registry checks the registry no longer has (after a seed).
local function resolve_registry_acks()
	local acks = storage.acks
	if not (acks and next(acks.lint)) then return end
	local entries = registry().entries
	local ended = {}
	for key, by in pairs(acks.lint) do
		local entry = key > 0 and entries[key]
		for check in pairs(by) do
			if REGISTRY_CHECKS[check] then
				local still = false
				for m in pairs(entry and entry.msgs or NO_LAYOUTS) do
					if MESSAGE_CHECK[m] == check then still = true end
				end
				if not still then ended[#ended + 1] = { key, check } end
			end
		end
	end
	for _, e in ipairs(ended) do diag.resolve_lint_ack(e[1], e[2]) end
end

--- Builds the registry from Cybersyn's own tables: the combinators
--- each stop owns give the doubled and control-only stops with no world read; only a combinator no stop owns costs
--- one search for a stop within reach (wrong side or derelict), and a ghost one for the stops it stands beside.
--- @return {orphans: int, ghosts: int, names: int, entries: int}
function lint.registry_seed()
	local old = storage.lint_registry
	storage.lint_registry = { entries = {}, version = (old and old.version or 0) + 1 }
	local to_stop, params = storage.to_stop or {}, storage.to_comb_params or {}
	local groups = {}
	local function group(stop)
		local unit = stop.unit_number --[[@as uint]]
		local g = groups[unit]
		if not g then
			g = { stop = stop, c = new_counts(), ghost = false }
			groups[unit] = g
		end
		return g
	end
	local orphans, ghosts = 0, 0
	-- A combinator a stop owns is a built one (ghosts never get a stop), so only the others are read from the game.
	for unit, comb in pairs(storage.to_comb or {}) do
		local stop = to_stop[unit]
		if stop and stop.valid then
			count(group(stop).c, params[unit])
		elseif comb.valid then
			if comb.name == "entity-ghost" then
				ghosts = ghosts + 1
				for _, near in pairs(comb.surface.find_entities_filtered({ area = reach_box(comb.position),
					name = "train-stop" })) do
					group(near).ghost = true
				end
			else
				local p = params[unit]
				if not (p and p.operation == MODE_WAGON) then
					orphans = orphans + 1
					eval_comb(comb)
				end
			end
		end
	end
	for unit, g in pairs(groups) do
		local found = lint.stop_facts(g.c, registered(unit), g.ghost)
		if found then set(g.stop, LINT_SUBJECT_STOP, STOP_MESSAGES, found) end
	end
	local names, n = {}, 0
	for _, depot in pairs(storage.depots or {}) do
		local stop = depot.entity_stop
		if stop and stop.valid then
			local key = stop.force.index .. "\1" .. stop.backer_name
			if not names[key] then
				names[key] = { stop.backer_name, stop.force }
				n = n + 1
			end
		end
	end
	for _, nf in pairs(names) do eval_name(nf[1], nf[2]) end
	resolve_registry_acks()
	return { orphans = orphans, ghosts = ghosts, names = n, entries = table_size(storage.lint_registry.entries) }
end

--- The registry's findings, one per message, by unit number (read only).
--- @return LintFinding[]
function lint.registry_findings()
	local reg = storage.lint_registry
	if not reg then return NO_LAYOUTS end
	local list = reg.findings
	if list then
		-- A removed entity's entry stays until on_object_destroyed, at the end of this tick or the next.
		for _, f in ipairs(list) do
			if not f.entity.valid then
				list = nil
				break
			end
		end
		if list then return list end
	end
	local units = {}
	for unit, entry in pairs(reg.entries) do
		if entry.entity.valid then units[#units + 1] = unit end
	end
	table.sort(units)
	list = {}
	for _, unit in ipairs(units) do
		local entry = reg.entries[unit]
		local msgs = {}
		for m in pairs(entry.msgs) do msgs[#msgs + 1] = m end
		table.sort(msgs)
		for _, m in ipairs(msgs) do
			list[#list + 1] = { subject = entry.subject, id = unit, check = MESSAGE_CHECK[m], entity = entry.entity,
				message = m, stop = entry.stop }
		end
	end
	reg.findings = list
	return list
end

--- The stop or combinator with this unit number: a stop from the registry, since the base train stop cannot be
--- looked up by unit number; a combinator from the game, registered or not.
--- @param unit uint
--- @return LuaEntity?
function lint.registry_entity(unit)
	local reg = storage.lint_registry
	local entry = reg and reg.entries[unit]
	local e = entry and entry.entity or game.get_entity_by_unit_number(unit)
	if e and e.valid then return e end
	return nil
end

--- Prints the registry the way /cybersyn-find-problems always has: one line per problem with a link to the stop or
--- the combinator's position, then the stops sharing a Cybersyn stop's name at a non-default priority (read now: no
--- event reports a priority change), or the all-clear line.
--- @param player LuaPlayer?
--- @return int lines
function lint.report(player)
	local function say(message)
		if player and player.valid then player.print(message) else game.print(message) end
	end
	local n = 0
	local function line(entity, message)
		local where = entity and entity.valid and entity_richtext(entity) or nil
		local text = { "cybersyn-problems." .. message }
		say(where and { "", where, " ", text } or text)
		n = n + 1
	end
	local force = player and player.valid and player.force or nil
	for _, f in ipairs(lint.registry_findings()) do
		if not force or f.entity.force == force then
			line(f.message == "wrong-side-combinator" and f.stop or f.entity, f.message)
		end
	end
	for _, stop in ipairs(off_priority_stops(force)) do line(stop, "non-default-priority") end
	if n == 0 then say({ "cybersyn-problems.no-problems-found" }) end
	return n
end

--- Drops a station's findings from a findings list; returns the list itself when it has none.
--- @param findings LintFinding[]
--- @param id uint
--- @return LintFinding[] kept
--- @return boolean hit
local function without_station(findings, id)
	local hit = false
	for _, f in ipairs(findings) do
		if f.subject == LINT_SUBJECT_STATION and f.id == id then
			hit = true
			break
		end
	end
	if not hit then return findings, false end
	local kept = {}
	for _, f in ipairs(findings) do
		if not (f.subject == LINT_SUBJECT_STATION and f.id == id) then kept[#kept + 1] = f end
	end
	return kept, true
end

--- A station left Cybersyn: its findings of the last pass go now, not at the next pass, so the Problems view counts the
--- same stations as the Overview's misconfigured line in between. Its snapshot record's mask goes with them (the
--- record itself stays until the collector's pass ends), and the running pass forgets it so its commit does not
--- bring it back.
--- @param id uint
function lint.station_removed(id)
	local manager = storage.manager
	local s = manager and manager.lint
	if not s then return end
	if s.bits[id] then set_station_lint(id, 0) end
	s.bits[id] = nil
	local job = s.job
	if job and job.bits and job.findings then
		job.bits[id] = nil
		job.findings = without_station(job.findings, id)
	end
	local kept, hit = without_station(s.findings, id)
	if not hit then return end
	s.findings = kept
	s.removed = (s.removed or 0) + 1
end

return lint
