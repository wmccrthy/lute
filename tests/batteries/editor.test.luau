--!strict
local test = require("@std/test")
local editor = require("@batteries/editor")
local ui = require("@batteries/ui")

test.suite("Editor", function(suite)
    suite:case("transactions preserve line endings and undo saved identity", function(assert)
        local doc = editor.document("one\r\ntwo\nthree")
        doc:marksaved()
        doc:edit({line = 1, column = 3}, {line = 2, column = 0}, "!")
        assert.eq(doc:text(), "one!two\nthree")
        assert.that(doc:dirty())
        doc:undo()
        assert.eq(doc:text(), "one\r\ntwo\nthree")
        assert.that(not doc:dirty())
        doc:redo()
        assert.eq(doc:line(1), "one!two")
        doc:marksaved()
        doc:undo()
        assert.that(doc:dirty())
        doc:redo()
        assert.that(not doc:dirty())
    end)

    suite:case("edits validate UTF8 boundaries before changing the document", function(assert)
        local doc = editor.document("aé界\nend")
        assert.throws(function() doc:edit({line = 1, column = 2}, {line = 1, column = 2}, "x") end)
        assert.eq(doc:line(1), "aé界")
        doc:edit({line = 1, column = 1}, {line = 1, column = 3}, "X\nY")
        assert.eq(doc:text(), "aX\nY界\nend")
        doc:undo()
        assert.eq(doc:text(), "aé界\nend")
    end)

    suite:case("local edits do not rebuild the line index", function(assert)
        local lines = {}
        for i = 1, 20000 do lines[i] = `line {i}` end
        local doc = editor.document(table.concat(lines, "\n"))
        local count = doc:stats().reindexes
        for _ = 1, 100 do
            doc:edit({line = 10000, column = 0}, {line = 10000, column = 0}, "x")
        end
        assert.eq(doc:stats().reindexes, count)
        assert.eq(doc:line(19999), "line 19999")
        assert.eq(doc:linecount(), 20000)
    end)

    suite:case("views share edits with independent cursors and selections", function(assert)
        local doc = editor.document("hello\nworld")
        local a, b = editor.view(doc), editor.view(doc)
        a:goto(1, 5)
        b:goto(2, 3)
        a:insert("\nnew")
        assert.eq(b:cursor().line, 3)
        assert.eq(b:cursor().column, 3)
        b:select({line = 3, column = 0}, {line = 3, column = 5})
        assert.eq(b:selectedtext(), "world")
        b:insert("Luau")
        assert.eq(doc:text(), "hello\nnew\nLuau")
        assert.that(a:find("Luau"))
        assert.eq(a:cursor().line, 3)
        a:close(); b:close()
    end)

    suite:case("pane resources and scoped commands follow pane lifetime", function(assert)
        local workspace = editor.workspace()
        local received, cleaned = 0, 0
        workspace:registerpane("custom", function(ctx)
            local label = ui.text("custom")
            ctx:on("changed", function() received += 1 end)
            ctx:onclose(function() cleaned += 1 end)
            ctx:command("custom.action", "Action", "f8", function() received += 10 end)
            return {title = "Custom", view = label, save = function() return {answer = 42} end}
        end)
        local pane = workspace:openpane("custom", {id = "custom-one"})
        workspace:emit("changed", nil)
        workspace:execute("custom.action")
        assert.eq(received, 11)
        local saved = workspace:snapshot()
        assert.eq(saved.tree.tabs[1].id, pane.id)
        assert.eq(saved.tree.tabs[1].state.answer, 42)
        workspace:closepane(pane.id)
        workspace:emit("changed", nil)
        assert.eq(received, 11)
        assert.eq(cleaned, 1)
        assert.that(not workspace:execute("custom.action"))
        workspace:close()
    end)

    suite:case("split layouts restore registered pane state and stable identities", function(assert)
        local workspace = editor.workspace()
        workspace:registerpane("notes", function(ctx)
            return {title = "Notes", view = ui.text(tostring(ctx.state)), save = function() return ctx.state end}
        end)
        workspace:openpane("notes", {id = "first", state = "a"})
        workspace:openpane("notes", {id = "second", state = "b", dock = "right"})
        local saved = workspace:snapshot()
        assert.eq(saved.tree.axis, "row")
        workspace:close()
        local restored = editor.workspace()
        restored:registerpane("notes", function(ctx)
            return {title = "Notes", view = ui.text(tostring(ctx.state)), save = function() return ctx.state end}
        end)
        restored:restore(saved)
        assert.eq(#restored:panes(), 2)
        assert.eq(restored:panes()[2].id, "second")
        restored:close()
    end)
    suite:case("segmented edits match a string oracle across block boundaries", function(assert)
        local initial = {}
        for i = 1, 600 do initial[i] = `line {i}` end
        local expected = table.concat(initial, "\n")
        local doc = editor.document(expected)
        local history = {expected}
        local seed = 917
        local function random(limit: number): number seed = (seed * 48271) % 2147483647; return seed % limit end
        for _ = 1, 300 do
            local lines = string.split(expected, "\n")
            local a = 1 + random(#lines)
            local b = math.min(#lines, a + random(3))
            local ac = random(#lines[a] + 1)
            local bc = if a == b then ac + random(#lines[b] - ac + 1) else random(#lines[b] + 1)
            local first, last = ac, bc
            for line = 1, a - 1 do first += #lines[line] + 1 end
            for line = 1, b - 1 do last += #lines[line] + 1 end
            local inserts = {"x", "a\nb", "\n", "", "    code"}
            local text = inserts[1 + random(#inserts)]
            if first == last and text == "" then text = "z" end
            expected = expected:sub(1, first) .. text .. expected:sub(last + 1)
            doc:edit({line = a, column = ac}, {line = b, column = bc}, text)
            assert.eq(doc:text(), expected)
            assert.eq(doc:stats().bytes, #expected)
            table.insert(history, expected)
        end
        for i = #history - 1, 1, -1 do doc:undo(); assert.eq(doc:text(), history[i]) end
        for i = 2, #history do doc:redo(); assert.eq(doc:text(), history[i]) end
    end)

    suite:case("custom canvases enforce pane bounds and row damage", function(assert)
        local filled = {}
        local drawn = ""
        local surface = ui.surface({paint = function(canvas)
            canvas:fill(-100, -100, 300, 300, {fg = 123})
            canvas:text(-2, 2, "abcdefghijklmnop", {fg = 123})
            canvas:text(1, 100, "must not escape", {fg = 123})
        end}, {padding = 1, border = true})
        local app = ui.app(surface)
        local term = {
            size = function(_self: any) return 10, 8 end,
            fill = function(_self: any, x: number, y: number, width: number, height: number, style: any)
                if style and style.fg == 123 then filled = {x, y, width, height} end
            end,
            text = function(_self: any, _x: number, _y: number, value: string, style: any)
                if style and style.fg == 123 then drawn = value end
            end,
            present = function(_self: any) end,
        }
        app:render(term)
        assert.eq(filled, {3, 3, 6, 4})
        assert.eq(drawn, "defghi")
        surface:invalidate(false, 2, 2)
        app:render(term)
        assert.eq(filled, {3, 4, 6, 1})
    end)

    suite:case("a local editor edit repaints one visible row", function(assert)
        local view = editor.view(editor.document("local a = 1\nlocal b = 2\nlocal c = 3"))
        local app = ui.app(view.widget)
        local heights: {number} = {}
        local term = {
            size = function(_self: any) return 80, 20 end,
            fill = function(_self: any, _x: number, _y: number, _width: number, height: number, _style: any) table.insert(heights, height) end,
            text = function(_self: any, _x: number, _y: number, _value: string, _style: any) end,
            present = function(_self: any) end,
        }
        app:render(term)
        table.clear(heights)
        view:insert("x")
        app:render(term)
        assert.eq(heights, {1})
        view:close()
    end)
    suite:case("view positions settle before normal document observers", function(assert)
        local doc = editor.document("one\ntwo")
        local view: editor.view? = nil
        local observed = ""
        doc:onchange(function()
            if view then observed = doc:line(view:cursor().line) end
        end)
        view = editor.view(doc)
        view:goto(2, 3)
        view:insert("\nend")
        view:undo()
        assert.eq(observed, "two")
        view:close()
    end)
end)
