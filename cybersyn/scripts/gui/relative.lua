-- Cybersyn panels beside the vanilla train-stop and train windows. One builder, relative.build, makes
-- the panel anywhere (the in-window Trains detail pane mounts it too); relative.open mounts it beside the
-- vanilla window (see "mounting") once per player and kind, and only shows it for a Cybersyn stop or train. While a panel is open it is refreshed on the manager tick: each section is rebuilt only when
-- its signature changes, and ages are rounded to 10 s so an idle panel rebuilds nothing.
--
-- Data: the manager snapshot's station record while a manager window keeps one; otherwise one read of this stop's
-- planner state per refresh (collector.read_station). The fleet counts of the Effective config section come from
-- a walk over storage.trains in chunks, only while that section is open.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local links = require("scripts.gui.utils.links")
local nav = require("scripts.gui.utils.nav")
local rich_text = require("scripts.gui.rich-text")
local collector = require("scripts.gui.collector")
local manager = require("scripts.gui.manager")
local trains_tab = require("scripts.gui.trains")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local utext = require("scripts.gui.unserved-text")
local rtext = require("scripts.gui.relative-text")
local pm = require("scripts.gui.problems-model")
local item_model = require("scripts.gui.item-model")
local lint_text = require("scripts.gui.lint-text")
local extras = require("scripts.gui.extras")
local repair = require("scripts.gui.repair")
local logic = require("scripts.gui.tab-logic")
local xlogic = require("scripts.gui.extras-logic")

local relative = {}

local WIDTH = 300
local PADDING = 12
-- Inside the body's padding, leaving room for the scroll bar a tall panel gets (relative.fit).
local INNER = WIDTH - 2 * PADDING - 12
-- An unserved row: item 28, the chip, stock and wait, 6 px apart; the chip takes what the numbers leave. The numbers
-- are in the small font: "≥59m 50s" and "≥23h 59m" are 61-62 px in the default one, which would leave the chip too
-- little for "Requester full" or "Train too small" (the tooltip repeats both numbers).
local UNSERVED_STOCK, UNSERVED_WAIT, UNSERVED_GAP = 56, 56, 6
local UNSERVED_FONT = "default-small"
local UNSERVED_CHIP = INNER - 28 - UNSERVED_STOCK - UNSERVED_WAIT - 3 * UNSERVED_GAP
-- One mount per window the panel sits beside: the stop's, the locomotive's (the docked train pane: a screen frame) and
-- each wagon's own window (anchored to it).
local MOUNT = { stop = "cybersyn_relative_stop", train = "cybersyn_relative_train", cargo = "cybersyn_relative_cargo" }
local PANEL = "cybersyn_relative_panel"
local EVENTS = 10
-- Rows of the stop's event list while the Effective config is expanded, so the panel fits a 1080p screen at scale 1.
local EVENTS_COMPACT = 4
local SLOT_COLUMNS = 7
local SLOT_ROWS = 3
local UNSERVED_ROWS = 3
local EFFECTIVE_ITEMS = 6
-- Trains of storage.trains the Effective config walk counts per refresh (about 2.5 µs each on a 2,000-station base),
-- how many the render of a click or an opened window counts at once, and how long a finished count is used.
local FLEET_CHUNK = 15
local FLEET_BURST = 600
local FLEET_TTL = 7200
-- While no manager window keeps a snapshot, the stop is read again at most this often: a read of a big multi-requester
-- (combinators and secondaries) is most of a refresh's cost, and the planner itself polls a stop less often.
local LIVE_READ_TICKS = 120
-- Ring rows the "Last events" scan examines per refresh after the first (diag.last_for_step): about 0.31 µs each
-- inside the real tick on a 2,000-station base's full rings, so 0.05 ms beside the rest of the panel's 0.06-0.09 ms
-- (live reads with the window closed, when the scan takes half). At 256 the p90 of a refresh was 0.21-0.30 ms. A stop
-- with few events (most of a big base) is scanned through both full rings (20k rows) in about 125 refreshes (250 with
-- the window closed), "Scanning…" until then.
local EVENT_SCAN_ROWS = 160
local WAIT_SIGNAL = defines.train_state.wait_signal

relative.WIDTH = WIDTH
relative.FLEET_CHUNK = FLEET_CHUNK

local STOP_SECTIONS = { "head", "slots", "unserved", "deliveries", "control", "setup", "effective", "events", "buttons" }
local TRAIN_SECTIONS = { "head", "alert", "manifest", "route", "schedule", "signal", "events", "buttons" }

local STATUS_COLOR, status_key = logic.STATUS_COLOR, logic.status_key

local ROLLING_STOCK = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true }

local STATE_NAMES = {}
for name, v in pairs(defines.train_state) do STATE_NAMES[v] = name end


local TRAIN_STATUS_KEY = {
	[STATUS_D] = "cybersyn-gui.parked-at-depot",
	[STATUS_TO_P] = "cybersyn-gui.fetching-from",
	[STATUS_P] = "cybersyn-gui.loading-at",
	[STATUS_TO_R] = "cybersyn-gui.delivering-to",
	[STATUS_R] = "cybersyn-gui.unloading-at",
	[STATUS_TO_D] = "cybersyn-gui.returning-to-depot",
	[STATUS_TO_D_BYPASS] = "cybersyn-gui.returning-to-depot",
	[STATUS_TO_F] = "cybersyn-gui.trains-going-to-refuel",
	[STATUS_F] = "cybersyn-gui.trains-refuelling",
}

local S_COLOUR = { cyan = "0.4,0.9,1", green = "0.3,1,0.3", red = "1,0.35,0.35" }

relative.handle = {}

-- ---------------------------------------------------------------- small helpers

local function short_age(ticks)
	return logic.short_duration(rtext.age_step(ticks))
end

local function label(caption, extra)
	local def = { type = "label", caption = caption }
	if extra then
		for k, v in pairs(extra) do def[k] = v end
	end
	return def
end

--- A label that wraps inside the panel.
local function line(caption, tooltip, color)
	return {
		type = "label",
		caption = caption,
		tooltip = tooltip,
		style_mods = { single_line = false, maximal_width = INNER, font_color = color },
	}
end

-- The head's label column ("Role", "Network", "Status"): labels carry no colon, the column sets them apart.
local FIELD_LABEL = 64

--- A label / value row of the panel head; `key` nil continues the row above (a second network).
--- @param key string? locale key of the label
--- @param value LocalisedString
--- @param tooltip LocalisedString?
local function field(key, value, tooltip)
	return {
		type = "flow",
		direction = "horizontal",
		style_mods = { horizontal_spacing = 8 },
		{ type = "label", caption = key and { key } or "", style_mods = { width = FIELD_LABEL, font_color = { 0.65, 0.65, 0.65 } } },
		{ type = "label", caption = value, tooltip = tooltip,
			style_mods = { single_line = false, maximal_width = INNER - FIELD_LABEL - 8 } },
	}
end

local function note(caption, tooltip)
	return line(caption, tooltip, { 0.65, 0.65, 0.65 })
end

local function heading(caption)
	return { type = "label", style = "caption_label", caption = caption }
end

local function network_rich(name)
	if not name then return { "cybersyn-gui.station-no-network" } end
	if name == NETWORK_EACH then return { "cybersyn-gui.network-each" } end
	local icon = rich_text.network_icon(name)
	if icon == name then return name end
	return icon .. " " .. name
end

