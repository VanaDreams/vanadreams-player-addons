-- roehelper.lua – RoE Helper (Ashita v4), based on commandobill/roe
-- Author: Original by Cair, ported by Commandobill
-- Description: Create and manage RoE profiles with configurable settings

addon.name    = 'roehelper'
addon.version = '1.12.3-lite'
addon.author  = 'Original by Cair, ported by Commandobill; UI by Adamantking'
addon.desc    = 'Create and activate RoE profiles'
addon.link    = 'https://github.com/commandobill/roe'

local config    = require('settings')
local chat      = require('chat')
local struct    = require('struct')
local bit       = require('bit')
local coroutine = coroutine
local roe_mapping = require('roe_mapping')
local roe_info = require('roe_info')      -- April 2026 list: objective count and rewards per RoE

-- Mute: switches off the addon's own messages and its "do that again" box. Replies to a command you typed are still shown.
local MUTE = { on = false, cmd = false }

-- Print error message
local function eprint(msg) if MUTE.on and not MUTE.cmd then return end print(chat.header('roehelper') .. chat.error(msg)) end

-- Print normal message
local function nprint(msg) if MUTE.on and not MUTE.cmd then return end print(chat.header('roehelper') .. chat.message(msg)) end

-- Fuzzy string matching function using Ashita v4 string utilities
local function fuzzy_match(search_term, target_string)
    -- Normalize strings: lowercase, remove punctuation, clean whitespace
    search_term = search_term:lower():gsub('[%p]+', ' '):clean()
    target_string = target_string:lower():gsub('[%p]+', ' '):clean()
    
    -- Split into words using Ashita's split function
    local search_words = search_term:split(' ')
    local target_words = target_string:split(' ')
    
    -- Debug: Print detailed matching info for crystal objectives
    if target_string:find('crystal') and search_term:find('crystal') then
        nprint(('Debug fuzzy_match: search="%s" target="%s"'):format(search_term, target_string))
        nprint(('Debug: search_words=%s'):format(table.concat(search_words, ',')))
        nprint(('Debug: target_words=%s'):format(table.concat(target_words, ',')))
    end
    
    -- Check if all search words are found in target using exact word matches
    local matches = 0
    local total_possible_matches = 0
    
    for _, search_word in ipairs(search_words) do
        if search_word:len() > 0 then  -- Skip empty words
            total_possible_matches = total_possible_matches + 1
            for _, target_word in ipairs(target_words) do
                -- Use exact word match instead of contains for better precision
                if target_word == search_word then
                    matches = matches + 1
                    break
                end
            end
        end
    end
    
    -- Calculate final score
    local final_score
    if matches == total_possible_matches then
        -- All search words found - this is a perfect match regardless of extra words
        final_score = 1.0
    else
        -- Partial match - score based on percentage of search words found
        final_score = matches / total_possible_matches
    end
    
    -- Debug: Print score for crystal objectives
    if target_string:find('crystal') and search_term:find('crystal') then
        nprint(('Debug: matches=%d/%d, final_score=%.2f'):format(matches, total_possible_matches, final_score))
    end
    
    return final_score
end

