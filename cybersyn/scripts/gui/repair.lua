-- Repair actions: the manager's buttons that change dispatcher or train state. Each
-- runs an existing code path for one entity per click, behind the `cybersyn-manager-actions` rule (checked in the
-- click handler, never trusted from a disabled button), a confirm step, and the audit trail of actions.audit.
--   Fail delivery and send home   on_failed_delivery + the depot schedule (train panel)
--   Recount deliveries            one station's delivery counters from the trains bound to it (stop panel, on the
--                                 counter-leak finding only)
--   Refresh allow-lists           update_train_layout per train, chunked by trains and stop visits (console command)

local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local logic = require("scripts.gui.extras-logic")
local actions = require("scripts.actions")
local lint = require("scripts.lint")

--- @class RepairJob
--- @field ids uint[] train ids at the start, in storage order
--- @field i int done so far
--- @field player_index uint 0 = the console
--- @field refreshed int

local repair = {}
repair.handle = {}

--- @param id uint
--- @return Train?
local function train_record(id)
	local train = storage.trains[id]
	if train and train.entity and train.entity.valid then return train end
	return nil
end

--- Whether the Fail delivery button has something to act on: a train on a delivery.
--- @param id uint
--- @return boolean
function repair.can_fail(id)
	local train = train_record(id)
	return train ~= nil and train.manifest ~= nil and STATUS_ON_DELIVERY[train.status] == true
end

--- Whether Recount deliveries has a station to act on. The combinators too: recount writes comb2's output, and an
--- invalid comb1/comb2 still attached is the state in which on_failed_delivery skips its decrement.
--- @param id uint
--- @return boolean
function repair.can_recount(id)
	local station = storage.stations[id]
	if not (station and station.entity_stop and station.entity_stop.valid) then return false end
	local comb1, comb2 = station.entity_comb1, station.entity_comb2
	return comb1 ~= nil and comb1.valid and (comb2 == nil or comb2.valid)
end

--- Whether the last lint pass still has a counter-leak finding on the station. The click checks it again because the
--- button can outlive the finding until the panel's next refresh.
--- @param id uint
--- @return boolean
function repair.has_leak(id)
	for _, f in ipairs(lint.findings()) do
		if f.id == id and f.subject ~= LINT_SUBJECT_TRAIN and logic.is_counter_leak(f) then return true end
	end
	return false
end

-- ---------------------------------------------------------------- the actions

--- Ends the train's delivery (on_failed_delivery: manifests off both stations, wagon filters cleared, the
--- failure logged) and sends it to its depot, as a train coming back from a requester does.
--- @param train_id uint
--- @return boolean done
--- @return LocalisedString? why not
function repair.fail_delivery(train_id)
	local train = train_record(train_id)
	if not (train and repair.can_fail(train_id)) then return false, { "cybersyn-gui.action-no-delivery" } end
	local depot = train.depot_id and storage.depots[train.depot_id]
	local depot_stop = depot and depot.entity_stop
	if not (depot_stop and depot_stop.valid) then return false, { "cybersyn-gui.action-no-depot" } end
	local old_status = train.status
	on_failed_delivery(storage, train_id, train, DIAG_FAIL_MANUAL)
	set_depot_schedule(train.entity, depot_stop.backer_name)
	send_train_to_depot(storage, train_id, train, old_status)
	return true
end

--- Sets one station's `deliveries_total` and `deliveries` to what the trains bound to it account for, then refreshes
--- what the dispatcher derives from them: the comb2 output and the "deliveries pending" bit of the stop's display.
--- @param station_id uint
--- @return {total: int, deliveries: {[string]: int}}? before nil when the station is gone
--- @return {total: int, deliveries: {[string]: int}, trains: uint[]}? after
function repair.recount(station_id)
	if not repair.can_recount(station_id) then return nil, nil end
	local station = storage.stations[station_id]
	local copy = {}
	for h, n in pairs(station.deliveries or {}) do copy[h] = n end
	local before = { total = station.deliveries_total or 0, deliveries = copy }
	local total, deliveries, ids = logic.recount(storage.trains, station_id, hash_item)
	station.deliveries_total = total
	station.deliveries = deliveries
	set_comb2(storage, station)
	if total == 0 and bit32.band(station.display_state, 1) > 0 then
		station.display_state = station.display_state - 1
		update_display(storage, station)
	elseif total > 0 and bit32.band(station.display_state, 1) == 0 then
		station.display_state = station.display_state + 1
		update_display(storage, station)
	end
	return before, { total = total, deliveries = deliveries, trains = ids }
end

