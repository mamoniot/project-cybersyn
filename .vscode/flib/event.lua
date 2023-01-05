--- @diagnostic disable
--- @deprecated use `script` directly
local flib_event = {}

for name, id in pairs(defines.events) do
  flib_event[name] = function(handler, filters)
    return script.on_event(id, handler, filters)
  end
end

--- @deprecated use `script` directly
function flib_event.on_init(handler) --
  script.on_init(handler)
end

--- @deprecated use `script` directly
function flib_event.on_load(handler) --
  script.on_load(handler)
end

--- @deprecated use `script` directly
function flib_event.on_configuration_changed(handler) --
  script.on_configuration_changed(handler)
end

--- @deprecated use `script` directly
function flib_event.on_nth_tick(nth_tick, handler) --
  if handler then
    script.on_nth_tick(nth_tick, handler)
  else
    script.on_nth_tick(nth_tick)
  end
end

--- @deprecated use `script` directly
function flib_event.register(ids, handler, filters) --
  if type(ids) ~= "table" then
    ids = { ids }
  end
  for i = 1, #ids do
    -- the game doesn't like you passing filters to events that don't support them, even if they're `nil`
    if filters then
      script.on_event(ids[i], handler, filters)
    else
      script.on_event(ids[i], handler)
    end
  end
end

--- @deprecated use `script` directly
function flib_event.register_on_entity_destroyed(entity) --
  return script.register_on_entity_destroyed(entity)
end

--- @deprecated use `script` directly
function flib_event.generate_id() --
  return script.generate_event_name()
end

--- @deprecated use `script` directly
function flib_event.get_handler(id) --
  return script.get_event_handler(id)
end

--- @deprecated use `script` directly
function flib_event.raise(id, event_data) --
  script.raise_event(id, event_data)
end

--- @deprecated use `script` directly
function flib_event.get_order() --
  return script.get_event_order()
end

--- @deprecated use `script` directly
function flib_event.set_filters(ids, filters) --
  if type(ids) ~= "table" then
    ids = { ids }
  end
  for i = 1, #ids do
    script.set_event_filter(ids[i], filters)
  end
end

--- @deprecated use `script` directly
function flib_event.get_filters(id) --
  script.get_event_filter(id)
end

return flib_event
