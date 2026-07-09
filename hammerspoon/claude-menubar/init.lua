-- claude-menubar/init.lua
-- Entry point. Wires menubar + status file watcher + webview together.
--
-- Public API:
--   require("claude-menubar").start()
--   require("claude-menubar").stop()
--
-- Design: this module is the only one that owns long-lived references
-- (menubar, pathwatcher, timer). The submodules are pure-ish helpers
-- that take state in and return new state out.

local M = {}

-- Resolve module dir so submodules can find web/ assets.
local sourcePath = debug.getinfo(1, "S").source:sub(2)
local moduleDir = sourcePath:match("(.*/)") or "./"
M.moduleDir = moduleDir
M.webDir = moduleDir .. "web/"
M.statusFile = os.getenv("HOME") .. "/.claude-menubar/status.json"

-- Submodules (loaded lazily to keep require cheap)
local menubar = dofile(moduleDir .. "menubar.lua")
local webview = dofile(moduleDir .. "webview.lua")
local transcript = dofile(moduleDir .. "transcript.lua")
local pet = dofile(moduleDir .. "pet.lua")
-- NOTE: desktop_sessions module exists but is intentionally NOT loaded here.
-- The "scan Claude Desktop sessions dir every tick + run transcript heuristic
-- on each" approach was too IO-heavy in practice (~100% CPU). We're back to
-- the status.json-driven data source. Re-enable later only with a debounced /
-- out-of-process indexer.

-- Shared state passed by reference into submodules.
local state = {
    sessions = {},        -- last parsed sessions map
    schemaVersion = 1,
    webviewVisible = false,
    lastToggleAt = 0,     -- epoch ms, debounce guard for R1
    blinkPhase = false,   -- pending title flip flag
    doneAnnounced = {},   -- "sid:updated_at" → true, long-task pings already sent
    petMode = nil,        -- nil | "pending" | "done" — what the pet is showing
}

-- ---------- JSON loading ----------
local hs_json = hs.json

