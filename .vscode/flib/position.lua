--- Utilities for manipulating positions. All functions support both the shorthand and explicit syntaxes and will
--- preserve the syntax that was passed in.
--- @class flib_position
local flib_position = {}

--- FIXME: Sumneko doesn't properly handle generics yet and throws a bunch of bogus warnings.
--- @diagnostic disable

--- Add two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return P
function flib_position.add(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  if pos1.x then
    return { x = x1 + x2, y = y1 + y2 }
  else
    return { x1 + x2, y1 + y2 }
  end
end

--- Ceil the given position.
--- @generic P
--- @param pos `P`
--- @return P
function flib_position.ceil(pos)
  if pos.x then
    return { x = math.ceil(pos.x), y = math.ceil(pos.y) }
  else
    return { math.ceil(pos[1]), math.ceil(pos[2]) }
  end
end

--- Calculate the distance between two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return number
function flib_position.distance(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

--- Calculate the squared distance between two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return number
function flib_position.distance_squared(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  return (x1 - x2) ^ 2 + (y1 - y2) ^ 2
end

--- Divide two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return P
function flib_position.div(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  if pos1.x then
    return { x = x1 / x2, y = y1 / y2 }
  else
    return { x1 / x2, y1 / y2 }
  end
end

--- Return the position in explicit form.
--- @generic P
--- @param pos `P`
--- @return P
function flib_position.ensure_explicit(pos)
  if pos.x then
    return pos
  else
    return { x = pos[1], y = pos[2] }
  end
end

--- Return the  position in shorthand form.
--- @generic P
--- @param pos `P`
--- @return P
function flib_position.ensure_short(pos)
  if pos.x then
    return { pos.x, pos.y }
  else
    return pos
  end
end

--- Test if two positions are equal.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return boolean
function flib_position.eq(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  return x1 == x2 and y1 == y2
end

--- Floor the given position.
--- @generic P
--- @param pos `P`
--- @return P
function flib_position.floor(pos)
  if pos.x then
    return { x = math.floor(pos.x), y = math.floor(pos.y) }
  else
    return { math.floor(pos[1]), math.floor(pos[2]) }
  end
end

--- Convert a `ChunkPosition` into a `TilePosition` by multiplying by 32.
--- @param pos ChunkPosition
--- @return TilePosition
function flib_position.from_chunk(pos)
  if pos.x then
    return { x = pos.x * 32, y = pos.y * 32 }
  else
    return { pos[1] * 32, pos[2] * 32 }
  end
end

--- Test if `pos1` is less than or equal to `pos2`.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return boolean
function flib_position.le(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  return x1 <= x2 and y1 <= y2
end

--- Test if `pos1` is less than `pos2`.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return boolean
function flib_position.lt(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  return x1 < x2 and y1 < y2
end

--- Take the remainder (modulus) of two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return P
function flib_position.mod(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  if pos1.x then
    return { x = x1 % x2, y = y1 % y2 }
  else
    return { x1 % x2, y1 % y2 }
  end
end

--- Multiply two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return P
function flib_position.mul(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  if pos1.x then
    return { x = x1 * x2, y = y1 * y2 }
  else
    return { x1 * x2, y1 * y2 }
  end
end

--- Subtract two positions.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return P
function flib_position.sub(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  if pos1.x then
    return { x = x1 - x2, y = y1 - y2 }
  else
    return { x1 - x2, y1 - y2 }
  end
end

--- Take the power of two positions. `pos1^pos2`.
--- @generic P
--- @param pos1 `P`
--- @param pos2 `P`
--- @return P
function flib_position.pow(pos1, pos2)
  local x1 = pos1.x or pos1[1]
  local y1 = pos1.y or pos1[2]
  local x2 = pos2.x or pos2[1]
  local y2 = pos2.y or pos2[2]
  if pos1.x then
    return { x = x1 ^ x2, y = y1 ^ y2 }
  else
    return { x1 ^ x2, y1 ^ y2 }
  end
end

--- Convert a `MapPosition` or `TilePosition` into a `ChunkPosition` by dividing by 32 and flooring.
--- @param pos MapPosition|TilePosition
--- @return ChunkPosition
function flib_position.to_chunk(pos)
  if pos.x then
    return { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) }
  else
    return { math.floor(pos[1] / 32), math.floor(pos[2] / 32) }
  end
end

--- Convert a `MapPosition` into a `TilePosition` by flooring.
--- @param pos MapPosition
--- @return TilePosition
function flib_position.to_tile(pos)
  if pos.x then
    return { x = math.floor(pos.x), y = math.floor(pos.y) }
  else
    return { math.floor(pos[1]), math.floor(pos[2]) }
  end
end

return flib_position
