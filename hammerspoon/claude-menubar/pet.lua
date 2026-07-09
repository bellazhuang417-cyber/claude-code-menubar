-- claude-menubar/pet.lua  (v0.4 "companion" architecture)
-- Single always-visible transparent webview that:
--   1. Hosts the pet artwork in the bottom-right at all times
--   2. Optionally shows a bubble above the pet for permission requests /
--      task completion / long-task check-ins
--   3. Expands UP from the pet position when Bella clicks the pet body or
--      the menubar cc icon, revealing the full session panel above the pet
--   4. Collapses back to idle when clicked again
--
-- One window replaces the previous split of "pet" + "panel" webviews. The
-- panel content (sessions / skin picker / status) is HTML-templated in
-- web/index.html; we load it as-is and control expansion via a CSS class
-- (body.mode-idle vs body.mode-expanded) plus an animated window frame.

local M = {}

local IDLE_HEIGHT      = 220   -- window height in idle mode (pet + bubble slot)
local EXPANDED_HEIGHT  = 760   -- max window height when expanded
local WIDTH            = 380   -- window width (same in both modes; matches panel)
local MARGIN           = 22    -- gap from screen bottom-right corner
-- Content anchored bottom-right → expanded content grows UP. When we resize
-- the window we adjust y so the bottom edge stays put.

M.WIDTH = WIDTH
M.IDLE_HEIGHT = IDLE_HEIGHT
M.EXPANDED_HEIGHT = EXPANDED_HEIGHT

