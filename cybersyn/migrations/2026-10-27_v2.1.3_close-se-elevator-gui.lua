-- Frames saved by older versions carry stale flib handler tags; close an open elevator window so the frame is rebuilt on reopen.
for _, player in pairs(game.players) do
	local frame = player.gui.relative["cybersyn-se-elevator-frame"]
	if frame then frame.destroy() end

	if player.connected and player.opened_gui_type == defines.gui_type.entity then
		local opened = player.opened
		if opened and opened.valid and opened.name == "se-space-elevator" then
			player.opened = nil
		end
	end
end
