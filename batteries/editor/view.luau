--!strict
local ui = require("../ui")
local tui = require("@std/tui")
local documents = require("./document")
local highlight = require("./highlight")
type position = documents.position
type document = documents.document
type cached = {text: string, incoming: string, outgoing: string, spans: {highlight.span}}
export type view = {
    doc: document, widget: ui.widget,
    _cursor: position, _anchor: position?, _top: number, _left: number, _rows: number, _columns: number,
    _follow: boolean, _closed: boolean, _preferred: number?, _dispose: () -> (),
    _cache: {[number]: cached}, _validTo: number, _clipboard: {text: string}, _state: (() -> ())?,
    cellcolumn: (view) -> number, restore: (view, {line: number, column: number, top: number?, left: number?}) -> (), cursor: (view) -> position, select: (view, position, position) -> (), selectedtext: (view) -> string,
    insert: (view, string) -> (), move: (view, string, boolean?) -> (),
    goto: (view, number, number?) -> (), find: (view, string) -> boolean,
    undo: (view) -> (), redo: (view) -> (), close: (view) -> (),
    onstate: (view, () -> ()) -> (), state: (view) -> {line: number, column: number, top: number, left: number},
}
local View = {}
local base: tui.style = {fg = "#d5dbe5", bg = "#141922"}
local gutterStyle: tui.style = {fg = "#66758c", bg = "#141922"}
local function before(a: position, b: position): boolean return a.line < b.line or (a.line == b.line and a.column < b.column) end
local function same(a: position, b: position): boolean return a.line == b.line and a.column == b.column end
local function range(self: view): (position, position)
    local anchor = self._anchor or self._cursor
    if before(anchor, self._cursor) then return anchor, self._cursor end
    return self._cursor, anchor
end
local function expand(text: string, startColumn: number?): (string, number)
    local parts = {}
    local column, start = startColumn or 0, 1
    local origin = column
    while true do
        local found = text:find("\t", start, true)
        if not found then break end
        local part = text:sub(start, found - 1)
        table.insert(parts, part); column += tui.measure(part)
        local spaces = 4 - column % 4
        table.insert(parts, string.rep(" ", spaces)); column += spaces
        start = found + 1
    end
    local part = text:sub(start)
    table.insert(parts, part); column += tui.measure(part)
    return table.concat(parts), column - origin
end
local function visual(text: string, byte: number): number local _, cells = expand(text:sub(1, byte)); return cells end
local function changed(self: view, firstLine: number?, lastLine: number?)
    local cell = visual(self.doc:line(self._cursor.line), self._cursor.column)
    if firstLine and lastLine and self._cursor.line >= self._top and self._cursor.line < self._top + self._rows and cell >= self._left and cell < self._left + self._columns then
        self.widget:invalidate(false, math.max(1, firstLine - self._top + 1), math.min(self._rows, lastLine - self._top + 1))
    else self.widget:invalidate() end
    if self._state then self._state() end
