-- The manager window as the rest of the GUI reaches it: render, open, close and focus it, select a tab, and move
-- player.opened for the mod's own switches.

local collector = require("scripts.gui.collector")

local nav = {}

--- @class WindowFns
--- @field render fun(player: LuaPlayer?, player_data: PlayerData)
--- @field open fun(player: LuaPlayer, player_data: PlayerData)
--- @field close fun(player: LuaPlayer, player_data: PlayerData)
--- @field focus fun(player: LuaPlayer, player_data: PlayerData, tab: string, focus: ManagerFocus)

--- @type WindowFns?
local window_fns

--- manager.lua requires every tab and every tab re-renders through here, so the window's functions are handed in
--- once manager.lua has loaded instead of required.
--- @param fns WindowFns
function nav.set_window_fns(fns)
	window_fns = fns
end

--- Re-renders the selected tab now instead of waiting for the next manager update.
--- @param player LuaPlayer?
--- @param player_data PlayerData
function nav.rerender(player, player_data)
	if window_fns then window_fns.render(player, player_data) end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
function nav.open(player, player_data)
	if window_fns then window_fns.open(player, player_data) end
end

--- Closes the window the way its close button does, pinned or not.
--- @param player LuaPlayer
--- @param player_data PlayerData
function nav.close(player, player_data)
	if window_fns then window_fns.close(player, player_data) end
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param tab string
--- @param focus ManagerFocus
function nav.focus(player, player_data, tab, focus)
	if window_fns then window_fns.focus(player, player_data, tab, focus) end
end

-- Players whose player.opened the mod itself is moving (nav.switch_opened). Not saved: the engine raises the
-- on_gui_closed and on_gui_opened of such a move inside the assignment, so the flag never outlives one call.
local switching = {}

--- Runs `move`, which changes what player.opened is (a link opening an entity, the action dialog, show on map), so
--- that the manager's on_gui_closed and on_gui_opened handlers know the switch is the mod's and not the player's.
--- Desync-safe: the flag is set and cleared within one call on every peer. Only the mod's own moves that the close and
--- open handlers must ignore go through here; those handlers' own re-takes of player.opened stay outside it.
--- @param player LuaPlayer
--- @param move fun()
function nav.switch_opened(player, move)
	switching[player.index] = true
	move()
	switching[player.index] = nil
end

--- @param player_index uint
--- @return boolean
function nav.switching(player_index)
	return switching[player_index] == true
end


--- Switches the tabbed pane and keeps `player_data.selected_tab` in sync (setting the index raises no event).
--- @param player_data PlayerData
--- @param tab string e.g. "stations_tab"
--- @return boolean found
function nav.select_tab(player_data, tab)
	local pane = player_data.refs and player_data.refs.manager_tabbed_pane
	if not pane or not pane.valid then return false end
	for i, t in ipairs(pane.tabs) do
		if t.tab.name == "manager_" .. tab then
			pane.selected_tab_index = i
			player_data.selected_tab = tab
			return true
		end
	end
	return false
end

--- Opens the manager on `tab` (the trains-window button, a HUD click), or switches an open one to it.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param tab string
function nav.open_manager_on(player, pd, tab)
	pd.selected_tab = tab
	if pd.is_manager_open then
		nav.select_tab(pd, tab)
		local window = pd.refs and pd.refs.manager_window
		if not pd.pinning and window and window.valid then player.opened = window end
		nav.rerender(player, pd)
	else
		nav.open(player, pd)
	end
end

--- The title bar's Back button shows while there is a view to return to.
--- @param player_data PlayerData
function nav.refresh_back(player_data)
	local back = player_data.refs and player_data.refs.manager_back_button
	if back and back.valid then back.visible = player_data.map_from ~= nil end
end

--- Opens an entity's GUI from a manager link. An unpinned manager stays on screen and takes player.opened back when
--- that GUI closes (manager.on_linked_gui_closed), so a second Escape closes the manager.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param entity LuaEntity
function nav.open_entity(player, player_data, entity)
	nav.switch_opened(player, function() player.opened = entity end)
	if player_data.pinning or not player_data.is_manager_open then return end
	local window = player_data.refs.manager_window
	if player.opened_gui_type == defines.gui_type.none then
		player.opened = window
	elseif player.opened ~= window then
		-- What holds player.opened now, not the entity: Cybersyn's combinator replaces the entity's window with its own.
		player_data.return_to = player.opened
	end
end

--- Hides the window and drops what only an open window needs, pinned or not (manager.handle.manager_close).
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param refs {[string]: LuaGuiElement}
function nav.close_manager_window(player, player_data, refs)
	refs.manager_window.visible = false
	-- Cleared first: releasing player.opened re-enters the close path through on_gui_closed.
	player_data.is_manager_open = false
	player_data.return_to = nil
	player_data.map_from = nil
	player_data.hover = nil
	-- Render signatures and row memos only skip redundant updates, and the memos reference snapshot records, so
	-- they are not worth keeping in the save while closed; a container without them updates every child once on
	-- the next render.
	local states = player_data.gui_state
	if states then
		for _, state in pairs(states) do
			state.sigs = nil
			state.cells = nil
			state.content_sigs = nil
		end
	end

	if player.opened == refs.manager_window then
		player.opened = nil
	end

	player.set_shortcut_toggled("cybersyn-toggle-gui", false)
	collector.on_last_close()
	-- The Stations query cache stays with a kept snapshot: a reopen folds in what changed instead of classifying and
	-- sorting every station in its first paint (12-15 ms on a 2,000-station base). collector.release drops it.
	player_data.cache = { stations = storage.manager.release_at and player_data.cache.stations or nil }
end

return nav
