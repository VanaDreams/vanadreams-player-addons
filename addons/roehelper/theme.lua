-- theme.lua (lite)  -  plain ImGui stand-in for the themed version. Same function names, no skins, no custom
-- fonts, no images: normal Ashita window title bar, default ImGui colours, a highlighted button for "on".
require('common')
local imgui = require('imgui')

local M = {}

M.C = {
    gold  = { 0.94, 0.77, 0.42, 1.0 }, amber = { 1.00, 0.70, 0.25, 1.0 },
    text  = { 0.91, 0.92, 0.94, 1.0 }, muted = { 0.55, 0.58, 0.64, 1.0 },
    green = { 0.45, 0.90, 0.60, 1.0 }, red   = { 1.00, 0.45, 0.45, 1.0 },
    warn  = { 1.00, 0.60, 0.20, 1.0 }, blue  = { 0.45, 0.70, 1.00, 1.0 },
}
local C = M.C

M.ui_scale = 1.0
function M.set_scale() end
function M.persist_scale() end
function M.push() return 0, 0 end
function M.pop() end
function M.child_scale() end
function M.finish() imgui.End() end

-- window with the normal title bar and its own close X (open = { true/false })
function M.begin(name, open, extra)
    local flags = ImGuiWindowFlags_NoCollapse
    if extra then flags = bit.bor(flags, extra) end
    return imgui.Begin(name, open, flags)
end

function M.caption(text) imgui.TextColored(C.muted, text) end
function M.muted(text) imgui.TextColored(C.muted, text) end
function M.text_w(text) local w = imgui.CalcTextSize(text) if type(w) == 'table' then w = w[1] end return w end
function M.btn_w(text) return math.floor(M.text_w(text) + 16) end

local function btn(label, size)
    if size then return imgui.Button(label, size) end
    return imgui.Button(label)
end

local function hl(label, color, size)
    imgui.PushStyleColor(ImGuiCol_Button, { color[1] * 0.45, color[2] * 0.45, color[3] * 0.45, 1 })
    local c = btn(label, size)
    imgui.PopStyleColor(1)
    return c
end

function M.accent(label, size) return hl(label, C.gold, size) end
function M.ghost(label, size) return btn(label, size) end
function M.tinted(label, color, size) return hl(label, color, size) end
function M.danger(label, size) return hl(label, C.red, size) end
function M.toggle(label, id, selected, size)
    local text = label .. '##' .. id
    if selected then return hl(text, C.gold, size) end
    return btn(text, size)
end

-- subtitle line (the title is the window's own title bar). mini = nil (no button) | false ("-") | true ("+").
-- Returns true when the mini button was clicked.
function M.header(open, a, b, sub, mini)
    local hit = false
    if mini ~= nil then
        if imgui.SmallButton((mini and '+' or '-') .. '##hdr_mini') then hit = true end
        if imgui.IsItemHovered() then imgui.SetTooltip(mini and 'Show controls' or 'Hide controls (compact)') end
        imgui.SameLine()
    end
    if sub and sub ~= '' then imgui.TextColored(C.muted, sub) else imgui.NewLine() end
    imgui.Separator()
    return hit
end

function M.mini_corner(tip)
    local hit = imgui.SmallButton('+##mini_corner')
    if imgui.IsItemHovered() then imgui.SetTooltip(tip or 'Show controls') end
    return hit
end

return M
