# Audit & Pull Request: RothSecretTester — Retail 12.1 Hardening & Runtime Lifecycle

**Target Addon:** `RothSecretTester`  
**Location:** `C:\Development\WoWDevAddons\_Addons\RothSecretTester`  
**Remote Tracking:** `github-roth-secret-tester` (`main`, `fix/retail-12-1-access-boundary-2026-08-29`)  
**Target Client:** World of Warcraft Retail 12.1.0 (`Interface: 120100`)  
**Verified Source Baseline:** `12.1.0.69497`  
**Auditor:** Neomorph Addon Engineering Workspace Agent  
**Date:** September 8, 2026  

---

## 1. Executive Summary & Current Addon State

`RothSecretTester` (RST2) is an empirical research and diagnostic harness designed to identify, record, and classify `SecretValue` and `SecretTable` behaviors across World of Warcraft API surfaces under Midnight / Retail 12.x conditions. 

The harness maintains a persistent multidimensional observation database (`schema.lua`, stored in `RothSecretTesterDB.schema`) that attributes whether API return paths produce secret or clear values according to operational context (in/out of combat, instance types, encounter states, and group configurations). It includes passive event listening (`Tester/tester.lua`), active structured test suites (`Tester/suites.lua`), interactive class modules (`Modules/BDK.lua`, `FDK.lua`, `UDK.lua`), error classification and flood suppression (`doctor.lua`), and a multi-mode report/export UI (`ui.lua`).

### Key Findings Matrix

| Audit Dimension | Status | Severity | Notes |
| :--- | :--- | :--- | :--- |
| **Interface Compatibility** | **OUTDATED** | Moderate | Local TOC declares `120000, 120001`; requires `120100`. |
| **12.1 Access Boundary** | **CRITICAL DEFECT** | High / Taint | Local `safe.lua` lacks `canaccessvalue()`; uses forbidden `scrubsecretvalues()` declassification anti-pattern and accesses `type(v)` prior to accessibility checks. Remote fix branch resolved this in `safe.lua`. |
| **Slash Command Integrity** | **COLLISION** | Moderate | Declares only `/rst`, colliding with `RothSpellTracker`. Needs secondary aliases (`/rothsct`, `/rstest`). |
| **Runtime Ownership (RT-AUDIT-002)** | **DEFECTS FOUND** | High | Unhandled `PLAYER_REGEN_ENABLED` in `core.lua` breaks combat reset deferral; redundant `ReloadUI()` in `ui.lua` popup bypasses combat lockdown; orphaned `ADDON_LOADED` listener in `tester.lua`; anonymous frame leaks in `suites.lua`. |
| **SavedVariables Defaults (RT-AUDIT-001)** | **PASS / CLEAN** | Low | Deep copy pattern `deepcopy(db, DEFAULTS)` isolates `DEFAULTS` from live mutation. Minor cleanup needed on redundant nested deep-copy. |
| **Dead Legacy Code** | **DEFECT** | Low | `createDropdown` using deprecated `UIDropDownMenuTemplate` in `ui.lua` is unused. |

---

## 2. Analysis of Remote GitHub Updates (`fix/retail-12-1-access-boundary-2026-08-29`)

A detailed comparison between `HEAD:_Addons/RothSecretTester` and `remotes/github-roth-secret-tester/fix/retail-12-1-access-boundary-2026-08-29` reveals 9 upstream commits focusing on the **Retail 12.1 Diagnostic Value Boundary**:

### 1. What Remote GitHub Fixed
- **TOC Update**: Bumped interface to `120100`, version to `1.7.0`, and added `## X-Verified-Build: 12.1.0.69497`.
- **`safe.lua` Overhaul**:
  - Implemented `canaccessvalue()` as the **mandatory first operation** on any untrusted runtime value via `CanAccessValue(value)`.
  - Prohibited any `type()`, equality comparison, string coercion, table indexing, or iteration on inaccessible values.
  - Eliminated `scrubsecretvalues()` as a classification fallback (scrubbing is not a classification or access-check primitive).
  - Added `Safe:CanAccess(value)` predicate.
  - Returns unambiguous `<inaccessible>` markers for inaccessible values and `<inaccessible_key>` for inaccessible table keys.
- **Specification & Contract Documentation**:
  - Added `Docs/SAFE_BOUNDARY_12_1.md` detailing the 10 rules governing untrusted data handling in Retail 12.1.
