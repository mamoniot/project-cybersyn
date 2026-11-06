-- "Explain" for one Unserved row: what the dispatcher recorded for a (requester, item) key, the
-- requester's setup findings and the recent confirmed reason changes and who it lost to. It reads storage.diag and
-- the lint result only: it never evaluates eligibility itself (the lint engine and the reason codes stay the only two
-- models).
-- Mounted as a screen frame beside the manager window, so the Overview's whole-row sizing never changes.

local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local logic = require("scripts.gui.tab-logic")
local templates = require("scripts.gui.templates")
local utext = require("scripts.gui.unserved-text")
local rtext = require("scripts.gui.relative-text")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local pm = require("scripts.gui.problems-model")
local lint_text = require("scripts.gui.lint-text")
local collector = require("scripts.gui.collector")

local explain = {}
explain.handle = {}

local FRAME = "cybersyn_explain"
local WIDTH = 440
local INNER = WIDTH - 24
local CHANGES = 5

--- @param r_id uint
--- @param hash string
--- @return DiagEntry?
local function entry_of(r_id, hash)
	local d = storage.diag
	if not d then return nil end
	local ix = d.item_ix[hash]
	local by_item = ix and d.unserved[r_id]
	return by_item and by_item[ix] or nil
end

local function stop_name(id)
	local stop = util.stop_record(id)
	return stop and stop.backer_name or tostring(id)
end

--- The combinator row of the requester that asks for the item, from the collector's snapshot; nil for a plain station.
--- @return SnapshotInventory?
local function request_row(r_id, hash)
	local snapshot = collector.get()
	local st = snapshot and snapshot.stations and snapshot.stations[r_id]
	return utext.inventory_of(st, hash, "requested", collector.inventories)
end

