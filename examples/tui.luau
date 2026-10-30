--!strict
-- Run: build/release/lute/cli/lute examples/tui.luau
local tui = require("@std/tui")

local entries = { "Read the terminal API", "Build something in Luau", "Ship a tiny terminal app" }
local done: { [number]: boolean } = {}
local selected = 1
local message = "Arrow keys or j/k to move; space/enter to toggle; q to quit."

tui.run({ mouse = true }, function(term)
    while true do
        local width, height = term:size()
        term:clear()
        term:text(2, 2, "Lute / terminal checklist", { fg = "#82aaff", bold = true })
        term:text(2, 3, string.rep("-", math.max(0, math.min(width - 3, 52))), { dim = true })
        for i, entry in entries do
            local prefix = if done[i] then "[x] " else "[ ] "
            term:text(2, i + 4, (if selected == i then "> " else "  ") .. prefix .. entry, {
                fg = if done[i] then 10 else 7,
                reverse = selected == i,
            })
        end
        term:text(2, math.max(9, height - 2), message, { dim = true })
        term:text(2, math.max(10, height - 1), `{width} columns x {height} rows | paste text to try bracketed paste`, { dim = true })
        term:present()
        local event = term:read()
        if event.kind == "key" then
            if event.key == "q" or (event.ctrl and event.key == "c") then
                break
            elseif event.key == "up" or event.key == "k" then
                selected = if selected > 1 then selected - 1 else #entries
            elseif event.key == "down" or event.key == "j" then
                selected = selected % #entries + 1
            elseif event.key == "space" or event.key == "enter" then
                done[selected] = not done[selected]
            end
        elseif event.kind == "mouse" and event.action == "press" then
            local row = event.y - 4
            if row >= 1 and row <= #entries then
                selected = row
                done[row] = not done[row]
            end
        elseif event.kind == "paste" then
            message = `Pasted {#event.text} bytes (never executed as commands).`
        end
    end
end)
