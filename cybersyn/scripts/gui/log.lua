-- Log tab: the diagnostics rings as a list of events, newest first, in 28 px rows in a
-- scroll pane that holds the newest model.PAGE matching rows (the one tab that scrolls). The rows, counts,
-- badge and Summary come from scripts/gui/log-model.lua; this file turns them into elements and handles the
-- subheader. Visible only while diagnostics are on (storage.diag exists).
--
-- Follow holds while the pointer is over the rows or the window is paused; Pause / Newest stops and resumes it. Factorio
-- has no GUI wheel event, and a custom input on the wheel does not fire over a scroll pane (the pane takes the wheel), so
-- the wheel cannot pause Follow. Factorio does not tell a mod where a scroll pane is scrolled either, so only the
-- first rows_by_tab.log rows (the viewport while the pane is at the top) get their age every update; the rows below
-- are written when their event moves and their ages one viewport's worth per update in turn, so a row scrolled to is
-- at most PAGE / rows updates stale.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local logic = require("scripts.gui.tab-logic")
local sync = require("scripts.gui.utils.sync")
local hover = require("scripts.gui.utils.hover")
local links = require("scripts.gui.utils.links")
local nav = require("scripts.gui.utils.nav")
local filters = require("scripts.gui.utils.filters")
local metrics = require("scripts.gui.metrics")
local collector = require("scripts.gui.collector")
local diag = require("scripts.diag")
local model = require("scripts.gui.log-model")
local name_cell = require("scripts.gui.name-cell")
local text = require("scripts.gui.unserved-text")

local log_tab = {}

local TAB = "log_tab"
local ROWS = "log_rows"
local ROW_HEIGHT = 28
local PAGE = model.PAGE
-- The scroll pane always shows its vertical bar, so the rows' width does not change with their number.
local SCROLLBAR = metrics.SCROLLBAR
-- The pointer resting on the rows holds Follow this long without a new hover event (a lost leave event cannot hold it
-- for ever). Longer than hover.HOVER_HOLD_TICKS: hover fires only on entering a row, and a reader rests on one row
-- while reading it.
local HOLD_TICKS = 3600
-- Rows built in the first update of an empty page (that one update may take up to 6 ms; a row costs about
-- 50-70 µs to build and write), then per update until the page is full, inside the Log's 1 ms. The prewarm builds
-- the pool while another tab shows, so the first look at the Log seldom builds anything.
local FIRST_FILL = 80
local FILL_ROWS = 8
-- Rows below the viewport a rewrite writes per update (at 16 a catch-up update measured 1.01-1.10 ms on a
-- 2,000-station base).
local DEFER_ROWS = 12
-- Ages move on a 2 s timer. While Follow is held the whole page's ages are written together once per AGE_TICKS and
-- not in between: a reader scrolled anywhere sees ages in order (a slice spread over updates would leave rows a
-- second apart, the older above the newer). Under Follow the reader is at the top: the viewport every update, and
-- below it a slice that would pass the page once per AGE_TICKS, capped at a viewport per update (the Follow path's
-- 1 ms).
local AGE_TICKS = 120
-- A lint pass's own rows are indented under its row by this many px (the row's left padding; the message cell gives
-- the room back, so the row keeps its width and its height).
local CHILD_INDENT = 20
local ROW_LEFT_PADDING = metrics.LOG_ROW_LEFT_PADDING
-- Logical px at the 1,392 px content width of a 1,440 px window; the message takes the rest.
local W = { age = 60, dot = 16, kind = 20, train = 56, station = 300, item = 28, count = 44, print = 28 }
local BASE_CONTENT_WIDTH = 1392
local CELLS = 9
local SPACING = metrics.LOG_SPACING
local ROW_PADDING = metrics.LOG_ROW_LEFT_PADDING + metrics.LOG_ROW_RIGHT_PADDING
local FRAME_BORDER = metrics.FRAME_BORDER
-- Ring rows examined per update by the rows, the Summary and the counts together, in that order (about 1 µs a row on a
-- 2,030-station base with a full ring of 16,384 rows): what the rows leave goes to the Summary, then to the counts.
local SCAN_BUDGET = 640
-- The badge scans on every tab's render, so it gets a budget of its own.
local BADGE_BUDGET = 1024
-- Subheader controls on the right of a fixed width (logical px), and the spacing of the subheader flow; the item chip
-- takes what is left of the content width. 40 estimates the English "Train" caption, 28 is each icon button.
local SEV_BUTTON_WIDTH = 84
local FOLLOW_WIDTH = 84
local SUBHEADER_FIXED = 3 * SEV_BUTTON_WIDTH + metrics.LOG_KIND_DROPDOWN_WIDTH + 40 + metrics.LOG_TRAIN_FIELD_WIDTH
	+ metrics.LOG_WINDOW_DROPDOWN_WIDTH + FOLLOW_WIDTH + 2 * 28 + 9 * metrics.SUBHEADER_SPACING
local SUBHEADER_PADDING = 2 * metrics.SUBHEADER_PADDING
local CHIP_MAX = 240
local SEV_SPRITES = { "flib_indicator_red", "flib_indicator_orange", "flib_indicator_white" }
local SUMMARY_SPRITE = "utility/list_view"
local SEV_KEYS = { "error", "warning", "info" }

-- Kind sprites, checked against the loaded prototypes once (a pure function of them, so the same in every Lua state).
local KIND_SPRITE_CANDIDATES = {
	[DIAG_KIND_UNSERVED_REASON] = { "utility/clock" },
	[DIAG_KIND_SERVED] = { "utility/check_mark_green", "utility/check_mark" },
	[DIAG_KIND_FLAPPING] = { "utility/refresh" },
	[DIAG_KIND_DISPATCH_FAILED] = { "utility/danger_icon" },
	[DIAG_KIND_DELIVERY_FAILED] = { "utility/danger_icon" },
	[DIAG_KIND_ALERT] = { "utility/warning_icon" },
	[DIAG_KIND_STATION_POWER] = { "utility/electricity_icon", "item/substation" },
	[DIAG_KIND_STATION_LIMIT] = { "item/train-stop" },
	[DIAG_KIND_STATION_WARMUP_DONE] = { "item/train-stop" },
	[DIAG_KIND_STATION_DISABLED] = { "item/train-stop" },
	[DIAG_KIND_SHORT_LOAD] = { "item/cargo-wagon" },
	[DIAG_KIND_UNEXPECTED_CARGO] = { "item/cargo-wagon" },
	[DIAG_KIND_RESIDUAL_CARGO] = { "item/cargo-wagon" },
	[DIAG_KIND_SCHEDULE_EDITED] = { "utility/rename_icon", "item/locomotive" },
	[DIAG_KIND_LINT] = { "item/cybersyn-combinator", "item/decider-combinator" },
	[DIAG_KIND_ACKNOWLEDGED] = { "utility/check_mark_white", "utility/check_mark" },
	[DIAG_KIND_UNACKNOWLEDGED] = { "utility/check_mark_white", "utility/check_mark" },
	[DIAG_KIND_MANUAL_ACTION] = { "utility/hand", "utility/rename_icon" },
	[DIAG_KIND_DISPATCHED] = { "item/locomotive" },
	[DIAG_KIND_ARRIVE_P] = { "item/locomotive" },
	[DIAG_KIND_LEAVE_P] = { "item/locomotive" },
	[DIAG_KIND_ARRIVE_R] = { "item/locomotive" },
	[DIAG_KIND_LEAVE_R] = { "item/locomotive" },
	[DIAG_KIND_RETURNED] = { "item/locomotive" },
	[DIAG_KIND_TRAIN_STATE] = { "item/locomotive" },
	[DIAG_KIND_SLOW_DELIVERY] = { "item/locomotive" },
}
-- A failed dispatch takes its icon from its severity: the self-healing no_path / path_blocked rows are info and wear
-- the other train rows' locomotive, not the danger triangle, so they do not read as errors.
local DISPATCH_SEV_CANDIDATES = {
	[DIAG_SEV_ERROR] = { "utility/danger_icon" },
	[DIAG_SEV_WARNING] = { "utility/warning_icon" },
	[DIAG_SEV_INFO] = { "item/locomotive" },
}
local kind_sprites
local dispatch_sprites

