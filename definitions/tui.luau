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

return tui
