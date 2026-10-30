--!strict
-- Headless document + viewport benchmark; excludes terminal I/O and filesystem work.
local editor = require("../batteries/editor")
local ui = require("../batteries/ui")
local lines = {}
for i = 1, 20000 do lines[i] = `local value{i} = {i}` end
local doc = editor.document(table.concat(lines, "\n"))
local view = editor.view(doc)
view:goto(10000, 0)
local app = ui.app(view.widget)
local rows = 0
local term = {
    size = function(_self: any) return 100, 30 end,
    fill = function(_self: any, _x: number, _y: number, _w: number, height: number, _style: any) rows += height end,
    text = function(_self: any, _x: number, _y: number, _value: string, _style: any) end,
    present = function(_self: any) end,
}
local cold = os.clock()
app:render(term)
local initial = os.clock() - cold
local reindexes = doc:stats().reindexes
rows = 0
local started = os.clock()
for _ = 1, 1000 do
    view:insert("x"); app:render(term)
    view:undo(); app:render(term)
end
local elapsed = os.clock() - started
assert(rows == 2000, `expected one row per edit/undo, got {rows}`)
assert(doc:stats().reindexes == reindexes)
assert(app:stats().layouts == 1)
print(string.format("20,000-line document: cold render at line 10,000 %.2f ms; 2,000 edit/undo frames %.2f ms (%.2f us/frame); rows/frame 1; extra line-index rebuilds/layouts 0", initial * 1000, elapsed * 1000, elapsed * 1000000 / 2000))
view:close()
