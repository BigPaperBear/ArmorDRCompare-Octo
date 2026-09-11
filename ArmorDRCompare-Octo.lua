-- Armor DR Compare (Octo)
-- OctoWoW vanilla 1.12.1
-- Version 1.3.0
--
-- Important Classic Era behavior:
--   * GameTooltip_ShowCompareItem uses ShoppingTooltip:SetCompareItem(...)
--   * The signed stat delta can be placed on the MAIN hovered GameTooltip,
--     not only on ShoppingTooltip1/2.
--
-- This version therefore processes BOTH sides after Blizzard builds a compare.

local ADDON_NAME = ...

local VERSION = "1.3.0"
-- "% DR" appears in every annotation we write; used to detect already-annotated lines.
local MARKER = "% DR"

-- Display mode: true = "±X Armor (DR%)", false = "DR% only".
-- Loaded from SavedVariables on PLAYER_LOGIN; default is full mode.
local showArmorDelta = true

-- Module-level so the slash command can reset it to force re-processing.
local vanillaMonitorLastState = nil

local DRUID_CLASS_ID = "DRUID"
local FORM_BEAR = 5
local FORM_DIRE_BEAR = 8
local FORM_MOONKIN = 31

local thickHideMultiplierCache

local function SafeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end

    local ok, a, b, c, d, e, f, g, h = pcall(func, ...)
    if not ok then
        return nil
    end

    return a, b, c, d, e, f, g, h
end

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value)
end

local function ToNumber(value)
    if value == nil or IsSecret(value) then
        return nil
    end
    return tonumber(value)
end

local function GetPlayerArmorAndLevel()
    local _, effectiveArmor = UnitArmor("player")
    local level = UnitLevel("player")

    return ToNumber(effectiveArmor), ToNumber(level)
end

local function ArmorDR(armor, attackerLevel)
    armor = ToNumber(armor)
    attackerLevel = ToNumber(attackerLevel)

    if not armor or not attackerLevel or attackerLevel <= 0 then
        return nil
    end

    if armor < 0 then
        armor = 0
    end

    local denominatorConstant = 400 + (85 * attackerLevel)
    local dr = armor / (armor + denominatorConstant)

    if dr > 0.75 then
        dr = 0.75
    elseif dr < 0 then
        dr = 0
    end

    return dr
end

local function GetPlayerClassID()
    local _, classID = UnitClass("player")
    return classID
end

local function FindThickHideTalent()
    if GetPlayerClassID() ~= DRUID_CLASS_ID then
        return 0, 0
    end

    local thickHideName = SafeCall(GetSpellInfo, 16929)
    if not thickHideName
        or type(GetNumTalentTabs) ~= "function"
        or type(GetNumTalents) ~= "function"
        or type(GetTalentInfo) ~= "function" then
        return nil, nil
    end

    local numTabs = SafeCall(GetNumTalentTabs) or 0

    for tabIndex = 1, numTabs do
        local numTalents = SafeCall(GetNumTalents, tabIndex) or 0

        for talentIndex = 1, numTalents do
            local name, _, _, _, rank, maxRank = SafeCall(
                GetTalentInfo,
                tabIndex,
                talentIndex
            )

            if name == thickHideName then
                return ToNumber(rank) or 0, ToNumber(maxRank) or 0
            end
        end
    end

    return nil, nil
end

local function GetThickHideMultiplier()
    if thickHideMultiplierCache then
        return thickHideMultiplierCache
    end

    if GetPlayerClassID() ~= DRUID_CLASS_ID then
        thickHideMultiplierCache = 1
        return thickHideMultiplierCache
    end

    local rank = FindThickHideTalent()
    local bonus = 0

    if rank and rank > 0 then
        -- Vanilla ranks: 2%, 4%, 6%, 8%, 10%.
        bonus = 0.02 * rank
    elseif rank == nil and type(IsPlayerSpell) == "function" then
        -- Fallback for clients where the talent inspection API is unavailable.
        local classicRanks = {
            { 16933, 0.10 },
            { 16932, 0.08 },
            { 16931, 0.06 },
            { 16930, 0.04 },
            { 16929, 0.02 },
        }

        for _, talentRank in ipairs(classicRanks) do
            if SafeCall(IsPlayerSpell, talentRank[1]) then
                bonus = talentRank[2]
                break
            end
        end
    end

    thickHideMultiplierCache = 1 + bonus
    return thickHideMultiplierCache
