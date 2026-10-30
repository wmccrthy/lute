--!strict
-- Headless Lua-side work benchmark. Timings exclude terminal I/O.
local ui = require("../batteries/ui")
local items: {ui.item} = {}
for i = 1, 20000 do items[i] = { id = tostring(i), text = `item {i}` } end
local listDraws = 0
local field = ui.input({})
local list = ui.list({ items = items, renderitem = function(item)
    listDraws += 1
    return item.text
end })
local app = ui.app(ui.column({}, {field, list}))
local term = {
    size = function(_self: any) return 80, 24 end,
    text = function(_self: any, _x: number, _y: number, _value: string, _style: any) end,
    fill = function(_self: any, _x: number, _y: number, _w: number, _h: number, _style: any) end,
    present = function(_self: any) end,
}
app:render(term)
local before = app:stats()
local started = os.clock()
for i = 1, 10000 do
    field:setvalue(tostring(i))
    app:render(term)
end
local elapsed = os.clock() - started
local after = app:stats()
assert(after.layouts == before.layouts)
assert(listDraws == 23)
assert(after.paints - before.paints == 10000)
print(string.format("10,000 local edits: %.2f ms (%.2f us/edit); extra layouts: 0; unrelated list row renders: 0; initial visible rows: %d / %d", elapsed * 1000, elapsed * 1000000 / 10000, listDraws, #items))
