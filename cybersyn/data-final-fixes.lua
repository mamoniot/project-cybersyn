flib = require("__flib__.table")
require('scripts.constants')

--Credit to modo-lv for submitting the following code
if mods["nullius"] then
	-- Place combinator in the same subgroup as the regular train stop
	data.raw["recipe"][COMBINATOR_NAME].subgroup = data.raw["train-stop"]["train-stop"].subgroup
	data.raw["item"][COMBINATOR_NAME].subgroup = data.raw["item"]["train-stop"].subgroup
	-- Nullius makes modded technologies part of its research tree
	-- Place combinator in the same place on the research tree as LTN
	table.insert(data.raw.technology["nullius-broadcasting-1"].prerequisites, "cybersyn-train-network")
end

-- compatibility for mods that disable/replace the arithmetic-combinator recipe, e.g. Nullius
local recipe
if mods["nullius"] then
	recipe = flib.deep_copy(data.raw["recipe"]["nullius-arithmetic-circuit"].ingredients)
-- use this template for additional mod compatibilities if necessary.
-- elseif mods["modnamehere"] then
-- 	recipe = flib.deep_copy(data.raw["recipe"]["mod's-arithmetic-combinator-replacement-here"].ingredients)
else
	-- Reset the combinator recipe back to arithmetic combinator recipe in case a mod has changed it
	recipe = flib.deep_copy(data.raw["recipe"]["arithmetic-combinator"].ingredients)
end
for k, _ in pairs(recipe) do
	local mult = 2
	for i, _ in pairs(recipe) do
		if recipe[k][i] == "copper-cable" then
			mult = 4
			break;
		end
	end
	for i, _ in pairs(recipe) do
		if type(recipe[k][i]) == "number" then
			recipe[k][i] = mult*recipe[k][i]
		end
	end
end
data.raw["recipe"][COMBINATOR_NAME].ingredients = recipe
