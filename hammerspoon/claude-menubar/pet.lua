-- claude-menubar/pet.lua
-- 桌面宠物：有会话在等确认时，Tac 从屏幕右下角跑出来，气泡喊
-- 「主子，有需求等你确认！」。点宠物 → 打开面板；点 × → 本轮不再打扰；
-- 需求都处理完 → 自动走掉。
--
-- 独立的透明无边框 webview，复用 web/assets 里的 Tac SVG（SMIL 动画内联才生效）。

local M = {}

local WIDTH, HEIGHT = 300, 200
local MARGIN = 28   -- gap from screen bottom-right corner

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function loadSvgRaw(webDir, filename)
    local raw = readFile(webDir .. "assets/" .. filename)
    if not raw then return "" end
    raw = raw:gsub("<%?xml.-%?>%s*", "", 1)
    return raw
end

local function escapeHtml(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- mood: "input" (pink, needs-you) | "done" (green, celebration)
local MOODS = {
    input = { svg = "tac-needs-input.svg", accent = "232,76,136" },
    done  = { svg = "tac-complete.svg",    accent = "74,222,128" },
}

-- ---------- Skin loading ----------
-- A skin lives at ~/.claude-menubar/skins/<name>/ and contains:
--   - manifest.json (frame size, animation ranges per mood)
--   - spritesheet.webp / .png
-- The special skin "tac" is the built-in SVG and doesn't need files.
-- Skins are personal — no third-party asset is shipped with the repo.
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

-- Base64-encode a file's bytes. Cached per skin so we don't re-read
-- 2 MB from disk every time the pet reappears.
local base64Cache = {}
local function spriteDataUrl(mf)
    local key = mf.dir .. mf.spritesheet
    local cached = base64Cache[key]
    if cached then return cached end
    local path = mf.dir .. mf.spritesheet
    local f = io.open(path, "rb")
    if not f then return "" end
    local data = f:read("*a"); f:close()
    local ok, b64 = pcall(hs.base64.encode, data)
    if not ok or not b64 then return "" end
    -- hs.base64.encode inserts line breaks; strip them for a valid data URL.
    b64 = b64:gsub("%s+", "")
    local mime = "image/webp"
    if path:sub(-4) == ".png" then mime = "image/png"
    elseif path:sub(-4) == ".jpg" or path:sub(-5) == ".jpeg" then mime = "image/jpeg" end
    local url = "data:" .. mime .. ";base64," .. b64
    base64Cache[key] = url
    return url
end

local function buildSpriteBody(mf, mood)
    -- CSS sprite-strip animation. We scale the whole spritesheet down so one
    -- frame fits the requested display size, then animate background-position
    -- across N adjacent frames on the given row. steps(N) keeps frame edges
    -- crisp (no interpolation blur).
    local anim = (mf.animations or {})[mood] or mf.animations.input or {}
    local fw, fh = mf.frame.w, mf.frame.h
    local dw, dh = mf.display.w, mf.display.h
    local sw, sh = mf.sheet.w, mf.sheet.h
    local scale = dw / fw
    local scaledW, scaledH = math.floor(sw * scale), math.floor(sh * scale)
    local col0 = anim.col or 0
    local row  = anim.row or 0
    local count = anim.count or 1
    local duration = anim.duration or 0.9
    local startX = -col0 * dw
    local endX   = -(col0 + count) * dw
    local startY = -row * dh
    -- Inline the spritesheet as a data URL so WKWebView doesn't need file://
    -- access. Base64 encode is cached, so this is cheap after the first read.
    local url = spriteDataUrl(mf)
    local html = string.format([[
    <div class="sprite" style="
      width:%dpx; height:%dpx;
      background: url('%s') no-repeat;
      background-size: %dpx %dpx;
      background-position: %dpx %dpx;
      animation: sprite-loop %.2fs steps(%d) infinite;
      image-rendering: -webkit-optimize-contrast;
    "></div>
    <style>@keyframes sprite-loop {
      from { background-position: %dpx %dpx; }
      to   { background-position: %dpx %dpx; }
    }</style>]],
        dw, dh, url, scaledW, scaledH, startX, startY, duration, count,
        startX, startY, endX, startY)
    return html, dw
end

local function buildHtml(webDir, text, subtext, mood, skinName)
    local m = MOODS[mood or "input"] or MOODS.input
    local mf = loadSkinManifest(skinName)
    local body, bubbleShift
    if mf then
        body, bubbleShift = buildSpriteBody(mf, mood or "input")
        bubbleShift = (mf.bubbleOffset or (bubbleShift / 2 + 6))
    else
        body = '<div class="tac">' .. loadSvgRaw(webDir, m.svg) .. '</div>'
        bubbleShift = 34
    end
    local html = [[<!doctype html><html><head><meta charset="utf-8"><style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { background: transparent; overflow: hidden; width: 100%; height: 100%; }
  body { font-family: "PingFang SC", -apple-system, sans-serif; -webkit-user-select: none; }

  .pet-wrap {
    position: absolute; right: 6px; bottom: 4px;
    display: flex; flex-direction: column; align-items: flex-end;
    animation: walk-in 0.65s cubic-bezier(0.22, 1.2, 0.36, 1) both;
    cursor: pointer;
  }
  @keyframes walk-in {
    0%   { transform: translateX(130%); }
    70%  { transform: translateX(-6%); }
    100% { transform: translateX(0); }
  }

  .bubble {
    position: relative;
    max-width: 240px;
    background: #1b1d22;
    border: 1px solid rgba(232,76,136,0.45);
    border-radius: 14px 14px 4px 14px;
    padding: 10px 30px 10px 14px;
    margin-right: 34px;
    box-shadow: 0 6px 22px rgba(0,0,0,0.35), 0 0 14px rgba(232,76,136,0.18);
    animation: bubble-pop 0.35s 0.45s cubic-bezier(0.34, 1.56, 0.64, 1) both;
  }
  @keyframes bubble-pop {
    from { transform: scale(0.5); opacity: 0; }
    to   { transform: scale(1); opacity: 1; }
  }
  .bubble::after {
    content: ""; position: absolute; right: -7px; bottom: 10px;
    width: 12px; height: 12px; background: #1b1d22;
    border-right: 1px solid rgba(232,76,136,0.45);
    border-bottom: 1px solid rgba(232,76,136,0.45);
    transform: rotate(-45deg);
  }
  .bubble .txt { color: #f4e9ee; font-size: 13px; font-weight: 600; line-height: 1.4; }
  .bubble .sub { color: #9a93a5; font-size: 11px; margin-top: 3px; line-height: 1.35;
                 overflow: hidden; max-width: 200px;
                 display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
  .bubble .close {
    position: absolute; top: 5px; right: 7px;
    color: #6d6878; font-size: 13px; line-height: 1; padding: 3px;
    cursor: pointer;
  }
  .bubble .close:hover { color: #f4e9ee; }

  .tac {
    width: 84px; height: 84px; margin-top: 6px; margin-right: 8px;
    filter: drop-shadow(0 5px 10px rgba(0,0,0,0.4));
    animation: bob 2.2s 0.7s ease-in-out infinite;
  }
  @keyframes bob {
    0%, 100% { transform: translateY(0); }
    50%      { transform: translateY(-5px); }
  }
  .tac svg { width: 100%; height: 100%; }

  /* Sprite-based skins (winkey, muskie, …) */
  .sprite {
    margin-top: 6px; margin-right: 8px;
    filter: drop-shadow(0 5px 10px rgba(0,0,0,0.4));
  }
</style></head><body>
  <div class="pet-wrap" id="pet">
    <div class="bubble" style="margin-right:__BUBBLE_SHIFT__px">
      <span class="close" id="pet-close">✕</span>
      <div class="txt">]] .. escapeHtml(text) .. [[</div>
      ]] .. (subtext and subtext ~= "" and ('<div class="sub">' .. escapeHtml(subtext) .. '</div>') or "") .. [[
    </div>
    ]] .. body .. [[
  </div><!-- accent swapped per mood below -->
  <script>
    function send(action) {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.claudePet) {
        window.webkit.messageHandlers.claudePet.postMessage({ action: action });
      }
    }
    document.getElementById("pet-close").addEventListener("click", function (e) {
      e.stopPropagation();
      send("pet-dismiss");
    });
    document.getElementById("pet").addEventListener("click", function () {
      send("pet-click");
    });
  </script>
</body></html>]]
    -- The template's accent literals are the pink "input" values; swap the
    -- rgb triplet for the mood's accent (green for "done").
    if m.accent ~= MOODS.input.accent then
        html = html:gsub("232,76,136", m.accent)
    end
    html = html:gsub("__BUBBLE_SHIFT__", tostring(math.floor(bubbleShift)))
    return html
end

-- create(opts) -> pet object
--   opts.webDir    : path to web/ (for assets)
--   opts.onClick   : called when the pet body is clicked
--   opts.onDismiss : called when the × is clicked
function M.create(opts)
    local pet = { opts = opts, visible = false }
    local controller = hs.webview.usercontent.new("claudePet")
    controller:setCallback(function(message)
        local body = message and message.body
        if type(body) ~= "table" then return end
        if body.action == "pet-click" and opts.onClick then
            pcall(opts.onClick)
        elseif body.action == "pet-dismiss" and opts.onDismiss then
            pcall(opts.onDismiss)
        end
    end)
    local view = hs.webview.new(hs.geometry.rect(0, 0, WIDTH, HEIGHT), {}, controller)
        :allowTextEntry(false)
        :transparent(true)
        :windowStyle({ "borderless", "nonactivating" })
        :level(hs.drawing.windowLevels.floating)
        :shadow(false)
    pet.view = view
    pet.controller = controller
    return pet
end

-- show(pet, text, subtext, mood, skinName) — (re)loads the HTML so the
-- walk-in animation replays, positions bottom-right of the main screen,
-- and shows the window. mood: "input" (default, pink) | "done" (green).
-- skinName: nil/"tac" → built-in SVG; anything else → ~/.claude-menubar/
-- skins/<name>/ manifest.
function M.show(pet, text, subtext, mood, skinName)
    if not pet or not pet.view then return end
    local html = buildHtml(pet.opts.webDir, text or "A request needs your approval!", subtext, mood, skinName)
    pet.view:html(html)
    local frame = hs.screen.mainScreen():frame()  -- excludes menubar; includes dock side
    pet.view:frame({
        x = frame.x + frame.w - WIDTH - MARGIN,
        y = frame.y + frame.h - HEIGHT - MARGIN,
        w = WIDTH,
        h = HEIGHT,
    })
    pet.view:show()
    pet.visible = true
end

function M.hide(pet)
    if not pet or not pet.view then return end
    pet.view:hide()
    pet.visible = false
end

function M.destroy(pet)
    if pet and pet.view then
        pet.view:delete()
        pet.view = nil
    end
    if pet then pet.visible = false end
end

return M
