--!strict
local ui = require("../ui")
local tui = require("@std/tui")
local fs = require("@std/fs")
local path = require("@std/path")
local process = require("@std/process")
local task = require("@std/task")
local documents = require("./document")
type document = documents.document
export type descriptor = {document: document?, path: string?, transient: boolean?, title: string, view: ui.widget, save: (() -> any)?, canclose: (() -> boolean)?}
export type pane = {
    id: string, kind: string, title: string, view: ui.widget, closed: boolean, document: document?, path: string?, transient: boolean?,
    save: (() -> any)?, canclose: (() -> boolean)?, _resources: {() -> ()},
}
export type context = {
    id: string, state: any, workspace: workspace, ui: typeof(ui),
    on: (context, string, (any) -> ()) -> (() -> ()), emit: (context, string, any) -> (),
    onclose: (context, () -> ()) -> (), invalidate: (context) -> (), settitle: (context, string) -> (),
    spawn: (context, () -> ()) -> (() -> ()),
    command: (context, string, string, string?, () -> ()) -> (),
}
export type factory = (context) -> descriptor
export type command = {id: string, title: string, key: string?, run: () -> (), owner: string?}
export type openoptions = {id: string?, state: any?, dock: string?, target: string?}
type leaf = {kind: "leaf", tabs: {pane}, active: number, root: ui.widget, header: ui.widget, body: ui.widget}
type split = {kind: "split", axis: string, ratio: number, first: tree, second: tree, root: ui.widget}
type tree = leaf | split
export type workspace = {
    ui: typeof(ui), app: ui.application, root: ui.widget, host: ui.widget, banner: ui.widget, statusbar: ui.widget,
    clipboard: {text: string}, _tree: tree, _registry: {[string]: factory}, _panes: {[string]: pane}, _order: {string},
    _commands: {[string]: command}, _events: {[string]: {[{}]: (any) -> ()}},
    _documents: {[string]: document}, _disk: {[string]: string}, _loading: {[string]: boolean}, _saving: {[string]: boolean}, _exists: {[string]: boolean},
    _documentSubscriptions: {() -> ()}, _active: string?, _next: number, _closed: boolean, _starts: {() -> ()},
    registerpane: (workspace, string, factory) -> (), openpane: (workspace, string, openoptions?) -> pane,
    closepane: (workspace, string, boolean?) -> boolean, focuspane: (workspace, string) -> (),
    resizepane: (workspace, string, number) -> (), activepane: (workspace) -> pane?, panes: (workspace) -> {pane}, nextpane: (workspace) -> (), nexttab: (workspace) -> (),
    registercommand: (workspace, command) -> (() -> ()), execute: (workspace, string) -> boolean, commands: (workspace) -> {command},
    on: (workspace, string, (any) -> ()) -> (() -> ()), emit: (workspace, string, any) -> (),
    snapshot: (workspace) -> any, restore: (workspace, any) -> (),
    reloaddocument: (workspace, string, boolean?) -> (), opendocument: (workspace, string) -> document, savedocument: (workspace, string) -> (),
    documents: (workspace) -> {[string]: document}, canonical: (workspace, string) -> string,
    status: (workspace, string) -> (), quit: (workspace, boolean?) -> boolean, run: (workspace, tui.options?) -> (), close: (workspace) -> (),
}
local Workspace = {}
-- A canceled pane may abandon its waiter, but must not strand an open file,
-- temporary save, or the per-document I/O lock. The worker owns its cleanup.
local function ioOperation(callback: () -> any): any
    local waiter = coroutine.running()
    local completed, success = false, false
    local value: any = nil
    task.defer(function()
        success, value = pcall(callback)
        completed = true
        if coroutine.status(waiter) == "suspended" then task.spawn(waiter) end
    end)
    coroutine.yield()
    assert(completed, "document operation resumed before completion")
    if not success then error(value, 0) end
    return value
