-- Delivery throughput counters for the manager's Overview tab. Unlike the collector this is always on, because
-- throughput can only be measured as it happens; every hook is O(1) plus O(manifest) and every structure is a
-- fixed-size ring, so neither UPS nor the save grows with time.

local stats = {}

local MINUTE = 3600
local HOUR = 216000
local MINUTE_SLOTS = 60
local HOUR_SLOTS = 24
-- Weight of the newest cycle sample in the moving average: about the last 20 deliveries dominate.
local EMA_ALPHA = 0.1
-- Per item the average follows the route mix faster (about the last 5 deliveries of that item).
local TRIP_ALPHA = 0.2
-- A trip longer than SLOW_FACTOR times its item's average is a slow delivery, once the average has this many samples
-- behind it (the first trips of an item set the average and are never slow).
stats.SLOW_FACTOR = 2
stats.SLOW_MIN_SAMPLES = 3

stats.MINUTE = MINUTE
stats.HOUR = HOUR

--- @class StatsBucket
--- @field start_tick uint
--- @field deliveries int
--- @field dispatches int
--- @field items {[string]: int} delivered amount per item hash
--- @field cycle_sum number? seconds from dispatch to unloaded, summed over the deliveries completed in this bucket
--- @field cycle_n int? deliveries that contributed to cycle_sum
--- @field wait_sum number? request wait in ticks, summed over the requests fulfilled (dispatched) in this bucket
--- @field wait_n int? fulfilled requests that contributed to wait_sum
--- @field wait_max uint? longest of those waits, in ticks
--- @field wait_max_station uint? requester station id of the longest wait
--- @field wait_max_hash string? item hash of the longest wait
--- @field wait_max_tick uint? when the longest wait ended (its train was dispatched)
--- @field avail_min {[string]: int}? per network, the fewest available trains seen while this bucket was current;
---   only networks whose count changed inside the bucket (an unchanged count is the current one)
--- @field no_train_failures int? requests that turned unserved for want of a train (diagnostics transitions into
---   NO_TRAINS_ON_NETWORK, TRAIN_FILTERED or CAPACITY)

