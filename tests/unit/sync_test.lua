-- The keyed reconciler in scripts/gui/utils/sync.lua: sync_children, sync_table_rows, set_if_changed, gui_state.

local H = require("harness")

local function sync()
	return H.load("scripts.gui.utils.sync")
end

test("set_if_changed: writes caption and tooltip only when the sig changes", function()
	local u = sync()
	local cache, elem = {}, H.element({ name = "label" })
	u.set_if_changed(cache, elem, "a", { "x" }, { "tip" })
	assert_eq({ elem.caption, elem.tooltip, cache.label }, { { "x" }, { "tip" }, "a" })
	elem.caption, elem.tooltip = "changed", "changed"
	u.set_if_changed(cache, elem, "a", { "y" }, { "tip2" })
	assert_eq({ elem.caption, elem.tooltip }, { "changed", "changed" })
	u.set_if_changed(cache, elem, "b", { "y" })
	assert_eq({ elem.caption, elem.tooltip }, { { "y" }, "changed" })
end)

test("gui_state: created on demand and stable", function()
	local u = sync()
	local pd = {}
	local s = u.gui_state(pd, "stations")
	assert_eq(s, {})
	assert_same(u.gui_state(pd, "stations"), s)
	assert_same(pd.gui_state.stations, s)
	assert_true(u.gui_state(pd, "trains") ~= s)
end)

-- ------------------------------------------------------------------ sync_children

local function entry(key, log, sig)
	return {
		key = key,
		sig = sig,
		build = function() return { type = "label", name = key, caption = key } end,
		update = function(elem, _, index)
			log[#log + 1] = key .. "@" .. index
			elem.updated_index = index
		end,
	}
end

local function child_names(parent)
	local out = {}
	for i, c in ipairs(parent.children) do out[i] = c.name end
	return out
end

local function entries_for(keys, log, sigs)
	local out = {}
	for i, k in ipairs(keys) do out[i] = entry(k, log, sigs and sigs[i]) end
	return out
end

test("sync_children: build, update in place, sig skip", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "b" }, log, { 1, 1 }), state), "rebuilt")
	assert_eq(child_names(parent), { "a", "b" })
	assert_eq(log, {})
	assert_eq(state.keys, { "a", "b" })
	assert_eq(state.sigs, { a = 1, b = 1 })
	assert_eq(u.sync_children(parent, entries_for({ "a", "b" }, log, { 1, 2 }), state), "updated")
	assert_eq(log, { "b@2" })
	assert_eq(state.sigs, { a = 1, b = 2 })
	assert_nil(state.dirty)
end)

test("sync_children: hold keeps structure and marks dirty", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	assert_eq(u.sync_children(parent, entries_for({ "c", "a" }, log), state, true), "held")
	assert_eq(child_names(parent), { "a", "b", "c" })
	-- Survivors get the update with their new index.
	assert_eq(log, { "a@2", "c@1" })
	assert_true(state.dirty)
	assert_eq(state.keys, { "a", "b", "c" })
end)

test("sync_children: unheld change keeps the common prefix and rebuilds the rest", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "c", "d" }, log), state), "rebuilt")
	assert_eq(child_names(parent), { "a", "c", "d" })
	assert_eq(log, { "a@1" })
	assert_eq(H.count_ops("destroy"), 2)
	assert_eq(H.count_ops("add"), 2)
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "x" }, log), state), "rebuilt")
	assert_eq(H.count_ops("clear"), 1)
	assert_eq(child_names(parent), { "x" })
end)

test("sync_children: movable swaps survivors instead of rebuilding", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "c", "a", "b" }, log), state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "c", "a", "b" })
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 0)
	assert_eq(log, { "c@1", "a@2", "b@3" })
	H.gui_log = {}
	log = {}
	assert_eq(u.sync_children(parent, entries_for({ "c", "d" }, log), state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "c", "d" })
	assert_eq(H.count_ops("add"), 1)
	assert_eq(H.count_ops("destroy"), 2)
	assert_eq(log, { "c@1" })
end)

test("sync_table_rows: header cells untouched, rows rebuilt from the first difference", function()
	local u = sync()
	local tbl = H.element({ name = "tbl" })
	tbl.add({ name = "h1" })
	tbl.add({ name = "h2" })
	local function row(key, log)
		return {
			key = key,
			build = function() return { { type = "label", name = key .. "1" }, { type = "label", name = key .. "2" } } end,
			update = function(cells, _, index) log[#log + 1] = key .. "@" .. index .. ":" .. cells[1].name end,
		}
	end
	local state, log = {}, {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, { row("a", log), row("b", log) }, state), "rebuilt")
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2" })
	assert_eq(u.sync_table_rows(tbl, 2, 2, { row("a", log), row("b", log) }, state), "updated")
	assert_eq(log, { "a@1:a1", "b@2:b1" })
	log = {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, { row("a", log), row("c", log) }, state), "rebuilt")
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "c1", "c2" })
	assert_eq(log, { "a@1:a1" })
end)

-- ------------------------------------------------------------------ sync_children: moves, reuse, guards

