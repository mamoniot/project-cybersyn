-- Dispatcher diagnostics: why each request is not served, and a log of what happened.
--
-- Failures are keyed state, not events: tick_dispatch re-evaluates every failing (requester, item) key about once per
-- planner cycle (135 live keys and ~190 failing evaluations per second measured on a 2,030-station base), so each
-- evaluation overwrites its entry in place and only a debounced change of reason reaches the log. The log is two
-- column rings sharing one sequence number: the basic ring holds the rare events (reason changes, failures, alerts,
-- station changes) and the full ring the routine ones (dispatch, arrival, departure), so turning `full` on can never
-- push basic history out. All of it lives in storage.diag, which is nil while the setting is off; every hook checks
-- that one value first, and the planner reads it once per call outside its loops.

local stats = require("scripts.stats")

local diag = {}

local BASIC_RING = 4096
local UNSERVED_CAP = 4096
-- Flap rule: a new reason is confirmed after this many consecutive evaluations and this many ticks.
local FLAP_EVALS = 2
local FLAP_TICKS = 1800
-- More than four confirmed changes inside the window is flapping; the key then stays quiet until stable that long.
local FLAP_CHANGES = 5
local FLAP_WINDOW = 36000
-- wait_signal flaps against on_the_path in normal traffic; only a wait this long is worth a log row.
local WAIT_SIGNAL_MIN = 600
-- The dispatcher re-sends its merged no-train alerts every planner cycle, its other requester alerts on every failing
-- evaluation and the stuck-train alert on every visit. The log keeps one row per entity and alert per this long, so a
-- row says the alert was being sent from then on, not that it had just appeared: one that clears and comes back
-- within the window writes no new row.
local ALERT_REPEAT = 36000
-- The unserved sweep runs on every SWEEP_EVERY-th planner cycle: an entry then lives up to that many cycles longer,
-- and the walk over every entry (about 60 µs per cycle on a 2,030-station base) costs that much less per tick.
local SWEEP_EVERY = 4
-- A key whose item was dispatched to another requester since the cutoff was not evaluated (the call ended in that
-- dispatch), so the sweep keeps it, for at most this long since its last evaluation.
local SWEEP_SPARE = 36000
-- A player editing a schedule changes it several times in a row; one log row per train per this long.
local EDIT_REPEAT = 600
local ACK_CAP = 1024
-- Rows a filtered diag.events call examines before it returns with the seq it reached.
local EVENTS_SCAN = 4096

diag.BASIC_RING = BASIC_RING
-- Rows of the full ring: at the roughly 18 rows per second a large base writes in full mode, about 15 minutes, for
-- about 11 MB of heap. A field rather than a local so the tests can shrink it.
diag.FULL_RING = 16384
diag.UNSERVED_CAP = UNSERVED_CAP
diag.FLAP_TICKS = FLAP_TICKS
diag.FLAP_WINDOW = FLAP_WINDOW
diag.ACK_CAP = ACK_CAP
diag.EVENTS_SCAN = EVENTS_SCAN
diag.WAIT_SIGNAL_MIN = WAIT_SIGNAL_MIN
diag.SWEEP_EVERY = SWEEP_EVERY
diag.SWEEP_SPARE = SWEEP_SPARE
diag.EDIT_REPEAT = EDIT_REPEAT

-- What station2, delivery, code, a and b hold depends on the kind: DIAG_KIND_SCHEMA.
local COLUMNS = { "seq", "tick", "kind", "sev", "code", "delivery", "train", "station", "station2", "item", "a", "b" }
diag.COLUMNS = COLUMNS
local SCHEMA = DIAG_KIND_SCHEMA

local NO_TRAIN_REASONS = {
	[REASON_NO_TRAINS_ON_NETWORK] = true,
	[REASON_TRAIN_FILTERED] = true,
	[REASON_CAPACITY] = true,
}

local ALERT_SEVERITY = {
	[DIAG_ALERT_STUCK] = DIAG_SEV_ERROR,
	[DIAG_ALERT_DEPOT_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_STATION_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_REFUELER_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES] = DIAG_SEV_ERROR,
	[DIAG_ALERT_GROUP_SCHEDULE_BROKEN] = DIAG_SEV_ERROR,
	[DIAG_ALERT_SCHEDULE_BROKEN] = DIAG_SEV_ERROR,
}

--- Scratch counters of the evaluation tick_dispatch is running (indices REJ_*). Not game state: the planner zeroes
--- it before each evaluation and diag.fail copies it into the entry, so every Lua state computes the same thing.
--- @type int[]
diag.rej = { 0, 0, 0, 0, 0, 0, 0, 0 }

--- @class DiagRing parallel integer columns (see COLUMNS); row `head` is the newest, `count` rows are live
--- A row is not changed once written, except the train count of a group's schedule edit (diag.schedule_edited); a
--- reader that copied the row earlier keeps the older count.
--- @field size int
--- @field head int
--- @field count int
--- @field filled true? the columns are preallocated to `size`
--- @field seq uint[]
--- @field tick uint[]
--- @field kind int[]
--- @field sev int[]
--- @field code int[]
--- @field delivery int[]
--- @field train int[]
--- @field station int[]
--- @field station2 int[]
--- @field item int[]
--- @field a int[]
--- @field b int[]

--- @class DiagEntry one failing (requester, item) key
--- @field reason DiagReason confirmed
--- @field pending DiagReason? a different reason seen since pending_since, not yet confirmed
--- @field pending_since uint?
--- @field pending_n int consecutive evaluations that returned `pending`
--- @field first_tick uint first failing evaluation
--- @field last_tick uint latest failing evaluation
--- @field n int failing evaluations
--- @field a int payload of the confirmed reason's latest evaluation
--- @field b int
--- @field p_station_id uint? best provider of the latest evaluation
--- @field p_count int? its stock (P_BELOW_THRESHOLD and priority losses)
--- @field p_threshold int? the threshold it was held against
--- @field rej int[] REJ_* counts of the latest evaluation of the confirmed reason
--- @field lost_n int evaluations that found the providers locked by an earlier requester of the same call
--- @field lost_to uint? that requester, at the latest loss
--- @field changes uint[] ticks of the last confirmed changes (at most FLAP_CHANGES)
--- @field change_reasons DiagReason[] the reason each of those changes confirmed
--- @field suppressed_until uint? flapping: no transition events before this tick

--- @class DiagState
--- @field mode string "basic"|"full"
--- @field full boolean
--- @field seq uint last sequence number handed out (both rings)
--- @field ring_basic DiagRing
--- @field ring_full DiagRing
--- @field unserved {[uint]: {[int]: DiagEntry}} requester unit number -> item index -> entry
--- @field unserved_count {[uint]: int}
--- @field unserved_n int
--- @field unserved_dropped int new keys refused because unserved_n was at UNSERVED_CAP
--- @field counts {[int]: int} live entries per confirmed reason
--- @field item_ix {[string]: int} item hash -> index
--- @field item_hash string[] index -> item hash
--- @field cycle_start int tick of the latest planner cycle start (tick_init)
--- @field cycle_prev int?
--- @field cycle_prev2 int?
--- @field unpowered {[uint]: true} stations whose combinator was not working at their last poll
--- @field alert_last {[int]: uint} (stop unit number, or -train id) * 32 + alert code -> tick it was last logged
--- @field alert_sweep uint? next tick alert_last is pruned
--- @field cycles int planner cycles started since this state was created (the unserved sweep runs every SWEEP_EVERY)
--- @field item_served {[int]: uint} item index -> tick create_delivery last served a requester of it
--- @field next_delivery uint
--- @field id int which state this is (seqs restart in a new one)
--- @field inherit_cycles int? planner cycle starts seen since creation, while the inherited window is open
--- @field inherit_until uint? start of the second planner cycle after creation; see diag.inherit_threshold
--- @field edit_rows table? open group schedule-edit rows by "player|group"; see diag.schedule_edited
--- @field export_name_tick uint? tick of the latest diag.export, so two exports in one tick get distinct names
--- @field export_name_n int? exports in that tick

-- ---------------------------------------------------------------- state

