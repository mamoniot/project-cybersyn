--- @diagnostic disable

local mod_name = script.mod_name
local gui_event_defines = {}

local event_id_to_string_mapping = {}
for name, id in pairs(defines.events) do
  if string.find(name, "^on_gui") then
    gui_event_defines[name] = id
    event_id_to_string_mapping[id] = string.gsub(name, "^on_gui", "on")
  end
end

--- @deprecated use `gui-lite` instead
local flib_gui = {}

--- @deprecated use `gui-lite` instead
function flib_gui.hook_events(callback)
  local on_event = script.on_event
  for _, id in pairs(gui_event_defines) do
    on_event(id, callback)
  end
end

--- @deprecated use `gui-lite` instead
function flib_gui.read_action(event_data)
  local elem = event_data.element
  if not elem or not elem.valid then
    return
  end

  local mod_tags = elem.tags[mod_name]
  if not mod_tags then
    return
  end

  local elem_actions = mod_tags.flib
  if not elem_actions then
    return
  end

  local event_name = event_id_to_string_mapping[event_data.name]
  local msg = elem_actions[event_name]

  return msg
end

--- @deprecated use `gui-lite` instead
local function recursive_build(parent, structure, refs)
  -- If the structure has no type, just ignore it
  -- This is to make it possible to pass unit types `{}` to represent "no element" without breaking things
  if not structure.type then
    return
  end

  -- Prepare tags
  local original_tags = structure.tags
  local tags = original_tags or {}
  local actions = structure.actions
  local tags_flib = tags.flib
  tags.flib = actions
  structure.tags = { [mod_name] = tags }

  -- Make the game not convert these into a property tree for no reason
  structure.actions = nil
  -- Substructures can be defined in special tables or as the array portion of this structure
  local substructures
  local substructures_len = #structure
  if substructures_len > 0 then
    if structure.children or structure.tabs then
      error("Children or tab-and-content pairs must ALL be in the array portion, or a subtable. Not both at once!")
    end
    substructures = {}
    for i = 1, substructures_len do
      substructures[i] = structure[i]
      structure[i] = nil
    end
  else
    substructures = structure.children or structure.tabs
    structure.children = nil
    structure.tabs = nil
  end

  -- Create element
  local elem = parent.add(structure)

  -- Restore structure
  structure.tags = original_tags
  structure.actions = actions
  tags.flib = tags_flib

  local style_mods = structure.style_mods
  if style_mods then
    for k, v in pairs(style_mods) do
      elem.style[k] = v
    end
  end

  local elem_mods = structure.elem_mods
  if elem_mods then
    for k, v in pairs(elem_mods) do
      elem[k] = v
    end
  end

  local ref = structure.ref
  if ref then
    -- Recursively create tables as needed
    local prev = refs
    local ref_length = #ref
    for i = 1, ref_length - 1 do
      local current_key = ref[i]
      local current = prev[current_key]
      if not current then
        current = {}
        prev[current_key] = current
      end
      prev = current
    end
    prev[ref[ref_length]] = elem
  end

  -- Substructures
  if substructures then
    if structure.type == "tabbed-pane" then
      local add_tab = elem.add_tab
      for i = 1, #substructures do
        local tab_and_content = substructures[i]
        if not (tab_and_content.tab and tab_and_content.content) then
          error("TabAndContent must have `tab` and `content` fields")
        end
        local tab = recursive_build(elem, tab_and_content.tab, refs)
        local content = recursive_build(elem, tab_and_content.content, refs)
        add_tab(tab, content)
      end
    else
      for i = 1, #substructures do
        recursive_build(elem, substructures[i], refs)
      end
    end
  end

  return elem
end

--- @deprecated use `gui-lite` instead
function flib_gui.build(parent, structures)
  local refs = {}
  for i = 1, #structures do
    recursive_build(parent, structures[i], refs)
  end
  return refs
end

