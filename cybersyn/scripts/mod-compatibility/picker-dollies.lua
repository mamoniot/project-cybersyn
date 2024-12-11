local lib = {}

-- TODO: picker dollies may have been forked/renamed for 2.0?

function lib.setup_picker_dollies_compat()
	IS_PICKER_DOLLIES_PRESENT = remote.interfaces["PickerDollies"] and
			remote.interfaces["PickerDollies"]["add_blacklist_name"]
	if IS_PICKER_DOLLIES_PRESENT then
		remote.call("PickerDollies", "add_blacklist_name", COMBINATOR_NAME)
		remote.call("PickerDollies", "add_blacklist_name", COMBINATOR_OUT_NAME)
	end
end

return lib