--- The requester's network as the why / fix lines name it: the inventory that requests the item when the station has
--- inventory combinators (an inventory on A2 is not served on the station combinator's A1), else the station's
--- network.
--- @param r_id uint
--- @param hash string
--- @param station table? storage.stations[r_id]
--- @return LocalisedString
function explain.network_of(r_id, hash, station)
	local row = request_row(r_id, hash)
	if row then return rtext.row_text(row) end
	return util.network_caption(station and station.network_name)
end

local GREY = { 0.65, 0.65, 0.65 }

local function label(caption, grey)
	return {
		type = "label",
		caption = caption,
		style_mods = { single_line = false, maximal_width = INNER, font_color = grey and GREY or nil },
	}
end

local function heading(caption)
	return { type = "label", style = "caption_label", caption = caption }
end

--- A string that changes whenever anything shown changes (ages in 10 s steps).
local function sig_of(r_id, hash, e)
	local now = game.tick
	local lint_s = storage.manager.lint
	if not e then return table.concat({ "gone", lint_s and lint_s.pass or 0 }, "|") end
	local row = request_row(r_id, hash)
	local inv_sig = row and rtext.row_sig(row) or ""
	return table.concat({ inv_sig, e.reason, e.a, e.b, e.n, #e.changes, e.changes[#e.changes] or 0, tostring(e.lost_to), e.lost_n,
		math.floor((now - e.first_tick) / utext.READ_STEP), lint_s and lint_s.pass or 0,
		storage.acks and storage.acks.lint_version or 0 }, "|")
end

--- The body's children for one key.
local function body_defs(r_id, hash, e)
	local now = game.tick
	local out = {}
	local sprite, quality = util.item_sprite_and_tooltip(hash)
	if not e then
		out[#out + 1] = label({ "cybersyn-gui.explain-gone" }, true)
	else
		local d = storage.diag
		local wait = now - e.first_tick
		local inherited = e.first_tick < diag.inherit_threshold(d)
		local station = storage.stations[r_id]
		local network = explain.network_of(r_id, hash, station)
		out[#out + 1] = heading({ "cybersyn-gui.explain-recorded" })
		out[#out + 1] = {
			type = "flow",
			direction = "horizontal",
			style_mods = { vertical_align = "center", horizontal_spacing = 8 },
			{ type = "button", style = utext.chip_style(e.reason), caption = utext.chip_caption(e.reason),
				ignored_by_interaction = true },
			label(utext.stock_caption(e.reason, e.a, e.b), true),
		}
		out[#out + 1] = label({ "cybersyn-gui.unserved-why", utext.why(e.reason, e.a, e.b, network, e.rej, util.surface_name) })
		out[#out + 1] = label({ "cybersyn-gui.unserved-fix", utext.fix(e.reason, network) }, true)
		out[#out + 1] = label({ inherited and "cybersyn-gui.unserved-since-load" or "cybersyn-gui.unserved-since",
			logic.format_duration(wait), tostring(e.n or 0) }, true)
		if e.p_station_id and e.reason ~= REASON_NO_PROVIDER then
			out[#out + 1] = label({ "cybersyn-gui.explain-provider", stop_name(e.p_station_id) }, true)
		end

		out[#out + 1] = heading({ "cybersyn-gui.explain-history" })
		local changes, reasons = e.changes, e.change_reasons
		if #changes == 0 then
			out[#out + 1] = label({ "cybersyn-gui.explain-history-none" }, true)
		end
		for k = #changes, math.max(1, #changes - CHANGES + 1), -1 do
			out[#out + 1] = label({ "cybersyn-gui.explain-change", logic.format_duration(now - changes[k]),
				utext.chip_caption(reasons[k] or e.reason) })
		end
		if e.lost_to and e.lost_n > 0 then
			out[#out + 1] = label({ "cybersyn-diag.lost-priority", stop_name(e.lost_to), tostring(e.lost_n) })
		end
	end

	out[#out + 1] = heading({ "cybersyn-gui.relative-setup" })
	local findings = {}
	for _, f in ipairs(lint.findings()) do
		if f.id == r_id and f.subject ~= LINT_SUBJECT_TRAIN then findings[#findings + 1] = f end
	end
	local lint_s = storage.manager.lint
	if #findings == 0 then
		out[#out + 1] = label({ (lint_s and lint_s.pass or 0) == 0 and "cybersyn-gui.relative-setup-not-run"
			or "cybersyn-gui.relative-setup-none" }, true)
	end
	for _, f in ipairs(findings) do
		out[#out + 1] = label({ "", "• ", { "cybersyn-diag.lint-" .. LINT_KEYS[f.check] } })
		out[#out + 1] = label(pm.detail(f, lint_text.ENV), true)
		out[#out + 1] = label(pm.fix(f.check, f), true)
	end

	return out, sprite, quality
end

--- Places the frame right of the manager window, or left when the right side has no room.
local function place(player, pd, frame)
	local window = pd.refs and pd.refs.manager_window
	local scale = player.display_scale
	if not (window and window.valid and window.visible) then
		frame.force_auto_center()
		return
	end
	local loc = window.location
	local layout = pd.layout
	local width_px = math.floor((layout and layout.width or 1440) * scale)
	local own = math.floor((WIDTH + 24) * scale)
	local x = loc.x + width_px + math.floor(8 * scale)
	if x + own > player.display_resolution.width then x = math.max(0, loc.x - own - math.floor(8 * scale)) end
	frame.location = { x = x, y = loc.y }
end

--- Places the open frame again after the manager window moved or was laid out again.
--- @param player LuaPlayer
--- @param pd PlayerData
function explain.place(player, pd)
	local frame = pd.explain and player.gui.screen[FRAME]
	if frame and frame.valid then place(player, pd, frame) end
end

--- Builds or refreshes the frame for pd.explain.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param force boolean? rebuild even when nothing changed
function explain.render(player, pd, force)
	local ex = pd.explain
	if not ex then return end
	local frame = player.gui.screen[FRAME]
	if not (frame and frame.valid) then return end
	local e = entry_of(ex.r_id, ex.hash)
	local sig = sig_of(ex.r_id, ex.hash, e)
	if not force and ex.sig == sig then return end
	ex.sig = sig
	local body = frame.body
	body.clear()
	local defs, sprite, quality = body_defs(ex.r_id, ex.hash, e)
	for _, def in ipairs(defs) do gui.add(body, def) end
	local title = frame.titlebar.title
	local caption = { "cybersyn-gui.explain-title", sprite and ("[img=" .. sprite .. "]") or "", stop_name(ex.r_id) }
	title.caption = caption
	title.tooltip = caption
end

--- Opens Explain for one Unserved key (the row's Why chip), or closes it when it already shows that key.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param r_id uint
--- @param hash string
function explain.open(player, pd, r_id, hash)
	local cur = pd.explain
	local frame = player.gui.screen[FRAME]
	if cur and cur.r_id == r_id and cur.hash == hash and frame and frame.valid then
		explain.close(player, pd)
		return
	end
	if frame and frame.valid then frame.destroy() end
	local _, f = gui.add(player.gui.screen, {
		type = "frame",
		name = FRAME,
		direction = "vertical",
		style_mods = { width = WIDTH },
		{
			type = "flow",
			name = "titlebar",
			style = "flib_titlebar_flow",
			-- Requester names carry many icons: the title squashes (full caption in its tooltip) so the X always stays in
			-- the frame, and the whole bar drags because the handle can be squashed to nothing.
			{
				type = "label",
				name = "title",
				style = "frame_title",
				style_mods = { horizontally_squashable = true },
			},
			{ type = "empty-widget", name = "drag", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
			templates.frame_action_button("close", "utility/close", { "gui.close-instruction" },
				{ [defines.events.on_gui_click] = explain.handle.explain_close }),
		},
		{
			type = "frame",
			name = "body",
			style = "inside_shallow_frame_with_padding",
			direction = "vertical",
			style_mods = { horizontally_stretchable = true },
		},
	})
	f.titlebar.drag_target = f
	f.titlebar.title.drag_target = f
	pd.explain = { r_id = r_id, hash = hash }
	place(player, pd, f)
	explain.render(player, pd, true)
end

--- @param player LuaPlayer?
--- @param pd PlayerData
function explain.close(player, pd)
	pd.explain = nil
	if not player then return end
	local frame = player.gui.screen[FRAME]
	if frame and frame.valid then frame.destroy() end
end

--- Manager tick: refresh the open frames. Closing the window closes its frame (manager_close, reset_player).
--- @param manager_data Manager
function explain.tick(manager_data)
	for i, pd in pairs(manager_data.players) do
		if pd.explain then
			local player = game.get_player(i)
			if player then explain.render(player, pd) end
		end
	end
end

function explain.handle.explain_close(player, pd)
	explain.close(player, pd)
end

explain.wrapper = util.wrapper

gui.add_handlers(explain.handle, explain.wrapper, "cybersyn_explain")

return explain
