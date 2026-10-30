--!strict
-- Entrypoint: build/release/lute/cli/lute examples/workbench/init.luau
local ui = require("@self/../../batteries/ui")
local task = require("@std/task")
local model = require("@self/model")
local views = require("@self/views")

local projects = model.projects()
local view = views.create()
local app = ui.app(view.root)
local byId = model.index(projects)
local items = model.filter(projects, "")
view.projects:setitems(items)
local logItems: {ui.item} = {}
local building = false
local logSequence = 0

local function selected(): model.project?
    local item = items[view.projects:selected()]
    return if item then byId[item.id] else nil
end

local function inspect()
    local project = selected()
    view.name:settext(if project then project.name else "No matching projects")
    view.group:settext(if project then `Group: {project.group}` else "")
    view.state:settext(if project then `Status: {project.status}` else "")
    view.history:settext(if project then `Successful builds: {project.builds}` else "")
end

local function appendLog(message: string, color: number?)
    logSequence += 1
    table.insert(logItems, { id = tostring(logSequence), text = message, style = { fg = color or 7 } })
    -- Bound demo history while retaining stable IDs across truncation.
    if #logItems > 200 then table.remove(logItems, 1) end
    view.logs:setitems(logItems)
    view.logs:select(#logItems)
end

local function build()
    local project = selected()
    if not project or building then return end
    building = true
    view.status:settext(`Building {project.name}; navigation stays responsive.`)
    appendLog(`> build {project.name}`, 14)
    app:spawn(function()
        local stages = { "Resolve dependencies", "Compile Luau", "Link runtime", "Run checks", "Package artifact" }
        for index, stage in stages do
            task.wait(0.18)
            view.progress:settext(string.rep("#", index * 4) .. string.rep("-", 20 - index * 4) .. ` {index * 20}%`)
            appendLog(`[{index}/{#stages}] {stage}`, 7)
        end
        project.builds += 1
        project.status = "ready"
        building = false
        inspect()
        appendLog(`Build complete: {project.name}`, 10)
        view.status:settext(`Build complete: {project.name}`)
    end)
end

view.search:on("change", function(event)
    items = model.filter(projects, event.value or "")
    view.projects:setitems(items)
    view.count:settext(`{#items} projects`)
    inspect()
end)
view.search:on("submit", function() app:focus(view.projects) end)
view.projects:on("select", inspect)
view.projects:on("submit", build)
view.run:on("press", build)
view.quit:on("press", function() app:quit() end)
app:onkey(function(event)
    if event.kind ~= "key" then return false end
    if event.key == "f5" then build(); return true end
    if event.key == "escape" then
        view.search:setvalue("")
        items = model.filter(projects, "")
        view.projects:setitems(items)
        view.count:settext(`{#items} projects`)
        inspect()
        app:focus(view.search)
        return true
    end
    return false
end)
inspect()
appendLog("Local build simulator. No external processes or network requests.", 8)
app:run({ mouse = true })
