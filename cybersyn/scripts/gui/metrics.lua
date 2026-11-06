-- Sizes that prototypes/gui-style.lua sets and the manager's layout arithmetic counts with, in logical px. The
-- runtime API cannot read an element's laid-out size, so both stages read them from here and stay in step.

local metrics = {}

-- Every subheader-like strip: the tab subheaders, the filter row, the banner, column headers and caption strips.
metrics.SUBHEADER_HEIGHT = 36
-- The tab subheaders' side padding (each side) and their controls' spacing.
metrics.SUBHEADER_PADDING = 8
metrics.SUBHEADER_SPACING = 8

-- An Overview tile: a button this tall, its body padded at top and bottom around a header and lines of TILE_LINE_HEIGHT.
metrics.TILE_HEIGHT = 108
metrics.TILE_PADDING = 4
metrics.TILE_LINE_HEIGHT = 18

-- The Overview and drill-down tables (cybersyn_unserved_table): side paddings and column spacing.
metrics.TABLE_LEFT_PADDING = 4
metrics.TABLE_RIGHT_PADDING = 10
metrics.TABLE_SPACING = 8

-- Stations and Trains rows and their column header: side padding (each side) and cell spacing.
metrics.LIST_ROW_PADDING = 4
metrics.LIST_SPACING = 8

-- Log rows: side paddings and cell spacing.
metrics.LOG_ROW_LEFT_PADDING = 4
metrics.LOG_ROW_RIGHT_PADDING = 8
metrics.LOG_SPACING = 8

metrics.SEARCH_FIELD_WIDTH = 200
metrics.LOG_KIND_DROPDOWN_WIDTH = 190
metrics.LOG_WINDOW_DROPDOWN_WIDTH = 160
metrics.LOG_TRAIN_FIELD_WIDTH = 72

-- The engine's, not a style's: a deep frame's border, both sides together, and a scroll pane's vertical bar.
metrics.FRAME_BORDER = 4
metrics.SCROLLBAR = 12

return metrics
