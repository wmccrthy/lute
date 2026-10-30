--!strict
-- Load with --extension examples/editor/metrics.luau. Uses only the public pane API.
local editor = require("../../batteries/editor")
return function(workspace: editor.workspace)
    workspace:registerpane("metrics", function(ctx)
        local source = workspace:activepane()
        if not source or not source.document then
            for _, candidate in workspace:panes() do if candidate.document then source = candidate; break end end
        end
        local doc: editor.document? = if source then source.document else nil
        local filename: string? = if source then source.path else nil
        if not doc and ctx.state and ctx.state.path then filename = ctx.state.path; doc = workspace:opendocument(filename :: string) end
        local surface = ctx.ui.surface({paint = function(canvas)
            canvas:text(2, 2, "Document statistics", {fg = "#82aaff", bold = true})
            if not doc then canvas:text(2, 4, "Focus a document to inspect it."); return end
            canvas:text(2, 4, `Lines: {doc:linecount()}`)
            canvas:text(2, 5, `Bytes: {doc:stats().bytes}`)
            canvas:text(2, 6, `Revision: {doc:revision()}`)
            canvas:text(2, 7, if doc:dirty() then "Modified" else "Saved")
        end})
        ctx:on("pane.focused", function(pane)
            if pane.document then doc, filename = pane.document, pane.path; ctx:invalidate() end
        end)
        ctx:on("document.changed", function(event) if event.document == doc then ctx:invalidate() end end)
        ctx:on("document.saved", function(event) if event.document == doc then ctx:invalidate() end end)
        return {title = "Statistics", view = surface, save = function() return {path = filename} end}
    end)
    workspace:registercommand({id = "metrics.open", title = "Open document statistics", key = "f8", run = function()
        local source = workspace:activepane()
        if not source or not source.document then
            for _, candidate in workspace:panes() do if candidate.document then source = candidate; break end end
        end
        workspace:openpane("metrics", {dock = "bottom", target = if source then source.id else nil})
    end})
end
