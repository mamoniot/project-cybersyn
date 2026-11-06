-- Global helpers the manager modules lean on (lib.lua, central-planning.lua, factorio-api.lua),
-- plus a check that the harness's copy of flib's format matches flib 0.17.2.

local H = require("harness")

test("hash_item / hash_signal / unhash_signal", function()
	assert_eq(hash_item("iron-plate"), "iron-plate")
	assert_eq(hash_item("iron-plate", "normal"), "iron-plate")
	assert_eq(hash_item("iron-plate", "rare"), "iron-plate|rare")
	assert_eq(hash_signal({ name = "water", quality = "legendary" }), "water|legendary")
	assert_eq({ unhash_signal("iron-plate") }, { "iron-plate" })
	assert_eq({ unhash_signal("iron-plate|rare") }, { "iron-plate", "rare" })
	assert_eq(create_item_network_name("signal-A", "coal|rare"), "signal-A:coal|rare")
end)

test("format_signal_count: SI suffixes, one decimal below 10 units", function()
	assert_eq(format_signal_count(0), "0")
	assert_eq(format_signal_count(999), "999")
	assert_eq(format_signal_count(-999), "-999")
	assert_eq(format_signal_count(1000), "1.0k")
	assert_eq(format_signal_count(1250), "1.2k")
	assert_eq(format_signal_count(9999), "9.9k")
	assert_eq(format_signal_count(10000), "10k")
	assert_eq(format_signal_count(123456), "123k")
	assert_eq(format_signal_count(2500000), "2.5M")
	assert_eq(format_signal_count(2147483647), "2.1G")
	-- Floors toward minus infinity, so negatives round away from zero.
	assert_eq(format_signal_count(-1250), "-1.3k")
end)

test("get_stack_size reads prototypes at load; get_any_train_entity prefers the front stock", function()
	assert_eq(get_stack_size(nil, "iron-ore"), 50)
	assert_eq(get_stack_size(nil, "iron-plate"), 100)
	assert_nil(get_stack_size(nil, "water"))
	local front, back, first = {}, {}, {}
	assert_same(get_any_train_entity({ valid = true, front_stock = front, back_stock = back }), front)
	assert_same(get_any_train_entity({ valid = true, back_stock = back }), back)
	assert_same(get_any_train_entity({ valid = true, carriages = { first } }), first)
	assert_nil(get_any_train_entity({ valid = false, front_stock = front }))
end)

test("network_text and get_network_mask", function()
	assert_eq(network_text(1), "0x00000001")
	assert_eq(network_text(-1), "0xFFFFFFFF")
	assert_eq(get_network_mask({ network_name = "signal-A", network_mask = 6 }, "signal-A"), 6)
	assert_eq(get_network_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 2 } }, "signal-B"), 2)
	assert_eq(get_network_mask({ network_name = NETWORK_EACH, network_mask = {} }, "signal-B"), 0)
end)

test("entity_richtext: a stop tag for any train stop, a gps tag and the name otherwise", function()
	assert_eq(entity_richtext({ type = "train-stop", name = "modded-stop", unit_number = 5, valid = true }), "[train-stop=5]")
	local comb = { type = "arithmetic-combinator", valid = true, position = { x = 1.5, y = -2 },
		surface = { name = "nauvis" }, localised_name = { "entity-name.cybersyn-combinator" } }
	assert_eq(entity_richtext(comb), { "", "[gps=1.5,-2,nauvis]", " ", { "entity-name.cybersyn-combinator" } })
end)

test("gps_text: an entity's position, empty for an invalid one", function()
	local stop = { valid = true, position = { x = 10.5, y = -3 }, surface = { name = "nauvis" } }
	assert_eq(gps_text(stop), "[gps=10.5,-3,nauvis]")
	assert_eq(gps_text({ valid = false }), "")
	assert_eq(gps_text(nil), "")
end)