end
local function detach(node: ui.widget) if node._parent then node._parent:remove(node) end end
local function firstControl(node: ui.widget): ui.widget?
    if node.options.visible == false then return nil end
    if node.kind == "input" or node.kind == "list" or node.kind == "button" or (node._surface and node._surface.input) then return node end
    for _, child in node:children() do local found = firstControl(child); if found then return found end end
    return nil
end
local function contains(root: ui.widget, node: ui.widget): boolean
    local current: ui.widget? = node
    while current do if current == root then return true end; current = current._parent end
    return false
end
local function leaves(node: tree, result: {leaf})
    if node.kind == "leaf" then table.insert(result, node) else leaves(node.first, result); leaves(node.second, result) end
end
local function findLeaf(self: workspace, id: string): leaf?
    local all: {leaf} = {}; leaves(self._tree, all)
    for _, node in all do for _, pane in node.tabs do if pane.id == id then return node end end end
    return nil
end
local function mount(node: leaf)
    local pane = node.tabs[node.active]
    local children = node.body:children()
    if pane and #children == 1 and children[1] == pane.view then node.header:invalidate(); return end
    for _, child in children do node.body:remove(child) end
    if pane then
        detach(pane.view)
        if pane.view.options.flex == nil then pane.view.options.flex = 1 end
        node.body:append(pane.view)
    end
    node.header:invalidate()
end
local function newLeaf(self: workspace): leaf
    local node: leaf
    local header = ui.surface({
        paint = function(canvas)
            local x = 1
            for index, pane in node.tabs do
                local title = (if index == node.active then " " else " ") .. tostring(index) .. ":" .. pane.title .. " "
                canvas:text(x, 1, title, {bg = if index == node.active then "#354d70" else "#202938", fg = "#d5dbe5", bold = index == node.active})
                x += tui.measure(title)
            end
            if #node.tabs == 0 then canvas:text(1, 1, " No panes / F1 commands", {dim = true}) end
        end,
        input = function(event)
            if event.kind ~= "mouse" or event.action ~= "press" then return false end
            local x = node.header:bounds().x
            for _, pane in node.tabs do
                local width = tui.measure(" " .. tostring(table.find(node.tabs, pane)) .. ":" .. pane.title .. " ")
                if event.x >= x and event.x < x + width then self:focuspane(pane.id); return true end
                x += width
            end
            return false
        end,
    }, {height = 1, flex = 0, style = {bg = "#202938"}})
    local body = ui.column({flex = 1}, {})
    node = {kind = "leaf", tabs = {}, active = 1, header = header, body = body, root = ui.column({flex = 1}, {header, body})}
    return node
end
local function build(node: tree): ui.widget
    detach(node.root)
    if node.kind == "leaf" then return node.root end
    local a, b = build(node.first), build(node.second)
    a.options.flex, b.options.flex = node.ratio, 100 - node.ratio
    a:invalidate(true); b:invalidate(true)
    node.root = if node.axis == "row" then ui.row({flex = 1, gap = 1}, {a, b}) else ui.column({flex = 1, gap = 1}, {a, b})
    return node.root
end
local function rebuild(self: workspace)
    for _, child in self.host:children() do self.host:remove(child) end
    self.host:append(build(self._tree))
end
local function replace(node: tree, target: tree, value: tree): tree
    if node == target then return value end
    if node.kind == "split" then node.first = replace(node.first, target, value); node.second = replace(node.second, target, value) end
    return node
end
local function prune(node: tree): tree?
    if node.kind == "leaf" then return if #node.tabs > 0 then node else nil end
    local a, b = prune(node.first), prune(node.second)
    if not a then return b end
    if not b then return a end
    node.first, node.second = a, b
    return node
end
local function own(pane: pane, cleanup: () -> ()): () -> ()
    local active = true
    local release: () -> ()
    release = function()
        if not active then return end
        active = false
        local index = table.find(pane._resources, release)
        if index then table.remove(pane._resources, index) end
        cleanup()
    end
    table.insert(pane._resources, release)
    return release
