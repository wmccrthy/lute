--!strict
local ui = require("../../batteries/ui")
local views = {}

function views.create()
    local search = ui.input({ placeholder = "Filter 12,000 projects..." })
    local projects = ui.list({ items = {} })
    local name = ui.text("Select a project", { style = { fg = "#82aaff", bold = true } })
    local group = ui.text("")
    local state = ui.text("")
    local history = ui.text("")
    local progress = ui.text("No build running", { style = { fg = 10 } })
    local logs = ui.list({ items = {} })
    local run = ui.button("Build selected", { width = 20, style = { fg = 10 } })
    local quit = ui.button("Quit", { width = 10 })
    local status = ui.text("Ready", { style = { dim = true } })
    local count = ui.text("12,000 projects", { style = { dim = true } })
    local root = ui.column({ gap = 1, padding = 1 }, {
        ui.text("LUTE WORKBENCH / project console", { style = { fg = "#82aaff", bold = true } }),
        search,
        ui.row({ gap = 1, flex = 1 }, {
            ui.box({ width = 30, title = "Projects" }, { projects }),
            ui.column({ flex = 1, gap = 1 }, {
                ui.box({ height = 8, title = "Inspector", padding = 1 }, { name, group, state, history }),
                ui.box({ flex = 1, title = "Build output" }, { logs }),
                progress,
            }),
        }),
        ui.row({ gap = 1, height = 1 }, { run, quit, count }),
        status,
        ui.text("Tab focus | Enter build | F5 build | Esc clear filter | Ctrl-C quit", { style = { dim = true } }),
    })
    return {
        root = root, search = search, projects = projects, name = name, group = group,
        state = state, history = history, progress = progress, logs = logs, run = run,
        quit = quit, status = status, count = count,
    }
end
return views
