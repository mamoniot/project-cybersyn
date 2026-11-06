-- Manager extras that only read game state: the path trace, pins, the button in the
-- vanilla trains window and the opt-in HUD line. Actions that change game state live in repair.lua.

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local nav = require("scripts.gui.utils.nav")
local logic = require("scripts.gui.extras-logic")
local utext = require("scripts.gui.unserved-text")
local diag = require("scripts.diag")
local stats = require("scripts.stats")

local extras = {}
extras.handle = {}

local PANEL = "cybersyn_relative_panel"
local TRAINS_ANCHOR = "cybersyn_trains_gui"
local HUD = "cybersyn_hud"
local TRACE_COLOR = { 0.25, 0.8, 1, 0.9 }
-- Not a multiple of the usual manager intervals (60, 30, 20, ... ticks), so a HUD refresh seldom shares their tick.
local HUD_TICKS = 301
extras.HUD_TICKS = HUD_TICKS

--- The subject of the relative panel an element sits in ({kind, id} tags of relative.build's frame).
--- @param elem LuaGuiElement
--- @return string? kind "stop"|"train"
--- @return uint? id
function extras.panel_subject(elem)
	while elem and elem.valid do
		if elem.name == PANEL then
			local tags = elem.tags
			return tags.kind, tags.id
		end
		elem = elem.parent
	end
	return nil, nil
end

local stop_record = util.stop_record

--- @param id uint
--- @return LuaTrain?
local function lua_train(id)
	local train = storage.trains[id]
	local entity = train and train.entity
	if entity and entity.valid then return entity end
	return nil
end

-- ---------------------------------------------------------------- path trace

--- Destroys the player's trace (button pressed again, another train selected, or time out).
--- @param pd PlayerData
function extras.clear_path_trace(pd)
	local t = pd.path_trace
	if not t then return end
	for _, id in ipairs(t.ids) do
		local obj = rendering.get_object_by_id(id)
		if obj and obj.valid then obj.destroy() end
	end
	pd.path_trace = nil
end

--- A panel or pane selected another subject: a trace of a different train goes.
--- @param pd PlayerData
--- @param kind string?
--- @param id uint?
function extras.on_selection(pd, kind, id)
	local t = pd.path_trace
	if t and not (kind == "train" and id == t.train_id) then extras.clear_path_trace(pd) end
end

--- Draws the rest of a train's path (from the rail it is on) as collinear runs, in both render modes, for this player
--- only, for TRACE_TICKS. Returns nil and a reason when the train has no path.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param train_id uint
--- @return table? trace
--- @return LocalisedString? why not
function extras.draw_path_trace(player, pd, train_id)
	extras.clear_path_trace(pd)
	local entity = lua_train(train_id)
	if not entity then return nil, { "cybersyn-message.error-train-is-invalid" } end
	local path = entity.path
	if not (path and path.valid and path.size > 0) then return nil, { "cybersyn-gui.path-trace-none" } end
	local rails = path.rails
	local size = path.size
	local xs, ys, n = {}, {}, 0
	for i = math.max(1, path.current), size do
		local rail = rails[i]
		if rail and rail.valid then
			local p = rail.position
			n = n + 1
			xs[n], ys[n] = p.x, p.y
		end
	end
	local vx, vy, runs = logic.sample_runs(xs, ys, n)
	local surface = entity.front_stock.surface
	local ids = {}
	local def = {
		color = TRACE_COLOR,
		width = 4,
		surface = surface,
		players = { player },
		time_to_live = logic.TRACE_TICKS,
		from = { 0, 0 },
		to = { 0, 0 },
	}
	for _, mode in ipairs({ "game", "chart" }) do
		def.render_mode = mode
		def.width = mode == "game" and 6 or 8
		for i = 1, #vx - 1 do
			def.from = { vx[i], vy[i] }
			def.to = { vx[i + 1], vy[i + 1] }
			ids[#ids + 1] = rendering.draw_line(def).id
		end
	end
	local trace = { train_id = train_id, ids = ids, until_tick = game.tick + logic.TRACE_TICKS, rails = n, runs = runs,
		segments = #vx - 1, size = size }
	pd.path_trace = trace
	return trace
end

--- Path trace button: draws the trace, or removes it when it shows this train already.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param train_id uint
function extras.toggle_path_trace(player, pd, train_id)
	if extras.trace_shown(pd, train_id) then
		extras.clear_path_trace(pd)
		return
	end
	local trace, why = extras.draw_path_trace(player, pd, train_id)
	if not trace then util.error_flying_text(player, why) end
end

--- @param pd PlayerData
--- @param train_id uint
--- @return boolean
function extras.trace_shown(pd, train_id)
	local t = pd.path_trace
	return t ~= nil and t.train_id == train_id and game.tick < t.until_tick
end

-- ---------------------------------------------------------------- pins

--- Pins a stop (backer name) or a train ("#<id>", on its front stock) on the player's map.
--- @param player LuaPlayer
--- @param kind string "station"|"depot"|"refueler"|"stop"|"train"
--- @param id uint
--- @return boolean pinned
function extras.add_pin(player, kind, id)
	local entity, label
	if kind == "train" then
		local train = lua_train(id)
		entity = train and train.front_stock
		-- A pin's label is a plain string (no LocalisedString), so not a word of any language: "#<id>".
		label = "#" .. tostring(id)
	else
		entity = stop_record(id)
		label = entity and entity.backer_name
	end
	if not (entity and entity.valid) then
		util.error_flying_text(player, { kind == "train" and "cybersyn-message.error-train-is-invalid"
			or "cybersyn-message.error-station-is-invalid" })
		return false
	end
	player.add_pin({ entity = entity, label = label })
	player.create_local_flying_text({ text = { "cybersyn-gui.pin-added", label }, create_at_cursor = true })
	return true
end

-- ---------------------------------------------------------------- relative panel tools

local function tool(name, sprite, tooltip, handler, toggled, enabled)
	return {
		type = "sprite-button",
		name = name,
		style = "tool_button",
		sprite = sprite,
		tooltip = tooltip,
		toggled = toggled or nil,
		enabled = enabled ~= false,
		handler = { [defines.events.on_gui_click] = handler },
	}
end

--- Tool buttons for the stop panel's first footer row.
--- @return flib.GuiElemDef[]
function extras.stop_tools()
	return {
		tool("pin", "utility/custom_tag_in_map_view", { "cybersyn-gui.relative-pin-tooltip" }, extras.handle.extras_pin),
	}
end

--- Tool buttons for the train panel's action row.
--- @param pd PlayerData
--- @param train_id uint
--- @return flib.GuiElemDef[]
function extras.train_tools(pd, train_id)
	return {
		tool("path_trace", "utility/gps_map_icon", { "cybersyn-gui.relative-path-trace-tooltip" },
			extras.handle.extras_path_trace, extras.trace_shown(pd, train_id)),
		tool("pin", "utility/custom_tag_in_map_view", { "cybersyn-gui.relative-pin-tooltip" }, extras.handle.extras_pin),
	}
end

--- Part of the footer's signature that these tools change.
--- @param pd PlayerData
--- @param kind string
--- @param id uint
--- @return string
function extras.tools_sig(pd, kind, id)
	if kind == "train" then return extras.trace_shown(pd, id) and "t" or "" end
	return ""
end

function extras.handle.extras_path_trace(player, pd, refs, e)
	local kind, id = extras.panel_subject(e.element)
	if kind ~= "train" then return end
	extras.toggle_path_trace(player, pd, id)
	nav.rerender(player, pd)
	if extras.on_change then extras.on_change(player, pd) end
end

function extras.handle.extras_pin(player, pd, refs, e)
	local kind, id = extras.panel_subject(e.element)
	if not kind then return end
	extras.add_pin(player, kind == "train" and "train" or "stop", id)
end

-- ---------------------------------------------------------------- trains_gui anchor

--- The "Open Cybersyn manager" button above the vanilla trains window, created once per player.
--- @param player LuaPlayer
function extras.ensure_trains_anchor(player)
	local root = player.gui.relative
	local frame = root[TRAINS_ANCHOR]
	if frame and frame.valid then return end
	gui.add(root, {
		type = "frame",
		name = TRAINS_ANCHOR,
		style = "cybersyn_trains_anchor_frame",
		anchor = { gui = defines.relative_gui_type.trains_gui, position = defines.relative_gui_position.top },
		{
			type = "button",
			name = "open_manager",
			caption = { "cybersyn-gui.trains-gui-open-manager" },
			tooltip = { "cybersyn-gui.trains-gui-open-manager-tooltip" },
			handler = { [defines.events.on_gui_click] = extras.handle.extras_trains_gui_open },
		},
	})
end

--- @param player LuaPlayer
function extras.reset_trains_anchor(player)
	local frame = player.gui.relative[TRAINS_ANCHOR]
	if frame and frame.valid then frame.destroy() end
	extras.ensure_trains_anchor(player)
end

function extras.handle.extras_trains_gui_open(player, pd)
	nav.open_manager_on(player, pd, "trains_tab")
end

-- ---------------------------------------------------------------- HUD line

--- @param player LuaPlayer
--- @param pd PlayerData
--- @return boolean
local function hud_wanted(player, pd)
	if pd.hud_on == nil then
		local s = settings.get_player_settings(player)["cybersyn-manager-hud"]
		pd.hud_on = s ~= nil and s.value == true
	end
	return pd.hud_on
end

--- The HUD's two labelled numbers. The keys are bare labels, not "label __1__" templates, because the Overview's Fleet
--- headroom tile sets its "Now" line as a separate label and value: it uses `hud-headroom-now` as that label, so the
--- tile and the HUD say one thing in the same words.
--- @param unserved string
--- @param free string
--- @return LocalisedString
function extras.hud_line(unserved, free)
	return { "", { "cybersyn-gui.hud-unserved" }, " ", unserved, " · ", { "cybersyn-gui.hud-headroom-now" }, " ", free }
end

--- The HUD's two captions, from diag.counts_by_reason() and the per-network train counters; nothing here wakes the
--- collector.
--- @return LocalisedString line1
--- @return LocalisedString line2
function extras.hud_text()
	local d = storage.diag
	local s = stats.get()
	local v = logic.hud_values(diag.counts_by_reason(), s.available_count, s.trains_by_network)
	local headroom = v.headroom and format.number(v.headroom) or utext.NO_VALUE
	local line2
	if not d then
		line2 = { "cybersyn-gui.hud-diag-off" }
	elseif v.unserved == 0 then
		line2 = { "cybersyn-gui.hud-all-served" }
	else
		line2 = { "cybersyn-gui.hud-top", utext.chip_caption(v.top_reason), format.number(v.top_count) }
	end
	return extras.hud_line(d and format.number(v.unserved) or utext.NO_VALUE, headroom), line2
end

--- @param player LuaPlayer
--- @param pd PlayerData
--- @return LuaGuiElement
local function hud_frame(player, pd)
	local frame = player.gui.screen[HUD]
	if frame and frame.valid then return frame end
	local _, f = gui.add(player.gui.screen, {
		type = "frame",
		name = HUD,
		style = "cybersyn_hud_frame",
		direction = "horizontal",
		handler = { [defines.events.on_gui_location_changed] = extras.handle.extras_hud_moved },
		{ type = "empty-widget", name = "drag", style = "cybersyn_hud_drag" },
		{
			type = "flow",
			name = "lines",
			direction = "vertical",
			style_mods = { vertical_spacing = 0 },
			{ type = "label", name = "line1", style = "cybersyn_hud_label", tooltip = { "cybersyn-gui.hud-tooltip" },
				handler = { [defines.events.on_gui_click] = extras.handle.extras_hud_click } },
			{ type = "label", name = "line2", style = "cybersyn_hud_note", tooltip = { "cybersyn-gui.hud-tooltip" },
				handler = { [defines.events.on_gui_click] = extras.handle.extras_hud_click } },
		},
	})
	f.drag.drag_target = f
	local loc = pd.hud_location
	if loc then
		f.location = loc
	else
		local scale = player.display_scale
		f.location = { x = math.floor(12 * scale), y = math.floor(player.display_resolution.height * 0.5) }
	end
	return f
end

--- Shows, refreshes or removes one player's HUD.
--- @param player LuaPlayer
--- @param pd PlayerData
function extras.hud_refresh(player, pd)
	if not hud_wanted(player, pd) then
		local frame = player.gui.screen[HUD]
		if frame and frame.valid then frame.destroy() end
		return
	end
	local frame = hud_frame(player, pd)
	local l1, l2 = extras.hud_text()
	frame.lines.line1.caption = l1
	frame.lines.line2.caption = l2
end

--- Every HUD_TICKS (registered unconditionally in scripts/main.lua): connected players with the setting on.
function extras.hud_tick()
	local manager_data = storage.manager
	if not manager_data then return end
	for i, pd in pairs(manager_data.players) do
		local player = game.get_player(i)
		if player and player.connected and (pd.hud_on ~= false) then extras.hud_refresh(player, pd) end
	end
end

--- The per-user setting changed: read it again and apply it now.
--- @param player LuaPlayer
--- @param pd PlayerData
function extras.hud_setting_changed(player, pd)
	pd.hud_on = nil
	extras.hud_refresh(player, pd)
end

function extras.handle.extras_hud_moved(player, pd, refs, e)
	local loc = e.element.location
	if loc then pd.hud_location = { x = loc.x, y = loc.y } end
end

function extras.handle.extras_hud_click(player, pd)
	nav.open_manager_on(player, pd, "overview_tab")
end

-- ---------------------------------------------------------------- manager tick

--- Drops a trace whose objects timed out.
--- @param manager_data Manager
function extras.tick(manager_data)
	local now = game.tick
	for _, pd in pairs(manager_data.players) do
		local t = pd.path_trace
		if t and now >= t.until_tick then pd.path_trace = nil end
	end
end

--- @param player LuaPlayer
--- @param pd PlayerData
function extras.reset(player, pd)
	extras.clear_path_trace(pd)
	extras.reset_trains_anchor(player)
	local hud = player.gui.screen[HUD]
	if hud and hud.valid then hud.destroy() end
	pd.hud_on = nil
end

extras.wrapper = util.wrapper

gui.add_handlers(extras.handle, extras.wrapper, "cybersyn_extras")

return extras