end
local function dispose(pane: pane)
    if pane.closed then return end
    pane.closed = true
    local problem: any = nil
    while #pane._resources > 0 do
        local cleanup = table.remove(pane._resources); assert(cleanup)
        local ok, errorValue = pcall(cleanup)
        if not ok and problem == nil then problem = errorValue end
    end
    table.clear(pane._resources)
    if problem ~= nil then error(problem, 0) end
end
function Workspace.registerpane(self: workspace, name: string, factory: factory)
    assert(not self._registry[name], "pane type is already registered")
    self._registry[name] = factory
end
function Workspace.on(self: workspace, topic: string, callback: (any) -> ()): () -> ()
    local subscriptions = self._events[topic]
    if not subscriptions then subscriptions = {}; self._events[topic] = subscriptions end
    local key = {}; subscriptions[key] = callback
    return function() subscriptions[key] = nil end
end
function Workspace.emit(self: workspace, topic: string, data: any)
    local subscriptions = self._events[topic]
    if not subscriptions then return end
    for key, callback in table.clone(subscriptions) do if subscriptions[key] then callback(data) end end
end
function Workspace.registercommand(self: workspace, command: command): () -> ()
    local key = (command.owner or "") .. ":" .. command.id
    assert(not self._commands[key], "command is already registered in this scope")
    if command.key then
        for _, existing in self._commands do
            assert(existing.owner ~= command.owner or existing.key ~= command.key, "key is already bound in this scope")
        end
    end
    self._commands[key] = table.clone(command)
    return function() self._commands[key] = nil end
end
function Workspace.activepane(self: workspace): pane?
    local focused = self.app:focused()
    if focused then
        local all: {leaf} = {}; leaves(self._tree, all)
        for _, leaf in all do
            if contains(leaf.root, focused) then return leaf.tabs[leaf.active] end
        end
    end
    return if self._active then self._panes[self._active] else nil
end
function Workspace.commands(self: workspace): {command}
    local pane = self:activepane()
    local available: {[string]: command} = {}
    for _, command in self._commands do if not command.owner then available[command.id] = command end end
    if pane then for _, command in self._commands do if command.owner == pane.id then available[command.id] = command end end end
    local result: {command} = {}
    for _, command in available do table.insert(result, command) end
    table.sort(result, function(a: command, b: command) return a.title < b.title end)
    return result
end
function Workspace.execute(self: workspace, id: string): boolean
    local active = self:activepane()
    local command = (if active then self._commands[active.id .. ":" .. id] else nil) or self._commands[":" .. id]
    if not command then return false end
    command.run(); return true
end
local function create(self: workspace, kind: string, options: openoptions): pane
    local factory = self._registry[kind]
    assert(factory, `unknown pane type {kind}`)
    self._next += 1
    if not options.id then while self._panes[`{kind}-{self._next}`] do self._next += 1 end end
    local id = options.id or (`{kind}-{self._next}`)
    assert(not self._panes[id], `pane ID already exists: {id}`)
    local pane: pane = {id = id, kind = kind, title = kind, view = ui.text(""), closed = false, _resources = {}}
    local ctx: context = {
        id = id, state = options.state, workspace = self, ui = ui,
        on = function(_ctx, topic, callback)
            assert(not pane.closed, "pane is closed")
            local cleanup = self:on(topic, function(data) if not pane.closed then callback(data) end end)
            return own(pane, cleanup)
        end,
        emit = function(_ctx, topic, data) if not pane.closed then self:emit(topic, data) end end,
        onclose = function(_ctx, callback) assert(not pane.closed, "pane is closed"); own(pane, callback) end,
        invalidate = function() if not pane.closed then pane.view:invalidate() end end,
        settitle = function(_ctx, title)
            if pane.closed then return end
            pane.title = title
            local leaf = findLeaf(self, id); if leaf then leaf.header:invalidate() end
        end,
        command = function(_ctx, commandId, title, key, callback)
            assert(not pane.closed, "pane is closed")
            local cleanup = self:registercommand({id = commandId, title = title, key = key, run = callback, owner = id})
            own(pane, cleanup)
        end,
        spawn = function(_ctx, callback)
            assert(not pane.closed, "pane is closed")
            local active, thread = true, nil :: thread?
            local release: () -> ()
            release = own(pane, function()
                active = false
                if thread and thread ~= coroutine.running() then self.app:cancel(thread) end
            end)
            local function launch()
                if active and not pane.closed then
                    thread = self.app:spawn(function()
                        local ok, result = pcall(callback)
                        release()
                        if not ok then error(result, 0) end
                    end)
                end
            end
            if self.app:running() then launch() else table.insert(self._starts, launch) end
            return release
        end,
    }
    local ok, descriptor = pcall(factory, ctx)
    if not ok then pcall(dispose, pane); error(descriptor, 0) end
    if type(descriptor) ~= "table" or type(descriptor.title) ~= "string" or not descriptor.view or descriptor.view._parent or descriptor.view._notify then
        pcall(dispose, pane); error("pane factory must return an unattached view and a title", 0)
    end
    pane.title, pane.view, pane.save, pane.canclose = descriptor.title, descriptor.view, descriptor.save, descriptor.canclose
    pane.document, pane.path, pane.transient = descriptor.document, descriptor.path, descriptor.transient
    self._panes[id] = pane; table.insert(self._order, id)
    return pane
