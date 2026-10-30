--!strict
local test = require("@std/test")
local tui = require("@std/tui")
local ui = require("@batteries/ui")

local function terminal(width: number, height: number)
    local result = { width = width, height = height, writes = 0, fills = 0, frames = 0 }
    function result:size()
        return result.width, result.height
    end
    function result:text(_x: number, _y: number, _text: string, _style: tui.style?)
        result.writes += 1
    end
    function result:fill(_x: number, _y: number, _width: number, _height: number, _style: tui.style?)
        result.fills += 1
    end
    function result:present()
        result.frames += 1
    end
    return result
end

local function key(value: string, text: string?, shift: boolean?): tui.event
    return { kind = "key", key = value, text = text or "", ctrl = false, alt = false, shift = shift or false }
end

test.suite("RetainedUI", function(suite)
    suite:case("viewport resizing distributes and clips nested layouts", function(assert)
        local left = ui.box({ width = 20, title = "left" }, { ui.text("left content") })
        local right = ui.box({ flex = 1, title = "right" }, { ui.list({ items = {} }) })
        local app = ui.app(ui.row({ gap = 1 }, { left, right }))
        local term = terminal(80, 24)
        app:render(term)
        assert.eq(left:bounds().width, 20)
        assert.eq(right:bounds().width, 59)
        assert.eq(right:bounds().height, 24)
        term.width, term.height = 12, 3
        app:render(term)
        assert.eq(left:bounds().width, 12)
        assert.eq(right:bounds().width, 0)
        term.width, term.height = 100, 40
        app:render(term)
        assert.eq(right:bounds().width, 79)
        assert.eq(right:bounds().height, 40)
    end)

    suite:case("resize preserves logical focus and nested intrinsic sizes propagate", function(assert)
        local label = ui.text("abc")
        local column = ui.column({}, {label})
        local button = ui.button("action")
        local app = ui.app(ui.row({}, {column, button}))
        local term = terminal(40, 8)
        app:render(term)
        app:focus(button)
        label:settext("abcdef")
        app:render(term)
        assert.eq(column:bounds().width, 6)
        term.width, term.height = 1, 1
        app:render(term)
        term.width, term.height = 40, 8
        app:render(term)
        assert.that(button:focused())
    end)

    suite:case("local edits avoid layout and unrelated list work", function(assert)
        local draws = 0
        local items: {ui.item} = {}
        for i = 1, 20000 do
            items[i] = { id = tostring(i), text = `item {i}` }
        end
        local input = ui.input({ placeholder = "filter" })
        local list = ui.list({ items = items, renderitem = function(item)
            draws += 1
            return item.text
        end })
        local app = ui.app(ui.column({}, { input, list }))
        local term = terminal(80, 24)
        app:render(term)
        assert.eq(draws, 23)
        local layouts = app:stats().layouts
        app:focus(input)
        app:dispatch(key("a", "a"))
        app:render(term)
        assert.eq(input:value(), "a")
        assert.eq(app:stats().layouts, layouts)
        assert.eq(draws, 23)
        local frames = term.frames
        input:setvalue("a")
        app:render(term)
        assert.eq(term.frames, frames)
    end)

    suite:case("focus consumes text and routes semantic events", function(assert)
        local input = ui.input({})
        local button = ui.button("Run")
        local app = ui.app(ui.column({}, { input, button }))
        app:render(terminal(40, 8))
        local activated = 0
        button:on("press", function()
            activated += 1
        end)
        app:focus(input)
        assert.that(app:dispatch(key("q", "q")))
        assert.eq(input:value(), "q")
        app:dispatch(key("tab"))
        assert.that(button:focused())
        app:dispatch(key("enter"))
        assert.eq(activated, 1)
        button:setvisible(false)
        app:render(terminal(40, 8))
        assert.that(input:focused())
        app:dispatch({ kind = "paste", text = "\nhello\r\nworld" })
        assert.eq(input:value(), "qhelloworld")
        app:dispatch({ kind = "paste", text = "\255" })
        assert.eq(input:value(), "qhelloworld")
    end)

    suite:case("list navigation scrolls and preserves selection by identity", function(assert)
        local items: {ui.item} = {}
        for i = 1, 100 do
            items[i] = { id = tostring(i), text = tostring(i) }
        end
        local list = ui.list({ items = items })
        local app = ui.app(list)
        local term = terminal(20, 4)
        app:render(term)
        app:focus(list)
        app:dispatch(key("end"))
        app:render(term)
        assert.eq(list:selected(), 100)
        assert.eq(list:scroll(), 96)
        list:setitems({ items[100], items[1] })
        app:render(term)
        assert.eq(list:selected(), 1)
        assert.eq(list:scroll(), 0)
        app:dispatch({ kind = "mouse", x = 1, y = 2, button = 1, action = "press", ctrl = false, alt = false, shift = false })
        assert.eq(list:selected(), 2)
    end)

    suite:case("input horizontal viewport follows caret and expands after resize", function(assert)
        local field = ui.input({ value = "abcdefghij" })
        local app = ui.app(field)
        local term = terminal(4, 1)
        app:render(term)
        assert.that(field:scroll() > 0)
        term.width = 20
        app:render(term)
        assert.eq(field:scroll(), 0)
        term.width = 4
        app:render(term)
        field:setvalue("a")
        app:render(term)
        assert.eq(field:scroll(), 0)
    end)

    suite:case("removal detaches focus and replacement clears old bounds", function(assert)
        local first = ui.input({ value = "first" })
        local root = ui.column({}, { first, ui.button("second") })
        local app = ui.app(root)
        local term = terminal(30, 6)
        app:render(term)
        app:focus(first)
        root:remove(first)
        app:render(term)
        assert.that(not first:focused())
        assert.eq(root:children()[1]:bounds().y, 1)
        assert.throws(function()
            root:append(root)
        end)
    end)
end)