test("templates.sort_checkbox carries the tags listing.sync_sort_header and listing.handle.sort_click read", function()
	local templates = H.load("scripts.gui.templates")
	local handler = function() end
	local def = templates.sort_checkbox("stations_tab", "name", { "a" }, { "b" }, true, handler)
	assert_eq(def.type, "checkbox")
	assert_eq(def.style, "ltnm_selected_sort_checkbox")
	assert_eq(def.state, false)
	assert_eq(def.tags, { sort_tab = "stations_tab", column = "name", default_state = false })
	assert_same(def.handler[defines.events.on_gui_checked_state_changed], handler)
	assert_eq(templates.sort_checkbox("trains_tab", "wait", "c", "t", false, handler).style, "ltnm_sort_checkbox")
	assert_eq(templates.column_label({ "c" }, { "t" }),
		{ type = "label", style = "ltnm_column_label", caption = { "c" }, tooltip = { "t" } })
end)

test("flib format copy: number and time", function()
	local format = require("__flib__.format")
	assert_eq(format.number(0), "0")
	assert_eq(format.number(1234), "1,234")
	assert_eq(format.number(-1234567), "-1,234,567")
	assert_eq(format.number(1234.5), "1,234.5")
	assert_eq(format.number(1234, true), "1.2 k")
	assert_eq(format.number(999, true), "999")
	assert_eq(format.number(1500000, true, 3), "1.5 M")
	assert_eq(format.time(0), "0:00")
	assert_eq(format.time(3599 * 60), "59:59")
	assert_eq(format.time(3600 * 60), "1:00:00")
	assert_eq(format.time(65 * 60, true), "01:05")
	game.ticks_played = 125 * 60
	assert_eq(format.time(), "2:05")
end)

test("harness: serpent.line sorts keys", function()
	assert_eq(serpent.line({ b = 1, a = { 1, 2 }, [3] = "x" }), '{[3] = "x", a = {1, 2}, b = 1}')
	assert_eq(table_size({ a = 1, b = 2, 3 }), 3)
	assert_eq(H.keys({ b = 1, a = 2, [2] = 0 }), { 2, "a", "b" })
end)

test("get_item_threshold: override, else fluid or item base; stack stations count items in stacks", function()
	local plain = { item_thresholds = { ["iron-ore"] = 7, water = 300 } }
	assert_eq(get_item_threshold(nil, plain, "iron-ore", "iron-ore", "item", 1000, 5000), 7)
	assert_eq(get_item_threshold(nil, plain, "water", "water", "fluid", 1000, 5000), 300)
	assert_eq(get_item_threshold(nil, plain, "iron-plate", "iron-plate", "item", 1000, 5000), 1000)
	assert_eq(get_item_threshold(nil, plain, "steam", "steam", "fluid", 1000, 5000), 5000)
	-- No fluid threshold set: fluids use the item one.
	assert_eq(get_item_threshold(nil, plain, "steam", "steam", "fluid", 1000, nil), 1000)
	assert_eq(get_item_threshold(nil, {}, "iron-plate", "iron-plate", "item", 1000), 1000)

	local stack = { is_stack = true, item_thresholds = { ["iron-ore"] = 2, water = 300 } }
	assert_eq(get_item_threshold(nil, stack, "iron-ore", "iron-ore", "item", 4, 5000), 100)
	assert_eq(get_item_threshold(nil, stack, "iron-plate", "iron-plate", "item", 4, 5000), 400)
	assert_eq(get_item_threshold(nil, stack, "water", "water", "fluid", 4, 5000), 300)
	assert_eq(get_item_threshold(nil, stack, "steam", "steam", "fluid", 4, 5000), 5000)

	-- Without bases: the provider override alone, scaled the same way, or nil.
	assert_eq(get_item_threshold(nil, stack, "iron-ore", "iron-ore", "item"), 100)
	assert_nil(get_item_threshold(nil, stack, "iron-plate", "iron-plate", "item"))
	assert_nil(get_item_threshold(nil, {}, "iron-plate", "iron-plate", "item"))
end)
