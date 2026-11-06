-- Overview tab: four tiles and one full-width table of the requests the dispatcher is not serving now,
-- with the reason it recorded for each (scripts/diag.lua). The table and the Unserved and Stations failing tiles obey
-- network name, network ID, surface and item, matched on the requester; Fleet headroom the network name
-- only; Throughput none. There is no station search here.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local pm = require("scripts.gui.problems-model")
local sync = require("scripts.gui.utils.sync")
local filters = require("scripts.gui.utils.filters")
local hover = require("scripts.gui.utils.hover")
local links = require("scripts.gui.utils.links")
local nav = require("scripts.gui.utils.nav")
local rich_text = require("scripts.gui.rich-text")
local metrics = require("scripts.gui.metrics")
local collector = require("scripts.gui.collector")
local stats = require("scripts.stats")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local text = require("scripts.gui.unserved-text")
local rtext = require("scripts.gui.relative-text")
local explain = require("scripts.gui.explain")
local extras_logic = require("scripts.gui.extras-logic")
local name_cell = require("scripts.gui.name-cell")
local logic = require("scripts.gui.tab-logic")

local overview_tab = {}

local TAB = "overview_tab"
local TABLE = "overview_unserved_table"
local PERIODS, DEFAULT_PERIOD = logic.PERIODS, logic.DEFAULT_PERIOD
local NO_VALUE = text.NO_VALUE
-- Tile 1's body: line 1 the requests older than N minutes, then two reasons and a third line (the third reason or
-- the rest summed).
local TOP_REASONS = 2
local MAX_TOOLTIP_NETWORKS = 12
local TABLE_COLUMNS = 8
-- Logical px at the 1,392 px content width of a 1,440 px window; the requester column takes the rest.
-- The Why cell holds the 132 px reason chip and room for the Setup marker beside it.
local W = { item = 32, why = 176, provider = 272, stock = 110, lost = 96, wait = 72, ack = 28 }
local CHIP_W = 132
local BASE_CONTENT_WIDTH = 1392
local REQUESTER_MIN, PROVIDER_MIN = 160, 120
local TABLE_PADDING = metrics.TABLE_LEFT_PADDING + metrics.TABLE_RIGHT_PADDING
local TABLE_SPACING = metrics.TABLE_SPACING
local FRAME_BORDER = metrics.FRAME_BORDER
-- The Why cell's "Setup" marker beside the reason chip.
local MARKER_W = 40
local ROW_H = 32

--- @class OverviewTileDef
--- @field name string
--- @field sprite string
--- @field lines int

--- @type OverviewTileDef[]
local TILES = {
	{ name = "unserved", sprite = "utility/warning_icon", lines = 4 },
	{ name = "fleet", sprite = "item/locomotive", lines = 3 },
	{ name = "failing", sprite = "item/train-stop", lines = 4 },
	{ name = "throughput", sprite = "item/cargo-wagon", lines = 4 },
}
local FAILING_LINES = { "no_power", "disabled", "throttling", "misconfigured" }

local get_period = logic.get_period

-- Requests waiting longer than this make tile 1's first line; shorter waits are normal between planner cycles.
local UNSERVED_MINUTES = 5

-- ---------------------------------------------------------------- build

--- Stations failing's Misconfigured line jumps on its own: to the Stations tab's Problems chip.
local LINK_LINES = { failing4 = true }
local TILE_H = metrics.TILE_HEIGHT
-- The link line overlays the button's last line slot: one line and the body's bottom padding.
local LINK_H = metrics.TILE_LINE_HEIGHT + metrics.TILE_PADDING

local function line_def(tile, i)
	local base = "overview_" .. tile.name .. "_line" .. i
	local link = LINK_LINES[tile.name .. i]
	return {
		type = "flow",
		name = base,
		direction = "horizontal",
		style = "cybersyn_overview_line_flow",
		ignored_by_interaction = not link,
		link and {
			type = "button",
			name = base .. "_label",
			style = "cybersyn_overview_line_link",
			caption = "",
			handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_problems_click },
		} or { type = "label", name = base .. "_label", style = "cybersyn_overview_line_label", caption = "" },
		{ type = "empty-widget", style = "flib_horizontal_pusher", ignored_by_interaction = true },
		{ type = "label", name = base .. "_value", style = "cybersyn_overview_line_value", caption = "",
			ignored_by_interaction = link or nil },
	}
end

--- @param tile OverviewTileDef
local function tile_def(tile)
	local body = {
		type = "flow",
		direction = "vertical",
		style = "cybersyn_overview_tile_body",
		ignored_by_interaction = true,
		{
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_overview_tile_header",
			{
				type = "sprite",
				style = "cybersyn_overview_tile_icon",
				sprite = tile.sprite,
				resize_to_sprite = false,
			},
			{ type = "label", name = "overview_" .. tile.name .. "_caption", style = "cybersyn_overview_tile_caption" },
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{ type = "label", name = "overview_" .. tile.name .. "_note", style = "cybersyn_subheader_note", caption = "" },
			{ type = "label", name = "overview_" .. tile.name .. "_headline", style = "cybersyn_overview_big_number", caption = NO_VALUE },
		},
	}
	local link
	for i = 1, tile.lines do
		if LINK_LINES[tile.name .. i] then
			link = line_def(tile, i)
		else
			body[#body + 1] = line_def(tile, i)
		end
	end
	local button = {
		type = "button",
		name = "overview_tile_" .. tile.name,
		style = "cybersyn_overview_tile",
		tags = { tile = tile.name },
		handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_tile_click },
		body,
	}
	if not link then return button end
	-- A button's ignored body cannot hold a clickable child, so the line that jumps on its own is a sibling laid over
	-- the full-height button's last line slot by a negative margin (the later sibling draws on top and takes the
	-- input). The wrapper draws nothing, so the tile's chrome and hover glow stay the button's own, like the others.
	link.style_mods = { left_padding = 10, right_padding = 10, height = metrics.TILE_LINE_HEIGHT, top_margin = -LINK_H }
	return {
		type = "frame",
		name = "overview_tile_" .. tile.name .. "_frame",
		direction = "vertical",
		style = "invisible_frame",
		style_mods = { height = TILE_H },
		button,
		link,
	}
end

local function header_cell(caption, width, right, name)
	return {
		type = "label",
		name = name,
		style = right and "cybersyn_unserved_header_value" or "cybersyn_unserved_header",
		style_mods = { width = width },
		caption = caption,
	}
end

--- The subheader's right side; manager.lua puts it after the shared search field, chip and progress note.
--- @return flib.GuiElemDef[]
function overview_tab.subheader_right()
	local period_items = {}
	local default_index = 1
	for i, minutes in ipairs(PERIODS) do
		period_items[i] = { "cybersyn-gui.overview-period-" .. minutes }
		if minutes == DEFAULT_PERIOD then default_index = i end
	end
	return {
		{
			type = "checkbox",
			name = "overview_show_acked",
			caption = { "cybersyn-gui.overview-show-acked", "0" },
			tooltip = { "cybersyn-gui.overview-show-acked-tooltip" },
			state = false,
			handler = { [defines.events.on_gui_checked_state_changed] = overview_tab.handle.overview_show_acked },
		},
		{ type = "empty-widget", style_mods = { width = 12 } },
		{
			type = "label",
			style = "subheader_caption_label",
			caption = { "cybersyn-gui.overview-period" },
			tooltip = { "cybersyn-gui.overview-period-tooltip" },
		},
		{
			type = "drop-down",
			name = "overview_period_dropdown",
			style = "cybersyn_overview_period_dropdown",
			items = period_items,
			selected_index = default_index,
			tooltip = { "cybersyn-gui.overview-period-tooltip" },
			handler = { [defines.events.on_gui_selection_state_changed] = overview_tab.handle.overview_period_changed },
		},
	}
end

