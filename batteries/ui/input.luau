--!strict
local tui = require("@std/tui")
local widgets = require("./widget")
local layout = require("./layout")
type widget = widgets.widget
local input = {}

function input.focusable(node: widget): boolean
    return node.kind == "input" or node.kind == "button" or node.kind == "list"
end

function input.hit(node: widget, x: number, y: number): widget?
    local r = node._rect
    if node.options.visible == false or x < r.x or y < r.y or x >= r.x + r.width or y >= r.y + r.height then return nil end
    for i = #node._children, 1, -1 do
        local found = input.hit(node._children[i], x, y)
        if found then return found end
    end
    return if input.focusable(node) then node else nil
end

local function insert(node: widget, text: string)
    local valid, cleaned = pcall(widgets.singleline, text)
    if not valid then return end -- Bad/oversized external paste is not an application error.
    text = cleaned :: string
    if text == "" then return end
    local value = node._value:sub(1, node._caret) .. text .. node._value:sub(node._caret + 1)
    if #value > 65536 then return end
    node._value = value
    node._caret += #text
    widgets.invalidate(node, false)
    widgets.emit(node, "change", { kind = "change", widget = node, value = value })
end

function input.handle(node: widget, event: tui.event): boolean
    if event.kind == "mouse" then
        if node.kind == "button" and event.action == "press" then widgets.emit(node, "press"); return true end
        if node.kind == "list" then
            if event.action == "press" then
                node:select(event.y - node._rect.y - layout.inset(node) + node._offset + 1)
            elseif event.action == "scrollup" then node:select(node._selection - 3)
            elseif event.action == "scrolldown" then node:select(node._selection + 3)
            else return false end
            return true
        end
        if node.kind == "input" and event.action == "press" then
            local target = math.max(0, event.x - node._rect.x - layout.inset(node) + node._offset)
            local column, caret = 0, 0
            for byte, cp in utf8.codes(node._value) do
                local nextByte = utf8.offset(node._value, 2, byte) or (#node._value + 1)
                local width = tui.measure(utf8.char(cp))
                if column + width > target then break end
                column += width; caret = nextByte - 1
            end
            node._caret = caret
            widgets.invalidate(node, false)
            return true
        end
        return false
    end
    if event.kind == "paste" then
        if node.kind == "input" then insert(node, event.text); return true end
        return false
    end
    if event.kind ~= "key" then return false end
    local key = event.key
    if node.kind == "button" then
        if key == "enter" or key == "space" then widgets.emit(node, "press"); return true end
    elseif node.kind == "list" then
        local nextIndex = node._selection
        local page = math.max(1, node._rect.height - 2 * layout.inset(node))
        if key == "up" or key == "k" then nextIndex -= 1
        elseif key == "down" or key == "j" then nextIndex += 1
        elseif key == "pageup" then nextIndex -= page
        elseif key == "pagedown" then nextIndex += page
        elseif key == "home" then nextIndex = 1
        elseif key == "end" then nextIndex = #node._items
        elseif key == "enter" then
            widgets.emit(node, "submit", { kind = "submit", widget = node, item = node._items[node._selection], index = node._selection })
            return true
        else return false end
        node:select(nextIndex)
        return true
    elseif node.kind == "input" then
        local caret = node._caret
        local previous = if caret > 0 then (utf8.offset(node._value, -1, caret + 1) or 1) - 1 else 0
        local following = if caret < #node._value then (utf8.offset(node._value, 2, caret + 1) or (#node._value + 1)) - 1 else #node._value
        if key == "left" then node._caret = previous
        elseif key == "right" then node._caret = following
        elseif key == "home" then node._caret = 0
        elseif key == "end" then node._caret = #node._value
        elseif key == "backspace" or key == "delete" then
            local first = if key == "backspace" then previous else caret
            local last = if key == "backspace" then caret else following
            if first ~= last then
                node._value = node._value:sub(1, first) .. node._value:sub(last + 1)
                node._caret = first
                widgets.emit(node, "change", { kind = "change", widget = node, value = node._value })
            end
        elseif key == "enter" then
            widgets.emit(node, "submit", { kind = "submit", widget = node, value = node._value })
            return true
        elseif event.text ~= "" and not event.ctrl and not event.alt then insert(node, event.text); return true
        else return false end
        widgets.invalidate(node, false)
        return true
    end
    return false
end
return input
