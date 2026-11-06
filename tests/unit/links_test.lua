-- An entity GUI opened from a link of an unpinned manager must not close it; closing that GUI hands
-- player.opened back to the window, so the next Escape closes the window. Any other GUI taking player.opened closes an
-- unpinned window, as the game's own windows close.
-- A train without a locomotive gets an error instead of a silent no-op.

local H = require("harness")

local function load()
	package.preload["__core__.lualib.mod-gui"] = function() return { get_button_flow = function() end } end
	commands = commands or { add_command = function() end }
	local manager_gui = H.load("scripts.gui.main")
	return manager_gui, require("scripts.gui.manager"), require("scripts.gui.utils.nav")
end

local function element_or_entity(o)
	if rawget(o, "_kids") then return { element = o } end
	return { entity = o }
end

--- A player whose player.opened behaves as the engine's (measured with a client): an assignment raises
--- on_gui_closed for the GUI it replaces, then on_gui_opened for the new one, both inside the assignment.
--- `entity_window` stands in for Cybersyn's combinator, whose on_gui_opened replaces the entity's window with a frame.
local function new_player(index, manager_gui)
	local state = { opened = nil, connected = true }
	local player
	local function raise_closed(old)
		local e = element_or_entity(old)
		e.name, e.player_index = defines.events.on_gui_closed, index
		manager_gui.on_gui_closed(e)
	end
	local function raise_opened(new)
		local e = element_or_entity(new)
		e.name, e.player_index = defines.events.on_gui_opened, index
		manager_gui.on_gui_opened(e)
		if new.entity_window and state.opened == new then player.opened = new.entity_window end
	end
	player = setmetatable({
		index = index, valid = true, _state = state, gui = { screen = {} }, set_shortcut_toggled = function() end,
		controller_type = defines.controllers.character,
	}, {
		__index = function(_, k)
			if k == "opened" then return state.opened end
			if k == "connected" then return state.connected end
			if k == "opened_gui_type" then
				local o = state.opened
				if o == nil then return defines.gui_type.none end
				return rawget(o, "_kids") and defines.gui_type.custom or defines.gui_type.entity
			end
		end,
		__newindex = function(t, k, v)
			if k ~= "opened" then return rawset(t, k, v) end
			local old = state.opened
			if old == v then return end
			if v ~= nil and v.unopenable then return end
			state.opened = nil
			if old ~= nil then raise_closed(old) end
			-- Closing to nothing keeps what a handler re-took; a switch to another GUI drops it without an event.
			if v == nil then return end
			state.opened = v
			raise_opened(v)
		end,
	})
	game.players[index] = player
	return player
end

--- E or Escape: the engine closes what holds player.opened.
local function escape(player)
	player.opened = nil
end

--- A GUI the player opens by hand (an entity clicked in the world). The engine drops whatever an on_gui_closed handler
--- re-took during the switch, without an event, and the new GUI wins.
local function world_open(manager_gui, player, target)
	local state = player._state
	local old = state.opened
	state.opened = nil
	if old ~= nil then
		local e = element_or_entity(old)
		e.name, e.player_index = defines.events.on_gui_closed, player.index
		manager_gui.on_gui_closed(e)
	end
	state.opened = target
	local e = element_or_entity(target)
	e.name, e.player_index = defines.events.on_gui_opened, player.index
	manager_gui.on_gui_opened(e)
end

local function setup(pinning)
	local manager_gui, manager, nav = load()
	local player = new_player(1, manager_gui)
	local window = H.element({ name = "manager_window" })
	window.visible = true
	local pd = H.player_data({ is_manager_open = true, pinning = pinning or false, refs = { manager_window = window } })
	storage.manager = { players = { [1] = pd } }
	player._state.opened = not pinning and window or nil
	game.tick = 500
	return manager_gui, manager, nav, player, pd, window
end

local stop = { valid = true, name = "train-stop", unit_number = 77 }
local chest = { valid = true, name = "wooden-chest", unit_number = 79 }

test("open_entity: the linked GUI opens and the unpinned window stays open", function()
	local _, _, nav, player, pd = setup()
	nav.open_entity(player, pd, stop)
	assert_same(player.opened, stop)
	assert_true(pd.is_manager_open)
	assert_same(pd.return_to, stop)
end)