function overview_tab.create()
	local tiles = {
		type = "flow",
		name = "overview_tile_row",
		direction = "horizontal",
		style = "cybersyn_overview_tile_row",
	}
	for _, tile in ipairs(TILES) do
		tiles[#tiles + 1] = tile_def(tile)
	end

	local tbl = {
		type = "table",
		name = TABLE,
		style = "cybersyn_unserved_table",
		column_count = TABLE_COLUMNS,
		header_cell("", W.item),
		header_cell({ "cybersyn-gui.unserved-col-requester" }, nil, false, "overview_unserved_h_requester"),
		header_cell({ "cybersyn-gui.unserved-col-why" }, W.why),
		header_cell({ "cybersyn-gui.unserved-col-provider" }, W.provider, false, "overview_unserved_h_provider"),
		header_cell({ "cybersyn-gui.unserved-col-stock" }, W.stock, true),
		header_cell({ "cybersyn-gui.unserved-col-lost" }, W.lost),
		header_cell({ "cybersyn-gui.unserved-col-wait" }, W.wait, true),
		header_cell("", W.ack),
	}
	tbl[5].tooltip = { "cybersyn-gui.unserved-col-stock-tooltip" }
	tbl[6].tooltip = { "cybersyn-gui.unserved-col-lost-tooltip" }
	tbl[7].tooltip = { "cybersyn-gui.unserved-col-wait-tooltip" }

	return {
		tab = {
			name = "manager_overview_tab",
			type = "tab",
			caption = { "cybersyn-gui.overview" },
		},
		content = {
			name = "manager_overview_content_frame",
			type = "flow",
			direction = "vertical",
			style = "cybersyn_overview_content",
			tiles,
			{
				type = "frame",
				name = "overview_unserved_frame",
				direction = "vertical",
				style = "cybersyn_unserved_frame",
				{
					type = "frame",
					direction = "horizontal",
					style = "cybersyn_unserved_caption_frame",
					{ type = "label", name = "overview_unserved_table_caption", style = "subheader_caption_label",
						caption = { "cybersyn-gui.unserved-caption" } },
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					{ type = "label", name = "overview_unserved_dropped", style = "cybersyn_subheader_note", visible = false },
					{
						type = "button",
						name = "overview_unserved_count",
						style = "cybersyn_unserved_count_button",
						caption = "",
						tooltip = { "cybersyn-gui.unserved-count-tooltip" },
						handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_count_click },
					},
				},
				{
					type = "flow",
					name = "overview_unserved_body",
					direction = "vertical",
					style_mods = { vertical_spacing = 0 },
					tbl,
					{
						type = "flow",
						name = "overview_unserved_empty_flow",
						direction = "horizontal",
						style = "cybersyn_overview_empty_flow",
						visible = false,
						{
							type = "label",
							name = "overview_unserved_empty",
							style = "cybersyn_overview_empty_label",
							caption = { "cybersyn-gui.unserved-empty" },
						},
					},
				},
			},
		},
	}
end

--- Sizes from the window layout: tile widths, the two stretching columns and the table body's height (whole rows).
--- @param player_data PlayerData
--- @param layout ManagerLayout
function overview_tab.apply_layout(player_data, layout)
	local refs = player_data.refs
	local cw = layout.content_width
	local rows = layout.rows_by_tab[TAB]
	local tile = math.floor((cw - 3 * 12) / 4)
	local provider = math.floor(W.provider * math.min(cw, BASE_CONTENT_WIDTH) / BASE_CONTENT_WIDTH)
	local fixed = W.item + W.why + provider + W.stock + W.lost + W.wait + W.ack
	local requester = cw - FRAME_BORDER - TABLE_PADDING - (TABLE_COLUMNS - 1) * TABLE_SPACING - fixed
	-- Windows below 960 px (screens narrower than that): the provider gives way so the requester keeps its name.
	if requester < REQUESTER_MIN then
		local give = math.max(0, math.min(provider - PROVIDER_MIN, REQUESTER_MIN - requester))
		provider, requester = provider - give, requester + give
	end
	local widths = { tile = tile, requester = requester, provider = provider, rows = rows }
	for _, t in ipairs(TILES) do
		local button = refs["overview_tile_" .. t.name]
		if button and button.valid then
			button.style.width = tile
			local body = button.children[1]
			body.style.width = tile
			body.style.height = TILE_H
			local frame = refs["overview_tile_" .. t.name .. "_frame"]
			if frame and frame.valid then
				frame.style.width = tile
				frame.children[2].style.width = tile
			end
		end
	end
	local old = player_data.tabs.overview_tab.widths
	player_data.tabs.overview_tab.widths = widths
	local h_req, h_prov = refs.overview_unserved_h_requester, refs.overview_unserved_h_provider
	if h_req and h_req.valid then h_req.style.width = requester end
	if h_prov and h_prov.valid then h_prov.style.width = provider end
	local body = refs.overview_unserved_body
	if body and body.valid then body.style.height = 20 + rows * 32 end
	local empty = refs.overview_unserved_empty_flow
	if empty and empty.valid then empty.style.height = rows * 32 end
	-- Rows built for other widths are rebuilt rather than restyled cell by cell.
	if not old or old.requester ~= requester or old.provider ~= provider then
		local tbl = refs[TABLE]
		if tbl and tbl.valid then
			local children = tbl.children
			for i = #children, TABLE_COLUMNS + 1, -1 do children[i].destroy() end
		end
		local state = sync.gui_state(player_data, TABLE)
		state.keys, state.sigs, state.hide = nil, nil, nil
		if tbl and tbl.valid then
			tbl.children[5].style.width = W.stock
			tbl.children[5].caption = { "cybersyn-gui.unserved-col-stock" }
			tbl.children[6].style.width = W.lost
			tbl.children[6].caption = { "cybersyn-gui.unserved-col-lost" }
		end
	end
end

-- ---------------------------------------------------------------- model

--- @param a table
--- @param b table
--- @return boolean
local function row_before(a, b)
	local ea, eb = a.e, b.e
	if ea.first_tick ~= eb.first_tick then return ea.first_tick < eb.first_tick end
	local sa, sb = REASON_SEVERITY[ea.reason] or DIAG_SEV_INFO, REASON_SEVERITY[eb.reason] or DIAG_SEV_INFO
	if sa ~= sb then return sa < sb end
	if a.r_id ~= b.r_id then return a.r_id < b.r_id end
	return a.hash < b.hash
end

--- Keeps `list` sorted by row_before and at most `k` long; allocates only for a row that makes the cut.
local function top_k(list, k, r_id, hash, e)
	local n = #list
	if n >= k then
		local last = list[n].e
		if e.first_tick > last.first_tick then return end
	end
	local row = { r_id = r_id, hash = hash, e = e }
	if n >= k then
		if not row_before(row, list[n]) then return end
		list[n] = nil
		n = n - 1
	end
	local i = n
	while i >= 1 and row_before(row, list[i]) do
		list[i + 1] = list[i]
		i = i - 1
	end
	list[i + 1] = row
end

--- @param a table
--- @param b table
--- @return boolean
local function counts_before(a, b)
	if a[2] ~= b[2] then return a[2] > b[2] end
	return a[1] < b[1]
end

