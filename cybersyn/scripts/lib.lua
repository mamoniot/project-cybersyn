local util = require "__core__.lualib.util"

--- A station combinator in any of its displays (plain, active, failed request).
---@param op ArithmeticCombinatorParameterOperation?
---@return boolean
function is_station_op(op)
	return op == MODE_PRIMARY_IO or op == MODE_PRIMARY_IO_ACTIVE or op == MODE_PRIMARY_IO_FAILED_REQUEST
end

--- An inventory combinator in either of its displays (plain, failed request).
---@param op ArithmeticCombinatorParameterOperation?
---@return boolean
function is_secondary_inventory_op(op)
	return op == MODE_SECONDARY_INVENTORY or op == MODE_SECONDARY_INVENTORY_FAILED
end

--- A station's threshold for one item, in items: its per-item override, else the stop's fluid or item threshold (a
--- nil fluid threshold means the item one). A stack station counts in stacks, fluids have none. Without bases it is
--- the override alone, or nil: how a provider's override is read.
---@param map_data MapData?
---@param station Station
---@param item_hash string
---@param item_name string
---@param item_type string
---@param base_item int?
---@param base_fluid int?
---@return int?
function get_item_threshold(map_data, station, item_hash, item_name, item_type, base_item, base_fluid)
	local thresholds = station.item_thresholds
	local threshold = thresholds and thresholds[item_hash] or item_type == "fluid" and base_fluid or base_item
	if threshold and station.is_stack and item_type == "item" then
		return threshold * get_stack_size(map_data, item_name)
	end
	return threshold
end

--By Mami
---@param v string
---@param h string?
function once(v, h)
	return not h and v or nil --[[@as string|nil]]
end
---@param t any[]
---@return any
function rnext_consume(t)
	local len = #t
	if len > 1 then
		local i = math.random(1, len)
		local v = t[i]
		t[i] = t[len]
		t[len] = nil
		return v
	else
		local v = t[1]
		t[1] = nil
		return v
	end
end

function table_compare(t0, t1)
	if #t0 ~= #t1 then
		return false
	end
	for i = 0, #t0 do
		if t0[i] ~= t1[i] then
			return false
		end
	end
	return true
end

---@param a any[]
---@param i uint
function irnext(a, i)
	i = i + 1
	if i <= #a then
		local r = a[#a - i + 1]
		return i, r
	else
		return nil, nil
	end
end

---@param a any[]
function irpairs(a)
	return irnext, a, 0
end

--- @generic K
--- @param t1 table<K, any>
--- @param t2 table<K, any>
--- @return fun(): K?
function dual_pairs(t1, t2)
	local state = true
	local key = nil
	return function()
		if state then
			key = next(t1, key)
			if key then
				return key
			end
			state = false
		end
		repeat
			key = next(t2, key)
		until t1[key] == nil
		return key
	end
end

---Filter an array by a predicate, creating a new array containing only those
---elements for which the predicate returns `true`.
---@generic T
---@param A T[]
---@param f fun(v: T): boolean
---@return T[]
function filter(A, f)
	local B = {}
	for i = 1, #A do
		local v = A[i]
		if f(v) then
			B[#B + 1] = v
		end
	end
	return B
end

--- @param count integer
--- @return string
function format_signal_count(count)
	local function si_format(divisor, si_symbol)
		if math.abs(math.floor(count / divisor)) >= 10 then
			count = math.floor(count / divisor)
			return string.format("%.0f%s", count, si_symbol)
		else
			count = math.floor(count / (divisor / 10)) / 10
			return string.format("%.1f%s", count, si_symbol)
		end
	end

	local abs = math.abs(count)
	return -- signals are 32bit integers so Giga is enough
			abs >= 1e9 and si_format(1e9, "G") or
			abs >= 1e6 and si_format(1e6, "M") or
			abs >= 1e3 and si_format(1e3, "k") or
			tostring(count)
end

---Concatenates the give numbers into a string separated by '|'.
---The same two numbers always produce the same string, no matter the order they are given in.
---@param number1 number
---@param number2 number
---@return string
function sorted_pair(number1, number2)
    return (number1 < number2) and (number1..'|'..number2) or (number2..'|'..number1)
end

--- Fetches a subtable from the given table or creates it if necessary
function get_or_create(a_table, subtable_key)
    local subtable = a_table[subtable_key]
    if not subtable then
        subtable = {}
        a_table[subtable_key] = subtable
    end
    return subtable
end

---Creates a GPS richtext tag from the given entity
---@param entity LuaEntity?
---@return string gpstag an empty string if entity is invalid
function gps_text(entity)
	if entity and entity.valid then
		return string.format("[gps=%s,%s,%s]", entity.position.x, entity.position.y, entity.surface.name )
	end
	return ""
end

---Creates a richtext link to the given entity: a stop tag (which shows the stop's name) for a train stop, otherwise
---a GPS tag followed by the entity's name
---@param entity LuaEntity
---@return LocalisedString
function entity_richtext(entity)
	if entity.type == "train-stop" then
		return "[train-stop=" .. entity.unit_number .. "]"
	end
	return { "", gps_text(entity), " ", entity.localised_name }
end

---Formats the given integer with prefix `0x` followed by exactly 8 hexadecimal digits
---@param network_id integer
function network_text(network_id)
	return string.format("0x%08X", bit32.band(network_id)) -- band ensures 32bits (the parameter might have more)
end

--- Networks of a station, refueler or train as (name, mask) pairs.
--- @param network_name string?
--- @param network_mask int|{[string]: int}?
--- @param fn fun(name: string, mask: int)
function each_network(network_name, network_mask, fn)
	if network_name == NETWORK_EACH then
		if type(network_mask) == "table" then
			for name, mask in pairs(network_mask) do fn(name, mask) end
		end
	elseif network_name then
		fn(network_name, type(network_mask) == "number" and network_mask or 0)
	end
end


-------------------------------------------------- simple class system ------------------------------------------------------
-- Adapted from "Programming in Lua" (PIL 16.2).
--
-- The method called "new" in the manual is called "derive" here because that better reflects its purpose.
-- 
-- "new" is used as the name of the constructor method that 
-- 1. creates instances via a call to the constructor of the superclass
-- 2. ensures the required fields are initialized before handing it to the caller

---Using classes works like this:
---
--- 1. Derive the new class from an existing class
---    ```
---    ---@class NewClass : Class
---    ---@field field1 string
---    NewClass = Class:derive()
---    ```
--- 2. Define a constructor for the new class that calls the super constructor (passing along parameters as necessary)
---    ```
---    ---@protected
---    ---@param param1 string
---    function NewClass:new(param1)
---        local instance = self:derive(Class:new()) -- the base constructor has no parameters
---        instance.field1 = param1
---        return instance
---    end 
---    ```
--- 3. Define new methods
---    ```
---    function NewClass:print()
---        print(string.format("Hello, %s", self.field1))
---    end 
---    ```
--- 4. Create an instance and use it
---    ```
---    local instance = NewClass:new("world")
---    instance:print()
---    ```
---@class Class
Class = {}

---Derives a new class or derives an instance of a class.
---
---```
---ChildClass = ParentClass:derive() -- variant A
---
---function ChildClass:new(param1, param2)
---    local instance = --[[variant B]] self:derive(ParentClass:new(param1))
---    instance.field2 = param2
---    return instance
---end
---```
---
---@generic T
---@param self T
---@param o table?
---@return T
---@protected
function Class:derive(o)
	self.__index = self
	return setmetatable(o or {}, self)
end

---Super constructor of all other constructors
---@protected
function Class:new()
    return {}
end