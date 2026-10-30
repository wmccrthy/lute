--!strict
local tui = require("@std/tui")

export type rect = { x: number, y: number, width: number, height: number }
export type item = { id: string, text: string, style: tui.style? }
export type options = {
    width: number?, height: number?, flex: number?, gap: number?, padding: number?,
    border: boolean?, title: string?, style: tui.style?, visible: boolean?,
    value: string?, placeholder: string?, items: {item}?,
    renderitem: ((item, number) -> string)?,
}
export type event = { kind: string, widget: widget, value: string?, item: item?, index: number? }
export type widget = {
    kind: string, options: options, _text: string, _value: string, _caret: number,
    _offset: number, _selection: number, _items: {item}, _children: {widget},
    _parent: widget?, _notify: ((widget, boolean) -> ())?, _focused: boolean,
    _rect: rect, _measure: {number}?, _handlers: {[string]: (event) -> ()},
    on: (widget, string, (event) -> ()) -> widget,
    settext: (widget, string) -> (), setvalue: (widget, string) -> (),
    setitems: (widget, {item}) -> (), select: (widget, number) -> (),
    selected: (widget) -> number, scroll: (widget) -> number, value: (widget) -> string,
    setstyle: (widget, tui.style) -> (), setvisible: (widget, boolean) -> (),
    append: (widget, widget) -> widget, remove: (widget, widget) -> (),
    children: (widget) -> {widget}, bounds: (widget) -> rect, focused: (widget) -> boolean,
}

local methods = {}
local widget = {}

function widget.invalidate(node: widget, layout: boolean)
    if layout then
        local ancestor: widget? = node
        while ancestor do
            ancestor._measure = nil
            ancestor = ancestor._parent
        end
    end
    if node._notify then node._notify(node, layout) end
end

function widget.attach(node: widget, notify: ((widget, boolean) -> ())?)
    node._notify = notify
    for _, child in node._children do widget.attach(child, notify) end
end

function widget.emit(node: widget, name: string, data: event?)
    local callback = node._handlers[name]
    if callback then callback(data or { kind = name, widget = node }) end
end

local function singleline(value: string): string
    -- Keep valid UTF-8, strip terminal controls, and bound editable values.
    value = value:gsub("[%z\1-\31\127]", "")
    assert(utf8.len(value) ~= nil, "input requires valid UTF-8")
    value = value:gsub("\194[\128-\159]", "")
    assert(#value <= 65536, "input exceeds 64 KiB")
    return value
end
widget.singleline = singleline

function methods.on(self: widget, name: string, callback: (event) -> ()): widget
    self._handlers[name] = callback
    return self
end
function methods.settext(self: widget, value: string)
    if self._text == value then return end
    self._text = value
    -- Natural width matters only until an explicit/stretch allocation cuts the
    -- dependency chain. Invalidate cached measures even when no layout is needed.
    local ancestor: widget? = self
    local needsLayout = false
    while ancestor do
        ancestor._measure = nil
        ancestor = ancestor._parent
    end
    ancestor = self
    while ancestor and ancestor.options.width == nil do
        local parent = ancestor._parent
        if not parent then break end
        if parent.kind == "row" then
            needsLayout = (ancestor.options.flex or 0) == 0
            break
        end
        ancestor = parent
    end
    widget.invalidate(self, needsLayout)
end
function methods.setvalue(self: widget, value: string)
    value = singleline(value)
    if self._value == value then return end
    self._value = value
    self._caret = #value
    widget.invalidate(self, false)
end
function methods.value(self: widget): string return self._value end
function methods.selected(self: widget): number return self._selection end
function methods.scroll(self: widget): number return self._offset end
function methods.focused(self: widget): boolean return self._focused end
function methods.bounds(self: widget): rect return table.clone(self._rect) end
function methods.children(self: widget): {widget} return table.clone(self._children) end
function methods.setstyle(self: widget, style: tui.style)
    self.options.style = table.clone(style)
    widget.invalidate(self, false)
end
function methods.setvisible(self: widget, visible: boolean)
    if self.options.visible == visible then return end
    self.options.visible = visible
    widget.invalidate(self, true)
end
function methods.setitems(self: widget, items: {item})
    local selected = self._items[self._selection]
    local identity = if selected then selected.id else nil
    self._items = table.clone(items)
    local selection = math.min(math.max(1, self._selection), #items)
    if identity then
        for i, entry in items do
            if entry.id == identity then selection = i; break end
        end
    end
    self._selection = selection
    self._offset = math.max(0, math.min(self._offset, #items - self._rect.height))
    widget.invalidate(self, false)
end
function methods.select(self: widget, index: number)
    index = math.clamp(math.floor(index), if #self._items == 0 then 0 else 1, #self._items)
    if self._selection == index then return end
    self._selection = index
    widget.invalidate(self, false)
    widget.emit(self, "select", { kind = "select", widget = self, item = self._items[index], index = index })
end
function methods.append(self: widget, child: widget): widget
    assert(self.kind == "row" or self.kind == "column" or self.kind == "box", "only containers accept children")
    assert(child._parent == nil and child._notify == nil, "widget already belongs to a tree")
    local ancestor: widget? = self
    while ancestor do
        assert(ancestor ~= child, "widget tree cannot contain cycles")
        ancestor = ancestor._parent
    end
    child._parent = self
    table.insert(self._children, child)
    widget.attach(child, self._notify)
    widget.invalidate(self, true)
    return self
end
function methods.remove(self: widget, child: widget)
    local index = table.find(self._children, child)
    assert(index, "widget is not a child")
    table.remove(self._children, index)
    child._parent = nil
    widget.attach(child, nil)
    widget.invalidate(self, true)
end

function widget.new(kind: string, text: string?, options: options?, children: {widget}?): widget
    local opts: options = table.clone(options or ({} :: options))
    for _, key in { "width", "height", "gap", "padding", "flex" } do
        local number = (opts :: any)[key]
        assert(number == nil or (type(number) == "number" and number >= 0 and number <= 4096 and number == math.floor(number)), `invalid {key}`)
    end
    local node: widget = setmetatable({
        kind = kind, options = opts, _text = text or "", _value = singleline(opts.value or ""),
        _caret = 0, _offset = 0, _selection = 0, _items = {}, _children = {},
        _parent = nil, _notify = nil, _focused = false, _measure = nil,
        _rect = { x = 1, y = 1, width = 0, height = 0 }, _handlers = {},
    }, { __index = methods }) :: any
    node._caret = #node._value
    if opts.items then node:setitems(opts.items) end
    if children then for _, child in children do node:append(child) end end
    return node
end

return widget
