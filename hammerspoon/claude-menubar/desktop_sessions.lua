-- claude-menubar/desktop_sessions.lua
-- Read Claude Desktop's own session database directly.
--
-- Why: hook-based status.json only contains sessions that fired a hook event
-- after Hammerspoon started. Bella's actual "what's waiting on me" needs to
-- match what Claude Desktop itself shows. Desktop tracks ALL chats in
-- ~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json
-- (one file per chat), with title, cwd, lastActivityAt, isArchived, etc.
--
-- We also need the transcript path so we can run the "unmatched tool_use"
-- heuristic for needs-input detection. Transcripts live in
-- ~/.claude/projects/<sanitized-path>/<cliSessionId>.jsonl. We build an index
-- once per refresh by scanning project subdirs.

local M = {}

local SESSIONS_DIR = os.getenv("HOME") .. "/Library/Application Support/Claude/claude-code-sessions"
local PROJECTS_DIR = os.getenv("HOME") .. "/.claude/projects"

-- Safe directory listing: hs.fs.dir returns (iterator, directoryData) — pcall
-- would drop the second value, breaking the for loop. We catch errors with a
-- wrapping pcall around the whole iteration instead.
local function listDir(path)
    local results = {}
    if not hs.fs.attributes(path) then return results end
    local ok, err = pcall(function()
        for name in hs.fs.dir(path) do
            if name ~= "." and name ~= ".." then
                table.insert(results, name)
            end
        end
    end)
    if not ok then
        print("[desktop_sessions] listDir failed for " .. path .. ": " .. tostring(err))
    end
    return results
end

-- Build a cliSessionId -> transcript path map across all project subdirs.
local function buildTranscriptMap()
    local map = {}
    for _, proj in ipairs(listDir(PROJECTS_DIR)) do
        local projPath = PROJECTS_DIR .. "/" .. proj
        local attr = hs.fs.attributes(projPath)
        if attr and attr.mode == "directory" then
            for _, f in ipairs(listDir(projPath)) do
                if f:sub(-6) == ".jsonl" then
                    local sid = f:sub(1, -7)
                    map[sid] = projPath .. "/" .. f
                end
            end
        end
    end
    return map
end

-- Cache: scanning ~86 session JSON files + ~100 transcript files per tick was
-- thrashing IO and locking up the machine. We memoize for CACHE_TTL seconds.
local _cache = { ts = 0, data = nil }
local CACHE_TTL = 8  -- seconds

-- list(maxAgeSeconds) -> { { sessionId, title, cwd, project, updated_at, transcript_path }, ... }
-- Only returns active (non-archived) sessions whose lastActivityAt is within the cutoff.
function M.list(maxAgeSeconds)
    maxAgeSeconds = maxAgeSeconds or (24 * 3600)
    local now = os.time()
    if _cache.data and (now - _cache.ts) < CACHE_TTL then
        return _cache.data
    end
    local cutoff = now - maxAgeSeconds

    local transcriptMap = buildTranscriptMap()
    local out = {}

    local scanned = 0
    local SCAN_BUDGET = 200  -- safety limit
    for _, ws in ipairs(listDir(SESSIONS_DIR)) do
        local wsPath = SESSIONS_DIR .. "/" .. ws
        local wsAttr = hs.fs.attributes(wsPath)
        if wsAttr and wsAttr.mode == "directory" then
            for _, sub in ipairs(listDir(wsPath)) do
                local subPath = wsPath .. "/" .. sub
                local subAttr = hs.fs.attributes(subPath)
                if subAttr and subAttr.mode == "directory" then
                    for _, f in ipairs(listDir(subPath)) do
                        if scanned >= SCAN_BUDGET then break end
                        if f:sub(1, 6) == "local_" and f:sub(-5) == ".json" then
                            scanned = scanned + 1
                            local fp = subPath .. "/" .. f
                            local file = io.open(fp, "r")
                            if file then
                                local raw = file:read("*a")
                                file:close()
                                local okj, d = pcall(hs.json.decode, raw)
                                if okj and type(d) == "table"
                                   and d.cliSessionId
                                   and not d.isArchived then
                                    local laMs = d.lastActivityAt or 0
                                    local laSec = math.floor(laMs / 1000)
                                    if laSec >= cutoff then
                                        local cwd = d.cwd or d.originCwd or ""
                                        local project = cwd:match("([^/]+)$") or "session"
                                        table.insert(out, {
                                            session_id     = d.cliSessionId,
                                            title          = d.title or "(untitled)",
                                            cwd            = cwd,
                                            project        = project,
                                            updated_at     = laSec,
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

    _cache.ts = now
    _cache.data = out
    return out
end

-- Force a re-scan on the next call (e.g. when user opens the panel and wants
-- fresh data). Otherwise the TTL cache keeps results between ticks.
function M.invalidate()
    _cache.data = nil
end

return M
