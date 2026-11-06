-- The pure parts of the relative panels: role and threshold arithmetic, the fleet counts of the
-- Effective config section, schedule and event rows. Every function takes plain values and returns plain values or
-- LocalisedStrings, so the host unit tests cover them without the engine.

local format = require("__flib__.format")
local logic = require("scripts.gui.tab-logic")
local rich_text = require("scripts.gui.rich-text")

local band = bit32.band
local bor = bit32.bor

local text = {}

text.NO_VALUE = "–"
text.UNLIMITED = TRAIN_LIMIT_UNLIMITED
-- Ages and durations shown in the panel are rounded down to this many ticks, so a panel left open is rebuilt at most
-- once per step instead of every update.
text.AGE_STEP = 600

--- "Provider · Requester", "Provider", "Requester" (or none), with " · stack thresholds" in stack mode.
--- @param is_p boolean
--- @param is_r boolean
--- @param is_stack boolean
--- @return LocalisedString
function text.role(is_p, is_r, is_stack)
	local key
	if is_p and is_r then
		key = "cybersyn-gui.relative-role-both"
	elseif is_p then
		key = "cybersyn-gui.relative-role-provider"
	elseif is_r then
		key = "cybersyn-gui.relative-role-requester"
	else
		key = "cybersyn-gui.relative-role-none"
	end
	if is_stack then return { "", { key }, " · ", { "cybersyn-gui.relative-stack-mode" } } end
	return { key }
end

--- Whole stacks a threshold in items occupies: the slots a train needs to carry it.
--- @param threshold number items
--- @param stack_size number?
--- @return int
function text.stacks(threshold, stack_size)
	if not stack_size or stack_size <= 0 then return 0 end
	return math.ceil(threshold / stack_size)
end

--- The requester's threshold against the lowest provider override: a provider's own item threshold replaces the
--- requester's when it is not higher, as in tick_dispatch, which applies it per pairing with each provider's own.
--- @param threshold number
--- @param override number? the lowest provider override
--- @return number
--- @return boolean overridden
function text.effective_threshold(threshold, override)
	if override and override <= threshold then return override, true end
	return threshold, false
end

--- The train-side mask of a Cybersyn train on one network, nil when the train is not on it.
--- @param train {network_name: string?, network_mask: int|{[string]: int}?}
--- @param network string
--- @return int?
function text.train_mask(train, network)
	local name = train.network_name
	if name == NETWORK_EACH then
		local m = train.network_mask
		return type(m) == "table" and m[network] or nil
	elseif name == network then
		local m = train.network_mask
		return type(m) == "number" and m or 0
	end
	return nil
end

--- @class RelativeFleetCount per network of a stop: what its mask matches and what the fleet offers
--- @field mask int the stop's mask on the network
--- @field trains int Cybersyn trains on the network whose mask shares a bit with the stop's
--- @field depots int distinct depots among those trains
--- @field depot_set {[uint]: true}
--- @field capability {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}} per layout, every
---   train on the network (the shape of snapshot.fleet.capability[network])
--- @field matched {[uint]: {count: int, item_capacity: int, fluid_capacity: int}} per layout, only the trains whose
---   own mask shares a bit with the stop's: a layout's OR-ed mask cannot tell which of its trains match

--- @param mask int
--- @return RelativeFleetCount
function text.new_fleet_count(mask)
	return { mask = mask, trains = 0, depots = 0, depot_set = {}, capability = {}, matched = {} }
end

--- Adds one Cybersyn train to a stop's per-network counts.
--- @param counts {[string]: RelativeFleetCount}
--- @param train {network_name: string?, network_mask: any, depot_id: uint?, layout_id: uint?, item_slot_capacity: int?, fluid_capacity: int?}
function text.count_train(counts, train)
	for network, c in pairs(counts) do
		local m = text.train_mask(train, network)
		if m then
			local layout_id = train.layout_id or 0
			local cap = c.capability[layout_id]
			if not cap then
				cap = { count = 0, item_capacity = 0, fluid_capacity = 0, mask_or = 0 }
				c.capability[layout_id] = cap
			end
			cap.count = cap.count + 1
			local items, fluid = train.item_slot_capacity or 0, train.fluid_capacity or 0
			if items > cap.item_capacity then cap.item_capacity = items end
			if fluid > cap.fluid_capacity then cap.fluid_capacity = fluid end
			cap.mask_or = bor(cap.mask_or, m)
			if band(m, c.mask) ~= 0 then
				c.trains = c.trains + 1
				local hit = c.matched[layout_id]
				if not hit then
					hit = { count = 0, item_capacity = 0, fluid_capacity = 0 }
					c.matched[layout_id] = hit
				end
				hit.count = hit.count + 1
				if items > hit.item_capacity then hit.item_capacity = items end
				if fluid > hit.fluid_capacity then hit.fluid_capacity = fluid end
				local depot = train.depot_id
				if depot and not c.depot_set[depot] then
					c.depot_set[depot] = true
					c.depots = c.depots + 1
				end
			end
		end
	end