end
function Workspace.openpane(self: workspace, kind: string, options: openoptions?): pane
    assert(not self._closed, "workspace is closed")
    local opts: openoptions = options or ({} :: openoptions)
    local dock = opts.dock or "tab"
    assert(dock == "tab" or dock == "left" or dock == "right" or dock == "top" or dock == "bottom", "invalid dock position")
    local active = self:activepane()
    local target = if opts.target then findLeaf(self, opts.target) else if active then findLeaf(self, active.id) else nil
    if not target then local all: {leaf} = {}; leaves(self._tree, all); target = all[1] end
    assert(target)
    local pane = create(self, kind, opts)
    if dock ~= "tab" and #target.tabs > 0 then
        local leaf = newLeaf(self)
        leaf.tabs = {pane}; mount(leaf)
        local forward = dock == "right" or dock == "bottom"
        local split: split = {kind = "split", axis = if dock == "left" or dock == "right" then "row" else "column", ratio = 50,
            first = if forward then target else leaf, second = if forward then leaf else target, root = ui.column({})}
        self._tree = replace(self._tree, target, split)
    else
        table.insert(target.tabs, pane); target.active = #target.tabs; mount(target)
    end
    rebuild(self); self:focuspane(pane.id); self:emit("panes.changed", nil)
    return pane
end
function Workspace.focuspane(self: workspace, id: string)
    local leaf = findLeaf(self, id)
    assert(leaf, "pane does not exist")
    for index, pane in leaf.tabs do if pane.id == id then leaf.active = index end end
    mount(leaf)
    self._active = id
    local pane = leaf.tabs[leaf.active]
    self.app:focus(firstControl(pane.view) or leaf.header)
    self:emit("pane.focused", pane)
end
function Workspace.panes(self: workspace): {pane}
    local result: {pane} = {}
    for _, id in self._order do if self._panes[id] then table.insert(result, self._panes[id]) end end
    return result
