-- Stations tab: filter chips in the tab's subheader (a second line below it when they do not
-- fit), one 32 px row per station (name with its icons, status, network, provided / requested, deliveries, wait, last
-- dispatch), exactly as many rows as the window fits, the pager in a subfooter. The Problems chip is the setup lint's
-- view: a Problems column takes the place of Provided / requested, and the findings about stops and combinators that
-- are not a station (the registry) follow the stations as rows of their own.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local sync = require("scripts.gui.utils.sync")
local filters = require("scripts.gui.utils.filters")
local listing = require("scripts.gui.utils.listing")
local hover = require("scripts.gui.utils.hover")
local links = require("scripts.gui.utils.links")
local nav = require("scripts.gui.utils.nav")
local rich_text = require("scripts.gui.rich-text")
local collector = require("scripts.gui.collector")
local sizing = require("scripts.gui.sizing")
local metrics = require("scripts.gui.metrics")
local logic = require("scripts.gui.tab-logic")
local name_cell = require("scripts.gui.name-cell")
local text = require("scripts.gui.unserved-text")
local templates = require("scripts.gui.templates")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local pm = require("scripts.gui.problems-model")
local lint_text = require("scripts.gui.lint-text")
local rtext = require("scripts.gui.relative-text")

local stations_tab = {}

local TAB = "stations_tab"
-- The row list (a flow, despite the name).
local SCROLL = "manager_stations_tab_scroll_pane"
local HEADER = "manager_stations_header"
local CHIPS = "manager_stations_status_flow"
-- The second line of chips, below the subheader.
local CHIP_ROW = "manager_stations_chip_row"
local CONTROL_TOGGLE = "manager_stations_control_toggle"
local CHIPS2 = "manager_stations_chip_flow2"
local UNLIMITED = collector.UNLIMITED
local SLOT = 32
-- Banner, subheader, column header and subfooter (styles cybersyn_tab_subheader, cybersyn_list_header,
-- cybersyn_list_subfooter).
local FIRST_UPDATE_ROWS = 15
local band = bit32.band
local FLAG_UNSERVED, FLAG_SETUP, FAILING = logic.FLAG_UNSERVED, logic.FLAG_SETUP, logic.FAILING
-- Alert kind 1 is Cybersyn's stuck-train alert (storage.active_alerts).
local ALERT_STUCK = 1

local STATUSES, STATUS_COLOR, status_key = logic.STATUSES, logic.STATUS_COLOR, logic.status_key
local STATUS_RANK = {}
for i, s in ipairs(STATUSES) do STATUS_RANK[s] = i end