end

--- The trains a stop on one network can be sent: mask match (train by train) and a layout the stop accepts, with
--- the largest capacities among them. The one count the Effective config section shows wherever it says "trains match".
--- @param c RelativeFleetCount?
--- @param allows_all boolean
--- @param accepted {[uint]: true?}
--- @return int trains
--- @return int item_capacity
--- @return int fluid_capacity
function text.eligible(c, allows_all, accepted)
	local trains, items, fluid = 0, 0, 0
	if not c then return 0, 0, 0 end
	for layout_id, l in pairs(c.matched) do
		if allows_all or accepted[layout_id] then
			trains = trains + l.count
			if l.item_capacity > items then items = l.item_capacity end
			if l.fluid_capacity > fluid then fluid = l.fluid_capacity end
		end
	end
	return trains, items, fluid
end

--- The allow-list line: how many layouts the stop accepts, how many trains it can be sent (text.eligible), and the
--- accepted layouts no train on the network has at all.
--- @param accepted {[uint]: true?}
--- @param allows_all boolean
--- @param c RelativeFleetCount?
--- @return int|false layouts accepted, false = every layout
--- @return int trains eligible trains
--- @return uint[] missing accepted layout ids no train on the network has, ascending
function text.allow_list(accepted, allows_all, c)
	local trains = text.eligible(c, allows_all, accepted)
	if allows_all then return false, trains, {} end
	local capability = c and c.capability or {}
	local n, missing = 0, {}
	for layout_id in pairs(accepted) do
		n = n + 1
		if not capability[layout_id] then missing[#missing + 1] = layout_id end
	end
	table.sort(missing)
	return n, trains, missing
end

--- One line of the schedule list.
--- @param index int
--- @param record {station: string?, rail: any?, temporary: boolean?, created_by_interrupt: boolean?}
--- @param current int the active record's index
--- @return {caption: LocalisedString, active: boolean}
function text.schedule_row(index, record, current)
	local active = index == current
	local target
	if record.station then
		target = record.station
	elseif record.rail then
		target = { "cybersyn-gui.relative-schedule-rail" }
	else
		target = text.NO_VALUE
	end
	local caption = { "", active and "▶ " or "    ", tostring(index), ". ", target }
	if record.created_by_interrupt then
		caption[#caption + 1] = " "
		caption[#caption + 1] = { "cybersyn-gui.relative-schedule-interrupt" }
	elseif record.temporary then
		caption[#caption + 1] = " "
		caption[#caption + 1] = { "cybersyn-gui.relative-schedule-temporary" }
	end
	return { caption = caption, active = active }
end

--- An age rounded down to AGE_STEP ticks, for captions that must not change every update.
--- @param ticks number
--- @return number
function text.age_step(ticks)
	ticks = math.max(ticks or 0, 0)
	return ticks - ticks % text.AGE_STEP
end

--- The caption of one event row: "2m 10s  Unserved · Provider low". `detail` is what the kind needs after the dot
--- (the reason, the lint check, the planned and actual amounts), nil when the kind needs nothing.
--- @param ev {tick: uint, kind: int, code: int, a: int, b: int}
--- @param now uint
--- @return LocalisedString
function text.event_row(ev, now)
	local key = DIAG_KIND_KEYS[ev.kind]
	local kind = key and { "cybersyn-diag.kind-" .. key } or tostring(ev.kind)
	local caption = { "", logic.short_duration(text.age_step(now - ev.tick)), "  ", kind }
	local detail = text.event_detail(ev)
	if detail then
		caption[#caption + 1] = " · "
		caption[#caption + 1] = detail
	end
	return caption
end

--- @param ev {kind: int, code: int, a: int, b: int}
--- @return LocalisedString?
function text.event_detail(ev)
	local kind, code = ev.kind, ev.code
	if kind == DIAG_KIND_UNSERVED_REASON or kind == DIAG_KIND_FLAPPING then
		local key = REASON_KEYS[code]
		return key and { "cybersyn-diag.chip-" .. key } or nil
	elseif kind == DIAG_KIND_SHORT_LOAD or kind == DIAG_KIND_UNEXPECTED_CARGO or kind == DIAG_KIND_RESIDUAL_CARGO then
		return { "cybersyn-gui.relative-event-cargo", format.number(ev.a or 0), format.number(ev.b or 0) }
	elseif kind == DIAG_KIND_LINT then
		local check_key = LINT_KEYS[ev.a]
		local verb = code == DIAG_LINT_APPEARED and "cybersyn-diag.lint-appeared" or "cybersyn-diag.lint-cleared"
		if check_key then return { "", { "cybersyn-diag.lint-" .. check_key }, " (", { verb }, ")" } end
		return { verb }
	elseif kind == DIAG_KIND_STATION_LIMIT then
		return { "cybersyn-gui.relative-event-limit", tostring(ev.a or 0), tostring(ev.b or 0) }
	elseif kind == DIAG_KIND_DISPATCH_FAILED then
		local name = DIAG_DISPATCH_NAMES[code]
		return name and { "cybersyn-diag.dispatch-" .. string.gsub(name, "_", "-") } or nil
	end
	return nil
end

--- The combinator's "S" colour for a station's display_state (main.lua: 0 cyan, odd green, else red).
--- @param display_state int?
--- @return "cyan"|"green"|"red"
function text.s_colour(display_state)
	display_state = display_state or 0
	if display_state == 0 then return "cyan" end
	if display_state % 2 == 1 then return "green" end
	return "red"
end

--- "1 / 2" for deliveries against the train limit, "1 / ∞" without a limit.
--- @param deliveries int
--- @param limit int
--- @return string
function text.trains_pair(deliveries, limit)
	local l = (limit or 0) >= text.UNLIMITED and "∞" or tostring(limit or 0)
	return tostring(deliveries or 0) .. " / " .. l
end

--- The mask as a number, with its bits for a small positive mask: "5 (101)"; "-1" alone (every bit).
--- @param mask int
--- @return string
function text.mask_text(mask)
	mask = mask or 0
	if mask < 0 or mask >= 65536 then return tostring(mask) end
	local m = mask
	local bits = {}
	while m > 0 and #bits < 32 do
		bits[#bits + 1] = tostring(m % 2)
		m = math.floor(m / 2)
	end
	if #bits == 0 then bits[1] = "0" end
	local out = {}
	for i = #bits, 1, -1 do out[#out + 1] = bits[i] end
	return tostring(mask) .. " (" .. table.concat(out) .. ")"
end

-- ---------------------------------------------------------------- inventory rows

-- Required here rather than at the top: the collector loads the engine-facing modules, and the functions above stay
-- usable without it.
local collector = require("scripts.gui.collector")

local EMPTY = {}

-- Networks a NETWORK_EACH row lists before "+n".
local EACH_SHOWN = 4

--- A NETWORK_EACH row's networks sorted by name, as {name, mask} pairs.
--- @param nets {[string]: int}
--- @return {name: string, mask: int}[]
local function sorted_nets(nets)
	local out = {}
	for name, mask in pairs(nets) do out[#out + 1] = { name = name, mask = mask } end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--- "[A]2": the network and mask a row advertises on; a NETWORK_EACH row lists its networks ("[A]1 [B]2", then "+n");
--- "" for a row on no network (unread, or the station has none).
--- @param row SnapshotInventory
--- @return string
function text.row_network(row)
	local nets = row.networks
	if nets then
		local list = sorted_nets(nets)
		local parts = {}
		for i = 1, math.min(#list, EACH_SHOWN) do
			parts[i] = rich_text.network_icon_with(list[i].name, collector.mask_label(list[i].mask))
		end
		if #list > EACH_SHOWN then parts[#parts + 1] = "+" .. (#list - EACH_SHOWN) end
		return table.concat(parts, " ")
	end
	local name, mask = row.network_name, row.mask
	if not name or name == NETWORK_EACH or mask == nil then return "" end
	return rich_text.network_icon_with(name, collector.mask_label(mask))
end

--- "Inventory 2 · priority 5": the stop panel's block head, and the start of every text that names a row.
--- @param row SnapshotInventory
--- @return LocalisedString
function text.row_head(row)
	return { "", row.label or collector.source_label(row), " · ", { "cybersyn-gui.section-priority", tostring(row.priority) } }
end

--- "Inventory 2 · priority 5 · [A]2": a row as one line, for tooltips and the unserved texts.
--- @param row SnapshotInventory
--- @return LocalisedString
function text.row_text(row)
	local net = text.row_network(row)
	if net == "" then return text.row_head(row) end
	return { "", text.row_head(row), " · ", net }
end

--- What row_text shows, as a plain string: views sign rows with it before building the text.
--- @param row SnapshotInventory
--- @return string
function text.row_sig(row)
	local nets = row.networks
	local net
	if nets then
		local parts = {}
		for i, n in ipairs(sorted_nets(nets)) do parts[i] = n.name .. "=" .. n.mask end
		net = table.concat(parts, ",")
	else
		net = tostring(row.network_name) .. "=" .. tostring(row.mask)
	end
	return row.kind .. row.index .. "/" .. tostring(row.priority) .. "/" .. net
end

--- Whether the station has inventory combinators: its views lay it out per inventory then.
--- @param st SnapshotStation
--- @return boolean
function text.has_inventories(st)
	return #collector.inventories(st) > 1
end

--- The distinct networks the station's rows advertise on, sorted by name then mask: the stop panel's "Networks" line.
--- @param st SnapshotStation
--- @return {name: string, mask: int}[]
function text.row_networks(st)
	local out, seen = {}, {}
	local function add(name, mask)
		local key = name .. "=" .. mask
		if not seen[key] then
			seen[key] = true
			out[#out + 1] = { name = name, mask = mask }
		end
	end
	for _, row in ipairs(collector.inventories(st)) do
		if row.networks then
			for name, mask in pairs(row.networks) do add(name, mask) end
		elseif row.network_name and row.network_name ~= NETWORK_EACH and row.mask ~= nil then
			add(row.network_name, row.mask)
		end
	end
	table.sort(out, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.mask < b.mask
	end)
	return out
end

--- Network name -> bitwise OR of every mask the station's rows advertise on it: the trains that can serve any of them.
--- @param st SnapshotStation
--- @return {[string]: int}
function text.rows_union(st)
	local union = {}
	for _, n in ipairs(text.row_networks(st)) do union[n.name] = bor(union[n.name] or 0, n.mask) end
	return union
end

--- Whether the planner skips this inventory row this pass because its station combinator holds it back.
--- @param row SnapshotInventory
--- @return boolean
function text.is_paused(row)
	if row.kind ~= "inventory" then return false end
	local src = row.src or row
	return src.read == false
end

--- Why an inventory row advertises on no network: its station combinator holds it back (paused), the combinator
--- itself is off, or it is read but its input carries no signals. Paused is the only case the paused texts describe.
--- @param row SnapshotInventory
--- @return "paused"|"off"|"empty"
function text.silent_reason(row)
	if text.is_paused(row) then return "paused" end
	local src = row.src or row
	if not src.ok then return "off" end
	return "empty"
end

--- Inventory rows the planner skips this pass (the station combinator is off, or has no input signals).
--- @param st SnapshotStation
--- @return SnapshotInventory[]
function text.paused_inventories(st)
	local out = {}
	for _, row in ipairs(collector.inventories(st)) do
		if text.is_paused(row) then out[#out + 1] = row end
	end
	return out
end

--- The rows the stop panel gives a block: the station combinator, then every inventory the planner reads.
--- @param st SnapshotStation
--- @return SnapshotInventory[]
function text.advertised_rows(st)
	local out = {}
	for _, row in ipairs(collector.inventories(st)) do
		if not text.is_paused(row) then out[#out + 1] = row end
	end
	return out
end

--- The paused line's locale key: why the station combinator holds its inventories back.
--- @param st SnapshotStation
--- @return string
function text.paused_key(st)
	return st.comb_ok and "cybersyn-gui.section-paused-no-signals" or "cybersyn-gui.section-paused"
end

--- Why a station's rows leave signals unadvertised: its Provide only / Request only switch.
--- @param st SnapshotStation
--- @return LocalisedString
function text.ignored_reason(st)
	if st.is_p and not st.is_r then return { "cybersyn-gui.section-provide-only" } end
	if st.is_r and not st.is_p then return { "cybersyn-gui.section-request-only" } end
	return { "cybersyn-gui.section-switch" }
end

--- A signature of everything the stop panel's inventory blocks show. Sorted, so two records with the same values sign
--- alike whatever order their tables were filled in.
--- @param st SnapshotStation
--- @return string
function text.rows_content(st)
	local parts = {}
	for i, row in ipairs(collector.inventories(st)) do
		local src = row.src or row
		local k = i .. row.kind .. row.index .. "#" .. tostring(row.unit)
		parts[#parts + 1] = k .. "=" .. text.row_sig(row) .. (src.ok and "o" or "") .. (src.read == false and "u" or "")
			.. (src.read == nil and "n" or "")
		for hash, count in pairs(row.provided) do parts[#parts + 1] = k .. "p" .. hash .. "=" .. count end
		for hash, req in pairs(row.requested) do
			parts[#parts + 1] = k .. "r" .. hash .. "=" .. req.count .. "/" .. req.threshold .. (req.active and "a" or "")
		end
		for hash, count in pairs(row.ignored or EMPTY) do parts[#parts + 1] = k .. "i" .. hash .. "=" .. count end
		for hash in pairs(row.starved or EMPTY) do parts[#parts + 1] = k .. "s" .. hash end
	end
	table.sort(parts)
	return (st.is_p and "p" or "") .. (st.is_r and "r" or "") .. (st.comb_ok and "o" or "")
		.. (st.network_name and "n" or "") .. "|" .. table.concat(parts, ",")
end

return text