end

local function GetArmorFormMultiplier()
    if GetPlayerClassID() ~= DRUID_CLASS_ID
        or type(GetShapeshiftFormID) ~= "function" then
        return 1, "Humanoid"
    end

    local formID = ToNumber(SafeCall(GetShapeshiftFormID))

    if formID == FORM_BEAR then
        return 2.8, "Bear Form"
    elseif formID == FORM_DIRE_BEAR then
        return 4.6, "Dire Bear Form"
    elseif formID == FORM_MOONKIN then
        return 4.6, "Moonkin Form"
    end

    return 1, "Humanoid"
end

local function GetItemArmorMultiplier()
    if GetPlayerClassID() ~= DRUID_CLASS_ID then
        return 1, "Humanoid"
    end

    local formMultiplier, formName = GetArmorFormMultiplier()
    return formMultiplier * GetThickHideMultiplier(), formName
end

local function FormatDRDelta(delta)
    local pct = delta * 100

    if math.abs(pct) < 0.0005 then
        pct = 0
    end

    local numberText
    if pct ~= 0 and math.abs(pct) < 0.01 then
        numberText = string.format("%+.3f%%", pct)
    else
        numberText = string.format("%+.2f%%", pct)
    end

    -- Use Blizzard's standard positive/negative comparison colors when
    -- available. Only the numeric percentage is colored; "DR" remains in
    -- the tooltip's normal text color.
    local green = GREEN_FONT_COLOR_CODE or "|cff20ff20"
    local red = RED_FONT_COLOR_CODE or "|cffff2020"
    local reset = FONT_COLOR_CODE_CLOSE or "|r"

    if pct > 0 then
        numberText = green .. numberText .. reset
    elseif pct < 0 then
        numberText = red .. numberText .. reset
    end

    return numberText .. " DR"
end

local function StripColorCodes(text)
    if not text or IsSecret(text) then
        return text
    end

    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("\194\160", " ")
    return text
end

local function Trim(text)
    if not text then
        return nil
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function AddUnique(tbl, value)
    if not value or value == "" then
        return
    end

    for _, old in ipairs(tbl) do
        if old == value then
            return
        end
    end

    table.insert(tbl, value)
end

local function GetArmorLabels()
    local labels = {}

    -- ARMOR is the most useful localized label in Classic.
    AddUnique(labels, Trim(ARMOR))

    -- ITEM_MOD_ARMOR_SHORT can be either a label or a format string depending
    -- on client/localization. Reduce it to its literal text.
    if ITEM_MOD_ARMOR_SHORT then
        local cleaned = ITEM_MOD_ARMOR_SHORT
        cleaned = cleaned:gsub("%%[%d%$]*[sdif]", "")
        cleaned = cleaned:gsub("[%+%-]", "")
        cleaned = Trim(cleaned)
        AddUnique(labels, cleaned)
    end

    -- English fallback.
    AddUnique(labels, "Armor")

    return labels
end

local function FindArmorLabel(text)
    if not text then
        return nil
    end

    local lower = text:lower()

    for _, label in ipairs(GetArmorLabels()) do
        local l = label:lower()
        local startPos, endPos = lower:find(l, 1, true)
        if startPos then
            return startPos, endPos, label
        end
    end

    return nil
end

local function FindSignedNumbers(text)
    local found = {}
    if not text then
        return found
    end

    local cursor = 1

    while true do
        local s, e, token = text:find("([%+%-]%s*[%d%.,]+)", cursor)
        if not s then
            break
        end

        local sign = token:match("^%s*([%+%-])")
        local digits = token:gsub("[^%d]", "")
        local value = tonumber(digits)

        if value then
            if sign == "-" then
                value = -value
            end

            table.insert(found, {
                startPos = s,
                endPos = e,
                value = value,
            })
        end

        cursor = e + 1
    end

    return found
end