test("sync_children: movable insertion updates shifted survivors although their sigs did not change", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { "s", "s", "s" }), state)
	H.gui_log = {}
	local result = u.sync_children(parent, entries_for({ "n", "a", "b", "c" }, log, { "s", "s", "s", "s" }), state, false, true)
	assert_eq(result, "rebuilt")
	assert_eq(child_names(parent), { "n", "a", "b", "c" })
	assert_eq(H.count_ops("add"), 1)
	assert_eq(H.count_ops("destroy"), 0)
	assert_eq(log, { "a@2", "b@3", "c@4" })
	assert_eq(parent.children[4].updated_index, 4)
	assert_eq(state.sigs, { n = "s", a = "s", b = "s", c = "s" })
	-- Same order again: every sig matches, nothing runs.
	log[#log + 1] = "|"
	assert_eq(u.sync_children(parent, entries_for({ "n", "a", "b", "c" }, log, { "s", "s", "s", "s" }), state, false, true), "updated")
	assert_eq(log, { "a@2", "b@3", "c@4", "|" })
end)

test("sync_children: movable hands a vanished key's child to a new key through reuse", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	local b_elem = parent.children[2]
	local entries = entries_for({ "a", "x", "c" }, log)
	entries[2].reuse = function(elem, old_key)
		log[#log + 1] = "reuse " .. old_key .. "->x"
		elem.name = "x"
	end
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries, state, false, true), "rebuilt")
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 0)
	assert_same(parent.children[2], b_elem)
	assert_eq(child_names(parent), { "a", "x", "c" })
	assert_eq(log, { "a@1", "reuse b->x", "x@2", "c@3" })
	assert_eq(state.keys, { "a", "x", "c" })
	-- A freed child elsewhere in the list is swapped into place before it is reused.
	entries = entries_for({ "z", "a", "c" }, log)
	entries[1].reuse = function(elem, old_key)
		log[#log + 1] = "reuse " .. old_key .. "->z"
		elem.name = "z"
	end
	H.gui_log = {}
	for i = #log, 1, -1 do log[i] = nil end
	assert_eq(u.sync_children(parent, entries, state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "z", "a", "c" })
	assert_same(parent.children[1], b_elem)
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 0)
	assert_eq(log, { "reuse x->z", "z@1", "a@2", "c@3" })
	-- An entry without reuse still gets a fresh child, and the vanished one is destroyed.
	H.gui_log = {}
	log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "y", "c" }, log), state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "a", "y", "c" })
	assert_eq(H.count_ops("add"), 1)
	assert_eq(H.count_ops("destroy"), 1)
	assert_false(b_elem.valid)
end)

test("sync_children: children changed behind its back force a full rebuild", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state)
	parent.children[2].destroy()
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state), "rebuilt")
	assert_eq(H.count_ops("clear"), 1)
	assert_eq(H.count_ops("add"), 3)
	assert_eq(child_names(parent), { "a", "b", "c" })
	assert_eq(log, {})
	assert_eq(state.sigs, { a = 1, b = 1, c = 1 })
	parent.children[3].destroy()
	assert_eq(u.sync_children(parent, entries_for({ "c", "a", "b" }, log), state, true), "rebuilt")
	assert_eq(child_names(parent), { "c", "a", "b" })
end)

test("sync_children options: a write budget defers updates and keeps their old sigs", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state)
	local opts = { budget = { n = 2 } }
	assert_eq(u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 2, 2, 2 }), state, false, opts), "updated")
	assert_eq(log, { "a@1", "b@2" })
	assert_true(opts.deferred)
	assert_eq(state.sigs, { a = 2, b = 2, c = 1 })
	opts = { budget = { n = 2 } }
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 2, 2, 2 }), state, false, opts)
	assert_eq(log, { "a@1", "b@2", "c@3" })
	assert_nil(opts.deferred)
end)

