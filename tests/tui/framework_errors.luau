--!strict
local ui = require("@batteries/ui")
local task = require("@std/task")
local tui = require("@std/tui")

for _, mode in { "job", "paint" } do
    local poisoned = false
    local list = ui.list({ items = { { id = "one", text = "ready" } }, renderitem = function(item)
        if poisoned then error("expected paint failure") end
        return item.text
    end })
    local app = ui.app(list)
    local ok, problem = pcall(function()
        app:run(nil, function()
            app:spawn(function()
                task.wait(0.02)
                if mode == "job" then error("expected job failure") end
                poisoned = true
                list:setstyle({ fg = 2 })
            end)
        end)
    end)
    assert(not ok and tostring(problem):find(`expected {mode} failure`, 1, true), tostring(problem))
end
-- Reopening in the same runtime proves both failure paths released ownership.
tui.run(nil, function(term)
    term:text(1, 1, "caught framework errors")
    term:present()
end)
