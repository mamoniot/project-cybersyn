-- A link cell for a stop name in a list row: up to three icons parsed from the front of the rich-text
-- name, the plain text as a link button, up to three icons from its end, each run with a "+n" when the name holds more.
-- Every part is a button tagged {kind, id} with links.handle.link_click, so a click anywhere on the name opens the stop.
-- The parts are direct children of one flow (no nested flows): a Trains page builds two of these per row.

local gui = require("__flib__.gui")
local util = require("scripts.gui.util")
local hover = require("scripts.gui.utils.hover")
local links = require("scripts.gui.utils.links")
local rich_name = require("scripts.gui.rich-name")

local name_cell = {}

local ICON = 20
local ICON_GAP = 2
local OVERFLOW = 22

--- A stop name is free text and outlives quality mods, and a sprite-button throws on an unknown quality.
--- @param quality string?
--- @return string?
local function known_quality(quality)
	return quality and prototypes.quality[quality] and quality or nil
end

--- Width the icons of one side take, so the text button can take the rest.
--- @param parts RichNameParts?
--- @return int
local function icons_width(parts)
	local w = 0
	if not parts then return w end
	for _, side in ipairs({ "lead", "tail" }) do
		local list = parts[side]
		if list then w = w + #list * (ICON + ICON_GAP) end
		if parts[side .. "_overflow"] then w = w + OVERFLOW end
	end
	return w
end

--- @param out flib.GuiElemDef[]
--- @param parts RichNameParts?
--- @param side "lead"|"tail"
--- @param tags {kind: string, id: any}
--- @param tooltip LocalisedString
--- @param scope string
local function add_side(out, parts, side, tags, tooltip, scope)
	local list = parts and parts[side]
	if list then
		local quality = parts[side .. "_quality"]
		for i, sprite in ipairs(list) do
			out[#out + 1] = hover.hoverable({
				type = "sprite-button",
				style = "cybersyn_name_icon",
				sprite = util.valid_sprite(sprite, "utility/questionmark"),
				quality = quality and known_quality(quality[i]),
				tooltip = tooltip,
				tags = { kind = tags.kind, id = tags.id },
				mouse_button_filter = { "left" },
				handler = { [defines.events.on_gui_click] = links.handle.link_click },
			}, scope)
		end
	end
	local over = parts and parts[side .. "_overflow"]
	if over then
		out[#out + 1] = { type = "label", style = "cybersyn_overflow_label", caption = "+" .. over, tooltip = tooltip }
	end
end

--- @param parts RichNameParts?
--- @param name string
--- @return string
local function text_of(parts, name)
	local text = parts and parts.text
	if text == nil or text == "" then return name end
	return text
end

--- The children of a cell: lead icons, the text button, tail icons.
local function children(parts, name, tags, width, tooltip, scope)
	local out = {}
	add_side(out, parts, "lead", tags, tooltip, scope)
	out[#out + 1] = hover.hoverable({
		type = "button",
		style = "cybersyn_link_button",
		style_mods = { maximal_width = math.max(width - icons_width(parts) - 4, 24) },
		caption = text_of(parts, name),
		tooltip = tooltip,
		tags = { kind = tags.kind, id = tags.id },
		mouse_button_filter = { "left" },
		handler = { [defines.events.on_gui_click] = links.handle.link_click },
	}, scope)
	add_side(out, parts, "tail", tags, tooltip, scope)
	return out
end

--- The text keeps at least this much of a cell before its icons give way.
local MIN_TEXT = 120

--- Parts for a cell `width` wide: when the icons would leave the text less than MIN_TEXT, the leading icons are dropped
--- (names such as "[a] / [b] Requestor for [c]" differ in their trailing icons). Parts are shared and read-only,
--- so a fitted copy is made only then.
--- @param parts RichNameParts?
--- @param width int
--- @return RichNameParts?
function name_cell.fit(parts, width)
	if not (parts and parts.lead) then return parts end
	if width - icons_width(parts) - 4 >= MIN_TEXT then return parts end
	return { text = parts.text, tail = parts.tail, tail_quality = parts.tail_quality, tail_overflow = parts.tail_overflow }
end

