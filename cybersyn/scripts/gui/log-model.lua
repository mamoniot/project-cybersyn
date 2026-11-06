-- What the Log tab shows, read from diag's two rings: the rows (adjacent identical events collapsed
-- into one row with a count), the severity counts, the unread-error badge and the Summary tables. Pure over the ring
-- tables and plain values, so the host tests cover it; scripts/gui/log.lua turns the result into elements.
--
-- Nothing here scans a ring whole per update: a full ring on a 2,030-station base is 20,480 rows, about 4 ms to walk.
-- The rows come from a backward scan from the head that stops once the window's rows are filled, then follow the head
-- forward; the counts are kept per 256-seq bucket so rows leaving the window (or the ring) at the old end are
-- subtracted by recounting one bucket; every scan examines at most `budget` rows per call, reports how many it used
-- (the Log shares one budget per update between them) and continues from the seq it reached on the next call.

local format = require("__flib__.format")
local diag = require("scripts.diag")
local rich_text = require("scripts.gui.rich-text")
local logic = require("scripts.gui.tab-logic")
local utext = require("scripts.gui.unserved-text")

local model = {}

model.BUDGET = 4096
-- The Log's scroll pane holds the newest PAGE matching rows, in Follow and paused alike.
model.PAGE = 200
model.BUCKET = 256
-- Counts this far behind the head are rebuilt by the chunked backward scan rather than caught up in one call.
model.COUNTS_BEHIND = 4096
model.SUMMARY_TOP = 10
-- Window drop-down: 10 min, 1 h, everything the rings hold.
model.WINDOWS = { 36000, 216000, false }
model.DEFAULT_WINDOW = 3

local at, first_after = diag.ring_at, diag.first_after
local SCHEMA = DIAG_KIND_SCHEMA
local KIND_ALERT = DIAG_KIND_ALERT
local KIND_LINT = DIAG_KIND_LINT

--- Kind groups of the drop-down. An alert belongs to the group of what it is about, by its code.
model.GROUPS = {
	{
		name = "unserved",
		kinds = { DIAG_KIND_UNSERVED_REASON, DIAG_KIND_SERVED, DIAG_KIND_FLAPPING },
		alerts = { DIAG_ALERT_MISSING_TRAIN, DIAG_ALERT_NO_TRAIN_HAS_CAPACITY, DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT,
			DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT, DIAG_ALERT_TRAINS_FILTERED },
	},
	{
		name = "deliveries",
		kinds = { DIAG_KIND_DISPATCH_FAILED, DIAG_KIND_DELIVERY_FAILED, DIAG_KIND_SLOW_DELIVERY, DIAG_KIND_DISPATCHED,
			DIAG_KIND_ARRIVE_P, DIAG_KIND_LEAVE_P, DIAG_KIND_ARRIVE_R, DIAG_KIND_LEAVE_R, DIAG_KIND_RETURNED },
	},
	{
		name = "stations",
		kinds = { DIAG_KIND_STATION_POWER, DIAG_KIND_STATION_LIMIT, DIAG_KIND_STATION_WARMUP_DONE,
			DIAG_KIND_STATION_DISABLED },
		alerts = { DIAG_ALERT_DEPOT_BROKEN, DIAG_ALERT_STATION_BROKEN, DIAG_ALERT_REFUELER_BROKEN,
			DIAG_ALERT_NON_DEFAULT_PRIORITY },
	},
	{
		name = "trains",
		kinds = { DIAG_KIND_TRAIN_STATE, DIAG_KIND_SCHEDULE_EDITED },
		-- Listed under this group in the drop-down only: picking it shows every alert, whatever it is about.
		items = { DIAG_KIND_ALERT },
		alerts = { DIAG_ALERT_STUCK, DIAG_ALERT_NONEMPTY_IN_DEPOT, DIAG_ALERT_AT_INCORRECT_STATION,
			DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES, DIAG_ALERT_GROUP_SCHEDULE_BROKEN, DIAG_ALERT_SCHEDULE_BROKEN,
			DIAG_ALERT_UNEXPECTED_TRAIN },
	},
	{
		name = "cargo",
		kinds = { DIAG_KIND_SHORT_LOAD, DIAG_KIND_UNEXPECTED_CARGO, DIAG_KIND_RESIDUAL_CARGO },
		alerts = { DIAG_ALERT_UNEXPECTED_CARGO },
	},
	{ name = "setup", kinds = { DIAG_KIND_LINT } },
	{ name = "actions", kinds = { DIAG_KIND_ACKNOWLEDGED, DIAG_KIND_UNACKNOWLEDGED, DIAG_KIND_MANUAL_ACTION } },
}

