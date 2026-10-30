--!strict
local document = require("@self/document")
local view = require("@self/view")
local workspace = require("@self/workspace")
export type document = document.document
export type position = document.position
export type change = document.change
export type view = view.view
export type workspace = workspace.workspace
export type context = workspace.context
export type pane = workspace.pane
export type descriptor = workspace.descriptor
export type openoptions = workspace.openoptions
local editor = {
    document = document.new,
    view = view.new,
    workspace = workspace.new,
}
return table.freeze(editor)
