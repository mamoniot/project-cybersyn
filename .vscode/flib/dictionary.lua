local gui = require("__flib__/gui-lite")
local mod_gui = require("__core__/lualib/mod-gui")
local table = require("__flib__/table")

--- @diagnostic disable
--- @deprecated Use 'dictionary-lite' instead.
local flib_dictionary = {}

local inner_separator = "" -- U+E000
local separator = "" -- U+E001
local translation_timeout = 600

-- Depending on the value of `use_local_storage`, this will be tied to `global` or will be re-generated during `on_load`
local raw = { _total_strings = 0 }

local use_local_storage = false

local function key_value(key, value)
  return key .. inner_separator .. value .. separator
end

local RawDictionary = {}

--- @deprecated Use 'dictionary-lite' instead.
function RawDictionary:add(internal, translation)
  local to_add = { "", internal, inner_separator, { "?", translation, "FLIB_TRANSLATION_FAILED" }, separator }

  local ref = self.ref
  local i = self.batch_i + 1
  -- Due to network saturation concerns, only group five strings together
  -- See https://github.com/factoriolib/flib/issues/45
  if i < 5 then
    ref[i] = to_add --- @diagnostic disable-line
    self.batch_i = i
  else
    local s_i = self.dict_i + 1
    self.dict_i = s_i
    local new_set = { "", to_add }
    self.ref = new_set
    self.strings[s_i] = new_set
    self.batch_i = 2
  end
  self.total = self.total + 1
  raw._total_strings = raw._total_strings + 1
end

--- @class RawDictionary
function flib_dictionary.new(name, keep_untranslated, initial_contents)
  if raw[name] then
    error("Dictionary with the name `" .. name .. "` already exists.")
  end

  --- @type LocalisedString
  local initial_string = { "" }
  --- @class RawDictionary
  local self = {
    -- Indices
    batch_i = 1,
    dict_i = 1,
    total = 1,
    -- Internal
    ref = initial_string,
    --- @type LocalisedString
    strings = { initial_string },
    -- Meta
    name = name,
  }
  setmetatable(self, { __index = RawDictionary })

  for key, value in pairs(initial_contents or {}) do
    self:add(key, value)
  end
  --- @diagnostic disable-next-line
  raw[name] = { strings = self.strings, keep_untranslated = keep_untranslated }

  return self
end

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.init()
  if not global.__flib then
    global.__flib = {}
  end
  global.__flib.dictionary = {
    in_process = {},
    players = {},
    raw = { _total_strings = 0 },
    translated = {},
  }
  if use_local_storage then
    raw = { _total_strings = 0 }
  else
    raw = global.__flib.dictionary.raw
  end
end

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.load()
  if not use_local_storage and global.__flib and global.__flib.dictionary then
    raw = global.__flib.dictionary.raw
  end
end

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.translate(player)
  if not player.connected then
    error("Player must be connected to the game before this function can be called!")
  end

  local player_data = global.__flib.dictionary.players[player.index]
  if player_data then
    return
  end
  global.__flib.dictionary.players[player.index] = {
    player = player,
    status = "get_language",
    requested_tick = game.tick,
  }

  player.request_translation({ "", "FLIB_LOCALE_IDENTIFIER", separator, { "locale-identifier" } })
end

local function request_translation(player_data)
  local string = raw[player_data.dictionary].strings[player_data.i]

  -- We use `while` instead of `if` here just in case a dictionary doesn't have any strings in it
  while not string do
    local next_dictionary = next(raw, player_data.dictionary)
    if next_dictionary then
      -- Set the next dictionary and reset index
      player_data.dictionary = next_dictionary
      player_data.i = 1
      string = raw[next_dictionary].strings[1]
    else
      -- We're done!
      player_data.status = "finished"
      return
    end
  end

  player_data.player.request_translation({
    "",
    key_value("FLIB_DICTIONARY_MOD", script.mod_name),
    key_value("FLIB_DICTIONARY_NAME", player_data.dictionary),
    key_value("FLIB_DICTIONARY_LANGUAGE", player_data.language),
    key_value("FLIB_DICTIONARY_STRING_INDEX", player_data.i),
    string,
  })

  player_data.requested_tick = game.tick