- **Automated Regression Suite**:
  - Added `tests/safe_12_1_spec.lua` validating boundary handling for throwing `__tostring`, throwing `__index`, inaccessible keys, secret tables, cyclic tables, and bounded string truncations.

### 2. What Remote GitHub Missed (Gaps Addressed by This PR)
1. **Slash Command Conflict**: Did not provide alternative slash aliases (`/rothsct`, `/rstest`) to resolve the namespace collision with `RothSpellTracker`.
2. **Broken Combat Reset Queue**: Left `PLAYER_REGEN_ENABLED` unhandled in `core.lua`, so queued resets never fire.
3. **Combat Lockdown Breach in UI Reset**: Left `ReloadUI()` immediately after `Addon:ResetAll()` in `ui.lua`'s `StaticPopupDialogs["RST_RESET_DB"]`.
4. **Orphaned Event Listener**: Handshake frame `f2` in `Tester/tester.lua` does not unregister `ADDON_LOADED`.
5. **Frame Allocation Leak in Aura Watch**: Repeated invocations of `suites.lua` create uncollected anonymous frames.
6. **Dead Legacy Template Usage**: Left unused `createDropdown` referencing `UIDropDownMenuTemplate`.

---

## 3. Detailed Audit Findings & Technical Rationale

### Finding 1: Retail 12.1 Value-Access Boundary & Inaccessible Proxies
- **Rule Reference**: `Docs/SAFE_BOUNDARY_12_1.md`, Retail 12.1 C-Engine Security Model.
- **Problem**: In local `safe.lua` (v1.6.4):
  ```lua
  function Safe:IsSecret(v)
      if type(issecretvalue) == "function" then
          local ok, r = pcall(issecretvalue, v)
          if ok and r then return true end
      end
      if type(v) == "table" and type(issecrettable) == "function" then ... end
      local okScrub, r1 = try_scrub(v)
      if okScrub and v ~= nil and r1 == nil then return true end
  end
  ```
  In Retail 12.1, restricted runtime contexts wrap inaccessible combat or aura values in proxy objects whose metatables throw or trigger taint upon direct operations (`type(v)`, `v == nil`, `tostring(v)`, indexing). Furthermore, `scrubsecretvalues` returns nil for secret values, but relying on this side effect is dangerous and violates client access rules.
- **Solution**: Port the canonical `Safe` implementation from `fix/retail-12-1-access-boundary-2026-08-29` where `canaccessvalue` is queried first before any operation.

### Finding 2: Slash Command Namespace Collision with `RothSpellTracker`
- **Rule Reference**: Addon Engineering Guidelines, Shared Alias Disambiguation.
- **Problem**: Both addons define `SLASH_ROTHSECRETT1 = "/rst"` and `SLASH_ROTHSPELLTRACKER1 = "/rst"`. Whichever addon initializes its slash table last wins `/rst`. `RothSecretTester` currently provides zero alternative aliases. If `RothSpellTracker` is loaded, user access to `/rst` for `RothSecretTester` is lost.
- **Solution**: Register secondary and tertiary aliases:
  ```lua
  SLASH_ROTHSECRETT1 = "/rst"
  SLASH_ROTHSECRETT2 = "/rothsct"
  SLASH_ROTHSECRETT3 = "/rstest"
  ```
  Update the usage message to inform the user of both aliases.

### Finding 3: Broken Combat Reset Deferral in `core.lua` (RT-AUDIT-002)
- **Rule Reference**: RT-AUDIT-002 (Single runtime owner & event lifecycle completeness).
- **Problem**: In `core.lua` line 924:
  ```lua
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  ```
  In `Addon:ResetAll()` line 542:
  ```lua
  if InCombatLockdown and InCombatLockdown() then
      self._pendingReset = true
      self:Warn("RESET", "queued (combat lockdown); will reset after leaving combat.")
      return
  end
  ```
  However, in `f:SetScript("OnEvent", ...)` (lines 926–954), there is no branch for `PLAYER_REGEN_ENABLED`! The event is consumed silently, and `self._pendingReset` is never processed.
- **Solution**: Handle `PLAYER_REGEN_ENABLED` in `f:SetScript("OnEvent")`:
  ```lua
  elseif event == "PLAYER_REGEN_ENABLED" then
      if Addon._pendingReset then
          Addon:ResetAll()
      end
  ```

