--!strict
-- Entrypoint: lute examples/editor/init.luau [file-or-directory] [--session file] [--extension module]
local editor = require("@self/../../batteries/editor")
local fs = require("@std/fs")
local path = require("@std/path")
local json = require("@std/json")
local luau = require("@std/luau")
local panes = require("@self/panes")
local installOutline = require("@self/outline")

local args: {string} = {...}
local target = "."
local session: string? = nil
local extensions: {string} = {}
local index = 2
while index <= #args do
    local argument = args[index]
    if argument == "--session" then index += 1; session = assert(args[index], "--session needs a filename")
    elseif argument == "--extension" then index += 1; table.insert(extensions, (assert(args[index], "--extension needs a module path")))
    else target = argument end
    index += 1
end
local workspace = editor.workspace()
local services = panes.install(workspace)
installOutline(workspace)
for _, filename in extensions do
    local install = luau.loadModule(path.resolve(filename)) :: (editor.workspace) -> ()
    assert(type(install) == "function", "extension must return an install(workspace) function")
    install(workspace)
end
local restored = false
local sessionWritable = true
local restoreError: string? = nil
if session and fs.exists(session) then
    local ok, problem = pcall(function() workspace:restore(json.deserialize(fs.readFileToString(session :: string))) end)
    if not ok then sessionWritable = false; restoreError = `Could not restore session: {tostring(problem)}` else restored = true end
end
if not restored then
    local absolute = path.format(path.resolve(target))
    if fs.exists(absolute) and fs.type(absolute) == "dir" then workspace:openpane("files", {state = {directory = absolute}})
    else
        local browser = workspace:openpane("files", {state = {directory = path.dirname(absolute)}})
        services.openfile(absolute, {dock = "right", target = browser.id})
        workspace:resizepane(browser.id, 22)
    end
end
if restoreError then workspace:status(restoreError) end
-- Persist only when quitting is accepted; document contents are saved explicitly.
if session and sessionWritable then
    workspace:on("workspace.quitting", function()
        fs.writeStringToFile(session :: string, json.serialize(workspace:snapshot(), true))
    end)
end
workspace:run({mouse = true})