--- @param candidates table<int, string[]>
--- @return table<int, string>
local function first_valid_sprites(candidates)
	local out = {}
	for k, list in pairs(candidates) do
		for _, path in ipairs(list) do
			if helpers.is_valid_sprite_path(path) then
				out[k] = path
				break
			end
		end
	end
	return out
end

--- @param kind int
--- @param sev int? the row's severity
--- @return string
local function kind_sprite(kind, sev)
	if not kind_sprites then
		kind_sprites = first_valid_sprites(KIND_SPRITE_CANDIDATES)
		dispatch_sprites = first_valid_sprites(DISPATCH_SEV_CANDIDATES)
	end
	if kind == DIAG_KIND_DISPATCH_FAILED and sev and dispatch_sprites[sev] then return dispatch_sprites[sev] end
	return kind_sprites[kind] or "utility/questionmark"
end

-- ---------------------------------------------------------------- state

--- @param player_data PlayerData
--- @return LogFilter
local function get_filter(player_data)
	local f = player_data.tabs.log_tab.filter
	if not f then
		f = model.default_filter()
		player_data.tabs.log_tab.filter = f
	end
	return f
end
log_tab.get_filter = get_filter

--- The manager's item filter as diag's item index (-1: an item the log has never seen, so nothing matches).
--- @param hash string?
--- @param d DiagState
--- @return int?
local function item_filter(hash, d)
	if not hash then return nil end
	return d.item_ix[hash] or -1
end

--- @param player_data PlayerData
--- @param d DiagState
--- @return LogCompiled
local function compiled(player_data, d)
	local f = get_filter(player_data)
	local mf = filters.get(player_data, "log_tab")
	local item = item_filter(mf.item, d)
	local station = mf.station
	local c = player_data.cache.log_cf
	local sev = f.sev
	-- Rebuilt only when the filter changed; otherwise only the window's start moves with the clock.
	if c and c.f_group == f.group and c.f_kind == f.kind and c.f_train == f.train and c.f_window == f.window
		and c.f_item == item and c.f_station == station
		and c.sevs[1] == (sev[1] == true) and c.sevs[2] == (sev[2] == true) and c.sevs[3] == (sev[3] == true) then
		local window = model.WINDOWS[f.window or model.DEFAULT_WINDOW]
		c.min_tick = window and math.max(0, game.tick - window) or nil
		return c
	end
	c = model.compile(f, game.tick, item, station)
	c.f_group, c.f_kind, c.f_train, c.f_window, c.f_item = f.group, f.kind, f.train, f.window, item
	c.f_station = station
	player_data.cache.log_cf = c
	return c
end
log_tab.compiled = compiled

--- @param player_data PlayerData
--- @return int
local function row_limit(player_data)
	local layout = player_data.layout
	return layout and layout.rows_by_tab[TAB] or 10
end

--- @param player_data PlayerData
--- @return {[string]: any}
local function caps(player_data)
	local c = player_data.tabs.log_tab.caps
	if not c then
		c = {}
		player_data.tabs.log_tab.caps = c
	end
	return c
end


-- ---------------------------------------------------------------- names

--- Views made during one render, by id (rows of one stop share it); emptied when the render ends, so nothing stale
--- outlives the call.
--- @type {[uint]: StopNameView|false}?
local view_cache

--- @param id uint
--- @return StopNameView?
local function station_view(id)
	return (name_cell.station_view(id, collector.get().stations, view_cache))
end
log_tab.station_view = station_view

--- @param index uint
--- @return string?
local function player_name(index)
	local p = index and index > 0 and game.get_player(index)
	return p and p.name or nil
end

--- @type LogTextContext
local TEXT_CTX = {
	player = player_name,
	stock = text.stock_caption,
	chip = text.chip_caption,
}

--- @param g LogGroup
--- @param expanded boolean? a lint pass's rows are shown
--- @return LocalisedString
function log_tab.message(g, expanded)
	return model.message(g, TEXT_CTX, expanded)
end

--- @param g LogGroup
--- @return LocalisedString?
function log_tab.message_tooltip(g)
	return model.dispatch_tooltip(g)
end

-- ---------------------------------------------------------------- build

local function hoverable(def)
	return hover.hoverable(def, ROWS)
end

--- Severity toggle: "[dot] 12", toggled while that severity is shown.
--- @param sev int
local function sev_button(sev)
	return {
		type = "button",
		name = "log_sev_" .. sev,
		style = "cybersyn_log_sev_button",
		style_mods = { width = SEV_BUTTON_WIDTH },
		caption = "[img=" .. SEV_SPRITES[sev] .. "] 0",
		toggled = true,
		tags = { sev = sev },
		handler = { [defines.events.on_gui_click] = log_tab.handle.log_sev_click },
	}
end

--- @return LocalisedString[]
local function kind_items()
	local items = {}
	for i, it in ipairs(model.KIND_ITEMS) do
		if it.group then
			items[i] = { "", "[font=default-semibold]", { "cybersyn-gui.log-group-" .. model.GROUPS[it.group].name }, "[/font]" }
		elseif it.kind then
			items[i] = { "cybersyn-diag.kind-" .. DIAG_KIND_KEYS[it.kind] }
		else
			items[i] = { "cybersyn-gui.log-all-kinds" }
		end
	end
	return items
end

--- A toggle in the subheader: a tool button, its name in bold above the tooltip.
local function toggle_button(name, sprite, caption_key, handler)
	return {
		type = "sprite-button",
		name = name,
		style = "tool_button",
		sprite = sprite,
		auto_toggle = false,
		tooltip = { "", "[font=default-bold]", { caption_key }, "[/font]\n", { caption_key .. "-tooltip" } },
		handler = { [defines.events.on_gui_click] = handler },
	}
end

--- The subheader's right side; manager.lua puts it after the shared chip and progress note.
--- @return flib.GuiElemDef[]
function log_tab.subheader_right()
	return {
		sev_button(DIAG_SEV_ERROR),
		sev_button(DIAG_SEV_WARNING),
		sev_button(DIAG_SEV_INFO),
		{
			type = "drop-down",
			name = "log_kind_dropdown",
			style = "cybersyn_log_kind_dropdown",
			items = kind_items(),
			selected_index = 1,
			tooltip = { "cybersyn-gui.log-kind-tooltip" },
			handler = { [defines.events.on_gui_selection_state_changed] = log_tab.handle.log_kind_changed },
		},
		{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.log-train-label" },
			tooltip = { "cybersyn-gui.log-train-tooltip" } },
		{
			type = "textfield",
			name = "log_train_field",
			style = "cybersyn_log_train_field",
			numeric = true,
			allow_decimal = false,
			allow_negative = false,
			lose_focus_on_confirm = true,
			tooltip = { "cybersyn-gui.log-train-tooltip" },
			handler = { [defines.events.on_gui_text_changed] = log_tab.handle.log_train_changed },
		},
		{
			type = "drop-down",
			name = "log_window_dropdown",
			style = "cybersyn_log_window_dropdown",
			items = { { "cybersyn-gui.log-window-10" }, { "cybersyn-gui.log-window-60" }, { "cybersyn-gui.log-window-all" } },
			selected_index = model.DEFAULT_WINDOW,
			tooltip = { "cybersyn-gui.log-window-tooltip" },
			handler = { [defines.events.on_gui_selection_state_changed] = log_tab.handle.log_window_changed },
		},
		{
			type = "button",
			name = "log_follow",
			style = "cybersyn_log_sev_button",
			style_mods = { width = FOLLOW_WIDTH },
			caption = { "cybersyn-gui.log-pause" },
			tooltip = { "cybersyn-gui.log-pause-tooltip" },
			handler = { [defines.events.on_gui_click] = log_tab.handle.log_follow_changed },
		},
		toggle_button("log_summary_toggle", SUMMARY_SPRITE, "cybersyn-gui.log-summary", log_tab.handle.log_summary_changed),
		{
			type = "sprite-button",
			name = "log_export_button",
			style = "tool_button",
			sprite = "utility/export_slot",
			tooltip = { "cybersyn-gui.log-export-tooltip" },
			handler = { [defines.events.on_gui_click] = log_tab.handle.log_export_click },
		},
	}