--- The diagnostics walk: the table's rows (top `rows` by wait, acknowledged ones apart) and the Unserved tile's
--- request counts, for the filters (the requester's network name, network ID and surface, the entry's item). One
--- pass over the unserved entries, never over the stations; the place filters are decided once per requester. The
--- tile's station count is not taken here: it comes from the snapshot records (station_part), the Unserved chip's rule.
--- @param d DiagState
--- @param f ManagerFilters filters.get(player_data, "overview_tab")
--- @param stations {[uint]: SnapshotStation}
--- @param rows int
--- @param threshold int ticks a request must have waited for the tile
--- @param now uint
--- @return table
local function unserved_model(d, f, stations, rows, threshold, now)
	local out = {
		open = {}, acked = {}, total = 0, acked_total = 0, old = 0, old_acked = 0, reasons = {},
	}
	local want_ix
	local item = f.item
	if item then
		want_ix = d.item_ix[item]
		if not want_ix then want_ix = -1 end
	end
	local acks = storage.acks
	local ack_requests = acks and acks.request
	local reasons = out.reasons
	local passes = filters.requester_passes
	local none = {}
	for r_id, by_item in pairs(d.unserved) do
		local by_ack = ack_requests and ack_requests[r_id]
		if not passes(r_id, stations, f) then by_item = none end
		for ix, e in pairs(by_item) do
			local reason = e.reason
			if not want_ix or ix == want_ix then
				local hash = d.item_hash[ix]
				local acked = by_ack and by_ack[hash] and diag.is_acked("request", r_id, hash) ~= nil
				local old = now - e.first_tick >= threshold
				if acked then
					out.acked_total = out.acked_total + 1
					if old then out.old_acked = out.old_acked + 1 end
					top_k(out.acked, rows, r_id, hash, e)
				else
					out.total = out.total + 1
					if old then
						out.old = out.old + 1
						reasons[reason] = (reasons[reason] or 0) + 1
					end
					top_k(out.open, rows, r_id, hash, e)
				end
			end
		end
	end
	local sorted = {}
	for reason, n in pairs(reasons) do sorted[#sorted + 1] = { reason, n } end
	table.sort(sorted, counts_before)
	out.sorted_reasons = sorted
	return out
end

local band = bit32.band
local F_NO_POWER, F_DISABLED, F_THROTTLING = logic.FLAG_NO_POWER, logic.FLAG_DISABLED, logic.FLAG_THROTTLING
local F_UNSERVED, FAILING = logic.FLAG_UNSERVED, logic.FAILING
local COUNTED = bit32.bor(FAILING, F_UNSERVED)

local lint_error_mask = pm.error_mask

--- One station's part of tiles 1 and 3: its Failing and Unserved flags (tab-logic, the flags the Stations tab's
--- Failing and Unserved chips list) and its error lint bits, or nil when it does not count or does not pass the
--- filters. The same record, flags and station_passes as those chips, so each tile counts the rows its jump lists.
--- @param st SnapshotStation?
--- @param f ManagerFilters
--- @return int? flags
--- @return int errors
local function station_part(st, f)
	if not st then return nil, 0 end
	local flags = band(logic.station_flags(st), COUNTED)
	if flags == 0 then return nil, 0 end
	if not filters.station_passes(st, f) then return nil, 0 end
	return flags, band(st.lint or 0, lint_error_mask())
end

--- @param c table the counts
--- @param flags int
--- @param sign int 1 adds the station, -1 takes it out
local function failing_add(c, flags, sign)
	if band(flags, F_UNSERVED) ~= 0 then c.unserved = c.unserved + sign end
	if band(flags, FAILING) == 0 then return end
	c.total = c.total + sign
	if band(flags, F_NO_POWER) ~= 0 then c.no_power = c.no_power + sign end
	if band(flags, F_DISABLED) ~= 0 then c.disabled = c.disabled + sign end
	if band(flags, F_THROTTLING) ~= 0 then c.throttling = c.throttling + sign end
end

--- The Misconfigured line: stations with an error-severity finding that is not acknowledged, and apart the
--- stations whose error findings are all acknowledged; findings by check. Walks only the stations with error bits
--- (72 of 2,030 on a large base), every update, so acknowledgements and their expiry need no cache key.
--- @param errs {[uint]: int} station id -> error lint bits
--- @return {stations: int, acked: int, findings: int, by_check: {[int]: int}}
local function misconfigured(errs)
	local out = { stations = 0, acked = 0, findings = 0, by_check = {} }
	local by_check = out.by_check
	local open_errors = util.open_setup_errors
	for id, mask in pairs(errs) do
		local open = open_errors(id, mask, by_check)
		if open > 0 then
			out.stations = out.stations + 1
			out.findings = out.findings + open
		else
			out.acked = out.acked + 1
		end
	end
	return out
end

--- Stations failing: status, throttling and lint bits from the records as they are now, the same fields the
--- Stations chips count. Walking 2,030 records cost 0.85 ms per update, so the counts are kept per player
--- and updated from the collector's change log (the records it replaced or reclassified and the lint masks written
--- since), as the Stations tab's classification is; a filter change or a log reset walks them again.
--- @param player_data PlayerData
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @return table
local function failing_model(player_data, snapshot, f)
	local cache = player_data.cache.failing
	local epoch, pos = collector.log_position()
	local fsig = filters.filter_signature(f)
	local ids, first, last
	if cache and cache.fsig == fsig then
		ids, first, last = collector.changed_since(cache.epoch, cache.pos)
	end
	local stations = snapshot.stations
	if ids then
		local parts, errs, c = cache.parts, cache.errs, cache.counts
		local seen = {}
		for i = first, last do
			local id = ids[i]
			if not seen[id] then
				seen[id] = true
				local old = parts[id]
				if old then failing_add(c, old, -1) end
				local flags, e = station_part(stations[id], f)
				parts[id] = flags
				errs[id] = flags and e ~= 0 and e or nil
				if flags then failing_add(c, flags, 1) end
			end
		end
	else
		local c = { no_power = 0, disabled = 0, throttling = 0, total = 0, unserved = 0 }
		local parts, errs = {}, {}
		for id, st in pairs(stations) do
			local flags, e = station_part(st, f)
			if flags then
				parts[id] = flags
				if e ~= 0 then errs[id] = e end
				failing_add(c, flags, 1)
			end
		end
		cache = { fsig = fsig, parts = parts, errs = errs, counts = c }
		player_data.cache.failing = cache
	end
	cache.epoch, cache.pos = epoch, pos
	local c = cache.counts
	return {
		total = c.total, no_power = c.no_power, disabled = c.disabled, throttling = c.throttling, unserved = c.unserved,
		misconfigured = misconfigured(cache.errs),
	}
end

