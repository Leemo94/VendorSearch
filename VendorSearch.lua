--[[
	VendorSearch (Ascension WoW, 3.3.5a)

	Adds a search bar below the merchant window: type part of an item name
	(e.g. "ironfoe") and the vendor list filters live. A stat dropdown filters
	to items whose tooltip mentions the stat (Intellect, Spell Power, ...);
	both filters combine.

	Safety: the stock repaint runs against remapped read-only getters, then
	every visible slot's button ID is re-stamped with the REAL vendor index —
	the stock UI routes every buy / pickup / stack-split / tooltip through
	button:GetID(), so purchases always hit the right item. If the filtered
	redraw ever errors, the addon disables itself for the session.
]]

local ADDON_NAME = ...

local f = CreateFrame("Frame")
local installed = false
local broken = false            -- error latch: true => permanent passthrough this session

-- stock globals captured at install time
local o_GetMerchantNumItems, o_GetMerchantItemInfo, o_GetMerchantItemLink
local o_GetMerchantItemCostInfo, o_GetMerchantItemCostItem
local origUpdate                -- stock MerchantFrame_UpdateMerchantInfo

local searchText = ""
local selectedStats = {}  -- set of stat keys; item must match ALL of them (AND)
local map = {}                  -- display index -> real vendor index
local matchCount, totalCount = 0, 0
local scanCache = {}            -- item link -> lowercased tooltip text
local needRescan = false
local rescanTries = 0
local bar, box, dropdown, countFS

