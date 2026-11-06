-- The manager's tab registry (scripts/gui/utils/tabs.lua): one entry per tab drives the window, and a tab's chip
-- tooltip comes from the same flag filters.get strips by.

local H = require("harness")

local function load_manager()
	package.preload["__core__.lualib.mod-gui"] = function() return { get_button_flow = function() end } end
	commands = commands or { add_command = function() end }
	H.load("scripts.gui.main")
	return require("scripts.gui.manager"), require("scripts.gui.utils.tabs")
end

test("every entry names a module with create and build, once", function()
	local _, tabs = load_manager()
	local seen = {}
	for _, t in ipairs(tabs) do
		assert_nil(seen[t.name], t.name)
		seen[t.name] = true
		local m = require(t.module)
		assert_eq(type(m.create), "function", t.name)
		assert_eq(type(m.build), "function", t.name)
		assert_true(tabs.by_name[t.name] == t, t.name)
	end
end)

test("chip tooltips: a tab that does not apply the station chip or the item filter says so", function()
	local manager, tabs = load_manager()
	storage.stations = { [12] = { entity_stop = { valid = true, backer_name = "Mine" } } }
	local refs = {}
	for _, t in ipairs(tabs) do
		for _, suffix in ipairs({ "_station_chip_flow", "_station_chip_icon", "_station_chip", "_chip_flow", "_chip_icon",
			"_chip" }) do
			refs[t.name .. suffix] = H.element({})
		end
	end
	local pd = H.player_data({ refs = refs, filters = { station = 12, item = "coal" } })
	manager.refresh_chips(pd)
	for _, t in ipairs(tabs) do
		assert_true(refs[t.name .. "_station_chip_flow"].visible, t.name)
		assert_eq(refs[t.name .. "_station_chip"].tooltip[1], t.station and "cybersyn-gui.station-chip-tooltip"
			or "cybersyn-gui.station-chip-ignored-tooltip", t.name)
		local item_tooltip = refs[t.name .. "_chip"].tooltip[1]
		if t.item then
			assert_true(item_tooltip ~= "cybersyn-gui.filter-chip-ignored-tooltip", t.name)
		else
			assert_eq(item_tooltip, "cybersyn-gui.filter-chip-ignored-tooltip", t.name)
		end
	end
	assert_eq(refs.overview_tab_chip.tooltip[1], "cybersyn-gui.filter-chip-overview-tooltip")
	assert_eq(refs.stations_tab_station_chip.caption, { "cybersyn-gui.station-chip", "Mine", "12" })
end)

test("the train chip shows only on the tabs that apply it", function()
	local manager, tabs = load_manager()
	local refs = {}
	for _, t in ipairs(tabs) do
		for _, suffix in ipairs({ "_train_chip_flow", "_train_chip" }) do refs[t.name .. suffix] = H.element({}) end
	end
	local pd = H.player_data({ refs = refs, filters = { train = 5 } })
	manager.refresh_chips(pd)
	for _, t in ipairs(tabs) do
		assert_eq(refs[t.name .. "_train_chip_flow"].visible == true, t.train == true, t.name)
	end
	assert_eq(refs.trains_tab_train_chip.caption, { "cybersyn-gui.train-chip", "5" })
	local templates = require("scripts.gui.templates")
	local _, with = templates.tab_header(tabs.by_name.trains_tab, {}, nil)
	local _, without = templates.tab_header(tabs.by_name.stations_tab, {}, nil)
	local function has(sub, name)
		for _, c in ipairs(sub) do if c.name == name then return true end end
		return false
	end
	assert_true(has(with, "trains_tab_train_chip_flow"))
	assert_false(has(without, "stations_tab_train_chip_flow"))
end)

test("Open in manager on a train panel: the Trains tab with the train chip, the search cleared", function()
	local manager = load_manager()
	local relative = require("scripts.gui.relative")
	storage.trains = { [5] = {} }
	storage.stations = { [3] = {} }
	local renders = 0
	local render = manager.render
	manager.render = function() renders = renders + 1 end
	local pd = H.player_data({ is_manager_open = true, pinning = true, refs = {}, page = { trains_tab = 2 },
		filters = { query = "depot", terms = { "depot" }, station = 3, trains_chip = "parked" } })
	local player = { index = 1, gui = { screen = {} } }
	local ok, err = pcall(relative.open_manager, player, pd, { kind = "train", id = 5 })
	manager.render = render
	assert_true(ok, err)
	assert_eq(pd.filters, { train = 5 })
	assert_true(pd.filter_row_open)
	assert_eq(pd.tabs.trains_tab.reveal, { train = 5 })
	assert_eq(pd.selected_tab, "trains_tab")
	assert_eq(pd.page, {})
	assert_eq(renders, 1)
end)