--- Fleet headroom: the network whose fewest available trains over the period is lowest, or the filtered network
--- (counts are kept per network name only: network ID and surface do not apply). "Now" is the HUD's free trains: the
--- fewest available on any network right now (extras-logic hud_values), or the filtered network's.
--- @param window StatsWindow
--- @param network string? the network name filter
--- @return table
local function fleet_model(window, network)
	local mins = window.min_available_by_network
	local s = stats.get()
	local now = s.available_count
	-- The counters only know networks that had a train available at some point; a network whose trains are all
	-- busy or stuck since the load is the worst of all, at 0.
	local seen = s.trains_by_network
	for name in pairs(seen) do
		if mins[name] == nil then mins[name] = 0 end
	end
	local names = {}
	for name in pairs(mins) do names[#names + 1] = name end
	table.sort(names, function(a, b)
		if mins[a] ~= mins[b] then return mins[a] < mins[b] end
		return a < b
	end)
	local worst = names[1]
	local free_now = extras_logic.hud_values({}, now, seen).headroom
	if network then
		local known = mins[network] ~= nil or now[network] ~= nil
		worst = known and network or nil
		free_now = known and (now[network] or 0) or nil
	end
	local minutes = math.max(window.span_ticks / 3600, 1 / 60)
	local per_minute = window.deliveries / minutes
	local busy = window.cycle_avg and per_minute * window.cycle_avg / 60 or nil
	return {
		worst = worst,
		network = network,
		headline = worst and mins[worst] or nil,
		now = free_now,
		failures = window.no_train_failures,
		names = names,
		mins = mins,
		current = now,
		per_minute = per_minute,
		trip = window.cycle_avg,
		busy = busy,
	}
end

--- Everything the tab shows, from the snapshot, storage.diag and storage.stats.
--- @param player_data PlayerData
--- @return table
function overview_tab.model(player_data)
	local snapshot = collector.get()
	local now = game.tick
	local f = filters.get(player_data, TAB)
	local item = f.item
	local period = get_period(player_data)
	local minutes = UNSERVED_MINUTES
	local layout = player_data.layout
	local rows = layout and layout.rows_by_tab[TAB] or 10
	local window = stats.aggregate(period, true)
	local d = storage.diag
	local collecting = snapshot.tick == nil
	local unserved = d and unserved_model(d, f, snapshot.stations, rows, minutes * 3600, now) or nil
	local failing = not collecting and failing_model(player_data, snapshot, f) or nil
	-- Tile 1's headline: the stations the Stations tab's Unserved chip lists under these filters.
	if unserved then unserved.stations = failing and failing.unserved end
	local cycle = stats.get().cycle
	return {
		now = now,
		item = item,
		filters = f,
		filtered = filters.place_filters_active(f),
		lint_pending = lint.progress(),
		period = period,
		minutes = minutes,
		rows = rows,
		collecting = collecting,
		diag = d ~= nil,
		inherit_before = d and diag.inherit_threshold(d) or 0,
		dropped = d and d.unserved_dropped or 0,
		unserved = unserved,
		failing = failing,
		fleet = fleet_model(window, f.network),
		throughput = {
			deliveries = window.deliveries,
			amount = window.amount,
			dispatches = window.dispatches,
			trip = window.cycle_avg,
			wait_avg = window.wait_avg,
			wait_max = window.wait_max,
			recorded = window.partial and window.span_ticks or nil,
			cycle_ticks = cycle.ticks_last or 0,
			cycle_dispatches = cycle.dispatches_last or 0,
		},
	}
end

-- ---------------------------------------------------------------- render: tiles

local set_caption = sync.set_if_changed

--- Whether set_tooltip would write `sig` (so the tooltip is built only then).
--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @return boolean
local function tooltip_due(cache, elem, sig)
	return elem ~= nil and elem.valid and cache[elem.name .. "#tooltip"] ~= sig
end

--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @param tooltip LocalisedString
local function set_tooltip(cache, elem, sig, tooltip)
	if not (elem and elem.valid) then return end
	local key = elem.name .. "#tooltip"
	if cache[key] == sig then return end
	cache[key] = sig
	elem.tooltip = tooltip
end

--- @param player_data PlayerData
--- @return table
local function caption_cache(player_data)
	local state = sync.gui_state(player_data, "overview_captions")
	state.captions = state.captions or {}
	return state.captions
end

--- @param refs table
--- @param cache table
--- @param tile string
--- @param i int
--- @param label_sig string
--- @param label LocalisedString
--- @param value string
local function set_line(refs, cache, tile, i, label_sig, label, value)
	local base = "overview_" .. tile .. "_line" .. i
	set_caption(cache, refs[base .. "_label"], label_sig, label)
	set_caption(cache, refs[base .. "_value"], value, value)
end

local function red_if(n, s)
	if n and n > 0 then return "[color=255,90,90]" .. s .. "[/color]" end
	return s
end

local count_text = text.count

local function render_unserved_tile(refs, cache, model)
	local u = model.unserved
	local minutes = tostring(model.minutes)
	set_caption(cache, refs.overview_unserved_caption, "c", { "cybersyn-gui.overview-tile-unserved" })
	if not u or model.collecting then
		set_caption(cache, refs.overview_unserved_headline, NO_VALUE, NO_VALUE)
		set_caption(cache, refs.overview_unserved_note, "", "")
		for i = 1, 4 do set_line(refs, cache, "unserved", i, "", "", "") end
		local sig = u and "collecting" or "off"
		set_tooltip(cache, refs.overview_tile_unserved, sig, u and { "cybersyn-gui.stations-collecting" } or { "cybersyn-gui.unserved-diag-off" })
		return
	end
	-- The headline is the number the click lists: the stations the Stations tab's Unserved chip shows. The
	-- minutes threshold applies to the requests on the lines below it.
	set_caption(cache, refs.overview_unserved_headline, tostring(u.stations), count_text(u.stations))
	set_caption(cache, refs.overview_unserved_note, "", "")
	local old = count_text(u.old)
	local old_value = old
	if u.old_acked > 0 then old_value = { "", old, " ", { "cybersyn-gui.overview-acked-note", count_text(u.old_acked) } } end
	set_caption(cache, refs.overview_unserved_line1_label, "old" .. minutes, { "cybersyn-gui.overview-unserved-old", minutes })
	set_caption(cache, refs.overview_unserved_line1_value, old .. "|" .. u.old_acked, old_value)
	local sorted = u.sorted_reasons
	for i = 2, 4 do
		local k = i - 1
		local entry = (k <= TOP_REASONS or #sorted == TOP_REASONS + 1) and sorted[k] or nil
		if entry then
			set_line(refs, cache, "unserved", i, "r" .. entry[1], { "cybersyn-diag.chip-" .. REASON_KEYS[entry[1]] }, count_text(entry[2]))
		elseif k == TOP_REASONS + 1 and #sorted > k then
			local rest = 0
			for j = k, #sorted do rest = rest + sorted[j][2] end
			set_line(refs, cache, "unserved", i, "other", { "cybersyn-gui.overview-other-reasons" }, count_text(rest))
		else
			set_line(refs, cache, "unserved", i, "", "", "")
		end
	end
	local parts = {}
	for i, entry in ipairs(sorted) do parts[i] = entry[1] .. ":" .. entry[2] end
	local sig = table.concat(parts, ",") .. "|" .. u.old .. "|" .. u.old_acked .. "|" .. model.minutes .. "|" .. u.stations
		.. "|" .. tostring(model.filtered)
	if not tooltip_due(cache, refs.overview_tile_unserved, sig) then return end
	local tooltip = { "", { "cybersyn-gui.overview-tile-unserved-tooltip", minutes } }
	if u.stations >= 10000 then
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-exact", format.number(u.stations) } }
	end
	tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-unserved-old-line", minutes, format.number(u.old) } }
	for i, entry in ipairs(sorted) do
		if i > 18 then break end
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-diag.reason-" .. REASON_KEYS[entry[1]] }, ": ", format.number(entry[2]) }
	end
	if u.old_acked > 0 then
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-acked-line", format.number(u.old_acked) } }
	end
	if model.filtered then
		tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-filtered-requester" } }
	end
	set_tooltip(cache, refs.overview_tile_unserved, sig, tooltip)
end

local function render_fleet_tile(refs, cache, model)
	local f = model.fleet
	local period = tostring(model.period)
	set_caption(cache, refs.overview_fleet_caption, "c", { "cybersyn-gui.overview-tile-fleet" })
	set_caption(cache, refs.overview_fleet_note, period, { "cybersyn-gui.overview-fleet-min", { "cybersyn-gui.overview-scope-" .. period } })
	local headline = f.headline and count_text(f.headline) or NO_VALUE
	if f.headline == 0 then headline = "[color=255,90,90]0[/color]" end
	set_caption(cache, refs.overview_fleet_headline, headline, headline)
	set_line(refs, cache, "fleet", 1, "now", { "cybersyn-gui.hud-headroom-now" }, f.now and count_text(f.now) or NO_VALUE)
	set_line(refs, cache, "fleet", 2, "fail", { "cybersyn-gui.overview-fleet-failures" }, f.failures and red_if(f.failures, count_text(f.failures)) or NO_VALUE)
	set_line(refs, cache, "fleet", 3, f.network and "net" or "worst",
		{ f.network and "cybersyn-gui.overview-fleet-network-filtered" or "cybersyn-gui.overview-fleet-worst" },
		f.worst and rich_text.network_icon(f.worst) or NO_VALUE)
	local parts = {}
	for i, name in ipairs(f.names) do parts[i] = name .. ":" .. f.mins[name] .. ":" .. (f.current[name] or 0) end
	local busy = f.busy and string.format("%.1f", f.busy) or "-"
	local sig = table.concat(parts, ",") .. "|" .. busy .. "|" .. period .. "|" .. (f.network or "") .. "|" .. tostring(f.now)
		.. "|" .. tostring(f.failures)
	if not tooltip_due(cache, refs.overview_tile_fleet, sig) then return end
	local tooltip = { "", { "cybersyn-gui.overview-tile-fleet-tooltip", { "cybersyn-gui.overview-scope-" .. period } } }
	local shown = 0
	for _, name in ipairs(f.names) do
		if not f.network or name == f.network then
			shown = shown + 1
			if shown > MAX_TOOLTIP_NETWORKS then
				tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-more-networks", tostring(#f.names - MAX_TOOLTIP_NETWORKS) } }
				break
			end
			tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-fleet-network", rich_text.network_icon(name),
				format.number(f.mins[name]), format.number(f.current[name] or 0) } }
		end
	end
	if f.busy then
		tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-fleet-littles-law", string.format("%.1f", f.per_minute),
			logic.short_duration(f.trip * 60), busy } }
	end
	tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-fleet-scope" } }
	set_tooltip(cache, refs.overview_tile_fleet, sig, tooltip)
end

--- "22" or "22 (+3 acked)" for the Misconfigured line.
--- @param m {stations: int, acked: int}
--- @return string sig
--- @return LocalisedString
local function misconfigured_value(m)
	local n = red_if(m.stations, count_text(m.stations))
	if m.acked == 0 then return n, n end
	return n .. "|" .. m.acked, { "", n, " ", { "cybersyn-gui.overview-acked-note", count_text(m.acked) } }
end

