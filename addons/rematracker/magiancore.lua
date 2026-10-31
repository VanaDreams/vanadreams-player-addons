--[[
    magiancore.lua - pure Magian trial logic (no Ashita dependencies, so it can be tested offline).

    Facts this module is built on (supplied from the VanaDreams staging server):
      * Server stores each trial as packed = (trialId << 16) + progress. That is server-only.
      * Messages: 583 = partial progress (trialId, remainingObjectives), 584 = objective complete (trialId).
      * Magian Moogle active-trial event: five packed pairs (low/high 16-bit trial ids), active count last.
      * Moogle trial-status update: required total, progress, objective detail, required element.
      * Requirement scaling: requiredCount = max(1, ceil(base * rate - 0.0001)), rate 0.500 on staging.
        The Moogle's confirmed total always wins and is never scaled again.
      * Item exdata carries the trial id and a completion bit, NOT the progress count.

    Every value carries a provenance so a tracker never presents a guess as server truth:
      'confirmed' - read from a server message/event this session
      'item'      - read from the item's own exdata (authoritative for completion only)
      'estimate'  - derived from bundled route data (scaled); replaced as soon as the server confirms
      'cached'    - was confirmed in an earlier session / before a relog; may be stale
      nil         - unknown (shown as "unknown", never as zero)
]]--

local core = {}

core.defaultRate    = 0.5
core.staleAfter     = 1800  -- seconds before a confirmed value is called stale
core.MSG_PROGRESS   = 583
core.MSG_COMPLETE   = 584

--------------------------------------------------------------------------------
-- Packing helpers
--------------------------------------------------------------------------------
function core.packTrial(id, progress)
    return id * 65536 + (progress % 65536)
end

function core.unpackTrial(packed)
    return math.floor(packed / 65536), packed % 65536
end

function core.packPair(lo, hi)
    return (lo or 0) + (hi or 0) * 65536
end

function core.unpackPair(v)
    return v % 65536, math.floor(v / 65536)
end

