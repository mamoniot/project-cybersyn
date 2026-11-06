-- The permission rule for everything that changes game state from a command or the manager.
-- The check runs in the handler against player.admin, which is synchronised, so every peer reaches the same answer;
-- a disabled button proves nothing. Every allowed action is audited three ways: a manual_action event while the
-- diagnostics log exists, log() always, and one line to the force, which is the trail that survives diagnostics off.

local diag = require("scripts.diag")

local actions = {}

--- @return string "admins"|"everyone"|"nobody"
function actions.setting()
	return mod_settings.manager_actions or "admins"
end

--- Whether `player` may change game state. Single player is always allowed; the server console (no player) counts
--- as an admin.
--- @param player LuaPlayer?
--- @return boolean
function actions.may_act(player)
	if not game.is_multiplayer() then return true end
	local setting = actions.setting()
	if setting == "nobody" then return false end
	if setting == "everyone" then return true end
	if not player then return true end
	return player.admin == true
end

--- Prints the refusal to the player (or the console) and returns false.
--- @param player LuaPlayer?
--- @param what string the command or action, as the player typed or saw it
--- @return boolean
function actions.refuse(player, what)
	local text = { "cybersyn-messages.action-refused", what, { "string-mod-setting.cybersyn-manager-actions-" .. actions.setting() } }
	-- A refusal is for the caller only; without a player that is the RCON client (the log keeps it either way).
	if player and player.valid then player.print(text) else rcon.print(text) end
	log({ "", "Cybersyn: refused ", what, " for ", player and player.name or "the server console" })
	return false
end

--- @param player LuaPlayer?
--- @param what string
--- @return boolean allowed
function actions.check(player, what)
	if actions.may_act(player) then return true end
	return actions.refuse(player, what)
end

--- Records an action that changed game state.
--- @param action DiagAction
--- @param target uint? the entity or train it applied to; nil = all of them
--- @param player LuaPlayer?
--- @param what LocalisedString the command or action, as the player typed or saw it
--- @param line LocalisedString? the chat line; default "<player> ran <what>"
--- @param train_id uint? the train it applied to, for the event's train column
--- @param station_id uint? the stop it applied to, for the event's station column
--- @param private boolean? print the line to the player only (a read-only action anyone may run)
function actions.audit(action, target, player, what, line, train_id, station_id, private)
	local index = player and player.valid and player.index or 0
	local name = player and player.valid and player.name or "server"
	diag.manual_action(action, target, index, train_id, station_id)
	log({ "", "Cybersyn: ", name, " ran ", what, " (", ACTION_NAMES[action] or tostring(action), ", target ",
		tostring(target or "all"), ")" })
	local text = line or { "cybersyn-messages.action-audit", name, what }
	if player and player.valid then
		if private then player.print(text) else player.force.print(text) end
	else
		game.print(text)
	end
end

return actions