local function FindArmorDelta(text)
    local plain = StripColorCodes(text)
    if not plain then
        return nil
    end

    if plain:find(MARKER, 1, true) then
        return nil
    end

    local armorStart, armorEnd = FindArmorLabel(plain)
    if not armorStart then
        return nil
    end

    local signed = FindSignedNumbers(plain)
    if #signed == 0 then
        return nil
    end

    -- Pick the signed number nearest the word "Armor".
    -- This handles all common Classic shapes:
    --   +25 Armor
    --   Armor +25
    --   119 Armor (+25)
    --   Armor (+25)
    local best, bestDistance

    for _, candidate in ipairs(signed) do
        local distance
        if candidate.endPos < armorStart then
            distance = armorStart - candidate.endPos
        elseif candidate.startPos > armorEnd then
            distance = candidate.startPos - armorEnd
        else
            distance = 0
        end

        if not bestDistance or distance < bestDistance then
            best = candidate
            bestDistance = distance
        end
    end

    -- Avoid accidentally interpreting a signed number far away in unrelated
    -- flavor/effect text. Comparison deltas sit close to the Armor label.
    if not best or bestDistance > 12 then
        return nil
    end

    return best.value
end

local function GetTooltipLine(tooltip, side, index)
    if not tooltip then
        return nil
    end

    local getterName = side == "left" and "GetLeftLine" or "GetRightLine"
    local getter = tooltip[getterName]

    if getter then
        local line = SafeCall(getter, tooltip, index)
        if line then
            return line
        end
    end

    -- Fallback for older/named tooltip layouts.
    if tooltip.GetName then
        local name = SafeCall(tooltip.GetName, tooltip)
        if name then
            return _G[name .. (side == "left" and "TextLeft" or "TextRight") .. index]
        end
    end

    return nil
end

local function GetTooltipItemLink(tooltip)
    if not tooltip or type(tooltip.GetItem) ~= "function" then
        return nil
    end

    local _, itemLink = SafeCall(tooltip.GetItem, tooltip)
    if itemLink and not IsSecret(itemLink) then
        return itemLink
    end

    return nil
end

local function AddUniqueLink(links, itemLink)
    if not itemLink then
        return
    end

    for _, oldLink in ipairs(links) do
        if oldLink == itemLink then
            return
        end
    end

    table.insert(links, itemLink)
end

local function AddShownTooltipLink(links, tooltip)
    if not tooltip then
        return
    end

    if tooltip.IsShown and not SafeCall(tooltip.IsShown, tooltip) then
        return
    end

    AddUniqueLink(links, GetTooltipItemLink(tooltip))
end

local function BuildComparisonContext(owner)
    if (owner == _G.ShoppingTooltip1 or owner == _G.ShoppingTooltip2)
        and owner.GetOwner then
        owner = SafeCall(owner.GetOwner, owner) or owner
    end

    local context = {
        newItemLink = GetTooltipItemLink(owner),
        oldItemLinks = {},
    }

    if owner and owner.shoppingTooltips then
        for _, tooltip in ipairs(owner.shoppingTooltips) do
            AddShownTooltipLink(context.oldItemLinks, tooltip)
        end
    end

    AddShownTooltipLink(context.oldItemLinks, _G.ShoppingTooltip1)
    AddShownTooltipLink(context.oldItemLinks, _G.ShoppingTooltip2)

    return context
end

local function GetIntrinsicItemArmor(itemLink)
    if not itemLink or IsSecret(itemLink) then
        return nil
    end

    local itemID = itemLink:match("item:(%d+)")
    if not itemID then
        return nil
    end

    -- A minimal item link deliberately omits permanent enchants, armor kits,
    -- gems, and random modifiers. It leaves the item's own armor and innate
    -- equip armor, which are the portions affected by Druid item-armor bonuses.
    local baseItemLink = "item:" .. itemID
    local stats

    if C_Item and type(C_Item.GetItemStats) == "function" then
        stats = SafeCall(C_Item.GetItemStats, baseItemLink)
    elseif type(GetItemStats) == "function" then
        stats = SafeCall(GetItemStats, baseItemLink)
    end

    if type(stats) ~= "table" then
        return nil
    end

    return ToNumber(stats.RESISTANCE0_NAME) or 0
end

