--- @diagnostic disable
--- @deprecated Use `bounding-box` instead.
local flib_area = {}

--- @deprecated Use `bounding-box` instead.
function flib_area.ceil(self)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end
  self.left_top = {
    x = math.floor(self.left_top.x),
    y = math.floor(self.left_top.y),
  }
  self.right_bottom = {
    x = math.ceil(self.right_bottom.x),
    y = math.ceil(self.right_bottom.y),
  }

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.center(self)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end
  return {
    x = self.left_top.x + (flib_area.width(self) / 2),
    y = self.left_top.y + (flib_area.height(self) / 2),
  }
end

--- @deprecated Use `bounding-box` instead.
function flib_area.center_on(self, center_point)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  local height = flib_area.height(self)
  local width = flib_area.width(self)

  self.left_top = {
    x = center_point.x - (width / 2),
    y = center_point.y - (height / 2),
  }
  self.right_bottom = {
    x = center_point.x + (width / 2),
    y = center_point.y + (height / 2),
  }

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.contains_area(self, other_area)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  return (
    self.left_top.x <= other_area.left_top.x
    and self.left_top.y <= other_area.left_top.y
    and self.right_bottom.x >= other_area.right_bottom.x
    and self.right_bottom.y >= other_area.right_bottom.y
  )
end

--- @deprecated Use `bounding-box` instead.
function flib_area.contains_position(self, position)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  return (
    self.left_top.x <= position.x
    and self.right_bottom.x >= position.x
    and self.left_top.y <= position.y
    and self.right_bottom.y >= position.y
  )
end

--- @deprecated Use `bounding-box` instead.
function flib_area.corners(self)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  self.left_bottom = {
    x = self.left_top.x,
    y = self.right_bottom.y,
  }
  self.right_top = {
    x = self.right_bottom.x,
    y = self.left_top.y,
  }

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.distance_to_nearest_edge(self, position)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  local x_distance = math.min(math.abs(self.left_top.x - position.x), math.abs(self.right_bottom.x - position.x))
  local y_distance = math.min(math.abs(self.left_top.y - position.y), math.abs(self.right_bottom.y - position.y))

  return math.min(x_distance, y_distance)
end

--- @deprecated Use `bounding-box` instead.
function flib_area.expand(self, delta)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  self.left_top.x = self.left_top.x - delta
  self.right_bottom.x = self.right_bottom.x + delta
  self.left_top.y = self.left_top.y - delta
  self.right_bottom.y = self.right_bottom.y + delta

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.expand_to_contain_area(self, other_area)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  self.left_top = {
    x = self.left_top.x < other_area.left_top.x and self.left_top.x or other_area.left_top.x,
    y = self.left_top.y < other_area.left_top.y and self.left_top.y or other_area.left_top.y,
  }
  self.right_bottom = {
    x = self.right_bottom.x > other_area.right_bottom.x and self.right_bottom.x or other_area.right_bottom.x,
    y = self.right_bottom.y > other_area.right_bottom.y and self.right_bottom.y or other_area.right_bottom.y,
  }

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.expand_to_contain_position(self, position)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  self.left_top = {
    x = self.left_top.x < position.x and self.left_top.x or position.x,
    y = self.left_top.y < position.y and self.left_top.y or position.y,
  }
  self.right_bottom = {
    x = self.right_bottom.x > position.x and self.right_bottom.x or position.x,
    y = self.right_bottom.y > position.y and self.right_bottom.y or position.y,
  }

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.floor(self)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  self.left_top = {
    x = math.ceil(self.left_top.x),
    y = math.ceil(self.left_top.y),
  }
  self.right_bottom = {
    x = math.floor(self.right_bottom.x),
    y = math.floor(self.right_bottom.y),
  }

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.from_dimensions(dimensions, center)
  center = center or { x = 0, y = 0 }
  local self = {
    left_top = {
      x = center.x - (dimensions.width / 2),
      y = center.y - (dimensions.height / 2),
    },
    right_bottom = {
      x = center.x + (dimensions.width / 2),
      y = center.y + (dimensions.height / 2),
    },
  }
  flib_area.load(self)
  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.from_position(position, snap)
  local self
  if snap then
    local floored_position = { x = math.floor(position.x), y = math.floor(position.y) }
    self = {
      left_top = { x = floored_position.x, y = floored_position.y },
      right_bottom = { x = floored_position.x + 1, y = floored_position.y + 1 },
    }
  else
    self = {
      left_top = { x = position.x - 0.5, y = position.y - 0.5 },
      right_bottom = { x = position.x + 0.5, y = position.y + 0.5 },
    }
  end

  if self then
    flib_area.load(self)
    return self
  end
