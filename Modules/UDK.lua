-- RothSecretTester2 Module: UDK
-- One-shot DK data probe. Visible concept is ONLY "module" (no packs/suites in UI).

local _, _ = ...

local mod = {
    id = "UDK",
    name = "DK: Unholy",
    desc = "Unholy DK seed probe (Plague / pets / ghoul & magus).",
    class = "DEATHKNIGHT",
    specId = 252,
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
            { id = 55090, label = 'Scourge Strike' },
            { id = 85948, label = 'Festering Strike' },
            { id = 455397, label = 'Festering Scythe' },
            { id = 1247378, label = 'Putrefy' },
            { id = 77575, label = 'Outbreak' },
            { id = 63560, label = 'Dark Transformation' },
            { id = 49206, label = 'Summon Gargoyle' },
            { id = 42650, label = 'Army of the Dead' },
            { id = 207317, label = 'Epidemic' },
            { id = 115989, label = 'Unholy Blight' },
            { id = 275699, label = 'Apocalypse' },
        },

        auraIDs = {
            { id = 191587, label = 'Virulent Plague (target disease)' },
            { id = 115989, label = 'Unholy Blight (target disease/aura)' },
            { id = 63560, label = 'Dark Transformation (buff)' },
            { id = 49530, label = 'Sudden Doom (proc; verify)' },
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