--- @param player LuaPlayer?
function repair.start_allow_job(player)
	local ids = {}
	for id in pairs(storage.trains) do ids[#ids + 1] = id end
	storage.manager.repair_job = { ids = ids, i = 0, player_index = player and player.index or 0, refreshed = 0 }
end

--- One chunk of the Refresh allow-lists job (manager_gui.repair_tick).
function repair.job_tick()
	local m = storage.manager
	local job = m and m.repair_job
	if not job then return end
	local total = #job.ids
	local stops = table_size(storage.stations) + table_size(storage.refuelers)
	local counts = storage.layout_train_count
	local k, n, spent = job.i, 0, 0
	while k < total do
		local train = train_record(job.ids[k + 1])
		local cost = train and logic.job_cost((counts[train.layout_id] or 0) <= 1, stops) or 0
		if not logic.job_continue(n, spent, cost) then break end
		k = k + 1
		if train then
			update_train_layout(storage, train)
			job.refreshed = job.refreshed + 1
			n = n + 1
			spent = spent + cost
		end
	end
	local done = k >= total
	job.i = k
	if done then
		m.repair_job = nil
		local player = job.player_index > 0 and game.get_player(job.player_index) or nil
		local text = { "cybersyn-messages.audit-allow-lists-done", tostring(job.refreshed) }
		log({ "", "Cybersyn: refreshed the allow-lists of ", tostring(job.refreshed), " trains" })
		if player and player.valid then player.force.print(text) else game.print(text) end
	end
end

-- ---------------------------------------------------------------- confirm buttons

--- The button for a one-entity action: "Confirm?" in red while armed, disabled with "Admin only" for a player
--- without the right, disabled when there is nothing to act on.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param name string element name
--- @param key string confirm key
--- @param caption LocalisedString
--- @param tooltip LocalisedString
--- @param handler function
--- @param applicable boolean
--- @param idle_tooltip LocalisedString? tooltip when not applicable
--- @return flib.GuiElemDef
function repair.confirm_button(player, pd, name, key, caption, tooltip, handler, applicable, idle_tooltip)
	local allowed = actions.may_act(player)
	local armed = allowed and applicable and logic.confirm_armed(pd.confirm, key, game.tick)
	return {
		type = "button",
		name = name,
		style = armed and "red_button" or "button",
		style_mods = { minimal_width = 0, left_padding = 8, right_padding = 8 },
		caption = armed and { "cybersyn-gui.action-confirm" } or caption,
		tooltip = not allowed and { "cybersyn-gui.action-admin-only" } or (not applicable and idle_tooltip)
			or (armed and { "cybersyn-gui.action-confirm-tooltip" }) or tooltip,
		enabled = allowed and applicable,
		tags = { action_key = key },
		handler = { [defines.events.on_gui_click] = handler },
	}
end

--- Second footer row of the train panel: `lead` (the pane's Locate), Send home, then `tools` (read-only, extras.lua).
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param train_id uint
--- @param tools flib.GuiElemDef[]?
--- @param lead flib.GuiElemDef?
--- @return flib.GuiElemDef
function repair.train_row(player, pd, train_id, tools, lead)
	local row = {
		type = "flow",
		name = "actions",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4 },
		repair.confirm_button(player, pd, "fail_delivery", "fail:" .. train_id, { "cybersyn-gui.action-fail-delivery" },
			{ "cybersyn-gui.action-fail-delivery-tooltip" }, repair.handle.repair_fail_click, repair.can_fail(train_id),
			{ "cybersyn-gui.action-no-delivery" }),
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
	}
	for _, def in ipairs(tools or {}) do row[#row + 1] = def end
	if lead then table.insert(row, 1, lead) end
	return row
end

--- The part of a panel footer's signature these rows depend on.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param kind string
--- @param id uint
--- @return string
function repair.sig(player, pd, kind, id)
	if kind ~= "train" then return "" end
	local armed = logic.confirm_armed(pd.confirm, "fail:" .. id, game.tick)
	return (actions.may_act(player) and "a" or "n") .. (armed and "c" or "") .. (repair.can_fail(id) and "y" or "")
end

--- The Recount deliveries button of the stop panel's counter-leak finding.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param station_id uint
--- @return flib.GuiElemDef
function repair.recount_button(player, pd, station_id)
	return repair.confirm_button(player, pd, "recount_deliveries", "recount:" .. station_id,
		{ "cybersyn-gui.action-recount" }, { "cybersyn-gui.action-recount-tooltip" }, repair.handle.repair_recount_click,
		repair.can_recount(station_id))
end

--- The part of the stop panel's Setup signature the Recount button depends on.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param station_id uint
--- @return string
function repair.recount_sig(player, pd, station_id)
	local armed = logic.confirm_armed(pd.confirm, "recount:" .. station_id, game.tick)
	return (actions.may_act(player) and "a" or "n") .. (armed and "c" or "")
end

--- A click on a confirm button: arms it, or on the second click checks the right again and runs `run`.
--- @return boolean fired
local function confirm_click(player, pd, e, what, run)
	local key = e.element.tags.action_key
	if not key then return false end
	if not actions.check(player, what) then
		pd.confirm = nil
		return false
	end
	local state, fire = logic.confirm_click(pd.confirm, key, game.tick)
	pd.confirm = state
	if state then storage.manager.confirm_any = true end
	if fire then run() end
	if repair.on_change then repair.on_change(player, pd) end
	return fire
end
repair.confirm_click = confirm_click

function repair.handle.repair_fail_click(player, pd, refs, e)
	local kind, id = repair.subject(e.element)
	if kind ~= "train" then return end
	confirm_click(player, pd, e, "fail delivery", function()
		local train = train_record(id)
		local tag = train and train_richtext(train.entity) or ("train " .. id)
		local ok, why = repair.fail_delivery(id)
		if not ok then
			util.error_flying_text(player, why)
			return
		end
		actions.audit(ACTION_FAIL_DELIVERY, id, player, { "cybersyn-gui.action-fail-delivery" },
			{ "cybersyn-messages.audit-fail-delivery", player.name, tag }, id, nil)
	end)
end

--- Text of a station's per-item counters for the force line: "iron-plate 400, coal -50" in hash order, or "–".
local function deliveries_text(deliveries)
	local keys = {}
	for h in pairs(deliveries) do keys[#keys + 1] = h end
	table.sort(keys)
	for i, h in ipairs(keys) do keys[i] = h .. " " .. tostring(deliveries[h]) end
	return #keys > 0 and table.concat(keys, ", ") or "–"
end

function repair.handle.repair_recount_click(player, pd, refs, e)
	local kind, id = repair.subject(e.element)
	if kind ~= "stop" then return end
	if not repair.has_leak(id) then
		pd.confirm = nil
		util.error_flying_text(player, { "cybersyn-gui.action-recount-no-leak" })
		return
	end
	confirm_click(player, pd, e, "recount deliveries", function()
		if not repair.has_leak(id) then
			util.error_flying_text(player, { "cybersyn-gui.action-recount-no-leak" })
			return
		end
		local stop = storage.stations[id] and storage.stations[id].entity_stop
		local before, after = repair.recount(id)
		if not (before and after) then
			util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
			return
		end
		local tag = stop and stop.valid and entity_richtext(stop) or tostring(id)
		actions.audit(ACTION_RECOUNT_DELIVERIES, id, player, { "cybersyn-gui.action-recount" },
			{ "cybersyn-gui.action-recount-done", player.name, tag, tostring(before.total), tostring(after.total),
				deliveries_text(before.deliveries), deliveries_text(after.deliveries) }, nil, id)
	end)
end

-- ---------------------------------------------------------------- tick, wiring

--- Redraws expired confirm buttons, and drops their state once the click grace (logic.CONFIRM_GRACE) is over too. On a
--- fixed nth (manager_gui.repair_tick), so a "Confirm?" goes back within a few ticks of its expiry whatever the
--- manager's update rate; free while no player has a button armed.
--- @param manager_data Manager
function repair.expire(manager_data)
	if not manager_data.confirm_any then return end
	local now = game.tick
	local any
	for i, pd in pairs(manager_data.players) do
		local cur = pd.confirm
		if cur then
			if logic.confirm_gone(cur, now) then
				pd.confirm = nil
			else
				any = true
				if not cur.redrawn and logic.confirm_expired(cur, now) then
					cur.redrawn = true
					local player = repair.on_change and game.get_player(i)
					if player then repair.on_change(player, pd) end
				end
			end
		end
	end
	manager_data.confirm_any = any
end

--- The panel subject of a clicked element; set by extras (relative.build's frame tags).
--- @type fun(elem: LuaGuiElement): string?, uint?
repair.subject = function() return nil, nil end

repair.wrapper = util.wrapper

gui.add_handlers(repair.handle, repair.wrapper, "cybersyn_repair")

--- /cybersyn-refresh-allow-lists: the allow-list job, behind the same right as the panel actions.
--- @param command CustomCommandData
function repair.allow_lists_command(command)
	local player = command.player_index and game.get_player(command.player_index) or nil
	if not actions.check(player, "/" .. command.name) then return end
	if not storage.manager then return end
	if storage.manager.repair_job then
		local text = { "cybersyn-gui.action-allow-lists-running" }
		if player then player.print(text) else game.print(text) end
		return
	end
	repair.start_allow_job(player)
	local name = player and player.name or "server"
	actions.audit(ACTION_REFRESH_ALLOW_LISTS, nil, player, "/" .. command.name,
		{ "cybersyn-messages.audit-allow-lists", name, tostring(#storage.manager.repair_job.ids) })
end

commands.add_command("cybersyn-refresh-allow-lists", { "cybersyn-messages.refresh-allow-lists-command-help" },
	repair.allow_lists_command)

return repair
