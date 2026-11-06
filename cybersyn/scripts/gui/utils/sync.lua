-- Keyed reconciliation of GUI children against an ordered entry list. It reads nothing but the elements and state it
-- is handed, so the host unit tests drive it with fake elements.

local gui = require("__flib__.gui")

local sync = {}

--- Writes caption (and tooltip, when given) only when `sig` changed since the last write. LocalisedString captions
--- cannot be compared with the element's, so the last plain-string signature is kept in `cache`, keyed by the
--- element's name: two elements of one name must not share a cache, or one of them stops updating.
--- @param cache table
--- @param elem LuaGuiElement?
--- @param sig string
--- @param caption LocalisedString
--- @param tooltip LocalisedString?
function sync.set_if_changed(cache, elem, sig, caption, tooltip)
	if not (elem and elem.valid) then return end
	local key = elem.name
	if cache[key] == sig then return end
	cache[key] = sig
	elem.caption = caption
	if tooltip ~= nil then elem.tooltip = tooltip end
end

--- Per-player render state for a container, created on demand.
--- @param player_data PlayerData
--- @param name string
--- @return {keys: (string|number)[]?, dirty: true?}
function sync.gui_state(player_data, name)
	return get_or_create(get_or_create(player_data, "gui_state"), name)
end

--- @class SyncOptions
--- @field build fun(entry: table): flib.GuiElemDef? for entries without their own `build`
--- @field update fun(elem: LuaGuiElement, entry: table, index: integer)? for entries without their own `update`
--- @field reuse fun(elem: LuaGuiElement, old_key: any, entry: table)? for entries without their own `reuse`
--- @field add fun(parent: LuaGuiElement, index: integer?, entry: table): LuaGuiElement? creates the child itself instead
--- of `build` (index nil = append)
--- @field after fun(elem: LuaGuiElement, entry: table, index: integer, fresh: boolean)? runs for every placed child,
--- `fresh` when it was built or reused in this call
--- @field gone fun(key: any)? runs for every key whose child is destroyed
--- @field elems boolean? the children live in `state.elems` instead of being read from `parent.children` (which makes a
--- wrapper per child on every call)
--- @field budget {n: integer}? updates this call may run; a skipped one keeps its old sig and sets `deferred`
--- @field build_budget integer? children this call may build; the entries after the first one over it wait for the
--- next call
--- @field destroy_vanished boolean? destroy children whose key vanished first instead of offering them for reuse
--- @field rebuild_mostly_new boolean? clear and rebuild when more keys are new than survive: each insert renumbers
--- every later child, so splicing a mostly new set into a few survivors costs more than recreating it
--- @field moved_keeps_sig boolean? a moved child's update does not depend on its index, so moving it writes nothing
--- @field deferred true? set by the call when `budget` ran out

local function run_update(entry, elem, index, sigs, opts)
	local update = entry.update or (opts and opts.update)
	if not update then return end
	local sig = entry.sig
	if sig ~= nil then
		if sigs[entry.key] == sig then return end
		local budget = opts and opts.budget
		if budget then
			if budget.n <= 0 then
				opts.deferred = true
				return
			end
			budget.n = budget.n - 1
		end
		sigs[entry.key] = sig
	end
	update(elem, entry, index)
end