-- Each stat matches if ANY of its `words` appears in an item's tooltip text.
-- Rating stats use the "... rating" wording so they don't false-match item
-- NAMES (e.g. a "Dodge Cloak" won't match "dodge rating").
local STATS = {
	{ key = "ALL",         label = "All items" },
	-- caster
	{ key = "intellect",   label = "Intellect",    words = { "intellect" } },
	{ key = "spirit",      label = "Spirit",       words = { "spirit" } },
	{ key = "spellpower",  label = "Spell Power",  words = { "spell power" } },
	{ key = "spelldamage", label = "Spell Damage", words = { "spell damage" } },
	{ key = "healing",     label = "Healing",      words = { "healing" } },
	{ key = "mp5",         label = "MP5",          words = { "mana per 5" } },
	-- physical
	{ key = "strength",    label = "Strength",     words = { "strength" } },
	{ key = "agility",     label = "Agility",      words = { "agility" } },
	{ key = "attackpower", label = "Attack Power", words = { "attack power" } },
	{ key = "armorpen",    label = "Armor Pen",    words = { "armor penetration" } },
	-- ratings (shared)
	{ key = "crit",        label = "Crit",         words = { "critical strike", "crit rating" } },
	{ key = "haste",       label = "Haste",        words = { "haste" } },
	{ key = "hit",         label = "Hit",          words = { "hit rating" } },
	{ key = "expertise",   label = "Expertise",    words = { "expertise" } },
	{ key = "spellpen",    label = "Spell Pen",    words = { "spell penetration" } },
	-- survival / tank / pvp
	{ key = "stamina",     label = "Stamina",      words = { "stamina" } },
	{ key = "resilience",  label = "Resilience",   words = { "resilience" } },
	{ key = "defense",     label = "Defense",      words = { "defense rating", "increased defense" } },
	{ key = "dodge",       label = "Dodge",        words = { "dodge rating" } },
	{ key = "parry",       label = "Parry",        words = { "parry rating" } },
	{ key = "block",       label = "Block",        words = { "block rating", "block value" } },
}
local STAT_WORDS, STAT_LABELS = {}, {}
for _, s in ipairs(STATS) do
	STAT_WORDS[s.key] = s.words
	STAT_LABELS[s.key] = s.label
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffVendorSearch:|r " .. msg)
end

local scanTip = CreateFrame("GameTooltip", "VendorSearchScanTooltip", nil, "GameTooltipTemplate")

local function TooltipTextFor(index, link)
	if link and scanCache[link] then
		return scanCache[link]
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	scanTip:ClearLines()
	scanTip:SetMerchantItem(index)
	local numLines = scanTip:NumLines()
	local parts = {}
	for i = 1, numLines do
		local fs = _G["VendorSearchScanTooltipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text then
			parts[#parts + 1] = text
		end
		fs = _G["VendorSearchScanTooltipTextRight" .. i]
		text = fs and fs:GetText()
		if text then
			parts[#parts + 1] = text
		end
	end
	scanTip:Hide()
	local full = strlower(table.concat(parts, "\n"))
	if link and numLines > 0 then
		scanCache[link] = full
	end
	return full
end

local function MatchesFilters(index)
	local name = o_GetMerchantItemInfo(index)
	local link = o_GetMerchantItemLink(index)
	if not name and link then
		name = strmatch(link, "%[(.-)%]")
	end
	if searchText ~= "" then
		if not name then
			needRescan = true
			return false
		end
		if not strfind(strlower(name), searchText, 1, true) then
			return false
		end
	end
	if next(selectedStats) then
		local text = TooltipTextFor(index, link)
		if text == "" then
			needRescan = true
			return false
		end
		-- AND: every selected stat's words must appear somewhere in the tooltip
		for key in pairs(selectedStats) do
			local words = STAT_WORDS[key]
			local found = false
			if words then
				for i = 1, #words do
					if strfind(text, words[i], 1, true) then
						found = true
						break
					end
				end
			end
			if not found then
				return false
			end
		end
	end
	return true
end

-- proxies installed only for the duration of the stock repaint call
local function p_GetMerchantNumItems()
	return #map
end

local function p_GetMerchantItemInfo(index)
	return o_GetMerchantItemInfo(map[index] or index)
end

local function p_GetMerchantItemLink(index)
	return o_GetMerchantItemLink(map[index] or index)
end

local function p_GetMerchantItemCostInfo(index)
	return o_GetMerchantItemCostInfo(map[index] or index)
end

local function p_GetMerchantItemCostItem(index, costIndex)
	return o_GetMerchantItemCostItem(map[index] or index, costIndex)
end

local function UpdateCountText(active)
	if not countFS then
		return
	end
	if active then
		if matchCount == 0 then
			countFS:SetText(format("|cffff40400/%d|r", totalCount))
		else
			countFS:SetText(format("|cff40ff40%d|r/%d", matchCount, totalCount))
		end
	else
		countFS:SetText("")
	end
end

local function StopTicker()
	if bar then
		bar:SetScript("OnUpdate", nil)
	end
end

local tickerElapsed = 0
local function StartTicker()
	if not bar then
		return
	end
	tickerElapsed = 0
	bar:SetScript("OnUpdate", function(self, elapsed)
		tickerElapsed = tickerElapsed + elapsed
		if tickerElapsed >= 0.3 then
			self:SetScript("OnUpdate", nil)
			if MerchantFrame and MerchantFrame:IsShown() then
				MerchantFrame_UpdateMerchantInfo()
			end
		end
	end)
end

local function FilterActive()
	return not broken
		and MerchantFrame.selectedTab == 1
		and (searchText ~= "" or next(selectedStats) ~= nil)
end

local function Update_Filtered(...)
	if not FilterActive() then
		UpdateCountText(false)
		return origUpdate(...)
	end

	needRescan = false
	wipe(map)
	totalCount = o_GetMerchantNumItems()
	for i = 1, totalCount do
		if MatchesFilters(i) then
			map[#map + 1] = i
		end
	end
	matchCount = #map
	UpdateCountText(true)

	local maxPage = math.max(1, math.ceil(matchCount / MERCHANT_ITEMS_PER_PAGE))
	if MerchantFrame.page > maxPage then
		MerchantFrame.page = maxPage
	end

	GetMerchantNumItems     = p_GetMerchantNumItems
	GetMerchantItemInfo     = p_GetMerchantItemInfo
	GetMerchantItemLink     = p_GetMerchantItemLink
	GetMerchantItemCostInfo = p_GetMerchantItemCostInfo
	GetMerchantItemCostItem = p_GetMerchantItemCostItem
	local ok, err = pcall(origUpdate, ...)
	GetMerchantNumItems     = o_GetMerchantNumItems
	GetMerchantItemInfo     = o_GetMerchantItemInfo
	GetMerchantItemLink     = o_GetMerchantItemLink
	GetMerchantItemCostInfo = o_GetMerchantItemCostInfo
	GetMerchantItemCostItem = o_GetMerchantItemCostItem

	if not ok then
		broken = true
		UpdateCountText(false)
		Print("|cffff0000error during filtered redraw — search disabled for this session.|r (" .. tostring(err) .. ")")
		local ok2, err2 = pcall(origUpdate)
		if not ok2 then
			geterrorhandler()(err2)
		end
		return
	end

	-- re-stamp REAL vendor indices so every buy/tooltip path hits the right item
	for i = 1, MERCHANT_ITEMS_PER_PAGE do
		local btn = _G["MerchantItem" .. i .. "ItemButton"]
		if btn and btn:IsShown() then
			local real = map[btn:GetID()]
			if real then
				btn:SetID(real)
			end
		end
	end

	if needRescan and rescanTries < 8 then
		rescanTries = rescanTries + 1
		StartTicker()
	end
end

local function RefreshMerchant()
	rescanTries = 0
	if MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab == 1 then
		MerchantFrame_UpdateMerchantInfo()
	end
end

local function StatSelectionCount()
	local n = 0
	for _ in pairs(selectedStats) do
		n = n + 1
	end
	return n
end

local function UpdateStatDropDownText()
	if not dropdown then
		return
	end
	local n = StatSelectionCount()
	if n == 0 then
		UIDropDownMenu_SetText(dropdown, "Any stat")
	elseif n == 1 then
		local k = next(selectedStats)
		UIDropDownMenu_SetText(dropdown, STAT_LABELS[k] or k)
	else
		UIDropDownMenu_SetText(dropdown, n .. " stats")
	end
end

local function ToggleStat(key)
	if selectedStats[key] then
		selectedStats[key] = nil
	else
		selectedStats[key] = true
	end
	UpdateStatDropDownText()
	RefreshMerchant()
end

local function ClearStats()
	wipe(selectedStats)
	UpdateStatDropDownText()
	RefreshMerchant()
end

local function Reset()
	StopTicker()
	searchText = ""
	wipe(selectedStats)
	rescanTries = 0
	if box then
		box:SetText("")
		box:ClearFocus()
	end
	UpdateStatDropDownText()
	UpdateCountText(false)
end

local function StatDropDown_Initialize()
	-- clear-all entry at the top
	local clear = UIDropDownMenu_CreateInfo()
	clear.text = "All items (clear stats)"
	clear.notCheckable = true
	clear.func = ClearStats
	UIDropDownMenu_AddButton(clear)
	-- one checkbox per stat; multi-select, menu stays open
	for _, opt in ipairs(STATS) do
		if opt.words then -- skip the legacy "ALL" placeholder
			local key = opt.key
			local info = UIDropDownMenu_CreateInfo()
			info.text = opt.label
			info.value = key
			info.isNotRadio = true
			info.keepShownOnClick = true
			info.checked = selectedStats[key] and true or false
			info.func = function() ToggleStat(key) end
			UIDropDownMenu_AddButton(info)
		end
	end
end

local function CreateUI()
	bar = CreateFrame("Frame", "VendorSearchBar", MerchantFrame)
	bar:SetWidth(360)
	bar:SetHeight(34)
	if MerchantFrameTab1 then
		bar:SetPoint("TOPLEFT", MerchantFrameTab1, "BOTTOMLEFT", 0, -2)
	else
		bar:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", 12, 10)
	end
	bar:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	bar:SetBackdropColor(0, 0, 0, 0.85)

	local findLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	findLabel:SetPoint("LEFT", bar, "LEFT", 12, 0)
	findLabel:SetText("Find:")

	box = CreateFrame("EditBox", "VendorSearchBox", bar, "InputBoxTemplate")
	box:SetWidth(110)
	box:SetHeight(20)
	box:SetPoint("LEFT", findLabel, "RIGHT", 10, 0)
	box:SetAutoFocus(false)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnTextChanged", function(self)
		local text = strtrim(self:GetText() or "")
		text = strlower(text)
		if text ~= searchText then
			searchText = text
			RefreshMerchant()
		end
	end)

	dropdown = CreateFrame("Frame", "VendorSearchStatDropDown", bar, "UIDropDownMenuTemplate")
	dropdown:SetPoint("LEFT", box, "RIGHT", -8, -2)
	UIDropDownMenu_Initialize(dropdown, StatDropDown_Initialize)
	UIDropDownMenu_SetWidth(dropdown, 100)
	UIDropDownMenu_SetText(dropdown, "Any stat")

	countFS = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	countFS:SetPoint("RIGHT", bar, "RIGHT", -12, 0)
	countFS:SetText("")
end

local function Install()
	if installed or broken then
		return
	end
	if not (MerchantFrame and MerchantFrame_UpdateMerchantInfo and MERCHANT_ITEMS_PER_PAGE) then
		broken = true
		Print("Merchant UI looks different than expected — not hooking (addon inactive).")
		return
	end
	installed = true

	o_GetMerchantNumItems    = GetMerchantNumItems
	o_GetMerchantItemInfo    = GetMerchantItemInfo
	o_GetMerchantItemLink    = GetMerchantItemLink
	o_GetMerchantItemCostInfo = GetMerchantItemCostInfo
	o_GetMerchantItemCostItem = GetMerchantItemCostItem

	origUpdate = MerchantFrame_UpdateMerchantInfo
	MerchantFrame_UpdateMerchantInfo = Update_Filtered

	CreateUI()

	f:RegisterEvent("MERCHANT_SHOW")
	f:RegisterEvent("MERCHANT_CLOSED")
end

f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			Install()
		end
	elseif event == "MERCHANT_SHOW" then
		Reset()
	elseif event == "MERCHANT_CLOSED" then
		Reset()
	end
end)

SLASH_VENDORSEARCH1 = "/vsearch"
SLASH_VENDORSEARCH2 = "/vendorsearch"
SlashCmdList["VENDORSEARCH"] = function(msg)
	local cmd = strlower(strtrim(msg or ""))
	if cmd == "clear" then
		Reset()
		RefreshMerchant()
		Print("filters cleared.")
	else
		Print("type in the box under the merchant window; tick one or more stats in the dropdown (matches items with ALL of them).")
		Print("commands: /vsearch clear" .. (broken and " |cffff0000(disabled by an error this session)|r" or ""))
	end
end
