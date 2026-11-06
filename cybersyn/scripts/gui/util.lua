local format = require("__flib__.format")
local stats = require("scripts.stats")
local diag = require("scripts.diag")
local logic = require("scripts.gui.tab-logic")
local pm = require("scripts.gui.problems-model")
local rich_text = require("scripts.gui.rich-text")

local util = {}

--- Create a flying text at the player's cursor with an error sound.
--- @param player LuaPlayer
--- @param message LocalisedString
function util.error_flying_text(player, message)
	player.create_local_flying_text({ create_at_cursor = true, text = message })
	player.play_sound({ path = "utility/cannot_build" })
end

--- A station's network as a caption: the signal's icon, "Each" for the each-network, "?" without one. Explain and
--- the item drill-down both go through here so they name a network the same way.
--- @param network_name string?
--- @return LocalisedString
function util.network_caption(network_name)
	if network_name == NETWORK_EACH then return { "cybersyn-gui.network-each" } end
	return rich_text.network_icon(network_name)
end

--- @param index uint
--- @return string
function util.surface_name(index)
	local s = game.get_surface(index)
	return s and s.name or tostring(index)
end

--- Builds a valid sprite path or returns nil
--- @param item string
--- @return string, string, LocalizedString
function util.generate_item_references(item)
	local sprite = nil
	local image_path = ""
	local item_name
	if helpers.is_valid_sprite_path("item/" .. item) then
		sprite = "item/" .. item
		image_path = "[img=item." .. item .. "]"
		local proto = prototypes.item[item]
		item_name = proto and proto.localised_name or item
	elseif helpers.is_valid_sprite_path("fluid/" .. item) then
		sprite = "fluid/" .. item
		image_path = "[img=fluid." .. item .. "]"
		local proto = prototypes.fluid[item]
		item_name = proto and proto.localised_name or item
	elseif helpers.is_valid_sprite_path("virtual-signal/" .. item) then
		sprite = "virtual-signal/" .. item
		image_path = "[img=virtual-signal." .. item .. "]"
		local proto = prototypes.virtual_signal[item]
		item_name = proto and proto.localised_name or item
	end
	return sprite, image_path, item_name
end

--- Returns a prototype based on an item name.
---@param name string
---@return LuaPrototypeBase
function util.prototype_from_name(name)
	return prototypes.item[name] or
		   prototypes.fluid[name] or
		   prototypes.virtual_signal[name] or
		   prototypes.entity[name] or
		   prototypes.recipe[name] or
		   prototypes.space_location[name] or
		   prototypes.asteroid_chunk[name] or
		   prototypes.quality[name]
end

--- Creates a SignalID structure from an item name and optional quality.
---@param name string
---@param quality string?
---@return SignalID
function util.signalid_from_name(name, quality)
	---@type SignalIDType
	-- TODO is there a better way to get item type from name?
	local signal_type = prototypes.item[name] ~= nil and "item" or
			prototypes.fluid[name] ~= nil and "fluid" or
			prototypes.virtual_signal[name] ~= nil and "virtual" or
			prototypes.entity[name] ~= nil and "entity" or
			prototypes.recipe[name] ~= nil and "recipe" or
			prototypes.space_location[name] ~= nil and "space-location" or
			prototypes.asteroid_chunk[name] ~= nil and "asteroid-chunk" or
			"quality"
	return {
		type = signal_type,
		name = name,
		quality = quality,
	}
end

--- False when the signal behind a stored hash no longer exists (its mod was removed), since writing it into
--- a choose-elem-button raises an error.
--- @param hash string?
--- @return boolean
function util.signal_hash_valid(hash)
	if type(hash) ~= "string" then return false end
	local name, quality = unhash_signal(hash)
	if quality and not prototypes.quality[quality] then return false end
	return util.prototype_from_name(name) ~= nil
end

--- @param hash string
--- @return SignalID
function util.signalid_from_hash(hash)
	local name, quality = unhash_signal(hash)
	return util.signalid_from_name(name, quality)
end

-- Pure functions of the loaded prototypes, so caching them per Lua state cannot desync.
local rank_cache = {}
local sprite_cache = {}
local sprite_valid = {}
local network_sprites = {}

--- The sprite of a network signal (item, fluid or virtual signal), nil when none can be drawn. Memoised: each lookup
--- is up to three is_valid_sprite_path calls, and the tabs ask for every row.
--- @param name string
--- @return string?
function util.network_sprite(name)
	local sprite = network_sprites[name]
	if sprite == nil then
		sprite = util.generate_item_references(name) or false
		network_sprites[name] = sprite
	end
	return sprite or nil
