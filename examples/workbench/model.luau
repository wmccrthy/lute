--!strict
local ui = require("../../batteries/ui")
export type project = { id: string, name: string, group: string, status: string, builds: number }
local model = {}

function model.projects(): {project}
    local result: {project} = {}
    local groups = { "runtime", "tools", "platform", "services", "libraries" }
    for i = 1, 12000 do
        result[i] = {
            id = tostring(i), name = string.format("%s/%04d", groups[(i - 1) % #groups + 1], i),
            group = groups[(i - 1) % #groups + 1], status = if i % 7 == 0 then "needs build" else "ready",
            builds = i % 24,
        }
    end
    return result
end

function model.index(projects: {project}): {[string]: project}
    local result: {[string]: project} = {}
    for _, project in projects do result[project.id] = project end
    return result
end

function model.filter(projects: {project}, query: string): {ui.item}
    query = string.lower(query)
    local items: {ui.item} = {}
    for _, project in projects do
        if string.find(string.lower(project.name), query, 1, true) then
            table.insert(items, { id = project.id, text = project.name })
        end
    end
    return items
end
return model