local function FindIntrinsicArmorDelta(context, rawArmorDelta)
    if not context or not context.newItemLink then
        return nil
    end

    local newArmor = GetIntrinsicItemArmor(context.newItemLink)
    if newArmor == nil then
        return nil
    end

    if #context.oldItemLinks == 0 then
        return newArmor
    end

    local bestDelta
    local bestDistance

    for _, oldItemLink in ipairs(context.oldItemLinks) do
        local oldArmor = GetIntrinsicItemArmor(oldItemLink)

        if oldArmor ~= nil then
            local forwardDelta = newArmor - oldArmor
            local reverseDelta = -forwardDelta
            local forwardDistance = math.abs(rawArmorDelta - forwardDelta)
            local reverseDistance = math.abs(rawArmorDelta - reverseDelta)
            local candidateDelta
            local candidateDistance

            if forwardDistance <= reverseDistance then
                candidateDelta = forwardDelta
                candidateDistance = forwardDistance
            else
                candidateDelta = reverseDelta
                candidateDistance = reverseDistance
            end

            if not bestDistance or candidateDistance < bestDistance then
                bestDelta = candidateDelta
                bestDistance = candidateDistance
            end
        end
    end

    return bestDelta
end

local function GetEffectiveArmorDelta(rawArmorDelta, context)
    local itemArmorMultiplier = GetItemArmorMultiplier()

    if itemArmorMultiplier == 1 then
        return rawArmorDelta
    end

    local intrinsicDelta = FindIntrinsicArmorDelta(context, rawArmorDelta)
    if intrinsicDelta == nil then
        -- Conservative fallback: never multiply an unknown delta, because it
        -- could come from an armor kit or another non-multiplied source.
        return rawArmorDelta
    end

    local otherArmorDelta = rawArmorDelta - intrinsicDelta
    return (intrinsicDelta * itemArmorMultiplier) + otherArmorDelta
end

local function BuildNewLineText(armorDelta, drStr)
    if not showArmorDelta then return drStr end
    local green = GREEN_FONT_COLOR_CODE or "|cff20ff20"
    local red   = RED_FONT_COLOR_CODE   or "|cffff2020"
    local reset = FONT_COLOR_CODE_CLOSE or "|r"
    local sign = armorDelta > 0 and "+" or ""
    local armorStr = sign .. armorDelta .. " Armor"
    if armorDelta > 0 then armorStr = green .. armorStr .. reset
    elseif armorDelta < 0 then armorStr = red .. armorStr .. reset end
    return armorStr .. " (" .. drStr .. ")"
end

-- Vanilla 1.12 support: find an unsigned armor value near the Armor label.
-- Classic Era shows signed deltas (+25 Armor); vanilla shows absolute values (145 Armor).
local function FindAbsoluteArmorValue(text)
    if not text then return nil end

    local armorStart, armorEnd = FindArmorLabel(text)
    if not armorStart then return nil end

    local best, bestDistance
    local cursor = 1

    while true do
        local s, e, digits = text:find("(%d+)", cursor)
        if not s then break end

        local value = tonumber(digits)
        if value and value > 0 then
            local distance
            if e < armorStart then
                distance = armorStart - e
            elseif s > armorEnd then
                distance = s - armorEnd
            else
                distance = 0
            end

            if not bestDistance or distance < bestDistance then
                best = value
                bestDistance = distance
            end
        end

        cursor = e + 1
    end

    if not best or bestDistance > 12 then return nil end
    return best
end

-- Scans all lines of a tooltip and returns the first absolute armor value found.
local function ReadArmorFromTooltip(tooltip)
    if not tooltip or not tooltip.NumLines then return nil end

    local numLines = SafeCall(tooltip.NumLines, tooltip)
    if not numLines then return nil end

    local sides = { "left", "right" }
    for i = 1, numLines do
        for _, side in ipairs(sides) do
            local fs = GetTooltipLine(tooltip, side, i)
            if fs and type(fs.GetText) == "function" then
                local text = SafeCall(fs.GetText, fs)
                if text and not IsSecret(text) then
                    local plain = StripColorCodes(text)
                    if not plain:find(MARKER, 1, true) then
                        local val = FindAbsoluteArmorValue(plain)
                        if val then return val end
                    end
                end
            end
        end
    end

    return nil
end