local function readFile(path, binary)
    local f = io.open(path, binary and "rb" or "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

-- ---------- Skin loading (unchanged from v0.3) ----------
local function loadSkinManifest(name)
    if not name or name == "tac" then return nil end
    local dir = os.getenv("HOME") .. "/.claude-menubar/skins/" .. name .. "/"
    local raw = readFile(dir .. "manifest.json")
    if not raw then return nil end
    local ok, mf = pcall(hs.json.decode, raw)
    if not ok or type(mf) ~= "table" then return nil end
    mf.dir = dir
    mf.name = name
    return mf
end

local base64Cache = {}
local function fileDataUrl(path)
    local cached = base64Cache[path]
    if cached then return cached end
    local data = readFile(path, true)
    if not data then return "" end
    local ok, b64 = pcall(hs.base64.encode, data)
    if not ok or not b64 then return "" end
    b64 = b64:gsub("%s+", "")
    local mime = "image/webp"
    local low = path:lower()
    if low:sub(-4) == ".png" then mime = "image/png"
    elseif low:sub(-4) == ".jpg" or low:sub(-5) == ".jpeg" then mime = "image/jpeg"
    elseif low:sub(-4) == ".gif" then mime = "image/gif" end
    local url = "data:" .. mime .. ";base64," .. b64
    base64Cache[path] = url
    return url
end

-- Load built-in Tac SVG artwork keyed by mood. Cached across calls.
local tacSvgCache = nil
local function loadTacSvgs(webDir)
    if tacSvgCache then return tacSvgCache end
    local dir = webDir .. "assets/"
    local function svg(name)
        local raw = readFile(dir .. name); if not raw then return "" end
        return (raw:gsub("<%?xml.-%?>%s*", "", 1))
    end
    tacSvgCache = {
        idle   = svg("tac.svg"),
        input  = svg("tac-needs-input.svg"),
        done   = svg("tac-complete.svg"),
        review = svg("tac-working.svg"),
    }
    return tacSvgCache
end

-- Build the pet body markup + a "data URL for skin's GIF" map so the JS
-- side can swap sprites in-place without a full HTML reload.
-- Returns: bodyHtml (initial pet HTML), skinData (table for JS)
local function skinRenderData(mf, mood, webDir)
    local dw = (mf and mf.display and mf.display.w) or 108
    local dh = (mf and mf.display and mf.display.h) or 116
    if mf and mf.gifs then
        -- GIF-per-mood skin: precompute data URLs for every mood so JS can
        -- swap by changing <img src> without contacting Lua again.
        local urls = {}
        for k, file in pairs(mf.gifs) do
            urls[k] = fileDataUrl(mf.dir .. file)
        end
        return { kind = "gif", w = dw, h = dh, urls = urls }
    elseif mf and mf.spritesheet then
        -- Sprite sheet: emit inline styles per mood (JS applies them)
        local sheetUrl = fileDataUrl(mf.dir .. mf.spritesheet)
        local sw = (mf.sheet and mf.sheet.w) or 1536
        local sh = (mf.sheet and mf.sheet.h) or 1872
        local fw = (mf.frame and mf.frame.w) or 192
        local fh = (mf.frame and mf.frame.h) or 208
        local scale = dw / fw
        local styles = {}
        for k, a in pairs(mf.animations or {}) do
            local col0 = a.col or 0
            local row  = a.row or 0
            local count = a.count or 1
            local dur = a.duration or 0.9
            styles[k] = {
                url = sheetUrl,
                sheetW = math.floor(sw * scale), sheetH = math.floor(sh * scale),
                startX = -col0 * dw, endX = -(col0 + count) * dw,
                startY = -row * dh,
                count = count, duration = dur,
            }
        end
        return { kind = "sprite", w = dw, h = dh, sprites = styles }
    end
    -- Built-in Tac: send raw SVG markup per mood, JS injects it.
    return { kind = "tac", w = 84, h = 84, svgs = loadTacSvgs(webDir or "") }
end

-- ---------- Public API ----------

-- create(opts) -> companion object
--   opts.webDir      : absolute path to web/
--   opts.onPetClick  : called when the pet body is clicked (toggle expand)
--   opts.onBubbleDismiss : called when the × on the bubble is clicked
--   opts.onAction    : called for every panel action {action, params}
function M.create(opts)
    local companion = {
        opts = opts,
        visible = false,
        expanded = false,
    }

    local bridgeLog = os.getenv("HOME") .. "/.claude-menubar/menubar.log"
    local function blog(s)
        local f = io.open(bridgeLog, "a")
        if f then f:write(string.format("[%s] bridge: %s\n", os.date("%H:%M:%S"), s)); f:close() end
    end

    local controller = hs.webview.usercontent.new("claudeMenubar")
    controller:setCallback(function(message)
        local body = message and message.body
        if type(body) ~= "table" then return end
        local action = body.action
        if action ~= "resize" then blog("recv action=" .. tostring(action)) end
        if action == "toggle-expand" and opts.onPetClick then
            pcall(opts.onPetClick)
        elseif action == "bubble-dismiss" and opts.onBubbleDismiss then
            pcall(opts.onBubbleDismiss)
        elseif opts.onAction then
            pcall(opts.onAction, action, body.params or {})
        end
    end)
    companion.controller = controller

    -- Load HTML from web/index.html (self-contained template with all styles
    -- and JS inlined). This lets us edit the panel visually without touching
    -- Lua strings.
    local html = readFile(opts.webDir .. "index.html")
    if not html then
        error("companion: web/index.html not found under " .. opts.webDir)
    end
    -- Inline the CSS and JS so no file:// requests are needed. The template
    -- already references them relatively, so we substitute inline.
    local css = readFile(opts.webDir .. "styles.css") or ""
    local js  = readFile(opts.webDir .. "app.js")    or ""
    html = html:gsub('<link rel="stylesheet" href="styles.css"[^>]*>', function()
        return "<style>" .. css .. "</style>"
    end)
    html = html:gsub('<script src="app.js"[^>]*></script>', function()
        return "<script>" .. js .. "</script>"
    end)
    companion.html = html

    local view = hs.webview.new(hs.geometry.rect(0, 0, WIDTH, IDLE_HEIGHT), {
        developerExtrasEnabled = true,
    }, controller)
        :allowTextEntry(false)
        :transparent(true)
        :windowStyle({ "borderless", "nonactivating" })
        :level(hs.drawing.windowLevels.floating)
        :shadow(false)
        :html(html)
    companion.view = view
    return companion
end

-- Compute the frame for a given mode and pet position. Pet's bottom-right
-- is the anchor; the window grows upward when expanded.
local function frameFor(mode, position)
    local screen = hs.screen.mainScreen():frame()
    local h = (mode == "expanded") and EXPANDED_HEIGHT or IDLE_HEIGHT
    local x, y
    if position and type(position.x) == "number" and type(position.y_bottom) == "number" then
        -- position.y_bottom is where the bottom of the (idle) window sits
        x = position.x
        y = position.y_bottom - h
    else
        x = screen.x + screen.w - WIDTH - MARGIN
        y = screen.y + screen.h - h - MARGIN
    end
    return { x = x, y = y, w = WIDTH, h = h }
end

-- position argument: { x = ..., y_bottom = ... } (bottom edge anchor).
-- Pass nil to use the default bottom-right corner of the main screen.
function M.show(companion, position)
    if not companion or not companion.view then return end
    companion.position = position
    local mode = companion.expanded and "expanded" or "idle"
    companion.view:frame(frameFor(mode, position))
    companion.view:show()
    companion.visible = true
end

function M.hide(companion)
    if not companion or not companion.view then return end
    companion.view:hide()
    companion.visible = false
end

function M.destroy(companion)
    if companion and companion.view then
        companion.view:delete()
        companion.view = nil
    end
    if companion then
        companion.visible = false
        companion.expanded = false
    end
end

-- Expand / collapse the panel with the pet anchored at the bottom.
function M.setExpanded(companion, expanded)
    if not companion or not companion.view then return end
    if companion.expanded == expanded then return end
    companion.expanded = expanded
    companion.view:frame(frameFor(expanded and "expanded" or "idle", companion.position))
    -- Tell JS to swap the mode class so panel visibility toggles.
    companion.view:evaluateJavaScript(
        "document.body.classList.toggle('mode-expanded', " .. tostring(expanded) .. ");" ..
        "document.body.classList.toggle('mode-idle', " .. tostring(not expanded) .. ");"
    )
end

-- ---------- Data push helpers (Lua -> JS) ----------

function M.pushSessions(companion, sessions, top)
    if not companion or not companion.view then return end
    local payload = hs.json.encode({ sessions = sessions, top = top, now = os.time() })
    if not payload then return end
    companion.view:evaluateJavaScript(
        "window.renderSessions && window.renderSessions(" .. payload .. ");")
end

function M.pushSkins(companion, skins)
    if not companion or not companion.view then return end
    local payload = hs.json.encode({ skins = skins })
    if not payload then return end
    companion.view:evaluateJavaScript(
        "window.renderSkins && window.renderSkins(" .. payload .. ");")
end

function M.pushLog(companion, sid, lines)
    if not companion or not companion.view then return end
    local payload = hs.json.encode({ sid = sid, lines = lines })
    if not payload then return end
    companion.view:evaluateJavaScript(
        "window.renderLog && window.renderLog(" .. payload .. ");")
end

-- Push the current pet mood + text. mood is "idle" | "input" | "done" |
-- "review" | nil. When mood is nil or "idle", the bubble is hidden.
--   { skin, skinName, mood, text, subtext }
function M.pushPet(companion, args)
    if not companion or not companion.view then return end
    local mf = loadSkinManifest(args.skin)
    local skinData = skinRenderData(mf, args.mood or "idle", companion.opts and companion.opts.webDir)
    local payload = hs.json.encode({
        skinName = args.skin or "tac",
        skinData = skinData,
        mood = args.mood or "idle",
        text = args.text or "",
        subtext = args.subtext or "",
    })
    if not payload then return end
    companion.view:evaluateJavaScript(
        "window.renderPet && window.renderPet(" .. payload .. ");")
end

return M
