local gui = require("__flib__.gui")


local templates = require("scripts.gui.templates")

local tabs = require("scripts.gui.utils.tabs")
local trains_tab = require("scripts.gui.trains")
local inventory_tab = require("scripts.gui.inventory")
local log_tab = require("scripts.gui.log")
local item = require("scripts.gui.item")
local explain = require("scripts.gui.explain")
local util = require("scripts.gui.util")
local logic = require("scripts.gui.tab-logic")
local filters = require("scripts.gui.utils.filters")
local listing = require("scripts.gui.utils.listing")
local hover = require("scripts.gui.utils.hover")
local nav = require("scripts.gui.utils.nav")
local collector = require("scripts.gui.collector")
local analytics = require("scripts.analytics")
local sizing = require("scripts.gui.sizing")

local manager = {}

local DEFAULT_TAB = "overview_tab"
--- @type {[string]: table} each tab's module, by tab name
local tab_modules = {}
for _, t in ipairs(tabs) do tab_modules[t.name] = require(t.module) end
-- The last render must be this old before the title bar says how old it is.
local STALE_TICKS = 180

local function set_frame_toggle(elem, selected)
	if elem and elem.valid then
		elem.style = selected and "flib_selected_frame_action_button" or "frame_action_button"
	end
end

local function frame_toggle(name, sprite, tooltip, handler)
	local def = templates.frame_action_button(name, sprite, tooltip, nil)
	def.handler = { [defines.events.on_gui_click] = handler }
	return def
end

--- @param def {content: flib.GuiElemDef}
--- @param tab ManagerTab
--- @param handlers table
--- @param right flib.GuiElemDef[]?
local function add_header(def, tab, handlers, right)
	local banner, subheader = templates.tab_header(tab, handlers, right)
	local content = def.content
	local children = content.children or content
	table.insert(children, 1, subheader)
	table.insert(children, 1, banner)
	return def
end

