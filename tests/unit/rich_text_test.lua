-- scripts/gui/rich-text.lua: the rich-text tags for networks, items, item hashes and signals.

local H = require("harness")
local rich_text = H.load("scripts.gui.rich-text")

test("network_icon: signal, item and fluid icons; an unknown name as it is", function()
	assert_eq(rich_text.network_icon("signal-A"), "[virtual-signal=signal-A]")
	assert_eq(rich_text.network_icon("coal"), "[item=coal]")
	assert_eq(rich_text.network_icon("water"), "[fluid=water]")
	assert_eq(rich_text.network_icon("no-such-signal"), "no-such-signal")
	assert_eq(rich_text.network_icon(nil), "?")
	-- Memoised: a second call returns the same string.
	assert_eq(rich_text.network_icon("signal-A"), "[virtual-signal=signal-A]")
end)

test("network_icon_with: an unknown name keeps a space before its mask", function()
	assert_eq(rich_text.network_icon_with("signal-A", "3"), "[virtual-signal=signal-A]3")
	assert_eq(rich_text.network_icon_with("no-such-signal", "3"), "no-such-signal 3")
	assert_eq(rich_text.network_icon_with("no-such-signal", ""), "no-such-signal")
end)

test("item and of_hash: quality only when not normal, fluids never", function()
	assert_eq(rich_text.item("iron-plate"), "[item=iron-plate]")
	assert_eq(rich_text.item("iron-plate", "normal"), "[item=iron-plate]")
	assert_eq(rich_text.item("iron-plate", "rare"), "[item=iron-plate,quality=rare]")
	assert_eq(rich_text.item("water"), "[fluid=water]")
	assert_eq(rich_text.of_hash("iron-plate|legendary"), "[item=iron-plate,quality=legendary]")
end)

test("signal: any SignalID, quality always spelled out", function()
	assert_eq(rich_text.signal({ name = "iron-plate" }), "[item=iron-plate,quality=]")
	assert_eq(rich_text.signal({ type = "virtual", name = "signal-A", quality = "rare" }), "[virtual-signal=signal-A,quality=rare]")
end)
