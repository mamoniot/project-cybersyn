-- scripts/gui/rich-name.lua: the station-name parser.

local H = require("harness")

local function parse(name)
	return H.load("scripts.gui.rich-name").parse(name)
end

local function icon(sprite, quality)
	return { sprite = sprite, quality = quality }
end

--- The expected compact shape: sprite strings, qualities by index, nothing for an empty side or a zero overflow.
local function parts(lead, text, tail, lead_overflow, tail_overflow)
	local p = { text = text }
	for side, icons in pairs({ lead = lead or {}, tail = tail or {} }) do
		for i, ic in ipairs(icons) do
			p[side] = p[side] or {}
			p[side][i] = ic.sprite
			if ic.quality then
				p[side .. "_quality"] = p[side .. "_quality"] or {}
				p[side .. "_quality"][i] = ic.quality
			end
		end
	end
	if lead_overflow and lead_overflow > 0 then p.lead_overflow = lead_overflow end
	if tail_overflow and tail_overflow > 0 then p.tail_overflow = tail_overflow end
	return p
end

test("plain names: text only, trimmed", function()
	assert_eq(parse("Iron Mine"), parts({}, "Iron Mine"))
	assert_eq(parse("  Iron  Mine \t"), parts({}, "Iron  Mine"))
	assert_eq(parse(""), parts({}, ""))
	assert_eq(parse(nil), parts({}, ""))
end)

test("leading icons of every supported type, with quality", function()
	assert_eq(parse("[item=iron-plate] Iron"), parts({ icon("item/iron-plate") }, "Iron"))
	assert_eq(parse("[fluid=water][virtual-signal=signal-A] [entity=stone-furnace]Smelter"), parts({
		icon("fluid/water"), icon("virtual-signal/signal-A"), icon("entity/stone-furnace"),
	}, "Smelter"))
	assert_eq(parse("[item=iron-plate,quality=rare] Iron"), parts({ icon("item/iron-plate", "rare") }, "Iron"))
	assert_eq(parse("[item= iron-plate , quality = epic ] Iron"), parts({ icon("item/iron-plate", "epic") }, "Iron"))
	assert_eq(parse("[planet=vulcanus][space-location=nauvis] [recipe=gear] Hub [tile=concrete][technology=steel][quality=rare]"),
		parts({ icon("space-location/vulcanus"), icon("space-location/nauvis"), icon("recipe/gear") }, "Hub",
			{ icon("tile/concrete"), icon("technology/steel"), icon("quality/rare") }))
	-- An img tag already holds a sprite path.
	assert_eq(parse("[img=item/coal] Coal"), parts({ icon("item/coal") }, "Coal"))
end)

test("trailing icons and mixed names", function()
	assert_eq(parse("Iron drop [item=iron-plate]"), parts({}, "Iron drop", { icon("item/iron-plate") }))
	assert_eq(parse("[item=coal] Coal [virtual-signal=signal-P][virtual-signal=signal-1]"),
		parts({ icon("item/coal") }, "Coal", { icon("virtual-signal/signal-P"), icon("virtual-signal/signal-1") }))
end)

test("icons inside the text stay in the text as rich text", function()
	assert_eq(parse("[item=coal] Coal to [item=iron-plate] smelter"),
		parts({ icon("item/coal") }, "Coal to [item=iron-plate] smelter"))
	-- Like a leading run, a trailing run needs no space before it.
	assert_eq(parse("A-[item=coal]"), parts({}, "A-", { icon("item/coal") }))
end)

test("lead and tail capped at three with overflow counts", function()
	local name = "[item=a][item=b][item=c][item=d][item=e] Hub [fluid=f][fluid=g][fluid=h][fluid=i]"
	assert_eq(parse(name), parts(
		{ icon("item/a"), icon("item/b"), icon("item/c") }, "Hub",
		{ icon("fluid/g"), icon("fluid/h"), icon("fluid/i") }, 2, 1))
end)

test("icons only: everything is the leading run", function()
	assert_eq(parse("[item=a] [item=b]"), parts({ icon("item/a"), icon("item/b") }, ""))
	assert_eq(parse("[item=a][item=b][item=c][item=d]"), parts({ icon("item/a"), icon("item/b"), icon("item/c") }, "", {}, 1))
end)

test("malformed and unknown tags are text", function()
	assert_eq(parse("[item=] Empty"), parts({}, "[item=] Empty"))
	assert_eq(parse("[item=coal Unclosed"), parts({}, "[item=coal Unclosed"))
	assert_eq(parse("[color=red]Red[/color]"), parts({}, "[color=red]Red[/color]"))
	assert_eq(parse("[item=coal,foo=bar] Coal"), parts({}, "[item=coal,foo=bar] Coal"))
	assert_eq(parse("[[item=coal]] x"), parts({}, "[[item=coal]] x"))
	-- An unknown tag ends the leading run; the icon after it is inside the text.
	assert_eq(parse("[item=coal][color=red]x[/color]"), parts({ icon("item/coal") }, "[color=red]x[/color]"))
end)

test("unicode text is kept byte for byte", function()
	assert_eq(parse("[item=coal] Kohle → Schmelze ÄÖÜ"), parts({ icon("item/coal") }, "Kohle → Schmelze ÄÖÜ"))
	assert_eq(parse("日本 [fluid=water]"), parts({}, "日本", { icon("fluid/water") }))
end)

test("compact shape: no empty sides, no zero overflow, qualities only where named", function()
	assert_eq(parse("Iron Mine"), { text = "Iron Mine" })
	assert_eq(parse("[item=coal] C [fluid=water,quality=rare]"),
		{ text = "C", lead = { "item/coal" }, tail = { "fluid/water" }, tail_quality = { "rare" } })
end)

test("separators between icons join the icon run (pY names)", function()
	assert_eq(parse("[item=iron-plate] / [item=copper-plate] Requestor for [fluid=water]"),
		parts({ icon("item/iron-plate"), icon("item/copper-plate") }, "Requestor for", { icon("fluid/water") }))
	assert_eq(parse("[item=coal],[item=stone] | [item=wood] Mix"),
		parts({ icon("item/coal"), icon("item/stone"), icon("item/wood") }, "Mix"))
	assert_eq(parse("Drop [item=coal] / [item=stone]"), parts({}, "Drop", { icon("item/coal"), icon("item/stone") }))
	assert_eq(parse("[item=coal] / [item=stone]"), parts({ icon("item/coal"), icon("item/stone") }, ""))
end)

test("separators outside a run stay in the text", function()
	-- Before the first icon, between the last lead icon and the text, after the last tail icon: text, not run.
	assert_eq(parse("/ [item=coal] Coal"), parts({}, "/ [item=coal] Coal"))
	assert_eq(parse("[item=coal] / Coal"), parts({ icon("item/coal") }, "/ Coal"))
	assert_eq(parse("Coal [item=coal] /"), parts({}, "Coal [item=coal] /"))
	assert_eq(parse("A / B [item=coal]"), parts({}, "A / B", { icon("item/coal") }))
end)
