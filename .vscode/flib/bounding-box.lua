local position = require("__flib__/position")

--- Utilities for manipulating bounding boxes. All functions support both the shorthand and explicit syntaxes for boxes
--- and positions, and will preserve the syntax that was passed in. Boxes are considered immutable; all functions will
--- return new boxes.
--- @class flib_bounding_box
local flib_bounding_box = {}

--- Return a new box expanded to the nearest tile edges.
--- @param box BoundingBox
--- @return BoundingBox
function flib_bounding_box.ceil(box)
  if box.left_top then
    return {
      left_top = { x = math.floor(box.left_top.x), y = math.floor(box.left_top.y) },
      right_bottom = { x = math.ceil(box.right_bottom.x), y = math.ceil(box.right_bottom.y) },
    }
  else
    return {
      { math.floor(box[1][1]), math.floor(box[1][2]) },
      { math.ceil(box[2][1]), math.ceil(box[2][2]) },
    }
  end
end

--- Calculate the centerpoint of the box.
--- @param box BoundingBox
--- @return MapPosition
function flib_bounding_box.center(box)
  if box.left_top then
    return {
      x = (box.left_top.x + box.right_bottom.x) / 2,
      y = (box.left_top.y + box.right_bottom.y) / 2,
    }
  else
    return {
      (box[1][1] + box[2][1]) / 2,
      (box[1][2] + box[2][2]) / 2,
    }
  end
end

--- Check if the first box contains the second box.
--- @param box1 BoundingBox
--- @param box2 BoundingBox
--- @return boolean
function flib_bounding_box.contains_box(box1, box2)
  local box1 = flib_bounding_box.ensure_explicit(box1)
  local box2 = flib_bounding_box.ensure_explicit(box2)

  return box1.left_top.x <= box2.left_top.x
    and box1.left_top.y <= box2.left_top.y
    and box1.right_bottom.x >= box2.right_bottom.x
    and box1.right_bottom.y >= box2.right_bottom.y
end

--- Check if the given box contains the given position.
--- @param box BoundingBox
--- @param pos MapPosition
--- @return boolean
function flib_bounding_box.contains_position(box, pos)
  local box = flib_bounding_box.ensure_explicit(box)
  local pos = position.ensure_explicit(pos)
  return
    box.left_top.x <= pos.x and box.left_top.y <= pos.y and box.right_bottom.x >= pos.x and box.right_bottom.y >= pos.y
end

--- Return the box in explicit form.
--- @param box BoundingBox
--- @return BoundingBox
function flib_bounding_box.ensure_explicit(box)
  return {
    left_top = position.ensure_explicit(box.left_top or box[1]),
    right_bottom = position.ensure_explicit(box.right_bottom or box[2]),
  }
end

--- Return the box in shorthand form.
--- @param box BoundingBox
--- @return BoundingBox
function flib_bounding_box.ensure_short(box)
  return {
    position.ensure_short(box.left_top or box[1]),
    position.ensure_short(box.right_bottom or box[2]),
  }
end

--- Return a new box with initial dimensions box1, expanded to contain box2.
--- @param box1 BoundingBox
--- @param box2 BoundingBox
--- @return BoundingBox
function flib_bounding_box.expand_to_contain_box(box1, box2)
  local box2 = flib_bounding_box.ensure_explicit(box2)

  if box1.left_top then
    return {
      left_top = {
        x = math.min(box1.left_top.x, box2.left_top.x),
        y = math.min(box1.left_top.y, box2.left_top.y),
      },
      right_bottom = {
        x = math.max(box1.right_bottom.x, box2.right_bottom.x),
        y = math.max(box1.right_bottom.y, box2.right_bottom.y),
      },
    }
  else
    return {
      {
        math.min(box1[1][1], box2.left_top.x),
        math.min(box1[1][2], box2.left_top.y),
      },
      {
        math.max(box1[2][1], box2.right_bottom.x),
        math.max(box1[2][2], box2.right_bottom.y),
      },
    }
  end
end

--- Return a new box expanded to contain the given position.
--- @param box BoundingBox
--- @param pos MapPosition
--- @return BoundingBox
function flib_bounding_box.expand_to_contain_position(box, pos)
  local pos = position.ensure_explicit(pos)

  if box.left_top then
    return {
      left_top = { x = math.min(box.left_top.x, pos.x), y = math.min(box.left_top.y, pos.y) },
      right_bottom = { x = math.max(box.right_bottom.x, pos.x), y = math.max(box.right_bottom.y, pos.y) },
    }
  else
    return {
      { math.min(box[1][1], pos.x), math.min(box[1][2], pos.y) },
      { math.max(box[2][1], pos.x), math.max(box[2][2], pos.y) },
    }
  end
end

--- Return a new box shrunk to the nearest tile edges.
--- @param box BoundingBox
--- @return BoundingBox
function flib_bounding_box.floor(box)
  if box.left_top then
    return {
      left_top = { x = math.ceil(box.left_top.x), y = math.ceil(box.left_top.y) },
      right_bottom = { x = math.floor(box.right_bottom.x), y = math.floor(box.right_bottom.y) },
    }
  else
    return {
      { math.ceil(box[1][1]), math.ceil(box[1][2]) },
      { math.floor(box[2][1]), math.floor(box[2][2]) },
    }
  end
