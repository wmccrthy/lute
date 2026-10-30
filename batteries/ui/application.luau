--!strict
local tui = require("@std/tui")
local task = require("@std/task")
local widgets = require("./widget")
local layout = require("./layout")
local paint = require("./paint")
local input = require("./input")
type widget = widgets.widget
export type stats = { layouts: number, paints: number, frames: number }
export type application = {
    root: widget,
    _dirty: {[widget]: boolean}, _layout: boolean, _focus: widget?, _focusables: {widget},
    _width: number, _height: number, _stats: stats, _term: tui.session?,
    _scheduled: boolean, _painting: boolean, _running: boolean, _error: string?,
    _jobs: {[thread]: boolean}, _renderer: thread?, _key: ((tui.event) -> boolean)?, _focusCallback: ((widget) -> ())?,
    render: (application, paint.terminal) -> (), dispatch: (application, tui.event) -> boolean,
    focus: (application, widget) -> (), stats: (application) -> stats,
    onfocus: (application, (widget) -> ()) -> (), focused: (application) -> widget?, cancel: (application, thread) -> (),
    onkey: (application, (tui.event) -> boolean) -> (),
    run: (application, tui.options?, (() -> ())?) -> (),
    quit: (application) -> (), spawn: (application, () -> ()) -> thread,
    running: (application) -> boolean,
}
local App = {}

local function belongs(app: application, node: widget): boolean
    local ancestor: widget? = node
    while ancestor do
        if ancestor == app.root then return true end
        ancestor = ancestor._parent
    end
    return false
end

local function visible(app: application, node: widget): boolean
    if not belongs(app, node) then return false end
    local ancestor: widget? = node
    while ancestor do
        if ancestor.options.visible == false then return false end
        ancestor = ancestor._parent
    end
    return true
end

local function focusables(node: widget, result: {widget})
    if node.options.visible == false or node._rect.width == 0 or node._rect.height == 0 then return end
    if input.focusable(node) then table.insert(result, node) end
    for _, child in node._children do focusables(child, result) end
end

local function schedule(app: application)
    if not app._running or not app._term or app._scheduled or app._painting then return end
    app._scheduled = true
    app._renderer = task.defer(function()
        app._scheduled = false
        if not app._running then return end
        app._painting = true
        local ok, problem = pcall(function()
            repeat
                app:render(app._term :: tui.session)
            until not app._running or (not app._layout and next(app._dirty) == nil)
        end)
        app._painting = false
        if not ok and app._running then
            app._error = tostring(problem)
            app:quit()
        end
    end)
end

function App.focus(self: application, node: widget)
    assert(belongs(self, node) and input.focusable(node), "focus target must be an interactive widget in this application")
    local ancestor: widget? = node
    while ancestor do
        assert(ancestor.options.visible ~= false, "cannot focus a hidden widget")
        ancestor = ancestor._parent
    end
    if self._focus == node then return end
    if self._focus then
        self._focus._focused = false
        self._dirty[self._focus] = true
    end
    self._focus = node
    node._focused = true
    self._dirty[node] = true
    schedule(self)
    if self._focusCallback then self._focusCallback(node) end
end

function App.render(self: application, term: paint.terminal)
    local width, height = term:size()
    if width ~= self._width or height ~= self._height then
        self._width, self._height = width, height
        self._layout = true
    end
    local full = self._layout
    if full then
        layout.arrange(self.root, 1, 1, width, height)
        self._stats.layouts += 1
        self._layout = false
        self._focusables = {}
        focusables(self.root, self._focusables)
        if not self._focus or not visible(self, self._focus) then
            if self._focus then self._focus._focused = false end
            self._focus = nil
            if self._focusables[1] then self:focus(self._focusables[1]) end
        end
    end
    if not full and next(self._dirty) == nil then return end
    local dirty = self._dirty
    self._dirty = {}
    if full then
        if self.root.options.visible == false then term:fill(1, 1, width, height) end
        self._stats.paints += paint.node(self.root, term)
    else
        for node in dirty do
            if not belongs(self, node) then continue end
            local ancestor = node._parent
            local covered = false
            while ancestor do
                if dirty[ancestor] then covered = true; break end
                ancestor = ancestor._parent
            end
            if not covered then self._stats.paints += paint.node(node, term, false) end
        end
    end
    self._stats.frames += 1
    term:present()
