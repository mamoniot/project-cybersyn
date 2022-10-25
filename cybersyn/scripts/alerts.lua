--By Mami

local send_missing_train_alert_for_stop_icon = {name = MISSING_TRAIN_NAME, type = "fluid"}
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
function send_lost_train_alert(train)
	for _, player in pairs(train.force.players) do
		player.add_custom_alert(
			train,
			send_lost_train_alert_icon,
			{"cybersyn-messages.lost-train"},
			true
		)
	end
end


local send_nonempty_train_in_depot_alert_icon = {name = NONEMPTY_TRAIN_NAME, type = "fluid"}
function send_nonempty_train_in_depot_alert(train)
	for _, player in pairs(train.force.players) do
		player.add_custom_alert(
			train,
			send_nonempty_train_in_depot_alert_icon,
			{"cybersyn-messages.nonempty-train"},
			true
		)
	end
end