-- Load hook-written status.json as the primary data source. Only sessions
-- whose hooks have fired since Hammerspoon was last running will be visible.
local function loadStatus()
    local f = io.open(M.statusFile, "r")
    if not f then return { schema_version = 1, sessions = {} } end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return { schema_version = 1, sessions = {} } end
    local ok, decoded = pcall(hs_json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return { schema_version = state.schemaVersion or 1, sessions = state.sessions or {} }
    end
    decoded.sessions = decoded.sessions or {}
    decoded.schema_version = decoded.schema_version or 1
    return decoded
end

-- ---------- Effective state (TTL filter, priority) ----------
local SESSION_TTL = 24 * 60 * 60      -- seconds: 24h — keep sessions visible all day
local PRIORITY = { pending = 3, running = 2, done = 1, idle = 0 }

-- State is event-driven via hooks. But "pending" with no pending_permission
-- means "Claude finished a turn, awaiting your reply" — if you don't actually
-- intend to reply, this state stays forever and clutters the panel. So we
-- age it out after STALE_REPLY_TIMEOUT (default 2h) → idle.
--
-- Critical exception: pending WITH pending_permission (waiting on Allow/Deny)
-- never times out — you might come back the next day and still need to act.
local STALE_REPLY_TIMEOUT = 2 * 3600  -- seconds; tune if needed
local DONE_TIMEOUT = 30 * 60          -- done ✓ fades to idle after 30 min

-- ---------- Transcript reconciliation ----------
-- Hooks are events; events get missed (sessions started before hooks were
-- configured, hook process killed, races). The transcript JSONL is ground
-- truth. Whenever the transcript's mtime is NEWER than the last hook write,
-- something happened that the hooks didn't record — derive the state from
-- the transcript's last entry instead of trusting the stale hook state.
local reconCache = {}  -- sid -> { mtime, verdict }  (avoid re-parsing every 5s tick)

local function reconciledState(sid, session)
    local raw = session.state or "idle"
    local tp = session.transcript_path
    if not tp or tp == "" then return raw end
    local attr = hs.fs.attributes(tp)
    if not attr or not attr.modification then return raw end
    local mtime = attr.modification
    if mtime <= (session.updated_at or 0) + 2 then return raw end
    local cached = reconCache[sid]
    if cached and cached.mtime == mtime then return cached.verdict end
    local ev = transcript.lastEvent(tp)
    local verdict = raw
    if ev then
        if ev.kind == "user" or ev.kind == "tool_use" or ev.kind == "tool_result" then
            verdict = "running"   -- user replied / tool in flight / tool finished
        elseif ev.kind == "assistant" then
            verdict = "done"      -- Claude's answer is the newest entry
        end
    end
    reconCache[sid] = { mtime = mtime, verdict = verdict }
    return verdict
end

local function effectiveState(sid, session, now)
    local raw = reconciledState(sid, session)
    local age = now - (session.updated_at or 0)
    if raw == "pending" and not session.pending_permission then
        if age > STALE_REPLY_TIMEOUT then return "idle" end
    end
    if raw == "done" and age > DONE_TIMEOUT then return "idle" end
    return raw
end

local function visibleSessions(sessionsMap, now)
    local list = {}
    for sid, sess in pairs(sessionsMap or {}) do
        local age = now - (sess.updated_at or 0)
        if age <= SESSION_TTL then
            local clone = {}
            for k, v in pairs(sess) do clone[k] = v end
            clone.session_id = sid
            clone.effective_state = effectiveState(sid, sess, now)
            clone.age_seconds = age
            -- If reconciliation moved us off pending, the permission card is
            -- stale — never render Allow/Deny for an already-resolved request.
            if clone.effective_state ~= "pending" then
                clone.pending_permission = nil
            end
            -- Show all states including idle (backfill writes idle for chats
            -- registered from Claude Desktop that haven't yet fired a hook).
            -- The status text just stays muted/grey for idle.
            table.insert(list, clone)
        end
    end
    -- Sort: pending first, then by updated_at desc.
    table.sort(list, function(a, b)
        local ap = a.effective_state == "pending" and 1 or 0
        local bp = b.effective_state == "pending" and 1 or 0
        if ap ~= bp then return ap > bp end
        return (a.updated_at or 0) > (b.updated_at or 0)
    end)
    return list
end

local function topPriority(list)
    local top = "idle"
    for _, sess in ipairs(list) do
        if (PRIORITY[sess.effective_state] or 0) > (PRIORITY[top] or 0) then
            top = sess.effective_state
        end
    end
    return top
end

-- Estimate the panel's rendered height. Generous over-estimates to absolutely
-- avoid the case where content overflows the webview rectangle. JS will then
-- send the true measured height back via `resize` action for fine-tuning.
local function estimatePanelHeight(sessionCount, expandedSid)
    local HEADER   = 70   -- .dd-head
    local FOOTER   = 56   -- .dd-foot
    local ROW      = 80   -- one .sess row (avatar 36 + padding + 2 lines text)
    local EXPANDED = 240
    local EMPTY    = 70
    if sessionCount == 0 then
        return HEADER + EMPTY + FOOTER
    end
    local total = HEADER + (ROW * sessionCount) + FOOTER
    if expandedSid then total = total + EXPANDED end
    return math.min(total, 760)
end

-- ---------- Remote permission decisions ----------
-- The PermissionRequest hook (update_status.py) blocks waiting for a file at
-- ~/.claude-menubar/decisions/<session_id>.json with {"behavior":"allow"|"deny"}.
-- We write that file from two places: the panel's Allow/Deny buttons and the
-- macOS notification's action buttons. The hook then answers Claude Code
-- directly — no window switch needed.
local DECISIONS_DIR = os.getenv("HOME") .. "/.claude-menubar/decisions"
local LOG_FILE = os.getenv("HOME") .. "/.claude-menubar/menubar.log"

-- Persistent debug log — Hammerspoon's console is ephemeral and unreadable
-- from scripts, so anything we might need to debug later goes here too.
local function mlog(fmt, ...)
    local line = string.format("[%s] " .. fmt, os.date("%H:%M:%S"), ...)
    print("[claude-menubar] " .. line)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(line .. "\n"); f:close() end
end
M.mlog = mlog

local function writeDecision(sid, behavior)
    hs.fs.mkdir(DECISIONS_DIR)
    local path = DECISIONS_DIR .. "/" .. sid .. ".json"
    local f, err = io.open(path, "w")
    if f then
        f:write(hs.json.encode({ behavior = behavior, ts = os.time() }))
        f:close()
        mlog("decision written: %s → %s", behavior, sid)
    else
        mlog("decision WRITE FAILED: %s (%s)", path, tostring(err))
    end
end

-- One actionable macOS notification per outstanding permission request.
-- Keyed by requested_at so a NEW request in the same session re-notifies,
-- but the same request never spams. Requires notification style "Alerts"
-- (System Settings → Notifications → Hammerspoon) for the buttons to stick.
state.permNotes = {}  -- sid -> { key, note }

local function withdrawPermNote(sid)
    local cur = state.permNotes[sid]
    if cur then
        if cur.note then pcall(function() cur.note:withdraw() end) end
        state.permNotes[sid] = nil
    end
end

-- Keep in sync with DECISION_WAIT in hooks/update_status.py — after this many
-- seconds the blocked hook has given up and a remote decision would be dead.
local REMOTE_WINDOW = 120

local function notifyPermissions(list)
    local now = os.time()
    local seen = {}
    for _, sess in ipairs(list) do
        local sid = sess.session_id
        seen[sid] = true
        local p = sess.pending_permission
        if p and (not p.requested_at or now - p.requested_at > REMOTE_WINDOW) then
            -- Hook no longer waiting → notification buttons would be no-ops.
            p = nil
            withdrawPermNote(sid)
        end
        if sess.effective_state == "pending" and p then
            local key = tostring(p.requested_at or sess.updated_at or 0)
            local cur = state.permNotes[sid]
            if not cur or cur.key ~= key then
                withdrawPermNote(sid)
                local note = hs.notify.new(function(n)
                    local t = n:activationType()
                    if t == hs.notify.activationTypes.actionButtonClicked then
                        writeDecision(sid, "allow")
                        state.permNotes[sid] = nil
                    elseif t == hs.notify.activationTypes.additionalActionClicked then
                        local extra = n:additionalActivationAction()
                        writeDecision(sid, extra == "Deny" and "deny" or "allow")
                        state.permNotes[sid] = nil
                    end
                end, {
                    title = "Claude 需要权限 · " .. (sess.project or "session"),
                    subTitle = p.tool or "tool",
                    informativeText = ((p.command ~= "" and p.command) or p.reason or ""):sub(1, 140),
                    hasActionButton = true,
                    actionButtonTitle = "Allow",
                    additionalActions = { "Deny" },
                    alwaysShowAdditionalActions = true,
                    withdrawAfter = 0,
                })
                pcall(function() note:send() end)
                state.permNotes[sid] = { key = key, note = note }
            end
        else
            -- Request resolved (allowed in-window, tool ran, session moved on)
            -- → pull the now-stale notification off screen.
            withdrawPermNote(sid)
        end
    end
    -- Sessions that disappeared entirely (SessionEnd / TTL prune).
    for sid in pairs(state.permNotes) do
        if not seen[sid] then withdrawPermNote(sid) end
    end
end

-- ---------- Desktop pet ----------
-- Tac runs out to the bottom-right corner whenever something is waiting on
-- Bella. Keyed by a signature of the outstanding pending items so:
--   · the same batch never re-triggers the walk-in animation every tick
--   · a NEW request re-summons the pet even after she dismissed it
--   · everything handled → pet leaves on its own
local function petSignature(list)
    local parts = {}
    for _, s in ipairs(list) do
        if s.effective_state == "pending" then
            local p = s.pending_permission
            table.insert(parts, s.session_id .. ":" .. tostring(p and p.requested_at or "wait"))
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- ~/.claude-menubar/config.json — optional per-user settings:
--   pet_name           : how the pet addresses you (default: macOS $USER)
--   long_task_seconds  : announce completions for turns that ran at least
--                        this long (default 120; quick Q&A stays silent)
local configCache = nil
local function menubarConfig()
    if configCache then return configCache end
    local cfg = {}
    local f = io.open(os.getenv("HOME") .. "/.claude-menubar/config.json", "r")
    if f then
        local raw = f:read("*a"); f:close()
        local ok, d = pcall(hs_json.decode, raw)
        if ok and type(d) == "table" then cfg = d end
    end
    configCache = cfg
    return cfg
end

local function petName()
    local n = menubarConfig().pet_name
    if type(n) == "string" and n ~= "" then return n end
    return os.getenv("USER") or "master"
end

local function currentSkin()
    local s = menubarConfig().skin
    if type(s) == "string" and s ~= "" then return s end
    return "tac"
end

-- Persisted pet window position (from Bella dragging the pet). Nil if she
-- never dragged it — pet.lua then falls back to the bottom-right default.
local function petPosition()
    local cfg = menubarConfig()
    if type(cfg.pet_x) == "number" and type(cfg.pet_y) == "number" then
        return { x = cfg.pet_x, y = cfg.pet_y }
    end
    return nil
end

local function savePetPosition(x, y)
    local path = os.getenv("HOME") .. "/.claude-menubar/config.json"
    local raw = ""
    local f = io.open(path, "r"); if f then raw = f:read("*a"); f:close() end
    local ok, cfg = pcall(hs_json.decode, raw)
    if not ok or type(cfg) ~= "table" then cfg = {} end
    cfg.pet_x = math.floor(x)
    cfg.pet_y = math.floor(y)
    local out = io.open(path, "w")
    if out then out:write(hs_json.encode(cfg)); out:close() end
    configCache = nil
    mlog("pet position saved: (%d, %d)", x, y)
end

-- Public: hs -c "claudeMenubar.resetPetPosition()"
-- Wipes the saved x/y so the pet snaps back to the default corner.
function M.resetPetPosition()
    local path = os.getenv("HOME") .. "/.claude-menubar/config.json"
    local raw = ""
    local f = io.open(path, "r"); if f then raw = f:read("*a"); f:close() end
    local ok, cfg = pcall(hs_json.decode, raw)
    if not ok or type(cfg) ~= "table" then cfg = {} end
    cfg.pet_x, cfg.pet_y = nil, nil
    local out = io.open(path, "w")
    if out then out:write(hs_json.encode(cfg)); out:close() end
    configCache = nil
    -- Also drop the runtime position on the live companion and re-show at
    -- the default corner so Bella doesn't have to reload Hammerspoon.
    if state.companion then
        state.companion.position = nil
        pet.show(state.companion, nil)
    end
    mlog("pet position reset to default")
    return "pet position reset"
end

-- Scan ~/.claude-menubar/skins/ for available user skins. Always returns
-- the built-in "tac" first, followed by any directory with a manifest.json.
-- Each entry: { name, displayName, active }
local function listSkins()
    local out = { { name = "tac", displayName = "Tac", active = false } }
    local base = os.getenv("HOME") .. "/.claude-menubar/skins"
    if hs.fs.attributes(base) then
        for entry in hs.fs.dir(base) do
            if entry ~= "." and entry ~= ".." then
                local dir = base .. "/" .. entry
                local attr = hs.fs.attributes(dir)
                if attr and attr.mode == "directory" then
                    local mfPath = dir .. "/manifest.json"
                    if hs.fs.attributes(mfPath) then
                        local f = io.open(mfPath, "r")
                        local raw = f and f:read("*a") or ""
                        if f then f:close() end
                        local ok, mf = pcall(hs_json.decode, raw)
                        local dn = (ok and type(mf) == "table" and mf.displayName) or entry
                        table.insert(out, { name = entry, displayName = dn, active = false })
                    end
                end
            end
        end
    end
    local cur = currentSkin()
    for _, s in ipairs(out) do
        if s.name == cur then s.active = true end
    end
    return out
end
M.listSkins = listSkins

-- ---------- Self-service skin installer ----------
-- Handles two zip layouts:
--   A) codex-pets.net format: pet.json + spritesheet.webp
--   B) GIF pack: many <slug>-<state>.gif files (no pet.json)
-- Derives the skin slug from either pet.json.id OR the common GIF prefix,
-- copies files into ~/.claude-menubar/skins/<slug>/, writes a manifest that
-- matches the schema pet.lua understands, and refreshes the picker.