end

--- One table of the Summary: a caption and up to SUMMARY_TOP rows of [dot] [subject] [count].
local function summary_table(name, caption)
	return {
		type = "frame",
		name = name .. "_frame",
		direction = "vertical",
		style = "cybersyn_log_summary_frame",
		{
			type = "frame",
			style = "cybersyn_unserved_caption_frame",
			{ type = "label", name = name .. "_caption", style = "subheader_caption_label", caption = caption },
		},
		{ type = "table", name = name, style = "cybersyn_log_summary_table", column_count = 3 },
	}
end

function log_tab.create()
	return {
		tab = {
			name = "manager_log_tab",
			type = "tab",
			caption = { "cybersyn-gui.log" },
		},
		content = {
			name = "manager_log_content_frame",
			type = "flow",
			direction = "vertical",
			style = "cybersyn_overview_content",
			{
				type = "frame",
				name = "log_frame",
				direction = "vertical",
				style = "cybersyn_unserved_frame",
				{
					type = "frame",
					direction = "horizontal",
					style = "cybersyn_unserved_caption_frame",
					{ type = "label", name = "log_header", style = "subheader_caption_label", caption = "",
						style_mods = { horizontally_squashable = true } },
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					{ type = "label", name = "log_status", style = "cybersyn_subheader_note", caption = "" },
				},
				{
					type = "flow",
					name = "log_body",
					direction = "vertical",
					style_mods = { vertical_spacing = 0 },
					hoverable({
						type = "scroll-pane",
						name = "log_scroll",
						style = "flib_naked_scroll_pane_no_padding",
						horizontal_scroll_policy = "never",
						vertical_scroll_policy = "always",
						{ type = "table", name = ROWS, style = "cybersyn_log_rows_table", column_count = 1 },
					}),
					{
						type = "flow",
						name = "log_summary",
						direction = "horizontal",
						visible = false,
						style_mods = { horizontal_spacing = 12, padding = 8 },
						summary_table("log_summary_stations", { "cybersyn-gui.log-summary-stations" }),
						summary_table("log_summary_items", { "cybersyn-gui.log-summary-items" }),
					},
					{
						type = "flow",
						name = "log_empty_flow",
						direction = "horizontal",
						style = "cybersyn_overview_empty_flow",
						visible = false,
						{ type = "label", name = "log_empty", style = "cybersyn_overview_empty_label", caption = "" },
					},
				},
			},
		},
	}
end

--- Cell widths from the window layout and the rows area's height (whole rows).
--- @param player_data PlayerData
--- @param layout ManagerLayout
function log_tab.apply_layout(player_data, layout)
	local refs = player_data.refs
	local cw = layout.content_width
	local rows = layout.rows_by_tab[TAB]
	local station = math.floor(W.station * math.min(cw, BASE_CONTENT_WIDTH) / BASE_CONTENT_WIDTH)
	local fixed = W.age + W.dot + W.kind + W.train + station + W.item + W.count + W.print
	local message = cw - FRAME_BORDER - ROW_PADDING - (CELLS - 1) * SPACING - fixed - SCROLLBAR
	local old = player_data.tabs.log_tab.widths
	-- Two summary frames side by side with 12 between them, inside the body's 8 px padding.
	local summary = math.floor((cw - FRAME_BORDER - 16 - 12) / 2)
	player_data.tabs.log_tab.widths = { station = station, message = message, rows = rows, summary = summary }
	for _, name in ipairs({ "log_summary_stations_frame", "log_summary_items_frame" }) do
		local frame = refs[name]
		if frame and frame.valid then frame.style.width = summary end
	end
	if player_data.tabs.log_tab.caps then
		player_data.tabs.log_tab.caps.log_summary_stations = nil
		player_data.tabs.log_tab.caps.log_summary_items = nil
	end
	-- The item chip (icon 28 + caption) is squashed to what the fixed controls leave, so the right end of the
	-- subheader is never pushed out of the window.
	local free = cw - SUBHEADER_PADDING - SUBHEADER_FIXED - 8
	local chip = math.max(60, math.min(CHIP_MAX, free))
	local item_chip = refs[TAB .. "_chip"]
	if item_chip and item_chip.valid then
		item_chip.style.maximal_width = math.max(32, chip - 28)
		item_chip.style.horizontally_squashable = true
	end
	local body = refs.log_body
	if body and body.valid then body.style.height = rows * ROW_HEIGHT end
	local scroll = refs.log_scroll
	if scroll and scroll.valid then scroll.style.height = rows * ROW_HEIGHT end
	local empty = refs.log_empty_flow
	if empty and empty.valid then empty.style.height = rows * ROW_HEIGHT end
	if not old or old.station ~= station or old.message ~= message then
		local parent = refs[ROWS]
		if parent and parent.valid then parent.clear() end
		local state = sync.gui_state(player_data, ROWS)
		-- New widths rebuild the page in one update, as the first fill does (a resolution or scale change is rare).
		state.keys, state.sigs, state.memo, state.elems, state.filled_once = nil, nil, nil, nil, nil
	end
end

-- ---------------------------------------------------------------- rows

