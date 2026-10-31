--[[
    RemaTracker - Ashita v4 addon
    Tracks REMA (Relic / Mythic / Empyrean / Aeonic) and Magian trials.

    Install: put this file at  <Ashita>/addons/rematracker/rematracker.lua
    Load:    /addon load rematracker
    Help:    /rt help

    Private servers differ in their trial rules and chat messages, so progress can be
    updated manually OR automatically via a per-trial "watch" rule (kill / item / text)
    that is matched against incoming chat lines.
]]--

addon.name    = 'rematracker'
addon.author  = 'Claude'
addon.version = '2.0'
addon.desc    = 'Tracks REMA and Magian trials with optional chat auto-counting.'
addon.link    = ''

require('common')
local chat     = require('chat')
local imgui    = require('imgui')
local settings = require('settings')

local TYPES = { 'Relic', 'Mythic', 'Empyrean', 'Aeonic', 'Armor', 'Magian', 'Other' }

local defaults = T{
    trials  = T{},
    visible = true,
    nextid  = 1,
    active  = 0, -- id of the trial you are currently on
    auto    = true, -- auto-detect trial + status from NPC dialogue
    party   = true, -- celebration animation when a stage is completed
    moogleLog = true, -- write one report per Magian Moogle visit
    sound   = true, -- play victory.wav with the stage-complete celebration
    magian  = true, -- read trials straight from the server's packets and from items
    magianState = T{}, -- last confirmed trial values (kept across relogs, labelled as cached)
    upgradeRate = 0.5, -- server requirement scaling (UPGRADE_COST_RATE)
    trackSlots = T{ worn = true, c0 = true }, -- where a Magian item must be for its trial to show
    pktmap  = T{ number = T{}, cur = T{}, target = T{}, remaining = T{} }, -- learned packet locations
    trialdb = T{}, -- learned/imported trial numbers -> requirements
    patterns = T{ name = '', progress = '' }, -- optional custom Lua patterns
}

local cfg = settings.load(defaults)

-- UI state
local ui = {
    open     = { cfg.visible },
    typeIdx  = 1,
    name     = { '' },
    target   = { 100 },
    note     = { '' },
    objective = { '' },
    auto      = { cfg.auto ~= false },
    party     = { cfg.party ~= false },
    plognote  = { '' },
    selectId  = nil,
    job       = { '' },
    filter   = 0,
    watchBuf = {},
}

-- Celebration state: set by start_celebration(), drawn by the 'rt_party' frame handler.
local celebrate = { t0 = 0, dur = 9, name = '', broken = false }
-- Victory fanfare: victory.wav next to the addon (converted from the mp3 you supplied; Windows plays WAV, not MP3).
local play_fanfare_ready = false
local function play_fanfare()
    if cfg.sound == false then return false end
    local path = addon.path .. 'victory.wav'
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()
    if ashita and ashita.misc and type(ashita.misc.play_sound) == 'function' then
        if pcall(ashita.misc.play_sound, path) then return true end
    end
    local ok = pcall(function()
        local ffi = require('ffi')
        if not play_fanfare_ready then
            ffi.cdef[[ int PlaySoundA(const char* pszSound, void* hmod, unsigned long fdwSound); ]]
            play_fanfare_ready = true
        end
        ffi.load('winmm').PlaySoundA(path, nil, 0x20001)   -- SND_ASYNC | SND_FILENAME
    end)
    return ok
end

local function start_celebration(name)
    if cfg.party ~= false then
        celebrate.t0, celebrate.name = os.clock(), tostring(name or '')
    end
    play_fanfare()
end

local function say(msg)
    print(chat.header(addon.name):append(chat.message(msg)))
end

--------------------------------------------------------------------------------
-- Error tracking + self-repair
--------------------------------------------------------------------------------
local errlog   = { list = {}, count = 0 }
local logpath  = nil
local MAX_LOG  = 30
local repairing = false

local function write_log(line)
    pcall(function()
        if not logpath then
            local dir = ('%s/config/addons/%s/'):format(AshitaCore:GetInstallPath(), addon.name)
            ashita.fs.create_dir(dir)
            logpath = dir .. 'errors.log'
        end
        local f = io.open(logpath, 'a')
        if f then
            f:write(('%s [%s] %s\n'):format(os.date('%Y-%m-%d %H:%M:%S'), line.where, line.full))
            f:close()
        end
    end)
end

-- kind: 'error' (a handler crashed) or 'fix' (data was repaired)
local function log_error(kind, where, msg)
    msg = tostring(msg or '')
    local first = msg:match('([^\n]*)') or msg
    for _, e in ipairs(errlog.list) do
        if e.kind == kind and e.where == where and e.msg == first then
            e.n = e.n + 1
            e.time = os.date('%H:%M:%S')
            if kind == 'error' then errlog.count = errlog.count + 1 end
            return
        end
    end
    table.insert(errlog.list, { kind = kind, where = where, msg = first, full = msg, n = 1, time = os.date('%H:%M:%S') })
    if #errlog.list > MAX_LOG then table.remove(errlog.list, 1) end
    if kind == 'error' then errlog.count = errlog.count + 1 end
    write_log({ where = where, full = kind .. ': ' .. msg })
    print(chat.header(addon.name):append((kind == 'error' and chat.error or chat.message)(
        (kind == 'error' and 'Error in ' or 'Repaired: ') .. where .. ': ' .. first)))
end

local VALID_MODES = { none = true, kill = true, item = true, text = true }

-- Validates and fixes saved data. Returns the number of fixes made.
local function repair()
    local fixes = 0
    local function fixed(msg) fixes = fixes + 1 log_error('fix', 'data', msg) end

    if type(cfg.trials) ~= 'table' then cfg.trials = T{} fixed('trial list was invalid; reset') end
    if type(cfg.nextid) ~= 'number' then cfg.nextid = 1 fixed('nextid was invalid') end
    if type(cfg.active) ~= 'number' then cfg.active = 0 fixed('active trial was invalid') end
    if type(cfg.auto) ~= 'boolean' then cfg.auto = true end
    if type(cfg.party) ~= 'boolean' then cfg.party = true end
    if type(cfg.magian) ~= 'boolean' then cfg.magian = true end
    if type(cfg.sound) ~= 'boolean' then cfg.sound = true end
    if type(cfg.moogleLog) ~= 'boolean' then cfg.moogleLog = true end
    if type(cfg.magianState) ~= 'table' then cfg.magianState = T{} end
    if type(cfg.trackSlots) ~= 'table' then
        cfg.trackSlots = T{ worn = true, c0 = true }
        if cfg.trackScope == 'wardrobes' or cfg.trackScope == 'all' then
            for _, c in ipairs({ 8, 10, 11, 12 }) do cfg.trackSlots['c' .. c] = true end
        end
        if cfg.trackScope == 'all' then for _, c in ipairs({ 1, 2, 4, 5, 6, 7, 9 }) do cfg.trackSlots['c' .. c] = true end end
    end
    if type(cfg.upgradeRate) ~= 'number' or cfg.upgradeRate <= 0 then cfg.upgradeRate = 0.5 end
    if type(cfg.pktmap) ~= 'table' then cfg.pktmap = T{} end
    for _, k in ipairs({ 'number', 'cur', 'target', 'remaining' }) do
        if type(cfg.pktmap[k]) ~= 'table' then cfg.pktmap[k] = T{} end
        for key, e in pairs(cfg.pktmap[k]) do
            if type(e) ~= 'table' or type(e.id) ~= 'number' or type(e.off) ~= 'number' or type(e.w) ~= 'number'
               or type(e.hits) ~= 'number' or type(e.miss) ~= 'number' or (e.dir ~= 'IN' and e.dir ~= 'OUT') then
                cfg.pktmap[k][key] = nil
            end
        end
    end
    if type(cfg.trialdb) ~= 'table' then cfg.trialdb = T{} fixed('trial database was invalid; reset') end
    for k, e in pairs(cfg.trialdb) do
        if type(e) ~= 'table' or type(e.reqs) ~= 'table' then cfg.trialdb[k] = nil end
    end
    if type(cfg.patterns) ~= 'table' then cfg.patterns = T{ name = '', progress = '' } fixed('custom patterns were invalid; reset') end
    for _, k in ipairs({ 'name', 'progress' }) do if type(cfg.patterns[k]) ~= 'string' then cfg.patterns[k] = '' end end

    local clean, seen, maxid = T{}, {}, 0
    for i, t in ipairs(cfg.trials) do
        if type(t) ~= 'table' then
            fixed(('entry %d was not a trial; removed'):format(i))
        else
            local ok_type = false
            for _, v in ipairs(TYPES) do if v == t.type then ok_type = true end end
            if not ok_type then t.type = 'Other' fixed(('trial %d had bad type; set to Other'):format(i)) end

            if type(t.name) ~= 'string' or t.name == '' then t.name = 'Unnamed trial' fixed(('trial %d had no name'):format(i)) end
            for _, k in ipairs({ 'objective', 'note', 'watch', 'job', 'synced', 'via' }) do
                if type(t[k]) ~= 'string' then t[k] = '' end
            end
            if t.number ~= nil and type(t.number) ~= 'number' then t.number = nil end
            if type(t.reqs) ~= 'table' then t.reqs = {} end
            local goodreqs = {}
            for _, r in ipairs(t.reqs) do
                if type(r) == 'table' and type(r.name) == 'string' and r.name ~= '' then
                    r.kind = (r.kind == 'kill' or r.kind == 'item' or r.kind == 'turnin') and r.kind or 'other'
                    r.need = math.max(1, math.floor(tonumber(r.need) or 1))
                    r.have = math.max(0, math.floor(tonumber(r.have) or 0))
                    r.bag  = math.max(0, math.floor(tonumber(r.bag) or 0))
                    if type(r.key) ~= 'string' or r.key == '' then r.key = r.name:lower() end
                    table.insert(goodreqs, r)
                end
            end
            t.reqs = goodreqs
            if t.reqmode ~= 'derived' and t.reqmode ~= 'explicit' then t.reqmode = 'explicit' end
            if type(t.npc) ~= 'table' then t.npc = {} end
            if type(t.convo) ~= 'table' then t.convo = nil end
            if not VALID_MODES[t.mode] then t.mode = 'none' t.watch = '' fixed(('trial "%s" had bad watch mode; auto-count off'):format(t.name)) end
            if t.mode == 'none' and t.watch ~= '' then t.watch = '' end

            local cur, tgt = tonumber(t.current), tonumber(t.target)
            if not tgt or tgt < 1 then tgt = 1 fixed(('trial "%s" had bad goal; set to 1'):format(t.name)) end
            if not cur or cur < 0 then cur = 0 fixed(('trial "%s" had bad progress; set to 0'):format(t.name)) end
            t.current, t.target = math.floor(cur), math.floor(tgt)
            t.done = t.current >= t.target

            if type(t.id) ~= 'number' or seen[t.id] then
                t.id = nil -- reassigned below once max id is known
                fixed(('trial "%s" had missing/duplicate id'):format(t.name))
            else
                seen[t.id] = true
                if t.id > maxid then maxid = t.id end
            end
            table.insert(clean, t)
        end
    end
    for _, t in ipairs(clean) do
        if not t.id then maxid = maxid + 1 t.id = maxid end
    end
    cfg.trials = clean
    if cfg.nextid <= maxid then cfg.nextid = maxid + 1 end

    local active_ok = false
    for _, t in ipairs(cfg.trials) do if t.id == cfg.active then active_ok = true end end
    if not active_ok and cfg.active ~= 0 then
        cfg.active = cfg.trials[1] and cfg.trials[1].id or 0
        fixed('active trial no longer existed; reselected')
    end

    if fixes > 0 then settings.save() end
    return fixes
end

-- Wrap an event handler so one failure never takes the addon down.
-- After a failure, saved data is re-validated (the most common cause).
local function safe(where, fn)
    return function(...)
        local args, n = { ... }, select('#', ...)
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
        if not ok then
            log_error('error', where, err)
            if not repairing then
                repairing = true
                pcall(repair)
                repairing = false
            end
        end
    end
end

repair() -- fix anything wrong in the saved settings at load time

local function find_trial(id)
    for i, t in ipairs(cfg.trials) do
        if t.id == id then return t, i end
    end
end

local function by_index(n)
    n = tonumber(n)
    if not n then return nil end
    return cfg.trials[n]
end

local function tag(t)
    if (t.job or '') ~= '' then return ('%s - %s'):format(t.type, t.job) end
    return t.type
end

local function add_trial(ttype, name, target, objective, job)
    local t = {
        id        = cfg.nextid,
        type      = ttype,
        name      = name,
        objective = objective or '',
        job       = (job or ''):upper(), -- e.g. WAR, RDM (used by armor trials)
        current   = 0,
        target    = math.max(1, tonumber(target) or 1),
        note      = '',
        reqs      = {},
        reqmode   = 'derived',
        npc       = {},
        mode    = 'none', -- none | kill | item | text
        watch   = '',
        done    = false,
    }
    cfg.nextid = cfg.nextid + 1
    table.insert(cfg.trials, t)
    if cfg.active == 0 or not find_trial(cfg.active) then cfg.active = t.id end
    settings.save()
    return t
end

local function bump(t, n)
    t.current = math.max(0, t.current + n)
    local was = t.done
    t.done = t.current >= t.target
    if t.done and not was then
        say(('STAGE COMPLETE! [%s] %s (%d/%d)'):format(tag(t), t.name, t.current, t.target))
        start_celebration(t.name)
        ui.open[1] = true      -- show the window by itself
        ui.selectId = t.id     -- and jump to that trial's tab
    end
    settings.save()
end

--------------------------------------------------------------------------------
-- NPC auto-detect: read the trial + status from the NPC's dialogue
--------------------------------------------------------------------------------
local capture = { until_t = 0, hard_t = 0, lines = {}, packets = {}, lastpackets = {}, last = {}, time = '', result = 'Waiting. Talk to your trial NPC.' }

local JOBS = {
    WAR = 'warrior', MNK = 'monk', WHM = 'white mage', BLM = 'black mage', RDM = 'red mage',
    THF = 'thief', PLD = 'paladin', DRK = 'dark knight', BST = 'beastmaster', BRD = 'bard',
    RNG = 'ranger', SAM = 'samurai', NIN = 'ninja', DRG = 'dragoon', SMN = 'summoner',
    BLU = 'blue mage', COR = 'corsair', PUP = 'puppetmaster', DNC = 'dancer', SCH = 'scholar',
    GEO = 'geomancer', RUN = 'rune fencer',
}
local GATE      = { 'trial', 'magian', 'relic', 'mythic', 'empyrean', 'aeonic', 'armor', 'armour' }
local NAME_PATS = { '[Cc]urrent [Tt]rial%s*[:%-]?%s*(.-)%s*$', '[Tt]rial[^:]-:%s*(.-)%s*$', '[Tt]rial of ([^%.!,]+)' }
local OBJ_VERBS = { 'defeat', 'slay', 'kill', 'obtain', 'collect', 'gather', 'fish', 'synthesize', 'craft', 'perform', 'complete', 'deliver', 'use ' }

local function smatch(s, pat)
    if type(pat) ~= 'string' or pat == '' then return nil end
    local ok, a, b = pcall(string.match, s, pat)
    if ok then return a, b end
end