local function shellQuote(s) return "'" .. (s or ""):gsub("'", "'\\''") .. "'" end

local function readJsonFile(path)
    local f = io.open(path, "r"); if not f then return nil end
    local raw = f:read("*a"); f:close()
    local ok, d = pcall(hs_json.decode, raw)
    if ok and type(d) == "table" then return d end
    return nil
end

local function writeJsonFile(path, obj)
    local f = io.open(path, "w"); if not f then return false end
    f:write(hs_json.encode(obj)); f:close(); return true
end

local function slugify(s)
    s = (s or ""):lower():gsub("[^%w%-]", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return (s == "") and "skin" or s
end

local function commonPrefix(names)
    if #names == 0 then return "" end
    local first = names[1]
    for i = #first, 1, -1 do
        local pfx = first:sub(1, i)
        local all = true
        for _, n in ipairs(names) do
            if n:sub(1, i) ~= pfx then all = false; break end
        end
        if all then return pfx end
    end
    return ""
end

function M.installSkinFromZip(zipPath)
    if not zipPath or not hs.fs.attributes(zipPath) then
        return false, "zip not found: " .. tostring(zipPath)
    end
    -- Unpack to a scratch dir under /tmp
    local tmp = os.tmpname() .. ".dir"
    os.remove(tmp); hs.fs.mkdir(tmp)
    local rc = os.execute("unzip -q -o " .. shellQuote(zipPath) .. " -d " .. shellQuote(tmp))
    if not rc then
        return false, "unzip failed"
    end

    -- Handle nested top-level directory (some zips wrap contents in a folder).
    local root = tmp
    do
        local entries, dirs = {}, {}
        for e in hs.fs.dir(tmp) do
            if e ~= "." and e ~= ".." then
                table.insert(entries, e)
                local a = hs.fs.attributes(tmp .. "/" .. e)
                if a and a.mode == "directory" then table.insert(dirs, e) end
            end
        end
        if #entries == 1 and #dirs == 1 then root = tmp .. "/" .. dirs[1] end
    end

    -- Inventory
    local files = {}
    for e in hs.fs.dir(root) do
        if e ~= "." and e ~= ".." then
            local a = hs.fs.attributes(root .. "/" .. e)
            if a and a.mode == "file" then table.insert(files, e) end
        end
    end

    local pet = readJsonFile(root .. "/pet.json")  -- codex-pets.net format
    local gifs = {}
    local spritesheet = nil
    for _, f in ipairs(files) do
        local lower = f:lower()
        if lower:sub(-4) == ".gif" then table.insert(gifs, f)
        elseif lower:sub(-5) == ".webp" or lower:sub(-4) == ".png" then
            if not spritesheet or lower:find("sprite") then spritesheet = f end
        end
    end

    -- Decide the slug + displayName
    local slug, displayName
    if pet and pet.id then
        slug, displayName = slugify(pet.id), pet.displayName or pet.id
    end
    if not slug and #gifs > 0 then
        local names = {}
        -- Lua footgun: string:gsub returns (result, count); passed straight
        -- to table.insert(t, X) it looks like table.insert(t, pos, value).
        -- Extract to a single-value local first.
        for _, g in ipairs(gifs) do
            local n = (g:gsub("%.gif$", ""))
            table.insert(names, n)
        end
        local pfx = (commonPrefix(names):gsub("%-$", ""))
        if pfx ~= "" then
            slug = slugify(pfx)
            -- Prettify: "sam-altman" → "Sam Altman", "mini-sama" → "Mini Sama"
            local dn = pfx:gsub("[-_]+", " "):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b:lower() end)
            displayName = displayName or dn
        end
    end
    if not slug then
        local base = zipPath:match("([^/]+)%.zip$") or "skin"
        slug = slugify(base:gsub("%-gifs$", ""))
        displayName = displayName or slug
    end
    displayName = displayName or slug

    -- Assemble a manifest. GIFs win if present (per-state timing baked in);
    -- otherwise fall back to sprite sheet (needs manual tuning).
    local manifest = {
        displayName = displayName,
        attribution = "Installed via panel",
        display = { w = 108, h = 116 },
        bubbleOffset = 44,
    }
    if #gifs > 0 then
        -- Auto-map moods based on filename hints.
        local function pick(kw) for _, g in ipairs(gifs) do if g:lower():find(kw) then return g end end end
        local running = pick("running%.gif") or pick("running%-right") or pick("run") or gifs[1]
        local jumping = pick("jumping") or pick("waving") or pick("jump") or running
        manifest.gifs = {
            input = running, done = jumping,
            idle = pick("idle"), waiting = pick("waiting"),
            review = pick("review"), failed = pick("failed"),
        }
    elseif spritesheet then
        -- Bare sprite sheet — leave animation ranges empty; user must edit
        -- manifest.json to define them. We still install to unblock browsing.
        manifest.spritesheet = spritesheet
        manifest.frame = { w = 192, h = 208 }
        manifest.sheet = { w = 1536, h = 1872 }
        manifest.animations = { input = { row = 0, col = 0, count = 1, duration = 0.9 } }
    else
        os.execute("rm -rf " .. shellQuote(tmp))
        return false, "zip has neither GIFs nor a sprite sheet"
    end

    -- Move files into ~/.claude-menubar/skins/<slug>/
    local dst = os.getenv("HOME") .. "/.claude-menubar/skins/" .. slug
    os.execute("rm -rf " .. shellQuote(dst))
    hs.fs.mkdir(os.getenv("HOME") .. "/.claude-menubar/skins")
    hs.fs.mkdir(dst)
    for _, f in ipairs(files) do
        if f:lower():sub(-4) == ".gif" or f == spritesheet then
            os.execute("cp " .. shellQuote(root .. "/" .. f) .. " " .. shellQuote(dst .. "/" .. f))
        end
    end
    writeJsonFile(dst .. "/manifest.json", manifest)
    os.execute("rm -rf " .. shellQuote(tmp))
    mlog("installSkin: '%s' → %s (%d gifs)", displayName, slug, #gifs)

    -- Refresh the panel picker if it's open.
    if state.webviewVisible and state.webviewObj then
        pet.pushSkins(state.companion, listSkins())
    end
    return true, slug
end

-- Show a native file dialog for picking a .zip, then install it. Called
-- from the "+" button in the panel footer.
function M.installSkinPrompt()
    local defaults = os.getenv("HOME") .. "/Downloads"
    local picked = nil
    local ok, result = pcall(function()
        return hs.dialog.chooseFileOrFolder(
            "Pick a Codex pet .zip to install",
            defaults, true, false, false, "zip", false)
    end)
    if ok and type(result) == "table" then
        for _, v in pairs(result) do picked = v; break end
    end
    if not picked then return "cancelled" end
    local success, slugOrErr = M.installSkinFromZip(picked)
    if success then
        hs.alert.show("Skin installed: " .. slugOrErr, 2)
        return "installed=" .. slugOrErr
    else
        hs.alert.show("Install failed: " .. tostring(slugOrErr), 3)
        return "error=" .. tostring(slugOrErr)
    end
end

-- Public: hs -c "claudeMenubar.setSkin('winkey')"
-- Writes ~/.claude-menubar/config.json, invalidates the cache, forces the
-- next pet appearance to re-render with the new skin.
function M.setSkin(name)
    if type(name) ~= "string" or name == "" then return "usage: setSkin('<name>')" end
    local path = os.getenv("HOME") .. "/.claude-menubar/config.json"
    local raw = ""
    local f = io.open(path, "r")
    if f then raw = f:read("*a"); f:close() end
    local ok, cfg = pcall(hs_json.decode, raw)
    if not ok or type(cfg) ~= "table" then cfg = {} end
    cfg.skin = name
    local out = io.open(path, "w")
    if out then out:write(hs_json.encode(cfg)); out:close() end
    configCache = nil
    -- v0.4: companion window stays visible; just refresh the pet artwork
    -- with the new skin. (v0.3 used to hide the whole window here — that
    -- caused the pet to disappear in idle mode after switching skins.)
    state.petShownSig = nil
    state.petDismissedSig = nil
    if state.companion then
        pet.pushPet(state.companion, { skin = name, mood = state.petMode or "idle" })
        pet.pushSkins(state.companion, listSkins())
    end
    mlog("skin → %s", name)
    return "skin=" .. name
end

local function formatDur(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds >= 3600 then
        return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    elseif seconds >= 60 then
        return string.format("%dm", math.floor(seconds / 60))
    end
    return string.format("%ds", seconds)
end

local function petTextFor(list)
    local perms, waits, names = 0, 0, {}
    for _, s in ipairs(list) do
        if s.effective_state == "pending" then
            if s.pending_permission then perms = perms + 1 else waits = waits + 1 end
            table.insert(names, s.project or "session")
        end
    end
    local total = perms + waits
    if total == 0 then return nil end
    local who = petName()
    local text
    if perms > 0 then
        text = (total == 1) and string.format("%s, a request needs your approval!", who)
            or string.format("%s, %d requests need your approval!", who, total)
    else
        text = (total == 1) and string.format("%s, a session is waiting for your reply~", who)
            or string.format("%s, %d sessions are waiting for your reply~", who, total)
    end
    return text, table.concat(names, " · ")
end

local function updatePet(list)
    if not state.petObj then
        mlog("pet: petObj is nil")
        return
    end
    local sig = petSignature(list)
    local skin = currentSkin()
    if sig == "" then
        -- Nothing pending. Companion window stays visible (v0.4), but drop
        -- the bubble by pushing an idle-mode pet render.
        if state.petMode == "pending" then
            mlog("pet: all clear → idle")
            pet.pushPet(state.companion, { skin = skin, mood = "idle" })
            state.petMode = nil
        end
        state.petShownSig = nil
        state.petDismissedSig = nil
        return
    end
    if sig == state.petShownSig or sig == state.petDismissedSig then return end
    local text, sub = petTextFor(list)
    if text then
        mlog("pet: show '%s' (%s) skin=%s", text, sub or "", skin)
        local ok, err = pcall(pet.pushPet, state.companion, {
            skin = skin, mood = "input", text = text, subtext = sub or "",
        })
        if not ok then mlog("pet: show ERROR: %s", tostring(err)) end
        state.petShownSig = sig
        state.petMode = "pending"
    end
end

-- ---------- Long-running check-in ("still working on it") ----------
-- When a session has been RUNNING for a while and there's nothing pending,
-- the pet drops by ONCE with the "review" mood (Musk's thinking pose) to
-- reassure that Claude is still on it. Silent for short turns, and only
-- fires once per running turn to avoid spam. Skipped entirely if the skin
-- doesn't define a "review" gif/animation.
local REVIEW_LINGER = 12  -- seconds the review pet stays on screen
local reviewAnnounced = {}  -- "sid:running_since" → true

local function skinHasReview(skinName)
    if not skinName or skinName == "tac" then return false end
    local path = os.getenv("HOME") .. "/.claude-menubar/skins/" .. skinName .. "/manifest.json"
    local f = io.open(path, "r"); if not f then return false end
    local raw = f:read("*a"); f:close()
    local ok, mf = pcall(hs_json.decode, raw)
    if not ok or type(mf) ~= "table" then return false end
    if mf.gifs and mf.gifs.review then return true end
    if mf.animations and mf.animations.review then return true end
    return false
end

local function announceReview(list, now)
    if not state.petObj then return end
    -- Only when the pet isn't already busy (pending has priority).
    if state.petMode == "pending" then return end
    local skin = currentSkin()
    if not skinHasReview(skin) then return end
    local threshold = tonumber(menubarConfig().long_task_seconds) or 120
    -- Skip if ANY session is currently pending — pet stays free for that.
    for _, s in ipairs(list) do
        if s.effective_state == "pending" then return end
    end
    for _, s in ipairs(list) do
        if s.effective_state == "running" and s.running_since then
            local elapsed = now - s.running_since
            if elapsed >= threshold then
                local key = s.session_id .. ":" .. tostring(s.running_since)
                if not reviewAnnounced[key] then
                    reviewAnnounced[key] = true
                    local dur = formatDur(elapsed)
                    mlog("review: %s (%s, %s in)", s.session_id, s.project or "?", dur)
                    local ok, err = pcall(pet.pushPet, state.companion, {
                        skin = skin, mood = "review",
                        text = string.format("%s, still on it…", petName()),
                        subtext = (s.title or s.label or s.project or "") .. "  ·  running " .. dur,
                    })
                    if ok then
                        state.petMode = "review"
                        if state.petReviewTimer then state.petReviewTimer:stop() end
                        state.petReviewTimer = hs.timer.doAfter(REVIEW_LINGER, function()
                            if state.companion and state.petMode == "review" then
                                pet.pushPet(state.companion, { skin = skin, mood = "idle" })
                                state.petMode = nil
                            end
                        end)
                    else
                        mlog("review: show ERROR %s", tostring(err))
                    end
                    return  -- one review pet per tick
                end
            end
        end
    end
end

-- ---------- Long-task completion announcements ----------
-- A turn that ran ≥ long_task_seconds and just hit Stop deserves a ping:
-- macOS notification always (stays in Notification Center if Bella is away),
-- pet celebration when the pet isn't already busy calling out a pending item.
local DONE_PET_LINGER = 25  -- seconds the celebration stays on screen

local function announceDone(list)
    if not state.petObj then return end
    local threshold = tonumber(menubarConfig().long_task_seconds) or 120
    local seen = {}
    for _, s in ipairs(list) do
        seen[s.session_id] = true
        if s.effective_state == "done" and (s.turn_duration or 0) >= threshold then
            local key = s.session_id .. ":" .. tostring(s.updated_at)
            if not state.doneAnnounced[key] then
                state.doneAnnounced[key] = true
                local dur = formatDur(s.turn_duration)
                mlog("done: announce %s (%s, ran %s)", s.session_id, s.project or "?", dur)
                pcall(function()
                    hs.notify.new(function(n)
                        if n:activationType() ~= hs.notify.activationTypes.none then
                            M.showWebView()
                        end
                    end, {
                        title = "Task finished ✓ · " .. (s.project or "session"),
                        informativeText = (s.title or s.label or "") .. "  (ran " .. dur .. ")",
                        withdrawAfter = 0,
                    }):send()
                end)
                local petBusy = state.petMode == "pending"
                if not petBusy then
                    local taskName = s.title or s.label or s.project or "session"
                    local skinNow = currentSkin()
                    local ok, err = pcall(pet.pushPet, state.companion, {
                        skin = skinNow, mood = "done",
                        text = string.format("%s, task finished ✓", petName()),
                        subtext = taskName .. "  ·  " .. (s.project or "") .. " · ran " .. dur,
                    })
                    if not ok then
                        mlog("pet: done-show ERROR: %s", tostring(err))
                    else
                        state.petMode = "done"
                        if state.petDoneTimer then state.petDoneTimer:stop() end
                        state.petDoneTimer = hs.timer.doAfter(DONE_PET_LINGER, function()
                            if state.companion and state.petMode == "done" then
                                pet.pushPet(state.companion, { skin = skinNow, mood = "idle" })
                                state.petMode = nil
                            end
                        end)
                    end
                end
            end
        end
    end
    -- Forget announcements for sessions that left the list (TTL / SessionEnd).
    for key in pairs(state.doneAnnounced) do
        local sid = key:match("^(.-):%d+$") or key
        if not seen[sid] then state.doneAnnounced[key] = nil end
    end
end

-- ---------- Render pipeline ----------
local function render()
    local now = os.time()
    local data = loadStatus()
    state.schemaVersion = data.schema_version or 1
    state.sessions = data.sessions or {}

    local list = visibleSessions(state.sessions, now)
    state.lastList = list
    local top = topPriority(list)

    menubar.update(state.menubarItem, top, #list, state.blinkPhase)
    -- v0.4 safety net: the companion should always be visible. If some
    -- accidental hide slipped through, bring it back on the next tick.
    if state.companion and state.companion.view and not state.companion.view:isVisible() then
        mlog("companion re-show (was hidden)")
        pet.show(state.companion, state.companion.position)
    end
    notifyPermissions(list)
    updatePet(list)
    announceDone(list)
    announceReview(list, now)

    if state.webviewVisible then
        pet.pushSessions(state.companion, list, top)
        pet.pushSkins(state.companion, listSkins())
        local h = estimatePanelHeight(#list, state.expandedSid)
        -- [v0.4] webview.resize removed (fixed idle/expanded sizes)
    end
end

-- ---------- Public lifecycle ----------
function M.start()
    -- IPC so `hs -c "..."` works from a terminal — needed for debugging the
    -- JS→Lua bridge without staring at the Hammerspoon console.
    pcall(function()
        require("hs.ipc")
        hs.ipc.cliInstall()
    end)

    -- Menubar item
    state.menubarItem = menubar.create({
        onClick = function() M.toggleExpand() end,
    })

    -- v0.4 "companion" — one window that hosts the pet permanently and
    -- expands to reveal the panel on click. Aliased to both state.petObj
    -- and state.webviewObj so the rest of the code (push helpers, drag tap)
    -- keeps working while we finish the migration.
    state.companion = pet.create({
        webDir = M.webDir,
        onPetClick = function()
            M.toggleExpand()
        end,
        onBubbleDismiss = function()
            state.petShownSig, state.petDismissedSig = state.petShownSig, state.petShownSig
        end,
        onAction = function(action, params)
            return M.handleAction(action, params)
        end,
    })
    state.petObj = state.companion
    state.webviewObj = state.companion
    -- Show the pet immediately at its saved position (or bottom-right default).
    local savedPos = petPosition()
    local screenFr = hs.screen.mainScreen():frame()
    local posArg = savedPos and { x = savedPos.x, y_bottom = savedPos.y + pet.IDLE_HEIGHT }
                              or nil
    pet.show(state.companion, posArg)
    state.webviewVisible = false   -- panel starts collapsed; pet visible
    -- Push initial idle pet render so the artwork appears right away.
    hs.timer.doAfter(0.3, function()
        if state.companion then
            pet.pushPet(state.companion, { skin = currentSkin(), mood = "idle" })
            pet.pushSkins(state.companion, listSkins())
        end
    end)

    -- Note: we used to watch ~/.claude-menubar/ to react to hook writes. But
    -- since the data source is now Claude Desktop's own sessions directory,
    -- and the hook writes (status.json + lock file) fire pathwatcher dozens
    -- of times per tool call, the watcher caused runaway CPU. The 5s tick
    -- below is sufficient — Desktop sessions don't change faster than that.

    -- 1Hz title blink (pending state). Reuses cached list to avoid full re-scan
    -- every second; the 5s tick refreshes the actual data.
    -- NOTE: both timers use hs.timer.new(..., continueOnError=true). doEvery
    -- kills the timer permanently on the FIRST callback error — one hiccup
    -- (e.g. hs.notify while usernoted restarts) silently stopped all updates.
    state.blinkTimer = hs.timer.new(1.0, function()
        state.blinkPhase = not state.blinkPhase
        local list = state.lastList or {}
        local top = topPriority(list)
        menubar.update(state.menubarItem, top, #list, state.blinkPhase)
    end, true)
    state.blinkTimer:start()

    -- 5s tick: recompute effective state so done→idle expiry, stale sessions
    -- drop off without needing a hook to write.
    state.tickTimer = hs.timer.new(5.0, function()
        local ok, err = pcall(render)
        if not ok then mlog("render ERROR: %s", tostring(err)) end
    end, true)
    state.tickTimer:start()

    -- ---------- Drag handle (eventtap) ----------
    -- Hammerspoon's WKWebView doesn't honor `-webkit-app-region: drag`, so
    -- we implement window dragging manually for both the panel AND the pet.
    -- A 5px movement threshold distinguishes a click (row expand, skin
    -- switch, pet body click, × dismiss) from a drag (reposition window).
    -- The pet's saved position is persisted to config.json on mouseup so
    -- next time it appears in the same spot.
    local drag = { armed = false, active = false, startMouse = nil, startFrame = nil }
    local DRAG_THRESHOLD = 5

    local function pointInFrame(mp, fr)
        return mp.x >= fr.x and mp.x <= fr.x + fr.w
           and mp.y >= fr.y and mp.y <= fr.y + fr.h
    end
    state.dragTap = hs.eventtap.new({
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.leftMouseDragged,
        hs.eventtap.event.types.leftMouseUp,
    }, function(event)
        local et = event:getType()
        local view = state.companion and state.companion.view
        if not view then return false end
        if et == hs.eventtap.event.types.leftMouseDown then
            drag.armed, drag.active = false, false
            local mp = hs.mouse.absolutePosition()
            local fr = view:frame()
            if pointInFrame(mp, fr) then
                drag.startFrame, drag.startMouse = fr, mp
                drag.armed = true
            end
        elseif et == hs.eventtap.event.types.leftMouseDragged then
            if drag.armed and drag.startFrame then
                local mp = hs.mouse.absolutePosition()
                local dx = mp.x - drag.startMouse.x
                local dy = mp.y - drag.startMouse.y
                if not drag.active and (dx*dx + dy*dy) < DRAG_THRESHOLD*DRAG_THRESHOLD then
                    return false  -- click, not drag
                end
                drag.active = true
                view:frame({
                    x = drag.startFrame.x + dx,
                    y = drag.startFrame.y + dy,
                    w = drag.startFrame.w,
                    h = drag.startFrame.h,
                })
            end
        elseif et == hs.eventtap.event.types.leftMouseUp then
            if drag.active then
                local fr = view:frame()
                -- Save the pet's bottom-edge position (independent of
                -- idle/expanded height) so both modes anchor to the same
                -- visual spot.
                savePetPosition(fr.x, fr.y + fr.h - pet.IDLE_HEIGHT)
                if state.companion then
                    state.companion.position = { x = fr.x, y_bottom = fr.y + fr.h }
                end
            end
            drag.armed, drag.active = false, false
        end
        return false  -- never swallow events; clicks still propagate
    end)
    state.dragTap:start()

    -- Accessibility hint.
    if not hs.accessibilityState() then
        hs.alert.show("Claude Menubar: please grant Accessibility to Hammerspoon", 4)
    end

    render()
    print("[claude-menubar] started")

    -- Backfill: scan Claude Desktop's sessions directory ONCE on startup and
    -- register any chats from the last 24h that aren't already in status.json
    -- (e.g. chats that existed before our hooks were configured).
    -- This is a one-shot scan, not a recurring tick — CPU-cheap.
    hs.timer.doAfter(1.0, function()
        local ok, n = pcall(M.backfillFromDesktopSessions, 24 * 3600)
        if ok and n and n > 0 then
            print("[claude-menubar] backfill: registered " .. n .. " sessions from Claude Desktop")
            render()
        end
    end)
end

-- Scan Claude Desktop's own session JSON files and register any active chats
-- that aren't yet tracked in status.json. Runs ONCE at startup. Returns count.
function M.backfillFromDesktopSessions(maxAgeSeconds)
    maxAgeSeconds = maxAgeSeconds or (24 * 3600)
    local DESKTOP_DIR = os.getenv("HOME") .. "/Library/Application Support/Claude/claude-code-sessions"
    local PROJECTS_DIR = os.getenv("HOME") .. "/.claude/projects"

    -- Safety: only proceed if directory exists.
    if not hs.fs.attributes(DESKTOP_DIR) then return 0 end

    local now = os.time()
    local cutoff = now - maxAgeSeconds

    -- Build cliSessionId → transcript path index once.
    local transcriptMap = {}
    local okp = pcall(function()
        for proj in hs.fs.dir(PROJECTS_DIR) do
            if proj ~= "." and proj ~= ".." then
                local projPath = PROJECTS_DIR .. "/" .. proj
                local attr = hs.fs.attributes(projPath)
                if attr and attr.mode == "directory" then
                    for f in hs.fs.dir(projPath) do
                        if f:sub(-6) == ".jsonl" then
                            transcriptMap[f:sub(1, -7)] = projPath .. "/" .. f
                        end
                    end
                end
            end
        end
    end)
    if not okp then transcriptMap = {} end

    -- Load existing status.json so we don't overwrite hook-written entries.
    local existing = {}
    do
        local f = io.open(M.statusFile, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            local okj, d = pcall(hs_json.decode, raw)
            if okj and type(d) == "table" and d.sessions then
                existing = d.sessions
            end
        end
    end

    -- Walk Desktop sessions dir (workspace/sub/local_*.json)
    local toAdd = {}
    pcall(function()
        for ws in hs.fs.dir(DESKTOP_DIR) do
            if ws ~= "." and ws ~= ".." then
                local wp = DESKTOP_DIR .. "/" .. ws
                local wpAttr = hs.fs.attributes(wp)
                if wpAttr and wpAttr.mode == "directory" then
                    for sub in hs.fs.dir(wp) do
                        if sub ~= "." and sub ~= ".." then
                            local sp = wp .. "/" .. sub
                            local spAttr = hs.fs.attributes(sp)
                            if spAttr and spAttr.mode == "directory" then
                                for f in hs.fs.dir(sp) do
                                    if f:sub(1, 6) == "local_" and f:sub(-5) == ".json" then
                                        local fp = sp .. "/" .. f
                                        local file = io.open(fp, "r")
                                        if file then
                                            local raw = file:read("*a")
                                            file:close()
                                            local okj, d = pcall(hs_json.decode, raw)
                                            if okj and type(d) == "table"
                                               and d.cliSessionId
                                               and not d.isArchived then
                                                local laSec = math.floor((d.lastActivityAt or 0) / 1000)
                                                if laSec >= cutoff and not existing[d.cliSessionId] then
                                                    table.insert(toAdd, {
                                                        session_id = d.cliSessionId,
                                                        title = d.title or "(untitled)",
                                                        cwd = d.cwd or d.originCwd or "",
                                                        updated_at = laSec,
                                                        transcript_path = transcriptMap[d.cliSessionId] or "",
                                                    })
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    if #toAdd == 0 then return 0 end

    -- Write them all in a single status.json update.
    local f = io.open(M.statusFile, "r")
    local raw = f and f:read("*a") or ""
    if f then f:close() end
    local ok, data = pcall(hs_json.decode, raw)
    if not ok or type(data) ~= "table" then
        data = { schema_version = 2, sessions = {} }
    end
    data.sessions = data.sessions or {}
    for _, s in ipairs(toAdd) do
        local cwd = s.cwd
        local project = cwd:match("([^/]+)$") or "session"
        data.sessions[s.session_id] = {
            state = "idle",            -- Hooks will update once user interacts
            project = project,
            title = s.title,
            label = "",                -- Will be re-derived when hook fires
            updated_at = s.updated_at,
            transcript_path = s.transcript_path,
            cwd = cwd,
            pending_permission = nil,
        }
    end
    local encoded = hs_json.encode(data)
    local wf = io.open(M.statusFile, "w")
    if wf then wf:write(encoded); wf:close() end
    return #toAdd
end

function M.petProbe(methodName)
    if not state.petObj or not state.petObj.view then return "no pet" end
    return "method=" .. tostring(methodName) .. " type=" .. type(state.petObj.view[methodName])
end

function M.listPetMethods(pattern)
    if not state.petObj or not state.petObj.view then return "no pet" end
    local mt = getmetatable(state.petObj.view)
    local out = {}
    for k, _ in pairs(mt) do
        if not pattern or k:find(pattern) then table.insert(out, k) end
    end
    table.sort(out)
    return table.concat(out, ", ")
end

function M.listPetWindowMethods(pattern)
    if not state.petObj or not state.petObj.view then return "no pet" end
    local w = state.petObj.view:hswindow()
    if not w then return "no hs.window" end
    local mt = getmetatable(w)
    local out = {}
    for k, _ in pairs(mt) do
        if not pattern or k:find(pattern) then table.insert(out, k) end
    end
    table.sort(out)
    return table.concat(out, ", ")
end

-- Debug helper: inspect the pet object from `hs -c`.
function M.forcePetMood(mood)
    if not state.companion then return "no companion" end
    pet.pushPet(state.companion, { skin = currentSkin(), mood = mood or "idle" })
    return "pushed " .. tostring(mood or "idle")
end

function M.petFrame()
    if not state.companion or not state.companion.view then return nil end
    local f = state.companion.view:frame()
    return string.format("%d %d %d %d", f.x, f.y, f.w, f.h)
end

function M.petDebug()
    if not state.petObj then return "petObj=NIL" end
    local v = state.petObj.view
    local out = string.format("view=%s visible=%s mode=%s",
        v and "ok" or "NIL", tostring(state.petObj.visible), tostring(state.petMode))
    if v then
        local f = v:frame()
        out = out .. string.format(" frame=(%d,%d %dx%d) shown=%s",
            f.x, f.y, f.w, f.h, tostring(v:isVisible()))
    end
    return out
end

-- Debug helper: run JS inside the panel webview from `hs -c`. Result lands in
-- ~/.claude-menubar/menubar.log (evaluateJavaScript is async).
function M.evalJS(js)
    if state.webviewObj and state.webviewObj.view then
        state.webviewObj.view:evaluateJavaScript(js, function(result, err)
            mlog("evalJS → %s | err: %s", hs.inspect(result), hs.inspect(err))
        end)
        return true
    end
    return false
end

function M.stop()
    if state.dragTap then state.dragTap:stop(); state.dragTap = nil end
    if state.watcher then state.watcher:stop(); state.watcher = nil end
    if state.blinkTimer then state.blinkTimer:stop(); state.blinkTimer = nil end
    if state.tickTimer then state.tickTimer:stop(); state.tickTimer = nil end
    if state.petObj then pet.destroy(state.petObj); state.petObj = nil end
    state.webviewObj = nil  -- v0.4: same window as state.petObj, destroyed above
    if state.menubarItem then state.menubarItem:delete(); state.menubarItem = nil end
    state.webviewVisible = false
    print("[claude-menubar] stopped")
end

-- ---------- WebView toggle (R1 race resolution) ----------
-- The race: menubar click fires AND webview focusLost fires when the user clicks
-- the icon a second time. We resolve it with two guards:
--   1. A single source of truth (`state.webviewVisible`) — the menubar click
--      reads this flag, not whether the webview is on screen. Clicking always
--      flips the flag.
--   2. A 250ms debounce between menubar clicks (`state.lastToggleAt`). If the
--      click handler fires within 250ms of the last toggle, ignore it — that's
--      the focus-lost echo bouncing back.
local TOGGLE_DEBOUNCE_MS = 250

function M.toggleWebView()
    local nowMs = hs.timer.absoluteTime() / 1e6
    if nowMs - state.lastToggleAt < TOGGLE_DEBOUNCE_MS then
        return -- swallow the echo
    end
    state.lastToggleAt = nowMs
    if state.webviewVisible then
        M.hideWebView()
    else
        M.showWebView()
    end
end

-- v0.4: showWebView / hideWebView now just expand / collapse the companion.
-- The window itself stays visible (pet is always shown); only the panel
-- above the pet toggles.
function M.showWebView()
    if not state.companion then return end
    state.webviewVisible = true
    local data = loadStatus()
    state.schemaVersion = data.schema_version or 1
    state.sessions = data.sessions or {}
    local list = visibleSessions(state.sessions, os.time())
    state.lastList = list
    pet.setExpanded(state.companion, true)
    pet.pushSessions(state.companion, list, topPriority(list))
    pet.pushSkins(state.companion, listSkins())
end

function M.hideWebView()
    if not state.companion then return end
    state.webviewVisible = false
    pet.setExpanded(state.companion, false)
end

-- Toggle expanded state (called by menubar click and pet body click).
function M.toggleExpand()
    if state.webviewVisible then M.hideWebView() else M.showWebView() end
end

-- ---------- URL action handler (JS -> Lua bridge) ----------
function M.handleAction(action, params)
    if action ~= "resize" then
        mlog("action: %s %s", tostring(action), hs.json.encode(params or {}))
    end
    if action == "open-status" then
        hs.execute("open " .. M.statusFile)
        return true
    elseif action == "quit" then
        local app = hs.application.get("Hammerspoon")
        if app then app:kill() end
        return true
    elseif action == "expand" then
        local sid = params.sid
        if not sid then return false end
        -- Look up the session in the last-rendered list (faster than re-scanning).
        local sess = nil
        for _, s in ipairs(state.lastList or {}) do
            if s.session_id == sid then sess = s; break end
        end
        if not sess then return false end
        state.expandedSid = sid
        local lines = transcript.tail(sess.transcript_path or "", 6)
        pet.pushLog(state.companion, sid, lines)
        local list = state.lastList or {}
        local h = estimatePanelHeight(#list, state.expandedSid)
        -- [v0.4] webview.resize removed (fixed idle/expanded sizes)
        return true
    elseif action == "collapse" then
        state.expandedSid = nil
        local list = state.lastList or {}
        local h = estimatePanelHeight(#list, nil)
        -- [v0.4] webview.resize removed (fixed idle/expanded sizes)
        return true
    elseif action == "set-skin" then
        local name = params.name
        if name then M.setSkin(name) end
        return true
    elseif action == "install-skin" then
        -- Fire the file picker off the main render tick.
        hs.timer.doAfter(0, function() M.installSkinPrompt() end)
        return true
    elseif action == "decide" then
        -- Allow/Deny clicked in the panel's permission card.
        local sid, behavior = params.sid, params.behavior
        if not sid or (behavior ~= "allow" and behavior ~= "deny") then return false end
        writeDecision(sid, behavior)
        withdrawPermNote(sid)
        -- Optimistic UI: the hook rewrites status.json within ~0.25s, but flip
        -- the local copy now so the card doesn't linger for a tick.
        for _, s in ipairs(state.lastList or {}) do
            if s.session_id == sid then
                s.effective_state = "running"
                s.pending_permission = nil
            end
        end
        pet.pushSessions(state.companion, state.lastList or {},
                             topPriority(state.lastList or {}))
        return true
    elseif action == "resize" then
        -- Front-end reports its real panel height — shrink the webview
        -- container to match so there's no empty/transparent area below.
        local h = tonumber(params.height)
        print(string.format("[resize-action] received height=%s", tostring(params.height)))
        if h and h > 80 and h < 1200 and state.webviewObj and state.webviewObj.view then
            -- [v0.4] webview.resize removed (fixed idle/expanded sizes)
        else
            print(string.format("[resize-action] REJECTED — h=%s, wv=%s", tostring(h), tostring(state.webviewObj and "yes" or "no")))
        end
        return true
    end
    return false
end

return M