--- The row of one ring row by its seq (a lint pass's member), nil once its ring has dropped it.
--- @param seq uint
--- @return LogGroup?
local function find_ring_group(seq)
	local d = storage.diag
	if not d then return nil end
	for _, r in ipairs({ d.ring_basic, d.full and d.ring_full or nil }) do
		local k = diag.first_after(r, seq - 1)
		if k < r.count then
			local i = diag.ring_at(r, k)
			if r.seq[i] == seq then return model.new_group(r, i) end
		end
	end
	return nil
end

--- Follow takes nothing new while the pointer is over the rows (or their scroll pane) and while the window is
--- paused.
--- @param player_data PlayerData
--- @return boolean
function log_tab.held(player_data)
	return player_data.paused or hover.hold_active(player_data, ROWS, HOLD_TICKS)
end


--- @param g LogGroup
--- @return string? hash
local function group_item(g)
	local d = storage.diag
	return g.item ~= 0 and d and d.item_hash[g.item] or nil
end

local station_tooltip = name_cell.station_tooltip

-- Station names and train validity are read again at most this often for a row whose event did not change; each row
-- at its own phase (by its key), so the rows are not all rewritten in one update. A poll rather than a names version:
-- renames, station removals and train invalidation each come from their own handler, and a row would need all three.
local NAME_REFRESH = 600

--- @param key uint
--- @param now uint
--- @return int
local function name_epoch(key, now)
	return math.floor((now + key * 37) / NAME_REFRESH)
end

--- The row's cell elements, kept in its memo (reading `children` makes a wrapper per child on every call).
--- @param elem LuaGuiElement the row
--- @param m table the row's memo
--- @return LuaGuiElement[]
local function row_cells(elem, m)
	local cells = m.cells
	if cells and cells[1].valid then return cells end
	cells = elem.children
	m.cells = cells
	m.icons = {}
	-- build_row's train cell already has the link style and its width.
	m.trs = m.trs or "cybersyn_log_link"
	return cells
end

-- The render's context in upvalues set by render_rows, so a render allocates no closures.
local r_memo, r_widths, r_now

--- Writes a row's cells, each only when what it shows changed since `m` (what the element shows now; empty for a
--- new row). A row whose event, count and numbers are unchanged is not looked at until the name refresh.
--- @param cells LuaGuiElement[]
--- @param g LogGroup
--- @param m table the row's memo, updated
--- @param now uint
--- @param key number
--- @param expanded boolean? the row is a lint pass whose rows are shown below it
--- @param child boolean? the row is one of an expanded lint pass's rows
local function write_cells(cells, g, m, now, key, expanded, child)
	m.seq, m.n_, m.a_, m.b_, m.epoch, m.x_ = g.seq, g.n, g.a, g.b, name_epoch(key, now), expanded
	local tsig = g.first_tick .. "|" .. g.tick .. "|" .. g.n
	if m.t ~= tsig then
		cells[1].tooltip = model.age_tooltip(g)
		m.t = tsig
	end
	if m.sev ~= g.sev then
		cells[2].sprite = SEV_SPRITES[g.sev] or SEV_SPRITES[3]
		cells[2].tooltip = { "cybersyn-diag.sev-" .. (SEV_KEYS[g.sev] or "info") }
		m.sev = g.sev
	end
	if m.kind ~= g.kind or m.ksev ~= g.sev then
		cells[3].sprite = kind_sprite(g.kind, g.sev)
		cells[3].tooltip = { "cybersyn-diag.kind-" .. (DIAG_KIND_KEYS[g.kind] or "alert") }
		m.kind, m.ksev = g.kind, g.sev
	end
	-- train
	local train_ok = g.train ~= 0 and storage.trains[g.train] ~= nil
	local trsig = g.train .. (train_ok and "t" or "")
	if m.tr ~= trsig then
		local train = cells[4]
		-- The tooltip (the link footer) is the cell's own from its build: the caption is the train id.
		train.caption = g.train ~= 0 and tostring(g.train) or ""
		local style = train_ok and "cybersyn_log_link" or "cybersyn_log_link_gone"
		if m.trs ~= style then
			train.style = style
			train.style.width = W.train
			m.trs = style
		end
		m.tr = trsig
	end
	-- station: lead icons · text · tail icons through name_cell, rewritten only when the name or the target changed
	local view = station_view(g.station)
	-- The other station of the event (the provider, the other end of a delivery) is named in this cell's tooltip.
	local other = DIAG_KIND_SCHEMA[g.kind].station2 == "station" and g.station2 ~= 0 and station_view(g.station2) or nil
	local ssig = g.station .. "|" .. (view and view.name or "") .. "|" .. (other and other.name or "")
	if m.st ~= ssig then
		local width = r_widths and r_widths.station or W.station
		local button
		if view then
			button = name_cell.write_pooled(cells[5], m.icons, view.parts, view.name, width)
		else
			button = name_cell.write_pooled(cells[5], m.icons, nil, "", width)
			button.caption = g.station ~= 0 and { "cybersyn-gui.log-gone-station", tostring(g.station) } or ""
			m.icons.text = nil
		end
		if m.en ~= (view ~= nil) then
			button.enabled = view ~= nil
			m.en = view ~= nil
		end
		button.tooltip = station_tooltip(view, other and { "cybersyn-gui.log-other-station", other.name } or nil)
		m.st = ssig
	end
	-- item
	local hash = group_item(g)
	if m.item ~= (hash or "") then
		local item = cells[6]
		local sprite, quality = nil, nil
		if hash then sprite, quality = util.item_sprite_and_tooltip(hash) end
		-- An empty slot shows nothing and log_link_click ignores it (disabled, it would draw its frame).
		if sprite then
			item.sprite = sprite
			if m.q ~= (quality or "") then
				item.quality = quality
				m.q = quality or ""
			end
			item.elem_tooltip = util.elem_tooltip(hash)
			if m.itip == false then item.tooltip = { "cybersyn-gui.item-click-hint" } end
			m.itip = true
		else
			item.sprite = nil
			item.elem_tooltip = nil
			if m.itip ~= false then item.tooltip = "" end
			m.itip = false
		end
		m.item = hash or ""
	end
	-- message, count
	local pass = g.pass and g.n > 1
	-- The train is in the dispatch tooltip, not the caption.
	local msig = g.kind .. "|" .. g.code .. "|" .. g.a .. "|" .. g.b .. "|" .. g.station2 .. "|" .. g.n .. "|" .. g.train ..
		(pass and ("|" .. table.concat(g.lint, ",") .. (expanded and "x" or "")) or "") .. (child and "|c" or "")
	if m.msg ~= msig then
		local message = log_tab.message(g, expanded)
		cells[7].caption = message
		cells[7].tooltip = pass and { "cybersyn-gui.log-lint-pass-tooltip" } or log_tab.message_tooltip(g) or ""
		m.msg = msig
	end
	local count = pass and "" or model.repeat_caption(g.n)
	if m.n ~= count then
		cells[8].caption = count
		m.n = count
	end
end

-- The tags of each part of a row (hover scope and handler names as flib writes them), made once: rows are built with
-- plain LuaGuiElement.add calls, about three times cheaper than flib's gui.add per element.
local row_tags

local function hover_tags(handlers)
	local h = { [defines.events.on_gui_hover] = hover.handle.hover_enter, [defines.events.on_gui_leave] = hover.handle.hover_leave }
	for k, v in pairs(handlers or {}) do h[k] = v end
	return gui.format_handlers(h, { hover_scope = ROWS })
end

local function make_row_tags()
	local click = defines.events.on_gui_click
	local link = log_tab.handle.log_link_click
	local function with(t, extra)
		for k, v in pairs(extra) do t[k] = v end
		return t
	end
	row_tags = {
		plain = hover_tags(),
		train = with(hover_tags({ [click] = link }), { cell = "train" }),
		station = with(hover_tags({ [click] = link }), { cell = "station" }),
		item = with(hover_tags({ [click] = link }), { cell = "item" }),
		message = hover_tags({ [click] = log_tab.handle.log_row_click }),
		print = hover_tags({ [click] = log_tab.handle.log_print_click }),
	}
end

-- Right on an item clears the item filter; train and stop cells take no right-click.
local LEFT, LEFT_RIGHT = { "left" }, { "left", "right" }

--- One empty row at `index` (nil = at the end); write_cells fills it. Rows are reused for other events, so their link
--- cells carry no target: the click finds it from the row.
--- @param parent LuaGuiElement
--- @param index int?
--- @param widths {station: int, message: int}
--- @return LuaGuiElement
local function build_row(parent, index, widths)
	if not row_tags then make_row_tags() end
	local t = row_tags
	local row = parent.add({ type = "frame", direction = "horizontal", style = "cybersyn_log_row", index = index,
		raise_hover_events = true, tags = t.plain })
	row.add({ type = "label", style = "cybersyn_log_age", raise_hover_events = true, tags = t.plain }).style.width = W.age
	row.add({ type = "sprite", style = "cybersyn_log_dot", raise_hover_events = true, tags = t.plain })
	row.add({ type = "sprite", style = "cybersyn_log_kind", raise_hover_events = true, tags = t.plain })
	row.add({ type = "button", style = "cybersyn_log_link", mouse_button_filter = LEFT,
		tooltip = links.LINK_FOOTER, raise_hover_events = true, tags = t.train }).style.width = W.train
	name_cell.pooled_add(row, widths.station, "cybersyn_log_cell_flow", { type = "button", style = "cybersyn_log_link",
		mouse_button_filter = LEFT, raise_hover_events = true, tags = t.station })
	row.add({ type = "sprite-button", style = "cybersyn_log_item", mouse_button_filter = LEFT_RIGHT,
		tooltip = { "cybersyn-gui.item-click-hint" }, raise_hover_events = true, tags = t.item })
	row.add({ type = "label", style = "cybersyn_log_message", raise_hover_events = true, tags = t.message }).style.width =
		widths.message
	row.add({ type = "label", style = "cybersyn_log_count", raise_hover_events = true, tags = t.plain }).style.width = W.count
	row.add({ type = "sprite-button", style = "cybersyn_log_print", sprite = "utility/center",
		tooltip = { "cybersyn-gui.log-print-tooltip" }, raise_hover_events = true, tags = t.print })
	return row
end

