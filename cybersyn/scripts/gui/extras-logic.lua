-- Pure rules of the manager's extras and repair actions: no game API, so the host unit tests run them as they are.

local logic = {}

-- ---------------------------------------------------------------- path trace

--- Most line objects one trace may draw per render mode; the trace draws each segment twice (game and chart view),
--- so a player never holds more than 2 × this many objects.
logic.TRACE_SEGMENTS = 128
logic.TRACE_TICKS = 600

--- Whether b continues the straight line a→b→c: the turn at b is below about 1°. Rail centres of a straight run lie
--- exactly on one line; a curve or a diagonal change turns by at least 22.5° between neighbours.
--- @return boolean
local function collinear(ax, ay, bx, by, cx, cy)
	local ux, uy = bx - ax, by - ay
	local vx, vy = cx - bx, cy - by
	local dot = ux * vx + uy * vy
	if dot <= 0 then return false end
	local cross = ux * vy - uy * vx
	return cross * cross <= 0.0003 * (ux * ux + uy * uy) * (vx * vx + vy * vy)
end

--- Polyline vertices for a path of points: duplicates dropped, interior points of collinear runs dropped, then, if
--- still more than `max_segments` segments, exactly `max_segments` + 1 of them kept, evenly spread (the first and the
--- last always).
--- @param xs number[]
--- @param ys number[]
--- @param n int points to read from xs/ys
--- @param max_segments int?
--- @return number[] vx
--- @return number[] vy
--- @return int runs segments after the collinear merge, before any thinning
function logic.sample_runs(xs, ys, n, max_segments)
	max_segments = max_segments or logic.TRACE_SEGMENTS
	local px, py = {}, {}
	for i = 1, n do
		local x, y = xs[i], ys[i]
		local m = #px
		if m == 0 or px[m] ~= x or py[m] ~= y then
			px[m + 1], py[m + 1] = x, y
		end
	end
	local m = #px
	if m < 2 then return px, py, 0 end
	local vx, vy = { px[1] }, { py[1] }
	for i = 2, m - 1 do
		local k = #vx
		if not collinear(vx[k], vy[k], px[i], py[i], px[i + 1], py[i + 1]) then
			vx[k + 1], vy[k + 1] = px[i], py[i]
		end
	end
	vx[#vx + 1], vy[#vy + 1] = px[m], py[m]
	local runs = #vx - 1
	if runs <= max_segments then return vx, vy, runs end
	-- Evenly spread over the turning points, so the whole budget is used and no stretch loses all its corners.
	local tx, ty = {}, {}
	for k = 0, max_segments do
		local i = 1 + math.floor(k * runs / max_segments + 0.5)
		tx[k + 1], ty[k + 1] = vx[i], vy[i]
	end
	return tx, ty, runs
end

-- ---------------------------------------------------------------- confirm step

--- Ticks an armed action button waits for its second click, counted on the manager tick.
logic.CONFIRM_TICKS = 180

--- @class ConfirmState
--- @field key string the action and its target, e.g. "fail:12"
--- @field tick uint when the first click armed it

--- Ticks a click on an armed button still fires after its "Confirm?" was drawn back. A client's click is applied a few
--- ticks after the player saw the button (the multiplayer input latency), so a click on a "Confirm?" made just before
--- the redraw lands just after it.
logic.CONFIRM_GRACE = 30

--- A click on the button `key`: the first click arms it, a second click within CONFIRM_TICKS (+ CONFIRM_GRACE) fires
--- it. A click on another button arms that one instead (one armed button per player).
--- @param cur ConfirmState?
--- @param key string
--- @param now uint
--- @return ConfirmState? next state
--- @return boolean fire
function logic.confirm_click(cur, key, now)
	if cur and cur.key == key and now - cur.tick < logic.CONFIRM_TICKS + logic.CONFIRM_GRACE then return nil, true end
	return { key = key, tick = now }, false
end

--- @param cur ConfirmState?
--- @param key string
--- @param now uint
--- @return boolean
function logic.confirm_armed(cur, key, now)
	return cur ~= nil and cur.key == key and now - cur.tick < logic.CONFIRM_TICKS
end

--- @param cur ConfirmState?
--- @param now uint
--- @return boolean
function logic.confirm_expired(cur, now)
	return cur ~= nil and now - cur.tick >= logic.CONFIRM_TICKS
end

--- Past the grace too: the state can go.
--- @param cur ConfirmState?
--- @param now uint
--- @return boolean
function logic.confirm_gone(cur, now)
	return cur ~= nil and now - cur.tick >= logic.CONFIRM_TICKS + logic.CONFIRM_GRACE
end

-- ---------------------------------------------------------------- chunked job

--- Trains one manager update of the Refresh allow-lists job handles.
logic.JOB_CHUNK = 50

--- Stop visits one chunk may spend. A train whose layout no other train shares costs two walks over every station and
--- refueler in update_train_layout (the old layout dropped, the new one tested against every allow-list), so on a
--- large map a 50-train chunk of such trains would blow the update budget; other trains cost about nothing here.
logic.JOB_STOP_VISITS = 4096

--- The stop visits update_train_layout makes for one train.
--- @param singleton boolean no other train shares its layout
--- @param stops int stations + refuelers
--- @return int
function logic.job_cost(singleton, stops)
	return singleton and 2 * stops or 0
end

--- Whether a chunk that has handled `done` trains and spent `spent` stop visits may take one more train costing
--- `cost`. The first train of a chunk always runs, so the job advances whatever one train costs.
--- @param done int
--- @param spent int
--- @param cost int
--- @param chunk int? trains per chunk, default JOB_CHUNK
--- @param budget int? stop visits per chunk, default JOB_STOP_VISITS
--- @return boolean
function logic.job_continue(done, spent, cost, chunk, budget)
	if done == 0 then return true end
	if done >= (chunk or logic.JOB_CHUNK) then return false end
	return spent + cost <= (budget or logic.JOB_STOP_VISITS)
end

-- ---------------------------------------------------------------- HUD

--- The HUD's numbers from the live unserved entries per reason and the available trains per network. `headroom` is
--- the fewest available trains on any one network right now (shown as "free trains": the Overview's Fleet headroom
--- is a minimum over a period, a different number); a network in `networks` that never had an available train has no
--- counter and counts as 0. nil without any network.
--- @param counts {[int]: int} diag.counts_by_reason()
--- @param available {[string]: int} stats available_count
--- @param networks {[string]: int}? Cybersyn trains per network (stats trains_by_network)
--- @return {unserved: int, headroom: int?, network: string?, top_reason: int?, top_count: int}
function logic.hud_values(counts, available, networks)
	local total, top, top_n = 0, nil, 0
	for reason, n in pairs(counts) do
		total = total + n
		if n > top_n or (n == top_n and top and reason < top) then top, top_n = reason, n end
	end
	local headroom, network
	local function consider(name, n)
		if not headroom or n < headroom or (n == headroom and name < network) then headroom, network = n, name end
	end
	for name, n in pairs(available) do consider(name, n) end
	for name in pairs(networks or {}) do
		if available[name] == nil then consider(name, 0) end
	end
	return { unserved = total, headroom = headroom, network = network, top_reason = top, top_count = top_n }
end

-- ---------------------------------------------------------------- Recount deliveries

local P_SIDE = { [STATUS_TO_P] = true, [STATUS_P] = true }
local R_SIDE = STATUS_ON_DELIVERY

--- A station's delivery counters as the dispatcher's own bookkeeping would hold them, from the trains bound to it:
--- create_delivery counts a train at both stations and adds the manifest to the requester's `deliveries` and
--- subtracts it from the provider's; leaving the provider undoes the provider side, leaving the requester the
--- requester side. So the provider side counts TO_P/P trains and the requester side TO_P..R trains, the same rule
--- the lint pass's occupancy index uses. Two limits, shared with the lint: a train under a custom status (>=
--- STATUS_CUSTOM, other mods') is not counted, and a net-zero amount (one train at both ends of the station) is dropped
--- where create_delivery would keep a 0 entry; remove_manifest then skips that key, which is harmless.
--- @param trains {[uint]: {status: int?, p_station_id: uint?, r_station_id: uint?, manifest: {name: string, quality: string?, count: int}[]?}}
--- @param station_id uint
--- @param hash fun(name: string, quality: string?): string
--- @return int total
--- @return {[string]: int} deliveries without zero entries
--- @return uint[] train ids counted, ascending
function logic.recount(trains, station_id, hash)
	local total, deliveries, ids = 0, {}, {}
	for id, train in pairs(trains) do
		local status = train.status
		local p = P_SIDE[status] and train.p_station_id == station_id
		local r = R_SIDE[status] and train.r_station_id == station_id
		if p or r then
			ids[#ids + 1] = id
			for _, item in ipairs(train.manifest or {}) do
				local h = hash(item.name, item.quality)
				local n = deliveries[h] or 0
				if p then n = n - item.count end
				if r then n = n + item.count end
				deliveries[h] = n
			end
			total = total + (p and 1 or 0) + (r and 1 or 0)
		end
	end
	for h, n in pairs(deliveries) do
		if n == 0 then deliveries[h] = nil end
	end
	table.sort(ids)
	return total, deliveries, ids
end

--- Whether a phantom finding is the counter-leak direction (the station counts more deliveries than trains are
--- bound to it), the one case "Recount deliveries" repairs; the other direction has a train to send home.
--- @param f {check: int, a: int?, b: int?}
--- @return boolean
function logic.is_counter_leak(f)
	return f.check == LINT_PHANTOM and (f.a or 0) > (f.b or 0)
end

-- ---------------------------------------------------------------- stop panel on narrow screens

-- The vanilla train-stop window and the 300 px panel beside it, in logical px. Factorio exposes no anchored window's
-- size, so the 1067 is measured (Factorio 2.1.23, UI scale 1); re-measure when the vanilla train-stop window changes.
logic.STOP_WINDOW_WIDTH = 1067
logic.STOP_PANEL_WIDTH = 300

--- Whether the stop panel fits beside the vanilla window on this screen. Where it does not, the panel is hidden
--- rather than drawn over or off the screen; "Open in manager" is the route there.
--- @param width number physical px
--- @param scale number UI scale
--- @return boolean
function logic.stop_panel_fits(width, scale)
	return width / scale >= logic.STOP_WINDOW_WIDTH + logic.STOP_PANEL_WIDTH
end

-- ---------------------------------------------------------------- train panel beside the docked locomotive pane

-- The remote view's docked locomotive pane (measured on Factorio 2.1.23 with connected clients; re-measure when the
-- vanilla pane changes): its top is below the 40 px "Remote
-- view" title bar; its right edge is at 452 logical px while its Fuel tab is disabled ("Locomotive is out of reach":
-- the window opened from the character), and further right when the Fuel tab is enabled (opened while already in
-- remote view) and its "Ghost cursor selection" needs more room: one 71 px tab per item group with an item unlocked
-- for the force, select_group_row_count (utility constant, 6 in base, up to 100 with large overhauls) tabs per row,
-- 28 px of margins and borders around the row; a tabbed pane is as wide as its widest tab. Each tab is floored to
-- whole physical px.
logic.TRAIN_PANE_NARROW = 452
logic.TRAIN_PANE_TOP = 40
logic.GROUP_TAB = 71
logic.GROUP_ROW_CHROME = 28
-- The stop panel, a relative GUI right of the train-stop window, touches that window and shares its top (measured
-- at 4K/1.5): the train panel mirrors it.
logic.TRAIN_PANEL_GAP = 0
-- The panel's frame: 300 px panel, 2 × 8 padding and the border.
logic.TRAIN_FRAME_WIDTH = 324
-- Subheader, footer and paddings around the scroll body (135 measured, plus room for a taller footer row); and the
-- room left below the frame for the hotbar, which a panel beside a wide pane overlaps in x (its top is 105 logical px
-- above the bottom at 1080p/1.0).
logic.TRAIN_PANEL_CHROME = 150
logic.TRAIN_PANEL_BOTTOM = 110
logic.TRAIN_BODY_MIN = 120
-- The dispatcher-paused banner above the subheader: cybersyn_banner_frame's fixed height (cybersyn_tab_subheader),
-- not part of the 135 measured with the planner running.
logic.TRAIN_PANEL_BANNER = 36

