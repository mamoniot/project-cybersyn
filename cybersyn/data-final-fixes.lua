flib = require("__flib__.table")
require('scripts.constants')

if mods["nullius"] then
	-- Credit to modo-lv for submitting the following code
	-- Place combinator in the same subgroup as the regular train stop
	data.raw["recipe"][COMBINATOR_NAME].subgroup = data.raw["train-stop"]["train-stop"].subgroup
	data.raw["item"][COMBINATOR_NAME].subgroup = data.raw["item"]["train-stop"].subgroup
	-- Nullius makes modded technologies part of its research tree
	-- Place combinator in the same place on the research tree as LTN
	table.insert(data.raw.technology["nullius-broadcasting-1"].prerequisites, "cybersyn-train-network")
end