-- Vanilla 1.12 comparison path: both tooltips show absolute armor values rather
-- than signed deltas. Computes delta = newItem - equippedItem and adds a new
-- annotation line to mainTooltip. Only called when Classic signed-delta search
-- finds nothing, so it never double-annotates on Classic Era.
local function ProcessVanillaComparison(mainTooltip, shoppingTooltip, armor, level)
    if not shoppingTooltip then return false end

    local stShown = not shoppingTooltip.IsShown
        or SafeCall(shoppingTooltip.IsShown, shoppingTooltip)
    if not stShown then return false end

    local newItemArmor = ReadArmorFromTooltip(mainTooltip)
    local oldItemArmor = ReadArmorFromTooltip(shoppingTooltip)

    if not newItemArmor or not oldItemArmor then return false end

    local armorDelta = newItemArmor - oldItemArmor
    if armorDelta == 0 then return false end

    local oldDR = ArmorDR(armor, level)
    local newDR = ArmorDR(armor + armorDelta, level)
    if not oldDR or not newDR then return false end

    local drStr = FormatDRDelta(newDR - oldDR)
    local newLineText = BuildNewLineText(armorDelta, drStr)

    local numLines = SafeCall(mainTooltip.NumLines, mainTooltip)
    local existingMarkerFS = nil
    if numLines then
        for i = 1, numLines do
            local fs = GetTooltipLine(mainTooltip, "left", i)
            if fs and type(fs.GetText) == "function" then
                local text = SafeCall(fs.GetText, fs)
                if text and StripColorCodes(text):find(MARKER, 1, true) then
                    existingMarkerFS = fs
                    break
                end
            end
        end
    end

    if existingMarkerFS then
        SafeCall(existingMarkerFS.SetText, existingMarkerFS, newLineText)
    else
        SafeCall(mainTooltip.AddLine, mainTooltip, newLineText)
    end

    if mainTooltip.Show then
        SafeCall(mainTooltip.Show, mainTooltip)
    end

    return true
end

local function ProcessTooltip(tooltip, context)
    if not tooltip or not tooltip.NumLines then
        return false
    end

    local armor, level = GetPlayerArmorAndLevel()
    if not armor or not level then
        return false
    end

    local numLines = SafeCall(tooltip.NumLines, tooltip)
    if not numLines then
        return false
    end

    context = context or BuildComparisonContext(tooltip)

    local existingMarkerFS = nil
    local rawArmorDelta = nil
    local effectiveArmorDelta = nil

    for i = 1, numLines do
        for _, side in ipairs({ "left", "right" }) do
            local fs = GetTooltipLine(tooltip, side, i)
            if fs and type(fs.GetText) == "function" then
                local text = SafeCall(fs.GetText, fs)
                if text and not IsSecret(text) then
                    local plain = StripColorCodes(text)
                    if plain:find(MARKER, 1, true) then
                        if not existingMarkerFS then existingMarkerFS = fs end
                    elseif not rawArmorDelta then
                        local delta = FindArmorDelta(text)
                        if delta then
                            rawArmorDelta = delta
                            effectiveArmorDelta = GetEffectiveArmorDelta(delta, context)
                        end
                    end
                end
            end
        end
    end

    if not effectiveArmorDelta then return false end

    local oldDR = ArmorDR(armor, level)
    local newDR = ArmorDR(armor + effectiveArmorDelta, level)
    if not oldDR or not newDR then return false end

    local drStr = FormatDRDelta(newDR - oldDR)
    local newLineText = BuildNewLineText(effectiveArmorDelta, drStr)

    if existingMarkerFS then
        SafeCall(existingMarkerFS.SetText, existingMarkerFS, newLineText)
    else
        SafeCall(tooltip.AddLine, tooltip, newLineText)
    end

    if tooltip.Show then
        SafeCall(tooltip.Show, tooltip)
    end

    return true
end