end

--- Create a new box from a centerpoint and dimensions.
--- @param center MapPosition
--- @param width number
--- @param height number
--- @return BoundingBox
function flib_bounding_box.from_dimensions(center, width, height)
  if center.x then
    return {
      left_top = { x = center.x - width / 2, y = center.y - height / 2 },
      right_bottom = { x = center.x - width / 2, y = center.y - height / 2 },
    }
  else
    return {
      { center[1] - width / 2, center[2] - height / 2 },
      { center[1] - width / 2, center[2] - height / 2 },
    }
  end
end

--- Create a 1x1 box from the given position, optionally snapped to the containing tile edges.
--- @param pos MapPosition
--- @param snap boolean?
--- @return BoundingBox
function flib_bounding_box.from_position(pos, snap)
  if snap then
    pos = position.floor(pos)
  else
    pos = position.sub(pos, { 0.5, 0.5 })
  end
  local x = pos.x or pos[1]
  local y = pos.y or pos[2]
  if pos.x then
    return {
      left_top = { x = x, y = y },
      right_bottom = { x = x + 1, y = y + 1 },
    }
  else
    return {
      { x, y },
      { x + 1, y + 1 },
    }
  end
end

--- Calculate the height of the box.
--- @param box BoundingBox
--- @return number
function flib_bounding_box.height(box)
  if box.left_top then
    return box.right_bottom.y - box.left_top.y
  else
    return box[2][2] - box[1][2]
  end
end

--- Check if the first box intersects (overlaps) the second box.
--- @param box1 BoundingBox
--- @param box2 BoundingBox
--- @return boolean
function flib_bounding_box.intersects_box(box1, box2)
  local box1 = flib_bounding_box.ensure_explicit(box1)
  local box2 = flib_bounding_box.ensure_explicit(box2)
  return
    box1.left_top.x < box2.right_bottom.x
      and box2.left_top.x < box1.right_bottom.x
      and box1.left_top.y < box2.right_bottom.y
      and box2.left_top.y < box1.right_bottom.y
end

--- Return a new box with  the same dimensions, moved by the given delta.
--- @param box BoundingBox
--- @param delta MapPosition
--- @return BoundingBox
function flib_bounding_box.move(box, delta)
  local dx = delta.x or delta[1]
  local dy = delta.y or delta[2]
  if box.left_top then
    return {
      left_top = { x = box.left_top.x + dx, y = box.left_top.y + dy },
      right_bottom = { x = box.right_bottom.x + dx, y = box.right_bottom.y + dy },
    }
  else
    return {
      { box[1][1] + dx, box[1][2] + dy },
      { box[2][1] + dx, box[2][2] + dy },
    }
  end
end

--- Return a new box with the same dimensions centered on the given position.
--- @param box BoundingBox
--- @param pos MapPosition
--- @return BoundingBox
function flib_bounding_box.recenter_on(box, pos)
  local height = flib_bounding_box.height(box)
  local width = flib_bounding_box.width(box)

  local pos_x = pos.x or pos[1]
  local pos_y = pos.y or pos[2]

  if box.left_top then
    return {
      left_top = { x = pos_x - (width / 2), y = pos_y - (width / 2) },
      right_bottom = { x = pos_x + (height / 2), y = pos_y + (height / 2) },
    }
  else
    return {
      { pos_x - (width / 2), pos_y - (width / 2) },
      { pos_x + (height / 2), pos_y + (height / 2) },
    }
  end
end

--- Return a new box grown or shrunk by the given delta. A positive delta will grow the box, a negative delta will
--- shrink it.
--- @param box BoundingBox
--- @param delta number
--- @return BoundingBox
function flib_bounding_box.resize(box, delta)
  if box.left_top then
    return {
      left_top = { x = box.left_top.x - delta, y = box.left_top.y - delta },
      right_bottom = { x = box.right_bottom.x + delta, y = box.right_bottom.y + delta },
    }
  else
    return {
      { box[1][1] - delta, box[1][2] - delta },
      { box[2][1] + delta, box[2][2] + delta },
    }
  end
end

--- Return a new box rotated 90 degrees about its center.
--- @param box BoundingBox
--- @return BoundingBox
function flib_bounding_box.rotate(box)
  local center = flib_bounding_box.center(box)
  local radius_x = flib_bounding_box.width(box) / 2
  local radius_y = flib_bounding_box.height(box) / 2

  if box.left_top then
    return {
      left_top = { x = center.x - radius_y, y = center.y - radius_x },
      right_bottom = { x = center.x + radius_y, y = center.y + radius_x },
    }
  else
    return {
      { center.x - radius_y, center.y - radius_x },
      { center.x + radius_y, center.y + radius_x },
    }
  end
end

--- Return a new box expanded to create a square.
--- @param box BoundingBox
--- @return BoundingBox
function flib_bounding_box.square(box)
  local radius = math.max(flib_bounding_box.width(box), flib_bounding_box.height(box))
  return flib_bounding_box.from_dimensions(flib_bounding_box.center(box), radius, radius)
end

--- Calculate the width of the box.
--- @param box BoundingBox
--- @return number
function flib_bounding_box.width(box)
  if box.left_top then
    return box.right_bottom.x - box.left_top.x
  else
    return box[2][1] - box[1][1]
  end
end

return flib_bounding_box