end

--- `path` when the loaded prototypes can draw it, else `fallback` (nil allowed). Memoised: tabs ask on every row
--- of every update.
--- @param path string?
--- @param fallback string?
--- @return string?
function util.valid_sprite(path, fallback)
	if not path then return fallback end
	local ok = sprite_valid[path]
	if ok == nil then
		ok = helpers.is_valid_sprite_path(path)
		sprite_valid[path] = ok
	end
	if ok then return path end
	return fallback
end

--- Rank of an item in the crafting-menu order (group, subgroup, order), quality as a fraction.
--- Unknown items rank after every known one.
--- @param hash string
--- @return number
function util.item_rank(hash)
	local rank = rank_cache[hash]
	if rank then return rank end
	local name, quality = unhash_signal(hash)
	local order = storage.manager and storage.manager.item_order
	rank = order and order[name] or 1e9
	if quality then
		local proto = prototypes.quality[quality]
		rank = rank + ((proto and proto.level or 15) + 1) / 32
	end
	rank_cache[hash] = rank
	return rank
end

--- Sprite, quality and a rich-text name for an item/fluid hash, or nil when no sprite exists.
--- @param hash string
--- @return string? sprite
--- @return string? quality
--- @return LocalisedString? name_tooltip "[img] Localised name"
--- @return SignalID? signal
--- @return LocalisedString? name the localised name alone
function util.item_sprite_and_tooltip(hash)
	local cached = sprite_cache[hash]
	if cached == nil then
		local name, quality = unhash_signal(hash)
		local signal = util.signalid_from_name(name, quality)
		local sprite = (signal.type == "fluid" and "fluid/" or signal.type == "virtual" and "virtual-signal/" or "item/") .. name
		-- A quality removed by a mod change still lingers in persisted hashes, and gui.add throws on it.
		if helpers.is_valid_sprite_path(sprite) and not (quality and not prototypes.quality[quality]) then
			local proto = util.prototype_from_name(name)
			local localised = proto and proto.localised_name or name
			cached = {
				sprite = sprite,
				quality = quality,
				tooltip = { "", rich_text.signal(signal), " ", localised },
				signal = signal,
				name = localised,
			}
		else
			cached = false
		end
		sprite_cache[hash] = cached
	end
	if not cached then return nil end
	return cached.sprite, cached.quality, cached.tooltip, cached.signal, cached.name
end

--- Decorate-sort-undecorate. `key_fn` runs once per row; the comparator touches no API.
--- Keys must all be numbers or all strings; nil keys sort last in both directions.
--- Ties are broken by `tiebreak_fn(row)` ascending, then by `tiebreak2_fn(row)` ascending (together they must be unique
--- and comparable), else by input position.
--- @param rows any[] Sorted in place and returned.
--- @param key_fn fun(row: any): (number|string|nil)
--- @param ascending boolean
--- @param tiebreak_fn (fun(row: any): (number|string))?
--- @param tiebreak2_fn (fun(row: any): (number|string))?
--- @return any[]
function util.sort_by(rows, key_fn, ascending, tiebreak_fn, tiebreak2_fn)
	local n = #rows
	local decorated = {}
	for i = 1, n do
		local row = rows[i]
		decorated[i] = { key_fn(row), tiebreak_fn and tiebreak_fn(row) or i, tiebreak2_fn and tiebreak2_fn(row) or i, row }
	end
	table.sort(decorated, function(a, b)
		local ka, kb = a[1], b[1]
		if ka ~= kb then
			if ka == nil then return false end
			if kb == nil then return true end
			if ascending then return ka < kb end
			return ka > kb
		end
		local ta, tb = a[2], b[2]
		if ta ~= tb then return ta < tb end
		return a[3] < b[3]
	end)
	for i = 1, n do
		rows[i] = decorated[i][4]
	end
	return rows
end

--- A Cybersyn stop by unit number: station first, then depot, then refueler, nil when its stop entity is gone.
--- @param id uint
--- @return LuaEntity? stop
--- @return (Station|Depot|Refueler)? record
--- @return "station"|"depot"|"refueler"|nil kind
function util.stop_record(id)
	local record, kind = storage.stations[id], "station"
	if not record then record, kind = storage.depots[id], "depot" end
	if not record then record, kind = storage.refuelers[id], "refueler" end
	local stop = record and record.entity_stop
	if stop and stop.valid then return stop, record, kind end
	return nil, nil, nil
