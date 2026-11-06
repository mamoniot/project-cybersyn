-- The locale files: en is the only complete one, every other locale keeps just its real translations.

local H = require("harness")

test("H.locale: en's text unless the locale has its own, keys from both", function()
	local en = H.locale("en")["cybersyn-gui"]
	local de = H.locale("de")["cybersyn-gui"]
	local own = H.read_cfg("de/manager.cfg")["cybersyn-gui"]
	assert_eq(de.inventory, own.inventory)
	assert_true(de.inventory ~= en.inventory, "de translates inventory")
	assert_true(own["trains-summary"] == nil, "de has no trains-summary of its own")
	assert_eq(de["trains-summary"], en["trains-summary"])
	assert_true(H.locale_text("de"):find("\ntrains-summary=" .. en["trains-summary"] .. "\n", 1, true) ~= nil)
end)

-- A key the code names and en lacks shows as "Unknown key" in game. Literals ending in "-" are prefixes the code
-- completes.
test("every cybersyn locale key literal under scripts exists in en", function()
	local cfgs = { H.read_cfg("en/manager.cfg"), H.read_cfg("en/base.cfg") }
	local function known(group, key)
		for _, cfg in ipairs(cfgs) do
			if cfg[group] and cfg[group][key] then return true end
		end
		return false
	end
	local files = assert(io.popen('find "' .. H.mod_root .. '/scripts" -name "*.lua"'))
	local missing, n = {}, 0
	for path in files:lines() do
		local f = assert(io.open(path, "r"))
		local code = f:read("*a")
		f:close()
		for group, key in code:gmatch('"(cybersyn%-[%a%-]+)%.([%w_%-]+)"') do
			if key:sub(-1) ~= "-" then
				n = n + 1
				if not known(group, key) then missing[#missing + 1] = path .. " " .. group .. "." .. key end
			end
		end
	end
	files:close()
	assert_true(n > 500, "found the keys")
	table.sort(missing)
	assert_eq(missing, {})
end)

-- A copy of an English value would keep showing the old English after en changes.
test("no locale repeats an en value: a key it does not translate is left to the fallback", function()
	local copies = {}
	for _, loc in ipairs(H.LOCALES) do
		if loc ~= "en" then
			for _, file in ipairs({ "manager.cfg", "base.cfg" }) do
				local en = H.read_cfg("en/" .. file)
				for name, s in pairs(H.read_cfg(loc .. "/" .. file)) do
					for _, k in ipairs(s.order) do
						local e = en[name] and en[name][k]
						if e and (s[k] == e or s[k] == "") then copies[#copies + 1] = loc .. "/" .. file .. " " .. k end
					end
				end
			end
		end
	end
	table.sort(copies)
	assert_eq(copies, {})
end)

test("no locale translates a manager key en does not have", function()
	local en = H.read_cfg("en/manager.cfg")
	local orphans = {}
	for _, loc in ipairs(H.LOCALES) do
		for name, s in pairs(H.read_cfg(loc .. "/manager.cfg")) do
			for _, k in ipairs(s.order) do
				if not (en[name] and en[name][k]) then orphans[#orphans + 1] = loc .. " [" .. name .. "] " .. k end
			end
		end
	end
	table.sort(orphans)
	assert_eq(orphans, {})
end)