--- @deprecated use `gui-lite` instead
function flib_gui.add(parent, structure)
  -- Just in case they had a ref in the structure already, extract it
  local previous_ref = structure.ref
  -- Put in a known ref that we can use later
  structure.ref = { "FLIB_ADD_ROOT" }
  -- Build the element
  local refs = {}
  recursive_build(parent, structure, refs)
  -- Restore the previous ref
  structure.ref = previous_ref
  -- Return the element
  return refs.FLIB_ADD_ROOT
end

--- @deprecated use `gui-lite` instead
local function recursive_update(elem, updates)
  if updates.cb then
    updates.cb(elem)
  end

  if updates.style then
    elem.style = updates.style
  end

  if updates.style_mods then
    for key, value in pairs(updates.style_mods) do
      elem.style[key] = value
    end
  end

  if updates.elem_mods then
    for key, value in pairs(updates.elem_mods) do
      elem[key] = value
    end
  end

  if updates.tags then
    flib_gui.update_tags(elem, updates.tags)
  end

  -- TODO: This could be a lot better
  if updates.actions then
    for event_name, payload in pairs(updates.actions) do
      flib_gui.set_action(elem, event_name, payload)
    end
  end

  local substructures
  local substructures_len = #updates
  if substructures_len > 0 then
    if updates.children or updates.tabs then
      error("Children or tab-and-content pairs must ALL be in the array portion, or a subtable. Not both at once!")
    end
    substructures = {}
    for i = 1, substructures_len do
      substructures[i] = updates[i]
      updates[i] = nil
    end
  else
    substructures = updates.children or updates.tabs
    updates.children = nil
    updates.tabs = nil
  end
  local subelements
  if elem.type == "tabbed-pane" then
    subelements = elem.tabs
  else
    subelements = elem.children
  end

  if substructures then
    for i, substructure in pairs(substructures) do
      if substructure.tab or substructure.content then
        local elem_tab_and_content = subelements[i]
        if elem_tab_and_content then
          local tab = elem_tab_and_content.tab
          local tab_updates = substructures.tab
          if tab and tab_updates then
            recursive_update(tab, tab_updates)
          end
          local content = elem_tab_and_content.content
          local content_updates = substructures.content
          if content and content_updates then
            recursive_update(content, content_updates)
          end
        end
      elseif subelements[i] then
        recursive_update(subelements[i], substructure)
      end
    end
  end
end

--- @deprecated use `gui-lite` instead
function flib_gui.update(elem, updates)
  recursive_update(elem, updates)
end

--- @deprecated use `gui-lite` instead
function flib_gui.get_tags(elem)
  return elem.tags[mod_name] or {}
end

--- @deprecated use `gui-lite` instead
function flib_gui.set_tags(elem, tags)
  local elem_tags = elem.tags
  elem_tags[mod_name] = tags
  elem.tags = elem_tags
end

--- @deprecated use `gui-lite` instead
function flib_gui.delete_tags(elem)
  local elem_tags = elem.tags
  elem_tags[mod_name] = nil
  elem.tags = elem_tags
end

--- @deprecated use `gui-lite` instead
function flib_gui.update_tags(elem, updates)
  local elem_tags = elem.tags
  local existing = elem_tags[mod_name]

  if not existing then
    existing = {}
    elem_tags[mod_name] = existing
  end

  for k, v in pairs(updates) do
    existing[k] = v
  end

  elem.tags = elem_tags
end

--- @deprecated use `gui-lite` instead
function flib_gui.set_action(elem, event_name, msg)
  local elem_tags = elem.tags
  local existing = elem_tags[mod_name]

  if not existing then
    existing = {}
    elem_tags[mod_name] = existing
  end

  local actions = existing.flib
  if not actions then
    actions = {}
    existing.flib = actions
  end

  actions[event_name] = msg or nil

  elem.tags = elem_tags
end

--- @deprecated use `gui-lite` instead
function flib_gui.get_action(elem, event_name)
  local elem_tags = elem.tags
  local existing = elem_tags[mod_name]

  if not existing then
    return
  end

  local actions = existing.flib
  if not actions then
    return
  end

  return actions[event_name]
end

return flib_gui