--- The docked locomotive pane's right edge in physical px from the screen's left edge.
--- @param narrow boolean the Fuel tab is disabled
--- @param groups int item groups the Fuel tab's ghost cursor selection shows (0: no Fuel tab)
--- @param row_count int group tabs per row (utility constant select_group_row_count)
--- @param scale number UI scale
--- @return int
function logic.train_pane_right(narrow, groups, row_count, scale)
	local edge = math.floor(logic.TRAIN_PANE_NARROW * scale + 0.5)
	if narrow or groups <= 0 then return edge end
	local columns = math.min(groups, math.max(1, row_count))
	return math.max(edge, math.floor(logic.GROUP_ROW_CHROME * scale) + columns * math.floor(logic.GROUP_TAB * scale))
end

--- Where the train panel's frame goes: flush right of the docked pane at its top, kept on the screen.
--- @param pane_right int physical px (train_pane_right)
--- @param scale number UI scale
--- @param width number screen width, physical px
--- @return int x physical px
--- @return int y physical px
function logic.train_panel_place(pane_right, scale, width)
	local x = pane_right + math.floor(logic.TRAIN_PANEL_GAP * scale)
	x = math.max(0, math.min(x, width - math.floor(logic.TRAIN_FRAME_WIDTH * scale)))
	return x, math.floor(logic.TRAIN_PANE_TOP * scale + 0.5)
end

--- The train panel's scroll body cap, in logical px: the frame stays above the hotbar.
--- @param height number screen height, physical px
--- @param scale number UI scale
--- @param banner number? logical px of the paused banner while it shows (TRAIN_PANEL_BANNER), 0 or nil otherwise
--- @return int
function logic.train_body_cap(height, scale, banner)
	local free = math.floor(height / scale) - logic.TRAIN_PANE_TOP - logic.TRAIN_PANEL_CHROME - logic.TRAIN_PANEL_BOTTOM
		- (banner or 0)
	return math.max(logic.TRAIN_BODY_MIN, free)
end

return logic