local function ProcessAllComparisonTooltips(owner)
    owner = owner or GameTooltip
    local context = BuildComparisonContext(owner)

    local classicChanged = false

    -- MAIN hovered tooltip: Classic Era can put "+X Armor" here.
    if ProcessTooltip(owner, context) then classicChanged = true end

    -- Equipped-item comparison tooltips.
    if owner and owner.shoppingTooltips then
        for _, tooltip in ipairs(owner.shoppingTooltips) do
            if ProcessTooltip(tooltip, context) then classicChanged = true end
        end
    end

    if ProcessTooltip(_G.ShoppingTooltip1, context) then classicChanged = true end
    if ProcessTooltip(_G.ShoppingTooltip2, context) then classicChanged = true end

    if owner ~= _G.ItemRefTooltip then
        local itemRefContext = BuildComparisonContext(_G.ItemRefTooltip)
        ProcessTooltip(_G.ItemRefTooltip, itemRefContext)
    end

    if _G.ItemRefTooltip and _G.ItemRefTooltip.shoppingTooltips then
        local itemRefContext = BuildComparisonContext(_G.ItemRefTooltip)
        for _, tooltip in ipairs(_G.ItemRefTooltip.shoppingTooltips) do
            ProcessTooltip(tooltip, itemRefContext)
        end
    end

    -- Vanilla 1.12 fallback: if no signed deltas were found (Classic approach found
    -- nothing), compare absolute armor values from both tooltips. This covers
    -- OctoWoW / TurtleWoW private servers where tooltips show "145 Armor" instead
    -- of "+25 Armor". Only runs when Classic path was a no-op to avoid duplicates.
    if not classicChanged then
        local armor, level = GetPlayerArmorAndLevel()
        if armor and level then
            local st1 = _G.ShoppingTooltip1
            if st1 then
                ProcessVanillaComparison(owner, st1, armor, level)
            end
        end
    end
end

local function DeferredProcess(owner)
    if C_Timer and C_Timer.After then
        -- First pass: immediately after Blizzard's compare builder.
        C_Timer.After(0, function()
            ProcessAllComparisonTooltips(owner)
        end)

        -- Second pass: catches profession/UI frames that finish text updates
        -- one frame later.
        C_Timer.After(0.03, function()
            ProcessAllComparisonTooltips(owner)
        end)
    else
        ProcessAllComparisonTooltips(owner)
    end
end

-- Classic Era 1.15.9's actual comparison entry point.
if type(GameTooltip_ShowCompareItem) == "function"
    and type(hooksecurefunc) == "function" then

    hooksecurefunc("GameTooltip_ShowCompareItem", function(owner)
        DeferredProcess(owner or GameTooltip)
    end)
end

-- Classic Era uses ShoppingTooltip:SetCompareItem, not
-- SetHyperlinkCompareItem. Hook the actual method when available.
local function HookSetCompareItem(tooltip)
    if not tooltip or tooltip.__ArmorDRCompare_SetCompareItemHooked then
        return
    end

    if tooltip.SetCompareItem and type(hooksecurefunc) == "function" then
        tooltip.__ArmorDRCompare_SetCompareItemHooked = true

        pcall(hooksecurefunc, tooltip, "SetCompareItem", function(self, otherTooltip, owner)
            local compareOwner = owner or GameTooltip
            local context = BuildComparisonContext(compareOwner)

            DeferredProcess(compareOwner)
            ProcessTooltip(self, context)
            ProcessTooltip(otherTooltip, context)
        end)
    end
end

HookSetCompareItem(_G.ShoppingTooltip1)
HookSetCompareItem(_G.ShoppingTooltip2)

-- Run after every item tooltip has been populated. This is deliberately broad:
-- signed "+/- X Armor" text is only changed when an Armor label and a nearby
-- explicit signed number are present, so ordinary "119 Armor" lines are ignored.
if TooltipDataProcessor
    and TooltipDataProcessor.AddTooltipPostCall
    and Enum
    and Enum.TooltipDataType
    and Enum.TooltipDataType.Item then

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                ProcessTooltip(tooltip)
                if tooltip == GameTooltip or tooltip == ItemRefTooltip then
                    ProcessAllComparisonTooltips(tooltip)
                end
            end)
        else
            ProcessTooltip(tooltip)
        end
    end)
end

-- Extra safety: the stock Classic ShoppingTooltip XML fires OnTooltipSetItem.
local function HookTooltipSetItem(tooltip)
    if not tooltip or not tooltip.HookScript or tooltip.__ArmorDRCompare_ItemHooked then
        return
    end

    tooltip.__ArmorDRCompare_ItemHooked = true

    pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self)
        local owner = self

        if (self == _G.ShoppingTooltip1 or self == _G.ShoppingTooltip2)
            and self.GetOwner then
            owner = SafeCall(self.GetOwner, self) or _G.GameTooltip
        end

        DeferredProcess(owner)
    end)
