local gui = require("__flib__/gui-lite")
local mod_gui = require("__core__/lualib/mod-gui")
local table = require("__flib__/table")

--- Utilities for creating dictionaries of localised string translations.
--- @class flib_dictionary
local flib_dictionary = {}

local request_timeout_ticks = (60 * 5)

--- @param init_only boolean?
--- @return flib_dictionary_global
local function get_data(init_only)
  if not global.__flib or not global.__flib.dictionary then
    error("Dictionary module was not properly initialized - ensure that all lifecycle events are handled.")
  end
  local data = global.__flib.dictionary
  if init_only and data.init_ran then
    error("Dictionaries cannot be modified after initialization.")
  end
  return data
end

--- @param data flib_dictionary_global
--- @param language string
--- @return LuaPlayer?
local function get_translator(data, language)
  for player_index, player_language in pairs(data.player_languages) do
    if player_language == language then
      local player = game.get_player(player_index)
      if player and player.connected then
        return player
      end
    end
  end
  -- There is no available translator, so remove this language from the pool
  for player_index, player_language in pairs(data.player_languages) do
    if player_language == language then
      data.player_languages[player_index] = nil
    end
  end
end

--- @param data flib_dictionary_global
local function update_gui(data)
  local wip = data.wip
  for _, player in pairs(game.players) do
    local frame_flow = mod_gui.get_frame_flow(player)
    local window = frame_flow.flib_translation_progress
    if wip then
      if not window then
        _, window = gui.add(frame_flow, {
          type = "frame",
          name = "flib_translation_progress",
          style = mod_gui.frame_style,
          direction = "vertical",
          {
            type = "label",
            style = "frame_title",
            caption = { "gui.flib-translating-dictionaries" },
            tooltip = { "gui.flib-translating-dictionaries-description" },
          },
          {
            type = "frame",
            name = "pane",
            style = "inside_shallow_frame_with_padding",
            style_mods = { top_padding = 8 },
            direction = "vertical",
          },
        })
      end
      local pane = window.pane --[[@as LuaGuiElement]]
      local mod_flow = pane[script.mod_name]
      if not mod_flow then
        _, mod_flow = gui.add(pane, {
          type = "flow",
          name = script.mod_name,
          style = "centering_horizontal_flow",
          style_mods = { top_margin = 4, horizontal_spacing = 8 },
          {
            type = "label",
            style = "caption_label",
            style_mods = { minimal_width = 130 },
            caption = { "?", { "mod-name." .. script.mod_name }, script.mod_name },
            ignored_by_interaction = true,
          },
          { type = "empty-widget", style = "flib_horizontal_pusher" },
          { type = "label", name = "language", style = "bold_label", ignored_by_interaction = true },
          {
            type = "progressbar",
            name = "bar",
            style_mods = { top_margin = 1, width = 100 },
            ignored_by_interaction = true,
          },
          {
            type = "label",
            name = "percentage",
            style = "bold_label",
            style_mods = { width = 24, horizontal_align = "right" },
            ignored_by_interaction = true,
          },
        })
      end
      local progress = wip.received_count / data.raw_count
      mod_flow.language.caption = wip.language
      mod_flow.bar.value = progress --[[@as double]]
      mod_flow.percentage.caption = tostring(math.min(math.floor(progress * 100), 99)) .. "%"
      mod_flow.tooltip =
        { "", (wip.dict or { "gui.flib-finishing" }), "\n" .. wip.received_count .. " / " .. data.raw_count }
    else
      if window then
        local mod_flow = window.pane[script.mod_name]
        if mod_flow then
          mod_flow.destroy()
        end
        if #window.pane.children == 0 then
          window.destroy()
        end
      end
    end
  end
end

--- @param data flib_dictionary_global
--- @return boolean success
local function request_next_batch(data)
  local raw = data.raw
  local wip = data.wip --[[@as DictWipData]]
  if wip.finished then
    return false
  end
  local requests, strings = {}, {}
  for i = 1, game.is_multiplayer() and 5 or 50 do
    local string
    repeat
      wip.key, string = next(raw[wip.dict], wip.key)
      if not wip.key then
        wip.dict = next(raw, wip.dict)
        if not wip.dict then
          -- We are done!
          wip.finished = true
        end
      end
    until string or wip.finished
    if wip.finished then
      break
    end
    requests[i] = { dict = wip.dict, key = wip.key }
    strings[i] = string
  end

  if #strings == 0 then
    return false -- Finished
  end

  local translator = wip.translator
  if not translator.valid or not translator.connected then
    local new_translator = get_translator(data, wip.language)
    if new_translator then
      wip.translator = new_translator
    else
      -- Cancel this translation
      data.wip = nil
      return false
    end
  end

  local ids = wip.translator.request_translations(strings)
  if not ids then
    return false
  end
  for i = 1, #ids do
    wip.requests[ids[i]] = requests[i]
  end
  wip.request_tick = game.tick

  update_gui(data)

  return true