--- The kind drop-down, in order: everything, then each group followed by its kinds. The trains group lists the
--- alert kind itself (every alert, whatever it is about); the group filters take alerts by code.
--- @type {group: int?, kind: int?}[]
model.KIND_ITEMS = { {} }
for g, group in ipairs(model.GROUPS) do
	model.KIND_ITEMS[#model.KIND_ITEMS + 1] = { group = g }
	for _, kind in ipairs(group.kinds) do
		model.KIND_ITEMS[#model.KIND_ITEMS + 1] = { kind = kind }
	end
	for _, kind in ipairs(group.items or {}) do
		model.KIND_ITEMS[#model.KIND_ITEMS + 1] = { kind = kind }
	end
end

--- @class LogFilter per player (player_data.tabs.log_tab.filter); plain values only
--- @field sev boolean[] error, warning, info shown
--- @field group int? index into model.GROUPS
--- @field kind int? DIAG_KIND_*
--- @field train uint? from the train-id field
--- @field window int index into model.WINDOWS
--- @field follow boolean
--- @field summary boolean

--- @return LogFilter
function model.default_filter()
	return { sev = { true, true, true }, window = model.DEFAULT_WINDOW, follow = true, summary = false }
end

--- @class LogCompiled the filter as the scans read it
--- @field sevs boolean[]
--- @field kinds {[int]: true}?
--- @field alerts {[int]: true}?
--- @field train uint?
--- @field station uint? the station chip's station (station column, or station2 where it names a station)
--- @field item int? item index (the manager's item filter); -1 = an item diagnostics never logged
--- @field min_tick uint?
--- @field any boolean some filter besides the severities and the window is set (else `match` is always true)
--- @field sig string everything but the severities
--- @field sev_sig string

--- @param f LogFilter
--- @param now uint
--- @param item int? the manager's item filter as diag's item index (-1 when diagnostics never logged that item)
--- @param station uint? the manager's station chip: events whose station (or station2 naming a station) is it
--- @return LogCompiled
function model.compile(f, now, item, station)
	local kinds, alerts
	if f.group and model.GROUPS[f.group] then
		local group = model.GROUPS[f.group]
		kinds = {}
		for _, k in ipairs(group.kinds) do kinds[k] = true end
		if group.alerts then
			alerts = {}
			for _, c in ipairs(group.alerts) do alerts[c] = true end
		end
	elseif f.kind then
		kinds = { [f.kind] = true }
	end
	local window = model.WINDOWS[f.window or model.DEFAULT_WINDOW]
	local sevs = { f.sev[1] == true, f.sev[2] == true, f.sev[3] == true }
	return {
		sevs = sevs,
		kinds = kinds,
		alerts = alerts,
		train = f.train,
		item = item,
		station = station,
		min_tick = window and math.max(0, now - window) or nil,
		any = kinds ~= nil or f.train ~= nil or item ~= nil or station ~= nil,
		sig = table.concat({ tostring(f.group), tostring(f.kind), tostring(f.train), tostring(f.window),
			tostring(item), tostring(station) }, "|"),
		sev_sig = (sevs[1] and "e" or "") .. (sevs[2] and "w" or "") .. (sevs[3] and "i" or ""),
	}
end

--- Every filter but the severities (those are what the counts split by).
--- @param r DiagRing
--- @param i int ring index
--- @param cf LogCompiled
--- @return boolean
local function match(r, i, cf)
	local kind = r.kind[i]
	local kinds = cf.kinds
	if kinds and not kinds[kind] then
		local alerts = cf.alerts
		if not (alerts and kind == KIND_ALERT and alerts[r.code[i]]) then return false end
	end
	local train = cf.train
	if train and r.train[i] ~= train then return false end
	local item = cf.item
	if item and r.item[i] ~= item then return false end
	local st = cf.station
	if st and r.station[i] ~= st and not (r.station2[i] == st and SCHEMA[kind].station2 == "station") then
		return false
	end
	return true
end
model.match = match

--- The same filter as diag.export takes it (DiagEventFilter).
--- @param cf LogCompiled
--- @return DiagEventFilter
function model.export_filter(cf)
	local sevs
	if not (cf.sevs[1] and cf.sevs[2] and cf.sevs[3]) then
		sevs = {}
		for s = 1, 3 do
			if cf.sevs[s] then sevs[s] = true end
		end
	end
	return {
		kinds = cf.kinds,
		alerts = cf.alerts,
		sevs = sevs,
		train = cf.train,
		item = cf.item,
		station = cf.station,
		min_tick = cf.min_tick,
	}
end

-- ---------------------------------------------------------------- scans

--- Visits rows with seq < `below` of both rings merged by seq, newest first, that pass `match` (not the severities),
--- until the rings or the window end, `visit(r, i)` returns true, or `budget` rows have been examined.
--- @param rb DiagRing
--- @param rf DiagRing? the full ring, nil while full is off
--- @param below uint
--- @param cf LogCompiled
--- @param budget int
--- @param visit fun(r: DiagRing, i: int): boolean?
--- @return boolean ended the rings or the window ended
--- @return uint? below where a later call continues (the row that stopped the scan is examined again)
--- @return int examined rows examined
local function scan_back(rb, rf, below, cf, budget, visit)
	local kb = first_after(rb, below - 1) - 1
	local kf = rf and (first_after(rf, below - 1) - 1) or -1
	local min_tick = cf.min_tick
	local any = cf.any ~= false
	local n = 0
	while true do
		local ib = kb >= 0 and at(rb, kb) or nil
		local iff = kf >= 0 and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] > rf.seq[iff]) then
			r, i, kb = rb, ib, kb - 1
		elseif iff then
			r, i, kf = rf, iff, kf - 1
		else
			return true, nil, n
		end
		-- Seq order is tick order in both rings, so the first row before the window ends the whole scan.
		if min_tick and r.tick[i] < min_tick then return true, nil, n end
		local seq = r.seq[i]
		if n >= budget then return false, seq + 1, n end
		n = n + 1
		if (not any or match(r, i, cf)) and visit(r, i) then return false, seq + 1, n end
	end
end
model.scan_back = scan_back

--- Visits rows with seq > `after`, both rings merged by seq, oldest first (no filter), at most `budget` of them.
--- @param rb DiagRing
--- @param rf DiagRing?
--- @param after uint
--- @param budget int
--- @param visit fun(r: DiagRing, i: int)
--- @return uint reached every row up to this seq was visited
--- @return boolean ended no row above `reached` was left
--- @return int visited
local function scan_fwd(rb, rf, after, budget, visit)
	local kb = first_after(rb, after)
	local nb = rb.count
	local kf, nf = 0, 0
	if rf then
		kf, nf = first_after(rf, after), rf.count
	end
	local n, reached = 0, after
	while kb < nb or kf < nf do
		if n >= budget then return reached, false, n end
		local ib = kb < nb and at(rb, kb) or nil
		local iff = kf < nf and at(rf, kf) or nil
		local r, i
		if ib and (not iff or rb.seq[ib] < rf.seq[iff]) then
			r, i, kb = rb, ib, kb + 1
		else
			r, i, kf = rf, iff, kf + 1
		end
		n = n + 1
		reached = r.seq[i]
		visit(r, i)
	end
	return reached, true, n
end
model.scan_fwd = scan_fwd

--- First logical row of `r` written at or after `tick` (r.count when none).
--- @param r DiagRing
--- @param tick uint
--- @return int
local function first_at_tick(r, tick)
	local lo, hi = 0, r.count
	local col = r.tick
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if col[at(r, mid)] >= tick then hi = mid else lo = mid + 1 end
	end
	return lo
end
model.first_at_tick = first_at_tick

--- The rings the Log reads: the full ring only while full is on (diag.horizon ignores it otherwise too).
--- @param d DiagState
--- @return DiagRing rb
--- @return DiagRing? rf
local function rings(d)
	return d.ring_basic, d.full and d.ring_full or nil
end
model.rings = rings

--- Which diagnostics state a seq belongs to: a recreated state starts its seqs again from 0.
--- @param d DiagState
--- @return string
local function state_id(d)
	return tostring(d.id)
end
model.state_id = state_id

--- Changes whenever diagnostics were recreated or full was switched: the rows read then change.
--- @param d DiagState
--- @return string
local function epoch(d)
	return state_id(d) .. (d.full and "f" or "b")
end
model.epoch = epoch

-- ---------------------------------------------------------------- rows

--- @class LogGroup one shown row: one event, or adjacent identical events (same kind, severity, code, train, stations,
--- item, and for the kinds whose numbers say what the event is about, those numbers)
--- @field seq uint newest event of the row
--- @field first uint oldest event of the row (the row's key: stable while newer identical events join at the top)
--- @field tick uint newest event's tick
--- @field first_tick uint
--- @field n int events in the row
--- @field kind int
--- @field sev int
--- @field code int
--- @field delivery uint
--- @field train uint
--- @field station uint
--- @field station2 uint
--- @field item int
--- @field a int
--- @field b int
--- @field full true? its events are in the full ring
--- @field pass number? lint rows: the pass they belong to (every lint row of one pass is one row)
--- @field lint int[]? lint rows: {errors, warnings, infos} that appeared, then the findings that cleared
--- @field seqs uint[]? lint rows: the seqs of the pass's rows, newest first (at most PAGE)
--- @field row LogDisplayRow? its row in model.display, kept with it

--- The pass a lint row belongs to: the delivery column of a lint row holds the pass key (DIAG_KIND_SCHEMA `pass`);
--- rows written outside a pass group by their tick.
--- @param r DiagRing
--- @param i int
--- @return number
local function pass_key(r, i)
	local p = r.delivery[i]
	return p ~= 0 and p or -r.tick[i]
end
model.pass_key = pass_key

--- @param r DiagRing
--- @param i int
--- @return LogGroup
local function new_group(r, i)
	local seq, tick = r.seq[i], r.tick[i]
	local kind = r.kind[i]
	local g = {
		seq = seq, first = seq, tick = tick, first_tick = tick, n = 1,
		kind = kind, sev = r.sev[i], code = r.code[i], delivery = r.delivery[i], train = r.train[i],
		station = r.station[i], station2 = r.station2[i], item = r.item[i], a = r.a[i], b = r.b[i],
	}
	if kind == KIND_LINT then
		g.pass = pass_key(r, i)
		local c = { 0, 0, 0, 0 }
		if g.code == DIAG_LINT_CLEARED then c[4] = 1 else c[g.sev] = 1 end
		g.lint = c
		g.seqs = { seq }
	end
	return g
end
model.new_group = new_group

--- Adds a lint row to its pass's row: newer rows move the row's newest seq and tick, older ones its first.
--- @param g LogGroup
--- @param r DiagRing
--- @param i int
--- @param newer boolean
local function pass_add(g, r, i, newer)
	local sev, seq = r.sev[i], r.seq[i]
	local c = g.lint
	if r.code[i] == DIAG_LINT_CLEARED then c[4] = c[4] + 1 else c[sev] = c[sev] + 1 end
	if sev < g.sev then g.sev = sev end
	-- A pass about several stops or trains names none of them.
	if g.station ~= r.station[i] then g.station = 0 end
	if g.train ~= r.train[i] then g.train = 0 end
	g.n = g.n + 1
	local seqs = g.seqs
	if newer then
		g.seq, g.tick = seq, r.tick[i]
		table.insert(seqs, 1, seq)
		if #seqs > model.PAGE then seqs[#seqs] = nil end
	else
		g.first, g.first_tick = seq, r.tick[i]
		if #seqs < model.PAGE then seqs[#seqs + 1] = seq end
	end
end
model.pass_add = pass_add

--- The row of each lint pass among `groups`, by pass key.
--- @param groups LogGroup[]
--- @return {[number]: LogGroup}
local function pass_index(groups)
	local ix = {}
	for _, g in ipairs(groups) do
		if g.pass then ix[g.pass] = g end
	end
	return ix
end

--- Lint rows are not compared: they join their pass's row (pass_add).
--- @param g LogGroup
--- @return boolean
local function identical(g, r, i)
	local kind = g.kind
	if kind == KIND_LINT then return false end
	local schema = SCHEMA[kind]
	return kind == r.kind[i] and g.sev == r.sev[i] and g.code == r.code[i] and g.train == r.train[i]
		and g.station == r.station[i] and g.station2 == r.station2[i] and g.item == r.item[i]
		and (not schema.a_named or g.a == r.a[i]) and (not schema.b_named or g.b == r.b[i])
end
model.identical = identical

--- Collapses adjacent identical events, newest first (plain event rows as diag.events returns them, newest first).
--- @param events table[]
--- @param limit int? rows at most
--- @return LogGroup[]
function model.collapse(events, limit)
	local cols = { seq = {}, tick = {}, kind = {}, sev = {}, code = {}, delivery = {}, train = {}, station = {},
		station2 = {}, item = {}, a = {}, b = {} }
	for i, ev in ipairs(events) do
		for c, col in pairs(cols) do col[i] = ev[c] or 0 end
	end
	local out = {}
	local passes = {}
	for i = 1, #events do
		local last = out[#out]
		local pg = cols.kind[i] == KIND_LINT and passes[pass_key(cols, i)]
		if pg then
			pass_add(pg, cols, i, false)
		elseif last and identical(last, cols, i) then
			last.n = last.n + 1
			last.first, last.first_tick = cols.seq[i], cols.tick[i]
		else
			if limit and #out >= limit then break end
			local g = new_group(cols, i)
			out[#out + 1] = g
			if g.pass then passes[g.pass] = g end
		end
	end
	return out
end

--- @class LogRowsState per player (player_data.tabs.log_tab.rows)
--- @field sig string?
--- @field groups LogGroup[] newest first
--- @field top uint every row up to this seq has been considered at the top
--- @field below uint? the backward scan continues below this seq; nil once complete
--- @field anchor uint? Follow off: rows written after this seq are not shown
--- @field anchor_state string? the diagnostics state the anchor's seq belongs to
--- @field limit int

--- Brings the rows up to date. Follow on: new events join at the top (an identical newest row counts them), rows
--- older than the window drop off the bottom. Follow off: the rows stay as they are until a filter changes, and a
--- rescan then reads only rows up to the anchor (the seq at the moment Follow went off). Held (the pointer is over
--- the rows, or the window is paused): Follow takes in nothing new at the top, so no row moves under the reader;
--- the bottom still fills.
--- @param rs LogRowsState
--- @param d DiagState
--- @param cf LogCompiled
--- @param limit int rows shown
--- @param follow boolean
--- @param budget int rows examined at most, both scans together
--- @param held boolean?
--- @return boolean changed
--- @return int examined
function model.update_rows(rs, d, cf, limit, follow, budget, held)
	local rb, rf = rings(d)
	local head = d.seq
	-- An anchor taken in an earlier diagnostics state is a seq of another numbering.
	if rs.anchor and rs.anchor_state ~= state_id(d) then rs.anchor, rs.top = nil, nil end
	if not follow and not rs.anchor then
		rs.anchor = rs.top or head
		rs.anchor_state = state_id(d)
	end
	if follow then rs.anchor = nil end
	local sig = table.concat({ epoch(d), cf.sig, cf.sev_sig, limit, tostring(rs.anchor) }, "|")
	local changed = false
	if rs.sig ~= sig then
		rs.sig = sig
		rs.groups = {}
		rs.top = rs.anchor or head
		rs.below = rs.top + 1
		rs.limit = limit
		changed = true
	end
	local groups = rs.groups
	local sevs = cf.sevs
	local used = 0
	local passes
	if follow and head > rs.top and not held then
		if head - rs.top > budget then
			-- Too far behind (a long pause): start again from the head.
			rs.sig = nil
			return model.update_rows(rs, d, cf, limit, follow, budget)
		end
		-- New rows are collected oldest first and put on top in one go (a burst after a hold is hundreds of rows).
		local added = 0
		local fresh, in_fresh, moved = {}, {}, nil
		local _, _, n = scan_fwd(rb, rf, rs.top, budget, function(r, i)
			if not (sevs[r.sev[i]] and match(r, i, cf)) then return end
			if cf.min_tick and r.tick[i] < cf.min_tick then return end
			added = added + 1
			local g = fresh[#fresh] or groups[1]
			if r.kind[i] == KIND_LINT then
				passes = passes or pass_index(groups)
				local pg = passes[pass_key(r, i)]
				if pg then
					pass_add(pg, r, i, true)
					-- The pass's row is about its newest finding, so it moves up to the top.
					if pg ~= g then
						if in_fresh[pg] then
							for k = 1, #fresh do
								if fresh[k] == pg then
									table.remove(fresh, k)
									break
								end
							end
						else
							moved = moved or {}
							moved[pg] = true
							in_fresh[pg] = true
						end
						fresh[#fresh + 1] = pg
					end
				else
					pg = new_group(r, i)
					passes[pg.pass] = pg
					fresh[#fresh + 1] = pg
					in_fresh[pg] = true
				end
			elseif g and identical(g, r, i) then
				g.n = g.n + 1
				g.seq, g.tick, g.sev, g.a, g.b, g.delivery = r.seq[i], r.tick[i], r.sev[i], r.a[i], r.b[i], r.delivery[i]
			else
				local ng = new_group(r, i)
				if r == rf then ng.full = true end
				fresh[#fresh + 1] = ng
				in_fresh[ng] = true
			end
		end)
		used = n
		rs.top = head
		if added > 0 then
			changed = true
			if #fresh > 0 then
				local out = {}
				for k = #fresh, 1, -1 do out[#out + 1] = fresh[k] end
				for _, og in ipairs(groups) do
					if not (moved and moved[og]) then out[#out + 1] = og end
				end
				if #out > limit then
					for k = #out, limit + 1, -1 do out[k] = nil end
					rs.below = nil
				end
				rs.groups = out
				groups = out
			end
		end
	end
	if follow and cf.min_tick and not held then
		while #groups > 0 and groups[#groups].tick < cf.min_tick do
			groups[#groups] = nil
			changed = true
		end
	end
	-- Rows whose newest event its ring has since overwritten: the event can no longer be found (a click, Print), so
	-- the row goes, and the backward scan refills from the other ring's older rows.
	if follow and not held then
		local oldest_b = rb.count > 0 and rb.seq[at(rb, 0)] or math.huge
		local oldest_f = rf and rf.count > 0 and rf.seq[at(rf, 0)] or math.huge
		local trimmed = false
		-- A full row can be gone while an older basic row below it is not, so every row is looked at; the bottom row
		-- holds the oldest seq, so nothing is gone while it is not (the usual case, one comparison).
		local last = groups[#groups]
		if last and last.seq < math.max(oldest_b == math.huge and 0 or oldest_b, oldest_f == math.huge and 0 or oldest_f) then
			local kept = {}
			for _, g in ipairs(groups) do
				if g.seq >= (g.full and oldest_f or oldest_b) then kept[#kept + 1] = g else trimmed = true end
			end
			if trimmed then
				for k = 1, #groups do groups[k] = kept[k] end
			end
		end
		if trimmed then
			changed = true
			local last = groups[#groups]
			rs.below = last and last.first or (rs.top + 1)
		end
	end
	if rs.below and used < budget then
		local ended, below, n = scan_back(rb, rf, rs.below, cf, budget - used, function(r, i)
			if not sevs[r.sev[i]] then return false end
			local last = groups[#groups]
			if r.kind[i] == KIND_LINT then
				passes = passes or pass_index(groups)
				local pg = passes[pass_key(r, i)]
				if pg then
					pass_add(pg, r, i, false)
					return false
				end
			end
			if last and identical(last, r, i) then
				last.n = last.n + 1
				last.first, last.first_tick = r.seq[i], r.tick[i]
				return false
			end
			if #groups >= limit then return true end
			local g = new_group(r, i)
			if r == rf then g.full = true end
			groups[#groups + 1] = g
			if g.pass then
				passes = passes or pass_index(groups)
				passes[g.pass] = g
			end
			changed = true
			return false
		end)
		used = used + n
		-- Stopped by a row that does not fit: the last row's count is complete, and nothing more is needed.
		if ended or (below and #groups >= limit) then
			rs.below = nil
		else
			rs.below = below
		end
		changed = true
	end
	-- Paused: the events newer than the anchor that the filter would show ("Paused · n newer"), counted forward with
	-- what is left of the budget.
	if not follow and rs.anchor then
		if rs.newer_sig ~= sig then rs.newer_sig, rs.newer_hi, rs.newer_n = sig, rs.anchor, 0 end
		if head > rs.newer_hi and used < budget then
			local n, min_tick = rs.newer_n, cf.min_tick
			local reached, _, k = scan_fwd(rb, rf, rs.newer_hi, budget - used, function(r, i)
				if sevs[r.sev[i]] and match(r, i, cf) and not (min_tick and r.tick[i] < min_tick) then n = n + 1 end
			end)
			rs.newer_hi, rs.newer_n = reached, n
			used = used + k
		end
	else
		rs.newer_sig, rs.newer_hi, rs.newer_n = nil, nil, nil
	end
	return changed, used
end

--- @class LogDisplayRow
--- @field key number the row element's key: a group's first seq, a pass member's seq + 0.5
--- @field g LogGroup
--- @field child true? a row of an expanded lint pass
--- @field x true? an expanded lint pass's own row

--- The rows on screen: every group, and below each expanded lint pass the pass's own rows, newest first; at most
--- `limit` rows together.
--- @param groups LogGroup[]
--- @param expanded {[number]: true}? pass keys the player opened
--- @param lookup fun(seq: uint): LogGroup? the row of one ring row (nil once its ring dropped it)
--- @param limit int
--- @return LogDisplayRow[]
function model.display(groups, expanded, lookup, limit)
	local out = {}
	for _, g in ipairs(groups) do
		if #out >= limit then break end
		local open = g.pass and g.n > 1 and expanded and expanded[g.pass] or nil
		-- Each group keeps its row, so a render with one new group makes one new row.
		local row = g.row
		if not row then
			row = { g = g }
			g.row = row
		end
		row.key, row.x = g.first, open
		out[#out + 1] = row
		if open then
			for _, seq in ipairs(g.seqs) do
				if #out >= limit then break end
				local c = lookup(seq)
				if c then out[#out + 1] = { key = seq + 0.5, g = c, child = true } end
			end
		end
	end
	return out
end

--- The parts of a lint pass's row caption: "25 errors, 6 warnings, 3 cleared" (zero counts left out).
--- @param c int[] LogGroup.lint
--- @return LocalisedString
function model.pass_counts(c)
	local out = { "" }
	local keys = { "log-lint-errors", "log-lint-warnings", "log-lint-infos", "log-lint-cleared" }
	for k = 1, 4 do
		if c[k] > 0 then
			if #out > 1 then out[#out + 1] = ", " end
			out[#out + 1] = { "cybersyn-gui." .. keys[k], format.number(c[k]), tostring(c[k]) }
		end
	end
	return out
end

--- A severity count's caption. While the count is still building, "+" says the true total may be higher; on a zero
--- it reads as nonsense, so a zero stays plain until the scan finds one.
--- @param n int
--- @param building boolean
--- @param short boolean? five digits and more in short form, as the Overview tiles count
--- @return string
function model.count_text(n, building, short)
	local s = short and utext.count(n) or format.number(n)
	if building and n > 0 then s = s .. "+" end
	return s
end

--- While paused: how many events newer than the frozen rows the filter selects, and whether that count is complete.
--- @param rs LogRowsState
--- @param d DiagState
--- @return int n
--- @return boolean complete
function model.newer(rs, d)
	if not rs.newer_hi then return 0, true end
	return rs.newer_n, rs.newer_hi >= d.seq
end

-- ---------------------------------------------------------------- severity counts

--- @class LogCountsState per player (player_data.tabs.log_tab.counts)
--- @field sig string?
--- @field hi uint every row up to this seq is counted (or was outside the filter)
--- @field build uint? the first count is still scanning backward below this seq
--- @field lo uint[] per ring: rows below this seq are no longer counted
--- @field buckets {[int]: int[]}[] per ring: seq // BUCKET -> {errors, warnings, infos}
--- @field total int[] {errors, warnings, infos}

--- @param cs LogCountsState
--- @param ring int 1 basic, 2 full
local function count_add(cs, ring, seq, sev)
	local b = math.floor(seq / model.BUCKET)
	local by = cs.buckets[ring]
	local c = by[b]
	if not c then
		c = { 0, 0, 0 }
		by[b] = c
	end
	c[sev] = c[sev] + 1
	cs.total[sev] = cs.total[sev] + 1
end

--- Rows before the window or gone from the ring stop counting: whole buckets below the boundary go, and the bucket
--- the boundary falls in is counted again from the rows still there.
--- @param cs LogCountsState
--- @param ring int
--- @param r DiagRing
--- @param cf LogCompiled
local function count_trim(cs, ring, r, cf)
	local low
	if r.count == 0 then
		low = cs.hi + 1
	else
		local k = cf.min_tick and first_at_tick(r, cf.min_tick) or 0
		low = k < r.count and r.seq[at(r, k)] or cs.hi + 1
	end
	if cs.lo[ring] == low then return end
	cs.lo[ring] = low
	local B = model.BUCKET
	local lb = math.floor(low / B)
	local by, total = cs.buckets[ring], cs.total
	for b, c in pairs(by) do
		if b <= lb then
			total[1], total[2], total[3] = total[1] - c[1], total[2] - c[2], total[3] - c[3]
			by[b] = nil
		end
	end
	local last = math.min(cs.hi, (lb + 1) * B - 1)
	local k = first_after(r, low - 1)
	local n = r.count
	while k < n do
		local i = at(r, k)
		local seq = r.seq[i]
		if seq > last then break end
		if match(r, i, cf) then count_add(cs, ring, seq, r.sev[i]) end
		k = k + 1
	end
end

--- Errors, warnings and infos in the window under every filter but the severities.
--- @param cs LogCountsState
--- @param d DiagState
--- @param cf LogCompiled
--- @param budget int rows examined at most, catching up and building together
--- @return boolean building the count is not complete yet (the totals are a lower bound)
--- @return int examined
function model.update_counts(cs, d, cf, budget)
	local rb, rf = rings(d)
	local sig = epoch(d) .. "|" .. cf.sig
	-- Far behind the head (the Log was not shown for a while): a fresh chunked count instead of one long catch-up.
	if cs.sig == sig and d.seq - cs.hi > model.COUNTS_BEHIND then cs.sig = nil end
	if cs.sig ~= sig then
		cs.sig = sig
		cs.hi = d.seq
		cs.build = d.seq + 1
		cs.lo = { -1, -1 }
		cs.buckets = { {}, {} }
		cs.total = { 0, 0, 0 }
	end
	local min_tick = cf.min_tick
	local used = 0
	if d.seq > cs.hi then
		local reached, ended, n = scan_fwd(rb, rf, cs.hi, budget, function(r, i)
			if (not min_tick or r.tick[i] >= min_tick) and match(r, i, cf) then
				count_add(cs, r == rb and 1 or 2, r.seq[i], r.sev[i])
			end
		end)
		used = n
		cs.hi = ended and d.seq or reached
		if not ended then return true, used end
	end
	if cs.build then
		if used >= budget then return true, used end
		local ended, below, n = scan_back(rb, rf, cs.build, cf, budget - used, function(r, i)
			count_add(cs, r == rb and 1 or 2, r.seq[i], r.sev[i])
			return false
		end)
		used = used + n
		cs.build = (not ended) and below or nil
		if cs.build then return true, used end
	end
	count_trim(cs, 1, rb, cf)
	if rf then count_trim(cs, 2, rf, cf) end
	return false, used
end

-- ---------------------------------------------------------------- unread errors (the tab's badge)

--- @class LogBadgeState per player (player_data.tabs.log_tab.badge)
--- @field epoch string?
--- @field hi uint every row up to this seq is counted
--- @field n int unread errors
--- @field seen uint? the seen seq the count started from
--- @field since uint? the since_tick the count was made with; a change recounts

--- The seq a player has seen the Log up to, in this diagnostics state (0 when it was seen in another one).
--- @param seen {state: string, seq: uint}?
--- @param d DiagState
--- @return uint
function model.seen_seq(seen, d)
	if seen and seen.state == state_id(d) then return seen.seq end
	return 0
end

--- Counts error rows newer than `seen` (the newest seq the player had on screen in the Log), at most `budget` new rows
--- per call. Rows written before `since_tick` do not count: the first planner cycles after diagnostics start record
--- every request that was already failing, which is the state of the base, not news.
--- @param bs LogBadgeState
--- @param d DiagState
--- @param seen uint? a seq of this diagnostics state (model.seen_seq)
--- @param budget int
--- @param since_tick uint? diag.inherit_threshold(d); nil = every row
--- @return int unread
function model.update_badge(bs, d, seen, budget, since_tick)
	local e = epoch(d)
	since_tick = since_tick or 0
	if bs.epoch ~= e then
		bs.epoch, bs.hi, bs.n, bs.seen = e, 0, 0, nil
	end
	seen = seen or 0
	if seen > d.seq then seen = 0 end
	if seen ~= bs.seen or since_tick ~= bs.since then
		bs.seen, bs.hi, bs.n, bs.since = seen, seen, 0, since_tick
	end
	local rb, rf = rings(d)
	if d.seq > bs.hi then
		local n = bs.n
		bs.hi = scan_fwd(rb, rf, bs.hi, budget, function(r, i)
			if r.sev[i] == DIAG_SEV_ERROR and r.tick[i] >= since_tick then n = n + 1 end
		end)
		bs.n = n
	end
	return bs.n
end

--- The tab's badge: unread errors, "99+" beyond 99 (the tooltip has the number).
--- @param n int
--- @return string
function model.badge_caption(n)
	if n <= 0 then return "" end
	if n > 99 then return "99+" end
	return tostring(n)
end

-- ---------------------------------------------------------------- summary

--- @class LogSummaryState per player while Summary is on (player_data.tabs.log_tab.summary)
--- @field sig string?
--- @field below uint? the scan continues below this seq; nil once done
--- @field as_of uint seq the summary counts up to
--- @field as_of_tick uint
--- @field stations {[uint]: int[]}? while scanning: id -> {events, worst severity}
--- @field items {[int]: int[]}?
--- @field scanned int rows in the summary
--- @field top_stations {id: uint, n: int, sev: int}[]? once done
--- @field top_items {item: int, n: int, sev: int}[]?

--- @return boolean a ranks before b: more events, then the worse severity, then the lower id
local function ranks_before(n1, s1, k1, n2, s2, k2)
	if n1 ~= n2 then return n1 > n2 end
	if s1 ~= s2 then return s1 < s2 end
	return k1 < k2
end

--- The SUMMARY_TOP entries by rank, by insertion into a short sorted list (a base has thousands of stations; only the
--- top few are ever shown).
--- @param map {[number]: int[]}
--- @param key_name string
--- @return table[]
local function top(map, key_name)
	local list, size = {}, model.SUMMARY_TOP
	for id, c in pairs(map) do
		local n, sev = c[1], c[2]
		local len = #list
		local last = list[len]
		if len < size or ranks_before(n, sev, id, last.n, last.sev, last[key_name]) then
			local pos = len + 1
			while pos > 1 do
				local p = list[pos - 1]
				if not ranks_before(n, sev, id, p.n, p.sev, p[key_name]) then break end
				pos = pos - 1
			end
			table.insert(list, pos, { [key_name] = id, n = n, sev = sev })
			if #list > size then list[#list] = nil end
		end
	end
	return list
end
model.top = top

--- The top stations (station column) and items by event count in the window, under every filter including the
--- severities, each with its worst severity. Computed once per toggle or filter change by a backward scan of at most
--- `budget` rows per call; it does not follow newer rows.
--- @param ss LogSummaryState
--- @param d DiagState
--- @param cf LogCompiled
--- @param budget int
--- @return boolean done
--- @return int examined
function model.update_summary(ss, d, cf, budget)
	local rb, rf = rings(d)
	local sig = epoch(d) .. "|" .. cf.sig .. "|" .. cf.sev_sig
	if ss.sig ~= sig then
		ss.sig = sig
		ss.below = d.seq + 1
		ss.as_of = d.seq
		ss.as_of_tick = game.tick
		ss.stations, ss.items = {}, {}
		ss.top_stations, ss.top_items = nil, nil
		ss.scanned = 0
	end
	if not ss.below then return true, 0 end
	local stations, items, sevs = ss.stations, ss.items, cf.sevs
	local scanned = ss.scanned
	local ended, below, used = scan_back(rb, rf, ss.below, cf, budget, function(r, i)
		local sev = r.sev[i]
		if not sevs[sev] then return false end
		scanned = scanned + 1
		local st = r.station[i]
		if st ~= 0 then
			local c = stations[st]
			if c then
				c[1] = c[1] + 1
				if sev < c[2] then c[2] = sev end
			else
				stations[st] = { 1, sev }
			end
		end
		local item = r.item[i]
		if item ~= 0 then
			local c = items[item]
			if c then
				c[1] = c[1] + 1
				if sev < c[2] then c[2] = sev end
			else
				items[item] = { 1, sev }
			end
		end
		return false
	end)
	ss.scanned = scanned
	if ended then
		ss.below = nil
		ss.top_stations = top(stations, "id")
		ss.top_items = top(items, "item")
		ss.stations, ss.items = nil, nil
		return true, used
	end
	ss.below = below
	return false, used
end

-- ---------------------------------------------------------------- text

--- "Exported 1,234 rows" style counts and the "×n" of a collapsed row.
--- @param n int
--- @return string
function model.repeat_caption(n)
	if n <= 1 then return "" end
	-- The count column is narrow; the age tooltip of a collapsed row gives the exact number.
	return "×" .. utext.count(n)
end

--- The age column: two units at most.
--- @param now uint
--- @param g LogGroup
--- @return string
function model.age_caption(now, g)
	return logic.short_duration(now - g.tick)
end

--- The age column's tooltip: the absolute tick and the game time it was written at (a range for a collapsed row).
--- @param g LogGroup
--- @return LocalisedString
function model.age_tooltip(g)
	local long = logic.format_duration
	if g.n > 1 then
		return { "cybersyn-gui.log-age-range-tooltip", tostring(g.first_tick), tostring(g.tick), long(g.first_tick),
			long(g.tick), format.number(g.n) }
	end
	return { "cybersyn-gui.log-age-tooltip", tostring(g.tick), long(g.tick) }
end

local STATE_NAMES = DIAG_TRAIN_STATE_NAMES

--- @class LogTextContext name lookups the message needs; all pure reads
--- @field station fun(id: uint): string? a station's (or depot's) name
--- @field player fun(index: uint): string?
--- @field stock fun(reason: int, a: int, b: int): LocalisedString unserved-text stock caption
--- @field chip fun(reason: int): LocalisedString unserved-text chip caption

local ACK_END = { "expired", "reason-changed", "resolved", "manual" }

--- @param n number
--- @return string
local function amount(n)
	return format_signal_count(n or 0)
end

--- The message column: what happened, with the row's numbers; the severity dot carries the colour.
--- A lint pass of several rows reads "Lint: 25 errors, 6 warnings ▸" (▾ while expanded).
--- @param g LogGroup
--- @param ctx LogTextContext
--- @param expanded boolean?
--- @return LocalisedString
function model.message(g, ctx, expanded)
	local kind, code, a, b = g.kind, g.code, g.a, g.b
	local key = DIAG_KIND_KEYS[kind]
	if not key then return tostring(kind) end
	if g.pass and g.n > 1 then
		return { "cybersyn-gui.log-lint-pass", model.pass_counts(g.lint), expanded and "▾" or "▸" }
	end
	local msg = "cybersyn-diag.msg-" .. key
	if kind == DIAG_KIND_UNSERVED_REASON then
		local stock = ctx.stock(code, a, b)
		if stock == "–" then return { msg .. "-plain", ctx.chip(code) } end
		return { msg, ctx.chip(code), stock }
	elseif kind == DIAG_KIND_SERVED then
		-- The plural takes the plain number: a grouped one ("8,646") is not a number to the locale engine.
		return { msg, logic.format_duration(a), format.number(b), ctx.chip(code), tostring(b) }
	elseif kind == DIAG_KIND_FLAPPING then
		return { msg, format.number(b), ctx.chip(code) }
	elseif kind == DIAG_KIND_DISPATCH_FAILED then
		local name = DIAG_DISPATCH_NAMES[code]
		return { msg, name and { "cybersyn-diag.dispatch-" .. string.gsub(name, "_", "-") } or tostring(code) }
	elseif kind == DIAG_KIND_DELIVERY_FAILED then
		local name = DIAG_FAIL_NAMES[code]
		local cause = name and { "cybersyn-diag.fail-" .. string.gsub(name, "_", "-") } or tostring(code)
		if a == 1 then return { msg .. "-at-p", cause } end
		if b == 1 then return { msg .. "-at-r", cause } end
		return { msg, cause }
	elseif kind == DIAG_KIND_ALERT then
		local name = DIAG_ALERT_NAMES[code]
		return { msg, name and { "cybersyn-diag.alert-" .. string.gsub(name, "_", "-") } or tostring(code) }
	elseif kind == DIAG_KIND_STATION_POWER then
		return { msg .. (a == 1 and "-on" or "-off") }
	elseif kind == DIAG_KIND_STATION_LIMIT or kind == DIAG_KIND_STATION_DISABLED then
		return { msg, tostring(a), tostring(b) }
	elseif kind == DIAG_KIND_SHORT_LOAD or kind == DIAG_KIND_RESIDUAL_CARGO then
		return { msg, amount(b), amount(a) }
	elseif kind == DIAG_KIND_UNEXPECTED_CARGO then
		return { msg, amount(b) }
	elseif kind == DIAG_KIND_SCHEDULE_EDITED then
		local who = ctx.player(a) or tostring(a)
		if b > 1 then return { msg .. "-group", who, format.number(b) } end
		return { msg, who }
	elseif kind == DIAG_KIND_LINT then
		local check = LINT_KEYS[a]
		local caption = check and { "cybersyn-diag.lint-" .. check } or tostring(a)
		return { msg .. (code == DIAG_LINT_CLEARED and "-cleared" or "-appeared"), caption }
	elseif kind == DIAG_KIND_ACKNOWLEDGED then
		local what = { "cybersyn-diag.ack-kind-" .. (DIAG_ACK_KINDS[code] or "request") }
		local who = ctx.player(g.station2) or "-"
		if a == 0 then return { msg .. "-reason", what, who } end
		return { msg, what, who, logic.format_duration(a - g.tick) }
	elseif kind == DIAG_KIND_UNACKNOWLEDGED then
		local what = { "cybersyn-diag.ack-kind-" .. (DIAG_ACK_KINDS[code] or "request") }
		local cause = ACK_END[b] or "expired"
		if b == DIAG_ACK_END_MANUAL then
			return { msg .. "-manual", what, ctx.player(g.station2) or "-" }
		end
		return { msg, what, { "cybersyn-diag.ack-end-" .. cause } }
	elseif kind == DIAG_KIND_MANUAL_ACTION then
		local name = ACTION_NAMES[a]
		local action = name and { "cybersyn-diag.action-" .. string.gsub(name, "_", "-") } or tostring(a)
		local who = g.station2 == 0 and { "cybersyn-diag.log-server" } or (ctx.player(g.station2) or tostring(g.station2))
		return { msg, action, who }
	elseif kind == DIAG_KIND_DISPATCHED then
		return { msg, amount(b), format.number(a) }
	elseif kind == DIAG_KIND_ARRIVE_P or kind == DIAG_KIND_LEAVE_P or kind == DIAG_KIND_ARRIVE_R then
		return { msg, amount(a) }
	elseif kind == DIAG_KIND_SLOW_DELIVERY then
		return { msg, logic.format_duration(a), b > 0 and string.format("%.1f", a / b) or "–", logic.format_duration(b) }
	elseif kind == DIAG_KIND_TRAIN_STATE then
		if code == defines.train_state.wait_signal then
			return { msg .. "-wait-signal", logic.format_duration(a) }
		end
		local state = STATE_NAMES[code]
		return { msg, state and logic.state_chip(state).caption or tostring(code) }
	end
	return { msg }
end

--- The message cell's why/fix tooltip of a dispatch_failed row; nil for any other row.
--- @param g LogGroup
--- @return LocalisedString?
function model.dispatch_tooltip(g)
	if g.kind ~= DIAG_KIND_DISPATCH_FAILED then return nil end
	local name = DIAG_DISPATCH_NAMES[g.code]
	if not name then return nil end
	local key = string.gsub(name, "_", "-")
	local state_name = (g.a or 0) > 0 and STATE_NAMES[g.a - DIAG_STATE_OFFSET]
	local state = state_name and logic.state_chip(state_name).caption or { "cybersyn-diag.dispatch-state-unknown" }
	local train = (g.train or 0) ~= 0 and tostring(g.train) or "–"
	return { "", { "cybersyn-gui.unserved-why", { "cybersyn-diag.dispatch-why-" .. key, train, state } }, "\n",
		{ "cybersyn-gui.unserved-fix", { "cybersyn-diag.dispatch-fix-" .. key } } }
end

--- Chat tags for a row: a train by its front stock's unit number, a stop by its unit number, a map
--- position; the engine makes each clickable in chat.
--- @param train_unit uint? front_stock.unit_number
--- @param stop_unit uint? the stop's unit number
--- @param gps {x: number, y: number, surface: string}?
--- @param item string? item hash
--- @return string
function model.chat_tags(train_unit, stop_unit, gps, item)
	local parts = {}
	if train_unit then parts[#parts + 1] = "[train=" .. train_unit .. "]" end
	if stop_unit then parts[#parts + 1] = "[train-stop=" .. stop_unit .. "]" end
	if item then parts[#parts + 1] = rich_text.of_hash(item) end
	if gps then
		parts[#parts + 1] = string.format("[gps=%d,%d,%s]", math.floor(gps.x), math.floor(gps.y), gps.surface)
	end
	return table.concat(parts, " ")
end

return model
