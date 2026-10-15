--!strict
--[[
    InventoryManager.lua
    Senior Gameplay Architecture: Server-Authoritative Inventory Validation
    
    Protects against client injection, memory pollution, and integer overflow exploits.
    Enforces strict slot limits, mass/weight capacity, and schema-validated item attributes.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local ProfileManager = require(script.Parent.Parent.DataStore.ProfileManager)

local InventoryManager = {}
InventoryManager.__index = InventoryManager

--------------------------------------------------------------------------------
-- CONFIGURATION & LIMITS
--------------------------------------------------------------------------------

local MAX_SLOTS = 24
local MAX_WEIGHT_KG = 45.0 -- Tactical maximum carrying capacity

--------------------------------------------------------------------------------
-- TYPES & SCHEMAS
--------------------------------------------------------------------------------

export type ItemCategory = "Weapon" | "Armor" | "Medical" | "Ammo" | "Valuable" | "Keycard"

export type ItemDefinition = {
	Id: string,
	DisplayName: string,
	Category: ItemCategory,
	MaxStack: number,
	WeightKg: number,
	AllowedAttributes: { [string]: "string" | "number" | "boolean" },
}

--------------------------------------------------------------------------------
-- ITEM CATALOG (IMMUTABLE SERVER REGISTRY)
--------------------------------------------------------------------------------

local ITEM_CATALOG: { [string]: ItemDefinition } = {
	["m4a1_carbine"] = {
		Id = "m4a1_carbine",
		DisplayName = "M4A1 Assault Rifle",
		Category = "Weapon",
		MaxStack = 1,
		WeightKg = 3.4,
		AllowedAttributes = {
			Durability = "number",
			AmmoLoaded = "number",
		},
	},
	["ammo_556_box"] = {
		Id = "ammo_556_box",
		DisplayName = "5.56x45mm Ammo Box",
		Category = "Ammo",
		MaxStack = 60,
		WeightKg = 0.015,
		AllowedAttributes = {
			Caliber = "string",
		},
	},
	["medkit_standard"] = {
		Id = "medkit_standard",
		DisplayName = "Tactical IFAK Medkit",
		Category = "Medical",
		MaxStack = 4,
		WeightKg = 0.8,
		AllowedAttributes = {
			Durability = "number",
		},
	},
	["gold_ingot"] = {
		Id = "gold_ingot",
		DisplayName = "Pure Gold Ingot",
		Category = "Valuable",
		MaxStack = 5,
		WeightKg = 2.5,
		AllowedAttributes = {
			Purity = "number",
		},
	},
	["military_battery"] = {
		Id = "military_battery",
		DisplayName = "Military Grade Li-Ion Battery",
		Category = "Valuable",
		MaxStack = 2,
		WeightKg = 4.2,
		AllowedAttributes = {
			Charge = "number",
		},
	},
	["lab_keycard_red"] = {
		Id = "lab_keycard_red",
		DisplayName = "Red Security Keycard",
		Category = "Keycard",
		MaxStack = 1,
		WeightKg = 0.05,
		AllowedAttributes = {
			UsesRemaining = "number",
		},
	},
}

--------------------------------------------------------------------------------
-- ANTI-EXPLOIT INPUT SANITIZATION
--------------------------------------------------------------------------------

-- Verifies quantity is an integer, positive, non-NaN, and not infinite
local function isValidQuantity(quantity: any): boolean
	if type(quantity) ~= "number" then
		return false
	end
	if quantity <= 0 then
		return false
	end
	if quantity ~= math.floor(quantity) then
		return false
	end
	if quantity == math.huge or quantity ~= quantity then
		return false
	end
	return true
end

-- Strictly filters attributes against the catalog schema to block malicious client payloads
local function sanitizeAttributes(
	definition: ItemDefinition,
	rawAttributes: { [string]: any }?
): ({ [string]: any }?, string?)
	if rawAttributes == nil then
		return {}, nil
	end

	if type(rawAttributes) ~= "table" then
		return nil, "Invalid attribute payload type"
	end

	local sanitized: { [string]: any } = {}

	for key, value in pairs(rawAttributes) do
		local expectedType = definition.AllowedAttributes[key]
		if not expectedType then
			return nil, string.format("Unauthorized attribute key '%s' rejected", tostring(key))
		end

		if type(value) ~= expectedType then
			return nil, string.format("Type mismatch for attribute '%s': expected %s, got %s", key, expectedType, type(value))
		end

		-- Range and bounds checks on numbers
		if expectedType == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return nil, string.format("Invalid numeric value for attribute '%s'", key)
			end
			if value < 0 or value > 1000000 then
				return nil, string.format("Attribute '%s' value out of permitted range", key)
			end
		end

		-- String length limits
		if expectedType == "string" and string.len(value) > 64 then
			return nil, string.format("Attribute '%s' string length exceeds limit", key)
		end

		sanitized[key] = value
	end

	return sanitized, nil
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

-- Retrieves item definition from immutable catalog
function InventoryManager.GetItemDefinition(itemId: string): ItemDefinition?
	return ITEM_CATALOG[itemId]
end

-- Calculates current aggregated weight across all inventory items
function InventoryManager.CalculateTotalWeight(player: Player): number
	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return 0
	end

	local totalWeight = 0
	for _, item in pairs(profile.Data.Inventory) do
		local definition = ITEM_CATALOG[item.Id]
		if definition then
			totalWeight += definition.WeightKg * item.Quantity
		end
	end

	return math.round(totalWeight * 1000) / 1000
end

-- Returns number of active inventory slots occupied
function InventoryManager.GetSlotCount(player: Player): number
	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return 0
	end

	local count = 0
	for _ in pairs(profile.Data.Inventory) do
		count += 1
	end
	return count
end

-- Returns player's complete inventory table
function InventoryManager.GetInventory(player: Player): { [string]: ProfileManager.ItemData }?
	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return nil
	end
	return profile.Data.Inventory
end

-- Validates whether an item addition violates slot, stack, or weight constraints
function InventoryManager.CanAddItem(player: Player, itemId: string, quantity: number): (boolean, string?)
	if not isValidQuantity(quantity) then
		return false, "Invalid quantity specified"
	end

	local definition = ITEM_CATALOG[itemId]
	if not definition then
		return false, "Item does not exist in registry"
	end

	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return false, "Player profile not loaded"
	end

	-- Check weight limit
	local currentWeight = InventoryManager.CalculateTotalWeight(player)
	local addedWeight = definition.WeightKg * quantity
	if (currentWeight + addedWeight) > MAX_WEIGHT_KG then
		return false, string.format("Weight limit exceeded (Capacity: %.1fkg, Attempted: %.1fkg)", MAX_WEIGHT_KG, currentWeight + addedWeight)
	end

	-- Check slot availability (considering existing stackable slots)
	local currentSlots = InventoryManager.GetSlotCount(player)
	local remainingToAdd = quantity

	if definition.MaxStack > 1 then
		for _, item in pairs(profile.Data.Inventory) do
			if item.Id == itemId and item.Quantity < definition.MaxStack then
				local spaceInStack = definition.MaxStack - item.Quantity
				remainingToAdd -= spaceInStack
				if remainingToAdd <= 0 then
					break
				end
			end
		end
	end

	if remainingToAdd > 0 then
		local requiredNewSlots = math.ceil(remainingToAdd / definition.MaxStack)
		if (currentSlots + requiredNewSlots) > MAX_SLOTS then
			return false, string.format("Slot limit reached (%d/%d)", currentSlots, MAX_SLOTS)
		end
	end

	return true, nil
end

-- Server-Authoritative Item Addition
function InventoryManager.AddItem(
	player: Player,
	itemId: string,
	quantity: number,
	rawAttributes: { [string]: any }?
): (boolean, string?, string?)
	local canAdd, reason = InventoryManager.CanAddItem(player, itemId, quantity)
	if not canAdd then
		return false, reason, nil
	end

	local definition = ITEM_CATALOG[itemId] :: ItemDefinition
	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return false, "Profile uninitialized", nil
	end

	local sanitizedAttrs, attrErr = sanitizeAttributes(definition, rawAttributes)
	if not sanitizedAttrs then
		return false, attrErr, nil
	end

	local remainingQuantity = quantity
	local lastUUID: string? = nil

	-- Attempt to merge into existing stacks if item has no unique attributes
	local hasCustomAttributes = rawAttributes ~= nil and next(rawAttributes) ~= nil
	if definition.MaxStack > 1 and not hasCustomAttributes then
		for uuid, item in pairs(profile.Data.Inventory) do
			if item.Id == itemId and item.Quantity < definition.MaxStack then
				local availableSpace = definition.MaxStack - item.Quantity
				local amountToStack = math.min(availableSpace, remainingQuantity)

				item.Quantity += amountToStack
				remainingQuantity -= amountToStack
				lastUUID = uuid

				if remainingQuantity <= 0 then
					break
				end
			end
		end
	end

	-- Create new slots for any remaining units
	while remainingQuantity > 0 do
		local stackAmount = math.min(definition.MaxStack, remainingQuantity)
		local newUUID = HttpService:GenerateGUID(false)

		local newItem: ProfileManager.ItemData = {
			UUID = newUUID,
			Id = itemId,
			Quantity = stackAmount,
			Attributes = sanitizedAttrs or {},
		}

		profile.Data.Inventory[newUUID] = newItem
		remainingQuantity -= stackAmount
		lastUUID = newUUID
	end

	profile.IsDirty = true
	return true, nil, lastUUID
end

-- Server-Authoritative Item Removal by UUID
function InventoryManager.RemoveItem(player: Player, itemUUID: string, quantity: number): (boolean, string?)
	if not isValidQuantity(quantity) then
		return false, "Invalid quantity specified"
	end

	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return false, "Profile not loaded"
	end

	local item = profile.Data.Inventory[itemUUID]
	if not item then
		return false, "Item UUID not found in inventory"
	end

	if item.Quantity < quantity then
		return false, string.format("Insufficient quantity (Has: %d, Requested: %d)", item.Quantity, quantity)
	end

	item.Quantity -= quantity

	if item.Quantity <= 0 then
		profile.Data.Inventory[itemUUID] = nil
	end

	profile.IsDirty = true
	return true, nil
end

-- Checks if player has at least required amount of a given item ID
function InventoryManager.HasItem(player: Player, itemId: string, requiredQuantity: number?): boolean
	local needed = requiredQuantity or 1
	if needed <= 0 then
		return true
	end

	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return false
	end

	local foundCount = 0
	for _, item in pairs(profile.Data.Inventory) do
		if item.Id == itemId then
			foundCount += item.Quantity
			if foundCount >= needed then
				return true
			end
		end
	end

	return false
end

-- Finds a specific item instance by its UUID
function InventoryManager.GetItemByUUID(player: Player, itemUUID: string): ProfileManager.ItemData?
	local profile = ProfileManager.GetProfile(player)
	if not profile then
		return nil
	end
	return profile.Data.Inventory[itemUUID]
end

return InventoryManager