--- @param player LuaPlayer
function manager.create(player)
	---@type table<string, LuaGuiElement>
	local refs = {}
	local header = {
		search_changed = manager.handle.manager_search_changed,
		chip_click = manager.handle.manager_chip_click,
	}
	local pane = {
		name = "manager_tabbed_pane",
		type = "tabbed-pane",
		style = "ltnm_tabbed_pane",
		handler = { [defines.events.on_gui_selected_tab_changed] = manager.handle.manager_tab_changed },
	}
	local with_analytics = analytics.is_enabled()
	for _, t in ipairs(tabs) do
		if with_analytics or not t.analytics then
			local m = tab_modules[t.name]
			pane[#pane + 1] = add_header(m.create(), t, header, m.subheader_right and m.subheader_right())
		end
	end

	gui.add(player.gui.screen, {
		{
			name = "manager_window",
			type = "frame",
			direction = "vertical",
			visible = false,
			handler = { [defines.events.on_gui_location_changed] = manager.handle.manager_location_changed },
			children = {
				{
					name = "manager_titlebar",
					type = "flow",
					style = "flib_titlebar_flow",
					handler = manager.handle.manager_titlebar_click,
					children = {
						{ type = "label", style = "frame_title", caption = { "mod-name.cybersyn" }, ignored_by_interaction = true },
						{ type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
						{
							name = "manager_updated_label",
							type = "label",
							visible = false,
							style_mods = { top_margin = 1, right_margin = 4 },
							tooltip = { "cybersyn-gui.updated-tooltip" },
						},
						{
							type = "sprite-button",
							name = "manager_back_button",
							style = "frame_action_button",
							sprite = "flib_nav_backward_white",
							hovered_sprite = "flib_nav_backward_black",
							clicked_sprite = "flib_nav_backward_black",
							visible = false,
							tooltip = { "cybersyn-gui.back-from-map-tooltip" },
							handler = { [defines.events.on_gui_click] = manager.handle.manager_back },
						},
						frame_toggle("manager_search_button", "utility/search", { "cybersyn-gui.search-button-tooltip" }, manager.handle.manager_toggle_search),
						frame_toggle("manager_filter_button", "cybersyn_filter_white", { "cybersyn-gui.filter-button-tooltip" }, manager.handle.manager_toggle_filter_row),
						frame_toggle("manager_pause_button", "cybersyn_pause_white", { "cybersyn-gui.pause-tooltip" }, manager.handle.manager_toggle_pause),
						frame_toggle("manager_pin_button", "ltnm_pin_white", { "cybersyn-gui.pin-tooltip" }, manager.handle.manager_toggle_pinned),
						frame_toggle(nil, "utility/close", { "gui.close-instruction" }, manager.handle.manager_close),
					},
				},
				{
					type = "frame",
					style = "inside_deep_frame",
					direction = "vertical",
					children = {
						{
							name = "manager_filter_row",
							type = "frame",
							style = "cybersyn_filter_row",
							visible = false,
							children = {
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.search-item-label" } },
								{
									type = "choose-elem-button",
									name = "manager_item_filter",
									elem_type = "signal",
									style = "slot_button_in_shallow_frame",
									style_mods = { size = 28 },
									handler = { [defines.events.on_gui_elem_changed] = manager.handle.manager_update_item_search },
								},
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.network-name-label" } },
								{
									type = "choose-elem-button",
									name = "network",
									elem_type = "signal",
									style = "slot_button_in_shallow_frame",
									style_mods = { size = 28 },
									tooltip = { "cybersyn-gui.network-tooltip" },
									handler = { [defines.events.on_gui_elem_changed] = manager.handle.manager_update_network_name },
								},
								{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.network-id-label" } },
								{
									name = "manager_network_mask_field",
									type = "textfield",
									style_mods = { width = 120 },
									numeric = true,
									allow_negative = true,
									text = "-1",
									handler = { [defines.events.on_gui_text_changed] = manager.handle.manager_update_network_mask },
								},
								{ type = "label", name = "manager_surface_label", style = "subheader_caption_label", caption = { "cybersyn-gui.surface-label" } },
								{
									name = "manager_surface_dropdown",
									type = "drop-down",
									handler = { [defines.events.on_gui_selection_state_changed] = manager.handle.manager_update_surface },
								},
								{ type = "empty-widget", style = "flib_horizontal_pusher" },
								{
									name = "manager_clear_filters_button",
									type = "sprite-button",
									style = "tool_button",
									sprite = "utility/reset",
									tooltip = { "cybersyn-gui.clear-filters-tooltip" },
									handler = { [defines.events.on_gui_click] = manager.handle.manager_clear_filters },
								},
							},
						},
						pane,
					},
				},
			},
		},
	}, refs)

	refs.manager_titlebar.drag_target = refs.manager_window
	refs.manager_tabbed_pane.selected_tab_index = 1
	refs.manager_window.force_auto_center()

	return refs
end

-- ---------------------------------------------------------------- layout

--- @return boolean
function manager.dispatch_paused()
	return mod_settings.enable_planner == false
end

--- The filter button is the row's switch: lit while the row is open, and closing it clears the row's filters, so a
--- filter is never active with the row hidden.
--- @param player_data PlayerData
--- @return boolean
function manager.filter_row_shown(player_data)
	return player_data.filter_row_open == true
end

--- Every open starts on the player's surface (player.surface, which follows remote view), or on All when
--- that surface holds no Cybersyn station (a space platform) or the game has a single surface.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.apply_surface_default(player, player_data)
	local index = player.surface.index
	filters.set(player_data, "surface", #game.surfaces > 1 and filters.surface_has_station(index) and index or nil)
end

--- @class ManagerFocus what manager.focus shows; the filter fields are FilterState's
--- @field query string? the search that names the subject (a depot or refueler name); nil clears the search
--- @field keep_row true? leave network, network ID, surface and item as they are (the Overview's Stations jumps: the
--- tile counted under them)
--- @field item string? item hash to filter by
--- @field station uint? station id for the station chip
--- @field train uint? train id for the train chip
--- @field network string? network name to filter by
--- @field stations_chip string? a Stations flag chip ("unserved"|"failing"|"problems")
--- @field problems_scope "errors"?
--- @field trains_chip string? a Trains chip ("parked")
--- @field reveal {train: uint?, group: string?, all: true?}? grouped Trains: expand the group holding this train, or
--- this group, or (all) every group holding a train that passes the filters
--- @field sort {tab: string, column: string, ascending: boolean}?
--- @field grids true? the Inventory's grids under the focus sort: the item filter (its drill-down replaces the grids)
--- and the grids' own sort buttons go

local FOCUS_FIELDS = { "item", "station", "train", "network", "stations_chip", "problems_scope", "trains_chip" }

--- Shows `tab` with exactly the subject in it. Every chip and overlay goes, and without keep_row every row filter
--- too, so nothing set earlier can hide what the player asked for. Every entry point resets through here, so a chip
--- added later cannot be missed by one of them.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param tab string
--- @param focus ManagerFocus
function manager.focus(player, player_data, tab, focus)
	item.close(player, player_data)
	explain.close(player, player_data)
	if focus.keep_row then
		-- The Overview tile counted without the station chip (it ignores it), so the jump must not keep it either.
		filters.clear(player_data, "chips")
	else
		player_data.filter_row_open = nil
		filters.clear(player_data, "row")
	end
	filters.set(player_data, "query", focus.query)
	if focus.query then player_data.search_open = true end
	if focus.grids then
		filters.set(player_data, "item", nil)
		player_data.tabs.inventory_tab.sorts = nil
	end
	for _, field in ipairs(FOCUS_FIELDS) do
		if focus[field] ~= nil then filters.set(player_data, field, focus[field]) end
	end
	local sort = focus.sort
	if sort then listing.set_sort(player_data, sort.tab, sort.column, sort.ascending) end
	player_data.tabs.trains_tab.reveal = focus.reveal
	player_data.selected_tab = tab
	if player_data.is_manager_open then
		nav.select_tab(player_data, tab)
		local window = player_data.refs.manager_window
		if not player_data.pinning and window and window.valid and player.opened ~= window then player.opened = window end
		manager.render(player, player_data)
	else
		-- The subject may be on another surface than the player: a surface default would hide it again.
		if not focus.keep_row then player_data.focus_open = true end
		manager.handle.manager_open(player, player_data, player_data.refs)
	end
end

--- The window size for this player's screen; stored in player_data.layout.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return ManagerLayout
function manager.layout(player, player_data)
	local res = player.display_resolution
	local res_w, res_h, scale = res.width, res.height, player.display_scale
	local layout = sizing.compute(res_w, res_h, scale, manager.filter_row_shown(player_data), manager.dispatch_paused())
	layout.res_width, layout.res_height, layout.scale = res_w, res_h, scale
	player_data.layout = layout
	return layout
end

--- Writes the layout into the window: its width, every tab's height and the per-tab row areas.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return ManagerLayout
function manager.apply_layout(player, player_data)
	local layout = manager.layout(player, player_data)
	local refs = player_data.refs
	local window = refs.manager_window
	if not (window and window.valid) then return layout end
	window.style.width = layout.width
	local height = layout.content_height + (manager.dispatch_paused() and sizing.BANNER_HEIGHT or 0)
	for _, t in ipairs(tabs) do
		local content = t.content and refs[t.content]
		if content and content.valid then
			content.style.height = height
			content.style.width = layout.content_width
		end
		local m = tab_modules[t.name]
		if m.apply_layout then m.apply_layout(player_data, layout) end
	end
	item.apply_layout(player_data, layout)
	return layout
end

--- Restores the stored position, or centres the window when there is none or it would be off the screen.
--- player_data.location duplicates the engine's own only so the position survives reset_player's rebuilds.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.place_window(player, player_data)
	local window = player_data.refs.manager_window
	if not (window and window.valid) then return end
	local res = player.display_resolution
	local layout = player_data.layout
	local scale = player.display_scale
	local width_px = (layout and layout.width or sizing.MAX_WIDTH) * scale
	local height_px = (layout and layout.window_height or 0) * scale
	local loc = sizing.fit_location(player_data.location, res.width, res.height, width_px, height_px)
	if loc then
		player_data.location = loc
		window.location = loc
	else
		player_data.location = nil
		window.force_auto_center()
	end
end

--- The resolution or UI scale changed, or the window was rebuilt: size it again and check its position.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.relayout(player, player_data)
	local refs = player_data.refs
	if not (refs and refs.manager_window and refs.manager_window.valid) then return end
	manager.apply_layout(player, player_data)
	-- A hidden window is placed when it opens; centring it now would use a stale size.
	if player_data.is_manager_open then
		manager.place_window(player, player_data)
		explain.place(player, player_data)
		manager.render(player, player_data)
	end
end

-- ---------------------------------------------------------------- strips: banner, search, chip, filter row

--- @param player_data PlayerData
function manager.refresh_banners(player_data)
	local refs = player_data.refs
	local paused = manager.dispatch_paused()
	local caption
	if paused then
		local by = storage.manager.paused_by
		local who = by and by > 0 and game.get_player(by)
		caption = who and { "cybersyn-gui.dispatch-paused-by", who.name } or { "cybersyn-gui.dispatch-paused" }
	end
	for _, t in ipairs(tabs) do
		local banner = refs[t.name .. "_banner"]
		if banner and banner.valid then
			banner.visible = paused
			if paused then
				local label = refs[t.name .. "_banner_label"]
				label.caption = caption
				label.tooltip = { "cybersyn-gui.dispatch-paused-tooltip" }
			end
		end
	end
end

--- @param player_data PlayerData
--- @return boolean
local function search_shown(player_data)
	return player_data.search_open == true or player_data.filters.query ~= nil
end

--- Whether the selected tab shows a search field: a search tab, except the Inventory while its drill-down takes the
--- place of its subheader.
--- @param player_data PlayerData
--- @return boolean
local function search_tab(player_data)
	local tab = player_data.selected_tab
	if tab == "inventory_tab" and item.filter_hash(player_data) then return false end
	local t = tabs.by_name[tab]
	return t ~= nil and t.search == true
end

--- @param player_data PlayerData
function manager.refresh_search_fields(player_data)
	local refs = player_data.refs
	local shown = search_shown(player_data)
	local text = player_data.filters.query or ""
	for _, t in ipairs(tabs) do
		local field = t.search and refs[t.name .. "_search_field"]
		if field and field.valid then
			if field.visible ~= shown then field.visible = shown end
			if field.text ~= text then field.text = text end
		end
	end
	set_frame_toggle(refs.manager_search_button, shown)
end

--- The stop name the station chip shows: its current name, so a rename shows on the next render.
--- @param id uint
--- @return string?
local function station_chip_name(id)
	local station = storage.stations[id]
	local stop = station and station.entity_stop
	return stop and stop.valid and stop.backer_name or nil
end

--- @param player_data PlayerData
local function refresh_station_chips(player_data, id, name)
	local refs = player_data.refs
	local shown = id ~= nil
	for _, t in ipairs(tabs) do
		local flow = refs[t.name .. "_station_chip_flow"]
		if flow and flow.valid then
			flow.visible = shown
			if shown then
				local tooltip = t.station and { "cybersyn-gui.station-chip-tooltip" }
					or { "cybersyn-gui.station-chip-ignored-tooltip" }
				refs[t.name .. "_station_chip_icon"].tooltip = tooltip
				local chip = refs[t.name .. "_station_chip"]
				chip.caption = { "cybersyn-gui.station-chip", name or "?", tostring(id) }
				chip.tooltip = tooltip
			end
		end
	end
end

--- @param player_data PlayerData
function manager.refresh_chips(player_data)
	local refs = player_data.refs
	local hash = player_data.filters.item
	local station = player_data.filters.station
	local station_name = station and station_chip_name(station)
	local train = player_data.filters.train
	local sig = (hash or "") .. "\1" .. (station and (tostring(station) .. "\1" .. (station_name or "")) or "") .. "\1"
		.. (train or "")
	if player_data.cache.chip_sig == sig then return end
	player_data.cache.chip_sig = sig
	refresh_station_chips(player_data, station, station_name)
	for _, t in ipairs(tabs) do
		local flow = t.train and refs[t.name .. "_train_chip_flow"]
		if flow and flow.valid then
			flow.visible = train ~= nil
			if train then refs[t.name .. "_train_chip"].caption = { "cybersyn-gui.train-chip", tostring(train) } end
		end
	end
	local sprite, quality, _, item_name
	if hash then sprite, quality, _, _, item_name = util.item_sprite_and_tooltip(hash) end
	local shown = sprite ~= nil
	for _, t in ipairs(tabs) do
		local flow = refs[t.name .. "_chip_flow"]
		if flow and flow.valid then
			flow.visible = shown
			if shown then
				local tooltip = { t.item_tooltip or t.item and "cybersyn-gui.filter-chip-tooltip"
					or "cybersyn-gui.filter-chip-ignored-tooltip" }
				local icon = refs[t.name .. "_chip_icon"]
				icon.sprite = sprite
				icon.quality = quality
				icon.elem_tooltip = util.elem_tooltip(hash)
				icon.tooltip = tooltip
				local chip = refs[t.name .. "_chip"]
				chip.caption = { "cybersyn-gui.filter-chip", item_name or hash }
				chip.tooltip = tooltip
			end
		end
	end
end

--- Shows or hides the filter row; a change of its visibility changes the rows that fit.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.refresh_filter_row(player, player_data)
	local refs = player_data.refs
	local row = refs.manager_filter_row
	if not (row and row.valid) then return end
	local shown = manager.filter_row_shown(player_data)
	local multi = #game.surfaces > 1
	if refs.manager_surface_label.visible ~= multi then
		refs.manager_surface_label.visible = multi
		refs.manager_surface_dropdown.visible = multi
	end
	set_frame_toggle(refs.manager_filter_button, shown)
	if row.visible ~= shown then
		row.visible = shown
		manager.apply_layout(player, player_data)
	end
end

--- @param player_data PlayerData
function manager.refresh_toggles(player_data)
	local refs = player_data.refs
	local pause = refs.manager_pause_button
	if pause and pause.valid then
		set_frame_toggle(pause, player_data.paused)
		local sprite = player_data.paused and "utility/play" or "cybersyn_pause_white"
		pause.sprite = sprite
		pause.hovered_sprite = sprite
		pause.clicked_sprite = sprite
		pause.tooltip = player_data.paused and { "cybersyn-gui.resume-tooltip" } or { "cybersyn-gui.pause-tooltip" }
	end
	local pin = refs.manager_pin_button
	if pin and pin.valid then
		set_frame_toggle(pin, player_data.pinning)
		local sprite = player_data.pinning and "ltnm_pin_black" or "ltnm_pin_white"
		pin.sprite = sprite
		pin.hovered_sprite = sprite
		pin.clicked_sprite = sprite
	end
	nav.refresh_back(player_data)
end

--- The title-bar age (only once the last render is STALE_TICKS old, or while paused) and the subheaders'
--- "Collecting… n %"; cheap enough to run every manager update, paused or not.
--- @param player_data PlayerData
function manager.update_status(player_data)
	local refs = player_data.refs
	local label = refs.manager_updated_label
	if not label or not label.valid then return end
	-- The caption tracks renders; the snapshot age cycles through a whole collector pass even while the window
	-- refreshes every second, so it only goes in the tooltip.
	local render_tick = player_data.last_update_tick
	local data_tick = player_data.rendered_snapshot_tick
	local stale = player_data.paused or not render_tick or game.tick - render_tick > STALE_TICKS
	if label.visible ~= stale then label.visible = stale end
	-- Hidden while renders are recent (nearly always): nothing to write then. Shown, written when its text changed.
	if stale then
		local age = render_tick and logic.format_duration(game.tick - render_tick) or "-"
		local data_age = data_tick and logic.format_duration(game.tick - data_tick) or "-"
		local held = false
		local cur = player_data.hover
		if not player_data.paused and cur and hover.hold_active(player_data, cur.scope) then
			local state = player_data.gui_state and player_data.gui_state[cur.scope]
			held = state ~= nil and state.dirty == true
		end
		local sig = age .. "|" .. data_age .. "|" .. (player_data.paused and "p" or "") .. (held and "h" or "")
		if player_data.cache.status_sig ~= sig then
			player_data.cache.status_sig = sig
			label.tooltip = { "", { "cybersyn-gui.updated-tooltip" }, "\n", { "cybersyn-gui.data-age", data_age } }
			local caption
			if player_data.paused then
				caption = { "", "[color=yellow]", { "cybersyn-gui.paused-updated-ago", age }, "[/color]" }
			else
				caption = { "cybersyn-gui.updated-ago", age }
				if held then caption = { "", caption, " ", { "cybersyn-gui.layout-held" } } end
			end
			label.caption = caption
		end
	else
		player_data.cache.status_sig = nil
	end

	-- The placeholders show from the open (collector.collecting); the note only once a cold boost outlasts
	-- collector.NOTE_TICKS, which a normal pass never does now that it steps every tick.
	local collecting = collector.collecting_note()
	local show = collecting ~= nil and not (player_data.paused and data_tick)
	local percent = show and math.floor(collecting * 100) or -1
	if player_data.cache.collecting_shown ~= percent then
		player_data.cache.collecting_shown = percent
		for _, t in ipairs(tabs) do
			local note = refs[t.name .. "_collecting"]
			if note and note.valid then
				note.visible = show
				note.caption = show and { "cybersyn-gui.collecting-progress", tostring(percent) } or ""
			end
		end
	end
end

--- Rebuilds the surface drop-down; only on open and when the number of surfaces changes.
--- @param player_data PlayerData
function manager.rebuild_surface_dropdown(player_data)
	local dropdown = player_data.refs.manager_surface_dropdown
	if not dropdown or not dropdown.valid then return end
	local surfaces = {}
	for _, surface in pairs(game.surfaces) do
		surfaces[#surfaces + 1] = surface
	end
	table.sort(surfaces, function(a, b) return a.index < b.index end)

	local items = { { "cybersyn-gui.all-surfaces" } }
	local ids = {}
	local selected = 1
	for i, surface in ipairs(surfaces) do
		items[i + 1] = surface.localised_name or surface.name
		ids[i + 1] = surface.index
		if surface.index == player_data.filters.surface then
			selected = i + 1
		end
	end
	dropdown.items = items
	dropdown.selected_index = selected
	player_data.surface_dropdown_ids = ids
end

--- Writes the stored filters into the filter row, the search fields and the chips (manager.render, when they
--- changed).
--- @param player LuaPlayer
--- @param player_data PlayerData
local function write_filter_widgets(player, player_data)
	local refs = player_data.refs
	local fs = player_data.filters
	refs.manager_item_filter.elem_value = fs.item and util.signalid_from_hash(fs.item) or nil
	refs.network.elem_value = fs.network and util.signalid_from_name(fs.network) or nil
	-- Not while it already reads as the stored ID: the player is typing in it ("", "-").
	local mask = refs.manager_network_mask_field
	if (tonumber(mask.text) or -1) ~= (fs.mask or -1) then mask.text = tostring(fs.mask or -1) end
	manager.rebuild_surface_dropdown(player_data)
	manager.refresh_search_fields(player_data)
	player_data.cache.chip_sig = nil
	manager.refresh_chips(player_data)
	manager.refresh_filter_row(player, player_data)
end

--- The tab's cleanup hook, if it has one: it is being left or the window closes.
--- @param map_data MapData
--- @param player_data PlayerData
--- @param tab string?
local function cleanup(map_data, player_data, tab)
	local m = tab and tab_modules[tab]
	if m and m.cleanup then m.cleanup(map_data, player_data) end
end

--- @param map_data MapData
--- @param player_data PlayerData
function manager.update(map_data, player_data)
	local previous_tab = player_data.previous_tab
	local current_tab = player_data.selected_tab
	if previous_tab ~= current_tab then
		cleanup(map_data, player_data, previous_tab)
		player_data.previous_tab = current_tab
	end

	-- The Inventory shows the item filter's drill-down in place of its grids; any other tab, or no filter, drops
	-- the drill-down's elements.
	local hash = current_tab == "inventory_tab" and item.filter_hash(player_data) or nil
	if hash and item.build(map_data, player_data, hash) then
		inventory_tab.set_drill_down(player_data, true)
		return
	end
	if player_data.cache.item_view then item.close(nil, player_data) end
	if current_tab == "inventory_tab" then inventory_tab.set_drill_down(player_data, false) end

	local m = tab_modules[current_tab]
	if m then m.build(map_data, player_data) end
end

--- Train alerts as the Trains tab's badge.
--- @param player_data PlayerData
local function refresh_badges(player_data)
	local tab = player_data.refs.manager_trains_tab
	if not (tab and tab.valid) then return end
	local n = #collector.get().alerts
	if player_data.cache.trains_badge ~= n then
		player_data.cache.trains_badge = n
		tab.badge_text = n > 0 and tostring(n) or ""
		tab.tooltip = n > 0 and { "cybersyn-gui.trains-badge-tooltip", tostring(n) } or ""
	end
end

--- Renders the selected tab from the current snapshot and refreshes the status label.
--- @param player LuaPlayer?
--- @param player_data PlayerData
function manager.render(player, player_data)
	if not player_data.is_manager_open then return end
	-- A stop removed or a mod uninstalled since the last render: the tabs must not filter on a dead id.
	filters.validate(player_data)
	-- Every filter change ends in a render, so this is the one place the row opens with a filter and the widgets
	-- follow the stored filters.
	if filters.active(player_data) then player_data.filter_row_open = true end
	local sig = filters.signature(player_data) .. (player_data.search_open and "\1s" or "\1")
		.. (player_data.filter_row_open and "r" or "")
	if player_data.cache.filter_widgets_sig ~= sig then
		player = player or game.get_player(player_data.player_index)
		if player then
			player_data.cache.filter_widgets_sig = sig
			write_filter_widgets(player, player_data)
		end
	end
	log_tab.refresh_visibility(player_data)
	manager.update(storage, player_data)
	player_data.last_update_tick = game.tick
	player_data.rendered_snapshot_tick = collector.get().tick
	manager.update_status(player_data)
	manager.refresh_chips(player_data)
	refresh_badges(player_data)
	log_tab.refresh_badge(player_data)
end

nav.set_window_fns({
	render = function(player, player_data) manager.render(player, player_data) end,
	open = function(player, player_data) manager.handle.manager_open(player, player_data, player_data.refs) end,
	close = function(player, player_data) manager.handle.manager_close(player, player_data, player_data.refs) end,
	focus = function(player, player_data, tab, focus) manager.focus(player, player_data, tab, focus) end,
})
manager.log_tab = log_tab

manager.handle = {}

manager.wrapper = util.wrapper

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_open(player, player_data, refs)
	manager.refresh_banners(player_data)
	manager.apply_layout(player, player_data)
	refs.manager_window.visible = true
	manager.place_window(player, player_data)
	refs.manager_window.bring_to_front()

	if not player_data.pinning then
		player.opened = refs.manager_window
	end

	player_data.is_manager_open = true
	player.set_shortcut_toggled("cybersyn-toggle-gui", true)

	player_data.hover = nil
	if player_data.focus_open then
		player_data.focus_open = nil
	else
		manager.apply_surface_default(player, player_data)
	end
	-- The row opens with the window exactly when a filter is set (manager.render), so it never shows lit and empty from
	-- an earlier open.
	player_data.filter_row_open = nil
	manager.refresh_toggles(player_data)
	log_tab.restore_widgets(player_data)
	log_tab.refresh_visibility(player_data)
	if not nav.select_tab(player_data, player_data.selected_tab or DEFAULT_TAB) then
		nav.select_tab(player_data, DEFAULT_TAB)
	end

	collector.ensure_fresh()
	manager.render(player, player_data)

	-- Once per player: the analytics tabs stay hidden, and a line on every open would bury the chat.
	local analytics_setting = settings.global["cybersyn-enable-analytics"]
	if analytics_setting and analytics_setting.value and not analytics.is_library_available()
		and not player_data.analytics_notice_tick then
		player.print({ "cybersyn-gui.analytics-library-missing" })
		player_data.analytics_notice_tick = game.tick
	end
end

--- Close button and toggle shortcut: closes even when pinned.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_close(player, player_data, refs)
	cleanup(storage, player_data, player_data.selected_tab)
	-- Cleanup above runs again on reopen otherwise.
	player_data.previous_tab = nil
	player_data.search_open = nil
	item.close(player, player_data)
	explain.close(player, player_data)
	nav.close_manager_window(player, player_data, refs)
end

-- ---------------------------------------------------------------- overlays and Escape

-- An unpinned window is a standard window: it holds player.opened while open, so E and Escape reach it as
-- on_gui_closed, and another GUI taking player.opened closes it. A pinned window never holds player.opened: E and
-- Escape go past it, and its overlays close by their own buttons.

--- What Escape closes before the window, top first: the search field (open, focused or not, as the game's own search
--- boxes), Explain, the Trains detail pane. The item drill-down is the Inventory under the item filter, not an
--- overlay: Escape closes the window over it, and it shows again when the window reopens.
--- @param player_data PlayerData
--- @return "search"|"explain"|"pane"|nil
function manager.top_overlay(player_data)
	if search_shown(player_data) and search_tab(player_data) then return "search" end
	if player_data.explain then return "explain" end
	if trains_tab.pane_shown(player_data) then return "pane" end
	return nil
end

--- Closes the top overlay; returns its kind, nil when none was open.
--- @return string?
local function peel_overlay(player, player_data)
	local kind = manager.top_overlay(player_data)
	if kind == "search" then
		manager.cancel_search(player, player_data)
	elseif kind == "explain" then
		explain.close(player, player_data)
	elseif kind == "pane" then
		trains_tab.close_pane(player_data)
	end
	return kind
end

--- on_gui_closed of the window: E or Escape, or another GUI or view replacing it. With an overlay open the overlay
--- closes and the window takes player.opened straight back; if another GUI was replacing it, the engine drops the
--- window again without an event and on_gui_opened closes it (manager.on_other_gui_opened). Otherwise it closes.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_closed_by_game(player, player_data, refs)
	if not player_data.is_manager_open or player_data.pinning or nav.switching(player.index) then return end
	if peel_overlay(player, player_data) then
		manager.render(player, player_data)
		-- The API has a single opened slot and no overlay stack, so layered Escape re-takes it inside the close event.
		player.opened = refs.manager_window
		return
	end
	manager.handle.manager_close(player, player_data, refs)
end

--- on_gui_opened: a GUI the manager did not open took player.opened from an unpinned window (an entity clicked in the
--- world, the game's own windows, another mod), so the window closes as the game's windows do.
--- @param e EventData.on_gui_opened
function manager.on_other_gui_opened(e)
	if nav.switching(e.player_index) then return end
	local player_data = storage.manager and storage.manager.players[e.player_index]
	if not (player_data and player_data.is_manager_open) or player_data.pinning then return end
	local window = player_data.refs and player_data.refs.manager_window
	if not (window and window.valid) or e.element == window then return end
	local player = game.get_player(e.player_index)
	if player then manager.handle.manager_close(player, player_data, player_data.refs) end
end

--- on_gui_closed of the GUI a manager link opened (nav.open_entity): the window takes player.opened back, so the
--- next Escape closes it. Called before the combinator's handler destroys its frame, which `e.element` may be.
--- @param e EventData.on_gui_closed
function manager.on_linked_gui_closed(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	local linked = player_data and player_data.return_to
	-- The action dialog stands in front of the linked GUI for a while (repair.lua) and hands it back.
	if not linked or nav.switching(e.player_index) then return end
	if linked.valid and e.entity ~= linked and e.element ~= linked then return end
	player_data.return_to = nil
	if not player_data.is_manager_open or player_data.pinning then return end
	local player = game.get_player(e.player_index)
	local window = player_data.refs.manager_window
	if player and window.valid then player.opened = window end
end

--- Leaving the remote view that "show on map" opened, by the game's own means: Back has nothing to return to. The
--- event comes after the switch that raised it, so it is told apart by where the player is, not by nav.switching.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.on_controller_changed(player, player_data)
	if not player_data.map_from or player.controller_type == defines.controllers.remote then return end
	player_data.map_from = nil
	manager.refresh_toggles(player_data)
end

--- Back after "show on map": the view the player looked from before, with the window still open.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_back(player, player_data, refs)
	local from = player_data.map_from
	if not from then return end
	player_data.map_from = nil
	nav.switch_opened(player, function()
		local surface = game.get_surface(from.surface)
		if from.controller == defines.controllers.remote then
			-- A platform's own view is remote: Back returns to where they looked from.
			if surface then
				player.set_controller({ type = defines.controllers.remote, position = from.position, surface = surface })
			end
		elseif player.controller_type == defines.controllers.remote then
			player.exit_remote_view()
		end
		if player_data.is_manager_open and not player_data.pinning then player.opened = refs.manager_window end
	end)
	manager.refresh_toggles(player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle(player, player_data, refs)
	if player_data.is_manager_open then
		manager.handle.manager_close(player, player_data, refs)
	else
		manager.handle.manager_open(player, player_data, refs)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_titlebar_click(player, player_data, refs, e)
	if e.name == defines.events.on_gui_click and e.button == defines.mouse_button_type.middle then
		player_data.location = nil
		refs.manager_window.force_auto_center()
	end
end

--- @param e EventData.on_gui_location_changed
function manager.handle.manager_location_changed(player, player_data, refs, e)
	local window = e.element
	-- Centring a hidden window moves it too; only a position the player can see is worth keeping.
	if window and window.valid and window == refs.manager_window and window.visible and player_data.is_manager_open then
		local loc = window.location
		player_data.location = { x = loc.x, y = loc.y }
		explain.place(player, player_data)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_pause(player, player_data, refs)
	player_data.paused = not player_data.paused
	manager.refresh_toggles(player_data)
	if player_data.paused then
		manager.update_status(player_data)
	else
		manager.render(player, player_data)
	end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_pinned(player, player_data, refs)
	player_data.pinning = not player_data.pinning
	-- Back belongs to an unpinned window that "show on map" kept open.
	player_data.map_from = nil
	manager.refresh_toggles(player_data)
	if not player_data.is_manager_open then return end
	if player_data.pinning then
		-- Releasing player.opened raises on_gui_closed, which a pinned window ignores.
		if player.opened == refs.manager_window then player.opened = nil end
	else
		player.opened = refs.manager_window
	end
end

--- Opens the search field of the selected tab and gives it the keyboard; the Overview has none, so its search goes
--- to the Stations tab.
--- @param player LuaPlayer
--- @param player_data PlayerData
function manager.focus_search(player, player_data)
	-- The Inventory's drill-down has no search field (it ignores the station search): the search goes to Stations,
	-- which keeps the item filter.
	if not search_tab(player_data) then
		nav.select_tab(player_data, "stations_tab")
	end
	player_data.search_open = true
	manager.refresh_search_fields(player_data)
	local field = player_data.refs[player_data.selected_tab .. "_search_field"]
	if field and field.valid then
		field.focus()
		field.select_all()
	end
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_search(player, player_data, refs)
	if search_shown(player_data) and search_tab(player_data) then
		player_data.search_open = nil
		filters.set(player_data, "query", nil)
		manager.render(player, player_data)
	else
		manager.focus_search(player, player_data)
	end
end

--- The search custom input (linked to the game's focus-search, Ctrl+F by default): only while the window is open.
--- @param e EventData.CustomInputEvent
function manager.on_search_input(e)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	if not (player_data and player_data.is_manager_open) then return end
	local player = game.get_player(e.player_index)
	if not player then return end
	-- The input is linked to the game's focus-search, which the GUI in front gets too: a pinned window behind another
	-- GUI (a chest, the train window) leaves Ctrl+F to that GUI instead of taking the keyboard from it.
	local window = player_data.refs and player_data.refs.manager_window
	if player.opened_gui_type ~= defines.gui_type.none and player.opened ~= window then return end
	-- With no GUI open at all (a pinned window without overlays), the client turns the same keypress into the map
	-- search in remote view; taking the keyboard here would only lose it to that again.
	if player.opened_gui_type == defines.gui_type.none then return end
	manager.focus_search(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_text_changed
function manager.handle.manager_search_changed(player, player_data, refs, e)
	filters.set(player_data, "query", e.element.text)
	manager.render(player, player_data)
end

--- Escape while the search field is open: the text goes, the field closes, the window stays.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return boolean handled
function manager.cancel_search(player, player_data)
	if not (search_shown(player_data) and search_tab(player_data)) then return false end
	player_data.search_open = nil
	filters.set(player_data, "query", nil)
	manager.render(player, player_data)
	return true
end

--- The item, station or train chip (either half): any click removes that filter.
--- @param e EventData.on_gui_click
function manager.handle.manager_chip_click(player, player_data, refs, e)
	filters.set(player_data, e.element and e.element.tags.chip or "item", nil)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_toggle_filter_row(player, player_data, refs)
	if player_data.filter_row_open then
		manager.close_filter_row(player_data)
	else
		player_data.filter_row_open = true
	end
	manager.render(player, player_data)
end

--- Closes the filter row and clears its filters (its button, /cybersyn-reset-gui); the next render shows it.
--- @param player_data PlayerData
function manager.close_filter_row(player_data)
	player_data.filter_row_open = nil
	filters.clear(player_data, "row")
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
function manager.handle.manager_clear_filters(player, player_data, refs)
	-- The row's own reset leaves what the filter button leaves: the row closed with its filters gone.
	player_data.filter_row_open = nil
	filters.clear(player_data, "all")
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_elem_changed
function manager.handle.manager_update_item_search(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local signal = element.elem_value --[[@as SignalID?]]
	local named = signal and signal.name
	filters.set(player_data, "item", named and hash_signal(signal) or nil)
	if named then interface_raise_item_selected(e.player_index, signal.name) end
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_elem_changed
function manager.handle.manager_update_network_name(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local signal = element.elem_value --[[@as SignalID?]]
	filters.set(player_data, "network", signal and signal.name or nil)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_text_changed
function manager.handle.manager_update_network_mask(player, player_data, refs, e)
	filters.set(player_data, "mask", tonumber(e.text) or -1)
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_selection_state_changed
function manager.handle.manager_update_surface(player, player_data, refs, e)
	local element = e.element
	if not element then return end
	local ids = player_data.surface_dropdown_ids or {}
	filters.set(player_data, "surface", ids[element.selected_index])
	manager.render(player, player_data)
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs table<string, LuaGuiElement>
--- @param e EventData.on_gui_selected_tab_changed
function manager.handle.manager_tab_changed(player, player_data, refs, e)
	local pane = e.element
	local tab = pane.tabs[pane.selected_tab_index]
	if not tab then return end
	local name = string.match(tab.tab.name, "^manager_(.+)$")
	if name then
		player_data.selected_tab = name
		manager.render(player, player_data)
	end
end

gui.add_handlers(manager.handle, manager.wrapper)

return manager