--- @param parts RichNameParts? shared and read-only (scripts/gui/rich-name.lua)
--- @param name string the full rich-text name
--- @param tags {kind: string, id: any}
--- @param width int
--- @param tooltip LocalisedString
--- @param scope string hover scope of the list
--- @param shrink boolean? at most `width` wide instead of exactly, so what follows the name sits right after it
--- @return flib.GuiElemDef
function name_cell.def(parts, name, tags, width, tooltip, scope, shrink)
	local def = {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_cell_flow",
		style_mods = shrink and { maximal_width = width, horizontal_spacing = ICON_GAP } or { width = width, horizontal_spacing = ICON_GAP },
		tags = { s = name .. "\1" .. tostring(tags.id) },
	}
	for i, child in ipairs(children(parts, name, tags, width, tooltip, scope)) do def[i] = child end
	return def
end

--- The text button of a cell.
--- @param cell LuaGuiElement
--- @return LuaGuiElement?
function name_cell.button(cell)
	for _, child in ipairs(cell.children) do
		if child.type == "button" then return child end
	end
	return nil
end

--- Rewrites a cell built by name_cell.def in place: rebuilt only when the name or the target changed, otherwise only
--- the tooltips are written.
--- @param cell LuaGuiElement
--- @param parts RichNameParts?
--- @param name string
--- @param tags {kind: string, id: any}
--- @param width int
--- @param tooltip LocalisedString
--- @param scope string
function name_cell.update(cell, parts, name, tags, width, tooltip, scope)
	local sig = name .. "\1" .. tostring(tags.id)
	if cell.tags.s ~= sig then
		cell.clear()
		for _, child in ipairs(children(parts, name, tags, width, tooltip, scope)) do gui.add(cell, child) end
		cell.tags = { s = sig }
		return
	end
	for _, child in ipairs(cell.children) do
		child.tooltip = tooltip
	end
end

--- Gives a cell built by name_cell.def a new width in place (the Trains table narrowed by the detail pane).
--- @param cell LuaGuiElement
--- @param parts RichNameParts?
--- @param width int
--- @param shrink boolean? as name_cell.def
function name_cell.resize(cell, parts, width, shrink)
	local style = cell.style
	if shrink then style.maximal_width = width else style.width = width end
	local button = name_cell.button(cell)
	if button then button.style.maximal_width = math.max(width - icons_width(parts) - 4, 24) end
end

-- ---------------------------------------------------------------- pooled cells (rows reused for other names)

-- Icons per side a pooled cell holds; a name with more shows the first ones.
name_cell.POOL_ICONS = 3
-- Logical px the text keeps before icons are dropped.
name_cell.MIN_TEXT = MIN_TEXT

