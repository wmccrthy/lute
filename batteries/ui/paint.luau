--!strict
local tui = require("@std/tui")
local widgets = require("./widget")
local layout = require("./layout")
type widget = widgets.widget
export type terminal = {
    size: (any) -> (number, number),
    text: (any, number, number, string, tui.style?) -> (),
    fill: (any, number, number, number, number, tui.style?) -> (),
    present: (any) -> (),
}
local paint = {}

function paint.node(node: widget, term: terminal): number
    local r = node._rect
    if r.width == 0 or r.height == 0 or node.options.visible == false then return 0 end
    local style: tui.style = table.clone(node.options.style or ({} :: tui.style))
    if node._focused and (node.kind == "button" or node.kind == "input") then style.reverse = true end
    term:fill(r.x, r.y, r.width, r.height, style)
    if node.options.border and r.width >= 2 and r.height >= 2 then
        local line = "+" .. string.rep("-", r.width - 2) .. "+"
        term:text(r.x, r.y, line, style)
        term:text(r.x, r.y + r.height - 1, line, style)
        for y = r.y + 1, r.y + r.height - 2 do
            term:text(r.x, y, "|", style)
            term:text(r.x + r.width - 1, y, "|", style)
        end
        if node.options.title then term:text(r.x + 1, r.y, tui.clip(" " .. node.options.title .. " ", r.width - 2), style) end
    end
    local inset = layout.inset(node)
    local x, y = r.x + inset, r.y + inset
    local width, height = math.max(0, r.width - 2 * inset), math.max(0, r.height - 2 * inset)
    local function line(value: string, row: number, lineStyle: tui.style?)
        if width > 0 and row < height then term:text(x, y + row, tui.clip(value, width), lineStyle or style) end
    end
    if node.kind == "text" then
        line(node._text, 0)
    elseif node.kind == "button" then
        line("[ " .. node._text .. " ]", 0)
    elseif node.kind == "input" and width > 0 and height > 0 then
        local caret = tui.measure(node._value:sub(1, node._caret))
        local fullwidth = if node._caret == #node._value then caret else tui.measure(node._value)
        node._offset = math.min(node._offset, math.max(0, fullwidth - width + 1))
        if caret < node._offset then node._offset = caret end
        if caret >= node._offset + width then node._offset = caret - width + 1 end
        if node._value == "" and not node._focused then
            local placeholder: tui.style = table.clone(style)
            placeholder.dim = true
            line(node.options.placeholder or "", 0, placeholder)
        else
            term:text(x, y, tui.clip(node._value, width, node._offset), style)
        end
        if node._focused then
            local caretStyle: tui.style = table.clone(style)
            caretStyle.reverse = not style.reverse
            local tail = node._value:sub(node._caret + 1)
            local nextByte = utf8.offset(tail, 2)
            local glyph = if tail == "" then " " else tail:sub(1, if nextByte then nextByte - 1 else #tail)
            local span = math.max(1, tui.measure(glyph))
            if caret - node._offset + span > width then glyph = " " end
            term:text(x + caret - node._offset, y, glyph, caretStyle)
        end
    elseif node.kind == "list" then
        local count = #node._items
        node._offset = math.clamp(node._offset, 0, math.max(0, count - height))
        if node._selection > 0 then
            if node._selection <= node._offset then node._offset = node._selection - 1 end
            if node._selection > node._offset + height then node._offset = math.max(0, node._selection - height) end
        end
        if width > 0 then
            for row = 0, math.min(height, count - node._offset) - 1 do
                local index = node._offset + row + 1
                local item = node._items[index]
                local value, itemStyle = item.text, item.style
                if node.options.renderitem then value = node.options.renderitem(item, index) end
                local rowStyle: tui.style = table.clone(itemStyle or style)
                if index == node._selection then
                    rowStyle.reverse = true
                    if node._focused then rowStyle.bold = true end
                end
                term:fill(x, y + row, width, 1, rowStyle)
                line(value, row, rowStyle)
            end
        end
    end
    local count = 1
    for _, child in node._children do count += paint.node(child, term) end
    return count
end
return paint
