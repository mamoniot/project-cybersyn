-- Per-item drill-down: the Inventory tab shows one item's providers, requesters (in the
-- dispatcher's order) and trains whenever the item filter is set, in place of its grids. A left-click on any item
-- cell sets the filter and selects the Inventory; the back button in the drill-down's subheader (like the filter
-- chip's x) clears the filter, and the grids return. Other tabs keep applying the filter to their own rows. Everything
-- comes from the collector's snapshot plus the diagnostics' unserved entries; the model (scripts/gui/item-model.lua)
-- is rebuilt only when the snapshot pass, the filters or the item change, and the rows are synced with sig guards, so
-- a steady update writes nothing.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local sync = require("scripts.gui.utils.sync")
local filters = require("scripts.gui.utils.filters")
local hover = require("scripts.gui.utils.hover")
local links = require("scripts.gui.utils.links")
local nav = require("scripts.gui.utils.nav")
local rich_text = require("scripts.gui.rich-text")
local metrics = require("scripts.gui.metrics")
local collector = require("scripts.gui.collector")
local diag = require("scripts.diag")
local pm = require("scripts.gui.problems-model")
local text = require("scripts.gui.unserved-text")
local name_cell = require("scripts.gui.name-cell")
local logic = require("scripts.gui.tab-logic")
local item_model = require("scripts.gui.item-model")

--- @class ItemView
--- @field hash string the item it shows (the item filter it was built for)

--- @class ItemCache
--- @field hash string
--- @field key string snapshot pass the model was built from
--- @field model ItemModel
--- @field alloc {providers: int, requesters: int, trains: int}?
--- @field alloc_sig string?
--- @field delivered int?
--- @field delivered_key string?
--- @field header_sig string?

local item = {}

