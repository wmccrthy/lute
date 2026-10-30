--!strict
-- A segmented line store. Character edits touch one line and one history entry;
-- structural edits rebuild the small block index, not a string for the whole file.
local deque = require("../collections/deque")
export type position = {line: number, column: number} -- one-based line, zero-based UTF-8 byte column
export type change = {first: position, last: position, finish: position, revision: number, reset: boolean?}
type entry = {text: string, eol: string}
type block = {entry}
type record = {line: number, removed: {entry}, inserted: {entry}, first: position, last: position, finish: position, before: number, after: number, cost: number}
type listener = {key: {}, callback: (change) -> (), priority: number, order: number}
export type document = {
    _blocks: {block}, _starts: {number}, _count: number, _eol: string,
    _undo: deque.Deque<record>, _redo: {record}, _historyBytes: number,
    _notifying: boolean, _revision: number, _identity: number, _state: number, _saved: number,
    _bytes: number, _listeners: {[{}]: listener}, _listenerSerial: number, _reindexes: number,
    line: (document, number) -> string, linecount: (document) -> number,
    reset: (document, string) -> (), text: (document) -> string, slice: (document, position, position) -> string,
    edit: (document, position, position, string) -> position,
    undo: (document) -> boolean, redo: (document) -> boolean,
    dirty: (document) -> boolean, marksaved: (document) -> (), revision: (document) -> number,
    onchange: (document, (change) -> (), number?) -> (() -> ()),
    stats: (document) -> {blocks: number, reindexes: number, historybytes: number, bytes: number},
    validate: (document, position) -> (),
}
local Document = {}
local BLOCK = 256
local HISTORY = 8 * 1024 * 1024

local function parse(value: string): {entry}
    assert(not value:find("\0", 1, true), "binary NUL is not supported in text documents")
    assert(utf8.len(value) ~= nil, "document requires valid UTF-8")
    local lines: {entry} = {}
    local start = 1
    while true do
        local first, last = value:find("[\r\n]", start)
        if not first then break end
        assert(last)
        if value:sub(first, first + 1) == "\r\n" then last = first + 1 end
        table.insert(lines, {text = value:sub(start, first - 1), eol = value:sub(first, last)})
        start = last + 1
    end
    table.insert(lines, {text = value:sub(start), eol = ""})
    return lines
end

local function reindex(self: document)
    self._starts = {}
    local count = 0
    for i, block in self._blocks do self._starts[i] = count + 1; count += #block end
    self._count = count
    self._reindexes += 1
end
local function locate(self: document, line: number): (number, number)
    assert(line >= 1 and line <= self._count and line == math.floor(line), "line out of range")
    local low, high = 1, #self._starts
    while low < high do
        local mid = math.ceil((low + high) / 2)
        if self._starts[mid] <= line then low = mid else high = mid - 1 end
    end
    return low, line - self._starts[low] + 1
end
local function get(self: document, line: number): entry
    local block, offset = locate(self, line)
    return self._blocks[block][offset]