local function render_failing_tile(refs, cache, model)
	local f = model.failing
	set_caption(cache, refs.overview_failing_caption, "c", { "cybersyn-gui.overview-tile-failing" })
	set_caption(cache, refs.overview_failing_note, "", "")
	local pending = model.lint_pending
	if not f then
		set_caption(cache, refs.overview_failing_headline, NO_VALUE, NO_VALUE)
		for i, line in ipairs(FAILING_LINES) do
			set_line(refs, cache, "failing", i, line, { "cybersyn-gui.overview-failing-" .. string.gsub(line, "_", "-") }, NO_VALUE)
		end
		set_tooltip(cache, refs.overview_tile_failing, "collecting", { "cybersyn-gui.stations-collecting" })
		return
	end
	-- Before the first lint pass every station reads clean: the total and the Misconfigured line wait for it.
	if pending then
		set_caption(cache, refs.overview_failing_headline, NO_VALUE, NO_VALUE)
	else
		set_caption(cache, refs.overview_failing_headline, tostring(f.total), red_if(f.total, count_text(f.total)))
	end
	for i, line in ipairs(FAILING_LINES) do
		local label = { "cybersyn-gui.overview-failing-" .. string.gsub(line, "_", "-") }
		if line == "misconfigured" then
			local sig, value
			if pending then
				sig, value = NO_VALUE, NO_VALUE
			else
				sig, value = misconfigured_value(f.misconfigured)
			end
			local base = "overview_failing_line" .. i
			set_caption(cache, refs[base .. "_label"], line, label)
			set_caption(cache, refs[base .. "_value"], sig, value)
		else
			local n = f[line]
			set_line(refs, cache, "failing", i, line, label, red_if(n, count_text(n)))
		end
	end
	local m = f.misconfigured
	local checks = {}
	for check in pairs(m.by_check) do checks[#checks + 1] = check end
	table.sort(checks)
	local parts = {}
	for i, check in ipairs(checks) do parts[i] = check .. ":" .. m.by_check[check] end
	local pct = pending and math.floor(pending * 100) or -1
	local sig = table.concat(parts, ",") .. "|" .. m.stations .. "|" .. m.acked .. "|" .. m.findings .. "|" .. pct
		.. "|" .. f.total
	if not tooltip_due(cache, refs.overview_tile_failing, sig) then return end
	local tooltip = { "", { "cybersyn-gui.overview-tile-failing-tooltip" } }
	if pending then
		tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-setup-checking", tostring(pct) } }
	else
		tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-misconfigured-count", format.number(m.stations),
			format.number(m.findings) } }
		if m.acked > 0 then
			tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-misconfigured-acked", format.number(m.acked) } }
		end
		if #checks > 0 then
			tooltip[#tooltip + 1] = { "", "\n\n", { "cybersyn-gui.overview-failing-lint-header" } }
			for i, check in ipairs(checks) do
				if i > 16 then break end
				local key = LINT_KEYS[check]
				local caption = key and { "cybersyn-diag.lint-" .. key } or tostring(check)
				tooltip[#tooltip + 1] = { "", "\n", { "cybersyn-gui.overview-failing-lint-check", caption, format.number(m.by_check[check]) } }
			end
		end
	end
	set_tooltip(cache, refs.overview_tile_failing, sig, tooltip)
	local link = refs.overview_failing_line4_label
	set_tooltip(cache, link, sig, { "", { "cybersyn-gui.overview-misconfigured-tooltip" }, "\n", tooltip })
end

local function render_throughput_tile(refs, cache, model)
	local t = model.throughput
	local period = tostring(model.period)
	set_caption(cache, refs.overview_throughput_caption, period,
		{ "", { "cybersyn-gui.overview-tile-throughput" }, " · ", { "cybersyn-gui.overview-scope-short-" .. period }, " · ",
			{ "cybersyn-gui.overview-all-networks" } })
	set_caption(cache, refs.overview_throughput_note, "", "")
	set_caption(cache, refs.overview_throughput_headline, tostring(t.deliveries), count_text(t.deliveries))
	local trip = t.trip and logic.short_duration(t.trip * 60) or NO_VALUE
	local wait_avg = t.wait_avg and logic.short_duration(t.wait_avg) or NO_VALUE
	local wait_max = t.wait_max and logic.short_duration(t.wait_max) or NO_VALUE
	set_line(refs, cache, "throughput", 1, "trip", { "cybersyn-gui.overview-throughput-trip" }, trip)
	set_line(refs, cache, "throughput", 2, "wavg", { "cybersyn-gui.overview-throughput-wait-avg" }, wait_avg)
	set_line(refs, cache, "throughput", 3, "wmax", { "cybersyn-gui.overview-throughput-wait-max" }, wait_max)
	-- A body row at every width: beside the caption it would be cut to "Recorded so far: 2m 1…".
	local recorded = t.recorded and logic.short_duration(t.recorded) or ""
	if t.recorded then
		set_line(refs, cache, "throughput", 4, "recorded", { "cybersyn-gui.overview-recorded-line" }, recorded)
	else
		set_line(refs, cache, "throughput", 4, "", "", "")
	end
	local per_cycle = t.cycle_ticks > 0 and string.format("%.1f", t.cycle_dispatches) or ""
	local sig = table.concat({ t.amount, t.dispatches, t.cycle_ticks, per_cycle, period, t.deliveries }, "|")
	if not tooltip_due(cache, refs.overview_tile_throughput, sig) then return end
	local tooltip = {
		"", { "cybersyn-gui.overview-tile-throughput-tooltip", { "cybersyn-gui.overview-scope-" .. period } },
		"\n", { "cybersyn-gui.overview-throughput-deliveries", format.number(t.deliveries) },
		"\n", { "cybersyn-gui.overview-throughput-items", format.number(t.amount) },
		"\n", { "cybersyn-gui.overview-throughput-dispatches", format.number(t.dispatches) },
	}
	if t.cycle_ticks > 0 then
		tooltip[#tooltip + 1] = "\n"
		tooltip[#tooltip + 1] = { "cybersyn-gui.overview-throughput-cycle", tostring(t.cycle_ticks), per_cycle }
	end
	tooltip[#tooltip + 1] = "\n"
	tooltip[#tooltip + 1] = { "cybersyn-gui.overview-throughput-wait-note" }
	set_tooltip(cache, refs.overview_tile_throughput, sig, tooltip)
end

--- @param player_data PlayerData
--- @param model table
local function render_tiles(player_data, model)
	local refs = player_data.refs
	local cache = caption_cache(player_data)
	render_unserved_tile(refs, cache, model)
	render_fleet_tile(refs, cache, model)
	render_failing_tile(refs, cache, model)
	render_throughput_tile(refs, cache, model)

	local dropdown = refs.overview_period_dropdown
	if dropdown and dropdown.valid then
		for i, minutes in ipairs(PERIODS) do
			if minutes == model.period and dropdown.selected_index ~= i then dropdown.selected_index = i end
		end
	end
	local toggle = refs.overview_show_acked
	if toggle and toggle.valid then
		local n = model.unserved and model.unserved.acked_total or 0
		set_caption(cache, toggle, tostring(n), { "cybersyn-gui.overview-show-acked", tostring(n) })
		local state = player_data.tabs.overview_tab.show_acked == true
		if toggle.state ~= state then toggle.state = state end
	end
end

-- ---------------------------------------------------------------- render: Unserved table

--- @param id uint?
--- @param snapshot Snapshot
--- @return StopNameView?
--- @return SnapshotStation?
local function station_view(id, snapshot)
	return name_cell.station_view(id, snapshot.stations)
end

--- @param view StopNameView
--- @return string
local function view_sig(view)
	if not view then return "" end
	return view.name
end

local station_tooltip = name_cell.station_tooltip

--- Every interactive cell joins the table's hover hold, so rows do not reorder under the cursor.
--- @param def flib.GuiElemDef
--- @return flib.GuiElemDef
local function hoverable(def)
	return hover.hoverable(def, TABLE)
end

--- A station cell drawn as on the other tabs (name-cell.lua: lead icons · text · tail icons, the lead giving way first
--- when the column is narrow). Without a target it is a disabled "–"; the click handler is attached
--- anyway, because an in-place update rewrites only the tags (flib keeps its handler name there).
--- @param view StopNameView?
--- @param kind string
--- @param id uint?
--- @param width int
--- @param tooltip LocalisedString
--- @param acked boolean
--- @return flib.GuiElemDef
local function link_cell(view, kind, id, width, tooltip, acked)
	local tags = id and { kind = kind, id = id } or {}
	local def = name_cell.def(view and name_cell.fit(view.parts, width), view and view.name or NO_VALUE, tags, width,
		tooltip, TABLE)
	def.style_mods.height = ROW_H
	for _, child in ipairs(def) do
		if child.type == "button" then
			if acked then child.style = "cybersyn_link_button_acked" end
			child.enabled = view ~= nil
		end
	end
	return def
end

--- Rewrites a cell built by link_cell in place; its icons are rebuilt only when the name or the target changed.
--- @param cell LuaGuiElement
--- @param view StopNameView?
--- @param kind string
--- @param id uint?
--- @param width int
--- @param tooltip LocalisedString
--- @param acked boolean
local function update_link_cell(cell, view, kind, id, width, tooltip, acked)
	local tags = id and { kind = kind, id = id } or {}
	name_cell.update(cell, view and name_cell.fit(view.parts, width), view and view.name or NO_VALUE, tags, width,
		tooltip, TABLE)
	local button = name_cell.button(cell)
	if not button then return end
	local style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button"
	if button.style.name ~= style then
		local w = button.style.maximal_width
		button.style = style
		button.style.maximal_width = w
	end
	if button.enabled ~= (view ~= nil) then button.enabled = view ~= nil end
end

local setup_cache = {}

--- Error findings of the last lint pass by station, for the Why cell's Setup marker. Rebuilt once
--- per pass; a pure function of storage, so a cache that differs between Lua states cannot desync anything.
--- @return {[uint]: LintFinding[]}?
local function setup_index()
	local s = storage.manager.lint
	if not (s and s.tick) then return nil end
	local findings = s.findings or {}
	local key = s.pass .. "|" .. s.tick .. "|" .. (s.removed or 0) .. "|" .. #findings
	if setup_cache.key ~= key then
		local by = {}
		for _, f in ipairs(findings) do
			if f.subject == LINT_SUBJECT_STATION and LINT_SEVERITY[f.check] == DIAG_SEV_ERROR then
				local list = get_or_create(by, f.id)
				list[#list + 1] = f
			end
		end
		setup_cache.key, setup_cache.by = key, by
	end
	return setup_cache.by
end

--- The blocking finding behind an Unserved row: an unacknowledged error finding of the requester for this item or
--- for the whole station.
--- @param index {[uint]: LintFinding[]}?
--- @param r_id uint
--- @param hash string
--- @return LintFinding?
local function setup_finding(index, r_id, hash)
	local list = index and index[r_id]
	if not list then return nil end
	for _, f in ipairs(list) do
		if (f.item == nil or f.item == hash) and not diag.is_acked("lint", r_id, f.check) then return f end
	end
	return nil
end

--- @param f LintFinding?
--- @return LocalisedString
local function setup_tooltip(f)
	if not f then return "" end
	local key = LINT_KEYS[f.check]
	return { "", "[font=default-semibold]", { "cybersyn-gui.unserved-setup-title" }, "[/font] · ",
		key and { "cybersyn-diag.lint-" .. key } or tostring(f.check),
		"\n", key and { "cybersyn-diag.lint-fix-" .. key } or "",
		"\n", { "cybersyn-gui.unserved-setup-hint" } }
end

local surface_name = util.surface_name

--- One table row's data and its cells.
--- @param row {r_id: uint, hash: string, e: DiagEntry}
--- @param acked boolean
--- @param ctx table
--- @return table? entry for sync.sync_table_rows
local function row_entry(row, acked, ctx)
	local hash, e, r_id = row.hash, row.e, row.r_id
	local sprite, quality, item_tooltip = util.item_sprite_and_tooltip(hash)
	-- An item a mod change removed still has its entry: a question mark, never a row less than the caption counts.
	if not sprite then sprite, quality, item_tooltip = "utility/questionmark", nil, hash end
	local now = ctx.now
	local requester, r_st = station_view(r_id, ctx.snapshot)
	local reason = e.reason
	local p_id = reason ~= REASON_NO_PROVIDER and e.p_station_id or nil
	local provider = p_id and station_view(p_id, ctx.snapshot) or nil
	local lost = e.lost_n > 0 and e.lost_to and station_view(e.lost_to, ctx.snapshot) or nil
	local setup = not acked and setup_finding(ctx.setup, r_id, hash) or nil
	local wait = now - e.first_tick
	-- On the 10 s step, as the stop panel shows the same entry, whichever update last wrote the row.
	local wait_shown = wait - wait % text.READ_STEP
	local inherited = e.first_tick < ctx.inherit_before
	local wait_caption = text.wait_caption(wait_shown, inherited)
	local read_age = r_st and r_st.read_tick and now - r_st.read_tick or nil
	-- The inventory that requests the item names the network in the chip tooltip (explain.network_of), and its request
	-- is the amount the tooltip gives, not the station's sum.
	local inv = text.inventory_of(r_st, hash, "requested", collector.inventories)
	local requested
	if r_st then
		local req = (inv or r_st).requested[hash]
		if req then requested = -req.count end
	end
	-- Everything but the clocks; the clocks (wait, read age) move every 10 s and then only their cells are written.
	-- The numbers (stock, evaluations, lost count, request) change on most updates of a large base while the rest
	-- stays, so a change of only them writes only their cells too.
	local ident_sig = table.concat({
		reason, tostring(p_id), view_sig(provider), view_sig(requester), tostring(e.lost_to),
		acked and "a" or "", inherited and "i" or "", setup and setup.check or "", inv and rtext.row_sig(inv) or "",
	}, "|")
	local content_sig = ident_sig .. "#" .. table.concat({ e.a, e.b, e.lost_n, e.n, tostring(requested) }, "|")
	local sig = content_sig .. "|" .. math.floor(wait / text.READ_STEP) .. "|" .. text.read_step(read_age)
	local content_sigs = ctx.content_sigs
	local widths = ctx.widths
	local req_width = ctx.requester_width
	local key = r_id .. "|" .. hash
	--- The ack's "for another …" is a clock too: the clocks-only path writes it with the wait.
	--- @return LocalisedString
	--- @return boolean counting
	local function ack_tooltip()
		if not acked then return { "cybersyn-gui.unserved-ack-tooltip" }, false end
		local a = diag.is_acked("request", r_id, hash)
		local who = a and a.player_index and game.get_player(a.player_index)
		local until_text = a and a.until_tick and logic.format_duration(a.until_tick - now) or nil
		return { "cybersyn-gui.unserved-ack-tooltip-acked", who and who.name or "-",
			until_text and { "cybersyn-gui.unserved-ack-for", until_text } or { "cybersyn-gui.unserved-ack-reason" } },
			until_text ~= nil
	end
	local function tooltips(clocks_only)
		local read = read_age and text.read_ago(read_age) or nil
		local chip = text.chip_tooltip({
			item = item_tooltip,
			requested = requested,
			requester = requester and requester.name or tostring(r_id),
			reason = reason,
			a = e.a,
			b = e.b,
			network = explain.network_of(r_id, hash, r_st),
			rej = e.rej,
			wait = wait_shown,
			inherited = inherited,
			n = e.n,
			read_age = read_age,
			surface_name = surface_name,
		})
		chip[#chip + 1] = "\n"
		chip[#chip + 1] = { "cybersyn-gui.unserved-explain-hint" }
		local r_tip = station_tooltip(requester, read)
		if clocks_only then return chip, r_tip end
		local p_tip = station_tooltip(provider, nil)
		local l_tip = lost and station_tooltip(lost, { "cybersyn-diag.lost-priority", lost.name, tostring(e.lost_n) }) or ""
		local item_tip = { "", { "cybersyn-gui.item-click-hint" } }
		return chip, r_tip, p_tip, l_tip, ack_tooltip(), item_tip
	end
	local stock = text.stock_caption(reason, e.a, e.b)
	local value_style = acked and "cybersyn_unserved_value_acked" or "cybersyn_unserved_value"
	local link_style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button"
	local cell_style = acked and "cybersyn_unserved_cell_acked" or "cybersyn_unserved_cell"
	local lost_caption = lost and ("×" .. e.lost_n) or ""
	local chip_width = CHIP_W
	-- A table places only visible cells, so a hidden column keeps its cells at width 0 and empty instead.
	local stock_shown = not ctx.hide.stock and stock or ""
	local hide = ctx.hide
	--- @param cell LuaGuiElement the Why cell
	local function write_why(cell, chip)
		local button, marker = cell.children[1], cell.children[2]
		local chip_style = acked and "cybersyn_chip_acked" or text.chip_style(reason)
		if button.style.name ~= chip_style then button.style = chip_style end
		if button.style.minimal_width ~= chip_width or button.style.maximal_width ~= chip_width then
			button.style.width = chip_width
		end
		button.caption = text.chip_caption(reason)
		button.tooltip = chip
		if marker.visible ~= (setup ~= nil) then marker.visible = setup ~= nil end
		marker.tooltip = setup_tooltip(setup)
	end
	return {
		key = key,
		sig = sig,
		row = row,
		acked = acked,
		has_stock = stock ~= NO_VALUE,
		has_lost = lost ~= nil,
		build = function()
			content_sigs[key] = content_sig
			local chip, r_tip, p_tip, l_tip, ack, item_tip = tooltips()
			local link = { [defines.events.on_gui_click] = links.handle.link_click }
			return {
				hoverable({
					type = "sprite-button",
					style = "cybersyn_unserved_item",
					sprite = sprite,
					quality = quality,
					elem_tooltip = util.elem_tooltip(hash),
					tooltip = item_tip,
					tags = { kind = "item", id = hash },
					mouse_button_filter = { "left", "right" },
					handler = link,
				}),
				link_cell(requester, "station", r_id, req_width, r_tip, acked),
				{
					type = "flow",
					direction = "horizontal",
					style = "cybersyn_unserved_cell_flow",
					style_mods = { width = W.why },
					hoverable({
						type = "button",
						style = acked and "cybersyn_chip_acked" or text.chip_style(reason),
						style_mods = { width = chip_width },
						caption = text.chip_caption(reason),
						tooltip = chip,
						tags = { r_id = r_id, hash = hash },
						handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_explain_click },
					}),
					-- A plain marker, not a button: the finding is fixed at the stop (its Setup section).
					hoverable({
						type = "label",
						style = "cybersyn_unserved_cell",
						style_mods = { width = MARKER_W, font_color = { 1, 0.65, 0.2 } },
						caption = { "cybersyn-gui.unserved-setup-marker" },
						tooltip = setup_tooltip(setup),
						visible = setup ~= nil,
					}),
				},
				link_cell(provider, "station", p_id, widths.provider, p_tip, acked),
				hoverable({ type = "label", style = value_style, style_mods = { width = hide.stock and 0 or W.stock },
					caption = stock_shown }),
				{
					type = "flow",
					direction = "horizontal",
					style = "cybersyn_unserved_cell_flow",
					style_mods = { width = hide.lost and 0 or W.lost },
					hoverable({
						type = "button",
						style = link_style,
						style_mods = { maximal_width = W.lost - 32 },
						caption = lost and lost.text or "",
						tooltip = l_tip,
						tags = lost and { kind = "station", id = e.lost_to } or {},
						mouse_button_filter = { "left" },
						handler = link,
						visible = not hide.lost,
					}),
					hoverable({ type = "label", style = cell_style, caption = lost_caption, tooltip = l_tip,
						visible = not hide.lost }),
				},
				hoverable({ type = "label", style = value_style, style_mods = { width = W.wait }, caption = wait_caption }),
				hoverable({
					type = "sprite-button",
					style = "cybersyn_unserved_ack",
					sprite = "utility/check_mark",
					toggled = acked,
					tooltip = ack,
					tags = { r_id = r_id, hash = hash },
					handler = { [defines.events.on_gui_click] = overview_tab.handle.overview_ack_click },
				}),
			}
		end,
		-- A row of another key reused at this position (sync.sync_table_rows): the key's own cells first, then
		-- every other cell as an update writes them.
		rebind = function(cells, entry)
			local item = cells[1]
			item.sprite = sprite
			item.quality = quality
			item.elem_tooltip = util.elem_tooltip(hash)
			local t = item.tags
			t.kind, t.id = "item", hash
			item.tags = t
			for _, c in ipairs({ cells[3].children[1], cells[8] }) do
				local ct = c.tags
				ct.r_id, ct.hash = r_id, hash
				c.tags = ct
			end
			content_sigs[key] = nil
			entry.update(cells)
		end,
		update = function(cells)
			local last = content_sigs[key]
			local numbers = last ~= content_sig and last ~= nil and #last > #ident_sig
				and string.sub(last, 1, #ident_sig + 1) == ident_sig .. "#"
			if last == content_sig or numbers then
				-- Only the clocks moved: the wait, and the tooltips that carry the wait and the read age.
				local chip, r_tip = tooltips(true)
				cells[7].caption = wait_caption
				cells[3].children[1].tooltip = chip
				for _, part in ipairs(cells[2].children) do part.tooltip = r_tip end
				if acked then
					local ack, counting = ack_tooltip()
					if counting then cells[8].tooltip = ack end
				end
				if numbers then
					content_sigs[key] = content_sig
					cells[5].caption = stock_shown
					local l_tip = lost and station_tooltip(lost, { "cybersyn-diag.lost-priority", lost.name, tostring(e.lost_n) })
						or ""
					local lost_button, lost_label = cells[6].children[1], cells[6].children[2]
					lost_button.tooltip = l_tip
					lost_label.caption = lost_caption
					lost_label.tooltip = l_tip
				end
				return
			end
			content_sigs[key] = content_sig
			local chip, r_tip, p_tip, l_tip, ack, item_tip = tooltips()
			cells[1].tooltip = item_tip
			update_link_cell(cells[2], requester, "station", r_id, req_width, r_tip, acked)
			write_why(cells[3], chip)
			update_link_cell(cells[4], provider, "station", p_id, widths.provider, p_tip, acked)
			for _, c in ipairs({ { cells[5], hide.stock and 0 or W.stock }, { cells[7], W.wait } }) do
				if c[1].style.name ~= value_style then
					c[1].style = value_style
					c[1].style.width = c[2]
				end
			end
			cells[5].caption = stock_shown
			local lost_button, lost_label = cells[6].children[1], cells[6].children[2]
			if lost_button.style.name ~= link_style then
				lost_button.style = link_style
				lost_button.style.maximal_width = W.lost - 32
			end
			if lost_label.style.name ~= cell_style then lost_label.style = cell_style end
			lost_button.caption = lost and lost.text or ""
			lost_button.tooltip = l_tip
			local t = lost_button.tags
			t.kind, t.id = lost and "station" or nil, lost and e.lost_to or nil
			lost_button.tags = t
			lost_label.caption = lost_caption
			lost_label.tooltip = l_tip
			cells[7].caption = wait_caption
			cells[8].toggled = acked
			cells[8].tooltip = ack
		end,
	}
end

--- @param player_data PlayerData
--- @param model table
local function render_table(player_data, model)
	local refs = player_data.refs
	local tbl = refs[TABLE]
	if not (tbl and tbl.valid) then return end
	local cache = caption_cache(player_data)
	local u = model.unserved
	local widths = player_data.tabs.overview_tab.widths
	if not widths then return end
	local entries = {}
	local shown_total = 0
	if u and not model.collecting then
		local state = sync.gui_state(player_data, TABLE)
		local content_sigs = state.content_sigs
		-- Keys that left the table leave their entry behind; dropped wholesale now and then.
		if not content_sigs or table_size(content_sigs) > 4 * model.rows + 64 then
			content_sigs = {}
			state.content_sigs = content_sigs
		end
		local hide = state.hide or { stock = false, lost = false }
		local ctx = { now = model.now, snapshot = collector.get(), inherit_before = model.inherit_before, widths = widths,
			content_sigs = content_sigs, setup = setup_index(), hide = hide }
		local show_acked = player_data.tabs.overview_tab.show_acked
		local open_take, acked_take = logic.unserved_split(model.rows, #u.open, #u.acked, show_acked)
		local picked = {}
		for i = 1, open_take do picked[i] = { u.open[i], false } end
		for i = 1, acked_take do picked[open_take + i] = { u.acked[i], true } end
		-- A column the visible rows leave empty gives its width to the requester. Rows are rebuilt
		-- for a change, as for a new window width; while the pointer holds the table the columns stay.
		local any_stock, any_lost = false, false
		for _, p in ipairs(picked) do
			local e = p[1].e
			if text.stock_caption(e.reason, e.a, e.b) ~= NO_VALUE then any_stock = true end
			if e.lost_n > 0 and e.lost_to then any_lost = true end
		end
		if #picked > 0 and (hide.stock == any_stock or hide.lost == any_lost) and not hover.hold_active(player_data, TABLE) then
			hide = { stock = not any_stock, lost = not any_lost }
			state.hide = hide
			ctx.hide = hide
			local children = tbl.children
			for i = #children, TABLE_COLUMNS + 1, -1 do children[i].destroy() end
			state.keys, state.sigs = nil, nil
		end
		ctx.requester_width = widths.requester + (hide.stock and W.stock or 0) + (hide.lost and W.lost or 0)
		local header = tbl.children
		for i, h in pairs({ [5] = { hide.stock, W.stock, "cybersyn-gui.unserved-col-stock" },
			[6] = { hide.lost, W.lost, "cybersyn-gui.unserved-col-lost" } }) do
			local width = h[1] and 0 or h[2]
			if header[i].style.minimal_width ~= width then
				header[i].style.width = width
				header[i].caption = h[1] and "" or { h[3] }
			end
		end
		local h_req = refs.overview_unserved_h_requester
		if h_req and h_req.valid and h_req.style.minimal_width ~= ctx.requester_width then
			h_req.style.width = ctx.requester_width
		end
		for _, p in ipairs(picked) do
			local entry = row_entry(p[1], p[2], ctx)
			if entry then entries[#entries + 1] = entry end
		end
		shown_total = u.total + (player_data.tabs.overview_tab.show_acked and u.acked_total or 0)
	end
	-- Rows key on (requester, item), so a wait that reorders them is a structural change the hover hold defers.
	sync.sync_table_rows(tbl, TABLE_COLUMNS, TABLE_COLUMNS, entries, sync.gui_state(player_data, TABLE),
		hover.hold_active(player_data, TABLE))

	local empty_flow, empty = refs.overview_unserved_empty_flow, refs.overview_unserved_empty
	local show_empty = #entries == 0
	if empty_flow.visible ~= show_empty then empty_flow.visible = show_empty end
	if show_empty then
		local sig, caption
		if not u then
			sig, caption = "off", { "cybersyn-gui.unserved-diag-off" }
		elseif model.collecting then
			sig, caption = "collecting", { "cybersyn-gui.stations-collecting" }
		elseif model.filtered then
			sig, caption = "empty-filtered", { "cybersyn-gui.unserved-empty-filtered" }
		elseif model.item then
			sig, caption = "empty-item", { "cybersyn-gui.unserved-empty-item" }
		else
			sig, caption = "empty", { "cybersyn-gui.unserved-empty" }
		end
		set_caption(cache, empty, sig, caption)
	end

	local count = refs.overview_unserved_count
	if u and not model.collecting and shown_total > 0 then
		local shown = tostring(#entries) .. "/" .. shown_total
		set_caption(cache, count, shown, { "cybersyn-gui.unserved-count", format.number(#entries), format.number(shown_total) })
	else
		set_caption(cache, count, "", "")
	end
	local dropped = refs.overview_unserved_dropped
	local n = model.dropped
	if dropped and dropped.valid then
		local show = n > 0
		if dropped.visible ~= show then dropped.visible = show end
		if show then set_caption(cache, dropped, tostring(n), { "cybersyn-gui.unserved-dropped", format.number(n) }) end
	end
end

--- @param map_data MapData
--- @param player_data PlayerData
function overview_tab.build(map_data, player_data)
	local refs = player_data.refs
	if not (refs.overview_unserved_headline and refs.overview_unserved_headline.valid) then return end
	local model = overview_tab.model(player_data)
	render_tiles(player_data, model)
	render_table(player_data, model)
end

overview_tab.handle = {}

overview_tab.wrapper = util.wrapper

--- @param e EventData.on_gui_selection_state_changed
function overview_tab.handle.overview_period_changed(player, player_data, refs, e)
	local element = e.element
	if not (element and element.valid) then return end
	local minutes = PERIODS[element.selected_index]
	if not minutes or minutes == player_data.tabs.overview_tab.period then return end
	player_data.tabs.overview_tab.period = minutes
	nav.rerender(player, player_data)
end

--- @param e EventData.on_gui_checked_state_changed
function overview_tab.handle.overview_show_acked(player, player_data, refs, e)
	player_data.tabs.overview_tab.show_acked = e.element.state or nil
	hover.release_hold(player_data)
	nav.rerender(player, player_data)
end

--- A tile or line jump to the Stations tab: the target lists under exactly the filters the Overview counted with,
--- so the row stays; the Overview has no station search, so a query typed on another tab goes, and the other chips go
--- (one chip at a time: a toggled status chip would win over the flag chip, stations.lua active_chip).
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param chip string the Stations flag chip
--- @param sort {tab: string, column: string, ascending: boolean}?
--- @param scope "errors"?
local function jump_stations(player, player_data, chip, sort, scope)
	nav.focus(player, player_data, "stations_tab", { keep_row = true, stations_chip = chip,
		problems_scope = scope, sort = sort })
end

local UNSERVED_SORT = { tab = "stations_tab", column = "wait", ascending = false }
local FAILING_SORT = { tab = "stations_tab", column = "station_status", ascending = true }
local FLEET_SORT = { tab = "trains_tab", column = "train_status", ascending = true }
local THROUGHPUT_SORT = { tab = "inventory_tab", column = "amount", ascending = false }

--- Every tile jumps to the tab that lists what it counts.
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_tile_click(player, player_data, refs, e)
	local tile = e.element.tags.tile
	if tile == "unserved" then
		jump_stations(player, player_data, "unserved", UNSERVED_SORT)
	elseif tile == "fleet" then
		-- Fleet headroom counts by network name alone: every other filter goes, or an item filter alone would
		-- empty the Parked list (parked trains carry no manifest).
		local worst = overview_tab.model(player_data).fleet.worst
		nav.focus(player, player_data, "trains_tab", { network = worst, trains_chip = "parked",
			sort = FLEET_SORT })
	elseif tile == "failing" then
		jump_stations(player, player_data, "failing", FAILING_SORT)
	elseif tile == "throughput" then
		nav.focus(player, player_data, "inventory_tab", { keep_row = true, grids = true,
			sort = THROUGHPUT_SORT })
	end
end

--- The Misconfigured line: Stations with the Problems chip (stations.lua reads the chip), narrowed to the
--- stations the line counts (an unacknowledged error-severity finding, util.open_setup_errors).
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_problems_click(player, player_data, refs, e)
	jump_stations(player, player_data, "problems", nil, "errors")
end

--- @param e EventData.on_gui_click
function overview_tab.handle.overview_count_click(player, player_data, refs, e)
	jump_stations(player, player_data, "unserved", UNSERVED_SORT)
end

--- The Why chip: Explain for that row (scripts/gui/explain.lua), a second click closes it.
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_explain_click(player, player_data, refs, e)
	hover.touch_hover(e)
	local tags = e.element.tags
	if not (tags.r_id and tags.hash) then return end
	explain.open(player, player_data, tags.r_id, tags.hash)
end

--- Acknowledge: click = 24 h, shift-click = 1 h, control-click = until the reason changes; a click
--- on an acknowledged row ends it. Display state only; diag.ack writes the event and removes the stop's alerts.
--- @param e EventData.on_gui_click
function overview_tab.handle.overview_ack_click(player, player_data, refs, e)
	local tags = e.element.tags
	local r_id, hash = tags.r_id, tags.hash
	if not (r_id and hash) then return end
	if diag.is_acked("request", r_id, hash) then
		diag.unack("request", r_id, hash, player.index)
	else
		diag.ack("request", r_id, hash, player.index, util.ack_until_tick(e))
	end
	hover.release_hold(player_data)
	nav.rerender(player, player_data)
end

gui.add_handlers(overview_tab.handle, overview_tab.wrapper)

return overview_tab
