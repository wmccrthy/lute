--!strict

local native = require("@lute/tui")

export type style = native.style
export type options = native.options
export type event = native.event
export type session = native.session

local tui = {
    supported = native.supported,
    open = native.open,
    measure = native.measure,
    clip = native.clip,
}

--- Run an application and restore the terminal on return or error, including after yields.
function tui.run(options: options?, application: (session) -> ()): ()
    assert(type(application) == "function", "tui.run expects an application function")
    local terminal = native.open(options)
    local ok, result = pcall(application, terminal)
    terminal:close()
    if not ok then
        error(result, 0)
    end
end

return table.freeze(tui)