end

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.check_skipped()
  local script_data = global.__flib.dictionary
  local tick = game.tick
  for _, player_data in pairs(script_data.players) do
    -- If it's been longer than the timeout, request the string again
    -- This is to solve a very rare edge case where translations requested on the same tick that a singleplayer game
    -- is saved will not be returned when that save is loaded
    if (player_data.requested_tick or 0) + translation_timeout <= tick then
      if player_data.status == "get_language" then
        player_data.player.request_translation({ "", "FLIB_LOCALE_IDENTIFIER", separator, { "locale-identifier" } })
      end
      if player_data.status == "translating" then
        request_translation(player_data)
      end
    end
  end
end

--- Escape match special characters
local function match_literal(s)
  return string.gsub(s, "%-", "%%-")
end

--- @param dict_lang string
local function clean_gui(dict_lang)
  for _, player in pairs(game.players) do
    local window = mod_gui.get_frame_flow(player).flib_translation_progress
    if window then
      local pane = window.pane
      local mod_flow = pane[script.mod_name]
      if mod_flow then
        local lang_flow = mod_flow[dict_lang]
        if lang_flow then
          lang_flow.destroy()
        end
        if #mod_flow.children == 1 then
          mod_flow.destroy()
        end
      end
      if #pane.children == 0 then
        window.destroy()
      end
    end
  end
end