-- Five packed words + the server's active count -> list of trial ids. Second value: did the count match?
function core.unpackActive(words, count)
    local ids = {}
    for i = 1, 5 do
        local lo, hi = core.unpackPair(words[i] or 0)
        if lo ~= 0 then ids[#ids + 1] = lo end
        if hi ~= 0 then ids[#ids + 1] = hi end
    end
    return ids, (#ids == count)
end

--------------------------------------------------------------------------------
-- Requirement scaling
--------------------------------------------------------------------------------
function core.scaledCount(base, rate)
    if base <= 0 then return base end          -- zero / negative counts are left alone
    rate = rate or core.defaultRate
    return math.max(1, math.ceil(base * rate - 0.0001))
end

--------------------------------------------------------------------------------
-- Item exdata
--------------------------------------------------------------------------------
local function bitand(a, b)
    local r, bitv = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end

-- bytes: 1-based array of the 24 exdata bytes. unpackBe: optional ashita.bits.unpack_be-style function
-- (table, bitOffset, bitLength); when given it is trusted and the manual decode is only a cross-check.
function core.decodeExtra(bytes, unpackBe)
    if type(bytes) ~= 'table' or #bytes < 12 then return nil end
    local kind, flags = bytes[1], bytes[2]
    local out = { kind = kind, flags = flags, augmented = (kind == 2 or kind == 3), hasTrial = false, augments = {} }
    if not out.augmented then return out end

    out.hasTrial = bitand(flags, 0x40) ~= 0
    for i = 1, 4 do
        local v = (bytes[2 * i + 1] or 0) + (bytes[2 * i + 2] or 0) * 256
        local id, val = v % 2048, math.floor(v / 2048)
        if unpackBe then
            id, val = unpackBe(bytes, 16 * i, 11), unpackBe(bytes, 16 * i + 11, 5)
        end
        if id ~= 0 then out.augments[#out.augments + 1] = { id = id, value = val } end
    end

    if out.hasTrial then
        local v = bytes[11] + bytes[12] * 256
        local id, done = v % 32768, v >= 32768
        if unpackBe then
            local uid, udone = unpackBe(bytes, 80, 15), unpackBe(bytes, 95, 1) == 1
            if uid ~= id or udone ~= done then out.mismatch = { manualId = id, manualDone = done } end
            id, done = uid, udone
        end
        if id > 0 then out.trialId, out.completed = id, done end
    end
    return out
end

--------------------------------------------------------------------------------
-- Bundled route data (the four verified routes). Used ONLY as a labelled estimate.
--------------------------------------------------------------------------------
core.augmentNames = {
    ['25:2'] = 'Attack+3',
    ['25:4'] = 'Attack+5',
}

function core.describeAugment(tuple)
    local key = tuple[1] .. ':' .. tuple[2]
    return core.augmentNames[key] or ('augment %d:%d (not decoded)'):format(tuple[1], tuple[2])
end

core.routes = {
    [2] = { objective = 'Nocuous Weapon',    previous = 0, baseCount = 3,
            required = { item = 'Peeler' },                         reward = { item = 'Renegade' } },
    [3] = { objective = 'Black Triple Stars', previous = 2, baseCount = 3,
            required = { item = 'Renegade' },                       reward = { item = 'Renegade', augments = { { 25, 2 } } } },
    [4] = { objective = 'Serra',             previous = 3, baseCount = 3,
            required = { item = 'Renegade', augments = { { 25, 2 } } }, reward = { item = 'Renegade', augments = { { 25, 4 } } } },
    [5] = { objective = 'Bugbear Strongman', previous = 4, baseCount = 4,
            required = { item = 'Renegade', augments = { { 25, 4 } } }, reward = { item = 'Kartika' } },
}

local function describeItem(spec)
    if not spec then return nil end
    local s = spec.item
    if spec.augments then
        local parts = {}
        for _, a in ipairs(spec.augments) do parts[#parts + 1] = core.describeAugment(a) end
        s = s .. ' with ' .. table.concat(parts, ', ')
    end
    return s
end

function core.routeInfo(id, rate)
    local r = core.routes[id]
    if not r then return nil end
    return {
        objective = r.objective, previous = r.previous, baseCount = r.baseCount,
        estimatedTotal = core.scaledCount(r.baseCount, rate),
        requiredItem = describeItem(r.required), rewardItem = describeItem(r.reward),
    }
end

--------------------------------------------------------------------------------
-- State: one record per trial id, kept separate from every other trial.
--------------------------------------------------------------------------------
function core.newState(opts)
    return { version = 1, rate = (opts and opts.rate) or core.defaultRate, trials = {}, order = {}, active = {}, dupes = 0 }
end

local function key(id) return tostring(id) end

local function getTrial(state, id, now)
    local k = key(id)
    local t = state.trials[k]
    if not t then
        t = { id = id, copies = {}, firstSeen = now }
        state.trials[k] = t
        state.order[#state.order + 1] = id
        local route = core.routeInfo(id, state.rate)
        if route then
            t.total, t.totalSrc = route.estimatedTotal, 'estimate'
        end
    end
    return t
end

-- Rebuild a state from saved data (defensive) and mark everything as cached: it may be stale after a relog.
function core.load(saved, opts)
    local state = core.newState(opts)
    if type(saved) == 'table' and type(saved.trials) == 'table' then
        for _, t in pairs(saved.trials) do
            if type(t) == 'table' and type(t.id) == 'number' then
                t.copies = {}                 -- items are re-read from the inventory, never trusted from disk
                state.trials[key(t.id)] = t
                state.order[#state.order + 1] = t.id
            end
        end
        table.sort(state.order)
        if type(saved.rate) == 'number' and saved.rate > 0 then state.rate = saved.rate end
    end
    if opts and opts.rate then state.rate = opts.rate end
    core.markStale(state)
    return state
end

-- Relog / zone / new session: keep every number, but stop claiming it is live.
function core.markStale(state)
    state.active = {}
    for _, t in pairs(state.trials) do
        t.active = false
        for _, f in ipairs({ 'total', 'progress', 'remaining', 'completed' }) do
            if t[f .. 'Src'] == 'confirmed' then t[f .. 'Src'] = 'cached' end
        end
        t.lastMsg = nil
    end
end

local function setConfirmed(t, field, value, now, src)
    t[field], t[field .. 'Src'], t[field .. 'At'] = value, src or 'confirmed', now
end

local function reconcileProgress(t, now)
    -- progress = required total - remaining, but only when both are known
    if t.remaining ~= nil and t.total ~= nil then
        local p = t.total - t.remaining
        if p < 0 then
            -- remaining is larger than the total we believed: the total was wrong (rules may have changed)
            if t.totalSrc == 'estimate' then
                t.estimateWrong, t.total, t.totalSrc, t.progress, t.progressSrc = t.total, nil, nil, nil, nil
                return
            end
            p = 0
        end
        t.progress = p
        local weak = (t.totalSrc ~= 'confirmed') or (t.remainingSrc ~= 'confirmed')
        t.progressSrc = weak and ((t.totalSrc == 'estimate') and 'estimate' or 'cached') or 'confirmed'
        t.progressAt = now
    end
end

-- Magian Moogle opened with the trial log: the authoritative list of active trials.
function core.onMoogleList(state, ids, now)
    local listed = {}
    for _, id in ipairs(ids) do listed[key(id)] = true end
    for _, id in ipairs(ids) do
        local t = getTrial(state, id, now)
        t.active, t.listedAt = true, now
    end
    for k, t in pairs(state.trials) do
        if not listed[k] then t.active = false end
    end
    state.active = {}
    for i, id in ipairs(ids) do state.active[i] = id end
    return true
end

-- Moogle trial-status update: required total, progress, objective detail, required element.
function core.onTrialStatus(state, id, total, progress, detail, element, now)
    if type(total) ~= 'number' or total < 1 or type(progress) ~= 'number' or progress < 0 or progress > total then
        return false, 'invalid'
    end
    local t = getTrial(state, id, now)
    if t.totalSrc == 'estimate' and t.total ~= total then t.estimateMismatch = t.total end
    setConfirmed(t, 'total', total, now)                  -- confirmed total is used as-is, never rescaled
    setConfirmed(t, 'progress', progress, now)
    setConfirmed(t, 'remaining', total - progress, now)
    t.detail, t.element, t.statusAt = detail, element, now
    if progress >= total then setConfirmed(t, 'completed', true, now) end
    return true
end

-- Moogle "what does this trial need" reply: required item, trade item, objective text number.
function core.onRequiredItem(state, id, requiredItemId, tradeItemId, textOffset, now)
    local t = getTrial(state, id, now)
    t.requiredItemId, t.tradeItemId, t.textOffset, t.infoAt = requiredItemId, tradeItemId, textOffset, now
    return true
end

-- Message 583: partial progress. Idempotent: the same message twice changes nothing.
function core.onProgressMessage(state, id, remaining, now)
    local t = getTrial(state, id, now)
    local sig = 'p:' .. remaining
    if t.lastMsg == sig then
        state.dupes = state.dupes + 1
        return false, 'duplicate'
    end
    t.lastMsg = sig
    setConfirmed(t, 'remaining', remaining, now)
    if t.completed and t.completedSrc ~= 'item' then t.completed, t.completedSrc = false, nil end
    reconcileProgress(t, now)
    return true
end

-- Message 584: objective complete (the reward is NOT yet claimed).
function core.onCompleteMessage(state, id, now)
    local t = getTrial(state, id, now)
    if t.lastMsg == 'c' then
        state.dupes = state.dupes + 1
        return false, 'duplicate'
    end
    t.lastMsg = 'c'
    setConfirmed(t, 'completed', true, now)
    setConfirmed(t, 'remaining', 0, now)
    if t.total ~= nil then
        t.progress, t.progressSrc, t.progressAt = t.total, (t.totalSrc == 'confirmed') and 'confirmed' or 'estimate', now
    end
    return true
end

-- Replace the known copies of items carrying trials with exactly what the inventory shows right now.
-- seen: { [trialId] = { [copyKey] = { itemId=, name=, equipped=, completed= } } }
function core.syncItems(state, seen, now)
    for _, t in pairs(state.trials) do t.copies = {} end
    for id, copies in pairs(seen) do
        local t = getTrial(state, id, now)
        for copyKey, info in pairs(copies) do
            t.copies[copyKey] = info
            if info.completed and t.completed ~= true then
                t.completed, t.completedSrc, t.completedAt = true, 'item', now
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------
-- Turn a provenance into text. Old confirmed values become "stale" without losing the number.
function core.provenance(src, at, now)
    if src == nil then return 'unknown' end
    if src == 'confirmed' then
        if at and now and (now - at) > core.staleAfter then return 'stale' end
        return 'server-confirmed'
    end
    if src == 'cached' then return 'cached (stale)' end
    if src == 'item' then return 'from item' end
    return src
end

function core.view(state, id, now)
    local t = state.trials[key(id)]
    if not t then return nil end
    local route = core.routeInfo(id, state.rate)
    local copies, equipped = {}, nil
    for copyKey, info in pairs(t.copies) do
        copies[#copies + 1] = { key = copyKey, name = info.name, equipped = info.equipped, completed = info.completed, loc = info.loc }
        if info.equipped then equipped = info.name end
    end
    table.sort(copies, function(a, b) return a.key < b.key end)
    local names = {}
    for _, c in ipairs(copies) do names[#names + 1] = (c.name or '?') .. (c.equipped and ' (worn)' or '') end

    return {
        id = id, active = t.active, route = route, objective = route and route.objective or nil,
        total = t.total, totalSrc = t.totalSrc, totalLabel = core.provenance(t.totalSrc, t.totalAt, now),
        progress = t.progress, progressSrc = t.progressSrc, progressLabel = core.provenance(t.progressSrc, t.progressAt, now),
        remaining = t.remaining, remainingSrc = t.remainingSrc, remainingLabel = core.provenance(t.remainingSrc, t.remainingAt, now),
        completed = t.completed, completedSrc = t.completedSrc, completedLabel = core.provenance(t.completedSrc, t.completedAt, now),
        rewardClaimed = nil,                      -- no client signal exists for this: always "unknown"
        estimateMismatch = t.estimateMismatch, estimateWrong = t.estimateWrong,
        detail = t.detail, element = t.element, requiredItemId = t.requiredItemId, tradeItemId = t.tradeItemId,
        textOffset = t.textOffset, copies = copies, weaponNames = (#names > 0) and table.concat(names, ', ') or nil,
        weaponName = equipped or (copies[1] and copies[1].name) or nil,
    }
end

return core
