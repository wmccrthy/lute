--!strict
local editor = require("../../batteries/editor")
local task = require("@std/task")
local filename = select(2, ...)
local workspace = editor.workspace()
local resumed = false
workspace:registerpane("io", function(ctx)
    ctx:spawn(function()
        workspace:opendocument(filename)
        resumed = true
    end)
    ctx:spawn(function()
        workspace:closepane(ctx.id, true)
        workspace:quit(true)
    end)
    return {title = "I/O scope", view = ctx.ui.text("reading")}
end)
workspace:openpane("io")
workspace:run()
local absolute = workspace:canonical(filename)
local deadline = os.clock() + 3
while not workspace:documents()[absolute] and os.clock() < deadline do task.wait(0.001) end
assert(workspace:documents()[absolute], "cancellation abandoned the document operation")
assert(not resumed, "closed pane resumed after I/O")
