-- claude-menubar/transcript.lua
-- Parse Claude Code transcript JSONL files, return the most recent N messages
-- formatted for display in the expanded log section.
--
-- Each input line is a JSON object with shape roughly:
--   { "type": "user" | "assistant", "message": { "role": ..., "content": ... } }
--   { "type": "user", "message": { "content": [{ "type": "tool_result", ... }] } }
-- We emit { kind = "user"|"assistant"|"tool", text = "..." } items.

local M = {}

local function truncate(s, n)
    if not s then return "" end
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s <= n then return s end
    -- Be byte-safe rather than char-safe; good enough for log lines.
    return s:sub(1, n - 1) .. "…"
end

-- Read last ~512KB of a file rather than the whole thing (transcripts grow).
local function readTail(path, maxBytes)
    maxBytes = maxBytes or (512 * 1024)
    local f = io.open(path, "rb")
    if not f then return "" end
    local size = f:seek("end") or 0
    local start = math.max(0, size - maxBytes)
    f:seek("set", start)
    local data = f:read("*a") or ""
    f:close()
    -- If we sliced mid-line, drop the partial first line.
    if start > 0 then
        local nl = data:find("\n")
        if nl then data = data:sub(nl + 1) end
    end
    return data
end

local function extractText(content)
    if type(content) == "string" then return content end
    if type(content) ~= "table" then return "" end
    -- content is a list of parts: { type = "text" | "tool_use" | "tool_result", ... }
    for _, part in ipairs(content) do
        if type(part) == "table" then
            if part.type == "text" and type(part.text) == "string" then
                return part.text
            end
        end
    end
    return ""
end

local function extractToolName(content)
    if type(content) ~= "table" then return nil end
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "tool_use" then
            return part.name or "tool"
        end
    end
    return nil
end

