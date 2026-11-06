-- Inventory: the provided, in-transit and requested grids, aggregated from the collector's snapshot. On a large base a
-- completed pass reaches the grid over a few renders (the totals wait one render, then the buttons change a budget
-- per render), so for those renders the grid mixes old and new counts.

local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local sync = require("scripts.gui.utils.sync")
local filters = require("scripts.gui.utils.filters")
local listing = require("scripts.gui.utils.listing")
local hover = require("scripts.gui.utils.hover")
local links = require("scripts.gui.utils.links")
local nav = require("scripts.gui.utils.nav")
local format = require("__flib__.format")
local collector = require("scripts.gui.collector")
local stats = require("scripts.stats")
local logic = require("scripts.gui.tab-logic")

local inventory_tab = {}

local TAB = "inventory_tab"
local GRIDS = { "provided", "in_transit", "requested" }
local GRID_GAP = 12
-- Scroll bar and frame borders inside a grid.
local GRID_INNER = 16
local SLOT_ROW = 40
local TOP_N = 5
local WAIT_SIG_TICKS = 600
-- A completed pass changes a few hundred buttons on a large base; each costs 40-60 us (tooltip rebuild plus
-- API writes), so they are spread over renders rather than landing on one tick.
local BACKGROUND_UPDATE_BUDGET = 60
-- Below this a whole refresh is cheap, and a pass may complete on every render, which spreading would starve.
local SPREAD_MIN_STATIONS = 300

local DEFAULT_SORT = "item_order"
-- Engineers look for the biggest numbers first; item order reads naturally top-down; the largest shortage first.
local DEFAULT_ASCENDING = { item_order = true, amount = false, stations = false, wait = false, deficit = false }
local GRID_SORTS = {
	provided = { "item_order", "amount", "stations" },
	in_transit = { "item_order", "amount", "stations" },
	requested = { "item_order", "amount", "stations", "wait", "deficit" },
}
local SORT_SPRITE = {
	item_order = "utility/list_view",
	stations = "item/train-stop",
	wait = "utility/clock",
	deficit = "virtual-signal/signal-alert",
}
-- Without a fitting sprite the button shows a caption instead.
local SORT_CAPTION = { amount = "#" }

local function grid_table_name(grid)
	return "inventory_" .. grid .. "_table"
end

--- @param grid string
--- @param column string
--- @return flib.GuiElemDef
local function sort_button(grid, column)
	local locale = string.gsub(column, "_", "-")
	local def = {
		type = "button",
		name = "inventory_" .. grid .. "_sort_" .. column,
		style = "cybersyn_sort_tool_button",
		tooltip = { "cybersyn-gui.inventory-sort-" .. locale .. "-tooltip" },
		tags = { grid = grid, column = column },
		handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_grid_sort_click },
	}
	local sprite = SORT_SPRITE[column]
	if sprite then
		def.type = "sprite-button"
		def.sprite = sprite
	else
		def.caption = SORT_CAPTION[column] or column
	end
	return def
end