end

--- @param data flib_dictionary_global
local function handle_next_language(data)
  while not data.wip and #data.to_translate > 0 do
    local next_language = table.remove(data.to_translate, 1)
    if next_language then
      local translator = get_translator(data, next_language)
      if translator then
        -- Start translation
        local dicts = {}
        local first_dict
        for name in pairs(data.raw) do
          first_dict = first_dict or name
          dicts[name] = {}
        end
        -- Don't do anything if there are no dictionaries to translate
        if not first_dict then
          return
        end
        --- @class DictWipData
        data.wip = {
          dict = first_dict,
          dicts = dicts,
          finished = false,
          --- @type string?
          key = nil,
          language = next_language,
          received_count = 0,
          --- @type table<uint, DictTranslationRequest>
          requests = {},
          request_tick = 0,
          translator = translator,
        }
      end
    end
  end
end

-- Events

flib_dictionary.on_player_dictionaries_ready = script.generate_event_name()
--- Called when a player's dictionaries are ready to be used. Handling this event is not required.
--- @class EventData.on_player_dictionaries_ready: EventData
--- @field player_index uint

flib_dictionary.on_player_language_changed = script.generate_event_name()
--- Called when a player's language changes. Handling this event is not required.
--- @class EventData.on_player_language_changed: EventData
--- @field player_index uint
--- @field language string

-- Lifecycle handlers

function flib_dictionary.on_init()
  -- Initialize global data
  if not global.__flib then
    global.__flib = {}
  end
  --- @class flib_dictionary_global
  global.__flib.dictionary = {
    init_ran = false,
    --- @type table<uint, string>
    player_languages = {},
    --- @type table<uint, DictLangRequest>
    player_language_requests = {},
    --- @type table<string, Dictionary>
    raw = {},
    raw_count = 0,
    --- @type string[]
    to_translate = {},
    --- @type table<string, table<string, TranslatedDictionary>>
    translated = {},
    --- @type DictWipData?
    wip = nil,
  }
  -- Initialize all existing players
  for player_index, player in pairs(game.players) do
    if player.connected then
      flib_dictionary.on_player_joined_game({
        --- @cast player_index uint
        player_index = player_index,
      })
    end
  end
end

flib_dictionary.on_configuration_changed = flib_dictionary.on_init

function flib_dictionary.on_tick()
  local data = get_data()
  if not data.init_ran then
    data.init_ran = true
  end

  -- Player language requests
  for id, request in pairs(data.player_language_requests) do
    if game.tick - request.tick > request_timeout_ticks then
      local player = request.player
      if player.valid and player.connected then
        local id = player.request_translation({ "locale-identifier" })
        if id then
          data.player_language_requests[id] = {
            player = player,
            tick = game.tick,
          }
        end
      end
      -- Deletion must be last so that the deleted entry isn't re-used for the new entry in memory
      data.player_language_requests[id] = nil
    end
  end

  local wip = data.wip
  if not wip then
    return
  end

  if game.tick - wip.request_tick > request_timeout_ticks then
    -- next() will return the first string from the last batch because it was inserted first
    local _, request = next(wip.requests)
    wip.dict = request.dict
    wip.finished = false
    wip.key = request.key
    wip.requests = {}
    request_next_batch(data)
    update_gui(data)
  end
end