test("open_entity: Escape on the linked GUI hands player.opened back, the next Escape closes the window", function()
	local _, _, nav, player, pd, window = setup()
	nav.open_entity(player, pd, stop)
	escape(player)
	assert_same(player.opened, window)
	assert_nil(pd.return_to)
	assert_true(pd.is_manager_open)
	escape(player)
	assert_false(pd.is_manager_open)
	assert_nil(player.opened)
end)

test("open_entity: a GUI that replaces the linked one closes the window", function()
	local manager_gui, _, nav, player, pd = setup()
	nav.open_entity(player, pd, stop)
	world_open(manager_gui, player, chest)
	assert_same(player.opened, chest)
	assert_false(pd.is_manager_open)
	assert_nil(pd.return_to)
end)

test("open_entity: another GUI closing does not hand back", function()
	local manager_gui, _, nav, player, pd = setup()
	nav.open_entity(player, pd, stop)
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = chest })
	assert_same(player.opened, stop)
	assert_same(pd.return_to, stop)
end)

test("open_entity: the combinator's own frame that replaces its entity window hands back when it closes", function()
	local _, _, nav, player, pd, window = setup()
	local frame = H.element({ name = COMBINATOR_NAME })
	local comb = { valid = true, name = COMBINATOR_NAME, unit_number = 78, entity_window = frame }
	nav.open_entity(player, pd, comb)
	assert_same(player.opened, frame)
	assert_same(pd.return_to, frame)
	escape(player)
	assert_same(player.opened, window)
end)

test("open_entity: a GUI that does not open leaves the window holding player.opened", function()
	local _, _, nav, player, pd, window = setup()
	nav.open_entity(player, pd, { valid = true, name = "far-away", unopenable = true })
	assert_same(player.opened, window)
	assert_nil(pd.return_to)
	assert_true(pd.is_manager_open)
end)

test("open_entity: a pinned window records nothing to return to", function()
	local _, _, nav, player, pd = setup(true)
	nav.open_entity(player, pd, stop)
	assert_same(player.opened, stop)
	assert_nil(pd.return_to)
	escape(player)
	assert_nil(player.opened)
	assert_true(pd.is_manager_open)
end)

test("Escape with an overlay open closes the overlay and keeps the window", function()
	local _, manager, _, player, pd, window = setup()
	local render = manager.render
	manager.render = function() end
	pd.explain = { r_id = 1, hash = "iron-plate" }
	escape(player)
	assert_nil(pd.explain)
	assert_same(player.opened, window)
	assert_true(pd.is_manager_open)
	escape(player)
	assert_false(pd.is_manager_open)
	manager.render = render
end)

test("another GUI replacing a window with an overlay open closes the window", function()
	local manager_gui, manager, _, player, pd = setup()
	local render = manager.render
	manager.render = function() end
	pd.explain = { r_id = 1, hash = "iron-plate" }
	world_open(manager_gui, player, chest)
	assert_same(player.opened, chest)
	assert_false(pd.is_manager_open)
	manager.render = render
end)

test("a pinned window ignores Escape and other GUIs", function()
	local manager_gui, _, _, player, pd = setup(true)
	world_open(manager_gui, player, chest)
	assert_true(pd.is_manager_open)
	escape(player)
	assert_true(pd.is_manager_open)
end)

test("close_manager_window: forgets a pending return and the map return", function()
	local _, _, nav, player, pd = setup()
	nav.open_entity(player, pd, stop)
	pd.map_from = { controller = defines.controllers.character, position = { x = 0, y = 0 }, surface = 1 }
	nav.close_manager_window(player, pd, pd.refs)
	assert_nil(pd.return_to)
	assert_nil(pd.map_from)
end)

-- Every key, not a list of known ones: a cache a later tab adds is dropped without being named anywhere.
local function fill_cache(pd)
	for _, k in ipairs({ "stations", "trains", "inventory", "item", "item_view", "delivered", "failing", "utilization",
		"breakdown", "log_cf", "status_sig", "chip_sig", "trains_badge", "a_future_tab" }) do
		pd.cache[k] = { k }
	end
	pd.tabs.log_tab.filter = { kind = "lint" }
	pd.tabs.trains_tab.selected = 5
end