local function trim(s) return ((s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- The Magian Moogle's trial text, exactly as seen on VanaDreams:
--   "Trial: Defeat a set number of experience-yielding monsters under the prescribed conditions."
--   "Objective: Black Triple Stars / Kills: 0/2.Equipment: Target item must be equipped.Area: Rolanberry Fields."
--   "Here is all you need to know about Trial 3, kupo."
local function parse_moogle_text(lines)
    local out
    for _, ln in ipairs(lines) do
        local mob, label, a, b, rest = ln:match('^%s*Objective:%s*(.-)%s*/%s*(%a+):%s*(%d+)%s*/%s*(%d+)%.?(.*)$')
        if mob and mob ~= '' then
            out = { mob = mob, label = label, cur = tonumber(a), target = tonumber(b), conditions = {} }
            for lab, txt in (rest or ''):gmatch('(%u%a+):%s*([^%.]-)%.') do
                txt = trim(txt)
                if lab == 'Area' then out.zone = txt
                elseif txt ~= '' then out.conditions[#out.conditions + 1] = lab .. ': ' .. txt end
            end
        end
    end
    if not out then return nil end
    for _, ln in ipairs(lines) do
        local n = ln:match('[Aa]bout [Tt]rial%s+(%d+)') or ln:match('^[Tt]rial%s+(%d+)')
        if n then out.number = tonumber(n) end
        local kindText = ln:match('^%s*Trial:%s*(.+)$')
        if kindText then out.kindText = trim(kindText):sub(1, 160) end
    end
    return out
end

local function open_capture(extend)
    local now = os.clock()
    local active = capture.until_t > 0 and now < capture.until_t
    if not active then
        capture.lines, capture.packets, capture.full = {}, {}, {}
        capture.hard_t = now + 15
    end
    if extend then capture.hard_t = math.max(capture.hard_t, now + 25) end   -- each menu choice keeps the conversation open
    capture.until_t = math.min(capture.hard_t, now + 6)
    capture.result  = 'Listening for NPC text...'
end

local function capture_line(raw)
    raw = trim(raw)
    if raw == '' then return end
    capture.full = capture.full or {}
    if #capture.full < 120 and capture.full[#capture.full] ~= raw then capture.full[#capture.full + 1] = raw:sub(1, 400) end   -- the conversation, verbatim and in order
    for _, l in ipairs(capture.lines) do if l == raw then return end end
    table.insert(capture.lines, raw)
    capture.until_t = math.min(capture.hard_t, os.clock() + 5)
end

local function parse_lines(lines)
    local info = {}
    local joined = table.concat(lines, ' ')
    local low = joined:lower()

    -- gate: only treat this as a trial conversation if it mentions trial-ish words (or you set a custom pattern)
    local mgText = parse_moogle_text(lines)
    if mgText then   -- the Moogle's own wording is exact: use it and skip the guessing below
        info.gated, info.type, info.moogle = true, 'Magian', mgText
        info.number = mgText.number
        info.cur, info.target = mgText.cur, mgText.target
        info.objective = ('%s - %d %s'):format(mgText.mob, mgText.target, mgText.label:lower())
        return info
    end
    local gated = (cfg.patterns.name ~= '' or cfg.patterns.progress ~= '')
    for _, k in ipairs(GATE) do if low:find(k, 1, true) then gated = true end end
    if not gated then return info end
    info.gated = true

    for _, v in ipairs({ 'Relic', 'Mythic', 'Empyrean', 'Aeonic', 'Magian' }) do
        if low:find(v:lower(), 1, true) then info.type = v break end
    end
    if not info.type and (low:find('armor', 1, true) or low:find('armour', 1, true)) then info.type = 'Armor' end

    if info.type == 'Armor' then
        for abbr, full in pairs(JOBS) do
            if joined:find('%f[%a]' .. abbr .. '%f[%A]') or low:find(full, 1, true) then info.job = abbr break end
        end
    end

    info.number = tonumber(low:match('trial%s*#%s*(%d+)') or low:match('trial%s+number%s*:?%s*#?(%d+)') or low:match('magian%s+trial%s+(%d+)'))

    for _, ln in ipairs(lines) do
        local l = ln:lower()
        if not info.name then
            local n = smatch(ln, cfg.patterns.name)
            if not n then
                for _, p in ipairs(NAME_PATS) do n = smatch(ln, p) if n and n ~= '' then break end end
            end
            if n and trim(n) ~= '' then info.name = trim(n):sub(1, 60) end
            -- "Trial #1234" is a number, not a name
            if info.name and info.name:match('^#?%s*%d+$') then
                info.number = info.number or tonumber(info.name:match('%d+'))
                info.name = nil
            end
        end
        if not info.objective then
            for _, v in ipairs(OBJ_VERBS) do
                if l:find(v, 1, true) then info.objective = ln:sub(1, 120) break end
            end
        end
        local label = ln:match('^(.-)%s*[:%-]%s*%d+%s*/%s*%d+%s*$')
        local is_req_line = false
        if label and label ~= '' then
            local ll = label:lower()
            is_req_line = not (ll:find('trial', 1, true) or ll:find('progress', 1, true) or ll:find('stage', 1, true)
                               or ll:find('total', 1, true) or ll:find('overall', 1, true))
        end
        if not info.cur and not is_req_line then
            local a, b = smatch(ln, cfg.patterns.progress)
            if not tonumber(a) then a, b = ln:match('(%d+)%s*/%s*(%d+)') end
            if not tonumber(a) then a, b = l:match('(%d+)%s+of%s+(%d+)') end
            if tonumber(a) and tonumber(b) then info.cur, info.target = tonumber(a), tonumber(b) end
        end
        if not info.remaining then
            local r = l:match('(%d+)%s+more') or l:match('(%d+)%s+remain') or l:match('(%d+)%s+left')
            if r then info.remaining = tonumber(r) end
            local nm = l:match('%d+%s+more%s+([%a][%a%s%-\']*)')
            if nm then info.remaining_name = nm end
        end
        if not info.goal then
            for _, v in ipairs({ 'defeat', 'slay', 'kill', 'obtain', 'collect', 'gather' }) do
                local g = l:match(v .. '%s+(%d+)')
                if g then info.goal = tonumber(g) break end
            end
        end
    end
    return info
end

local function stem(w)
    w = trim((w or ''):lower())
    for _, cut in ipairs({ ' in ', ' at ', ' from ', ' near ', ' using ', ' with ', ' to ', ' for ' }) do
        local i = w:find(cut, 1, true)
        if i then w = w:sub(1, i - 1) end
    end
    w = trim(w):gsub('^the ', ''):gsub('^a ', ''):gsub('^an ', '')
    if w:sub(-3) == 'ies' then w = w:sub(1, -4) .. 'y'
    elseif w:sub(-1) == 's' and w:sub(-2) ~= 'ss' then w = w:sub(1, -2) end
    return trim(w)
end

-- "Defeat 100 Goblin Smithies" -> kill / "goblin smithy";  "Obtain 30 Mandragora Roots" -> item / "mandragora root"
local function derive_watch(obj)
    local l = (obj or ''):lower()
    for _, v in ipairs({ 'defeat', 'slay', 'kill' }) do
        local _, what = l:match(v .. '%s+(%d+)%s+([%a%s%-\']+)')
        if what and stem(what) ~= '' then return 'kill', stem(what) end
    end
    for _, v in ipairs({ 'obtain', 'collect', 'gather' }) do
        local _, what = l:match(v .. '%s+(%d+)%s+([%a%s%-\']+)')
        if what and stem(what) ~= '' then return 'item', stem(what) end
    end
end

local function auto_watch(t)
    if t.mode ~= 'none' or (t.watch or '') ~= '' then return end   -- never overwrite a rule you set yourself
    local mode, what = derive_watch(t.objective)
    if mode then t.mode, t.watch = mode, what end
end

--------------------------------------------------------------------------------
-- Exact requirements: kills, items to collect, items to turn in
--------------------------------------------------------------------------------
local REQ_VERBS = {
    { 'defeat', 'kill' }, { 'slay', 'kill' }, { 'kill', 'kill' }, { 'hunt', 'kill' },
    { 'turn in', 'turnin' }, { 'hand in', 'turnin' }, { 'bring', 'turnin' }, { 'deliver', 'turnin' }, { 'trade', 'turnin' },
    { 'obtain', 'item' }, { 'collect', 'item' }, { 'gather', 'item' }, { 'acquire', 'item' },
}

local function cut_name(w)
    w = trim((w or ''):lower())
    for _, cut in ipairs({ ' in ', ' at ', ' from ', ' near ', ' using ', ' with ', ' to ', ' for ', ' by ', ' on ', ' that ', ' which ' }) do
        local i = w:find(cut, 1, true)
        if i then w = w:sub(1, i - 1) end
    end
    return trim(w:gsub('[%.!%?:;]+$', ''))
end

local function titlecase(s)
    return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

local function parse_amount(rest)
    local n, what = rest:match('^(%d+)x?%s+(.+)')
    if not n then
        local w2, n2 = rest:match('^(.-)%s*x(%d+)%s*[%.!]*$')
        if w2 and w2 ~= '' then what, n = w2, n2 end
    end
    if not n then
        what = rest:match('^the%s+(.+)') or rest:match('^an?%s+(.+)')
        if what then n = 1 end
    end
    return n, what
end

-- Name of the zone you are standing in (used to learn where a trial mob lives).
local function current_zone()
    local ok, name = pcall(function()
        local id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
        return AshitaCore:GetResourceManager():GetString('zones.names', id)
    end)
    if ok and type(name) == 'string' and name ~= '' then return name end
end

local function make_req(kind, n, what)
    local name = cut_name(what)
    name = name:gsub('^the ', '')
    local zone
    if kind == 'kill' then          -- "goblin smithy in valkurm dunes" / "... at ..." / "... within ..."
        zone = (what or ''):match('%f[%a]in%s+(.+)$') or (what or ''):match('%f[%a]at%s+(.+)$') or (what or ''):match('%f[%a]within%s+(.+)$')
        if zone then zone = titlecase(trim((zone:gsub('^the%s+', ''):gsub('[%.!%?]+$', '')))) end
        if zone == '' then zone = nil end
    end
    if name ~= '' and #name < 50 then
        return { kind = kind, name = titlecase(name), key = stem(name), need = math.max(1, tonumber(n)), have = 0, bag = 0,
                 zone = zone, zoneSrc = zone and 'npc' or nil }
    end
end

-- Returns the requirement found in one clause plus the verb kind it used.
-- A clause with no verb ("2 Mythril Ores" in "turn in 3 Iron Ingots, 2 Mythril Ores") reuses the previous verb.
local function parse_clause(c, inherit)
    local l = c:lower()
    for _, v in ipairs(REQ_VERBS) do
        local i, j = l:find('%f[%a]' .. v[1] .. '%f[%A]')
        if i then
            local rest = trim(l:sub(j + 1)):gsub('^me%s+', ''):gsub('^us%s+', '')
            local n, what = parse_amount(rest)
            if n and what then return make_req(v[2], n, what), v[2] end
            return nil, v[2]
        end
    end
    if inherit then
        local n, what = trim(l):match('^(%d+)x?%s+(.+)')
        if n and what then return make_req(inherit, n, what), inherit end
    end
end

local function parse_requirements(lines)
    local mgText = parse_moogle_text(lines)
    if mgText then
        local lab = mgText.label:lower()
        return { { kind = (lab == 'kills' and 'kill') or (lab:find('item', 1, true) and 'item') or 'other',
                   name = mgText.mob, key = stem(mgText.mob:lower()), need = math.max(1, mgText.target), have = mgText.cur, bag = 0,
                   zone = mgText.zone, zoneSrc = mgText.zone and 'npc' or nil, conditions = mgText.conditions,
                   explicit = true, fromMoogle = true } }
    end
    local reqs = {}
    local function find(key) for _, r in ipairs(reqs) do if r.key == key then return r end end end

    for _, ln in ipairs(lines) do
        local line = ln:gsub('(%d),(%d%d%d)', '%1%2')
        -- split one sentence into clauses: "Defeat 100 Orcs and obtain 30 Roots; turn in 5 Gems"
        line = line:gsub('%f[%a][Aa][Nn][Dd]%f[%A]', ';'):gsub(',', ';')
        local last
        for clause in line:gmatch('[^;]+') do
            local r, kind = parse_clause(clause, last)
            if kind then last = kind end
            if r and not find(r.key) then table.insert(reqs, r) end
        end
    end

    -- per-requirement status lines such as "Goblin Smithy: 12/50"
    for _, ln in ipairs(lines) do
        local name, a, b = ln:match('^(.-)%s*[:%-]%s*(%d+)%s*/%s*(%d+)%s*$')
        if name and name ~= '' then
            local low = name:lower()
            if not low:find('trial', 1, true) and not low:find('progress', 1, true) and not low:find('stage', 1, true) then
                local key = stem(cut_name(name))
                local r = find(key)
                if r then
                    r.have, r.need, r.explicit = tonumber(a), math.max(1, tonumber(b)), true
                else
                    table.insert(reqs, { kind = 'other', name = titlecase(cut_name(name)), key = key,
                                         need = math.max(1, tonumber(b)), have = tonumber(a), bag = 0, explicit = true })
                end
            end
        end
    end
    -- Where to find the mobs: the NPC says it in its own words ("...can be found in Garlaige Citadel.")
    local PLACE = { 'found', 'located', 'lurk', 'lurks', 'lurking', 'roam', 'roams', 'roaming', 'dwell', 'dwells', 'dwelling',
                    'inhabit', 'inhabits', 'reside', 'resides', 'hide', 'hides', 'hiding', 'spawn', 'spawns', 'appear', 'appears',
                    'wander', 'wanders', 'prowl', 'prowls', 'live', 'lives', 'seen', 'sighted', 'rumored' }
    local PREP = { 'in', 'at', 'near', 'around', 'within', 'throughout', 'inside', 'on', 'across', 'by' }
    local function place_in(sentence)
        local l = sentence:lower()
        for _, w in ipairs(PLACE) do
            local _, e = l:find('%f[%a]' .. w .. '%f[%A]')
            if e then
                local rest = sentence:sub(e + 1)
                local rl = rest:lower()
                for _, pr in ipairs(PREP) do
                    local _, pe = rl:find('^[%a%s]-%f[%a]' .. pr .. '%s+')
                    if pe and pe < 24 then
                        local z = rest:sub(pe + 1)
                        z = z:gsub('^[Tt]he%s+', '')
                        for _, cutw in ipairs({ ' and ', ' where ', ' to ', ' for ', ' but ', ' so ', ' if ', ' when ', ' which ', ' that ', '[%.!%?;,:]' }) do
                            local plain = cutw:sub(1, 1) ~= '['
                            local i = z:lower():find(cutw, 1, plain)
                            if i then z = z:sub(1, i - 1) end
                        end
                        z = trim(z)
                        if z ~= '' and #z < 40 and z:match('^[%u%d]') then return z end
                    end
                end
            end
        end
    end
    local kills = {}
    for _, r in ipairs(reqs) do if r.kind == 'kill' and not r.zone then kills[#kills + 1] = r end end
    if #kills > 0 then
        for _, ln in ipairs(lines) do
            for sentence in (ln .. ' '):gmatch('(.-[%.!%?])%s') do
                local z = place_in(sentence)
                if z then
                    local sl, named = sentence:lower(), nil
                    for _, r in ipairs(kills) do
                        if not r.zone and (sl:find(r.key, 1, true) or sl:find(r.name:lower(), 1, true)) then
                            r.zone, r.zoneSrc, named = z, 'npc', true
                        end
                    end
                    if not named and #kills == 1 and not kills[1].zone then kills[1].zone, kills[1].zoneSrc = z, 'npc' end
                end
            end
            -- a line without a final stop
            if not ln:find('[%.!%?]%s*$') then
                local z = place_in(ln)
                if z and #kills == 1 and not kills[1].zone then kills[1].zone, kills[1].zoneSrc = z, 'npc' end
            end
        end
    end
    return reqs
end

local function set_progress(t, cur, tgt)
    local was = t.done
    t.target  = math.max(1, math.floor(tgt or t.target))
    t.current = math.max(0, math.floor(cur))
    t.done    = t.current >= t.target
    if t.done and not was then
        say(('STAGE COMPLETE! [%s] %s (%d/%d)'):format(tag(t), t.name, t.current, t.target))
        start_celebration(t.name)
        ui.open[1] = true
        ui.selectId = t.id
    end
    settings.save()
end

-- Overall progress of a trial that has requirements = all requirements added together.
local function recompute(t)
    if t.reqmode ~= 'derived' or #(t.reqs or {}) == 0 then return end
    local cur, tgt = 0, 0
    for _, r in ipairs(t.reqs) do
        cur = cur + math.min(r.have, r.need)
        tgt = tgt + r.need
    end
    if cur ~= t.current or tgt ~= t.target then set_progress(t, cur, tgt) end
end

local function apply_reqs(t, info)
    local old = t.reqs or {}
    for _, r in ipairs(info.reqs) do
        for _, o in ipairs(old) do
            if o.key == r.key then
                if not r.explicit then r.have = o.have end
                r.bag = o.bag or 0
                r.npcset = o.npcset
                if not r.zone and o.zone then r.zone, r.zoneSrc = o.zone, o.zoneSrc end
            end
        end
    end
    t.reqs = info.reqs
    -- one requirement whose goal equals the NPC's overall goal: the NPC's progress is that requirement's progress
    if info.cur and #t.reqs == 1 and info.target == t.reqs[1].need then
        t.reqs[1].have = info.cur
        t.reqmode = 'derived'
    elseif info.cur and not info.reqs_explicit then
        t.reqmode = 'explicit'
    else
        t.reqmode = 'derived'
    end
    for _, r in ipairs(t.reqs) do if r.explicit then t.reqmode = 'derived' end end
    if info.lines then
        t.npc = {}
        for i, l in ipairs(info.lines) do if i <= 60 then t.npc[i] = l:sub(1, 400) end end
    end
end

-- Count kills / item drops from chat against each trial's own requirements.
local function count_reqs(msg)
    for _, t in ipairs(cfg.trials) do
        if not t.done and t.reqs and t.serverTracked then
            for _, r in ipairs(t.reqs) do   -- progress is the server's; a kill only teaches us where the mob lives
                if r.kind == 'kill' and (msg:find('defeats the ' .. r.key, 1, true) or msg:find('you defeat the ' .. r.key, 1, true)) then
                    local z = current_zone()
                    if z and r.zoneSrc ~= 'npc' and r.zone ~= z then r.zone, r.zoneSrc = z, 'seen' settings.save() end
                end
            end
        end
        if not t.done and t.reqs and not t.serverTracked then
            for _, r in ipairs(t.reqs) do
                local w, hit = r.key, false
                if r.kind == 'kill' then
                    hit = msg:find('defeats the ' .. w, 1, true) or msg:find('you defeat the ' .. w, 1, true)
                    if hit then
                        local z = current_zone()
                        if z and r.zoneSrc ~= 'npc' then r.zone, r.zoneSrc = z, 'seen' end
                    end
                elseif r.kind == 'item' then
                    hit = msg:find('obtained: ' .. w, 1, true) or msg:find('you find a ' .. w, 1, true)
                       or msg:find('you find an ' .. w, 1, true) or msg:find('obtains a ' .. w, 1, true)
                end
                if hit then
                    r.have = r.have + 1
                    if t.reqmode == 'derived' then
                        recompute(t)
                    elseif t.mode == 'none' then
                        set_progress(t, t.current + 1, t.target)
                    end
                    settings.save()
                end
            end
        end
    end
end

-- Items in your bag, so "turn in" requirements show how many you are holding.
local function read_bag()
    local counts = {}
    local ok = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        local res = AshitaCore:GetResourceManager()
        for i = 0, inv:GetContainerCountMax(0) do
            local it = inv:GetContainerItem(0, i)
            if it ~= nil and it.Id ~= 0 and it.Id ~= 65535 then
                local r = res:GetItemById(it.Id)
                if r ~= nil and r.Name[1] then
                    local key = stem(tostring(r.Name[1]))
                    counts[key] = (counts[key] or 0) + (it.Count or 1)
                end
            end
        end
    end)
    if ok then return counts end
end

local bag_dirty = true   -- set by inventory packets / NPC activity; the bag is never polled on a timer
local function refresh_bag()
    if not bag_dirty then return end
    bag_dirty = false
    local want = false
    for _, t in ipairs(cfg.trials) do
        if not t.done then
            for _, r in ipairs(t.reqs or {}) do
                if r.kind == 'item' or r.kind == 'turnin' then want = true end
            end
        end
    end
    if not want then return end
    local counts = read_bag()
    if not counts then return end
    for _, t in ipairs(cfg.trials) do
        if not t.done then
            for _, r in ipairs(t.reqs or {}) do
                if r.kind == 'item' or r.kind == 'turnin' then
                    r.bag = counts[r.key] or 0
                    if r.kind == 'turnin' and not r.npcset then r.have = r.bag end
                end
            end
            recompute(t)
        end
    end
end

local function same(a, b) return (a or ''):lower() == (b or ''):lower() end

local function db_key(n) return tostring(math.floor(n)) end

local function copy_reqs(list)
    local out = {}
    for _, r in ipairs(list or {}) do
        table.insert(out, { kind = r.kind, name = r.name, key = r.key, need = r.need, have = 0, bag = 0 })
    end
    return out
end

-- Remember what a trial number requires, so the next time it is set up instantly.
local function learn_trial(t)
    if not t.number or #(t.reqs or {}) == 0 then return end
    cfg.trialdb[db_key(t.number)] = {
        name = t.name, type = t.type, job = t.job or '', objective = t.objective or '', reqs = copy_reqs(t.reqs),
    }
end

local function seed_from_db(t)
    local e = t.number and cfg.trialdb[db_key(t.number)]
    if e and #(t.reqs or {}) == 0 then
        t.reqs = copy_reqs(e.reqs)
        t.reqmode = 'derived'
        if (t.objective or '') == '' then t.objective = e.objective or '' end
        if t.type == 'Other' and e.type then t.type = e.type end
        if (t.job or '') == '' then t.job = e.job or '' end
        recompute(t)
    end
end

-- A trial number was seen: create/select that trial and fill in its requirements from the database.
local function activate_number(n)
    local found
    for _, t in ipairs(cfg.trials) do if t.number == n then found = t break end end
    if not found then
        local e = cfg.trialdb[db_key(n)]
        found = add_trial(e and e.type or 'Magian', e and e.name or ('Trial #' .. n), 1, e and e.objective or '', e and e.job or '')
        found.number = n
    end
    seed_from_db(found)
    cfg.active = found.id
    ui.selectId = found.id
    ui.open[1] = true
    settings.save()
    return found
end

local function match_trial(info)
    local found
    if info.number then
        for _, t in ipairs(cfg.trials) do if t.number == info.number then found = t break end end
    end
    if not found and info.name then
        for _, t in ipairs(cfg.trials) do if same(t.name, info.name) then found = t break end end
    end
    if not found and not info.name and not info.number then
        local n, hit = 0, nil
        for _, t in ipairs(cfg.trials) do
            if (not info.type or t.type == info.type) and (not info.job or same(t.job, info.job)) then n = n + 1 hit = t end
        end
        if n == 1 then found = hit end
    end
    return found
end

-- The conversation is recorded per trial. A repeat of the same conversation is only noted, never re-applied.
local function convo_sig(lines)
    local parts = {}
    for _, l in ipairs(lines) do parts[#parts + 1] = l:lower():gsub('%s+', ' ') end
    return table.concat(parts, '|')
end

local function append_npc_file(t, lines)
    pcall(function()
        local f = io.open(addon.path .. 'npc_log.txt', 'a')
        if not f then return end
        f:write(('=== %s  [%s] %s%s ===\n'):format(os.date('%Y-%m-%d %H:%M:%S'), t.type or '?', t.name or '?', t.number and (' #' .. t.number) or ''))
        for _, l in ipairs(lines) do f:write(l, '\n') end
        f:write('\n')
        f:close()
    end)
end

local function record_convo(t, lines)
    t.convo = type(t.convo) == 'table' and t.convo or {}
    local sig = convo_sig(lines)
    local last = t.convo[#t.convo]
    if last and last.sig == sig then
        last.seen, last.checked = (last.seen or 1) + 1, os.date('%Y-%m-%d %H:%M:%S')
        return false
    end
    local copy = {}
    for i, l in ipairs(lines) do copy[i] = l end
    t.convo[#t.convo + 1] = { time = os.date('%Y-%m-%d %H:%M:%S'), sig = sig, seen = 1, lines = copy }
    while #t.convo > 6 do table.remove(t.convo, 1) end
    t.npc = {}
    for i, l in ipairs(lines) do if i <= 60 then t.npc[i] = l end end
    append_npc_file(t, lines)
    return true
end

local function upsert(info)
    local found = match_trial(info)

    local target = info.target or info.goal or (found and found.target)
    local cur = info.cur

    if not found then
        local e = info.number and cfg.trialdb[db_key(info.number)]
        local name = info.name or (e and e.name) or (info.number and ('Trial #' .. info.number)) or ((info.type or 'Trial') .. ' trial')
        found = add_trial(info.type or (e and e.type) or (info.number and 'Magian') or 'Other', name, target or cur or 1, info.objective, info.job)
    else
        if info.objective and info.objective ~= '' then found.objective = info.objective end
        if info.job and (found.job or '') == '' then found.job = info.job end
        if target and target >= 1 then found.target = math.floor(target) end
    end
    if info.number then found.number = info.number end
    found.via = info.via or ''

    if info.reqs and #info.reqs > 0 then apply_reqs(found, info) else seed_from_db(found) end

    -- "12 more Goblin Smithies" / "5 remaining": set what is LEFT on the matching requirement
    local applied = false
    if info.remaining and #(found.reqs or {}) > 0 then
        local hit
        if info.remaining_name then
            local key = stem(cut_name(info.remaining_name))
            for _, r in ipairs(found.reqs) do if r.key == key then hit = r end end
        end
        if not hit then
            local open = {}
            for _, r in ipairs(found.reqs) do if r.have < r.need then table.insert(open, r) end end
            if #found.reqs == 1 then hit = found.reqs[1] elseif #open == 1 then hit = open[1] end
        end
        if hit then
            hit.have = math.max(0, hit.need - info.remaining)
            hit.npcset = true
            found.reqmode = 'derived'
            applied = true
        end
    end
    if not cur and info.remaining and not applied and target then cur = math.max(0, target - info.remaining) end

    local derived = (found.reqmode == 'derived' and #(found.reqs or {}) > 0)
    if derived then recompute(found) end
    if cur and not derived then
        local was = found.done
        found.current = math.max(0, math.floor(cur))
        found.done = found.current >= found.target
        if found.done and not was then
            say(('STAGE COMPLETE! [%s] %s (%d/%d)'):format(tag(found), found.name, found.current, found.target))
            start_celebration(found.name)
        end
    end
    found.synced = os.date('%H:%M:%S')
    if #(found.reqs or {}) == 0 then auto_watch(found) end
    learn_trial(found)
    cfg.active = found.id
    ui.selectId = found.id
    ui.open[1] = true
    settings.save()
    return found
end

--------------------------------------------------------------------------------
-- Packet decoder: learns where the trial number / progress sit in NPC packets,
-- then reads them straight from the packets to find the trial you are on.
--------------------------------------------------------------------------------
local ffi = require('ffi')
local NOISY_IN = { [0x00D] = true, [0x00E] = true, [0x028] = true, [0x037] = true, [0x063] = true, [0x0DF] = true }
local FIELDS = { 'number', 'cur', 'target', 'remaining' }

local function pkt_data(e)
    local d = e.data_modified or e.data
    if type(d) == 'string' and #d > 0 then return d end
    local ok, s = pcall(ffi.string, e.data_raw, e.size)
    if ok then return s end
end

local function store_packet(dir, e)
    if NOISY_IN[e.id] or #capture.packets >= 24 then return end
    local d = pkt_data(e)
    if d then table.insert(capture.packets, { dir = dir, id = e.id, data = d:sub(1, 192) }) end
end

local function read_val(data, off, w)
    if off < 0 or off + w > #data then return nil end
    local v = 0
    for i = w - 1, 0, -1 do v = v * 256 + data:byte(off + i + 1) end
    return v
end

local function map_key(p, off, w) return ('%s:%d:%d:%d'):format(p.dir, p.id, off, w) end
local function reliable(e) return e.hits >= 2 and e.miss * 2 <= e.hits end

-- Learn from one conversation whose true values are known (from the NPC's text or from you).
local function calibrate(packets, known)
    local present = {}
    for _, p in ipairs(packets) do present[p.dir .. ':' .. p.id] = true end
    for _, field in ipairs(FIELDS) do
        local val = known[field]
        if val and val >= 1 then
            local m, seen = cfg.pktmap[field], {}
            for _, p in ipairs(packets) do
                for _, w in ipairs({ 4, 2 }) do
                    if val < 256 ^ w then
                        for off = 0, #p.data - w, w do
                            if read_val(p.data, off, w) == val then
                                local k = map_key(p, off, w)
                                if not seen[k] then
                                    seen[k] = true
                                    local e = m[k] or { dir = p.dir, id = p.id, off = off, w = w, hits = 0, miss = 0 }
                                    e.hits = e.hits + 1
                                    m[k] = e
                                end
                            end
                        end
                    end
                end
            end
            -- places that held the value before, but did not this time
            for k, e in pairs(m) do
                if not seen[k] and present[e.dir .. ':' .. e.id] then
                    e.miss = e.miss + 1
                    if e.miss >= 3 and e.miss > e.hits then m[k] = nil end
                end
            end
        end
    end
end

-- Read a field from the current conversation's packets using the best learned location.
local function decode_field(field, packets)
    local best, bestv
    for _, e in pairs(cfg.pktmap[field]) do
        if reliable(e) then
            for i = #packets, 1, -1 do
                local p = packets[i]
                if p.dir == e.dir and p.id == e.id then
                    local v = read_val(p.data, e.off, e.w)
                    if v and v >= 1 and (not best or e.hits > best.hits) then best, bestv = e, v end
                    break
                end
            end
        end
    end
    return bestv, best
end

-- Before anything is learned: if exactly one already-known trial number appears in the packets, that is the trial.
local function match_db_number(packets)
    local found, count = nil, 0
    for _, p in ipairs(packets) do
        for _, w in ipairs({ 4, 2 }) do
            for off = 0, #p.data - w, w do
                local v = read_val(p.data, off, w)
                if v and v >= 10 and cfg.trialdb[tostring(v)] and v ~= found then
                    found = v
                    count = count + 1
                end
            end
        end
    end
    if count == 1 then return found end
end

local function map_summary()
    local out = {}
    for _, field in ipairs(FIELDS) do
        local best
        for _, e in pairs(cfg.pktmap[field]) do
            if reliable(e) and (not best or e.hits > best.hits) then best = e end
        end
        if best then
            out[#out + 1] = ('%s: %s 0x%03X +%d (u%d), %d matches'):format(field, best.dir, best.id, best.off, best.w * 8, best.hits)
        end
    end
    return out
end

local function finalize_capture()
    capture.until_t = 0
    capture.last = capture.lines
    capture.time = os.date('%H:%M:%S')
    if #capture.lines == 0 then
        capture.result = 'No NPC text was captured.'
        return
    end
    local info = parse_lines(capture.lines)
    if next(info) ~= nil then
        info.reqs = parse_requirements(capture.lines)
        info.lines = capture.lines
    end
    capture.lastpackets = capture.packets
    local pk = capture.packets

    -- 1) the NPC's words tell us the true values: learn where they sit in the packets
    if #pk > 0 and info.gated then
        calibrate(pk, { number = info.number, cur = info.cur, target = info.target, remaining = info.remaining })
    end
    -- 2) values the text did not give can be read straight from the packets
    if #pk > 0 then
        if not info.number then
            local v, e = decode_field('number', pk)
            if v and (info.gated or cfg.trialdb[tostring(v)]) then
                info.number, info.via = v, ('packet 0x%03X'):format(e.id)
            else
                local m = match_db_number(pk)
                if m then info.number, info.via = m, 'known trial number in packet' end
            end
        end
        if info.number and not info.cur and not info.remaining then
            local c, ce = decode_field('cur', pk)
            local t = decode_field('target', pk)
            if c then info.cur, info.target, info.via = c, t or info.target, info.via or ('packet 0x%03X'):format(ce.id) end
            if not c then
                local r, re = decode_field('remaining', pk)
                if r then info.remaining, info.via = r, info.via or ('packet 0x%03X'):format(re.id) end
            end
        end
    end
    if not info.name and not info.number and not info.cur and not info.remaining and not (info.reqs and #info.reqs > 0) then
        capture.result = 'Heard the NPC but found no trial name or progress. See "Last NPC text" and use /rt pattern.'
        return
    end
    local full = (capture.full and #capture.full > 0) and capture.full or capture.lines

    -- Same conversation as the one already recorded for this trial: everything is already on the display, so keep it as is.
    local known = match_trial(info)
    local lastc = known and type(known.convo) == 'table' and known.convo[#known.convo]
    if known and lastc and lastc.sig == convo_sig(full) then
        record_convo(known, full)
        known.synced = os.date('%H:%M:%S')
        cfg.active, ui.selectId = known.id, known.id
        capture.result = ('No change: [%s] %s  %d/%d (conversation already recorded)'):format(tag(known), known.name, known.current, known.target)
        say(capture.result)
        settings.save()
        return
    end

    local t = upsert(info)
    local isnew = record_convo(t, full)
    capture.result = ('%s: [%s] %s  %d/%d'):format(isnew and 'Updated' or 'Synced', tag(t), t.name, t.current, t.target)
    say(capture.result)
    settings.save()
end

ashita.events.register('d3d_present', 'rt_capture_tick', safe('capture', function()
    if capture.until_t > 0 and os.clock() >= capture.until_t then finalize_capture() end
    refresh_bag()
end))

-- Talking to an NPC sends event packets; open a listening window when they arrive.
ashita.events.register('packet_in', 'rt_packet_in', safe('packet', function(e)
    if cfg.auto ~= false and (e.id == 0x32 or e.id == 0x34) then open_capture() end
    if cfg.auto ~= false and os.clock() < capture.until_t then store_packet('IN', e) end
end))

--------------------------------------------------------------------------------
-- Packet logger: records NPC-conversation packets + chat so trial data can be decoded
--------------------------------------------------------------------------------
local plog = {
    on = false, mode = 'talk', only = nil, path = nil, file = nil,
    count = 0, bytes = 0, until_t = 0, recent = {},
    -- Busy packets that drown out an NPC conversation. Editable with /rt plog ignore.
    ignore = {
        IN  = { [0x00D] = true, [0x00E] = true, [0x028] = true, [0x037] = true, [0x063] = true, [0x0DF] = true },
        OUT = { [0x015] = true },
        ALL = {},
    },
}
local PLOG_MAX_BYTES = 5 * 1024 * 1024
local TALK_SECS = 8

local function plog_dir()
    return ('%s/config/addons/%s/packets/'):format(AshitaCore:GetInstallPath(), addon.name)
end

local function plog_write(text)
    if not plog.file then return end
    plog.file:write(text)
    plog.file:flush()
    plog.bytes = plog.bytes + #text
end

local function plog_note_recent(line)
    table.insert(plog.recent, line)
    if #plog.recent > 8 then table.remove(plog.recent, 1) end
end

local function plog_stop(why)
    if not plog.on then return end
    plog.on = false
    if plog.file then plog.file:close() plog.file = nil end
    say(('Packet logger stopped (%s). %d packet%s saved to %s'):format(why or 'stopped', plog.count, plog.count == 1 and '' or 's', tostring(plog.path)))
end

local function plog_start(mode, only)
    if plog.on then plog_stop('restarted') end
    local ok, err = pcall(function()
        ashita.fs.create_dir(plog_dir())
        plog.path = plog_dir() .. os.date('packets_%Y%m%d_%H%M%S') .. '.log'
        plog.file = assert(io.open(plog.path, 'w'))
    end)
    if not ok or not plog.file then
        say('Could not create the log file: ' .. tostring(err))
        return
    end
    plog.on, plog.mode, plog.only = true, mode, only
    plog.count, plog.bytes, plog.until_t, plog.recent = 0, 0, 0, {}
    plog_write(('# rematracker packet log  %s  mode=%s\n'):format(os.date('%Y-%m-%d %H:%M:%S'), mode))
    plog_write('# Tip: use "/rt plog note <text>" to label what you just did, e.g. "talked to Magian Moogle, item has Trial 1234".\n')
    plog_write('# This log may contain your character name and map position. Skim it before sharing.\n\n')
    local what = mode == 'ids' and 'selected packet ids' or (mode == 'all' and 'all packets (noisy ones ignored)' or 'NPC conversations')
    say('Packet logger started: ' .. what .. '. Log file: ' .. plog.path)
end

local function hexdump(d, size)
    local out = {}
    size = math.min(size, #d, 1024)
    for off = 0, size - 1, 16 do
        local hex, asc = {}, {}
        for i = off, math.min(off + 15, size - 1) do
            local b = d:byte(i + 1)
            hex[#hex + 1] = ('%02X'):format(b)
            asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or '.'
        end
        out[#out + 1] = ('  %04X  %-47s  %s'):format(off, table.concat(hex, ' '), table.concat(asc))
    end
    return table.concat(out, '\n')
end

-- Non-zero 32-bit words (trial numbers and counts are often stored this way) and readable text runs.
local function analyse(d, size)
    size = math.min(size, #d, 1024)
    local words = {}
    for off = 0, size - 4, 4 do
        local b1, b2, b3, b4 = d:byte(off + 1, off + 4)
        local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        if v ~= 0 and #words < 24 then words[#words + 1] = ('+%02X=%d'):format(off, v) end
    end
    local texts = {}
    for run in d:sub(1, size):gmatch('[ -~]+') do
        if #run >= 4 and #texts < 8 then texts[#texts + 1] = '"' .. run .. '"' end
    end
    local out = {}
    if #words > 0 then out[#out + 1] = '  u32:  ' .. table.concat(words, ' ') end
    if #texts > 0 then out[#out + 1] = '  text: ' .. table.concat(texts, ' ') end
    return table.concat(out, '\n')
end

local function packet_bytes(e)
    local d = e.data_modified or e.data
    if type(d) == 'string' and #d > 0 then return d end
    local ok, s = pcall(ffi.string, e.data_raw, e.size)
    if ok then return s end
end

local function plog_wanted(dir, id)
    if plog.only then return plog.only[id] == true end
    if plog.ignore[dir][id] or plog.ignore.ALL[id] then return false end
    if plog.mode == 'all' then return true end
    -- talk mode: an NPC event (or your own action packet) opens a short recording window
    if (dir == 'IN' and (id == 0x032 or id == 0x034)) or (dir == 'OUT' and id == 0x01A) then
        plog.until_t = os.clock() + TALK_SECS
    end
    return os.clock() < plog.until_t
end

local function plog_packet(dir, e)
    if not plog.on or not plog_wanted(dir, e.id) then return end
    local d = packet_bytes(e)
    if not d then return end
    local size = e.size or #d
    plog.count = plog.count + 1
    plog_write(('[%s] %s 0x%03X size=%d\n%s\n%s\n\n'):format(os.date('%H:%M:%S'), dir, e.id, size, hexdump(d, size), analyse(d, size)))
    plog_note_recent(('%s %s 0x%03X (%d bytes)'):format(os.date('%H:%M:%S'), dir, e.id, size))
    if plog.bytes > PLOG_MAX_BYTES then plog_stop('size limit reached') end
end

local function plog_chat(raw)
    if not plog.on then return end
    if plog.mode == 'talk' and os.clock() >= plog.until_t then return end
    raw = trim(raw or '')
    if raw ~= '' then plog_write(('[%s] CHAT: %s\n'):format(os.date('%H:%M:%S'), raw)) end
end

ashita.events.register('packet_in', 'rt_plog_in', safe('plog', function(e) plog_packet('IN', e) end))
ashita.events.register('packet_out', 'rt_plog_out', safe('plog', function(e) plog_packet('OUT', e) end))

-- Rebuild packets from a log file written by the packet logger.
local function read_log_packets(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local packets, cur = {}, nil
    local function close() if cur then cur.data = string.char(unpack(cur.bytes)) cur.bytes = nil cur = nil end end
    for line in f:lines() do
        local dir, id = line:match('^%[[%d:]+%] (%u+) 0x(%x+) size=%d+')
        if dir then
            close()
            cur = { dir = dir, id = tonumber(id, 16), bytes = {} }
            table.insert(packets, cur)
        elseif cur and line:match('^  %x%x%x%x  ') then
            for b in line:sub(9, 55):gmatch('%x%x') do cur.bytes[#cur.bytes + 1] = tonumber(b, 16) end
        elseif line:match('^%[[%d:]+%] CHAT') or line:match('^%[[%d:]+%] NOTE') then
            close()
        end
    end
    close()
    f:close()
    return packets
end

local function latest_log_path()
    if plog.path then return plog.path end
    local ok, files = pcall(ashita.fs.get_dir, plog_dir(), '.*%.log', true)
    if ok and type(files) == 'table' and #files > 0 then
        table.sort(files)
        return plog_dir() .. files[#files]
    end
end

local function parse_ids(args, from)
    local set, n = {}, 0
    for i = from, #args do
        local id = tonumber((args[i]:gsub('^0[xX]', '')), 16)
        if id then set[id] = true n = n + 1 end
    end
    return set, n
end

--------------------------------------------------------------------------------
-- Magian tracker (read-only). Logic lives in magiancore.lua; this is the Ashita glue.
--
-- VERIFICATION STATUS (be honest about it): the packet layouts below follow the LandSandBoat
-- server source. They have NOT yet been validated against client packet captures from
-- VanaDreams. Messages 583/584 are message ids carried in packet 0x029, not packet ids.
-- Run "/rt magian" to see which signals have actually been seen live this session, and
-- use the packet logger to capture the rest. Item exdata (trial id + completion bit) is
-- documented by the server team and is decoded with ashita.bits.unpack_be.
--
-- Offsets are 0-based and include the 4-byte packet header:
--   IN  0x034 num[8] i32 @8..39, EventNum(zone) u16 @42     Moogle active-trial list
--   OUT 0x05B EndPara u32 @8, Mode u16 @14                   which trial/question you picked
--   IN  0x05C num[8] i32 @4..35                              Moogle reply (total, progress, items)
--   IN  0x029 Data u32 @12, Data2 u32 @16, MessageNum u16 @24
--
-- Event driven: inventory is read after login, zoning, inventory/equipment packets and Moogle
-- activity (debounced), never on a timer. Nothing here trades, talks to NPCs or finishes quests.
--------------------------------------------------------------------------------
local okCore, core = pcall(require, 'magiancore')
if not okCore then
    core = nil
    print(chat.header(addon.name):append(chat.error('magiancore.lua was not found next to rematracker.lua - Magian tracking is off.')))
end

local mg_scan_items
local MG = {
    zone = 243,                      -- Ru'Lude Gardens, where the Magian Moogles stand
    state = nil, pend = nil, scanDue = nil, seenSig = '', firstScan = true,
    stats = { moogle = 0, view = 0, reply = 0, message = 0, crate = 0, items = 0, mismatch = 0 },
    seen = { reward = false, moogleList = false, status = false, detail = false, msg583 = false, msg584 = false, itemTrial = false },
}

local function mg_reload()
    if core then
        MG.state = core.load(cfg.magianState, { rate = cfg.upgradeRate })
        cfg.magianState = MG.state
    end
end
mg_reload()

local function mg_char()
    local ok, name = pcall(function() return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0) end)
    if ok and name and name ~= '' then return name end
    return 'unknown character'
end

--------------------------------------------------------------------------------
-- Magian Moogle session recorder. Starts by itself when you talk to the Moogle (no clicking) and writes
-- ONE report per visit: every packet of the visit (hex + readable numbers/text), the NPC's chat text,
-- what the tracker decoded, the items it found, and the final state. Send that file to verify the layouts.
-- It only listens: it never talks to the Moogle or sends anything.
--------------------------------------------------------------------------------
local mrec = { on = false, file = nil, path = nil, last = 0, hard = 0, count = 0, lastReport = nil, sessions = 0, start = 0 }
local MREC_IDLE, MREC_HARD = 7, 240

local function mrec_write(text)
    if not mrec.on or not mrec.file then return end
    mrec.file:write(text)
    mrec.file:flush()
end

local function mrec_target()
    local ok, n = pcall(function()
        local tm = AshitaCore:GetMemoryManager():GetTarget()
        local idx = tm:GetTargetIndex(0)
        if idx and idx > 0 then return AshitaCore:GetMemoryManager():GetEntity():GetName(idx) end
    end)
    if ok and type(n) == 'string' and n ~= '' then return n end
end

local function mrec_zone()
    local ok, z = pcall(function() return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) end)
    return ok and z or nil
end

local function mrec_start(reason)
    if mrec.on or cfg.moogleLog == false then return end
    local ok = pcall(function()
        ashita.fs.create_dir(plog_dir())
        mrec.path = plog_dir() .. os.date('moogle_%Y%m%d_%H%M%S') .. '.log'
        mrec.file = assert(io.open(mrec.path, 'w'))
    end)
    if not ok or not mrec.file then return end
    mrec.on, mrec.count, mrec.start = true, 0, os.clock()
    mrec.last, mrec.hard = os.clock(), os.clock() + MREC_HARD
    mrec.sessions = mrec.sessions + 1
    mrec.write0 = true
    mrec_write(('# Magian Moogle session  %s\n# started by: %s\n# character: %s   zone id: %s   target: %s\n'):format(
        os.date('%Y-%m-%d %H:%M:%S'), reason or '?', mg_char(), tostring(mrec_zone()), tostring(mrec_target())))
    mrec_write('# Packet offsets are 0-based and include the 4-byte header. Lines marked "guess" are NOT verified layouts.\n')
    mrec_write('# This report contains your character name. Skim it before sharing.\n\n')
    -- what you were carrying when the visit began
    local seen = mg_scan_items and mg_scan_items() or nil
    if seen then
        for id, copies in pairs(seen) do
            for k, info in pairs(copies) do
                mrec_write(('ITEM trial=%d  slot=%s  item=%s (%s)  completedBit=%s  worn=%s\n'):format(id, k, tostring(info.name), tostring(info.itemId), tostring(info.completed), tostring(info.equipped)))
            end
        end
        mrec_write('\n')
    end
end

local function s32(v) if v and v >= 2147483648 then return v - 4294967296 end return v end

-- Plain-language reading of the packets we know candidates for. Everything here is a guess until verified.
local function mrec_annotate(dir, id, d)
    local out = {}
    local function nums(base, count, label)
        local t, p = {}, {}
        for i = 0, count - 1 do
            local v = read_val(d, base + 4 * i, 4)
            if v == nil then break end
            t[#t + 1] = ('%d'):format(s32(v))
            p[#p + 1] = ('%d/%d'):format(v % 65536, math.floor(v / 65536))
        end
        out[#out + 1] = ('  guess %s @%d: n = [%s]'):format(label, base, table.concat(t, ', '))
        out[#out + 1] = ('        as low/high u16 pairs: [%s]'):format(table.concat(p, ', '))
    end
    if dir == 'IN' and id == 0x034 then
        nums(8, 8, 'event params (num[0..7])')
        out[#out + 1] = ('  guess event number (zone) @42: %s'):format(tostring(read_val(d, 42, 2)))
    elseif dir == 'IN' and id == 0x05C then
        nums(4, 8, 'event update reply (num[0..7])')
    elseif dir == 'OUT' and id == 0x05B then
        local para, mode = read_val(d, 8, 4), read_val(d, 14, 2)
        if para then out[#out + 1] = ('  guess EndPara @8 = %d  (low byte %d, high 16 bits %d)   Mode @14 = %s'):format(para, para % 256, math.floor(para / 65536), tostring(mode)) end
    elseif dir == 'IN' and id == 0x029 then
        out[#out + 1] = ('  guess Data @12 = %s  Data2 @16 = %s  MessageNum @24 = %s'):format(tostring(read_val(d, 12, 4)), tostring(read_val(d, 16, 4)), tostring((read_val(d, 24, 2) or 0) % 32768))
    end
    return out
end

local function mrec_stop(why)
    if not mrec.on then return end
    mrec_write(('\n--- END (%s) after %.0f s, %d packets ---\n'):format(why or 'done', os.clock() - mrec.start, mrec.count))
    -- final state of every trial the tracker knows about, with where each value came from
    if core and MG.state then
        mrec_write('TRACKER STATE\n')
        mrec_write('  active list: ' .. table.concat(MG.state.active, ', ') .. '\n')
        for _, id in ipairs(MG.state.order) do
            local v = core.view(MG.state, id, os.time())
            if v then
                mrec_write(('  trial %d: total=%s [%s] progress=%s [%s] remaining=%s [%s] complete=%s copies=%s\n'):format(
                    id, tostring(v.total), tostring(v.totalLabel), tostring(v.progress), tostring(v.progressLabel),
                    tostring(v.remaining), tostring(v.remainingLabel), tostring(v.completed), tostring(v.weaponNames)))
            end
        end
    end
    mrec.on = false
    if mrec.file then mrec.file:close() mrec.file = nil end
    mrec.lastReport = mrec.path
    say(('Magian Moogle report saved (%d packets): %s'):format(mrec.count, tostring(mrec.path)))
end

local MREC_NOISY = { IN = { [0x00D] = true, [0x00E] = true, [0x028] = true, [0x037] = true, [0x063] = true, [0x0DF] = true, [0x0E0] = true, [0x067] = true },
                     OUT = { [0x015] = true, [0x0E8] = true } }
-- Packets that mean "you are in an NPC event". The Moogle's own list (0x034) is the surest sign.
local function mrec_packet(dir, e)
    if cfg.moogleLog == false then return end
    local id = e.id
    if not mrec.on then
        local zone = mrec_zone()
        if dir == 'IN' and (id == 0x034 or id == 0x032 or id == 0x033) and (zone == MG.zone or id == 0x034) then
            mrec_start(('IN 0x%03X'):format(id))
        elseif dir == 'OUT' and id == 0x01A and zone == MG.zone then
            local tn = mrec_target()
            if tn and tn:lower():find('moogle', 1, true) then mrec_start('you targeted ' .. tn) end
        end
        if not mrec.on then return end
    end
    if MREC_NOISY[dir][id] or plog.ignore.ALL[id] then return end
    local d = packet_bytes(e)
    if not d then return end
    mrec.count, mrec.last = mrec.count + 1, os.clock()
    local size = e.size or #d
    local lines = mrec_annotate(dir, id, d)
    mrec_write(('[%s +%.2fs] %s 0x%03X size=%d\n%s\n%s\n%s\n\n'):format(os.date('%H:%M:%S'), os.clock() - mrec.start, dir, id, size,
        hexdump(d, size), analyse(d, size), table.concat(lines, '\n')))
end

local function mrec_chat(raw)
    if not mrec.on then return end
    raw = trim(raw or '')
    if raw ~= '' and raw ~= mrec.lastChat then mrec.lastChat = raw mrec.last = os.clock() mrec_write(('[%s +%.2fs] CHAT: %s\n'):format(os.date('%H:%M:%S'), os.clock() - mrec.start, raw)) end
end

ashita.events.register('packet_in', 'rt_mrec_in', safe('mrec', function(e) mrec_packet('IN', e) end))
ashita.events.register('packet_out', 'rt_mrec_out', safe('mrec', function(e) mrec_packet('OUT', e) end))
ashita.events.register('d3d_present', 'rt_mrec_tick', safe('mrec', function()
    if not mrec.on then return end
    if os.clock() - mrec.last > MREC_IDLE then mrec_stop('quiet for ' .. MREC_IDLE .. ' s')
    elseif os.clock() > mrec.hard then mrec_stop('time limit') end
end))

local function plog_decoded(text)
    if plog.on then plog_write(('[%s] DECODE: %s\n\n'):format(os.date('%H:%M:%S'), text)) end
    mrec_write(('[%s] DECODE: %s\n\n'):format(os.date('%H:%M:%S'), text))
end

local function item_name_by_id(id)
    local ok, name = pcall(function()
        local r = AshitaCore:GetResourceManager():GetItemById(id)
        return r and r.Name[1] and tostring(r.Name[1]) or nil
    end)
    if ok and name and name ~= '' then return name end
end

local function mg_select(t, open)
    cfg.active = t.id
    ui.selectId = t.id
    if open then ui.open[1] = true end
end

-- Copy what the core knows about a trial into the window's trial entry. live = caused by a server event just now.
local function mg_sync(id, live)
    if not core then return end
    local v = core.view(MG.state, id, os.time())
    if not v then return end

    local t
    for _, x in ipairs(cfg.trials) do if x.number == id then t = x break end end
    if not t then
        t = add_trial('Magian', v.weaponName or v.objective or ('Trial #' .. id), 1, '', '')
        t.number = id
    end
    t.serverTracked, t.reqmode, t.via = true, 'explicit', 'server data'
    t.synced = os.date('%H:%M:%S')
    if v.weaponName then
        t.name = v.weaponName
    elseif v.objective and (t.name == '' or t.name:match('^Trial #%d+$')) then
        t.name = v.objective
    end
    if v.route then t.objective = v.objective .. ' (route data)' end

    local was = t.done
    t.done = (v.completed == true)
    t.progressUnknown, t.remainingOnly = (v.progress == nil), false
    if v.total then
        t.target = v.total
        t.current = t.done and v.total or math.min(v.progress or 0, v.total)
    elseif v.remaining ~= nil then
        t.target, t.current, t.remainingOnly = math.max(1, v.remaining), 0, true
    elseif t.done then
        t.target, t.current = 1, 1
    end

    -- the mob to kill (route data is an estimate; the zone is learned when you kill one)
    if v.route and v.route.objective then
        t.reqs = t.reqs or {}
        local r
        for _, x in ipairs(t.reqs) do if x.fromRoute or x.fromMoogle then r = x end end
        if not r and #t.reqs == 0 then
            r = { kind = 'kill', name = v.route.objective, key = stem(v.route.objective), need = 1, have = 0, bag = 0, fromRoute = true }
            t.reqs[1] = r
        end
        if r then
            r.need = math.max(1, v.total or r.need or 1)
            r.have, r.haveUnknown = v.progress or r.have or 0, (v.progress == nil and not r.fromMoogle)
            r.src = v.totalLabel
        end
    end

    -- turn-in trials: "deposited" comes from the server, "owned" from the bag; they are different things
    local r = t.reqs and t.reqs[1]
    if r and r.kind == 'turnin' then
        r.npcset = true
        r.have = v.progress or 0
        if v.total then r.need = v.total end
    end

    if live and t.done and not was and v.completedSrc == 'confirmed' then
        say(('STAGE COMPLETE! [Magian] %s (trial %d) - report to the Magian Moogle.'):format(t.name, id))
        start_celebration(t.name)
        mg_select(t, true)
    end
    return t
end

local function mg_request_scan() MG.scanDue = os.clock() + 0.75 end

-- IN 0x034: the Magian Moogle opened with the trial log (authoritative list of active trials)
local function mg_on_event_params(d)
    if #d < 52 then return end
    local zone, count = read_val(d, 42, 2), read_val(d, 36, 4)
    if zone ~= MG.zone or not count or count < 1 or count > 10 then return end
    if read_val(d, 28, 4) ~= 0 or read_val(d, 32, 4) ~= 0 then return end   -- params 6 and 7 must be zero

    local words = {}
    for i = 0, 4 do words[i + 1] = read_val(d, 8 + 4 * i, 4) end
    local ids, ok = core.unpackActive(words, count)
    if not ok then
        MG.stats.mismatch = MG.stats.mismatch + 1
        plog_decoded(('0x034 looked like the Moogle list, but %d trial ids were found and the packet says %d'):format(#ids, count))
        return
    end
    for _, id in ipairs(ids) do if id > 32767 then return end end

    MG.stats.moogle, MG.seen.moogleList = MG.stats.moogle + 1, true
    core.onMoogleList(MG.state, ids, os.time())
    local first
    for _, id in ipairs(ids) do first = first or mg_sync(id, true) mg_sync(id, true) end
    if #ids == 1 and first then mg_select(first, true) end
    plog_decoded(('Magian Moogle: %d active trial(s): %s'):format(#ids, table.concat(ids, ', ')))
    say(('Magian trial log: %d active (%s)'):format(#ids, table.concat(ids, ', ')))
    mg_request_scan()
    bag_dirty = true
    settings.save()
end

-- OUT 0x05B: you picked something on the Moogle / Delivery Crate menu
local function mg_on_event_update(d)
    if #d < 20 or read_val(d, 14, 2) ~= 1 then return end
    if cfg.auto ~= false then open_capture(true) end
    local para = read_val(d, 8, 4)
    local ut = para % 256
    local tid
    if ut >= 1 and ut <= 4 then tid = math.floor(para / 65536) end
    MG.pend = { type = ut, trial = tid, t = os.clock() }
    MG.stats.view = MG.stats.view + 1
    plog_decoded(tid and ('You asked the Moogle about trial %d (request type %d)'):format(tid, ut)
                      or ('You sent event update type %d'):format(ut))
end

-- IN 0x05C: the server's reply to that question
local function mg_remember_raw(trial, ptype, d)
    local nums = {}
    for i = 0, 7 do nums[#nums + 1] = tostring(read_val(d, 4 + 4 * i, 4)) end
    MG.raw = MG.raw or {}
    MG.raw[trial] = { type = ptype, nums = table.concat(nums, ', '), at = os.date('%H:%M:%S') }
end

local function mg_on_pending(d)
    local p = MG.pend
    if not p or os.clock() - p.t > 8 or #d < 36 then
        if #d >= 36 then plog_decoded('0x05C arrived without a matching request from you (not decoded)') end
        return
    end
    if p.trial then mg_remember_raw(p.trial, p.type, d) end
    if p.type ~= 1 and p.type ~= 2 and p.type ~= 3 and p.type ~= 5 then
        MG.unknownTypes = MG.unknownTypes or {}
        MG.unknownTypes[p.type] = (MG.unknownTypes[p.type] or 0) + 1
        plog_decoded(('Request type %d has no verified meaning; its reply was recorded raw only'):format(p.type))
    end
    local now = os.time()
    local function num(i) return read_val(d, 4 + 4 * i, 4) end

    if p.type == 2 and p.trial then
        local ok = core.onTrialStatus(MG.state, p.trial, num(0), num(2), num(5), num(6), now)
        if ok then
            MG.stats.reply, MG.seen.status = MG.stats.reply + 1, true
            local t = mg_sync(p.trial, true)
            if t then mg_select(t, true) end
            plog_decoded(('Trial %d: total %d, progress %d, detail %d, element %d'):format(p.trial, num(0), num(2), num(5), num(6)))
        else
            MG.stats.mismatch = MG.stats.mismatch + 1
            plog_decoded(('Trial %d status looked wrong (total %d, progress %d) and was ignored'):format(p.trial, num(0), num(2)))
        end
    elseif p.type == 3 and p.trial then
        -- reward: seen on VanaDreams for trial 3: num[3] = item id, num[1] = packed augment words (0x1019 = id 25, value 2 = Attack+3)
        local augs = {}
        for _, w in ipairs({ num(1), num(2) }) do
            for _, u in ipairs({ w % 65536, math.floor(w / 65536) }) do
                if u ~= 0 then augs[#augs + 1] = { u % 2048, math.floor(u / 2048) } end
            end
        end
        MG.reward = MG.reward or {}
        MG.reward[p.trial] = { item = num(3), augments = augs, at = os.date('%H:%M:%S') }
        MG.stats.reply, MG.seen.reward = MG.stats.reply + 1, true
        mg_sync(p.trial, true)
        plog_decoded(('Trial %d reward: item %d, %d augment(s)'):format(p.trial, num(3), #augs))
    elseif p.type == 1 and p.trial then
        local req, trade, text = num(3), num(5), num(6)
        MG.required = MG.required or {}
        MG.required[p.trial] = { item = req, trade = trade, text = text, at = os.date('%H:%M:%S') }
        core.onRequiredItem(MG.state, p.trial, req, trade, text, now)
        MG.stats.reply, MG.seen.detail = MG.stats.reply + 1, true
        local t = mg_sync(p.trial, true)
        if t and trade > 0 then
            local nm = item_name_by_id(trade) or ('Item #' .. trade)
            t.reqs = { { kind = 'turnin', name = nm, key = stem(nm), need = math.max(1, t.target or 1), have = 0, bag = 0, npcset = true } }
            t.objective = ('Trade %s to the Delivery Crate in Ru\'Lude Gardens.'):format(nm)
            bag_dirty = true
            mg_sync(p.trial, false)
        elseif t and text > 0 and (t.objective or '') == '' then
            t.objective = ('Objective text #%d: read it on the Magian Moogle.'):format(text)
        end
        plog_decoded(('Trial %d: item needed %d, trade item %d, text #%d'):format(p.trial, req, trade, text))
    elseif p.type == 5 then
        local words = {}
        for i = 0, 4 do words[i + 1] = num(i) end
        local ids, ok = core.unpackActive(words, num(7))
        if ok then
            core.onMoogleList(MG.state, ids, now)
            for _, id in ipairs(ids) do mg_sync(id, true) end
        end
    end
    settings.save()
end

-- IN 0x029: message 583 (remaining objectives) / 584 (objective complete)
local function mg_on_message(d)
    if #d < 27 then return end
    local msg = read_val(d, 24, 2) % 32768
    if msg ~= core.MSG_PROGRESS and msg ~= core.MSG_COMPLETE then return end
    local tid = read_val(d, 12, 4)
    if tid < 1 or tid > 32767 then return end
    local now = os.time()
    MG.stats.message = MG.stats.message + 1
    if msg == core.MSG_COMPLETE then
        MG.seen.msg584 = true
        local ok = core.onCompleteMessage(MG.state, tid, now)
        plog_decoded(('Trial %d complete%s'):format(tid, ok and '' or ' (duplicate ignored)'))
    else
        MG.seen.msg583 = true
        local remaining = read_val(d, 16, 4)
        local ok = core.onProgressMessage(MG.state, tid, remaining, now)
        plog_decoded(('Trial %d: %d remaining%s'):format(tid, remaining, ok and '' or ' (duplicate ignored)'))
    end
    mg_sync(tid, true)
    settings.save()
end

-- Read the trial id / completion bit off items you wear or carry (item.Extra, per the server team's decoder).
local function mg_extra_bytes(it)
    local ex = it.Extra
    if ex == nil then return nil end
    if type(ex) == 'string' then
        local ok, tbl = pcall(function() return ex:totable() end)
        if ok and type(tbl) == 'table' and #tbl > 0 then return tbl end
        local out = {}
        for i = 1, #ex do out[i] = ex:byte(i) end
        return out
    elseif type(ex) == 'table' then
        local out = {}
        for i = 1, 24 do if type(ex[i]) ~= 'number' then break end out[i] = ex[i] end
        return out
    end
    return nil
end

local function mg_unpack_be()
    if ashita and ashita.bits and type(ashita.bits.unpack_be) == 'function' then
        return function(b, o, l) return ashita.bits.unpack_be(b, o, l) end
    end
end

function mg_scan_items()
    local seen = {}
    local ok = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        local worn = {}
        for slot = 0, 15 do
            local eq = inv:GetEquippedItem(slot)
            if eq ~= nil and eq.Index ~= 0 then
                worn[math.floor(eq.Index / 256) .. ':' .. (eq.Index % 256)] = true
            end
        end
        for _, c in ipairs({ 0, 8, 10, 11, 12, 5, 6, 7, 1, 2, 4, 9 }) do   -- every bag; copies are told apart by container:slot
            local ok2, max = pcall(function() return inv:GetContainerCountMax(c) end)
            if ok2 and max then
                for i = 0, max do
                    local it = inv:GetContainerItem(c, i)
                    if it ~= nil and it.Id ~= 0 and it.Id ~= 65535 then
                        local bytes = mg_extra_bytes(it)
                        if bytes then
                            local okd, info = pcall(core.decodeExtra, bytes, mg_unpack_be())
                            if not okd then info = core.decodeExtra(bytes) end
                            if info and info.trialId then
                                local k = c .. ':' .. i
                                seen[info.trialId] = seen[info.trialId] or {}
                                seen[info.trialId][k] = {
                                    itemId = it.Id, name = item_name_by_id(it.Id), completed = info.completed,
                                    equipped = worn[k] == true,
                                    cont = c,
                                }
                                if info.mismatch then plog_decoded(('Item %s: manual decode and unpack_be disagree'):format(k)) end
                            end
                        end
                    end
                end
            end
        end
    end)
    if ok then MG.scanned = true end
    return ok and seen or nil
end

local function mg_apply_items(seen)
    core.syncItems(MG.state, seen, os.time())
    local worn, n = {}, 0
    for id, copies in pairs(seen) do
        n = n + 1
        MG.seen.itemTrial = true
        -- an item whose trial is finished and that the Moogle isn't tracking is just gear: no window entry
        local interesting = false
        for _, a in ipairs(MG.state.active) do if a == id then interesting = true end end
        for _, x in ipairs(cfg.trials) do if x.number == id then interesting = true end end
        for _, info in pairs(copies) do if info.completed == false then interesting = true end end
        if interesting then mg_sync(id, false) end
        for _, info in pairs(copies) do if info.equipped then worn[#worn + 1] = id break end end
    end
    MG.stats.items = n
    table.sort(worn)
    local sig = table.concat(worn, ',')
    -- the weapon/armor you are wearing is the trial you are on; re-select only when that changes
    if #worn > 0 and sig ~= MG.seenSig then
        for _, x in ipairs(cfg.trials) do
            if x.number == worn[1] then mg_select(x, not MG.firstScan) break end
        end
        plog_decoded('Wearing item with trial ' .. sig)
    end
    MG.seenSig, MG.firstScan = sig, false
    settings.save()
end

local INVENTORY_PACKETS = { [0x00A] = true, [0x01E] = true, [0x01F] = true, [0x020] = true, [0x050] = true }

ashita.events.register('packet_in', 'rt_magian_in', safe('magian', function(e)
    if not core or cfg.magian == false then return end
    if INVENTORY_PACKETS[e.id] then
        mg_request_scan()
        bag_dirty = true
        if e.id == 0x00A then MG.state.active = {} end        -- zoning: the Moogle list must be re-confirmed
        return
    end
    if e.id ~= 0x034 and e.id ~= 0x05C and e.id ~= 0x029 then return end
    local d = pkt_data(e)
    if not d then return end
    if e.id == 0x034 then mg_on_event_params(d)
    elseif e.id == 0x05C then mg_on_pending(d)
    else mg_on_message(d) end
end))

ashita.events.register('packet_out', 'rt_magian_out', safe('magian', function(e)
    if not core or cfg.magian == false or e.id ~= 0x05B then return end
    local d = pkt_data(e)
    if d then mg_on_event_update(d) end
end))

-- No timer: this only checks a flag that the events above set.
MG.scanDue = os.clock() + 3      -- once after the addon loads (login / reload)
ashita.events.register('d3d_present', 'rt_item_scan', safe('itemscan', function()
    if not core or not MG.scanDue or os.clock() < MG.scanDue then return end
    MG.scanDue = nil
    if cfg.magian == false then return end
    local seen = mg_scan_items()
    if seen then mg_apply_items(seen) end
end))

local function mg_status()
    local s, v = MG.stats, MG.seen
    local function yn(b) return b and 'seen' or 'not seen yet' end
    say(('Magian tracker: %s   character: %s'):format((not core) and 'unavailable' or (cfg.magian == false and 'OFF' or 'ON'), mg_char()))
    say('  Verified on VanaDreams (capture of 2026-10-30): Moogle trial list (0x034), your menu choice (0x05B), replies types 1, 2, 5 (0x05C).')
    say('  Inferred from that capture: type 3 = reward. Not understood yet: type 4. Messages 583/584 not seen yet.')
    say(('  Moogle trial list: %s   trial status reply: %s   item detail reply: %s'):format(yn(v.moogleList), yn(v.status), yn(v.detail)))
    say(('  message 583 (progress): %s   message 584 (complete): %s   item trial data: %s'):format(yn(v.msg583), yn(v.msg584), yn(v.itemTrial)))
    say(('  counts: lists %d, replies %d, messages %d, trial items %d, unexpected layouts %d, duplicates ignored %d'):format(
        s.moogle, s.reply, s.message, s.items, s.mismatch, MG.state and MG.state.dupes or 0))
    if MG.state and #MG.state.active > 0 then say('  Active trials from the Moogle: ' .. table.concat(MG.state.active, ', ')) end
    for ty, n in pairs(MG.unknownTypes or {}) do say(('  request type %d seen %d time(s): meaning not verified'):format(ty, n)) end
    say(('  Visit reports: %s   last: %s'):format(cfg.moogleLog == false and 'OFF' or 'ON', tostring(mrec.lastReport or mrec.path or 'none yet')))
end

--------------------------------------------------------------------------------
-- Chat auto-counting
--------------------------------------------------------------------------------
local function on_text_in(e)
    if e.injected then return end
    if plog.on then plog_chat(string.strip_colors(e.message_modified or e.message or '')) end
    if mrec and mrec.on then mrec_chat(string.strip_colors(e.message_modified or e.message or '')) end
    if cfg.auto ~= false and os.clock() < capture.until_t then
        capture_line(string.strip_colors(e.message_modified or e.message or ''))
    end
    local msg = string.strip_colors(e.message_modified or e.message or ''):lower()
    if msg == '' then return end

    local tn = msg:match('trial%s*#%s*(%d+)') or msg:match('trial%s+number%s*:?%s*#?(%d+)')
    if tn and cfg.auto ~= false and os.clock() >= capture.until_t then
        local n = tonumber(tn)
        if n and cfg.trialdb[db_key(n)] then activate_number(n) end
    end

    -- Passive status updates: a line with progress like 43/100 that names a trial (or says "trial")
    if cfg.auto ~= false and os.clock() >= capture.until_t then
        local a, b = msg:match('(%d+)%s*/%s*(%d+)')
        if a and b and tonumber(b) >= 1 then
            local hit
            for _, t in ipairs(cfg.trials) do
                if msg:find(t.name:lower(), 1, true) then hit = t break end
            end
            if not hit and msg:find('trial', 1, true) then hit = find_trial(cfg.active) end
            if hit and hit.reqmode == 'derived' and #(hit.reqs or {}) > 0 then hit = nil end
            if hit and hit.serverTracked then hit = nil end
            if hit and (hit.current ~= tonumber(a) or hit.target ~= tonumber(b)) then
                hit.target = math.floor(tonumber(b))
                hit.current = 0
                hit.done = false
                bump(hit, math.floor(tonumber(a)))
                hit.synced = os.date('%H:%M:%S')
            end
        end
    end

    if os.clock() >= capture.until_t then count_reqs(msg) end

    for _, t in ipairs(cfg.trials) do
        if not t.done and not t.serverTracked and t.mode ~= 'none' and t.watch ~= '' then
            local w = t.watch:lower()
            local hit = false
            if t.mode == 'kill' then
                hit = msg:find('defeats the ' .. w, 1, true)
                   or msg:find('you defeat the ' .. w, 1, true)
            elseif t.mode == 'item' then
                hit = msg:find('obtained: ' .. w, 1, true)
                   or msg:find('you find a ' .. w, 1, true)
                   or msg:find('you find an ' .. w, 1, true)
                   or msg:find('obtains a ' .. w, 1, true)
            elseif t.mode == 'text' then
                hit = msg:find(w, 1, true)
            end
            if hit then bump(t, 1) end
        end
    end
end
ashita.events.register('text_in', 'rt_text_in', safe('chat', on_text_in))

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------
local function help()
    say('Commands (/rt or /rematracker):')
    say('  show | hide | toggle           - window')
    say('  list                           - print trials with their index')
    say('  add <type> <target> <name...>  - type: relic mythic empyrean aeonic armor magian other')
    say('  job <#> <JOB>                  - set the job for an armor trial (e.g. WAR)')
    say('  type <#> <type>                - change a trial type (relic, mythic, armor, ...)')
    say('  inc <#> [n] | dec <#> [n]      - change progress')
    say('  set <#> <value>                - set progress')
    say('  target <#> <value>             - change goal')
    say('  watch <#> <kill|item|text|off> <string...> - auto count from chat')
    say('  active <#>                     - choose the trial you are currently on')
    say('  objective <#> <text...>        - what the trial is (e.g. "Defeat 100 Goblin Smiths")')
    say('  note <#> <text...>             - attach a note (stage, item, location)')
    say('  done <#> | reset <#> | remove <#> | clear')
    say('  auto [on|off]                  - auto-detect trial/status after talking to an NPC')
    say('  capture                        - manually listen for NPC text for a few seconds')
    say('  party [on|off|test]            - celebration animation on stage complete')
    say('  lines                          - show the last NPC text the addon heard')
    say('  pattern <name|progress> <lua pattern> | pattern clear - teach it your server wording')
    say('  info [#]                       - print the exact requirements of a trial')
    say('  req <#> <kill|item|turnin|other> <need> <name...> | req <#> clear - set requirements by hand')
    say('  trial <number>                 - set up trial #N from the learned database')
    say('  number <#> <trial number>      - give a listed trial its trial number')
    say('  trialdb                        - list the trial numbers learned so far')
    say('  dumpext                        - print equipped items\' raw extra data (to help decode trial numbers)')
    say('  plog start [talk|all] | plog ids <hex...> | plog stop - packet logger (see /rt plog)')
    say('  plog note <text> | plog ignore <hex...> | plog status  - label / filter / check the log')
    say('  plog learn number <n> [cur <n>] [target <n>] [left <n>] | plog map [clear] - teach it from the last log')
    say('  magian [on|off|scan|zone <id>] - server-confirmed Magian tracker status')
    say('  slots [<slot> on|off|all|none] - which bags/slots Magian items are tracked in (equipped + inventory by default)')
    say('  moogle [on|off|stop|note]      - automatic report of each Magian Moogle visit')
    say('  sound [on|off|test]            - victory fanfare when a stage completes')
    say('  selftest                       - run the offline Magian logic tests in game')
    say('  errors [clear]                 - show/clear the error log')
    say('  repair                         - validate and fix saved trial data')
end

local function resolve_type(s)
    s = (s or ''):lower()
    for _, v in ipairs(TYPES) do
        if v:lower() == s then return v end
    end
end

local function on_command(e)
    local args = e.command:args()
    if #args == 0 or (args[1]:lower() ~= '/rt' and args[1]:lower() ~= '/rematracker') then return end
    e.blocked = true

    local sub = (args[2] or 'help'):lower()

    if sub == 'help' then help()
    elseif sub == 'show' then ui.open[1] = true
    elseif sub == 'hide' then ui.open[1] = false
    elseif sub == 'toggle' then ui.open[1] = not ui.open[1]
    elseif sub == 'list' then
        if #cfg.trials == 0 then say('No trials yet. Use /rt add.') end
        for i, t in ipairs(cfg.trials) do
            say(('%d. [%s] %s  %d/%d%s'):format(i, tag(t), t.name, t.current, t.target, t.done and ' (done)' or ''))
        end
    elseif sub == 'add' then
        local ttype = resolve_type(args[3])
        local target = tonumber(args[4])
        if not ttype or not target or not args[5] then
            say('Usage: /rt add <type> <target> <name...>')
            return
        end
        local name = table.concat(args, ' ', 5)
        add_trial(ttype, name, target)
        say(('Added [%s] %s (0/%d)'):format(ttype, name, target))
    elseif sub == 'inc' or sub == 'dec' then
        local t = by_index(args[3])
        if not t then say('Bad index.') return end
        local n = tonumber(args[4]) or 1
        bump(t, sub == 'inc' and n or -n)
    elseif sub == 'set' then
        local t = by_index(args[3])
        local v = tonumber(args[4])
        if not t or not v then say('Usage: /rt set <#> <value>') return end
        t.current = 0
        t.done = false
        bump(t, v)
    elseif sub == 'target' then
        local t = by_index(args[3])
        local v = tonumber(args[4])
        if not t or not v then say('Usage: /rt target <#> <value>') return end
        t.target = math.max(1, v)
        t.done = t.current >= t.target
        settings.save()
    elseif sub == 'watch' then
        local t = by_index(args[3])
        local mode = (args[4] or ''):lower()
        if not t then say('Bad index.') return end
        if mode == 'off' then
            t.mode, t.watch = 'none', ''
        elseif (mode == 'kill' or mode == 'item' or mode == 'text') and args[5] then
            t.mode, t.watch = mode, table.concat(args, ' ', 5)
        else
            say('Usage: /rt watch <#> <kill|item|text|off> <string...>')
            return
        end
        settings.save()
        say(('Watch for %s: %s %s'):format(t.name, t.mode, t.watch))
    elseif sub == 'active' then
        local t = by_index(args[3])
        if not t then say('Bad index.') return end
        cfg.active = t.id
        settings.save()
    elseif sub == 'auto' then
        local v = (args[3] or ''):lower()
        if v == 'on' then cfg.auto = true elseif v == 'off' then cfg.auto = false else cfg.auto = not (cfg.auto ~= false) end
        ui.auto[1] = cfg.auto
        settings.save()
        say('NPC auto-detect: ' .. (cfg.auto and 'ON' or 'OFF'))
    elseif sub == 'magian' then
        local v = (args[3] or ''):lower()
        if v == 'on' then cfg.magian = true settings.save()
        elseif v == 'off' then cfg.magian = false settings.save()
        elseif v == 'scan' then mg_request_scan() say('Reading worn/carried items for trials...')
        elseif v == 'zone' and tonumber(args[4]) then MG.zone = tonumber(args[4]) say('Moogle zone id set to ' .. MG.zone) end
        mg_status()
    elseif sub == 'slots' then
        local name, v = (args[3] or ''):lower(), (args[4] or ''):lower()
        if name == 'all' or name == 'none' then
            for _, o in ipairs(SLOT_LIST) do cfg.trackSlots[o[1]] = (name == 'all') end
            settings.save()
        elseif name ~= '' and (v == 'on' or v == 'off') then
            local hit
            for k, n in pairs(SLOT_NAMES) do if n == name then cfg.trackSlots[k] = (v == 'on') hit = true end end
            if hit then settings.save() else say('Unknown slot: ' .. name) end
        end
        local on = {}
        for _, o in ipairs(SLOT_LIST) do if cfg.trackSlots[o[1]] then on[#on + 1] = SLOT_NAMES[o[1]] end end
        say('Tracking Magian items in: ' .. (#on > 0 and table.concat(on, ', ') or 'nothing'))
        say('  /rt slots <worn|inventory|wardrobe|wardrobe2-4|satchel|sack|case|safe|safe2|storage|locker> <on|off>, or /rt slots all|none')
    elseif sub == 'moogle' then
        local v = (args[3] or ''):lower()
        if v == 'on' or v == 'off' then cfg.moogleLog = (v == 'on') settings.save()
        elseif v == 'stop' then mrec_stop('stopped by you')
        elseif v == 'note' then
            if mrec.on then mrec_write(('[%s] NOTE: %s\n\n'):format(os.date('%H:%M:%S'), table.concat(args, ' ', 4))) say('Note added to the visit report.')
            else say('No Moogle visit is being recorded right now.') end
        end
        say(('Magian Moogle visit reports: %s%s'):format(cfg.moogleLog == false and 'OFF' or 'ON', mrec.on and ('  (recording now, %d packets)'):format(mrec.count) or ''))
        if mrec.lastReport or mrec.path then say('  Latest report: ' .. tostring(mrec.lastReport or mrec.path)) end
        say('  Reports are saved by themselves when you talk to the Magian Moogle. Folder: ' .. plog_dir())
        say('  /rt moogle on|off|stop|note <text>')
    elseif sub == 'sound' then
        local v = (args[3] or ''):lower()
        if v == 'on' or v == 'off' then cfg.sound = (v == 'on') settings.save() end
        if v == 'test' then
            if not play_fanfare() then say('Could not play victory.wav (is it in the addon folder, and is sound on?).') end
        end
        say('Victory fanfare: ' .. (cfg.sound and 'ON' or 'OFF') .. '   (/rt sound on|off|test)')
    elseif sub == 'selftest' then
        local okt, T = pcall(require, 'magiancore_test')
        if not okt then say('magiancore_test.lua not found next to the addon.') return end
        local _, failed = T.run(say)
        if failed == 0 then say('All Magian tests passed.') end
    elseif sub == 'sprite' then
        local sp = celebrate.sprite
        local path = addon.path .. 'moogle_dance.png'
        local f = io.open(path, 'rb')
        say(('Sprite file: %s  (%s)'):format(path, f and 'found' or 'NOT FOUND - copy moogle_dance.png into the addon folder'))
        if f then f:close() end
        if sp then
            if sp.state == 'failed' then sp.state, sp.mode = 'new', 'drawlist' end    -- retry
            celebrate.t0, celebrate.name, celebrate.broken = os.clock(), 'Sprite test', false
            say('Playing a test celebration now; run /rt sprite again afterwards for the result.')
            say(('Last result: %s%s'):format(sp.state, sp.err and ('  - ' .. sp.err) or ''))
        end
    elseif sub == 'party' then
        local v = (args[3] or ''):lower()
        if v == 'test' then
            celebrate.broken = false
            cfg.party = true
            ui.party[1] = true
            start_celebration('Test Trial')
        else
            if v == 'on' then cfg.party = true elseif v == 'off' then cfg.party = false else cfg.party = not (cfg.party ~= false) end
            ui.party[1] = cfg.party
            settings.save()
            say('Celebration animation: ' .. (cfg.party and 'ON' or 'OFF'))
        end
    elseif sub == 'capture' then
        open_capture()
        say('Listening - talk to your trial NPC now.')
    elseif sub == 'lines' then
        if #capture.last == 0 then say('Nothing captured yet.') end
        for _, l in ipairs(capture.last) do say('  ' .. l) end
        say(capture.result)
    elseif sub == 'pattern' then
        local which = (args[3] or ''):lower()
        if which == 'clear' then
            cfg.patterns.name, cfg.patterns.progress = '', ''
            settings.save()
            say('Custom patterns cleared.')
        elseif (which == 'name' or which == 'progress') and args[4] then
            local pat = table.concat(args, ' ', 4)
            if not pcall(string.find, '', pat) then say('That is not a valid Lua pattern.') return end
            cfg.patterns[which] = pat
            settings.save()
            say(('Pattern %s = %s  (name: 1 capture; progress: 2 captures = current, goal)'):format(which, pat))
        else
            say('Usage: /rt pattern <name|progress> <lua pattern>  or  /rt pattern clear')
        end
    elseif sub == 'info' then
        local t = by_index(args[3]) or find_trial(cfg.active)
        if not t then say('No trial selected.') return end
        say(('[%s] %s  %d/%d'):format(tag(t), t.name, t.current, t.target))
        if (t.objective or '') ~= '' then say('  Trial: ' .. t.objective) end
        for _, r in ipairs(t.reqs or {}) do
            local extra = (r.kind == 'item' or r.kind == 'turnin') and (' (in bag: %d)'):format(r.bag or 0) or ''
            say(('  %s: %s x%d  -  %d/%d%s'):format(r.kind, r.name, r.need, r.have, r.need, extra))
        end
        if #(t.reqs or {}) == 0 then say('  No requirements read yet - talk to the NPC.') end
    elseif sub == 'req' then
        local t = by_index(args[3])
        if not t then say('Bad index.') return end
        local kind = (args[4] or ''):lower()
        if kind == 'clear' then
            t.reqs = {}
            settings.save()
        else
            local need = tonumber(args[5])
            if not (kind == 'kill' or kind == 'item' or kind == 'turnin' or kind == 'other') or not need or not args[6] then
                say('Usage: /rt req <#> <kill|item|turnin|other> <need> <name...>')
                return
            end
            local name = table.concat(args, ' ', 6)
            table.insert(t.reqs, { kind = kind, name = name, key = stem(name), need = math.max(1, need), have = 0, bag = 0 })
            t.reqmode = 'derived'
            recompute(t)
            settings.save()
        end
    elseif sub == 'trial' then
        local n = tonumber(args[3])
        if not n then say('Usage: /rt trial <number>') return end
        local known = cfg.trialdb[db_key(n)] ~= nil
        local t = activate_number(n)
        say(known and ('Trial #%d set up: %s'):format(n, t.name)
                  or ('Trial #%d is new. Talk to the NPC and it will learn the requirements.'):format(n))
    elseif sub == 'number' then
        local t = by_index(args[3])
        local n = tonumber(args[4])
        if not t or not n then say('Usage: /rt number <#> <trial number>') return end
        t.number = n
        learn_trial(t)
        settings.save()
    elseif sub == 'trialdb' then
        local keys = {}
        for k in pairs(cfg.trialdb) do keys[#keys + 1] = tonumber(k) or 0 end
        table.sort(keys)
        if #keys == 0 then say('No trial numbers learned yet.') end
        for _, k in ipairs(keys) do
            local e = cfg.trialdb[db_key(k)]
            say(('#%d  %s  (%d requirement%s)'):format(k, e.name or '?', #e.reqs, #e.reqs == 1 and '' or 's'))
        end
    elseif sub == 'dumpext' then
        local names = { 'Main', 'Sub', 'Range', 'Ammo', 'Head', 'Body', 'Hands', 'Legs', 'Feet', 'Neck', 'Waist', 'Ear1', 'Ear2', 'Ring1', 'Ring2', 'Back' }
        local ok = pcall(function()
            local inv = AshitaCore:GetMemoryManager():GetInventory()
            local res = AshitaCore:GetResourceManager()
            for slot = 0, 15 do
                local eq = inv:GetEquippedItem(slot)
                if eq ~= nil and eq.Index ~= 0 then
                    local container = bit.rshift(bit.band(eq.Index, 0xFF00), 8)
                    local it = inv:GetContainerItem(container, bit.band(eq.Index, 0x00FF))
                    if it ~= nil and it.Id ~= 0 and it.Id ~= 65535 then
                        local r = res:GetItemById(it.Id)
                        local hex, extra = {}, it.Extra
                        if type(extra) == 'string' then
                            for i = 1, #extra do hex[#hex + 1] = ('%02X'):format(extra:byte(i)) end
                        elseif type(extra) == 'table' then
                            for i = 1, #extra do hex[#hex + 1] = ('%02X'):format(extra[i]) end
                        end
                        say(('%s: %s  %s'):format(names[slot + 1], r and tostring(r.Name[1]) or tostring(it.Id), table.concat(hex, ' ')))
                    end
                end
            end
        end)
        if not ok then say('Could not read equipment on this Ashita build.') end
    elseif sub == 'plog' then
        local act = (args[3] or 'status'):lower()
        if act == 'start' then
            local mode = (args[4] or 'talk'):lower()
            plog_start(mode == 'all' and 'all' or 'talk', nil)
        elseif act == 'ids' then
            local set, n = parse_ids(args, 4)
            if n == 0 then say('Usage: /rt plog ids <hex ids>   e.g. /rt plog ids 32 34 5C') return end
            plog_start('ids', set)
        elseif act == 'stop' then
            if plog.on then plog_stop('stopped by you') else say('Packet logger is not running.') end
        elseif act == 'note' then
            local text = args[4] and table.concat(args, ' ', 4) or ''
            if not plog.on then say('Start the logger first: /rt plog start') return end
            plog_write(('[%s] NOTE: %s\n\n'):format(os.date('%H:%M:%S'), text))
            say('Note added to the log.')
        elseif act == 'learn' then
            local known, n = {}, 0
            local alias = { number = 'number', cur = 'cur', target = 'target', left = 'remaining', remaining = 'remaining' }
            local i = 4
            while args[i] and args[i + 1] do
                local f, v = alias[args[i]:lower()], tonumber(args[i + 1])
                if f and v then known[f] = v n = n + 1 end
                i = i + 2
            end
            if n == 0 then say('Usage: /rt plog learn number 1234 [cur 42] [target 100] [left 58]') return end
            local pk
            local path = latest_log_path()
            if path then pk = read_log_packets(path) end
            if (not pk or #pk == 0) and #capture.lastpackets > 0 then pk, path = capture.lastpackets, 'the last NPC talk' end
            if not pk or #pk == 0 then say('No packets to learn from. Run /rt plog start, talk to the NPC, then try again.') return end
            calibrate(pk, known)
            settings.save()
            say(('Learned from %d packets (%s).'):format(#pk, tostring(path)))
            for _, l in ipairs(map_summary()) do say('  ' .. l) end
            if #map_summary() == 0 then say('  Nothing reliable yet. Do this once more with a different trial/value.') end
        elseif act == 'map' then
            if (args[4] or ''):lower() == 'clear' then
                cfg.pktmap = T{ number = T{}, cur = T{}, target = T{}, remaining = T{} }
                settings.save()
                say('Learned packet locations cleared.')
            else
                local sm = map_summary()
                if #sm == 0 then say('No reliable packet locations learned yet.') end
                for _, l in ipairs(sm) do say(l) end
            end
        elseif act == 'ignore' then
            local set, n = parse_ids(args, 4)
            if n == 0 then say('Usage: /rt plog ignore <hex ids>') return end
            for id in pairs(set) do plog.ignore.ALL[id] = true end
            say(('Ignoring %d more packet id(s) in both directions.'):format(n))
        else
            say(('Packet logger: %s  mode=%s  packets=%d'):format(plog.on and 'RUNNING' or 'stopped', plog.mode, plog.count))
            if plog.path then say('Log file: ' .. plog.path) end
        end
    elseif sub == 'errors' then
        if (args[3] or ''):lower() == 'clear' then
            errlog.list, errlog.count = {}, 0
            say('Error log cleared.')
        elseif #errlog.list == 0 then
            say('No errors recorded.')
        else
            for i = math.max(1, #errlog.list - 4), #errlog.list do
                local en = errlog.list[i]
                say(('%s [%s/%s] x%d %s'):format(en.time, en.kind, en.where, en.n, en.msg))
            end
            if logpath then say('Full log: ' .. logpath) end
        end
    elseif sub == 'repair' then
        local n = repair()
        say(n == 0 and 'Data looks fine, nothing to repair.' or ('Repaired %d problem(s).'):format(n))
    elseif sub == 'type' then
        local t = by_index(args[3])
        local v = resolve_type(args[4])
        if not t or not v then say('Usage: /rt type <#> <relic|mythic|empyrean|aeonic|armor|magian|other>') return end
        t.type = v
        settings.save()
    elseif sub == 'job' then
        local t = by_index(args[3])
        if not t then say('Bad index.') return end
        t.job = (args[4] or ''):upper()
        settings.save()
    elseif sub == 'objective' then
        local t = by_index(args[3])
        if not t then say('Bad index.') return end
        t.objective = args[4] and table.concat(args, ' ', 4) or ''
        settings.save()
    elseif sub == 'note' then
        local t = by_index(args[3])
        if not t then say('Bad index.') return end
        t.note = args[4] and table.concat(args, ' ', 4) or ''
        settings.save()
    elseif sub == 'done' then
        local t = by_index(args[3])
        if t then t.done = true t.current = t.target settings.save() end
    elseif sub == 'reset' then
        local t = by_index(args[3])
        if t then t.current = 0 t.done = false settings.save() end
    elseif sub == 'remove' then
        local n = tonumber(args[3])
        if n and cfg.trials[n] then table.remove(cfg.trials, n) settings.save() end
    elseif sub == 'clear' then
        cfg.trials = T{}
        settings.save()
        say('All trials cleared.')
    else
        help()
    end
end
ashita.events.register('command', 'rt_command', safe('command', on_command))

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
-- Some Ashita/ImGui builds do not expose SetWindowFontScale. Use it only if present.
local HAS_SCALE = (type(imgui.SetWindowFontScale) == 'function')
local function set_scale(v)
    if HAS_SCALE then
        local ok = pcall(imgui.SetWindowFontScale, v)
        if not ok then HAS_SCALE = false end
    end
end

local TYPE_COLORS = {
    Relic    = { 1.00, 0.82, 0.30, 1.0 },
    Mythic   = { 0.82, 0.55, 1.00, 1.0 },
    Empyrean = { 0.40, 0.78, 1.00, 1.0 },
    Aeonic   = { 1.00, 0.42, 0.42, 1.0 },
    Armor    = { 1.00, 0.66, 0.25, 1.0 },
    Magian   = { 0.50, 1.00, 0.65, 1.0 },
    Other    = { 0.80, 0.80, 0.85, 1.0 },
}

-- Classic FFXI menu look: deep blue panels, gold trim, cream text.
local GOLD  = { 0.96, 0.80, 0.38, 1.0 }
local CREAM = { 0.97, 0.94, 0.85, 1.0 }
local DIM   = { 0.62, 0.68, 0.90, 1.0 }
local WHITE = { 1.00, 1.00, 1.00, 1.0 }

local function lerp_col(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t,
             a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t }
end

local function pulse(speed)
    return 0.5 + 0.5 * math.sin(os.clock() * speed)
end

local function push_theme(border)
    local cols = {
        { ImGuiCol_Text,             CREAM },
        { ImGuiCol_TextDisabled,     DIM },
        { ImGuiCol_WindowBg,         { 0.04, 0.06, 0.24, 0.96 } },
        { ImGuiCol_PopupBg,          { 0.05, 0.08, 0.30, 0.98 } },
        { ImGuiCol_Border,           border },
        { ImGuiCol_TitleBg,          { 0.10, 0.14, 0.44, 1.0 } },
        { ImGuiCol_TitleBgActive,    { 0.17, 0.24, 0.62, 1.0 } },
        { ImGuiCol_TitleBgCollapsed, { 0.08, 0.10, 0.34, 1.0 } },
        { ImGuiCol_FrameBg,          { 0.02, 0.03, 0.14, 1.0 } },
        { ImGuiCol_FrameBgHovered,   { 0.10, 0.14, 0.42, 1.0 } },
        { ImGuiCol_FrameBgActive,    { 0.14, 0.20, 0.54, 1.0 } },
        { ImGuiCol_Button,           { 0.12, 0.18, 0.52, 1.0 } },
        { ImGuiCol_ButtonHovered,    { 0.24, 0.33, 0.74, 1.0 } },
        { ImGuiCol_ButtonActive,     { 0.80, 0.62, 0.20, 1.0 } },
        { ImGuiCol_Header,           { 0.12, 0.18, 0.52, 1.0 } },
        { ImGuiCol_HeaderHovered,    { 0.24, 0.33, 0.74, 1.0 } },
        { ImGuiCol_HeaderActive,     { 0.80, 0.62, 0.20, 1.0 } },
        { ImGuiCol_Separator,        { 0.80, 0.65, 0.28, 0.65 } },
        { ImGuiCol_ScrollbarBg,      { 0.02, 0.03, 0.14, 0.8 } },
        { ImGuiCol_ScrollbarGrab,    { 0.60, 0.48, 0.20, 1.0 } },
        { ImGuiCol_CheckMark,        GOLD },
    }
    for _, c in ipairs(cols) do imgui.PushStyleColor(c[1], c[2]) end

    local nvar = 0
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0)    nvar = nvar + 1
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0)     nvar = nvar + 1
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.0)  nvar = nvar + 1
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1.0)   nvar = nvar + 1
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 14, 12 }) nvar = nvar + 1
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 8, 7 })  nvar = nvar + 1
    return #cols, nvar
end

local function heading(text)
    imgui.TextColored(GOLD, '- ' .. text .. ' -')
end

local function big_text(text, color, scale)
    -- ImGui has no bold font, so draw the text twice with a 1px offset to fake it.
    -- Without font scaling, frame the text so it still stands out.
    if not HAS_SCALE then text = '*** ' .. text .. ' ***' end
    set_scale(scale)
    local x, y = imgui.GetCursorPos()
    imgui.SetCursorPos({ x + 1, y })
    imgui.TextColored(color, text)
    imgui.SetCursorPos({ x, y })
    imgui.TextColored(color, text)
    set_scale(1.0)
end

local function draw_add_form()
    imgui.PushItemWidth(110)
    if imgui.BeginCombo('##type', TYPES[ui.typeIdx]) then
        for i, v in ipairs(TYPES) do
            if imgui.Selectable(v, i == ui.typeIdx) then ui.typeIdx = i end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.PushItemWidth(220)
    imgui.InputText('##name', ui.name, 64)
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.PushItemWidth(90)
    imgui.InputInt('##target', ui.target)
    imgui.PopItemWidth()
    imgui.Text('Job (armor):')
    imgui.SameLine()
    imgui.PushItemWidth(70)
    imgui.InputText('##job', ui.job, 4)
    imgui.PopItemWidth()
    imgui.Text('What is the trial?')
    imgui.SameLine()
    imgui.PushItemWidth(380)
    imgui.InputText('##objective', ui.objective, 128)
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button('Accept') and ui.name[1] ~= '' then
        local t = add_trial(TYPES[ui.typeIdx], ui.name[1], ui.target[1], ui.objective[1], ui.job[1])
        ui.name[1], ui.objective[1], ui.job[1] = '', '', ''
        if cfg.active == 0 then cfg.active = t.id end
    end
end

local REQ_LABEL = {
    kill = { 'KILL', { 1.00, 0.45, 0.45, 1.0 } },
    turnin = { 'TURN IN', { 0.50, 0.85, 1.00, 1.0 } },
    item = { 'OBTAIN', { 0.50, 1.00, 0.65, 1.0 } },
    other = { 'NEED', { 0.85, 0.85, 0.90, 1.0 } },
}

local function draw_requirements(t)
    local reqs = t.reqs or {}
    if #reqs == 0 then
        imgui.TextDisabled('Requirements: talk to the trial NPC to read them.')
    else
        imgui.TextColored(GOLD, 'Requirements')
    end
    for i, r in ipairs(reqs) do
        imgui.PushID(i)
        local lab = REQ_LABEL[r.kind] or REQ_LABEL.other
        local ok = (not r.haveUnknown) and r.have >= r.need
        local isItem = (r.kind == 'turnin' or r.kind == 'item')
        imgui.TextColored(lab[2], ('[%s]'):format(lab[1]))
        imgui.SameLine()
        if r.kind == 'kill' then
            imgui.Text(('Mob: %s'):format(r.name))
            imgui.TextDisabled(('    Zone: %s'):format(r.zone and (r.zone .. (r.zoneSrc == 'seen' and '  (where you killed it)' or '')) or 'not known yet (filled in when you kill one)'))
            imgui.TextDisabled(('    Kills required: %d'):format(r.need))
            for _, c in ipairs(r.conditions or {}) do imgui.TextDisabled('    ' .. c) end
        elseif isItem then
            imgui.Text(('Item: %s'):format(r.name))
            imgui.TextDisabled(('    Required: %d'):format(r.need))
        else
            imgui.Text(('%d x %s'):format(r.need, r.name))
        end
        imgui.Text(r.kind == 'kill' and '    Progress:' or '    Progress:')
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol_PlotHistogram, ok and GOLD or lab[2])
        if r.haveUnknown then
            imgui.ProgressBar(0, { 140, 16 }, ('? / %d'):format(r.need))
        else
            imgui.ProgressBar(math.min(1, r.have / r.need), { 140, 16 }, ('%d/%d'):format(math.min(r.have, 99999), r.need))
        end
        imgui.PopStyleColor(1)
        if ok then
            imgui.SameLine()
            imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'DONE')
        elseif isItem then
            imgui.SameLine()
            imgui.TextDisabled(('in bag: %d  (need %d more)'):format(r.bag or 0, math.max(0, r.need - r.have)))
        elseif not r.haveUnknown then
            imgui.SameLine()
            imgui.TextDisabled(('%d left'):format(r.need - r.have))
        end
        imgui.PopID()
    end

    if #(t.npc or {}) > 0 then
        if imgui.CollapsingHeader(('What the NPC said###rt_npc%d'):format(t.id)) then
            for _, l in ipairs(t.npc) do imgui.TextWrapped(l) end
        end
    end
    if type(t.convo) == 'table' and #t.convo > 0 then
        local last = t.convo[#t.convo]
        if imgui.CollapsingHeader(('Conversation log (%d recorded)###rt_cv%d'):format(#t.convo, t.id)) then
            imgui.TextDisabled('Also saved to npc_log.txt in the addon folder.')
            for n = #t.convo, 1, -1 do
                local c = t.convo[n]
                imgui.TextColored(GOLD, ('%s%s'):format(c.time, (c.seen or 1) > 1 and ('   (heard %d times, last %s)'):format(c.seen, c.checked or c.time) or ''))
                for _, l in ipairs(c.lines or {}) do imgui.TextWrapped('  ' .. l) end
                imgui.Spacing()
            end
        end
    end
end

-- The trial you are working on: everything you need at a glance. Extras are folded away.
-- Returns true if the user asked to remove this trial.
local PROV_COLOR = {
    ['server-confirmed'] = { 0.45, 1.00, 0.55, 1.0 },
    ['from item']        = { 0.50, 0.80, 1.00, 1.0 },
    ['estimate']         = { 1.00, 0.80, 0.30, 1.0 },
    ['stale']            = { 1.00, 0.60, 0.30, 1.0 },
    ['cached (stale)']   = { 1.00, 0.60, 0.30, 1.0 },
    ['unknown']          = { 0.70, 0.70, 0.78, 1.0 },
    ['from Moogle']      = { 0.45, 1.00, 0.55, 1.0 },
    ['inferred']         = { 1.00, 0.80, 0.30, 1.0 },
}

-- Server data for one trial: every value says where it came from. Unknown stays "unknown", never zero.
local function draw_magian(t)
    if not core or not t.serverTracked or not t.number then return end
    local v = core.view(MG.state, t.number, os.time())
    if not v then return end
    if not imgui.CollapsingHeader(('Server data###rt_mg%d'):format(t.id), ImGuiTreeNodeFlags_DefaultOpen or 32) then return end

    local function row(label, value, prov)
        imgui.Text(('%s %s'):format(label, value))
        imgui.SameLine()
        imgui.TextColored(PROV_COLOR[prov] or PROV_COLOR.unknown, '[' .. prov .. ']')
    end
    local function num(x) return x ~= nil and tostring(x) or 'unknown' end

    imgui.TextDisabled(('%s   |   weapon: %s   |   trial #%d'):format(mg_char(), v.weaponNames or 'not found in worn gear/bags', v.id))
    row('Required total:', num(v.total), v.totalLabel)
    if v.estimateMismatch then imgui.TextDisabled(('  route data estimated %d; the server says %d'):format(v.estimateMismatch, v.total or 0)) end
    if v.estimateWrong then imgui.TextDisabled(('  route estimate of %d was wrong and was dropped'):format(v.estimateWrong)) end
    row('Progress:', num(v.progress), v.progressLabel)
    row('Remaining:', num(v.remaining), v.remainingLabel)

    local complete = 'unknown'
    if v.completed == true then complete = 'yes'
    elseif v.completed == false or (v.remaining ~= nil and v.remaining > 0) then complete = 'no' end
    local rq = MG.required and MG.required[t.number]
    if rq and rq.item and rq.item > 0 then row('Item to upgrade:', item_name_by_id(rq.item) or ('item #' .. rq.item), 'from Moogle') end
    local rw = MG.reward and MG.reward[t.number]
    if rw and rw.item and rw.item > 0 then
        local parts = {}
        for _, a in ipairs(rw.augments) do parts[#parts + 1] = core.describeAugment(a) end
        row('Reward:', (item_name_by_id(rw.item) or ('item #' .. rw.item)) .. (#parts > 0 and (' with ' .. table.concat(parts, ', ')) or ''), 'inferred')
    end
    row('Objective complete:', complete, complete == 'unknown' and 'unknown' or v.completedLabel)
    row('Reward claimed:', 'unknown', 'unknown')
    local raw = MG.raw and MG.raw[t.number]
    if raw then imgui.TextDisabled(('Last Moogle reply (type %d, %s): %s'):format(raw.type, raw.at, raw.nums)) end
    if v.completed == true then imgui.TextColored(GOLD, 'Report to the Magian Moogle to claim the reward.') end

    local r = t.reqs and t.reqs[1]
    if r and r.kind == 'turnin' then
        row('Materials owned (bag):', tostring(r.bag or 0), 'from item')
        row('Materials deposited:', num(v.progress), v.progressLabel)
    end
    if v.route then
        imgui.TextDisabled(('Route (estimate): previous trial %d | needs %s | rewards %s'):format(v.route.previous, v.route.requiredItem or '?', v.route.rewardItem or '?'))
    end
end

local function draw_current(t)
    local col = TYPE_COLORS[t.type] or TYPE_COLORS.Other
    local remove = false

    imgui.TextColored(col, ('[%s]'):format(tag(t)))
    imgui.SameLine()
    set_scale(1.3)
    imgui.TextColored(col, t.name)
    set_scale(1.0)
    if t.number then
        imgui.SameLine()
        imgui.TextColored(GOLD, ('#%d'):format(t.number))
    end
    if (t.objective or '') ~= '' then imgui.TextWrapped(t.objective) end

    imgui.Spacing()
    local frac = math.min(1, t.current / t.target)
    local bar = col
    if t.done then bar = lerp_col(GOLD, WHITE, pulse(5) * 0.6) end
    local plabel = ('%d / %d  (%d%%)'):format(t.current, t.target, math.floor(frac * 100))
    if t.serverTracked and not t.done then
        if t.remainingOnly then plabel, frac = ('%d remaining (total unknown)'):format(t.target), 0
        elseif t.progressUnknown then plabel, frac = ('? / %d'):format(t.target), 0 end
    end
    imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar)
    imgui.ProgressBar(frac, { -1, 22 }, plabel)
    imgui.PopStyleColor(1)

    if t.done then
        big_text('STAGE COMPLETE!', lerp_col(GOLD, WHITE, pulse(5)), 2.6)
    end

    draw_magian(t)

    imgui.Spacing()
    draw_requirements(t)

    imgui.Spacing()
    local foot = {}
    if (t.synced or '') ~= '' then foot[#foot + 1] = 'synced ' .. t.synced end
    if (t.via or '') ~= '' then foot[#foot + 1] = 'found via ' .. t.via end
    if t.mode ~= 'none' then foot[#foot + 1] = ('auto-count: %s "%s"'):format(t.mode, t.watch) end
    if #foot > 0 then imgui.TextDisabled(table.concat(foot, '   |   ')) end

    if imgui.CollapsingHeader(('Adjust by hand###rt_adj%d'):format(t.id)) then
        if imgui.SmallButton('-1') then bump(t, -1) end
        imgui.SameLine()
        if imgui.SmallButton('+1') then bump(t, 1) end
        imgui.SameLine()
        if imgui.SmallButton('+10') then bump(t, 10) end
        imgui.SameLine()
        if imgui.SmallButton('Reset') then t.current = 0 t.done = false settings.save() end
        imgui.SameLine()
        if imgui.SmallButton('Remove trial') then remove = true end
        if (t.note or '') ~= '' then imgui.TextDisabled('Note: ' .. t.note) end
    end
    return remove
end

local function draw_errors()
    local label = ('Adventurer Log - Errors (%d)###rt_errors'):format(errlog.count)
    if imgui.CollapsingHeader(label) then
        if imgui.Button('Run repair') then
            local n = repair()
            say(n == 0 and 'Data looks fine, nothing to repair.' or ('Repaired %d problem(s).'):format(n))
        end
        imgui.SameLine()
        if imgui.Button('Clear log') then errlog.list, errlog.count = {}, 0 end
        if logpath then imgui.TextDisabled(logpath) end
        if #errlog.list == 0 then imgui.TextDisabled('No errors recorded.') end
        for i = #errlog.list, 1, -1 do
            local en = errlog.list[i]
            local col = en.kind == 'error' and { 1.0, 0.4, 0.4, 1.0 } or { 0.5, 0.9, 0.5, 1.0 }
            imgui.TextColored(col, ('%s  %s/%s  x%d'):format(en.time, en.kind, en.where, en.n))
            imgui.TextWrapped(en.msg)
        end
    end
end

local TAB_SELECT = ImGuiTabItemFlags_SetSelected or 2

-- Begin a tab item; force-select it when asked. Falls back if this build rejects the flags form.
local function begin_tab(label, select)
    if select then
        local ok, res = pcall(imgui.BeginTabItem, label, nil, TAB_SELECT)
        if ok then return res end
    end
    return imgui.BeginTabItem(label)
end

local function short_label(t)
    local base = t.name
    if #base > 18 then base = base:sub(1, 17) .. '~' end
    if (t.job or '') ~= '' then base = t.job .. ' ' .. base end
    return base
end

local function draw_capture_panel()
    if imgui.Checkbox('Read my trial from the NPC after I talk to them', ui.auto) then
        cfg.auto = ui.auto[1]
        settings.save()
    end
    if imgui.SmallButton('Listen now') then open_capture() end
    imgui.SameLine()
    local listening = os.clock() < capture.until_t
    imgui.TextColored(listening and GOLD or DIM, capture.result)
    if capture.time ~= '' then imgui.TextDisabled('Last read at ' .. capture.time) end
    if imgui.TreeNode('Last NPC text###rt_lastnpc') then
        if #capture.last == 0 then imgui.TextDisabled('Nothing captured yet.') end
        for _, l in ipairs(capture.last) do imgui.TextWrapped(l) end
        imgui.TextDisabled('Not understood? /rt pattern name <p>   /rt pattern progress <p>')
        imgui.TreePop()
    end
end

-- Everything that is not "the trial I'm on": roster, adding trials, settings, errors.
-- Completed trials stay on screen for 10 seconds, then drop out of the display (data is kept).
local DONE_SHOW_SECS = 10
ui.doneSince = {}
-- Where a Magian item can be, in the order shown in the menu.
local SLOT_LIST = {
    { 'worn', 'Equipped' }, { 'c0', 'Inventory' },
    { 'c8', 'Wardrobe' }, { 'c10', 'Wardrobe 2' }, { 'c11', 'Wardrobe 3' }, { 'c12', 'Wardrobe 4' },
    { 'c5', 'Satchel' }, { 'c6', 'Sack' }, { 'c7', 'Case' },
    { 'c1', 'Safe' }, { 'c9', 'Safe 2' }, { 'c2', 'Storage' }, { 'c4', 'Locker' },
}
local SLOT_NAMES = { worn = 'worn', c0 = 'inventory', c8 = 'wardrobe', c10 = 'wardrobe2', c11 = 'wardrobe3', c12 = 'wardrobe4',
                     c5 = 'satchel', c6 = 'sack', c7 = 'case', c1 = 'safe', c9 = 'safe2', c2 = 'storage', c4 = 'locker' }

-- A Magian trial shows only when one of its items is in a slot you chose to track.
local function in_scope(t)
    if not (core and MG.scanned and t.serverTracked and t.number) then return true end   -- manual trials always show
    local tr = MG.state and MG.state.trials[tostring(t.number)]
    local slots, any = cfg.trackSlots, false
    for _, info in pairs(tr and tr.copies or {}) do
        any = true
        if info.equipped and slots.worn then return true end
        if info.cont and slots['c' .. info.cont] then return true end
    end
    if any then return false end
    for _, o in ipairs(SLOT_LIST) do if not slots[o[1]] then return false end end
    return true       -- no item found anywhere: only shown when every slot is tracked
end

local function is_hidden(t)
    if not in_scope(t) then return true end
    if not t.done then ui.doneSince[t.id] = nil return false end
    local now = os.clock()
    local since = ui.doneSince[t.id]
    if not since then ui.doneSince[t.id] = now return false end
    return now - since > DONE_SHOW_SECS
end

local function draw_menu()
    local done = 0
    for _, t in ipairs(cfg.trials) do if t.done then done = done + 1 end end
    imgui.TextDisabled(('%d trial%s tracked, %d stage%s complete'):format(
        #cfg.trials, #cfg.trials == 1 and '' or 's', done, done == 1 and '' or 's'))

    if imgui.CollapsingHeader('Track Magian items in...###rt_m_slots') then
        for i, o in ipairs(SLOT_LIST) do
            local box = { cfg.trackSlots[o[1]] == true }
            if imgui.Checkbox(o[2] .. '##slot' .. o[1], box) then cfg.trackSlots[o[1]] = box[1] settings.save() end
            if i % 3 ~= 0 and i ~= #SLOT_LIST then imgui.SameLine(150 * (i % 3)) end
        end
        if imgui.SmallButton('Equipped + inventory') then
            for _, o in ipairs(SLOT_LIST) do cfg.trackSlots[o[1]] = (o[1] == 'worn' or o[1] == 'c0') end settings.save()
        end
        imgui.SameLine()
        if imgui.SmallButton('All slots') then for _, o in ipairs(SLOT_LIST) do cfg.trackSlots[o[1]] = true end settings.save() end
    end

    if imgui.CollapsingHeader('All trials###rt_m_roster', ImGuiTreeNodeFlags_DefaultOpen or 32) then
        if #cfg.trials == 0 then imgui.TextDisabled('None yet. Talk to your trial NPC.') end
        for i, t in ipairs(cfg.trials) do
          if not is_hidden(t) then
            imgui.PushID(t.id)
            local col = TYPE_COLORS[t.type] or TYPE_COLORS.Other
            if t.id == cfg.active then
                imgui.TextColored(GOLD, '>>')
            elseif imgui.SmallButton('Go') then
                cfg.active = t.id
                ui.selectId = t.id
            end
            imgui.SameLine()
            imgui.TextColored(col, short_label(t))
            imgui.SameLine()
            imgui.PushStyleColor(ImGuiCol_PlotHistogram, t.done and GOLD or col)
            imgui.ProgressBar(math.min(1, t.current / t.target), { 100, 12 }, ('%d/%d'):format(t.current, t.target))
            imgui.PopStyleColor(1)
            if t.done then
                imgui.SameLine()
                imgui.TextColored(lerp_col(GOLD, WHITE, pulse(5)), 'COMPLETE!')
            end
            imgui.PopID()
          end
        end
    end
    if imgui.CollapsingHeader('Add a trial###rt_m_add') then draw_add_form() end
    if imgui.CollapsingHeader('NPC auto-detect###rt_m_npc') then draw_capture_panel() end
    if imgui.Checkbox('Celebration animation on stage complete', ui.party) then
        cfg.party = ui.party[1]
        settings.save()
    end
    if imgui.CollapsingHeader('Packet logger (for setup)###rt_m_plog') then
        imgui.TextColored(plog.on and GOLD or DIM, plog.on and ('RECORDING (%s) - %d packets'):format(plog.mode, plog.count) or 'Not recording')
        if not plog.on then
            if imgui.SmallButton('Start: NPC talks') then plog_start('talk', nil) end
            imgui.SameLine()
            if imgui.SmallButton('Start: everything') then plog_start('all', nil) end
        else
            if imgui.SmallButton('Stop') then plog_stop('stopped by you') end
            imgui.SameLine()
            imgui.PushItemWidth(220)
            imgui.InputText('##plognote', ui.plognote, 120)
            imgui.PopItemWidth()
            imgui.SameLine()
            if imgui.SmallButton('Add note') and ui.plognote[1] ~= '' then
                plog_write(('[%s] NOTE: %s\n\n'):format(os.date('%H:%M:%S'), ui.plognote[1]))
                ui.plognote[1] = ''
            end
        end
        if plog.path then imgui.TextDisabled(plog.path) end
        for _, l in ipairs(plog.recent) do imgui.TextDisabled(l) end
        for _, l in ipairs(map_summary()) do imgui.TextColored(GOLD, 'Decoder: ' .. l) end
        imgui.TextDisabled(('Magian decoder: %d Moogle lists, %d replies, %d progress messages, %d trial items'):format(
            MG.stats.moogle, MG.stats.reply, MG.stats.message, MG.stats.items))
        imgui.TextDisabled('Start it, talk to the trial NPC, then send me the log file.')
    end
    draw_errors()
    imgui.TextDisabled('/rt help  lists every command')
end

local function draw_body()
    -- On first draw, open on the trial you are currently working on.
    if not ui.started then
        ui.started = true
        if cfg.active ~= 0 and find_trial(cfg.active) then ui.selectId = cfg.active end
    end

    -- if the trial you were on just left the display, move to one that is still shown
    local cur = find_trial(cfg.active)
    if cur and is_hidden(cur) then
        for _, x in ipairs(cfg.trials) do
            if not is_hidden(x) then cfg.active, ui.selectId = x.id, x.id break end
        end
    end

    if #cfg.trials == 0 then
        imgui.TextColored(DIM, 'No trial yet. Talk to your trial NPC and it will appear here.')
    end

    local remove_id
    if imgui.BeginTabBar('##rt_tabs', ImGuiTabBarFlags_FittingPolicyScroll or 0) then
        -- Trials first (the one you are on is selected automatically)...
        for _, t in ipairs(cfg.trials) do
          if not is_hidden(t) then
            local col = TYPE_COLORS[t.type] or TYPE_COLORS.Other
            local label = ('%s%s###rt_tab%d'):format(t.done and '* ' or '', short_label(t), t.id)
            local want = (ui.selectId == t.id)
            imgui.PushStyleColor(ImGuiCol_Text, t.done and lerp_col(GOLD, WHITE, pulse(5)) or col)
            local open = begin_tab(label, want)
            imgui.PopStyleColor(1)
            if want then ui.selectId = nil end
            if open then
                cfg.active = t.id
                if draw_current(t) then remove_id = t.id end
                imgui.EndTabItem()
            end
          end
        end
        -- ...and everything else lives in one quiet tab at the end.
        local menu_label = ('Menu%s###rt_menu'):format(errlog.count > 0 and ' (!)' or '')
        if imgui.BeginTabItem(menu_label) then
            draw_menu()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end

    if remove_id then
        local _, idx = find_trial(remove_id)
        if idx then table.remove(cfg.trials, idx) end
        cfg.active = cfg.trials[1] and cfg.trials[1].id or 0
        settings.save()
    end
end

--------------------------------------------------------------------------------
-- Stage-complete celebration: an original dancing party blob with confetti
--------------------------------------------------------------------------------
local function ucol(r, g, b, a) return imgui.GetColorU32({ r, g, b, a }) end

local CONFETTI = {
    { 1.00, 0.35, 0.40 }, { 1.00, 0.82, 0.30 }, { 0.40, 0.85, 1.00 }, { 0.55, 1.00, 0.55 }, { 0.85, 0.55, 1.00 },
}

-- Dancing sprite: moogle_dance.png is a 4-column sheet of 256x256 cells (1024x2048), 17 frames, built from the GIF you supplied.
local SPRITE = { frames = 17, cols = 4, cell = 256, w = 1024, h = 2048, tex = nil, state = 'new', err = nil, mode = 'drawlist' }
celebrate.sprite = SPRITE

local function sprite_load()
    local path = addon.path .. 'moogle_dance.png'
    local f = io.open(path, 'rb')
    if not f then error('file not found: ' .. path) end
    f:close()
    local ffi = require('ffi')
    local d3d = require('d3d8')
    -- harmless if Ashita (or another addon) already declared it
    pcall(ffi.cdef, [[ HRESULT __stdcall D3DXCreateTextureFromFileA(IDirect3DDevice8* pDevice, const char* pSrcFile, IDirect3DTexture8** ppTexture); ]])
    local ptr = ffi.new('IDirect3DTexture8*[1]')
    local hr = ffi.C.D3DXCreateTextureFromFileA(d3d.get_device(), path, ptr)
    if hr ~= 0 then error(('D3DXCreateTextureFromFileA returned 0x%X'):format(tonumber(hr) % 0x100000000)) end
    local tex = ptr[0]
    if d3d.gc_safe_release then
        local g = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', tex))
        if g ~= nil then tex = g end
    end
    SPRITE.tex = tex
    SPRITE.id = tonumber(ffi.cast('uint32_t', tex))
end

local function sprite_texture()
    if SPRITE.state == 'ready' then return true end
    if SPRITE.state ~= 'new' then return false end
    local ok, err = pcall(sprite_load)
    if ok then SPRITE.state, SPRITE.err = 'ready', nil
    else SPRITE.state, SPRITE.err = 'failed', tostring(err) end
    return SPRITE.state == 'ready'
end

-- Returns true when the sprite was drawn (otherwise the caller draws the fallback blob).
local function draw_sprite(dl, cx, cy, fade, t)
    if not sprite_texture() then return false end
    local frame = math.floor(t * 25) % SPRITE.frames
    local col, row = frame % SPRITE.cols, math.floor(frame / SPRITE.cols)
    local u0, v0 = col * SPRITE.cell / SPRITE.w, row * SPRITE.cell / SPRITE.h
    local u1, v1 = (col + 1) * SPRITE.cell / SPRITE.w, (row + 1) * SPRITE.cell / SPRITE.h
    local size = 300
    local x0, y0 = cx - size / 2, cy - size / 2

    if SPRITE.mode == 'drawlist' then
        local ok, err = pcall(function()
            dl:AddImage(SPRITE.id, { x0, y0 }, { x0 + size, y0 + size }, { u0, v0 }, { u1, v1 }, ucol(1, 1, 1, fade))
        end)
        if ok then return true end
        SPRITE.err, SPRITE.mode = 'AddImage failed: ' .. tostring(err), 'window'   -- try a transparent image window instead
    end

    -- a borderless, transparent window holding imgui.Image
    local ok, err = pcall(function()
        imgui.SetNextWindowPos({ x0, y0 })
        imgui.SetNextWindowSize({ size + 8, size + 8 })
        if imgui.Begin('##rt_sprite', true, 5103) then
            imgui.Image(SPRITE.id, { size, size }, { u0, v0 }, { u1, v1 }, { 1, 1, 1, fade }, { 0, 0, 0, 0 })
        end
        imgui.End()
    end)
    if not ok then
        SPRITE.err, SPRITE.state = 'Image window failed: ' .. tostring(err), 'failed'
        return false
    end
    return true
end

local function draw_party(dl, W, H, t)
    local fade = math.min(1, t / 0.35, (celebrate.dur - t) / 0.9)
    if fade <= 0 then return end

    local beat = t * 7.0
    local cx = W * 0.5 + math.sin(t * 1.6) * 60
    local hop = math.abs(math.sin(beat)) * 34
    local cy = H * 0.60 - hop
    local sway = math.sin(beat) * 0.12
    local R = 38

    -- confetti burst (deterministic per particle, so no state to keep)
    for i = 1, 46 do
        local ang = (i * 2.399) % (math.pi * 2)
        local spd = 90 + (i * 37) % 170
        local px = cx + math.cos(ang) * spd * t
        local py = (H * 0.55) - math.sin(ang) * spd * t * 0.9 + 140 * t * t
        local c = CONFETTI[(i % #CONFETTI) + 1]
        local sz = 3 + (i % 3)
        local spin = t * 5 + i
        dl:AddRectFilled({ px - sz, py - sz * 0.6 * (0.5 + 0.5 * math.sin(spin)) }, { px + sz, py + sz * 0.6 * (0.5 + 0.5 * math.sin(spin)) },
            ucol(c[1], c[2], c[3], fade))
    end

    -- shadow
    dl:AddCircleFilled({ cx, H * 0.60 + R + 22 }, R * (0.9 - hop / 160), ucol(0, 0, 0, 0.25 * fade), 24)

    if not draw_sprite(dl, cx, cy - 75, fade, t) then
      -- legs (alternate stepping)
      local step = math.sin(beat)
      dl:AddCircleFilled({ cx - 16, cy + R - 2 + math.max(0, step) * 8 }, 9, ucol(0.10, 0.45, 0.55, fade), 16)
      dl:AddCircleFilled({ cx + 16, cy + R - 2 + math.max(0, -step) * 8 }, 9, ucol(0.10, 0.45, 0.55, fade), 16)

      -- arms waving up and down
      local wave = math.sin(beat * 1.0)
      dl:AddLine({ cx - R + 4, cy + 4 }, { cx - R - 22, cy - 22 - wave * 16 }, ucol(0.10, 0.45, 0.55, fade), 6)
      dl:AddLine({ cx + R - 4, cy + 4 }, { cx + R + 22, cy - 22 + wave * 16 }, ucol(0.10, 0.45, 0.55, fade), 6)
      dl:AddCircleFilled({ cx - R - 22, cy - 22 - wave * 16 }, 6, ucol(0.95, 0.98, 1.0, fade), 12)
      dl:AddCircleFilled({ cx + R + 22, cy - 22 + wave * 16 }, 6, ucol(0.95, 0.98, 1.0, fade), 12)

      -- body + belly
      dl:AddCircleFilled({ cx, cy }, R, ucol(0.20, 0.70, 0.78, fade), 32)
      dl:AddCircleFilled({ cx, cy + 10 }, R * 0.62, ucol(0.75, 0.95, 0.95, fade), 28)

      -- happy closed eyes (^ ^) and a big smile
      local ex = 14
      local ey = cy - 8
      for _, sx in ipairs({ -1, 1 }) do
          dl:AddLine({ cx + sx * ex - 6, ey + 3 }, { cx + sx * ex, ey - 4 }, ucol(0.05, 0.15, 0.2, fade), 3)
          dl:AddLine({ cx + sx * ex, ey - 4 }, { cx + sx * ex + 6, ey + 3 }, ucol(0.05, 0.15, 0.2, fade), 3)
      end
      local prev
      for i = 0, 8 do
          local a = math.pi * (0.1 + 0.8 * i / 8)
          local pt = { cx + math.cos(a) * 12, cy + 4 + math.sin(a) * 9 }
          if prev then dl:AddLine(prev, pt, ucol(0.05, 0.15, 0.2, fade), 3) end
          prev = pt
      end
      dl:AddCircleFilled({ cx - 24, cy + 4 }, 5, ucol(1.0, 0.55, 0.55, 0.55 * fade), 12)
      dl:AddCircleFilled({ cx + 24, cy + 4 }, 5, ucol(1.0, 0.55, 0.55, 0.55 * fade), 12)

      -- party hat that tips with the beat
      local hx, hy = cx + sway * 60, cy - R + 2
      dl:AddTriangleFilled({ hx - 16, hy }, { hx + 16, hy }, { hx + sway * 40, hy - 46 }, ucol(1.0, 0.82, 0.30, fade))
      dl:AddLine({ hx - 9, hy - 16 }, { hx + 9, hy - 16 }, ucol(0.9, 0.3, 0.4, fade), 4)
      dl:AddCircleFilled({ hx + sway * 40, hy - 48 }, 6, ucol(1, 1, 1, fade), 12)

    end

    -- text
    local pulse_c = lerp_col(GOLD, WHITE, 0.5 + 0.5 * math.sin(t * 8))
    local msg = 'STAGE COMPLETE!'
    dl:AddText({ cx - 58 + 1, H * 0.60 + R + 50 + 1 }, ucol(0, 0, 0, fade), msg)
    dl:AddText({ cx - 58, H * 0.60 + R + 50 }, ucol(pulse_c[1], pulse_c[2], pulse_c[3], fade), msg)
    dl:AddText({ cx - 58, H * 0.60 + R + 50 }, ucol(pulse_c[1], pulse_c[2], pulse_c[3], fade), msg) -- doubled for a bold look
    if celebrate.name ~= '' then
        dl:AddText({ cx - (#celebrate.name * 3.5), H * 0.60 + R + 70 }, ucol(1, 1, 1, 0.9 * fade), celebrate.name)
    end
end

local function screen_size()
    local ok, w, h = pcall(function()
        local ds = imgui.GetIO().DisplaySize
        return ds.x or ds[1], ds.y or ds[2]
    end)
    if ok and w and h and w > 0 and h > 0 then return w, h end
    return 1280, 720
end

ashita.events.register('d3d_present', 'rt_party', function()
    if celebrate.broken or cfg.party == false then return end
    local t = os.clock() - celebrate.t0
    if celebrate.t0 == 0 or t < 0 or t > celebrate.dur then return end

    local ok, err = pcall(function()
        local W, H = screen_size()
        local dl = imgui.GetForegroundDrawList()
        draw_party(dl, W, H, t)
    end)
    if not ok then
        -- Never spam errors every frame: log once, turn the animation off, keep the on-screen banner.
        celebrate.broken = true
        log_error('error', 'celebration', err)
        say('Celebration animation is not supported on this Ashita build, so it was turned off. The STAGE COMPLETE! banner still shows.')
    end
end)

ashita.events.register('d3d_present', 'rt_present', function()
    if not ui.open[1] then return end

    -- The window border flashes when the tracked trial is finished.
    local active = find_trial(cfg.active)
    local border = GOLD
    if active and active.done then border = lerp_col(GOLD, WHITE, pulse(5)) end

    local ncol, nvar = push_theme(border)
    imgui.SetNextWindowSize({ 520, 380 }, ImGuiCond_FirstUseEver)
    if imgui.SetNextWindowSizeConstraints then pcall(imgui.SetNextWindowSizeConstraints, { 300, 160 }, { 4000, 4000 }) end

    if imgui.Begin("Vana'diel Trial Log##rematracker", ui.open) then
        -- Always reach imgui.End(), even if drawing fails.
        imgui.PushTextWrapPos(0)    -- wrap every line at the window edge, so resizing never pushes text off screen
        local ok, err = xpcall(draw_body, debug.traceback)
        imgui.PopTextWrapPos()
        if not ok then
            log_error('error', 'ui', err)
            if not repairing then
                repairing = true
                pcall(repair)
                repairing = false
            end
        end
    end
    imgui.End()

    imgui.PopStyleVar(nvar)
    imgui.PopStyleColor(ncol)
end)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
settings.register('settings', 'rt_settings_update', safe('settings', function(s)
    if s then cfg = s end
    repair()
    mg_reload()
    settings.save()
end))

ashita.events.register('unload', 'rt_unload', function()
    cfg.visible = ui.open[1]
    settings.save()
end)
