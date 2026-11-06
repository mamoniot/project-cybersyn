-- Minimal test runner: loads every tests/unit/*_test.lua in sorted order, runs each test() in a fresh harness
-- state and prints one line per failure plus a final "PASS n FAIL m".

local DIR = "tests/unit"
package.path = DIR .. "/?.lua;" .. package.path

local H = require("harness")

local tests = {}
local current_file

function test(name, fn)
	tests[#tests + 1] = { name = current_file .. ": " .. name, fn = fn }
end

local function deep_eq(a, b, path, seen)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false, path
	end
	seen = seen or {}
	if seen[a] == b then return true end
	seen[a] = b
	for k, v in pairs(a) do
		local ok, where = deep_eq(v, b[k], path .. "." .. tostring(k), seen)
		if not ok then return false, where end
	end
	for k in pairs(b) do
		if a[k] == nil then return false, path .. "." .. tostring(k) end
	end
	return true
end

local function fail(msg, detail)
	error((msg and (msg .. ": ") or "") .. detail, 3)
end

--- Deep equality for tables, == for everything else.
function assert_eq(actual, expected, msg)
	local ok, where = deep_eq(actual, expected, "")
	if not ok then
		fail(msg, "expected " .. H.serialize(expected) .. ", got " .. H.serialize(actual)
			.. ((where and where ~= "") and (" (first difference at " .. where .. ")") or ""))
	end
end

function assert_near(actual, expected, eps, msg)
	if type(actual) ~= "number" or math.abs(actual - expected) > (eps or 1e-9) then
		fail(msg, "expected ~" .. tostring(expected) .. ", got " .. tostring(actual))
	end
end

function assert_true(v, msg)
	if v ~= true then fail(msg, "expected true, got " .. H.serialize(v)) end
end

function assert_false(v, msg)
	if v ~= false then fail(msg, "expected false, got " .. H.serialize(v)) end
end

function assert_nil(v, msg)
	if v ~= nil then fail(msg, "expected nil, got " .. H.serialize(v)) end
end

function assert_not_nil(v, msg)
	if v == nil then fail(msg, "expected a value, got nil") end
end

--- Identity, for "the same table is kept" checks.
function assert_same(actual, expected, msg)
	if actual ~= expected then fail(msg, "expected the same object") end
end

function assert_error(fn, pattern, msg)
	local ok, err = pcall(fn)
	if ok then fail(msg, "expected an error") end
	if pattern and not string.find(tostring(err), pattern) then
		fail(msg, "error " .. tostring(err) .. " does not match " .. pattern)
	end
end

local files = {}
local p = io.popen("ls " .. DIR .. "/*_test.lua 2>/dev/null")
for line in p:lines() do files[#files + 1] = line end
p:close()
table.sort(files)

local load_failures = 0
for _, file in ipairs(files) do
	current_file = string.match(file, "([^/]+)%.lua$")
	local chunk, err = loadfile(file)
	if not chunk then
		print("FAIL " .. current_file .. ": load: " .. err)
		load_failures = load_failures + 1
	else
		H.fresh()
		local ok, lerr = pcall(chunk)
		if not ok then
			print("FAIL " .. current_file .. ": load: " .. tostring(lerr))
			load_failures = load_failures + 1
		end
	end
end

local pass, failed = 0, load_failures
local verbose = os.getenv("VERBOSE")
for _, t in ipairs(tests) do
	H.fresh()
	local ok, err = xpcall(t.fn, function(e)
		return verbose and debug.traceback(tostring(e), 2) or tostring(e)
	end)
	if ok then
		pass = pass + 1
	else
		failed = failed + 1
		print("FAIL " .. t.name .. ": " .. tostring(err))
	end
end

print(string.format("PASS %d FAIL %d", pass, failed))
os.exit(failed == 0 and 0 or 1)
