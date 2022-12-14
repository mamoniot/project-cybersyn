---@meta
---@diagnostic disable

--$Factorio 1.1.72
--$Overlay 5
--$Section LuaStyle
-- This file is automatically generated. Edits will be overwritten.

---Style of a GUI element. All of the attributes listed here may be `nil` if not available for a particular GUI element.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html)
---@class LuaStyle:LuaObject
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.badge_font)
---
---_Can only be used if this is TabStyle_
---@field badge_font string 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.badge_horizontal_spacing)
---
---_Can only be used if this is TabStyle_
---@field badge_horizontal_spacing int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.bar_width)
---
---_Can only be used if this is LuaProgressBarStyle_
---@field bar_width uint 
---[RW]  
---Space between the table cell contents bottom and border.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.bottom_cell_padding)
---
---_Can only be used if this is LuaTableStyle_
---@field bottom_cell_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.bottom_margin)
---@field bottom_margin int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.bottom_padding)
---@field bottom_padding int 
---[W]  
---Space between the table cell contents and border. Sets top/right/bottom/left cell paddings to this value.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.cell_padding)
---
---_Can only be used if this is LuaTableStyle_
---@field cell_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.clicked_font_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field clicked_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.clicked_vertical_offset)
---
---_Can only be used if this is LuaButtonStyle_
---@field clicked_vertical_offset int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.color)
---
---_Can only be used if this is LuaProgressBarStyle_
---@field color Color 
---[R]  
---Array containing the alignment for every column of this table element. Even though this property is marked as read-only, the alignment can be changed by indexing the LuaCustomTable, like so:
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.column_alignments)
---
---### Example
---```
---table_element.style.column_alignments[1] = "center"
---```
---@field column_alignments LuaCustomTable<uint,Alignment> 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.default_badge_font_color)
---
---_Can only be used if this is TabStyle_
---@field default_badge_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.disabled_badge_font_color)
---
---_Can only be used if this is TabStyle_
---@field disabled_badge_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.disabled_font_color)
---
---_Can only be used if this is LuaButtonStyle or LuaTabStyle_
---@field disabled_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_bottom_margin_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_bottom_margin_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_bottom_padding_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_bottom_padding_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_left_margin_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_left_margin_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_left_padding_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_left_padding_when_activated int 
---[W]  
---Sets `extra_top/right/bottom/left_margin_when_activated` to this value. An array with two values sets top/bottom margin to the first value and left/right margin to the second value. An array with four values sets top, right, bottom, left margin respectively.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_margin_when_activated)
---@field extra_margin_when_activated int|int[] 
---[W]  
---Sets `extra_top/right/bottom/left_padding_when_activated` to this value. An array with two values sets top/bottom padding to the first value and left/right padding to the second value. An array with four values sets top, right, bottom, left padding respectively.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_padding_when_activated)
---@field extra_padding_when_activated int|int[] 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_right_margin_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_right_margin_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_right_padding_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_right_padding_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_top_margin_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_top_margin_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.extra_top_padding_when_activated)
---
---_Can only be used if this is ScrollPaneStyle_
---@field extra_top_padding_when_activated int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.font)
---@field font string 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.font_color)
---@field font_color Color 
---[R]  
---Gui of the [LuaGuiElement](https://lua-api.factorio.com/latest/LuaGuiElement.html) of this style.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.gui)
---@field gui LuaGui 
---[W]  
---Sets both minimal and maximal height to the given value.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.height)
---@field height int 
---[RW]  
---Horizontal align of the inner content of the widget, if any. Possible values are "left", "center" or "right".
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.horizontal_align)
---@field horizontal_align? string 
---[RW]  
---Horizontal space between individual cells.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.horizontal_spacing)
---
---_Can only be used if this is LuaTableStyle, LuaFlowStyle or LuaHorizontalFlowStyle_
---@field horizontal_spacing int 
---[RW]  
---Whether the GUI element can be squashed (by maximal width of some parent element) horizontally. `nil` if this element does not support squashing. This is mainly meant to be used for scroll-pane The default value is false.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.horizontally_squashable)
---@field horizontally_squashable? boolean 
---[RW]  
---Whether the GUI element stretches its size horizontally to other elements. `nil` if this element does not support stretching.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.horizontally_stretchable)
---@field horizontally_stretchable? boolean 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.hovered_font_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field hovered_font_color Color 
---[RW]  
---Space between the table cell contents left and border.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.left_cell_padding)
---
---_Can only be used if this is LuaTableStyle_
---@field left_cell_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.left_margin)
---@field left_margin int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.left_padding)
---@field left_padding int 
---[W]  
---Sets top/right/bottom/left margins to this value. An array with two values sets top/bottom margin to the first value and left/right margin to the second value. An array with four values sets top, right, bottom, left margin respectively.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.margin)
---@field margin int|int[] 
---[RW]  
---Maximal height ensures, that the widget will never be bigger than than that size. It can't be stretched to be bigger.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.maximal_height)
---@field maximal_height int 
---[RW]  
---Maximal width ensures, that the widget will never be bigger than than that size. It can't be stretched to be bigger.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.maximal_width)
---@field maximal_width int 
---[RW]  
---Minimal height ensures, that the widget will never be smaller than than that size. It can't be squashed to be smaller.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.minimal_height)
---@field minimal_height int 
---[RW]  
---Minimal width ensures, that the widget will never be smaller than than that size. It can't be squashed to be smaller.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.minimal_width)
---@field minimal_width int 
---[R]  
---Name of this style.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.name)
---@field name string 
---[RW]  
---Natural height specifies the height of the element tries to have, but it can still be squashed/stretched to have a smaller or bigger size.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.natural_height)
---@field natural_height int 
---[RW]  
---Natural width specifies the width of the element tries to have, but it can still be squashed/stretched to have a smaller or bigger size.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.natural_width)
---@field natural_width int 
---[R]  
---The class name of this object. Available even when `valid` is false. For LuaStruct objects it may also be suffixed with a dotted path to a member of the struct.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.object_name)
---@field object_name string 
---[W]  
---Sets top/right/bottom/left paddings to this value. An array with two values sets top/bottom padding to the first value and left/right padding to the second value. An array with four values sets top, right, bottom, left padding respectively.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.padding)
---@field padding int|int[] 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.pie_progress_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field pie_progress_color Color 
---[RW]  
---How this GUI element handles rich text.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.rich_text_setting)
---
---_Can only be used if this is LuaLabelStyle, LuaTextBoxStyle or LuaTextFieldStyle_
---@field rich_text_setting defines.rich_text_setting 
---[RW]  
---Space between the table cell contents right and border.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.right_cell_padding)
---
---_Can only be used if this is LuaTableStyle_
---@field right_cell_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.right_margin)
---@field right_margin int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.right_padding)
---@field right_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.selected_badge_font_color)
---
---_Can only be used if this is TabStyle_
---@field selected_badge_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.selected_clicked_font_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field selected_clicked_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.selected_font_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field selected_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.selected_hovered_font_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field selected_hovered_font_color Color 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.single_line)
---
---_Can only be used if this is LabelStyle_
---@field single_line boolean 
---[W]  
---Sets both width and height to the given value. Also accepts an array with two values, setting width to the first and height to the second one.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.size)
---@field size int|int[] 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.stretch_image_to_widget_size)
---
---_Can only be used if this is ImageStyle_
---@field stretch_image_to_widget_size boolean 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.strikethrough_color)
---
---_Can only be used if this is LuaButtonStyle_
---@field strikethrough_color Color 
---[RW]  
---Space between the table cell contents top and border.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.top_cell_padding)
---
---_Can only be used if this is LuaTableStyle_
---@field top_cell_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.top_margin)
---@field top_margin int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.top_padding)
---@field top_padding int 
---[RW]
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.use_header_filler)
---
---_Can only be used if this is LuaFrameStyle_
---@field use_header_filler boolean 
---[R]  
---Is this object valid? This Lua object holds a reference to an object within the game engine. It is possible that the game-engine object is removed whilst a mod still holds the corresponding Lua object. If that happens, the object becomes invalid, i.e. this attribute will be `false`. Mods are advised to check for object validity if any change to the game state might have occurred between the creation of the Lua object and its access.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.valid)
---@field valid boolean 
---[RW]  
---Vertical align of the inner content of the widget, if any. Possible values are "top", "center" or "bottom".
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.vertical_align)
---@field vertical_align? string 
---[RW]  
---Vertical space between individual cells.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.vertical_spacing)
---
---_Can only be used if this is LuaTableStyle, LuaFlowStyle, LuaVerticalFlowStyle or LuaTabbedPaneStyle_
---@field vertical_spacing int 
---[RW]  
---Whether the GUI element can be squashed (by maximal height of some parent element) vertically. `nil` if this element does not support squashing. This is mainly meant to be used for scroll-pane The default (parent) value for scroll pane is true, false otherwise.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.vertically_squashable)
---@field vertically_squashable? boolean 
---[RW]  
---Whether the GUI element stretches its size vertically to other elements. `nil` if this element does not support stretching.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.vertically_stretchable)
---@field vertically_stretchable? boolean 
---[W]  
---Sets both minimal and maximal width to the given value.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.width)
---@field width int 
local LuaStyle={
---All methods and properties that this object supports.
---
---[View documentation](https://lua-api.factorio.com/latest/LuaStyle.html#LuaStyle.help)
---@return string
help=function()end,
}


