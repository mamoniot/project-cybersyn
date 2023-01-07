--- Extension of the Lua 5.2 table library.
---
--- **NOTE:** Several functions in this module will only work with [arrays](https://www.lua.org/pil/11.1.html),
--- which are tables with sequentially numbered keys. All table functions will work with arrays as well, but
--- array functions **will not** work with tables.
--- @class flib_table: tablelib
local flib_table = {}

-- Import lua table functions
for name, func in pairs(table) do
  flib_table[name] = func
end

--- Shallow copy an array's values into a new array.
---
--- This function is optimized specifically for arrays, and should be used in place of `table.shallow_copy` for arrays.
--- @param arr Array
--- @return Array
function flib_table.array_copy(arr)
  local new_arr = {}
  for i = 1, #arr do
    new_arr[i] = arr[i]
  end
  return new_arr
end

--- Merge all of the given arrays into a single array.
--- @param arrays Array An array of arrays to merge.
--- @return Array
function flib_table.array_merge(arrays)
  local output = {}
  local i = 0
  for j = 1, #arrays do
    local arr = arrays[j]
    for k = 1, #arr do
      i = i + 1
      output[i] = arr[k]
    end
  end
  return output
end

--- Recursively compare two tables for inner equality.
---
--- Does not compare metatables.
--- @param tbl1 table
--- @param tbl2 table
--- @return boolean
function flib_table.deep_compare(tbl1, tbl2)
  if tbl1 == tbl2 then
    return true
  end
  for k, v in pairs(tbl1) do
    if type(v) == "table" and type(tbl2[k]) == "table" then
      if not flib_table.deep_compare(v, tbl2[k]) then
        return false
      end
    else
      if v ~= tbl2[k] then
        return false
      end
    end
  end
  for k in pairs(tbl2) do
    if tbl1[k] == nil then
      return false
    end
  end
  return true
end

--- Recursively copy the contents of a table into a new table.
---
--- Does not create new copies of Factorio objects.
--- @generic T
--- @param tbl T The table to make a copy of.
--- @return T
function flib_table.deep_copy(tbl)
  local lookup_table = {}
  local function _copy(object)
    if type(object) ~= "table" then
      return object
      -- don't copy factorio rich objects
    elseif object.__self then
      return object
    elseif lookup_table[object] then
      return lookup_table[object]
    end

    local new_table = {}
    lookup_table[object] = new_table
    for index, value in pairs(object) do
      new_table[_copy(index)] = _copy(value)
    end

    return setmetatable(new_table, getmetatable(object))
  end
  return _copy(tbl)
end

--- Recursively merge two or more tables.
---
--- Values from earlier tables are overwritten by values from later tables, unless both values are tables, in which case
--- they are recursively merged.
---
--- Non-merged tables are deep-copied, so the result is brand-new.
---
--- # Examples
---
--- ```lua
--- local tbl = {foo = "bar"}
--- log(tbl.foo) -- logs "bar"
--- log (tbl.bar) -- errors (key is nil)
--- tbl = table.merge{tbl, {foo = "baz", set = 3}}
--- log(tbl.foo) -- logs "baz"
--- log(tbl.bar) -- logs "3"
--- ```
--- @param tables Array An array of tables to merge.
--- @return table
function flib_table.deep_merge(tables)
  local output = {}
  for _, tbl in ipairs(tables) do
    for k, v in pairs(tbl) do
      if type(v) == "table" then
        if type(output[k] or false) == "table" then
          output[k] = flib_table.deep_merge({ output[k], v })
        else
          output[k] = flib_table.deep_copy(v)
        end
      else
        output[k] = v
      end
    end
  end
  return output
end

--- Find and return the first key containing the given value.
---
--- # Examples
---
--- ```lua
--- local tbl = {"foo", "bar"}
--- local key_of_foo = table.find(tbl, "foo") -- 1
--- local key_of_baz = table.find(tbl, "baz") -- nil
--- ```
--- @generic K, V
--- @param tbl table<K, V> The table to search.
--- @param value V The value to match. Must have an `eq` metamethod set, otherwise will error.
--- @return K? key The first key corresponding to `value`, if any.
function flib_table.find(tbl, value)
  for k, v in pairs(tbl) do
    if v == value then
      return k
    end
  end
end

--- Call the given function for each item in the table, and abort if the function returns truthy.
---
--- Calls `callback(value, key)` for each item in the table, and immediately ceases iteration if the callback returns truthy.
---
--- # Examples
---
--- ```lua
--- local tbl = {1, 2, 3, 4, 5}
--- -- Run a function for each item (identical to a standard FOR loop)
--- table.for_each(tbl, function(v) game.print(v) end)
--- -- Determine if any value in the table passes the test
--- local value_is_even = table.for_each(tbl, function(v) return v % 2 == 0 end)
--- -- Determine if ALL values in the table pass the test (invert the test result and function return)
--- local all_values_less_than_six = not table.for_each(tbl, function(v) return not (v < 6) end)
--- ```
--- @generic K, V
--- @param tbl table<K, V>
--- @param callback fun(value: V, key: K): boolean Receives `value` and `key` as parameters.
--- @return boolean Whether the callback returned truthy for any one item, and thus halted iteration.
function flib_table.for_each(tbl, callback)
  for k, v in pairs(tbl) do
    if callback(v, k) then
      return true
    end
  end
  return false
end

--- Call the given function on a set number of items in a table, returning the next starting key.
---
--- Calls `callback(value, key)` over `n` items from `tbl`, starting after `from_k`.
---
--- The first return value of each invocation of `callback` will be collected and returned in a table keyed by the
--- current item's key.
---
--- The second return value of `callback` is a flag requesting deletion of the current item.
---
--- The third return value of `callback` is a flag requesting that the iteration be immediately aborted. Use this flag to
--- early return on some condition in `callback`. When aborted, `for_n_of` will return the previous key as `from_k`, so
--- the next call to `for_n_of` will restart on the key that was aborted (unless it was also deleted).
---
--- **DO NOT** delete entires from `tbl` from within `callback`, this will break the iteration. Use the deletion flag
--- instead.
---
--- # Examples
---
--- ```lua
--- local extremely_large_table = {
---   [1000] = 1,
---   [999] = 2,
---   [998] = 3,
---   ...,
---   [2] = 999,
---   [1] = 1000,
--- }
--- event.on_tick(function()
---   global.from_k = table.for_n_of(extremely_large_table, global.from_k, 10, function(v) game.print(v) end)
--- end)
--- ```
--- @generic K, V, C
--- @param tbl table<K, V> The table to iterate over.
--- @param from_k K The key to start iteration at, or `nil` to start at the beginning of `tbl`. If the key does not exist in `tbl`, it will be treated as `nil`, _unless_ a custom `_next` function is used.
--- @param n number The number of items to iterate.
--- @param callback fun(value: V, key: K):C,boolean,boolean Receives `value` and `key` as parameters.
--- @param _next? fun(tbl: table<K, V>, from_k: K):K,V A custom `next()` function. If not provided, the default `next()` will be used.
--- @return K? next_key Where the iteration ended. Can be any valid table key, or `nil`. Pass this as `from_k` in the next call to `for_n_of` for `tbl`.
--- @return table<K, C> results The results compiled from the first return of `callback`.
--- @return boolean reached_end Whether or not the end of the table was reached on this iteration.
function flib_table.for_n_of(tbl, from_k, n, callback, _next)
  -- Bypass if a custom `next` function was provided
  if not _next then
    -- Verify start key exists, else start from scratch
    if from_k and not tbl[from_k] then
      from_k = nil
    end
    -- Use default `next`
    _next = next
  end

  local delete
  local prev
  local abort
  local result = {}

  -- Run `n` times
  for _ = 1, n, 1 do
    local v
    if not delete then
      prev = from_k
    end
    from_k, v = _next(tbl, from_k)
    if delete then
      tbl[delete] = nil
    end

    if from_k then
      result[from_k], delete, abort = callback(v, from_k)
      if delete then
        delete = from_k
      end
      if abort then
        break
      end
    else
      return from_k, result, true
    end
  end

  if delete then
    tbl[delete] = nil
    from_k = prev
  elseif abort then
    from_k = prev
  end
  return from_k, result, false
end

-- TODO: Remove array_insert, create separate array_filter function

--- Create a filtered version of a table based on the results of a filter function.
---
--- Calls `filter(value, key)` on each element in the table, returning a new table with only pairs for which
--- `filter` returned a truthy value.
---
--- # Examples
---
--- ```lua
--- local tbl = {1, 2, 3, 4, 5, 6}
--- local just_evens = table.filter(tbl, function(v) return v % 2 == 0 end) -- {[2] = 2, [4] = 4, [6] = 6}
--- local just_evens_arr = table.filter(tbl, function(v) return v % 2 == 0 end, true) -- {2, 4, 6}
--- ```
--- @generic K, V
--- @param tbl table<K, V>
--- @param filter fun(value: V, key: K): boolean
--- @param array_insert boolean? If true, the result will be constructed as an array of values that matched the filter. Key references will be lost.
--- @return table<K, V>
function flib_table.filter(tbl, filter, array_insert)
  local output = {}
  local i = 0
  for k, v in pairs(tbl) do
    if filter(v, k) then
      if array_insert then
        i = i + 1
        output[i] = v
      else
        output[k] = v
      end
    end
  end
  return output
end

--- Retrieve the value at the key, or insert the default value.
--- @generic K, V
--- @param table table<K, V>
--- @param key K
--- @param default_value V
--- @return V
function flib_table.get_or_insert(table, key, default_value)
  local value = table[key]
  if not value then
    table[key] = default_value
    return default_value
  end
  return value
end

--- Invert the given table such that `[value] = key`, returning a new table.
---
--- Non-unique values are overwritten based on the ordering from `pairs()`.
---
--- # Examples
---
--- ```lua
--- local tbl = {"foo", "bar", "baz", set = "baz"}
--- local inverted = table.invert(tbl) -- {foo = 1, bar = 2, baz = "set"}
--- ```
--- @generic K, V
--- @param tbl table<K, V>
--- @return table<V, K>
function flib_table.invert(tbl)
  local inverted = {}
  for k, v in pairs(tbl) do
    inverted[v] = k
  end
  return inverted
end

--- Create a transformed table using the output of a mapper function.
---
--- Calls `mapper(value, key)` on each element in the table, using the return as the new value for the key.
---
--- # Examples
---
--- ```lua
--- local tbl = {1, 2, 3, 4, 5}
--- local tbl_times_ten = table.map(tbl, function(v) return v * 10 end) -- {10, 20, 30, 40, 50}
--- ```
--- @generic K, V, N
--- @param tbl table<K, V>
--- @param mapper fun(value: V, key: V):N?
--- @return table<K, N>
function flib_table.map(tbl, mapper)
  local output = {}
  for k, v in pairs(tbl) do
    output[k] = mapper(v, k)
  end
  return output
end

local function default_comp(a, b)
  return a < b
end

--- Partially sort an array.
---
--- This function utilizes [insertion sort](https://en.wikipedia.org/wiki/Insertion_sort), which is _extremely_ inefficient with large data sets. However, you can spread the sorting over multiple ticks, reducing the performance impact. Only use this function if `table.sort` is too slow.
--- @generic V
--- @param arr Array<V>
--- @param from_index number? The index to start iteration at (inclusive). Pass `nil` or a number less than `2` to begin at the start of the array.
--- @param iterations number The number of iterations to perform. Higher is more performance-heavy. This number should be adjusted based on the performance impact of the custom `comp` function (if any) and the size of the array.
--- @param comp fun(a: V, b: V) A comparison function for sorting. Must return truthy if `a < b`.
--- @return number? next_index The index to start the next iteration at, or `nil` if the end was reached.
function flib_table.partial_sort(arr, from_index, iterations, comp)
  comp = comp or default_comp
  local start_index = (from_index and from_index > 2) and from_index or 2
  local end_index = start_index + (iterations - 1)

  for j = start_index, end_index do
    local key = arr[j]
    if not key then
      return nil
    end
    local i = j - 1

    while i > 0 and comp(key, arr[i]) do
      arr[i + 1] = arr[i]
      i = i - 1
    end

    arr[i + 1] = key
  end

  return end_index + 1
end

--- "Reduce" a table's values into a single output value, using the results of a reducer function.
---
--- Calls `reducer(accumulator, value, key)` on each element in the table, returning a single accumulated output value.
---
--- # Examples
---
--- ```lua
--- local tbl = {10, 20, 30, 40, 50}
--- local sum = table.reduce(tbl, function(acc, v) return acc + v end)
--- local sum_minus_ten = table.reduce(tbl, function(acc, v) return acc + v end, -10)
--- ```
--- @generic K, V, R
--- @param tbl table<K, V>
--- @param reducer fun(acc: R, value: V, key: K):R
--- @param initial_value R? The initial value for the accumulator. If not provided or is falsy, the first value in the table will be used as the initial `accumulator` value and skipped as `key`. Calling `reduce()` on an empty table without an `initial_value` will cause a crash.
--- @return R
function flib_table.reduce(tbl, reducer, initial_value)
  local accumulator = initial_value
  for key, value in pairs(tbl) do
    if accumulator then
      accumulator = reducer(accumulator, value, key)
    else
      accumulator = value
    end
  end
  return accumulator
end

--- @deprecated use `table.remove`.
flib_table.retrieve = flib_table.remove

--- Shallowly copy the contents of a table into a new table.
---
--- The parent table will have a new table reference, but any subtables within it will still have the same table
--- reference.
---
--- Does not copy metatables.
--- @generic T
--- @param tbl T
--- @param use_rawset boolean? Use rawset to set the values (ignores metamethods).
--- @return T The copied table.
function flib_table.shallow_copy(tbl, use_rawset)
  local output = {}
  for k, v in pairs(tbl) do
    if use_rawset then
      rawset(output, k, v)
    else
      output[k] = v
    end
  end
  return output
end

--- Shallowly merge two or more tables.
--- Unlike `table.deep_merge`, this will only combine the top level of the tables.
--- @param tables table[]
--- @return table
function flib_table.shallow_merge(tables)
  local output = {}
  for _, tbl in pairs(tables) do
    for key, value in pairs(tbl) do
      output[key] = value
    end
  end
  return output
end

--- Retrieve the size of a table.
---
--- Uses Factorio's built-in `table_size` function.
--- @type fun(tbl: table):number
flib_table.size = _ENV.table_size

--- Retrieve a shallow copy of a portion of an array, selected from `start` to `end` inclusive.
---
--- The original array **will not** be modified.
---
--- # Examples
---
--- ```lua
--- local arr = {10, 20, 30, 40, 50, 60, 70, 80, 90}
--- local sliced = table.slice(arr, 3, 7) -- {30, 40, 50, 60, 70}
--- log(serpent.line(arr)) -- {10, 20, 30, 40, 50, 60, 70, 80, 90} (unchanged)
--- ```
--- @generic V
--- @param arr Array<V>
--- @param start number? default: `1`
--- @param stop number? Stop at this index. If zero or negative, will stop `n` items from the end of the array (default: `#arr`).
--- @return Array<V> A new array with the copied values.
function flib_table.slice(arr, start, stop)
  local output = {}
  local n = #arr

  start = start or 1
  stop = stop or n
  stop = stop <= 0 and (n + stop) or stop

  if start < 1 or start > n then
    return {}
  end

  local k = 1
  for i = start, stop do
    output[k] = arr[i]
    k = k + 1
  end
  return output
end

--- Extract a portion of an array, selected from `start` to `end` inclusive.
--
--- The original array **will** be modified.
---
--- # Examples
---
--- ```lua
--- local arr = {10, 20, 30, 40, 50, 60, 70, 80, 90}
--- local spliced = table.splice(arr, 3, 7) -- {30, 40, 50, 60, 70}
--- log(serpent.line(arr)) -- {10, 20, 80, 90} (values were removed)
--- ```
--- @generic V
--- @param arr Array<V>
--- @param start number default: `1`
--- @param stop number? Stop at this index. If zero or negative, will stop `n` items from the end of the array (default: `#arr`).
--- @return Array<V> A new array with the extracted values.
function flib_table.splice(arr, start, stop)
  local output = {}
  local n = #arr

  start = start or 1
  stop = stop or n
  stop = stop <= 0 and (n + stop) or stop

  if start < 1 or start > n then
    return {}
  end

  local k = 1
  for _ = start, stop do
    output[k] = table.remove(arr, start)
    k = k + 1
  end
  return output
end

--- @class Array<T>: { [integer]: T }

return flib_table