end
local function splice(self: document, line: number, count: number, inserted: {entry})
    local removedBytes, insertedBytes = 0, 0
    for i = line, line + count - 1 do local value = get(self, i); removedBytes += #value.text + #value.eol end
    for _, value in inserted do insertedBytes += #value.text + #value.eol end
    self._bytes += insertedBytes - removedBytes
    local firstBlock, firstOffset = locate(self, line)
    if count == 1 and #inserted == 1 then self._blocks[firstBlock][firstOffset] = inserted[1]; return end
    local lastBlock, lastOffset = locate(self, line + count - 1)
    local boundary: {entry} = {}
    for i = 1, firstOffset - 1 do table.insert(boundary, self._blocks[firstBlock][i]) end
    for _, value in inserted do table.insert(boundary, value) end
    for i = lastOffset + 1, #self._blocks[lastBlock] do table.insert(boundary, self._blocks[lastBlock][i]) end
    local blocks: {block} = {}
    for i = 1, firstBlock - 1 do table.insert(blocks, self._blocks[i]) end
    for first = 1, #boundary, BLOCK do
        local block: block = {}
        for i = first, math.min(first + BLOCK - 1, #boundary) do table.insert(block, boundary[i]) end
        table.insert(blocks, block)
    end
    for i = lastBlock + 1, #self._blocks do table.insert(blocks, self._blocks[i]) end
    self._blocks = blocks
    reindex(self)
end
local function emit(self: document, first: position, last: position, finish: position, reset: boolean?)
    self._revision += 1
    local event: change = {first = table.clone(first), last = table.clone(last), finish = table.clone(finish), revision = self._revision, reset = reset}
    local callbacks: {listener} = {}
    for _, listener in self._listeners do table.insert(callbacks, listener) end
    table.sort(callbacks, function(a: listener, b: listener)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.order < b.order
    end)
    local problem: any = nil
    self._notifying = true
    for _, listener in callbacks do
        if self._listeners[listener.key] then
            local ok, err = pcall(listener.callback, event)
            if not ok and problem == nil then problem = err end
        end
    end
    self._notifying = false
    if problem ~= nil then error(problem, 0) end
end
function Document.validate(self: document, point: position)
    local text = self:line(point.line)
    local column = point.column
    assert(column >= 0 and column <= #text and column == math.floor(column), "column out of range")
    local byte = text:byte(column + 1)
    assert(not byte or byte < 128 or byte >= 192, "column splits a UTF-8 scalar")
end
function Document.line(self: document, line: number): string return get(self, line).text end
function Document.linecount(self: document): number return self._count end
function Document.revision(self: document): number return self._revision end
function Document.dirty(self: document): boolean return self._state ~= self._saved end
function Document.marksaved(self: document) self._saved = self._state end
function Document.stats(self: document)
    return {blocks = #self._blocks, reindexes = self._reindexes, historybytes = self._historyBytes, bytes = self._bytes}
end
function Document.text(self: document): string
    local parts = {}
    for _, block in self._blocks do for _, value in block do table.insert(parts, value.text .. value.eol) end end
    return table.concat(parts)
end
function Document.slice(self: document, first: position, last: position): string
    self:validate(first); self:validate(last)
    assert(first.line < last.line or (first.line == last.line and first.column <= last.column), "reversed edit range")
    if first.line == last.line then return self:line(first.line):sub(first.column + 1, last.column) end
    local parts = {self:line(first.line):sub(first.column + 1)}
    for line = first.line + 1, last.line - 1 do table.insert(parts, self:line(line)) end
    table.insert(parts, self:line(last.line):sub(1, last.column))
    return table.concat(parts, "\n")
end
function Document.edit(self: document, first: position, last: position, text: string): position
    assert(not self._notifying, "document edits cannot be nested inside change listeners")
    self:validate(first); self:validate(last)
    assert(first.line < last.line or (first.line == last.line and first.column <= last.column), "reversed edit range")
    local parsed = parse(text)
    local finish = {line = first.line + #parsed - 1, column = #parsed[#parsed].text + (if #parsed == 1 then first.column else 0)}
    if first.line == last.line and first.column == last.column and text == "" then return finish end
    local removed: {entry} = {}
    local cost = 0
    for line = first.line, last.line do local value = get(self, line); table.insert(removed, value); cost += #value.text + #value.eol end
    local inserted: {entry} = {}
    for i, value in parsed do
        local content = value.text
        if i == 1 then content = removed[1].text:sub(1, first.column) .. content end
        if i == #parsed then content ..= removed[#removed].text:sub(last.column + 1) end
        local eol = if i == #parsed then removed[#removed].eol else self._eol
        table.insert(inserted, {text = content, eol = eol})
        cost += #content + #eol
    end
    self._identity += 1
    local record: record = {
        line = first.line, removed = removed, inserted = inserted,
        first = table.clone(first), last = table.clone(last), finish = finish,
        before = self._state, after = self._identity, cost = cost,
    }
    splice(self, first.line, #removed, inserted)
    self._state = record.after
    self._redo = {}
    self._undo:pushback(record)
    self._historyBytes += cost
    while (self._historyBytes > HISTORY and #self._undo > 1) or #self._undo > 10000 do
        self._historyBytes -= self._undo:popfront().cost
    end
    emit(self, first, last, finish)
    return table.clone(finish)
end
function Document.undo(self: document): boolean
    assert(not self._notifying, "document edits cannot be nested inside change listeners")
    if #self._undo == 0 then return false end
    local record = self._undo:popback()
    splice(self, record.line, #record.inserted, record.removed)
    self._state = record.before
    table.insert(self._redo, record)
    self._historyBytes -= record.cost
    emit(self, record.first, record.finish, record.last)
    return true
end
function Document.redo(self: document): boolean
    assert(not self._notifying, "document edits cannot be nested inside change listeners")
    local record = table.remove(self._redo)
    if not record then return false end
    splice(self, record.line, #record.removed, record.inserted)
    self._state = record.after
    self._undo:pushback(record)
    self._historyBytes += record.cost
    emit(self, record.first, record.last, record.finish)
    return true
end
function Document.onchange(self: document, callback: (change) -> (), priority: number?): () -> ()
    local key = {}
    self._listenerSerial += 1
    self._listeners[key] = {key = key, callback = callback, priority = priority or 0, order = self._listenerSerial}
    return function() self._listeners[key] = nil end
end
function Document.reset(self: document, text: string)
    assert(not self._notifying, "document edits cannot be nested inside change listeners")
    local replacement = Document.new(text)
    local last = {line = self._count, column = #self:line(self._count)}
    self._blocks, self._starts, self._count, self._eol, self._bytes = replacement._blocks, replacement._starts, replacement._count, replacement._eol, replacement._bytes
    self._reindexes += 1
    self._undo, self._redo, self._historyBytes = deque.new(nil :: record?), {}, 0
    self._identity += 1; self._state = self._identity; self._saved = self._state
    emit(self, {line = 1, column = 0}, last, {line = self._count, column = #self:line(self._count)}, true)
end
function Document.new(text: string): document
    local lines = parse(text)
    local blocks: {block} = {}
    for first = 1, #lines, BLOCK do
        local block: block = {}
        for i = first, math.min(first + BLOCK - 1, #lines) do table.insert(block, lines[i]) end
        table.insert(blocks, block)
    end
    local self: document = setmetatable({
        _blocks = blocks, _starts = {}, _count = 0, _eol = if lines[1].eol ~= "" then lines[1].eol else "\n",
        _undo = deque.new(nil :: record?), _redo = {}, _historyBytes = 0, _notifying = false, _revision = 0, _identity = 0, _state = 0, _saved = 0,
        _bytes = #text, _listeners = {}, _listenerSerial = 0, _reindexes = 0,
    }, {__index = Document}) :: any
    reindex(self)
    return self
end
return Document