--- A re-sort mostly permutes the same rows, and rebuilding a heavy row costs far more than moving it: survivors are
--- swapped into place, a child whose key vanished is handed to a new key through `reuse(elem, old_key, entry)` when
--- there is one (then updated like a survivor), and only the remaining new keys are built, at their index.
local function sync_moved(parent, entries, keys, old, elems, state, sigs, opts)
	local n = #entries
	local build_fn = opts and opts.build
	local reuse_fn = opts and opts.reuse
	local add = opts and opts.add
	local after = opts and opts.after
	local gone = opts and opts.gone
	local build_left = opts and opts.build_budget
	local keep_sig = opts and opts.moved_keeps_sig
	local wanted = {}
	for i = 1, n do
		wanted[keys[i]] = true
	end
	local cur, pos_of, old_index = {}, {}, {}
	local free = {}
	if opts and opts.destroy_vanished then
		local m = 0
		for j = 1, #old do
			local key, elem = old[j], elems[j]
			if wanted[key] then
				m = m + 1
				cur[m] = key
				elems[m] = elem
			else
				elem.destroy()
				sigs[key] = nil
				if gone then gone(key) end
			end
		end
		for j = #elems, m + 1, -1 do
			elems[j] = nil
		end
		if opts.rebuild_mostly_new and n - m > m then
			parent.clear()
			if gone then
				for j = 1, m do gone(cur[j]) end
			end
			cur = {}
			for j = m, 1, -1 do
				elems[j] = nil
			end
			sigs = {}
		end
	else
		for j = 1, #old do
			cur[j] = old[j]
		end
	end
	for j = 1, #cur do
		local key = cur[j]
		pos_of[key] = j
		old_index[key] = j
		if not wanted[key] then free[#free + 1] = key end
	end
	-- Positions before i are final, so every unclaimed child sits at i or later.
	local function swap(i, j)
		parent.swap_children(i, j)
		cur[i], cur[j] = cur[j], cur[i]
		elems[i], elems[j] = elems[j], elems[i]
		pos_of[cur[i]] = i
		pos_of[cur[j]] = j
	end
	local i = 1
	while i <= n do
		local key = keys[i]
		local entry = entries[i]
		local fresh = false
		local reuse = entry.reuse or reuse_fn
		if cur[i] == key then
			-- A child that moved must learn its new index even when its data did not change.
			if not keep_sig and old_index[key] ~= i then sigs[key] = nil end
			run_update(entry, elems[i], i, sigs, opts)
		elseif pos_of[key] then
			swap(i, pos_of[key])
			if not keep_sig then sigs[key] = nil end
			run_update(entry, elems[i], i, sigs, opts)
		elseif reuse and #free > 0 then
			-- The lowest free child, so the children above the change are not moved.
			local old_key = table.remove(free)
			local j = pos_of[old_key]
			if j ~= i then swap(i, j) end
			pos_of[old_key] = nil
			sigs[old_key] = nil
			cur[i] = key
			pos_of[key] = i
			reuse(elems[i], old_key, entry)
			sigs[key] = nil
			run_update(entry, elems[i], i, sigs, opts)
			fresh = true
		else
			if build_left then
				if build_left <= 0 then break end
				build_left = build_left - 1
			end
			local elem
			if add then
				elem = add(parent, i <= #cur and i or nil, entry)
			else
				local def = (entry.build or build_fn)(entry)
				def.index = i <= #cur and i or nil
				local _, added = gui.add(parent, def)
				elem = added
				if entry.built then entry.built(elem, entry) end
			end
			table.insert(cur, i, key)
			table.insert(elems, i, elem)
			for m = i, #cur do
				pos_of[cur[m]] = m
			end
			sigs[key] = entry.sig
			fresh = true
		end
		if after then after(elems[i], entry, i, fresh) end
		i = i + 1
	end
	for j = #cur, i, -1 do
		elems[j].destroy()
		sigs[cur[j]] = nil
		if gone then gone(cur[j]) end
		cur[j] = nil
		elems[j] = nil
	end
	state.sigs = sigs
	state.keys = cur
	if opts and opts.elems then state.elems = elems end
	state.dirty = nil
	return "rebuilt"
end

--- Invariants: keys are unique within one call; with `movable`, `update` applies everything that depends on the
--- child's index unless `moved_keeps_sig` is set; a budget defers work only by keeping the old sig and setting
--- `deferred`, so the next call picks it up. Tests: the "sync_children" ones in
--- tests/unit/sync_test.lua.
--- Reconciles `parent`'s children with `entries`, an ordered array of
--- `{key=, build=fun(entry): GuiElemDef, update=fun(elem, entry, index)?, sig=string|number?}` (build, built and reuse
--- also get the entry, so one function can serve every row).
--- Same key sequence: `update` each child in place. Otherwise, when `hold` is set, structure is left alone
--- (children whose key is still present get `update`d) and `state.dirty` is set; when not held, the common
--- prefix is updated in place, the rest destroyed and rebuilt.
--- `sig`, when given, is a cheap signature of everything `update` writes: an unchanged sig skips the update.
--- `built(elem)`, when given, receives each child right after `build` created it.
--- @param parent LuaGuiElement
--- @param entries {key: string|number, build: fun(): flib.GuiElemDef, update: fun(elem: LuaGuiElement, entry: table, index: integer)?, sig: (string|number)?}[]
--- @param state {keys: (string|number)[]?, sigs: {[string|number]: string|number}?, dirty: true?, elems: LuaGuiElement[]?} from sync.gui_state
--- @param hold boolean?
--- @param movable (boolean|SyncOptions)? keep children whose key survives and move them into place instead of
--- rebuilding from the first difference; `update` then also runs for a moved or reused child and must apply anything
--- that depends on its index (see sync_moved). A table is movable with options.
--- @return "updated"|"held"|"rebuilt"
function sync.sync_children(parent, entries, state, hold, movable)
	local opts = type(movable) == "table" and movable or nil
	local n = #entries
	local keys = {}
	for i = 1, n do
		keys[i] = entries[i].key
	end
	local old = state.keys
	local children
	if opts and opts.elems then
		children = state.elems
		if not (old and children and #old == #children and (not children[1] or children[1].valid)) then
			old = nil
		end
	else
		children = parent.children
		if old and #old ~= #children then
			old = nil
		end
	end
	local sigs = state.sigs
	if not old or not sigs then
		sigs = {}
		state.sigs = sigs
	end

	local prefix = 0
	if old then
		local m = math.min(#old, n)
		while prefix < m and old[prefix + 1] == keys[prefix + 1] do
			prefix = prefix + 1
		end
		if prefix == n and #old == n then
			local after = opts and opts.after
			for i = 1, n do
				run_update(entries[i], children[i], i, sigs, opts)
				if after then after(children[i], entries[i], i, false) end
			end
			state.dirty = nil
			return "updated"
		end
		if hold then
			local index_of = {}
			for i = 1, n do
				index_of[keys[i]] = i
			end
			for j = 1, #old do
				local i = index_of[old[j]]
				if i then
					run_update(entries[i], children[j], i, sigs, opts)
				end
			end
			state.dirty = true
			return "held"
		end
	end

	if opts then
		if not old then
			parent.clear()
			return sync_moved(parent, entries, keys, {}, {}, state, sigs, opts)
		end
		return sync_moved(parent, entries, keys, old, children, state, sigs, opts)
	end
	if movable and old then
		return sync_moved(parent, entries, keys, old, children, state, sigs)
	end

	for i = 1, prefix do
		run_update(entries[i], children[i], i, sigs)
	end
	if prefix == 0 then
		parent.clear()
	else
		for j = #children, prefix + 1, -1 do
			children[j].destroy()
		end
	end
	local new_sigs = {}
	for i = 1, prefix do
		local key = keys[i]
		new_sigs[key] = sigs[key]
	end
	for i = prefix + 1, n do
		local entry = entries[i]
		local _, elem = gui.add(parent, entry.build(entry))
		if entry.built then entry.built(elem, entry) end
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	state.sigs = new_sigs
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

--- sync.sync_children for a `table` element whose rows are `columns` cells wide. The first `first` children (a
--- header row, say) are left alone. Each entry's `build` returns one GuiElemDef per cell and `update` receives the
--- row's cells as an array; keys, sigs and `hold` work as in sync.sync_children.
--- @param tbl LuaGuiElement
--- @param columns integer
--- @param first integer
--- @param entries {key: string|number, build: fun(): flib.GuiElemDef[], update: fun(cells: LuaGuiElement[], entry: table, index: integer)?, sig: (string|number)?}[]
--- @param state {keys: (string|number)[]?, sigs: {[string|number]: string|number}?, dirty: true?} from sync.gui_state
--- @param hold boolean?
--- @return "updated"|"held"|"rebuilt"
function sync.sync_table_rows(tbl, columns, first, entries, state, hold)
	local n = #entries
	local old = state.keys
	local sigs = state.sigs
	if not old or not sigs then
		old = nil
		sigs = {}
		state.sigs = sigs
	end
	-- Unchanged keys and sigs (the common render) read no element: `tbl.children` wraps every cell of the table.
	local same = old ~= nil and #old == n
	if same then
		for i = 1, n do
			if old[i] ~= entries[i].key then
				same = false
				break
			end
		end
	end
	local children
	if same then
		for i = 1, n do
			local entry = entries[i]
			local fn = entry.update
			local sig = entry.sig
			if fn and (sig == nil or sigs[entry.key] ~= sig) then
				if not children then
					children = tbl.children
					-- Someone else changed the table: rebuild instead of writing into the wrong cells.
					if first + n * columns ~= #children then
						same = false
						break
					end
				end
				if sig ~= nil then sigs[entry.key] = sig end
				local cells = {}
				local base = first + (i - 1) * columns
				for c = 1, columns do cells[c] = children[base + c] end
				fn(cells, entry, i)
			end
		end
		if same then
			state.dirty = nil
			return "updated"
		end
	end
	children = children or tbl.children
	if old and first + #old * columns ~= #children then old = nil end
	local keys = {}
	for i = 1, n do keys[i] = entries[i].key end

	local function update(entry, row, index)
		local fn = entry.update
		if not fn then return end
		local sig = entry.sig
		if sig ~= nil then
			if sigs[entry.key] == sig then return end
			sigs[entry.key] = sig
		end
		local cells = {}
		local base = first + (row - 1) * columns
		for c = 1, columns do
			cells[c] = children[base + c]
		end
		fn(cells, entry, index)
	end

	local prefix = 0
	if old then
		local m = math.min(#old, n)
		while prefix < m and old[prefix + 1] == keys[prefix + 1] do
			prefix = prefix + 1
		end
		if hold then
			local index_of = {}
			for i = 1, n do
				index_of[keys[i]] = i
			end
			for j = 1, #old do
				local i = index_of[old[j]]
				if i then
					update(entries[i], j, i)
				end
			end
			state.dirty = true
			return "held"
		end
	end

	for i = 1, prefix do
		update(entries[i], i, i)
	end
	-- Rows past the common prefix are rebound in place when their entries can (`rebind` rewrites every cell, tags
	-- included): removing one row then rewrites the rows below it instead of destroying and building them again.
	local reuse = prefix
	local old_n = old and #old or 0
	while reuse < math.min(old_n, n) and entries[reuse + 1].rebind do reuse = reuse + 1 end
	for i = prefix + 1, reuse do
		local entry = entries[i]
		local cells = {}
		local base = first + (i - 1) * columns
		for c = 1, columns do cells[c] = children[base + c] end
		entry.rebind(cells, entry, i)
	end
	for j = #children, first + reuse * columns + 1, -1 do
		children[j].destroy()
	end
	local new_sigs = {}
	for i = 1, prefix do
		local key = keys[i]
		new_sigs[key] = sigs[key]
	end
	for i = prefix + 1, reuse do
		local entry = entries[i]
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	for i = reuse + 1, n do
		local entry = entries[i]
		for _, def in ipairs(entry.build()) do
			gui.add(tbl, def)
		end
		if entry.sig ~= nil then new_sigs[entry.key] = entry.sig end
	end
	state.sigs = new_sigs
	state.keys = keys
	state.dirty = nil
	return "rebuilt"
end

return sync