### Finding 4: Premature `ReloadUI()` in UI Reset Dialog
- **Rule Reference**: Protected API restrictions during combat lockdown.
- **Problem**: In `ui.lua` lines 328–331:
  ```lua
  OnAccept = function()
      Addon:ResetAll()
      ReloadUI()
  end,
  ```
  When accepted in combat, `Addon:ResetAll()` sets `_pendingReset = true` and defers reload. But line 330 immediately calls `ReloadUI()`, ignoring the deferral and immediately triggering a reload (or an error if reload is blocked in combat).
- **Solution**: Remove the trailing `ReloadUI()`, as `Addon:ResetAll()` already calls `ReloadUI()` when out of combat.

### Finding 5: Leaked Handshake Listener in `Tester/tester.lua` (RT-AUDIT-002)
- **Rule Reference**: Event hygiene and lifecycle cleanup.
- **Problem**: In `Tester/tester.lua` lines 187–195:
  ```lua
  local f2 = CreateFrame("Frame")
  f2:RegisterEvent("ADDON_LOADED")
  f2:SetScript("OnEvent", function(_, _, name)
      if name ~= "RothSecretTester" then return end
      Tester.READY = true
      if _G.RothSecretTesterCore then
          _G.RothSecretTesterCore:RegisterTester(Tester)
      end
  end)
  ```
  `f2` remains registered for every addon loaded after `RothSecretTester`, executing redundant Lua callbacks.
- **Solution**: Unregister `ADDON_LOADED` immediately after handling `RothSecretTester`.

### Finding 6: Anonymous Frame Allocation Leak in `Tester/suites.lua`
- **Rule Reference**: Widget allocation lifecycle.
- **Problem**: In `suites.lua` line 904, every invocation of the 15-second aura watch executes:
  ```lua
  local f = CreateFrame("Frame")
  ```
  WoW UI frames cannot be garbage collected. Repeated runs permanently leak frames in memory.
- **Solution**: Cache and reuse `Suites._auraWatchFrame`.

### Finding 7: Dead UIDropDownMenu Code in `ui.lua`
- **Rule Reference**: Dragonflight / TWW / Midnight UI Modernization (removal of deprecated UIDropDownMenu).
- **Problem**: `ui.lua` lines 39–82 defines `createDropdown` using `UIDropDownMenuTemplate`. This function is never invoked anywhere in the codebase.
- **Solution**: Delete the unused helper to eliminate legacy template instantiation.

---

## 4. Proposed Code Changes (PR Diffs)

### Change 1: `RothSecretTester.toc`
```diff
--- a/RothSecretTester.toc
+++ b/RothSecretTester.toc
@@ -1,10 +1,11 @@
-## Interface: 120000, 120001
+## Interface: 120100
 ## Title: Roth Secret Tester 2
-## Notes: SecretValue research harness (Midnight). Export defaults to Log; Report is filtered view.
+## Notes: SecretValue research harness for Retail 12.1. Export defaults to Log; Report is a filtered view.
 ## Author: Neomorph
-## Version: 1.6.4
+## Version: 1.7.0
 ## SavedVariables: RothSecretTesterDB
 ## OptionalDeps: !BugGrabber, BugSack
+## X-Verified-Build: 12.1.0.69497
 
 core.lua
 safe.lua
```

---

