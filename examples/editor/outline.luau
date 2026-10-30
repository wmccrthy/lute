--!strict
-- An ordinary extension module. No dependency on the editor application's internals.
local editor = require("../../batteries/editor")
local ui = require("../../batteries/ui")
return function(workspace: editor.workspace)
    workspace:registerpane("outline", function(ctx)
        local list = ui.list({items = {}})
        local filename: string? = nil
        local doc: editor.document? = nil
        local symbols: {[number]: string} = {}
        local function render()
            local lines: {number} = {}
            for line in symbols do table.insert(lines, line) end
            table.sort(lines)
            local items: {ui.item} = {}
            for _, line in lines do table.insert(items, {id = tostring(line), text = `{line}  {symbols[line]}`}) end
            list:setitems(items)
            ctx:settitle("Outline / " .. (filename and filename:match("[^/\\]+$") or "no file"))
        end
        local function scan(first: number, last: number)
            if not doc then return end
            for line = first, last do
                local text = doc:line(line)
                local name = text:match("^%s*local%s+function%s+([%w_%.:]+)") or text:match("^%s*function%s+([%w_%.:]+)")
                symbols[line] = name
            end
        end
        local function follow(pane: editor.pane?)
            if not pane or not pane.document or pane.document == doc then return end
            local document = pane.document; assert(document)
            filename, doc = pane.path, document
            symbols = {}; scan(1, document:linecount()); render()
        end
        follow(workspace:activepane())
        ctx:on("pane.focused", follow)
        ctx:on("document.changed", function(event)
            if event.document ~= doc then return end
            local change = event.change
            if change.first.line == change.last.line and change.first.line == change.finish.line then
                local previous = symbols[change.first.line]
                scan(change.first.line, change.first.line)
                if previous ~= symbols[change.first.line] then render() end
                return
            end
            local updated: {[number]: string} = {}
            for line, name in symbols do
                if line < change.first.line then updated[line] = name
                elseif line > change.last.line then updated[line + change.finish.line - change.last.line] = name end
            end
            symbols = updated
            scan(change.first.line, change.finish.line)
            render()
        end)
        list:on("submit", function(event)
            if filename and event.item then ctx:emit("editor.navigate", {path = filename, line = tonumber(event.item.id)}) end
        end)
        return {title = "Outline", view = list}
    end)
    workspace:registercommand({id = "outline.open", title = "Open function outline", key = "f3", run = function()
        for _, pane in workspace:panes() do if pane.kind == "outline" then workspace:focuspane(pane.id); return end end
        local pane = workspace:openpane("outline", {dock = "right"})
        workspace:resizepane(pane.id, 25)
    end})
end