end
local function byteAt(text: string, target: number): number
    local column, result = 0, 0
    for byte, cp in utf8.codes(text) do
        local width = if cp == 9 then 4 - column % 4 else tui.measure(utf8.char(cp))
        if column + width > target then break end
        column += width
        result = (utf8.offset(text, 2, byte) or (#text + 1)) - 1
    end
    return result
end
local function transform(point: position, change: documents.change): position
    if before(point, change.first) then return point end
    if not before(change.last, point) then return table.clone(change.finish) end
    if point.line == change.last.line then return {line = change.finish.line, column = change.finish.column + point.column - change.last.column} end
    return {line = point.line + change.finish.line - change.last.line, column = point.column}
end
local function spans(self: view, line: number): {highlight.span}
    if line > self._validTo then
        local state = if self._validTo > 0 then self._cache[self._validTo].outgoing else ""
        for index = self._validTo + 1, line do
            local text = self.doc:line(index)
            local cached = self._cache[index]
            if not cached or cached.text ~= text or cached.incoming ~= state then
                local runs, outgoing = highlight.line(text, state)
                cached = {text = text, incoming = state, outgoing = outgoing, spans = runs}
                self._cache[index] = cached
            end
            state = cached.outgoing
        end
        self._validTo = line
    end
    return self._cache[line].spans
end
local function paint(self: view, canvas: ui.canvas)
    if self._closed then return end
    local gutter = math.min(#tostring(self.doc:linecount()) + 2, math.max(0, canvas.width - 1))
    local width = canvas.width - gutter
    self._rows, self._columns = canvas.height, width
    if self._follow then
        if self._cursor.line < self._top then self._top = self._cursor.line end
        if self._cursor.line >= self._top + canvas.height then self._top = self._cursor.line - canvas.height + 1 end
        local column = visual(self.doc:line(self._cursor.line), self._cursor.column)
        if column < self._left then self._left = column end
        if column >= self._left + width then self._left = column - width + 1 end
    end
    self._top = math.clamp(self._top, 1, math.max(1, self.doc:linecount() - canvas.height + 1))
    local first, last = range(self)
    for row = canvas.firstrow, canvas.lastrow do
        local line = self._top + row - 1
        if line > self.doc:linecount() then break end
        local text = self.doc:line(line)
        if gutter > 0 then canvas:text(1, row, string.format("%" .. math.max(1, gutter - 1) .. "d ", line), gutterStyle) end
        local selectionStart = if first.line < line then 0 else if first.line == line then first.column else #text
        local selectionEnd = if last.line > line then #text else if last.line == line then last.column else 0
        local column = 0
        for _, run in spans(self, line) do
            local cuts = {run.first, run.last}
            if selectionStart > run.first and selectionStart < run.last then table.insert(cuts, selectionStart) end
            if selectionEnd > run.first and selectionEnd < run.last then table.insert(cuts, selectionEnd) end
            table.sort(cuts)
            for i = 1, #cuts - 1 do
                local a, b = cuts[i], cuts[i + 1]
                local expanded, cells = expand(text:sub(a + 1, b), column)
                local style = run.style
                if a >= selectionStart and a < selectionEnd then style = table.clone(style); style.bg = "#354d70" end
                if column + cells > self._left and column < self._left + width then
                    local x = math.max(0, column - self._left)
                    canvas:text(gutter + x + 1, row, tui.clip(expanded, width - x, math.max(0, self._left - column)), style)
                end
                column += cells
            end
        end
        if line >= first.line and line < last.line and selectionEnd == #text and column >= self._left and column < self._left + width then
            canvas:fill(gutter + column - self._left + 1, row, 1, 1, {bg = "#354d70"})
        end
    end
    if canvas.focused and self._cursor.line >= self._top and self._cursor.line < self._top + canvas.height then
        local text = self.doc:line(self._cursor.line)
        local column = visual(text, self._cursor.column)
        local tail = text:sub(self._cursor.column + 1)
        local nextByte = utf8.offset(tail, 2)
        local glyph = if tail == "" then " " else tail:sub(1, if nextByte then nextByte - 1 else #tail)
        glyph = expand(glyph, column)
        if column >= self._left and column < self._left + width then
            local clipped = tui.clip(glyph, width - column + self._left)
            canvas:text(gutter + column - self._left + 1, self._cursor.line - self._top + 1, if clipped == "" then " " else clipped, {fg = "#10131a", bg = "#82aaff"})
        end
    end
end
function View.cellcolumn(self: view): number return visual(self.doc:line(self._cursor.line), self._cursor.column) end
function View.restore(self: view, state: {line: number, column: number, top: number?, left: number?})
    self:goto(state.line, state.column)
    self._top = math.clamp(math.floor(state.top or 1), 1, self.doc:linecount())
    self._left = math.max(0, math.floor(state.left or 0))
end
function View.cursor(self: view): position return table.clone(self._cursor) end
function View.state(self: view) return {line = self._cursor.line, column = self._cursor.column, top = self._top, left = self._left} end
function View.onstate(self: view, callback: () -> ()) self._state = callback end
function View.selectedtext(self: view): string local first, last = range(self); return self.doc:slice(first, last) end
function View.select(self: view, anchor: position, head: position)
    local oldFirst, oldLast = range(self)
    self.doc:validate(anchor); self.doc:validate(head)
    self._anchor, self._cursor = table.clone(anchor), table.clone(head)
    self._follow = true; self._preferred = nil; changed(self, math.min(oldFirst.line, anchor.line, head.line), math.max(oldLast.line, anchor.line, head.line))
end
function View.goto(self: view, line: number, column: number?)
    local oldFirst, oldLast = range(self)
    line = math.clamp(math.floor(line), 1, self.doc:linecount())
    local text = self.doc:line(line)
    local byte = math.clamp(math.floor(column or 0), 0, #text)
    while byte > 0 and byte < #text and (text:byte(byte + 1) :: number) >= 128 and (text:byte(byte + 1) :: number) < 192 do byte -= 1 end
    self._cursor, self._anchor = {line = line, column = byte}, nil
    self._preferred = nil; self._follow = true; changed(self, math.min(oldFirst.line, line), math.max(oldLast.line, line))
end
function View.insert(self: view, text: string)
    local first, last = range(self)
    self._cursor = self.doc:edit(first, last, text)
    self._anchor = nil; self._preferred = nil; self._follow = true; changed(self, first.line, math.max(last.line, self._cursor.line))
end
function View.undo(self: view) self._anchor = nil; self.doc:undo(); self._follow = true; changed(self, self._cursor.line, self._cursor.line) end
function View.redo(self: view) self._anchor = nil; self.doc:redo(); self._follow = true; changed(self, self._cursor.line, self._cursor.line) end
function View.move(self: view, direction: string, shift: boolean?)
    local oldFirst, oldLast = range(self)
    if self._anchor and not shift and (direction == "left" or direction == "right") then
        local point = if direction == "left" then oldFirst else oldLast
        self:goto(point.line, point.column); return
    end
    local point = table.clone(self._cursor)
    local text = self.doc:line(point.line)
    if shift then self._anchor = self._anchor or table.clone(point) else self._anchor = nil end
    if direction == "left" then
        if point.column > 0 then point.column = (utf8.offset(text, -1, point.column + 1) or 1) - 1
        elseif point.line > 1 then point.line -= 1; point.column = #self.doc:line(point.line) end
    elseif direction == "right" then
        if point.column < #text then point.column = (utf8.offset(text, 2, point.column + 1) or (#text + 1)) - 1
        elseif point.line < self.doc:linecount() then point.line += 1; point.column = 0 end
    elseif direction == "home" then point.column = 0
    elseif direction == "end" then point.column = #text
    else
        self._preferred = self._preferred or visual(text, point.column)
        local delta = if direction == "up" then -1 else if direction == "down" then 1 else if direction == "pageup" then -math.max(1, self._rows - 1) else math.max(1, self._rows - 1)
        point.line = math.clamp(point.line + delta, 1, self.doc:linecount())
        point.column = byteAt(self.doc:line(point.line), self._preferred :: number)
    end
    if direction == "left" or direction == "right" or direction == "home" or direction == "end" then self._preferred = nil end
    self._cursor = point; self._follow = true; changed(self, math.min(oldFirst.line, point.line), math.max(oldLast.line, point.line))
end
function View.find(self: view, query: string): boolean
    if query == "" or query:find("\n", 1, true) then return false end
    for pass = 1, 2 do
        local firstLine = if pass == 1 then self._cursor.line else 1
        local lastLine = if pass == 1 then self.doc:linecount() else self._cursor.line
        for line = firstLine, lastLine do
            local start = if pass == 1 and line == self._cursor.line then self._cursor.column + 1 else 1
            local a, b = self.doc:line(line):find(query, start, true)
            if a and b then self:select({line = line, column = a - 1}, {line = line, column = b}); return true end
        end
    end
    return false
end
local function indent(self: view, outdent: boolean)
    local first, last = range(self)
    local lastLine = if last.line > first.line and last.column == 0 then last.line - 1 else last.line
    local lines = {}
    for line = first.line, lastLine do
        local text = self.doc:line(line)
        if outdent then text = text:gsub("^\t", "", 1); if self.doc:line(line):sub(1, 1) ~= "\t" then text = text:gsub("^ ? ? ? ?", "", 1) end
        else text = "    " .. text end
        table.insert(lines, text)
    end
    self._anchor = {line = first.line, column = 0}
    self._cursor = {line = lastLine, column = #self.doc:line(lastLine)}
    self:insert(table.concat(lines, "\n"))
end
local function input(self: view, event: tui.event): boolean
    if self._closed then return false end
    if event.kind == "mouse" then
        if event.action == "scrollup" or event.action == "scrolldown" then
            self._top = math.clamp(self._top + (if event.action == "scrollup" then -3 else 3), 1, math.max(1, self.doc:linecount() - self._rows + 1))
            self._follow = false; changed(self); return true
        end
        if event.action == "press" or (event.action == "move" and event.button == 1) then
            local rect = self.widget:bounds()
            local line = math.clamp(event.y - rect.y + self._top, 1, self.doc:linecount())
            local gutter = math.min(#tostring(self.doc:linecount()) + 2, math.max(0, rect.width - 1))
            local byte = byteAt(self.doc:line(line), math.max(0, event.x - rect.x - gutter + self._left))
            if event.shift or event.action == "move" then self:select(self._anchor or self._cursor, {line = line, column = byte})
            else self:goto(line, byte) end
            return true
        end
        return false
    end
    if event.kind == "paste" then
        if utf8.len(event.text) and not event.text:find("\0", 1, true) then self:insert(event.text) end
        return true
    end
    if event.kind ~= "key" then return false end
    local key = event.key
    if event.ctrl then
        if key == "a" then self:select({line = 1, column = 0}, {line = self.doc:linecount(), column = #self.doc:line(self.doc:linecount())})
        elseif key == "z" then self:undo()
        elseif key == "y" then self:redo()
        elseif key == "c" then self._clipboard.text = self:selectedtext()
        elseif key == "x" then self._clipboard.text = self:selectedtext(); if self._clipboard.text ~= "" then self:insert("") end
        elseif key == "v" then self:insert(self._clipboard.text)
        elseif key == "home" then self:goto(1, 0)
        elseif key == "end" then self:goto(self.doc:linecount(), #self.doc:line(self.doc:linecount()))
        else return false end
        return true
    end
    if key == "left" or key == "right" or key == "up" or key == "down" or key == "home" or key == "end" or key == "pageup" or key == "pagedown" then self:move(key, event.shift)
    elseif key == "enter" then self:insert("\n" .. (self.doc:line(self._cursor.line):sub(1, self._cursor.column):match("^[ \t]*") or ""))
    elseif key == "tab" then
        if event.shift or self._anchor then indent(self, event.shift)
        else self:insert(string.rep(" ", 4 - visual(self.doc:line(self._cursor.line), self._cursor.column) % 4)) end
    elseif key == "backspace" or key == "delete" then
        local first, last = range(self)
        if same(first, last) then
            self:move(if key == "backspace" then "left" else "right", true)
        end
        self:insert("")
    elseif key == "escape" and self._anchor then self._anchor = nil; changed(self)
    elseif event.text ~= "" and not event.alt then self:insert(event.text)
    else return false end
    return true
end
function View.close(self: view)
    if self._closed then return end
    self._closed = true; self._dispose(); self._state = nil
end
function View.new(doc: document, clipboard: {text: string}?): view
    local self: view = setmetatable({
        doc = doc, widget = nil, _cursor = {line = 1, column = 0}, _anchor = nil,
        _top = 1, _left = 0, _rows = 1, _columns = 1, _follow = true, _closed = false, _preferred = nil,
        _dispose = function() end, _cache = {}, _validTo = 0, _clipboard = clipboard or {text = ""}, _state = nil,
    }, {__index = View}) :: any
    self.widget = ui.surface({
        paint = function(canvas) paint(self, canvas) end,
        input = function(event) return input(self, event) end,
        resize = function() self._follow = true end,
    }, {style = base})
    self._dispose = doc:onchange(function(change)
        if change.reset then
            self._cache, self._validTo = {}, 0
            self:goto(self._cursor.line, self._cursor.column)
            self.widget:invalidate()
            return
        end
        self._cursor = transform(self._cursor, change)
        if self._anchor then self._anchor = transform(self._anchor, change) end
        local cached = self._cache[change.first.line]
        self._validTo = math.min(self._validTo, change.first.line - 1)
        self._follow = self.widget:focused()
        if change.last.line == change.finish.line and change.first.line == change.last.line and cached then
            local _, outgoing = highlight.line(self.doc:line(change.first.line), cached.incoming)
            changed(self, change.first.line, if outgoing == cached.outgoing then change.first.line else self._top + self._rows - 1)
        else changed(self) end
    end, -100)
    return self
end
return View
