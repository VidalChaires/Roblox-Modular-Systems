--!strict
--[[
    ExtractionSystem.lua
    Senior Gameplay Architecture: Tactical Raid Extraction & Session-to-Persistent Transfer
    
    Coordinates extraction zone triggers, countdown timers, combat/movement interruptions,
    and atomic transfer of in-raid loot into ProfileManager's persistent storage.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local ProfileManager = require(script.Parent.Parent.DataStore.ProfileManager)
local InventoryManager = require(script.Parent.InventoryManager)

local ExtractionSystem = {}
ExtractionSystem.__index = ExtractionSystem

--------------------------------------------------------------------------------
-- CONFIGURATION & CONSTANTS
--------------------------------------------------------------------------------

local DEFAULT_EXTRACTION_DURATION = 7.0 -- Seconds required to extract
local DEFAULT_ZONE_COOLDOWN = 15.0 -- Cooldown before a zone can be triggered again by same player
local HEARTBEAT_TOLERANCE_DISTANCE = 3.0 -- Studs allowed outside zone geometry before interruption

--------------------------------------------------------------------------------
-- TYPES
--------------------------------------------------------------------------------

export type SessionItem = {
	UUID: string,
	Id: string,
	Quantity: number,
	Attributes: { [string]: any },
}

export type ExtractionZone = {
	Id: string,
	Part: BasePart,
	Duration: number,
	Cooldown: number,
	LastExtracted: { [Player]: number },
}

export type ActiveExtraction = {
	Player: Player,
	Zone: ExtractionZone,
	StartTime: number,
	Duration: number,
	LastHealth: number,
	Thread: thread?,
	Connections: { [string]: RBXScriptConnection },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local ExtractionZones: { [string]: ExtractionZone } = {}
local ActiveExtractions: { [Player]: ActiveExtraction } = {}
local RaidSessionLoot: { [Player]: { [string]: SessionItem } } = {}

-- Signals (BindableEvents for internal server communication)
local ExtractionStartedEvent = Instance.new("BindableEvent")
local ExtractionProgressEvent = Instance.new("BindableEvent")
local ExtractionCancelledEvent = Instance.new("BindableEvent")
local ExtractionSuccessEvent = Instance.new("BindableEvent")

ExtractionSystem.OnExtractionStarted = ExtractionStartedEvent.Event
ExtractionSystem.OnExtractionProgress = ExtractionProgressEvent.Event
ExtractionSystem.OnExtractionCancelled = ExtractionCancelledEvent.Event
ExtractionSystem.OnExtractionSuccess = ExtractionSuccessEvent.Event

--------------------------------------------------------------------------------
-- INTERNAL HELPERS & VALIDATION
--------------------------------------------------------------------------------

local function isPlayerInsideZone(player: Player, zonePart: BasePart): boolean
	local character = player.Character
	if not character then
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return false
	end

	-- Transform RootPart position into ZonePart's local coordinate space
	local relativePos = zonePart.CFrame:PointToObjectSpace(rootPart.Position)
	local halfSize = (zonePart.Size / 2) + Vector3.new(HEARTBEAT_TOLERANCE_DISTANCE, HEARTBEAT_TOLERANCE_DISTANCE, HEARTBEAT_TOLERANCE_DISTANCE)

	return math.abs(relativePos.X) <= halfSize.X
		and math.abs(relativePos.Y) <= halfSize.Y
		and math.abs(relativePos.Z) <= halfSize.Z
end

local function cleanupExtraction(player: Player)
	local active = ActiveExtractions[player]
	if not active then
		return
	end

	if active.Thread then
		task.cancel(active.Thread)
		active.Thread = nil
	end

	for _, connection in pairs(active.Connections) do
		connection:Disconnect()
	end
	table.clear(active.Connections)

	ActiveExtractions[player] = nil
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

-- Initializes the extraction system and registers lifecycle hooks
function ExtractionSystem.Init()
	if RunService:IsClient() then
		error("[ExtractionSystem] Cannot run on client.")
	end

	-- Clean up session data on player leave
	Players.PlayerRemoving:Connect(function(player)
		cleanupExtraction(player)
		RaidSessionLoot[player] = nil
	end)
end

-- Registers a physical extraction zone in the game world
function ExtractionSystem.RegisterZone(
	zoneId: string,
	zonePart: BasePart,
	duration: number?,
	cooldown: number?
): ExtractionZone
	local zone: ExtractionZone = {
		Id = zoneId,
		Part = zonePart,
		Duration = duration or DEFAULT_EXTRACTION_DURATION,
		Cooldown = cooldown or DEFAULT_ZONE_COOLDOWN,
		LastExtracted = {},
	}

	ExtractionZones[zoneId] = zone
	return zone
end

-- Adds an item to the player's temporary raid bag during an active match
function ExtractionSystem.AddSessionLoot(
	player: Player,
	itemId: string,
	quantity: number,
	attributes: { [string]: any }?
): (boolean, string?)
	local definition = InventoryManager.GetItemDefinition(itemId)
	if not definition then
		return false, "Item does not exist in registry"
	end

	if not RaidSessionLoot[player] then
		RaidSessionLoot[player] = {}
	end

	local uuid = HttpService:GenerateGUID(false)
	local sessionItem: SessionItem = {
		UUID = uuid,
		Id = itemId,
		Quantity = quantity,
		Attributes = attributes or {},
	}

	RaidSessionLoot[player][uuid] = sessionItem
	return true, nil
end

-- Retrieves all session loot collected by player in current match
function ExtractionSystem.GetSessionLoot(player: Player): { [string]: SessionItem }
	return RaidSessionLoot[player] or {}
end

-- Cancels an ongoing extraction attempt with a logged reason
function ExtractionSystem.CancelExtraction(player: Player, reason: string)
	local active = ActiveExtractions[player]
	if not active then
		return
	end

	cleanupExtraction(player)
	ExtractionCancelledEvent:Fire(player, reason)
	print(string.format("[ExtractionSystem] Extraction cancelled for %s: %s", player.Name, reason))
end

-- Completes extraction: transfers session loot into ProfileManager persistent inventory
function ExtractionSystem.CompleteExtraction(player: Player)
	local active = ActiveExtractions[player]
	if not active then
		return
	end

	local zone = active.Zone
	zone.LastExtracted[player] = os.clock()

	cleanupExtraction(player)

	-- Atomic transfer from raid bag to permanent profile
	local raidItems = RaidSessionLoot[player] or {}
	local transferErrors: { string } = {}
	local transferredCount = 0

	for _, item in pairs(raidItems) do
		local success, reason = InventoryManager.AddItem(player, item.Id, item.Quantity, item.Attributes)
		if success then
			transferredCount += 1
		else
			table.insert(transferErrors, string.format("Item '%s': %s", item.Id, reason or "Unknown"))
		end
	end

	-- Clear raid loot container upon completion
	RaidSessionLoot[player] = {}

	-- Save persistent profile to DataStore immediately
	ProfileManager.SaveAsync(player)

	-- Flag character state (Invulnerable / Teleport to extraction hub)
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.MaxHealth = math.huge
			humanoid.Health = math.huge
			humanoid.WalkSpeed = 0
		end
	end

	ExtractionSuccessEvent:Fire(player, zone.Id, transferredCount, transferErrors)
	print(string.format("[ExtractionSystem] Player %s successfully extracted from %s with %d items.", player.Name, zone.Id, transferredCount))
end

-- Starts the extraction countdown sequence for a player in a specific zone
function ExtractionSystem.StartExtraction(player: Player, zoneId: string): (boolean, string?)
	if ActiveExtractions[player] then
		return false, "Extraction sequence already active"
	end

	local zone = ExtractionZones[zoneId]
	if not zone then
		return false, "Extraction zone does not exist"
	end

	-- Verify cooldown
	local lastTime = zone.LastExtracted[player]
	if lastTime and (os.clock() - lastTime) < zone.Cooldown then
		local remaining = math.ceil(zone.Cooldown - (os.clock() - lastTime))
		return false, string.format("Extraction zone on cooldown (%ds remaining)", remaining)
	end

	-- Verify character state
	local character = player.Character
	if not character then
		return false, "Character not found"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "Player is deceased or humanoid invalid"
	end

	if not isPlayerInsideZone(player, zone.Part) then
		return false, "Player is outside extraction zone boundary"
	end

	local active: ActiveExtraction = {
		Player = player,
		Zone = zone,
		StartTime = os.clock(),
		Duration = zone.Duration,
		LastHealth = humanoid.Health,
		Thread = nil,
		Connections = {},
	}

	ActiveExtractions[player] = active

	-- 1. Interruption check: Combat damage
	active.Connections["HealthChanged"] = humanoid.HealthChanged:Connect(function(newHealth)
		if newHealth < active.LastHealth then
			ExtractionSystem.CancelExtraction(player, "Extraction interrupted by incoming damage")
		else
			active.LastHealth = newHealth
		end
	end)

	-- 2. Interruption check: Death
	active.Connections["Died"] = humanoid.Died:Connect(function()
		ExtractionSystem.CancelExtraction(player, "Player died during extraction")
		RaidSessionLoot[player] = {} -- Lost on death
	end)

	-- 3. Countdown and Spatial Boundary Verification Thread
	active.Thread = task.spawn(function()
		local elapsed = 0
		while elapsed < active.Duration do
			task.wait(0.2)
			elapsed = os.clock() - active.StartTime

			-- Verify player hasn't stepped out of the extraction boundary
			if not isPlayerInsideZone(player, zone.Part) then
				ExtractionSystem.CancelExtraction(player, "Left extraction zone boundary")
				return
			end

			-- Fire progress tick (0.0 to 1.0)
			local progress = math.clamp(elapsed / active.Duration, 0, 1)
			ExtractionProgressEvent:Fire(player, zone.Id, progress, active.Duration - elapsed)
		end

		-- If still active, finalize extraction
		if ActiveExtractions[player] == active then
			ExtractionSystem.CompleteExtraction(player)
		end
	end)

	ExtractionStartedEvent:Fire(player, zone.Id, zone.Duration)
	return true, nil
end

return ExtractionSystem
