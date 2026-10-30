--!strict
local editor = require("../../batteries/editor")
local ui = require("../../batteries/ui")
local fs = require("@std/fs")
local path = require("@std/path")
export type services = {
    views: {[string]: editor.view},
    openfile: (string, editor.openoptions?) -> editor.pane,
    current: () -> editor.view?,
}
local panes = {}
function panes.install(workspace: editor.workspace): services
    local views: {[string]: editor.view} = {}
    local services: services
    local lastEditor: string? = nil
    local function current(): editor.view?
        local pane = workspace:activepane()
        return (if pane then views[pane.id] else nil) or (if lastEditor then views[lastEditor] else nil)
    end
    local function safe(callback: () -> ())
        local ok, problem = pcall(callback)
        if not ok then workspace:status((tostring(problem):gsub("^.-:%d+:%s*", ""))) end
    end
    workspace:registerpane("editor", function(ctx)
        local filename = workspace:canonical(assert(ctx.state and ctx.state.path, "editor pane needs a path"))
        local doc = workspace:opendocument(filename)
        local view = editor.view(doc, workspace.clipboard)
        views[ctx.id] = view
        local function status()
            if workspace:activepane() and (workspace:activepane() :: editor.pane).id == ctx.id then
                workspace:status(`{if doc:dirty() then "Modified" else "Saved"} / Ln {view:cursor().line}, Col {view:cellcolumn() + 1} / {filename}`)
            end
        end
        view:onstate(status)
        if ctx.state.line then view:restore(ctx.state) end
        ctx:onclose(function() views[ctx.id] = nil; view:close() end)
        local function title() ctx:settitle((path.basename(filename) or filename) .. (if doc:dirty() then " *" else "")); status() end
        ctx:on("document.changed", function(event) if event.document == doc then title() end end)
        ctx:on("document.saved", function(event) if event.document == doc then title() end end)
        ctx:on("pane.focused", function(pane) if pane.id == ctx.id then lastEditor = ctx.id; status() end end)
        ctx:command("document.save", "Save file", "ctrl+s", function() safe(function() workspace:savedocument(filename); title(); workspace:status(if doc:dirty() then `Saved snapshot / newer edits remain / {filename}` else `Saved {filename}`) end) end)
        ctx:command("document.reload", "Reload from disk", "f5", function() safe(function() workspace:reloaddocument(filename); workspace:status(`Reloaded {filename}`) end) end)
        ctx:command("document.discardreload", "Reload discarding changes", nil, function() safe(function() workspace:reloaddocument(filename, true); workspace:status(`Reloaded {filename}`) end) end)
        ctx:command("document.undo", "Undo", nil, function() view:undo() end)
        ctx:command("document.redo", "Redo", nil, function() view:redo() end)
        return {
            title = (path.basename(filename) or filename) .. (if doc:dirty() then " *" else ""),
            view = view.widget, document = doc, path = filename,
            canclose = function()
                if not doc:dirty() then return true end
                for id, candidate in views do if id ~= ctx.id and candidate.doc == doc then return true end end
                workspace:status("Unsaved changes / Ctrl-S to save before closing this view")
                return false
            end,
            save = function()
                local state: any = view:state(); state.path = filename; return state
            end,
        }
    end)
    local function openfile(filename: string, options: editor.openoptions?): editor.pane
        filename = workspace:canonical(filename)
        local opts: editor.openoptions = table.clone(options or ({} :: editor.openoptions))
        if not opts.dock then
            for _, pane in workspace:panes() do if pane.kind == "editor" and pane.path == filename then workspace:focuspane(pane.id); return pane end end
            for _, pane in workspace:panes() do if pane.kind == "editor" then opts.target = pane.id; break end end
        end
        opts.state = {path = filename}
        local pane = workspace:openpane("editor", opts)
        lastEditor = pane.id
        return pane
    end
    services = {views = views, openfile = openfile, current = current}
    workspace:registerpane("files", function(ctx)
        local directory = workspace:canonical(if ctx.state and ctx.state.directory then ctx.state.directory else ".")
        local listing = ui.list({items = {}})
        local entries: {[string]: fs.DirectoryEntry} = {}
        local function refresh()
            local items: {ui.item} = {{id = "..", text = "../"}}
            local children = fs.listDirectory(directory)
            table.sort(children, function(a: fs.DirectoryEntry, b: fs.DirectoryEntry)
                if (a.type == "dir") ~= (b.type == "dir") then return a.type == "dir" end
                return a.name < b.name
            end)
            entries = {}
            for _, entry in children do
                entries[entry.name] = entry
                table.insert(items, {id = entry.name, text = entry.name .. (if entry.type == "dir" then "/" else ""), style = if entry.type == "dir" then {fg = "#82aaff"} else nil})
            end
            listing:setitems(items)
            ctx:settitle(path.basename(directory) or directory)
        end
        listing:on("submit", function(event)
            if not event.item then return end
            safe(function()
                local name = event.item.id
                if name == ".." then directory = path.dirname(directory); refresh()
                elseif entries[name].type == "dir" then directory = path.format(path.join(directory, name)); refresh()
                else
                    local hasEditor = false
                    for _, pane in workspace:panes() do if pane.kind == "editor" then hasEditor = true; break end end
                    openfile(path.format(path.join(directory, name)), if hasEditor then nil else {dock = "right", target = ctx.id})
                    if not hasEditor then workspace:resizepane(ctx.id, 25) end
                end
            end)
        end)
        ctx:command("files.refresh", "Refresh directory", "f5", function() safe(refresh) end)
        refresh()
        return {title = path.basename(directory) or directory, view = listing, save = function() return {directory = directory} end}
    end)
    workspace:registerpane("prompt", function(ctx)
        local mode = if ctx.state then ctx.state.mode else "open"
        local target = if ctx.state then ctx.state.target else nil
        local view = if target then views[target] else current()
        local field = ui.input({placeholder = if mode == "find" then "Find literal text" else if mode == "goto" then "Line number" else "File path (new files supported)"})
        if mode == "open" and ctx.state and ctx.state.value then field:setvalue(ctx.state.value) end
        local original = if view then view:cursor() else nil
        if mode == "find" then
            field:on("change", function(event)
                if view and original then
                    view:goto(original.line, original.column)
                    local found = view:find(event.value or "")
                    workspace:status(if found then `Match / Ln {view:cursor().line}` else "No match")
                end
            end)
        end
        field:on("submit", function(event)
            local value = event.value or ""
            safe(function()
                if mode == "open" then
                    local pane = openfile(value)
                    workspace:closepane(ctx.id, true); workspace:focuspane(pane.id)
                elseif mode == "goto" and view then
                    local line = tonumber(value); assert(line and line >= 1, "enter a positive line number")
                    view:goto(line, 0); workspace:closepane(ctx.id, true)
                    if target then workspace:focuspane(target) end
                elseif view then
                    if not view:find(value) then workspace:status("No match") end
                end
            end)
        end)
        return {title = if mode == "find" then "Find / Enter next / Esc close" else if mode == "goto" then "Go to line" else "Open file", view = field, transient = true}
    end)
    workspace:registerpane("commands", function(ctx)
        local commands = workspace:commands()
        local byId: {[string]: () -> ()} = {}
        local all: {ui.item} = {}
        for _, command in commands do
            byId[command.id] = command.run
            table.insert(all, {id = command.id, text = command.title .. (if command.key then " / " .. command.key else "")})
        end
        local field = ui.input({placeholder = "Filter commands..."})
        local list = ui.list({items = all})
        field:on("change", function(event)
            local items: {ui.item} = {}
            local query = string.lower(event.value or "")
            for _, item in all do if string.find(string.lower(item.text), query, 1, true) then table.insert(items, item) end end
            list:setitems(items)
        end)
        local function activate()
            -- The selected list can change after filtering without a select event.
            local item = list:selecteditem()
            if not item then workspace:status("No matching command"); return end
            local id = item.id
            workspace:closepane(ctx.id, true)
            if ctx.state and ctx.state.target then pcall(function() workspace:focuspane(ctx.state.target) end) end
            if id and byId[id] then safe(byId[id]) end
        end
        field:on("submit", activate); list:on("submit", activate)
        return {title = "Commands / Tab selects list / Enter runs", view = ui.column({flex = 1}, {field, list}), transient = true}
    end)
    local function prompt(mode: string)
        local pane = workspace:activepane()
        local target = if pane and views[pane.id] then pane.id else lastEditor
        if mode ~= "open" and not target then workspace:status("Open a file first"); return end
        local window = workspace:openpane("prompt", {dock = "bottom", target = target, state = {mode = mode, target = target}})
        workspace:resizepane(window.id, 15)
    end
    workspace:registercommand({id = "editor.open", title = "Open file", key = "ctrl+o", run = function() prompt("open") end})
    workspace:registercommand({id = "editor.find", title = "Find in document", key = "ctrl+f", run = function() prompt("find") end})
    workspace:registercommand({id = "editor.goto", title = "Go to line", key = "ctrl+g", run = function() prompt("goto") end})
    workspace:registercommand({id = "editor.commands", title = "Command palette", key = "f1", run = function()
        local pane = workspace:activepane()
        local window = workspace:openpane("commands", {dock = "bottom", state = {target = if pane then pane.id else nil}})
        workspace:resizepane(window.id, 35)
    end})
    workspace:registercommand({id = "editor.close", title = "Close pane or tab", key = "ctrl+w", run = function()
        local pane = workspace:activepane(); if pane then workspace:closepane(pane.id) end
    end})
    workspace:registercommand({id = "editor.dismiss", title = "Dismiss prompt", key = "escape", run = function()
        local pane = workspace:activepane()
        if pane and pane.transient then workspace:closepane(pane.id, true); if lastEditor then pcall(function() workspace:focuspane(lastEditor :: string) end) end end
    end})
    workspace:registercommand({id = "editor.split", title = "Split another view of this document", key = "f4", run = function()
        local pane = workspace:activepane()
        if pane and pane.path then openfile(pane.path, {dock = "right", target = pane.id}) end
    end})
    workspace:registercommand({id = "editor.quit", title = "Quit", key = "ctrl+q", run = function() workspace:quit() end})
    workspace:registercommand({id = "editor.discardquit", title = "Quit without saving", run = function() workspace:quit(true) end})
    workspace:on("editor.navigate", function(event)
        safe(function() local pane = openfile(event.path); local view = views[pane.id]; view:goto(event.line, 0) end)
    end)
    return services
end
return panes
