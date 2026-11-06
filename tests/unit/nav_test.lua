-- Window navigation in scripts/gui/utils/nav.lua: tab selection and the player.opened switch guard.

local H = require("harness")

local function nav()
	return H.load("scripts.gui.utils.nav")
end

test("select_tab: finds the tab by element name and syncs selected_tab", function()
	local u = nav()
	assert_false(u.select_tab({}, "stations_tab"))
	local pane = {
		valid = true,
		selected_tab_index = 1,
		tabs = { { tab = { name = "manager_overview_tab" } }, { tab = { name = "manager_stations_tab" } } },
	}
	local pd = { refs = { manager_tabbed_pane = pane }, selected_tab = "overview_tab" }
	assert_true(u.select_tab(pd, "stations_tab"))
	assert_eq(pane.selected_tab_index, 2)
	assert_eq(pd.selected_tab, "stations_tab")
	assert_false(u.select_tab(pd, "log_tab"))
	assert_eq(pane.selected_tab_index, 2)
	assert_eq(pd.selected_tab, "stations_tab")
	pane.valid = false
	assert_false(u.select_tab(pd, "overview_tab"))
end)

test("switch_opened: the guard holds only while the move runs, per player", function()
	local u = nav()
	local inside, other
	u.switch_opened({ index = 1 }, function()
		inside = u.switching(1)
		other = u.switching(2)
	end)
	assert_true(inside)
	assert_false(other)
	assert_false(u.switching(1))
end)
