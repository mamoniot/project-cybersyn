--- Various string formatting functions.
--- @class flib_format
local flib_format = {}

local suffix_list = {
  { "Y", 1e24 }, -- yotta
  { "Z", 1e21 }, -- zetta
  { "E", 1e18 }, -- exa
  { "P", 1e15 }, -- peta
  { "T", 1e12 }, -- tera
  { "G", 1e9 }, -- giga
  { "M", 1e6 }, -- mega
  { "k", 1e3 }, -- kilo
}

--- Format a number for display, adding commas and an optional SI suffix.
--- Specify `fixed_precision` to display the number with the given width,
--- adjusting precision as necessary.
--- @param amount number
--- @param append_suffix boolean?
--- @param fixed_precision number?
--- @return string
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
    -- Show the number with fixed width precision
    local len_before = #tostring(math.floor(amount))
    local len_after = math.max(0, fixed_precision - len_before - 1)
    formatted = string.format("%." .. len_after .. "f", amount)
  end
  -- Add commas to result
  while true do
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
    if k == 0 then
      break
    end
  end
  return formatted .. suffix
end

--- Convert the given tick or game.tick into "[hh:]mm:ss" format.
--- @param tick uint?
--- @param include_leading_zeroes boolean?
--- @return string
function flib_format.time(tick, include_leading_zeroes)
  local total_seconds = math.floor((tick or game.ticks_played) / 60)
  local seconds = total_seconds % 60
  local minutes = math.floor(total_seconds / 60)
  if minutes > 59 then
    minutes = minutes % 60
    local hours = math.floor(total_seconds / 3600)
    if include_leading_zeroes then
      return string.format("%02d:%02d:%02d", hours, minutes, seconds)
    else
      return string.format("%d:%02d:%02d", hours, minutes, seconds)
    end
  else
    if include_leading_zeroes then
      return string.format("%02d:%02d", minutes, seconds)
    else
      return string.format("%d:%02d", minutes, seconds)
    end
  end
end

return flib_format
