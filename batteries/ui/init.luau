--!strict
local widget = require("@self/widget")
local application = require("@self/application")
export type widget = widget.widget
export type options = widget.options
export type item = widget.item
export type canvas = widget.canvas
export type surface = widget.surface
export type event = widget.event
export type application = application.application
local ui = {}

function ui.text(value: string, options: options?): widget
    return widget.new("text", value, options)
end
function ui.button(label: string, options: options?): widget
    return widget.new("button", label, options)
end
function ui.input(options: options?): widget return widget.new("input", nil, options) end
function ui.list(options: options?): widget return widget.new("list", nil, options) end
function ui.row(options: options?, children: {widget}?): widget return widget.new("row", nil, options, children) end
function ui.column(options: options?, children: {widget}?): widget return widget.new("column", nil, options, children) end
function ui.box(options: options?, children: {widget}?): widget
    local opts: options = table.clone(options or ({} :: options))
    if opts.border == nil then opts.border = true end
    return widget.new("box", nil, opts, children)
end
function ui.surface(callbacks: surface, options: options?): widget
    local opts: options = table.clone(options or ({} :: options))
    if opts.flex == nil then opts.flex = 1 end
    local node = widget.new("surface", nil, opts)
    node._surface = callbacks
    return node
end
function ui.app(root: widget): application return application.new(root) end
return table.freeze(ui)
