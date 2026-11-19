-- roe_zones.lua - zone / element data used by the RoE UI.
--
-- "Conflict: <zone>" RoEs are matched to your current zone automatically from
-- roe_mapping.lua (by name), so they need no table here.
--
-- REGION_ZONES maps each "Region: <name>" RoE to the zones in that region.
-- Ronfaure, Gustaberg, Sarutabaruta, Kolshushu, Qufim and Fauregandi were taken
-- from the FFXIclopedia area lists. The rest (marked "best effort") are from memory:
-- if the Region RoE is not added in a zone where you expect it, add the zone name here.
-- Zone names are compared ignoring case, punctuation and a leading "The".

local M = {}

M.REGION_ZONES = {
    ['Ronfaure'] = {
        'West Ronfaure', 'East Ronfaure', 'Ghelsba Outpost', 'Fort Ghelsba', 'Yughott Grotto',
        'Horlais Peak', "King Ranperre's Tomb", 'Bostaunieux Oubliette',
    },
    ['Gustaberg'] = {
        'North Gustaberg', 'South Gustaberg', 'Zeruhn Mines', 'Palborough Mines', 'Dangruf Wadi',
        'Korroloka Tunnel', 'Waughroon Shrine',
    },
    ['Sarutabaruta'] = {
        'West Sarutabaruta', 'East Sarutabaruta', 'Giddeus', 'Inner Horutoto Ruins',
        'Outer Horutoto Ruins', 'Toraimarai Canal', "Balga's Dais", 'Full Moon Fountain',
    },
    ['Kolshushu'] = {
        'Buburimu Peninsula', 'Tahrongi Canyon', 'Maze of Shakhrami', 'Labyrinth of Onzozo',
        'Bibiki Bay', 'Bibiki Bay - Purgonorgo Isle',
    },
    ['Qufim'] = {
        'Qufim Island', "Behemoth's Dominion", "Lower Delkfutt's Tower", "Middle Delkfutt's Tower",
        "Upper Delkfutt's Tower", 'Stellar Fulcrum',
    },
    ['Fauregandi'] = {
        'Beaucedine Glacier', "Fei'Yin", "Pso'Xja", 'Ranguemont Pass', "Qu'Bia Arena",
        'The Shrouded Maw', 'Cloister of Frost',
    },
    -- best effort (not verified):
    ['Zulkheim']         = { 'Valkurm Dunes', 'Konschtat Highlands', 'Gusgen Mines' },
    ['Norvallen']        = { 'Jugner Forest', 'Batallia Downs', 'La Theine Plateau', "Ordelle's Caves",
                             'Davoi', 'Eldieme Necropolis' },
    ['Derfland']         = { 'Pashhow Marshlands', 'Rolanberry Fields', 'Beadeaux', "Crawlers' Nest" },
    ['Aragoneu']         = { 'Meriphataud Mountains', 'Sauromugue Champaign', 'Garlaige Citadel',
                             'Castle Oztroja' },
    ['Kuzotz']           = { 'Eastern Altepa Desert', 'Western Altepa Desert', 'Quicksand Caves',
                             'Kuftal Tunnel', 'Cloister of Tremors' },
    ['Vollbow']          = { 'Cape Teriggan', 'Valley of Sorrows', 'Gustav Tunnel' },
    ["Li'Telor"]         = { "Sanctuary of Zi'Tah", "Ro'Maeve", 'Boyahda Tree', "Dragon's Aery" },
    ['Elshimo Lowlands'] = { 'Yuhtunga Jungle', 'Sea Serpent Grotto' },
    ['Elshimo Uplands']  = { 'Yhoator Jungle', 'Temple of Uggalepih', 'Den of Rancor' },
}

-- RoE names abbreviate a few zones; expand them so they match the real zone names.
M.ZONE_ALIASES = {
    ['Alza%.']   = 'Alzadaal',
    ['Meriph%.'] = 'Meriphataud',
    ['Sauro%.']  = 'Sauromugue',
}

-- Zones whose official name starts with "The" (display only: the dropdown shows
-- "The Boyahda Tree" but sorts it under B).
M.THE_ZONES = {
    'Boyahda Tree', "Sanctuary of Zi'Tah", 'Eldieme Necropolis', "Garden of Ru'Hmet",
    "Grand Palace of Hu'Xzoi", "Shrine of Ru'Avitau",
}

-- Element -> RoE ids
M.CRYSTALS = { Fire = 71, Ice = 72, Wind = 73, Earth = 74, Lightning = 75, Water = 76, Light = 77, Dark = 78 }
M.GEODES   = { Fire = 84, Ice = 85, Wind = 86, Earth = 87, Lightning = 88, Water = 89, Light = 90, Dark = 91 }
M.ITES     = { Fire = 92, Ice = 93, Wind = 94, Earth = 95, Lightning = 96, Water = 97, Light = 98, Dark = 99 }

-- Display / iteration order
M.ELEMENTS = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' }

-- The three daily objectives from the "Other" category
M.DAILIES = {
    { id = 386, label = 'Telepoint Pilgrimage' },
    { id = 387, label = 'Culling the Darkness' },
    { id = 388, label = 'Petals of Recollection' },
}

-- Repeatable RoEs shown in the UI by default (edit in-game with /roe repeat add|rem)
M.DEFAULT_REPEATABLES = { 15, 117 }

return M