end

--- @deprecated Use `bounding-box` instead.
function flib_area.from_shorthand(area)
  local self = {
    left_top = { x = area[1][1], y = area[1][2] },
    right_bottom = { x = area[2][1], y = area[2][2] },
  }
  flib_area.load(self)
  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.height(self)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  return math.abs(self.right_bottom.y - self.left_top.y)
end

--- @deprecated Use `bounding-box` instead.
function flib_area.iterate(self, step, starting_offset)
  starting_offset = starting_offset or { x = 0, y = 0 }
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  step = step or 1

  local x = self.left_top.x + starting_offset.x
  local y = self.left_top.y + starting_offset.y
  local max_x = self.right_bottom.x
  local max_y = self.right_bottom.y
  local first = true

  return function()
    if first then
      first = false
      return { x = x, y = y }
    end

    local new_x = x + step
    if x < max_x and new_x < max_x then
      x = new_x
    else
      local new_y = y + step
      if y < max_y and new_y < max_y then
        x = self.left_top.x + starting_offset.x
        y = new_y
      else
        return nil
      end
    end

    return { x = x, y = y }
  end
end

--- @deprecated Use `bounding-box` instead.
function flib_area.load(area)
  if not area.left_top then
    area = flib_area.from_shorthand(area)
  end
  return setmetatable(area, { __index = flib_area })
end

--- @deprecated Use `bounding-box` instead.
function flib_area.move(self, delta)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  self.left_top.x = self.left_top.x + delta.x
  self.left_top.y = self.left_top.y + delta.y
  self.right_bottom.x = self.right_bottom.x + delta.x
  self.right_bottom.y = self.right_bottom.y + delta.y

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.rotate(self)
  -- save current properties
  local center = flib_area.center(self)
  local height = flib_area.height(self)
  local width = flib_area.width(self)

  local radius_x = height / 2
  local radius_y = width / 2

  self.left_top.x = center.x - radius_x
  self.right_bottom.x = center.x + radius_x

  self.left_top.y = center.y - radius_y
  self.right_bottom.y = center.y + radius_y

  return self
end

--- @deprecated Use `bounding-box` instead.
function flib_area.square(self)
  local radius = math.max(flib_area.height(self), flib_area.width(self))

  return flib_area.from_dimensions({ height = radius, width = radius }, flib_area.center(self))
end

--- @deprecated Use `bounding-box` instead.
function flib_area.strip(self)
  return {
    left_top = {
      x = self.left_top.x,
      y = self.left_top.y,
    },
    right_bottom = {
      x = self.right_bottom.x,
      y = self.right_bottom.y,
    },
  }
end

--- @deprecated Use `bounding-box` instead.
function flib_area.to_shorthand(self)
  if not self.left_top then
    return self
  end

  return {
    { self.left_top.x, self.left_top.y },
    { self.right_bottom.x, self.right_bottom.y },
  }
end

--- @deprecated Use `bounding-box` instead.
function flib_area.width(self)
  if not self.left_top then
    self = flib_area.from_shorthand(self)
  end

  return math.abs(self.right_bottom.x - self.left_top.x)
end

return flib_area