end

--- Every GUI handler's form: `handler(player, player_data, refs, e)`. Panels outside the manager window can fire
--- before `storage.manager` exists.
--- @param e {player_index: uint}
function util.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	local player_data = storage.manager and storage.manager.players[e.player_index]
	if not (player and player_data) then return end
	handler(player, player_data, player_data.refs, e)
end

local ACK_HOUR = 216000

--- How long an acknowledge click holds: a day, an hour with shift, until the finding clears with control (nil).
--- @param e EventData.on_gui_click
--- @return uint?
function util.ack_until_tick(e)
	if e.control then return nil end
	return game.tick + (e.shift and ACK_HOUR or 24 * ACK_HOUR)
end

--- A sort key that orders the digit runs of a string by their value ("stn-2" before "stn-10"): each run becomes its
--- length in two digits followed by the digits without leading zeros.
--- @param s string
--- @return string
function util.natural_key(s)
	return (string.gsub(s, "%d+", function(d)
		d = string.gsub(d, "^0+", "")
		if d == "" then d = "0" end
		return string.format("%02d", #d) .. d
	end))
end

--- The error-severity checks station `id` fails that are not acknowledged: the Overview's Misconfigured rule, the
--- one problems-model applies to the Stations rows, so the line and its rows agree.
--- @param id uint station id
--- @param bits int? the station's lint bits (SnapshotStation.lint)
--- @param by_check {[int]: int}? adds 1 per open check
--- @return int open
function util.open_setup_errors(id, bits, by_check)
	return pm.open_errors(id, bits, diag.is_acked, by_check)
end

--- Items delivered in the last `minutes`, from stats.aggregate, cached per game minute for this player and shared by
--- every view (the Inventory tooltips, the item drill-down), so they never show two figures in the same minute.
--- @param player_data PlayerData
--- @param minutes int
--- @return {[string]: int}
function util.delivered_items(player_data, minutes)
	local minute = math.floor(game.tick / 3600)
	local cache = player_data.cache.delivered
	if not (cache and cache.minute == minute) then
		cache = { minute = minute, by_period = {} }
		player_data.cache.delivered = cache
	end
	local items = cache.by_period[minutes]
	if not items then
		items = stats.aggregate(minutes).items
		cache.by_period[minutes] = items
	end
	return items
end

--- @param hashes {[string]: any}
--- @return string[]
function util.hashes_in_item_order(hashes)
	local list = {}
	for hash in pairs(hashes) do
		list[#list + 1] = hash
	end
	return util.sort_by(list, util.item_rank, true, function(h) return h end)
end

--- Slot styles: `prefix` .. colour for a slot (`selected_prefix` for the `selected` item's), `count` for its label.
--- @alias SlotLook {prefix: string, selected_prefix: string?, count: string, selected: string?}
local SMALL_SLOTS = { prefix = "ltnm_small_slot_button_", count = "ltnm_label_signal_count" }

--- @param look SlotLook
local function slot_button(hash, count, color, tooltip_tail, look)
	local sprite, quality, name_tooltip = util.item_sprite_and_tooltip(hash)
	if not sprite then return nil end
	local tooltip = { "", name_tooltip }
	for _, part in ipairs(tooltip_tail) do
		tooltip[#tooltip + 1] = part
	end
	return {
		type = "sprite-button",
		sprite = sprite,
		quality = quality,
		enabled = false,
		style = (hash == look.selected and look.selected_prefix or look.prefix) .. color,
		tooltip = tooltip,
		elem_tooltip = util.elem_tooltip(hash),
		tags = { kind = "item", id = hash },
		children = {
			{
				type = "label",
				style = look.count,
				ignored_by_interaction = true,
				caption = format_signal_count(count),
			},
		},
	}
end

--- Provided (green) and requested (red, orange below threshold) items of a snapshot station, in item order.
--- @param st SnapshotStation
--- @param look SlotLook? the small LTNM slots when nil
--- @return GuiElemDef[]
function util.slot_table_build_from_station(st, look)
	look = look or SMALL_SLOTS
	local children = {}
	local now = game.tick
	for _, hash in ipairs(util.hashes_in_item_order(st.provided)) do
		children[#children + 1] = slot_button(hash, st.provided[hash], "green", {
			" ", { "cybersyn-gui.provided" },
			"\n", { "cybersyn-gui.amount", format.number(st.provided[hash]) },
		}, look)
	end
	for _, hash in ipairs(util.hashes_in_item_order(st.requested)) do
		local req = st.requested[hash]
		local tail
		if req.active then
			tail = { " ", { "cybersyn-gui.requested" } }
			local start = st.wait[hash]
			if start then
				tail[#tail + 1] = "\n[color=yellow]"
				tail[#tail + 1] = { "cybersyn-gui.waiting-for", logic.format_duration(now - start) }
				tail[#tail + 1] = "[/color]"
			end
		else
			tail = { " ", { "cybersyn-gui.requested-below-threshold" } }
		end
		tail[#tail + 1] = "\n"
		tail[#tail + 1] = { "cybersyn-gui.amount", format.number(req.count) }
		children[#children + 1] = slot_button(hash, req.count, req.active and "red" or "orange", tail, look)
	end
	return children
end

--- @param st SnapshotStation
--- @param look SlotLook? the small LTNM slots when nil
--- @return GuiElemDef[]
function util.slot_table_build_from_deliveries(st, look)
	look = look or SMALL_SLOTS
	local children = {}
	for _, hash in ipairs(util.hashes_in_item_order(st.deliveries)) do
		local count = st.deliveries[hash]
		children[#children + 1] = slot_button(hash, count, count > 0 and "green" or "blue", {
			" ", count > 0 and { "cybersyn-gui.incoming" } or { "cybersyn-gui.outgoing" },
			"\n", { "cybersyn-gui.amount", format.number(count) },
		}, look)
	end
	return children
end

--- @param name string
--- @param count int
--- @param look SlotLook
--- @param source LocalisedString? which combinator, for a signal of the control combinator
--- @return GuiElemDef?
local function virtual_slot(name, count, look, source)
	local sprite = "virtual-signal/" .. name
	if not util.valid_sprite(sprite) then return nil end
	local proto = prototypes.virtual_signal[name]
	local tooltip = { "", "[virtual-signal=" .. name .. "] ", proto and proto.localised_name or name, "\n",
		{ "cybersyn-gui.amount", format.number(count) } }
	if source then
		tooltip[#tooltip + 1] = "\n"
		tooltip[#tooltip + 1] = source
	end
	return {
		type = "sprite-button",
		sprite = sprite,
		enabled = false,
		style = look.prefix .. "default",
		tooltip = tooltip,
		-- The same signal can be on both combinators: each gets its own slot key.
		tags = { slot_key = (source and "c2:" or "c1:") .. name },
		children = {
			{ type = "label", style = look.count, ignored_by_interaction = true, caption = format_signal_count(count) },
		},
	}
end

--- Virtual signals of the station combinator, then of the control combinator, then the control combinator's per-item
--- thresholds.
--- @param st SnapshotStation
--- @param look SlotLook? the small LTNM slots when nil
--- @return GuiElemDef[]
function util.slot_table_build_from_control_signals(st, look)
	look = look or SMALL_SLOTS
	local children = {}
	local control2_source = { "cybersyn-gui.control-combinator-signal" }
	for _, signals in ipairs({ st.control, st.control2 or {} }) do
		local names = {}
		for name in pairs(signals) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			children[#children + 1] = virtual_slot(name, signals[name], look,
				signals ~= st.control and control2_source or nil)
		end
	end
	for _, hash in ipairs(util.hashes_in_item_order(st.thresholds)) do
		children[#children + 1] = slot_button(hash, st.thresholds[hash], "default", {
			"\n", { "cybersyn-gui.request-threshold", format.number(st.thresholds[hash]) },
		}, look)
	end
	return children
end

local elem_tooltip_cache = {}

--- The native item or fluid tooltip of an item hash (stacks above a custom tooltip), or nil for anything else.
--- @param hash string
--- @return ElemID?
function util.elem_tooltip(hash)
	local cached = elem_tooltip_cache[hash]
	if cached == nil then
		local name, quality = unhash_signal(hash)
		if prototypes.item[name] and not (quality and not prototypes.quality[quality]) then
			cached = { type = "item-with-quality", name = name, quality = quality or "normal" }
		elseif prototypes.fluid[name] then
			cached = { type = "fluid", name = name }
		else
			cached = false
		end
		elem_tooltip_cache[hash] = cached
	end
	return cached or nil
end

return util