### Change 2: `safe.lua`
```diff
--- a/safe.lua
+++ b/safe.lua
@@ -1,12 +1,11 @@
 -- safe.lua
--- Centralized SecretValue hardening helpers.
+-- Centralized SecretValue hardening helpers for Retail 12.1.
 --
--- IMPORTANT RULES (Midnight / SecretValue):
---  - Never use potentially secret values as table keys.
---  - Never concatenate or tostring() potentially secret values.
---  - Never do boolean tests on potentially secret values (if v then).
---
--- This module provides normalized, non-secret string keys and safe-to-string.
+-- Boundary rule:
+--  - canaccessvalue() is the first operation on an untrusted runtime value.
+--  - inaccessible values are never typed, compared, formatted, indexed, logged,
+--    persisted, or used as table keys.
+--  - pcall is an error boundary only; it never declassifies a value.
 
 local Addon = _G.RothSecretTesterCore
 if not Addon then return end
@@ -16,184 +15,226 @@ local Safe = Addon.Safe
 
 local type = type
 local tostring = tostring
+local tonumber = tonumber
 local pcall = pcall
+local pairs = pairs
+local format = string.format
 
--- Patch 12.0+: secret helpers
+local canaccessvalue = _G.canaccessvalue
 local issecretvalue = _G.issecretvalue
 local issecrettable = _G.issecrettable
-local scrubsecretvalues = _G.scrubsecretvalues
 
-local function try_scrub(v)
-    if type(scrubsecretvalues) ~= "function" then return true, v end
-    -- Signature is documented as: scrubsecretvalues(...) -> ... where secret inputs become nil.
-    local ok, r1 = pcall(scrubsecretvalues, v)
-    if not ok then
-        return false, v
+local function CanAccessValue(value)
+    if type(canaccessvalue) == "function" then
+        local ok, accessible = pcall(canaccessvalue, value)
+        return ok and accessible == true
     end
-    return true, r1
-end
 
-function Safe:IsSecret(v)
-    -- NOTE: in 12.0+ there are multiple secret types (values, tables).
+    -- Compatibility fallback for older clients.
     if type(issecretvalue) == "function" then
-        local ok, r = pcall(issecretvalue, v)
-        if ok and r then return true end
+        local ok, secret = pcall(issecretvalue, value)
+        return ok and secret ~= true
+    end
+
+    return true
+end
+
+local function IsSecretTable(value)
+    if type(issecrettable) ~= "function" then
+        return false
+    end
+
+    local ok, secret = pcall(issecrettable, value)
+    return ok and secret == true
+end
+
+function Safe:CanAccess(value)
+    return CanAccessValue(value)
+end
+
+function Safe:IsSecret(value)
+    if not CanAccessValue(value) then
+        return true
+    end
+
+    if type(issecretvalue) == "function" then
+        local ok, secret = pcall(issecretvalue, value)
+        if ok and secret == true then
+            return true
+        end
+    end
+
+    -- type() is legal only after the accessibility gate above.
+    if type(value) == "table" and IsSecretTable(value) then
+        return true
     end
 
-    if type(v) == "table" and type(issecrettable) == "function" then
-        local ok, r = pcall(issecrettable, v)
-        if ok and r then return true end
-    end
-
-    -- Fallback: scrubsecretvalues returns nil for secret inputs.
-    local okScrub, r1 = try_scrub(v)
-    if okScrub and v ~= nil and r1 == nil then
-        return true
-    end
-
     return false
 end
 
-function Safe:SafeToString(v)
-    if self:IsSecret(v) then
+function Safe:SafeToString(value)
+    if not CanAccessValue(value) then
+        return "<inaccessible>"
+    end
+    if self:IsSecret(value) then
         return "<secret>"
     end
-    local ok, s = pcall(tostring, v)
-    if ok then return s end
+
+    local ok, text = pcall(tostring, value)
+    if ok then
+        return text
+    end
     return "<tostring-error>"
 end
 
-function Safe:Key(v, opts)
+function Safe:Key(value, opts)
     opts = (type(opts) == "table") and opts or {}
 
-    if v == nil then
-        return opts.nilPlaceholder or "<nil>"
+    if not CanAccessValue(value) then
+        return opts.inaccessiblePlaceholder or opts.secretPlaceholder or "<inaccessible>"
     end
-
-    if self:IsSecret(v) then
+    if self:IsSecret(value) then
         return opts.secretPlaceholder or "<secret>"
     end
 
-    local tv = type(v)
-    if tv == "string" then
-        if v ~= "" then return v end
+    local valueType = type(value)
+    if valueType == "nil" then
+        return opts.nilPlaceholder or "<nil>"
+    end
+    if valueType == "string" then
+        if value ~= "" then
+            return value
+        end
         return opts.emptyPlaceholder or "<empty>"
     end
-
-    if tv == "boolean" then
-        return v and "true" or "false"
+    if valueType == "boolean" then
+        return value and "true" or "false"
     end
-
-    if tv == "number" then
+    if valueType == "number" then
         if opts.collapseNumbers then
             return opts.numberPlaceholder or "[*]"
         end
-        return self:SafeToString(v)
+        return self:SafeToString(value)
     end
 
-    return "<" .. tv .. ">"
+    return "<" .. valueType .. ">"
 end
 
-function Safe:KeyNoIndex(v)
-    -- Stricter key normalizer: never attempts to represent the value itself.
-    -- Useful if you're unsure about toString behavior.
-    if v == nil then return "<nil>" end
-    if self:IsSecret(v) then return "<secret>" end
-    local tv = type(v)
-    if tv == "string" then return v end
-    if tv == "number" then return "<num>" end
-    if tv == "boolean" then return v and "true" or "false" end
-    return "<" .. tv .. ">"
+function Safe:KeyNoIndex(value)
+    if not CanAccessValue(value) then
+        return "<inaccessible>"
+    end
+    if self:IsSecret(value) then
+        return "<secret>"
+    end
+
+    local valueType = type(value)
+    if valueType == "nil" then return "<nil>" end
+    if valueType == "string" then return value end
+    if valueType == "number" then return "<num>" end
+    if valueType == "boolean" then return value and "true" or "false" end
+    return "<" .. valueType .. ">"
 end
 
--- -----------------------------------------
--- SavedVariables-safe sanitization helpers
--- -----------------------------------------
--- Goal: never persist SecretValues or huge nested tables in SavedVariables.
--- Used by Doctor + Log samples.
-
-local function _truncate(s, maxLen)
-    if type(s) ~= "string" then return s end
-    maxLen = tonumber(maxLen) or 160
-    if #s <= maxLen then return s end
-    return s:sub(1, maxLen) .. "…"
+local function Truncate(text, maxLength)
+    maxLength = tonumber(maxLength) or 160
+    if #text <= maxLength then
+        return text
+    end
+    return text:sub(1, maxLength) .. "…"
 end
 
-local function _sanitizePrimitive(self, v, opts)
+local function SanitizePrimitive(self, value, opts)
     opts = (type(opts) == "table") and opts or {}
 
-    if v == nil then return nil end
-
-    -- Extra hardening: scrub first (handles cases where issecretvalue/issecrettable are absent or incomplete).
-    local okScrub, scrubbed = try_scrub(v)
-    if okScrub and scrubbed == nil and v ~= nil then
-        return opts.secretPlaceholder or "<secret>"
+    if not CanAccessValue(value) then
+        return opts.inaccessiblePlaceholder or opts.secretPlaceholder or "<inaccessible>"
     end
-
-    if self:IsSecret(v) then
+    if self:IsSecret(value) then
         return opts.secretPlaceholder or "<secret>"
     end
 
-    local tv = type(v)
-    if tv == "string" then
-        return _truncate(v, opts.maxStringLen)
+    local valueType = type(value)
+    if valueType == "nil" then
+        return nil
     end
-    if tv == "number" then
+    if valueType == "string" then
+        return Truncate(value, opts.maxStringLen)
     end
-    if tv == "boolean" then
-        return v and true or false
+    if valueType == "number" then
         if opts.collapseNumbers then
             return opts.numberPlaceholder or "[*]"
         end
-        return v
+        return value
     end
-    if tv == "boolean" then
+    if valueType == "boolean" then
         return value
     end
 
-    -- Keep SavedVariables stable: represent non-serializable types as strings.
-    return "<" .. tv .. ">"
+    return "<" .. valueType .. ">"
 end
 
-local function _sanitizeTable(self, t, depth, visited, opts)
-    if t == nil then return nil end
+local function SanitizeValue(self, value, depth, visited, opts)
     opts = (type(opts) == "table") and opts or {}
 
-    -- scrub/secret check must happen BEFORE type(table) iteration
-    local okScrub, scrubbed = try_scrub(t)
-    if okScrub and scrubbed == nil and t ~= nil then
-        return (opts and opts.secretPlaceholder) or "<secret>"
+    if not CanAccessValue(value) then
+        return opts.inaccessiblePlaceholder or opts.secretPlaceholder or "<inaccessible>"
     end
-
-    if self:IsSecret(t) then return (opts and opts.secretPlaceholder) or "<secret>" end
-    if type(t) ~= "table" then return _sanitizePrimitive(self, t, opts) end
+    if self:IsSecret(value) then
+        return opts.secretPlaceholder or "<secret>"
+    end
+
+    local valueType = type(value)
+    if valueType ~= "table" then
+        return SanitizePrimitive(self, value, opts)
     end
 
+    if IsSecretTable(value) then
+        return opts.secretPlaceholder or "<secret>"
+    end
+
     depth = tonumber(depth) or 2
-    if depth <= 0 then return "<table>" end
+    if depth <= 0 then
+        return "<table>"
+    end
 
     visited = visited or {}
-    if visited[t] then return "<cycle>" end
-    visited[t] = true
+    if visited[value] then
+        return "<cycle>"
+    end
+    visited[value] = true
 
-    opts = (type(opts) == "table") and opts or {}
     local maxItems = tonumber(opts.maxItems) or 50
+    local output = {}
+    local itemCount = 0
 
-    local out = {}
-    local n = 0
-    for k, v in pairs(t) do
-        n = n + 1
-        if n > maxItems then
-            out["<truncated>"] = string.format("…(+%d)", n - maxItems)
+    for key, child in pairs(value) do
+        itemCount = itemCount + 1
+        if itemCount > maxItems then
+            output["<truncated>"] = format("…(+%d)", itemCount - maxItems)
             break
         end
-        -- Keys must be safe + deterministic.
-        local sk = self:Key(k, { collapseNumbers = true, secretPlaceholder = "<secret_key>" })
-        out[sk] = _sanitizeTable(self, v, depth - 1, visited, opts)
+
+        local safeKey = self:Key(key, {
+            collapseNumbers = true,
+            inaccessiblePlaceholder = "<inaccessible_key>",
+            secretPlaceholder = "<secret_key>",
+        })
+        output[safeKey] = SanitizeValue(self, child, depth - 1, visited, opts)
     end
 
-    visited[t] = nil
-    return out
+    visited[value] = nil
+    return output
 end
 
-function Safe:Sanitize(v, depth, opts)
-    return _sanitizeTable(self, v, depth, nil, opts)
+function Safe:Sanitize(value, depth, opts)
+    return SanitizeValue(self, value, depth, nil, opts)
 end
```