end
function Workspace.closepane(self: workspace, id: string, force: boolean?): boolean
    local previous = self:activepane()
    local pane = self._panes[id]
    if not pane then return false end
    if not force and pane.canclose and not pane.canclose() then return false end
    local leaf = findLeaf(self, id)
    assert(leaf)
    local index = table.find(leaf.tabs, pane); assert(index)
    table.remove(leaf.tabs, index); leaf.active = math.max(1, math.min(leaf.active, #leaf.tabs))
    mount(leaf); detach(pane.view)
    self._panes[id] = nil
    local order = table.find(self._order, id); if order then table.remove(self._order, order) end
    local ok, problem = pcall(dispose, pane)
    self._tree = prune(self._tree) or newLeaf(self)
    rebuild(self)
    local nextId = if previous and previous.id ~= id and self._panes[previous.id] then previous.id else if leaf.tabs[leaf.active] then leaf.tabs[leaf.active].id else self._order[1]
    if nextId then self:focuspane(nextId) else self._active = nil end
    self:emit("panes.changed", nil)
    if not ok then error(problem, 0) end
    return true
end
function Workspace.resizepane(self: workspace, id: string, percent: number)
    assert(percent >= 1 and percent <= 99, "pane percentage must be 1..99")
    local leaf = findLeaf(self, id); assert(leaf, "pane does not exist")
    local function visit(node: tree): boolean
        if node.kind == "leaf" then return false end
        if node.first == leaf then node.ratio = math.floor(percent); return true end
        if node.second == leaf then node.ratio = 100 - math.floor(percent); return true end
        return visit(node.first) or visit(node.second)
    end
    if visit(self._tree) then rebuild(self) end
end
function Workspace.nextpane(self: workspace)
    local all: {leaf} = {}; leaves(self._tree, all)
    local active = self:activepane()
    local current = if active then findLeaf(self, active.id) else nil
    local index = if current then table.find(all, current) or 0 else 0
    for step = 1, #all do local leaf = all[(index + step - 1) % #all + 1]; if leaf.tabs[leaf.active] then self:focuspane(leaf.tabs[leaf.active].id); return end end
end
function Workspace.nexttab(self: workspace)
    local active = self:activepane(); if not active then return end
    local leaf = findLeaf(self, active.id); assert(leaf)
    local next = leaf.tabs[leaf.active % #leaf.tabs + 1]; self:focuspane(next.id)
end
function Workspace.snapshot(self: workspace): any
    local function serialize(node: tree): any
        if node.kind == "split" then
            local a, b = serialize(node.first), serialize(node.second)
            if not a then return b end
            if not b then return a end
            return {kind = "split", axis = node.axis, ratio = node.ratio, first = a, second = b}
        end
        local tabs = {}
        for _, pane in node.tabs do if not pane.transient then table.insert(tabs, {id = pane.id, kind = pane.kind, state = if pane.save then pane.save() else nil}) end end
        if #tabs == 0 then return nil end
        return {kind = "leaf", tabs = tabs, active = if node.tabs[node.active] then node.tabs[node.active].id else nil}
    end
    local active = self:activepane()
    return {version = 1, tree = serialize(self._tree) or {kind = "leaf", tabs = {}}, active = if active then active.id else nil}
end
function Workspace.restore(self: workspace, data: any)
    assert(#self._order == 0 and data.version == 1, "restore requires an empty workspace and version 1 layout")
    local ids = {}
    local function validate(node: any, depth: number)
        assert(type(node) == "table" and depth <= 32, "invalid layout")
        if node.kind == "split" then
            assert((node.axis == "row" or node.axis == "column") and type(node.ratio) == "number" and node.ratio >= 1 and node.ratio <= 99, "invalid split")
            validate(node.first, depth + 1); validate(node.second, depth + 1)
        else
            assert(node.kind == "leaf" and type(node.tabs) == "table", "invalid leaf")
            for _, pane in node.tabs do
                assert(type(pane.id) == "string" and not ids[pane.id] and self._registry[pane.kind], "unknown pane type or duplicate pane ID")
                ids[pane.id] = true
            end
        end
    end
    validate(data.tree, 0)
    local function construct(value: any): tree
        if value.kind == "split" then return {kind = "split", axis = value.axis, ratio = math.floor(value.ratio), first = construct(value.first), second = construct(value.second), root = ui.column({})} end
        local leaf = newLeaf(self)
        for _, item in value.tabs do local pane = create(self, item.kind, {id = item.id, state = item.state}); table.insert(leaf.tabs, pane); if item.id == value.active then leaf.active = #leaf.tabs end end
        mount(leaf); return leaf
    end
    local ok, result = pcall(construct, data.tree)
    if not ok then
        for _, pane in self:panes() do pcall(dispose, pane) end
        self._panes, self._order = {}, {}
        error(result, 0)
    end
    self._tree = result :: tree
    rebuild(self)
    if data.active and self._panes[data.active] then self:focuspane(data.active)
    elseif self._order[1] then self:focuspane(self._order[1]) end
end
function Workspace.canonical(_self: workspace, filename: string): string return path.format(path.resolve(filename)) end
local function readDocument(self: workspace, filename: string): document
    local filename = self:canonical(filename)
    if self._documents[filename] then return self._documents[filename] end
    assert(not self._loading[filename], "document is already being opened")
    self._loading[filename] = true
    local ok, result = pcall(function()
        -- Refuse replacing a symlink on save; open its target explicitly instead.
        local name = path.basename(filename)
        for _, entry in fs.listDirectory(path.dirname(filename)) do assert(entry.name ~= name or entry.type ~= "link", "open the symbolic link target directly") end
        local exists = fs.exists(filename)
        local content = if exists then fs.readFileToString(filename) else ""
        self._exists[filename] = exists
        local doc = documents.new(content)
        self._documents[filename], self._disk[filename] = doc, content
        if not self._closed then
            table.insert(self._documentSubscriptions, doc:onchange(function(change)
                self:emit("document.changed", {path = filename, document = doc, change = change})
            end))
        end
        return doc
    end)
    self._loading[filename] = nil
    if not ok then error(result, 0) end
    return result :: document
end
local function savedocument(self: workspace, filename: string)
    local doc = self._documents[filename]; assert(doc, "document is not open")
    local expected = self._disk[filename]
    local existing = fs.exists(filename)
    local current = if existing then fs.readFileToString(filename) else ""
    assert(current == expected and existing == self._exists[filename], "file changed on disk; refusing to overwrite external changes")
    local revision, contents = doc:revision(), doc:text()
    self._next += 1
    local temporary = filename .. `.lute-save-{process.pid()}-{self._next}`
    local handle = fs.open(temporary, "x")
    fs.close(handle)
    local ok, problem = pcall(function()
        -- Copy first to retain the existing regular file's permission bits.
        if existing then fs.copy(filename, temporary) end
        local output = fs.open(temporary, "w")
        local written, writeError = pcall(fs.write, output, contents)
        fs.close(output)
        if not written then error(writeError, 0) end
        local stillExists = fs.exists(filename)
        local latest = if stillExists then fs.readFileToString(filename) else ""
        assert(latest == expected and stillExists == existing, "file changed during save")
        fs.move(temporary, filename)
    end)
    if not ok then pcall(fs.remove, temporary); error(problem, 0) end
    self._disk[filename] = contents
    self._exists[filename] = true
    if doc:revision() == revision then doc:marksaved() end
    self:emit("document.saved", {path = filename, document = doc})
end
local function writeDocument(self: workspace, filename: string)
    filename = self:canonical(filename)
    assert(not self._saving[filename] and not self._loading[filename], "document I/O is already in progress")
    self._saving[filename] = true
    local ok, problem = pcall(savedocument, self, filename)
    self._saving[filename] = nil
    if not ok then error(problem, 0) end
end
local function reloadDocument(self: workspace, filename: string, force: boolean?)
    filename = self:canonical(filename)
    local doc = self._documents[filename]; assert(doc, "document is not open")
    assert(force or not doc:dirty(), "document has unsaved edits; use Reload discarding changes explicitly")
    assert(not self._saving[filename] and not self._loading[filename], "document I/O is already in progress")
    self._loading[filename] = true
    local revision = doc:revision()
    local ok, result = pcall(fs.readFileToString, filename)
    self._loading[filename] = nil
    if not ok then error(result, 0) end
    assert(doc:revision() == revision, "document changed while reading from disk")
    doc:reset(result :: string)
    self._disk[filename], self._exists[filename] = result :: string, true
    self:emit("document.saved", {path = filename, document = doc})
end
function Workspace.opendocument(self: workspace, filename: string): document
    assert(not self._closed, "workspace is closed")
    filename = self:canonical(filename)
    if self._documents[filename] then return self._documents[filename] end
    return ioOperation(function() return readDocument(self, filename) end) :: document
end
function Workspace.savedocument(self: workspace, filename: string)
    assert(not self._closed, "workspace is closed")
    ioOperation(function() writeDocument(self, filename); return nil end)
end
function Workspace.reloaddocument(self: workspace, filename: string, force: boolean?)
    assert(not self._closed, "workspace is closed")
    ioOperation(function() reloadDocument(self, filename, force); return nil end)
end
function Workspace.documents(self: workspace): {[string]: document} return table.clone(self._documents) end
function Workspace.status(self: workspace, message: string) self.statusbar:settext(message) end
function Workspace.quit(self: workspace, force: boolean?): boolean
    if not force then
        for _, doc in self._documents do if doc:dirty() then self:status("Unsaved changes / Ctrl-S saves / F1 offers Quit without saving"); return false end end
        for _, pane in self._panes do if pane.canclose and not pane.canclose() then return false end end
    end
    self:emit("workspace.quitting", nil)
    if not force then
        for _, doc in self._documents do if doc:dirty() then self:status("Document changed while quitting; save before exiting"); return false end end
    end
    self.app:quit(); return true
end
function Workspace.close(self: workspace)
    if self._closed then return end
    self._closed = true
    if self.app:running() then self.app:quit() end
    local problem: any = nil
    for _, pane in self:panes() do local ok, err = pcall(dispose, pane); if not ok and problem == nil then problem = err end end
    for _, cleanup in self._documentSubscriptions do cleanup() end
    self._documentSubscriptions = {}
    self._events = {}; self._commands = {}; self._panes = {}; self._order = {}; self._starts = {}
    if problem then error(problem, 0) end
end
function Workspace.run(self: workspace, options: tui.options?)
    assert(not self._closed, "workspace is closed")
    local ok, problem = pcall(function()
        self.app:run(options, function()
            local starts = self._starts; self._starts = {}
            for _, start in starts do start() end
        end)
    end)
    local closed, closeError = pcall(function() self:close() end)
    if not ok then error(problem, 0) end
    if not closed then error(closeError, 0) end
end
function Workspace.new(): workspace
    local host = ui.column({flex = 1}, {})
    local banner = ui.text("LUTE EDITOR / F1 commands / F6 panes / F7 tabs / F10 quit", {style = {bg = "#202938", fg = "#82aaff"}})
    local statusbar = ui.text("Ready", {style = {bg = "#202938", fg = "#b4c4dc"}})
    local root = ui.column({}, {banner, host, statusbar})
    local self: workspace = setmetatable({
        ui = ui, app = ui.app(root), root = root, host = host, banner = banner, statusbar = statusbar,
        clipboard = {text = ""}, _tree = nil, _registry = {}, _panes = {}, _order = {},
        _commands = {}, _events = {}, _documents = {}, _disk = {}, _loading = {}, _saving = {}, _exists = {},
        _documentSubscriptions = {}, _active = nil, _next = 0, _closed = false, _starts = {},
    }, {__index = Workspace}) :: any
    self._tree = newLeaf(self); rebuild(self)
    self.app:onfocus(function()
        local pane = self:activepane()
        if pane and self._active ~= pane.id then self._active = pane.id; self:emit("pane.focused", pane) end
    end)
    self.app:onkey(function(event)
        if event.kind ~= "key" then return false end
        local key = (if event.ctrl then "ctrl+" else "") .. (if event.alt then "alt+" else "") .. (if event.shift then "shift+" else "") .. string.lower(event.key)
        local commands = self:commands()
        for _, command in commands do if command.owner and command.key == key then command.run(); return true end end
        for _, command in commands do if not command.owner and command.key == key then command.run(); return true end end
        if event.ctrl and event.key == "c" then return true end
        return false
    end)
    self:registercommand({id = "workspace.nextpane", title = "Focus next pane", key = "f6", run = function() self:nextpane() end})
    self:registercommand({id = "workspace.nexttab", title = "Focus next tab", key = "f7", run = function() self:nexttab() end})
    self:registercommand({id = "workspace.quit", title = "Quit", key = "f10", run = function() self:quit() end})
    return self
end
return Workspace
