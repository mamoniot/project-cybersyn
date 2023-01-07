--By Mami
---@param v string
---@param h string?
function once(v, h)
	return not h and v or nil--[[@as string|nil]]
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

---@generic V
---@param arr Array<V>
---@param comp fun(a: V, b: V) A comparison function for sorting. Must return truthy if `a < b`.
function stable_sort(arr, comp)
	local size = #arr
	for i = 2, size do
		local a = arr[i]
		local j = i
		while j > 1 do
			local b = arr[j - 1]
			if comp(a, b) then
				arr[j] = b
				j = j - 1
			else
				break
			end
		end
		arr[j] = a
	end
end

---@param values number[]
---@param keys any[]
function dual_sort(values, keys)
	local size = #values
	for i = 2, size do
		local a = values[i]
		local j = i
		while j > 1 do
			local b = values[j - 1]
			if a < b then
				values[j] = b
				keys[j] = keys[j - 1]
				j = j - 1
			else
				break
			end
		end
		values[j] = a
		keys[j] = keys[i]
	end
end