--- How many lead and tail icons a name shows in a cell `width` px wide: lead · text · tail, and when that is short
--- the lead icons go first (the tail is what tells a base's similar names apart), then the tail's.
--- @param parts RichNameParts?
--- @param width int
--- @param max_icons int? per side, default POOL_ICONS
--- @return int lead
--- @return int tail
function name_cell.fit_counts(parts, width, max_icons)
	max_icons = max_icons or name_cell.POOL_ICONS
	local lead = parts and parts.lead and math.min(#parts.lead, max_icons) or 0
	local tail = parts and parts.tail and math.min(#parts.tail, max_icons) or 0
	local room = width - 4 - name_cell.MIN_TEXT
	while lead + tail > 0 and (lead + tail) * (ICON + ICON_GAP) > room do
		if lead > 0 then lead = lead - 1 else tail = tail - 1 end
	end
	return lead, tail
end

--- A cell that is written in place for whatever name its row shows next: a flow holding the text button; icon slots
--- are added beside it the first time a name needs them and hidden, never destroyed, when the next one does not.
--- Plain LuaGuiElement.add (no flib definition), so a long list of these is cheap to build.
--- @param parent LuaGuiElement
--- @param width int
--- @param flow_style string
--- @param button LuaGuiElement.add_param the text button: type, style, tags as the list needs
--- @return LuaGuiElement flow
function name_cell.pooled_add(parent, width, flow_style, button)
	local flow = parent.add({ type = "flow", direction = "horizontal", style = flow_style })
	local style = flow.style
	style.width = width
	style.horizontal_spacing = ICON_GAP
	flow.add(button)
	return flow
end

-- Icon slots are sprite buttons, not sprites: only a button draws an icon's quality badge.
local SLOT = { type = "sprite-button", style = "cybersyn_name_icon", ignored_by_interaction = true }

--- Writes a pooled cell's icons and text for `parts`, each part only when what it shows changed. `memo` (one per cell,
--- kept by the caller) remembers the elements and what they show. Returns the text button.
--- @param flow LuaGuiElement made by name_cell.pooled_add
--- @param memo table
--- @param parts RichNameParts?
--- @param name string the full name (shown when the name has no text of its own or no icon fits)
--- @param width int
--- @return LuaGuiElement button
function name_cell.write_pooled(flow, memo, parts, name, width)
	local button = memo.button
	if not (button and button.valid) then
		button = flow.children[1]
		memo.button, memo.lead, memo.tail, memo.shown = button, {}, {}, {}
	end
	local lead, tail = name_cell.fit_counts(parts, width)
	local shown = memo.shown
	local function side(list, n, sprites, qualities, prefix, before)
		for i = 1, math.max(n, #list) do
			local key = prefix .. i
			local sprite = i <= n and sprites[i] or false
			local quality = sprite and qualities and known_quality(qualities[i]) or nil
			local sig = sprite and (sprite .. "|" .. (quality or "")) or false
			if shown[key] ~= sig then
				local elem = list[i]
				if not elem then
					-- Lead slots go in front of the button, tail slots after the last one; made with their icon.
					SLOT.index = before and i or nil
					SLOT.sprite, SLOT.quality = util.valid_sprite(sprite, "utility/questionmark"), quality
					elem = flow.add(SLOT)
					SLOT.sprite, SLOT.quality = nil, nil
					list[i] = elem
					shown["q" .. key] = quality
				elseif sprite then
					elem.sprite = util.valid_sprite(sprite, "utility/questionmark")
					if shown["q" .. key] ~= quality then
						elem.quality = quality
						shown["q" .. key] = quality
					end
					if not shown[key] then elem.visible = true end
				elseif shown[key] then
					elem.visible = false
				end
				shown[key] = sig
			end
		end
	end
	side(memo.lead, lead, parts and parts.lead, parts and parts.lead_quality, "l", true)
	side(memo.tail, tail, parts and parts.tail, parts and parts.tail_quality, "t", false)
	SLOT.index = nil
	local text = parts and parts.text
	if text == nil or text == "" then text = (lead + tail) > 0 and "" or name end
	if memo.text ~= text then
		button.caption = text
		memo.text = text
	end
	local maximal = math.max(width - (lead + tail) * (ICON + ICON_GAP) - 4, 24)
	if memo.width ~= maximal then
		button.style.maximal_width = maximal
		memo.width = maximal
	end
	return button
end

-- ---------------------------------------------------------------- stop names

-- A pure function of the name, so a cache that differs between Lua states cannot desync anything.
local parsed_cache = {}

--- Name parts of a stop the snapshot does not hold (yet): parsed once per distinct name.
--- @param name string
--- @return RichNameParts
function name_cell.parse_name(name)
	local p = parsed_cache[name]
	if not p then
		p = rich_name.parse(name)
		parsed_cache[name] = p
	end
	return p
end

--- @class StopNameView
--- @field name string full rich-text name, for tooltips and the cell's signature
--- @field text string the name's text part, or the name
--- @field parts RichNameParts? lead icons · text · tail icons (scripts/gui/rich-name.lua)
--- @field kind "station"|"depot"|"refueler"

--- A station, depot or refueler by its stop's unit number, from the snapshot when it holds the station.
--- @param id uint?
--- @param stations {[uint]: SnapshotStation} the snapshot's stations
--- @param cache {[uint]: StopNameView|false}? views made during one render, so rows of one stop share one
--- @return StopNameView?
--- @return SnapshotStation?
function name_cell.station_view(id, stations, cache)
	if not id or id == 0 then return nil end
	local st = stations[id]
	if cache then
		local v = cache[id]
		if v ~= nil then return v or nil, st end
	end
	local name, parts, kind
	if st then
		name, parts, kind = st.name, st.name_parts, "station"
	else
		local stop, _, stop_kind = util.stop_record(id)
		if not stop then
			if cache then cache[id] = false end
			return nil
		end
		name, kind = stop.backer_name, stop_kind
		parts = name_cell.parse_name(name)
	end
	local label = parts and parts.text or name
	if label == nil or label == "" then label = name end
	local view = { name = name, text = label, parts = parts, kind = kind }
	if cache then cache[id] = view end
	return view, st
end

--- The full name in bold, an optional line under it, then the link footer.
--- @param view StopNameView?
--- @param extra LocalisedString?
--- @return LocalisedString
function name_cell.station_tooltip(view, extra)
	if not view then return "" end
	local tooltip = { "", "[font=default-semibold]", view.name, "[/font]" }
	if extra then
		tooltip[#tooltip + 1] = "\n"
		tooltip[#tooltip + 1] = extra
	end
	tooltip[#tooltip + 1] = "\n"
	tooltip[#tooltip + 1] = links.LINK_FOOTER
	return tooltip
end

return name_cell