--- Brings one row element to `entry` (a LogDisplayRow, or a placeholder without a group): its memo says what the
--- element shows, so only what changed is written; the age only when `age` is set (the viewport and its slice).
--- @param elem LuaGuiElement
--- @param entry {key: number, g: LogGroup?, x: boolean?}
--- @param age boolean?
--- @param still boolean? held: the age only, no name refresh
local function row_write(elem, entry, age, still)
	local key, g, now = entry.key, entry.g, r_now
	local m = r_memo[key]
	if not m then
		m = {}
		r_memo[key] = m
	end
	m.g = g
	if not g then
		if not m.hidden then
			elem.visible = false
			m.hidden = true
		end
		return
	end
	if m.hidden then
		elem.visible = true
		m.hidden = nil
	end
	local cells = row_cells(elem, m)
	local indent = entry.child and CHILD_INDENT or 0
	local message_width = r_widths.message - indent
	if m.ind ~= indent or m.mw ~= message_width then
		elem.style.left_padding = ROW_LEFT_PADDING + indent
		cells[7].style.width = message_width
		m.ind, m.mw = indent, message_width
	end
	local moved = m.seq ~= g.seq or m.n_ ~= g.n or m.a_ ~= g.a or m.b_ ~= g.b or m.x_ ~= entry.x
	if moved or (age and not still and m.epoch ~= name_epoch(key, now)) then
		write_cells(cells, g, m, now, key, entry.x, entry.child)
	end
	if age or moved or not m.a then
		local caption = model.age_caption(now, g)
		if m.a ~= caption then
			cells[1].caption = caption
			m.a = caption
		end
	end
end

-- Per-call context of sync_rows' hooks, in upvalues so a render allocates no closures.
local r_viewport, r_defer = 0, false

local ROW_SYNC = {
	elems = true,
	add = function(parent, index, entry)
		r_memo[entry.key] = {}
		return build_row(parent, index, r_widths)
	end,
	reuse = function(_, old_key, entry)
		local memo = r_memo
		memo[entry.key] = memo[old_key] or {}
		memo[old_key] = nil
	end,
	gone = function(key)
		r_memo[key] = nil
	end,
	after = function(elem, entry, i, fresh)
		local memo = r_memo
		local key = entry.key
		local m = memo[key]
		if not m then
			m = {}
			memo[key] = m
		end
		if fresh and i > r_viewport and entry.g then
			m.stale = true
			r_defer = true
			if not m.hidden then
				elem.visible = false
				m.hidden = true
			end
		elseif not m.stale then
			row_write(elem, entry, i <= r_viewport)
		elseif i <= r_viewport then
			m.stale = nil
			row_write(elem, entry, true)
		else
			r_defer = true
		end
	end,
}

--- Reconciles the rows table with `entries`. Moving a row costs one swap_children (about 0.5 µs) and writing one
--- about 40 µs on a large base (building one about 75 µs), so rows are moved, not rewritten: a key still shown is
--- swapped into its place, a new key takes the element of a key that left (or a built one), and only those elements
--- are written. Under Follow a new event is one element rewritten at the top and every other row swapped one place
--- down; a lint pass moving up is swaps only. New keys below the viewport (a filter change, a burst after a hold) are
--- hidden and written DEFER_ROWS per update, top down, so a burst costs about a viewport of writes at once. Each
--- element's memo says what it shows, so a write touches only the cells that differ.
--- @param parent LuaGuiElement
--- @param entries {key: number, g: LogGroup?, x: boolean?}[]
--- @param state table sync.gui_state of the rows
--- @param build_left int rows that may be built in this call; the rest of a long fill waits for the next update
--- @param viewport int rows from the top written now, with their ages
local function sync_rows(parent, entries, state, build_left, viewport)
	r_viewport, r_defer = viewport, false
	ROW_SYNC.build_budget = build_left
	sync.sync_children(parent, entries, state, false, ROW_SYNC)
	if r_defer then state.defer_from = viewport + 1 end
end

--- Writes up to DEFER_ROWS of the rows the last rewrite left hidden, top down.
--- @param state table
--- @param entries {key: number, g: LogGroup?, x: boolean?}[] the entries the keys were made from
--- @param viewport int
local function write_deferred(state, entries, viewport)
	local from = state.defer_from
	if not from then return end
	local keys, elems, memo = state.keys, state.elems, r_memo
	local n = #keys
	local done = 0
	local i = math.max(from, viewport + 1)
	while i <= n and done < DEFER_ROWS do
		local m = memo[keys[i]]
		if m and m.stale then
			m.stale = nil
			row_write(elems[i], entries[i], false)
			done = done + 1
		end
		i = i + 1
	end
	state.defer_from = i <= n and i or nil
end

--- Writes the ages of the next rows below the viewport (age only, no other cell), as many as the time since the last
--- slice asks for, at most a viewport (see AGE_TICKS).
--- @param state table
--- @param entries {key: number, g: LogGroup?, x: boolean?}[]
--- @param viewport int
--- @param now uint
local function age_slice(state, entries, viewport, now)
	local keys, elems, memo = state.keys, state.elems, r_memo
	local n = #keys
	local below = n - viewport
	if below <= 0 then return end
	local last = state.age_tick
	state.age_tick = now
	-- The rows were just written with their ages.
	if not last then return end
	local elapsed = math.min(now - last, AGE_TICKS)
	if elapsed <= 0 then return end
	local count = math.ceil(below * elapsed / AGE_TICKS)
	if count > viewport then count = viewport end
	local cursor = state.age_cursor or viewport
	for _ = 1, count do
		cursor = (cursor >= n or cursor < viewport) and viewport + 1 or cursor + 1
		local m = memo[keys[cursor]]
		local e = entries[cursor]
		if m and not m.stale and e and e.g then row_write(elems[cursor], e, true, true) end
	end
	state.age_cursor = cursor
end

--- While held: every row's age at once, once per AGE_TICKS (see there).
--- @param state table
--- @param entries {key: number, g: LogGroup?, x: boolean?}[]
--- @param now uint
local function held_ages(state, entries, now)
	local last = state.held_age_tick
	if last and now - last < AGE_TICKS then return end
	state.held_age_tick = now
	local keys, elems, memo = state.keys, state.elems, r_memo
	for i = 1, #keys do
		local m = memo[keys[i]]
		local e = entries[i]
		if m and not m.stale and e and e.g then row_write(elems[i], e, true, true) end
	end
end

