-- The hover hold in scripts/gui/utils/hover.lua.

local H = require("harness")

local function hover()
	return H.load("scripts.gui.utils.hover")
end

test("hold_active: scope match within HOVER_HOLD_TICKS", function()
	local u = hover()
	assert_eq(u.HOVER_HOLD_TICKS, 600)
	game.tick = 1000
	local pd = { hover = { tick = 500, scope = "rows", index = 3 } }
	assert_true(u.hold_active(pd, "rows"))
	assert_false(u.hold_active(pd, "other"))
	game.tick = 1099
	assert_true(u.hold_active(pd, "rows"))
	game.tick = 1100
	assert_false(u.hold_active(pd, "rows"))
	assert_false(u.hold_active({}, "rows"))
end)

test("with_hover/hoverable: function handler becomes on_gui_click", function()
	local u = hover()
	local click = function() end
	local h = u.with_hover(click)
	assert_same(h[defines.events.on_gui_click], click)
	assert_same(h[defines.events.on_gui_hover], u.handle.hover_enter)
	assert_same(h[defines.events.on_gui_leave], u.handle.hover_leave)
	local def = u.hoverable({ type = "button", tags = { a = 1 } }, "rows")
	assert_true(def.raise_hover_events)
	assert_eq(def.tags, { a = 1, hover_scope = "rows" })
	assert_same(def.handler[defines.events.on_gui_hover], u.handle.hover_enter)
	assert_nil(def.handler[defines.events.on_gui_click])
end)

test("hover_enter/hover_leave/touch_hover keep one hover record per player", function()
	local u = hover()
	game.tick = 70
	local parent = H.element({ name = "rows" })
	local elem = parent.add({ type = "button", tags = { hover_scope = "rows" } })
	local pd = {}
	u.handle.hover_enter(nil, pd, nil, { element = elem })
	assert_eq(pd.hover, { tick = 70, scope = "rows", index = 1 })
	local other = parent.add({ type = "button" })
	u.handle.hover_leave(nil, pd, nil, { element = other })
	assert_not_nil(pd.hover)
	u.handle.hover_leave(nil, pd, nil, { element = elem })
	assert_nil(pd.hover)

	storage.manager = { players = { [1] = pd } }
	local tagged = parent.add({ type = "button", tags = { hover_scope = "rows" } })
	game.tick = 80
	u.touch_hover({ element = tagged, player_index = 1 })
	assert_eq(pd.hover, { tick = 80, scope = "rows", index = 3 })
	game.tick = 90
	u.touch_hover({ element = tagged, player_index = 1 })
	assert_eq(pd.hover.tick, 90)
	local untagged = parent.add({ type = "button" })
	u.touch_hover({ element = untagged, player_index = 1 })
	assert_eq(pd.hover.tick, 90)
end)