end

function App.dispatch(self: application, event: tui.event): boolean
    if event.kind == "resize" then
        self._layout = true
        schedule(self)
        return true
    end
    if event.kind == "key" and event.key == "tab" then
        if self._focus and self._focus._surface and input.handle(self._focus, event) then return true end
        local count = #self._focusables
        if count > 0 then
            local index = if self._focus then table.find(self._focusables, self._focus) or 0 else 0
            local nextIndex = (index - 1 + (if event.shift then -1 else 1)) % count + 1
            self:focus(self._focusables[nextIndex])
        end
        return true
    end
    if event.kind == "mouse" then
        local hit = input.hit(self.root, event.x, event.y)
        if hit then
            if event.action == "press" then self:focus(hit) end
            if input.handle(hit, event) then return true end
        end
    elseif self._focus and input.handle(self._focus, event) then return true end
    if self._key and self._key(event) then return true end
    if event.kind == "key" and event.ctrl and event.key == "c" then self:quit(); return true end
    return false
end

function App.onfocus(self: application, callback: (widget) -> ()) self._focusCallback = callback end
function App.focused(self: application): widget? return self._focus end
function App.cancel(self: application, thread: thread)
    self._jobs[thread] = nil
    if coroutine.status(thread) ~= "dead" then task.cancel(thread) end
end
function App.stats(self: application): stats return table.clone(self._stats) end
function App.onkey(self: application, callback: (tui.event) -> boolean) self._key = callback end
function App.running(self: application): boolean return self._running end
function App.quit(self: application)
    self._running = false
    if self._term then self._term:close() end
end
function App.spawn(self: application, callback: () -> ()): thread
    assert(self._running, "application tasks require a running application")
    local thread = task.defer(function()
        local ok, problem = pcall(callback)
        self._jobs[coroutine.running()] = nil
        if not ok and self._running then self._error = tostring(problem); self:quit() end
    end)
    self._jobs[thread] = true
    return thread
end
function App.run(self: application, options: tui.options?, start: (() -> ())?)
    assert(not self._running, "application is already running")
    self._running = true
    self._error = nil
    self._layout = true
    local ok, problem = pcall(function()
        tui.run(options, function(term)
            self._term = term
            self._painting = true
            self:render(term)
            self._painting = false
            if start then start() end
            schedule(self)
            while self._running do
                local readok, event = pcall(function() return term:read() end)
                if not readok then
                    if self._running then error(event, 0) end
                    break
                end
                self:dispatch(event :: tui.event)
            end
        end)
    end)
    self._running = false
    self._term = nil
    self._painting = false
    self._scheduled = false
    if self._renderer and coroutine.status(self._renderer) ~= "dead" then task.cancel(self._renderer) end
    self._renderer = nil
    for thread in self._jobs do
        if coroutine.status(thread) ~= "dead" then task.cancel(thread) end
    end
    table.clear(self._jobs)
    if self._error then error(self._error, 0) end
    if not ok then error(problem, 0) end
end

function App.new(root: widget): application
    assert(root._parent == nil and root._notify == nil, "application root already belongs to a tree")
    local app: application = setmetatable({
        root = root, _dirty = {}, _layout = true, _focus = nil, _focusables = {},
        _width = 0, _height = 0, _stats = { layouts = 0, paints = 0, frames = 0 },
        _term = nil, _scheduled = false, _painting = false, _running = false, _error = nil,
        _jobs = {}, _renderer = nil, _key = nil, _focusCallback = nil,
    }, { __index = App }) :: any
    widgets.attach(root, function(node, needsLayout)
        app._dirty[node] = true
        if needsLayout then app._layout = true end
        schedule(app)
    end)
    return app
end
return App
