-- Original easyTH by Arielfy, Copyright (c) 2025. MIT LICENSE retained.
-- Compatibility/safety revision: per-monster observed procs, full alliance and safe UI/parser.
addon.author = 'Arielfy'
addon.name = 'EasyTH'
addon.version = '0.4.1-vd'
addon.desc = 'Tracks observed Treasure Hunter procs'
addon.link = 'https://github.com/ariel-logos/easyTH'
addon.commands = {'/easyth'}

require('common')
local imgui = require('imgui')
local parser = require('parser')
local Tracker = require('tracker')
local tracker = Tracker.new()
local anyJob = false

local function playerEnabled()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    return player and player:GetLoginStatus() == 2 and (anyJob or player:GetMainJob() == 6)
end

local function partyIds()
    local party = AshitaCore:GetMemoryManager():GetParty()
    local ids = {}
    -- Includes all 18 alliance slots, regardless of main/sub job or TH gear.
    for slot = 0, 17 do
        local id = party:GetMemberServerId(slot)
        if id and id > 0 then ids[id] = true end
    end
    return ids, party:GetMemberServerId(0)
end

ashita.events.register('d3d_present', 'easyth_present', function()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if not player or player:GetLoginStatus() ~= 2 then
        tracker:reset()
        return
    end
    if not playerEnabled() then tracker:reset(); return end
    if tracker.count == 0 then return end

    imgui.SetNextWindowPos({200, 100}, ImGuiCond_FirstUseEver)
    local flags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBringToFrontOnFocus)
    local visible = imgui.Begin('Treasure Hunter Tracker', true, flags)
    if visible then
        local enemy = tracker:currentEnemy()
        imgui.Text(enemy and enemy.name or 'EasyTH')
        imgui.Separator()
        if enemy and enemy.th then
            imgui.Text('TH Lvl: ' .. enemy.th)
        elseif enemy then
            imgui.Text('TH Lvl: Unknown (no proc observed)')
        else
            imgui.Text('------')
        end
    end
    -- ImGui requires End even when Begin returns false (e.g. a clipped window).
    imgui.End()
end)

ashita.events.register('command', 'easyth_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/easyth' then return end
    e.blocked = true
    local command = args[2] and args[2]:lower()
    if command == 'anyjob' then
        anyJob = not anyJob
        tracker:reset()
        print('[EasyTH] Tracking ' .. (anyJob and 'on any job.' or 'on THF main job.'))
    elseif command == 'reset' then
        tracker:reset()
        print('[EasyTH] Tracking has been reset.')
    else
        print('[EasyTH] /easyth anyjob | /easyth reset. Levels are unknown until a proc is observed.')
    end
end)

ashita.events.register('packet_in', 'easyth_packet_in', function(e)
    if e.injected then return end
    -- Do not carry monster IDs/levels into another zone or instance session.
    if e.id == 0x00A or e.id == 0x00B then
        tracker:reset()
        return
    end
    if not playerEnabled() or type(e.data) ~= 'string' then return end

    if e.id == 0x029 then
        if #e.data < 26 then return end
        local ok, target, message = pcall(function()
            return struct.unpack('I', e.data, 0x09), struct.unpack('H', e.data, 0x19) % 32768
        end)
        if ok and (message == 6 or message == 20) then tracker:remove(target) end
        return
    end
    if e.id ~= 0x028 or #e.data < 19 then return end

    -- Header offsets match the action packet: actor at bit40, category at bit82.
    local category = bit.band(bit.rshift(e.data:byte(11), 2), 15)
    if category ~= 1 and category ~= 3 then return end
    local okActor, actor = pcall(struct.unpack, 'I', e.data, 6)
    if not okActor then return end
    local ids, selfId = partyIds()
    if not ids[actor] then return end

    local ok, action = pcall(parser.parse, e.data)
    if not ok or type(action) ~= 'table' or type(action.target) ~= 'table' then return end
    for index, target in ipairs(action.target) do
        local proc = nil
        for _, result in ipairs(target.result) do
            if result.has_proc and result.proc_kind == 7 and result.proc_message == 603 then
                proc = math.max(proc or 0, result.proc_value)
            end
        end
        tracker:observe(target.m_uID, target.target_name, actor == selfId and index == 1, proc)
    end
end)