---

### Change 3: `core.lua`
```diff
--- a/core.lua
+++ b/core.lua
@@ -26,7 +26,7 @@ local pcall = pcall
 local xpcall = xpcall
 
 local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
 local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
 
-Addon.VERSION = "1.6.4"
+Addon.VERSION = "1.7.0"
 
 -- Forward decl modules (filled by other lua files)
@@ -169,7 +169,6 @@ function Addon:GetDB()
     if type(_G.RothSecretTesterDB) ~= "table" then _G.RothSecretTesterDB = {} end
     local db = _G.RothSecretTesterDB
     deepcopy(db, DEFAULTS)
-    deepcopy(db.settings, DEFAULTS.settings)
 
     -- One-time migration for defaults / UX changes.
@@ -944,6 +943,10 @@ f:SetScript("OnEvent", function(_, event, ...)
                 end
             elseif event == "PLAYER_LOGIN" then
                 if Addon.UI and Addon.UI.RefreshStatus then Addon.UI:RefreshStatus() end
+            elseif event == "PLAYER_REGEN_ENABLED" then
+                if Addon._pendingReset then
+                    Addon:ResetAll()
+                end
             end
         end)
     else
@@ -957,6 +960,8 @@ end)
 -- Slash
 -- --------------------------------
 SLASH_ROTHSECRETT1 = "/rst"
+SLASH_ROTHSECRETT2 = "/rothsct"
+SLASH_ROTHSECRETT3 = "/rstest"
 SlashCmdList["ROTHSECRETT"] = function(msg)
     msg = msg or ""
     local cmd, rest = msg:match("^(%S+)%s*(.-)%s*$")
@@ -1008,7 +1013,7 @@ SlashCmdList["ROTHSECRETT"] = function(msg)
         return
     end
 
-    Addon:Info("CORE", "Usage: /rst [show|hide|new|export|exportfull|audit|reset|bdk|fdk|udk|passive on|passive off|bugsack]")
+    Addon:Info("CORE", "Usage: /rst (or /rothsct, /rstest) [show|hide|new|export|exportfull|audit|reset|bdk|fdk|udk|passive on|passive off|bugsack]")
     if Addon.UI then Addon.UI:Toggle(true) end
 end
```