--- @class Stats
--- @field minute {[int]: StatsBucket} ring of one-minute buckets
--- @field hour {[int]: StatsBucket} ring of one-hour buckets
--- @field totals {deliveries: int, dispatches: int, items: int, since_tick: uint}
--- @field cycle {ema_seconds: number?, ticks_last: uint, dispatches_last: int, calls_last: int, start_tick: uint?, dispatches_run: int, calls_run: int}
---   the last complete planner cycle: its length in ticks, deliveries created and tick_dispatch calls, from
---   integer counters the planner bumps outside its loops (*_run, rolled over at tick_init)
--- @field refuel_since uint tick from which Train.refuel_tick is recorded (older saves did not track refuelling)
--- @field available_count {[string]: int} available trains per network, kept equal to the sizes of
---   storage.available_trains by add_available_train / remove_available_train
--- @field trains_by_network {[string]: int} Cybersyn trains per network whatever their state, each-network masks
---   expanded; a network without trains has no key. Kept by stats.train_networks_changed
--- @field trip_ema {[string]: {avg: number, n: int}}? per item hash (the manifest's first item), the moving average
---   of dispatch-to-unloaded ticks and the deliveries behind it; the slow-delivery baseline. Analytics keeps a
---   similar average, but only with factorio-charts and its setting on, and without the sample count the baseline
---   needs before it judges a delivery slow

--- @return Stats
local function new_stats()
	return {
		minute = {},
		hour = {},
		totals = { deliveries = 0, dispatches = 0, items = 0, since_tick = game and game.tick or 0 },
		cycle = { ema_seconds = nil, ticks_last = 0, dispatches_last = 0, calls_last = 0, dispatches_run = 0, calls_run = 0 },
		available_count = {},
		trains_by_network = {},
		refuel_since = game and game.tick or 0,
	}
end

--- A missing table only exists before init, on a save from before stats were recorded: a hook raised by a migration
--- starts it fresh.
--- @return Stats
local function get()
	local s = storage.stats
	if s then return s end
	s = new_stats()
	storage.stats = s
	return s
end

--- @param hash string
--- @return boolean
local function hash_is_valid(hash)
	local name, quality = unhash_signal(hash)
	if quality and not prototypes.quality[quality] then return false end
	return prototypes.item[name] ~= nil or prototypes.fluid[name] ~= nil
end

--- Buckets outlive mod changes, so a removed item or quality would otherwise reach the GUI and fail there.
--- @param s Stats
local function purge_invalid_hashes(s)
	for _, ring in pairs({ s.minute, s.hour }) do
		for _, b in pairs(ring) do
			for hash in pairs(b.items) do
				if not hash_is_valid(hash) then b.items[hash] = nil end
			end
			if b.wait_max_hash and not hash_is_valid(b.wait_max_hash) then b.wait_max_hash = nil end
		end
	end
	for hash in pairs(s.trip_ema or {}) do
		if not hash_is_valid(hash) then s.trip_ema[hash] = nil end
	end
end

--- Recounts the available-train counters from the planner's own table, so a save from before them starts exact. A
--- counter that disagrees means a writer of storage.available_trains skipped stats.available_changed: logged as the
--- bug it is.
--- @param s Stats
local function recount_available(s)
	local counts = s.available_count
	local trains = storage.available_trains or {}
	for name, n in pairs(counts) do
		local actual = trains[name] and table_size(trains[name]) or 0
		if n ~= actual then log("Cybersyn: " .. name .. " counted " .. n .. " available trains, has " .. actual) end
		counts[name] = actual
	end
	for name, ids in pairs(trains) do counts[name] = table_size(ids) end
end

--- @param counts {[string]: int}
--- @param train Train
--- @param delta 1|-1
local function count_train(counts, train, delta)
	each_network(train.network_name, train.network_mask, function(name)
		local n = (counts[name] or 0) + delta
		counts[name] = n > 0 and n or nil
	end)
end

function stats.init()
	local s = get()
	purge_invalid_hashes(s)
	recount_available(s)
	local counts = {}
	for _, train in pairs(storage.trains or {}) do count_train(counts, train, 1) end
	s.trains_by_network = counts
end

--- @return Stats
function stats.get()
	return get()
end

--- @param ring {[int]: StatsBucket}
--- @param slots int
--- @param width uint
--- @param tick uint
--- @return StatsBucket
local function bucket(ring, slots, width, tick)
	local start = tick - tick % width
	local index = (start / width) % slots + 1
	local b = ring[index]
	if not b or b.start_tick ~= start then
		b = { start_tick = start, deliveries = 0, dispatches = 0, items = {} }
		ring[index] = b
	end
	return b
end

--- @param ring {[int]: StatsBucket}
--- @param slots int
--- @param width uint
--- @param tick uint
--- @param name string
--- @param old int
--- @param new int
local function note_available(ring, slots, width, tick, name, old, new)
	local b = bucket(ring, slots, width, tick)
	local mins = b.avail_min
	if not mins then
		mins = {}
		b.avail_min = mins
	end
	-- `old` held since the previous change, which may predate this bucket, so it counts towards its minimum.
	local m = mins[name]
	if not m or old < m then m = old end
	if new < m then m = new end
	mins[name] = m
end

--- add_available_train / remove_available_train changed a network's available count by `delta`; O(1).
--- @param name string network name
--- @param delta int
function stats.available_changed(name, delta)
	local s = get()
	local counts = s.available_count
	local old = counts[name] or 0
	local new = old + delta
	if new < 0 then new = 0 end
	counts[name] = new
	-- Increases count too: the level before one may have held since before the window began.
	local tick = game.tick
	note_available(s.minute, MINUTE_SLOTS, MINUTE, tick, name, old, new)
	note_available(s.hour, HOUR_SLOTS, HOUR, tick, name, old, new)
end

--- A train joined (1) or left (-1) the networks it is on now: call it on both sides of a network change and when the
--- train is removed.
--- @param train Train
--- @param delta 1|-1
function stats.train_networks_changed(train, delta)
	count_train(get().trains_by_network, train, delta)
end

--- A request turned unserved for want of a train (from diagnostics transitions).
function stats.record_no_train_failure()
	local s = get()
	local tick = game.tick
	local m = bucket(s.minute, MINUTE_SLOTS, MINUTE, tick)
	m.no_train_failures = (m.no_train_failures or 0) + 1
	local h = bucket(s.hour, HOUR_SLOTS, HOUR, tick)
	h.no_train_failures = (h.no_train_failures or 0) + 1
end

--- Fewest available trains per network over the window: the current count, lowered by every minimum a bucket of
--- the window recorded. A network whose count never changed in the window reports its current count.
--- @param ring {[int]: StatsBucket}
--- @param oldest uint
--- @param tick uint
--- @return {[string]: int}
local function min_available(s, ring, oldest, tick)
	local out = {}
	for name, n in pairs(s.available_count) do out[name] = n end
	for _, b in pairs(ring) do
		local mins = b.avail_min
		if mins and b.start_tick >= oldest and b.start_tick <= tick then
			for name, m in pairs(mins) do
				if out[name] == nil or m < out[name] then out[name] = m end
			end
		end
	end
	return out
end

--- Called from create_delivery once the schedule is applied.
--- @param train Train
function stats.record_dispatch(train)
	local tick = game.tick
	train.dispatch_tick = tick
	local s = get()
	local m = bucket(s.minute, MINUTE_SLOTS, MINUTE, tick)
	m.dispatches = m.dispatches + 1
	local h = bucket(s.hour, HOUR_SLOTS, HOUR, tick)
	h.dispatches = h.dispatches + 1
	s.totals.dispatches = s.totals.dispatches + 1
	local cycle = s.cycle
	cycle.dispatches_run = cycle.dispatches_run + 1
end

--- tick_dispatch calls made in one planner tick.
--- @param n int
function stats.count_calls(n)
	local s = storage.stats
	if not s then return end
	local cycle = s.cycle
	cycle.calls_run = (cycle.calls_run or 0) + n
end

--- tick_init: the cycle that just ended becomes the last one.
--- @param tick uint
function stats.cycle_start(tick)
	local s = storage.stats
	if not s then return end
	local cycle = s.cycle
	if cycle.start_tick then
		cycle.ticks_last = tick - cycle.start_tick
		cycle.dispatches_last = cycle.dispatches_run
		cycle.calls_last = cycle.calls_run
	end
	cycle.start_tick = tick
	cycle.dispatches_run = 0
	cycle.calls_run = 0
end

--- @param b StatsBucket
--- @param ticks uint
--- @param station_id uint
--- @param hash string
local function add_wait(b, ticks, station_id, hash)
	b.wait_sum = (b.wait_sum or 0) + ticks
	b.wait_n = (b.wait_n or 0) + 1
	local max = b.wait_max
	-- Ties keep the first request, so a bucket's maximum does not flicker between equal waits.
	if not max or ticks > max then
		b.wait_max = ticks
		b.wait_max_station = station_id
		b.wait_max_hash = hash
		b.wait_max_tick = game.tick
	end
end

--- Called from create_delivery for each manifest item whose request start was tracked. Only bucket aggregates are
--- kept, so the cost and the save size do not depend on the number of deliveries.
--- @param ticks uint time from the request start until the delivery was created
--- @param station_id uint requester station id
--- @param hash string item hash
function stats.record_fulfilment(ticks, station_id, hash)
	local tick = game.tick
	local s = get()
	add_wait(bucket(s.minute, MINUTE_SLOTS, MINUTE, tick), ticks, station_id, hash)
	add_wait(bucket(s.hour, HOUR_SLOTS, HOUR, tick), ticks, station_id, hash)
end

--- The trip against its item's average: true when it is slow (judged before the trip joins the average).
--- @param e {avg: number, n: int}? the item's average so far
--- @param ticks uint
--- @return boolean
function stats.is_slow(e, ticks)
	return e ~= nil and e.n >= stats.SLOW_MIN_SAMPLES and ticks > stats.SLOW_FACTOR * e.avg
end

--- Adds a trip to the item's average.
--- @param ema {[string]: {avg: number, n: int}}
--- @param hash string
--- @param ticks uint
--- @return {avg: number, n: int}
function stats.add_trip(ema, hash, ticks)
	local e = ema[hash]
	if e then
		e.avg = e.avg + TRIP_ALPHA * (ticks - e.avg)
		e.n = e.n + 1
	else
		e = { avg = ticks, n = 1 }
		ema[hash] = e
	end
	return e
end

--- Called when a train has finished unloading at the requester, before its manifest is cleared.
--- @param train Train
--- @return boolean slow the trip took more than SLOW_FACTOR times its item's average (the caller reports it)
--- @return string? hash the manifest's first item
--- @return uint? ticks the trip
--- @return number? avg the average it was judged against
function stats.record_delivery_complete(train)
	local tick = game.tick
	local s = get()
	local m = bucket(s.minute, MINUTE_SLOTS, MINUTE, tick)
	local h = bucket(s.hour, HOUR_SLOTS, HOUR, tick)
	m.deliveries = m.deliveries + 1
	h.deliveries = h.deliveries + 1
	local totals = s.totals
	totals.deliveries = totals.deliveries + 1
	local slow, slow_hash, slow_ticks, slow_avg = false, nil, nil, nil

	local manifest = train.manifest
	if manifest then
		local m_items, h_items = m.items, h.items
		for _, item in ipairs(manifest) do
			local hash = hash_item(item.name, item.quality)
			local count = item.count or 0
			m_items[hash] = (m_items[hash] or 0) + count
			h_items[hash] = (h_items[hash] or 0) + count
			totals.items = totals.items + count
		end
	end

	-- Trains already on a delivery when this version was installed have no dispatch tick.
	local dispatch_tick = train.dispatch_tick
	if dispatch_tick and dispatch_tick <= tick then
		local seconds = (tick - dispatch_tick) / 60
		m.cycle_sum = (m.cycle_sum or 0) + seconds
		m.cycle_n = (m.cycle_n or 0) + 1
		h.cycle_sum = (h.cycle_sum or 0) + seconds
		h.cycle_n = (h.cycle_n or 0) + 1
		local cycle = s.cycle
		local ema = cycle.ema_seconds
		cycle.ema_seconds = ema and (ema + EMA_ALPHA * (seconds - ema)) or seconds
		local ticks = tick - dispatch_tick
		local first = manifest and manifest[1]
		if first then
			local hash = hash_item(first.name, first.quality)
			local trips = s.trip_ema
			if not trips then
				trips = {}
				s.trip_ema = trips
			end
			local e = trips[hash]
			local avg = e and e.avg
			slow, slow_hash, slow_ticks, slow_avg = stats.is_slow(e, ticks), hash, ticks, avg
			stats.add_trip(trips, hash, ticks)
		end
	end
	train.dispatch_tick = nil
	return slow, slow_hash, slow_ticks, slow_avg
end

--- @class StatsWindow
--- @field minutes int
--- @field span_ticks uint time the buckets cover so far, for rates
--- @field partial boolean recording started inside the period, so span_ticks is shorter than the period
--- @field deliveries int
--- @field dispatches int
--- @field items {[string]: int} delivered amount per item hash
--- @field amount int all delivered amounts together
--- @field cycle_avg number? seconds from dispatch to unloaded
--- @field cycle_n int
--- @field wait_avg number? ticks from request start to dispatch
--- @field wait_n int
--- @field wait_max uint? ticks
--- @field slowest StatsBucket[] buckets with a fulfilled request, as they are; read only
--- @field slowest_minutes {[StatsBucket]: true} entries of `slowest` that are minute buckets in an hour-bucket period
--- @field min_available_by_network {[string]: int} fewest available trains per network during the period
--- @field no_train_failures int? requests that turned unserved for want of a train during the period; nil while
---   diagnostics are off, since only diagnostics count them

-- Merged per-item amounts of the closed buckets of a period, per period. Closed buckets never change (records go to
-- the current bucket), so this is valid until the current bucket rolls over. A pure function of storage.stats and the
-- tick, so a Lua state that rebuilds it after a load computes exactly what one that kept it holds.
--- @type {[int]: {stats: Stats, current: uint, items: {[string]: int}}}
local closed_items = {}

--- @param s Stats
--- @param minutes int
--- @param ring {[int]: StatsBucket}
--- @param oldest uint
--- @param current uint start tick of the current bucket of `ring`
--- @return {[string]: int}
local function closed_items_of(s, minutes, ring, oldest, current)
	local c = closed_items[minutes]
	if c and c.stats == s and c.current == current then return c.items end
	local items = {}
	for _, b in pairs(ring) do
		if b.start_tick >= oldest and b.start_tick < current then
			for hash, n in pairs(b.items) do
				items[hash] = (items[hash] or 0) + n
			end
		end
	end
	closed_items[minutes] = { stats = s, current = current, items = items }
	return items
end

--- The ring a period reads and its bucket range: minute buckets up to an hour, hour buckets beyond (rounded up to
--- whole hours, at most a day).
--- @param s Stats
--- @param minutes int
--- @param tick uint
--- @return {[int]: StatsBucket} ring
--- @return uint current start tick of the current bucket
--- @return uint oldest start tick of the period's oldest bucket
local function period(s, minutes, tick)
	local ring, width, count
	if minutes <= MINUTE_SLOTS then
		ring, width, count = s.minute, MINUTE, minutes
	else
		ring, width, count = s.hour, HOUR, math.min(math.ceil(minutes / 60), HOUR_SLOTS)
	end
	local current = tick - tick % width
	return ring, current, current - (count - 1) * width
end

--- Everything the Overview shows for one period: minute buckets for 10 and 60 minutes, hour buckets for longer
--- periods (rounded up to whole hours), the current partial bucket included. Per-item amounts of the closed buckets
--- are cached until the current bucket rolls over; the scalar sums are redone every call in ring order, so floating
--- point totals come out bit for bit the same as an uncached pass.
--- @param minutes int 10, 60 or 1440
--- @param summary boolean? only the sums (no per-item map, no slowest list)
--- @return StatsWindow
function stats.aggregate(minutes, summary)
	local s = get()
	local tick = game.tick
	local ring, current, oldest = period(s, minutes, tick)
	local since = s.totals.since_tick or 0
	local out = {
		minutes = minutes,
		span_ticks = tick - math.max(oldest, since) + 1,
		partial = since > oldest,
		deliveries = 0,
		dispatches = 0,
		items = {},
		amount = 0,
		cycle_n = 0,
		wait_n = 0,
		slowest = {},
		slowest_minutes = {},
		no_train_failures = storage.diag and 0 or nil,
	}
	local items = out.items
	-- The Overview reads the sums only: no per-item map and no slowest list for it (`summary`).
	if not summary then
		for hash, n in pairs(closed_items_of(s, minutes, ring, oldest, current)) do
			items[hash] = n
		end
	end
	local amount, cycle_sum, wait_sum, wait_max = 0, 0, 0, nil
	for _, b in pairs(ring) do
		if b.start_tick >= oldest and b.start_tick <= tick then
			out.deliveries = out.deliveries + b.deliveries
			out.dispatches = out.dispatches + b.dispatches
			if b.no_train_failures and out.no_train_failures then out.no_train_failures = out.no_train_failures + b.no_train_failures end
			local live = not summary and b.start_tick >= current
			for hash, n in pairs(b.items) do
				if live then items[hash] = (items[hash] or 0) + n end
				amount = amount + n
			end
			if b.cycle_n then
				cycle_sum = cycle_sum + b.cycle_sum
				out.cycle_n = out.cycle_n + b.cycle_n
			end
			if b.wait_n then
				wait_sum = wait_sum + b.wait_sum
				out.wait_n = out.wait_n + b.wait_n
				if not wait_max or b.wait_max > wait_max then wait_max = b.wait_max end
				if not summary then out.slowest[#out.slowest + 1] = b end
			end
		end
	end
	-- The current hour holds a single maximum until it closes, so a longer period would list fewer of the recent
	-- slow requests than a shorter one; its minute buckets stand in for it in the list (not in the sums).
	if ring == s.hour and not summary then
		local hour_start = tick - tick % HOUR
		local slowest, minutes = {}, out.slowest_minutes
		for _, b in ipairs(out.slowest) do
			if b.start_tick ~= hour_start then slowest[#slowest + 1] = b end
		end
		for _, b in pairs(s.minute) do
			if b.wait_n and b.start_tick >= hour_start and b.start_tick <= tick then
				slowest[#slowest + 1] = b
				minutes[b] = true
			end
		end
		out.slowest = slowest
	end
	out.amount = amount
	out.min_available_by_network = min_available(s, ring, oldest, tick)
	if out.cycle_n > 0 then out.cycle_avg = cycle_sum / out.cycle_n end
	if out.wait_n > 0 then out.wait_avg = wait_sum / out.wait_n end
	out.wait_max = wait_max
	return out
end

--- Fewest available trains per network over the last `minutes` (Overview Fleet headroom).
--- @param minutes int
--- @return {[string]: int}
function stats.min_available(minutes)
	local s = get()
	local tick = game.tick
	local ring, _, oldest = period(s, minutes, tick)
	return min_available(s, ring, oldest, tick)
end

return stats
