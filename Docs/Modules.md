# Modules

A **module** is an event-driven probe that can be started/stopped from the UI.

Design goals:

- no taint / no protected calls
- low chat spam (log to session lines + schema instead)
- safe handling of secret values: never stringify/concatenate a value unless wrapped in `pcall`

## Interface

A module is a Lua table registered via `RothSecretTester_RegisterModule(Mod)`:

Required fields:

- `id` (string, stable key)
- `name` (human label)
- `desc` (short description)

Optional fields:

- `addonName` (for LoadOnDemand external modules)

Methods:

- `:Init(core)` – one-time setup (create frames, cache functions)
- `:Start(ctx)` – register events / start timers
- `:Stop(ctx)` – unregister events / cleanup

## Schema observation pattern

Use the schema as the canonical dataset:

- `Core.Schema:Observe(apiKey, caseKey, path, value, meta, source)`

Notes:

- keep `apiKey` stable (ex: `UnitGUID`, `C_UnitAuras.GetAuraDataByIndex`)
- keep `caseKey` stable and explicit (ex: `unit=player`, `spellId=49998`)
- `path` should identify the return/field (ex: `ret#1`, `aura.duration`, `aura.points[1]`)
- `source` should identify the module (`module:<id>`)

## Template / Boilerplate

Below is a standard boilerplate for a new testing module.

```lua
local _, Addon = ...
local Mod = {
    id = "MyModule",
    name = "My Test Module",
    desc = "Example module to safely test API returns",
}

function Mod:Init(core)
    self.core = core
    self.frame = CreateFrame("Frame")
    self.frame:SetScript("OnEvent", function(_, event, ...)
        if self[event] then self[event](self, ...) end
    end)
end

function Mod:Start(ctx)
    self.session = ctx.session
    self.frame:RegisterEvent("UNIT_AURA")
    self.core:Info("MODULE", "MyModule started")
end

function Mod:Stop(ctx)
    self.frame:UnregisterAllEvents()
    self.session = nil
    self.core:Info("MODULE", "MyModule stopped")
end

function Mod:UNIT_AURA(unit)
    if unit ~= "player" then return end
    
    local data = C_UnitAuras.GetAuraDataByIndex("player", 1, "HELPFUL")
    if data then
        -- Safely record the observation into the Schema
        self.core.Schema:Observe("C_UnitAuras", "player,helpful", "points", data.points, nil, "module:MyModule")
    end
end

_G.RothSecretTester_RegisterModule(Mod)
```

## Best Practices (Оптимизация и Безопасность)

1. **Троттлинг эвентов (Throttling)**: События вроде `UNIT_AURA` или `UNIT_POWER_UPDATE` могут срабатывать десятки раз в секунду. Используйте кулдауны (`GetTime()`), `C_Timer` или `OnUpdate` с ограничением частоты (например, не чаще 0.5с), чтобы избежать лагов.
2. **Ограничение глубины рекурсии**: Если вы пишете свой сканер таблиц — всегда передавайте ограничение по глубине (`depth`, желательно не более 3-4), чтобы клиент не завис при обходе закольцованных таблиц Blizzard.
3. **Безопасная работа с секретными данными**: Никогда не вызывайте `tostring()` и не конкатенируйте (`..`) сырые данные, которые могут быть секретными (`isSecure`). Передавайте значения в `Schema:Observe` как есть, она безопасно их обработает.
4. **Ленивые вычисления**: Не пытайтесь перебирать 100 000 ID в одном цикле (например, заклинания). Разбивайте задачу на корутины (`coroutine.create`) или таймеры, чтобы игра не "замирала" (freeze).
5. **Группировка в логах**: Старайтесь не спамить в метод `:Line()`. Ядро теперь автоматически группирует одинаковые строки, но лучше изначально минимизировать вывод незначимых данных.