--- Rows live in a one-column table whose odd-row background gives the tint, so a row that moves needs no restyle.
--- The table holds PAGE rows once filled: those without a group are hidden placeholders, so a filter that shows few
--- rows destroys none and the next one that shows many creates none.
--- @param player_data PlayerData
--- @param display LogDisplayRow[]
--- @param size int rows the table holds (PAGE; the prewarm grows it)
--- @param changed boolean
--- @param viewport int rows written every update
--- @param held boolean? Follow is held: rows keep their contents, only ages move, the whole page at once every AGE_TICKS
local function render_rows(player_data, display, size, changed, viewport, held)
	local refs = player_data.refs
	local parent = refs[ROWS]
	local widths = player_data.tabs.log_tab.widths
	if not (parent and parent.valid and widths) then return end
	local state = sync.gui_state(player_data, ROWS)
	local memo = state.memo
	if not memo then
		memo = {}
		state.memo = memo
	end
	local now = game.tick
	r_memo, r_widths, r_now = memo, widths, now
	view_cache = {}
	local entries = state.entries
	-- Nothing new: only the ages and the staggered name refresh move, for the viewport and one slice below it, and
	-- the rows a rewrite left for later.
	if not changed and entries and state.display == display and state.size == size and state.widths == widths and
		state.keys and #state.keys == size and not state.filling then
		local keys, elems = state.keys, state.elems
		local intact = elems and #elems == #keys and (not elems[1] or elems[1].valid)
		if intact then
			-- Rows a rewrite left hidden are already in their final places, so showing them moves nothing even while
			-- Follow is held.
			write_deferred(state, entries, viewport)
			if held then
				-- The reader's rows keep their contents, only ages move.
				held_ages(state, entries, now)
			else
				for i = 1, math.min(viewport, #keys) do
					local m = memo[keys[i]]
					if m and not m.stale and display[i] then row_write(elems[i], display[i], true) end
				end
				age_slice(state, entries, viewport, now)
			end
			r_memo, r_widths, view_cache = nil, nil, nil
			return
		end
	end
	state.display, state.size, state.widths = display, size, widths
	entries = {}
	for i, row in ipairs(display) do entries[i] = row end
	local placeholders = state.placeholders
	if not placeholders then
		placeholders = {}
		state.placeholders = placeholders
	end
	for i = #display + 1, size do
		local e = placeholders[i]
		if not e then
			e = { key = -i }
			placeholders[i] = e
		end
		entries[i] = e
	end
	state.entries = entries
	-- The first viewport is built in one go; a long fill below it continues over the next updates.
	local have = state.keys and #state.keys or 0
	local budget = math.max(viewport - have, 0) + FILL_ROWS
	if not state.filled_once then budget = math.max(viewport, FIRST_FILL) end
	sync_rows(parent, entries, state, budget, viewport)
	write_deferred(state, entries, viewport)
	if held then held_ages(state, entries, now) else age_slice(state, entries, viewport, now) end
	state.filled_once = true
	state.filling = #state.keys < #entries or nil
	r_memo, r_widths, view_cache = nil, nil, nil
end

-- ---------------------------------------------------------------- summary

--- @param player_data PlayerData
--- @param tbl LuaGuiElement
--- @param list table[]?
--- @param is_item boolean
local function render_summary_table(player_data, tbl, list, is_item)
	if not (tbl and tbl.valid) then return end
	local d = storage.diag
	local sig = { tostring(list ~= nil) }
	for _, e in ipairs(list or {}) do sig[#sig + 1] = (e.id or e.item) .. ":" .. e.n .. ":" .. e.sev end
	sig = table.concat(sig, ",")
	local c = caps(player_data)
	if c[tbl.name] == sig then return end
	c[tbl.name] = sig
	tbl.clear()
	local widths = player_data.tabs.log_tab.widths
	-- frame width less the table padding, the dot, the count and the spacing between them
	local name_width = (widths and widths.summary or 600) - 14 - 16 - 60 - 2 * 8 - 8
	for _, e in ipairs(list or {}) do
		gui.add(tbl, { type = "sprite", style = "cybersyn_log_dot", sprite = SEV_SPRITES[e.sev],
			tooltip = { "cybersyn-diag.sev-" .. SEV_KEYS[e.sev] } })
		if is_item then
			local hash = d and d.item_hash[e.item]
			local sprite, quality, _, item_name
			if hash then sprite, quality, _, _, item_name = util.item_sprite_and_tooltip(hash) end
			gui.add(tbl, {
				type = "flow",
				direction = "horizontal",
				style = "cybersyn_log_cell_flow",
				{
					type = "sprite-button",
					style = "cybersyn_log_item",
					sprite = sprite,
					quality = quality,
					elem_tooltip = hash and util.elem_tooltip(hash) or nil,
					tags = hash and { kind = "item", id = hash } or {},
					mouse_button_filter = { "left", "right" },
					handler = { [defines.events.on_gui_click] = links.handle.link_click },
				},
				{ type = "label", style = "cybersyn_log_message", style_mods = { width = name_width - 32 },
					caption = item_name or hash or "?" },
			})
		else
			local view = station_view(e.id)
			gui.add(tbl, {
				type = "button",
				style = "cybersyn_log_link",
				style_mods = { width = name_width },
				caption = view and view.name or { "cybersyn-gui.log-gone-station", tostring(e.id) },
				enabled = view ~= nil,
				tooltip = station_tooltip(view, nil),
				tags = view and { kind = view.kind, id = e.id } or {},
				mouse_button_filter = { "left" },
				handler = { [defines.events.on_gui_click] = links.handle.link_click },
			})
		end
		gui.add(tbl, { type = "label", style = "cybersyn_log_count", style_mods = { width = 60 }, caption = format.number(e.n),
			tooltip = { "cybersyn-gui.log-summary-count-tooltip", format.number(e.n), tostring(e.n) } })
	end
end

--- @param player_data PlayerData
--- @param ss LogSummaryState
--- @param done boolean
local function render_summary(player_data, ss, done)
	local refs = player_data.refs
	render_summary_table(player_data, refs.log_summary_stations, done and ss.top_stations or nil, false)
	render_summary_table(player_data, refs.log_summary_items, done and ss.top_items or nil, true)
end

-- ---------------------------------------------------------------- subheader and header line

--- The last planner cycle as storage.stats.cycle holds it, the same figures the Overview's Throughput tooltip shows.
--- @return int? dispatches
--- @return int ticks
local function cycle_figures()
	local cycle = storage.stats and storage.stats.cycle
	if not cycle then return nil, 0 end
	return cycle.dispatches_last, cycle.ticks_last or 0
end

--- "covering the last 11 min · basic · planner cycle 43 ticks · 2.7 dispatches per cycle". The reach is
--- diag.horizon(), the one figure for how far back the log is complete; with full on that is the full ring's reach,
--- and the basic events' longer one is named beside it.
--- @param d DiagState
--- @return LocalisedString
--- @return string sig
local function header_line(d)
	local now = game.tick
	local _, ticks = diag.horizon()
	local covering = logic.short_duration(ticks)
	local mode, basic_covering = { "cybersyn-gui.log-mode-basic" }, ""
	local rb, rf = model.rings(d)
	if rf then
		local basic_start = rb.count > 0 and rb.tick[diag.ring_at(rb, 0)] or now
		basic_covering = logic.short_duration(now - basic_start)
		mode = { "cybersyn-gui.log-mode-full-reach", basic_covering }
	end
	local per_cycle, cycle_ticks = cycle_figures()
	local per = per_cycle and format.number(per_cycle) or "–"
	-- The plurals take the plain numbers: a grouped one ("1,234") is not a number to the locale engine.
	return { "cybersyn-gui.log-header", covering, mode, tostring(cycle_ticks), per, tostring(per_cycle or 0) },
		covering .. "|" .. basic_covering .. "|" .. cycle_ticks .. "|" .. per
end

--- @param player_data PlayerData
--- @param cs LogCountsState
--- @param building boolean
local function render_sev_buttons(player_data, cs, building)
	local refs = player_data.refs
	local f = get_filter(player_data)
	for sev = 1, 3 do
		local button = refs["log_sev_" .. sev]
		if button and button.valid then
			local n = cs.total[sev]
			local shown = f.sev[sev] == true
			local sig = n .. (building and "+" or "") .. (shown and "on" or "off")
			local c = caps(player_data)
			if c[button.name] ~= sig then
				c[button.name] = sig
				local count = model.count_text(n, building)
				-- Five digits and more in short form, so the fixed-width button never truncates; the tooltip has it all.
				local short = model.count_text(n, building, true)
				button.caption = "[img=" .. SEV_SPRITES[sev] .. "] " .. short
				if button.toggled ~= shown then button.toggled = shown end
				button.tooltip = { "cybersyn-gui.log-sev-tooltip", { "cybersyn-diag.sev-" .. SEV_KEYS[sev] }, count }
			end
		end
	end
end

--- The subheader controls written back from the stored filter (on open, and after a chip change).
--- @param player_data PlayerData
function log_tab.restore_widgets(player_data)
	local refs = player_data.refs
	local f = get_filter(player_data)
	local dropdown = refs.log_kind_dropdown
	if dropdown and dropdown.valid then
		local index = 1
		for i, it in ipairs(model.KIND_ITEMS) do
			if (f.group and it.group == f.group) or (f.kind and it.kind == f.kind) then index = i end
		end
		dropdown.selected_index = index
	end
	local field = refs.log_train_field
	if field and field.valid then
		local t = f.train and tostring(f.train) or ""
		if field.text ~= t then field.text = t end
	end
	local window = refs.log_window_dropdown
	if window and window.valid then window.selected_index = f.window or model.DEFAULT_WINDOW end
	local follow = refs.log_follow
	if follow and follow.valid then
		local on = f.follow ~= false
		follow.caption = on and { "cybersyn-gui.log-pause" } or { "cybersyn-gui.log-newest" }
		follow.tooltip = on and { "cybersyn-gui.log-pause-tooltip" } or { "cybersyn-gui.log-newest-tooltip" }
	end
	if refs.log_summary_toggle and refs.log_summary_toggle.valid then refs.log_summary_toggle.toggled = f.summary == true end
	local c = player_data.tabs.log_tab.caps
	if c then
		for sev = 1, 3 do c["log_sev_" .. sev] = nil end
	end
end

-- ---------------------------------------------------------------- the tab

--- The tab exists in every window; it is shown while diagnostics are on. Every Lua state reads the same storage.diag,
--- so every peer writes the same `visible`.
--- @param player_data PlayerData
function log_tab.refresh_visibility(player_data)
	local refs = player_data.refs
	local tab = refs and refs.manager_log_tab
	if not (tab and tab.valid) then return end
	local on = storage.diag ~= nil
	if tab.visible ~= on then tab.visible = on end
	if not on then
		if tab.badge_text ~= "" then tab.badge_text = "" end
		log_tab.forget(player_data)
		if player_data.selected_tab == TAB then nav.select_tab(player_data, "overview_tab") end
	end
end

--- Diagnostics are off: every seq the player's Log state holds belongs to a state that is gone.
--- @param player_data PlayerData
function log_tab.forget(player_data)
	player_data.tabs.log_tab.badge = nil
	player_data.tabs.log_tab.seen = nil
	player_data.tabs.log_tab.rows = nil
	player_data.tabs.log_tab.counts = nil
	player_data.tabs.log_tab.summary = nil
	player_data.cache.log_cf = nil
	player_data.tabs.log_tab.expanded = nil
end

local PREWARM_ROWS = 6

--- While another tab shows, the row pool grows by PREWARM_ROWS hidden rows per render up to the page, so the Log's first
--- render writes cells into existing rows instead of creating about 13 elements per row in one update.
--- @param player_data PlayerData
function log_tab.prewarm(player_data)
	if not storage.diag or player_data.selected_tab == TAB then return end
	local parent = player_data.refs[ROWS]
	if not (parent and parent.valid and player_data.tabs.log_tab.widths and collector.get().tick) then return end
	local state = sync.gui_state(player_data, ROWS)
	local have = state.keys and #state.keys or #parent.children
	if have >= PAGE then return end
	render_rows(player_data, {}, math.min(PAGE, have + PREWARM_ROWS), true, row_limit(player_data))
end

--- Unread errors as the tab's badge, and the row pool prewarmed.
--- @param player_data PlayerData
function log_tab.refresh_badge(player_data)
	local refs = player_data.refs
	local tab = refs and refs.manager_log_tab
	local d = storage.diag
	if not (tab and tab.valid and d) then return end
	log_tab.prewarm(player_data)
	local bs = player_data.tabs.log_tab.badge
	if not bs then
		bs = {}
		player_data.tabs.log_tab.badge = bs
	end
	local seen = model.seen_seq(player_data.tabs.log_tab.seen, d)
	local n = model.update_badge(bs, d, seen, BADGE_BUDGET, diag.inherit_threshold(d))
	local caption = model.badge_caption(n)
	if tab.badge_text ~= caption then
		tab.badge_text = caption
		tab.tooltip = n > 0 and { "cybersyn-gui.log-badge-tooltip", format.number(n), tostring(n) } or ""
	end
end

--- @param player_data PlayerData
--- @param seq uint the newest seq the Log has on screen
function log_tab.mark_seen(player_data, seq)
	local d = storage.diag
	if not d then return end
	local id = model.state_id(d)
	local seen = player_data.tabs.log_tab.seen
	if seen and seen.state == id and seen.seq >= seq then return end
	player_data.tabs.log_tab.seen = { state = id, seq = seq }
end

--- @param map_data MapData
--- @param player_data PlayerData
function log_tab.build(map_data, player_data)
	local refs = player_data.refs
	if not (refs.log_body and refs.log_body.valid) then return end
	local d = storage.diag
	if not d then return end
	local f = get_filter(player_data)
	local cf = compiled(player_data, d)
	local limit = row_limit(player_data)

	local cs = player_data.tabs.log_tab.counts
	if not cs then
		cs = {}
		player_data.tabs.log_tab.counts = cs
	end
	local rows_flow, summary_flow, empty_flow = refs[ROWS], refs.log_summary, refs.log_empty_flow
	local status_sig, status
	local empty_sig, empty_caption
	-- One scan budget per update: the rows (or the Summary) first, the counts get what is left.
	local left = SCAN_BUDGET
	local seen = d.seq
	if f.summary then
		local ss = player_data.tabs.log_tab.summary
		if not ss then
			ss = {}
			player_data.tabs.log_tab.summary = ss
		end
		local done, used = model.update_summary(ss, d, cf, left)
		left = left - used
		-- The Summary is a count up to as_of, not a view of the newest rows.
		seen = nil
		-- The scroll pane keeps the body's full height even when empty, so it must go too or the Summary is clipped.
		if refs.log_scroll.visible then refs.log_scroll.visible = false end
		if rows_flow.visible then rows_flow.visible = false end
		local any = done and (#ss.top_stations > 0 or #ss.top_items > 0)
		if summary_flow.visible ~= (any == true) then summary_flow.visible = any == true end
		render_summary(player_data, ss, done)
		if done then
			local age = logic.short_duration(game.tick - ss.as_of_tick)
			status_sig = "sum" .. ss.scanned .. "|" .. age
			status = { "cybersyn-gui.log-summary-status", format.number(ss.scanned), age, tostring(ss.scanned) }
			if not any then empty_sig, empty_caption = "sum-empty", { "cybersyn-gui.log-empty" } end
		else
			status_sig, status = "summing", { "cybersyn-gui.log-summarising" }
			empty_sig, empty_caption = "summing", { "cybersyn-gui.log-summarising" }
		end
	else
		player_data.tabs.log_tab.summary = nil
		local rs = player_data.tabs.log_tab.rows
		if not rs then
			rs = { groups = {} }
			player_data.tabs.log_tab.rows = rs
		end
		local held = log_tab.held(player_data)
		local rows_changed, used = model.update_rows(rs, d, cf, PAGE, f.follow ~= false, left, held)
		left = left - used
		if summary_flow.visible then summary_flow.visible = false end
		local any = #rs.groups > 0
		local scroll = refs.log_scroll
		if scroll.visible ~= any then scroll.visible = any end
		if rows_flow.visible ~= any then rows_flow.visible = any end
		-- With nothing to show the row elements stay (hidden), to be reused when rows come back.
		if any then
			local expanded = player_data.tabs.log_tab.expanded
			local now_sig = player_data.tabs.log_tab.expanded_v or 0
			if rows_changed or not rs.display or rs.expanded_sig ~= now_sig then
				rs.display = model.display(rs.groups, expanded, find_ring_group, PAGE)
				rs.expanded_sig = now_sig
				rows_changed = true
			end
			render_rows(player_data, rs.display, PAGE, rows_changed, limit, held)
		end
		rs.held = held or nil
		if not any then
			if rs.below then
				empty_sig, empty_caption = "scanning", { "cybersyn-gui.log-scanning" }
			else
				empty_sig, empty_caption = "empty", { "cybersyn-gui.log-empty" }
			end
		end
		if f.follow == false and rs.anchor then
			local newer, complete = model.newer(rs, d)
			local shown = model.count_text(newer, not complete)
			status_sig = "paused" .. shown
			status = { "cybersyn-gui.log-paused", shown, tostring(newer) }
			seen = rs.anchor
		elseif rs.held then
			status_sig, status = "held", { "cybersyn-gui.log-held" }
			seen = rs.top
		else
			status_sig, status = "", ""
		end
	end
	local building = model.update_counts(cs, d, cf, math.max(0, left))
	render_sev_buttons(player_data, cs, building)

	local show_empty = empty_caption ~= nil
	if empty_flow.visible ~= show_empty then empty_flow.visible = show_empty end
	if show_empty then sync.set_if_changed(caps(player_data), refs.log_empty, empty_sig, empty_caption) end
	sync.set_if_changed(caps(player_data), refs.log_status, status_sig, status)

	local header, header_sig = header_line(d)
	sync.set_if_changed(caps(player_data), refs.log_header, header_sig, header, { "cybersyn-gui.log-header-tooltip" })
	if seen then log_tab.mark_seen(player_data, seen) end
end

-- ---------------------------------------------------------------- export, chat print

--- Writes what the Log's filter selects to a CSV file on the player's machine and says where in chat.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return string? path
function log_tab.export(player, player_data)
	local d = storage.diag
	if not d then return nil end
	local path, rows = diag.export(player.index, model.export_filter(compiled(player_data, d)))
	if path then player.print({ "cybersyn-gui.log-exported", format.number(rows), path }) end
	return path
end

--- A row's group by any seq it holds (the shown rows), else the ring row with that seq.
--- @param player_data PlayerData
--- @param seq uint
--- @return LogGroup?
local function find_group(player_data, seq)
	local rs = player_data.tabs.log_tab.rows
	for _, g in ipairs(rs and rs.groups or {}) do
		if g.seq == seq or g.first == seq then return g end
	end
	return find_ring_group(seq)
end

--- The chat line for a row: its age, kind, tags the chat makes clickable, and the message.
--- @param player LuaPlayer
--- @param g LogGroup
--- @return LocalisedString
function log_tab.chat_line(player, g)
	local train_unit
	local train = g.train ~= 0 and storage.trains[g.train]
	local entity = train and train.entity
	if entity and entity.valid then
		local front = entity.front_stock
		train_unit = front and front.unit_number or nil
	end
	local stop_unit, gps
	local view = station_view(g.station)
	if view then
		local stop = util.stop_record(g.station)
		if stop then
			stop_unit = stop.unit_number
			gps = { x = stop.position.x, y = stop.position.y, surface = stop.surface.name }
		end
	elseif entity and entity.valid and entity.front_stock then
		local front = entity.front_stock
		gps = { x = front.position.x, y = front.position.y, surface = front.surface.name }
	end
	local tags = model.chat_tags(train_unit, stop_unit, gps, group_item(g))
	return { "cybersyn-gui.log-chat", logic.format_duration(game.tick - g.tick),
		{ "cybersyn-diag.kind-" .. (DIAG_KIND_KEYS[g.kind] or "alert") }, tags, log_tab.message(g) }
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param seq uint
--- @return LocalisedString? printed
function log_tab.print_row(player, player_data, seq)
	local g = find_group(player_data, seq)
	if not g then return nil end
	local line = log_tab.chat_line(player, g)
	player.print(line)
	return line
end

-- ---------------------------------------------------------------- handlers

log_tab.handle = {}

log_tab.wrapper = util.wrapper

local function changed(player, player_data)
	nav.rerender(player, player_data)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_sev_click(player, player_data, refs, e)
	local sev = e.element.tags.sev
	local f = get_filter(player_data)
	f.sev[sev] = not f.sev[sev]
	changed(player, player_data)
end

--- @param e EventData.on_gui_selection_state_changed
function log_tab.handle.log_kind_changed(player, player_data, refs, e)
	local it = model.KIND_ITEMS[e.element.selected_index] or {}
	local f = get_filter(player_data)
	f.group, f.kind = it.group, it.kind
	changed(player, player_data)
end

--- @param e EventData.on_gui_text_changed
function log_tab.handle.log_train_changed(player, player_data, refs, e)
	local f = get_filter(player_data)
	local id = tonumber(e.element.text)
	f.train = id and id > 0 and math.floor(id) or nil
	changed(player, player_data)
end

--- @param e EventData.on_gui_selection_state_changed
function log_tab.handle.log_window_changed(player, player_data, refs, e)
	get_filter(player_data).window = e.element.selected_index
	changed(player, player_data)
end

--- Pause, or Newest: back to the top and following again.
--- @param player_data PlayerData
--- @param on boolean
function log_tab.set_follow(player_data, on)
	local f = get_filter(player_data)
	f.follow = on
	log_tab.restore_widgets(player_data)
	local scroll = player_data.refs.log_scroll
	if on and scroll and scroll.valid then scroll.scroll_to_top() end
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_follow_changed(player, player_data, refs, e)
	log_tab.set_follow(player_data, get_filter(player_data).follow == false)
	changed(player, player_data)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_summary_changed(player, player_data, refs, e)
	local f = get_filter(player_data)
	f.summary = not f.summary
	e.element.toggled = f.summary
	-- Toggling it on again recomputes it.
	player_data.tabs.log_tab.summary = nil
	changed(player, player_data)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_export_click(player, player_data, refs, e)
	log_tab.export(player, player_data)
end

--- @param e EventData.on_gui_click
--- The group a row element shows, from its position in the rows table.
--- @param player_data PlayerData
--- @param elem LuaGuiElement a row or anything inside one
--- @return LogGroup?
local function row_group(player_data, elem)
	local rows = player_data.refs[ROWS]
	while elem and elem.valid and elem.parent and elem.parent ~= rows do elem = elem.parent end
	if not (elem and elem.valid and elem.parent == rows) then return nil end
	local state = sync.gui_state(player_data, ROWS)
	local key = state.keys and state.keys[elem.get_index_in_parent()]
	if not key then return nil end
	-- The memo keeps the group a row shows, also one the rows have dropped while the hover hold kept it on screen.
	local m = state.memo and state.memo[key]
	if m and m.g then return m.g end
	return find_group(player_data, key)
end

--- The link target of a row's train, station or item cell: {kind, id} or nil.
--- @param g LogGroup
--- @param cell string
--- @return string? kind
--- @return any id
local function cell_target(g, cell)
	if cell == "train" then
		if g.train ~= 0 then return "train", g.train end
	elseif cell == "station" then
		local view = station_view(g.station)
		if view then return view.kind, g.station end
	elseif cell == "item" then
		local hash = group_item(g)
		if hash then return "item", hash end
	end
	return nil, nil
end

--- A train, station or item cell of a row: the shared link semantics (links.handle_link_click) on the row's target.
--- @param e EventData.on_gui_click
function log_tab.handle.log_link_click(player, player_data, refs, e)
	hover.touch_hover(e)
	local g = row_group(player_data, e.element)
	if not g then return end
	local kind, id = cell_target(g, e.element.tags.cell)
	if not kind then return end
	links.handle_link_click(player, player_data, e, kind, id)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_print_click(player, player_data, refs, e)
	hover.touch_hover(e)
	local g = row_group(player_data, e.element)
	if g then log_tab.print_row(player, player_data, g.seq) end
end

log_tab.cell_target = cell_target

--- A lint pass's row opens and closes its rows.
--- @param player_data PlayerData
--- @param g LogGroup
--- @return boolean toggled
function log_tab.toggle_pass(player_data, g)
	if not (g and g.pass and g.n > 1) then return false end
	local expanded = player_data.tabs.log_tab.expanded or {}
	player_data.tabs.log_tab.expanded = expanded
	expanded[g.pass] = not expanded[g.pass] or nil
	player_data.tabs.log_tab.expanded_v = (player_data.tabs.log_tab.expanded_v or 0) + 1
	return true
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_row_click(player, player_data, refs, e)
	hover.touch_hover(e)
	if log_tab.toggle_pass(player_data, row_group(player_data, e.element)) then changed(player, player_data) end
end

gui.add_handlers(log_tab.handle, log_tab.wrapper)

return log_tab