--- Networks of a station or refueler as {name, mask} pairs, in a stable order.
local function networks_of(network_name, network_mask)
	local out = {}
	each_network(network_name, network_mask, function(name, mask) out[#out + 1] = { name = name, mask = mask } end)
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

local HEAD_NETWORKS = 12

--- "[A]1 · [A]3 · [B]4": the distinct networks and masks the station's combinators advertise on, for the head.
--- @param nets {name: string, mask: int}[] rtext.row_networks
local function networks_caption(nets)
	local parts = {}
	for i = 1, math.min(#nets, HEAD_NETWORKS) do
		parts[i] = rich_text.network_icon_with(nets[i].name, collector.mask_label(nets[i].mask))
	end
	local caption = table.concat(parts, " · ")
	if #nets > HEAD_NETWORKS then caption = caption .. " +" .. (#nets - HEAD_NETWORKS) end
	return caption
end

local function stop_name(kind, id)
	local record
	if kind == "station" then
		record = storage.stations[id]
	elseif kind == "depot" then
		record = storage.depots[id]
	elseif kind == "refueler" then
		record = storage.refuelers[id]
	end
	local stop = record and record.entity_stop
	return stop and stop.valid and stop.backer_name or nil
end

--- A link cell to a station, depot or refueler (links.handle_link_click semantics).
local function stop_link(kind, id, max_width)
	local name = id and stop_name(kind, id)
	return {
		type = "button",
		style = "cybersyn_link_button",
		style_mods = { maximal_width = max_width or INNER, height = 24 },
		caption = name or utext.NO_VALUE,
		enabled = name ~= nil,
		tooltip = name and { "", "[font=default-semibold]", name, "[/font]\n", links.LINK_FOOTER } or nil,
		tags = name and { kind = kind, id = id } or {},
		mouse_button_filter = { "left" },
		handler = { [defines.events.on_gui_click] = links.handle.link_click },
	}
end

--- @param station uint? the stop panel's station: a click also sets the station chip, shift leaves it off
--- @param flight true? an in-flight slot: the click lands on the Trains tab
local function slot(hash, count, color, tooltip, station, flight)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	-- The engine shows the custom tooltip next to the item's own (elem_tooltip), so the hint needs no item text.
	local hint = station and { flight and "cybersyn-gui.relative-flight-slot-hint" or "cybersyn-gui.relative-slot-hint" }
	return {
		type = "sprite-button",
		sprite = sprite,
		quality = quality,
		style = "ltnm_small_slot_button_" .. color,
		tooltip = hint and { "", name_tooltip, tooltip, "\n", hint } or { "", name_tooltip, tooltip },
		elem_tooltip = util.elem_tooltip(hash),
		tags = { kind = "item", id = hash, station = station, flight = flight },
		-- Right-click clears the manager's item filter, which a stop panel does not show.
		mouse_button_filter = station and { "left" } or { "left", "right" },
		handler = { [defines.events.on_gui_click] = links.handle.link_click },
		{
			type = "label",
			style = "ltnm_label_signal_count",
			ignored_by_interaction = true,
			caption = format_signal_count(count),
		},
	}
end

--- A slot table of at most SLOT_ROWS rows, with "+n more" below when it overflows.
local function slot_table(slots, total, columns)
	columns = columns or SLOT_COLUMNS
	local tbl = {
		type = "frame",
		style = "ltnm_small_slot_table_frame_light",
		{ type = "table", style = "slot_table", column_count = columns },
	}
	local cap = columns * SLOT_ROWS
	for i = 1, math.min(#slots, cap) do tbl[1][#tbl[1] + 1] = slots[i] end
	local out = { tbl }
	if total > cap then out[2] = note({ "cybersyn-gui.relative-more", tostring(total - cap) }) end
	return out
end

local function sev_color(sev)
	if sev == DIAG_SEV_ERROR then return { 1, 0.45, 0.4 } end
	if sev == DIAG_SEV_WARNING then return { 1, 0.78, 0.45 } end
	return nil
end

-- ---------------------------------------------------------------- builder

--- The panel: a 300 px inside_shallow_frame with the dispatcher-paused banner, a subheader captioned "Cybersyn" and
--- one empty flow per section, which relative.refresh fills. Mountable anywhere.
--- @param parent LuaGuiElement
--- @param kind "stop"|"train"
--- @param id uint?
--- @return LuaGuiElement panel
function relative.build(parent, kind, id)
	local sections = kind == "train" and TRAIN_SECTIONS or STOP_SECTIONS
	local body = {
		type = "flow",
		name = "body",
		direction = "vertical",
		style_mods = { padding = PADDING, vertical_spacing = 8 },
	}
	for _, name in ipairs(sections) do
		if name == "buttons" then break end
		body[#body + 1] = {
			type = "flow",
			name = name,
			direction = "vertical",
			visible = false,
			style_mods = { vertical_spacing = 4, maximal_width = INNER },
		}
	end
	local _, panel = gui.add(parent, {
		type = "frame",
		name = PANEL,
		style = "inside_shallow_frame",
		direction = "vertical",
		style_mods = { width = WIDTH },
		tags = { kind = kind, id = id },
		{
			type = "frame",
			name = "banner",
			style = "cybersyn_banner_frame",
			visible = false,
			{ type = "label", name = "banner_label", style = "cybersyn_banner_label" },
		},
		{
			type = "frame",
			name = "subheader",
			style = "subheader_frame",
			style_mods = { horizontally_stretchable = true },
			{ type = "label", name = "caption_label", style = "subheader_caption_label", caption = { "cybersyn-gui.relative-caption" } },
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{
				type = "sprite-button",
				name = "effective_button",
				style = "tool_button",
				sprite = "utility/expand",
				visible = kind == "stop",
				tooltip = { "cybersyn-gui.relative-effective-tooltip" },
				handler = { [defines.events.on_gui_click] = relative.handle.relative_toggle_effective },
			},
		},
		{
			type = "scroll-pane",
			name = "scroll",
			style = "flib_naked_scroll_pane_no_padding",
			horizontal_scroll_policy = "never",
			vertical_scroll_policy = "auto",
			body,
		},
		-- Outside the scroll pane, so the buttons stay in view however far the body scrolls.
		{
			type = "flow",
			name = "footer",
			direction = "vertical",
			style_mods = { left_padding = PADDING, right_padding = PADDING, top_padding = 4, bottom_padding = PADDING,
				maximal_width = WIDTH },
			{ type = "flow", name = "buttons", direction = "vertical", visible = false, style_mods = { maximal_width = INNER } },
		},
	})
	return panel
end

-- ---------------------------------------------------------------- state

--- @class RelativeState per player, for the open panel; plain data
--- @field kind "stop"|"train"
--- @field id uint
--- @field sigs {[string]: string}
--- @field rebuilds int sections rebuilt since the panel opened
--- @field st SnapshotStation? the live record while no snapshot holds this station (never a snapshot record)
--- @field starved {[string]: true} this station's request keys nobody provides, from the planner's economy
--- @field cursor DiagScanCursor?
--- @field fleet {key: string, ids: uint[], i: int, counts: {[string]: RelativeFleetCount}, done_tick: uint?}?
--- @field schedule {records: table[], tick: uint}?
--- @field slots_last {r: string, d: string, sig: string}? the parts of the slots signature last built

local function new_state(kind, id)
	return { kind = kind, id = id, sigs = {}, ages = {}, rebuilds = 0, starved = {} }
end

local function hidden() return nil end

--- Rebuilds one section when its signature changed; `build` returns its children (nil or empty = hidden). Callers
--- compare the signature first, so a section that did not change allocates no builder closure.
local function section(state, body, name, sig, build)
	if state.sigs[name] == sig then return end
	local flow = body[name]
	if not (flow and flow.valid) then return end
	state.sigs[name] = sig
	flow.clear()
	local defs = build()
	local shown = defs ~= nil and #defs > 0
	if shown then
		for _, def in ipairs(defs) do
			if def then gui.add(flow, def) end
		end
	end
	if flow.visible ~= shown then flow.visible = shown end
	state.rebuilds = state.rebuilds + 1
end

-- ---------------------------------------------------------------- stop model

--- This station's active request keys nobody on its networks provides, each combinator's requests on that
--- combinator's own networks (collector.station_status then marks each row's starved set). With diagnostics on, from
--- the reason the dispatcher recorded (NO_PROVIDER); else from the starved set the planner published.
--- @return boolean updated
local function update_starved(state, st)
	if not st then return false end
	local d = storage.diag
	if d then
		local starved = {}
		local by_item = d.unserved[st.id]
		if by_item then
			local rows = collector.inventories(st)
			for ix, e in pairs(by_item) do
				if e.reason == REASON_NO_PROVIDER then
					local hash = d.item_hash[ix]
					if hash then
						for _, row in ipairs(rows) do
							local req = row.requested[hash]
							if req and req.active then
								if row.networks then
									for net in pairs(row.networks) do starved[net .. ":" .. hash] = true end
								elseif row.network_name and row.network_name ~= NETWORK_EACH then
									starved[row.network_name .. ":" .. hash] = true
								end
							end
						end
					end
				end
			end
		end
		state.starved = starved
		return true
	end
	-- The collector scans each row on its own networks; a record without rows names the station's.
	state.starved = collector.economy_starved(st, not st.rows and networks_of(st.network_name, st.network_mask) or nil)
	return true
end

local function same_values(a, b)
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function same_requests(a, b)
	for k, r in pairs(a) do
		local o = b[k]
		if not o or o.count ~= r.count or o.threshold ~= r.threshold or o.active ~= r.active then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

--- Whether two live reads of one stop hold the same values for everything the panel shows.
local function same_record(a, b)
	if a.status ~= b.status or a.trains_limit ~= b.trains_limit or a.deliveries_total ~= b.deliveries_total or
		a.network_name ~= b.network_name or a.is_p ~= b.is_p or a.is_r ~= b.is_r or a.is_stack ~= b.is_stack then
		return false
	end
	local ma, mb = a.network_mask, b.network_mask
	if type(ma) == "table" and type(mb) == "table" then
		if not same_values(ma, mb) then return false end
	elseif ma ~= mb then
		return false
	end
	return same_values(a.provided, b.provided) and same_requests(a.requested, b.requested) and
		same_values(a.deliveries, b.deliveries) and same_values(a.control, b.control) and
		same_values(a.control2, b.control2) and same_values(a.thresholds, b.thresholds) and
		a.rows_sig == b.rows_sig
end

--- Whether this refresh rewrites the unserved rows' ages in place (render_unserved): the live read and a fleet walk
--- chunk wait for the next refresh then, so no refresh pays for two of them.
local function age_due(state, now)
	local a = state.ages.unserved
	return a ~= nil and a ~= math.floor(now / rtext.AGE_STEP)
end

--- The station record the panel shows: the manager snapshot's while a window keeps it current, else a live read of
--- the stop (a snapshot kept after the last close is up to collector.KEEP_TICKS old).
--- @return SnapshotStation?
--- @return "snapshot"|"live"
local function station_record(state, id)
	local snap = collector.live()
	local st = snap and snap.stations[id]
	if st then
		state.st, state.spare, state.read = nil, nil, false
		return st, "snapshot"
	end
	local cur = state.st
	if cur and cur.id == id then
		local age = game.tick - cur.read_tick
		if age < LIVE_READ_TICKS or (age < 2 * LIVE_READ_TICKS and age_due(state, game.tick)) then
			state.read = false
			return cur, "live"
		end
	end
	-- Two records take turns, so an unchanged read keeps the previous one's content key and every section's cached
	-- signature (record_sig) still applies.
	st = collector.read_station(id, state.spare, state.starved)
	state.read = true
	if not st then return nil, "live" end
	if update_starved(state, st) then st.status = collector.station_status(st, state.starved) end
	-- Built once per read: same_record compares it, and render_slots reuses it as its signature.
	st.rows_sig = rtext.rows_content(st)
	if cur and cur.id == id and cur.sig_key and same_record(cur, st) then
		st.sig_key = cur.sig_key
	else
		state.live_version = (state.live_version or 0) + 1
		st.sig_key = -state.live_version
	end
	state.spare, state.st = cur, st
	return st, "live"
end

--- The stop's findings of the last lint pass, looked up again only when a pass completed.
local function lint_findings_of(state, id, pass)
	local cached = state.findings
	if cached and cached.pass == pass and cached.id == id then return cached.list end
	local out = {}
	for _, f in ipairs(lint.findings()) do
		if f.id == id and f.subject ~= LINT_SUBJECT_TRAIN then out[#out + 1] = f end
	end
	state.findings = { pass = pass, id = id, list = out }
	return out
end

local NO_ROWS = {}

--- Unserved entries of a requester, oldest first; sorted again only when the set of entries changed.
local function unserved_rows(state, id)
	local by_item = diag.unserved_for(id)
	if not by_item then
		state.urows = nil
		return NO_ROWS
	end
	local n, first, ixs = 0, 0, 0
	for ix, e in pairs(by_item) do
		n, first, ixs = n + 1, first + e.first_tick, ixs + ix
	end
	local c = state.urows
	if c and c.n == n and c.first == first and c.ixs == ixs then
		local ok = true
		for _, r in ipairs(c.rows) do
			local e = by_item[r.ix]
			if not e then
				ok = false
				break
			end
			r.e = e
		end
		if ok then return c.rows end
	end
	local rows = {}
	state.urows = { n = n, first = first, ixs = ixs, rows = rows }
	for ix, e in pairs(by_item) do
		local hash = diag.item_hash(ix)
		if hash then rows[#rows + 1] = { ix = ix, hash = hash, e = e } end
	end
	table.sort(rows, function(a, b)
		if a.e.first_tick ~= b.e.first_tick then return a.e.first_tick < b.e.first_tick end
		return a.ix < b.ix
	end)
	return rows
end

--- Item maps fold into weighted sums for their signatures: each item weighs its crafting-order rank (distinct per
--- item and quality), so a change of any count or of the item set changes the sums; building a string per item cost
--- a live read's refresh 20-40 µs on a 10-item requester. A checksum, not an exact signature: different maps can
--- collide (counts 1,3,1 and 2,1,2 on ranks 1,2,3; two items outside item_order, which share one rank, trading
--- amounts) and leave a section stale until something else changes. Do not use it where an exact comparison matters.
--- @return string
local function content_sig(n, a, b, c)
	return string.format("%d:%.17g:%.17g:%.17g", n, a, b, c)
end

--- A signature over a station record's contents, computed again only when the record was refilled (a snapshot
--- record changes once per collector pass; walking a big requester's items every refresh cost more than the rest).
--- @param fn fun(st: SnapshotStation, arg: any): string
--- @return string
local function record_sig(state, name, st, fn, arg)
	local cache = state.rsig
	if not cache then
		cache = {}
		state.rsig = cache
	end
	-- A snapshot record changes once per pass (read_tick); a live record carries its content key (station_record).
	local key = st.sig_key or st.read_tick
	local e = cache[name]
	if e and e.tick == key and e.id == st.id and e.arg == arg then return e.sig end
	local sig = fn(st, arg)
	cache[name] = { tick = key, id = st.id, sig = sig, arg = arg }
	return sig
end

local function deliveries_content(st, total)
	local n, a, b = 0, 0, 0
	for hash, count in pairs(st.deliveries) do
		local r = util.item_rank(hash)
		n, a, b = n + 1, a + r, b + count * r
	end
	return content_sig(n, a, b, total)
end

local function control_content(st)
	local parts = {}
	for name, count in pairs(st.control) do parts[#parts + 1] = name .. "=" .. count end
	parts[#parts + 1] = "|"
	for hash, v in pairs(st.thresholds) do parts[#parts + 1] = hash .. "=" .. v end
	return table.concat(parts, ",")
end

local function eff_inputs_content(st)
	local parts = { st.trains_limit, st.control[REQUEST_THRESHOLD] or "", st.control[REQUEST_FLUID_THRESHOLD] or "",
		st.control[SIGNAL_PRIORITY] or "" }
	for hash, req in pairs(st.requested) do parts[#parts + 1] = hash .. "=" .. req.threshold end
	return table.concat(parts, ",")
end

--- The fleet counts for this stop's networks: a walk over storage.trains, FLEET_CHUNK trains per refresh, restarted
--- once a finished count is FLEET_TTL old or the stop's networks changed.
--- @return {[string]: RelativeFleetCount}? counts nil while the first walk runs
--- @return number progress 0..1
local function fleet_counts(state, nets, key)
	local now = game.tick
	local f = state.fleet
	if not f or f.key ~= key or (f.done_tick and now - f.done_tick >= FLEET_TTL) then
		local ids = {}
		for tid in pairs(storage.trains) do ids[#ids + 1] = tid end
		local counts = {}
		for _, n in ipairs(nets) do counts[n.name] = rtext.new_fleet_count(n.mask) end
		local result = f and f.key == key and f.result or nil
		f = { key = key, ids = ids, i = 0, counts = counts, result = result }
		state.fleet = f
	end
	if not f.done_tick and (state.burst or not (state.read or age_due(state, now))) then
		local ids, trains = f.ids, storage.trains
		local stop = math.min(#ids, f.i + (state.burst and FLEET_BURST or FLEET_CHUNK))
		for i = f.i + 1, stop do
			-- Only Cybersyn's own fields: a destroyed train leaves storage.trains in the event that destroys it.
			local train = trains[ids[i]]
			if train then rtext.count_train(f.counts, train) end
		end
		f.i = stop
		if stop >= #ids then
			f.done_tick = now
			f.result = f.counts
			f.ids = nil
		end
	end
	return f.result, #(f.ids or {}) > 0 and f.i / #f.ids or 1
end

--- The Effective config numbers. The fleet numbers come from the panel's own walk, train by
--- train: snapshot.fleet.capability ORs the masks of a layout's trains, which cannot tell how many of them match.
local function build_effective(state, st, station, nets, counts, progress)
	local snap = collector.live()
	local control = st.control
	local m = {
		base_item = control[REQUEST_THRESHOLD] and math.abs(control[REQUEST_THRESHOLD]) or (mod_settings.r_threshold or 1),
		base_item_signal = control[REQUEST_THRESHOLD] ~= nil,
		limit = st.trains_limit,
		priority = control[SIGNAL_PRIORITY] or mod_settings.priority or 0,
		s_colour = rtext.s_colour(station.display_state),
		counting = counts == nil and progress or nil,
		nets = {},
		items = {},
		-- The providers' own item thresholds are a pass aggregate of the snapshot; a live read has none.
		overrides_known = snap ~= nil,
	}
	if control[REQUEST_FLUID_THRESHOLD] then
		m.base_fluid, m.base_fluid_signal = math.abs(control[REQUEST_FLUID_THRESHOLD]), true
	elseif (mod_settings.r_fluid_threshold or 0) > 0 then
		m.base_fluid = mod_settings.r_fluid_threshold
	else
		m.base_fluid = m.base_item
	end
	local allows_all = station.allows_all_trains == true
	local accepted = station.accepted_layouts or {}
	local best_items, best_fluid = 0, 0
	for _, net in ipairs(nets) do
		local c = counts and counts[net.name]
		local eligible, items, fluid = rtext.eligible(c, allows_all, accepted)
		local n_accepted, _, missing = rtext.allow_list(accepted, allows_all, c)
		m.nets[#m.nets + 1] = {
			name = net.name,
			mask = net.mask,
			trains = c and c.trains or nil,
			depots = c and c.depots or nil,
			eligible = eligible,
			item_capacity = items,
			fluid_capacity = fluid,
			accepted = n_accepted,
			allow_trains = eligible,
			missing = missing,
			known = c ~= nil,
		}
		if items > best_items then best_items = items end
		if fluid > best_fluid then best_fluid = fluid end
	end
	m.item_capacity, m.fluid_capacity = best_items, best_fluid
	local entries = diag.unserved_for(st.id)
	local list = util.hashes_in_item_order(st.requested)
	local warned = 0
	-- Items with a threshold of their own on the control combinator take its priority signal, as tick_dispatch does.
	local item_priorities, n_item_priorities = {}, 0
	for i = 1, #list do
		local hash = list[i]
		local req = st.requested[hash]
		local name = unhash_signal(hash)
		local is_fluid = prototypes.fluid[name] ~= nil
		local override
		for _, net in ipairs(nets) do
			local o = snap and snap.provider_overrides and snap.provider_overrides[net.name .. ":" .. hash]
			if o and (not override or o < override) then override = o end
		end
		local effective, overridden = rtext.effective_threshold(req.threshold, override)
		local stack = not is_fluid and (get_stack_size(nil, name) or 1) or nil
		local need = is_fluid and effective or rtext.stacks(effective, stack)
		local capacity = is_fluid and best_fluid or best_items
		local warn = capacity > 0 and need >= capacity
		if warn then warned = warned + 1 end
		local prior = item_model.effective_priority(st, hash, SIGNAL_PRIORITY)
		if prior ~= (st.priority or 0) and n_item_priorities < EFFECTIVE_ITEMS then
			n_item_priorities = n_item_priorities + 1
			item_priorities[n_item_priorities] = { hash = hash, priority = prior }
		end
		if i <= EFFECTIVE_ITEMS then
			local e
			local ix = entries and storage.diag and storage.diag.item_ix[hash]
			if ix then e = entries[ix] end
			m.items[#m.items + 1] = {
				hash = hash,
				threshold = req.threshold,
				override = overridden and override or nil,
				effective = effective,
				is_fluid = is_fluid,
				stack = stack,
				need = need,
				capacity = capacity,
				gap = capacity - need,
				warn = warn,
				p_count = e and e.p_count or nil,
				p_threshold = e and e.p_threshold or nil,
			}
		end
	end
	m.warned = warned
	m.more_items = math.max(0, #list - EFFECTIVE_ITEMS)
	m.item_priorities = item_priorities
	return m
end

--- build_effective, rebuilt only when its inputs moved: the record was refilled, a new snapshot or fleet count, the
--- combinator display; the unserved entries' p_count / p_threshold are read again on every refresh.
local function effective_model(state, st, station, nets, nets_key)
	local counts, progress = fleet_counts(state, nets, nets_key)
	local c = state.eff
	local snap = collector.live()
	local snap_tick = snap and snap.tick
	local done = state.fleet and state.fleet.done_tick
	-- What the section reads from the record: a live record is refilled every refresh, mostly with the same values.
	local inputs = record_sig(state, "eff_inputs", st, eff_inputs_content)
	local m
	if c and c.id == st.id and c.inputs == inputs and c.snap == snap_tick and c.done == done and
		c.display == station.display_state and c.all == station.allows_all_trains then
		m = c.model
	else
		m = build_effective(state, st, station, nets, counts, progress)
		state.eff = { id = st.id, inputs = inputs, snap = snap_tick, done = done, display = station.display_state,
			all = station.allows_all_trains, model = m }
	end
	m.counting = counts == nil and progress or nil
	local entries = diag.unserved_for(st.id)
	local d = storage.diag
	for _, it in ipairs(m.items) do
		local ix = entries and d and d.item_ix[it.hash]
		local e = ix and entries[ix]
		it.p_count = e and e.p_count or nil
		it.p_threshold = e and e.p_threshold or nil
	end
	return m
end

--- The networks every combinator of the station advertises on, and the union of their masks per network (the trains
--- the Effective config counts can serve any of them).
local function rows_networks(st)
	local nets = rtext.row_networks(st)
	local parts = {}
	for i, n in ipairs(nets) do parts[i] = n.name .. "=" .. n.mask end
	return { list = nets, key = table.concat(parts, ","), union = rtext.rows_union(st) }
end

--- Everything the stop panel shows, as plain values.
--- @return table?
local function stop_model(pd, state)
	local id = state.id
	local station = storage.stations[id]
	local depot = not station and storage.depots[id] or nil
	local refueler = not (station or depot) and storage.refuelers[id] or nil
	local record = station or depot or refueler
	local stop = record and record.entity_stop
	if not (stop and stop.valid) then return nil end
	local now = game.tick
	local m = {
		kind = "stop",
		id = id,
		sub = station and "station" or depot and "depot" or "refueler",
		name = stop.backer_name,
		trains_count = stop.trains_count,
		lint_bits = lint.bits_of(id),
		lint_pass = storage.manager.lint and storage.manager.lint.pass or 0,
		read_tick = now,
		source = "live",
	}
	if station then
		local st, source = station_record(state, id)
		if not st then return nil end
		m.source = source
		m.read_tick = st.read_tick or now
		m.is_p, m.is_r, m.is_stack = st.is_p, st.is_r, st.is_stack
		m.network_name = st.network_name
		local nc = state.nets
		local mask = st.network_mask
		-- With inventories a network's mask is what any combinator advertises on: the trains the Effective config counts
		-- and the head's networks follow the union, not the station combinator's mask alone.
		local has_inventories = rtext.has_inventories(st)
		local rn = has_inventories and record_sig(state, "row_networks", st, rows_networks) or nil
		local union = rn and rn.union
		if not (nc and nc.id == st.id and nc.name == st.network_name and (union and nc.union and same_values(nc.union, union)
				or not union and not nc.union and type(mask) == "number" and nc.mask == mask)) then
			local nets = union and networks_of(NETWORK_EACH, union) or networks_of(st.network_name, st.network_mask)
			local parts = {}
			for i, n in ipairs(nets) do parts[i] = n.name .. "=" .. n.mask end
			local copy
			if union then
				copy = {}
				for k, v in pairs(union) do copy[k] = v end
			end
			nc = { id = st.id, name = st.network_name, mask = type(mask) == "number" and mask or nil, union = copy, nets = nets,
				key = table.concat(parts, ",") }
			state.nets = nc
		end
		m.nets = nc.nets
		m.nets_key = nc.key
		m.has_inventories = has_inventories
		m.row_nets = rn and rn.list or nil
		m.row_nets_key = rn and rn.key or nil
		m.status = pm.shown_status(st.status, id, m.lint_bits, diag.is_acked)
		if m.status == "setup" then m.setup_checks, m.setup_mask = pm.open_error_checks(id, m.lint_bits, diag.is_acked) end
		m.deliveries = st.deliveries_total
		m.limit = st.trains_limit
		m.unserved = unserved_rows(state, id)
		m.st = st
		m.display_state = station.display_state
		if pd.relative_effective_open then m.effective = effective_model(state, st, station, m.nets, m.nets_key) end
	elseif depot then
		m.limit = stop.trains_limit
		m.parked = depot.available_train_id
		m.deliveries = depot.available_train_id and 1 or 0
	else
		m.network_name = refueler.network_name
		m.nets = networks_of(refueler.network_name, refueler.network_mask)
		local parts = {}
		for i, n in ipairs(m.nets) do parts[i] = n.name .. "=" .. n.mask end
		m.nets_key = table.concat(parts, ",")
		m.limit = stop.trains_limit
		m.deliveries = refueler.trains_total or 0
	end
	m.occupancy_lint = lint.has(m.lint_bits, LINT_OCCUPANCY) or lint.has(m.lint_bits, LINT_PHANTOM)
	m.findings = lint_findings_of(state, id, m.lint_pass)
	return m
end

-- ---------------------------------------------------------------- stop sections

local function status_caption(status)
	return { "", "[img=flib_indicator_" .. (STATUS_COLOR[status] or "white") .. "] ",
		{ status_key(status) } }
end

--- The label style that says what a chip style said (cybersyn_chip_red -> cybersyn_marker_red), without looking
--- pressable: these panel cells have nothing to click.
--- @param chip_style string
--- @return string
local function marker_style(chip_style)
	return (string.gsub(chip_style, "^cybersyn_chip_", "cybersyn_marker_"))
end

--- A finding named in the panel head: coloured words with the detail in the tooltip, not a chip (nothing to click).
local function lint_marker(check, tooltip)
	return {
		type = "label",
		style = LINT_SEVERITY[check] == DIAG_SEV_ERROR and "cybersyn_marker_red" or "cybersyn_marker_orange",
		caption = { "cybersyn-diag.lint-" .. LINT_KEYS[check] },
		tooltip = tooltip,
	}
end

--- One lint finding as the panels and the Trains depot markers word it: the check's name, the detail with its
--- numbers, the fix line.
--- @param f LintFinding
--- @return LocalisedString
function relative.finding_text(f)
	return { "", "[font=default-semibold]", pm.caption(f.check), "[/font]  ", pm.detail(f, lint_text.ENV), "\n",
		pm.fix(f.check, f) }
end

local function render_stop_head(state, body, m)
	local sig = table.concat({ m.sub, tostring(m.is_p), tostring(m.is_r), tostring(m.is_stack), tostring(m.status),
		m.nets_key or "", m.row_nets_key or "", m.deliveries or 0, m.limit or 0, m.trains_count or 0, tostring(m.occupancy_lint),
		tostring(m.parked), m.setup_mask or 0 }, "|")
	if state.sigs["head"] ~= sig then
		section(state, body, "head", sig, function()
			local out = {}
			if m.sub == "station" then
				out[#out + 1] = field("cybersyn-gui.relative-role", rtext.role(m.is_p, m.is_r, m.is_stack))
			else
				out[#out + 1] = field("cybersyn-gui.relative-role", { "cybersyn-gui.relative-role-" .. m.sub })
			end
			if m.row_nets then
				out[#out + 1] = field("cybersyn-gui.relative-networks", #m.row_nets > 0 and networks_caption(m.row_nets)
					or { "cybersyn-gui.station-no-network" })
			elseif m.nets then
				if #m.nets == 0 then
					out[#out + 1] = field("cybersyn-gui.relative-network", { "cybersyn-gui.station-no-network" })
				end
				for i, n in ipairs(m.nets) do
					out[#out + 1] = field(i == 1 and "cybersyn-gui.relative-network" or nil,
						{ "cybersyn-gui.relative-network-mask", network_rich(n.name), rtext.mask_text(n.mask) })
				end
			end
			if m.status then
				out[#out + 1] = field("cybersyn-gui.relative-status", status_caption(m.status),
					m.setup_checks and pm.setup_status_tooltip(m.setup_checks)
					or { status_key(m.status) .. "-tooltip" })
			end
			local pair = {
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8 },
				{ type = "label", caption = { "cybersyn-gui.relative-trains-label" },
					style_mods = { width = FIELD_LABEL, font_color = { 0.65, 0.65, 0.65 } } },
				label({ "cybersyn-gui.relative-trains", rtext.trains_pair(m.deliveries, m.limit), tostring(m.trains_count) },
					{ tooltip = { "cybersyn-gui.relative-trains-tooltip" } }),
			}
			if m.occupancy_lint then
				local check = lint.has(m.lint_bits, LINT_PHANTOM) and LINT_PHANTOM or LINT_OCCUPANCY
				local f
				for _, x in ipairs(m.findings) do
					if x.check == check then f = x end
				end
				pair[#pair + 1] = lint_marker(check, f and relative.finding_text(f) or nil)
			end
			out[#out + 1] = pair
			return out
		end)
	end
end

local MUTED = { 0.65, 0.65, 0.65 }
local EMPTY = {}
-- A section's Provided / Requested lists sit beside their FIELD_LABEL caption: five slots fit what is left of INNER.
local LIST_COLUMNS = 5
local BLOCKS_SHOWN = 8
local NOT_ADVERTISED_SHOWN = 8

--- One "Provided" / "Requested" row of a section: its caption, then the slots or "Nothing".
local function list_row(key, slots)
	local row = {
		type = "flow",
		direction = "horizontal",
		-- 8 cut the fifth slot's right edge by about a pixel under the body's scroll bar, and with it the last
		-- character of a five-character count ("-200k").
		style_mods = { horizontal_spacing = 4 },
		{ type = "label", caption = { key }, style_mods = { width = FIELD_LABEL, font_color = MUTED } },
	}
	if #slots == 0 then
		row[#row + 1] = label({ "cybersyn-gui.section-none" }, { style_mods = { font_color = MUTED } })
		return row
	end
	local cell = { type = "flow", direction = "vertical", style_mods = { vertical_spacing = 2 } }
	for _, def in ipairs(slot_table(slots, #slots, LIST_COLUMNS)) do cell[#cell + 1] = def end
	row[#row + 1] = cell
	return row
end

--- "Not advertised: [icon]-866 [icon]52 (station is Provide only)".
local function not_advertised(ignored, reason)
	local hashes = util.hashes_in_item_order(ignored)
	if #hashes == 0 then return nil end
	local parts = {}
	for i = 1, math.min(#hashes, NOT_ADVERTISED_SHOWN) do
		local hash = hashes[i]
		parts[i] = rich_text.of_hash(hash) .. format_signal_count(ignored[hash])
	end
	local icons = table.concat(parts, " ")
	if #hashes > NOT_ADVERTISED_SHOWN then icons = icons .. " +" .. (#hashes - NOT_ADVERTISED_SHOWN) end
	return note({ "", { "cybersyn-gui.section-not-advertised" }, " ", icons, " (", reason, ")" })
end

--- The letter a block's head starts with: what its combinator shows, the S of the station combinator (cyan, green,
--- red: rtext.s_colour) or the I of an inventory (cyan, red when its own request failed).
--- @param row SnapshotInventory
--- @param display {s: string, inv_failed: {[uint]: true}?}?
--- @return string colour key of S_COLOUR
--- @return string letter
local function row_letter(row, display)
	if row.kind == "station" then return display and display.s or "cyan", "S" end
	local failed
	if display then
		failed = display.inv_failed ~= nil and display.inv_failed[row.unit] == true
	else
		failed = row.failed == true
	end
	return failed and "red" or "cyan", "I"
end

--- One combinator's block: "S Station combinator · priority 1  [A]1" / "I Inventory 2 · priority 5  [A]2", what it
--- provides and requests, and the signals the station's switch keeps it from advertising.
local function inventory_block(out, st, row, reason, display)
	local colour, letter = row_letter(row, display)
	local head = {
		type = "flow",
		direction = "horizontal",
		style_mods = { horizontal_spacing = 6, vertical_align = "center" },
		label({ "", "[color=" .. S_COLOUR[colour] .. "]" .. letter .. "[/color] ", rtext.row_head(row) }, {
			style = "bold_label",
			tooltip = { "cybersyn-gui.relative-" .. string.lower(letter) .. "-" .. colour },
		}),
	}
	local net = rtext.row_network(row)
	if net ~= "" then
		head[#head + 1] = label(net, { style_mods = { font = "default-small", font_color = MUTED } })
	end
	out[#out + 1] = head

	local starved = row.starved or EMPTY
	local provided = {}
	for _, hash in ipairs(util.hashes_in_item_order(row.provided)) do
		local count = row.provided[hash]
		provided[#provided + 1] = slot(hash, count, "green",
			{ "", " ", { "cybersyn-gui.provided" }, "\n", { "cybersyn-gui.amount", format.number(count) } }, st.id)
	end
	out[#out + 1] = list_row("cybersyn-gui.section-provided", provided)

	local requested, below = {}, false
	for _, hash in ipairs(util.hashes_in_item_order(row.requested)) do
		local req = row.requested[hash]
		if not req.active then below = true end
		local tip = {
			"", " ", req.active and { "cybersyn-gui.requested" } or { "cybersyn-gui.requested-below-threshold" },
			"\n", { "cybersyn-gui.amount", format.number(req.count) },
			"\n", { "cybersyn-gui.request-threshold", format.number(req.threshold) },
		}
		if starved[hash] then
			tip[#tip + 1] = "\n[color=1,0.45,0.4]"
			tip[#tip + 1] = { "cybersyn-gui.section-starved" }
			tip[#tip + 1] = "[/color]"
		end
		requested[#requested + 1] = slot(hash, req.count, req.active and "red" or "orange", tip, st.id)
	end
	out[#out + 1] = list_row("cybersyn-gui.section-requested", requested)
	if below then out[#out + 1] = note({ "cybersyn-gui.section-below-threshold" }) end
	out[#out + 1] = not_advertised(row.ignored or EMPTY, reason)
end

--- The Advertised blocks' element defs: one per combinator, the station combinator first.
--- @param st SnapshotStation
--- @param display {s: string, inv_failed: {[uint]: true}?}? the combinators' letters as shown now; without it the S
---   reads cyan and each I follows the row's `failed`
--- @return flib.GuiElemDef[]
local function slots_defs(st, display)
	if not st.network_name then return { note({ "cybersyn-gui.relative-no-items" }) } end
	local rows = rtext.advertised_rows(st)
	local out = { heading({ "cybersyn-gui.section-advertised" }) }
	local paused = rtext.paused_inventories(st)
	if #paused > 0 then
		local names = { "" }
		for i = 1, math.min(#paused, 4) do
			if i > 1 then names[#names + 1] = ", " end
			names[#names + 1] = paused[i].label or collector.source_label(paused[i])
		end
		if #paused > 4 then names[#names + 1] = " +" .. (#paused - 4) end
		out[#out + 1] = line({ rtext.paused_key(st), names }, nil, { 1, 0.78, 0.45 })
	end
	local reason = rtext.ignored_reason(st)
	for i = 1, math.min(#rows, BLOCKS_SHOWN) do
		if i > 1 then out[#out + 1] = { type = "line", direction = "horizontal" } end
		inventory_block(out, st, rows[i], reason, display)
	end
	if #rows > BLOCKS_SHOWN then
		out[#out + 1] = note({ "cybersyn-gui.relative-more", tostring(#rows - BLOCKS_SHOWN) })
	end
	return out
end
-- Exposed for the unit tests, which build the blocks from fixture records.
relative.slots_defs = slots_defs

--- @param st SnapshotStation
--- @return string
local function slots_content(st)
	return st.rows_sig or rtext.rows_content(st)
end

--- The letters' part of the blocks' signature.
--- @param st SnapshotStation
--- @param s string the S letter's colour
--- @param inv {[uint]: true}? station.inv_failed
--- @return string
local function display_sig(st, s, inv)
	if not inv then return s end
	-- Runs on every refresh: no table, and a lit I is rare.
	for _, row in ipairs(collector.inventories(st)) do
		if inv[row.unit] then s = s .. "," .. row.unit end
	end
	return s
end

--- What the station advertises, one block per combinator: a station without inventories is a single block.
local function render_slots(state, body, m)
	local st = m.st
	if not st then
		if state.sigs["slots"] ~= "" then section(state, body, "slots", "", hidden) end
		return
	end
	local station = storage.stations and storage.stations[st.id]
	local s_colour, inv_failed = rtext.s_colour(m.display_state), station and station.inv_failed or nil
	-- Each row carries its starved set (collector.station_status); a new station-level set refills them without a new
	-- read, so it keys the cached signature too.
	local snap = collector.live()
	local starved = m.source == "live" and state.starved or (snap and snap.starved) or nil
	local rsig = record_sig(state, "slots", st, slots_content, starved)
	local dsig = display_sig(st, s_colour, inv_failed)
	-- The rows part can be several KB on a big requester and is the same cached string between reads: comparing the
	-- parts skips a concatenation (a fresh long string) on every refresh.
	local last = state.slots_last
	if last and last.r == rsig and last.d == dsig and state.sigs["slots"] == last.sig then return end
	local sig = rsig .. "|" .. dsig
	state.slots_last = { r = rsig, d = dsig, sig = sig }
	if state.sigs["slots"] ~= sig then
		section(state, body, "slots", sig, function() return slots_defs(st, { s = s_colour, inv_failed = inv_failed }) end)
	end
end
relative.render_slots = render_slots

--- The texts of an unserved row that move between reason changes: the four-line why (payload, evaluations, losses,
--- wait), the stock and the wait, all on the 10 s age step.
--- @return LocalisedString tip
--- @return LocalisedString stock
--- @return LocalisedString wait
local function unserved_texts(m, r, now, inherit_before)
	local e = r.e
	local _, _, item_tooltip = util.item_sprite_and_tooltip(r.hash)
	local st = m.st
	-- On a station with inventories the text names the one that requests the item, as the Overview does,
	-- with that combinator's request rather than the station's sum.
	local inv = utext.inventory_of(st, r.hash, "requested", collector.inventories)
	local req = st and (inv or st).requested[r.hash]
	local wait = rtext.age_step(now - e.first_tick)
	local inherited = e.first_tick < inherit_before
	local tip = utext.chip_tooltip({
		item = item_tooltip or r.hash,
		requested = req and -req.count or nil,
		requester = m.name,
		reason = e.reason,
		a = e.a,
		b = e.b,
		network = inv and rtext.row_text(inv) or m.network_name and network_rich(m.network_name) or nil,
		rej = e.rej,
		wait = wait,
		inherited = inherited,
		n = e.n,
		surface_name = util.surface_name,
	})
	local stock = utext.stock_caption(e.reason, e.a, e.b)
	return tip, stock ~= utext.NO_VALUE and stock or "", utext.wait_caption(wait, inherited)
end
relative.unserved_texts = unserved_texts

local function render_unserved(state, body, m, compact)
	local rows = m.unserved
	if not rows or #rows == 0 or not storage.diag then
		state.ages.unserved = nil
		if state.sigs["unserved"] ~= "" then section(state, body, "unserved", "", hidden) end
		return
	end
	local now = game.tick
	local d = storage.diag
	local inherit_before = diag.inherit_threshold(d)
	-- The rows are rebuilt when an item, a reason, an ack or the provider changes; the texts that move with every
	-- planner cycle on a busy base are rewritten in place on the 10 s age step (a rebuild cost a refresh 0.4 ms).
	local a, b, c = 0, 0, 0
	local n = math.min(#rows, UNSERVED_ROWS)
	for i = 1, n do
		local r, e = rows[i], rows[i].e
		local w = util.item_rank(r.hash) * i
		a = a + w * e.reason + (diag.is_acked("request", state.id, r.hash) and w or 0)
		b = b + w * e.first_tick
		c = c + w * (e.p_station_id or 0)
	end
	local unserved_sig = content_sig(#rows, a, b, c) .. (compact and "c" or "")
	local step = math.floor(now / rtext.AGE_STEP)
	local ages = state.ages
	if state.sigs["unserved"] ~= unserved_sig then
		ages.unserved = step
		section(state, body, "unserved", unserved_sig, function()
			local out = { heading({ "cybersyn-gui.relative-unserved", tostring(#rows) }) }
			for i = 1, n do
				local r, e = rows[i], rows[i].e
				local sprite, quality = util.item_sprite_and_tooltip(r.hash)
				local tip, stock, wait = unserved_texts(m, r, now, inherit_before)
				local acked = diag.is_acked("request", state.id, r.hash) ~= nil
				out[#out + 1] = {
					type = "flow",
					name = "row" .. i,
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = UNSERVED_GAP, maximal_width = INNER },
					sprite and {
						type = "sprite-button",
						style = "cybersyn_unserved_item",
						sprite = sprite,
						quality = quality,
						tooltip = { "cybersyn-gui.relative-slot-hint" },
						elem_tooltip = util.elem_tooltip(r.hash),
						tags = { kind = "item", id = r.hash, station = state.id },
						mouse_button_filter = { "left" },
						handler = { [defines.events.on_gui_click] = links.handle.link_click },
					} or label(r.hash),
					{
						type = "label",
						name = "chip",
						style = marker_style(acked and "cybersyn_chip_acked" or utext.chip_style(e.reason)),
						style_mods = { maximal_width = UNSERVED_CHIP },
						caption = utext.chip_caption(e.reason),
						tooltip = tip,
					},
					label(stock, { name = "stock", style_mods = { width = UNSERVED_STOCK, horizontal_align = "right",
						font = UNSERVED_FONT } }),
					label(wait, { name = "wait", style_mods = { width = UNSERVED_WAIT, horizontal_align = "right", font = UNSERVED_FONT,
						font_color = { 0.7, 0.7, 0.7 } } }),
				}
				-- The expanded Effective config needs the room; the four lines stay in the chip's tooltip.
				if i == 1 and not compact then
					local why = line(tip)
					why.name = "why"
					out[#out + 1] = why
				end
			end
			if #rows > UNSERVED_ROWS then
				out[#out + 1] = note({ "cybersyn-gui.relative-more", tostring(#rows - UNSERVED_ROWS) })
			end
			return out
		end)
	elseif ages.unserved ~= step then
		ages.unserved = step
		local flow = body.unserved
		for i = 1, n do
			local row = flow and flow["row" .. i]
			if row then
				local tip, stock, wait = unserved_texts(m, rows[i], now, inherit_before)
				row.chip.tooltip = tip
				row.stock.caption = stock
				row.wait.caption = wait
				if i == 1 and flow.why then flow.why.caption = tip end
			end
		end
	end
end

local function render_deliveries(state, body, m)
	local st = m.st
	if not st then
		if state.sigs["deliveries"] ~= "" then section(state, body, "deliveries", "", hidden) end
		return
	end
	local sig = record_sig(state, "deliveries", st, deliveries_content, m.deliveries or 0)
	if state.sigs["deliveries"] ~= sig then
		section(state, body, "deliveries", sig, function()
			local out = { heading({ "cybersyn-gui.relative-in-flight", tostring(m.deliveries or 0) }) }
			local slots, total = {}, 0
			for _, hash in ipairs(util.hashes_in_item_order(st.deliveries)) do
				local count = st.deliveries[hash]
				total = total + 1
				slots[#slots + 1] = slot(hash, count, count > 0 and "green" or "blue", {
					"", " ", count > 0 and { "cybersyn-gui.incoming" } or { "cybersyn-gui.outgoing" },
					"\n", { "cybersyn-gui.amount", format.number(count) },
				}, st.id, true)
			end
			if total == 0 then return nil end
			for _, def in ipairs(slot_table(slots, total)) do out[#out + 1] = def end
			return out
		end)
	end
end

local function render_control(state, body, m)
	local st = m.st
	if not st then
		if state.sigs["control"] ~= "" then section(state, body, "control", "", hidden) end
		return
	end
	local sig = record_sig(state, "control", st, control_content)
	if state.sigs["control"] ~= sig then
		section(state, body, "control", sig, function()
			local slots = util.slot_table_build_from_control_signals(st)
			if #slots == 0 then return nil end
			local out = { heading({ "cybersyn-gui.control-signals" }) }
			for _, def in ipairs(slot_table(slots, #slots)) do out[#out + 1] = def end
			return out
		end)
	end
end

--- Whether a finding line gets the Recount deliveries button: the counter-leak direction of a phantom finding.
local function leak_of(findings)
	for _, f in ipairs(findings) do
		if xlogic.is_counter_leak(f) then return true end
	end
	return false
end

local function render_setup(state, body, m, pd)
	local player = game.get_player(pd.player_index)
	if not player then return end
	local leak = m.sub == "station" and leak_of(m.findings)
	local sig = m.lint_bits .. ":" .. m.lint_pass .. (leak and (":" .. repair.recount_sig(player, pd, state.id)) or "")
	if state.sigs["setup"] ~= sig then
		section(state, body, "setup", sig, function()
			local out = { heading({ "cybersyn-gui.relative-setup" }) }
			if #m.findings == 0 then
				if m.lint_pass == 0 then
					out[#out + 1] = note({ "cybersyn-gui.relative-setup-not-run" })
				else
					out[#out + 1] = note({ "cybersyn-gui.relative-setup-none" })
				end
				return out
			end
			for _, f in ipairs(m.findings) do
				out[#out + 1] = line({ "", "• ", { "cybersyn-diag.lint-" .. LINT_KEYS[f.check] } }, nil, sev_color(LINT_SEVERITY[f.check]))
				-- Same detail and fix texts as the Stations Problems column, so one finding reads alike in both places.
				out[#out + 1] = note(pm.detail(f, lint_text.ENV))
				out[#out + 1] = note(pm.fix(f.check, f))
				if leak and xlogic.is_counter_leak(f) then out[#out + 1] = repair.recount_button(player, pd, state.id) end
			end
			return out
		end)
	end
end

local function render_effective(state, body, m)
	local e = m.effective
	if not e then
		if state.sigs["effective"] ~= "" then section(state, body, "effective", "", hidden) end
		return
	end
	if not e.sig then
		local parts = { e.base_item, tostring(e.base_item_signal), e.base_fluid, e.limit, e.priority, e.s_colour,
			e.item_capacity, e.fluid_capacity, e.more_items, e.warned, tostring(e.overrides_known) }
		for _, n in ipairs(e.nets) do
			parts[#parts + 1] = table.concat({ n.name, n.mask, tostring(n.trains), tostring(n.depots), n.item_capacity,
				n.fluid_capacity, tostring(n.accepted), n.allow_trains, table.concat(n.missing, "/"), tostring(n.known) }, ":")
		end
		for _, it in ipairs(e.items) do
			parts[#parts + 1] = table.concat({ it.hash, it.threshold, tostring(it.override), it.need, it.capacity }, ":")
		end
		for _, ip in ipairs(e.item_priorities or {}) do parts[#parts + 1] = "p" .. ip.hash .. ":" .. ip.priority end
		e.sig = table.concat(parts, "|")
	end
	local sig = e.sig
	if e.counting then sig = sig .. "|c" .. math.floor(e.counting * 10) end
	for i, it in ipairs(e.items) do
		if it.p_count then sig = sig .. "|" .. i .. "=" .. it.p_count .. "/" .. tostring(it.p_threshold) end
	end
	if state.sigs["effective"] ~= sig then
		section(state, body, "effective", sig, function()
			local out = { heading({ "cybersyn-gui.relative-effective" }) }
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-threshold", format.number(e.base_item),
				e.base_item_signal and { "cybersyn-gui.relative-from-signal" } or { "cybersyn-gui.relative-from-default" },
				m.is_stack and { "cybersyn-gui.relative-unit-stacks" } or { "cybersyn-gui.relative-unit-items" } })
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-fluid", format.number(e.base_fluid) })
			if #e.items > 0 then
				local RED = { 1, 0.45, 0.4 }
				local function cell(caption, tooltip, color)
					return { type = "label", caption = caption, tooltip = tooltip,
						style_mods = { horizontal_align = "right", minimal_width = 56, font_color = color } }
				end
				local tbl = {
					type = "table",
					column_count = 4,
					style_mods = { horizontal_spacing = 12, vertical_spacing = 2 },
					label({ "cybersyn-gui.relative-eff-col-item" }, { style = "bold_label" }),
					cell({ "cybersyn-gui.relative-eff-col-threshold" }, { "cybersyn-gui.relative-eff-col-threshold-tooltip" }),
					cell({ "cybersyn-gui.relative-eff-col-need" }, { "cybersyn-gui.relative-eff-col-need-tooltip" }),
					cell({ "cybersyn-gui.relative-eff-col-gap" }, { "cybersyn-gui.relative-eff-col-gap-tooltip" }),
				}
				for i = 2, 4 do tbl[i].style_mods.font = "default-semibold" end
				for _, it in ipairs(e.items) do
					local sprite, quality = util.item_sprite_and_tooltip(it.hash)
					local tip = { "", { "cybersyn-gui.relative-eff-item-tooltip", format.number(it.threshold),
						it.stack and tostring(it.stack) or utext.NO_VALUE } }
					if it.override then
						tip[#tip + 1] = "\n"
						tip[#tip + 1] = { "cybersyn-gui.relative-eff-override", format.number(it.override) }
					end
					if it.p_count then
						tip[#tip + 1] = "\n"
						tip[#tip + 1] = { "cybersyn-gui.relative-eff-provider", format.number(it.p_count),
							format.number(it.p_threshold or 0) }
					end
					local color = it.warn and RED or nil
					tbl[#tbl + 1] = sprite and {
						type = "sprite-button",
						style = "cybersyn_name_icon",
						sprite = sprite,
						quality = quality,
						elem_tooltip = util.elem_tooltip(it.hash),
						tooltip = tip,
					} or label(it.hash)
					tbl[#tbl + 1] = cell(format.number(it.effective) .. (it.override and "*" or ""), tip)
					tbl[#tbl + 1] = cell(it.is_fluid and format.number(it.need) or { "cybersyn-gui.relative-eff-stacks", tostring(it.need) }, nil, color)
					tbl[#tbl + 1] = cell(it.capacity > 0 and ((it.gap >= 0 and "+" or "−") .. format.number(math.abs(it.gap))) or utext.NO_VALUE,
						nil, color)
				end
				out[#out + 1] = tbl
				if not e.overrides_known then
					out[#out + 1] = note({ "cybersyn-gui.relative-eff-overrides-unknown" })
				end
			end
			if e.warned > 0 then
				out[#out + 1] = line({ "cybersyn-gui.relative-eff-warn", tostring(e.warned), tostring(e.item_capacity),
					format.number(e.fluid_capacity) }, nil, { 1, 0.45, 0.4 })
			end
			if e.more_items > 0 then out[#out + 1] = note({ "cybersyn-gui.relative-more", tostring(e.more_items) }) end
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-limit", e.limit >= rtext.UNLIMITED and "∞" or tostring(e.limit),
				tostring(e.priority) })
			local ips = e.item_priorities
			if ips and #ips > 0 then
				local list = { "" }
				for k, ip in ipairs(ips) do
					list[#list + 1] = (k > 1 and ", " or "") .. lint_text.ENV.item(ip.hash) .. " " .. ip.priority
				end
				out[#out + 1] = line({ "cybersyn-gui.relative-eff-item-priority", list })
			end
			if e.counting then
				out[#out + 1] = note({ "cybersyn-gui.relative-eff-counting", tostring(math.floor(e.counting * 100)) })
			end
			for _, n in ipairs(e.nets) do
				out[#out + 1] = line({ "cybersyn-gui.relative-eff-mask", network_rich(n.name), rtext.mask_text(n.mask),
					n.trains and tostring(n.trains) or "…", n.depots and tostring(n.depots) or "…" })
				if n.known then
					out[#out + 1] = line({ "cybersyn-gui.relative-eff-capacity", tostring(n.item_capacity),
						format.number(n.fluid_capacity), tostring(n.eligible) })
					local layouts = {}
					for i, layout_id in ipairs(n.missing) do
						if i > 4 then
							layouts[#layouts + 1] = "…"
							break
						end
						local layout = storage.layouts[layout_id]
						layouts[#layouts + 1] = layout and logic.composition(layout) or "?"
					end
					local allow
					if n.accepted == false then
						allow = { "cybersyn-gui.relative-eff-allow-all", tostring(n.allow_trains) }
					else
						allow = { "cybersyn-gui.relative-eff-allow", tostring(n.accepted), tostring(n.allow_trains),
							#layouts > 0 and table.concat(layouts, ", ") or utext.NO_VALUE }
					end
					out[#out + 1] = line(allow, { "cybersyn-gui.relative-eff-allow-tooltip" },
						n.allow_trains == 0 and { 1, 0.45, 0.4 } or nil)
				end
			end
			out[#out + 1] = line({ "cybersyn-gui.relative-eff-s", "[color=" .. S_COLOUR[e.s_colour] .. "]S[/color]",
				{ "cybersyn-gui.relative-s-" .. e.s_colour } }, { "cybersyn-gui.relative-s-legend" })
			return out
		end)
	end
end

local function event_rows_sig(rows)
	local parts = {}
	for i, ev in ipairs(rows) do parts[i] = ev.seq end
	return table.concat(parts, ",")
end

--- The alert's own name ("Train stuck") for an alert event, nil for any other kind.
--- @param ev {kind: int, code: int}
--- @return LocalisedString?
local function alert_name(ev)
	local name = ev.kind == DIAG_KIND_ALERT and DIAG_ALERT_NAMES[ev.code]
	return name and { "cybersyn-diag.alert-" .. string.gsub(name, "_", "-") } or nil
end

local function event_caption(ev, now, d)
	local alert = alert_name(ev)
	-- An alert row names the alert where other rows name their kind: "Alert" alone says nothing.
	local caption = alert and { "", short_age(now - ev.tick), "  ", alert }
		or rtext.event_row(ev, now)
	local hash = ev.item ~= 0 and d and d.item_hash[ev.item] or nil
	local _, _, item_tooltip = hash and util.item_sprite_and_tooltip(hash)
	if item_tooltip then caption = { "", caption, "  ", item_tooltip } end
	return caption
end

local function render_events(state, body, kind, id, shown)
	if not storage.diag then
		state.cursor = nil
		if state.sigs["events"] ~= "" then section(state, body, "events", "", hidden) end
		return
	end
	local cursor = state.cursor
	local first_scan = not cursor
	if not cursor then
		cursor = diag.scan_cursor(kind, id, EVENTS)
		state.cursor = cursor
	end
	-- The refresh that opens the panel scans diag.SCAN_ROWS at once (a one-off, like the fleet walk's burst); later
	-- refreshes go on EVENT_SCAN_ROWS at a time.
	-- A stop panel without a manager snapshot (state.st: live reads of the stop) spends more per refresh: half the rows.
	local rows = diag.last_for_step(cursor, not first_scan and (state.st and EVENT_SCAN_ROWS / 2 or EVENT_SCAN_ROWS) or nil)
	local now = game.tick
	shown = shown or EVENTS
	-- The rows change only when the cursor's newest row or its first row does; their ages are rewritten in place
	-- every AGE_STEP.
	local first = rows[1] and rows[1].seq or 0
	local ec = state.events_sig
	local events_sig
	if ec and ec.first == first and ec.n == #rows and ec.done == cursor.done and ec.shown == shown then
		events_sig = ec.sig
	else
		events_sig = event_rows_sig(rows) .. (cursor.done and "" or "+") .. shown
		state.events_sig = { first = first, n = #rows, done = cursor.done, shown = shown, sig = events_sig }
	end
	-- Half a step after the unserved rows', so the two in-place rewrites fall on different refreshes.
	local step = math.floor((now + rtext.AGE_STEP / 2) / rtext.AGE_STEP)
	local ages = state.ages
	local d = storage.diag
	if state.sigs["events"] ~= events_sig then
		ages.events = step
		local shown_ages = {}
		state.event_ages = shown_ages
		section(state, body, "events", events_sig, function()
			local out = { heading({ "cybersyn-gui.relative-events" }) }
			if #rows == 0 then
				out[#out + 1] = note(cursor.done and { kind == "train" and "cybersyn-gui.relative-events-none-train"
					or "cybersyn-gui.relative-events-none" } or { "cybersyn-gui.relative-events-scanning" })
				return out
			end
			for i, ev in ipairs(rows) do
				if i > shown then break end
				shown_ages[i] = short_age(now - ev.tick)
				local row = line(event_caption(ev, now, d), { "cybersyn-gui.relative-event-tooltip",
					logic.format_duration(ev.tick), tostring(ev.seq) }, sev_color(ev.sev))
				row.name = "ev" .. i
				out[#out + 1] = row
			end
			return out
		end)
	elseif ages.events ~= step then
		ages.events = step
		local flow = body.events
		local shown_ages = state.event_ages or {}
		state.event_ages = shown_ages
		-- An age past the hour reads in minutes, so most of an old stop's rows keep their caption.
		for i, ev in ipairs(rows) do
			if i > shown then break end
			local age = short_age(now - ev.tick)
			local row = shown_ages[i] ~= age and flow and flow["ev" .. i]
			if row then
				shown_ages[i] = age
				row.caption = event_caption(ev, now, d)
			end
		end
	end
end

local function tool(name, sprite, tooltip, handler, enabled, tags)
	return {
		type = "sprite-button",
		name = name,
		style = "tool_button",
		sprite = sprite,
		tooltip = tooltip,
		enabled = enabled ~= false,
		tags = tags,
		handler = handler and { [defines.events.on_gui_click] = handler } or nil,
	}
end

-- ---------------------------------------------------------------- tools and actions in the footer

--- The footer's signature part that the footer tools and actions depend on (scripts/gui/extras.lua, repair.lua).
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param kind "stop"|"train"
--- @param id uint
--- @return string
local function extras_sig(player, pd, kind, id)
	return "|" .. extras.tools_sig(pd, kind, id) .. "|" .. repair.sig(player, pd, kind, id)
end

--- The footer rows: `row` (the panel's own buttons) with the tool buttons appended, and for a train the
--- action row below.
--- @return flib.GuiElemDef[]
local function extras_rows(player, pd, kind, id, row, lead)
	local rows = { row }
	if kind == "train" then
		-- Beside the vanilla window Open in manager keeps the first row to itself, apart from the tools on the action
		-- row; it has no Locate because the remote view already follows the train. The Trains pane has no Open in
		-- manager, so Locate leads the action row: one row, not a lone button above it.
		if lead then rows = {} end
		rows[#rows + 1] = repair.train_row(player, pd, id, extras.train_tools(pd, id), lead)
	else
		for _, def in ipairs(extras.stop_tools()) do row[#row + 1] = def end
	end
	return rows
end

local function render_stop_buttons(state, body, m, pd)
	local station = storage.stations[state.id]
	local has2 = station and station.entity_comb2 and station.entity_comb2.valid or false
	local player = game.get_player(pd.player_index)
	if not player then return end
	local buttons_sig = m.sub .. tostring(has2) .. extras_sig(player, pd, "stop", state.id)
	if state.sigs["buttons"] ~= buttons_sig then
		section(state, body, "buttons", buttons_sig, function()
			local row = {
				type = "flow",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				{
					type = "button",
					name = "open_manager",
					caption = { "cybersyn-gui.relative-open-manager" },
					tooltip = { m.sub == "station" and "cybersyn-gui.relative-open-manager-tooltip"
						or "cybersyn-gui.relative-open-manager-depot-tooltip" },
					handler = { [defines.events.on_gui_click] = relative.handle.relative_open_manager },
				},
				tool("comb1", "item/cybersyn-combinator", { "cybersyn-gui.relative-comb1" }, relative.handle.relative_comb),
			}
			if m.sub == "station" then
				row[#row + 1] = tool("comb2", "item/cybersyn-combinator", { "cybersyn-gui.relative-comb2" },
					relative.handle.relative_comb, has2)
			end
			row[#row + 1] = { type = "empty-widget", style = "flib_horizontal_pusher" }
			return extras_rows(player, pd, "stop", state.id, row)
		end)
	end
end

-- ---------------------------------------------------------------- train model and sections

--- Schedule records as plain data, read once on open and again on on_train_schedule_changed.
local function read_schedule(state, entity)
	local records = {}
	local schedule = entity.get_schedule()
	for i, r in ipairs(schedule.get_records() or {}) do
		records[i] = {
			station = r.station,
			rail = r.rail ~= nil,
			temporary = r.temporary == true,
			created_by_interrupt = r.created_by_interrupt == true,
		}
	end
	state.schedule = { records = records, tick = game.tick }
end

--- @return table?
local function train_model(pd, state)
	local train = storage.trains[state.id]
	local entity = train and train.entity
	if not (entity and entity.valid) then return nil end
	local state_now = entity.state
	-- A schedule edit or an interrupt raises on_train_schedule_changed, which drops state.schedule. The current record
	-- is read every render: go_to_station moves it with no event and, on a moving train, no state change (2.1.23).
	if not state.schedule then read_schedule(state, entity) end
	local now = game.tick
	local current = entity.get_schedule().current
	local m = {
		kind = "train",
		id = state.id,
		status = train.status,
		state = state_now,
		state_name = STATE_NAMES[state_now],
		state_since = train.state_tick,
		manifest = train.manifest or {},
		p_station_id = train.p_station_id,
		r_station_id = train.r_station_id,
		depot_id = train.depot_id,
		refueler_id = train.refueler_id,
		dispatch_tick = train.dispatch_tick,
		refuel_tick = train.refuel_tick,
		delivery_id = train.delivery_id,
		schedule = state.schedule.records,
		current = current,
		read_tick = now,
	}
	if state_now == WAIT_SIGNAL then
		local signal = entity.signal
		if signal and signal.valid then m.signal = signal end
	end
	return m
end

local function status_target(m)
	local s = m.status
	if s == STATUS_TO_P or s == STATUS_P then return "station", m.p_station_id end
	if s == STATUS_TO_R or s == STATUS_R then return "station", m.r_station_id end
	if s == STATUS_TO_F or s == STATUS_F then return "refueler", m.refueler_id end
	return "depot", m.depot_id
end

--- The train's state as every place names it (logic.state_chip): residue or refuelling replace a quiet state.
--- @param m table the train panel's model
--- @param now uint
--- @return StateChip
local function train_state_chip(m, now)
	local residue = m.status == STATUS_D and next(m.manifest) ~= nil
	return logic.state_chip(m.state_name, m.state_since, now,
		residue and "residue" or (m.status == STATUS_F and "refuel" or nil))
end

--- @param sc StateChip
--- @return string
local function state_label_style(sc)
	return sc.style and ("cybersyn_marker_" .. sc.style) or "label"
end

--- @param sc StateChip
--- @return LocalisedString
local function state_label_caption(sc)
	return { "", "[img=" .. sc.sprite .. "] ", sc.caption }
end

local function render_train_head(state, body, m)
	local now = game.tick
	-- Time in state as the Trains row beside the pane shows it (logic.short_duration of the exact age): one rule.
	local since = m.state_since and (now - m.state_since) or -1
	local since_caption = since >= 0 and logic.short_duration(since) or ""
	local kind, target = status_target(m)
	local sig = table.concat({ m.status or -1, kind, tostring(target), tostring(target and stop_name(kind, target)) }, "|")
	-- A moving train changes state at every signal: the state and its age are rewritten in place.
	local ages = state.ages
	local sc = train_state_chip(m, now)
	local state_now = sc.key .. "|" .. tostring(sc.style)
	if state.sigs["head"] == sig then
		if ages.head ~= state_now or ages.head_since ~= since_caption then
			local row = body.head and body.head.state_row
			if row then
				if ages.head ~= state_now then
					row.state_chip.style = state_label_style(sc)
					row.state_chip.caption = state_label_caption(sc)
				end
				row.in_state.caption = since >= 0 and { "cybersyn-gui.relative-in-state", since_caption } or ""
				row.in_state.tooltip = m.state_since and logic.format_duration(since) or ""
			end
			ages.head, ages.head_since = state_now, since_caption
		end
	else
		ages.head, ages.head_since = state_now, since_caption
		section(state, body, "head", sig, function()
			local key = TRAIN_STATUS_KEY[m.status]
			local status = key and { key } or { "cybersyn-gui.trains-custom-status", tostring(m.status) }
			local out = {
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					label(status, { style = "bold_label" }),
					stop_link(kind, target, INNER - 120),
				},
			}
			out[#out + 1] = {
				type = "flow",
				name = "state_row",
				direction = "horizontal",
				style_mods = { vertical_align = "center", horizontal_spacing = 8 },
				{
					type = "label",
					name = "state_chip",
					style = state_label_style(sc),
					caption = state_label_caption(sc),
				},
				label(since >= 0 and { "cybersyn-gui.relative-in-state", since_caption } or "",
					{ name = "in_state", tooltip = m.state_since and logic.format_duration(since) or nil }),
			}
			return out
		end)
	end
end

--- The Cybersyn alert on the train (the warning triangle of the Trains tab and the map), named.
local function render_alert(state, body)
	local alerts = storage.active_alerts
	local alert = alerts and alerts[state.id]
	local code = alert and alert[2]
	local sig = code and tostring(code) or ""
	if state.sigs["alert"] == sig then return end
	section(state, body, "alert", sig, function()
		if not code then return nil end
		local name = DIAG_ALERT_NAMES[code]
		return { {
			type = "flow",
			direction = "horizontal",
			style_mods = { vertical_align = "center", horizontal_spacing = 4 },
			{ type = "sprite", sprite = "utility/warning_icon", resize_to_sprite = false, style_mods = { size = 20 } },
			-- A label, not a chip button: it has no action.
			{
				type = "label",
				name = "alert_chip",
				style = marker_style("cybersyn_chip_orange"),
				caption = name and { "cybersyn-diag.alert-" .. string.gsub(name, "_", "-") } or { "cybersyn-gui.overview-alert-0" },
				tooltip = { "cybersyn-gui.relative-alert-tooltip" },
			},
		} }
	end)
end

local function render_manifest(state, body, m)
	local parts = {}
	for i, it in ipairs(m.manifest) do parts[i] = (it.name or "?") .. ":" .. tostring(it.quality) .. "=" .. (it.count or 0) end
	local manifest_sig = table.concat(parts, ",")
	if state.sigs["manifest"] ~= manifest_sig then
		section(state, body, "manifest", manifest_sig, function()
			if #m.manifest == 0 then return nil end
			local slots = {}
			for _, it in ipairs(m.manifest) do
				local hash = hash_item(it.name, it.quality)
				slots[#slots + 1] = slot(hash, it.count, "default",
					{ "", "\n", { "cybersyn-gui.amount", format.number(it.count) } })
			end
			local out = { heading({ "cybersyn-gui.shipment" }) }
			for _, def in ipairs(slot_table(slots, #slots)) do out[#out + 1] = def end
			return out
		end)
	end
end

local function render_route(state, body, m)
	local now = game.tick
	local dispatched = m.dispatch_tick and rtext.age_step(now - m.dispatch_tick) or -1
	local refuel = m.refuel_tick and rtext.age_step(now - m.refuel_tick) or -1
	local sig = table.concat({ m.status or -1, tostring(m.p_station_id), tostring(m.r_station_id), tostring(m.depot_id),
		tostring(m.p_station_id and stop_name("station", m.p_station_id)),
		tostring(m.r_station_id and stop_name("station", m.r_station_id)),
		tostring(m.depot_id and stop_name("depot", m.depot_id)), tostring(dispatched >= 0), tostring(refuel >= 0) }, "|")
	local ages = state.ages
	if state.sigs["route"] == sig then
		if ages.route ~= dispatched or ages.refuel ~= refuel then
			ages.route, ages.refuel = dispatched, refuel
			local flow = body.route
			if flow and flow.dispatched and dispatched >= 0 then
				flow.dispatched.caption = { "cybersyn-gui.relative-dispatched", logic.short_duration(dispatched) }
			end
			if flow and flow.refuel and refuel >= 0 then
				flow.refuel.caption = { "cybersyn-gui.relative-refuel", { "cybersyn-gui.time-ago", logic.short_duration(refuel) } }
			end
		end
	else
		ages.route, ages.refuel = dispatched, refuel
		section(state, body, "route", sig, function()
			local out = {}
			local s = m.status
			if (m.p_station_id or m.r_station_id) and s and s >= STATUS_TO_P and s <= STATUS_R then
				out[#out + 1] = {
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					stop_link("station", m.p_station_id, math.floor((INNER - 24) / 2)),
					label("→"),
					stop_link("station", m.r_station_id, math.floor((INNER - 24) / 2)),
				}
			end
			-- The head already links the depot while the train is parked there or heading back.
			if status_target(m) ~= "depot" then
				out[#out + 1] = {
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					label({ "cybersyn-gui.relative-depot" }),
					stop_link("depot", m.depot_id, INNER - 80),
				}
			end
			if dispatched >= 0 then
				local row = line({ "cybersyn-gui.relative-dispatched", logic.short_duration(dispatched) })
				row.name = "dispatched"
				out[#out + 1] = row
			end
			local row = line({ "cybersyn-gui.relative-refuel",
				refuel >= 0 and { "cybersyn-gui.time-ago", logic.short_duration(refuel) } or { "cybersyn-gui.never" } })
			row.name = "refuel"
			out[#out + 1] = row
			return out
		end)
	end
end

local function render_schedule(state, body, m)
	local sig = tostring(state.schedule and state.schedule.tick) .. ":" .. tostring(m.current)
	if state.sigs["schedule"] ~= sig then
		section(state, body, "schedule", sig, function()
			local records = m.schedule
			if #records == 0 then return nil end
			local out = { heading({ "cybersyn-gui.relative-schedule" }) }
			for i, r in ipairs(records) do
				local row = rtext.schedule_row(i, r, m.current)
				out[#out + 1] = line(row.caption, nil, row.active and { 1, 0.74, 0.4 } or nil)
			end
			return out
		end)
	end
end

local function render_signal(state, body, m)
	local sig = m.signal and tostring(m.signal.unit_number) or ""
	if state.sigs["signal"] ~= sig then
		section(state, body, "signal", sig, function()
			if not m.signal then return nil end
			return {
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 8 },
					label({ "cybersyn-gui.relative-waiting-signal" }),
					{
						type = "button",
						name = "locate_signal",
						caption = { "cybersyn-gui.relative-locate" },
						tooltip = { "cybersyn-gui.relative-locate-signal-tooltip" },
						handler = { [defines.events.on_gui_click] = relative.handle.relative_locate_signal },
					},
				},
			}
		end)
	end
end

local function render_train_buttons(state, body, m, pd)
	local player = game.get_player(pd.player_index)
	if not player then return end
	-- In the manager's Trains pane the train is already the selected row: no Open in manager.
	local buttons_sig = (state.pane and "pane" or "train") .. extras_sig(player, pd, "train", state.id)
	if state.sigs["buttons"] ~= buttons_sig then
		section(state, body, "buttons", buttons_sig, function()
			if state.pane then
				return extras_rows(player, pd, "train", state.id, nil, {
					type = "button",
					name = "locate",
					caption = { "cybersyn-gui.relative-locate" },
					tooltip = { "cybersyn-gui.relative-locate-train-tooltip" },
					style_mods = { minimal_width = 0, left_padding = 8, right_padding = 8 },
					handler = { [defines.events.on_gui_click] = relative.handle.relative_locate_train },
				})
			end
			-- Beside the vanilla window the remote view already follows the train it opened: no Locate.
			return extras_rows(player, pd, "train", state.id,
				{
					type = "flow",
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
					{
						type = "button",
						name = "open_manager",
						caption = { "cybersyn-gui.relative-open-manager" },
						tooltip = { "cybersyn-gui.relative-open-manager-train-tooltip" },
						handler = { [defines.events.on_gui_click] = relative.handle.relative_open_manager },
					},
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
				})
		end)
	end
end

-- ---------------------------------------------------------------- refresh

local function render_banner(state, panel)
	-- mod_settings mirrors the setting (scripts/main.lua grab_all_settings), without a settings.global read per refresh.
	local paused = mod_settings.enable_planner == false and not state.pane
	local by = paused and storage.manager.paused_by or nil
	local sig = paused and ("p" .. tostring(by)) or ""
	if state.sigs.banner == sig then return end
	state.sigs.banner = sig
	local banner = panel.banner
	banner.visible = paused
	if paused then
		local who = by and by > 0 and game.get_player(by)
		banner.banner_label.caption = who and { "cybersyn-gui.dispatch-paused-by", who.name } or { "cybersyn-gui.dispatch-paused" }
		banner.banner_label.tooltip = { "cybersyn-gui.dispatch-paused-tooltip" }
	end
	-- The banner takes height from the train panel's body, which is capped to stay above the hotbar.
	if state.kind == "train" and not state.pane then relative.fit(game.get_player(panel.player_index), panel) end
end

local function render_caption(state, panel, m, pd)
	local now = game.tick
	local age = now - (m.read_tick or now)
	local sig = utext.read_step(age) .. (m.source or "")
	if state.sigs.caption ~= sig then
		state.sigs.caption = sig
		panel.subheader.caption_label.tooltip = { "", utext.read_ago(age),
			m.source == "live" and { "cybersyn-gui.relative-source-live" } or "" }
	end
	local open = pd.relative_effective_open == true
	local shown = m.sub == "station"
	local bsig = (open and "o" or "c") .. (shown and "s" or "h")
	if state.sigs.effective_button ~= bsig then
		state.sigs.effective_button = bsig
		local button = panel.subheader.effective_button
		button.toggled = open
		button.sprite = open and "utility/collapse" or "utility/expand"
		button.visible = shown
	end
end

--- Refreshes `panel` (a relative.build result) for state.kind/state.id; returns the model, nil when the subject is gone.
--- @param pd PlayerData
--- @param state RelativeState
--- @param panel LuaGuiElement
--- @return table?
function relative.render(pd, state, panel)
	local body = panel.scroll.body
	render_banner(state, panel)
	if state.kind == "stop" then
		local m = stop_model(pd, state)
		if not m then return nil end
		render_caption(state, panel, m, pd)
		render_stop_head(state, body, m)
		render_slots(state, body, m)
		local compact = pd.relative_effective_open == true
		render_unserved(state, body, m, compact)
		render_deliveries(state, body, m)
		render_control(state, body, m)
		render_setup(state, body, m, pd)
		render_effective(state, body, m)
		if m.sub == "station" then
			render_events(state, body, "station", state.id, compact and EVENTS_COMPACT or EVENTS)
		else
			if state.sigs["events"] ~= "" then section(state, body, "events", "", hidden) end
		end
		render_stop_buttons(state, panel.footer, m, pd)
		return m
	end
	local m = train_model(pd, state)
	if not m then return nil end
	render_caption(state, panel, m, pd)
	render_train_head(state, body, m)
	render_alert(state, body)
	render_manifest(state, body, m)
	render_route(state, body, m)
	render_schedule(state, body, m)
	render_signal(state, body, m)
	render_events(state, body, "train", state.id)
	render_train_buttons(state, panel.footer, m, pd)
	return m
end

-- ---------------------------------------------------------------- mounting

-- The stop panel is anchored to the train-stop window. Factorio's train window is the remote view's docked side pane,
-- and a relative GUI anchored to train_gui is drawn in the middle of the screen whatever its position (left, right,
-- top and bottom all land on the centre, over the train the view follows; there is no relative type for the docked
-- pane), so the train panel is a screen frame placed flush right of that pane. The pane's width cannot be
-- read: it is derived from how it was opened and the item groups with an item unlocked for the force (the Fuel tab's
-- ghost cursor selection; xlogic.train_pane_right), with constants measured on Factorio 2.1.23.
local ANCHORS = {
	stop = { gui = defines.relative_gui_type.train_stop_gui, position = defines.relative_gui_position.right, type = "train-stop" },
	-- A wagon opens its own window (in the middle of the screen), not the docked pane: the panel anchors to it.
	-- Factorio has no wagon GUI types: a cargo wagon's window is a container_gui. Fluid and artillery wagon windows
	-- are not known to match one, so they keep the docked-pane frame.
	cargo = { gui = defines.relative_gui_type.container_gui, position = defines.relative_gui_position.right, type = "cargo-wagon" },
}
-- The mount for a rolling stock window of its own; anything else (a locomotive) uses the screen frame.
local WAGON_MOUNT = { ["cargo-wagon"] = "cargo" }
-- The stop panel's body height, in logical px: an anchored panel taller than the train-stop window (767 px at 1080p
-- scale 1, measured on Factorio 2.1.23) stretches that window up under the remote view's title bar. Body + subheader +
-- footer + paddings stay below it.
local STOP_BODY_MAX = 600
local STOP_BODY_MIN = 120
local STOP_SCREEN_MARGIN = 300

--- @param player LuaPlayer
--- @param key string a MOUNT key
--- @return LuaGuiElement root
local function root_of(player, key)
	return key == "train" and player.gui.screen or player.gui.relative
end

--- The mount key of an open panel: its own, or its kind.
--- @param open {kind: string, mount: string?}
--- @return string
local function mount_key(open)
	return open.mount or open.kind
end

--- The mount of `kind` if it exists.
--- @return LuaGuiElement?
local function mount_of(player, kind)
	local frame = root_of(player, kind)[MOUNT[kind]]
	return frame and frame.valid and frame or nil
end

--- The player's mount for `kind`, created on first use.
--- @param player LuaPlayer
--- @param kind "stop"|"train"
--- @return LuaGuiElement mount
--- @return LuaGuiElement panel
local function mount(player, kind, key)
	key = key or kind
	local frame = mount_of(player, key)
	if frame and frame[PANEL] then return frame, frame[PANEL] end
	if frame then frame.destroy() end
	frame = root_of(player, key).add({ type = "frame", name = MOUNT[key], direction = "vertical", anchor = ANCHORS[key],
		visible = false })
	frame.style.padding = 8
	return frame, relative.build(frame, kind, nil)
end

--- The player's screen in physical px and UI scale.
--- @param player LuaPlayer
--- @return number width
--- @return number height
--- @return number scale
local function screen_of(player)
	local r = player.display_resolution
	return r.width, r.height, player.display_scale
end

-- What the Fuel tab's ghost cursor selection is built from, from prototypes only (the same in every Lua state of a
-- multiplayer game): the visible items of each item group, the recipes that unlock each item for filter selections
-- (an item no such recipe makes is always shown) and the group tabs per row.
local group_items, item_recipes, group_row_count

local function build_selection()
	group_items, item_recipes = {}, {}
	for name, item in pairs(prototypes.item) do
		local group = item.group
		if group and not (item.hidden or item.parameter) then
			local list = get_or_create(group_items, group.name)
			list[#list + 1] = name
		end
	end
	for name, recipe in pairs(prototypes.recipe) do
		if recipe.unlock_results then
			for _, product in pairs(recipe.products) do
				if product.type == "item" then
					local list = get_or_create(item_recipes, product.name)
					list[#list + 1] = name
				end
			end
		end
	end
	group_row_count = prototypes.utility_constants.select_group_row_count or 6
end

--- The item groups the ghost cursor selection shows a tab for: those with an item unlocked for the force (filter
--- selections show an item once an enabled recipe that unlocks results makes it, or always when none makes
--- it; measured: 11 tabs on one overhaul base, where 13 groups have visible items).
--- @param force LuaForce
--- @return int groups
--- @return int row_count
local function ghost_selection(force)
	if not group_items then build_selection() end
	local recipes = force.recipes
	local n = 0
	for _, items in pairs(group_items) do
		for _, name in ipairs(items) do
			local makers = item_recipes[name]
			local shown = makers == nil
			if not shown then
				for _, r in ipairs(makers) do
					local recipe = recipes[r]
					if recipe and recipe.enabled then
						shown = true
						break
					end
				end
			end
			if shown then
				n = n + 1
				break
			end
		end
	end
	return n, group_row_count
end

--- Places the train panel flush right of the docked pane, at its top, for the player's current screen.
--- @param player LuaPlayer
--- @param frame LuaGuiElement
--- @param open {pane_narrow: boolean?, groups: int?}
local function place_train(player, frame, open)
	local width, _, scale = screen_of(player)
	if not group_items then build_selection() end
	local edge = xlogic.train_pane_right(open.pane_narrow == true, open.groups or 0, group_row_count, scale)
	local x, y = xlogic.train_panel_place(edge, scale, width)
	frame.location = { x = x, y = y }
end

--- How the docked pane opening now for `entity` is laid out. Its Fuel tab shows the character's inventory while the
--- character can reach the locomotive, and is disabled when this very tick switched the player from the character to
--- remote view (the game does that to open a train from the character): both fit the narrow pane. That event order is
--- observed engine timing (Factorio 2.1.23), not API: the remote_entered_tick stamp covers on_gui_opened arriving
--- second and relative.on_controller_changed's re-place covers it arriving first, so neither can go alone. Otherwise
--- it shows the ghost cursor selection. Also returns the groups of that selection (0 without a burner, which has no
--- Fuel tab).
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param entity LuaEntity?
--- @return boolean narrow
--- @return int groups
local function pane_for(player, pd, entity)
	if not (entity and entity.valid and entity.type == "locomotive" and entity.prototype.burner_prototype) then
		return true, 0
	end
	local character = player.character
	local narrow = pd.remote_entered_tick == game.tick
		or (character ~= nil and character.valid and character.can_reach_entity(entity))
	if narrow then return true, 0 end
	return false, (ghost_selection(player.force))
end

--- Whether the stop panel is shown on this player's screen: only where the vanilla window and the panel
--- both fit. A narrower screen gets no panel, never a cut or overlapping one; "Open in manager" is the way there.
--- @param player LuaPlayer
--- @return boolean
function relative.stop_fits(player)
	local width, _, scale = screen_of(player)
	return xlogic.stop_panel_fits(width, scale)
end

--- Caps the panel's height to the player's screen: a stop with many requests, findings and events scrolls instead of
--- running off a 1080p screen at scale 1.
--- @param player LuaPlayer
--- @param panel LuaGuiElement a relative.build result
function relative.fit(player, panel)
	local _, h, scale = screen_of(player)
	local screen = math.floor(h / scale)
	local height
	if panel.tags.kind == "stop" then
		height = math.max(STOP_BODY_MIN, math.min(STOP_BODY_MAX, screen - STOP_SCREEN_MARGIN))
	else
		height = xlogic.train_body_cap(h, scale, panel.banner.visible and xlogic.TRAIN_PANEL_BANNER or 0)
	end
	local scroll = panel.scroll
	if scroll.style.maximal_height ~= height then scroll.style.maximal_height = height end
end

local function hide_all(player)
	for kind in pairs(MOUNT) do
		local frame = mount_of(player, kind)
		if frame and frame.visible then frame.visible = false end
	end
end

--- Closes the panel state of a player (the vanilla window closed, the player left).
--- @param player LuaPlayer?
--- @param pd PlayerData
function relative.close(player, pd)
	pd.relative_open = nil
	pd.relative = nil
	if player then hide_all(player) end
end

--- Shows the panel for a Cybersyn stop or train and renders it at once.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param kind "stop"|"train"
--- @param id uint
--- @param key string? the mount (WAGON_MOUNT for a wagon's window); default `kind`
--- @param entity LuaEntity? the entity whose window opened (the train panel's place depends on it)
function relative.open(player, pd, kind, id, key, entity)
	extras.on_selection(pd, kind, id)
	hide_all(player)
	key = key or kind
	local frame, panel = mount(player, kind, key)
	local state = pd.relative
	if not (state and state.kind == kind and state.id == id) then
		state = new_state(kind, id)
		pd.relative = state
	end
	panel.tags = { kind = kind, id = id }
	local open = { kind = kind, id = id, mount = key ~= kind and key or nil }
	pd.relative_open = open
	storage.manager.relative_any = true
	if key == "train" then
		open.tick = game.tick
		open.pane_narrow, open.groups = pane_for(player, pd, entity)
		place_train(player, frame, open)
	end
	if key == "stop" and not relative.stop_fits(player) then
		-- Still open, so a display change that makes room shows it (relative.on_display_changed); nothing renders.
		pd.relative_open.narrow = true
		return
	end
	relative.fit(player, panel)
	frame.visible = true
	state.burst = true
	local alive = relative.render(pd, state, panel)
	state.burst = nil
	if not alive then relative.close(player, pd) end
end

--- Mounts the panel of `kind`/`id` in `parent` inside the manager window (the Trains detail pane), reusing the one
--- already there, and renders it at once. relative.tick refreshes it while `pd.relative_pane_open` is set, the window
--- is open and shows the Trains tab; it has its own state (`pd.relative_pane`), so a vanilla window's panel can be
--- open beside it.
--- @param pd PlayerData
--- @param parent LuaGuiElement
--- @param kind "stop"|"train"
--- @param id uint
--- @param body_height int? the scroll body's height cap in logical px
--- @return LuaGuiElement? panel nil when the subject is gone (nothing stays mounted then)
function relative.mount(pd, parent, kind, id, body_height)
	local panel = parent[PANEL]
	if panel and panel.tags.kind ~= kind then
		panel.destroy()
		panel = nil
	end
	local state = pd.relative_pane
	if not panel then
		panel = relative.build(parent, kind, id)
		-- The pane's own subheader names the train and the tab shows the paused banner.
		panel.subheader.visible = false
		-- The scrollbar then sits inside the panel instead of widening it.
		panel.scroll.style.horizontally_stretchable = true
		-- The panel fills the pane and its footer sits at the pane's bottom, however short the body.
		panel.style.vertically_stretchable = true
		local pusher = panel.add({ type = "empty-widget", name = "footer_pusher",
			index = panel.scroll.get_index_in_parent() + 1, ignored_by_interaction = true })
		pusher.style.vertically_stretchable = true
		state = nil
	end
	if not (state and state.kind == kind and state.id == id) then
		state = new_state(kind, id)
		state.pane = true
		pd.relative_pane = state
	end
	panel.tags = { kind = kind, id = id, pane = true }
	local scroll = panel.scroll
	if body_height and scroll.style.maximal_height ~= body_height then scroll.style.maximal_height = body_height end
	pd.relative_pane_open = { kind = kind, id = id, panel = panel }
	storage.manager.relative_any = true
	state.burst = true
	local alive = relative.render(pd, state, panel)
	state.burst = nil
	if not alive then
		relative.unmount(pd)
		return nil
	end
	return panel
end

--- Removes the panel relative.mount put in the manager window, and its state.
--- @param pd PlayerData
function relative.unmount(pd)
	local pane = pd.relative_pane_open
	local panel = pane and pane.panel
	if panel and panel.valid then panel.destroy() end
	pd.relative_pane_open = nil
	pd.relative_pane = nil
end

--- What a vanilla window shows, as a relative panel subject: a Cybersyn stop or train, else nil.
--- @param entity LuaEntity
--- @return "stop"|"train"|nil kind
--- @return uint? id
--- @return boolean? cybersyn
local function subject_of(entity)
	if entity.type == "train-stop" then
		local id = entity.unit_number
		return "stop", id, (storage.stations[id] or storage.depots[id] or storage.refuelers[id]) ~= nil
	end
	if ROLLING_STOCK[entity.type] then
		local train = entity.train
		if not (train and train.valid) then return nil end
		return "train", train.id, storage.trains[train.id] ~= nil
	end
	return nil
end

--- on_gui_opened (registered unconditionally in scripts/main.lua).
--- @param e EventData.on_gui_opened
function relative.on_gui_opened(e)
	if e.gui_type ~= defines.gui_type.entity then return end
	local entity = e.entity
	if not (entity and entity.valid) then return end
	local manager_data = storage.manager
	local pd = manager_data and manager_data.players[e.player_index]
	local player = game.get_player(e.player_index)
	if not (pd and player) then return end
	local kind, id, cybersyn = subject_of(entity)
	if not kind then return end
	if not (cybersyn and settings.get_player_settings(player)["cybersyn-manager-panels"].value) then
		relative.close(player, pd)
		return
	end
	relative.open(player, pd, kind, id, WAGON_MOUNT[entity.type], entity)
end

--- on_gui_closed of any entity GUI hides the panels.
--- @param e EventData.on_gui_closed
function relative.on_gui_closed(e)
	if e.gui_type ~= defines.gui_type.entity then return end
	local manager_data = storage.manager
	local pd = manager_data and manager_data.players[e.player_index]
	if not (pd and pd.relative_open) then return end
	relative.close(game.get_player(e.player_index), pd)
end

--- Whether the player still has the vanilla window of the panel's subject open. on_gui_closed is the main path that
--- closes a panel; this poll is the fallback for the cases no event reports: a save loaded with the window open opens
--- no entity GUI, a wagon's train id changes (coupling or uncoupling) while its window stays open, and the train panel
--- is a screen frame nothing else hides.
--- @param player LuaPlayer
--- @param open {kind: "stop"|"train", id: uint}
--- @return boolean
local function window_open(player, open)
	if player.opened_gui_type ~= defines.gui_type.entity then return false end
	local entity = player.opened
	if not (entity and entity.valid and entity.object_name == "LuaEntity") then return false end
	if open.kind == "stop" then return entity.type == "train-stop" and entity.unit_number == open.id end
	if not ROLLING_STOCK[entity.type] then return false end
	local train = entity.train
	return train ~= nil and train.valid and train.id == open.id
end

local pane_gone_fn

--- Lets the Trains tab hear that its detail pane's train is gone, without a require cycle.
--- @param fn fun(player: LuaPlayer, pd: PlayerData)
function relative.set_pane_gone(fn)
	pane_gone_fn = fn
end

--- Refreshes the panel mounted in the manager (relative.mount) while the window shows the Trains tab.
--- @param manager_data Manager
--- @param i uint
--- @param pd PlayerData
local function tick_pane(manager_data, i, pd)
	local pane = pd.relative_pane_open
	local panel = pane.panel
	local state = pd.relative_pane
	if not (panel and panel.valid and state) then
		pd.relative_pane_open = nil
		pd.relative_pane = nil
		return
	end
	if not (pd.is_manager_open and pd.selected_tab == "trains_tab") then return end
	local alive = relative.render(pd, state, panel)
	if not alive then
		relative.unmount(pd)
		local player = game.get_player(i)
		if player and pane_gone_fn then pane_gone_fn(player, pd) end
	end
end

--- The manager tick: refreshes every open panel, and closes one whose vanilla window is gone.
--- @param manager_data Manager
function relative.tick(manager_data)
	-- Set whenever a panel opens and cleared here once none is open, so a tick without panels walks no players.
	if not manager_data.relative_any then return end
	local any = false
	for i, pd in pairs(manager_data.players) do
		if pd.relative_pane_open then
			any = true
			tick_pane(manager_data, i, pd)
		end
		local open = pd.relative_open
		if open then
			any = true
			local player = game.get_player(i)
			local frame = player and mount_of(player, mount_key(open))
			local panel = frame and frame[PANEL]
			local state = pd.relative
			if not (panel and state) then
				pd.relative_open = nil
				pd.relative = nil
			elseif not window_open(player, open) then
				relative.close(player, pd)
			elseif open.narrow then
				-- Hidden on a narrow screen: the window check above is all it costs.
			else
				local alive = relative.render(pd, state, panel)
				if not alive then relative.close(player, pd) end
			end
		end
	end
	if not any then manager_data.relative_any = nil end
end

--- A display scale or resolution change: the train panel's place and the body's height cap follow it.
--- @param player LuaPlayer
--- @param pd PlayerData
function relative.on_display_changed(player, pd)
	local open = pd.relative_open
	if not open then return end
	local frame = mount_of(player, mount_key(open))
	local panel = frame and frame[PANEL]
	if not panel then return end
	if mount_key(open) == "train" then place_train(player, frame, open) end
	if mount_key(open) == "stop" then
		local fits = relative.stop_fits(player)
		if fits == (open.narrow == nil) then
			if frame.visible then relative.fit(player, panel) end
			return
		end
		if not fits then
			open.narrow = true
			frame.visible = false
			return
		end
		open.narrow = nil
		relative.fit(player, panel)
		frame.visible = true
		local state = pd.relative
		if state then
			state.burst = true
			local alive = relative.render(pd, state, panel)
			state.burst = nil
			if not alive then relative.close(player, pd) end
		end
		return
	end
	relative.fit(player, panel)
end

--- on_player_controller_changed: the game switches from the character to remote view to open a train from the
--- character, in the same tick as the locomotive's on_gui_opened (either order, observed on Factorio 2.1.23); a panel
--- opened earlier in this tick is placed again for the narrow pane. The stamp and the re-place depend on each other
--- (pane_for).
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param e EventData.on_player_controller_changed
function relative.on_controller_changed(player, pd, e)
	if not (e.old_type == defines.controllers.character
		and player.controller_type == defines.controllers.remote) then
		return
	end
	pd.remote_entered_tick = game.tick
	local open = pd.relative_open
	if not (open and open.tick == game.tick and mount_key(open) == "train") then return end
	local frame = mount_of(player, "train")
	if not frame then return end
	open.pane_narrow = true
	place_train(player, frame, open)
end

--- Drops a player's mounts and panel state (a mod update may change the panel's skeleton; mount() reuses a mount).
--- @param player LuaPlayer
--- @param pd PlayerData
function relative.reset(player, pd)
	pd.relative_open = nil
	pd.relative = nil
	relative.unmount(pd)
	for kind in pairs(MOUNT) do
		local frame = mount_of(player, kind)
		if frame then frame.destroy() end
	end
end

--- A schedule change of the train an open panel shows: read its records again on the next render.
--- @param e EventData.on_train_schedule_changed
function relative.on_train_schedule_changed(e)
	local manager_data = storage.manager
	if not (manager_data and manager_data.relative_any) then return end
	-- Cybersyn changes a schedule on every dispatch: read the train only when some train panel is open, and allocate
	-- nothing.
	local id
	for _, pd in pairs(manager_data.players) do
		for k = 1, 2 do
			local state = k == 1 and pd.relative or pd.relative_pane
			if state and state.kind == "train" then
				if not id then
					local train = e.train
					if not (train and train.valid) then return end
					id = train.id
				end
				if state.id == id then state.schedule = nil end
			end
		end
	end
end

-- ---------------------------------------------------------------- handlers

relative.wrapper = util.wrapper

--- The state of the panel a click came from: the one mounted in the manager (relative.mount) or the one beside the
--- vanilla window.
--- @param pd PlayerData
--- @param e {element: LuaGuiElement}?
--- @return RelativeState?
local function state_of(pd, e)
	local elem = e and e.element
	while elem and elem.valid do
		if elem.name == PANEL then
			if elem.tags.pane then return pd.relative_pane end
			return pd.relative
		end
		elem = elem.parent
	end
	return pd.relative
end

local function rerender(player, pd)
	local open = pd.relative_open
	if not open then return end
	local frame = mount_of(player, mount_key(open))
	local panel = frame and frame[PANEL]
	local state = pd.relative
	if panel and state then
		state.burst = true
		relative.render(pd, state, panel)
		state.burst = nil
	end
end

--- @param player LuaPlayer
--- @param pd PlayerData
function relative.handle.relative_toggle_effective(player, pd)
	pd.relative_effective_open = not pd.relative_effective_open or nil
	local state = pd.relative
	if state then
		state.sigs.effective = nil
		state.fleet = nil
		state.eff = nil
	end
	rerender(player, pd)
end

--- Opens the manager on the Stations tab with the station chip on this stop (by id, so a name that is a
--- substring of other names, "R", shows only this stop; a depot or refueler: the Trains tab searching its name), or on
--- the Trains tab with the train chip on a train; manager.focus clears everything else that could hide it.
--- @param player LuaPlayer
--- @param pd PlayerData
function relative.open_manager(player, pd, state)
	state = state or pd.relative
	if not state then return end
	if state.kind == "train" then
		manager.focus(player, pd, "trains_tab", { train = state.id, reveal = { train = state.id } })
		return
	end
	local station = storage.stations[state.id]
	local kind = station and "station" or storage.depots[state.id] and "depot" or "refueler"
	local name = stop_name(kind, state.id)
	if not name then return end
	if station then
		manager.focus(player, pd, "stations_tab", { station = state.id })
	else
		manager.focus(player, pd, "trains_tab", { query = name,
			reveal = { group = kind == "depot" and name or trains_tab.REFUELERS } })
	end
end

function relative.handle.relative_open_manager(player, pd, refs, e)
	relative.open_manager(player, pd, state_of(pd, e))
end

--- comb1 / comb2 tool buttons: the station's (or depot's, refueler's) combinators.
function relative.handle.relative_comb(player, pd, refs, e)
	local state = state_of(pd, e)
	if not state or state.kind ~= "stop" then return end
	local which = e.element.name
	local station = storage.stations[state.id]
	local record = station or storage.depots[state.id] or storage.refuelers[state.id]
	local comb
	if station then
		comb = which == "comb2" and station.entity_comb2 or station.entity_comb1
	else
		comb = record and record.entity_comb
	end
	if comb and comb.valid then
		nav.open_entity(player, pd, comb)
	else
		util.error_flying_text(player, { "cybersyn-message.error-cybernetic-combinator-not-found" })
	end
end

function relative.handle.relative_locate_train(player, pd, refs, e)
	local state = state_of(pd, e)
	local train = state and state.kind == "train" and storage.trains[state.id]
	local entity = train and train.entity
	local front = entity and entity.valid and entity.front_stock
	if front then links.show_on_map(player, pd, front, front) end
end

function relative.handle.relative_locate_signal(player, pd, refs, e)
	local state = state_of(pd, e)
	local train = state and state.kind == "train" and storage.trains[state.id]
	local entity = train and train.entity
	local signal = entity and entity.valid and entity.signal
	if signal and signal.valid then links.show_on_map(player, pd, signal) end
end

-- The footer tool buttons find their subject from the panel's tags (mountable anywhere) and repaint the panel
-- they sit in at once, so an armed "Confirm?" or a drawn trace shows on the click, not on the next manager tick.
repair.subject = extras.panel_subject
extras.on_change = rerender
repair.on_change = rerender

gui.add_handlers(relative.handle, relative.wrapper, "cybersyn_relative")

return relative