test("sync_children options: after sees every placed child, fresh when built or reused; gone sees destroyed keys", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, seen, gone = {}, {}, {}
	local opts = {
		elems = true,
		build = function(e) return { type = "label", name = e.key } end,
		reuse = function(elem, _, e) elem.name = e.key end,
		after = function(elem, e, i, fresh) seen[#seen + 1] = e.key .. "@" .. i .. (fresh and "+" or "") .. elem.name end,
		gone = function(key) gone[#gone + 1] = key end,
	}
	local function plain(keys)
		local out = {}
		for i, k in ipairs(keys) do out[i] = { key = k } end
		return out
	end
	u.sync_children(parent, plain({ "a", "b" }), state, false, opts)
	assert_eq(seen, { "a@1+a", "b@2+b" })
	assert_eq(#state.elems, 2)
	seen = {}
	assert_eq(u.sync_children(parent, plain({ "a", "b" }), state, false, opts), "updated")
	assert_eq(seen, { "a@1a", "b@2b" })
	seen = {}
	H.gui_log = {}
	u.sync_children(parent, plain({ "x", "a" }), state, false, opts)
	assert_eq(child_names(parent), { "x", "a" })
	assert_eq(H.count_ops("add"), 0)
	assert_eq(seen, { "x@1+x", "a@2a" })
	u.sync_children(parent, plain({ "a" }), state, false, opts)
	assert_eq(gone, { "x" })
	assert_eq(state.keys, { "a" })
	assert_same(state.elems[1], parent.children[1])
end)

test("sync_children options: a build budget stops at the first build over it and drops the rest", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c", "d" }, log), state, false, { build_budget = 2 })
	assert_eq(child_names(parent), { "a", "b" })
	assert_eq(state.keys, { "a", "b" })
	u.sync_children(parent, entries_for({ "a", "b", "c", "d" }, log), state, false, { build_budget = 2 })
	assert_eq(child_names(parent), { "a", "b", "c", "d" })
	-- A new key at the top over the budget: everything below it waits, survivors included.
	u.sync_children(parent, entries_for({ "n", "a", "b", "c", "d" }, log), state, false, { build_budget = 0 })
	assert_eq(child_names(parent), {})
	assert_eq(state.keys, {})
end)

test("sync_children options: destroy_vanished never reuses, rebuild_mostly_new recreates a mostly new set", function()
	local u = sync()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	local opts = { destroy_vanished = true, rebuild_mostly_new = true, moved_keeps_sig = true }
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state)
	local entries = entries_for({ "c", "x", "a" }, log, { 1, 1, 1 })
	entries[2].reuse = function() error("reused") end
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries, state, false, opts), "rebuilt")
	assert_eq(child_names(parent), { "c", "x", "a" })
	assert_eq(H.count_ops("destroy"), 1)
	assert_eq(H.count_ops("add"), 1)
	assert_eq(log, {}, "moved children keep their sigs")
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "p", "q" }, log, { 1, 1, 1 }), state, false, opts), "rebuilt")
	assert_eq(child_names(parent), { "a", "p", "q" })
	assert_eq(H.count_ops("clear"), 1)
	assert_eq(H.count_ops("add"), 3)
	assert_eq(state.sigs, { a = 1, p = 1, q = 1 })
end)

local function table_row(key, log)
	return {
		key = key,
		build = function() return { { type = "label", name = key .. "1" }, { type = "label", name = key .. "2" } } end,
		update = function(cells, _, index) log[#log + 1] = key .. "@" .. index .. ":" .. cells[1].name .. "," .. cells[2].name end,
	}
end

local function table_rows(keys, log)
	local out = {}
	for i, k in ipairs(keys) do out[i] = table_row(k, log) end
	return out
end

local function header_table()
	local tbl = H.element({ name = "tbl" })
	tbl.add({ name = "h1" })
	tbl.add({ name = "h2" })
	return tbl
end

test("sync_table_rows: hold keeps the rows, updates survivors from their old cells and marks dirty", function()
	local u = sync()
	local tbl = header_table()
	local state, log = {}, {}
	u.sync_table_rows(tbl, 2, 2, table_rows({ "a", "b", "c" }, log), state)
	H.gui_log = {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, table_rows({ "c", "a" }, log), state, true), "held")
	assert_true(state.dirty)
	assert_eq(state.keys, { "a", "b", "c" })
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2", "c1", "c2" })
	assert_eq(#H.gui_log, 0)
	assert_eq(log, { "a@2:a1,a2", "c@1:c1,c2" })
	log = {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, table_rows({ "c", "a" }, log), state), "rebuilt")
	assert_nil(state.dirty)
	assert_eq(child_names(tbl), { "h1", "h2", "c1", "c2", "a1", "a2" })
end)

test("sync_table_rows: cells changed behind its back force a rebuild below the header", function()
	local u = sync()
	local tbl = header_table()
	local state, log = {}, {}
	u.sync_table_rows(tbl, 2, 2, table_rows({ "a", "b" }, log), state)
	tbl.children[4].destroy()
	assert_eq(u.sync_table_rows(tbl, 2, 2, table_rows({ "a", "b" }, log), state), "rebuilt")
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2" })
	assert_eq(log, {})
end)

test("sync_table_rows: rows that can rebind are rewritten in place past the first difference, not rebuilt", function()
	local u = sync()
	local tbl = header_table()
	local state, log = {}, {}
	local function rows(keys)
		local out = table_rows(keys, log)
		for _, e in ipairs(out) do
			e.rebind = function(cells, _, index) log[#log + 1] = "rebind " .. e.key .. "@" .. index .. ":" .. cells[1].name end
		end
		return out
	end
	u.sync_table_rows(tbl, 2, 2, rows({ "a", "b", "c" }), state)
	H.gui_log = {}
	log = {}
	-- "b" left: "c" takes b's elements, the last row's go.
	assert_eq(u.sync_table_rows(tbl, 2, 2, rows({ "a", "c" }), state), "rebuilt")
	assert_eq(log, { "a@1:a1,a2", "rebind c@2:b1" })
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2" })
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 2)
	assert_eq(state.keys, { "a", "c" })
	-- One more row than before: the new last one is built.
	H.gui_log = {}
	log = {}
	u.sync_table_rows(tbl, 2, 2, rows({ "a", "c", "d" }), state)
	assert_eq(H.count_ops("add"), 2)
	assert_eq(log, { "a@1:a1,a2", "c@2:b1,b2" })
end)