--- @param grid string
local function grid_def(grid)
	local locale = string.gsub(grid, "_", "-")
	local header = {
		type = "frame",
		name = "inventory_" .. grid .. "_header_frame",
		style = "cybersyn_inventory_grid_header",
		{
			type = "label",
			name = "inventory_" .. grid .. "_header",
			style = "subheader_caption_label",
			caption = { "cybersyn-gui." .. locale },
			tooltip = { "cybersyn-gui.inventory-" .. locale .. "-legend" },
		},
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
	}
	if grid == "provided" then
		header[#header + 1] = {
			type = "sprite-button",
			name = "inventory_dim_button",
			style = "cybersyn_sort_tool_button",
			sprite = "virtual-signal/signal-ghost",
			tooltip = { "cybersyn-gui.inventory-dim-tooltip" },
			handler = { [defines.events.on_gui_click] = inventory_tab.handle.on_dim_click },
		}
	end
	for _, column in ipairs(GRID_SORTS[grid]) do
		header[#header + 1] = sort_button(grid, column)
	end
	return {
		type = "frame",
		name = "inventory_" .. grid .. "_frame",
		direction = "vertical",
		style = "cybersyn_inventory_grid_frame",
		header,
		{
			type = "scroll-pane",
			name = "inventory_" .. grid .. "_scroll",
			style = "ltnm_slot_table_scroll_pane",
			style_mods = { horizontally_stretchable = true },
			vertical_scroll_policy = "auto-and-reserve-space",
			{
				type = "table",
				name = grid_table_name(grid),
				style = "slot_table",
				column_count = 9,
			},
		},
	}
end

function inventory_tab.create()
	return {
		tab = {
			name = "manager_inventory_tab",
			type = "tab",
			caption = { "cybersyn-gui.inventory" },
		},
		content = {
			name = "manager_inventory_content_frame",
			type = "flow",
			direction = "vertical",
			-- Its height and the grids' slot rows come from the window layout (inventory_tab.apply_layout).
			style_mods = { vertical_spacing = 0 },
			{
				name = "inventory_empty_flow",
				type = "flow",
				style = "ltnm_warning_flow",
				visible = false,
				{
					name = "inventory_empty_label",
					type = "label",
					style = "ltnm_semibold_label",
				},
			},
			{
				name = "inventory_grids_flow",
				type = "flow",
				direction = "horizontal",
				style_mods = { horizontal_spacing = GRID_GAP, top_margin = GRID_GAP },
				grid_def("provided"),
				grid_def("in_transit"),
				grid_def("requested"),
			},
		},
	}
end

--- Grid width and slot columns for a tab content width: three grids share the width evenly, 12 px apart.
--- @param cw int
--- @return int width
--- @return int columns
local function grid_size(cw)
	local width = math.floor((cw - 2 * GRID_GAP) / 3)
	return width, math.max(4, math.floor((width - GRID_INNER) / SLOT_ROW))
end

--- Recreates a grid's table when its column count must change (column_count is fixed at creation).
--- @param player_data PlayerData
--- @param grid string
--- @param columns int
local function ensure_columns(player_data, grid, columns)
	local refs = player_data.refs
	local name = grid_table_name(grid)
	local tbl = refs[name]
	if not (tbl and tbl.valid) or tbl.column_count == columns then return end
	local pane = tbl.parent
	tbl.destroy()
	local _, new = gui.add(pane, { type = "table", name = name, style = "slot_table", column_count = columns })
	refs[name] = new
	local state = sync.gui_state(player_data, name)
	state.keys, state.sigs, state.render_sig, state.dirty = nil, nil, nil, nil
end

--- Whole slot rows: each grid's scroll pane shows exactly the layout's row count; the grids share the width.
--- @param player_data PlayerData
--- @param layout ManagerLayout
function inventory_tab.apply_layout(player_data, layout)
	local rows = layout.rows_by_tab[TAB]
	local width, columns = grid_size(layout.content_width)
	for _, grid in ipairs(GRIDS) do
		local frame = player_data.refs["inventory_" .. grid .. "_frame"]
		if frame and frame.valid then frame.style.width = width end
		local pane = player_data.refs["inventory_" .. grid .. "_scroll"]
		if pane and pane.valid then pane.style.height = rows * SLOT_ROW end
		ensure_columns(player_data, grid, columns)
	end
end

--- Gives the tab's content to the item drill-down, which item.lua adds to the same content frame with a subheader
--- of its own, or takes it back: the tab's subheader, empty note and grids hide while an item filter is set. Back, the
--- grids show and the next render's empty check decides between them and the note.
--- @param player_data PlayerData
--- @param drill boolean
function inventory_tab.set_drill_down(player_data, drill)
	local state = sync.gui_state(player_data, "inventory_drill_down")
	if state.drill == drill then return end
	state.drill = drill
	local refs = player_data.refs
	for _, name in ipairs({ TAB .. "_subheader", "inventory_empty_flow", "inventory_grids_flow" }) do
		local elem = refs[name]
		if elem and elem.valid then elem.visible = not drill and name ~= "inventory_empty_flow" end
	end
end

--- Keeps the TOP_N largest entries in a flat {mag, id, name, mag, id, name, ...} list, ties broken by station id
--- so the list does not depend on station iteration order.
--- @param top table
--- @param mag number
--- @param id uint
--- @param name string
local function top_insert(top, mag, id, name)
	local n = #top / 3
	if n == TOP_N then
		local last_mag = top[TOP_N * 3 - 2]
		if mag < last_mag or (mag == last_mag and id > top[TOP_N * 3 - 1]) then return end
	end
	local pos = n + 1
	for i = 1, n do
		local m, other = top[i * 3 - 2], top[i * 3 - 1]
		if mag > m or (mag == m and id < other) then
			pos = i
			break
		end
	end
	if pos > TOP_N then return end
	local last = math.min(n, TOP_N - 1)
	for i = last, pos, -1 do
		local b = i * 3
		top[b + 1], top[b + 2], top[b + 3] = top[b - 2], top[b - 1], top[b]
	end
	local b = pos * 3
	top[b - 2], top[b - 1], top[b] = mag, id, name
end

--- @param bucket table
--- @param top_bucket table
--- @param hash string
--- @param count int signed amount added to the total
--- @param mag number magnitude used to rank the station
--- @param st SnapshotStation
local function accumulate(bucket, top_bucket, hash, count, mag, st)
	local agg = bucket[hash]
	if agg then
		agg.count = agg.count + count
		agg.stations = agg.stations + 1
	else
		agg = { count = count, stations = 1 }
		bucket[hash] = agg
	end
	local top = top_bucket[hash]
	if not top then
		top = {}
		top_bucket[hash] = top
	end
	top_insert(top, mag, st.id, st.name)
	return agg
end

--- The per-network sums the deficit is computed from: r = requested, t = incoming deliveries, s = provider stock
--- not yet promised (provider signals plus their negative, outgoing deliveries).
--- @param nets table
--- @param name string
local function net_bucket(nets, name)
	local nb = nets[name]
	if not nb then
		nb = { r = {}, t = {}, s = {} }
		nets[name] = nb
	end
	return nb
end

--- The networks an inventory row's numbers count on: the filter's network, its own, or for a row on several networks
--- (the each-network) each of them for its stock (it can supply any) and the first by name for its requests (counted
--- once).
--- @param nets table
--- @param row SnapshotInventory
--- @param network string? the network filter
--- @return table request_bucket
--- @return table[]? stock_buckets nil = the request bucket alone
local function row_buckets(nets, row, network)
	if network then return net_bucket(nets, network), nil end
	local name = row.network_name
	local networks = row.networks
	if name ~= NETWORK_EACH or type(networks) ~= "table" then return net_bucket(nets, name or ""), nil end
	local names = {}
	for n in pairs(networks) do names[#names + 1] = n end
	if #names == 0 then return net_bucket(nets, ""), nil end
	table.sort(names)
	local stock = {}
	for i, n in ipairs(names) do stock[i] = net_bucket(nets, n) end
	return stock[1], stock
end

--- @param buckets table[]
--- @param hash string
--- @param count number
local function add_stock(buckets, hash, count)
	for _, nb in ipairs(buckets) do nb.s[hash] = (nb.s[hash] or 0) + count end
end

--- One pass over the snapshot producing the per-grid totals and each item's top stations together, so a
--- tooltip's top list always agrees with the totals shown next to it. Every inventory row that passes
--- the filters counts what it advertises on its own network: a secondary on A2 lands in A2's numbers, not in the
--- station combinator's A1. A station's kept rows are summed per item and the station counts once per item in the
--- totals and top lists; its deliveries count once, incoming ones on the network of its first kept row that
--- requests the item (else its first kept row's), outgoing ones against the stock on every network its kept rows are
--- on. The deficit per item is the sum over the networks of what each is short (logic.deficit), so stock on one
--- network never offsets a shortage on another.
--- @param snapshot Snapshot
--- @param f ManagerFilters
local function aggregate_with_top(snapshot, f)
	local filtered = filters.filters_active(f, true)
	local row_passes = filters.row_passes
	local inv = { provided = {}, requested = {}, in_transit = {} }
	local top = { provided = {}, requested = {}, in_transit = {} }
	local has_wait = false
	local nets = {}
	local inventories = collector.inventories
	for _, st in pairs(snapshot.stations) do
		local rows = inventories(st)
		-- Most stations have one row: its own lists are used as they are, and only a station whose kept rows are several
		-- gets summed copies.
		local p, r, first_bucket, first_stock, stock_seen, first_row
		-- {row, bucket, row, bucket, ...} once a second row is kept: an incoming delivery counts on the network of the
		-- row that requests the item, so its train offsets that network's request.
		local kept_rows
		local kept = 0
		for i = 1, #rows do
			local row = rows[i]
			if not filtered or row_passes(row, f, true) then
				kept = kept + 1
				local nb, stock = row_buckets(nets, row, f.network)
				if kept == 1 then
					first_bucket, first_stock, first_row = nb, stock, row
				else
					if kept == 2 then kept_rows = { first_row, first_bucket } end
					kept_rows[#kept_rows + 1] = row
					kept_rows[#kept_rows + 1] = nb
					-- The networks whose stock an outgoing delivery reduces, once a second row is kept.
					if not stock_seen then
						stock_seen = {}
						for _, b in ipairs(first_stock or { first_bucket }) do stock_seen[b] = true end
					end
					for _, b in ipairs(stock or { nb }) do stock_seen[b] = true end
				end
				local s, rb = nb.s, nb.r
				for hash, count in pairs(row.provided) do
					if stock then add_stock(stock, hash, count) else s[hash] = (s[hash] or 0) + count end
				end
				for hash, req in pairs(row.requested) do
					if req.active then rb[hash] = (rb[hash] or 0) - req.count end
				end
				if kept == 1 then
					p, r = row.provided, row.requested
				else
					if kept == 2 then
						local p1, r1 = p, r
						p, r = {}, {}
						for hash, count in pairs(p1) do p[hash] = count end
						for hash, req in pairs(r1) do
							if req.active then r[hash] = { count = req.count, active = true } end
						end
					end
					for hash, count in pairs(row.provided) do p[hash] = (p[hash] or 0) + count end
					for hash, req in pairs(row.requested) do
						if req.active then
							local sum = r[hash]
							if sum then
								sum.count = sum.count + req.count
							else
								r[hash] = { count = req.count, active = true }
							end
						end
					end
				end
			end
		end
		if first_bucket then
			for hash, count in pairs(p) do accumulate(inv.provided, top.provided, hash, count, count, st) end
			local wait = st.wait
			for hash, req in pairs(r) do
				if req.active then
					local agg = accumulate(inv.requested, top.requested, hash, req.count, -req.count, st)
					local start = wait and wait[hash]
					if start and (not agg.earliest_wait_start or start < agg.earliest_wait_start) then
						agg.earliest_wait_start = start
						has_wait = true
					end
				end
			end
			for hash, count in pairs(st.deliveries) do
				if count > 0 then
					accumulate(inv.in_transit, top.in_transit, hash, count, count, st)
					local tb = first_bucket
					if kept_rows then
						for k = 1, #kept_rows, 2 do
							if kept_rows[k].requested[hash] then
								tb = kept_rows[k + 1]
								break
							end
						end
					end
					tb.t[hash] = (tb.t[hash] or 0) + count
				elseif stock_seen then
					for nb in pairs(stock_seen) do nb.s[hash] = (nb.s[hash] or 0) + count end
				elseif first_stock then
					add_stock(first_stock, hash, count)
				else
					first_bucket.s[hash] = (first_bucket.s[hash] or 0) + count
				end
			end
		end
	end
	local deficit = {}
	local short = logic.deficit
	for _, nb in pairs(nets) do
		local t, s = nb.t, nb.s
		for hash, requested in pairs(nb.r) do
			local d = short(requested, t[hash], s[hash])
			if d > 0 then deficit[hash] = (deficit[hash] or 0) + d end
		end
	end
	inv.deficit = deficit
	return inv, top, has_wait
end
inventory_tab._aggregate = aggregate_with_top

--- Not filters.filter_signature: the grids never apply the item filter (with one set the tab shows the item's drill-down
--- instead), so picking an item must not re-aggregate.
--- @param f ManagerFilters
local function filter_signature(f)
	return (f.terms and table.concat(f.terms, " ") or "") .. "|" .. (f.network or "") .. "|" .. f.mask .. "|" .. (f.surface or "")
		.. "|" .. (f.station or "")
end

--- The aggregate is recomputed only when a collector pass completes or the filters change, and lives in storage so
--- the rendered output never depends on whether a client happened to have it cached.
--- @param player_data PlayerData
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @return table cache
--- @return boolean? rebuilt
local function get_cache(player_data, snapshot, f)
	local fkey = filter_signature(f)
	local cache = player_data.cache.inventory
	local same_filters = cache ~= nil and cache.fkey == fkey
	if same_filters and cache.tick == snapshot.tick and cache.started == snapshot.started_tick then
		return cache
	end
	local spread = (snapshot.station_count or 0) >= SPREAD_MIN_STATIONS
	-- The tick a pass completes already carries the collector's final step, so the new totals wait one render.
	if spread and same_filters and snapshot.tick == game.tick and not cache.deferred then
		cache.deferred = true
		return cache
	end
	local inv, top, has_wait = aggregate_with_top(snapshot, f)
	-- Kept outside the cache, which is dropped on close, so a grid's render signature can never repeat a stale one.
	local version = (player_data.tabs.inventory_tab.version or 0) + 1
	player_data.tabs.inventory_tab.version = version
	cache = {
		tick = snapshot.tick,
		started = snapshot.started_tick,
		fkey = fkey,
		inv = inv,
		top = top,
		has_wait = has_wait,
		-- Computed by unrequested_of on the first render that dims, not on every pass.
		unrequested = nil,
		order = {},
		version = version,
		-- A refresh nobody asked for, on a base big enough to be worth spreading over renders.
		background = spread and same_filters,
	}
	player_data.cache.inventory = cache
	return cache, true
end

--- Sort key for one item of a grid. `wait` only means something for requests once a requester has a tracked
--- start (has_wait); before that it falls back to item order.
--- @param column string
--- @param grid string
--- @param bucket table the grid's aggregate
--- @param has_wait boolean?
--- @return string column_used
--- @return fun(hash: string): number?
local function key_fn(column, grid, bucket, has_wait, inv)
	if column == "deficit" and grid == "requested" and inv then
		local deficit = inv.deficit or {}
		return column, function(hash) return deficit[hash] or 0 end
	elseif column == "amount" then
		return column, function(hash) return math.abs(bucket[hash].count) end
	elseif column == "stations" then
		return column, function(hash) return bucket[hash].stations end
	elseif column == "wait" and grid == "requested" and has_wait then
		return column, function(hash)
			local start = bucket[hash].earliest_wait_start
			return start and -start or nil
		end
	end
	return "item_order", util.item_rank
end

--- Display order, memoised in the cache because it only changes with the aggregate or the sort.
--- @param cache table
--- @param grid string
--- @param column string
--- @param ascending boolean
--- @return string[] hashes in display order
local function ordered_hashes(cache, grid, column, ascending)
	local order_key = grid .. "|" .. column .. "|" .. tostring(ascending)
	local cached = cache.order[order_key]
	if cached then return cached end
	local bucket = cache.inv[grid]
	local list = {}
	for hash in pairs(bucket) do
		if util.item_sprite_and_tooltip(hash) then list[#list + 1] = hash end
	end
	local used, fn = key_fn(column, grid, bucket, cache.has_wait, cache.inv)
	if used ~= column then ascending = true end
	-- Equal keys fall back to crafting-menu order, then the hash, so the order is total.
	util.sort_by(list, fn, ascending, util.item_rank, function(h) return h end)
	cache.order[order_key] = list
	return list
end

local CLICK_HINT = { "", "\n", { "cybersyn-gui.item-click-hint" } }
local STATIONS_KEY = {
	provided = "cybersyn-gui.provided-by-stations",
	in_transit = "cybersyn-gui.in-transit-to-stations",
	requested = "cybersyn-gui.requested-by-stations",
}

--- @param player_data PlayerData
--- @param grid string
--- @param n integer
local function update_header(player_data, grid, n)
	local header = player_data.refs["inventory_" .. grid .. "_header"]
	if not (header and header.valid) then return end
	local state = sync.gui_state(player_data, header.name)
	if state.n == n then return end
	state.n = n
	header.caption = { "cybersyn-gui.inventory-grid-caption", { "cybersyn-gui." .. string.gsub(grid, "_", "-") }, format.number(n) }
end

--- @param top table flat top-station list
--- @return LocalisedString
local function top_tooltip(top)
	local out = { "", "\n\n", { "cybersyn-gui.inventory-top-stations" } }
	for i = 1, #top / 3 do
		local b = i * 3
		out[#out + 1] = { "", "\n", { "cybersyn-gui.inventory-top-station-line", top[b], format.number(top[b - 2]) } }
	end
	return out
end

--- Entries are plain data and the tooltip is only assembled for buttons that are built or whose sig changed:
--- after a pass that is a few hundred of the ~700 buttons, and before it none.
--- @param ctx table per-grid render context from build_entries
--- @param entry table
--- @return LocalisedString
local function entry_tooltip(ctx, entry)
	local hash, agg = entry.key, entry.agg
	local _, _, name_tooltip = util.item_sprite_and_tooltip(hash)
	local tail = { "", "\n", { ctx.stations_key, tostring(agg.stations) } }
	if ctx.is_requested then
		local start = agg.earliest_wait_start
		if start then
			tail = { "", tail, "\n[color=yellow]", { "cybersyn-gui.waiting-for", logic.format_duration(ctx.now - start) }, "[/color]" }
		end
		local transit = entry.transit
		if transit then
			tail = { "", tail, "\n[color=orange]", { "cybersyn-gui.in-transit-amount", format.number(transit.count) }, "[/color]" }
		else
			tail = { "", tail, "\n[color=red]", { "cybersyn-gui.not-in-transit" }, "[/color]" }
		end
		if entry.starved then
			tail = { "", tail, "\n[color=red]", { "cybersyn-gui.inventory-starved" }, "[/color]" }
		end
	end
	if entry.dim then
		tail = { "", tail, "\n[color=0.6,0.6,0.6]", { "cybersyn-gui.inventory-unrequested" }, "[/color]" }
	end
	if ctx.is_requested and entry.deficit and entry.deficit > 0 then
		tail = { "", tail, "\n", { "cybersyn-gui.inventory-deficit", format.number(entry.deficit) } }
	end
	local item_top = ctx.top_bucket[hash]
	return {
		"", name_tooltip, tail,
		"\n", { "cybersyn-gui.amount", format.number(math.abs(agg.count)) },
		"\n", { "cybersyn-gui.inventory-delivered-hour", format.number(entry.delivered or 0) },
		item_top and top_tooltip(item_top) or "",
		CLICK_HINT,
	}
end

--- @param ctx table
--- @param entry table
--- @return flib.GuiElemDef
local function entry_build(ctx, entry)
	local hash, agg = entry.key, entry.agg
	local sprite, quality = util.item_sprite_and_tooltip(hash)
	return hover.hoverable({
		type = "sprite-button",
		sprite = sprite,
		quality = quality,
		style = entry.style,
		elem_tooltip = util.elem_tooltip(hash),
		tags = { kind = "item", id = hash },
		mouse_button_filter = { "left", "right" },
		handler = { [defines.events.on_gui_click] = links.handle.link_click },
		tooltip = entry_tooltip(ctx, entry),
		{
			type = "label",
			style = "ltnm_label_signal_count_inventory",
			ignored_by_interaction = true,
			caption = format_signal_count(agg.count),
		},
		{
			type = "label",
			style = "ltnm_label_train_count_inventory",
			ignored_by_interaction = true,
			caption = format_signal_count(agg.stations),
		},
	}, ctx.scope)
end

--- @param ctx table
--- @param elem LuaGuiElement
--- @param entry table
local function entry_update(ctx, elem, entry)
	local agg = entry.agg
	local count_caption = format_signal_count(agg.count)
	local stations_caption = format_signal_count(agg.stations)
	local labels = elem.children
	if labels[1].caption ~= count_caption then labels[1].caption = count_caption end
	if labels[2].caption ~= stations_caption then labels[2].caption = stations_caption end
	elem.tooltip = entry_tooltip(ctx, entry)
	local style = entry.style
	if elem.style.name ~= style then elem.style = style end
end

--- A changed key sequence is reached by destroying the vanished buttons, swapping the moved ones and inserting the
--- new ones at their index. A completed pass usually adds or drops a handful of items, and a sort change only
--- permutes them, so this keeps hundreds of buttons (and the player's scroll position) instead of recreating every
--- button after the first difference. A button's update does not depend on its index, and the render's budget
--- spreads a background refresh over several renders.
--- @param parent LuaGuiElement
--- @param ctx table
--- @param entries table[]
--- @param state {keys: string[]?, sigs: table?, dirty: true?}
--- @param hold boolean
--- @return "updated"|"held"|"rebuilt"
local function reconcile(parent, ctx, entries, state, hold)
	local opts = {
		build = function(entry) return entry_build(ctx, entry) end,
		update = function(elem, entry) entry_update(ctx, elem, entry) end,
		budget = ctx.budget,
		destroy_vanished = true,
		rebuild_mostly_new = true,
		moved_keeps_sig = true,
	}
	local result = sync.sync_children(parent, entries, state, hold, opts)
	if opts.deferred then ctx.deferred = true end
	return result
end

--- @param player_data PlayerData
--- @param table_elem LuaGuiElement
--- @param state table from sync.gui_state
--- @param ctx table
--- @param entries table[]
local function render_grid(player_data, grid, table_elem, state, ctx, entries)
	local result = reconcile(table_elem, ctx, entries, state, hover.hold_active(player_data, table_elem.name))
	-- While held the grid still shows the old set, so a new count would contradict the buttons under the cursor.
	if result ~= "held" then update_header(player_data, grid, #entries) end
	return result
end

--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @param hash string
local function is_starved(snapshot, f, hash)
	if f.network then
		local starved = snapshot.starved
		return starved ~= nil and starved[f.network .. ":" .. hash] == true
	end
	local items = snapshot.starved_items
	return items ~= nil and items[hash] == true
end

-- Sigs are numeric digests rather than strings: building ~700 strings per render, with every number converted
-- to text, cost more than the updates they saved. A collision only delays one button's refresh to its next change.
local DIGEST_MOD = 4294967296
local function mix(d, v)
	return (d * 1000003 + v) % DIGEST_MOD
end

--- Order-sensitive digest of a flat top-station list. Station renames alone do not change it; they show up with
--- the item's next count change.
--- @param d number
--- @param top table?
--- @return number
local function mix_top(d, top)
	if not top then return mix(d, 0) end
	for i = 1, #top / 3 do
		local b = i * 3
		d = mix(mix(d, top[b - 1]), top[b - 2] % DIGEST_MOD)
	end
	return d
end

local COLOR_CODE = { green = 1, blue = 2, red = 3, orange = 4, pink = 5, grey = 6 }

--- @param cache table from get_cache
--- @param grid string
--- @param scope string hover scope (the grid's table name)
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @param budget {n: integer}? shared by the grids of one render; nil = unlimited
--- @return table ctx
--- @return table[] entries
--- The provided items nobody on the same network requests, for the cache's pass and filters; computed only while
--- Dim unrequested is on.
--- @param cache table
--- @param snapshot Snapshot
--- @param f ManagerFilters
--- @return {[string]: true}
local function unrequested_of(cache, snapshot, f)
	local set = cache.unrequested
	if set then return set end
	set = logic.unrequested(snapshot.provider_masks or {}, snapshot.request_keys or {}, f.network)
	cache.unrequested = set
	return set
end

local function build_entries(cache, grid, scope, snapshot, f, column, ascending, now, budget, delivered, dim)
	local inv = cache.inv
	local bucket = inv[grid]
	local top_bucket = cache.top[grid]
	local hashes = ordered_hashes(cache, grid, column, ascending)
	local is_requested = grid == "requested"
	local base_color = grid == "provided" and "green" or "blue"
	local ctx = {
		scope = scope,
		is_requested = is_requested,
		stations_key = STATIONS_KEY[grid],
		top_bucket = top_bucket,
		now = now,
		budget = budget,
	}
	local in_transit = inv.in_transit
	local inv_deficit = inv.deficit or {}
	local unrequested = dim and grid == "provided" and unrequested_of(cache, snapshot, f) or nil
	local entries = {}
	for i, hash in ipairs(hashes) do
		local agg = bucket[hash]
		local color, sig_extra, transit, starved, deficit
		local is_dim = unrequested ~= nil and unrequested[hash] == true
		if is_requested then
			transit = in_transit[hash]
			starved = is_starved(snapshot, f, hash)
			color = starved and "pink" or transit and "orange" or "red"
			deficit = inv_deficit[hash] or 0
			local start = agg.earliest_wait_start
			sig_extra = mix(mix(start and math.floor((now - start) / WAIT_SIG_TICKS) + 1 or 0, transit and transit.count % DIGEST_MOD or -1), starved and 1 or 0)
			sig_extra = mix(sig_extra, deficit % DIGEST_MOD)
		elseif is_dim then
			color = "grey"
		else
			color = base_color
		end
		local sent = delivered and delivered[hash] or 0
		local style = "flib_slot_button_" .. color
		-- Content-based rather than version-based, so a completed pass only touches the items whose numbers moved.
		local sig = mix(mix(mix(agg.count % DIGEST_MOD, agg.stations), COLOR_CODE[color] * 2), sig_extra or 0)
		sig = mix(mix_top(sig, top_bucket[hash]), sent % DIGEST_MOD)
		entries[i] = { key = hash, sig = sig, agg = agg, style = style, transit = transit, starved = starved, dim = is_dim,
			deficit = deficit, delivered = sent }
	end
	return ctx, entries
end

--- Empty grids alone do not say whether nothing matches or nothing has been collected yet. The message replaces
--- the grids, centred like the empty state of the Stations and Trains tabs. It follows the aggregate the grids show,
--- which reaches a completed pass a render or two after the pass itself (get_cache spreads the refresh).
--- @param refs table<string, LuaGuiElement>
--- @param cache table from get_cache
local function render_empty_label(refs, cache, f)
	local label, flow, grids = refs.inventory_empty_label, refs.inventory_empty_flow, refs.inventory_grids_flow
	if not (label and label.valid and flow and flow.valid and grids and grids.valid) then return end
	local inv = cache.inv
	local key
	if not cache.tick then
		key = "cybersyn-gui.stations-collecting"
	elseif not (next(inv.provided) or next(inv.requested) or next(inv.in_transit)) then
		key = filters.filters_active(f, true) and "cybersyn-gui.inventory-no-match" or "cybersyn-gui.inventory-empty"
	end
	local show = key ~= nil
	if flow.visible ~= show then flow.visible = show end
	if grids.visible == show then grids.visible = not show end
	if key and label.tags.key ~= key then
		label.caption = { key }
		label.tags = { key = key }
	end
end

--- A grid's sort: the column its own buttons chose, else the tab's sort.
--- @param player_data PlayerData
--- @param grid string
--- @return string column
--- @return boolean ascending
local function grid_sort(player_data, grid)
	local sorts = player_data.tabs.inventory_tab.sorts
	local column = sorts and sorts[grid]
	if column and DEFAULT_ASCENDING[column] ~= nil then return column, DEFAULT_ASCENDING[column] end
	return listing.get_sort(player_data, TAB, DEFAULT_SORT)
end

--- The toggled state of the grids' sort buttons and the dim button.
--- @param player_data PlayerData
--- @param columns {[string]: string}
local function sync_buttons(player_data, columns)
	local refs = player_data.refs
	local state = sync.gui_state(player_data, "inventory_buttons")
	local dim = refs.inventory_dim_button
	local sig = (player_data.tabs.inventory_tab.dim and "d" or "") .. "|" .. columns.provided .. "|"
		.. columns.in_transit .. "|" .. columns.requested .. "|" .. (dim and dim.valid and dim.index or "")
	if state.sig == sig then return end
	state.sig = sig
	for _, grid in ipairs(GRIDS) do
		for _, column in ipairs(GRID_SORTS[grid]) do
			local button = refs["inventory_" .. grid .. "_sort_" .. column]
			if button and button.valid then button.toggled = columns[grid] == column end
		end
	end
	if dim and dim.valid then dim.toggled = player_data.tabs.inventory_tab.dim == true end
end

--- Leaving the tab: coming back must show current totals at once, not a refresh spread over the next renders.
---@param map_data MapData
---@param player_data PlayerData
function inventory_tab.cleanup(map_data, player_data)
	player_data.cache.inventory = nil
end

--- The grids, while no item filter is set (with one the tab shows the item's drill-down): the other filters
--- and the station chip restrict which inventory rows are aggregated.
---@param map_data MapData
---@param player_data PlayerData
function inventory_tab.build(map_data, player_data)
	local refs = player_data.refs
	local snapshot = collector.get()
	local f = filters.get(player_data, TAB)
	local layout = player_data.layout
	if layout then
		local _, columns = grid_size(layout.content_width)
		for _, grid in ipairs(GRIDS) do ensure_columns(player_data, grid, columns) end
	end
	local sorts = {}
	local used = {}
	for _, grid in ipairs(GRIDS) do
		local column, ascending = grid_sort(player_data, grid)
		sorts[grid] = { column, ascending }
		local supported = false
		for _, c in ipairs(GRID_SORTS[grid]) do
			if c == column then supported = true end
		end
		used[grid] = supported and column or DEFAULT_SORT
	end
	sync_buttons(player_data, used)
	local cache, rebuilt = get_cache(player_data, snapshot, f)
	-- A background refresh aggregates on one render and applies on the next, so neither carries both costs.
	if rebuilt and cache.background then return end
	render_empty_label(refs, cache, f)
	-- The grids are hidden until a completed pass is aggregated. Left alone meanwhile, the buttons from before the
	-- window was closed are mostly reused then instead of all being built again (~20 ms for 600 items).
	if not cache.tick then return end
	local version = cache.version
	local now = game.tick
	local minute = math.floor(now / 3600)
	-- Only a refresh nobody asked for is spread out; a filter or sort change shows complete numbers at once.
	local budget = cache.background and { n = BACKGROUND_UPDATE_BUDGET } or nil
	local dim = player_data.tabs.inventory_tab.dim == true
	local delivered

	for _, grid in ipairs(GRIDS) do
		local scope = grid_table_name(grid)
		local table_elem = refs[scope]
		if table_elem and table_elem.valid then
			local state = sync.gui_state(player_data, scope)
			local column, ascending = sorts[grid][1], sorts[grid][2]
			-- Wait times in the requested tooltips age even when nothing else changes; delivered amounts once a minute.
			local wait_bucket = grid == "requested" and cache.has_wait and math.floor(now / WAIT_SIG_TICKS) or ""
			local render_sig = version .. "|" .. column .. "|" .. tostring(ascending) .. "|" .. table_elem.index .. "|" .. wait_bucket .. "|" .. minute .. "|" .. (dim and grid == "provided" and "d" or "")
			if state.render_sig ~= render_sig or state.dirty or not state.keys then
				if not delivered then
					-- Once a minute, not on each of the renders a refresh is spread over.
					delivered = util.delivered_items(player_data, 60)
				end
				-- A refresh spread over renders builds its entries once and works through them on the next renders
				-- (rebuilding every entry on each of them put the renders after a pass at the 5 ms edge on a large
				-- base).
				local pending = state.pending
				local ctx, entries
				if pending and pending.sig == render_sig and pending.version == version then
					ctx, entries = pending.ctx, pending.entries
					ctx.budget, ctx.deferred, ctx.now = budget and { n = BACKGROUND_UPDATE_BUDGET } or nil, nil, now
				else
					ctx, entries = build_entries(cache, grid, scope, snapshot, f, column, ascending, now, budget, delivered,
						dim)
				end
				local result = render_grid(player_data, grid, table_elem, state, ctx, entries)
				state.render_sig = (result ~= "held" and not ctx.deferred) and render_sig or nil
				state.pending = ctx.deferred and { sig = render_sig, version = version, ctx = ctx, entries = entries } or nil
			end
		end
	end
end

inventory_tab.handle = {}

inventory_tab.wrapper = util.wrapper

--- A grid's sort button: selects that column for the grid; the active one again goes back to item order.
--- @param e EventData.on_gui_click
function inventory_tab.handle.on_grid_sort_click(player, player_data, refs, e)
	local tags = e.element.tags
	local grid, column = tags.grid, tags.column
	if not (grid and column) then return end
	inventory_tab.set_grid_sort(player_data, grid, column)
	nav.rerender(player, player_data)
end

--- @param player_data PlayerData
--- @param grid string
--- @param column string
function inventory_tab.set_grid_sort(player_data, grid, column)
	local current = grid_sort(player_data, grid)
	if current == column then column = DEFAULT_SORT end
	local sorts = player_data.tabs.inventory_tab.sorts or {}
	sorts[grid] = column
	player_data.tabs.inventory_tab.sorts = sorts
end

--- @param e EventData.on_gui_click
function inventory_tab.handle.on_dim_click(player, player_data, refs, e)
	player_data.tabs.inventory_tab.dim = not player_data.tabs.inventory_tab.dim or nil
	nav.rerender(player, player_data)
end

gui.add_handlers(inventory_tab.handle, inventory_tab.wrapper)

return inventory_tab
