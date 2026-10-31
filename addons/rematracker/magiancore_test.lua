--[[
    magiancore_test.lua - offline tests for magiancore.lua.
    Run outside the game:   lua magiancore_test.lua
    Run inside the game:    /rt selftest
]]--

local core = require('magiancore')

local M = {}

function M.run(out)
    out = out or print
    local passed, failed = 0, 0

    local function check(name, cond, detail)
        if cond then
            passed = passed + 1
        else
            failed = failed + 1
            out(('FAIL: %s%s'):format(name, detail and (' -> ' .. tostring(detail)) or ''))
        end
    end
    local function eq(name, got, want) check(name, got == want, ('got %s, want %s'):format(tostring(got), tostring(want))) end

    -- Reference bit reader with the same convention the Ashita decoder uses for these fields:
    -- bit n of the byte stream is bit (n % 8) of byte floor(n / 8), counted from the least significant bit.
    local function unpackBe(bytes, offset, length)
        local v = 0
        for i = 0, length - 1 do
            local bitIndex = offset + i
            local byte = bytes[math.floor(bitIndex / 8) + 1]
            local bit = math.floor(byte / 2 ^ (bitIndex % 8)) % 2
            v = v + bit * 2 ^ i
        end
        return v
    end

    -- Build 24 bytes of exdata exactly as the server lays them out.
    local function makeExtra(opts)
        local b = { opts.kind or 2, opts.flags or 0x43 }
        for i = 1, 4 do
            local a = (opts.augments or {})[i]
            local v = a and (a[1] + a[2] * 2048) or 0
            b[#b + 1] = v % 256
            b[#b + 1] = math.floor(v / 256)
        end
        local t = (opts.trial or 0) + (opts.completed and 32768 or 0)
        b[#b + 1] = t % 256
        b[#b + 1] = math.floor(t / 256)
        for _ = 1, 12 do b[#b + 1] = 0 end
        return b
    end

    ---------------------------------------------------------------- packing
    do
        local packed = core.packTrial(3, 2)
        eq('packTrial', packed, 3 * 65536 + 2)
        local id, prog = core.unpackTrial(packed)
        eq('unpackTrial id', id, 3); eq('unpackTrial progress', prog, 2)
        local id2, prog2 = core.unpackTrial(core.packTrial(32767, 65535))
        eq('max id', id2, 32767); eq('max progress', prog2, 65535)

        eq('packPair', core.packPair(5, 4), 5 + 4 * 65536)
        local lo, hi = core.unpackPair(core.packPair(1234, 4321))
        eq('unpackPair lo', lo, 1234); eq('unpackPair hi', hi, 4321)

        -- three active trials: 2, 3 in the first word, 4 alone in the second
        local ids, ok = core.unpackActive({ core.packPair(2, 3), core.packPair(4, 0), 0, 0, 0 }, 3)
        eq('active count', #ids, 3); check('active count matches', ok)
        eq('active[1]', ids[1], 2); eq('active[2]', ids[2], 3); eq('active[3]', ids[3], 4)
        local _, ok2 = core.unpackActive({ core.packPair(2, 3), 0, 0, 0, 0 }, 3)
        check('count mismatch detected', not ok2)
        local ten = core.unpackActive({ core.packPair(1, 2), core.packPair(3, 4), core.packPair(5, 6), core.packPair(7, 8), core.packPair(9, 10) }, 10)
        eq('ten slots', #ten, 10)
    end

    ---------------------------------------------------------------- rounding
    do
        eq('3 * 0.5 -> 2', core.scaledCount(3, 0.5), 2)
        eq('4 * 0.5 -> 2', core.scaledCount(4, 0.5), 2)
        eq('1 * 0.5 -> 1 (never below 1)', core.scaledCount(1, 0.5), 1)
        eq('5 * 0.5 -> 3', core.scaledCount(5, 0.5), 3)
        eq('10 * 0.5 -> 5', core.scaledCount(10, 0.5), 5)
        eq('300 * 0.5 -> 150', core.scaledCount(300, 0.5), 150)
        eq('10000 * 0.5 -> 5000', core.scaledCount(10000, 0.5), 5000)
        eq('rate 1 leaves counts alone', core.scaledCount(3, 1.0), 3)
        eq('zero stays zero', core.scaledCount(0, 0.5), 0)
        eq('negative stays negative', core.scaledCount(-4, 0.5), -4)
        eq('default rate is 0.5', core.scaledCount(3), 2)
    end

    ---------------------------------------------------------------- item decoding
    do
        local plain = core.decodeExtra(makeExtra({ kind = 2, flags = 0x03 }))
        check('standard augmented item has no trial', plain.augmented and not plain.hasTrial)

        local trial = core.decodeExtra(makeExtra({ trial = 2, augments = { { 25, 2 } } }))
        check('trial flag', trial.hasTrial)
        eq('trial id', trial.trialId, 2)
        check('not completed', trial.completed == false)
        eq('one augment', #trial.augments, 1)
        eq('augment id', trial.augments[1].id, 25); eq('augment value', trial.augments[1].value, 2)

        local done = core.decodeExtra(makeExtra({ trial = 4, completed = true }))
        eq('completed trial id', done.trialId, 4); check('completion bit', done.completed == true)

        local big = core.decodeExtra(makeExtra({ trial = 32767, completed = true }))
        eq('15-bit id', big.trialId, 32767); check('completion bit with max id', big.completed == true)

        local bundled = core.decodeExtra(makeExtra({ kind = 3, flags = 0x40, trial = 9 }))
        check('kind 3 is treated as augmented', bundled.augmented)
        eq('kind 3 with trial flag', bundled.trialId, 9)

        local notAug = core.decodeExtra(makeExtra({ kind = 1, flags = 0x40, trial = 9 }))
        check('kind 1 ignored', not notAug.augmented and notAug.trialId == nil)

        -- the manual decode and the Ashita-style bit reader must agree
        for _, case in ipairs({ { 2, false }, { 3, true }, { 1234, false }, { 32767, true } }) do
            local x = core.decodeExtra(makeExtra({ trial = case[1], completed = case[2], augments = { { 25, 4 }, { 300, 17 } } }), unpackBe)
            eq('unpack_be trial id ' .. case[1], x.trialId, case[1])
            check('unpack_be completion ' .. case[1], x.completed == case[2])
            check('no manual/unpack mismatch ' .. case[1], x.mismatch == nil, x.mismatch and 'mismatch' or nil)
            eq('unpack_be augment 2 id', x.augments[2].id, 300); eq('unpack_be augment 2 value', x.augments[2].value, 17)
        end
        check('short data rejected', core.decodeExtra({ 2, 0x43 }) == nil)
    end

    ---------------------------------------------------------------- four sample routes
    do
        local r2, r3, r4, r5 = core.routeInfo(2), core.routeInfo(3), core.routeInfo(4), core.routeInfo(5)
        eq('route 2 objective', r2.objective, 'Nocuous Weapon'); eq('route 2 previous', r2.previous, 0)
        eq('route 2 base', r2.baseCount, 3); eq('route 2 scaled', r2.estimatedTotal, 2)
        eq('route 2 required', r2.requiredItem, 'Peeler'); eq('route 2 reward', r2.rewardItem, 'Renegade')

        eq('route 3 objective', r3.objective, 'Black Triple Stars'); eq('route 3 previous', r3.previous, 2)
        eq('route 3 scaled', r3.estimatedTotal, 2); eq('route 3 required', r3.requiredItem, 'Renegade')
        eq('route 3 reward', r3.rewardItem, 'Renegade with Attack+3')

        eq('route 4 objective', r4.objective, 'Serra'); eq('route 4 previous', r4.previous, 3)
        eq('route 4 scaled', r4.estimatedTotal, 2)
        eq('route 4 required', r4.requiredItem, 'Renegade with Attack+3')
        eq('route 4 reward', r4.rewardItem, 'Renegade with Attack+5')

        eq('route 5 objective', r5.objective, 'Bugbear Strongman'); eq('route 5 previous', r5.previous, 4)
        eq('route 5 base', r5.baseCount, 4); eq('route 5 scaled', r5.estimatedTotal, 2)
        eq('route 5 required', r5.requiredItem, 'Renegade with Attack+5'); eq('route 5 reward', r5.rewardItem, 'Kartika')

        eq('chain 2->3', core.routes[3].previous, 2)
        eq('chain 3->4', core.routes[4].previous, 3)
        eq('chain 4->5', core.routes[5].previous, 4)

        -- encoded augment tuples must be decoded, not shown as raw numbers
        eq('augment {25,2}', core.describeAugment({ 25, 2 }), 'Attack+3')
        eq('augment {25,4}', core.describeAugment({ 25, 4 }), 'Attack+5')
        check('unknown augment labelled', core.describeAugment({ 99, 1 }):find('not decoded') ~= nil)
        check('unknown route', core.routeInfo(99999) == nil)

        -- a different rate rescales the estimate (rate is configuration, not a constant)
        eq('rate 1.0 estimate', core.routeInfo(5, 1.0).estimatedTotal, 4)
    end

    ---------------------------------------------------------------- provenance and the confirmed total
    do
        local s = core.newState()
        core.onMoogleList(s, { 2 }, 1000)
        local v = core.view(s, 2, 1000)
        eq('estimate total before the Moogle answers', v.total, 2); eq('estimate label', v.totalSrc, 'estimate')
        eq('progress unknown (not zero)', v.progress, nil); eq('progress label', v.progressLabel, 'unknown')
        eq('reward claimed is unknown', v.rewardClaimed, nil)

        -- Moogle confirms a total of 3: used as-is, NOT scaled again, and the estimate mismatch is recorded
        check('status accepted', core.onTrialStatus(s, 2, 3, 1, 0, 0, 1010))
        v = core.view(s, 2, 1010)
        eq('confirmed total wins', v.total, 3); eq('confirmed label', v.totalLabel, 'server-confirmed')
        eq('progress confirmed', v.progress, 1); eq('remaining derived', v.remaining, 2)
        eq('estimate mismatch remembered', v.estimateMismatch, 2)

        check('bad total rejected', select(1, core.onTrialStatus(s, 2, 0, 0, 0, 0, 1011)) == false)
        check('progress above total rejected', select(1, core.onTrialStatus(s, 2, 3, 4, 0, 0, 1011)) == false)
        eq('rejected status left state alone', core.view(s, 2, 1011).progress, 1)

        -- a confirmed value turns stale with time, without changing the number
        v = core.view(s, 2, 1010 + core.staleAfter + 1)
        eq('stale label', v.totalLabel, 'stale'); eq('stale keeps value', v.total, 3)
    end

    ---------------------------------------------------------------- progress messages, duplicates, completion
    do
        local s = core.newState()
        core.onMoogleList(s, { 3 }, 100)                -- estimate total 2
        check('first 583 applied', core.onProgressMessage(s, 3, 1, 110))
        local v = core.view(s, 3, 110)
        eq('remaining', v.remaining, 1); eq('progress = total - remaining', v.progress, 1)
        eq('estimate-based progress is labelled', v.progressSrc, 'estimate')

        local again, why = core.onProgressMessage(s, 3, 1, 111)
        check('duplicate ignored', again == false and why == 'duplicate')
        eq('duplicate counted', s.dupes, 1)
        eq('progress not double counted', core.view(s, 3, 111).progress, 1)

        check('584 applied', core.onCompleteMessage(s, 3, 120))
        v = core.view(s, 3, 120)
        check('completed', v.completed == true); eq('completed from server', v.completedSrc, 'confirmed')
        eq('remaining 0', v.remaining, 0); eq('progress = total', v.progress, 2)
        local d2, why2 = core.onCompleteMessage(s, 3, 121)
        check('duplicate 584 ignored', d2 == false and why2 == 'duplicate')
        eq('reward still unknown after completion', v.rewardClaimed, nil)

        -- confirmed total + remaining gives confirmed progress
        local s2 = core.newState()
        core.onTrialStatus(s2, 5, 2, 0, 0, 0, 200)
        core.onProgressMessage(s2, 5, 1, 210)
        local v2 = core.view(s2, 5, 210)
        eq('confirmed progress', v2.progress, 1); eq('confirmed progress src', v2.progressSrc, 'confirmed')

        -- remaining larger than the estimated total: the estimate was wrong, so progress becomes unknown
        local s3 = core.newState()
        core.onMoogleList(s3, { 2 }, 300)               -- estimate total 2
        core.onProgressMessage(s3, 2, 5, 310)
        local v3 = core.view(s3, 2, 310)
        eq('wrong estimate dropped', v3.total, nil); eq('progress unknown after wrong estimate', v3.progress, nil)
        eq('remaining still known', v3.remaining, 5); eq('estimate flagged wrong', v3.estimateWrong, 2)

        -- unknown trial id, remaining only: total and progress stay unknown
        local s4 = core.newState()
        core.onProgressMessage(s4, 777, 4, 400)
        local v4 = core.view(s4, 777, 400)
        eq('remaining only', v4.remaining, 4); eq('no total', v4.total, nil); eq('no progress', v4.progress, nil)
    end

    ---------------------------------------------------------------- multiple trials stay separate
    do
        local s = core.newState()
        core.onMoogleList(s, { 2, 3, 4 }, 500)
        core.onTrialStatus(s, 2, 3, 1, 0, 0, 501)
        core.onTrialStatus(s, 3, 5, 5, 0, 0, 502)
        core.onProgressMessage(s, 4, 1, 503)
        eq('trial 2 progress', core.view(s, 2, 503).progress, 1)
        check('trial 3 complete by status', core.view(s, 3, 503).completed == true)
        eq('trial 4 remaining', core.view(s, 4, 503).remaining, 1)
        check('trial 2 not complete', core.view(s, 2, 503).completed ~= true)
        eq('three trials tracked', #s.order, 3)

        -- a new Moogle list without trial 3 marks it inactive but keeps its data
        core.onMoogleList(s, { 2, 4 }, 600)
        check('trial 3 inactive', core.view(s, 3, 600).active == false)
        eq('trial 3 data kept', core.view(s, 3, 600).total, 5)
        check('trial 2 still active', core.view(s, 2, 600).active == true)
    end

    ---------------------------------------------------------------- duplicate weapon copies
    do
        local s = core.newState()
        core.syncItems(s, { [2] = {
            ['0:12'] = { itemId = 19332, name = 'Peeler', equipped = false },
            ['8:3']  = { itemId = 19332, name = 'Peeler', equipped = true },
        } }, 700)
        local v = core.view(s, 2, 700)
        eq('two copies tracked', #v.copies, 2)
        eq('worn copy preferred for the name', v.weaponName, 'Peeler')
        check('copy list names both', v.weaponNames:find('worn') ~= nil)

        -- one copy completed (completion bit) marks the trial complete from the item
        core.syncItems(s, { [2] = {
            ['0:12'] = { itemId = 19332, name = 'Peeler', equipped = false, completed = true },
        } }, 710)
        v = core.view(s, 2, 710)
        eq('copy removed after re-scan', #v.copies, 1)
        check('completion from item', v.completed == true and v.completedSrc == 'item')
    end

    ---------------------------------------------------------------- relogging must not reset unknown progress
    do
        local s = core.newState()
        core.onMoogleList(s, { 4 }, 800)
        core.onTrialStatus(s, 4, 2, 1, 0, 0, 810)
        local saved = { version = s.version, rate = s.rate, trials = s.trials, order = s.order }

        local s2 = core.load(saved)
        local v = core.view(s2, 4, 900)
        eq('progress survives relog', v.progress, 1); eq('total survives relog', v.total, 2)
        eq('now labelled cached', v.progressSrc, 'cached'); check('cached label says stale', v.progressLabel:find('stale') ~= nil)
        eq('no zero reset', v.remaining, 1)
        check('not active until the Moogle lists it again', v.active == false)
        eq('items are re-read, not trusted from disk', #v.copies, 0)

        core.onProgressMessage(s2, 4, 0, 950)           -- fresh confirmation upgrades the label again
        eq('re-confirmed remaining', core.view(s2, 4, 950).remainingSrc, 'confirmed')

        -- an estimate-only trial that was never confirmed stays an estimate after relog
        local s3 = core.newState()
        core.onMoogleList(s3, { 5 }, 1)
        local v3 = core.view(core.load({ trials = s3.trials, order = s3.order, rate = s3.rate }), 5, 2)
        eq('estimate stays estimate', v3.totalSrc, 'estimate'); eq('estimate value kept', v3.total, 2)

        check('garbage save ignored', core.load('nonsense') ~= nil)
        check('garbage trials ignored', core.load({ trials = { 'x', {} } }).order[1] == nil)
    end

    ---------------------------------------------------------------- Moogle detail replies
    do
        local s = core.newState()
        core.onRequiredItem(s, 2, 19332, 2881, 17, 600)
        local v = core.view(s, 2, 600)
        eq('required item id', v.requiredItemId, 19332); eq('trade item id', v.tradeItemId, 2881); eq('text number', v.textOffset, 17)
        core.onTrialStatus(s, 2, 10, 4, 2881, 0, 601)
        eq('detail stored', core.view(s, 2, 601).detail, 2881)
    end

    out(('magiancore tests: %d passed, %d failed'):format(passed, failed))
    return passed, failed
end

-- run directly with `lua magiancore_test.lua`
if arg and arg[0] and tostring(arg[0]):find('magiancore_test', 1, true) then
    local _, failed = M.run(print)
    os.exit(failed == 0 and 0 or 1)
end

return M
