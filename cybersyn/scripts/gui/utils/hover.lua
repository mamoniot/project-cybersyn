local gui = require("__flib__.gui")

local util = require("scripts.gui.util")

local hover = {}

hover.handle = {}

hover.HOVER_HOLD_TICKS = 600

--- @param player_data PlayerData
--- @param e EventData.on_gui_hover
function hover.handle.hover_enter(player, player_data, refs, e)
	local elem = e.element
	if not elem or not elem.valid then return end
	player_data.hover = { tick = game.tick, scope = elem.tags.hover_scope, index = elem.index }
	-- A pointer that arrives after a row-changing click in the same tick holds the rows it now rests on.
	player_data.hold_released_tick = nil
end

--- @param player_data PlayerData
--- @param e EventData.on_gui_leave
function hover.handle.hover_leave(player, player_data, refs, e)
	local cur = player_data.hover
	-- A leave can arrive after the hover of the next element; only clear our own.
	if cur and e.element and e.element.valid and cur.index == e.element.index then
		player_data.hover = nil
	end
end

--- Merges the hover/leave handlers into an element's handler table.
--- A bare function handler would fire on hover events too, so a function is treated as on_gui_click.
--- @param handlers (function|table<defines.events, function>)?
--- @return table<defines.events, function>
function hover.with_hover(handlers)
	local out = {}
	if type(handlers) == "function" then
		out[defines.events.on_gui_click] = handlers
	elseif handlers then
		for k, v in pairs(handlers) do
			out[k] = v
		end
	end
	out[defines.events.on_gui_hover] = hover.handle.hover_enter
	out[defines.events.on_gui_leave] = hover.handle.hover_leave
	return out
end

--- Makes an element definition hover-aware for `scope` (normally the name of the container passed to sync_children).
--- An element destroyed, rebuilt or moved under the cursor loses the click or hands it to another row, and Factorio
--- has no "leave alone while hovered" option, so the hover events drive a hold that defers structural changes.
--- @param def flib.GuiElemDef Modified in place and returned.
--- @param scope string
--- @return flib.GuiElemDef
function hover.hoverable(def, scope)
	def.raise_hover_events = true
	local tags = def.tags or {}
	tags.hover_scope = scope
	def.tags = tags
	def.handler = hover.with_hover(def.handler)
	return def
end

--- True while the cursor is over an element of `scope`. The API cannot report the cursor position, so three patches
--- keep the recorded hover honest: HOVER_HOLD_TICKS ends a hold whose leave never arrives (a destroyed or rebuilt element
--- raises no on_gui_leave); release_hold lifts it for the rest of the tick of a row-changing click, until the next
--- hover_enter; touch_hover restarts the timeout on clicks, so repeated clicks on one element keep the hold.
--- @param player_data PlayerData
--- @param scope string
--- @param ticks uint? the timeout, hover.HOVER_HOLD_TICKS by default
--- @return boolean
function hover.hold_active(player_data, scope, ticks)
	local cur = player_data.hover
	return cur ~= nil and cur.scope == scope and game.tick - cur.tick < (ticks or hover.HOVER_HOLD_TICKS)
		and player_data.hold_released_tick ~= game.tick
end

--- A click whose purpose is to change the rows (an acknowledgement, a show/hide toggle) renders them in its own event.
--- The hover stays recorded: the pointer is still on the table, so the hold protects the rows that slid under it from
--- the next tick on.
--- @param player_data PlayerData
function hover.release_hold(player_data)
	player_data.hold_released_tick = game.tick
end

--- A click proves the cursor is still on a hoverable element, so it restarts the hold timeout; repeated
--- shift-clicks on one slot would otherwise lose the hold after HOVER_HOLD_TICKS.
--- @param e EventData.on_gui_click
function hover.touch_hover(e)
	local elem = e.element
	if not (elem and elem.valid) then return end
	local scope = elem.tags.hover_scope
	if not scope then return end
	local manager_data = storage.manager
	local player_data = manager_data and manager_data.players[e.player_index]
	if not player_data then return end
	local cur = player_data.hover
	if cur and cur.scope == scope and cur.index == elem.index then
		cur.tick = game.tick
	else
		player_data.hover = { tick = game.tick, scope = scope, index = elem.index }
	end
end

gui.add_handlers(hover.handle, util.wrapper, "cybersyn_hover")

return hover