--- Chips besides the statuses, by the station flag they test (tab-logic); stuck comes from the trains.
local FLAG_CHIPS = { unserved = logic.FLAG_UNSERVED, problems = logic.FLAG_SETUP, failing = logic.FAILING }
local CHIP_ORDER = { "all" }
for _, s in ipairs(STATUSES) do CHIP_ORDER[#CHIP_ORDER + 1] = s end
for _, c in ipairs({ "unserved", "problems", "stuck", "failing" }) do CHIP_ORDER[#CHIP_ORDER + 1] = c end
-- Problems leads with the warning triangle the Trains depot rows' Problems marker shows, so it does not read as the
-- yellow status dot of Setup beside it.
local CHIP_ICON = {
	unserved = "utility/warning_icon",
	problems = "utility/warning_icon",
	stuck = "item/locomotive",
	failing = "utility/danger_icon",
}
-- Widths of the chips with their names and a one-digit count in unscaled GUI px, the widest any shipped locale renders
-- at any UI scale (tests/unit/chip_width_test.lua measures them with the game's fonts). They are the buttons'
-- maximal_width and what chip_lines reserves, so the chips that do not fit beside the search field go to the second
-- line instead of overflowing.
local CHIP_WIDTH = {
	all = 52, no_power = 118, disabled = 112, warming_up = 133, starved = 106, setup = 95, saturated = 119, idle = 82, ok = 76,
	unserved = 117, problems = 117, stuck = 155, failing = 99,
}
-- Each further digit of a count, separators included.
local DIGIT_WIDTH = 8

local COLUMNS = { "name", "station_status", "network", "priority", "control", "provided_requested", "deliveries", "wait",
	"last_delivery" }
-- While the Problems chip is on, the sixth column shows a station's lint findings instead of its slots.
local PROBLEM_COLUMNS = { "name", "station_status", "network", "priority", "control", "problems", "deliveries", "wait",
	"last_delivery" }
-- Control signals (not sortable) sits beside Priority, whose signal it shows with the rest. The subheader toggle hides
-- it, and the Problems view, which needs the width, always does.
local CONTROL_COLUMN = 5
local PROBLEMS_COLUMN = 6
local WAIT_COLUMN = 8
-- Its left padding: Priority before it is right-aligned, so the spacing alone runs the two together.
local CONTROL_GAP = 12
local RIGHT = { priority = true, wait = true, last_delivery = true }
-- Column captions and sort tooltips whose locale key is not the column's name.
local CAPTION_KEY = { last_delivery = "stations-last-dispatch", problems = "stations-problems", priority = "item-col-priority",
	control = "stations-control" }
local SORT_KEY = { last_delivery = "stations-sort-last-dispatch", problems = "stations-sort-problems" }
-- Fixed widths in logical px; the name and the two slot strips share the rest (column_widths).
local W = { station_status = 156, network = 80, priority = 64, dl_count = 40, wait = 64, last_delivery = 88 }
local NAME_MIN = 160
-- The Problems view: Deliveries keeps its two slots, the name a quarter of what the fixed columns leave (at least
-- NAME_MIN), and the Problems column stretches over the rest; never under PROBLEMS_MIN while the name keeps NAME_MIN.
local PROBLEMS_NAME_SHARE = 0.25
local PROBLEMS_MIN = 300
local PROBLEMS_DL_SLOTS = 2

--- Column widths for a tab content width: fixed columns, slot strips of whole slots (Provided / requested 5..12,
--- Deliveries 2..6, Control signals 3..5), the name takes the rest. With `problems` the Problems column takes Provided /
--- requested's place and stretches: Deliveries keeps two slots, the name a quarter; a hidden Wait or Control signals
--- column gives its width to the name. On a narrow window Control signals takes its slots from Provided / requested,
--- which keeps three: the toggle is there for a player who wants them back.
--- @param cw int
--- @param problems boolean?
--- @param hide_wait boolean?
--- @param show_control boolean?
--- @return table
local function column_widths(cw, problems, hide_wait, show_control)
	show_control = show_control and not problems
	-- Row padding, 16 px of frame borders and seven gaps between the eight columns other than Control signals (one
	-- fewer with Wait hidden, one more with Control signals shown).
	local avail = cw - 2 * metrics.LIST_ROW_PADDING - 16 - 7 * metrics.LIST_SPACING
	local wait = W.wait
	if hide_wait then
		wait = 0
		avail = avail + metrics.LIST_SPACING
	end
	if show_control then avail = avail - metrics.LIST_SPACING - CONTROL_GAP end
	local fixed = W.station_status + W.network + W.priority + W.dl_count + 4 + wait + W.last_delivery
	local rest = avail - fixed
	local ctl = show_control and math.min(5, math.max(3, math.floor(rest * 0.15 / SLOT))) or 0
	rest = rest - ctl * SLOT
	local pr = math.min(12, math.max(5, math.floor(rest * 0.45 / SLOT)))
	local dl = math.min(6, math.max(2, math.floor(rest * 0.2 / SLOT)))
	local fourth, name
	if problems then
		dl = PROBLEMS_DL_SLOTS
		name = math.max(NAME_MIN, math.floor(rest * PROBLEMS_NAME_SHARE))
		fourth = math.max(PROBLEMS_MIN, rest - name - dl * SLOT)
		name = rest - fourth - dl * SLOT
	else
		fourth = pr * SLOT
		name = rest - fourth - dl * SLOT
	end
	while name < NAME_MIN and not problems and pr > 5 do
		pr = pr - 1
		fourth = pr * SLOT
		name = name + SLOT
	end
	while name < NAME_MIN and dl > 2 do
		dl = dl - 1
		name = name + SLOT
	end
	while name < NAME_MIN and ctl > 3 do
		ctl = ctl - 1
		name = name + SLOT
	end
	while name < NAME_MIN and show_control and pr > 3 do
		pr = pr - 1
		fourth = pr * SLOT
		name = name + SLOT
	end
	-- On a window too narrow for both, the Problems column gives up its minimum before the name does.
	if problems and name < NAME_MIN then
		local give = math.min(NAME_MIN - name, fourth)
		fourth = fourth - give
		name = name + give
	end
	return {
		cw = cw,
		sig = cw .. (problems and "p" or "") .. (hide_wait and "w" or "") .. (show_control and "c" or ""),
		problems_view = problems == true,
		hide_wait = hide_wait == true,
		show_control = show_control == true,
		name = name,
		station_status = W.station_status,
		network = W.network,
		priority = W.priority,
		pr_slots = pr,
		provided_requested = pr * SLOT,
		problems = fourth,
		dl_slots = dl,
		dl_count = W.dl_count,
		deliveries = W.dl_count + 4 + dl * SLOT,
		wait = wait,
		last_delivery = W.last_delivery,
		ctl_slots = ctl,
		control = show_control and ctl * SLOT + CONTROL_GAP or 0,
	}
end

--- @param player_data PlayerData
--- @param problems boolean?
--- @param hide_wait boolean?
--- @return table
local function widths_for(player_data, problems, hide_wait)
	local layout = player_data.layout
	local cw = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	return column_widths(cw, problems, hide_wait, stations_tab.control_shown(player_data))
end

--- Whether the Control signals column shows: the player's choice from the toggle, else (Auto) whenever it fits beside
--- a name of NAME_MIN. Fit is judged with Wait shown, so the column does not come and go with the page.
--- @param player_data PlayerData
--- @return boolean
function stations_tab.control_shown(player_data)
	local choice = player_data.tabs.stations_tab.control
	if choice ~= nil then return choice end
	local layout = player_data.layout
	local cw = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	return column_widths(cw, false, false, true).name >= NAME_MIN
end

--- @param column string
--- @return LocalisedString caption
--- @return LocalisedString tooltip
local function header_texts(column)
	local locale = string.gsub(column, "_", "-")
	return { "cybersyn-gui." .. (CAPTION_KEY[column] or locale) },
		{ "cybersyn-gui." .. (SORT_KEY[column] or ("stations-sort-" .. locale)) }
end

local function header_cell(column, width, selected)
	local caption, tooltip = header_texts(column)
	if column == "control" then
		return {
			type = "flow",
			direction = "horizontal",
			style_mods = { width = width, vertical_align = "center", left_padding = CONTROL_GAP },
			{ type = "label", style = "cybersyn_list_header_label", caption = caption,
				tooltip = { "cybersyn-gui.stations-control-tooltip" } },
		}
	end
	return {
		type = "flow",
		direction = "horizontal",
		style_mods = { width = width, horizontal_align = RIGHT[column] and "right" or "left", vertical_align = "center" },
		templates.sort_checkbox(TAB, column, caption, tooltip, selected, listing.handle.sort_click),
	}
end

function stations_tab.create()
	local w = column_widths(sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	local header = { type = "frame", name = HEADER, style = "cybersyn_list_header" }
	for i, column in ipairs(COLUMNS) do
		header[#header + 1] = header_cell(column, w[column], i == 1)
	end
	return {
		tab = {
			name = "manager_stations_tab",
			type = "tab",
			caption = { "cybersyn-gui.stations" },
		},
		content = {
			name = "manager_stations_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			-- Right below the subheader (manager.add_header puts the banner and the subheader first).
			{
				type = "frame",
				name = CHIP_ROW,
				style = "cybersyn_chip_row",
				visible = false,
				{ type = "empty-widget", style = "flib_horizontal_pusher" },
				{
					type = "flow",
					name = CHIPS2,
					direction = "horizontal",
					style_mods = { vertical_align = "center", horizontal_spacing = 4 },
				},
			},
			header,
			{ name = SCROLL, type = "flow", direction = "vertical", style = "cybersyn_list_rows" },
			{
				name = "manager_stations_warning_flow",
				type = "flow",
				style = "ltnm_warning_flow",
				visible = false,
				{
					name = "manager_stations_warning_label",
					type = "label",
					style = "ltnm_semibold_label",
					caption = { "cybersyn-gui.no-stations" },
				},
			},
			{
				type = "frame",
				name = "manager_stations_subfooter",
				style = "cybersyn_list_subfooter",
				{ type = "label", name = "manager_stations_summary", style = "cybersyn_subheader_note" },
				{ type = "empty-widget", style = "flib_horizontal_pusher" },
				templates.pager(TAB, listing.handle.pager_click),
			},
		},
	}
end

--- Active requests of `st` with no provider on any of its networks, in item order, for the status tooltip.
--- @param st SnapshotStation
--- @param starved {[string]: true}
--- @return string[]|false
local function starved_hashes(st, starved)
	local hashes = collector.starved_hashes(st, starved)
	if hashes then util.sort_by(hashes, util.item_rank, true, function(h) return h end) end
	return hashes
end

local function finite_limit(st)
	local limit = st.trains_limit
	return limit < UNLIMITED and limit or nil
end

-- Shifts a signed 32-bit mask to a non-negative 10-digit number so its zero-padded string sorts in signed order.
local OFFSET = 2147483648

-- Natural sort keys of station names ("stn-2" before "stn-10"): a pure function of the name, so a cache that differs
-- between Lua states cannot desync anything.
local natural_cache = {}

--- @param name_lower string
--- @return string
local function natural(name_lower)
	local key = natural_cache[name_lower]
	if not key then
		key = util.natural_key(name_lower)
		natural_cache[name_lower] = key
	end
	return key
end

--- True while no train has been dispatched to or from the station since it was built: Cybersyn starts
--- last_delivery_tick at the build tick, which the station record keeps as created_tick (stations built before that
--- field existed cannot tell and show their age). The tick is the snapshot's, as the age and the sort key are, so the
--- three agree during a pass; created_tick never changes and is read live.
--- @param st SnapshotStation
--- @return boolean
local function never_dispatched(st)
	local stations = storage.stations
	local station = stations and stations[st.id]
	return station ~= nil and station.created_tick ~= nil and st.last_delivery_tick == station.created_tick
end
stations_tab.never_dispatched = never_dispatched

--- The control combinator's priority when it applies (items with their own threshold there), and how many items.
--- @param st SnapshotStation
--- @return int? priority
--- @return int items
local function item_priority(st)
	local control2, thresholds = st.control2, st.thresholds
	local p = control2 and control2[SIGNAL_PRIORITY]
	local n = thresholds and table_size(thresholds) or 0
	if p == nil or n == 0 then return nil, 0 end
	return p, n
end

--- The request start tick of the row's longest-waiting active request. A row on the station's own lists (a station
--- without inventories) is the station's figure.
--- @param row SnapshotInventory
--- @return uint?
local function row_wait_start(row)
	local st = row.st
	if row.requested == st.requested then return st.longest_wait_start end
	local wait = st.wait
	local start
	for hash, req in pairs(row.requested) do
		if req.active then
			local t = wait and wait[hash]
			if t and (not start or t < start) then start = t end
		end
	end
	return start
end

--- Sort keys of a row (one row per combinator); each must return only numbers or only strings (nil sorts
--- last). The network, provided / requested, priority and wait keys are the row's own; the others are its station's,
--- so a sort on them keeps a station's rows together. Keys are cached per row between collector passes, so they must
--- not depend on the current tick: ages sort by their negated start tick.
--- @type {[string]: fun(row: SnapshotInventory, ctx: table): (number|string|nil)}
local sort_keys = {
	name = function(row) return natural(row.st.name_lower) end,
	station_status = function(row, ctx) return STATUS_RANK[ctx.status[row.st.id]] end,
	network = function(row)
		local name = row.network_name
		if not name then return nil end
		local mask = row.mask
		if name ~= NETWORK_EACH and mask == nil or name == NETWORK_EACH and not row.networks then return nil end
		return string.format("%s\0%010.0f", name, type(mask) == "number" and mask + OFFSET or 0)
	end,
	provided_requested = function(row) return table_size(row.provided) + table_size(row.requested) end,
	priority = function(row) return row.priority end,
	deliveries = function(row) return row.st.deliveries_total end,
	wait = function(row)
		local start = row_wait_start(row)
		return start and -start or nil
	end,
	last_delivery = function(row)
		local st = row.st
		local last = st.last_delivery_tick
		if not last or never_dispatched(st) then return nil end
		return -last
	end,
	-- Open errors first (the Overview's Misconfigured stations), then open warnings and info, then stations whose
	-- findings are all acknowledged; by worst check within each. Acknowledgements change without a change-log entry,
	-- so query refreshes these keys when storage.acks.lint_version moves (diag.expire_acks bumps it as well).
	problems = function(row) return pm.station_rank(row.st.id, row.st.lint, diag.is_acked) end,
}

--- The toggled chip: a status, one of the flag chips, or nil (All). A value no chip has any more reads as All.
--- @param player_data PlayerData
--- @return string?
local function active_chip(player_data)
	local c = player_data.filters.stations_chip
	if c and (STATUS_RANK[c] or FLAG_CHIPS[c] or c == "stuck") then return c end
	return nil
end

--- The sort column for the view: the Problems column sorts only while it shows, and stands in for Provided /
--- requested there.
--- @param column string
--- @param problems boolean
--- @return string
local function view_column(column, problems)
	if problems and column == "provided_requested" then return "problems" end
	if not problems and column == "problems" then return "provided_requested" end
	return column
end

-- Everything the filtered set depends on besides the data itself. The chip is left out: it is applied after the
-- cached order, so a station changing status mid-pass shows up at once, matching the chip counts.
local filter_sig = filters.filter_signature

local function view_sig(f, column, ascending)
	return column .. "\1" .. (ascending and "+" or "-") .. "\1" .. filter_sig(f)
end

--- @param counts table
--- @param flags int
--- @param d int +1 or -1
local function count_flags(counts, flags, d)
	if band(flags, logic.FLAG_UNSERVED) ~= 0 then counts.unserved = counts.unserved + d end
	if band(flags, logic.FLAG_SETUP) ~= 0 then counts.problems = counts.problems + d end
	if band(flags, logic.FAILING) ~= 0 then counts.failing = counts.failing + d end
end

--- @return int
local function lint_ack_version()
	local acks = storage.acks
	return acks and acks.lint_version or 0
end

--- Re-reads the Problems sort key of every listed row of a station with a finding after an acknowledgement changed;
--- the rows whose place moved are merged into the order on this render: one explicit click, not a data-driven
--- reshuffle that waits for the pass.
--- @param cache table
local function refresh_problem_keys(cache)
	local keys, key_fn, rec, rows_of = cache.keys, sort_keys.problems, cache.rec, cache.rows_of
	local changed = cache.changed
	if not changed then
		changed = {}
		cache.changed = changed
	end
	for id, fl in pairs(cache.flags) do
		if band(fl, FLAG_SETUP) ~= 0 then
			for _, rk in ipairs(rows_of[id] or {}) do
				local row = rec[rk]
				local key = row and key_fn(row)
				if keys[rk] ~= key then
					keys[rk] = key
					changed[rk] = true
					cache.dirty = true
					cache.sort_now = true
				end
			end
		end
	end
end

--- Stations of the filtered set with an error nobody acknowledged, and those whose errors are all acknowledged: the
--- Overview's Misconfigured line and its "+n acked" under the same filters (pm.open_errors is its rule).
--- @param cache table
--- @return int open
--- @return int acked
local function open_error_counts(cache)
	local stations = collector.get().stations
	local error_mask, open_errors, is_acked = pm.error_mask(), pm.open_errors, diag.is_acked
	local open, acked = 0, 0
	for id, fl in pairs(cache.flags) do
		local st = stations[id]
		if st and band(fl, FLAG_SETUP) ~= 0 and band(st.lint or 0, error_mask) ~= 0 then
			if open_errors(id, st.lint, is_acked) > 0 then open = open + 1 else acked = acked + 1 end
		end
	end
	return open, acked
end

local NO_KEYS = {}

--- Rewrites the cached rows of one station: drops the keys it listed, then adds each of its rows the filters let
--- through (filters.row_passes) with its sort key. Every key dropped or added is marked changed.
--- @param cache table
--- @param id uint
--- @param st SnapshotStation? nil or failing the filters: the station lists no rows
--- @param f ManagerFilters
--- @param key_fn function
--- @param ctx table
--- @return boolean moved a key was added, dropped or got another sort key
--- @return boolean relisted a key was added or dropped, or a key's row record was replaced
local function refill_rows(cache, id, st, f, key_fn, ctx)
	local keys, rec, index, changed, rows_of = cache.keys, cache.rec, cache.index, cache.changed, cache.rows_of
	local old = rows_of[id] or NO_KEYS
	local moved, relisted = false, false
	local rows = st and collector.inventories(st) or NO_KEYS
	local row_passes = filters.row_passes
	-- A station seen for the first time (every station of a rebuild) builds its list in this one walk.
	local fresh = #old == 0
	local new
	-- Most refills list the same keys again: the old list is kept then, so a pass allocates nothing per station.
	local n, same = 0, true
	for _, row in ipairs(rows) do
		if row_passes(row, f) then
			n = n + 1
			local rk = row.key
			if old[n] ~= rk then same = false end
			if fresh then
				new = new or {}
				new[n] = rk
			end
			local key = key_fn(row, ctx)
			if rec[rk] ~= row then relisted = true end
			if rec[rk] ~= row or keys[rk] ~= key or index[rk] ~= row.index then
				rec[rk], keys[rk], index[rk] = row, key, row.index
				changed[rk] = true
				moved = true
			end
		end
	end
	if same and n == #old then return moved, relisted end
	if fresh then
		rows_of[id] = new
		return true, true
	end
	new = n > 0 and {} or nil
	local listed = {}
	n = 0
	for _, row in ipairs(rows) do
		if rec[row.key] == row and row_passes(row, f) then
			n = n + 1
			new[n] = row.key
			listed[row.key] = true
		end
	end
	for _, rk in ipairs(old) do
		if not listed[rk] then
			rec[rk], keys[rk], index[rk] = nil, nil, nil
			changed[rk] = true
		end
	end
	rows_of[id] = new
	return true, true
end

--- Rescans every snapshot station into a fresh per-player query cache.
local function rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
	local stations = snapshot.stations
	local key_fn = sort_keys[column]
	local status, flags, nat = {}, {}, {}
	local counts = { all = 0, unserved = 0, problems = 0, failing = 0 }
	for _, s in ipairs(STATUSES) do counts[s] = 0 end
	local ctx = { status = status }
	local cache = {
		epoch = epoch, pos = pos, fsig = fsig, column = column, status = status, keys = {}, rec = {}, index = {},
		rows_of = {}, flags = flags, nat = nat, counts = counts, dirty = true, changed = {},
	}
	local station_flags, passes = logic.station_flags, filters.station_passes
	local shown, is_acked = pm.shown_status, diag.is_acked
	local all, unserved, setup, failing = 0, 0, 0, 0
	for id, st in pairs(stations) do
		if passes(st, f) then
			local s = shown(st.status, id, st.lint, is_acked)
			status[id] = s
			counts[s] = counts[s] + 1
			all = all + 1
			local fl = station_flags(st)
			-- Records without a chip flag keep no entry (most stations on a large base).
			if fl ~= 0 then
				flags[id] = fl
				if band(fl, FLAG_UNSERVED) ~= 0 then unserved = unserved + 1 end
				if band(fl, FLAG_SETUP) ~= 0 then setup = setup + 1 end
				if band(fl, FAILING) ~= 0 then failing = failing + 1 end
			end
			nat[id] = natural(st.name_lower)
			refill_rows(cache, id, st, f, key_fn, ctx)
		end
	end
	counts.all, counts.unserved, counts.problems, counts.failing = all, unserved, setup, failing
	cache.changed = {}
	player_data.cache.stations = cache
	return cache
end

--- Folds the station records the collector refilled, reclassified or removed since the last render into the cache.
local function apply_changes(cache, snapshot, f, ids, first, last)
	local stations = snapshot.stations
	local key_fn = sort_keys[cache.column]
	local status, counts, flags = cache.status, cache.counts, cache.flags
	if not cache.changed then cache.changed = {} end
	local ctx = { status = status }
	for i = first, last do
		local id = ids[i]
		local st = stations[id]
		local old = status[id]
		local new = st and filters.station_passes(st, f) and pm.shown_status(st.status, id, st.lint, diag.is_acked) or nil
		local old_flags = flags[id] or 0
		local new_flags = new and logic.station_flags(st) or 0
		if old ~= new then
			cache.version = (cache.version or 0) + 1
			if old then
				counts[old] = counts[old] - 1
				counts.all = counts.all - 1
			end
			if new then
				counts[new] = counts[new] + 1
				counts.all = counts.all + 1
			end
			status[id] = new
			if not old or not new then cache.dirty = true end
		end
		if old_flags ~= new_flags then
			count_flags(counts, old_flags, -1)
			count_flags(counts, new_flags, 1)
			flags[id] = new_flags ~= 0 and new_flags or nil
			cache.version = (cache.version or 0) + 1
		end
		local name_key = new and natural(st.name_lower) or nil
		local renamed = cache.nat[id] ~= name_key
		if renamed then cache.nat[id] = name_key end
		local moved, relisted = refill_rows(cache, id, new and st or nil, f, key_fn, ctx)
		if moved then cache.dirty = true end
		-- The row list follows the keys a station lists and the records it holds, not only the statuses. A sort key
		-- that moved waits for the re-sort, so it does not rebuild the list (2,000+ rows on a large base) on every
		-- render of a pass under a count sort.
		if relisted then cache.version = (cache.version or 0) + 1 end
		if renamed then
			cache.dirty = true
			for _, rk in ipairs(cache.rows_of[id] or NO_KEYS) do cache.changed[rk] = true end
		end
	end
end

--- An acknowledgement turns a Setup status back into OK (and an expiry the other way) without a change-log entry, so
--- the stations with a finding are folded in again when storage.acks.lint_version moves.
--- @param cache table
--- @param snapshot Snapshot
--- @param f ManagerFilters
local function refresh_setup_statuses(cache, snapshot, f)
	local ids = {}
	for id, fl in pairs(cache.flags) do
		if band(fl, FLAG_SETUP) ~= 0 then ids[#ids + 1] = id end
	end
	if #ids > 0 then apply_changes(cache, snapshot, f, ids, 1, #ids) end
end

--- The display order as a comparator over row keys: key in the requested direction with nil last, then the station's
--- natural name key and id ascending, then the inventory index, so a name sort keeps a station's rows together. No
--- per-row tables: 2,000+ of them per sort on a large base.
--- @param keys {[string]: any}
--- @param nat {[uint]: string} natural name keys by station id
--- @param rec {[string]: SnapshotInventory}
--- @param index {[string]: int}
--- @param ascending boolean
--- @return fun(a: string, b: string): boolean
local function order_less(keys, nat, rec, index, ascending)
	return function(a, b)
		local ka, kb = keys[a], keys[b]
		if ka ~= kb then
			if ka == nil then return false end
			if kb == nil then return true end
			if ascending then return ka < kb end
			return ka > kb
		end
		local ia, ib = rec[a].st.id, rec[b].st.id
		if ia ~= ib then
			local na, nb = nat[ia], nat[ib]
			if na ~= nb then return na < nb end
			return ia < ib
		end
		return index[a] < index[b]
	end
end

--- Sorting every row costs about 3 ms on a 2,000-station base and a pass changes the keys of only some of them, so
--- the previous order is kept for the rest and the re-sorted changed keys are merged into it.
--- @return string[]? order nil when so many keys changed that a full sort is cheaper
local function merge_changes(cache, ascending)
	local rec, changed = cache.rec, cache.changed
	local moved = {}
	for rk in pairs(changed) do
		if rec[rk] then moved[#moved + 1] = rk end
	end
	local old = cache.order
	if #moved * 4 > #old then return nil end
	local less = order_less(cache.keys, cache.nat, rec, cache.index, ascending)
	table.sort(moved, less)
	local order = {}
	local n, j, m = 0, 1, #moved
	for _, rk in ipairs(old) do
		if rec[rk] and not changed[rk] then
			while j <= m and less(moved[j], rk) do
				n = n + 1
				order[n] = moved[j]
				j = j + 1
			end
			n = n + 1
			order[n] = rk
		end
	end
	for k = j, m do
		n = n + 1
		order[n] = moved[k]
	end
	return order
end

--- Stations named by a train with a stuck alert, and a signature of the set for the row cache.
--- @param snapshot Snapshot
--- @return {[uint]: true}
--- @return string
local function stuck_set(snapshot)
	local set = logic.stuck_stations(snapshot.alerts, snapshot.trains, ALERT_STUCK)
	local ids = {}
	for id in pairs(set) do ids[#ids + 1] = id end
	table.sort(ids)
	return set, table.concat(ids, ",")
end

--- @param chip string?
--- @param id uint
--- @param cache table
--- @param stuck {[uint]: true}
--- @return boolean
local function chip_passes(chip, id, cache, stuck)
	if not chip then return true end
	if STATUS_RANK[chip] then return cache.status[id] == chip end
	if chip == "stuck" then return stuck[id] == true end
	return band(cache.flags[id] or 0, FLAG_CHIPS[chip]) ~= 0
end

--- Filters, classifies and sorts the snapshot stations' inventory rows (one row per combinator; the
--- counts stay per station). The chip applies after counting so every chip shows what it would yield.
--- Classification is cached per player and updated only for the records the collector replaced since the last
--- render, so a render costs O(changed + page) rather than O(stations). Sorting 2,000 rows costs more than the
--- rest of an update, so the order is kept until the sort or a filter changes, or a completed pass changed a key
--- or the filtered set; in between, rows show live data in the order of the last sort, which also keeps them
--- from shuffling while a pass trickles in.
--- @param player_data PlayerData
--- @return SnapshotInventory[] rows
--- @return {[string]: integer} counts per status and chip over the filtered stations, plus `all`
--- @return table ctx {status = {[id]=status}, flags, stuck, now, snapshot, stations = stations the rows list}
--- @return string column
--- @return boolean ascending
function stations_tab.query(player_data)
	local snapshot = collector.get()
	local stations = snapshot.stations
	local f = filters.get(player_data, TAB)
	local wanted = active_chip(player_data)
	local problems = wanted == "problems"
	-- The Overview's Misconfigured jump narrows the Problems view to the stations its line counts (p1's contract).
	if not problems then player_data.filters.problems_scope = nil end
	local errors_only = problems and player_data.filters.problems_scope == "errors"
	if problems ~= (player_data.tabs.stations_tab.problems_view == true) then
		-- The Problems view opens worst first; leaving it drops its sort.
		player_data.tabs.stations_tab.problems_view = problems or nil
		local current = listing.get_sort(player_data, TAB, "name")
		if problems then
			listing.set_sort(player_data, TAB, "problems", true)
		elseif current == "problems" then
			listing.set_sort(player_data, TAB, "name", true)
		end
	end
	local column, ascending = listing.get_sort(player_data, TAB, "name")
	column = view_column(column, problems)
	if not sort_keys[column] then column = "name" end
	-- The first pass after opening is still filling records: rows and counts from part of the stations would change
	-- on every update and disagree with the other tabs, so there are none until it completes.
	local cache = player_data.cache.stations
	-- The first build after a boosted pass is split over three renders, so no tick carries more than one of the
	-- pass's last batch, classifying every station, sorting them (together 6.4-6.6 ms on a 2,000-station base with
	-- the chip flags) or writing every row of the page (3.8-4.4 ms): the completing tick shows nothing yet, the next
	-- render classifies, the one after sorts, and the next writes the rows. Each deferred render owes the next tick
	-- one (render), so a first visit long after the pass completed (a tab switch) also gets its rows within three
	-- ticks.
	if not snapshot.tick or (not cache and snapshot.boosted and snapshot.tick == game.tick) then
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	local first_build = not cache and snapshot.boosted

	local fsig = filter_sig(f)
	local epoch, pos = collector.log_position()
	local ids, first, last
	if cache and cache.fsig == fsig and cache.column == column and cache.flags and cache.nat and cache.rows_of then
		ids, first, last = collector.changed_since(cache.epoch, cache.pos)
	end
	local av = lint_ack_version()
	if ids then
		apply_changes(cache, snapshot, f, ids, first, last)
		cache.pos = pos
	else
		cache = rebuild_query(player_data, snapshot, f, fsig, column, epoch, pos)
		cache.av = av
	end
	if cache.av ~= av then
		if column == "problems" then refresh_problem_keys(cache) end
		refresh_setup_statuses(cache, snapshot, f)
		cache.av = av
	end
	if first_build then
		cache.defer_sort = true
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	local status = cache.status
	local stuck, stuck_sig = stuck_set(snapshot)
	local n_stuck = 0
	for id in pairs(stuck) do
		if status[id] then n_stuck = n_stuck + 1 end
	end
	cache.counts.stuck = n_stuck
	local ctx = { status = status, flags = cache.flags, stuck = stuck, now = game.tick, snapshot = snapshot }

	-- An empty order (the window opened before the first pass completed) has no rows to keep still.
	local resort = not cache.order or cache.ascending ~= ascending or (cache.dirty and #cache.order == 0)
	-- A data-driven re-sort waits for the update after the one that completed the pass, which carries the pass's
	-- last collector batch; the next one carries only the cheap start of a new pass.
	if resort or cache.sort_now or (cache.dirty and cache.sorted_tick ~= snapshot.tick and snapshot.tick ~= game.tick) then
		cache.sort_now = nil
		local order = not resort and merge_changes(cache, ascending) or nil
		cache.sort_kind = order and "merged" or "full"
		if not order then
			order = {}
			for rk in pairs(cache.rec) do order[#order + 1] = rk end
			table.sort(order, order_less(cache.keys, cache.nat, cache.rec, cache.index, ascending))
		end
		cache.order = order
		cache.ascending = ascending
		cache.sorted_tick = snapshot.tick
		cache.dirty = false
		cache.changed = {}
	end

	-- The row list only changes with the order, the chip, a status or flag, or the stuck set; rebuilding it every
	-- update allocated tens of KB per render on a large base.
	local rows = cache.rows
	local want_sig = (wanted or "") .. (wanted == "stuck" and ("\1" .. stuck_sig) or "")
	if errors_only then
		local ls = storage.manager.lint
		want_sig = want_sig .. "\2" .. lint_ack_version() .. ":" .. (ls and ls.pass or 0)
	end
	if not rows or cache.rows_order ~= cache.order or cache.rows_wanted ~= want_sig or cache.rows_version ~= cache.version then
		rows = {}
		local seen, n_stations = {}, 0
		local rec, rows_of = cache.rec, cache.rows_of
		local open_errors = util.open_setup_errors
		for _, rk in ipairs(cache.order) do
			local row = rec[rk]
			local id = row and row.st.id
			-- Findings are about the stop: the Problems view lists each station once, on the first of its rows the
			-- filters keep. Under a mask or item filter that need not be the station combinator's, and the station
			-- still counts in the chips.
			if row and status[id] and chip_passes(wanted, id, cache, stuck) and not (problems and rows_of[id][1] ~= rk)
				and (not errors_only or open_errors(id, row.st.lint) > 0) then
				rows[#rows + 1] = row
				if not seen[id] then
					seen[id] = true
					n_stations = n_stations + 1
				end
			end
		end
		cache.rows, cache.rows_order, cache.rows_wanted, cache.rows_version = rows, cache.order, want_sig, cache.version
		cache.rows_stations = n_stations
	end
	ctx.stations = cache.rows_stations
	if cache.defer_sort then
		cache.defer_sort = nil
		return {}, {}, { status = {}, flags = {}, stuck = {}, now = game.tick, snapshot = snapshot, pending = true }, column, ascending
	end
	return rows, cache.counts, ctx, column, ascending
end

-- ---------------------------------------------------------------- rows

local NONE_CAPTION = { "cybersyn-gui.none-short" }
local NEVER_CAPTION = { "cybersyn-gui.never" }
-- Findings a Problems cell's tooltip spells out; the rest are counted.
local TOOLTIP_FINDINGS = 6
-- Subjects that have a row of their own elsewhere (stations here, the rest on Trains); every other subject is a stop
-- or combinator the registry reports, listed after the stations.
local NOT_REGISTRY = {
	[LINT_SUBJECT_STATION] = true,
	[LINT_SUBJECT_DEPOT] = true,
	[LINT_SUBJECT_REFUELER] = true,
	[LINT_SUBJECT_TRAIN] = true,
}

-- ---------------------------------------------------------------- problems

--- @class StationsProblems
--- @field src LintFinding[] lint.findings() it was built from
--- @field av int storage.acks.lint_version it was built at
--- @field expiry uint? the earliest end of an acknowledgement it shows
--- @field by_id {[uint]: ProblemEntry[]} a station's findings in the order its cell shows them
--- @field registry ProblemEntry[] findings about stops and combinators that are not a station

--- The last lint pass's findings by station, and the registry's, rebuilt only when the pass, the registry or an
--- acknowledgement changed (or one of the acknowledgements shown ran out).
--- @param cache table the player's stations query cache
--- @return StationsProblems
local function problem_index(cache)
	local findings = lint.findings()
	local acks = storage.acks
	local av = acks and acks.lint_version or 0
	local px = cache.problems
	if px and px.src == findings and px.av == av and not (px.expiry and game.tick >= px.expiry) then
		return px
	end
	local by_station, registry = {}, {}
	local function add(f)
		if f.subject == LINT_SUBJECT_STATION then
			local list = get_or_create(by_station, f.id)
			list[#list + 1] = f
		elseif not NOT_REGISTRY[f.subject] then
			registry[#registry + 1] = f
		end
	end
	for _, f in ipairs(findings) do add(f) end
	local expiry
	local function is_acked(f)
		local a = diag.is_acked("lint", lint.subject_key(f.subject, f.id), f.check)
		if a and a.until_tick and (not expiry or a.until_tick < expiry) then expiry = a.until_tick end
		return a
	end
	local by_id = {}
	for id, list in pairs(by_station) do by_id[id] = pm.order(list, is_acked) end
	px = { src = findings, av = av, by_id = by_id, registry = pm.order(registry, is_acked) }
	px.expiry = expiry
	cache.problems = px
	return px
end

--- Progress of the first lint pass in percent while there is no result yet, nil once there is one.
--- @return int?
local function lint_pending()
	local p = lint.progress()
	return p and math.floor(100 * p)
end

--- @param a DiagAck
--- @param now uint
--- @return LocalisedString
local function acked_line(a, now)
	local who = a.player_index and game.get_player(a.player_index)
	local until_text = a.until_tick and logic.format_duration(a.until_tick - now) or nil
	return { "cybersyn-gui.unserved-ack-tooltip-acked", who and who.name or "-",
		until_text and { "cybersyn-gui.unserved-ack-for", until_text } or { "cybersyn-gui.problems-ack-until-clear" } }
end

--- Caption, severity, predicted reason, fix line and numbers of each finding, worst first.
--- @param entries ProblemEntry[]
--- @param snapshot Snapshot
--- @param now uint
--- @return LocalisedString
local function problems_tooltip(entries, snapshot, now)
	local out = { "" }
	for i = 1, math.min(#entries, TOOLTIP_FINDINGS) do
		local e = entries[i]
		local f = e.f
		local t = lint_text.texts(f.check, lint_text.role_of(f, snapshot), f)
		local part = { "", "[img=" .. (e.ack and pm.ACKED_DOT or pm.DOT[e.sev]) .. "] ", t.tooltip, "\n",
			pm.detail(f, lint_text.ENV) }
		if e.ack then
			part[#part + 1] = "\n"
			part[#part + 1] = acked_line(e.ack, now)
		end
		if i > 1 then out[#out + 1] = "\n\n" end
		out[#out + 1] = part
	end
	if #entries > TOOLTIP_FINDINGS then
		out[#out + 1] = "\n\n"
		out[#out + 1] = { "cybersyn-gui.stations-problems-more", tostring(#entries - TOOLTIP_FINDINGS) }
	end
	return out
end

--- What a Problems cell shows: the first finding spelled out, "+n" for the others, all of them in the tooltip, and an
--- acknowledge button for the row (tags: `sid` = station id, or `rk`/`ck` = subject key and check of a registry row).
--- @param entries ProblemEntry[]?
--- @param tags table
--- @param ctx table
--- @return table
local function problems_view(entries, tags, ctx)
	local n = entries and #entries or 0
	local p = { n = n, tags = tags }
	if n == 0 then
		p.sig = "0"
		return p
	end
	local parts = { tostring(n), tostring(tags.sid or ((tags.rk or "") .. ":" .. (tags.ck or ""))) }
	local open = 0
	for _, e in ipairs(entries) do
		local a = e.ack
		if not a then open = open + 1 end
		parts[#parts + 1] = e.f.check .. ":" .. pm.detail_sig(e.f)
			.. (a and (":" .. tostring(a.until_tick) .. "/" .. tostring(a.player_index)) or "")
	end
	p.sig = table.concat(parts, "|")
	p.all_acked = open == 0
	p.write = function(r)
		local first = entries[1]
		local f = first.f
		local acked = first.ack ~= nil
		r.dot.sprite = acked and pm.ACKED_DOT or pm.DOT[first.sev]
		r.dot.visible = true
		local style = acked and "cybersyn_chip_acked" or pm.CHIP_STYLE[first.sev]
		local chip = r.chip
		if chip.style.name ~= style then
			chip.style = style
			-- The check stays readable; the detail squashes instead (assigning a style drops this).
			chip.style.horizontally_squashable = false
		end
		chip.caption = pm.chip(f.check)
		chip.visible = true
		r.detail.caption = pm.detail(f, lint_text.ENV)
		local detail_style = acked and "cybersyn_lint_detail_acked" or "cybersyn_lint_detail"
		if r.detail.style.name ~= detail_style then r.detail.style = detail_style end
		r.more.caption = n > 1 and ("+" .. (n - 1)) or ""
		r.more.visible = n > 1
		r.cell.tooltip = problems_tooltip(entries, ctx.snapshot, ctx.now)
		local ack = r.ack
		ack.visible = true
		-- Merged into the element's tags: they also carry flib's handler name.
		local t = ack.tags
		t.sid, t.rk, t.ck = tags.sid, tags.rk, tags.ck
		ack.tags = t
		if ack.toggled ~= p.all_acked then ack.toggled = p.all_acked end
		ack.tooltip = p.all_acked and acked_line(first.ack, ctx.now) or { "cybersyn-gui.problems-ack-tooltip" }
	end
	return p
end

--- @param r table problems cell refs
local function clear_problems(r)
	r.dot.visible = false
	r.chip.visible = false
	r.detail.caption = ""
	r.more.visible = false
	r.ack.visible = false
	r.cell.tooltip = ""
end

local parse_name = name_cell.parse_name

--- The stop or combinator a registry finding is about, while it exists.
--- @param f LintFinding
--- @return LuaEntity?
local function entity_of(f)
	local e = f.entity
	if e and e.valid then return e end
	e = lint.registry_entity(f.id)
	if e and e.valid then return e end
	return nil
end

--- The registry findings the filters let through: they belong to no network and carry no item, so a network, network
--- ID or item filter hides them; the surface filter and the name search apply.
--- @param px StationsProblems
--- @param f ManagerFilters
--- @return {e: ProblemEntry, entity: LuaEntity?, name: string}[]
local function registry_rows(px, f)
	local out = {}
	if #px.registry == 0 or f.network or f.item or f.station or (f.mask and f.mask ~= -1) then return out end
	for _, e in ipairs(px.registry) do
		local gone = e.f.entity
		-- The entity went without an event the registry hears (a script destroy that raised none): no row.
		if gone and not gone.valid then goto continue end
		local entity = entity_of(e.f)
		local name, parts
		if entity then
			if entity.type == "train-stop" then
				name = entity.backer_name
			else
				local pos = entity.position
				parts = { lead = { "item/" .. COMBINATOR_NAME }, text = math.floor(pos.x) .. ", " .. math.floor(pos.y) }
				name = "[item=" .. COMBINATOR_NAME .. "] " .. parts.text
			end
		else
			name = "#" .. e.f.id
		end
		-- Without its entity a row cannot tell its surface: a surface filter hides it.
		local pass = not (f.surface and (not entity or entity.surface_index ~= f.surface))
		if pass and f.terms then
			pass = filters.terms_match(helpers.multilingual_to_lower(parts and parts.text or name), f.terms)
		end
		if pass then out[#out + 1] = { e = e, entity = entity, name = name, parts = parts } end
		::continue::
	end
	return out
end

--- @param f LintFinding
--- @return string
local function registry_key(f)
	return "r" .. f.check .. ":" .. f.subject .. ":" .. f.id .. ":" .. tostring(f.message or f.item or "")
end

--- A registry row in the shape of a station row (rows are reused across both): the stop's name or the combinator's
--- position linked to the entity, "Train stop" or "Combinator" in the Status column, the finding in the Problems
--- column, the other cells empty.
--- @param row {e: ProblemEntry, entity: LuaEntity?, name: string, parts: RichNameParts?}
--- @param ctx table
--- @return table
local function registry_model(row, ctx)
	local f = row.e.f
	local kind = "entity"
	if f.subject == LINT_SUBJECT_STOP then
		kind = storage.stations[f.id] and "station" or storage.depots[f.id] and "depot"
			or storage.refuelers[f.id] and "refueler" or "entity"
	end
	local subject = LINT_SUBJECT_NAMES[f.subject] or "stop"
	local m = {
		registry = true,
		key = registry_key(f),
		name = row.name,
		parts = row.parts or parse_name(row.name),
		link = { kind = kind, id = f.id },
		status_sig = "registry:" .. subject,
		status_sprite = "flib_indicator_white",
		status_caption = { "cybersyn-gui.stations-registry-" .. subject },
		status_tip_sig = "registry",
		net_sig = "-",
		dl_caption = "",
		dl_sig = "-",
		wait_caption = "",
		wait_sig = "-",
		last_caption = "",
		last_sig = "-",
	}
	m.name_sig = row.name .. "\1" .. kind .. f.id
	m.name_tooltip = function()
		return { "", "[font=default-semibold]", row.name, "[/font]\n", { "cybersyn-gui.stations-registry-tooltip" }, "\n",
			links.LINK_FOOTER }
	end
	m.status_tooltip = function() return { "cybersyn-gui.stations-registry-tooltip" } end
	m.network = function() return "", "", "" end
	m.problems = problems_view({ row.e }, { rk = lint.subject_key(f.subject, f.id), ck = f.check }, ctx)
	return m
end

local SILENT_TOOLTIP = {
	off = "cybersyn-gui.stations-inventory-off-tooltip",
	empty = "cybersyn-gui.stations-inventory-empty-tooltip",
}

--- Why an inventory advertises on no network, as the Network cell's tooltip says it: only a row the station
--- combinator holds back gets the paused text, which blames the station combinator.
--- @param row SnapshotInventory
--- @param reason string rtext.silent_reason(row)
--- @return LocalisedString
local function silent_text(row, reason)
	if reason == "paused" then return { rtext.paused_key(row.st), row.label } end
	return { SILENT_TOOLTIP[reason], row.label }
end

--- The Network cell of a row: net_sig, and m.network() -> sprite, caption, tooltip (built only when the sig changed).
--- The row's own network and mask; "×N" for a NETWORK_EACH combinator.
--- @param m table row model
--- @param row SnapshotInventory
local function network_model(m, row)
	local network_name = row.network_name
	local mask = row.mask
	-- An inventory that advertises on no mask: a NETWORK_EACH one has no networks then, the others no mask.
	local silent = network_name and (network_name == NETWORK_EACH and not row.networks
		or network_name ~= NETWORK_EACH and mask == nil)
	local reason = silent and rtext.silent_reason(row) or nil
	if not network_name then
		m.net_sig = ""
	elseif silent then
		m.net_sig = network_name .. "=?" .. reason .. (row.st.comb_ok and "+" or "-")
	elseif network_name == NETWORK_EACH then
		local nets = row.networks
		local names = {}
		if nets then
			for n in pairs(nets) do names[#names + 1] = n end
		end
		table.sort(names)
		local parts = {}
		for i, n in ipairs(names) do parts[i] = n .. "=" .. nets[n] end
		m.net_sig = NETWORK_EACH .. "|" .. table.concat(parts, ",")
		m.net_names = names
	else
		m.net_sig = network_name .. "=" .. mask
	end
	m.network = function()
		if not network_name then
			return "utility/close_black", "", { "cybersyn-gui.station-no-network" }
		elseif silent then
			local sprite = network_name == NETWORK_EACH and ("virtual-signal/" .. NETWORK_EACH)
				or util.network_sprite(network_name)
			return sprite or "utility/close_black", text.NO_VALUE, silent_text(row, reason)
		elseif network_name == NETWORK_EACH then
			local names, nets = m.net_names, row.networks
			local lines = { "" }
			for i, n in ipairs(names) do
				if i > 20 then break end
				lines[#lines + 1] = (i > 1 and "\n" or "") .. rich_text.network_icon(n) .. " " .. nets[n]
			end
			return "virtual-signal/" .. NETWORK_EACH, { "cybersyn-gui.network-each-count", #names }, lines
		end
		local sprite = util.network_sprite(network_name)
		return sprite or "utility/close_black", tostring(mask), { "", rich_text.network_icon(network_name), " ",
			{ "cybersyn-gui.station-network-mask", mask, network_text(mask) } }
	end
end

--- The Priority cell of a row: its combinator's own priority. On the station combinator's row a "*" marks a control
--- combinator whose priority replaces the station's for the items it sets a threshold on.
--- @param m table row model
--- @param row SnapshotInventory
local function priority_model(m, row)
	local item_p, item_n
	if row.index == 0 then item_p, item_n = item_priority(row.st) end
	local caption = tostring(row.priority) .. (item_p and "*" or "")
	m.prio_caption = caption
	m.prio_small = false
	m.prio_sig = caption .. "|" .. (item_p and (item_p .. "/" .. item_n) or "")
	m.prio_tooltip = function()
		local tip = { "", { "cybersyn-gui.stations-priority-tooltip" } }
		if item_p then
			tip[#tip + 1] = { "", "\n", { "cybersyn-gui.stations-priority-item", tostring(item_p), tostring(item_n) } }
		end
		return tip
	end
end

-- The marker of an inventory row: a small combinator icon after the name, and the room it takes.
local MARKER_SIZE = 16
local MARKER_SPRITE = "cybersyn-combinator-muted"
local MARKER_W = MARKER_SIZE + 2

local SILENT_MARKER = {
	paused = "cybersyn-gui.stations-inventory-unread",
	off = "cybersyn-gui.stations-inventory-off",
	empty = "cybersyn-gui.stations-inventory-empty",
}

--- "network [A] mask 2", "networks [A]1 [B]2", or why it advertises on none ("not read", "off", "no input signals"):
--- a row's network as the marker tooltip words it.
--- @param row SnapshotInventory
--- @return LocalisedString
local function marker_network(row)
	if row.networks then return { "cybersyn-gui.stations-inventory-networks", rtext.row_network(row) } end
	local name = row.network_name
	if not name then return { "cybersyn-gui.station-no-network" } end
	if row.mask == nil or name == NETWORK_EACH then return { SILENT_MARKER[rtext.silent_reason(row)] } end
	return { "cybersyn-gui.stations-inventory-network", rich_text.network_icon(name), tostring(row.mask) }
end

--- The marker of an inventory row, nil on the station combinator's row.
--- @param row SnapshotInventory
--- @return {unit: uint, sig: string, tooltip: fun(): LocalisedString}?
local function marker_model(row)
	if row.index == 0 then return nil end
	return {
		unit = row.unit,
		sig = row.unit .. "|" .. rtext.row_sig(row) .. (row.failed and "|f" or "") .. "|" .. rtext.silent_reason(row),
		tooltip = function()
			local tip = { "", { "cybersyn-gui.stations-inventory-marker", tostring(row.index), tostring(row.priority),
				marker_network(row) } }
			if row.failed then
				tip[#tip + 1] = { "", "\n[color=1,0.35,0.35]", { "cybersyn-gui.relative-i-red" }, "[/color]" }
			end
			tip[#tip + 1] = { "", "\n", { "cybersyn-gui.stations-inventory-click" } }
			return tip
		end,
	}
end

--- @param marker table marker_model
--- @return flib.GuiElemDef
local function marker_def(marker)
	return hover.hoverable({
		type = "sprite-button",
		style = "cybersyn_name_icon",
		style_mods = { size = MARKER_SIZE },
		sprite = MARKER_SPRITE,
		hovered_sprite = "item/" .. COMBINATOR_NAME,
		tooltip = marker.tooltip(),
		-- The combinator by unit number: links.handle_link_click's "entity" kind opens it.
		tags = { kind = "entity", id = marker.unit, marker = true },
		mouse_button_filter = { "left" },
		handler = { [defines.events.on_gui_click] = links.handle.link_click },
	}, SCROLL)
end

--- Adds, rewrites or removes the marker at the end of a name cell, after name_cell wrote the rest.
--- @param cell LuaGuiElement
--- @param marker table? marker_model
local function sync_marker(cell, marker)
	local elem
	for _, child in ipairs(cell.children) do
		if child.tags.marker then elem = child end
	end
	if not marker then
		if elem then elem.destroy() end
		return
	end
	if not elem then
		gui.add(cell, marker_def(marker))
		return
	end
	elem.tooltip = marker.tooltip()
	local tags = elem.tags
	if tags.id ~= marker.unit then
		tags.id = marker.unit
		elem.tags = tags
	end
end

--- Everything a row shows that is not a slot table, as plain values comparable between updates. Tooltips and the
--- network cell cost API calls, so they are built by functions that run only when their sig changed. The name,
--- status, deliveries and last dispatch are the station's on each of its rows; network, priority, slots and wait are
--- the row's own.
--- @param row SnapshotInventory
--- @param ctx table
local function row_model(row, ctx)
	local st = row.st
	local now = ctx.now
	local status = ctx.status[st.id]
	local m = {
		key = row.key,
		row = row,
		name = st.name,
		parts = st.name_parts,
		link = { kind = "station", id = st.id },
		status_sig = status,
		status_sprite = "flib_indicator_" .. STATUS_COLOR[status],
		status_caption = { status_key(status) },
	}
	if ctx.problems_view then
		m.problems = problems_view(ctx.lint.by_id[st.id], { sid = st.id }, ctx)
	end

	local marker = marker_model(row)
	m.marker = marker
	m.marker_sig = marker and marker.sig or ""
	local read_age = st.read_tick and now - st.read_tick or nil
	m.name_sig = st.name .. "\1" .. st.id .. "\1" .. (read_age and text.read_step(read_age) or "") .. "\1" .. m.marker_sig
	m.name_tooltip = function()
		local tip = { "", "[font=default-semibold]", st.name, "[/font]" }
		if marker then
			tip[#tip + 1] = "\n"
			tip[#tip + 1] = rtext.row_text(row)
		end
		if read_age then
			tip[#tip + 1] = "\n"
			tip[#tip + 1] = text.read_ago(read_age)
		end
		tip[#tip + 1] = "\n"
		tip[#tip + 1] = links.LINK_FOOTER
		return tip
	end

	local hashes = status == "starved" and starved_hashes(st, ctx.snapshot.starved) or nil
	local setup_checks, setup_mask
	if status == "setup" then setup_checks, setup_mask = pm.open_error_checks(st.id, st.lint, diag.is_acked) end
	local unserved = st.unserved and st.unserved.count or 0
	m.status_tip_sig = (hashes and (status .. "|" .. table.concat(hashes, ",", 1, math.min(#hashes, 10))) or status)
		.. "|" .. unserved .. (st.throttling and "|t" or "") .. (setup_mask and ("|s" .. setup_mask) or "")
	m.status_tooltip = function()
		local tooltip = { "", setup_checks and pm.setup_status_tooltip(setup_checks) or { status_key(status) .. "-tooltip" } }
		if hashes then
			local icons = {}
			for i = 1, math.min(#hashes, 10) do
				icons[i] = rich_text.of_hash(hashes[i])
			end
			tooltip[#tooltip + 1] = "\n" .. table.concat(icons, " ")
		end
		if unserved > 0 then
			tooltip[#tooltip + 1] = "\n"
			tooltip[#tooltip + 1] = { "cybersyn-gui.stations-unserved-line", tostring(unserved) }
		end
		if st.throttling then
			tooltip[#tooltip + 1] = "\n"
			tooltip[#tooltip + 1] = { "cybersyn-gui.stations-throttling-line" }
		end
		return tooltip
	end

	network_model(m, row)
	priority_model(m, row)

	local limit = finite_limit(st)
	m.dl_caption = { "", st.deliveries_total, "/", limit or { "cybersyn-gui.no-limit-short" } }
	m.dl_sig = st.deliveries_total .. "/" .. (limit or "")

	local start = row_wait_start(row)
	if start then
		m.wait_caption = logic.short_duration(now - start)
		m.wait_sig = m.wait_caption
	else
		m.wait_caption, m.wait_sig = NONE_CAPTION, ""
	end
	m.wait_full = start and logic.format_duration(now - start) or nil

	local age = collector.delivery_age(st)
	if age and never_dispatched(st) then
		m.last_caption, m.last_sig, m.last_never = NEVER_CAPTION, "never", true
	elseif age then
		m.last_caption = logic.short_duration(age)
		m.last_sig = m.last_caption
	else
		m.last_caption, m.last_sig = NONE_CAPTION, ""
	end
	m.last_full = age and logic.format_duration(age) or nil
	return m
end

local function wait_tooltip(m)
	if m.registry then return "" end
	return m.wait_full and { "cybersyn-gui.waiting-for", m.wait_full } or { "cybersyn-gui.stations-wait-none" }
end

local function last_tooltip(m)
	if m.last_never then return { "cybersyn-gui.stations-last-dispatch-never" } end
	if m.registry then return "" end
	return m.last_full and { "cybersyn-gui.time-ago", m.last_full } or { "cybersyn-gui.never" }
end

--- The 32 px rows' slots; the filtered item is highlighted rather than hidden.
--- @param item string?
--- @return SlotLook
local function slot_look(item)
	return { prefix = "cybersyn_slot_32_", selected_prefix = "cybersyn_selected_slot_32_", count = "cybersyn_slot_32_count",
		selected = item }
end

--- Slot buttons of the 32 px rows: clickable items with the standard item click semantics and hover-hold.
local function decorate_slots(defs)
	for _, def in pairs(defs) do
		local tags = def.tags
		local hash = tags and tags.kind == "item" and tags.id or nil
		if hash then
			def.enabled = true
			def.mouse_button_filter = { "left", "right" }
			-- The one item click of every view (links.handle_link_click -> links.item_button_click).
			def.handler = { [defines.events.on_gui_click] = links.handle.link_click }
			hover.hoverable(def, SCROLL)
			def.tooltip = { "", def.tooltip, "\n", { "cybersyn-gui.item-click-hint" } }
		elseif tags and tags.slot_key then
			-- A control signal: nothing to click, but a disabled button greys its icon out.
			def.enabled = true
			hover.hoverable(def, SCROLL)
		end
	end
	return defs
end

--- One line of slots: when the items do not fit, the last slot shows "+n" with the rest in its tooltip.
--- @param defs flib.GuiElemDef[]
--- @param capacity int
--- @return flib.GuiElemDef[]
local function fit_slots(defs, capacity)
	local shown, over = logic.fit_slots(#defs, capacity)
	if over == 0 then return defs end
	local out = {}
	for i = 1, shown do out[i] = defs[i] end
	local lines = {}
	for i = shown + 1, math.min(#defs, shown + 24) do
		local d = defs[i]
		lines[#lines + 1] = "[img=" .. d.sprite .. "] " .. tostring(d.children[1].caption)
	end
	out[shown + 1] = {
		type = "label",
		style = "cybersyn_overflow_label",
		style_mods = { width = SLOT, height = SLOT, vertical_align = "center" },
		caption = "+" .. over,
		tooltip = table.concat(lines, "\n"),
		tags = { overflow = true },
	}
	return out
end

local function slot_key(def)
	local tags = def.tags
	if tags and tags.slot_key then return tags.slot_key end
	if def.type == "label" then return "+" end
	return def.tags and def.tags.kind == "item" and def.tags.id or def.sprite
end

--- Flattens a LocalisedString so the slot sig follows exact amounts that the abbreviated caption hides.
local function flatten(ls, out)
	if type(ls) == "table" then
		for _, v in ipairs(ls) do flatten(v, out) end
	elseif ls ~= nil then
		out[#out + 1] = tostring(ls)
	end
	return out
end

local function update_slot(elem, entry)
	local def = entry.def
	if def.type == "label" then
		elem.caption = def.caption
		elem.tooltip = def.tooltip
		return
	end
	if elem.style.name ~= def.style then elem.style = def.style end
	elem.tooltip = def.tooltip
	local label = elem.children[1]
	if label then label.caption = def.children[1].caption end
end

--- Reconciles one slot table keyed by item, so counts update in place and hovered buttons are not recreated.
--- @param table_elem LuaGuiElement
--- @param defs flib.GuiElemDef[]
--- @param state table
--- @param hold boolean
--- @param minute integer re-signs tooltips once a minute so wait times in them do not go stale
local function sync_slots(table_elem, defs, state, hold, minute)
	local entries = {}
	for i, def in ipairs(defs) do
		local caption = def.type == "label" and def.caption or def.children[1].caption
		entries[i] = {
			key = slot_key(def),
			def = def,
			sig = tostring(def.style) .. "|" .. tostring(caption) .. "|" .. minute .. "|" .. table.concat(flatten(def.tooltip, {}), "\1"),
			build = function() return def end,
			update = update_slot,
		}
	end
	return sync.sync_children(table_elem, entries, state, hold)
end

-- A registry row (no station) has empty slot tables. Each row shows its own combinator's provides and requests; the
-- station's deliveries sit on its station combinator's row, as filters.row_passes counts them.
local SLOT_TABLES = {
	pr = function(row, item, w)
		if not row then return {} end
		local defs = util.slot_table_build_from_station({ provided = row.provided, requested = row.requested, wait = row.st.wait },
			slot_look(item))
		return fit_slots(decorate_slots(defs), w.pr_slots)
	end,
	dl = function(row, item, w)
		if not row or row.index ~= 0 then return {} end
		return fit_slots(decorate_slots(util.slot_table_build_from_deliveries(row.st, slot_look(item))), w.dl_slots)
	end,
	-- The station's own signals, on its station combinator's row as its deliveries are.
	ctl = function(row, item, w)
		if not (row and row.index == 0 and w.show_control) then return {} end
		return fit_slots(decorate_slots(util.slot_table_build_from_control_signals(row.st, slot_look(item))), w.ctl_slots)
	end,
}
local NO_SLOTS = { pr = "", dl = "", ctl = "" }

local function count_parts(parts, prefix, map)
	if not map then return end
	for k, v in pairs(map) do
		parts[#parts + 1] = prefix .. k .. "=" .. tostring(v)
	end
end

--- Signatures of what each slot table shows, from the row's data, so an unchanged table is not rebuilt as defs at
--- all. The minute is part of the provided/requested sig only when one of its requests shows a wait.
--- @param row SnapshotInventory
--- @param item string?
--- @param minute integer
--- @return {pr: string, dl: string}
local function slot_sigs(row, item, minute)
	local parts = {}
	count_parts(parts, "p", row.provided)
	local waits = false
	local wait = row.st.wait
	for hash, req in pairs(row.requested) do
		parts[#parts + 1] = "r" .. hash .. "=" .. req.count .. (req.active and "a" or "b")
		if req.active and wait[hash] then
			waits = true
			parts[#parts + 1] = tostring(wait[hash])
		end
	end
	parts[#parts + 1] = item or ""
	if waits then parts[#parts + 1] = tostring(minute) end
	local pr = table.concat(parts, "\1")
	if row.index ~= 0 then return { pr = pr, dl = "", ctl = "" } end
	local st = row.st
	parts = {}
	count_parts(parts, "", st.deliveries)
	parts[#parts + 1] = item or ""
	local dl = table.concat(parts, "\1")
	parts = {}
	count_parts(parts, "c", st.control)
	count_parts(parts, "k", st.control2)
	count_parts(parts, "t", st.thresholds)
	parts[#parts + 1] = item or ""
	return { pr = pr, dl = dl, ctl = table.concat(parts, "\1") }
end

local function slot_state(slots, name)
	return get_or_create(slots, name)
end

--- Element references of a row, found once and kept in the row's memo.
--- @param row LuaGuiElement
--- @param problems boolean the row was built for the Problems view
local function row_refs(row, problems)
	local c = row.children
	local status = c[2].children
	local net = c[3].children
	local dl = c[7].children
	local refs = {
		name = c[1],
		status_sprite = status[1],
		status_label = status[2],
		net = c[3],
		net_sprite = net[1],
		net_label = net[2],
		prio = c[4],
		dl_count = dl[1],
		dl = dl[2],
		wait = c[8],
		last = c[9],
		ctl = c[CONTROL_COLUMN].children[1],
	}
	if problems then
		local p = c[PROBLEMS_COLUMN]
		local pc = p.children
		refs.problems = { cell = p, dot = pc[1], chip = pc[2], detail = pc[3], more = pc[4], ack = pc[6] }
	else
		refs.pr = c[PROBLEMS_COLUMN].children[1]
	end
	return refs
end

--- @param cell table
--- @param row LuaGuiElement
--- @param problems boolean
local function cell_refs(cell, row, problems)
	local refs = cell.refs
	if not (refs and refs.name.valid and refs.last.valid and (refs.problems ~= nil) == problems) then
		refs = row_refs(row, problems)
		cell.refs = refs
	end
	return refs
end

--- @param r table refs.problems
--- @param p table? problems_view
--- @param cell table
local function update_problems(r, p, cell)
	local sig = p and p.sig or "0"
	if cell.problems_sig == sig then return end
	if p and p.write then p.write(r) else clear_problems(r) end
	cell.problems_sig = sig
end

--- @param row LuaGuiElement
--- @param inv SnapshotInventory? nil for a registry row
--- @param m table row model
--- @param cell table per-row render memo from the previous update (empty on first sight)
--- @param item string? item filter hash
--- @param hold boolean
--- @param minute integer
--- @param sigs {pr: string, dl: string}
--- @param w table column widths
local function update_row(row, inv, m, cell, item, hold, minute, sigs, w)
	local r = cell_refs(cell, row, w.problems_view)
	if cell.name_sig ~= m.name_sig then
		local width = w.name - (m.marker and MARKER_W or 0)
		if cell.marker_sig ~= m.marker_sig then
			-- The text button's width follows the marker: name_cell rebuilds the cell rather than rewriting tooltips.
			local tags = r.name.tags
			tags.s = ""
			r.name.tags = tags
		end
		name_cell.update(r.name, m.parts, m.name, m.link, width, m.name_tooltip(), SCROLL)
		sync_marker(r.name, m.marker)
		cell.name_sig = m.name_sig
		cell.marker_sig = m.marker_sig
	end

	if cell.status ~= m.status_sig then
		r.status_sprite.sprite = m.status_sprite
		r.status_label.caption = m.status_caption
		cell.status = m.status_sig
	end
	if cell.status_tip_sig ~= m.status_tip_sig then
		r.status_label.tooltip = m.status_tooltip()
		cell.status_tip_sig = m.status_tip_sig
	end

	if cell.net_sig ~= m.net_sig then
		local sprite, caption, tooltip = m.network()
		r.net_sprite.sprite = sprite
		r.net_label.caption = caption
		r.net.tooltip = tooltip
		cell.net_sig = m.net_sig
	end

	if cell.prio_sig ~= m.prio_sig then
		r.prio.caption = m.prio_caption or ""
		r.prio.tooltip = m.prio_tooltip and m.prio_tooltip() or ""
		cell.prio_sig = m.prio_sig
	end

	if cell.dl_sig ~= m.dl_sig then
		r.dl_count.caption = m.dl_caption
		r.dl_count.tooltip = m.registry and "" or { "cybersyn-gui.stations-deliveries-count-tooltip" }
		cell.dl_sig = m.dl_sig
	end
	if cell.wait_sig ~= m.wait_sig then
		r.wait.caption = m.wait_caption
		cell.wait_sig = m.wait_sig
	end
	if cell.last_sig ~= m.last_sig then
		r.last.caption = m.last_caption
		cell.last_sig = m.last_sig
	end
	local wait_tip, last_tip = m.wait_full or m.wait_sig, (m.last_full or m.last_sig)
	if cell.wait_tip ~= wait_tip then
		r.wait.tooltip = wait_tooltip(m)
		cell.wait_tip = wait_tip
	end
	if cell.last_tip ~= last_tip then
		r.last.tooltip = last_tooltip(m)
		cell.last_tip = last_tip
	end
	if r.problems then update_problems(r.problems, m.problems, cell) end

	local slots = cell.slots or {}
	cell.slots = slots
	local sig_of = cell.slot_sigs or {}
	cell.slot_sigs = sig_of
	for name, build in pairs(SLOT_TABLES) do
		local table_elem = r[name]
		local sig = sigs[name]
		if table_elem and sig_of[name] ~= sig then
			local result = sync_slots(table_elem, build(inv, item, w), slot_state(slots, name), hold, minute)
			-- A hold deferred a structural change (hover.hoverable), so the table is retried next update.
			sig_of[name] = result ~= "held" and sig or nil
		end
	end
end

--- The Problems column's cell: written by update_problems, so a new row starts empty.
--- @param w table
--- @return flib.GuiElemDef
local function problems_cell_def(w)
	return {
		type = "flow",
		style = "cybersyn_cell_flow",
		style_mods = { width = w.problems, horizontal_spacing = 6 },
		{ type = "sprite", style = "cybersyn_lint_dot", sprite = "flib_indicator_white", visible = false, ignored_by_interaction = true },
		-- A chip that shows the check, not a button: no hover glow, the cell carries the tooltip.
		{ type = "button", style = "cybersyn_chip_grey", caption = "", visible = false, ignored_by_interaction = true,
			style_mods = { horizontally_squashable = false } },
		{ type = "label", style = "cybersyn_lint_detail", caption = "", ignored_by_interaction = true },
		{ type = "label", style = "cybersyn_overflow_label", caption = "", visible = false, ignored_by_interaction = true },
		{ type = "empty-widget", style = "flib_horizontal_pusher", ignored_by_interaction = true },
		{
			type = "sprite-button",
			style = "cybersyn_unserved_ack",
			sprite = "utility/check_mark",
			visible = false,
			tags = {},
			handler = { [defines.events.on_gui_click] = stations_tab.handle.on_lint_ack_click },
		},
	}
end

--- @param inv SnapshotInventory? nil for a registry row
--- @param m table row model
--- @param color "light"|"dark"
--- @param item string?
--- @param w table column widths
local function row_def(inv, m, color, item, w)
	local defs = { pr = w.problems_view and {} or SLOT_TABLES.pr(inv, item, w), dl = SLOT_TABLES.dl(inv, item, w),
		ctl = SLOT_TABLES.ctl(inv, item, w) }
	local net_sprite, net_caption, net_tooltip = m.network()
	local name = name_cell.def(m.parts, m.name, m.link, w.name - (m.marker and MARKER_W or 0), m.name_tooltip(), SCROLL)
	if m.marker then
		name.style_mods.width = w.name
		name[#name + 1] = marker_def(m.marker)
	end
	local fourth
	if w.problems_view then
		fourth = problems_cell_def(w)
	else
		fourth = {
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.provided_requested },
			{ type = "table", style = "slot_table", column_count = w.pr_slots, children = defs.pr },
		}
	end
	return hover.hoverable({
		type = "frame",
		style = "cybersyn_station_row_" .. color,
		direction = "horizontal",
		tags = { station_id = inv and inv.st.id or nil, unit = inv and inv.unit or nil, registry = m.registry and m.key or nil },
		name,
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.station_status },
			{ type = "sprite", style = "flib_indicator", sprite = m.status_sprite },
			{ type = "label", style = "cybersyn_cell_label", caption = m.status_caption, tooltip = m.status_tooltip() },
		},
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.network },
			tooltip = net_tooltip,
			{ type = "sprite", sprite = net_sprite, resize_to_sprite = false, style_mods = { size = 24 }, ignored_by_interaction = true },
			{ type = "label", caption = net_caption, ignored_by_interaction = true },
		},
		{ type = "label", style = "cybersyn_cell_value", caption = m.prio_caption or "", tooltip = m.prio_tooltip and m.prio_tooltip() or "",
			style_mods = { width = w.priority } },
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.control, left_padding = CONTROL_GAP },
			visible = w.show_control,
			{ type = "table", style = "slot_table", column_count = math.max(1, w.ctl_slots), children = defs.ctl },
		},
		fourth,
		{
			type = "flow",
			style = "cybersyn_cell_flow",
			style_mods = { width = w.deliveries },
			{
				type = "label",
				style = "cybersyn_cell_value",
				style_mods = { width = w.dl_count },
				caption = m.dl_caption,
				tooltip = m.registry and "" or { "cybersyn-gui.stations-deliveries-count-tooltip" },
			},
			{ type = "table", style = "slot_table", column_count = w.dl_slots, children = defs.dl },
		},
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = w.wait }, caption = m.wait_caption,
			tooltip = wait_tooltip(m), visible = not w.hide_wait },
		{ type = "label", style = "cybersyn_cell_value", style_mods = { width = w.last_delivery }, caption = m.last_caption, tooltip = last_tooltip(m) },
	}, SCROLL), defs
end

-- ---------------------------------------------------------------- chips

--- @param key string
--- @return string
local function chip_icon(key)
	if STATUS_COLOR[key] then return "flib_indicator_" .. STATUS_COLOR[key] end
	return util.valid_sprite(CHIP_ICON[key], "utility/warning_icon")
end

--- @param key string
--- @param count integer? nil while the first pass after opening (or the first lint pass) runs
--- @return LocalisedString
function stations_tab.chip_caption(key, count)
	local number = count and format.number(count) or "–"
	if key == "all" then
		return { "", { "cybersyn-gui.station-status-all" }, "  ", number }
	end
	local name = STATUS_COLOR[key] and { status_key(key) } or { "cybersyn-gui.stations-chip-" .. key }
	return { "", "[img=" .. chip_icon(key) .. "] ", name, "  ", number }
end

--- @param key string
--- @param pending int? the first lint pass's progress while it runs
--- @return LocalisedString?
local function chip_tooltip(key, pending)
	if key == "all" then return nil end
	if STATUS_COLOR[key] then return { "", "[font=default-semibold]", { status_key(key) }, "[/font]\n", { status_key(key) .. "-tooltip" } } end
	local tip = { "", "[font=default-semibold]", { "cybersyn-gui.stations-chip-" .. key }, "[/font]\n", { "cybersyn-gui.stations-chip-" .. key .. "-tooltip" } }
	if key == "problems" and pending then
		tip[#tip + 1] = "\n"
		tip[#tip + 1] = { "cybersyn-gui.problems-pending-progress", tostring(pending) }
	end
	return tip
end

--- The chip flow at the right end of a tab's subheader (templates.tab_header), added on first use.
--- @param player_data PlayerData
--- @param tab string
--- @param name string the flow's element name, also its key in refs
--- @return LuaGuiElement? flow
--- @return boolean created true on the call that added it
function stations_tab.chip_flow(player_data, tab, name)
	local refs = player_data.refs
	local flow = refs[name]
	if flow and flow.valid then return flow, false end
	local subheader = refs[tab .. "_subheader"]
	if not (subheader and subheader.valid) then return nil, false end
	local _, elem = gui.add(subheader, {
		type = "flow",
		name = name,
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4 },
	})
	refs[name] = elem
	return elem, true
end

--- Width left for the chips in the subheader after the search field, the item chip and the collecting note.
--- @param player_data PlayerData
--- @param tab string
--- @return int
function stations_tab.chip_space(player_data, tab)
	local refs = player_data.refs
	local layout = player_data.layout
	local space = (layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)) - 24
	local function shown(name)
		local e = refs[tab .. name]
		return e and e.valid and e.visible
	end
	-- The item chip and the collecting note size to localised text: their figures are English estimates.
	if shown("_search_field") then space = space - metrics.SEARCH_FIELD_WIDTH - metrics.SUBHEADER_SPACING end
	if shown("_chip_flow") then space = space - 260 end
	if shown("_train_chip_flow") then space = space - 140 end
	if shown("_collecting") then space = space - 160 end
	-- The Stations tab's Control signals toggle (the Trains tab subtracts its own group toggle).
	if tab == TAB then space = space - 32 end
	return space
end

--- The chip button's maximal_width: a caption wider than the layout reserved is clipped instead of pushing the line
--- past the subheader.
--- @param key string
--- @param count int?
--- @return int
function stations_tab.chip_max_width(key, count)
	return CHIP_WIDTH[key] + DIGIT_WIDTH * (#format.number(count or 0) - 1)
end

--- @param key string
--- @param count int?
--- @return int
local function chip_width(key, count)
	return stations_tab.chip_max_width(key, count) + 4
end

--- Which chips show, and on which line (tab-logic chip_lines).
--- @param counts {[string]: int}
--- @param selected string the toggled chip or "all"
--- @param space1 int px left in the subheader
--- @param space2 int px of the second line
--- @param always {[string]: true}? chips shown although their count is unknown or zero
--- @return string[] line1
--- @return string[] line2
function stations_tab.chip_lines(counts, selected, space1, space2, always)
	local chips = {}
	for i, key in ipairs(CHIP_ORDER) do
		local count = counts[key]
		chips[i] = { key = key, width = chip_width(key, count), count = count,
			keep = key == "all" or key == selected or (always ~= nil and always[key] == true) }
	end
	return logic.chip_lines(chips, selected, space1, space2)
end

--- @param flow LuaGuiElement
--- @param keys string[]
--- @param counts {[string]: int}
--- @param wanted string
--- @param state table
--- @param pending int?
local function sync_chip_line(flow, keys, counts, wanted, state, pending)
	local entries = {}
	for i, key in ipairs(keys) do
		local count = counts[key]
		local waiting = key == "problems" and pending or nil
		if waiting then count = nil end
		local selected = wanted == key
		local enabled = selected or (count ~= nil and count > 0)
		entries[i] = {
			key = key,
			sig = tostring(count) .. (selected and "+" or "-") .. tostring(waiting),
			build = function()
				return {
					type = "button",
					style = "cybersyn_filter_chip",
					style_mods = { maximal_width = stations_tab.chip_max_width(key, count) },
					caption = stations_tab.chip_caption(key, count),
					tooltip = chip_tooltip(key, waiting),
					toggled = selected,
					enabled = enabled,
					tags = { station_chip = key },
					handler = { [defines.events.on_gui_click] = stations_tab.handle.on_status_chip_click },
				}
			end,
			update = function(elem)
				elem.caption = stations_tab.chip_caption(key, count)
				elem.style.maximal_width = stations_tab.chip_max_width(key, count)
				elem.tooltip = chip_tooltip(key, waiting)
				elem.toggled = selected
				elem.enabled = enabled
			end,
		}
	end
	sync.sync_children(flow, entries, state, false)
end

--- Chips: counts over the filtered set, click to show only that set, click again for all.
--- @return boolean wrapped the second line shows (the page has one row less)
local function render_chips(player_data, counts)
	local flow, created = stations_tab.chip_flow(player_data, TAB, CHIPS)
	if not flow then return false end
	local refs = player_data.refs
	if created then
		local _, toggle = gui.add(refs[TAB .. "_subheader"], {
			type = "sprite-button",
			name = CONTROL_TOGGLE,
			style = "tool_button",
			sprite = "item/cybersyn-combinator",
			tooltip = { "", "[font=default-bold]", { "cybersyn-gui.stations-control" }, "[/font]\n",
				{ "cybersyn-gui.stations-control-toggle-tooltip" } },
			handler = { [defines.events.on_gui_click] = stations_tab.handle.on_control_toggle },
		})
		refs[CONTROL_TOGGLE] = toggle
	end
	local toggle = refs[CONTROL_TOGGLE]
	local shown = stations_tab.control_shown(player_data)
	if toggle and toggle.valid and toggle.toggled ~= shown then toggle.toggled = shown end
	local wanted = active_chip(player_data) or "all"
	local pending = lint_pending()
	local layout = player_data.layout
	local cw = layout and layout.content_width or (sizing.MAX_WIDTH - sizing.OUTER_WIDTH)
	local line1, line2 = stations_tab.chip_lines(counts, wanted, stations_tab.chip_space(player_data, TAB), cw - 24,
		pending and { problems = true } or nil)
	sync_chip_line(flow, line1, counts, wanted, sync.gui_state(player_data, CHIPS), pending)
	local row, flow2 = refs[CHIP_ROW], refs[CHIPS2]
	if not (row and row.valid and flow2 and flow2.valid) then return false end
	local wrapped = #line2 > 0
	if row.visible ~= wrapped then row.visible = wrapped end
	sync_chip_line(flow2, line2, counts, wanted, sync.gui_state(player_data, CHIPS2), pending)
	return wrapped
end

-- ---------------------------------------------------------------- render

--- Writes the column widths, the fourth column's caption and the Wait column's visibility into the header, and the sort
--- state into its checkboxes, when either changed.
--- @param player_data PlayerData
--- @param w table
--- @return boolean widths_changed
local function sync_header(player_data, w, column, ascending)
	local header = player_data.refs[HEADER]
	if not (header and header.valid) then return false end
	local state = sync.gui_state(player_data, HEADER)
	-- A rebuilt window has a new header built with the default widths.
	if state.index ~= header.index then
		state.cw, state.sort, state.index = nil, nil, header.index
	end
	local changed = state.cw ~= w.sig
	if changed then
		local columns = w.problems_view and PROBLEM_COLUMNS or COLUMNS
		local cells = header.children
		for i, cell in ipairs(cells) do
			cell.style.width = w[columns[i]]
			cell.visible = not (i == WAIT_COLUMN and w.hide_wait or i == CONTROL_COLUMN and not w.show_control)
		end
		local box = cells[PROBLEMS_COLUMN].children[1]
		local tags = box.tags
		if tags.column ~= columns[PROBLEMS_COLUMN] then
			box.caption, box.tooltip = header_texts(columns[PROBLEMS_COLUMN])
			tags.column = columns[PROBLEMS_COLUMN]
			box.tags = tags
		end
		state.cw = w.sig
	end
	local sig = column .. (ascending and "+" or "-")
	if changed or state.sort ~= sig then
		for _, cell in ipairs(header.children) do listing.sync_sort_header(cell, column, ascending) end
		state.sort = sig
	end
	return changed
end

--- The rows of the view: the stations' inventory rows, then (in the Problems view) the registry's findings.
--- @param player_data PlayerData
--- @param rows SnapshotInventory[]
--- @param ctx table
--- @return {e: ProblemEntry, entity: LuaEntity?, name: string}[]
local function view_registry(player_data, rows, ctx)
	ctx.problems_view = active_chip(player_data) == "problems"
	if not ctx.problems_view or ctx.pending then return {} end
	local cache = player_data.cache.stations
	if not cache then return {} end
	ctx.lint = problem_index(cache)
	-- The Misconfigured jump's scope counts stations only.
	if player_data.filters.problems_scope == "errors" then return {} end
	return registry_rows(ctx.lint, filters.get(player_data, TAB))
end

--- @param map_data MapData
--- @param player_data PlayerData
function stations_tab.build(map_data, player_data)
	local refs = player_data.refs
	local list = refs[SCROLL]
	if not (list and list.valid) then return end

	local rows, counts, ctx, column, ascending = stations_tab.query(player_data)
	local registry = view_registry(player_data, rows, ctx)
	local problems = ctx.problems_view
	local state = sync.gui_state(player_data, SCROLL)
	local wrapped = render_chips(player_data, counts)
	local size = math.max(1, listing.page_size(player_data, TAB) - (wrapped and 1 or 0))
	local n_rows = #rows
	local first, last = listing.paginate(player_data, TAB, n_rows + #registry, size)
	-- A column the page leaves empty gives its width to the name, unless it carries the sort.
	local hide_wait = not ctx.pending and column ~= "wait"
	for i = first, math.min(last, n_rows) do
		if row_wait_start(rows[i]) then
			hide_wait = false
			break
		end
	end
	local w = widths_for(player_data, problems, hide_wait)
	if sync_header(player_data, w, column, ascending) or state.cw ~= w.sig then
		-- Rows built for other widths are rebuilt rather than resized cell by cell.
		state.keys = nil
		state.cells = nil
		state.cw = w.sig
	end
	state.widths = w
	local summary = refs.manager_stations_summary
	if ctx.pending then
		-- Rows from before the window was closed stay hidden rather than destroyed: most of them are reused, not
		-- built again, once the first pass completes.
		list.visible = false
		-- With a snapshot in hand this is a first build split over the next ticks: a blank list for those few ticks,
		-- not the "Collecting" text, which would flash on every navigation.
		local deferred = ctx.snapshot.tick ~= nil
		if deferred then collector.owe_render() end
		local warning = refs.manager_stations_warning_flow
		if warning and warning.valid then
			-- Shown even when blank: the flow stretches, which keeps the pager at the bottom of the pane.
			warning.visible = true
			refs.manager_stations_warning_label.caption = deferred and "" or { "cybersyn-gui.stations-collecting" }
		end
		if summary and summary.valid then
			summary.caption = ""
			state.summary = nil
		end
		return
	end

	local item = player_data.filters.item
	local minute = math.floor(ctx.now / 3600)
	-- A hold must only defer data-driven reshuffles; a filter, sort, chip or page change the user just made (often
	-- by clicking inside a hovered row) has to apply at once.
	local view = view_sig(filters.get(player_data, TAB), column, ascending) .. "\1"
		.. (active_chip(player_data) or "") .. "\1" .. tostring(player_data.page and player_data.page[TAB])
	local hold = state.view == view and hover.hold_active(player_data, SCROLL)
	state.view = view
	local old_cells = state.cells or {}
	local cells = {}
	local entries = {}
	for i = first, last do
		local inv = i <= n_rows and rows[i] or nil
		local index = i - first + 1
		local m = inv and row_model(inv, ctx) or registry_model(registry[i - n_rows], ctx)
		local key = m.key
		local color = index % 2 == 0 and "dark" or "light"
		entries[index] = {
			key = key,
			build = function()
				local def, defs = row_def(inv, m, color, item, w)
				local slots = {}
				for name, list_defs in pairs(defs) do
					local keys = {}
					for k, d in ipairs(list_defs) do keys[k] = slot_key(d) end
					slots[name] = { keys = keys }
				end
				cells[key] = {
					slots = slots, slot_sigs = inv and slot_sigs(inv, item, minute) or NO_SLOTS, name_sig = m.name_sig,
					marker_sig = m.marker_sig,
					status = m.status_sig, color = color, status_tip_sig = m.status_tip_sig, net_sig = m.net_sig,
					dl_sig = m.dl_sig, wait_sig = m.wait_sig, last_sig = m.last_sig, wait_tip = m.wait_full or m.wait_sig,
					last_tip = m.last_full or m.last_sig,
				}
				return def
			end,
			built = function(elem)
				local cell = cells[key]
				if cell then
					cell.refs = row_refs(elem, w.problems_view)
					if cell.refs.problems then update_problems(cell.refs.problems, m.problems, cell) end
				end
			end,
			-- A row that left the page becomes this one: its slot tables keep their buttons where the items match.
			reuse = function(elem, old_key)
				local old = old_cells[old_key]
				old_cells[key] = { slots = old and old.slots, color = old and old.color, refs = old and old.refs }
				local tags = elem.tags
				tags.station_id = inv and inv.st.id or nil
				tags.unit = inv and inv.unit or nil
				tags.registry = m.registry and key or nil
				elem.tags = tags
			end,
			update = function(elem)
				local cell = old_cells[key] or {}
				if cell.color ~= color then
					elem.style = "cybersyn_station_row_" .. color
					cell.color = color
				end
				update_row(elem, inv, m, cell, item, hold, minute, inv and slot_sigs(inv, item, minute) or NO_SLOTS, w)
				cells[key] = cell
			end,
		}
	end
	-- The window's first render after a reopen rewrites every row (the memo went with the close): half of them now,
	-- the rest on the next update, so neither carries the whole page on a large base.
	if not state.cells and #entries > FIRST_UPDATE_ROWS then
		for i = FIRST_UPDATE_ROWS + 1, #entries do entries[i].update = nil end
	end
	local result = sync.sync_children(list, entries, state, hold, true)
	if result == "held" then
		-- Rows that left the page keep their memo until the hold ends and they are rebuilt.
		for id, cell in pairs(old_cells) do
			if not cells[id] then cells[id] = cell end
		end
	end
	state.cells = cells
	state.result = result

	if summary and summary.valid then
		local open, acked
		if problems then open, acked = open_error_counts(player_data.cache.stations) end
		local n_stations = ctx.stations or n_rows
		local sig = counts.all .. "|" .. n_rows .. "|" .. n_stations .. "|" .. #registry .. "|" .. summary.index .. "|"
			.. tostring(open) .. "|" .. tostring(acked)
		if state.summary ~= sig then
			local caption
			if #registry > 0 then
				caption = { "cybersyn-gui.stations-summary-registry", format.number(n_stations), format.number(counts.all),
					format.number(#registry), tostring(#registry) }
			else
				caption = { "cybersyn-gui.stations-summary", format.number(n_stations), format.number(counts.all) }
			end
			-- The counts are stations; a station with inventories lists a row per combinator.
			if n_rows ~= n_stations then
				caption = { "", caption, " · ", { "cybersyn-gui.stations-summary-rows", format.number(n_rows), tostring(n_rows) } }
			end
			-- The Overview's Misconfigured number, under the same filters: the stations this view lists first.
			if open then
				caption = { "", caption, " · ", acked > 0
					and { "cybersyn-gui.stations-open-errors-acked", format.number(open), format.number(acked) }
					or { "cybersyn-gui.stations-open-errors", format.number(open) } }
				summary.tooltip = { "cybersyn-gui.stations-open-errors-tooltip" }
			else
				summary.tooltip = ""
			end
			summary.caption = caption
			state.summary = sig
			state.open_errors = open and { open, acked } or nil
		end
	end

	local empty = n_rows + #registry == 0
	list.visible = not empty
	local warning = refs.manager_stations_warning_flow
	if warning and warning.valid then
		warning.visible = empty
		if empty then
			local caption
			local pending = problems and lint_pending()
			local filtered = filters.filters_active(filters.get(player_data, TAB))
			if pending then
				caption = { "cybersyn-gui.problems-pending-progress", tostring(pending) }
			elseif problems then
				caption = { filtered and "cybersyn-gui.stations-problems-none-filtered" or "cybersyn-gui.stations-problems-none" }
			elseif counts.all > 0 or filtered then
				caption = { "cybersyn-gui.stations-no-match" }
			else
				caption = { "cybersyn-gui.no-stations" }
			end
			refs.manager_stations_warning_label.caption = caption
		end
	end
end

-- Exposed for the unit tests, which render the cells and strips of fixture rows (collector.inventories).
function stations_tab.network_cell(row)
	local m = {}
	network_model(m, row)
	local sprite, caption, tooltip = m.network()
	return { sig = m.net_sig, sprite = sprite, caption = caption, tooltip = tooltip }
end

function stations_tab.priority_cell(row)
	local m = {}
	priority_model(m, row)
	return { sig = m.prio_sig, caption = m.prio_caption, tooltip = m.prio_tooltip() }
end

--- The marker an inventory row's name carries: its sig, unit and tooltip; nil on the station combinator's row.
function stations_tab.marker(row)
	local marker = marker_model(row)
	if not marker then return nil end
	return { sig = marker.sig, unit = marker.unit, tooltip = marker.tooltip(), def = marker_def(marker) }
end

stations_tab.column_widths = column_widths

function stations_tab.pr_slots(row, item, capacity)
	return SLOT_TABLES.pr(row, item, { pr_slots = capacity })
end

function stations_tab.dl_slots(row, item, capacity)
	return SLOT_TABLES.dl(row, item, { dl_slots = capacity })
end
stations_tab.row_wait_start = row_wait_start
stations_tab.slot_key = slot_key
stations_tab.slot_sigs = slot_sigs
stations_tab.sort_keys = sort_keys

stations_tab.handle = {}

stations_tab.wrapper = util.wrapper

--- @param e EventData.on_gui_click
function stations_tab.handle.on_status_chip_click(player, player_data, refs, e)
	stations_tab.set_chip(player_data, e.element.tags.station_chip)
	nav.rerender(player, player_data)
end

--- Acknowledge a row's findings: click = 24 h, shift = 1 h, control = until they clear; a click on a row whose
--- findings are all acknowledged ends them. Display state only, so any player may acknowledge.
--- @param e EventData.on_gui_click
function stations_tab.handle.on_lint_ack_click(player, player_data, refs, e)
	local tags = e.element.tags
	local targets = {}
	if tags.sid then
		local cache = player_data.cache.stations
		local px = cache and problem_index(cache)
		local seen = {}
		for _, en in ipairs(px and px.by_id[tags.sid] or {}) do
			local key = lint.subject_key(en.f.subject, en.f.id)
			local id = key .. ":" .. en.f.check
			if not seen[id] then
				seen[id] = true
				targets[#targets + 1] = { key, en.f.check, en.ack ~= nil }
			end
		end
	elseif tags.rk and tags.ck then
		targets[1] = { tags.rk, tags.ck, diag.is_acked("lint", tags.rk, tags.ck) ~= nil }
	end
	if #targets == 0 then return end
	local open = false
	for _, t in ipairs(targets) do
		if not t[3] then open = true end
	end
	if open then
		local until_tick = util.ack_until_tick(e)
		for _, t in ipairs(targets) do
			if not t[3] then diag.ack("lint", t[1], t[2], player.index, until_tick) end
		end
	else
		for _, t in ipairs(targets) do diag.unack("lint", t[1], t[2], player.index) end
	end
	-- The click is the change the player asked for: the row updates now, not once the cursor leaves.
	hover.release_hold(player_data)
	nav.rerender(player, player_data)
end

--- Toggles a chip: a status, "unserved", "problems", "stuck", "failing"; "all" or the active chip again clears it.
--- @param player_data PlayerData
--- @param chip string?
function stations_tab.set_chip(player_data, chip)
	if chip == "all" or chip == active_chip(player_data) then chip = nil end
	player_data.filters.problems_scope = nil
	if chip and not (STATUS_RANK[chip] or FLAG_CHIPS[chip] or chip == "stuck") then chip = nil end
	player_data.filters.stations_chip = chip
	listing.reset_page(player_data, TAB)
end

--- @param e EventData.on_gui_click
function stations_tab.handle.on_control_toggle(player, player_data, refs, e)
	player_data.tabs.stations_tab.control = not stations_tab.control_shown(player_data)
	hover.release_hold(player_data)
	nav.rerender(player, player_data)
end

gui.add_handlers(stations_tab.handle, stations_tab.wrapper)

return stations_tab
