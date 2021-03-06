--[[	*** DataStore_Auctions ***
Written by : Thaoky, EU-Marécages de Zangar
July 15th, 2009
--]]
if not DataStore then return end

local addonName = "DataStore_Auctions"

_G[addonName] = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")

local addon = _G[addonName]

local THIS_ACCOUNT = "Default"

local AddonDB_Defaults = {
	global = {
		Options = {
			AutoClearExpiredItems = true,		-- Automatically clear expired auctions and bids
		},
		Characters = {
			['*'] = {				-- ["Account.Realm.Name"] 
				Auctions = {},
				Bids = {},
				lastUpdate = nil,				-- last time the AH was checked for this char
				lastVisitDate = nil,			-- in YYYY MM DD  hh:mm, for external apps
			}
		}
	}
}

local function GetOption(option)
	return addon.db.global.Options[option]
end


-- ** Mixins **
local function _GetNumAuctions(character)
	return #character.Auctions
end

local function _GetNumBids(character)
	return #character.Bids
end

local function _GetAuctionHouseItemInfo(character, list, index)
	if list == "Auctions" or list == "Bids" then
		local item = character[list][index]
		if not item then return end
		local isGoblin, itemID, count, name, price1, price2, timeLeft = strsplit("|", item)
		isGoblin = tonumber(isGoblin)
		isGoblin = (isGoblin == 1) and true or nil
		return isGoblin, tonumber(itemID), tonumber(count), name, tonumber(price1), tonumber(price2), tonumber(timeLeft)
	end
end

local function _GetAuctionHouseLastVisit(character)
	return character.lastUpdate or 0
end

local function _GetAuctionHouseItemCount(character, searchedID)
	local count = 0
	for k, v in pairs (character.Auctions) do
		local _, id, itemCount = strsplit("|", v)
		if id and (tonumber(id) == searchedID) then 
			itemCount = tonumber(itemCount) or 1
			count = count + itemCount
		end 
	end
	return count
end

local function _ClearAuctionEntries(character, AHType, AHZone)
	-- this function clears the "auctions" or "bids" of a specific AH (faction or goblin)
	-- AHType = "Auctions" or "Bids" (the name of the table in the DB)
	-- AHZone = 0 for player faction, or 1 for goblin
	local ah = character[AHType]
	if not ah then return end
	
	for i = #ah, 1, -1 do			-- parse backwards to avoid messing up the index
		local faction = strsplit("|", ah[i])
		if faction then
			if tonumber(faction) == AHZone then
				table.remove(ah, i)
			end
		end
	end
end

local PublicMethods = {
	GetNumAuctions = _GetNumAuctions,
	GetNumBids = _GetNumBids,
	GetAuctionHouseItemInfo = _GetAuctionHouseItemInfo,
	GetAuctionHouseLastVisit = _GetAuctionHouseLastVisit,
	GetAuctionHouseItemCount = _GetAuctionHouseItemCount,
	ClearAuctionEntries = _ClearAuctionEntries,
}

-- maximum time left in seconds per auction type : [1] = max 30 minutes, [2] = 2 hours, [3] = 12 hours, [4] = more than 12, but max 48 hours
-- info : http://www.wowwiki.com/API_C_AuctionHouse.GetReplicateItemTimeLeft
local maxTimeLeft = { 30*60, 2*60*60, 12*60*60, 48*60*60 }

local function CheckExpiries()
	local AHTypes = { "Auctions", "Bids" }
	local timeLeft, diff
	
	for key, character in pairs(addon.db.global.Characters) do
		for _, ahType in pairs(AHTypes) do					-- browse both auctions & bids
			for index = #character[ahType], 1, -1 do		-- from last to first, to make sure table.remove does not screw up indexes.
				timeLeft = select(7, _GetAuctionHouseItemInfo(character, ahType, index))
				if not timeLeft or (timeLeft < 1) or (timeLeft > 4) then
					timeLeft = 4	-- timeLeft is supposed to always be between 1 and 4, if it's not in this range, set it to the longest value (4 = more than 12 hours)
				end

				diff = time() - character.lastUpdate
				if diff > maxTimeLeft[timeLeft] then	-- has expired
					table.remove(character[ahType], index)
				end
			end
		end
	end
end

function addon:OnInitialize()
	addon.db = LibStub("AceDB-3.0"):New(addonName .. "DB", AddonDB_Defaults)

	DataStore:RegisterModule(addonName, addon, PublicMethods)
	DataStore:SetCharacterBasedMethod("GetNumAuctions")
	DataStore:SetCharacterBasedMethod("GetNumBids")
	DataStore:SetCharacterBasedMethod("GetAuctionHouseItemInfo")
	DataStore:SetCharacterBasedMethod("GetAuctionHouseLastVisit")
	DataStore:SetCharacterBasedMethod("GetAuctionHouseItemCount")
	DataStore:SetCharacterBasedMethod("ClearAuctionEntries")
end

function addon:OnEnable()
	addon:RegisterEvent("AUCTION_HOUSE_SHOW")
	addon:SetupOptions()
	
	if GetOption("AutoClearExpiredItems") then
		addon:ScheduleTimer(CheckExpiries, 3)	-- check AH expiries 3 seconds later, to decrease the load at startup
	end
end

function addon:OnDisable()
	addon:UnregisterEvent("AUCTION_HOUSE_SHOW")
end