--- Columns are filled to their size up front: a column grown by appending is reallocated at every power of two, and
--- those copies landed in the dispatcher's ticks.
--- @param col table
--- @param from int
--- @param to int
local function prefill(col, from, to)
	for k = from, to do col[k] = 0 end
end

--- @param size int
--- @param filled boolean? preallocate the columns now (the full ring waits until full mode is on)
--- @return DiagRing
local function new_ring(size, filled)
	--- @type table<string, any> the columns are added below, so this is not a DiagRing until the loop ends
	local r = { size = size, head = 0, count = 0, filled = filled or nil }
	for _, c in ipairs(COLUMNS) do
		local col = {}
		if filled then prefill(col, 1, size) end
		r[c] = col
	end
	return r
end

--- @param r DiagRing
local function fill_ring(r)
	if r.filled then return end
	for _, c in ipairs(COLUMNS) do
		local col = r[c]
		prefill(col, #col + 1, r.size)
	end
	r.filled = true
end

--- @return string "off"|"basic"|"full"
local function mode_setting()
	return mod_settings.diagnostics or "basic"
end

--- @return DiagState
local function new_state()
	storage.diag_serial = (storage.diag_serial or 0) + 1
	return {
		id = storage.diag_serial,
		mode = "basic",
		full = false,
		seq = 0,
		ring_basic = new_ring(BASIC_RING, true),
		ring_full = new_ring(diag.FULL_RING, false),
		unserved = {},
		unserved_count = {},
		unserved_n = 0,
		unserved_dropped = 0,
		counts = {},
		item_ix = {},
		item_hash = {},
		cycle_start = -1,
		unpowered = {},
		alert_last = {},
		cycles = 0,
		item_served = {},
		next_delivery = 0,
		inherit_cycles = 0,
	}
end

--- Keeps the newest min(count, size) rows, oldest first from index 1.
--- @param r DiagRing
--- @param size int
function diag.resize_ring(r, size)
	if r.size == size then return end
	local keep = math.min(r.count, size)
	local old_size, head = r.size, r.head
	for _, c in ipairs(COLUMNS) do
		local col, out = r[c], {}
		for k = 1, keep do
			out[k] = col[(head - keep + k - 1) % old_size + 1]
		end
		if r.filled then prefill(out, keep + 1, size) end
		r[c] = out
	end
	r.size = size
	r.count = keep
	r.head = keep
end

--- Trains dispatched while the full log was off still carry an older log's delivery id.
local function clear_delivery_ids()
	for _, train in pairs(storage.trains or {}) do
		train.delivery_id = nil
	end
end

--- Brings storage.diag in line with the settings: nil when off, created when missing, the full ring resized.
--- @return DiagState?
function diag.apply()
	local mode = mode_setting()
	if mode == "off" then
		storage.diag = nil
		return nil
	end
	local d = storage.diag
	if not d then
		d = new_state()
		storage.diag = d
		clear_delivery_ids()
	end
	-- Rows of a full session would otherwise stay in every reader that does not check the mode (events, export, the
	-- Log), next to basic rows that kept coming.
	if mode ~= "full" and d.ring_full.count > 0 then d.ring_full = new_ring(diag.FULL_RING, false) end
	d.mode = mode
	d.full = mode == "full"
	diag.resize_ring(d.ring_full, diag.FULL_RING)
	fill_ring(d.ring_basic)
	if d.full then fill_ring(d.ring_full) end
	return d
end

--- @param d DiagState
--- @param hash string
--- @return int
local function intern(d, hash)
	local ix = d.item_ix[hash]
	if ix then return ix end
	ix = #d.item_hash + 1
	d.item_hash[ix] = hash
	d.item_ix[hash] = ix
	return ix
end
diag.intern = intern

--- @param ix int?
--- @return string?
function diag.item_hash(ix)
	local d = storage.diag
	return d and ix and d.item_hash[ix] or nil
end

-- ---------------------------------------------------------------- rings

--- @param d DiagState
--- @param r DiagRing
--- @return uint seq
local function push(d, r, kind, sev, code, delivery, train, station, station2, item, a, b)
	local h = r.head % r.size + 1
	r.head = h
	if r.count < r.size then r.count = r.count + 1 end
	local seq = d.seq + 1
	d.seq = seq
	r.seq[h] = seq
	r.tick[h] = game.tick
	r.kind[h] = kind
	r.sev[h] = sev
	r.code[h] = code or 0
	r.delivery[h] = delivery or 0
	r.train[h] = train or 0
	r.station[h] = station or 0
	r.station2[h] = station2 or 0
	r.item[h] = item or 0
	r.a[h] = a or 0
	r.b[h] = b or 0
	return seq
end

--- Writes one event to the ring its kind belongs to; full-only kinds are dropped unless the mode is full.
--- @param d DiagState
--- @param kind DiagKind
--- @param sev DiagSev
--- @return uint? seq
function diag.event(d, kind, sev, code, delivery, train, station, station2, item, a, b)
	if SCHEMA[kind].full then
		if not d.full then return nil end
		return push(d, d.ring_full, kind, sev, code, delivery, train, station, station2, item, a, b)
	end
	return push(d, d.ring_basic, kind, sev, code, delivery, train, station, station2, item, a, b)
end

--- Ring index of logical row k (0 = oldest).
local function at(r, k)
	return (r.head - r.count + k) % r.size + 1
end

--- First logical row whose seq is above `seq` (count when none).
local function first_after(r, seq)
	local lo, hi = 0, r.count
	local col = r.seq
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if col[at(r, mid)] > seq then hi = mid else lo = mid + 1 end
	end
	return lo
end

diag.ring_at = at
diag.first_after = first_after

--- One step of the walk over both rings merged by seq: of the rows at logical index kb of `rb` and kf of `rf`, the
--- one that comes first in direction `dir` (1 = oldest first, -1 = newest first), and kb, kf advanced past it; nil
--- once both rings are walked out.
--- @param dir 1|-1
--- @return DiagRing? r
--- @return int? i ring index of the row
--- @return int kb
--- @return int kf
local function step(rb, rf, kb, kf, dir)
	local ib = kb >= 0 and kb < rb.count and at(rb, kb) or nil
	local iff = kf >= 0 and kf < rf.count and at(rf, kf) or nil
	if ib and (not iff or (rb.seq[ib] < rf.seq[iff]) == (dir > 0)) then return rb, ib, kb + dir, kf end
	if iff then return rf, iff, kb, kf + dir end
	return nil, nil, kb, kf
end

--- @class DiagEventFilter
--- @field kind DiagKind?
--- @field kinds {[int]: true}? any of these kinds (with `alerts`: or an alert row whose code is in `alerts`)
--- @field alerts {[int]: true}? DIAG_ALERT_* codes an alert row may have when `kinds` does not name the alert kind
--- @field sev DiagSev? at most this severity (1 = errors only)
--- @field sevs {[int]: true}? exactly these DIAG_SEV_*
--- @field station uint? subject station: the station column, or station2 where that column names a station
--- @field train uint?
--- @field delivery uint?
--- @field item int? item index
--- @field min_tick uint? ignore rows written before this tick
--- @field max_seq uint? ignore rows written after this

--- @return boolean
local function matches(r, i, f)
	if not f then return true end
	if f.max_seq and r.seq[i] > f.max_seq then return false end
	if f.min_tick and r.tick[i] < f.min_tick then return false end
	local kind = r.kind[i]
	if f.kind and kind ~= f.kind then return false end
	local kinds = f.kinds
	if kinds and not kinds[kind] then
		local alerts = f.alerts
		if not (alerts and kind == DIAG_KIND_ALERT and alerts[r.code[i]]) then return false end
	end
	local sev = r.sev[i]
	if f.sev and sev > f.sev then return false end
	if f.sevs and not f.sevs[sev] then return false end
	if f.train and r.train[i] ~= f.train then return false end
	if f.delivery and (r.delivery[i] ~= f.delivery or SCHEMA[kind].pass) then return false end
	if f.item and r.item[i] ~= f.item then return false end
	local st = f.station
	if st and r.station[i] ~= st and not (r.station2[i] == st and SCHEMA[kind].station2 == "station") then
		return false
	end
	return true
end
diag.matches = matches

--- @return table row with every column
local function row(r, i)
	local out = {}
	for _, c in ipairs(COLUMNS) do out[c] = r[c][i] end
	return out
end

--- Events with seq above `from_seq`, oldest first, merged from both rings; with from_seq nil, the newest `limit`
--- (still oldest first). A filter may match few rows, so at most `max_scan` rows (EVENTS_SCAN by default when there is
--- a filter) are examined;
--- the second result is the seq the scan reached, from which a later call continues (forward: pass it as from_seq;
--- backward: rows below it are still to be examined), nil when the scan reached the end.
--- @param filter DiagEventFilter?
--- @param from_seq uint?
--- @param limit int?
--- @param max_scan int? rows examined at most; math.huge for an unbounded scan
--- @return table[] rows
--- @return uint? reached
function diag.events(filter, from_seq, limit, max_scan)
	local d = storage.diag
	local out = {}
	if not d then return out, nil end
	limit = limit or 1000
	max_scan = max_scan or (filter and EVENTS_SCAN or math.huge)
	local rb, rf = d.ring_basic, d.ring_full
	local backward = from_seq == nil
	local dir = backward and -1 or 1
	local kb, kf
	if backward then
		kb, kf = rb.count - 1, rf.count - 1
	else
		kb, kf = first_after(rb, from_seq), first_after(rf, from_seq)
	end
	local max_seq = not backward and filter and filter.max_seq
	local scanned, reached, ended = 0, nil, false
	while #out < limit and scanned < max_scan do
		local r, i
		r, i, kb, kf = step(rb, rf, kb, kf, dir)
		if not r or (max_seq and r.seq[i] > max_seq) then
			ended = true
			break
		end
		scanned = scanned + 1
		reached = r.seq[i]
		if matches(r, i, filter) then out[#out + 1] = row(r, i) end
	end
	if backward then
		local n = #out
		for k = 1, math.floor(n / 2) do
			out[k], out[n - k + 1] = out[n - k + 1], out[k]
		end
	end
	return out, not ended and step(rb, rf, kb, kf, dir) and reached or nil
end

-- Rows one diag.last_for_step call examines at most. A rare entity's last rows can sit 70,000 rows back in a full
-- ring, which a panel refreshed every update cannot scan in one go. Measured on a 2,000-station base with both rings full: about
-- 0.31 µs per row inside the real tick, so a 4,096-row call is about 1.3 ms; panels pass a smaller budget after their
-- first.
diag.SCAN_ROWS = 4096

--- Walks both rings backwards over the rows with stop_seq < seq < below, newest first, appending the rows that match
--- `f` (one subject: {station|train|delivery = id}) to `out` until it holds `n`, or `budget` rows were examined. The
--- merge of `step` written out, with the columns read straight from the ring arrays: through ring_at and diag.matches
--- a row cost about 1 µs inside the real tick on full rings, which kept the stop panel over its 0.2 ms refresh budget,
--- and through `step` alone it still costs 3.6 times the inlined walk (host Lua, 20,000 rows).
--- @return int examined
--- @return uint oldest seq of the oldest row examined (`below` when none)
--- @return boolean exhausted no unexamined row is left in the range
local function scan_back(d, f, below, stop_seq, budget, out, n)
	local key, id = next(f)
	local rb, rf = d.ring_basic, d.ring_full
	local kb, kf = first_after(rb, below - 1) - 1, first_after(rf, below - 1) - 1
	local ib = kb >= 0 and at(rb, kb) or nil
	local iff = kf >= 0 and at(rf, kf) or nil
	local seq_b, seq_f = rb.seq, rf.seq
	local col_b, col_f = rb[key], rf[key]
	local is_station = key == "station"
	local is_delivery = key == "delivery"
	local st2_b, st2_f = rb.station2, rf.station2
	local kind_b, kind_f = rb.kind, rf.kind
	local size_b, size_f = rb.size, rf.size
	local examined, oldest, found = 0, below, #out
	while found < n do
		if ib and (not iff or seq_b[ib] > seq_f[iff]) then
			local seq = seq_b[ib]
			if seq <= stop_seq then return examined, oldest, true end
			if examined >= budget then return examined, oldest, false end
			examined = examined + 1
			oldest = seq
			if (col_b[ib] == id and not (is_delivery and SCHEMA[kind_b[ib]].pass)) or (is_station and st2_b[ib] == id and SCHEMA[kind_b[ib]].station2 == "station") then
				found = found + 1
				out[found] = row(rb, ib)
			end
			kb = kb - 1
			if kb < 0 then ib = nil elseif ib == 1 then ib = size_b else ib = ib - 1 end
		elseif iff then
			local seq = seq_f[iff]
			if seq <= stop_seq then return examined, oldest, true end
			if examined >= budget then return examined, oldest, false end
			examined = examined + 1
			oldest = seq
			if (col_f[iff] == id and not (is_delivery and SCHEMA[kind_f[iff]].pass)) or (is_station and st2_f[iff] == id and SCHEMA[kind_f[iff]].station2 == "station") then
				found = found + 1
				out[found] = row(rf, iff)
			end
			kf = kf - 1
			if kf < 0 then iff = nil elseif iff == 1 then iff = size_f else iff = iff - 1 end
		else
			return examined, oldest, true
		end
	end
	return examined, oldest, false
end

--- @class DiagScanCursor a resumable backward scan for one subject; plain data, kept per panel in storage
--- @field kind "train"|"station"|"delivery"
--- @field id uint
--- @field n int
--- @field rows table[] the newest matching rows found so far, newest first, at most n
--- @field top uint every row with seq in (low, top] has been examined
--- @field low uint
--- @field done boolean rows holds the newest n matches of the whole log (or all of them)
--- @field state_id int? DiagState.id of the state the cursor read (a new state starts over)
--- @field examined int rows examined by the last call

--- @param kind "train"|"station"|"delivery"
--- @param id uint
--- @param n int
--- @return DiagScanCursor
function diag.scan_cursor(kind, id, n)
	return { kind = kind, id = id, n = n, rows = {}, top = 0, low = 1, done = false, examined = 0 }
end

--- The last `n` events about one train, station or delivery, newest first, examining at most `budget` rows
--- (diag.SCAN_ROWS) per call: rows written since the previous call first, then the backward scan continues where it
--- stopped. The result is complete once `cursor.done` is true.
--- @param cursor DiagScanCursor
--- @param budget int?
--- @return table[] rows
function diag.last_for_step(cursor, budget)
	local d = storage.diag
	cursor.examined = 0
	if not d then
		cursor.rows, cursor.done, cursor.state_id = {}, true, nil
		return cursor.rows
	end
	if cursor.done and cursor.top == d.seq and cursor.state_id == d.id then return cursor.rows end
	budget = budget or diag.SCAN_ROWS
	local n = cursor.n
	local f = { [cursor.kind] = cursor.id }
	if cursor.state_id ~= d.id then
		cursor.rows, cursor.top, cursor.low, cursor.done, cursor.state_id = {}, d.seq, d.seq + 1, false, d.id
	end
	if d.seq > cursor.top then
		if d.seq - cursor.top > budget then
			-- More new rows than one call may examine: the newest are what matters, so start over from the head.
			cursor.rows, cursor.top, cursor.low, cursor.done = {}, d.seq, d.seq + 1, false
		else
			local new = {}
			local examined = scan_back(d, f, d.seq + 1, cursor.top, budget, new, n)
			budget = budget - examined
			cursor.examined = examined
			if #new >= n then
				cursor.rows, cursor.done, cursor.low = new, true, d.seq + 1
			else
				for _, ev in ipairs(cursor.rows) do
					if #new >= n then break end
					new[#new + 1] = ev
				end
				cursor.rows = new
				if #new >= n then cursor.done = true end
			end
			cursor.top = d.seq
		end
	end
	if not cursor.done and budget > 0 then
		local examined, oldest, exhausted = scan_back(d, f, cursor.low, 0, budget, cursor.rows, n)
		cursor.examined = cursor.examined + examined
		cursor.low = oldest
		if exhausted or #cursor.rows >= n then cursor.done = true end
	end
	return cursor.rows
end

--- How far back the log reaches: the tick of the oldest row (both rings), and the ticks since then.
--- @return uint? oldest_tick
--- @return uint ticks
function diag.horizon()
	local d = storage.diag
	if not d then return nil, 0 end
	-- The log reaches back only as far as both rings do: with full on, the newer of the two oldest rows; with it
	-- off, the full ring may hold rows of an earlier full session and does not count.
	local oldest
	local rb, rf = d.ring_basic, d.ring_full
	if rb.count > 0 then oldest = rb.tick[at(rb, 0)] end
	if d.full and rf.count > 0 then
		local t = rf.tick[at(rf, 0)]
		if not oldest or t > oldest then oldest = t end
	end
	return oldest, oldest and (game.tick - oldest) or 0
end

-- ---------------------------------------------------------------- acknowledgements

--- storage.acks lives outside storage.diag so an acknowledgement survives diagnostics off. Request acks are keyed by
--- item hash, not by diag's item index, because that index is rebuilt whenever storage.diag is.
--- @class DiagAck
--- @field player_index uint
--- @field tick uint
--- @field until_tick uint? nil = until the reason changes
--- @field reason DiagReason? confirmed reason when acknowledged (requests)

--- One shape for every kind: acks[kind][id][sub], sub = the item hash (request), the check (lint) or 0 (station).
--- @return {request: {[uint]: {[string]: DiagAck}}, station: {[uint]: {[0]: DiagAck}}, lint: {[uint]: {[int]: DiagAck}}, n: int, lint_version: int?} n counts the acknowledgements; lint_version counts every change to the lint ones
function diag.acks()
	local acks = storage.acks
	if not acks then
		acks = { request = {}, station = {}, lint = {}, n = 0 }
		storage.acks = acks
	end
	return acks
end

local ACK_KIND = { request = DIAG_ACK_REQUEST, station = DIAG_ACK_STATION, lint = DIAG_ACK_LINT }

--- Calls fn(kind_code, id, sub, ack) for every acknowledgement.
local function each_ack(acks, fn)
	for code, name in ipairs(DIAG_ACK_KINDS) do
		for id, by in pairs(acks[name]) do
			for sub, ack in pairs(by) do fn(code, id, sub, ack) end
		end
	end
end

local function log_ack(verb, kind, id, sub, player_index, until_tick)
	log("Cybersyn diagnostics: " .. verb .. " " .. (DIAG_ACK_KINDS[kind] or "?") .. " " .. tostring(id) .. " " ..
		tostring(sub or "") .. " by player " .. tostring(player_index or "-") .. " until " .. tostring(until_tick or "reason change"))
end

--- @param kind DiagAckKind
local function ack_event(kind_event, kind, id, sub, player_index, a, b)
	local d = storage.diag
	if not d then return end
	local item = kind == DIAG_ACK_REQUEST and intern(d, sub) or 0
	-- Lint acknowledgements of trains are keyed by the negated train id (lint.subject_key): write it where the
	-- train's own lint events put it.
	local train, station = 0, id
	if kind == DIAG_ACK_LINT and id < 0 then train, station = -id, 0 end
	diag.event(d, kind_event, DIAG_SEV_INFO, kind, 0, train, station, player_index or 0, item, a or 0,
		b or (kind == DIAG_ACK_LINT and sub or 0))
end

--- Removes one acknowledgement and writes the unacknowledged event.
--- @param kind DiagAckKind
local function end_ack(kind, id, sub, cause, player_index)
	local acks = storage.acks
	local t = acks[DIAG_ACK_KINDS[kind]]
	local by = t[id]
	by[sub] = nil
	if next(by) == nil then t[id] = nil end
	acks.n = acks.n - 1
	if kind == DIAG_ACK_LINT then acks.lint_version = (acks.lint_version or 0) + 1 end
	ack_event(DIAG_KIND_UNACKNOWLEDGED, kind, id, sub, player_index, 0, cause)
	log_ack("unacknowledged", kind, id, sub, player_index, nil)
end

--- The stored acknowledgement, expired or not.
--- @param kind "request"|"station"|"lint"
--- @return DiagAck?
local function find_ack(kind, id, sub)
	local acks = storage.acks
	local by = acks and acks[kind][id]
	return by and by[sub or 0]
end

--- @param stop LuaEntity?
local function remove_stop_alerts(stop)
	if not (stop and stop.valid) then return end
	remove_alert_about_missing_train(stop)
end

--- Acknowledge a request (id = requester, sub = item hash), a station (sub nil) or a lint finding (sub = check
--- bit). Display state only: any player may do it, and it always expires.
--- @param kind "request"|"station"|"lint"
--- @param id uint
--- @param sub string|int?
--- @param player_index uint?
--- @param until_tick uint? nil = until the confirmed reason changes
--- @param reason DiagReason? defaults to the request's confirmed reason
--- @return DiagAck
function diag.ack(kind, id, sub, player_index, until_tick, reason)
	local code = ACK_KIND[kind]
	if not code then error("unknown acknowledgement kind " .. tostring(kind)) end
	sub = sub or 0
	local acks = diag.acks()
	if not find_ack(kind, id, sub) then
		if acks.n >= ACK_CAP then
			local oldest
			each_ack(acks, function(k, i, s, ack)
				if not oldest or ack.tick < oldest[4].tick then oldest = { k, i, s, ack } end
			end)
			end_ack(oldest[1], oldest[2], oldest[3], DIAG_ACK_END_EXPIRED, nil)
		end
		acks.n = acks.n + 1
	end
	local d = storage.diag
	if code == DIAG_ACK_REQUEST and reason == nil and d then
		local by = d.unserved[id]
		local ix = d.item_ix[sub]
		local e = by and ix and by[ix]
		reason = e and e.reason or nil
	end
	local ack = { player_index = player_index, tick = game.tick, until_tick = until_tick, reason = reason }
	local t = acks[kind]
	local by = t[id]
	if not by then
		by = {}
		t[id] = by
	end
	by[sub] = ack
	if code == DIAG_ACK_LINT then acks.lint_version = (acks.lint_version or 0) + 1 end
	ack_event(DIAG_KIND_ACKNOWLEDGED, code, id, sub, player_index, until_tick or 0, nil)
	log_ack("acknowledged", code, id, sub, player_index, until_tick)
	local station = storage.stations and storage.stations[id]
	if code ~= DIAG_ACK_LINT and station then remove_stop_alerts(station.entity_stop) end
	return ack
end

--- @return boolean removed
function diag.unack(kind, id, sub, player_index)
	sub = sub or 0
	if not find_ack(kind, id, sub) then return false end
	end_ack(ACK_KIND[kind], id, sub, DIAG_ACK_END_MANUAL, player_index)
	return true
end

--- @return DiagAck? the acknowledgement while it holds
function diag.is_acked(kind, id, sub)
	local ack = find_ack(kind, id, sub)
	if ack and ack.until_tick and ack.until_tick <= game.tick then return nil end
	return ack
end

--- Ends the acknowledgement of a setup finding that is gone (scripts/lint.lua): the finding cleared or its subject
--- left.
--- @param key int lint.subject_key of the subject
--- @param check int LINT_*
function diag.resolve_lint_ack(key, check)
	if find_ack("lint", key, check) then end_ack(DIAG_ACK_LINT, key, check, DIAG_ACK_END_RESOLVED, nil) end
end

--- Drops acknowledgements whose time is up. Runs at every planner cycle start, with or without storage.diag.
function diag.expire_acks()
	local acks = storage.acks
	if not acks or acks.n == 0 then return end
	local now = game.tick
	each_ack(acks, function(kind, id, sub, ack)
		if ack.until_tick and ack.until_tick <= now then end_ack(kind, id, sub, DIAG_ACK_END_EXPIRED, nil) end
	end)
end

--- @param r_id uint
--- @param hash string
--- @param cause DiagAckEnd
local function end_request_ack(r_id, hash, cause)
	if find_ack("request", r_id, hash) then end_ack(DIAG_ACK_REQUEST, r_id, hash, cause, nil) end
end

-- ---------------------------------------------------------------- unserved state

--- @param now uint
--- @return DiagEntry
local function new_entry(now)
	return {
		reason = 0,
		pending_n = 0,
		first_tick = now,
		last_tick = now,
		n = 0,
		a = 0,
		b = 0,
		rej = { 0, 0, 0, 0, 0, 0, 0, 0 },
		lost_n = 0,
		changes = {},
		change_reasons = {},
	}
end

--- @param e DiagEntry
local function write_payload(e, reason, a, b, p_id, rej)
	e.a = a or 0
	e.b = b or 0
	e.p_station_id = p_id
	if reason == REASON_P_BELOW_THRESHOLD then
		e.p_count, e.p_threshold = a, b
	else
		e.p_count, e.p_threshold = nil, nil
	end
	local er = e.rej
	if rej then
		for i = 1, REJ_COUNT do er[i] = rej[i] end
	else
		for i = 1, REJ_COUNT do er[i] = 0 end
	end
end

local function count_add(d, reason, delta)
	local n = (d.counts[reason] or 0) + delta
	d.counts[reason] = n ~= 0 and n or nil
end

--- @param d DiagState
--- @param r_id uint
--- @param by_item {[int]: DiagEntry}
--- @param ix int
--- @param e DiagEntry
local function remove_entry(d, r_id, by_item, ix, e)
	by_item[ix] = nil
	count_add(d, e.reason, -1)
	d.unserved_n = d.unserved_n - 1
	local n = (d.unserved_count[r_id] or 1) - 1
	if n <= 0 then
		d.unserved_count[r_id] = nil
		d.unserved[r_id] = nil
	else
		d.unserved_count[r_id] = n
	end
end

--- @param d DiagState
--- @param e DiagEntry
local function confirm(d, e, r_id, ix, reason, now)
	local old = e.reason
	count_add(d, old, -1)
	count_add(d, reason, 1)
	e.reason = reason
	e.pending = nil
	e.pending_since = nil
	e.pending_n = 0
	local changes, reasons = e.changes, e.change_reasons
	changes[#changes + 1] = now
	reasons[#reasons + 1] = reason
	if #changes > FLAP_CHANGES then
		table.remove(changes, 1)
		table.remove(reasons, 1)
	end
	local suppressed = e.suppressed_until ~= nil and now < e.suppressed_until
	if #changes >= FLAP_CHANGES and now - changes[1] <= FLAP_WINDOW then
		if not suppressed then
			local mask = bit32.lshift(1, old - 1)
			for _, r in ipairs(reasons) do mask = bit32.bor(mask, bit32.lshift(1, r - 1)) end
			diag.event(d, DIAG_KIND_FLAPPING, DIAG_SEV_WARNING, reason, 0, 0, r_id, e.p_station_id, ix, mask, #changes)
		end
		e.suppressed_until = now + FLAP_WINDOW
	elseif suppressed then
		e.suppressed_until = now + FLAP_WINDOW
	else
		e.suppressed_until = nil
		diag.event(d, DIAG_KIND_UNSERVED_REASON, REASON_SEVERITY[reason] or DIAG_SEV_INFO, reason, 0, 0, r_id, e.p_station_id, ix, e.a, e.b)
	end
	end_request_ack(r_id, d.item_hash[ix], DIAG_ACK_END_REASON_CHANGED)
	if NO_TRAIN_REASONS[reason] then stats.record_no_train_failure() end
end

--- One failing evaluation of the key (r_id, hash), called by tick_dispatch at the site that rejected it.
--- @param d DiagState
--- @param r_id uint requester station id (its stop's unit number)
--- @param hash string item hash
--- @param reason DiagReason
--- @param a int? payload
--- @param b int?
--- @param p_id uint? best provider
--- @param rej int[]? REJ_* counters of this evaluation
--- @param lost_to uint? requester whose evaluation in the same call locked the providers this one needed
function diag.fail(d, r_id, hash, reason, a, b, p_id, rej, lost_to)
	local now = game.tick
	local ix = d.item_ix[hash]
	local by_item = d.unserved[r_id]
	local e = ix and by_item and by_item[ix]
	if not e then
		-- Every failing key is re-evaluated once per cycle in a fixed order, so evicting the least recently
		-- evaluated one only makes room for a key that evicts the next: at the cap new keys wait for the sweep.
		if d.unserved_n >= UNSERVED_CAP then
			d.unserved_dropped = d.unserved_dropped + 1
			return
		end
		ix = ix or intern(d, hash)
		if not by_item then
			by_item = {}
			d.unserved[r_id] = by_item
		end
		e = new_entry(now)
		e.reason = reason
		by_item[ix] = e
		d.unserved_n = d.unserved_n + 1
		d.unserved_count[r_id] = (d.unserved_count[r_id] or 0) + 1
		count_add(d, reason, 1)
		write_payload(e, reason, a, b, p_id, rej)
		diag.event(d, DIAG_KIND_UNSERVED_REASON, REASON_SEVERITY[reason] or DIAG_SEV_INFO, reason, 0, 0, r_id, p_id, ix, e.a, e.b)
		if NO_TRAIN_REASONS[reason] then stats.record_no_train_failure() end
		-- The key may have been swept or diagnostics turned off since the acknowledgement: it holds only while the
		-- reason is the one acknowledged, and one taken without a known reason binds to this one.
		local ack = find_ack("request", r_id, hash)
		if ack then
			if ack.reason == nil then
				ack.reason = reason
			elseif ack.reason ~= reason then
				end_ack(DIAG_ACK_REQUEST, r_id, hash, DIAG_ACK_END_REASON_CHANGED, nil)
			end
		end
	else
		e.last_tick = now
		if reason == e.reason then
			if e.pending then
				e.pending = nil
				e.pending_since = nil
				e.pending_n = 0
			end
			write_payload(e, reason, a, b, p_id, rej)
		elseif reason == e.pending then
			e.pending_n = e.pending_n + 1
			if e.pending_n >= FLAP_EVALS and now - e.pending_since >= FLAP_TICKS then
				write_payload(e, reason, a, b, p_id, rej)
				confirm(d, e, r_id, ix, reason, now)
			end
		else
			e.pending = reason
			e.pending_since = now
			e.pending_n = 1
		end
	end
	e.n = e.n + 1
	if lost_to then
		e.lost_n = e.lost_n + 1
		e.lost_to = lost_to
	end
end

--- A requester the item's requester loop skipped, at the return that ends the item for this cycle (no requester
--- was left to evaluate): its skip reason, re-derived from the same fields the loop tested.
--- @param d DiagState
--- @param r_id uint
--- @param station Station
--- @param hash string
function diag.skipped(d, r_id, station, hash)
	local limit = station.trains_limit
	local total = station.deliveries_total
	if total >= limit then
		diag.fail(d, r_id, hash, limit == 0 and REASON_R_DISABLED or REASON_R_AT_LIMIT, total, limit, nil, nil, nil)
		return
	end
	local deliveries = station.deliveries[hash]
	if deliveries and deliveries < 0 then
		local stop = station.entity_stop
		if not (stop and stop.valid) then return end
		diag.fail(d, r_id, hash, REASON_R_IS_PROVIDING, -deliveries, 0, nil, nil, nil)
	end
end

--- Cybersyn trains per network (every train whose depot serves it, available or not).
--- @param network_name string
--- @return int
function diag.fleet_size(network_name)
	return stats.get().trains_by_network[network_name] or 0
end

--- create_delivery served the key: the wait goes to the log and the entry goes away.
--- @param d DiagState
--- @param r_id uint
--- @param hash string
--- @param p_id uint
--- @param train_id uint
--- @param delivery_id uint?
function diag.served(d, r_id, hash, p_id, train_id, delivery_id)
	local ix = d.item_ix[hash]
	if ix then d.item_served[ix] = game.tick end
	local by_item = d.unserved[r_id]
	local e = ix and by_item and by_item[ix]
	if e then
		diag.event(d, DIAG_KIND_SERVED, DIAG_SEV_INFO, e.reason, delivery_id, train_id, r_id, p_id, ix,
			game.tick - e.first_tick, e.n)
		remove_entry(d, r_id, by_item, ix, e)
	end
	-- Only service resolves a request: a swept entry keeps its acknowledgement, which is keyed by hash.
	end_request_ack(r_id, hash, DIAG_ACK_END_RESOLVED)
end

--- A station left Cybersyn: its entries and its acknowledgements go with it.
--- @param station_id uint
function diag.station_removed(station_id)
	local d = storage.diag
	if d then
		local by_item = d.unserved[station_id]
		if by_item then
			for ix, e in pairs(by_item) do remove_entry(d, station_id, by_item, ix, e) end
		end
		d.unserved[station_id] = nil
		d.unserved_count[station_id] = nil
		d.unpowered[station_id] = nil
		for code = 1, #DIAG_ALERT_NAMES do d.alert_last[station_id * 32 + code] = nil end
	end
	local acks = storage.acks
	if acks then
		for _, name in ipairs(DIAG_ACK_KINDS) do
			local by = acks[name][station_id]
			if by then
				for _ in pairs(by) do acks.n = acks.n - 1 end
				acks[name][station_id] = nil
				if name == "lint" then acks.lint_version = (acks.lint_version or 0) + 1 end
			end
		end
	end
end

--- Planner cycle start (tick_init): every SWEEP_EVERY cycles drops entries no evaluation has touched for two cycles,
--- unless their item was served to another requester since (that dispatch ended the call before they were reached);
--- expires acknowledgements.
function diag.cycle()
	diag.expire_acks()
	local d = storage.diag
	if not d then return end
	local now = game.tick
	local seen = d.inherit_cycles
	if seen then
		if seen >= 1 then
			d.inherit_until, d.inherit_cycles = now, nil
		else
			d.inherit_cycles = seen + 1
		end
	end
	d.cycle_prev2 = d.cycle_prev
	d.cycle_prev = d.cycle_start >= 0 and d.cycle_start or nil
	d.cycle_start = now
	local cycles = d.cycles + 1
	d.cycles = cycles
	if now >= (d.alert_sweep or 0) then
		local last = d.alert_last
		for key, tick in pairs(last) do
			if now - tick >= ALERT_REPEAT then last[key] = nil end
		end
		d.alert_sweep = now + ALERT_REPEAT
	end
	local cutoff = d.cycle_prev2
	if not cutoff or d.unserved_n == 0 or cycles % diag.SWEEP_EVERY ~= 0 then return end
	local served = d.item_served
	for r_id, by_item in pairs(d.unserved) do
		for ix, e in pairs(by_item) do
			local last = e.last_tick
			if last < cutoff and ((served[ix] or -1) < cutoff or now - last > SWEEP_SPARE) then
				remove_entry(d, r_id, by_item, ix, e)
			end
		end
	end
end

-- ---------------------------------------------------------------- GUI reads

--- An entry whose first_tick is below this may have been failing before diagnostics saw it: a request already
--- starving when the state was created is first evaluated somewhere in the cycle that was running then or in the
--- next full one, so the window closes at the start of the second cycle after creation.
--- @param d DiagState
--- @return number
function diag.inherit_threshold(d)
	return d.inherit_until or math.huge
end

--- @param r_id uint
--- @return {[int]: DiagEntry}? item index -> entry; read only
function diag.unserved_for(r_id)
	local d = storage.diag
	return d and d.unserved[r_id] or nil
end

--- @param r_id uint
--- @return int count
--- @return DiagReason? worst_reason
--- @return uint? oldest_first_tick
function diag.unserved_summary(r_id)
	local d = storage.diag
	local by_item = d and d.unserved[r_id]
	if not by_item then return 0, nil, nil end
	local n, worst, worst_sev, oldest = 0, nil, nil, nil
	for _, e in pairs(by_item) do
		n = n + 1
		local r = e.reason
		local sev = REASON_SEVERITY[r] or DIAG_SEV_INFO
		if not worst or sev < worst_sev or (sev == worst_sev and r < worst) then
			worst, worst_sev = r, sev
		end
		if not oldest or e.first_tick < oldest then oldest = e.first_tick end
	end
	return n, worst, oldest
end

--- Live entries per confirmed reason (the number the Overview tile shows). Read only.
--- @return {[int]: int}
function diag.counts_by_reason()
	local d = storage.diag
	return d and d.counts or {}
end

--- @class DiagUnservedRow
--- @field r_station_id uint
--- @field item int item index
--- @field hash string
--- @field entry DiagEntry read only

--- The `limit` longest-waiting entries (oldest first_tick first; ties by requester id, then item index).
--- @param filter {item: string?, reason: DiagReason?, requester: uint?, limit: int?}?
--- @return DiagUnservedRow[]
function diag.unserved_rows(filter)
	local d = storage.diag
	local out = {}
	if not d then return out end
	local limit = filter and filter.limit or 100
	local want_ix = filter and filter.item and d.item_ix[filter.item] or nil
	if filter and filter.item and not want_ix then return out end
	local want_reason = filter and filter.reason
	local item_hash = d.item_hash
	local function before(t, r_id, ix, other)
		local rt = other.entry.first_tick
		if t ~= rt then return t < rt end
		if r_id ~= other.r_station_id then return r_id < other.r_station_id end
		return ix < other.item
	end
	local function scan(r_id, by_item)
		for ix, e in pairs(by_item) do
			if (not want_ix or ix == want_ix) and (not want_reason or e.reason == want_reason) then
				local t = e.first_tick
				local n = #out
				-- Test before allocating: on a full table most entries lose to the current last row.
				if n < limit or before(t, r_id, ix, out[n]) then
					local pos = n + 1
					while pos > 1 and before(t, r_id, ix, out[pos - 1]) do
						out[pos] = out[pos - 1]
						pos = pos - 1
					end
					out[pos] = { r_station_id = r_id, item = ix, hash = item_hash[ix], entry = e }
					if #out > limit then out[#out] = nil end
				end
			end
		end
	end
	local want_r = filter and filter.requester
	if want_r then
		local by_item = d.unserved[want_r]
		if by_item then scan(want_r, by_item) end
	else
		for r_id, by_item in pairs(d.unserved) do scan(r_id, by_item) end
	end
	return out
end

-- ---------------------------------------------------------------- hooks outside the planner loops

--- @param stop LuaEntity?
--- @return uint
local function unit(stop)
	return stop and stop.valid and stop.unit_number or 0
end

--- Every send_alert_* in factorio-api.lua.
--- @param code DiagAlert
--- @param train LuaTrain?
--- @param stop LuaEntity?
--- @param stop2 LuaEntity?
function diag.alert(code, train, stop, stop2)
	local d = storage.diag
	if not d then return end
	local station = unit(stop)
	local train_id = train and train.valid and train.id or 0
	-- Per alert, not per entity: one requester can fail two items in turn with two different alerts.
	local key = station ~= 0 and (station * 32 + code) or -(train_id * 32 + code)
	local now = game.tick
	local last = d.alert_last[key]
	if last and now - last < ALERT_REPEAT then return end
	d.alert_last[key] = now
	local ctrain = train_id ~= 0 and storage.trains[train_id]
	diag.event(d, DIAG_KIND_ALERT, ALERT_SEVERITY[code] or DIAG_SEV_WARNING, code, ctrain and ctrain.delivery_id or 0,
		train_id, station, unit(stop2), 0, 0, 0)
end

--- An alert about a requester sent from inside the planner, which already holds storage.diag and the stop ids.
--- @param d DiagState
--- @param code DiagAlert
--- @param station uint requester stop unit number
--- @param station2 uint? provider
function diag.alert_ids(d, code, station, station2)
	local key = station * 32 + code
	local now = game.tick
	local last = d.alert_last[key]
	if last and now - last < ALERT_REPEAT then return end
	d.alert_last[key] = now
	diag.event(d, DIAG_KIND_ALERT, ALERT_SEVERITY[code] or DIAG_SEV_WARNING, code, 0, 0, station, station2 or 0, 0, 0, 0)
end

--- The create_delivery exits that give up on a chosen train.
--- @param code DiagDispatch DIAG_DISPATCH_*
--- @param manifest Manifest? its first item fills the item column
--- @param state defines.train_state? stored as state + DIAG_STATE_OFFSET in a (0 = not recorded)
function diag.dispatch_failed(code, train_id, r_id, p_id, manifest, state)
	local d = storage.diag
	if not d then return end
	local first = manifest and manifest[1]
	local item = first and intern(d, hash_item(first.name, first.quality)) or 0
	diag.event(d, DIAG_KIND_DISPATCH_FAILED, DIAG_DISPATCH_SEVERITY[code] or DIAG_SEV_ERROR, code, 0, train_id, r_id,
		p_id, item, state and state + DIAG_STATE_OFFSET or 0, 0)
end

--- on_failed_delivery: a delivery ended without being completed.
--- @param cause DiagFail?
--- @param train Train
function diag.delivery_failed(cause, train_id, train, p_id, r_id, is_p, is_r)
	local d = storage.diag
	if not d then return end
	local manifest = train.manifest
	local first = manifest and manifest[1]
	local item = first and intern(d, hash_item(first.name, first.quality)) or 0
	diag.event(d, DIAG_KIND_DELIVERY_FAILED, DIAG_SEV_ERROR, cause or 0, train.delivery_id, train_id, r_id, p_id, item,
		is_p and 1 or 0, is_r and 1 or 0)
end

--- tick_poll_station saw the stop's train limit change.
function diag.station_limit(d, station_id, old, new)
	if new == 0 then
		diag.event(d, DIAG_KIND_STATION_DISABLED, DIAG_SEV_WARNING, 0, 0, 0, station_id, 0, 0, old, new)
	else
		diag.event(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 0, 0, 0, station_id, 0, 0, old, new)
	end
end

--- tick_poll_station saw the station combinator start or stop working (power, or disabled).
function diag.station_power(d, station_id, working)
	d.unpowered[station_id] = (not working) or nil
	diag.event(d, DIAG_KIND_STATION_POWER, working and DIAG_SEV_INFO or DIAG_SEV_WARNING, 0, 0, 0, station_id, 0, 0,
		working and 1 or 0, 0)
end

function diag.station_warmup_done(d, station_id)
	diag.event(d, DIAG_KIND_STATION_WARMUP_DONE, DIAG_SEV_INFO, 0, 0, 0, station_id, 0, 0, 0, 0)
end

--- create_delivery applied the schedule: in full mode the delivery gets an id its later events carry.
--- @param train Train
--- @param manifest Manifest
--- @param first_hash string? hash of manifest[1], which the caller has already built
function diag.dispatched(d, train_id, train, r_id, p_id, manifest, first_hash)
	if not d.full then
		train.delivery_id = nil
		return
	end
	local id = d.next_delivery + 1
	d.next_delivery = id
	train.delivery_id = id
	local total = 0
	for _, item in ipairs(manifest) do total = total + item.count end
	diag.event(d, DIAG_KIND_DISPATCHED, DIAG_SEV_INFO, 0, id, train_id, r_id, p_id,
		first_hash and intern(d, first_hash) or 0, #manifest, total)
end

--- A delivery took more than stats.SLOW_FACTOR times its item's average trip (basic ring): `a` = the trip in ticks,
--- `b` = the average it was judged against; station = requester, station2 = provider, item = the manifest's first.
--- @param train Train
--- @param hash string
--- @param ticks uint
--- @param avg number
function diag.slow_delivery(train, hash, ticks, avg)
	local d = storage.diag
	if not d then return end
	local entity = train.entity
	local train_id = entity and entity.valid and entity.id or 0
	diag.event(d, DIAG_KIND_SLOW_DELIVERY, DIAG_SEV_WARNING, 0, train.delivery_id or 0, train_id,
		train.r_station_id or 0, train.p_station_id or 0, intern(d, hash), ticks, math.floor(avg + 0.5))
end

--- Arrivals, departures and the return to a depot (full only).
--- @param kind DiagKind DIAG_KIND_ARRIVE_P .. DIAG_KIND_RETURNED
--- @param train Train
function diag.train_event(kind, train_id, train, station_id)
	local d = storage.diag
	if not (d and d.full) then return end
	local manifest = train.manifest
	local total = 0
	if manifest then
		for _, item in ipairs(manifest) do total = total + item.count end
	end
	diag.event(d, kind, DIAG_SEV_INFO, 0, train.delivery_id, train_id, station_id or 0,
		kind == DIAG_KIND_RETURNED and 0 or (train.r_station_id or 0), 0, total, 0)
end

local TS = defines.train_state
local STATE_SEV = {
	[TS.no_path] = DIAG_SEV_ERROR,
	[TS.destination_full] = DIAG_SEV_WARNING,
	[TS.manual_control] = DIAG_SEV_INFO,
}

--- on_train_changed_state for a Cybersyn train (full only): entering no_path, destination_full or manual control,
--- and leaving a signal it waited at for at least WAIT_SIGNAL_MIN.
--- @param train Train
--- @param old_state defines.train_state?
--- @param since uint? tick old_state began
--- @param state defines.train_state the state entered
function diag.train_state(train_id, train, old_state, since, state)
	local d = storage.diag
	if not (d and d.full) then return end
	local sev = STATE_SEV[state]
	if sev then
		diag.event(d, DIAG_KIND_TRAIN_STATE, sev, state, train.delivery_id, train_id, 0, 0, 0, 0, 0)
	end
	if old_state == TS.wait_signal and since then
		local waited = game.tick - since
		if waited >= WAIT_SIGNAL_MIN then
			diag.event(d, DIAG_KIND_TRAIN_STATE, DIAG_SEV_WARNING, TS.wait_signal, train.delivery_id, train_id, 0, 0,
				0, waited, 0)
		end
	end
end

-- ---------------------------------------------------------------- cargo anomalies

local CARGO_SHORT = 1
local CARGO_EXTRA = 2
local CARGO_RESIDUE = 3
diag.CARGO_SHORT, diag.CARGO_EXTRA, diag.CARGO_RESIDUE = CARGO_SHORT, CARGO_EXTRA, CARGO_RESIDUE

--- @param quality string?
local function q(quality)
	return quality or "normal"
end

--- Amount of a manifest entry aboard: items by name and quality from get_contents(), fluids by name.
--- @param m ManifestEntry
--- @param contents ItemWithQualityCount[]
--- @param fluids {[string]: number}
--- @return number
local function aboard(m, contents, fluids)
	if m.type == "fluid" then return fluids[m.name] or 0 end
	local n, mq = 0, q(m.quality)
	for _, c in pairs(contents) do
		if c.name == m.name and q(c.quality) == mq then n = n + c.count end
	end
	return n
end

--- @param manifest Manifest
--- @return ManifestEntry?
local function planned(manifest, name, quality, is_fluid)
	for _, m in ipairs(manifest) do
		if m.name == name and ((m.type == "fluid") == is_fluid) and (is_fluid or q(m.quality) == q(quality)) then
			return m
		end
	end
	return nil
end

--- Compares a train's cargo with its manifest when it leaves a stop. At the provider (`at_r` false) a manifest
--- entry with less aboard is a short load (items: any shortfall; fluids: more than `tolerance` percent) and
--- anything aboard that the manifest does not name is unexpected; at the requester anything still aboard is
--- residual (fluids: above `tolerance` percent of the planned amount, or any amount the manifest did not name).
--- Pure: the caller reads the contents. Returns at most one finding per kind, the largest.
--- @param manifest Manifest
--- @param contents ItemWithQualityCount[] LuaTrain.get_contents()
--- @param fluids {[string]: number} LuaTrain.get_fluid_contents()
--- @param tolerance number percent
--- @param at_r boolean
--- @return {kind: int, name: string, quality: string?, type: string, planned: int, actual: int}[]
--- @return boolean? item_extra at the provider: some item aboard is unplanned (the unexpected-cargo alert), even when
---   a larger unplanned fluid is the finding
function diag.cargo_check(manifest, contents, fluids, tolerance, at_r)
	local out = {}
	local frac = tolerance / 100
	if at_r then
		local best, best_n
		for _, c in pairs(contents) do
			if c.count > 0 and (not best_n or c.count > best_n) then
				local m = planned(manifest, c.name, c.quality, false)
				best = { kind = CARGO_RESIDUE, name = c.name, quality = c.quality, type = "item",
					planned = m and m.count or 0, actual = c.count }
				best_n = c.count
			end
		end
		for name, amount in pairs(fluids) do
			local m = planned(manifest, name, nil, true)
			local limit = m and m.count * frac or 0
			if amount > limit and amount >= 1 and (not best_n or amount > best_n) then
				best = { kind = CARGO_RESIDUE, name = name, type = "fluid", planned = m and m.count or 0,
					actual = math.floor(amount + 0.5) }
				best_n = amount
			end
		end
		if best then out[1] = best end
		return out
	end
	local short, short_gap
	for _, m in ipairs(manifest) do
		local have = aboard(m, contents, fluids)
		local need = m.type == "fluid" and m.count * (1 - frac) or m.count
		if have < need and m.count > 0 then
			local gap = (m.count - have) / m.count
			if not short_gap or gap > short_gap then
				short = { kind = CARGO_SHORT, name = m.name, quality = m.quality, type = m.type or "item",
					planned = m.count, actual = math.floor(have + 0.5) }
				short_gap = gap
			end
		end
	end
	if short then out[#out + 1] = short end
	local extra, item_extra
	for _, c in pairs(contents) do
		if c.count > 0 and not planned(manifest, c.name, c.quality, false) then
			item_extra = true
			if not extra or c.count > extra.actual then
				extra = { kind = CARGO_EXTRA, name = c.name, quality = c.quality, type = "item", planned = 0,
					actual = c.count }
			end
		end
	end
	for name, amount in pairs(fluids) do
		if amount >= 1 and not planned(manifest, name, nil, true) and (not extra or amount > extra.actual) then
			extra = { kind = CARGO_EXTRA, name = name, type = "fluid", planned = 0, actual = math.floor(amount + 0.5) }
		end
	end
	if extra then out[#out + 1] = extra end
	return out, item_extra
end

local CARGO_KIND = {
	[CARGO_SHORT] = DIAG_KIND_SHORT_LOAD,
	[CARGO_EXTRA] = DIAG_KIND_UNEXPECTED_CARGO,
	[CARGO_RESIDUE] = DIAG_KIND_RESIDUAL_CARGO,
}

--- Writes the findings of diag.cargo_check: `a` = planned, `b` = actual, station = the stop the train left.
--- @param d DiagState
--- @param findings table[] diag.cargo_check
--- @param train Train
function diag.cargo_events(d, findings, train_id, train, station_id, other_id)
	for _, f in ipairs(findings) do
		local hash = f.type == "fluid" and f.name or hash_item(f.name, f.quality)
		diag.event(d, CARGO_KIND[f.kind], DIAG_SEV_WARNING, 0, train.delivery_id, train_id, station_id or 0,
			other_id or 0, intern(d, hash), f.planned, f.actual)
	end
end

-- ---------------------------------------------------------------- schedule edits, lint, manual actions

--- on_train_schedule_changed raised by a player on a Cybersyn train. An edit of a vanilla group's schedule fires
--- once per member train, so a grouped train adds itself to the row its group's edit by the same player wrote (`b` =
--- trains in it) for EDIT_REPEAT; an ungrouped train writes one row per EDIT_REPEAT. `a` = the player index.
--- @param d DiagState
--- @param train Train
--- @param player_index uint
--- @param group string? LuaTrain.group ("" or nil when the train is in none)
function diag.schedule_edited(d, train_id, train, player_index, group)
	local now = game.tick
	local last = train.edited_tick
	if last and now - last < EDIT_REPEAT then return end
	train.edited_tick = now
	local rows = d.edit_rows
	if not rows then
		rows = {}
		d.edit_rows = rows
	end
	local key = group and group ~= "" and (player_index .. "|" .. group) or nil
	if key then
		local open = rows[key]
		local r = d.ring_basic
		if open and now - open.tick < EDIT_REPEAT and r.seq[open.h] == open.seq then
			if not open.trains[train_id] then
				open.trains[train_id] = true
				r.b[open.h] = r.b[open.h] + 1
			end
			return
		end
	end
	for k, open in pairs(rows) do
		if now - open.tick >= EDIT_REPEAT then rows[k] = nil end
	end
	local seq = diag.event(d, DIAG_KIND_SCHEDULE_EDITED, DIAG_SEV_WARNING, 0, train.delivery_id, train_id,
		train.r_station_id or train.p_station_id or 0, player_index, 0, player_index, 1)
	if key and seq then
		rows[key] = { h = d.ring_basic.head, seq = seq, tick = now, trains = { [train_id] = true } }
	end
end

--- A lint finding appeared or cleared (`a` = check, `b` = subject id; trains also in `train`, stops in `station`).
--- The delivery column holds the pass key, so the Log shows a pass as one row; delivery subjects and filters skip lint
--- rows and the CSV export writes 0 there.
--- @param check int LINT_*
--- @param subject int LINT_SUBJECT_*
--- @param id uint
--- @param appeared boolean
--- @param pass uint? the running pass's start tick + 1; 0 or nil outside a pass
function diag.lint(check, subject, id, appeared, pass)
	local d = storage.diag
	if not d then return end
	local is_train = subject == LINT_SUBJECT_TRAIN
	diag.event(d, DIAG_KIND_LINT, appeared and (LINT_SEVERITY[check] or DIAG_SEV_WARNING) or DIAG_SEV_INFO,
		appeared and DIAG_LINT_APPEARED or DIAG_LINT_CLEARED, pass, is_train and id or 0, is_train and 0 or id, subject, 0,
		check, id)
end

--- A state-changing command or manager action: `a` = ACTION_*, `b` = target id (0 = all),
--- station2 = player index (0 = the server console); train / station = the train or stop it applied to, if any.
function diag.manual_action(action, target, player_index, train_id, station_id)
	local d = storage.diag
	if not d then return end
	diag.event(d, DIAG_KIND_MANUAL_ACTION, DIAG_SEV_INFO, action, 0, train_id or 0, station_id or 0, player_index or 0, 0,
		action, target or 0)
end

-- ---------------------------------------------------------------- export

local HEADER = "seq,tick,kind,severity,code,delivery,train,station,station2,item,a,b\n"

--- Name of the event's code column, or the number where its kind names none.
--- @param kind DiagKind
--- @param code int
--- @return string
local function code_name(kind, code)
	local names = SCHEMA[kind].code_names
	return names and names[code] or tostring(code)
end

diag.code_name = code_name

local LINE = "%d,%d,%s,%s,%s,%d,%d,%d,%d,%s,%d,%d\n"

--- @param item_hash string[]
--- @param ix int
--- @return string
local function csv_item(item_hash, ix)
	local item = ix ~= 0 and item_hash[ix] or ""
	if string.find(item, "[,\"]") then item = '"' .. string.gsub(item, '"', '""') .. '"' end
	return item
end

--- Writes every row the rings hold now that matches `filter` to one CSV file within the tick: exports are rare, so a
--- long tick is a fair price for not spreading the write over many.
--- @param player_index uint? whose machine gets the file; 0 or nil = the server
--- @param filter DiagEventFilter?
--- @return string? path relative to script-output, nil while diagnostics are off
--- @return int rows
function diag.export(player_index, filter)
	local d = storage.diag
	if not d then return nil, 0 end
	-- Two exports in one tick get two files.
	local tick = game.tick
	if d.export_name_tick == tick then
		d.export_name_n = d.export_name_n + 1
	else
		d.export_name_tick, d.export_name_n = tick, 1
	end
	local path = "cybersyn/diag-" .. tick .. (d.export_name_n > 1 and ("-" .. d.export_name_n) or "") .. ".csv"
	local item_hash = d.item_hash
	local parts = { HEADER }
	for _, ev in ipairs(diag.events(filter, 0, math.huge, math.huge)) do
		local kind = ev.kind
		parts[#parts + 1] = string.format(LINE, ev.seq, ev.tick, DIAG_KIND_NAMES[kind] or tostring(kind),
			DIAG_SEV_NAMES[ev.sev] or tostring(ev.sev), code_name(kind, ev.code),
			SCHEMA[kind].pass and 0 or ev.delivery, ev.train, ev.station, ev.station2, csv_item(item_hash, ev.item),
			ev.a, ev.b)
	end
	helpers.write_file(path, table.concat(parts), false, player_index or 0)
	return path, #parts - 1
end

return diag
