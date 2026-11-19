-- NPCs that trigger an RoE when you talk to them (from the LandSandBoat scripts), used by the "Do that again" box.
-- by_name: lowercase letters/digits of the NPC's name -> RoE ids.  prefix: names that start with the key.
return {
    by_name = {
        cheupirudaux = { 100 },      -- Speak to Carpenters' Guild Master
        ghemp = { 101 }, mevreauche = { 101 },   -- Blacksmiths'
        reinberta = { 102 },         -- Goldsmiths'
        ponono = { 103 },            -- Weavers'
        faulpie = { 104 },           -- Tanners'
        peshiyohnts = { 105 },       -- Boneworkers'
        abdalraziq = { 106 },        -- Alchemists'
        piketopuketo = { 107 },      -- Culinarians'
        isakoth = { 1 },             -- First Step Forward
        amanliaison = { 1448 },      -- Assist Channel
        gorpamasorpa = { 499 },      -- Ambuscade Primer
        greyson = { 3768 },          -- A.M.A.N. Trove (M)
        igsli = { 5 }, urbiolaine = { 5 }, yonolala = { 5 }, teldrokesdrodo = { 5 }, nunaarlbthtrogg = { 5 },   -- Unity Concord: All for One
    },
    prefix = {
        homepoint = { 3769 },        -- Examine a Home Point (M)
    },
}