--- @param e EventData.on_string_translated
function flib_dictionary.on_string_translated(e)
  local data = get_data()
  local id = e.id

  -- Player language requests
  local request = data.player_language_requests[id]
  if request then
    data.player_language_requests[id] = nil
    if not e.translated then
      error("Language key request for player " .. e.player_index .. " failed")
    end
    if data.player_languages[e.player_index] ~= e.result then
      data.player_languages[e.player_index] = e.result
      script.raise_event(
        flib_dictionary.on_player_language_changed,
        { player_index = e.player_index, language = e.result }
      )
      if data.translated[e.result] then
        script.raise_event(flib_dictionary.on_player_dictionaries_ready, { player_index = e.player_index })
        return
      elseif data.wip and data.wip.language == e.result then
        return
      elseif table.find(data.to_translate, e.result) then
        return
      else
        table.insert(data.to_translate, e.result)
      end
    end
  end

  handle_next_language(data)

  local wip = data.wip
  if not wip then
    return
  end

  local request = wip.requests[id]
  if request then
    wip.requests[id] = nil
    wip.received_count = wip.received_count + 1
    if e.translated then
      wip.dicts[request.dict][request.key] = e.result
    end
  end

  while wip and table_size(wip.requests) == 0 and not request_next_batch(data) do
    if wip.finished then
      data.translated[wip.language] = wip.dicts
      data.wip = nil
      for player_index, language in pairs(data.player_languages) do
        if wip.language == language then
          script.raise_event(flib_dictionary.on_player_dictionaries_ready, { player_index = player_index })
        end
      end
    end
    handle_next_language(data)
    update_gui(data)
    wip = data.wip
  end
end

--- @param e EventData.on_player_joined_game
function flib_dictionary.on_player_joined_game(e)
  -- Request the player's locale identifier
  local player = game.get_player(e.player_index) --[[@as LuaPlayer]]
  local id = player.request_translation({ "locale-identifier" })
  if not id then
    return
  end
  local data = get_data()
  data.player_language_requests[id] = {
    player = player,
    tick = game.tick,
  }
  update_gui(data)
end

--- Handle all non-bootstrap events with default event handlers. Will not overwrite any existing handlers. If you have
--- custom handlers for on_tick, on_string_translated, or on_player_joined_game, ensure that you call the corresponding
--- module lifecycle handler..
function flib_dictionary.handle_events()
  for id, handler in pairs({
    [defines.events.on_tick] = flib_dictionary.on_tick,
    [defines.events.on_string_translated] = flib_dictionary.on_string_translated,
    [defines.events.on_player_joined_game] = flib_dictionary.on_player_joined_game,
  }) do
    if
      not script.get_event_handler(id --[[@as uint]])
    then
      script.on_event(id, handler)
    end
  end
end

-- Dictionary creation

--- Create a new dictionary. The name must be unique.
--- @param name string
--- @param initial_strings Dictionary?
function flib_dictionary.new(name, initial_strings)
  local raw = get_data(true).raw
  if raw[name] then
    error("Attempted to create dictionary '" .. name .. "' twice.")
  end
  raw[name] = initial_strings or {}
end

--- Add the given string to the dictionary.
--- @param dict_name string
--- @param key string
--- @param localised LocalisedString
function flib_dictionary.add(dict_name, key, localised)
  local data = get_data(true)
  local raw = data.raw[dict_name]
  if not raw then
    error("Dictionary '" .. dict_name .. "' does not exist.")
  end
  if not raw[key] then
    data.raw_count = data.raw_count + 1
  end
  raw[key] = localised
end

--- Get all dictionaries for the player. Will return `nil` if the player's language has not finished translating.
--- @param player_index uint
--- @return table<string, TranslatedDictionary>?
function flib_dictionary.get_all(player_index)
  local data = get_data()
  local language = data.player_languages[player_index]
  if not language then
    return
  end
  return data.translated[language]
end

--- Get the specified dictionary for the player. Will return `nil` if the dictionary has not finished translating.
--- @param player_index uint
--- @param dict_name string
--- @return TranslatedDictionary?
function flib_dictionary.get(player_index, dict_name)
  local data = get_data()
  if not data.raw[dict_name] then
    error("Dictionary '" .. dict_name .. "' does not exist.")
  end
  local language_dicts = flib_dictionary.get_all(player_index) or {}
  return language_dicts[dict_name]
end

--- @class DictLangRequest
--- @field player LuaPlayer
--- @field tick uint

--- @class DictTranslationRequest
--- @field language string
--- @field dict string
--- @field key string

--- Localised strings identified by an internal key. Keys must be unique and language-agnostic.
--- @alias Dictionary table<string, LocalisedString>

--- Translations are identified by their internal key. If the translation failed, then it will not be present. Locale
--- fallback groups can be used if every key needs a guaranteed translation.
--- @alias TranslatedDictionary table<string, string>

return flib_dictionary
