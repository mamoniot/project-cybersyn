-- Splits a train stop's rich-text name into leading icons, plain text and trailing icons, so a row can draw the icons
-- as sprites and give the text the width. Pure string work: identical in every Lua state, no prototype lookups.

local rich_name = {}

--- Icons kept on each side; the rest is counted in lead_overflow / tail_overflow.
--- The parts are kept per station in the snapshot, so they hold no empty tables and no zero counts: the first
--- version, with an icon table per icon, cost ~1.45 KB per station (2.9 MB on a 2,030-station save).
rich_name.MAX_ICONS = 3

--- Rich-text tag types that name a sprite, mapped to their sprite path prefix (SpritePath); `img` already holds one.
local SPRITE_TYPES = {
	item = "item",
	fluid = "fluid",
	["virtual-signal"] = "virtual-signal",
	entity = "entity",
	recipe = "recipe",
	tile = "tile",
	technology = "technology",
	["space-location"] = "space-location",
	planet = "space-location",
	quality = "quality",
	img = "",
}

--- @class RichNameIcon
--- @field sprite string sprite path, e.g. "item/iron-plate"
--- @field quality string? quality name of a `[item=x,quality=y]` tag

--- @class RichNameParts
--- @field text string the name between the icon runs, trimmed; may still hold tags this parser does not turn into icons
--- @field lead string[]? sprite paths of at most MAX_ICONS icons before the text, in name order; nil when none
--- @field lead_quality {[integer]: string}? quality per `lead` index, only for icons that name one
--- @field lead_overflow integer? leading icons beyond MAX_ICONS; nil when none
--- @field tail string[]? sprite paths of at most MAX_ICONS icons after the text, in name order; nil when none
--- @field tail_quality {[integer]: string}?
--- @field tail_overflow integer?

--- Parses the tag starting at `pos` (a "["). Returns the icon and the position after the "]", or nil when the tag is
--- not an icon tag this module understands.
--- @param name string
--- @param pos integer
--- @return RichNameIcon?
--- @return integer?
local function icon_at(name, pos)
	local s, e, kind, body = string.find(name, "^%[([%w%-]+)=([^%[%]]*)%]", pos)
	if not s then return nil end
	local prefix = SPRITE_TYPES[kind]
	if not prefix then return nil end
	local id, rest = string.match(body, "^%s*([^,%s]+)%s*(.*)$")
	if not id then return nil end
	local quality
	if rest ~= "" then
		quality = string.match(rest, "^,%s*quality%s*=%s*([^,%s]+)%s*$")
		if not quality then return nil end
	end
	return { sprite = prefix == "" and id or prefix .. "/" .. id, quality = quality }, e + 1
end

--- Every icon tag in `name`, each with its byte span, in order.
--- @param name string
--- @return {icon: RichNameIcon, s: integer, e: integer}[]
local function scan(name)
	local found = {}
	local pos = 1
	while true do
		local s = string.find(name, "[", pos, true)
		if not s then break end
		local icon, after = icon_at(name, s)
		if icon then
			found[#found + 1] = { icon = icon, s = s, e = after - 1 }
			pos = after
		else
			pos = s + 1
		end
	end
	return found
end

local function only_space(name, from, to)
	return from > to or string.find(string.sub(name, from, to), "^%s*$") ~= nil
end

-- "/", "," and "|" between two icons join them into one run, so "[a] / [b] Requestor" draws [b] as a sprite rather
-- than inline at glyph size beside a stray slash.
local function only_separators(name, from, to)
	return from > to or string.find(string.sub(name, from, to), "^[%s/,|]*$") ~= nil
end

--- @param parts RichNameParts
--- @param side "lead"|"tail"
--- @param icon RichNameIcon
local function add_icon(parts, side, icon)
	local sprites = get_or_create(parts, side)
	local i = #sprites + 1
	sprites[i] = icon.sprite
	if icon.quality then
		local key = side .. "_quality"
		local qualities = get_or_create(parts, key)
		qualities[i] = icon.quality
	end
end

--- @param name string full rich-text name
--- @return RichNameParts
function rich_name.parse(name)
	local parts = { text = "" }
	if type(name) ~= "string" or name == "" then return parts end
	local found = scan(name)
	local n = #found
	local max = rich_name.MAX_ICONS

	-- Leading run: icons separated from the start by whitespace, from each other by whitespace or separators.
	local lead_n, prev_end = 0, 0
	while lead_n < n and (lead_n == 0 and only_space or only_separators)(name, prev_end + 1, found[lead_n + 1].s - 1) do
		lead_n = lead_n + 1
		prev_end = found[lead_n].e
	end
	local text_from = prev_end + 1

	-- Trailing run, never overlapping the leading one.
	local tail_first, next_start = n + 1, #name + 1
	while tail_first - 1 > lead_n
		and (tail_first == n + 1 and only_space or only_separators)(name, found[tail_first - 1].e + 1, next_start - 1) do
		tail_first = tail_first - 1
		next_start = found[tail_first].s
	end
	local text_to = next_start - 1

	for i = 1, math.min(lead_n, max) do
		add_icon(parts, "lead", found[i].icon)
	end
	if lead_n > max then parts.lead_overflow = lead_n - max end
	local tail_n = n - tail_first + 1
	local skip = math.max(tail_n - max, 0)
	if skip > 0 then parts.tail_overflow = skip end
	for i = tail_first + skip, n do
		add_icon(parts, "tail", found[i].icon)
	end
	parts.text = string.match(string.sub(name, text_from, text_to), "^%s*(.-)%s*$")
	return parts
end

return rich_name
