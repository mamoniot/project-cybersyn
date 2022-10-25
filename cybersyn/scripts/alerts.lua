--By Mami

local send_missing_train_alert_for_stop_icon = {name = MISSING_TRAIN_NAME, type = "fluid"}
---@param r_stop LuaEntity
---@param p_stop LuaEntity
function send_missing_train_alert_for_stops(r_stop, p_stop)
	for _, player in pairs(r_stop.force.players) do
		player.add_custom_alert(
			r_stop,
			send_missing_train_alert_for_stop_icon,
			{"cybersyn-messages.missing-trains", r_stop.backer_name, p_stop.backer_name},
			true
		)
	end
end

local send_lost_train_alert_icon = {name = LOST_TRAIN_NAME, type = "fluid"}
---@param train LuaTrain
function send_lost_train_alert(train)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
				loco,
				send_lost_train_alert_icon,
				{"cybersyn-messages.lost-train"},
				true
			)
		end
	end
end


local send_nonempty_train_in_depot_alert_icon = {name = NONEMPTY_TRAIN_NAME, type = "fluid"}
---@param train LuaTrain
function send_nonempty_train_in_depot_alert(train)
	local loco = train.front_stock or train.back_stock
	if loco then
		for _, player in pairs(loco.force.players) do
			player.add_custom_alert(
				loco,
				send_nonempty_train_in_depot_alert_icon,
				{"cybersyn-messages.nonempty-train"},
				true
			)
		end
	end
end
