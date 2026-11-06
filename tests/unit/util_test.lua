-- Characterization tests for scripts/gui/util.lua.

local H = require("harness")

local function util()
	return H.load("scripts.gui.util")
end

-- ------------------------------------------------------------------ sprites

test("valid_sprite: the path when drawable, else the fallback, and each path asked once", function()
	local u = util()
	assert_eq(u.valid_sprite("item/iron-ore", "utility/questionmark"), "item/iron-ore")
	assert_eq(u.valid_sprite("item/no-such-thing", "utility/questionmark"), "utility/questionmark")
	assert_eq(u.valid_sprite("item/no-such-thing"), nil)
	assert_eq(u.valid_sprite(nil, "utility/warning_icon"), "utility/warning_icon")
	local real, calls = helpers.is_valid_sprite_path, 0
	helpers.is_valid_sprite_path = function(path) calls = calls + 1 return real(path) end
	u.valid_sprite("fluid/water")
	u.valid_sprite("fluid/water")
	helpers.is_valid_sprite_path = real
	assert_eq(calls, 1)
end)

-- ------------------------------------------------------------------ sorting

local function ids(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.id end
	return out
end

test("sort_by: ascending and descending, nil keys last, ties by input position", function()
	local u = util()
	local function rows()
		return {
			{ k = 3, id = "a" }, { k = 1, id = "b" }, { k = 3, id = "c" }, { k = nil, id = "d" },
			{ k = 2, id = "e" }, { k = nil, id = "f" },
		}
	end
	local key = function(r) return r.k end
	local asc = rows()
	assert_same(u.sort_by(asc, key, true), asc)
	assert_eq(ids(asc), { "b", "e", "a", "c", "d", "f" })
	local desc = u.sort_by(rows(), key, false)
	assert_eq(ids(desc), { "a", "c", "e", "b", "d", "f" })
end)

test("sort_by: stable for many equal keys", function()
	local u = util()
	local rows = {}
	for i = 1, 60 do rows[i] = { k = i % 2, id = i } end
	u.sort_by(rows, function(r) return r.k end, true)
	local expected = {}
	for i = 2, 60, 2 do expected[#expected + 1] = i end
	for i = 1, 59, 2 do expected[#expected + 1] = i end
	assert_eq(ids(rows), expected)
end)

test("sort_by: tiebreak_fn ascending in both directions; string keys compare bytewise", function()
	local u = util()
	local function rows()
		return { { k = 1, id = "z" }, { k = 1, id = "m" }, { k = 0, id = "q" }, { k = 1, id = "a" } }
	end
	local key = function(r) return r.k end
	local tb = function(r) return r.id end
	assert_eq(ids(u.sort_by(rows(), key, true, tb)), { "q", "a", "m", "z" })
	assert_eq(ids(u.sort_by(rows(), key, false, tb)), { "a", "m", "z", "q" })
	local names = { { id = "b" }, { id = "a" }, { id = "C" } }
	assert_eq(ids(u.sort_by(names, function(r) return r.id end, true)), { "C", "a", "b" })
end)

-- ------------------------------------------------------------------ items and signals

test("item_rank: item_order plus quality fraction, unknown items last", function()
	local u = util()
	storage.manager = { item_order = { ["iron-plate"] = 5, ["copper-plate"] = 7 } }
	assert_eq(u.item_rank("iron-plate"), 5)
	assert_eq(u.item_rank("iron-plate|rare"), 5 + 3 / 32)
	assert_eq(u.item_rank("iron-plate|legendary"), 5 + 6 / 32)
	assert_eq(u.item_rank("iron-plate|normal"), 5 + 1 / 32)
	assert_eq(u.item_rank("iron-plate|gone"), 5 + 16 / 32)
	assert_eq(u.item_rank("unobtainium"), 1e9)
end)

test("item_rank: cached per Lua state, so a later item_order change is not seen", function()
	local u = util()
	storage.manager = { item_order = { ["iron-plate"] = 5 } }
	assert_eq(u.item_rank("iron-plate"), 5)
	storage.manager.item_order["iron-plate"] = 9
	assert_eq(u.item_rank("iron-plate"), 5)
	local u2 = util()
	assert_eq(u2.item_rank("iron-plate"), 9)
	storage.manager = nil
	assert_eq(util().item_rank("iron-plate"), 1e9)
end)

test("hashes_in_item_order: rank, then hash string", function()
	local u = util()
	storage.manager = { item_order = { ["iron-plate"] = 5, ["copper-plate"] = 7 } }
	local hashes = { ["copper-plate"] = 1, ["iron-plate"] = 1, ["iron-plate|rare"] = 1, zzz = 1, aaa = 1 }
	assert_eq(u.hashes_in_item_order(hashes), { "iron-plate", "iron-plate|rare", "copper-plate", "aaa", "zzz" })
	assert_eq(u.hashes_in_item_order({}), {})
end)

test("signal_hash_valid: prototype lookup and quality check", function()
	local u = util()
	assert_false(u.signal_hash_valid(nil))
	assert_false(u.signal_hash_valid(5))
	assert_true(u.signal_hash_valid("iron-plate"))
	assert_true(u.signal_hash_valid("water"))
	assert_true(u.signal_hash_valid("signal-A"))
	assert_true(u.signal_hash_valid("cybersyn-combinator"))
	assert_true(u.signal_hash_valid("iron-plate|rare"))
	assert_false(u.signal_hash_valid("iron-plate|bogus"))
	assert_false(u.signal_hash_valid("nonexistent"))
	assert_false(u.signal_hash_valid("nonexistent|rare"))
	-- A quality name is itself a valid signal.
	assert_true(u.signal_hash_valid("rare"))
end)

test("signalid_from_name / signalid_from_hash: type by prototype group", function()
	local u = util()
	assert_eq(u.signalid_from_name("iron-plate"), { type = "item", name = "iron-plate" })
	assert_eq(u.signalid_from_name("water", "rare"), { type = "fluid", name = "water", quality = "rare" })
	assert_eq(u.signalid_from_name("signal-A"), { type = "virtual", name = "signal-A" })
	assert_eq(u.signalid_from_name("cybersyn-combinator"), { type = "entity", name = "cybersyn-combinator" })
	-- Unknown names fall through to "quality" rather than failing.
	assert_eq(u.signalid_from_name("nonexistent"), { type = "quality", name = "nonexistent" })
	assert_eq(u.signalid_from_hash("iron-plate|rare"), { type = "item", name = "iron-plate", quality = "rare" })
	assert_eq(u.signalid_from_hash("crude-oil"), { type = "fluid", name = "crude-oil" })
end)

test("item_sprite_and_tooltip", function()
	local u = util()
	local sprite, quality, tooltip, signal = u.item_sprite_and_tooltip("iron-plate|rare")
	assert_eq(sprite, "item/iron-plate")
	assert_eq(quality, "rare")
	assert_eq(tooltip, { "", "[item=iron-plate,quality=rare]", " ", { "item-name.iron-plate" } })
	assert_eq(signal, { type = "item", name = "iron-plate", quality = "rare" })
	assert_eq(u.item_sprite_and_tooltip("water"), "fluid/water")
	assert_nil(u.item_sprite_and_tooltip("nonexistent"))
	assert_nil(u.item_sprite_and_tooltip("iron-plate|gone"))
end)

-- ------------------------------------------------------------------ slot tables

local function slot_summary(defs)
	local out = {}
	for i, d in ipairs(defs) do
		out[i] = (d.tags and d.tags.kind == "item" and d.tags.id or d.sprite) .. " " .. string.match(d.style, "_(%a+)$") .. " " .. d.children[1].caption
	end
	return out
end

local function slot_station()
	storage.manager = { item_order = { ["iron-plate"] = 1, coal = 2, stone = 3, ["copper-ore"] = 4, ["iron-ore"] = 5 } }
	game.tick = 4000
	return {
		provided = { ["iron-plate"] = 1500, coal = 5 },
		requested = {
			stone = { count = -60, active = true },
			["copper-ore|rare"] = { count = -10, active = false },
			["iron-ore"] = { count = -7, active = true },
		},
		wait = { stone = 400, ["copper-ore|rare"] = 100 },
		deliveries = { ["iron-ore"] = 400, coal = -50 },
		control = { ["cybersyn-priority"] = 3, ["signal-A"] = 1, ["bogus-signal"] = 5 },
		thresholds = { stone = 150 },
	}
end

test("slot_table_build_from_station: provided green, active requests red, below threshold orange, item order", function()
	local u = util()
	local defs = u.slot_table_build_from_station(slot_station())
	assert_eq(slot_summary(defs), {
		"iron-plate green 1.5k",
		"coal green 5",
		"stone red -60",
		"copper-ore|rare orange -10",
		"iron-ore red -7",
	})
	assert_eq(defs[3], {
		type = "sprite-button",
		sprite = "item/stone",
		elem_tooltip = { type = "item-with-quality", name = "stone", quality = "normal" },
		enabled = false,
		style = "ltnm_small_slot_button_red",
		tags = { kind = "item", id = "stone" },
		tooltip = {
			"",
			{ "", "[item=stone,quality=]", " ", { "item-name.stone" } },
			" ", { "cybersyn-gui.requested" },
			"\n[color=yellow]", { "cybersyn-gui.waiting-for", "1m 0s" }, "[/color]",
			"\n", { "cybersyn-gui.amount", "-60" },
		},
		children = {
			{ type = "label", style = "ltnm_label_signal_count", ignored_by_interaction = true, caption = "-60" },
		},
	})
	-- Below threshold: no wait line even with a tracked start.
	assert_eq(defs[4].quality, "rare")
	assert_eq(defs[4].tooltip, {
		"",
		{ "", "[item=copper-ore,quality=rare]", " ", { "item-name.copper-ore" } },
		" ", { "cybersyn-gui.requested-below-threshold" },
		"\n", { "cybersyn-gui.amount", "-10" },
	})
	assert_eq(defs[1].tooltip[6], { "cybersyn-gui.amount", "1,500" })
end)

test("slot_table_build_from_deliveries: incoming green, outgoing blue", function()
	local u = util()
	local defs = u.slot_table_build_from_deliveries(slot_station())
	assert_eq(slot_summary(defs), { "coal blue -50", "iron-ore green 400" })
	assert_eq(defs[1].tooltip[4], { "cybersyn-gui.outgoing" })
	assert_eq(defs[2].tooltip[4], { "cybersyn-gui.incoming" })
end)

test("slot builders: a look sets the slot and count styles and highlights its selected item", function()
	local u = util()
	local look = { prefix = "p_", selected_prefix = "s_", count = "c", selected = "coal" }
	local defs = u.slot_table_build_from_deliveries(slot_station(), look)
	assert_eq({ defs[1].style, defs[2].style, defs[2].children[1].style }, { "s_blue", "p_green", "c" })
	assert_eq(u.slot_table_build_from_station(slot_station(), look)[2].style, "s_green")
end)

test("slot_table_build_from_control_signals: sorted virtual signals with a sprite, then thresholds", function()
	local u = util()
	local defs = u.slot_table_build_from_control_signals(slot_station())
	assert_eq(slot_summary(defs), {
		"virtual-signal/cybersyn-priority default 3",
		"virtual-signal/signal-A default 1",
		"stone default 150",
	})
	assert_eq(defs[2].tooltip, {
		"", "[virtual-signal=signal-A] ", { "item-name.signal-A" }, "\n", { "cybersyn-gui.amount", "1" },
	})
	-- A slot key of its own, not an item's: a click on it sets no filter.
	assert_eq(defs[2].tags, { slot_key = "c1:signal-A" })
	assert_eq(defs[3].tooltip, {
		"",
		{ "", "[item=stone,quality=]", " ", { "item-name.stone" } },
		"\n", { "cybersyn-gui.request-threshold", "150" },
	})
end)

test("slot_table_build_from_control_signals: the control combinator's signals follow, marked, with their own keys", function()
	local u = util()
	local st = slot_station()
	st.control2 = { ["cybersyn-priority"] = 7 }
	local look = { prefix = "p_", selected_prefix = "s_", count = "c" }
	local defs = u.slot_table_build_from_control_signals(st, look)
	assert_eq(slot_summary(defs), {
		"virtual-signal/cybersyn-priority default 3",
		"virtual-signal/signal-A default 1",
		"virtual-signal/cybersyn-priority default 7",
		"stone default 150",
	})
	assert_eq(defs[3].tags, { slot_key = "c2:cybersyn-priority" })
	assert_eq(defs[3].tooltip[7], { "cybersyn-gui.control-combinator-signal" })
	assert_eq({ defs[1].style, defs[4].style, defs[1].children[1].style }, { "p_default", "p_default", "c" })
end)

test("natural_key: digit runs compare by value, leading zeros ignored", function()
	local util = H.load("scripts.gui.util")
	local names = { "stn-10", "stn-2", "stn-1", "stn-002", "stn", "a10b", "a9b", "x0" }
	table.sort(names, function(a, b)
		local ka, kb = util.natural_key(a), util.natural_key(b)
		if ka ~= kb then return ka < kb end
		return a < b
	end)
	assert_eq(names, { "a9b", "a10b", "stn", "stn-1", "stn-002", "stn-2", "stn-10", "x0" })
	assert_eq(util.natural_key("000"), util.natural_key("0"))
end)

test("ack_until_tick: a day, an hour with shift, until clear with control", function()
	local u = util()
	game.tick = 100
	assert_eq(u.ack_until_tick({}), 100 + 24 * 216000)
	assert_eq(u.ack_until_tick({ shift = true }), 100 + 216000)
	assert_nil(u.ack_until_tick({ control = true, shift = true }))
end)
