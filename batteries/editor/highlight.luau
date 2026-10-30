--!strict
-- Incremental lexical Luau colors. Long-bracket state is carried between lines;
-- this intentionally isn't a parser or a diagnostic engine.
local tui = require("@std/tui")
export type span = {first: number, last: number, style: tui.style}
local plain: tui.style = {fg = "#d5dbe5"}
local colors: {[string]: tui.style} = {
    keyword = {fg = "#c792ea"}, string = {fg = "#c3e88d"}, comment = {fg = "#66758c", italic = true},
    number = {fg = "#f78c6c"}, punctuation = {fg = "#89ddff"},
}
for _, style in colors do style.bg = "#141922" end
plain.bg = "#141922"
local keywords = {}
for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while continue type export typeof read write"):gmatch("%S+") do keywords[word] = true end
local highlight = {}
function highlight.line(text: string, incoming: string): ({span}, string)
    local result: {span} = {}
    local position = 1
    local state = incoming
    local function add(first: number, last: number, style: tui.style)
        if last >= first then
            local previous = result[#result]
            if previous and previous.style == style and previous.last == first - 1 then previous.last = last
            else table.insert(result, {first = first - 1, last = last, style = style}) end
        end
    end
    while position <= #text do
        if state ~= "" then
            local kind, equals = state:match("^([cs]):(.*)$")
            if kind and equals then
                local close = "]" .. equals .. "]"
                local first, last = text:find(close, position, true)
                add(position, last or #text, if kind == "c" then colors.comment else colors.string)
                position = if last then last + 1 else #text + 1
                if first then state = "" end
            else
                local quote = state
                local start = position
                while position <= #text do
                    local char = text:sub(position, position)
                    position += 1
                    if char == "\\" then position += 1
                    elseif char == quote then state = ""; break end
                end
                add(start, math.min(#text, position - 1), colors.string)
                if quote ~= "`" and text:sub(-1) ~= "\\" then state = "" end
            end
            continue
        end
        local start = position
        local comment = text:sub(position, position + 1) == "--"
        local opener = if comment then text:match("^%-%-%[(=*)%[", position) else text:match("^%[(=*)%[", position)
        if opener then
            local prefix = #opener + (if comment then 4 else 2)
            local close = "]" .. opener .. "]"
            local _, last = text:find(close, position + prefix, true)
            add(start, last or #text, if comment then colors.comment else colors.string)
            position = if last then last + 1 else #text + 1
            if not last then state = (if comment then "c:" else "s:") .. opener end
        elseif comment then add(start, #text, colors.comment); break
        else
            local char = text:sub(position, position)
            if char == '"' or char == "'" or char == "`" then
                position += 1
                state = char
                while position <= #text do
                    local current = text:sub(position, position)
                    position += 1
                    if current == "\\" then position += 1
                    elseif current == char then state = ""; break end
                end
                add(start, math.min(#text, position - 1), colors.string)
                if char ~= "`" and text:sub(-1) ~= "\\" then state = "" end
            else
                local word = text:match("^[%a_][%w_]*", position)
                local number = text:match("^0[xX][%da-fA-F_%.]+", position) or text:match("^%d[%w_%.]*", position)
                if word then add(start, start + #word - 1, if keywords[word] then colors.keyword else plain); position += #word
                elseif number then add(start, start + #number - 1, colors.number); position += #number
                else
                    -- Group punctuation/whitespace without splitting UTF-8 scalars.
                    local count = if char:byte() >= 128 then (utf8.offset(text, 2, position) or (#text + 1)) - position else 1
                    add(start, start + count - 1, if char:match("%s") then plain else colors.punctuation)
                    position += count
                end
            end
        end
    end
    return result, state
end
return highlight
