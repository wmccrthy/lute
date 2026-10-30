--!strict
local tui = require("@std/tui")
local widgets = require("./widget")
type widget = widgets.widget
local layout = {}

function layout.inset(node: widget): number
    return (node.options.padding or 0) + (if node.options.border then 1 else 0)
end

function layout.measure(node: widget): (number, number)
    if node._measure then return node._measure[1], node._measure[2] end
    local width, height = 0, 1
    if node.kind == "text" or node.kind == "button" then
        width = tui.measure(node._text) + (if node.kind == "button" then 4 else 0)
    elseif node.kind == "input" then width = 20
    elseif node.kind == "list" or node.kind == "surface" then width, height = 20, 1
    else
        local row = node.kind == "row"
        local count = 0
        width, height = 0, 0
        for _, child in node._children do
            if child.options.visible ~= false then
                local w, h = layout.measure(child)
                if row then width += w; height = math.max(height, h)
                else width = math.max(width, w); height += h end
                count += 1
            end
        end
        local gaps = math.max(0, count - 1) * (node.options.gap or 0)
        if row then width += gaps else height += gaps end
    end
    local inset = layout.inset(node) * 2
    width = node.options.width or (width + inset)
    height = node.options.height or (height + inset)
    node._measure = {width, height}
    return width, height
end

function layout.arrange(node: widget, x: number, y: number, width: number, height: number)
    if node.options.visible == false then width, height = 0, 0 end
    node._rect = { x = x, y = y, width = width, height = height }
    local inset = layout.inset(node)
    x += math.min(inset, width)
    y += math.min(inset, height)
    width = math.max(0, width - inset * 2)
    height = math.max(0, height - inset * 2)
    local row = node.kind == "row"
    local available = if row then width else height
    local fixed, weight, count = 0, 0, 0
    for _, child in node._children do
        if child.options.visible ~= false then
            local cw, ch = layout.measure(child)
            local explicit = if row then child.options.width else child.options.height
            local flex = if explicit ~= nil then 0 else child.options.flex or (if child.kind == "list" then 1 else 0)
            if flex > 0 then weight += flex else fixed += if row then cw else ch end
            count += 1
        end
    end
    local gap = node.options.gap or 0
    local remaining = math.max(0, available - fixed - math.max(0, count - 1) * gap)
    local used, allocatedWeight, allocatedSpace = 0, 0, 0
    for _, child in node._children do
        if child.options.visible == false then
            layout.arrange(child, x, y, 0, 0)
            continue
        end
        local cw, ch = layout.measure(child)
        local explicit = if row then child.options.width else child.options.height
        local flex = if explicit ~= nil then 0 else child.options.flex or (if child.kind == "list" then 1 else 0)
        local size = if row then cw else ch
        if flex > 0 and weight > 0 then
            allocatedWeight += flex
            local cumulative = math.floor(remaining * allocatedWeight / weight)
            size = cumulative - allocatedSpace
            allocatedSpace = cumulative
        end
        size = math.min(size, math.max(0, available - used))
        if row then
            layout.arrange(child, x + used, y, size, math.min(height, child.options.height or height))
        else
            layout.arrange(child, x, y + used, math.min(width, child.options.width or width), size)
        end
        used = math.min(available, used + size + gap)
    end
end

return layout