local function getAHZone()
	local zoneID = C_Map.GetBestMapForUnit("player")
	if zoneID == 161 or zoneID == 281 or zoneID == 673 then
 		return 1			-- 1 means goblin AH
 	end
    return 0
end

-- *** Scanning functions ***
local function ScanAuctions()
	local AHZone = getAHZone()
	
	local character = addon.ThisCharacter
	character.lastUpdate = time()
	
	_ClearAuctionEntries(character, "Auctions", AHZone)
	
	for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
        local ownedAuction = C_AuctionHouse.GetOwnedAuctionInfo(i)
		local itemName = ownedAuction.itemLink
        local count = ownedAuction.quantity
        local startPrice = ownedAuction.bidAmount 
		local buyoutPrice = ownedAuction.buyoutAmount
        local highBidder = ownedAuction.bidder
        local saleStatus = ownedAuction.status 
        local itemID = ownedAuction.itemKey.itemID  
			
		-- do not list sold items, they're supposed to be in the mailbox
		if saleStatus and saleStatus == 1 then		-- just to be sure, in case Bliz ever returns nil
			saleStatus = true
		else
			saleStatus = false
		end
			
		if itemName and itemID and not saleStatus then
			local timeLeft = ownedAuction.timeLeft
			
			table.insert(character.Auctions, format("%s|%s|%s|%s|%s|%s|%s", 
				AHZone, itemID, count, highBidder or "", startPrice or "", buyoutPrice, timeLeft or ""))
		end
	end
	
	addon:SendMessage("DATASTORE_AUCTIONS_UPDATED")
end

-- UPDATE 8.3.003 2020/03/21:
-- Since addons can't seem to be able to scan the AH after selling an item, instead I will try to get the information about an item being sold directly

-- bid and buyout are optional parameters
local function onPostItem(item, duration, quantity, bid, buyout)
    -- item is an ItemLocationMixin from Blizzard's ItemLocation.lua
    local bagID, slotIndex = item:GetBagAndSlot()
    local itemID = GetContainerItemID(bagID, slotIndex)
    local AHZone = getAHZone()
    
    local character = addon.ThisCharacter
	character.lastUpdate = time()
    
   table.insert(character.Auctions, format("%s|%s|%s|%s|%s|%s|%s", 
				AHZone, itemID, quantity, "", bid or "", buyout or "", duration or ""))
end

local function onPostCommodity(item, duration, quantity, unitPrice)
    -- item is an ItemLocationMixin from Blizzard's ItemLocation.lua
    local bagID, slotIndex = item:GetBagAndSlot()
    local itemID = GetContainerItemID(bagID, slotIndex)
    local AHZone = getAHZone()
    
    local character = addon.ThisCharacter
	character.lastUpdate = time()
    
    table.insert(character.Auctions, format("%s|%s|%s|%s|%s|%s|%s", 
				AHZone, itemID, quantity, "", "", unitPrice or "", duration or ""))
end

-- Hook the game UI's PostItem and PostCommodity functions, grabbing their parameter information
hooksecurefunc(C_AuctionHouse, "PostItem", onPostItem)
hooksecurefunc(C_AuctionHouse, "PostCommodity", onPostCommodity)


local function ScanBids()
	local AHZone = 0		-- 0 means faction AH
	-- local zoneFaction = GetZonePVPInfo()	-- "friendly", "sanctuary", "contested" (PvP server) or nil (PvE server)
	-- if ( zoneFaction ~= "friendly" ) and ( zoneFaction ~= "sanctuary" ) then
		-- AHZone = 1			-- 1 means goblin AH
	-- end
	
	local zoneID = C_Map.GetBestMapForUnit("player")
	if zoneID == 161 or zoneID == 281 or zoneID == 673 then
 		AHZone = 1			-- 1 means goblin AH
 	end
	
	local character = addon.ThisCharacter
	character.lastUpdate = time()
	character.lastVisitDate = date("%Y/%m/%d %H:%M")
	
	_ClearAuctionEntries(character, "Bids", AHZone)
	
	for i = 1, C_AuctionHouse.GetNumReplicateItems("bidder") do
		local itemName, _, count, _, _, _, _, _, 
			_, buyoutPrice, bidPrice, _, ownerName = C_AuctionHouse.GetReplicateItemInfo("bidder", i);
			
		if itemName then
			local link = C_AuctionHouse.GetReplicateItemLink("bidder", i)
			if not link:match("battlepet:(%d+)") then		-- temporarily skip battle pets
				local id = tonumber(link:match("item:(%d+)"))
				local timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft("bidder", i)
			
				table.insert(character.Bids, format("%s|%s|%s|%s|%s|%s|%s", 
					AHZone, id, count, ownerName or "", bidPrice, buyoutPrice, timeLeft))
			end
		end
	end
end

-- *** EVENT HANDLERS ***
function addon:AUCTION_HOUSE_SHOW()
	addon:RegisterEvent("AUCTION_HOUSE_CLOSED")
	addon:RegisterEvent("OWNED_AUCTIONS_UPDATED", ScanAuctions)
	addon:RegisterEvent("BIDS_UPDATED", ScanBids)
end

function addon:AUCTION_HOUSE_CLOSED()
	addon:UnregisterEvent("AUCTION_HOUSE_CLOSED")
	addon:UnregisterEvent("OWNED_AUCTIONS_UPDATED")
	addon:UnregisterEvent("BIDS_UPDATED")
end