---

### Change 4: `ui.lua`
```diff
--- a/ui.lua
+++ b/ui.lua
@@ -36,50 +36,6 @@ local function createButton(parent, text, w, h)
     return b
 end
 
-local function createDropdown(parent, label, width, getItems, onSelect)
-    local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
-    dd:SetSize(width + 40, 32)
-    dd._label = createLabel(parent, "GameFontNormalSmall")
-    dd._label:SetText(label)
-    dd._selectedValue = nil
-    dd._selectedText = nil
-    dd._getItems = getItems
-    dd._onSelect = onSelect
-
-    UIDropDownMenu_SetWidth(dd, width)
-    UIDropDownMenu_SetText(dd, label)
-
-    UIDropDownMenu_Initialize(dd, function(self, level)
-        if level ~= 1 then return end
-        local items = {}
-        if type(dd._getItems) == "function" then
-            items = dd._getItems() or {}
-        end
-        for i = 1, #items do
-            local it = items[i]
-            local info = UIDropDownMenu_CreateInfo()
-            info.text = it.text
-            info.value = it.value
-            info.func = function()
-                dd._selectedValue = it.value
-                dd._selectedText = it.text
-                UIDropDownMenu_SetText(dd, it.text)
-                if type(dd._onSelect) == "function" then
-                    dd._onSelect(it.value, it.text)
-                end
-            end
-            UIDropDownMenu_AddButton(info, level)
-        end
-    end)
-
-    function dd:SetSelectedValue(value, text)
-        dd._selectedValue = value
-        dd._selectedText = text or value
-        UIDropDownMenu_SetText(dd, dd._selectedText or label)
-    end
-
-    return dd
-end
-
 local function normalize(s)
     if type(s) ~= "string" then return "" end
     return strlower(s)
@@ -327,7 +283,6 @@ function UI:Init()
             preferredIndex = 3,
             OnAccept = function()
                 Addon:ResetAll()
-                ReloadUI()
             end,
         }
     end
```

