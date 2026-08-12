-- RothSecretTester Integration (Core)
-- BugGrabber/BugSack: optional, no hard deps.

local Addon = _G.RothSecretTesterCore
if not Addon then return end

local Integration = {}
Addon.Integration = Integration

local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded

function Integration:Init(core)
    self.core = core
end

local function bugGrabberAvailable()
    return IsAddOnLoaded and IsAddOnLoaded("!BugGrabber") and type(_G.BugGrabber) == "table" and type(_G.BugGrabber.StoreError) == "function"
end

local function bugSackAvailable()
    return IsAddOnLoaded and IsAddOnLoaded("BugSack") and type(_G.BugSack) == "table"
end

function Integration:OpenBugSack()
    if _G.BugSack and type(_G.BugSack.OpenSack) == "function" then
        _G.BugSack:OpenSack()
        return
    end
    if SlashCmdList and SlashCmdList.BugSack then
        SlashCmdList.BugSack("show")
    end
end

function Integration:MaybeReportError(errRec)
    local core = self.core or Addon
    local db = core:GetDB()
    local s = db.settings and db.settings.bugGrabber or {}
    if not s.enabled then return end
    if errRec.phase == "probe" and not s.reportProbe then return end
    if not bugGrabberAvailable() then return end

    local msg = ("[RST][%s/%s/%s] %s"):format(errRec.origin, errRec.phase, errRec.cause, errRec.message)
    local err = { message = msg, session = core.activeSession and core.activeSession.id or 0, time = time() }
    pcall(function() _G.BugGrabber:StoreError(err) end)
    if bugSackAvailable() and _G.BugSack.UpdateDisplay then pcall(function() _G.BugSack:UpdateDisplay() end) end
end

function Integration:MaybeReportFinding(category, level, api, key, rec)
    local core = self.core or Addon
    local db = core:GetDB()
    local s = db.settings and db.settings.bugGrabber or {}
    if not s.enabled or not s.reportFindings then return end
    if not bugGrabberAvailable() then return end

    local msg = ("[RST][FINDING][%s][L%s] %s :: %s (x%d)"):format(category, tostring(level), api, key, rec.count or 1)
    local err = { message = msg, session = core.activeSession and core.activeSession.id or 0, time = time() }
    pcall(function() _G.BugGrabber:StoreError(err) end)
    if bugSackAvailable() and _G.BugSack.UpdateDisplay then pcall(function() _G.BugSack:UpdateDisplay() end) end
end
