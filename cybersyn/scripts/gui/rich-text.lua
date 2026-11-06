-- Rich-text tags for signals, items and networks. Pure (prototypes only), so the text models can use it.

local rich_text = {}

-- Prototypes cannot change while the game runs, and every prototypes.* lookup creates a wrapper object; the manager
-- names networks on every row it signs, so each name is looked up once per Lua state.
local network_icons = {}

---Creates the rich-text icon of a network signal; a name no prototype has is returned as it is
---@param network_name string?
---@return string
function rich_text.network_icon(network_name)
	if not network_name then return "?" end
	local icon = network_icons[network_name]
	if icon then return icon end
	if prototypes.virtual_signal[network_name] then
		icon = "[virtual-signal=" .. network_name .. "]"
	elseif prototypes.item[network_name] then
		icon = "[item=" .. network_name .. "]"
	elseif prototypes.fluid[network_name] then
		icon = "[fluid=" .. network_name .. "]"
	else
		icon = network_name
	end
	network_icons[network_name] = icon
	return icon
end

---A network's icon followed by `suffix` (its mask or a count), with a space between when the network has no icon so
---that a plain name and a number stay apart
---@param network_name string
---@param suffix string
---@return string
function rich_text.network_icon_with(network_name, suffix)
	local icon = rich_text.network_icon(network_name)
	if icon == network_name and suffix ~= "" then return icon .. " " .. suffix end
	return icon .. suffix
end

---Creates the rich-text icon of an item or fluid, with its quality unless that is normal (fluids have none)
---@param name string
---@param quality string?
---@return string
function rich_text.item(name, quality)
	if prototypes.fluid[name] then return "[fluid=" .. name .. "]" end
	if quality and quality ~= "normal" then return "[item=" .. name .. ",quality=" .. quality .. "]" end
	return "[item=" .. name .. "]"
end

---Creates the rich-text icon of a stored item hash, as rich_text.item does
---@param hash string
---@return string
function rich_text.of_hash(hash)
	return rich_text.item(unhash_signal(hash))
end

---Turns SignalID into a valid rich-text definition of the signal icon
---@param signal SignalID
---@return string
function rich_text.signal(signal)
	local quality = signal.quality or ""
	local type = signal.type or "item" -- if type is nil, it is item
	if type == "virtual" then
		type = "virtual-signal" -- rich text needs 'virtual-signal'
	end
	return "[" .. type .. "=" .. signal.name .. ",quality=" .. quality .. "]"
end

return rich_text
