-- claude-menubar/menubar.lua
-- Pure menubar icon + title logic. Owns no state across calls.

local M = {}

-- Build a small SF Symbol-ish icon. hs.menubar can't render SF Symbols
-- directly, but it can take hs.image objects. We use a tiny templated
-- image so macOS auto-inverts it for light/dark mode.
local function makeIcon()
    -- 16pt PDF-ish: just text rendered to image. Cheapest: use imageFromASCII.
    -- A 14x14 monochrome "cc" glyph in dot art.
    local ascii = [[
................
................
..####....####..
.##..##..##..##.
.#........#.....
.#........#.....
.#........#.....
.#........#.....
.#........#.....
.#........#.....
.##..##..##..##.
..####....####..
................
................
]]
    local img = hs.image.imageFromASCII(ascii, {
        { strokeColor = { white = 1.0 }, fillColor = { white = 1.0 } }
    })
    if img then img:setSize({ w = 14, h = 14 }) end
    return img
end

-- Cache so we don't re-render the image on every tick.
local cachedIcon = nil

function M.create(opts)
    opts = opts or {}
    local item = hs.menubar.new()
    if not item then
        error("hs.menubar.new() returned nil; menubar slot may be full")
    end
    -- Use text title instead of ASCII-art image — the 14x14 imageFromASCII
    -- renders fuzzy at menubar size and gets mistaken for unrelated icons.
    item:setTitle("cc")
    item:setClickCallback(function() opts.onClick() end)
    return item
end

-- update(item, topState, count, blinkPhase)
--   topState  : "idle" | "running" | "pending" | "done"
--   count     : visible session count (running + pending + recent done)
--   blinkPhase: bool, toggled every 1s by caller; when true and pending, show "!"
function M.update(item, topState, count, blinkPhase)
    if not item then return end
    local title
    if topState == "idle" or count == 0 then
        title = "cc"
    elseif topState == "pending" then
        local mark = blinkPhase and "!" or " "
        title = string.format("cc %d%s", count, mark)
    elseif topState == "running" then
        title = string.format("cc %d", count)
    elseif topState == "done" then
        title = "cc ✓"
    else
        title = "cc"
    end
    item:setTitle(title)
end

return M
