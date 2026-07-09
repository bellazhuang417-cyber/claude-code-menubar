-- claude-menubar/webview.lua
-- WebView lifecycle + Lua<->JS bridge.
--
-- Returns an opaque "wv" object that callers pass back to show/hide/pushSessions.
-- Internally that object is just a table holding the hs.webview plus its config.

local M = {}

local WIDTH = 380
local HEIGHT = 600
local OFFSET_Y = 6  -- gap below the menubar icon

-- Parse `hammerspoon://action?key=value&key=value` URLs into (action, params).
local function parseUrl(url)
    if not url then return nil, {} end
    local scheme = url:match("^([%w%-]+)://")
    if scheme ~= "hammerspoon" then return nil, {} end
    local rest = url:sub(#"hammerspoon://" + 1)
    local action, query = rest:match("^([^?]+)%??(.*)$")
    local params = {}
    if query and query ~= "" then
        for k, v in query:gmatch("([^&=]+)=([^&=]*)") do
            params[k] = hs.http.urlDecode and hs.http.urlDecode(v) or v
        end
    end
    return action, params
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

-- Build a fully-inlined HTML doc. Why inline rather than file:// linking?
-- See PRD R3 — file:// reliability under hs.webview varies. We resolve by
-- inlining CSS + JS at load time. The source files stay split for developer
-- ergonomics (mock mode in browser); we just concat them at runtime.
local function buildInlineHtml(webDir)
    local html = readFile(webDir .. "index.html") or "<html><body>missing index.html</body></html>"
    local css = readFile(webDir .. "styles.css") or ""
    local js = readFile(webDir .. "app.js") or ""

    -- Inline Tac SVG mascot assets as RAW XML strings (NOT data URIs).
    -- Rationale: WebKit disables SMIL animations when SVG is loaded via <img>
    -- or data: URI. Inline <svg> is the only way to get tail-sway / eye-blink
    -- to animate. We strip the XML prolog so it can be injected mid-document,
    -- and we'll rewrite duplicate IDs per-row in JS to avoid <defs> collisions.
    local function loadSvgRaw(filename)
        local raw = readFile(webDir .. "assets/" .. filename)
        if not raw then return "" end
        -- Drop the <?xml ... ?> prolog — HTML doesn't accept it inline.
        raw = raw:gsub("<%?xml.-%?>%s*", "", 1)
        return raw
    end
    local tacSvgs = {
        idle    = loadSvgRaw("tac.svg"),
        running = loadSvgRaw("tac-working.svg"),
        pending = loadSvgRaw("tac-needs-input.svg"),
        done    = loadSvgRaw("tac-complete.svg"),
    }
    -- Embed the raw-SVG lookup as a window-level JS variable.
    local svgInject = string.format(
        '<script>window.TAC_SVGS = { idle: %q, running: %q, pending: %q, done: %q };</script>',
        tacSvgs.idle, tacSvgs.running, tacSvgs.pending, tacSvgs.done
    )

    -- Strip the external <link> and <script> tags, inline instead.
    html = html:gsub('<link[^>]-href="styles%.css"[^>]->', "")
    html = html:gsub('<link[^>]-href="styles%.css"[^>]*/>', "")
    html = html:gsub('<script[^>]-src="app%.js"[^>]->%s*</script>', "")
    -- Inject before </head>: CSS first, then SVG lookup table.
    local headInject = "<style>\n" .. css .. "\n</style>\n" .. svgInject
    if html:find("</head>") then
        html = html:gsub("</head>", function() return headInject .. "\n</head>" end, 1)
    else
        html = headInject .. html
    end
    -- Inject JS before </body>.
    local bodyInject = "<script>\n" .. js .. "\n</script>"
    if html:find("</body>") then
        html = html:gsub("</body>", function() return bodyInject .. "\n</body>" end, 1)
    else
        html = html .. bodyInject
    end
    return html
end

function M.create(opts)
    local wv = {
        opts = opts,
        webDir = opts.webDir,
        urlHandler = opts.urlHandler,
        onFocusLost = opts.onFocusLost,
    }

    local rect = hs.geometry.rect(0, 0, WIDTH, HEIGHT)
    local prefs = {
        developerExtrasEnabled = true,
        suppressesIncrementalRendering = false,
    }
    -- JS→Lua bridge, primary path: WKWebView user-content message handler.
    -- JS calls window.webkit.messageHandlers.claudeMenubar.postMessage({action, params}).
    -- The legacy hammerspoon:// navigation interception below stays as fallback,
    -- but modern WebKit silently drops JS-initiated custom-scheme navigations,
    -- which is why panel clicks (expand / decide) never reached Lua.
    local bridgeLog = os.getenv("HOME") .. "/.claude-menubar/menubar.log"
    local function blog(s)
        print("[bridge] " .. s)
        local f = io.open(bridgeLog, "a")
        if f then f:write(string.format("[%s] bridge: %s\n", os.date("%H:%M:%S"), s)); f:close() end
    end
    local controller = hs.webview.usercontent.new("claudeMenubar")
    controller:setCallback(function(message)
        local body = message and message.body
        if type(body) ~= "table" then
            blog("non-table body: " .. tostring(body))
            return
        end
        if body.action ~= "resize" then
            blog("recv action=" .. tostring(body.action))
        end
        if body.action and wv.urlHandler then
            local ok, err = pcall(wv.urlHandler, body.action, body.params or {})
            if not ok then blog("handler ERROR: " .. tostring(err)) end
        end
    end)
    wv.controller = controller

    -- Dragging is enabled in two ways:
    --  1. CSS `-webkit-app-region: drag` on the panel header (in styles.css)
    --  2. NSWindow's `movableByWindowBackground` (set after construction below)
    local view = hs.webview.new(rect, prefs, controller)
        :allowTextEntry(true)
        :transparent(true)
        :windowStyle({ "borderless", "closable", "nonactivating" })
        :level(hs.drawing.windowLevels.floating)
        :shadow(false)            -- CSS draws the rounded shadow itself; rect shadow would leak
        :closeOnEscape(true)

    -- Navigation interception for hammerspoon:// scheme.
    local navLog = os.getenv("HOME") .. "/.claude-menubar/menubar.log"
    local function nlog(s)
        print("[nav] " .. s)
        if s:find("resize") then return end  -- resize fires constantly; skip file log
        local f = io.open(navLog, "a")
        if f then f:write(string.format("[%s] nav: %s\n", os.date("%H:%M:%S"), s)); f:close() end
    end
    view:navigationCallback(function(action, webview, navigation)
        -- action: "didStartProvisionalNavigation", "didReceiveServerRedirect", etc.
        -- We only care about pre-navigation decisions.
        if action == "didStartProvisionalNavigation" then
            local url = navigation.request and navigation.request.URL
            if url and url:match("^hammerspoon://") then
                nlog("intercepted: " .. tostring(url))
                local act, params = parseUrl(url)
                if act and wv.urlHandler then
                    wv.urlHandler(act, params)
                end
                return true  -- cancel real navigation
            end
        end
        return false
    end)

    -- Focus-lost auto-hide.
    view:windowCallback(function(reason, webview, state)
        if reason == "focusChange" and state == false then
            if wv.onFocusLost then wv.onFocusLost() end
        end
    end)

    -- Load the inlined HTML once. Subsequent updates push via evaluateJavaScript.
    local html = buildInlineHtml(opts.webDir)
    view:html(html, "file://" .. opts.webDir)
    wv.view = view
    return wv
end

function M.destroy(wv)
    if wv and wv.view then
        wv.view:delete()
        wv.view = nil
    end
end

-- Position webview below the menubar icon and bring it on screen.
-- `height` is the panel's estimated content height — if omitted, we use HEIGHT
-- as a fallback. Passing the real height up-front avoids the visible "shrink
-- after appear" flash that happens when we resize after show.
function M.show(wv, iconFrame, height)
    if not wv or not wv.view then return end
    local h = height or HEIGHT
    local screen = hs.screen.mainScreen()
    local screenFrame = screen:frame()  -- excludes menubar
    local x, y

    if iconFrame then
        -- Right-align to icon's right edge; clamp into screen.
        x = iconFrame.x + iconFrame.w - WIDTH
        y = iconFrame.y + iconFrame.h + OFFSET_Y
    else
        x = screenFrame.x + screenFrame.w - WIDTH - 12
        y = screenFrame.y + 32
    end
    if x < screenFrame.x + 8 then x = screenFrame.x + 8 end
    if x + WIDTH > screenFrame.x + screenFrame.w - 8 then
        x = screenFrame.x + screenFrame.w - WIDTH - 8
    end
    wv.view:frame({ x = x, y = y, w = WIDTH, h = h })
    wv.view:show()
    wv.view:bringToFront(true)
    -- Give it focus so focusLost works on next outside click.
    hs.timer.doAfter(0.05, function()
        if wv.view then wv.view:bringToFront(true) end
    end)
end

function M.hide(wv)
    if wv and wv.view then wv.view:hide() end
end

-- Push the full sessions list to JS for re-render.
function M.pushSessions(wv, list, topState)
    if not wv or not wv.view then return end
    local payload = hs.json.encode({ sessions = list, top = topState, now = os.time() })
    if not payload then return end
    -- evaluateJavaScript expects a string of JS.
    local js = "window.renderSessions && window.renderSessions(" .. payload .. ");"
    wv.view:evaluateJavaScript(js)
end

-- Push the current list of available skins so the panel can render its
-- skin picker (bottom of the dropdown). Called on show and after setSkin.
function M.pushSkins(wv, skins)
    if not wv or not wv.view then return end
    local payload = hs.json.encode({ skins = skins })
    if not payload then return end
    local js = "window.renderSkins && window.renderSkins(" .. payload .. ");"
    wv.view:evaluateJavaScript(js)
end

-- Push expanded log lines for one session.
function M.pushLog(wv, sid, lines)
    if not wv or not wv.view then return end
    local payload = hs.json.encode({ sid = sid, lines = lines })
    if not payload then return end
    local js = "window.renderLog && window.renderLog(" .. payload .. ");"
    wv.view:evaluateJavaScript(js)
end

-- Resize the webview window to fit the panel content height.
-- The width stays at WIDTH; only height changes. Keeps the window pinned
-- to the top-right corner where it was anchored.
function M.resize(wv, newHeight)
    if not wv or not wv.view then
        print("[resize] no view to resize")
        return
    end
    local fr = wv.view:frame()
    if not fr then
        print("[resize] no current frame")
        return
    end
    local oldH = fr.h
    fr.h = newHeight
    wv.view:frame(fr)
    print(string.format("[resize] %d -> %d", oldH, newHeight))
end

return M
