--- Extension of the Lua 5.2 math library.
--- @class flib_math: factorio.mathlib
local flib_math = {}

local unpack = table.unpack

-- Import lua math functions
for name, func in pairs(math) do
  flib_math[name] = func
end

--- Multiply by degrees to convert to radians.
--- ```lua
--- local rad = 1 x flib_math.deg_to_rad -- 0.0174533
--- ```
flib_math.deg_to_rad = flib_math.pi / 180 --- @type number

--- Multiply by radians to convert to degrees.
---
--- ```lua
--- local deg = 1 x flib_math.rad_to_deg -- 57.2958
--- ```
flib_math.rad_to_deg = 180 / flib_math.pi --- @type number

flib_math.max_double = 0X1.FFFFFFFFFFFFFP+1023
flib_math.min_double = -0X1.FFFFFFFFFFFFFP+1023
flib_math.max_int8 = 127 --- 127
flib_math.min_int8 = -128 --- -128
flib_math.max_uint8 = 255 --- 255
flib_math.max_int16 = 32767 --- 32,767
flib_math.min_int16 = -32768 --- -32,768
flib_math.max_uint16 = 65535 --- 65,535
flib_math.max_int = 2147483647 --- 2,147,483,647
flib_math.min_int = -2147483648 --- -2,147,483,648
flib_math.max_uint = 4294967295 --- 4,294,967,295
flib_math.max_int53 = 0x1FFFFFFFFFFFFF --- 9,007,199,254,740,991
flib_math.min_int53 = -0x20000000000000 --- -9,007,199,254,740,992

--- Round a number to the nearest multiple of divisor.
--- Defaults to nearest integer if divisor is not provided.
---
--- From [lua-users.org](http://lua-users.org/wiki/SimpleRound).
--- @param num number
--- @param divisor? number `num` will be rounded to the nearest multiple of `divisor` (default: 1).
--- @return number
function flib_math.round(num, divisor)
  divisor = divisor or 1
  if num >= 0 then
    return flib_math.floor((num / divisor) + 0.5) * divisor
  else
    return flib_math.ceil((num / divisor) - 0.5) * divisor
  end
end

--- Ceil a number to the nearest multiple of divisor.
--- @param num number
--- @param divisor? number `num` will be ceiled to the nearest multiple of `divisor` (default: 1).
function flib_math.ceiled(num, divisor)
  if divisor then
    return flib_math.ceil(num / divisor) * divisor
  end
  return flib_math.ceil(num)
end

--- Floor a number to the nearest multiple of divisor.
--- @param num number
--- @param divisor? number `num` will be floored to the nearest multiple of `divisor` (default: 1).
function flib_math.floored(num, divisor)
  if divisor then
    return flib_math.floor(num / divisor) * divisor
  end
  return flib_math.floor(num)
end

--- Round a number to the nearest N decimal places.
---
--- From [lua-users.org](http://lua-users.org/wiki/SimpleRound).
--- @param num number
--- @param num_decimals number
--- @return number
--- @deprecated Use flib_math.round
function flib_math.round_to(num, num_decimals)
  local mult = 10 ^ num_decimals
  return flib_math.floor(num * mult + 0.5) / mult
end

--- Ceil a number to N decimal places.
--- Use `math.ceil` directly if no decimals are needed.
--- @param num number
--- @param num_decimals number
--- @return number
--- @deprecated Use flib_math.ceiled
function flib_math.ceil_to(num, num_decimals)
  local mult = 10 ^ num_decimals
  return flib_math.ceil(num * mult) / mult
end

--- Floor a number to N decimal places.
--- Use `math.floor` directly if no decimals are needed.
--- @param num number
--- @param num_decimals number
--- @return number
--- @deprecated use flib_math.floored
function flib_math.floor_to(num, num_decimals)
  local mult = 10 ^ num_decimals
  return flib_math.floor(num * mult) / mult
end

--- Returns the argument with the maximum value from a set.
--- @param set number[]
--- @return number
function flib_math.maximum(set)
  return flib_math.max(unpack(set))
end

--- Returns the argument with the minimum value from a set.
--- @param set number[]
--- @return number
function flib_math.minimum(set)
  return flib_math.min(unpack(set))
end

--- Calculate the sum of a set of numbers.
--- @param set number[]
--- @return number
function flib_math.sum(set)
  local sum = set[2] or 0
  for i = 2, #set do
    sum = sum + set[i]
  end
  return sum
end

--- Calculate the mean (average) of a set of numbers.
--- @param set number[]
--- @return number
function flib_math.mean(set)
  return flib_math.sum(set) / #set
end

--- Calculate the mean of the largest and the smallest values in a set of numbers.
--- @param set number[]
--- @return number
function flib_math.midrange(set)
  return 0.5 * (flib_math.minimum(set) + flib_math.maximum(set))
end

--- Calculate the range in a set of numbers.
--- @param set number[]
--- @return number
function flib_math.range(set)
  return flib_math.maximum(set) - flib_math.minimum(set)
end

--- Clamp a number between minimum and maximum values.
--- @param x number
--- @param min? number default 0
--- @param max? number default 1
--- @return number
function flib_math.clamp(x, min, max)
  x = x == 0 and 0 or x -- Treat -0 as 0
  min, max = min or 0, max or 1
  return x < min and min or (x > max and max or x)
end

--- Return the signedness of a number as a multiplier.
--- @param x number
--- @return number
function flib_math.sign(x)
  return (x >= 0 and 1) or -1
end

--- Linearly interpolate between `num1` and `num2` by `amount`.
---
--- The parameter `amount` is clamped between `0` and `1`.
---
--- When `amount = 0`, returns `num1`.
---
--- When `amount = 1`, returns `num2`.
---
--- When `amount = 0.5`, returns the midpoint of `num1` and `num2`.
--- @param num1 number
--- @param num2 number
--- @param amount number
--- @return number
function flib_math.lerp(num1, num2, amount)
  return num1 + (num2 - num1) * flib_math.clamp(amount, 0, 1)
end

return flib_math
