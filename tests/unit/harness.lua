-- Host-side stand-ins for the Factorio runtime, just enough to load the manager's pure modules under lua5.2.
-- Every stub mirrors documented engine behaviour; anything that needs the real engine stays out of the unit layer.

local harness = {}

local MOD_ROOT = os.getenv("CYBERSYN_ROOT") or "cybersyn"
harness.mod_root = MOD_ROOT
package.path = MOD_ROOT .. "/?.lua;" .. package.path

-- ---------------------------------------------------------------- serpent / log / table_size

local function serialize(v, indent, depth, seen)
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t ~= "table" then return tostring(v) end
	if seen[v] then return '"<cycle>"' end
	if depth > 8 then return '"<deep>"' end
	seen[v] = true
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	-- Sorted output keeps failure messages identical between runs; pairs() order is not.
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		if ta == "number" or ta == "string" then return a < b end
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	local n = #v
	for _, k in ipairs(keys) do
		local key
		if type(k) == "number" and k >= 1 and k <= n and k % 1 == 0 then
			key = ""
		elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
			key = k .. " = "
		else
			key = "[" .. serialize(k, indent, depth + 1, seen) .. "] = "
		end
		parts[#parts + 1] = key .. serialize(v[k], indent, depth + 1, seen)
	end
	seen[v] = nil
	if indent then
		local pad = string.rep("  ", depth + 1)
		return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. "\n" .. string.rep("  ", depth) .. "}"
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

serpent = {
	line = function(v) return serialize(v, false, 0, {}) end,
	block = function(v) return serialize(v, true, 0, {}) end,
}
serpent.dump = serpent.line

harness.logged = {}
function log(msg)
	harness.logged[#harness.logged + 1] = msg
end

function table_size(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- ---------------------------------------------------------------- defines

defines = {
	events = {
		on_tick = 0,
		on_gui_click = 1,
		on_gui_checked_state_changed = 2,
		on_gui_closed = 3,
		on_gui_confirmed = 4,
		on_gui_elem_changed = 5,
		on_gui_hover = 6,
		on_gui_leave = 7,
		on_gui_location_changed = 8,
		on_gui_selected_tab_changed = 9,
		on_gui_selection_state_changed = 10,
		on_gui_text_changed = 11,
		on_gui_value_changed = 12,
		on_gui_switch_state_changed = 13,
		on_player_created = 14,
		on_player_removed = 15,
		on_runtime_mod_setting_changed = 16,
		on_train_changed_state = 17,
		on_train_created = 18,
		on_train_schedule_changed = 19,
		on_player_display_resolution_changed = 20,
		on_player_display_scale_changed = 21,
		on_player_controller_changed = 22,
		on_lua_shortcut = 23,
	},
	train_state = {
		on_the_path = 0,
		path_lost = 1,
		no_schedule = 2,
		no_path = 3,
		arrive_signal = 4,
		wait_signal = 5,
		arrive_station = 6,
		wait_station = 7,
		manual_control_stop = 8,
		manual_control = 9,
		destination_full = 10,
	},
	controllers = { ghost = 0, character = 1, god = 2, editor = 3, cutscene = 4, spectator = 5, remote = 6 },
	render_mode = { game = 1, chart = 2 },
	wire_connector_id = {
		circuit_red = 1,
		circuit_green = 2,
		combinator_input_red = 1,
		combinator_input_green = 2,
		combinator_output_red = 3,
		combinator_output_green = 4,
	},
	entity_status = {
		working = 1,
		normal = 2,
		no_power = 3,
		low_power = 4,
		disabled_by_control_behavior = 5,
		disabled_by_script = 6,
		marked_for_deconstruction = 7,
	},
	mouse_button_type = { none = 1, left = 2, right = 4, middle = 8 },
	alert_type = { custom = 1, train_out_of_fuel = 2 },
	gui_type = { none = 0, entity = 1, trains = 7, custom = 16 },
	relative_gui_type = { train_stop_gui = 1, train_gui = 2 },
	relative_gui_position = { top = 0, bottom = 1, left = 2, right = 3 },
	print_sound = { always = 0, never = 1, use_player_settings = 2 },
	train_type = { cargo_wagon = 1, fluid_wagon = 2 },
}

-- ---------------------------------------------------------------- prototypes

local function proto(name, order, extra)
	local p = { name = name, order = order, localised_name = { "item-name." .. name }, valid = true }
	if extra then
		for k, v in pairs(extra) do p[k] = v end
	end
	return p
end

prototypes = {
	item = {
		["iron-ore"] = proto("iron-ore", "e[iron-ore]", { stack_size = 50, type = "item" }),
		["copper-ore"] = proto("copper-ore", "f[copper-ore]", { stack_size = 50, type = "item" }),
		["coal"] = proto("coal", "b[coal]", { stack_size = 50, type = "item" }),
		["stone"] = proto("stone", "d[stone]", { stack_size = 50, type = "item" }),
		["iron-plate"] = proto("iron-plate", "a[iron-plate]", { stack_size = 100, type = "item" }),
		["copper-plate"] = proto("copper-plate", "b[copper-plate]", { stack_size = 100, type = "item" }),
	},
	fluid = {
		["water"] = proto("water", "a[fluid]-a[water]"),
		["crude-oil"] = proto("crude-oil", "a[fluid]-b[crude-oil]"),
	},
	virtual_signal = {
		["signal-A"] = proto("signal-A", "d[letters]-a"),
		["signal-B"] = proto("signal-B", "d[letters]-b"),
		["signal-each"] = proto("signal-each", "a[special]-c"),
		["cybersyn-priority"] = proto("cybersyn-priority", "z[cybersyn]-a"),
		["cybersyn-request-threshold"] = proto("cybersyn-request-threshold", "z[cybersyn]-b"),
		["cybersyn-fluid-request-threshold"] = proto("cybersyn-fluid-request-threshold", "z[cybersyn]-c"),
	},
	quality = {
		["normal"] = proto("normal", "a", { level = 0 }),
		["uncommon"] = proto("uncommon", "b", { level = 1 }),
		["rare"] = proto("rare", "c", { level = 2 }),
		["legendary"] = proto("legendary", "e", { level = 5 }),
	},
	entity = {
		["cybersyn-combinator"] = proto("cybersyn-combinator", "z"),
	},
	recipe = {},
	space_location = {},
	asteroid_chunk = {},
	item_group = {},
	item_subgroup = {},
}

-- ---------------------------------------------------------------- helpers

local function json_encode(v)
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" or t == "number" then return tostring(v) end
	if t == "string" then return string.format("%q", v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	if #keys == #v then
		local parts = {}
		for i = 1, #v do parts[i] = json_encode(v[i]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = string.format("%q", tostring(k)) .. ":" .. json_encode(v[k])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local sprite_types = {
	item = "item",
	fluid = "fluid",
	["virtual-signal"] = "virtual_signal",
	entity = "entity",
	recipe = "recipe",
	quality = "quality",
}

helpers = {
	multilingual_to_lower = string.lower,
	table_to_json = json_encode,
	-- A sprite path is valid exactly when it names an existing prototype of that type.
	is_valid_sprite_path = function(path)
		local kind, name = string.match(path, "^([^/]+)/(.+)$")
		local group = kind and sprite_types[kind]
		return group ~= nil and prototypes[group][name] ~= nil
	end,
	write_file = function() end,
}

-- ---------------------------------------------------------------- settings / script / remote

harness.player_settings = {}

settings = {
	startup = {},
	global = {},
	get_player_settings = function(player_index)
		return harness.player_settings[player_index] or {}
	end,
}

script = {
	mod_name = "cybersyn",
	active_mods = { base = "2.1.23", flib = "0.17.2", cybersyn = "0.0.0" },
	on_event = function() end,
	on_nth_tick = function() end,
	on_init = function() end,
	on_load = function() end,
	on_configuration_changed = function() end,
	register_on_object_destroyed = function() return 0 end,
	generate_event_name = (function()
		local n = 1000
		return function()
			n = n + 1
			return n
		end
	end)(),
	raise_event = function() end,
}

remote = {
	interfaces = {},
	add_interface = function(name, fns) remote.interfaces[name] = fns end,
	remove_interface = function(name) remote.interfaces[name] = nil end,
	call = function(name, fn, ...)
		local i = remote.interfaces[name]
		if not (i and i[fn]) then error("unknown remote interface " .. tostring(name) .. "." .. tostring(fn)) end
		return i[fn](...)
	end,
}

-- ---------------------------------------------------------------- game

local function new_profiler()
	local p = { stopped = false, divisor = 1, restarts = 0 }
	function p.stop() p.stopped = true end
	function p.restart() p.stopped = false; p.restarts = p.restarts + 1 end
	function p.reset() p.stopped = false end
	function p.divide(n) p.divisor = n end
	function p.add() end
	return p
end

local function new_game()
	local g = { tick = 0, ticks_played = 0, players = {}, surfaces = {}, speed = 1 }
	function g.create_profiler(stopped)
		local p = new_profiler()
		p.stopped = stopped == true
		return p
	end
	function g.get_player(i) return g.players[i] end
	function g.print() end
	return g
end

-- ---------------------------------------------------------------- flib and core stand-ins

-- flib 0.17.2 format.lua (logic unchanged, comments dropped): both functions are pure.
local flib_format = {}
do
	local suffix_list = {
		{ "Q", 1e30 }, { "R", 1e27 }, { "Y", 1e24 }, { "Z", 1e21 }, { "E", 1e18 },
		{ "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 },
	}
	function flib_format.number(amount, append_suffix, fixed_precision)
		local suffix = ""
		if append_suffix then
			for _, data in ipairs(suffix_list) do
				if math.abs(amount) >= data[2] then
					amount = amount / data[2]
					suffix = " " .. data[1]
					break
				end
			end
			if not fixed_precision then
				amount = math.floor(amount * 10) / 10
			end
		end
		local formatted, k = tostring(amount), nil
		if fixed_precision then
			local len_before = #tostring(math.floor(amount))
			local len_after = math.max(0, fixed_precision - len_before - 1)
			formatted = string.format("%." .. len_after .. "f", amount)
		end
		while true do
			formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
			if k == 0 then break end
		end
		return formatted .. suffix
	end
	function flib_format.time(tick, include_leading_zeroes)
		local total_seconds = math.floor((tick or game.ticks_played) / 60)
		local seconds = total_seconds % 60
		local minutes = math.floor(total_seconds / 60)
		if minutes > 59 then
			minutes = minutes % 60
			local hours = math.floor(total_seconds / 3600)
			if include_leading_zeroes then
				return string.format("%02d:%02d:%02d", hours, minutes, seconds)
			end
			return string.format("%d:%02d:%02d", hours, minutes, seconds)
		end
		if include_leading_zeroes then
			return string.format("%02d:%02d", minutes, seconds)
		end
		return string.format("%d:%02d", minutes, seconds)
	end
end

-- flib.gui.add builds elements through LuaGuiElement.add; the fake elements below implement that, so the stub
-- forwards to it and records nothing else. Handlers are only registered, never dispatched.
local flib_gui = { handlers = {}, events = {} }
function flib_gui.add(parent, def, elems)
	elems = elems or {}
	local children = def.children
	local tabs = def.tabs
	local spec = {}
	for k, v in pairs(def) do
		if k ~= "children" and k ~= "tabs" and k ~= "handler" and k ~= "elem_mods" and k ~= "style_mods" and k ~= "drag_target" then
			spec[k] = v
		end
	end
	local elem = parent.add(spec)
	if def.name then elems[def.name] = elem end
	if def.style_mods then
		for k, v in pairs(def.style_mods) do elem.style[k] = v end
	end
	if def.elem_mods then
		for k, v in pairs(def.elem_mods) do elem[k] = v end
	end
	if children then
		for _, child in ipairs(children) do flib_gui.add(elem, child, elems) end
	end
	if tabs then
		for _, pair in ipairs(tabs) do
			flib_gui.add(elem, pair.tab, elems)
			flib_gui.add(elem, pair.content, elems)
		end
	end
	return elems, elem
end
function flib_gui.add_handlers(new_handlers, wrapper, prefix)
	for name, fn in pairs(new_handlers) do
		flib_gui.handlers[(prefix and prefix .. ":" or "") .. name] = { fn = fn, wrapper = wrapper }
	end
end
function flib_gui.dispatch() return false end
function flib_gui.handle_events() end
function flib_gui.format_handlers(input) return input end

local flib_position = {}
function flib_position.distance(a, b)
	local ax, ay = a.x or a[1], a.y or a[2]
	local bx, by = b.x or b[1], b.y or b[2]
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

package.preload["__flib__.format"] = function() return flib_format end
package.preload["__flib__.gui"] = function() return flib_gui end
package.preload["__flib__.position"] = function() return flib_position end
-- The GUI only calls open_gui, from click handlers the unit layer never dispatches.
-- get_main_locomotive as flib 0.17.2 has it.
package.preload["__flib__.train"] = function()
	return {
		open_gui = function() end,
		get_main_locomotive = function(train)
			if not train.valid then return nil end
			local locomotives = train.locomotives
			return locomotives and (locomotives.front_movers[1] or locomotives.back_movers[1])
		end,
	}
end
-- scripts/gui.lua's entity GUI handlers, which the manager's on_gui_opened and on_gui_closed run first.
function on_entity_gui_opened_closed() return false end
function on_entity_gui_closed() end
-- lib.lua requires the core util but never calls it.
package.preload["__core__.lualib.util"] = function() return {} end
-- central-planning.lua is loaded for hash_item/hash_signal/unhash_signal; analytics is only touched by the
-- dispatcher functions, which the unit layer never calls.
package.preload["scripts.analytics"] = function() return {} end
-- The manager GUI is engine-only; the remote interface only hands toggle_gui to it.
package.preload["gui.main"] = function() return {} end

harness.flib_gui = flib_gui

-- ---------------------------------------------------------------- fake LuaGuiElement

--- A LuaGuiElement stand-in: children (a fresh array per read), add/clear/destroy/swap_children, index and parent.
--- `harness.gui_log` records structural calls so tests can count builds and moves.
harness.gui_log = {}

local function reindex(kids)
	for i, c in ipairs(kids) do c.index = i end
end

-- LuaGuiElement.children returns a new array on every read; tests that hold one must not see later changes.
-- Assigning a style name replaces the element's LuaStyle, as `elem.style = "name"` does in the engine.
local element_meta = {
	__index = function(e, k)
		if k == "children" then
			local out = {}
			for i, c in ipairs(rawget(e, "_kids")) do out[i] = c end
			return out
		elseif k == "style" then
			return rawget(e, "_style")
		end
	end,
	__newindex = function(e, k, v)
		if k == "style" then
			rawset(e, "_style", type(v) == "string" and { name = v } or v)
		else
			rawset(e, k, v)
		end
	end,
}

function harness.element(spec)
	local e = { _kids = {} }
	for k, v in pairs(spec or {}) do
		if k ~= "style" then e[k] = v end
	end
	e.valid = true
	e._style = spec and spec.style and { name = spec.style } or {}
	e.tags = e.tags or {}
	local kids = e._kids
	function e.add(child_spec)
		local c = harness.element(child_spec)
		c.parent = e
		table.insert(kids, child_spec.index or (#kids + 1), c)
		reindex(kids)
		harness.gui_log[#harness.gui_log + 1] = { op = "add", key = child_spec.name or child_spec.caption }
		return c
	end
	function e.clear()
		for _, c in ipairs(kids) do c.valid = false end
		for i = #kids, 1, -1 do kids[i] = nil end
		harness.gui_log[#harness.gui_log + 1] = { op = "clear" }
	end
	function e.destroy()
		e.valid = false
		local p = e.parent
		if p then
			local pk = rawget(p, "_kids")
			for i, c in ipairs(pk) do
				if c == e then
					table.remove(pk, i)
					break
				end
			end
			reindex(pk)
		end
		harness.gui_log[#harness.gui_log + 1] = { op = "destroy", key = e.name or e.caption }
	end
	function e.swap_children(i, j)
		kids[i], kids[j] = kids[j], kids[i]
		reindex(kids)
		harness.gui_log[#harness.gui_log + 1] = { op = "swap", i = i, j = j }
	end
	return setmetatable(e, element_meta)
end

--- Counts gui_log entries with the given op.
function harness.count_ops(op)
	local n = 0
	for _, entry in ipairs(harness.gui_log) do
		if entry.op == op then n = n + 1 end
	end
	return n
end

-- ---------------------------------------------------------------- state reset and module loading

mod_settings = {}
storage = {}
game = new_game()

--- Resets every piece of mutable global state a test can touch.
function harness.fresh()
	storage = {}
	mod_settings = {}
	game = new_game()
	harness.player_settings = {}
	harness.logged = {}
	harness.gui_log = {}
end

-- Globals from the mod's own files, loaded once: they only define constants and functions.
dofile(MOD_ROOT .. "/scripts/constants.lua")
dofile(MOD_ROOT .. "/scripts/lib.lua")
dofile(MOD_ROOT .. "/scripts/factorio-api.lua")
dofile(MOD_ROOT .. "/scripts/central-planning.lua")

--- Requires a module from scratch, so module-level caches (util's rank and sprite caches) start empty.
--- @param name string
function harness.load(name)
	package.loaded[name] = nil
	return require(name)
end

--- Fresh instances of the named modules, loaded in order so a later one requires the earlier ones, with
--- package.loaded put back afterwards: whatever a test stubs on them cannot reach another test.
--- @return table ...
function harness.isolated(...)
	local names = { ... }
	local saved, out = {}, {}
	for i, name in ipairs(names) do
		saved[i] = package.loaded[name]
		package.loaded[name] = nil
	end
	for i, name in ipairs(names) do out[i] = require(name) end
	for i, name in ipairs(names) do package.loaded[name] = saved[i] end
	return table.unpack(out)
end

--- Deep copy of plain data.
function harness.copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = harness.copy(v) end
	return out
end

--- Sorted array of a table's keys (numbers before strings), for asserting on sets without relying on pairs() order.
function harness.keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	return out
end

harness.serialize = serpent.line

-- ---------------------------------------------------------------- locale

--- The locales that ship a manager.cfg. Only en is complete: the others keep just their real translations and the
--- engine falls back to en for every key they lack, so a test must check what a player sees, not the raw file.
harness.LOCALES = { "en", "de", "es", "fr", "ko", "ru", "sv-SE" }

--- section -> key -> value of one cfg file under locale/, plus the keys in file order as sections[name].order.
function harness.read_cfg(path)
	local f = assert(io.open(MOD_ROOT .. "/locale/" .. path, "r"))
	local sections, current = {}, nil
	for line in f:lines() do
		line = line:gsub("\r$", "")
		local head = line:match("^%[(.-)%]%s*$")
		if head then
			current = sections[head] or { order = {} }
			sections[head] = current
		elseif current and not line:match("^%s*[;#]") then
			local k, v = line:match("^([^=]+)=(.*)$")
			if k then
				if current[k] == nil then current.order[#current.order + 1] = k end
				current[k] = v
			end
		end
	end
	f:close()
	return sections
end

--- What a player in `loc` gets from `file` (default manager.cfg): en's sections with loc's own values on top.
function harness.locale(loc, file)
	file = file or "manager.cfg"
	local out = harness.read_cfg("en/" .. file)
	if loc ~= "en" then
		for name, s in pairs(harness.read_cfg(loc .. "/" .. file)) do
			local into = out[name] or { order = {} }
			out[name] = into
			for _, k in ipairs(s.order) do
				if into[k] == nil then into.order[#into.order + 1] = k end
				into[k] = s[k]
			end
		end
	end
	return out
end

--- Fills in the tables gui/main.lua's init_player_fields gives every PlayerData.
--- @param pd table
--- @return table pd
function harness.player_data(pd)
	pd.filters = pd.filters or {}
	pd.cache = pd.cache or {}
	pd.tabs = pd.tabs or {}
	for _, tab in ipairs(require("scripts.gui.utils.tabs")) do pd.tabs[tab.name] = pd.tabs[tab.name] or {} end
	return pd
end

--- harness.locale(loc, file) as cfg text, for tests that search it for "\nkey=" lines.
function harness.locale_text(loc, file)
	local parts = {}
	for name, s in pairs(harness.locale(loc, file)) do
		parts[#parts + 1] = "\n[" .. name .. "]"
		for _, k in ipairs(s.order) do parts[#parts + 1] = "\n" .. k .. "=" .. s[k] end
	end
	return table.concat(parts) .. "\n"
end

return harness
