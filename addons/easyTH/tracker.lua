-- easyTH tracking corrections. Original addon Copyright (c) 2025 Arielfy.
-- This file is provided under the accompanying MIT LICENSE.
local Tracker = {}
Tracker.__index = Tracker

function Tracker.new()
    return setmetatable({ enemies = {}, current = 0, count = 0 }, Tracker)
end

function Tracker:reset()
    self.enemies = {}
    self.current = 0
    self.count = 0
end

function Tracker:observe(id, name, ownAction, proc)
    if type(id) ~= 'number' or id <= 0 then return end
    local enemy = self.enemies[id]
    if not enemy then
        -- Unknown is not TH0, TH1, or another enemy's last observed level.
        enemy = { name = name or 'Unknown', th = nil }
        self.enemies[id] = enemy
        self.count = self.count + 1
    elseif name and name ~= 'Unknown' then
        enemy.name = name
    end
    if type(proc) == 'number' and proc > 0 then
        enemy.th = proc -- the latest server observation, including a reset to a lower level
    end
    if ownAction or self.current == 0 then self.current = id end
end

function Tracker:remove(id)
    if self.enemies[id] then
        self.enemies[id] = nil
        self.count = self.count - 1
    end
    if self.current == id then self.current = 0 end
end

function Tracker:currentEnemy()
    return self.enemies[self.current]
end

return Tracker
