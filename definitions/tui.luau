--!strict

local tui = {}

export type style = {
    fg: (number | string)?,
    bg: (number | string)?,
    bold: boolean?,
    dim: boolean?,
    italic: boolean?,
    underline: boolean?,
    reverse: boolean?,
}
export type options = { mouse: boolean?, escapedelay: number? }
export type event =
    { kind: "key", key: string, text: string, ctrl: boolean, alt: boolean, shift: boolean }
    | { kind: "paste", text: string }
    | { kind: "mouse", x: number, y: number, button: number, action: string, ctrl: boolean, alt: boolean, shift: boolean }
    | { kind: "resize", width: number, height: number }
export type session = {
    read: (self: session) -> event,
    close: (self: session) -> (),
    clear: (self: session) -> (),
    size: (self: session) -> (number, number),
    text: (self: session, x: number, y: number, value: string, style: style?) -> (),
    fill: (self: session, x: number, y: number, width: number, height: number, style: style?) -> (),
    present: (self: session) -> (),
}

--- Whether stdin/stdout are terminals and TERM is not dumb. Does not probe every terminal capability.
function tui.supported(): boolean
    error("unimplemented")
end

--- Own the terminal until close. Prefer @std/tui.run for scoped cleanup.
function tui.open(_options: options?): session
    error("unimplemented")
end

--- Measure maximum line width and line count using the renderer's scalar widths.
function tui.measure(_value: string): (number, number)
    error("unimplemented")
end

--- Clip a single line to cell width, starting at a zero-based cell offset.
function tui.clip(_value: string, _width: number, _offset: number?): string
    error("unimplemented")
end

return tui