---

### Change 5: `Tester/tester.lua`
```diff
--- a/Tester/tester.lua
+++ b/Tester/tester.lua
@@ -191,6 +191,7 @@ local f2 = CreateFrame("Frame")
 f2:RegisterEvent("ADDON_LOADED")
 f2:SetScript("OnEvent", function(_, _, name)
     if name ~= "RothSecretTester" then return end
+    f2:UnregisterEvent("ADDON_LOADED")
     Tester.READY = true
     if _G.RothSecretTesterCore then
         _G.RothSecretTesterCore:RegisterTester(Tester)
```

---

### Change 6: `Tester/suites.lua`
```diff
--- a/Tester/suites.lua
+++ b/Tester/suites.lua
@@ -901,7 +901,8 @@ function Lists:Run(args)
         local watchSecs = 15
         core:Line(string.format("[%s] aura-watch: %ds (player+target)", suiteName, watchSecs))
 
-        local f = CreateFrame("Frame")
+        Suites._auraWatchFrame = Suites._auraWatchFrame or CreateFrame("Frame")
+        local f = Suites._auraWatchFrame
         local pending = {}
         local prev = {}
 
```

---

## 5. Implementation & Verification Plan

### Automated Regression Verification
1. Run `texlua tests/safe_12_1_spec.lua safe.lua` to prove that:
   - Inaccessible values whose `__tostring` or `__index` throw errors do not crash or declassify.
   - Inaccessible values normalize to `<inaccessible>`.
   - Inaccessible keys normalize to `<inaccessible_key>`.
   - Secret tables normalize to `<secret>`.
   - Table sanitization respects recursion depth, string length truncation, cycle detection, and max item caps.
2. Static AST check:
   - Verify that no remaining calls to `scrubsecretvalues` exist.
   - Verify that no calls to `UIDropDownMenu` exist.
   - Verify `git diff --check` passes cleanly with no trailing whitespaces or syntax regressions.

### In-Game Live Verification Checklist
1. **Slash Command Disambiguation**:
   - Install both `RothSecretTester` and `RothSpellTracker`.
   - Test `/rst`, `/rothsct`, and `/rstest`. Confirm both addons can be configured simultaneously without collision.
2. **Combat Lockdown Safety & Deferred Reset**:
   - Engage combat.
   - Run `/rst reset` or click "Reset DB" in the UI. Confirm warning message `"queued (combat lockdown); will reset after leaving combat."` appears and UI is not reloaded prematurely.
   - Exit combat. Confirm `PLAYER_REGEN_ENABLED` fires, triggering `Addon:ResetAll()` and `ReloadUI()` cleanly without taint.
3. **Passive Combat Aura & Power Testing**:
   - Run `/rst passive on`.
   - Engage a target dummy or dungeon boss.
   - Confirm that `UNIT_AURA` and `UNIT_POWER_UPDATE` events are throttled at 0.5s intervals and do not throw metatable indexing errors on inaccessible aura payloads.
   - Run `/rst export` -> `Report` and verify that inaccessible aura fields are recorded with `<inaccessible>` without overflowing `RothSecretTesterDB`.