local dictionary_match_string = key_value("^FLIB_DICTIONARY_MOD", match_literal(script.mod_name))
  .. key_value("FLIB_DICTIONARY_NAME", "(.-)")
  .. key_value("FLIB_DICTIONARY_LANGUAGE", "(.-)")
  .. key_value("FLIB_DICTIONARY_STRING_INDEX", "(%d-)")
  .. "(.*)$"

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.process_translation(event_data)
  if not event_data.translated then
    return
  end
  local script_data = global.__flib.dictionary
  if string.find(event_data.result, "FLIB_DICTIONARY_NAME") then
    local _, _, dict_name, dict_lang, string_index, translation =
      string.find(event_data.result, dictionary_match_string)

    if dict_name and dict_lang and string_index and translation then
      local language_data = script_data.in_process[dict_lang]
      -- In some cases, this can fire before on_configuration_changed
      if not language_data then
        return
      end
      local dictionary = language_data.dictionaries[dict_name]
      if not dictionary then
        return
      end
      local dict_data = raw[dict_name]
      local player_data = script_data.players[event_data.player_index]

      -- If this number does not match, this is a duplicate, so ignore it
      if tonumber(string_index) == player_data.i then
        -- Extract current string's translations
        for str in string.gmatch(translation, "(.-)" .. separator) do
          local _, _, key, value = string.find(str, "^(.-)" .. inner_separator .. "(.-)$")
          if key then
            -- If `keep_untranslated` is true, then use the key as the value if it failed
            local failed = string.find(value, "FLIB_TRANSLATION_FAILED")
            if failed and dict_data.keep_untranslated then
              value = key
            elseif failed then
              value = nil
            end
            if value then
              dictionary[key] = value
            end
            language_data.translated_i = language_data.translated_i + 1
          end
        end

        -- Request next translation
        player_data.i = player_data.i + 1
        request_translation(player_data)

        -- GUI
        for _, player in pairs(game.players) do
          --- @type LuaGuiElement
          local flow = mod_gui.get_frame_flow(player)
          if not flow.flib_translation_progress then
            gui.add(flow, {
              type = "frame",
              name = "flib_translation_progress",
              style = mod_gui.frame_style,
              style_mods = { width = 350 },
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
          local pane = flow.flib_translation_progress.pane --[[@as LuaGuiElement]]
          if not pane[script.mod_name] then
            gui.add(pane, {
              type = "flow",
              name = script.mod_name,
              direction = "vertical",
              { type = "label", style = "caption_label", style_mods = { top_margin = 4 }, caption = script.mod_name },
            })
          end
          local mod_flow = pane[script.mod_name] --[[@as LuaGuiElement]]
          if not mod_flow[dict_lang] then
            gui.add(mod_flow, {
              type = "flow",
              name = dict_lang,
              style_mods = { vertical_align = "center", horizontal_spacing = 8 },
              { type = "label", style = "bold_label", caption = dict_lang },
              { type = "progressbar", name = "bar", style_mods = { horizontally_stretchable = true } },
              { type = "label", name = "label", style = "bold_label" },
            })
          end
          local progress = language_data.translated_i / raw._total_strings
          mod_flow[dict_lang].bar.value = progress --[[@as double]]
          mod_flow[dict_lang].label.caption = tostring(math.ceil(progress * 100)) .. "%"
          mod_flow[dict_lang].label.tooltip = dict_name
            .. "\n"
            .. language_data.translated_i
            .. " / "
            .. raw._total_strings
        end

        if player_data.status == "finished" then
          -- Clean up translation data
          script_data.translated[dict_lang] = language_data.dictionaries
          script_data.in_process[dict_lang] = nil
          for _, player_index in pairs(language_data.players) do
            script_data.players[player_index] = nil
          end

          -- Clean up GUI
          clean_gui(dict_lang)

          return { dictionaries = language_data.dictionaries, language = dict_lang, players = language_data.players }
        end
      end
    end
  elseif string.find(event_data.result, "^FLIB_LOCALE_IDENTIFIER") then
    local _, _, language = string.find(event_data.result, "^FLIB_LOCALE_IDENTIFIER" .. separator .. "(.*)$")
    if language then
      local player_data = script_data.players[event_data.player_index]
      -- Handle duplicates
      if not player_data or player_data.status ~= "get_language" then
        return
      end

      player_data.language = language

      -- Check if this language is already translated or being translated
      local dictionaries = script_data.translated[language]
      if dictionaries then
        script_data.players[event_data.player_index] = nil
        return { dictionaries = dictionaries, language = language, players = { event_data.player_index } }
      end
      local in_process = script_data.in_process[language]
      if in_process then
        table.insert(in_process.players, event_data.player_index)
        player_data.status = "waiting"
        return
      end

      -- Set up player data for translating
      player_data.status = "translating"
      player_data.dictionary = next(raw, "_total_strings")
      player_data.i = 1

      -- Add language to in process data
      script_data.in_process[language] = {
        dictionaries = table.map(raw, function(_, k)
          if k ~= "_total_strings" then
            return {}
          end
        end),
        players = { event_data.player_index },
        translated_i = 0,
      }

      -- Start translating
      request_translation(player_data)
    end
  end
end

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.cancel_translation(player_index)
  local script_data = global.__flib.dictionary
  local player_data = script_data.players[player_index]
  if not player_data then
    return
  end
  -- Delete this player's data from global
  script_data.players[player_index] = nil

  local in_process = script_data.in_process[player_data.language]
  if not in_process then
    return
  end

  -- Remove this player from the players table
  local i = table.find(in_process.players, player_index)
  if i then
    table.remove(in_process.players, i)
  end

  if player_data.status ~= "translating" then
    return
  end

  -- Find the next player in the list with valid data
  local next_player_data
  for _, player_index in pairs(in_process.players) do
    local player_data = script_data.players[player_index]
    if player_data then
      next_player_data = player_data
      break
    end
  end
  -- If there are no more valid players
  if not next_player_data then
    -- Completely cancel the translation
    script_data.in_process[player_data.language] = nil
    clean_gui(player_data.language)
    return
  end
  --Update player info
  next_player_data.status = "translating"
  next_player_data.dictionary = player_data.dictionary
  next_player_data.i = player_data.i
  -- Resume translating with the new player
  request_translation(next_player_data)
end

--- @deprecated Use 'dictionary-lite' instead.
function flib_dictionary.set_use_local_storage(value)
  use_local_storage = value
end

return flib_dictionary