end

HookTooltipSetItem(_G.GameTooltip)
HookTooltipSetItem(_G.ShoppingTooltip1)
HookTooltipSetItem(_G.ShoppingTooltip2)
HookTooltipSetItem(_G.ItemRefTooltip)

local function RefreshVisibleComparisons()
    if _G.GameTooltip
        and (not _G.GameTooltip.IsShown or SafeCall(_G.GameTooltip.IsShown, _G.GameTooltip)) then
        DeferredProcess(_G.GameTooltip)
    end

    if _G.ItemRefTooltip
        and _G.ItemRefTooltip.IsShown
        and SafeCall(_G.ItemRefTooltip.IsShown, _G.ItemRefTooltip) then
        DeferredProcess(_G.ItemRefTooltip)
    end
end

if type(CreateFrame) == "function" then
    local eventFrame = CreateFrame("Frame")

    if eventFrame and eventFrame.RegisterEvent and eventFrame.SetScript then
        pcall(eventFrame.RegisterEvent, eventFrame, "UPDATE_SHAPESHIFT_FORM")
        pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_TALENT_UPDATE")
        pcall(eventFrame.RegisterEvent, eventFrame, "CHARACTER_POINTS_CHANGED")
        pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_LOGIN")

        -- In vanilla 1.12 the event name is a global, not a function parameter.
        -- Support both styles so the handler works on all client versions.
        eventFrame:SetScript("OnEvent", function(self, evParam)
            local ev = evParam or (type(event) == "string" and event) or ""

            if ev == "PLAYER_LOGIN" then
                if not ArmorDRCompareOctoDB then ArmorDRCompareOctoDB = {} end
                if ArmorDRCompareOctoDB.showArmorDelta == nil then
                    ArmorDRCompareOctoDB.showArmorDelta = true
                end
                showArmorDelta = ArmorDRCompareOctoDB.showArmorDelta
            end

            if ev == "PLAYER_TALENT_UPDATE" or ev == "CHARACTER_POINTS_CHANGED" then
                thickHideMultiplierCache = nil
            end

            RefreshVisibleComparisons()
        end)
    end
end

local function PrintTooltipLines(label, tooltip)
    if not tooltip or not tooltip.NumLines then
        print("|cffaaaaaa" .. label .. ": unavailable|r")
        return
    end

    local shown = tooltip.IsShown and SafeCall(tooltip.IsShown, tooltip)
    local count = SafeCall(tooltip.NumLines, tooltip) or 0

    print(string.format("|cffffcc00%s|r shown=%s lines=%d", label, tostring(shown), count))

    for i = 1, count do
        local left = GetTooltipLine(tooltip, "left", i)
        local right = GetTooltipLine(tooltip, "right", i)

        local leftText = left and SafeCall(left.GetText, left) or nil
        local rightText = right and SafeCall(right.GetText, right) or nil

        if leftText or rightText then
            print(string.format(
                "  %02d  L=[%s]  R=[%s]",
                i,
                tostring(StripColorCodes(leftText) or ""),
                tostring(StripColorCodes(rightText) or "")
            ))
        end
    end
end

SLASH_ARMORDRCOMPARE1 = "/adrc"
SLASH_ARMORDRCOMPARE2 = "/armordr"