local TAB = "item_tab"
local VIEW = "item_view"
local NO_VALUE = text.NO_VALUE
local ROW = 32
-- Requesters column that shows the wait, and the step of the "last delivery n ago" tooltip age.
local WAIT_COLUMN = 5
local AGE_STEP = 3600
-- Row writes per update (budget: 2 ms per update), counted in rows rewritten in place; a new row costs about
-- three rewrites. A table is rewritten whole or not at all, so it always shows one pass's rows in that pass's order
-- (a table left for the next update keeps the previous pass's rows, count and wait clock). New rows are added a few
-- per update below rows that already match the model, as the Trains tab builds its first page.
local WRITE_BUDGET = 18
local BUILD_COST = 3
local RENDER_ORDER = { "requesters", "providers", "trains" }
-- Each table scrolls inside its share of the window and holds at most the Log's page of rows. Rows below a table's
-- viewport move nothing the player sees, so once its viewport is full they are added with what is left of FILL_ROWS
-- new rows per update (the three tables together, viewport rows counted first), and only in an update that leaves no
-- rewrite waiting. A new row costs 0.12-0.16 ms on a 2,000-station base: 16 keep a fill update near 3 ms.
local MAX_ROWS = 200
local FILL_ROWS = 16
local HEADER = 20
-- The scroll panes reserve their bar's width, so the rows' width does not change with their number.
local SCROLLBAR = metrics.SCROLLBAR
-- Signing a row costs about 8 µs on a 2,000-station base: between passes Requesters below the viewport are signed
-- CHECK_ROWS per update in turn (23 rows in 4 updates, a 200-row table in about a pass and a half), and at most
-- WINDOW_WRITES of them are rewritten.
local CHECK_ROWS = 6
local WINDOW_WRITES = 4
-- Signed rows of tables that show an older pass, per update (about 1.6 ms); the first such table always goes.
local FULL_CHECK = 200
-- Wait clocks below the viewport written per update, in turn.
local CLOCK_ROWS = 6

-- The Inventory's content, which the drill-down takes over (manager.lua sizes it).
local HOST_CONTENT = "manager_inventory_content_frame"

--- The reason or queue state is plain coloured text (nothing happens on a click): the chip style's colour as a label.
--- @param chip_style string? cybersyn_chip_red|orange|grey|acked
--- @return string
local function label_style(chip_style)
	return (string.gsub(chip_style or "cybersyn_chip_grey", "^cybersyn_chip_", "cybersyn_reason_label_"))
end

local STATUS_COLOR, status_key = logic.STATUS_COLOR, logic.status_key

-- Logical px; the station / destination column of each table takes what is left of the content width.
-- A row of a station with secondary inventories names its inventory after the station's name ("Inventory 2  [A]2",
-- the station combinator's row "[A]1"), at most this wide; a station with one row has no tag and keeps the whole
-- column for its name.
local TAG_W = 120
local W = { value = 96, status = 150, priority = 64, wait = 80, why = 132, train = 72, train_status = 150 }
local FRAME_BORDER = metrics.FRAME_BORDER
local TABLE_PADDING = metrics.TABLE_LEFT_PADDING + metrics.TABLE_RIGHT_PADDING
local TABLE_SPACING = metrics.TABLE_SPACING

--- @class ItemColumn
--- @field kind "station"|"train"|"value"|"text"|"chip"|"status"
--- @field width int? nil = the flexible column
--- @field header string locale key suffix

local COLUMNS = {
	providers = {
		{ kind = "station", header = "station" },
		{ kind = "value", width = W.priority, header = "priority" },
		{ kind = "value", width = W.value, header = "stock" },
		{ kind = "value", width = W.value, header = "threshold" },
		{ kind = "value", width = W.value, header = "out" },
		{ kind = "status", width = W.status, header = "status" },
	},
	requesters = {
		{ kind = "station", header = "station" },
		{ kind = "value", width = W.priority, header = "priority" },
		{ kind = "value", width = W.value, header = "requested" },
		{ kind = "value", width = W.value, header = "threshold" },
		{ kind = "value", width = W.wait, header = "wait" },
		{ kind = "chip", width = W.why, header = "why" },
		{ kind = "value", width = W.value, header = "incoming" },
	},
	trains = {
		{ kind = "train", width = W.train, header = "train" },
		{ kind = "text", width = W.train_status, header = "train-status" },
		{ kind = "value", width = W.value, header = "amount" },
		{ kind = "station", header = "to" },
	},
}

--- @param t string "providers"|"requesters"|"trains"
local function table_name(t) return "item_" .. t .. "_table" end

--- @param key int row position
local function wait_name(key) return "item_wait_" .. key end

local get_period = logic.get_period

--- Width of each table's flexible column for the current layout.
--- @param content_width int
--- @return {[string]: int}
local function flex_widths(content_width)
	local out = {}
	for t, cols in pairs(COLUMNS) do
		local fixed = 0
		for _, c in ipairs(cols) do fixed = fixed + (c.width or 0) end
		out[t] = content_width - FRAME_BORDER - TABLE_PADDING - (#cols - 1) * TABLE_SPACING - fixed - SCROLLBAR
	end
	return out
end

-- ---------------------------------------------------------------- build

local PRIORITY_TOOLTIP = {
	providers = "cybersyn-gui.item-provider-priority-tooltip",
	requesters = "cybersyn-gui.item-priority-tooltip",
}

local function header_cell(caption, width, right, tooltip)
	return {
		type = "label",
		style = right and "cybersyn_unserved_header_value" or "cybersyn_unserved_header",
		style_mods = { width = width },
		caption = caption,
		tooltip = tooltip,
	}
end

local function section_def(t, flex)
	-- The column headers stay above the scroll pane; the same style keeps them over their columns.
	local header = {
		type = "table",
		name = "item_" .. t .. "_header",
		style = "cybersyn_unserved_table",
		column_count = #COLUMNS[t],
	}
	for _, c in ipairs(COLUMNS[t]) do
		local tooltip = c.header == "priority" and { PRIORITY_TOOLTIP[t] } or nil
		header[#header + 1] = header_cell({ "cybersyn-gui.item-col-" .. c.header }, c.width or flex[t],
			c.kind == "value" or c.kind == "train", tooltip)
	end
	local caption_tooltip = t == "requesters" and { "cybersyn-gui.item-requesters-tooltip" } or nil
	return {
		type = "frame",
		name = "item_" .. t .. "_frame",
		direction = "vertical",
		style = "cybersyn_unserved_frame",
		{
			type = "frame",
			direction = "horizontal",
			style = "cybersyn_unserved_caption_frame",
			style_mods = { height = 36 },
			{
				type = "label",
				name = "item_" .. t .. "_caption",
				style = "subheader_caption_label",
				caption = { "cybersyn-gui.item-" .. t },
				tooltip = caption_tooltip,
			},
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			{ type = "label", name = "item_" .. t .. "_count", style = "cybersyn_subheader_note", caption = "" },
		},
		{
			type = "flow",
			name = "item_" .. t .. "_body",
			direction = "vertical",
			style_mods = { vertical_spacing = 0 },
			header,
			-- Hover-aware like the rows, so the hold also covers the scroll bar and the pane's blank space.
			hover.hoverable({
				type = "scroll-pane",
				name = "item_" .. t .. "_scroll",
				style = "cybersyn_item_scroll_pane",
				horizontal_scroll_policy = "never",
				vertical_scroll_policy = "auto-and-reserve-space",
				{ type = "table", name = table_name(t), style = "cybersyn_item_rows_table", column_count = #COLUMNS[t] },
				{
					type = "flow",
					name = "item_" .. t .. "_empty_flow",
					direction = "horizontal",
					style = "cybersyn_overview_empty_flow",
					visible = false,
					{
						type = "label",
						name = "item_" .. t .. "_empty_label",
						style = "cybersyn_overview_empty_label",
						caption = { "cybersyn-gui.item-empty-" .. t },
					},
				},
			}, table_name(t)),
		},
	}
end

--- @param layout ManagerLayout
local function view_def(layout)
	local flex = flex_widths(layout.content_width)
	local total = function(name)
		return { type = "label", name = "item_total_" .. name, style = "cybersyn_item_total", caption = "" }
	end
	local def = {
		type = "flow",
		name = VIEW,
		direction = "vertical",
		style = "cybersyn_overview_content",
		{
			type = "frame",
			name = "item_subheader",
			style = "cybersyn_tab_subheader",
			{
				type = "sprite-button",
				name = "item_back_button",
				style = "tool_button",
				sprite = "flib_nav_backward_black",
				tooltip = { "cybersyn-gui.item-back-clear-tooltip" },
				handler = { [defines.events.on_gui_click] = item.handle.item_back },
			},
			{
				type = "sprite-button",
				name = "item_icon",
				style = "cybersyn_item_chip_icon",
				mouse_button_filter = { "left", "right" },
				tags = { kind = "item" },
				handler = { [defines.events.on_gui_click] = links.handle.link_click },
			},
			{ type = "label", name = "item_name", style = "subheader_caption_label", caption = "" },
			-- The station chip as the tab subheader shows it: the drill-down's subheader takes that one's place.
			{
				type = "flow",
				name = "item_station_chip_flow",
				direction = "horizontal",
				visible = false,
				style_mods = { horizontal_spacing = 0, vertical_align = "center", left_margin = 8 },
				{
					type = "sprite-button",
					name = "item_station_chip_icon",
					style = "cybersyn_item_chip_icon",
					sprite = "item/train-stop",
					tags = { chip = "station" },
					mouse_button_filter = { "left", "right" },
					handler = { [defines.events.on_gui_click] = item.handle.item_station_chip },
				},
				{
					type = "button",
					name = "item_station_chip",
					style = "cybersyn_item_chip",
					tags = { chip = "station" },
					mouse_button_filter = { "left", "right" },
					handler = { [defines.events.on_gui_click] = item.handle.item_station_chip },
				},
			},
			{ type = "label", name = "item_collecting", style = "cybersyn_subheader_note", visible = false },
			{ type = "empty-widget", style = "flib_horizontal_pusher" },
			total("provided"),
			total("in_transit"),
			total("requested"),
			total("delivered"),
		},
	}
	for _, t in ipairs(item_model.TABLES) do
		def[#def + 1] = section_def(t, flex)
	end
	return def
end

-- ---------------------------------------------------------------- open / close

--- The item the drill-down shows: the item filter, while it names an item that still exists.
--- @param player_data PlayerData
--- @return string?
function item.filter_hash(player_data)
	local hash = player_data.filters.item
	if hash and util.item_sprite_and_tooltip(hash) then return hash end
	return nil
end

--- Drops the drill-down's elements and render state; the Inventory shows its grids again on its next render
--- (inventory_tab.set_drill_down).
--- @param player LuaPlayer?
--- @param player_data PlayerData
function item.close(player, player_data)
	local frame = player_data.cache.item_refs and player_data.cache.item_refs[VIEW]
	if frame and frame.valid then frame.destroy() end
	player_data.cache.item_view = nil
	player_data.cache.item = nil
	player_data.cache.item_refs = nil
	local states = player_data.gui_state
	if states then
		for _, t in ipairs(item_model.TABLES) do states[table_name(t)] = nil end
	end
end

--- Builds the drill-down's elements into the Inventory's content when they are not there, or points them at `hash`.
--- @param player_data PlayerData
--- @param hash string
--- @return boolean ready
local function ensure_view(player_data, hash)
	local view = player_data.cache.item_view
	local frame = player_data.cache.item_refs and player_data.cache.item_refs[VIEW]
	if view and frame and frame.valid then
		if view.hash ~= hash then
			view.hash = hash
			player_data.cache.item = nil
			-- Every cell is rewritten for the new item: the per-cell memo of the old one says nothing about it.
			local states = player_data.gui_state
			if states then
				for _, t in ipairs(item_model.TABLES) do
					local st = states[table_name(t)]
					if st then st.sigs, st.cells = nil, nil end
				end
			end
		end
		return true
	end
	item.close(nil, player_data)
	local layout = player_data.layout
	local content = player_data.refs[HOST_CONTENT]
	if not (layout and content and content.valid) then return false end
	local refs = {}
	gui.add(content, view_def(layout), refs)
	player_data.cache.item_refs = refs
	player_data.cache.item_view = { hash = hash }
	return true
end

-- ---------------------------------------------------------------- render

local function station_view(snapshot, id)
	local st = id and snapshot.stations[id]
	if not st then return nil end
	return st
end

local station_tooltip = name_cell.station_tooltip

local network_caption = util.network_caption
local TAG = "item_net_tag"

local function tag_def(v, scope)
	return hover.hoverable({
		type = "label",
		name = TAG,
		style = "cybersyn_subheader_note",
		style_mods = { maximal_width = TAG_W },
		caption = v.tag,
		tooltip = v.tooltip,
	}, scope)
end

--- An inventory row's network as the Stations tab's Network cell shows it: icon and mask ("[A]2"), or for an
--- each-network row the each icon and how many networks it is on ("×3"). Nil for a row on no network.
--- @param row SnapshotInventory
--- @return string?
local function row_network_label(row)
	local name = row.network_name
	if not name then return nil end
	if name == NETWORK_EACH then
		return rich_text.network_icon_with(name, "×" .. (row.networks and table_size(row.networks) or 0))
	end
	return rich_text.network_icon_with(name, row.mask and tostring(row.mask) or "")
end

--- What the row's network texts depend on: the station's network, or for a station with several inventory rows the
--- row's own network, mask, inventory and priority. Cheap: rows are signed every update, their texts built only when
--- this changes.
--- @param r ItemProviderRow|ItemRequesterRow
--- @param st SnapshotStation?
--- @return string
local function network_sig(r, st)
	local row = r.row
	if not (r.multi and row) then return tostring(st and st.network_name) end
	return table.concat({ r.key, tostring(row.network_name), row_network_label(row) or "", tostring(row.index),
		tostring(r.priority) }, "/")
end

--- The network a row names: the station's for a station with one inventory row (as before rows), else the row's own,
--- with its inventory ("Inventory 2") in the row's short tag.
--- @param r ItemProviderRow|ItemRequesterRow
--- @param st SnapshotStation?
--- @return LocalisedString network for tooltips
--- @return LocalisedString? tag the row's short tag, nil for a station with one row
local function row_network(r, st)
	local row = r.row
	if not (r.multi and row) then return network_caption(st and st.network_name), nil end
	local net = row_network_label(row) or network_caption(row.network_name)
	-- The dispatcher's priority for this row (the model's, with the item override), not the combinator's raw signal,
	-- so the tooltip agrees with the Priority column.
	local tip = { "", net, " · ", row.label, " · ", { "cybersyn-gui.item-col-priority" }, " ", tostring(r.priority) }
	if row.index == 0 then return tip, net end
	return tip, { "", row.label, "  ", net }
end

--- One cell definition from its column and value.
--- @param col ItemColumn
--- @param v table the cell's value: {caption, tooltip, style?, id?, st?, visible?}
--- @param width int
--- @param scope string
local function cell_def(col, v, width, scope)
	local kind = col.kind
	if kind == "station" then
		local st = v.st
		local name = st and st.name or NO_VALUE
		local def = name_cell.def(st and st.name_parts, name, { kind = st and "station" or nil, id = st and v.id or nil },
			v.tag and width - TAG_W or width, v.tooltip or "", scope)
		if v.tag then
			def.style_mods.width = width
			def[#def + 1] = tag_def(v, scope)
		end
		return def
	elseif kind == "train" then
		return hover.hoverable({
			type = "button",
			style = "cybersyn_item_train_button",
			style_mods = { width = width },
			caption = v.caption,
			tooltip = v.tooltip,
			tags = { kind = "train", id = v.id },
			mouse_button_filter = { "left" },
			handler = { [defines.events.on_gui_click] = links.handle.link_click },
		}, scope)
	elseif kind == "chip" then
		return {
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_unserved_cell_flow",
			style_mods = { width = width },
			hover.hoverable({
				type = "label",
				style = label_style(v.style),
				style_mods = { maximal_width = width },
				caption = v.caption or "",
				tooltip = v.tooltip,
				visible = v.visible ~= false,
			}, scope),
		}
	elseif kind == "status" then
		return {
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_unserved_cell_flow",
			style_mods = { width = width },
			{ type = "sprite", style = "flib_indicator", sprite = v.sprite },
			{ type = "label", style = "cybersyn_unserved_cell", caption = v.caption, tooltip = v.tooltip },
		}
	end
	return hover.hoverable({
		type = "label",
		style = kind == "value" and "cybersyn_unserved_value" or "cybersyn_unserved_cell",
		style_mods = { width = width },
		caption = v.caption,
		tooltip = v.tooltip,
	}, scope)
end

--- Rewrites a cell built by cell_def in place.
local function cell_update(col, cell, v, width, scope)
	local kind = col.kind
	if kind == "station" then
		local st = v.st
		local name = st and st.name or NO_VALUE
		local parts = st and st.name_parts
		local inner = v.tag and width - TAG_W or width
		local had = cell[TAG] ~= nil
		name_cell.update(cell, parts, name, { kind = st and "station" or nil, id = st and v.id or nil }, inner,
			v.tooltip or "", scope)
		local tag = cell[TAG]
		if v.tag then
			if tag then
				tag.caption = v.tag
				tag.tooltip = v.tooltip
			else
				gui.add(cell, tag_def(v, scope))
			end
		elseif tag then
			tag.destroy()
		end
		-- A row that gains or loses its tag in place (position-keyed rows show another station after a re-sort) moves
		-- the name's width; a rebuilt name cell was already given it.
		if had ~= (v.tag ~= nil) then
			name_cell.resize(cell, parts, inner)
			cell.style.width = width
		end
	elseif kind == "train" then
		cell.caption = v.caption
		cell.tooltip = v.tooltip
		local t = cell.tags
		t.id = v.id
		cell.tags = t
	elseif kind == "chip" then
		local button = cell.children[1]
		local style = label_style(v.style)
		if button.style.name ~= style then
			button.style = style
			button.style.maximal_width = width
		end
		button.caption = v.caption or ""
		button.tooltip = v.tooltip
		button.visible = v.visible ~= false
	elseif kind == "status" then
		local children = cell.children
		children[1].sprite = v.sprite
		children[2].caption = v.caption
		children[2].tooltip = v.tooltip
	else
		cell.caption = v.caption
		cell.tooltip = v.tooltip
	end
end

--- A row entry for sync.sync_table_rows: `values()` builds the cells' values only when the row's sig changed, and a
--- cell is written only when its own sig (`value.sig`) differs from the one memorised for that row position.
--- @param t string
--- @param key int row position
--- @param sig string
--- @param values fun(): table[]
--- @param ctx table widths and the per-table memo (render state, dropped on close)
local function row_entry(t, key, sig, values, ctx)
	local cols = COLUMNS[t]
	local scope = table_name(t)
	local widths = ctx.widths
	local memo = ctx.memo[t]
	return {
		key = key,
		sig = sig,
		build = function()
			local vals = values()
			local defs, sigs = {}, {}
			for i, col in ipairs(cols) do
				defs[i] = cell_def(col, vals[i], col.width or widths[t], scope)
				sigs[i] = vals[i].sig
			end
			-- wait_clock finds the cell by name: reading tbl.children would wrap every cell of up to MAX_ROWS rows.
			if t == "requesters" then defs[WAIT_COLUMN].name = wait_name(key) end
			memo[key] = sigs
			return defs
		end,
		update = function(cells)
			local vals = values()
			local sigs = get_or_create(memo, key)
			for i, col in ipairs(cols) do
				local v = vals[i]
				if v.sig == nil or sigs[i] ~= v.sig then
					cell_update(col, cells[i], v, col.width or widths[t], scope)
					sigs[i] = v.sig
				end
			end
		end,
	}
end

local function count(n)
	return format_signal_count(n)
end

--- @param r ItemProviderRow
--- @param i int position: rows are keyed by position, so a re-sort rewrites cells instead of rebuilding rows
local function provider_entry(r, ctx, i)
	local st = station_view(ctx.snapshot, r.id)
	local name = st and st.name or ""
	local status = pm.shown_status(r.status, r.id, st and st.lint, diag.is_acked)
	local sig = table.concat({ name, r.priority, r.stock, tostring(r.threshold), r.out, status }, "|")
	local net_sig = network_sig(r, st)
	-- A station with several inventories has one row per inventory, so the inventory is part of the row's identity.
	return row_entry("providers", i, r.key .. "@" .. net_sig .. "#" .. sig, function()
		local network, tag = row_network(r, st)
		return {
			{ st = st, id = r.id, tooltip = station_tooltip(st, { "cybersyn-gui.item-network", network }), tag = tag,
				sig = name .. "\1" .. r.id .. "\1" .. net_sig },
			{ caption = tostring(r.priority), tooltip = { "cybersyn-gui.item-provider-priority-tooltip" },
				sig = tostring(r.priority) },
			{ caption = count(r.stock), tooltip = format.number(r.stock), sig = tostring(r.stock) },
			r.threshold and { caption = count(r.threshold), tooltip = format.number(r.threshold), sig = tostring(r.threshold) }
				or { caption = NO_VALUE, tooltip = { "cybersyn-gui.item-threshold-none-tooltip" }, sig = "-" },
			{ caption = r.out > 0 and count(r.out) or NO_VALUE, sig = tostring(r.out) },
			{
				sprite = "flib_indicator_" .. (STATUS_COLOR[status] or "white"),
				caption = { status_key(status) },
				tooltip = { status_key(status) .. "-tooltip" },
				sig = status,
			},
		}
	end, ctx)
end

--- @param r ItemRequesterRow
--- @param i int
local function requester_entry(r, ctx, i)
	local st = station_view(ctx.snapshot, r.id)
	local name = st and st.name or ""
	local now = ctx.now
	local e = ctx.entries and ctx.ix and ctx.entries[r.id] and ctx.entries[r.id][ctx.ix] or nil
	local acked = e and diag.is_acked("request", r.id, ctx.hash) ~= nil or false
	local wait = r.wait_start and now - r.wait_start or nil
	local age = st and collector.delivery_age(st) or nil
	local network = network_sig(r, st)
	local inherited = e and e.first_tick < ctx.inherit_before or false
	local lost = e and e.lost_n > 0 and e.lost_to and station_view(ctx.snapshot, e.lost_to) or nil
	-- The wait caption has its own clock (wait_clock); the tooltips' ages move in steps, so a steady row is not
	-- rewritten every update. The evaluation count in the chip's tooltip refreshes with that step too.
	local e_sig = e and table.concat({ e.reason, e.a, e.b, acked and "a" or "", inherited and "i" or "",
		math.floor((now - e.first_tick) / text.READ_STEP), table.concat(e.rej, ","), tostring(e.lost_to), e.lost_n,
		lost and lost.name or "" }, "\1") or ""
	local sig = table.concat({
		name, network, r.requested, r.threshold, r.priority, r.group, tostring(r.position), r.incoming, wait and 1 or 0,
		age and math.floor(age / AGE_STEP) or -1, e_sig,
	}, "|")
	local age_step = age and math.floor(age / AGE_STEP) or -1
	local station_sig = table.concat({ name, r.id, tostring(r.position), r.priority, r.group, age_step, network }, "\1")
	-- The chip's tooltip names the requester and its network, so they are part of its sig: rows are keyed by position.
	local chip_sig = table.concat({ r.id, name, network, r.group, r.requested, e_sig, e and e.n or "" }, "\1")
	return row_entry("requesters", i, r.key .. "@" .. network .. "#" .. sig, function()
		local network_tip, tag = row_network(r, st)
		local last = age and { "cybersyn-gui.time-ago", logic.short_duration(age - age % AGE_STEP) }
			or { "cybersyn-gui.item-last-served-never" }
		local queue
		if r.position then
			queue = { "cybersyn-gui.item-queue-position", tostring(r.position), tostring(r.priority), last }
		else
			queue = { "cybersyn-gui.item-queue-skipped", { "cybersyn-gui.item-group-" .. item_model.GROUP_KEYS[r.group] },
				tostring(r.priority), last }
		end
		local chip
		if e then
			local reason = e.reason
			chip = {
				sig = chip_sig,
				caption = text.chip_caption(reason),
				style = acked and "cybersyn_chip_acked" or text.chip_style(reason),
				tooltip = text.chip_tooltip({
					item = ctx.item_tooltip,
					requested = r.requested,
					requester = name,
					reason = reason,
					a = e.a,
					b = e.b,
					network = network_tip,
					rej = e.rej,
					wait = now - e.first_tick,
					inherited = inherited,
					n = e.n,
					surface_name = ctx.surface_name,
				}),
			}
			if lost then
				local tip = chip.tooltip
				tip[#tip + 1] = "\n"
				tip[#tip + 1] = { "cybersyn-diag.lost-priority", lost.name, tostring(e.lost_n) }
			end
		elseif r.group ~= item_model.QUEUED then
			local key = item_model.GROUP_KEYS[r.group]
			chip = { caption = { "cybersyn-gui.item-group-" .. key }, tooltip = { "cybersyn-gui.item-group-" .. key .. "-tooltip" },
				sig = chip_sig }
		else
			chip = { visible = false, sig = chip_sig }
		end
		return {
			{ st = st, id = r.id, tooltip = station_tooltip(st, { "", queue, "\n",
				{ "cybersyn-gui.item-network", network_tip } }), tag = tag, sig = station_sig },
			{ caption = tostring(r.priority), tooltip = { "cybersyn-gui.item-priority-tooltip" }, sig = tostring(r.priority) },
			{ caption = count(r.requested), tooltip = format.number(r.requested), sig = tostring(r.requested) },
			{ caption = count(r.threshold), tooltip = format.number(r.threshold), sig = tostring(r.threshold) },
			-- The seconds are wait_clock's; this cell is written when the row gains or loses a wait.
			{ caption = wait and logic.short_duration(wait) or NO_VALUE,
				tooltip = wait and { "cybersyn-gui.waiting-for", logic.format_duration(wait) } or { "cybersyn-gui.item-wait-none" },
				sig = wait and "w" or "-" },
			chip,
			{ caption = r.incoming > 0 and count(r.incoming) or NO_VALUE, sig = tostring(r.incoming) },
		}
	end, ctx)
end

--- @param r ItemTrainRow
--- @param i int
local function train_entry(r, ctx, i)
	local to = station_view(ctx.snapshot, r.to)
	local from = station_view(ctx.snapshot, r.from)
	local sig = table.concat({ r.status or -1, r.amount, to and to.name or "", from and from.name or "" }, "|")
	return row_entry("trains", i, r.id .. "#" .. sig, function()
		local chip = logic.train_chip(r.status)
		local status = chip and { logic.train_chip_locale(chip, false) } or { "cybersyn-gui.trains-custom-status", tostring(r.status) }
		local status_tip = chip and { logic.train_chip_locale(chip, false) .. "-tooltip" } or nil
		local route = { "cybersyn-gui.item-train-route", from and from.name or NO_VALUE, to and to.name or NO_VALUE }
		local route_sig = (from and from.name or "") .. "\1" .. (to and to.name or "")
		return {
			{ caption = tostring(r.id), id = r.id, tooltip = { "", { "cybersyn-gui.item-train-tooltip", tostring(r.id) }, "\n",
				route, "\n", links.LINK_FOOTER }, sig = r.id .. "\1" .. route_sig },
			{ caption = status, tooltip = status_tip, sig = tostring(r.status) },
			{ caption = count(r.amount), tooltip = format.number(r.amount), sig = tostring(r.amount) },
			{ st = to, id = r.to, tooltip = station_tooltip(to, route), sig = tostring(r.to) .. "\1" .. route_sig },
		}
	end, ctx)
end

local ENTRY = { providers = provider_entry, requesters = requester_entry, trains = train_entry }

--- The Wait column of the shown requester rows: one caption write per row whose seconds moved, every update for the
--- unscrolled viewport's rows and CLOCK_ROWS of the others in turn (a scrolled-to clock steps a few seconds at a time,
--- as the Log's ages do).
--- @param tbl LuaGuiElement
--- @param rows ItemRequesterRow[] the model rows the table shows (the previous pass's while its rewrite waits)
--- @param n int rows built
--- @param view int rows of the unscrolled viewport
--- @param from int? first row below the viewport to write in this update
--- @param now uint
--- @return int? where the next update continues below the viewport
local function wait_clock(tbl, rows, n, view, from, now)
	local function write(i)
		local start = rows[i] and rows[i].wait_start
		if not start then return end
		local cell = tbl[wait_name(i)]
		local caption = logic.short_duration(now - start)
		if cell and cell.caption ~= caption then
			cell.caption = caption
			cell.tooltip = { "cybersyn-gui.waiting-for", logic.format_duration(now - start) }
		end
	end
	for i = 1, math.min(n, view) do write(i) end
	if n <= view then return nil end
	if not from or from > n or from <= view then from = view + 1 end
	local last = math.min(n, from + CLOCK_ROWS - 1)
	for i = from, last do write(i) end
	return last + 1
end

local function set_caption(elem, caption)
	if elem and elem.valid then elem.caption = caption end
end

--- The subheader: icon, name, totals and delivered in the Overview's period, written when one of them changed.
--- @param player_data PlayerData
--- @param cache ItemCache
local function render_header(player_data, cache)
	local refs = player_data.cache.item_refs
	local m = cache.model
	local hash = m.hash
	local period = get_period(player_data)
	local minute = math.floor(game.tick / 3600)
	local dkey = period .. ":" .. minute
	if cache.delivered_key ~= dkey then
		cache.delivered_key = dkey
		cache.delivered = util.delivered_items(player_data, period)[hash] or 0
	end
	local t = m.totals
	local collecting = collector.collecting_note()
	local percent = collecting and math.floor(collecting * 100) or -1
	local station = player_data.filters.station
	local station_record = station and storage.stations[station]
	local stop = station_record and station_record.entity_stop
	local station_name = stop and stop.valid and stop.backer_name or nil
	local sig = table.concat({ hash, t.provided, t.provided_stations, t.in_transit, t.in_transit_stations, t.requested,
		t.requested_stations, cache.delivered, period, percent, m.filtered and 1 or 0, station or "", station_name or "" },
		"|")
	if cache.header_sig == sig then return end
	cache.header_sig = sig
	local chip_flow = refs.item_station_chip_flow
	if chip_flow and chip_flow.valid then
		chip_flow.visible = station ~= nil
		local chip = refs.item_station_chip
		if station and chip and chip.valid then
			chip.caption = { "cybersyn-gui.station-chip", station_name or "?", tostring(station) }
			chip.tooltip = { "cybersyn-gui.station-chip-tooltip" }
			refs.item_station_chip_icon.tooltip = { "cybersyn-gui.station-chip-tooltip" }
		end
	end
	local sprite, quality, _, _, item_name = util.item_sprite_and_tooltip(hash)
	local icon = refs.item_icon
	if icon and icon.valid then
		icon.sprite = sprite
		icon.quality = quality
		icon.elem_tooltip = util.elem_tooltip(hash)
		icon.tooltip = { "cybersyn-gui.item-icon-tooltip" }
		local tags = icon.tags
		tags.kind, tags.id = "item", hash
		icon.tags = tags
	end
	set_caption(refs.item_name, item_name or hash)
	local function total(name, key, value, stations, tooltip_key, note)
		local elem = refs["item_total_" .. name]
		if not (elem and elem.valid) then return end
		elem.caption = { "cybersyn-gui.item-" .. key, count(value) }
		local tooltip = stations and { tooltip_key or "cybersyn-gui.item-total-tooltip", format.number(value),
			tostring(stations) } or nil
		if tooltip and note then tooltip = { "", tooltip, "\n", note } end
		elem.tooltip = tooltip
	end
	-- Stock only; the Providers table also lists stations a loading train emptied, so its "n of m" can count more.
	total("provided", "provided", t.provided, t.provided_stations, "cybersyn-gui.item-provided-tooltip")
	total("in_transit", "in-transit", t.in_transit, t.in_transit_stations)
	-- Active requests only (the Inventory's figure); the Requesters table also lists those below threshold and the
	-- stops the dispatcher skips, so its "n of m" counts more stations. The tooltip says which.
	-- The Overview's marker for the same place filters; its wording names the requesting station, so only here.
	total("requested", "requested", t.requested, t.requested_stations, "cybersyn-gui.item-requested-tooltip",
		m.filtered and { "cybersyn-gui.overview-filtered-requester" } or nil)
	local delivered = refs.item_total_delivered
	if delivered and delivered.valid then
		delivered.caption = { "cybersyn-gui.item-delivered", { "cybersyn-gui.item-period-" .. period }, count(cache.delivered) }
		delivered.tooltip = { "cybersyn-gui.item-delivered-tooltip", format.number(cache.delivered),
			{ "cybersyn-gui.item-period-" .. period } }
	end
	local note = refs.item_collecting
	if note and note.valid then
		note.visible = collecting ~= nil
		note.caption = collecting and { "cybersyn-gui.collecting-progress", tostring(percent) } or ""
	end
end

--- Body heights from the row split, written only when the split changed.
--- @param refs table
--- @param alloc {[string]: int}
local function apply_alloc(refs, alloc)
	for _, t in ipairs(item_model.TABLES) do
		local rows = alloc[t]
		local body = refs["item_" .. t .. "_body"]
		if body and body.valid then body.style.height = HEADER + rows * ROW end
		local scroll = refs["item_" .. t .. "_scroll"]
		if scroll and scroll.valid then scroll.style.height = rows * ROW end
		local empty = refs["item_" .. t .. "_empty_flow"]
		if empty and empty.valid then empty.style.height = rows * ROW end
	end
end

--- The filters the drill-down applies: every manager filter but the item (it is the item) and the station search (a
--- query typed on another tab would hide rows invisibly): network name, network ID, surface and the station chip.
--- @param player_data PlayerData
--- @return ManagerFilters
local function view_filters(player_data)
	local f = filters.get(player_data, "inventory_tab")
	f.terms, f.item = nil, nil
	return f
end

--- @param player_data PlayerData
--- @return ItemCache
--- @return boolean refreshed the model was (re)built in this call: for a new collector pass, a new item or a new view
local function get_cache(player_data, hash)
	local snapshot = collector.get()
	local f = view_filters(player_data)
	local filtered = filters.filters_active(f, true)
	local key = tostring(snapshot.tick) .. ":" .. tostring(snapshot.pass) .. ":" .. filters.filter_signature(f)
	local cache = player_data.cache.item
	if cache and cache.hash == hash and cache.key == key then return cache, false end
	local row_passes, train_passes = filters.row_passes, filters.train_passes
	local keep = filtered and {
		row = function(row) return row_passes(row, f, true) end,
		train = function(tr) return train_passes(tr, f, true) end,
	} or nil
	-- Records the running pass refilled since the snapshot completed may name the item where the snapshot's index
	-- does not (the Stations tab, filtered to the item, reads those records too).
	local m = item_model.build(snapshot, hash, SIGNAL_PRIORITY, collector.changed_this_pass(), keep, collector.inventories)
	m.empty_suffix = filters.empty_filter_suffix(f)
	if cache and cache.hash == hash then
		cache.key, cache.model, cache.header_sig = key, m, nil
		return cache, true
	end
	cache = { hash = hash, key = key, model = m }
	player_data.cache.item = cache
	return cache, true
end

--- Renders the drill-down of `hash` in the Inventory's content, building its elements first when they are not there.
--- False when it cannot (no layout or content yet), so the Inventory renders its grids instead.
--- @param map_data MapData
--- @param player_data PlayerData
--- @param hash string
--- @return boolean rendered
function item.build(map_data, player_data, hash)
	if not ensure_view(player_data, hash) then return false end
	local view = player_data.cache.item_view
	local refs = player_data.cache.item_refs
	local cache, refreshed = get_cache(player_data, view.hash)
	local m = cache.model
	-- A new pass rebuilds the model in this update and rewrites the rows in the next ones, so neither update pays
	-- for both (budget: 2 ms per update). The header's totals follow with the rows, so header and rows always
	-- show the same pass (only a drill-down that never showed a header gets it at once).
	if not refreshed or not cache.header_sig then render_header(player_data, cache) end
	if refreshed then return true end
	local layout = player_data.layout
	local total = layout.rows_by_tab[TAB]

	-- A table under the cursor keeps its rows as they are (the hover hold); new data waits until the cursor leaves.
	local held, any_held = {}, false
	for _, t in ipairs(item_model.TABLES) do
		local name = table_name(t)
		local state = sync.gui_state(player_data, name)
		held[t] = state.keys ~= nil and #state.keys > 0 and hover.hold_active(player_data, name)
		any_held = any_held or held[t]
	end
	-- A new split changes the three body heights at once, so every table follows it in the same update; it waits
	-- while a table is held.
	local alloc = item_model.split_rows(total, { providers = #m.providers, requesters = #m.requesters, trains = #m.trains })
	local asig = total .. ":" .. alloc.providers .. ":" .. alloc.requesters .. ":" .. alloc.trains
	local forced = false
	if cache.alloc_sig ~= asig and (not any_held or not cache.alloc) then
		cache.alloc_sig = asig
		cache.alloc = alloc
		apply_alloc(refs, alloc)
		forced = true
	end
	alloc = cache.alloc

	local snapshot = collector.get()
	local d = storage.diag
	local hash = view.hash
	local _, _, item_tip = util.item_sprite_and_tooltip(hash)
	local ctx = {
		snapshot = snapshot,
		now = game.tick,
		hash = hash,
		widths = player_data.tabs.inventory_tab.item_widths or flex_widths(layout.content_width),
		entries = d and d.unserved,
		ix = d and d.item_ix[hash],
		inherit_before = d and diag.inherit_threshold(d) or 0,
		item_tooltip = item_tip,
		surface_name = util.surface_name,
	}
	ctx.memo = {}
	for _, t in ipairs(item_model.TABLES) do
		local state = sync.gui_state(player_data, table_name(t))
		-- The cell memo belongs to the rows the state's keys describe; without keys the rows are rebuilt anyway.
		if not (state.cells and state.keys) then state.cells = {} end
		ctx.memo[t] = state.cells
	end
	-- First every table's rewrite and its viewport's new rows (WRITE_BUDGET), then rows below the viewports
	-- (FILL_ROWS); each table is synced once.
	local budget, wrote, waiting = WRITE_BUDGET, false, false
	local full_left = FULL_CHECK
	local plan = {}
	for _, t in ipairs(RENDER_ORDER) do
		local rows = m[t]
		local n = math.min(#rows, MAX_ROWS)
		local name = table_name(t)
		local tbl = refs[name]
		local state = sync.gui_state(player_data, name)
		if tbl and tbl.valid then
			local built = state.keys and #state.keys or 0
			local sigs = state.keys and state.sigs
			local view_n = math.min(n, alloc[t])
			local to = math.min(n, built)
			local make = ENTRY[t]
			-- A table that does not show this pass yet (stale) is signed whole, so that it is rewritten whole; stale
			-- tables past the first wait for the next update when they would take it past FULL_CHECK signed rows. A
			-- held one is signed once per pass: what it found waits for the hold to end.
			local stale = not sigs or state.model_key ~= cache.key
			local held_skip = held[t] and stale and state.held_key == cache.key
			local skip = held_skip or (stale and full_left < to and full_left < FULL_CHECK)
			local entries, changed = {}, 0
			local function sign(i)
				local entry = make(rows[i], ctx, i)
				if not (sigs and sigs[i] == entry.sig) then changed = changed + 1 end
				entries[i] = entry
			end
			local next_check
			if skip then
				-- nothing signed
			elseif stale then
				for i = 1, to do sign(i) end
				full_left = full_left - to
			else
				for i = 1, math.min(view_n, to) do sign(i) end
				-- Below the viewport only Requesters' sigs move between passes (wait, reason, acks, last delivery):
				-- CHECK_ROWS of them are signed in turn, and the window stops at its WINDOW_WRITES-th changed row, so
				-- rows nobody may be looking at never take an update's whole budget.
				if t == "requesters" and to > view_n then
					local i = state.check
					if not i or i > to or i <= view_n then i = view_n + 1 end
					local stop, writes = i + CHECK_ROWS, 0
					while i <= to and i < stop and writes < WINDOW_WRITES do
						local before = changed
						sign(i)
						if changed > before then writes = writes + 1 end
						i = i + 1
					end
					next_check = i
				end
				for i = view_n + 1, to do
					if not entries[i] then
						-- Keeps its sig; built from the current model if the table ever has to be rebuilt.
						entries[i] = { key = i, sig = sigs[i], build = function() return make(rows[i], ctx, i).build() end }
					end
				end
			end
			-- A held table may only grow below rows that all still match the model: nothing under the cursor is
			-- rewritten, and a player who hovers a list as soon as it opens still gets the rest of it.
			local open = not skip and (not held[t] or (changed == 0 and n >= built))
			if skip then
				if not held_skip then waiting = true end
			elseif open and (changed == 0 or forced or not wrote or changed <= budget) then
				budget = budget - changed
				wrote = wrote or changed > 0
				local keep = built
				if keep < view_n then
					local room = math.max(0, math.floor(budget / BUILD_COST))
					if not wrote and room == 0 then room = 1 end
					keep = math.min(view_n, built + room)
					budget = budget - (keep - built) * BUILD_COST
					wrote = wrote or keep > built
				end
				-- The window moves on only once its rows were synced: a change found in it waits there for its rewrite.
				if next_check then state.check = next_check end
				plan[#plan + 1] = { t = t, tbl = tbl, state = state, rows = rows, n = n, entries = entries, make = make,
					keep = math.min(keep, n), view_n = view_n, built = built }
			else
				if held[t] then
					state.held_key = stale and cache.key or nil
				else
					waiting = waiting or changed > 0
				end
			end
		end
	end
	local fold = waiting and 0 or FILL_ROWS
	for _, p in ipairs(plan) do
		fold = fold - math.max(0, p.keep - p.built)
		-- Every viewport first: on a short layout one table's viewport fills within the budget while another's is still
		-- waiting for rows, and the rows nobody sees must not go before those.
		if p.keep < p.view_n then fold = 0 end
	end
	for _, p in ipairs(plan) do
		local keep, n = p.keep, p.n
		if keep >= p.view_n and keep < n and fold > 0 then
			local more = math.min(n - keep, fold)
			fold = fold - more
			keep = keep + more
		end
		local entries = p.entries
		-- New rows are signed only once it is known how many this update keeps.
		for i = p.built + 1, keep do entries[i] = p.make(p.rows[i], ctx, i) end
		sync.sync_table_rows(p.tbl, #COLUMNS[p.t], 0, entries, p.state)
		p.state.shown, p.state.shown_n = p.rows, n
		p.state.model_key = cache.key
		p.state.held_key = nil
	end
	for _, t in ipairs(RENDER_ORDER) do
		local name = table_name(t)
		local tbl = refs[name]
		local state = sync.gui_state(player_data, name)
		-- Wait clock, count and empty state follow the rows the table shows, not the model it may not show yet.
		local shown = state.shown
		if t == "requesters" and shown and tbl and tbl.valid then
			state.clock = wait_clock(tbl, shown, math.min(state.keys and #state.keys or 0, state.shown_n), alloc.requesters,
				state.clock, ctx.now)
		end
		local empty = refs["item_" .. t .. "_empty_flow"]
		local show_empty = shown ~= nil and #shown == 0
		if empty and empty.valid and empty.visible ~= show_empty then empty.visible = show_empty end
		-- With place filters or the station chip set, "No station provides this item" would deny stations the
		-- filters merely hide.
		local label = refs["item_" .. t .. "_empty_label"]
		local suffix = m.empty_suffix or ""
		if label and label.valid and state.empty_suffix ~= suffix then
			state.empty_suffix = suffix
			label.caption = { "cybersyn-gui.item-empty-" .. t .. suffix }
		end
		local c = refs["item_" .. t .. "_count"]
		local capped = shown ~= nil and #shown > state.shown_n
		local csig = shown and (state.shown_n .. "/" .. #shown) or ""
		if c and c.valid and state.count_sig ~= csig then
			state.count_sig = csig
			-- "n of m" only when the table stops at MAX_ROWS; otherwise every row is there to scroll to.
			c.caption = not shown and "" or capped and { "cybersyn-gui.item-count", tostring(state.shown_n), tostring(#shown) }
				or tostring(#shown)
		end
	end
	return true
end

--- Recomputes the flexible column widths after a layout change; rows built for other widths are rebuilt.
--- @param player_data PlayerData
--- @param layout ManagerLayout
function item.apply_layout(player_data, layout)
	local widths = flex_widths(layout.content_width)
	local old = player_data.tabs.inventory_tab.item_widths
	player_data.tabs.inventory_tab.item_widths = widths
	local cache = player_data.cache.item
	if cache then cache.alloc_sig = nil end
	local refs = player_data.cache.item_refs
	if not refs or (old and old.providers == widths.providers) then return end
	for _, t in ipairs(item_model.TABLES) do
		local tbl = refs[table_name(t)]
		if tbl and tbl.valid then tbl.clear() end
		local header = refs["item_" .. t .. "_header"]
		if header and header.valid then
			local children = header.children
			for i, col in ipairs(COLUMNS[t]) do
				if not col.width then children[i].style.width = widths[t] end
			end
		end
		local state = sync.gui_state(player_data, table_name(t))
		state.keys, state.sigs = nil, nil
	end
end

-- ---------------------------------------------------------------- handlers

item.handle = {}

item.wrapper = util.wrapper

--- Back clears the item filter, as the filter chip's x does: the Inventory shows its grids again.
function item.handle.item_back(player, player_data, refs, e)
	filters.set(player_data, "item", nil)
	nav.rerender(player, player_data)
end

--- The station chip in the drill-down's subheader: any click removes it, as on the tab subheader's chip.
function item.handle.item_station_chip(player, player_data, refs, e)
	filters.set(player_data, "station", nil)
	nav.rerender(player, player_data)
end

gui.add_handlers(item.handle, item.wrapper)

return item
