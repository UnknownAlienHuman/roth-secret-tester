-- RothSecretTester2 Module: BDK
-- One-shot DK data probe. Visible concept is ONLY "module" (no packs/suites in UI).

local _, _ = ...

local mod = {
    id = "BDK",
    name = "DK: Blood",
    desc = "Blood DK seed probe (Death Strike / Blood Shield focus).",
    class = "DEATHKNIGHT",
    specId = 250,
    lists = {
        spells = {
            { id = 61304, label = 'GCD (Global Cooldown)' },
            { id = 6603, label = 'Auto Attack' },
            { id = 49576, label = 'Death Grip' },
            { id = 47528, label = 'Mind Freeze' },
            { id = 45524, label = 'Chains of Ice' },
            { id = 43265, label = 'Death and Decay' },
            { id = 49998, label = 'Death Strike' },
            { id = 47541, label = 'Death Coil' },
            { id = 48707, label = 'Anti-Magic Shell' },
            { id = 48792, label = 'Icebound Fortitude' },
            { id = 49039, label = 'Lichborne' },
            { id = 46584, label = 'Raise Dead' },
            { id = 56222, label = 'Dark Command' },
            { id = 108199, label = "Gorefiend's Grasp" },
            { id = 212552, label = 'Wraith Walk' },
            { id = 48743, label = 'Death Pact' },
            { id = 439843, label = "Reaper's Mark (hero)" },
            { id = 439851, label = 'Wave of Souls (hero)' },
            { id = 441378, label = 'Exterminate (hero)' },
            { id = 444347, label = 'Death Charge (hero)' },
            { id = 433895, label = 'Vampiric Strike (hero)' },
            { id = 433925, label = 'Essence of the Blood Queen (hero)' },
            { id = 195182, label = 'Marrowrend' },
            { id = 206930, label = 'Heart Strike' },
            { id = 50842, label = 'Blood Boil' },
            { id = 55233, label = 'Vampiric Blood' },
            { id = 49028, label = 'Dancing Rune Weapon' },
            { id = 194844, label = 'Bonestorm' },
            { id = 219809, label = 'Tombstone' },
            { id = 194679, label = 'Rune Tap' },
            { id = 195292, label = "Death's Caress" },
        },

        auraIDs = {
            { id = 195181, label = 'Bone Shield (stacks)' },
            { id = 77535, label = 'Blood Shield (absorb; verify)' },
            { id = 55233, label = 'Vampiric Blood (buff)' },
            { id = 49028, label = 'Dancing Rune Weapon (buff)' },
            { id = 194679, label = 'Rune Tap (buff)' },
        },

        items = {
            { slot = 13, label = 'Trinket 1' },
            { slot = 14, label = 'Trinket 2' },
            { slot = 16, label = 'Mainhand' },
            { slot = 17, label = 'Offhand (if dual wield)' },
        },
    }
}

function mod:Start(env)
    local core = env and env.core or _G.RothSecretTesterCore
    if not core then return end

    if not core:LoadTester() then
        core:Crit("MODULE", "Tester not available")
        return
    end

    core:Info("MODULE", ("run %s"):format(self.id))
    if core.tester and core.tester.RunSuite then
        core.tester:RunSuite("lists", { moduleId = self.id, lists = self.lists })
    else
        core:Crit("MODULE", "Tester missing RunSuite")
    end
end

function mod:Stop(env)
    -- One-shot module; nothing to clean up.
end

if type(_G.RothSecretTester_RegisterModule) == "function" then
    _G.RothSecretTester_RegisterModule(mod)
elseif _G.RothSecretTesterCore and _G.RothSecretTesterCore.RegisterModule then
    _G.RothSecretTesterCore:RegisterModule(mod)
end