-- tail(transcriptPath, n) -> { { kind, text }, ... }
function M.tail(transcriptPath, n)
    n = n or 6
    if not transcriptPath or transcriptPath == "" then return {} end
    local raw = readTail(transcriptPath)
    if raw == "" then return {} end

    local results = {}  -- collect all, then take last n
    for line in raw:gmatch("[^\n]+") do
        local ok, d = pcall(hs.json.decode, line)
        if ok and type(d) == "table" then
            local t = d.type
            local msg = d.message
            if (t == "user" or t == "assistant") and type(msg) == "table" then
                local content = msg.content
                local toolName = extractToolName(content)
                if toolName then
                    table.insert(results, { kind = "tool", text = toolName })
                end
                local text = extractText(content)
                text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
                if text ~= "" then
                    -- Skip system-y opener noise.
                    local first = text:sub(1, 1)
                    if first ~= "<" and first ~= "[" then
                        table.insert(results, {
                            kind = t,
                            text = truncate(text, 80),
                        })
                    end
                end
            end
        end
    end

    -- Tail N.
    local out = {}
    local startIdx = math.max(1, #results - n + 1)
    for i = startIdx, #results do
        table.insert(out, results[i])
    end
    return out
end

-- lastEvent(transcriptPath) -> { kind = "user"|"assistant"|"tool_use"|"tool_result" } or nil
-- What was the LAST meaningful thing written to the transcript? Used by
-- init.lua to reconcile hook-driven state against ground truth:
--   user        → the user replied (hook missed UserPromptSubmit) → running
--   tool_use    → Claude just issued a tool call → running
--   tool_result → a tool finished (user must have allowed it)    → running
--   assistant   → Claude's text answer is the newest entry       → done
function M.lastEvent(transcriptPath)
    if not transcriptPath or transcriptPath == "" then return nil end
    local raw = readTail(transcriptPath, 64 * 1024)
    if raw == "" then return nil end

    local last = nil
    for line in raw:gmatch("[^\n]+") do
        local ok, d = pcall(hs.json.decode, line)
        if ok and type(d) == "table" then
            local t = d.type
            local msg = d.message
            if (t == "user" or t == "assistant") and type(msg) == "table" then
                local content = msg.content
                local kind = nil
                if type(content) == "table" then
                    -- Scan parts; tool blocks take precedence over text so a
                    -- combined "text + tool_use" assistant message counts as
                    -- an in-flight tool call, not a finished answer.
                    local sawText = false
                    for _, part in ipairs(content) do
                        if type(part) == "table" then
                            if part.type == "tool_use" then
                                kind = "tool_use"
                            elseif part.type == "tool_result" then
                                kind = "tool_result"
                            elseif part.type == "text" and type(part.text) == "string"
                                   and part.text:gsub("%s", "") ~= "" then
                                sawText = true
                            end
                        end
                    end
                    if not kind and sawText then kind = t end
                elseif type(content) == "string" and content:gsub("%s", "") ~= "" then
                    -- Plain-string user messages; skip harness noise.
                    local first = content:sub(1, 1)
                    if first ~= "<" then kind = t end
                end
                if kind then last = { kind = kind } end
            end
        end
    end
    return last
end

-- Heuristic: is this session likely waiting for the user to approve a tool?
-- Logic: scan the tail of the transcript and collect every tool_use_id
-- that doesn't yet have a matching tool_result. If at least one such pending
-- tool_use exists AND the assistant's message timestamp is older than
-- thresholdSeconds, we infer the session is awaiting user approval.
--
-- Returns: boolean, optional secondsSinceRequest
function M.isAwaitingPermission(transcriptPath, thresholdSeconds)
    thresholdSeconds = thresholdSeconds or 8
    if not transcriptPath or transcriptPath == "" then return false end
    local raw = readTail(transcriptPath)
    if raw == "" then return false end

    -- Collect tool_use ids from assistant messages and tool_result ids from
    -- user messages. Anything in tool_use but not in tool_result is pending.
    local pendingToolUses = {}  -- id -> { name = ..., timestamp_iso = ... }
    local satisfied = {}        -- id -> true (we saw a tool_result for it)
    local lastAssistantWithToolUseTs = nil  -- ISO timestamp string

    for line in raw:gmatch("[^\n]+") do
        local ok, d = pcall(hs.json.decode, line)
        if ok and type(d) == "table" then
            local t = d.type
            local msg = d.message
            local ts = d.timestamp  -- ISO 8601 string from Claude transcript
            if (t == "user" or t == "assistant") and type(msg) == "table" then
                local content = msg.content
                if type(content) == "table" then
                    for _, part in ipairs(content) do
                        if type(part) == "table" then
                            if part.type == "tool_use" and part.id then
                                pendingToolUses[part.id] = {
                                    name = part.name or "tool",
                                    timestamp_iso = ts,
                                }
                                if ts then lastAssistantWithToolUseTs = ts end
                            elseif part.type == "tool_result" and part.tool_use_id then
                                satisfied[part.tool_use_id] = true
                            end
                        end
                    end
                end
            end
        end
    end

    -- Any tool_use without a matching tool_result?
    local stillPending = false
    for id, _info in pairs(pendingToolUses) do
        if not satisfied[id] then
            stillPending = true
            break
        end
    end
    if not stillPending then return false end

    -- Parse ISO timestamp to epoch and compare.
    if not lastAssistantWithToolUseTs then return false end
    -- ISO format: "2026-05-21T07:32:45.123Z" — extract date components.
    local y, mo, d, h, mi, s = lastAssistantWithToolUseTs:match(
        "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
    )
    if not y then return false end
    local utcEpoch = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    -- os.time() interprets the table as LOCAL time. Adjust by timezone offset
    -- so we compare UTC-to-UTC.
    local localNow = os.time()
    local utcNow = os.time(os.date("!*t", localNow))
    local tzOffset = localNow - utcNow
    local realEpoch = utcEpoch + tzOffset
    local age = localNow - realEpoch
    if age >= thresholdSeconds then
        return true, age
    end
    return false
end

return M