test("manager_close: no view cache survives; the tabs' state does", function()
	local _, manager, _, player, pd = setup()
	fill_cache(pd)
	manager.handle.manager_close(player, pd, pd.refs)
	assert_eq(pd.cache, {})
	assert_eq(pd.tabs.log_tab.filter, { kind = "lint" })
	assert_eq(pd.tabs.trains_tab.selected, 5)
end)

test("manager_close: a kept snapshot keeps only the Stations rows, until collector.release_due frees both", function()
	local _, manager, _, player, pd = setup()
	local collector = require("scripts.gui.collector")
	storage.manager.snapshot = { tick = 450 }
	fill_cache(pd)
	manager.handle.manager_close(player, pd, pd.refs)
	assert_eq(pd.cache, { stations = { "stations" } })
	local at = storage.manager.release_at
	assert_not_nil(at, "the snapshot is kept")
	game.tick = at
	collector.release_due()
	assert_eq(pd.cache, {})
end)

-- The train id cell is a tag button {kind = "train", id} handled by links.handle_link_click.
local function train_case(locomotive)
	local _, _, _, player, pd = setup()
	local texts = {}
	player.create_local_flying_text = function(spec) texts[#texts + 1] = spec.text end
	player.play_sound = function() end
	storage.trains = { [5] = { entity = { valid = true, id = 5,
		locomotives = { front_movers = { locomotive }, back_movers = {} } } } }
	require("scripts.gui.utils.links").handle_link_click(player, pd, { element = { tags = { kind = "train", id = 5 } },
		button = defines.mouse_button_type.left })
	return player, pd, texts
end

test("open_train_gui: a train without a locomotive says so", function()
	local player, pd, texts = train_case(nil)
	assert_eq(texts, { { "cybersyn-gui.train-has-no-locomotive" } })
	assert_nil(pd.return_to)
	assert_same(player.opened, pd.refs.manager_window)
end)

test("open_train_gui: the main locomotive opens as a manager link", function()
	local loco = { valid = true, name = "locomotive", unit_number = 9 }
	local player, pd, texts = train_case(loco)
	assert_eq(texts, {})
	assert_same(player.opened, loco)
	assert_same(pd.return_to, loco)
end)

-- Right-click on a train or stop link does nothing; on an item it clears the item filter.
local function right_click(kind, id)
	local _, manager, _, player, pd = setup()
	local renders, texts = 0, {}
	local render = manager.render
	manager.render = function() renders = renders + 1 end
	player.create_local_flying_text = function(spec) texts[#texts + 1] = spec.text end
	storage.trains = { [5] = { entity = { valid = true, id = 5, locomotives = { front_movers = {}, back_movers = {} } } } }
	storage.stations = {}
	pd.filters.item = "iron-plate"
	require("scripts.gui.utils.links").handle_link_click(player, pd, { element = { tags = { kind = kind, id = id } },
		button = defines.mouse_button_type.right })
	manager.render = render
	return player, pd, renders, texts
end

test("right-click on a station link: no handler, no re-render, nothing set", function()
	local player, pd, renders, texts = right_click("station", 3)
	assert_eq(renders, 0)
	assert_eq(texts, {})
	assert_nil(pd.tabs.log_tab.filter)
	assert_nil(pd.return_to)
	assert_same(player.opened, pd.refs.manager_window)
	assert_eq(pd.filters.item, "iron-plate")
end)

test("right-click on a train link: no handler, no re-render, nothing set", function()
	local player, pd, renders, texts = right_click("train", 5)
	assert_eq(renders, 0)
	assert_eq(texts, {})
	assert_nil(pd.tabs.log_tab.filter)
	assert_same(player.opened, pd.refs.manager_window)
end)

test("right-click on an item still clears the item filter and re-renders", function()
	local _, pd, renders = right_click("item", "iron-plate")
	assert_nil(pd.filters.item)
	assert_eq(renders, 1)
end)

test("the GUI helpers offer no hook that scopes the Log to a subject", function()
	load()
	for _, name in ipairs({ "util", "utils.sync", "utils.filters", "utils.listing", "utils.hover", "utils.links",
			"utils.nav" }) do
		for k in pairs(require("scripts.gui." .. name)) do assert(not string.find(k, "subject", 1, true), name .. "." .. k) end
	end
end)
