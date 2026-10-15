--!strict
--[[
    ProfileManager.lua
    Senior Gameplay Architecture: Enterprise Data Persistence & Session-Locking
    
    Prevents item duping and race conditions using atomic DataStore UpdateAsync locks.
    Implements exponential backoff retries, lease timeouts, and graceful session eviction.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ProfileManager = {}
ProfileManager.__index = ProfileManager

--------------------------------------------------------------------------------
-- CONFIGURATION & CONSTANTS
--------------------------------------------------------------------------------

local DATA_SCOPE = "Production"
local DATA_STORE_NAME = "PlayerData_v1"
local LOCK_LEASE_SECONDS = 120 -- Time after which an inactive lock is considered stale
local HEARTBEAT_INTERVAL = 30 -- Cadence for renewing lock timestamp
local MAX_RETRIES = 5
local BASE_RETRY_DELAY = 1.0
local BACKOFF_MULTIPLIER = 2.0

--------------------------------------------------------------------------------
-- TYPES
--------------------------------------------------------------------------------

export type ItemData = {
	UUID: string,
	Id: string,
	Quantity: number,
	Attributes: { [string]: any },
}

export type PlayerData = {
	Version: number,
	Credits: number,
	Inventory: { [string]: ItemData }, -- Keyed by Item UUID
	SessionLock: {
		JobId: string,
		Timestamp: number,
	}?,
}

export type Profile = {
	Player: Player,
	Data: PlayerData,
	IsLoaded: boolean,
	IsDirty: boolean,
	LastSaveTime: number,
	HeartbeatThread: thread?,
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local DataStore: GlobalDataStore? = nil
local ActiveProfiles: { [Player]: Profile } = {}
local ServerClosing = false

-- Fallback default schema for newly created profiles
local DEFAULT_DATA: PlayerData = {
	Version = 1,
	Credits = 1000,
	Inventory = {},
	SessionLock = nil,
}

--------------------------------------------------------------------------------
-- INTERNAL UTILITIES
--------------------------------------------------------------------------------

local function deepCopy<T>(target: T): T
	if type(target) ~= "table" then
		return target
	end
	local copy = {}
	for k, v in pairs(target :: any) do
		copy[k] = deepCopy(v)
	end
	return copy :: any
end

local function getDataStore(): GlobalDataStore
	if not DataStore then
		DataStore = DataStoreService:GetDataStore(DATA_STORE_NAME, DATA_SCOPE)
	end
	return DataStore :: GlobalDataStore
end

local function getPlayerKey(userId: number): string
	return string.format("Player_%d", userId)
end

-- Exponential backoff executor for DataStore calls
local function retryWithBackoff<T>(operation: () -> T): (boolean, T | string)
	local attempt = 0
	local delayTime = BASE_RETRY_DELAY

	while attempt < MAX_RETRIES do
		attempt += 1
		local success, result = pcall(operation)
		if success then
			return true, result
		end

		warn(string.format("[ProfileManager] DataStore error on attempt %d/%d: %s", attempt, MAX_RETRIES, tostring(result)))
		if attempt < MAX_RETRIES then
			task.wait(delayTime)
			delayTime *= BACKOFF_MULTIPLIER
		end
	end

	return false, "Maximum DataStore retry attempts exceeded"
end

--------------------------------------------------------------------------------
-- SESSION-LOCKING CORE
--------------------------------------------------------------------------------

-- Checks if a profile lock is currently active on another server
local function isLockedByAnotherServer(sessionLock: { JobId: string, Timestamp: number }?): boolean
	if not sessionLock then
		return false
	end

	-- Lock is held by current server instance
	if sessionLock.JobId == game.JobId then
		return false
	end

	-- Check if lease timestamp has expired
	local elapsedTime = os.time() - sessionLock.Timestamp
	if elapsedTime >= LOCK_LEASE_SECONDS then
		warn(string.format("[ProfileManager] Dead lock detected from JobId: %s (expired %ds ago). Overriding.", sessionLock.JobId, elapsedTime))
		return false
	end

	return true
end

-- Renews session lock timestamp periodically to avoid lease expiration
local function startHeartbeat(player: Player, profile: Profile)
	if profile.HeartbeatThread then
		task.cancel(profile.HeartbeatThread)
	end

	profile.HeartbeatThread = task.spawn(function()
		while profile.IsLoaded and player.Parent do
			task.wait(HEARTBEAT_INTERVAL)

			if not profile.IsLoaded or not player.Parent then
				break
			end

			local store = getDataStore()
			local key = getPlayerKey(player.UserId)

			local success, err = pcall(function()
				store:UpdateAsync(key, function(existingData: PlayerData?)
					if not existingData then
						return nil
					end

					-- If another server hijacked the lock while this session was active
					if existingData.SessionLock and existingData.SessionLock.JobId ~= game.JobId then
						return nil
					end

					existingData.SessionLock = {
						JobId = game.JobId,
						Timestamp = os.time(),
					}
					return existingData
				end)
			end)

			if not success then
				warn(string.format("[ProfileManager] Heartbeat failed for player %s: %s", player.Name, tostring(err)))
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

-- Initializes the profile persistence system and binds server shutdown hooks
function ProfileManager.Init()
	if RunService:IsClient() then
		error("[ProfileManager] Cannot run ProfileManager on the client.")
	end

	-- BindToClose ensures all active profiles release locks cleanly when server terminates
	game:BindToClose(function()
		ServerClosing = true
		local playersToSave = {}

		for player, _ in pairs(ActiveProfiles) do
			table.insert(playersToSave, player)
		end

		local completedCount = 0
		local totalCount = #playersToSave

		for _, player in ipairs(playersToSave) do
			task.spawn(function()
				ProfileManager.SaveAndReleaseAsync(player)
				completedCount += 1
			end)
		end

		-- Yield until all profiles are processed or Roblox 30-second shutdown timer is near
		local maxWait = 25
		local startWait = os.clock()
		while completedCount < totalCount and (os.clock() - startWait) < maxWait do
			task.wait(0.2)
		end

		print("[ProfileManager] BindToClose shutdown sequence completed.")
	end)
end

-- Atomic Profile Load with Session-Locking
function ProfileManager.LoadProfileAsync(player: Player): (Profile?, string?)
	if ActiveProfiles[player] then
		return ActiveProfiles[player], nil
	end

	local store = getDataStore()
	local key = getPlayerKey(player.UserId)
	local loadedData: PlayerData? = nil
	local lockRefused = false
	local lockRefusedReason = ""

	local success, errResult = retryWithBackoff(function()
		return store:UpdateAsync(key, function(existing: any)
			local data: PlayerData = existing or deepCopy(DEFAULT_DATA)

			-- Verify Session-Lock to eliminate race condition/duping
			if isLockedByAnotherServer(data.SessionLock) then
				lockRefused = true
				lockRefusedReason = string.format("Profile locked by JobId '%s'", data.SessionLock.JobId)
				return nil -- Abort update without modifying storage
			end

			-- Claim atomic session lock
			data.SessionLock = {
				JobId = game.JobId,
				Timestamp = os.time(),
			}

			loadedData = data
			return data
		end)
	end)

	if lockRefused then
		player:Kick("Your profile is loaded in another server. Please wait 1-2 minutes before reconnecting.")
		return nil, lockRefusedReason
	end

	if not success or not loadedData then
		return nil, tostring(errResult)
	end

	local profile: Profile = {
		Player = player,
		Data = loadedData,
		IsLoaded = true,
		IsDirty = false,
		LastSaveTime = os.time(),
		HeartbeatThread = nil,
	}

	ActiveProfiles[player] = profile
	startHeartbeat(player, profile)

	return profile, nil
end

-- Retrieves loaded profile from local memory
function ProfileManager.GetProfile(player: Player): Profile?
	return ActiveProfiles[player]
end

-- Saves profile data without releasing session lock
function ProfileManager.SaveAsync(player: Player): (boolean, string?)
	local profile = ActiveProfiles[player]
	if not profile or not profile.IsLoaded then
		return false, "Profile not loaded"
	end

	local store = getDataStore()
	local key = getPlayerKey(player.UserId)

	local success, errResult = retryWithBackoff(function()
		return store:UpdateAsync(key, function(existing: PlayerData?)
			if not existing then
				return nil
			end

			-- Verify ownership of lock
			if existing.SessionLock and existing.SessionLock.JobId ~= game.JobId then
				error("Session lock hijacked by another server instance")
			end

			local dataToSave = deepCopy(profile.Data)
			dataToSave.SessionLock = {
				JobId = game.JobId,
				Timestamp = os.time(),
			}

			return dataToSave
		end)
	end)

	if success then
		profile.IsDirty = false
		profile.LastSaveTime = os.time()
		return true, nil
	else
		return false, tostring(errResult)
	end
end

-- Saves data and completely clears session lock on player departure
function ProfileManager.SaveAndReleaseAsync(player: Player): (boolean, string?)
	local profile = ActiveProfiles[player]
	if not profile then
		return true, nil
	end

	profile.IsLoaded = false
	if profile.HeartbeatThread then
		task.cancel(profile.HeartbeatThread)
		profile.HeartbeatThread = nil
	end

	local store = getDataStore()
	local key = getPlayerKey(player.UserId)

	local success, errResult = retryWithBackoff(function()
		return store:UpdateAsync(key, function(existing: PlayerData?)
			if not existing then
				return nil
			end

			-- Only clear lock if this server owns it
			if existing.SessionLock and existing.SessionLock.JobId == game.JobId then
				local dataToSave = deepCopy(profile.Data)
				dataToSave.SessionLock = nil
				return dataToSave
			end

			return nil
		end)
	end)

	ActiveProfiles[player] = nil

	if success then
		return true, nil
	else
		warn(string.format("[ProfileManager] Failed to release lock for %s: %s", player.Name, tostring(errResult)))
		return false, tostring(errResult)
	end
end

return ProfileManager