-- Find RoE objectives by name using fuzzy matching
local function find_roe_by_name(search_term, require_all_words)
    local results = {}
    local min_score = require_all_words and 1.0 or 0.5  -- Require 100% match for bulk operations
    
    -- Debug: Print search term and min_score
    nprint(('Debug: Searching for "%s" with min_score %.1f'):format(search_term, min_score))
    
    for id, name in pairs(roe_mapping) do
        local score = fuzzy_match(search_term, name)
        if score >= min_score then
            results[#results + 1] = {
                id = id,
                name = name,
                score = score
            }
            -- Debug: Print when we add a result
            if name:find('Crystal') then
                nprint(('Debug: Added result %d: "%s" (score=%.2f)'):format(id, name, score))
            end
        end
    end
    
    -- Debug: Print number of results found
    nprint(('Debug: Found %d results'):format(#results))
    
    -- Sort by score (highest first)
    table.sort(results, function(a, b) return a.score > b.score end)
    
    return results
end

-- Send RoE packet with a given packet ID and objective ID
local function send_roe_packet(pid, roe_id)
    local pkt = struct.pack('bbbbHbb', pid, 0x04, 0x00, 0x00, roe_id, 0x00, 0x00):totable()
    AshitaCore:GetPacketManager():AddOutgoingPacket(pid, pkt)
end


-- Create a new set object with utility methods
local function _new_set(values)
    local self = {}
    if values then for _, v in pairs(values) do self[v] = true end end
    local mt = {}

    function mt.__index(t, k)
        if     k == 'add'          then return function(_, v) t[v] = true end
        elseif k == 'remove'       then return function(_, v) t[v] = nil end
        elseif k == 'contains'     then return function(_, v) return t[v] end
        elseif k == 'length'       then return function() local c = 0; for _ in pairs(t) do c = c + 1 end; return c end
        elseif k == 'keyset'       then return function() local r = S{}; for v in pairs(t) do r:add(v) end; return r end
        elseif k == 'update'       then return function(_, o) for v in pairs(o) do t[v] = true end end
        elseif k == 'diff'         then return function(_, o) local r = S{}; for v in pairs(t) do if not o[v] then r:add(v) end end; return r end
        elseif k == 'intersection' then return function(_, o) local r = S{}; for v in pairs(t) do if o[v] then r:add(v) end end; return r end
        elseif k == 'union'        then return function(_, o) local r = S{}; r:update(t); r:update(o); return r end
        elseif k == 'it'           then return function() local k; return function() k = next(t, k); return k end end
        end
    end

    return setmetatable(self, mt)
end

-- Global S constructor for sets
S = setmetatable({}, { __call = function(_, iter) return _new_set(iter) end })

-- Convert input into a Set object
local function as_set(value)
    if type(value) == 'string' then
        local arr = {}; for id in value:gmatch('%d+') do arr[#arr+1] = tonumber(id) end
        return S(arr)
    elseif type(value) == 'table' then
        if value.diff then return value end -- Already a Set
        local arr = {}
        for k, v in pairs(value) do
            if type(k) == 'number' and v == true then arr[#arr+1] = k
            elseif type(v) == 'number' then arr[#arr+1] = v end
        end
        return S(arr)
    end
    return S{}
end

-- Default configuration settings
local defaults = T{
    profiles      = { default = S{} },
    blacklist     = T{},
    clear         = true,
    clearprogress = false,
    clearall      = false,
    repeatables   = T{ 15, 117 },
    auto          = false,     -- auto mode: keep this zone's Conflict RoE and today's geode / -ite stone set
    mini          = false,     -- compact window
    grey_unimpl   = true,      -- categories window: grey out categories the server does not implement
    cats_off      = T{},       -- RoE categories ("Top/Sub") that auto mode must not turn on
    fight         = true,      -- auto mode: turn on the RoEs that match the monster you are fighting (Subjugation, kill, level, mission)
    drops         = true,      -- auto mode: turn on the Spoils RoE of an item a monster just dropped
    syncwin       = true,      -- open the Level Sync RoE window when you become level synced
    mute          = false,     -- mute: no chat messages from the addon (except replies to your commands) and no "do that again" box
    beginner      = false,     -- beginner mode: walks you through the Basics / Tutorial RoEs
}

-- State management
local roe = T{
    active    = S{},
    complete  = S{},
    max_count = 30,
    settings  = config.load(defaults)
}

-- "Conflict: <zone>" RoEs are repeatable, so the game's completed flag never counts for them
local function completed(id)
    if not roe.complete[id] then return false end
    local name = roe_mapping[id]
    if type(name) == 'string' and name:find('^Conflict:') then return false end
    return true
end

-- categories: the game's RoE book sections ("Tutorial/Basics", "Content/Dynamis"...)
local cats = require('roe_cats')
local function cat_of(id) local i = cats.of[id] return i and cats.list[i] or nil end
local function rn(id)                                   -- name with its category, for messages
    local n = roe_mapping[id] or ('#' .. id)
    local c = cat_of(id)
    return c and ('%s (%s)'):format(n, c) or n
end
local function cat_allowed(id)
    local c = cat_of(id)
    return not c or not (roe.settings.cats_off and roe.settings.cats_off[c])
end

-- Register settings update handler
config.register('settings', 'settings_update', function(s)
    if s then roe.settings = s end
    MUTE.on = roe.settings.mute == true
    config.save()
end)

-- Cancel a specific RoE objective
local function cancel_roe(id)
    id = tonumber(id)
    if not id or roe.settings.blacklist[id] or not roe.active[id] then return end
    send_roe_packet(0x10D, id)
end

-- Accept a specific RoE objective
local function accept_roe(id)
    id = tonumber(id)
    if not id or completed(id) or roe.active[id] then return end
    if id >= 4008 and id <= 4021 then return end
    send_roe_packet(0x10C, id)
end

-- Save current active RoE objectives as a profile
local function save_profile(name)
    if type(name) ~= 'string' then eprint('save: specify a profile name') return end
    name = name:lower()
    local list, n = {}, 0
    for id in pairs(roe.active) do n = n + 1; list[n] = id end
    roe.settings.profiles[name] = S(list)
    config.save()
    nprint(('saved %d objectives to profile %s'):format(n, name))
end

-- List all saved RoE profiles
local function list_profiles()
    nprint('Profiles: ' .. table.concat((function()
        local out = {}; for k in pairs(roe.settings.profiles) do out[#out+1] = k end
        table.sort(out); return out end)(), ', '))
end

-- Set and apply a saved profile of RoE objectives
local function set_profile(name)
    if type(name) ~= 'string' then eprint('set: specify a profile name') return end
    name = name:lower()
    local prof = as_set(roe.settings.profiles[name])
    if prof:length() == 0 then eprint(('set: profile "%s" does not exist or is empty'):format(name)) return end

    local have   = roe.active:keyset()
    local need   = prof:diff(have)
    local slots  = roe.max_count - roe.active:length()
    local remove = S{}

    if roe.settings.clearall then
        remove:update(have)
    elseif roe.settings.clear then
        for id, prog in pairs(roe.active) do
            if (need:length() - remove:length()) <= slots then break end
            if (prog == 0 or roe.settings.clearprogress) and not roe.settings.blacklist[id] then
                remove:add(id)
            end
        end
    end

    local remaining = need:length() - remove:length()
    if remaining > slots then
        eprint("not enough free ROE slots. Additional slots needed: " .. remaining - slots)
        return
    end

    for id in remove:it() do cancel_roe(id); coroutine.sleep(0.5) end
    for id in need:it()   do accept_roe(id); coroutine.sleep(0.5) end
    nprint(('loaded profile "%s"'):format(name))
end

-- Unset active objectives or those in a given profile
local function unset_profile(name)
    name = name and name:lower()
    if name and roe.settings.profiles[name] then
        local todo = roe.active:keyset():intersection(roe.settings.profiles[name])
        for id in todo:it() do cancel_roe(id); coroutine.sleep(0.5) end
        nprint(('unset profile "%s"'):format(name))
    elseif name then
        eprint(('unset: profile "%s" does not exist'):format(name))
    else
        nprint('clearing ROE objectives...')
        for id, prog in pairs(roe.active) do
            if prog == 0 or roe.settings.clearprogress then cancel_roe(id); coroutine.sleep(0.5) end
        end
        nprint('ROE objectives cleared...')
    end
end

-- Handle incoming RoE packets
ashita.events.register('packet_in','roe_in', function(e)
    if e.id == 0x111 then
        local was_known, old_active = roe.known, roe.active
        roe.active = S{}
        roe.known = true
            for i = 1, roe.max_count do
            local off   = 5 + ((i - 1) * 4)
            local word  = struct.unpack('I', e.data, off)   -- 32-bit LE
            local qid   = bit.band(word, 0xFFF)             -- lower 12 bits
            local prog  = bit.rshift(word, 12)              -- upper 20 bits
            if qid > 0 then
                roe.active[qid] = prog                      -- store progress %
            end
        end
        -- log the number of any RoE you just took yourself (RoEs added by this addon are already in
        -- roe.active, so they are not repeated; the first sync after login/reload is skipped)
        if was_known then
            for id in pairs(roe.active) do
                if old_active[id] == nil then
                    nprint(('RoE taken: #%d  %s   (repeatable: /roehelper repeat add %d)'):format(id, roe_mapping[id] and rn(id) or '?', id))
                end
            end
        end
    elseif e.id == 0x112 then
        local done = S{}
        local offset_val = struct.unpack('H', e.data, 133)
        for i = 0, 1023 do
            local byte = e.data:byte(5 + math.floor(i / 8))
            if bit.band(byte, bit.lshift(1, i % 8)) ~= 0 then
                done:add(i + offset_val * 1024)
            end
        end
        roe.complete:update(done)
    end
end)

local true_strings  = S{'true','t','y','yes','on'}
local false_strings = S{'false','f','n','no','off'}
local bool_strings  = true_strings:union(false_strings)

-- Handle toggle settings command
local function handle_setting(name, val)
    if type(name) ~= 'string' then eprint('settings: specify a setting name'); return end
    name = name:lower()
    if roe.settings[name] == nil then eprint(('settings: "%s" does not exist'):format(name)); return end
    if type(roe.settings[name]) ~= 'boolean' then eprint(('settings: "%s" is not a toggle'):format(name)); return end
    val = val and val:lower()
    if not val or not bool_strings:contains(val) then
        roe.settings[name] = not roe.settings[name]
    elseif true_strings:contains(val) then
        roe.settings[name] = true
    else
        roe.settings[name] = false
    end
    nprint(('setting "%s" is now %s'):format(name, tostring(roe.settings[name])))
    config.save()
end

-- Handle blacklist add/remove command
local function blacklist(action, id)
    action = action and action:lower()
    id = tonumber(id)
    if not (action and id) then eprint('blacklist usage: blacklist [add|remove] <id>'); return end
    if action == 'add' then
        roe.settings.blacklist[id] = true
        nprint(('quest %d added to blacklist'):format(id))
    elseif action == 'remove' then
        if id >= 4008 and id <= 4021 then return end
        roe.settings.blacklist[id] = nil
        nprint(('quest %d removed from blacklist'):format(id))
    else
        eprint('blacklist: first arg must be "add" or "remove"')
    end
    config.save()
end

-- Add a specific RoE objective by ID or name
local function add_roe(input)
    
    -- Try to parse as number first
    local id = tonumber(input)
    
    if id then
        -- Input is a number, treat as ID
        if completed(id) then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is already completed'):format(id, name))
            return 
        end
        if roe.active[id] then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is already active'):format(id, name))
            return 
        end
        if id >= 4008 and id <= 4021 then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) cannot be added (auto hourly objectives)'):format(id, name))
            return 
        end
        
        accept_roe(id)
        local name = roe_mapping[id] or "Unknown"
        nprint(('Added RoE objective %d: %s'):format(id, name))
    else
        -- Input is not a number, treat as name search
        local results = find_roe_by_name(input)
        
        if #results == 0 then
            eprint(('No RoE objectives found matching "%s"'):format(input))
            return
        elseif #results == 1 then
            local result = results[1]
            if completed(result.id) then 
                eprint(('RoE objective %d (%s) is already completed'):format(result.id, result.name))
                return 
            end
            if roe.active[result.id] then 
                eprint(('RoE objective %d (%s) is already active'):format(result.id, result.name))
                return 
            end
            if result.id >= 4008 and result.id <= 4021 then 
                eprint(('RoE objective %d (%s) cannot be added (restricted range)'):format(result.id, result.name))
                return 
            end
            
            accept_roe(result.id)
            nprint(('Added RoE objective %d: %s'):format(result.id, result.name))
        else
            -- Multiple matches found - check if there's a 100% match
            local perfect_match = nil
            for _, result in ipairs(results) do
                if result.score == 1.0 then
                    perfect_match = result
                    break
                end
            end
            
            if perfect_match then
                -- Use the perfect match automatically
                if completed(perfect_match.id) then 
                    eprint(('RoE objective %d (%s) is already completed'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                if roe.active[perfect_match.id] then 
                    eprint(('RoE objective %d (%s) is already active'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                if perfect_match.id >= 4008 and perfect_match.id <= 4021 then 
                    eprint(('RoE objective %d (%s) cannot be added (restricted range)'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                
                accept_roe(perfect_match.id)
                nprint(('Added RoE objective %d: %s'):format(perfect_match.id, perfect_match.name))
            else
                -- No perfect match, show multiple results
                eprint(('Multiple RoE objectives found matching "%s":'):format(input))
                for i = 1, math.min(5, #results) do  -- Show top 5 matches
                    local result = results[i]
                    nprint(('  %d: %s (%.0f%% match)'):format(result.id, result.name, result.score * 100))
                end
                if #results > 5 then
                    nprint(('  ... and %d more matches'):format(#results - 5))
                end
                eprint('Please be more specific or use the ID directly.')
            end
        end
    end
end

-- Remove a specific RoE objective by ID or name
local function rem_roe(input)
    -- Check if we have 0 active RoEs (status needs refresh)
    if roe.active:length() == 0 then
        eprint('No active RoE objectives detected. Please add an RoE objective to refresh the status.')
        return
    end
    
    -- Try to parse as number first
    local id = tonumber(input)
    
    if id then
        -- Input is a number, treat as ID
        if not roe.active[id] then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is not currently active'):format(id, name))
            return 
        end
        if roe.settings.blacklist[id] then
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is blacklisted and cannot be removed'):format(id, name))
            return 
        end
        
        cancel_roe(id)
        local name = roe_mapping[id] or "Unknown"
        nprint(('Removed RoE objective %d: %s'):format(id, name))
    else
        -- Input is not a number, treat as name search
        local results = find_roe_by_name(input)
        
        if #results == 0 then
            eprint(('No RoE objectives found matching "%s"'):format(input))
            return
        elseif #results == 1 then
            local result = results[1]
            if not roe.active[result.id] then 
                eprint(('RoE objective %d (%s) is not currently active'):format(result.id, result.name))
                return 
            end
            if roe.settings.blacklist[result.id] then
                eprint(('RoE objective %d (%s) is blacklisted and cannot be removed'):format(result.id, result.name))
                return 
            end
            
            cancel_roe(result.id)
            nprint(('Removed RoE objective %d: %s'):format(result.id, result.name))
        else
            -- Multiple matches found - check if there's a 100% match
            local perfect_match = nil
            for _, result in ipairs(results) do
                if result.score == 1.0 then
                    perfect_match = result
                    break
                end
            end
            
            if perfect_match then
                -- Use the perfect match automatically
                if not roe.active[perfect_match.id] then 
                    eprint(('RoE objective %d (%s) is not currently active'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                if roe.settings.blacklist[perfect_match.id] then
                    eprint(('RoE objective %d (%s) is blacklisted and cannot be removed'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                
                cancel_roe(perfect_match.id)
                nprint(('Removed RoE objective %d: %s'):format(perfect_match.id, perfect_match.name))
            else
                -- No perfect match, show multiple results
                eprint(('Multiple RoE objectives found matching "%s":'):format(input))
                for i = 1, math.min(5, #results) do  -- Show top 5 matches
                    local result = results[i]
                    local status = ""
                    if not roe.active[result.id] then
                        status = " (not active)"
                    elseif roe.settings.blacklist[result.id] then
                        status = " (blacklisted)"
                    end
                    nprint(('  %d: %s (%.0f%% match)%s'):format(result.id, result.name, result.score * 100, status))
                end
                if #results > 5 then
                    nprint(('  ... and %d more matches'):format(#results - 5))
                end
                eprint('Please be more specific or use the ID directly.')
            end
        end
    end
end

-- Add multiple RoE objectives by name using fuzzy matching
local function addall_roe(input)
    
    -- Only works with name search, not ID
    local id = tonumber(input)
    if id then
        eprint('addall: use "add" command for specific ID numbers')
        return
    end
    
    -- Search for matches (require all words to match for bulk operations)
    local results = find_roe_by_name(input, true)
    
    if #results == 0 then
        eprint(('No RoE objectives found matching "%s"'):format(input))
        return
    elseif #results > 10 then
        eprint(('Too many RoE objectives found matching "%s" (%d matches)'):format(input, #results))
        eprint('Showing first 10 matches:')
        for i = 1, 10 do
            local result = results[i]
            local status = ""
            if completed(result.id) then
                status = " (completed)"
            elseif roe.active[result.id] then
                status = " (active)"
            elseif result.id >= 4008 and result.id <= 4021 then
                status = " (restricted)"
            end
            nprint(('  %d: %s (%.0f%% match)%s'):format(result.id, result.name, result.score * 100, status))
        end
        eprint('Please be more specific or use individual IDs.')
        return
    end
    
    -- Check available slots
    local available_slots = roe.max_count - roe.active:length()
    local objectives_to_add = 0
    
    -- Count how many objectives we can actually add
    for _, result in ipairs(results) do
        if not completed(result.id) and not roe.active[result.id] and not (result.id >= 4008 and result.id <= 4021) then
            objectives_to_add = objectives_to_add + 1
        end
    end
    
    if objectives_to_add > available_slots then
        eprint("not enough free ROE slots. Additional slots needed: " .. (objectives_to_add - available_slots))
        eprint(('Found %d objectives to add, but only %d slots available'):format(objectives_to_add, available_slots))
        return
    end
    
    -- Process all matches
    local added_count = 0
    local skipped_count = 0
    local skipped_reasons = {}
    
    for _, result in ipairs(results) do
        if completed(result.id) then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - already completed'):format(result.id, result.name)
        elseif roe.active[result.id] then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - already active'):format(result.id, result.name)
        elseif result.id >= 4008 and result.id <= 4021 then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - restricted range'):format(result.id, result.name)
        else
            accept_roe(result.id)
            coroutine.sleep(0.5)
            added_count = added_count + 1
        end
    end
    
    -- Report results
    if added_count > 0 then
        nprint(('Added %d RoE objectives matching "%s"'):format(added_count, input))
    end
    
    if skipped_count > 0 then
        eprint(('Skipped %d objectives:'):format(skipped_count))
        for _, reason in ipairs(skipped_reasons) do
            eprint(('  %s'):format(reason))
        end
    end
    
    if added_count == 0 and skipped_count == 0 then
        eprint(('No objectives were processed for "%s"'):format(input))
    end
end

-- Remove multiple RoE objectives by name using fuzzy matching
local function remall_roe(input)
    -- Check if we have 0 active RoEs (status needs refresh)
    if roe.active:length() == 0 then
        eprint('No active RoE objectives detected. Please add an RoE objective to refresh the status.')
        return
    end
    
    -- Only works with name search, not ID
    local id = tonumber(input)
    if id then
        eprint('remall: use "rem" command for specific ID numbers')
        return
    end
    
    -- Search for matches (require all words to match for bulk operations)
    local results = find_roe_by_name(input, true)
    
    if #results == 0 then
        eprint(('No RoE objectives found matching "%s"'):format(input))
        return
    elseif #results > 10 then
        eprint(('Too many RoE objectives found matching "%s" (%d matches)'):format(input, #results))
        eprint('Showing first 10 matches:')
        for i = 1, 10 do
            local result = results[i]
            local status = ""
            if not roe.active[result.id] then
                status = " (not active)"
            elseif roe.settings.blacklist[result.id] then
                status = " (blacklisted)"
            end
            nprint(('  %d: %s (%.0f%% match)%s'):format(result.id, result.name, result.score * 100, status))
        end
        eprint('Please be more specific or use individual IDs.')
        return
    end
    
    -- Process all matches
    local removed_count = 0
    local skipped_count = 0
    local skipped_reasons = {}
    
    for _, result in ipairs(results) do
        if not roe.active[result.id] then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - not currently active'):format(result.id, result.name)
        elseif roe.settings.blacklist[result.id] then
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - blacklisted'):format(result.id, result.name)
        else
            cancel_roe(result.id)
            coroutine.sleep(0.5)
            removed_count = removed_count + 1
        end
    end
    
    -- Report results
    if removed_count > 0 then
        nprint(('Removed %d RoE objectives matching "%s"'):format(removed_count, input))
    end
    
    if skipped_count > 0 then
        eprint(('Skipped %d objectives:'):format(skipped_count))
        for _, reason in ipairs(skipped_reasons) do
            eprint(('  %s'):format(reason))
        end
    end
    
    if removed_count == 0 and skipped_count == 0 then
        eprint(('No objectives were processed for "%s"'):format(input))
    end
end

-- Show current RoE status for debugging
local function show_status()
    nprint('Current RoE Status:')
    nprint(('Active objectives: %d/%d'):format(roe.active:length(), roe.max_count))
    
    if roe.active:length() > 0 then
        nprint('Active objectives:')
        for id, progress in pairs(roe.active) do
            local name = roe_mapping[id] or "Unknown"
            nprint(('  %d: %s (%.0f%% progress)'):format(id, name, progress))
        end
    else
        nprint('No active objectives found')
    end
    
    nprint(('Completed objectives: %d'):format(roe.complete:length()))
    nprint(('Blacklisted objectives: %d'):format(table.getn(roe.settings.blacklist)))
    
    -- Note: Status refresh requires adding an RoE objective
    nprint('Note: If status appears incorrect, add an RoE objective to refresh the status.')
end

-- Print help text to chat
local function help()
    nprint([[
ROE - Command List

/roehelper help
    Show this help menu.

/roehelper mute [on|off]
    Turn off all messages from the addon and the "do that again" box (replies to your commands still show).

/roehelper info <id or name>
    Show a RoE's category, how many it needs and its rewards (sparks, exp, ...).

/roehelper ui
    Toggle the RoE helper window (zone RoEs, element stones, dailies, repeatables).

/roehelper zone
    Add the combat RoEs and day/weather stones for your current zone.

/roehelper auto [on|off]
    Auto mode: when your zone or the day changes, add the zone's Conflict RoE and the day's geode and -ite stone
    (and take off the ones auto mode added earlier that no longer fit).

/roehelper beginner [on|off]
    Beginner mode: a guide window that goes through the Basics > Tutorial RoEs, accepts the ones it can and tells you in the chat
    and in the window what to do next.

/roehelper cats
    Open / close the category filter: tick which RoE categories (Tutorial/Basics, Content/Dynamis ...) auto mode may turn on.

/roehelper cat <Top/Sub> on|off
    Allow / block one category for auto mode, e.g. /roehelper cat Content/Dynamis off.

/roehelper sync
    Open / close the Level Sync RoE window. It also opens by itself when you become level synced
    (/roehelper autosyncwin [on|off]; /roehelper syncid <id> if the Level Sync status id is not 269).

/roehelper autofight [on|off]
    Auto mode: when you are engaged with a monster, turn on the RoEs that match it: Subjugation and other named-monster
    RoEs (by the monster's id or name), the generic Vanquish kill RoEs, the next "Level N <job>" RoE of your job and the RoE
    of your current nation / Zilart / CoP mission. They come off again 90 s after the fight.

/roehelper mini
    Switch the window between full size and the compact mini window.

/roehelper clearzone | clearconflicts | clearcrystals | clearspoils
    Remove all zone (Conflict and Region) RoEs, only the Conflict RoEs, the crystal RoEs, or every Spoils RoE
    (crystals, geodes, -ite stones, monster drops, chips, Unity spoils).

/roehelper repeat <add|rem|list> [id or name]
    Manage the repeatables list shown in the window.

/roehelper add <id or name>
    Add a specific ROE objective by its ID number or name.
    Examples:
    /roehelper add 77
    /roehelper add "spoils light crystal"
    /roehelper add "vanquish enemy"

/roehelper rem <id or name>
    Remove a specific ROE objective by its ID number or name.
    Examples:
    /roehelper rem 77
    /roehelper rem "spoils light crystal"
    /roehelper rem "vanquish enemy"

/roehelper addall <name>
    Add all ROE objectives matching the name (max 10 matches).
    Examples:
    /roehelper addall "crystal"
    /roehelper addall "vanquish"

/roehelper remall <name>
    Remove all ROE objectives matching the name (max 10 matches).
    Examples:
    /roehelper remall "crystal"
    /roehelper remall "vanquish"

/roehelper save <profile name>
    Save your currently set ROE objectives to a named profile.

/roehelper set <profile name>
    Load and apply a saved profile of ROE objectives.
    - Objectives may be canceled automatically based on settings.
    - By default, only incomplete objectives will be removed if space is needed.

/roehelper unset [<profile name>]
    Remove the currently set ROE objectives.
    - Without a name, it will only remove objectives with no progress.
    - If a profile is specified, it removes only those objectives.

/roehelper list
    List all saved profile names.

/roehelper settings <name> [true|false]
    Toggle a settings value, or set it explicitly.
    * clear         : Remove inactive objectives if needed (default: true)
    * clearprogress : Also remove in-progress objectives (default: false)
    * clearall      : Clear all objectives before loading (default: false)

/roehelper blacklist [add|remove] <id>
    Add or remove a quest from the blacklist.
    - Blacklisted objectives will not be removed automatically.

/roehelper status
    Show current RoE status. If no active objectives are shown, add an RoE objective to refresh the status.
]])
end

-- Command dispatch table
local close_again = function() end            -- set once the "do that again" state exists
local handlers = {
    save      = save_profile,
    list      = list_profiles,
    set       = set_profile,
    unset     = unset_profile,
    settings  = handle_setting,
    blacklist = blacklist,
    add       = add_roe,
    rem       = rem_roe,
    addall    = addall_roe,
    remall    = remall_roe,
    status    = show_status,
    help      = help,
    mute      = function(v)
        v = v and v:lower()
        local cur = roe.settings.mute == true
        if v == 'on' then cur = true elseif v == 'off' then cur = false else cur = not cur end
        roe.settings.mute, MUTE.on = cur, cur
        if cur then close_again() end
        config.save()
        MUTE.cmd = true
        nprint(cur and 'Muted: no messages from the addon and no "do that again" box (replies to your commands still show). /roehelper mute off to undo.' or 'Unmuted.')
    end,
    info      = function(...)
        local q = table.concat({ ... }, ' '):lower()
        if q == '' then nprint('Usage: /roehelper info <id or part of a name>') return end
        local found, id = {}, tonumber(q)
        if id and roe_mapping[id] then found[1] = id
        else
            for k, v in pairs(roe_mapping) do
                if type(k) == 'number' and type(v) == 'string' and v:lower():find(q, 1, true) then found[#found + 1] = k end
            end
            table.sort(found)
        end
        if #found == 0 then nprint('No RoE matches that.') return end
        for i = 1, math.min(#found, 12) do
            local k = found[i]
            local r = roe_info[k]
            local line = ('#%d  %s  [%s]'):format(k, roe_mapping[k], cat_of(k) or '?')
            if r then
                line = line .. ('  needs %d | %d sparks, %d exp%s%s%s'):format(r[1], r[2], r[3],
                    r[4] > 0 and (', ' .. r[4] .. ' cp') or '', r[5] > 0 and (', ' .. r[5] .. ' accolades') or '', r[6] > 0 and (', ' .. r[6] .. ' plaudits') or '')
            end
            nprint(line)
        end
        if #found > 12 then nprint(('... and %d more, be more specific'):format(#found - 12)) end
    end,
}

-- Ashita command event
ashita.events.register('load', 'roe_mute_load', function() MUTE.on = roe.settings.mute == true end)

ashita.events.register('command','roe_cmd',function(e)
    local a = e.command:args(); if #a == 0 or a[1]:lower() ~= '/roehelper' then return end
    e.blocked = true
    local sub = a[2] and a[2]:lower() or 'ui'   -- plain /roehelper opens the window; /roehelper help lists commands
    if handlers[sub] then
        MUTE.cmd = true
        local ok, err = pcall(handlers[sub], table.unpack(a, 3))
        MUTE.cmd = false
        if not ok then error(err, 0) end
    else MUTE.cmd = true nprint(('unknown roe sub-command: %s'):format(sub)) MUTE.cmd = false end
end)



-- Check if world state is ready
local function is_world_ready()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local player_ent = GetPlayerEntity()
    return not (player == nil or player.isZoning or player_ent == nil)
end

-- Initial load event
local _startup = { sent = false }
ashita.events.register('load','roe_load',function()
    for name, prof in pairs(roe.settings.profiles) do
        if type(prof) == 'string' then
            local arr = {}; for id in prof:gmatch('%d+') do arr[#arr+1] = tonumber(id) end
            roe.settings.profiles[name] = S(arr)
        end
    end
    if _startup.sent then return end
    if is_world_ready() then
        nprint('RoE addon loaded. Add an RoE objective to refresh status if needed.')
        _startup.sent = true
    end
end)


--------------------------------------------------------------------------------
-- RoE UI window (combat wide area / region, element stones, dailies, repeatables)
--------------------------------------------------------------------------------
local imgui     = require('imgui')
local theme     = require('theme')
local roe_zones = require('roe_zones')

local ui = {
    visible     = true,
    open        = { true },
    queue       = {},          -- pending { kind = 'add'|'rem', id = n }
    next_send   = 0,
    day_ov      = 'auto',      -- 'auto' or an element name
    weather_ov  = 'auto',      -- 'auto', 'none' or an element name
    weather_id  = nil,         -- from packet 0x057
    clear_arm   = 0,           -- time until which "Remove ALL" is armed
    sel_key     = nil,         -- zone chosen in the conflict dropdown
    rep_buf     = { '' },
    room_retry  = {},          -- ids that did not fit because the RoE list was full (id -> forced)
    room_needed = false, room_t = nil, room_after = nil,
    drop_added  = {},          -- ids added because of a monster drop (taken off again when you leave the zone)
    drop_seen   = {}, drop_note = '', zone_t = -100,
    auto_added  = {},          -- ids auto mode added this session (only those are taken off again)
    auto_applied = nil,        -- the zone/day signature auto mode last applied
    auto_pending = nil, auto_since = 0, auto_zone_changed = false, auto_note = '',
    last_pkt    = 0,           -- last time a 0x111 RoE status packet arrived
    size_req    = nil,         -- { w, h } to force once (switching between mini and full size)
    full_size   = { 470, 640 },
    msg         = { text = '', t_end = 0, bad = false },
}

local COL_HEAD = theme.C.gold
local COL_GOOD = theme.C.green
local COL_DIM  = theme.C.muted
local COL_WARN = theme.C.warn
local COL_SEL  = 'primary'      -- btn() markers, not colours
local COL_DEL  = 'danger'

-- Vana'diel day (0 = Firesday) and weather ids ----------------------------------
local DAYS = { [0] = 'Fire', 'Earth', 'Water', 'Wind', 'Ice', 'Lightning', 'Light', 'Dark' }

local WEATHER = {
    [0]  = { 'Clear' },                  [1]  = { 'Sunshine' },
    [2]  = { 'Clouds' },                 [3]  = { 'Fog' },
    [4]  = { 'Hot Spell', 'Fire' },      [5]  = { 'Heat Wave', 'Fire' },
    [6]  = { 'Rain', 'Water' },          [7]  = { 'Squall', 'Water' },
    [8]  = { 'Dust Storm', 'Earth' },    [9]  = { 'Sand Storm', 'Earth' },
    [10] = { 'Wind', 'Wind' },           [11] = { 'Gale', 'Wind' },
    [12] = { 'Snow', 'Ice' },            [13] = { 'Blizzard', 'Ice' },
    [14] = { 'Thunder', 'Lightning' },   [15] = { 'Thunderstorm', 'Lightning' },
    [16] = { 'Aurora', 'Light' },        [17] = { 'Stellar Glare', 'Light' },
    [18] = { 'Gloom', 'Dark' },          [19] = { 'Darkness', 'Dark' },
}

local function game_day()
    local vana = (os.time() - 1009810800) * 25       -- Vana'diel seconds since the epoch
    return DAYS[math.floor(vana / 86400) % 8]
end

ashita.events.register('packet_in', 'roe_weather', function(e)
    if e.id == 0x057 then
        local w = struct.unpack('H', e.data, 9)       -- weather id (uint16 at byte offset 8)
        if w and WEATHER[w] then ui.weather_id = w end
    end
end)

-- effective day / weather element (override wins) ---------------------------------
local function day_element()
    if ui.day_ov ~= 'auto' then return ui.day_ov, true end
    return game_day(), false
end

local function weather_info()
    -- returns element-or-nil, display text, overridden?
    if ui.weather_ov == 'none' then return nil, 'None', true end
    if ui.weather_ov ~= 'auto' then return ui.weather_ov, ui.weather_ov, true end
    local w = ui.weather_id and WEATHER[ui.weather_id]
    if not w then return nil, 'Unknown', false end
    return w[2], w[1], false
end

-- zone ----------------------------------------------------------------------------
local function norm(s)
    s = (s or ''):lower()
    s = s:gsub('^the%s+', '')
    s = s:gsub('[%p]', ' ')
    s = s:gsub('%s+', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function current_zone()
    local ok, id = pcall(function() return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0) end)
    if not ok or not id or id == 0 then return nil, 'Unknown' end
    local ok2, name = pcall(function() return AshitaCore:GetResourceManager():GetString('zones.names', id) end)
    if not ok2 or not name or name == '' then return nil, ('Zone %d'):format(id) end
    return norm(name), name
end

-- index of "Conflict: <zone>" RoEs (all tiers I/II/III...), excluding Unity (UC) ones
local conflict_by_zone = {}
local region_of_zone   = {}
local region_roe_id    = {}
local zone_names       = {}   -- normalized key -> display name
local zone_list        = {}   -- sorted { key =, name = } for the dropdown

local function build_indexes()
    conflict_by_zone, region_of_zone, region_roe_id = {}, {}, {}
    zone_names, zone_list = {}, {}
    local the_set = {}
    for _, n in ipairs(roe_zones.THE_ZONES or {}) do the_set[n] = true end
    for id, name in pairs(roe_mapping) do
        local base = name:match('^Conflict: (.+)$')
        if base and not base:find('%(UC%)') then
            for pat, rep in pairs(roe_zones.ZONE_ALIASES) do base = base:gsub(pat, rep) end
            base = base:gsub('%s+[IVX]+$', '')             -- drop tier suffix
            local key = norm(base)
            conflict_by_zone[key] = conflict_by_zone[key] or {}
            table.insert(conflict_by_zone[key], id)
            if not zone_names[key] then zone_names[key] = the_set[base] and ('The ' .. base) or base end
        end
        local region = name:match('^Region: (.+)$')
        if region then region_roe_id[region] = id end
    end
    for _, list in pairs(conflict_by_zone) do table.sort(list) end
    for key, name in pairs(zone_names) do zone_list[#zone_list + 1] = { key = key, name = name } end
    table.sort(zone_list, function(a, b) return a.key < b.key end)   -- key ignores a leading "The"
    for region, zones in pairs(roe_zones.REGION_ZONES) do
        for _, z in ipairs(zones) do region_of_zone[norm(z)] = region end
    end
end

-- queue ---------------------------------------------------------------------------
local function say(text, bad)
    ui.msg = { text = text, t_end = os.clock() + 8, bad = bad or false }
    if bad then eprint(text) else nprint(text) end
end

local function pending_adds()
    local n = 0
    for _, q in ipairs(ui.queue) do if q.kind == 'add' then n = n + 1 end end
    return n
end

local function pending_rems()
    local n = 0
    for _, q in ipairs(ui.queue) do if q.kind == 'rem' and roe.active[q.id] then n = n + 1 end end
    return n
end

local function queued(kind, id)
    for _, q in ipairs(ui.queue) do
        if q.kind == kind and q.id == id then return true end
    end
    return false
end

-- Queue adds. force = ignore the "already completed" flag (repeatable / daily RoEs);
-- it can be true (all ids) or a table { [id] = true } (only those ids).
-- Returns added count, then list of skip reasons.
local function queue_adds(ids, force)
    local function is_forced(id)
        return force == true or (type(force) == 'table' and force[id] == true)
    end
    local free = roe.max_count - (roe.active:length() - pending_rems()) - pending_adds()
    local added, skipped = 0, {}
    if ui.auto_ctx then                                          -- auto mode only turns on the categories you allow
        local keep = {}
        for _, id in ipairs(ids) do if cat_allowed(id) then keep[#keep + 1] = id end end
        ids = keep
    end
    for _, id in ipairs(ids) do
        local name = rn(id)
        if roe.active[id] or queued('add', id) then
            skipped[#skipped + 1] = name .. ' (already active)'
        elseif completed(id) and not is_forced(id) then
            skipped[#skipped + 1] = name .. ' (completed)'
        elseif id >= 4008 and id <= 4021 then
            skipped[#skipped + 1] = name .. ' (automatic)'
        elseif added >= free then
            skipped[#skipped + 1] = name .. ' (no free slot)'
            if roe.settings.auto then                                  -- auto mode: the list is full, make room and try again
                ui.room_retry[id] = is_forced(id)
                ui.room_needed = true
            end
        else
            ui.queue[#ui.queue + 1] = { kind = 'add', id = id }
            added = added + 1
        end
    end
    return added, skipped
end

local function report(title, added, skipped)
    local msg = ('%s: %d queued'):format(title, added)
    if #skipped > 0 then msg = msg .. (', %d skipped'):format(#skipped) end
    say(msg, false)
    for _, s in ipairs(skipped) do nprint('  skipped: ' .. s) end
end

local function queue_rem(id)
    if roe.active[id] and not roe.settings.blacklist[id] and not queued('rem', id) then
        ui.queue[#ui.queue + 1] = { kind = 'rem', id = id }
        return true
    end
    return false
end

-- Process one queued packet every 0.6 s (same pacing as the command versions)
local function pump_queue(now)
    if #ui.queue == 0 or now < ui.next_send then return end
    local q = table.remove(ui.queue, 1)
    if q.kind == 'add' then
        send_roe_packet(0x10C, q.id)
        roe.active[q.id] = 0                 -- optimistic; the server's 0x111 corrects it
    else
        send_roe_packet(0x10D, q.id)
        roe.active[q.id] = nil
    end
    ui.next_send = now + 0.6
end

-- zone plan: conflict + region + element stones ------------------------------------
local function build_plan(zone_key, auto)
    local plan = {}
    local znorm = zone_key or current_zone()
    if znorm then
        for _, id in ipairs(conflict_by_zone[znorm] or {}) do
            plan[#plan + 1] = { id = id, why = 'Combat (Wide Area)' }
        end
        local region = region_of_zone[znorm]
        if region and region_roe_id[region] and not auto then
            plan[#plan + 1] = { id = region_roe_id[region], why = 'Combat (Region)' }
        end
    end
    local day_el = day_element()
    local weather_el = (not auto) and weather_info() or nil      -- auto mode goes by the day only
    local seen = {}
    for _, el in ipairs({ day_el, weather_el }) do
        if el and not seen[el] then
            seen[el] = true
            if roe_zones.GEODES[el] then plan[#plan + 1] = { id = roe_zones.GEODES[el], why = el .. ' geode', force = true } end
            if roe_zones.ITES[el]   then plan[#plan + 1] = { id = roe_zones.ITES[el],   why = el .. ' stone', force = true } end
        end
    end
    return plan
end

local function add_zone_roes(zone_key)
    local plan = build_plan(zone_key)
    if #plan == 0 then say('Nothing to add for this zone.', true) return end
    local ids, forced = {}, {}
    for _, p in ipairs(plan) do
        ids[#ids + 1] = p.id
        if p.force then forced[p.id] = true end       -- geodes / -ite stones repeat
    end
    local title = zone_key and ('Zone RoEs (' .. (zone_names[zone_key] or zone_key) .. ')') or 'Zone RoEs'
    local added, skipped = queue_adds(ids, forced)
    report(title, added, skipped)
end

local function add_element_set(tbl, label)
    local ids = {}
    for _, el in ipairs(roe_zones.ELEMENTS) do ids[#ids + 1] = tbl[el] end
    local added, skipped = queue_adds(ids, true)          -- repeatable: never skip as "completed"
    report(label, added, skipped)
end

local function remove_all()
    local n = 0
    for id in pairs(roe.active) do
        if type(id) == 'number' and not (id >= 4008 and id <= 4021) then
            if queue_rem(id) then n = n + 1 end
        end
    end
    say(('Remove all: %d objectives queued for removal'):format(n), false)
end

-- clear buttons ----------------------------------------------------------------------
local CRYSTAL_SET = {}
for _, id in pairs(roe_zones.CRYSTALS) do CRYSTAL_SET[id] = true end

local function name_starts(id, prefix)
    local name = roe_mapping[id]
    return type(name) == 'string' and name:find('^' .. prefix) ~= nil
end
local function is_spoils(id) return name_starts(id, 'Spoils') end         -- every "Spoils (...)" RoE: crystals, geodes, -ites, drops, chips, Unity ones
local function is_conflict(id) return name_starts(id, 'Conflict:') end

local function is_zone_roe(id)
    local name = roe_mapping[id]
    return type(name) == 'string' and (name:find('^Conflict:') ~= nil or name:find('^Region:') ~= nil)
end

local function clear_where(label, pred)
    local n = 0
    for id in pairs(roe.active) do
        if type(id) == 'number' and not (id >= 4008 and id <= 4021) and pred(id) then
            if queue_rem(id) then n = n + 1 end
        end
    end
    say(('%s: %d queued for removal'):format(label, n), false)
end
local function clear_zone_roes() clear_where('Clear zone RoEs', is_zone_roe) end
local function clear_conflicts() clear_where('Clear conflict RoEs', is_conflict) end
local function clear_crystals()  clear_where('Clear crystals', function(id) return CRYSTAL_SET[id] end) end
local function clear_spoils()    clear_where('Clear spoils', is_spoils) end

-- what auto mode may take off ------------------------------------------------------------
-- Only when more than 29 RoEs are active, and only: zone RoEs (Conflict / Region) of a zone you are not in, and the crystal /
-- geode / -ite stone RoEs of an element that is not today's. Never a RoE whose requirement is higher than 10 (e.g. 20 kills).
local ROE_GOALS = require('roe_goals')
local ELEMENT_OF = {}
for _, tbl in ipairs({ roe_zones.CRYSTALS, roe_zones.GEODES, roe_zones.ITES }) do
    for el, id in pairs(tbl) do ELEMENT_OF[id] = el end
end

-- room = the list was full when something had to be added (that is proof enough that it is full)
local function auto_removable(id, room)
    if ROE_GOALS[id] then return false end
    if not room and roe.active:length() - pending_rems() <= 29 then return false end
    local el = ELEMENT_OF[id]
    if el then return el ~= day_element() end
    if is_zone_roe(id) then
        local keep = {}
        for _, p in ipairs(build_plan(nil, true)) do keep[p.id] = true end
        local z = current_zone()
        local region = z and region_of_zone[z]
        if region and region_roe_id[region] then keep[region_roe_id[region]] = true end
        return not keep[id]
    end
    if is_spoils(id) then return true end                         -- monster-drop Spoils (rabbit hide, ...), chips, Unity spoils
    return false
end

local function auto_rem(id)
    if roe.active[id] and auto_removable(id) then return queue_rem(id) end
    return false
end

-- auto mode ---------------------------------------------------------------------------
-- Reads your zone and the day. Once they have been the same for a few seconds (and the RoE list has arrived after a zone
-- change) it takes off the zone / day RoEs it added earlier that no longer fit and adds this zone's Conflict RoEs and
-- today's geode and -ite stone. Anything you added yourself is left alone.
local function auto_signature()
    local zkey = current_zone()
    if not zkey then return nil end
    local el = day_element()
    return zkey .. '|' .. tostring(el), zkey
end

local function auto_apply()
    local plan = build_plan(nil, true)
    local want, ids, forced = {}, {}, {}
    for _, p in ipairs(plan) do
        want[p.id] = true
        ids[#ids + 1] = p.id
        if p.force then forced[p.id] = true end
    end
    local gone = 0
    if ui.auto_zone_changed then                                       -- you left the zone: its zone RoEs and drop RoEs go
        for id in pairs(roe.active) do
            if type(id) == 'number' and not want[id] and is_zone_roe(id) and not ui.auto_added[id] then
                if auto_rem(id) then gone = gone + 1 end
            end
        end
        for id in pairs(ui.drop_added) do
            if auto_rem(id) then gone = gone + 1 end
            ui.drop_added[id] = nil
        end
    end
    for id in pairs(ui.auto_added) do
        if not want[id] then
            if auto_rem(id) then gone = gone + 1 end
            ui.auto_added[id] = nil
        end
    end
    local added, skipped = queue_adds(ids, forced)
    for _, id in ipairs(ids) do
        if queued('add', id) then ui.auto_added[id] = true end
    end
    local _, zname = current_zone()
    local el = day_element()
    ui.auto_note = ('%s / %s day: %d added%s%s'):format(zname, tostring(el), added, (gone > 0) and (', ' .. gone .. ' old removed') or '', (#skipped > 0) and (', ' .. #skipped .. ' skipped') or '')
    say('Auto: ' .. ui.auto_note, false)
end

local function auto_tick(now)
    if not roe.settings.auto then return end
    if ui.auto_next and now < ui.auto_next then return end
    ui.auto_next = now + 1
    local sig, zkey = auto_signature()
    if not sig then return end
    if sig ~= ui.auto_pending then
        local old = ui.auto_pending
        ui.auto_zone_changed = (old ~= nil) and (old:match('^[^|]*') ~= zkey)
        ui.auto_pending, ui.auto_since = sig, now
    end
    if sig == ui.auto_applied then return end
    if not roe.known or #ui.queue > 0 then return end
    local waited = now - ui.auto_since
    if waited < 3 then return end
    if ui.auto_zone_changed and ui.last_pkt < ui.auto_since and waited < 10 then return end   -- wait for the new zone's RoE list
    ui.auto_applied = sig
    auto_apply()
end

local function set_auto(on)
    roe.settings.auto = on and true or false
    config.save()
    ui.auto_applied, ui.auto_pending = nil, nil
    say(on and 'Auto mode on: it adds this zone\'s Conflict RoE and today\'s geode and -ite stone when the zone or the day changes. It also asks you to talk to an NPC again when its RoE was off.' or 'Auto mode off.', false)
end

local function set_mini(on, cur_w, cur_h)
    roe.settings.mini = on and true or false
    config.save()
    if on then
        if cur_w and cur_h then ui.full_size = { cur_w, cur_h } end
        ui.size_req = { 460, 290 }
    else
        ui.size_req = { ui.full_size[1], ui.full_size[2] }
    end
end

ashita.events.register('packet_in', 'roe_auto_pkt', function(e)
    if e.id == 0x111 then ui.last_pkt = os.clock() end
end)

-- repeatables -----------------------------------------------------------------------
local function repeatables()
    if type(roe.settings.repeatables) ~= 'table' then
        roe.settings.repeatables = T{}
        for _, id in ipairs(roe_zones.DEFAULT_REPEATABLES) do roe.settings.repeatables[#roe.settings.repeatables + 1] = id end
        config.save()
    end
    return roe.settings.repeatables
end

local function repeat_has(id)
    for _, v in ipairs(repeatables()) do if v == id then return true end end
    return false
end

local function repeat_add(input)
    local id = tonumber(input)
    if not id then
        local hits = {}
        for rid, name in pairs(roe_mapping) do
            if fuzzy_match(input, name) >= 1.0 then hits[#hits + 1] = rid end
        end
        table.sort(hits)
        if #hits == 0 then say(('No RoE matches "%s"'):format(input), true) return end
        if #hits > 1 then
            say(('"%s" matches %d RoEs - use an id (/roehelper repeat add <id>):'):format(input, #hits), true)
            for i = 1, math.min(5, #hits) do nprint(('  %d: %s'):format(hits[i], roe_mapping[hits[i]])) end
            return
        end
        id = hits[1]
    end
    if not roe_mapping[id] then say(('Unknown RoE id %d'):format(id), true) return end
    if repeat_has(id) then say(('%s is already in the repeatables list'):format(roe_mapping[id]), true) return end
    local list = repeatables()
    list[#list + 1] = id
    config.save()
    say(('Added to repeatables: %s'):format(roe_mapping[id]))
end

local function repeat_rem(input)
    local id = tonumber(input)
    local list = repeatables()
    for i, v in ipairs(list) do
        if v == id then
            table.remove(list, i)
            config.save()
            say(('Removed from repeatables: %s'):format(roe_mapping[id] or id))
            return
        end
    end
    say('That id is not in the repeatables list', true)
end

local function repeat_toggle(id, want_on)
    if want_on then
        local added = queue_adds({ id }, true)
        if added == 0 then say(('Could not add %s (slot/active)'):format(roe_mapping[id] or id), true) end
    else
        queue_rem(id)
    end
end

-- command: /roehelper ui | /roehelper zone | /roehelper repeat <add|rem|list> ---------------------------
handlers.ui   = function() ui.visible = not ui.visible; ui.open[1] = true end
handlers.auto = function(v)
    v = v and v:lower()
    if v == 'on' then set_auto(true) elseif v == 'off' then set_auto(false) else set_auto(not roe.settings.auto) end
end
handlers.mini = function() set_mini(not roe.settings.mini) end
local set_beginner, LEVEL_SYNC_BUFF = nil, 269              -- defined further down (the level sync and beginner mode code)
local function flag_cmd(key, label)
    return function(v)
        v = v and v:lower()
        local cur = roe.settings[key] ~= false
        if v == 'on' then cur = true elseif v == 'off' then cur = false else cur = not cur end
        roe.settings[key] = cur
        config.save()
        say(label .. (cur and ' on.' or ' off.'), false)
    end
end
handlers.autodrops = flag_cmd('drops', 'Auto mode: Spoils RoEs from drops')
handlers.autofight = flag_cmd('fight', 'Auto mode: RoEs that match the monster you are fighting')
handlers.autosyncwin = flag_cmd('syncwin', 'The Level Sync RoE window')
handlers.beginner = function(v)
    v = v and v:lower()
    if v == 'on' then set_beginner(true) elseif v == 'off' then set_beginner(false) else set_beginner(not roe.settings.beginner) end
end
handlers.cats = function() ui.cats_win.open[1] = not ui.cats_win.open[1] end
handlers.cat = function(...)                      -- /roehelper cat <Top/Sub> on|off
    local a = { ... }
    local v = a[#a] and a[#a]:lower()
    if #a < 2 or (v ~= 'on' and v ~= 'off') then nprint('usage: /roehelper cat <Top/Sub> on|off   (/roehelper cats lists them)') return end
    local name = table.concat(a, ' ', 1, #a - 1):lower()
    roe.settings.cats_off = roe.settings.cats_off or T{}
    local hit
    for _, c in ipairs(cats.list) do if c:lower() == name then hit = c end end
    if not hit then nprint('unknown category: ' .. name) return end
    roe.settings.cats_off[hit] = (v == 'off') and true or nil
    config.save()
    say(('Category %s: %s'):format(hit, v), false)
end
handlers.sync = function() ui.sync_win.open[1] = not ui.sync_win.open[1] end
handlers.syncid = function(v)
    local n = tonumber(v)
    if n and n > 0 and n < 1024 then LEVEL_SYNC_BUFF = math.floor(n) say('Level Sync status id = ' .. LEVEL_SYNC_BUFF .. ' (this session).', false)
    else say('Usage: /roehelper syncid <status id>   (now ' .. LEVEL_SYNC_BUFF .. ')', true) end
end
handlers.clearzone     = function() clear_zone_roes() end
handlers.clearconflicts = function() clear_conflicts() end
handlers.clearcrystals = function() clear_crystals() end
handlers.clearspoils   = function() clear_spoils() end
handlers.zone = function(...)
    local name = table.concat({ ... }, ' ')
    if name == '' then add_zone_roes() return end
    local key = norm(name)
    if not conflict_by_zone[key] then say(('No conflict RoE found for zone "%s"'):format(name), true) return end
    add_zone_roes(key)
end
handlers['repeat'] = function(action, arg)
    action = action and action:lower()
    if action == 'add' and arg then repeat_add(arg)
    elseif (action == 'rem' or action == 'remove') and arg then repeat_rem(arg)
    elseif action == 'list' then
        for _, id in ipairs(repeatables()) do nprint(('  %d: %s'):format(id, roe_mapping[id] or '?')) end
    else
        eprint('usage: /roehelper repeat add <id or name> | rem <id> | list')
    end
end


-- auto mode extras ---------------------------------------------------------------------
-- 1. drops: an item that lands in the treasure pool (packet 0x0D2, the way XIUI's notifications read it) is looked up in the
--    "Spoils (<item>)" RoEs; a match is turned on, so the next kills count it. The drop that triggered it is not counted.
-- 2. no room: when a RoE could not be added because the list is full, the geode / -ite stone RoEs that do not match today are
--    taken off, then the add is tried again.

local function item_key(s) return ((s or ''):lower():gsub('[^%w]', '')) end

local spoil_by_item = {}
for id, name in pairs(roe_mapping) do
    if type(name) == 'string' and not name:find('%(UC%)') then
        local item = name:match('^Spoils %((.-)%)$')
        if item then
            local k = item_key(item)
            spoil_by_item[k] = spoil_by_item[k] or {}
            table.insert(spoil_by_item[k], id)
        end
    end
end
for _, list in pairs(spoil_by_item) do table.sort(list) end

local ELEMENT_STONES = {}
for _, tbl in ipairs({ roe_zones.GEODES, roe_zones.ITES }) do
    for el, id in pairs(tbl) do ELEMENT_STONES[id] = el end
end

local function repeatable_spoil(id)
    return repeat_has(id) or CRYSTAL_SET[id] or ELEMENT_STONES[id] ~= nil
end

local function drop_seen(item_id, item_name)
    local ids = spoil_by_item[item_key(item_name)]
    if not ids then return end
    local want, forced = {}, {}
    for _, id in ipairs(ids) do
        if not roe.active[id] and not queued('add', id) and not roe.settings.blacklist[id] then
            want[#want + 1] = id
            if repeatable_spoil(id) then forced[id] = true end
        end
    end
    if #want == 0 then
        ui.drop_note = ('%s dropped: its Spoils RoE is already on.'):format(item_name)
        return
    end
    local added, skipped = queue_adds(want, forced)
    for _, id in ipairs(want) do
        if queued('add', id) then ui.drop_added[id] = true end
    end
    ui.drop_note = ('%s dropped: %d Spoils RoE queued%s'):format(item_name, added, (#skipped > 0) and (' (' .. skipped[1] .. ')') or '')
    say('Auto: ' .. ui.drop_note, false)
end

ashita.events.register('packet_in', 'roe_drops', function(e)
    if e.id == 0x00A then ui.zone_t = os.clock() return end                  -- zoning: the pool is re-sent, ignore that
    if e.id ~= 0x0D2 or not roe.settings.auto or roe.settings.drops == false then return end
    local now = os.clock()
    if now - ui.zone_t < 6 then return end
    pcall(function()
        local item_id = struct.unpack('H', e.data, 0x10 + 1)
        local slot = struct.unpack('B', e.data, 0x14 + 1)
        if not item_id or item_id == 0 or item_id == 0xFFFF or not slot or slot >= 10 then return end
        local key = slot .. ':' .. item_id
        if ui.drop_seen[key] and now - ui.drop_seen[key] < 30 then return end   -- the same pool entry sent again
        ui.drop_seen[key] = now
        local item = AshitaCore:GetResourceManager():GetItemById(item_id)
        local name = item and item.Name and item.Name[1]
        if name and name ~= '' then
            local nk = 'n:' .. item_key(name)
            if ui.drop_seen[nk] and now - ui.drop_seen[nk] < 20 then return end
            ui.drop_seen[nk] = now
            drop_seen(item_id, name)
        end
    end)
end)

-- fallback: the chat lines for a drop ("You find a bat wing on the Giant Bat." / "You obtain a bat wing." / "<name> obtains a bat wing.").
-- It works even when the pool packet is not read the way the code expects. The same item is only handled once per 20 seconds.
ashita.events.register('text_in', 'roe_drops_text', function(e)
    if not roe.settings.auto or roe.settings.drops == false then return end
    if os.clock() - ui.zone_t < 6 then return end
    local msg = (e.message or ''):gsub('\30.', ''):gsub('\31.', ''):gsub('[%c\127-\255]', '')
    local item = msg:match('^You find an? (.-) on ') or msg:match('^You obtain an? (.-)%.$') or msg:match('^%S+ obtains an? (.-)%.$')
    if not item or item == '' then return end
    item = item:gsub('^the ', '')
    local now = os.clock()
    local nk = 'n:' .. item_key(item)
    if ui.drop_seen[nk] and now - ui.drop_seen[nk] < 20 then return end
    if not spoil_by_item[item_key(item)] then return end
    ui.drop_seen[nk] = now
    pcall(drop_seen, nil, item)
end)

local function extras_tick(now)
    if not roe.settings.auto or not roe.known then return end
    if ui.x_next and now < ui.x_next then return end
    ui.x_next = now + 1

    -- no room: free the off-day geode / -ite stone RoEs, then retry
    if ui.room_needed and #ui.queue == 0 and (not ui.room_t or now - ui.room_t > 20) then
        ui.room_t, ui.room_needed = now, false
        local need = 0
        for _ in pairs(ui.room_retry) do need = need + 1 end
        local cand = {}
        for id in pairs(roe.active) do
            if type(id) == 'number' and auto_removable(id, true) then cand[#cand + 1] = id end
        end
        local function rank(id) return ELEMENT_OF[id] and 1 or (is_zone_roe(id) and 2 or 3) end   -- off-day stones, other-zone RoEs, then spoils
        table.sort(cand, function(x, y) local a, b = rank(x), rank(y) if a ~= b then return a < b end return x < y end)
        local n = 0
        for _, id in ipairs(cand) do
            if n >= math.max(need, 1) then break end
            if queue_rem(id) then n = n + 1 end
        end
        if n > 0 then
            ui.room_after = now + 2
            say(('Auto: the RoE list is full: %d RoE (off-day stone, other zone or Spoils) are being taken off.'):format(n), false)
        else
            ui.room_retry = {}
            say('Auto: the RoE list is full and nothing may be taken off (only off-day stones and crystals, other-zone RoEs and monster Spoils with a requirement of 10 or less).', true)
        end
    end
    if ui.room_after and #ui.queue == 0 and now >= ui.room_after then
        ui.room_after = nil
        local ids, forced = {}, {}
        for id, f in pairs(ui.room_retry) do ids[#ids + 1] = id if f then forced[id] = true end end
        ui.room_retry = {}
        table.sort(ids)
        if #ids > 0 then
            local added, skipped = queue_adds(ids, forced)
            for _, id in ipairs(ids) do
                if queued('add', id) and spoil_by_item and is_spoils(id) and not ELEMENT_STONES[id] then ui.drop_added[id] = true end
            end
            say(('Auto: tried again after making room: %d queued'):format(added), false)
        end
    end

end


-- fight: turn on the RoEs that match the monster you are fighting -------------------
-- Subjugation / named-monster RoEs (matched by the monster's server id or name), the generic "Vanquish" ones, the next
-- "Level N <job>" RoE for your current job and the RoE of your current nation / Zilart / CoP mission.
-- It only reads the target, the same way the target bar does, and sends the normal accept packet.
local fights = require('roe_fights')
local FIGHT_REPEAT = {}
for _, id in ipairs(fights.repeatable) do FIGHT_REPEAT[id] = true end
ui.fight = { next = 0, mob = nil, added = {}, tried = {}, off_since = nil, note = '', mission = {} }

ashita.events.register('packet_in', 'roe_mission', function(e)
    if e.id ~= 0x056 or #e.data < 0x2A then return end
    -- current missions (LandSandBoat GP_SERV_COMMAND_MISSION): Nation @0x04, NationMission @0x08, RotZ @0x0C, CoP @0x10, 0xFFFF marker near 0x24
    pcall(function()
        local nat = struct.unpack('I', e.data, 5)
        local m1, m2 = struct.unpack('H', e.data, 0x25), struct.unpack('H', e.data, 0x29)
        if nat > 2 or not (m1 == 0xFFFF or m2 == 0xFFFF) then return end
        ui.fight.mission = { [nat] = struct.unpack('I', e.data, 9), [3] = struct.unpack('I', e.data, 13), [6] = struct.unpack('I', e.data, 17) }
    end)
end)

-- the monster you are fighting: engaged, target is a monster, alive. Returns server id, name or nil
local function fight_target()
    local ok, sid, name = pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        local pidx = mm:GetParty():GetMemberTargetIndex(0)
        local ent = mm:GetEntity()
        if not pidx or pidx < 1 or pidx > 0x8FF or ent:GetStatus(pidx) ~= 1 then return nil end   -- not engaged
        local ti = mm:GetTarget():GetTargetIndex(0)
        if not ti or ti < 1 or ti > 0x8FF then return nil end                                    -- never read past the entity table
        local id = ent:GetServerId(ti)
        if not id or id < 0x01000000 or id >= 0x02000000 then return nil end                      -- monsters only
        if (ent:GetHPPercent(ti) or 0) <= 0 then return nil end
        return id, ent:GetName(ti)
    end)
    if ok then return sid, name end
    return nil
end

local function fight_wanted(sid, name)
    local want, forced, have = {}, {}, {}
    local function add(id)
        if not have[id] then have[id] = true want[#want + 1] = id end
        if FIGHT_REPEAT[id] then forced[id] = true end
    end
    for _, id in ipairs(fights.mob_id[sid] or {}) do add(id) end
    for _, id in ipairs(fights.mob_name[(name or ''):lower()] or {}) do add(id) end
    for _, id in ipairs(fights.generic) do add(id) end
    -- level: the next unreached "Level N <job>" RoE of the job you are on, but only once you are one level below it
    local ok, job, lvl = pcall(function()
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        return pl:GetMainJob(), pl:GetMainJobLevel()
    end)
    if ok and job and fights.level[job] then
        for _, e in ipairs(fights.level[job]) do
            if e[1] > lvl then                                        -- only on the level before it: it can be reached by this fight
                if e[1] - lvl <= 1 then add(e[2]) end
                break
            end
        end
    end
    -- mission: the RoE of the mission you are on now
    for log, cur in pairs(ui.fight.mission) do
        if log <= 2 or cur > 0 then                                  -- Zilart / CoP: 0 can also mean "not started"
        local ids = fights.mission[log] and fights.mission[log][cur]
        for _, id in ipairs(ids or {}) do add(id) end
        end
    end
    return want, forced
end

local function fight_tick(now)
    local f = ui.fight
    if not roe.settings.auto or roe.settings.fight == false or not roe.known then return end
    if now < f.next then return end
    f.next = now + 1
    local sid, name = fight_target()
    if not sid then
        f.mob = nil
        -- you stopped fighting: take off what the fight added (after a pause so a quick re-target keeps it)
        if next(f.added) then
            f.off_since = f.off_since or now
            if now - f.off_since > 90 and #ui.queue == 0 then
                local n = 0
                for id in pairs(f.added) do
                    if auto_rem(id) then n = n + 1 end
                    f.added[id] = nil
                end
                f.off_since = nil
                if n > 0 then say(('Auto: fight over - %d RoE taken off.'):format(n), false) end
            end
        end
        return
    end
    f.off_since = nil
    if #ui.queue > 0 then return end
    local key = sid
    if f.mob == key then return end                                    -- already handled this monster
    f.mob = key
    local want, forced = fight_wanted(sid, name)
    local ids = {}
    for _, id in ipairs(want) do
        if not roe.active[id] and not queued('add', id) and not roe.settings.blacklist[id]
           and not (f.tried[id] and now - f.tried[id] < 120) then
            ids[#ids + 1] = id
        end
    end
    if #ids == 0 then return end
    local added, skipped = queue_adds(ids, forced)
    local names = {}
    for _, id in ipairs(ids) do
        f.tried[id] = now
        if queued('add', id) then
            f.added[id] = true
            names[#names + 1] = rn(id)
        end
    end
    f.note = ('%s: %d RoE on (%s)'):format(name or 'monster', added, table.concat(names, ', '))
    if added > 0 then say('Auto: ' .. f.note, false) end
end

-- do that again: you talked to an NPC whose RoE was not on ------------------------------
-- The game counts the RoE when you talk to the NPC (guild masters, A.M.A.N. Liaison, Unity Concord, Home Points...). If the RoE was
-- off, it is turned on now and a box asks you to talk to the NPC again.
local npc_roes = require('roe_npcs')
ui.again = { open = { false }, npc = '', ids = {}, key = nil, t = 0 }
close_again = function() ui.again.open[1] = false end

local function npc_key(s) return ((s or ''):lower():gsub('[^%w]', '')) end

local function again_close() ui.again.open[1] = false ui.again.ids = {} ui.again.key = nil end

ashita.events.register('packet_out', 'roe_again', function(e)
    if e.id ~= 0x01A or not roe.settings.auto or not roe.known then return end
    if not completed(1) then return end                                                       -- not before First Step Forward is done
    pcall(function()
        local idx = struct.unpack('H', e.data, 0x08 + 1)
        local cat = struct.unpack('H', e.data, 0x0A + 1)
        if cat ~= 0 or not idx or idx < 1 or idx >= 0x400 then return end                      -- talking to an NPC only; never read past the table
        local name = AshitaCore:GetMemoryManager():GetEntity():GetName(idx)
        local key = npc_key(name)
        if key == '' then return end
        local ids = npc_roes.by_name[key]
        if not ids then
            for pre, list in pairs(npc_roes.prefix) do if key:sub(1, #pre) == pre then ids = list break end end
        end
        if not ids then return end
        if ui.again.open[1] and ui.again.key == key then again_close() end                    -- you talked to him again: done
        local want = {}
        for _, id in ipairs(ids) do
            if cat_allowed(id) and not roe.active[id] and not queued('add', id) and not roe.settings.blacklist[id] and not completed(id) then want[#want + 1] = id end
        end
        if #want == 0 then return end
        ui.auto_ctx = true
        local added = queue_adds(want, false)
        ui.auto_ctx = false
        if added == 0 then return end
        local names = {}
        for _, id in ipairs(want) do if queued('add', id) then names[#names + 1] = rn(id) end end
        ui.again.npc, ui.again.ids, ui.again.key, ui.again.t = name, want, key, os.clock()
        ui.again.names = table.concat(names, ', ')
        ui.again.open[1] = not roe.settings.mute
        nprint(('Do that again: "%s" is on now - talk to %s again.'):format(ui.again.names, name))
    end)
end)

local function again_tick(now)
    if not ui.again.open[1] then return end
    local done = true
    for _, id in ipairs(ui.again.ids) do if roe.active[id] and not completed(id) then done = false end end
    if now - ui.again.t > 120 or (done and now - ui.again.t > 3 and #ui.queue == 0) then again_close() end
end

-- drawing ---------------------------------------------------------------------------
local function btn(label, id, kind)
    if kind == COL_SEL then return theme.accent(label .. '##' .. id, nil, true) end
    if kind == COL_DEL then return theme.danger(label .. '##' .. id) end
    return theme.toggle(label, id, false)
end

local override_cycle = {
    day     = { 'auto', 'Fire', 'Earth', 'Water', 'Wind', 'Ice', 'Lightning', 'Light', 'Dark' },
    weather = { 'auto', 'none', 'Fire', 'Earth', 'Water', 'Wind', 'Ice', 'Lightning', 'Light', 'Dark' },
}

local function cycle(kind)
    local list = override_cycle[kind]
    local cur = (kind == 'day') and ui.day_ov or ui.weather_ov
    local idx = 1
    for i, v in ipairs(list) do if v == cur then idx = i break end end
    local nxt = list[(idx % #list) + 1]
    if kind == 'day' then ui.day_ov = nxt else ui.weather_ov = nxt end
end

local function draw_plan(plan)
    if #plan == 0 then
        imgui.TextColored(COL_DIM, '  No combat RoEs found for this zone.')
    end
    for _, p in ipairs(plan) do
        local name = roe_mapping[p.id] or ('#' .. p.id)
        local state, col = '', { 1, 1, 1, 1 }
        if roe.active[p.id] then state, col = '  [active]', COL_GOOD
        elseif completed(p.id) and not p.force then state, col = '  [done]', COL_DIM end
        imgui.TextColored(col, ('  %s  -  %s%s'):format(name, p.why, state))
    end
end

local function draw_window()
    imgui.SetNextWindowPos({ 120, 160 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize({ 470, 640 }, ImGuiCond_FirstUseEver)
    ui.open[1] = true
    if roe.settings.mini and not ui.mini_sized then          -- started in mini mode: shrink the window once
        ui.mini_sized = true
        ui.size_req = { 460, 290 }
    end
    if ui.size_req then
        imgui.SetNextWindowSize(ui.size_req, ImGuiCond_Always)
        ui.size_req = nil
    end
    if not theme.begin('RoE Helper', ui.open) then imgui.End() return end
    local mini = roe.settings.mini and true or false
    if theme.header(ui.open, 'RoE', 'HELPER', mini and 'Mini' or 'Records of Eminence', mini) then
        local w, h = imgui.GetWindowSize()
        if type(w) == 'table' then w, h = w.x or w[1], w.y or w[2] end
        set_mini(not mini, w, h)
    end
    if mini then
        -- the compact window: where you are, auto mode, and the buttons used most
        local znorm0, zname0 = current_zone()
        imgui.TextColored(COL_HEAD, ('%s  -  %s day'):format(zname0, tostring((day_element()))))
        imgui.SameLine()
        imgui.TextColored(COL_DIM, ('   RoE %d/%d%s'):format(roe.active:length(), roe.max_count, (#ui.queue > 0) and ('  (' .. #ui.queue .. ' queued)') or ''))
        if theme.toggle(roe.settings.auto and 'Auto: ON' or 'Auto: OFF', 'auto_m', roe.settings.auto and true or false) then set_auto(not roe.settings.auto) end
        imgui.SameLine()
        if btn('Add Zone RoEs', 'zone_m', COL_SEL) then add_zone_roes(nil) end
        if btn('Clear Conflicts', 'cf_m') then clear_conflicts() end
        imgui.SameLine()
        if btn('Clear Zone', 'cz_m') then clear_zone_roes() end
        if btn('Clear Crystals', 'cc_m') then clear_crystals() end
        imgui.SameLine()
        if btn('Clear Spoils', 'cs_m') then clear_spoils() end
        if os.clock() < ui.msg.t_end then
            imgui.TextColored(ui.msg.bad and COL_WARN or COL_GOOD, ui.msg.text)
        end
        theme.finish()
        if not ui.open[1] then ui.visible = false end
        return
    end

    -- status ---------------------------------------------------------------------
    imgui.TextColored(COL_HEAD, ('Active RoEs: %d/%d'):format(roe.active:length(), roe.max_count))
    if #ui.queue > 0 then
        imgui.SameLine()
        imgui.TextColored(COL_WARN, ('   working... %d queued'):format(#ui.queue))
    end
    if roe.active:length() == 0 and not roe.known then
        imgui.TextColored(COL_WARN, 'RoE status not received yet - zone or add/remove one RoE to sync.')
    end
    if os.clock() < ui.msg.t_end then
        imgui.TextColored(ui.msg.bad and COL_WARN or COL_GOOD, ui.msg.text)
    end
    imgui.Separator()

    -- zone / day / weather -------------------------------------------------------
    local znorm, zname = current_zone()
    local day_el, day_ov = day_element()
    local w_el, w_text, w_ov = weather_info()
    imgui.Text('Zone:')
    imgui.SameLine()
    imgui.TextColored(COL_HEAD, zname)

    imgui.Text('Day:')
    imgui.SameLine()
    imgui.TextColored(COL_HEAD, day_el .. (day_ov and ' (manual)' or ''))
    imgui.SameLine()
    if btn('change', 'day') then cycle('day') end

    imgui.Text('Weather:')
    imgui.SameLine()
    imgui.TextColored(COL_HEAD, w_text .. (w_el and (' [' .. w_el .. ']') or '') .. (w_ov and ' (manual)' or ''))
    imgui.SameLine()
    if btn('change', 'wx') then cycle('weather') end
    imgui.TextColored(COL_DIM, 'Day/weather are read automatically; "change" cycles a manual override (auto first).')
    imgui.Separator()

    -- mute --------------------------------------------------------------------------
    if theme.toggle(roe.settings.mute and 'Mute: ON' or 'Mute: OFF', 'mute', roe.settings.mute and true or false) then
        roe.settings.mute = not roe.settings.mute
        MUTE.on = roe.settings.mute
        if MUTE.on then ui.again.open[1] = false end
        config.save()
    end
    if imgui.IsItemHovered() then imgui.SetTooltip('Turns off all chat messages from this addon and the "do that again" box. Replies to commands you type still show.') end

    -- auto mode -------------------------------------------------------------------
    if theme.toggle(roe.settings.auto and 'Auto mode: ON' or 'Auto mode: OFF', 'auto', roe.settings.auto and true or false) then set_auto(not roe.settings.auto) end
    imgui.SameLine()
    if roe.settings.auto then
        local waiting = (ui.auto_pending ~= nil and ui.auto_pending ~= ui.auto_applied)
        imgui.TextColored(waiting and COL_WARN or COL_GOOD, waiting and 'waiting for the zone / day to settle...' or (ui.auto_note ~= '' and ui.auto_note or 'in sync'))
    else
        imgui.TextColored(COL_DIM, 'adds this zone\'s Conflict RoE and today\'s geode and -ite stone by itself')
    end
    if btn('Categories...', 'cats_open') then handlers.cats() end
    imgui.SameLine()
    if theme.toggle(roe.settings.beginner and 'Beginner mode: ON' or 'Beginner mode: OFF', 'beginner', roe.settings.beginner and true or false) then set_beginner(not roe.settings.beginner) end
    if imgui.IsItemHovered() then imgui.SetTooltip('Opens a guide that walks you through the Basics > Tutorial RoEs: it accepts them and tells you what to do.') end
    imgui.SameLine()
    if theme.toggle(roe.settings.syncwin ~= false and 'Level sync window: ON' or 'Level sync window: OFF', 'syncwin', roe.settings.syncwin ~= false) then handlers.autosyncwin() end
    if imgui.IsItemHovered() then imgui.SetTooltip('When you become level synced, a window with every Level Sync RoE opens so you can switch them on or off.') end
    if roe.settings.auto then
        if theme.toggle(roe.settings.drops ~= false and 'Drops: ON' or 'Drops: OFF', 'auto_drops', roe.settings.drops ~= false) then handlers.autodrops() end
        if imgui.IsItemHovered() then imgui.SetTooltip('When a monster drops an item that has a Spoils RoE (Rabbit Hide...), that RoE is turned on.') end
        if ui.drop_note ~= '' then imgui.TextColored(COL_DIM, ui.drop_note) end
        if theme.toggle(roe.settings.fight ~= false and 'Fight: ON' or 'Fight: OFF', 'auto_fight', roe.settings.fight ~= false) then handlers.autofight() end
        if imgui.IsItemHovered() then imgui.SetTooltip('When you fight a monster that has an RoE (Subjugation: Kirin...), or a kill, level-up or mission RoE applies, it is turned on so the kill counts.') end
        if ui.fight.note ~= '' then imgui.TextColored(COL_DIM, ui.fight.note) end
    end
    imgui.Separator()

    -- zone RoEs --------------------------------------------------------------------
    local plan = build_plan()
    if btn('Add Zone RoEs', 'zone', COL_SEL) then add_zone_roes(nil) end
    imgui.SameLine()
    imgui.TextColored(COL_DIM, '(current zone: combat + day/weather stones; no fishing/harvesting)')
    draw_plan(plan)
    if btn('Clear All Zone Conflicts', 'clrconf') then clear_conflicts() end
    imgui.SameLine()
    if btn('Clear All Zone RoEs', 'clrzone') then clear_zone_roes() end
    imgui.TextColored(COL_DIM, '(conflicts only, or every Conflict and Region RoE that is on)')
    imgui.Separator()

    -- manual conflict zone picker (alphabetical, ignoring "The") ---------------------------
    imgui.TextColored(COL_HEAD, 'Pick a conflict zone manually')
    local preview = ui.sel_key and zone_names[ui.sel_key] or 'Select a zone...'
    -- plain collapsing list instead of a combo box (some Ashita builds reject BeginCombo / child windows)
    if imgui.CollapsingHeader(preview .. '###confzone') then
        for _, z in ipairs(zone_list) do
            if imgui.Selectable(z.name .. '##cz' .. z.key, ui.sel_key == z.key) then ui.sel_key = z.key end
        end
    end
    if btn('Add', 'confadd', COL_SEL) then
        if ui.sel_key then add_zone_roes(ui.sel_key) else say('Select a zone first.', true) end
    end
    if ui.sel_key then draw_plan(build_plan(ui.sel_key)) end
    imgui.Separator()

    -- element sets -----------------------------------------------------------------
    imgui.TextColored(COL_HEAD, 'Element RoEs')
    if btn('Add All Crystals', 'crys') then add_element_set(roe_zones.CRYSTALS, 'Crystals') end
    imgui.SameLine()
    if btn('Add All Geodes', 'geo') then add_element_set(roe_zones.GEODES, 'Geodes') end
    imgui.SameLine()
    if btn('Add All -ite Stones', 'ite') then add_element_set(roe_zones.ITES, '-ite stones') end
    if btn('Clear All Crystals', 'clrcrys') then clear_crystals() end
    imgui.SameLine()
    if btn('Clear All Spoils', 'clrspoil') then clear_spoils() end
    imgui.SameLine()
    imgui.TextColored(COL_DIM, '(spoils = every "Spoils (...)" RoE)')
    imgui.Separator()

    -- dailies ----------------------------------------------------------------------
    imgui.TextColored(COL_HEAD, 'Dailies')
    for i, d in ipairs(roe_zones.DAILIES) do
        local on = roe.active[d.id] ~= nil or queued('add', d.id)
        if i > 1 then imgui.SameLine() end
        if btn(d.label .. (on and '  [on]' or ''), 'daily' .. d.id, on and COL_SEL or nil) then
            if on then queue_rem(d.id) else queue_adds({ d.id }, true) end
        end
    end
    if btn('Add All Dailies', 'dailyall') then
        local ids = {}
        for _, d in ipairs(roe_zones.DAILIES) do ids[#ids + 1] = d.id end
        local added, skipped = queue_adds(ids, true)
        report('Dailies', added, skipped)
    end
    imgui.Separator()

    -- repeatables ------------------------------------------------------------------
    imgui.TextColored(COL_HEAD, 'Repeatables (stay listed - tick to turn on/off)')
    local list = repeatables()
    local remove_idx = nil
    for i, id in ipairs(list) do
        local c = { roe.active[id] ~= nil or queued('add', id) }
        if imgui.Checkbox((roe_mapping[id] or ('#' .. id)) .. '##rep' .. id, c) then
            repeat_toggle(id, c[1])
        end
        if imgui.IsItemHovered() and roe_info[id] then
            local r = roe_info[id]
            imgui.SetTooltip(('Needs %d  |  %d sparks, %d exp%s'):format(r[1], r[2], r[3], r[4] > 0 and (', ' .. r[4] .. ' cp') or ''))
        end
        imgui.SameLine()
        if imgui.SmallButton('x##reprem' .. id) then remove_idx = id end
    end
    if remove_idx then repeat_rem(remove_idx) end
    if #list == 0 then imgui.TextColored(COL_DIM, '  (none)') end

    if imgui.SetNextItemWidth then imgui.SetNextItemWidth(220) end
    imgui.InputText('##repinput', ui.rep_buf, 64)
    imgui.SameLine()
    if btn('Add to list', 'repadd') and ui.rep_buf[1] ~= '' then
        repeat_add(ui.rep_buf[1])
        ui.rep_buf[1] = ''
    end
    imgui.TextColored(COL_DIM, 'Type an RoE id or name (e.g. "Total Damage I").')
    imgui.Separator()

    -- remove all (two clicks) ----------------------------------------------------------
    local now = os.clock()
    if now < ui.clear_arm then
        if btn('Click again to REMOVE ALL', 'clr2', COL_DEL) then
            ui.clear_arm = 0
            remove_all()
        end
    else
        if btn('Remove All RoEs', 'clr') then ui.clear_arm = now + 3 end
    end

    theme.finish()
    if not ui.open[1] then ui.visible = false end
end


-- level sync window -----------------------------------------------------------------------
-- Being level synced opens a window with every "Level Sync ..." RoE, each with an on / off box.
-- (LEVEL_SYNC_BUFF = 269 is the status effect id of Level Sync; /roehelper syncid <id> if it differs)
local sync_list = {}
for id, name in pairs(roe_mapping) do
    if type(name) == 'string' and name:find('^Level Sync') then sync_list[#sync_list + 1] = id end
end
table.sort(sync_list)
ui.sync_win = { open = { false }, synced = false, next = 0 }

local function level_synced()
    local ok, r = pcall(function()
        for _, id in pairs(AshitaCore:GetMemoryManager():GetPlayer():GetBuffs()) do
            if id == LEVEL_SYNC_BUFF then return true end
        end
        return false
    end)
    return ok and r or false
end

local function sync_tick(now)
    if now < ui.sync_win.next then return end
    ui.sync_win.next = now + 1
    local synced = level_synced()
    if synced and not ui.sync_win.synced and roe.settings.syncwin ~= false then
        ui.sync_win.open[1] = true
        say('Level sync detected: the Level Sync RoE window is open.', false)
    elseif (not synced) and ui.sync_win.synced then
        ui.sync_win.open[1] = false                          -- the sync ended: the window goes away
    end
    ui.sync_win.synced = synced
end

local function draw_sync_window()
    if not ui.sync_win.open[1] then return end
    imgui.SetNextWindowPos({ 640, 200 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize({ 430, 250 }, ImGuiCond_FirstUseEver)
    if not theme.begin('RoE Helper - Level Sync', ui.sync_win.open) then imgui.End() return end
    theme.header(ui.sync_win.open, 'LEVEL', 'SYNC', 'Level Sync RoEs')
    imgui.TextColored(COL_DIM, 'Tick the ones you want on while you are level synced.')
    if not roe.known then imgui.TextColored(COL_WARN, 'RoE status not received yet - zone or add/remove one RoE to sync.') end
    for _, id in ipairs(sync_list) do
        local name = roe_mapping[id]
        local is_on = roe.active[id] ~= nil or queued('add', id)
        local c = { is_on }
        if imgui.Checkbox(name .. '##syncroe' .. id, c) then
            if c[1] then
                local _, skipped = queue_adds({ id }, true)
                if skipped[1] then say(skipped[1], true) end
            else
                queue_rem(id)
            end
        end
        if roe.active[id] and type(roe.active[id]) == 'number' and roe.active[id] > 0 then
            imgui.SameLine()
            imgui.TextColored(COL_DIM, roe.active[id] .. '%')
        end
        if name:find('%(UC%)') then
            imgui.SameLine()
            imgui.TextColored(COL_DIM, '(needs Unity)')
        end
    end
    if os.clock() < ui.msg.t_end then imgui.TextColored(ui.msg.bad and COL_WARN or COL_GOOD, ui.msg.text) end
    theme.finish()
end

-- beginner mode ------------------------------------------------------------------------------
-- Goes through the Basics > Tutorial RoEs in the order the game lists them: accepts each one it can, tells you in the chat and
-- in its own window what to do, and moves on when the game reports it done.
local BEGINNER = {
    { id = 1,    accept = false, text = 'Unlocks the Records of Eminence. Find one of the A.M.A.N. NPCs in a city (look for them on the map) and talk to them.' },
    { id = 5,    accept = false, text = 'Unlocks Unity Concord. Talk to a Unity Concord NPC in a city and join a Unity.' },
    { id = 3,    accept = true,  text = 'Go to a Fields of Valor book (a tome in the field zones, e.g. outside your home city) and accept a training regime from it.' },
    { id = 4,    accept = true,  text = 'Rest with /heal and recover at least 1 HP. Get a little damaged first if you are at full HP, then type /heal and wait.' },
    { id = 11,   accept = true,  text = 'Find a Grounds of Valor tome (the Grounds Tome) and accept a training from it.' },
    { id = 2,    accept = true,  text = 'Go and defeat one enemy. It does not have to give experience, so anything in the field will do.' },
    { id = 499,  accept = false, text = 'Unlocks Ambuscade. Talk to the Ambuscade NPC in a city.' },
    { id = 932,  accept = true,  text = 'Call forth an Alter Ego (a Trust): cast one of the Trust spells you have, for example /ma "Valaineral" <me>. Trust magic has to be unlocked first.' },
    { id = 933,  accept = true,  text = 'Summon Valaineral:  /ma "Valaineral" <me>' },
    { id = 934,  accept = true,  text = 'Summon Mihli Aliapoh:  /ma "Mihli Aliapoh" <me>' },
    { id = 935,  accept = true,  text = 'Summon Tenzen:  /ma "Tenzen" <me>' },
    { id = 936,  accept = true,  text = 'Summon Adelheid:  /ma "Adelheid" <me>' },
    { id = 937,  accept = true,  text = 'Summon Joachim:  /ma "Joachim" <me>' },
    { id = 1447, accept = false, text = 'Unlocks the A.M.A.N. Trove. Talk to the A.M.A.N. Trove NPC.' },
    { id = 1448, accept = false, text = 'Speak with an A.M.A.N. Liaison NPC to finish the Assist Channel objective.' },
}
ui.beg = { open = { false }, cur = nil, skipped = {}, said_all = false, next = 0, accepted = {} }

local function beg_current()
    for i, st in ipairs(BEGINNER) do
        if not completed(st.id) and not ui.beg.skipped[st.id] then return i, st end
    end
    return nil
end

local function beg_announce(i, st)
    local name = roe_mapping[st.id] or ('#' .. st.id)
    nprint(('[Beginner %d/%d] %s'):format(i, #BEGINNER, name))
    nprint('  ' .. st.text)
end

local function beg_accept(st)
    if not st.accept or roe.active[st.id] or queued('add', st.id) or completed(st.id) then return end
    local added = queue_adds({ st.id }, false)
    if added > 0 then nprint(('  Accepted the "%s" RoE for you.'):format(rn(st.id))) end
end

set_beginner = function(on)
    roe.settings.beginner = on and true or false
    config.save()
    ui.beg.open[1] = roe.settings.beginner
    ui.beg.cur, ui.beg.said_all, ui.beg.skipped, ui.beg.accepted = nil, false, {}, {}
    if on then nprint('Beginner mode on: it will walk you through the Basics > Tutorial RoEs.') else nprint('Beginner mode off.') end
end

local function beginner_tick(now)
    if not roe.settings.beginner or not roe.known then return end
    if now < ui.beg.next then return end
    ui.beg.next = now + 1
    local i, st = beg_current()
    if not i then
        if not ui.beg.said_all then
            ui.beg.said_all = true
            ui.beg.cur = nil
            nprint('[Beginner] All the Basics > Tutorial RoEs are done (or skipped). Beginner mode can be switched off.')
        end
        return
    end
    ui.beg.said_all = false
    if ui.beg.cur ~= st.id then
        if ui.beg.cur then nprint('[Beginner] Done: ' .. rn(ui.beg.cur)) end
        ui.beg.cur = st.id
        beg_announce(i, st)
    end
    if st.accept and not ui.beg.accepted[st.id] and #ui.queue == 0 then
        ui.beg.accepted[st.id] = true
        beg_accept(st)
    end
end

local function draw_again_window()
    if not ui.again.open[1] then return end
    imgui.SetNextWindowPos({ 640, 120 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize({ 400, 150 }, ImGuiCond_FirstUseEver)
    if not theme.begin('RoE Helper - Do that again', ui.again.open) then imgui.End() return end
    theme.header(ui.again.open, 'DO THAT', 'AGAIN', 'RoE turned on')
    imgui.TextColored(COL_GOOD, ('"%s" is on now.'):format(ui.again.names or ''))
    imgui.TextWrapped(('It was off when you talked to %s, so it did not count. Talk to %s again.'):format(ui.again.npc, ui.again.npc))
    if theme.accent('Okay##again_ok', nil, true) then again_close() end
    theme.finish()
end

ui.cats_win = { open = { false } }
local function draw_cats_window()
    if not ui.cats_win.open[1] then return end
    roe.settings.cats_off = roe.settings.cats_off or T{}
    imgui.SetNextWindowPos({ 640, 200 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize({ 420, 520 }, ImGuiCond_FirstUseEver)
    if not theme.begin('RoE Helper - Categories', ui.cats_win.open) then imgui.End() return end
    theme.header(ui.cats_win.open, 'RoE', 'CATEGORIES', 'What auto mode may turn on')
    imgui.TextWrapped('Untick a category and auto mode (zone, stones, drops, fight, do that again) will not turn those RoEs on. RoEs you add yourself are never blocked.')
    if btn('All on', 'cats_all_on') then roe.settings.cats_off = T{} config.save() end
    imgui.SameLine()
    if theme.toggle(roe.settings.grey_unimpl ~= false and 'Grey out inactive: ON' or 'Grey out inactive: OFF', 'cats_grey', roe.settings.grey_unimpl ~= false) then
        roe.settings.grey_unimpl = not (roe.settings.grey_unimpl ~= false) config.save()
    end
    if imgui.IsItemHovered() then imgui.SetTooltip('Grey out RoEs / categories the server does not implement (RoE ids that LandSandBoat has no record for). Other servers may differ.') end
    imgui.SameLine()
    if btn('All off', 'cats_all_off') then for _, c in ipairs(cats.list) do roe.settings.cats_off[c] = true end config.save() end
    imgui.Separator()
    local tops, order = {}, {}
    for _, c in ipairs(cats.list) do
        local top = c:match('^(.-)/') or c
        if not tops[top] then tops[top] = {} order[#order + 1] = top end
        tops[top][#tops[top] + 1] = c
    end
    table.sort(order)
    local grey = roe.settings.grey_unimpl ~= false
    if not cats.count then                                     -- RoEs in each category: total and implemented on the server
        cats.count = {}
        for id, i in pairs(cats.of) do
            local c = cats.list[i]
            local t = cats.count[c] or { 0, 0 }
            t[1] = t[1] + 1
            if cats.impl[id] then t[2] = t[2] + 1 end
            cats.count[c] = t
        end
    end
    for _, top in ipairs(order) do
        local subs = tops[top]
        local n_on = 0
        for _, c in ipairs(subs) do if not roe.settings.cats_off[c] then n_on = n_on + 1 end end
        local all_on = n_on == #subs
        local v = { n_on > 0 }                                   -- ticked when at least one subcategory is on
        -- some on: a dimmer tick; all on: no tick, a filled circle instead
        imgui.PushStyleColor(ImGuiCol_CheckMark, all_on and { 0, 0, 0, 0 } or { 0.6, 0.6, 0.6, 0.85 })
        local top_clicked = imgui.Checkbox(('##cattop' .. top), v)
        imgui.PopStyleColor()
        if all_on then
            local ok, x1, y1, x2, y2 = pcall(function()
                local a, c = imgui.GetItemRectMin(), imgui.GetItemRectMax()
                local mx, my, nx, ny
                if type(a) == 'table' then mx, my = a[1] or a.x, a[2] or a.y else mx, my = imgui.GetItemRectMin() end
                if type(c) == 'table' then nx, ny = c[1] or c.x, c[2] or c.y else nx, ny = imgui.GetItemRectMax() end
                return mx, my, nx, ny
            end)
            local dl = ok and x1 and y2 and imgui.GetWindowDrawList()
            if dl then
                local g = theme.C.green or { 0.4, 1, 0.5, 1 }
                dl:AddCircleFilled({ (x1 + x2) / 2, (y1 + y2) / 2 }, (x2 - x1) * 0.28, imgui.GetColorU32(g), 16)
            end
        end
        if top_clicked then
            for _, c in ipairs(subs) do roe.settings.cats_off[c] = (not v[1]) and true or nil end
            config.save()
        end
        imgui.SameLine()
        local top_total, top_impl = 0, 0
        for _, c in ipairs(subs) do top_total = top_total + cats.count[c][1] top_impl = top_impl + cats.count[c][2] end
        local top_dead = grey and top_impl == 0
        if top_dead then imgui.PushStyleColor(ImGuiCol_Text, { 0.5, 0.5, 0.5, 0.7 }) end
        local open_tree = imgui.TreeNode(('%s  (%d/%d)###cattree%s'):format(top, n_on, #subs, top))
        if top_dead then imgui.PopStyleColor() end
        if open_tree then
            for _, c in ipairs(subs) do
                local on = { not roe.settings.cats_off[c] }
                local ct = cats.count[c]
                local dead = grey and ct[2] == 0
                local part = grey and ct[2] > 0 and ct[2] < ct[1]
                if dead then imgui.PushStyleColor(ImGuiCol_Text, { 0.5, 0.5, 0.5, 0.7 }) end
                local label = (c:match('/(.*)$') or c) .. (part and ('  (%d/%d active)'):format(ct[2], ct[1]) or dead and '  (not active on server)' or '')
                local clicked = imgui.Checkbox(label .. '##cat' .. c, on)
                if dead then imgui.PopStyleColor() end
                if clicked then
                    roe.settings.cats_off[c] = (not on[1]) and true or nil
                    config.save()
                end
            end
            imgui.TreePop()
        end
    end
    theme.finish()
end

local function draw_beginner_window()
    if not roe.settings.beginner then return end
    if not ui.beg.open[1] then set_beginner(false) return end         -- closing the window turns beginner mode off
    imgui.SetNextWindowPos({ 640, 470 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize({ 470, 430 }, ImGuiCond_FirstUseEver)
    if not theme.begin('RoE Helper - Beginner', ui.beg.open) then imgui.End() return end
    theme.header(ui.beg.open, 'BEGINNER', 'MODE', 'Basics > Tutorial')
    local i, st = beg_current()
    if not roe.known then
        imgui.TextColored(COL_WARN, 'RoE status not received yet - zone or add/remove one RoE to sync.')
    elseif i then
        imgui.TextColored(COL_HEAD, ('Step %d of %d:  %s'):format(i, #BEGINNER, roe_mapping[st.id] or ('#' .. st.id)))
        imgui.TextWrapped(st.text)
        local prog = roe.active[st.id]
        if prog ~= nil then
            imgui.TextColored(COL_GOOD, ('The RoE is accepted%s.'):format((type(prog) == 'number' and prog > 0) and (' (' .. prog .. '%)') or ''))
        elseif st.accept then
            imgui.TextColored(COL_WARN, 'The RoE is not accepted yet.')
        else
            imgui.TextColored(COL_DIM, 'This one is done in the game world; it finishes by itself.')
        end
        if st.accept and prog == nil and btn('Accept this RoE', 'beg_acc', COL_SEL) then beg_accept(st) end
        if btn('Say it in chat again', 'beg_say') then beg_announce(i, st) end
        imgui.SameLine()
        if btn('Skip this step', 'beg_skip') then ui.beg.skipped[st.id] = true nprint('[Beginner] Skipped ' .. (roe_mapping[st.id] or st.id)) end
    else
        imgui.TextColored(COL_GOOD, 'All the Basics > Tutorial RoEs are done (or skipped).')
    end
    imgui.Separator()
    for n, step in ipairs(BEGINNER) do
        local mark, col = '[ ]', COL_DIM
        if completed(step.id) then mark, col = '[x]', COL_GOOD
        elseif ui.beg.skipped[step.id] then mark, col = '[-]', COL_DIM
        elseif st and step.id == st.id then mark, col = '[>]', COL_HEAD end
        imgui.TextColored(col, ('%s %s'):format(mark, roe_mapping[step.id] or ('#' .. step.id)))
    end
    theme.finish()
end

-- the automatic features respect the category filter
local _auto_tick, _extras_tick, _fight_tick = auto_tick, extras_tick, fight_tick
local function in_auto(fn, now)
    ui.auto_ctx = true
    local ok, err = pcall(fn, now)
    ui.auto_ctx = false
    if not ok then error(err, 0) end
end
auto_tick   = function(now) in_auto(_auto_tick, now) end
extras_tick = function(now) in_auto(_extras_tick, now) end
fight_tick  = function(now) in_auto(_fight_tick, now) end

ashita.events.register('d3d_present', 'roe_ui_present', function()
    pump_queue(os.clock())
    auto_tick(os.clock())
    extras_tick(os.clock())
    fight_tick(os.clock())
    sync_tick(os.clock())
    beginner_tick(os.clock())
    again_tick(os.clock())
    do
        local nc, nv = theme.push()
        draw_sync_window()
        draw_beginner_window()
        draw_again_window()
        draw_cats_window()
        theme.pop(nc, nv)
    end
    if ui.visible then
        local nc, nv = theme.push()
        draw_window()
        theme.pop(nc, nv)
    end
end)

ashita.events.register('load', 'roe_ui_load', function()
    build_indexes()
    repeatables()
end)
