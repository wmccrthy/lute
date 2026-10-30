--!strict
local ui = require("@batteries/ui")
local task = require("@std/task")

local viewport = ui.text("viewport")
local value = ui.text("value")
local background = ui.text("background waiting")
local input = ui.input({})
local root = ui.column({}, { viewport, input, value, background, ui.list({ items = {} }) })
local app = ui.app(root)
input:on("change", function(event) value:settext("value " .. (event.value or "")) end)
app:run(nil, function()
    app:spawn(function()
        task.wait(0.1)
        background:settext("background ready")
        while app:running() do
            local rect = root:bounds()
            viewport:settext(`viewport {rect.width}x{rect.height}`)
            task.wait(0.02)
        end
    end)
end)
assert(input:value() == "hello", "resize lost input state")