SlashCmdList.ARMORDRCOMPARE = function(msg)
    msg = Trim(msg or "") or ""
    local lower = msg:lower()

    if lower == "dump" then
        print("|cff00ff00Armor DR Compare tooltip dump|r")
        PrintTooltipLines("GameTooltip", _G.GameTooltip)
        PrintTooltipLines("ShoppingTooltip1", _G.ShoppingTooltip1)
        PrintTooltipLines("ShoppingTooltip2", _G.ShoppingTooltip2)
        PrintTooltipLines("ItemRefTooltip", _G.ItemRefTooltip)
        return
    end

    if lower == "mode" or lower:sub(1, 5) == "mode " then
        local arg = Trim(lower:sub(6)) or ""

        if arg == "dr" then
            showArmorDelta = false
        elseif arg == "full" then
            showArmorDelta = true
        else
            showArmorDelta = not showArmorDelta
        end

        if ArmorDRCompareOctoDB then
            ArmorDRCompareOctoDB.showArmorDelta = showArmorDelta
        end

        local modeName = showArmorDelta
            and "|cff00ff00full|r  (+-Armor DR%)"
            or  "|cff00ff00DR only|r (%DR)"
        print("|cff00ff00Armor DR Compare:|r mode: " .. modeName)

        vanillaMonitorLastState = nil
        RefreshVisibleComparisons()
        return
    end

    if lower == "status" then
        local wowVersion, build, buildDate, interfaceVersion = GetBuildInfo()
        local armor, level = GetPlayerArmorAndLevel()
        local dr = armor and level and ArmorDR(armor, level)

        print(string.format(
            "|cff00ff00Armor DR Compare|r v%s | OctoWoW 1.12.1 | WoW %s | build %s | interface %s",
            VERSION,
            tostring(wowVersion),
            tostring(build),
            tostring(interfaceVersion)
        ))

        if armor and level and dr then
            print(string.format(
                "Current armor: %d | same-level physical DR: %.2f%%",
                armor,
                dr * 100
            ))
        end

        local modeName = showArmorDelta
            and "full (±Armor DR%)"
            or  "DR only (csak %DR)"
        print("Display mode: " .. modeName .. " | /adrc mode to toggle")

        if GetPlayerClassID() == DRUID_CLASS_ID then
            local itemArmorMultiplier, formName = GetItemArmorMultiplier()
            print(string.format(
                "Druid armor state: %s | intrinsic item armor multiplier: %.2fx",
                formName,
                itemArmorMultiplier
            ))
        end

        print("Compare hook: GameTooltip_ShowCompareItem = "
            .. tostring(type(GameTooltip_ShowCompareItem) == "function"))
        print("ShoppingTooltip1:SetCompareItem = "
            .. tostring(_G.ShoppingTooltip1 and type(_G.ShoppingTooltip1.SetCompareItem) == "function"))
        return
    end

    local amount = tonumber(msg:match("[-+]?%d+"))
    local armor, level = GetPlayerArmorAndLevel()

    if not armor or not level then
        print("|cffff4444Armor DR Compare: armor data unavailable.|r")
        return
    end

    local oldDR = ArmorDR(armor, level)

    if amount then
        local newDR = ArmorDR(armor + amount, level)
        print(string.format(
            "|cff00ff00Armor DR Compare:|r %+d effective armor = %s (%.2f%% -> %.2f%%)",
            amount,
            FormatDRDelta(newDR - oldDR),
            oldDR * 100,
            newDR * 100
        ))
    else
        print(string.format(
            "|cff00ff00Armor DR Compare:|r %d armor = %.2f%% DR vs level %d.",
            armor,
            oldDR * 100,
            level
        ))
        print("Commands: /adrc 100   /adrc status   /adrc dump   /adrc mode")
    end
end

-- Vanilla 1.12 hook: C_Timer, HookScript, and OnTooltipSetItem are unavailable.
-- ShaguTweaks equip-compare (common on OctoWoW/TurtleWoW) uses its own OnUpdate
-- loop to show ShoppingTooltip1 instead of calling GameTooltip_ShowCompareItem,
-- so the hook above does not fire. Poll ShoppingTooltip1 visibility here and
-- trigger processing once each time its content changes.
if not (C_Timer and C_Timer.After) and type(CreateFrame) == "function" then
    local vanillaMonitor = CreateFrame("Frame")

    if vanillaMonitor and vanillaMonitor.SetScript then
        vanillaMonitor:SetScript("OnUpdate", function()
            local st1 = _G.ShoppingTooltip1
            if not (st1 and type(st1.IsShown) == "function" and st1:IsShown()) then
                vanillaMonitorLastState = nil
                return
            end

            local l1 = _G["GameTooltipTextLeft1"]
            local s1 = _G["ShoppingTooltip1TextLeft1"]
            local gtText = (l1 and type(l1.GetText) == "function" and l1:GetText()) or ""
            local stText = (s1 and type(s1.GetText) == "function" and s1:GetText()) or ""
            local state  = gtText .. "|" .. stText

            if state == vanillaMonitorLastState then return end
            vanillaMonitorLastState = state

            ProcessAllComparisonTooltips(GameTooltip)
        end)
    end
end

print("|cff00ff00Armor DR Compare (Octo) v1.3.0 loaded.|r")
