-- create_manifest's locked slots under both values of the cybersyn-locked-slots-per-item map setting: reserved once
-- per cargo wagon, or once per item type in the manifest (fluids do not count, they travel in fluid wagons).

local H = require("harness")

local function sig(name, count, type)
	return { signal = { name = name, type = type or "item" }, count = count }
end

--- A requester asking for `requests`, a provider holding plenty of each, and one train of one 40-slot cargo wagon and
--- one fluid wagon. Returns the manifest create_manifest builds for that pair.
local function manifest_for(requests, locked_slots, per_item)
	mod_settings = { locked_slots_per_item = per_item }
	local p_counts = {}
	local requested = {}
	for _, r in ipairs(requests) do
		p_counts[hash_signal(r.signal)] = 100000
		requested[hash_signal(r.signal)] = 1
	end
	local map_data = {
		stations = {
			[1] = { deliveries = {}, r_threshold = 1, r_fluid_threshold = 1 },
			[2] = { locked_slots = locked_slots, reserved_fluid_capacity = 0 },
		},
		trains = {
			[7] = {
				item_slot_capacity = 40,
				fluid_capacity = 25000,
				entity = { valid = true, cargo_wagons = { {} }, fluid_wagons = { {} } },
			},
		},
	}
	local r_stop = { station_id = 1, tick_signals = requests, r_threshold = 1, r_fluid_threshold = 1, requested = requested }
	local p_stop = { station_id = 2, item_p_counts = p_counts }
	local out = {}
	for _, item in ipairs(create_manifest(map_data, r_stop, p_stop, 7, "iron-plate")) do out[item.name] = item.count end
	return out
end

local TWO_ITEMS_AND_FLUID = function()
	return { sig("iron-plate", -1900), sig("copper-plate", -1900), sig("water", -1000, "fluid") }
end

test("locked slots off: reserved once per cargo wagon however many items the delivery carries", function()
	H.fresh()
	-- 40 - 2 = 38 slots: both 19-stack requests fit.
	assert_eq(manifest_for(TWO_ITEMS_AND_FLUID(), 2, false),
		{ ["iron-plate"] = 1900, ["copper-plate"] = 1900, water = 1000 })
	assert_eq(manifest_for(TWO_ITEMS_AND_FLUID(), 2, nil),
		{ ["iron-plate"] = 1900, ["copper-plate"] = 1900, water = 1000 }, "unset reads as off")
end)

test("locked slots per item: multiplied by the item types, the fluid does not count", function()
	H.fresh()
	-- 40 - 2 * 2 = 36 slots: the primary item takes 19, the second is cut to 17 stacks. Counting the fluid would
	-- leave 34 and cut it to 15.
	assert_eq(manifest_for(TWO_ITEMS_AND_FLUID(), 2, true),
		{ ["iron-plate"] = 1900, ["copper-plate"] = 1700, water = 1000 })
end)

test("locked slots per item: one item type reserves the same as off, zero locked slots reserves nothing", function()
	H.fresh()
	local one = function() return { sig("iron-plate", -5000), sig("water", -1000, "fluid") } end
	assert_eq(manifest_for(one(), 2, true), { ["iron-plate"] = 3800, water = 1000 })
	assert_eq(manifest_for(one(), 2, false), { ["iron-plate"] = 3800, water = 1000 })
	assert_eq(manifest_for(TWO_ITEMS_AND_FLUID(), 0, true),
		{ ["iron-plate"] = 1900, ["copper-plate"] = 1900, water = 1000 })
end)
