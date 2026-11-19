-- .INI files (GetProfileString and friends), read and written through the
-- DOS file system, keeping the file's own order, comments and spacing.

local dosfs = require("win16.dosfs")

local profile = {}

local cache = {}   -- full DOS path -> {lines = {...}}

-- Default WIN.INI contents for a new home, as Windows 3.1 Setup would write.
profile.defaults = {}

local function load(path)
    local full = dosfs.full(path)
    local c = cache[full]
    if c then return c end
    local text = dosfs.read(full) or profile.defaults[full] or ""
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    if lines[#lines] == "" then lines[#lines] = nil end
    c = {lines = lines, path = full}
    cache[full] = c
    return c
end

local function sectionOf(line)
    return line:match("^%s*%[([^%]]*)%]")
end

-- Returns the line index range [first, last] of a section's entries, or nil.
local function findSection(c, app)
    local want = app:upper()
    for i, line in ipairs(c.lines) do
        local s = sectionOf(line)
        if s and s:upper() == want then
            local j = i + 1
            while j <= #c.lines and not sectionOf(c.lines[j]) do j = j + 1 end
            return i, j - 1
        end
    end
end

local function keyOf(line)
    if line:match("^%s*;") then return nil end
    local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
    return k, v
end

-- value of app/key, or nil
function profile.get(path, app, key)
    local c = load(path)
    local first, last = findSection(c, app)
    if not first then return nil end
    local want = key:upper()
    for i = first + 1, last do
        local k, v = keyOf(c.lines[i])
        if k and k:upper() == want then
            -- a value in quotes loses them, as Windows does
            local q = v:match('^"(.*)"$')
            return q or v
        end
    end
end

-- all keys of a section (for a NULL key name), or all sections (NULL app)
function profile.keys(path, app)
    local c = load(path)
    local out = {}
    if not app then
        for _, line in ipairs(c.lines) do
            local s = sectionOf(line)
            if s then out[#out + 1] = s end
        end
        return out
    end
    local first, last = findSection(c, app)
    if not first then return out end
    for i = first + 1, last do
        local k = keyOf(c.lines[i])
        if k and k ~= "" then out[#out + 1] = k end
    end
    return out
end

local function save(c)
    dosfs.write(c.path, table.concat(c.lines, "\r\n") .. "\r\n")
end

-- value nil deletes the key; key nil deletes the section.
function profile.set(path, app, key, value)
    local c = load(path)
    local first, last = findSection(c, app)
    if not key then
        if first then
            for _ = first, last do table.remove(c.lines, first) end
            save(c)
        end
        return true
    end
    if not first then
        if value == nil then return true end
        if #c.lines > 0 and c.lines[#c.lines] ~= "" then c.lines[#c.lines + 1] = "" end
        c.lines[#c.lines + 1] = "[" .. app .. "]"
        c.lines[#c.lines + 1] = key .. "=" .. value
        save(c)
        return true
    end
    local want = key:upper()
    for i = first + 1, last do
        local k = keyOf(c.lines[i])
        if k and k:upper() == want then
            if value == nil then table.remove(c.lines, i) else c.lines[i] = key .. "=" .. value end
            save(c)
            return true
        end
    end
    if value ~= nil then
        -- after the last non-blank entry of the section
        local at = last
        while at > first and c.lines[at]:match("^%s*$") do at = at - 1 end
        table.insert(c.lines, at + 1, key .. "=" .. value)
        save(c)
    end
    return true
end

-- Forgets cached files (another program changed them).
function profile.flush(path)
    if path then cache[dosfs.full(path)] = nil else cache = {} end
end

-- A profile file name: a bare name lives in the Windows folder.
function profile.resolve(file)
    if not file or file == "" then return dosfs.windows .. "\\WIN.INI" end
    if not file:find("[\\/:]") then return dosfs.windows .. "\\" .. file end
    return file
end

return profile
