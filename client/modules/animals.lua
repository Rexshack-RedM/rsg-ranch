local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Core Variables
---------------------------------------------
local animalDataCache = {}
local followStates = {}
local transportingAnimals = {}
local isBusy = false
local wanderStates = {} -- Track wandering state for each animal
local wanderManagerRunning = false -- Whether the single shared wander-tick thread is active

-- Returns true if the LOCAL player currently works at the given ranch specifically -
-- used to gate each animal's map blip so only that ranch's own staff see it (unlike
-- isPlayerRanchStaff() below, which just checks membership at any ranch, for interactions).
local function isPlayerStaffOfRanch(ranchid)
    if not ranchid then return false end
    local PlayerData = RSGCore.Functions.GetPlayerData()
    if not PlayerData or not PlayerData.job then return false end
    return PlayerData.job.name == ranchid
end

-- Human-readable names for each animal model, used for blip labels (and anywhere else
-- a friendly name is needed instead of the raw ped model string).
local AnimalDisplayNames = {
    ['a_c_bull_01'] = 'sv_animal_bull',
    ['a_c_cow'] = 'sv_animal_cow',
    ['a_c_pig_01'] = 'sv_animal_pig',
    ['a_c_sheep_01'] = 'sv_animal_sheep',
}

local function GetAnimalDisplayName(model)
    if not model then return locale('cl_ranch_animal') end
    return AnimalDisplayNames[model] and locale(AnimalDisplayNames[model]) or model
end

-- Looks up the latest cached data for an animal by id (falls back to nil if it isn't
-- in the cache, e.g. it hasn't been received from the server yet). Defined up here so
-- both the blip logic and the animal info menu further down can use it.
local function getFreshAnimalData(animalid)
    local targetId = tostring(animalid)
    for _, cachedAnimal in ipairs(animalDataCache) do
        if tostring(cachedAnimal.animalid) == targetId then
            return cachedAnimal
        end
    end
    return nil
end

-- Maps an animal's health (0-100) to a blip color modifier name, using the same
-- thresholds as the health status shown in the animal info menu: green above 80,
-- yellow down to 10, red at 10 or below. RedM colors a blip via BlipAddModifier with
-- one of the BLIP_MODIFIER_MP_COLOR_* hashes, rather than a GTA-style SetBlipColour.
local function GetHealthBlipModifierName(health)
    health = tonumber(health) or 100
    if health > 80 then
        return 'BLIP_MODIFIER_MP_COLOR_8' -- green
    elseif health > 10 then
        return 'BLIP_MODIFIER_MP_COLOR_6' -- light yellow
    else
        return 'BLIP_MODIFIER_MP_COLOR_10' -- red
    end
end

-- Applies the health-based color modifier to a blip. BlipAddModifier only adds
-- modifiers - it doesn't replace one that's already there - so this removes whatever
-- color modifier is currently applied (tracked per-animal in SpawnManager.blipColorMods)
-- before adding the new one. Skips the swap entirely if the color hasn't changed.
local function ApplyHealthBlipColor(spawnManager, animalId, blip, health)
    local newModifierName = GetHealthBlipModifierName(health)
    local newModifierHash = joaat(newModifierName)
    local currentModifierHash = spawnManager.blipColorMods[animalId]

    if currentModifierHash == newModifierHash then
        return
    end

    if currentModifierHash then
        BlipRemoveModifier(blip, currentModifierHash)
    end

    BlipAddModifier(blip, newModifierHash)
    spawnManager.blipColorMods[animalId] = newModifierHash
end

---------------------------------------------
-- Spawn Manager (New System)
---------------------------------------------
local SpawnManager = {
    entities = {},          -- Stores spawned animal entities with metadata
    pending = {},          -- Tracks pending spawn requests
    blips = {},            -- Stores each animal's map blip (animalId -> blip handle), staff-only
    blipColorMods = {},    -- Stores each animal's currently-applied health color modifier hash
    config = {
        spawnDistance = 50.0,   -- Distance to spawn animals
        despawnDistance = 75.0, -- Distance to despawn animals
        checkInterval = 2000,   -- Check frequency in ms
        maxConcurrentSpawns = 5 -- Max animals spawning at once
    }
}

-- Initialize spawn manager
function SpawnManager:Initialize()
    self.entities = {}
    self.pending = {}
    self.blips = {}
    self.blipColorMods = {}
    
    -- Clean up any orphaned entities from previous sessions
    CreateThread(function()
        Wait(2000) -- Wait for player to fully load
        self:CleanupOrphanedEntities()
    end)
    
    -- Start the spawn check thread
    CreateThread(function()
        while true do
            self:CheckSpawnRequests()
            Wait(self.config.checkInterval)
        end
    end)
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Initialized new spawn system')
    end
end

-- Check what animals need to be spawned/despawned
function SpawnManager:CheckSpawnRequests()
    if not cache.ped or not DoesEntityExist(cache.ped) or #animalDataCache == 0 then
        return
    end
    
    -- Clean up stale pending requests (older than 30 seconds)
    local currentTime = GetGameTimer()
    local staleTimeout = 30000
    for animalId, requestData in pairs(self.pending) do
        if (currentTime - requestData.timestamp) > staleTimeout then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Cleaning up stale pending request for animal ' .. animalId)
            end
            self.pending[animalId] = nil
        end
    end
    
    local playerCoords = GetEntityCoords(cache.ped)
    local pendingCount = self:GetPendingCount()
    
    for _, animalData in ipairs(animalDataCache) do
        if self:IsValidAnimalData(animalData) then
            local animalId = tostring(animalData.animalid)
            local animalPos = vector3(animalData.pos_x, animalData.pos_y, animalData.pos_z)
            local distance = #(playerCoords - animalPos)
            
            -- Check if we should spawn this animal
            if distance <= self.config.spawnDistance then
                if not self.entities[animalId] and not self.pending[animalId] then
                    if pendingCount < self.config.maxConcurrentSpawns then
                        self:RequestSpawn(animalId, animalData)
                        pendingCount = pendingCount + 1
                    end
                end
            -- Check if we should despawn this animal
            elseif distance > self.config.despawnDistance then
                if self.entities[animalId] then
                    -- Don't despawn if animal is being transported or following
                    if not transportingAnimals[animalId] and not followStates[animalId] then
                        self:DespawnAnimal(animalId)
                    end
                end
            end
        end
    end
end

-- Validate animal data
function SpawnManager:IsValidAnimalData(data)
    return data and data.animalid and data.model and 
           data.pos_x and data.pos_y and data.pos_z and
           type(data.pos_x) == 'number' and type(data.pos_y) == 'number' and type(data.pos_z) == 'number'
end

-- Request to spawn an animal
function SpawnManager:RequestSpawn(animalId, animalData)
    -- Don't request if already spawned
    if self.entities[animalId] then
        local existingEntity = self.entities[animalId].entity
        if DoesEntityExist(existingEntity) then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Animal ' .. animalId .. ' already spawned, skipping request')
            end
            return
        else
            -- Clean up stale reference
            self.entities[animalId] = nil
        end
    end
    
    -- Don't request if already pending
    if self.pending[animalId] then
        if Config.Debug then
            print('^3[SPAWN MANAGER]^7 Spawn already pending for animal ' .. animalId)
        end
        return
    end
    
    self.pending[animalId] = {
        data = animalData,
        timestamp = GetGameTimer()
    }
    
    TriggerServerEvent('rsg-ranch:server:requestAnimalSpawn', animalId, animalData)
    
    if Config.Debug then
        print('^3[SPAWN MANAGER]^7 Requested spawn for animal ' .. animalId)
    end
end

-- Spawn an animal entity
function SpawnManager:SpawnAnimal(animalId, animalData, networkId, isCreator)
    -- Check if animal already exists
    if self.entities[animalId] then
        local existingEntity = self.entities[animalId].entity
        if DoesEntityExist(existingEntity) then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Animal ' .. animalId .. ' already exists (entity: ' .. existingEntity .. '), skipping spawn')
            end
            self.pending[animalId] = nil
            return true
        else
            -- Entity was deleted but not cleaned up, remove it
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Cleaning up stale entity reference for animal ' .. animalId)
            end
            self.entities[animalId] = nil
        end
    end
    
    -- If we have a networkId but are not the creator, wait for the entity to sync
    if networkId and not isCreator then
        -- Try to get the existing networked entity
        local entity = NetworkGetEntityFromNetworkId(networkId)
        if DoesEntityExist(entity) then
            if Config.Debug then
                print('^2[SPAWN MANAGER]^7 Using synced networked entity ' .. entity .. ' for animal ' .. animalId .. ' (netId: ' .. networkId .. ')')
            end
            self:ConfigureAnimalEntity(entity, animalData)
            self.entities[animalId] = {
                entity = entity,
                data = animalData,
                spawnTime = GetGameTimer(),
                networkId = networkId
            }
            self.pending[animalId] = nil
            self:SetupAnimalInteraction(entity, animalData)
            self:CreateOrUpdateAnimalBlip(animalId)
            if Config.AnimalWanderingEnabled then
                self:SetupAnimalWandering(animalId, entity, animalData)
            end
            return true
        end
        
        -- Entity doesn't exist yet, wait a bit and retry
        if Config.Debug then
            print('^3[SPAWN MANAGER]^7 Waiting for networked entity to sync for animal ' .. animalId .. ' (netId: ' .. networkId .. ')')
        end
        CreateThread(function()
            for i = 1, 10 do
                Wait(500)
                local entity = NetworkGetEntityFromNetworkId(networkId)
                if DoesEntityExist(entity) then
                    if Config.Debug then
                        print('^2[SPAWN MANAGER]^7 Synced networked entity ' .. entity .. ' for animal ' .. animalId .. ' after ' .. (i * 500) .. 'ms')
                    end
                    self:ConfigureAnimalEntity(entity, animalData)
                    self.entities[animalId] = {
                        entity = entity,
                        data = animalData,
                        spawnTime = GetGameTimer(),
                        networkId = networkId
                    }
                    self.pending[animalId] = nil
                    self:SetupAnimalInteraction(entity, animalData)
                    self:CreateOrUpdateAnimalBlip(animalId)
                    if Config.AnimalWanderingEnabled then
                        self:SetupAnimalWandering(animalId, entity, animalData)
                    end
                    return
                end
            end
            -- Timed out
            if Config.Debug then
                print('^1[SPAWN MANAGER]^7 Timed out waiting for networked entity for animal ' .. animalId)
            end
            self.pending[animalId] = nil
        end)
        return true
    end
    
    -- Only create if we are the creator
    if not isCreator then
        if Config.Debug then
            print('^3[SPAWN MANAGER]^7 Not creator and no networkId, cannot spawn animal ' .. animalId)
        end
        self.pending[animalId] = nil
        return false
    end
    
    local entity, newNetworkId = self:CreateAnimalEntity(animalData, nil)
    if not entity then
        if Config.Debug then
            print('^1[SPAWN MANAGER]^7 Failed to create entity for animal ' .. animalId)
        end
        self.pending[animalId] = nil
        return false
    end
    
    -- Store entity with metadata including network ID
    self.entities[animalId] = {
        entity = entity,
        data = animalData,
        spawnTime = GetGameTimer(),
        networkId = newNetworkId or networkId
    }
    
    -- Clean up pending request
    self.pending[animalId] = nil
    
    -- Report network ID to server for tracking (we are the creator)
    if newNetworkId then
        TriggerServerEvent('rsg-ranch:server:registerAnimalNetworkId', animalId, newNetworkId)
    end
    
    -- Setup interaction (restricted to ranch staff via canInteract)
    self:SetupAnimalInteraction(entity, animalData)
    self:CreateOrUpdateAnimalBlip(animalId)
    
    -- Setup wandering behavior if enabled
    if Config.AnimalWanderingEnabled then
        self:SetupAnimalWandering(animalId, entity, animalData)
    end
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Spawned animal ' .. animalId .. ' (entity: ' .. entity .. ', netId: ' .. (newNetworkId or networkId or 'none') .. ')')
    end
    
    return true
end

-- Create the actual animal entity
function SpawnManager:CreateAnimalEntity(animalData, networkId)
    local model = GetHashKey(animalData.model)
    
    -- Request model
    lib.requestModel(model, 5000)
    if not HasModelLoaded(model) then
        return nil
    end
    
    -- Check if we should use an existing networked entity from server
    if networkId and networkId > 0 then
        local entity = NetworkGetEntityFromNetworkId(networkId)
        if DoesEntityExist(entity) then
            if Config.Debug then
                print('^2[SPAWN MANAGER]^7 Using existing networked entity ' .. entity .. ' (netId: ' .. networkId .. ')')
            end
            self:ConfigureAnimalEntity(entity, animalData)
            return entity, networkId
        end
    end
    
    -- Create the ped as a networked entity (isNetwork = true)
    local entity = CreatePed(
        model,
        animalData.pos_x,
        animalData.pos_y,
        animalData.pos_z - 1.0,
        animalData.pos_w or 0,
        true,  -- isNetwork: true for multiplayer visibility
        false,
        0,
        0
    )
    
    if not DoesEntityExist(entity) then
        return nil
    end
    
    -- Register entity as networked and get network ID
    NetworkRegisterEntityAsNetworked(entity)
    local newNetworkId = NetworkGetNetworkIdFromEntity(entity)
    
    -- Configure entity
    self:ConfigureAnimalEntity(entity, animalData)
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Created networked entity ' .. entity .. ' (netId: ' .. newNetworkId .. ')')
    end
    
    return entity, newNetworkId
end

-- Configure animal entity properties
function SpawnManager:ConfigureAnimalEntity(entity, animalData)
    -- Networked entity configuration
    -- Animals are visible to all players but interactions are restricted to ranch staff
    
    -- Scale handling
    local scale = tonumber(animalData.scale) or 1.0
    if scale <= 0 or scale ~= scale then scale = 1.0 end
    scale = math.min(math.max(scale, 0.1), 2.0)
    SetPedScale(entity, scale)
    
    -- Entity properties
    -- SetEntityAsMissionEntity keeps it from being auto-deleted
    SetEntityAsMissionEntity(entity, true, true)
    SetEntityInvincible(entity, true)
    FreezeEntityPosition(entity, false)
    SetPedOutfitPreset(entity, 0)
    SetRelationshipBetweenGroups(1, GetPedRelationshipGroupHash(entity), joaat('PLAYER'))
    SetBlockingOfNonTemporaryEvents(entity, true)
    
    -- Fade in effect
    if Config.AnimalFadeIn then
        SetEntityAlpha(entity, 0, false)
        CreateThread(function()
            for i = 0, 255, 51 do
                if DoesEntityExist(entity) then
                    SetEntityAlpha(entity, i, false)
                    Wait(50)
                end
            end
        end)
    end
end

-- Create (or refresh) an animal's map blip, only for players who work at that specific
-- ranch. The blip is attached to the animal's entity so it tracks the animal as it
-- wanders, and is removed automatically the moment the local player is no longer that
-- ranch's staff (job change, fired, etc) via the periodic refresh loop below.
function SpawnManager:CreateOrUpdateAnimalBlip(animalId)
    if not Config.AnimalBlipsEnabled then return end

    local entityInfo = self.entities[animalId]
    if not entityInfo then return end

    local entity = entityInfo.entity
    if not entity or not DoesEntityExist(entity) then
        self:RemoveAnimalBlip(animalId)
        return
    end

    local shouldShow = isPlayerStaffOfRanch(entityInfo.data and entityInfo.data.ranchid)
    if not shouldShow then
        self:RemoveAnimalBlip(animalId)
        return
    end

    -- Health can change after the blip is first created (feeding, damage, time), so
    -- pull the freshest cached value we have rather than whatever health the entity
    -- was spawned with.
    local freshAnimal = getFreshAnimalData(animalId)
    local health = (freshAnimal and freshAnimal.health) or (entityInfo.data and entityInfo.data.health)

    local existingBlip = self.blips[animalId]
    if existingBlip and DoesBlipExist(existingBlip) then
        -- Already showing and attached to the entity - just keep its color current
        -- with the animal's health, since the refresh loop calls this periodically.
        ApplyHealthBlipColor(self, animalId, existingBlip, health)
        return
    end

    local blip = BlipAddForEntity(1664425300, entity)
    SetBlipSprite(blip, joaat(Config.AnimalBlipSprite or 'blip_ambient_companion'), true)
    SetBlipScale(blip, Config.AnimalBlipScale or 0.15)
    SetBlipName(blip, GetAnimalDisplayName(entityInfo.data and entityInfo.data.model))
    ApplyHealthBlipColor(self, animalId, blip, health)
    self.blips[animalId] = blip

    if Config.Debug then
        print('^2[ANIMAL BLIP]^7 Created blip for animal ' .. animalId .. ' (ranch staff only)')
    end
end

-- Remove an animal's map blip, if it currently has one
function SpawnManager:RemoveAnimalBlip(animalId)
    local blip = self.blips[animalId]
    if blip then
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        self.blips[animalId] = nil
    end
    self.blipColorMods[animalId] = nil
end

-- Setup animal interaction (ox_target)
function SpawnManager:SetupAnimalInteraction(entity, animalData)
    local animalId = tostring(animalData.animalid)

    exports.ox_target:addLocalEntity(entity, {
        {
            name = 'ranch_animal',
            label = locale('cl_animals_label_1'),
            onSelect = function()
                TriggerEvent('rsg-ranch:client:animalmenu', entity, animalData)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        },
    })
end

-- NOTE: animals are now fed/watered automatically by the ranch's feed/water trough
-- pool (see ProcessAnimalSurvival / BuildRanchTroughPools server-side) as long as the
-- ranch has a stocked trough, so the old manual "Send to Drink"/"Send to Feed" actions
-- and the walk-to-trough simulation below are no longer needed.

-- Setup animal wandering behavior
function SpawnManager:SetupAnimalWandering(animalId, entity, animalData)
    -- Store spawn point as home location
    local homePosition = vector3(animalData.pos_x, animalData.pos_y, animalData.pos_z)

    -- Initialize wander state
    wanderStates[animalId] = {
        entity = entity,
        homePosition = homePosition,
        state = 'idle', -- 'idle' or 'moving'
        stateChangeTime = GetGameTimer(),
        targetPosition = nil,
        active = true,
        lastPositionSave = GetGameTimer()
    }

    -- All animals share a single ticking thread (see StartWanderManager) instead of
    -- spawning one CreateThread per animal - keeps this cheap even with dozens of animals.
    self:StartWanderManager()

    if Config.Debug then
        print('^2[WANDER]^7 Setup wandering for animal ' .. animalId)
    end
end

-- Single shared thread that ticks every wandering animal on Config.WanderCheckInterval.
-- Started lazily the first time an animal needs wandering, and exits on its own once
-- there are no more wandering animals to process (restarted next time one is needed).
function SpawnManager:StartWanderManager()
    if wanderManagerRunning then return end
    wanderManagerRunning = true

    CreateThread(function()
        while next(wanderStates) ~= nil do
            for animalId, wanderState in pairs(wanderStates) do
                if wanderState.active then
                    self:UpdateAnimalWander(animalId)
                end
            end
            Wait(Config.WanderCheckInterval or 2000)
        end
        wanderManagerRunning = false
    end)
end

-- Update animal wandering behavior
function SpawnManager:UpdateAnimalWander(animalId)
    local wanderState = wanderStates[animalId]
    if not wanderState then return end
    
    local entity = wanderState.entity
    
    -- Check if entity still exists
    if not DoesEntityExist(entity) then
        wanderStates[animalId] = nil
        return
    end
    
    -- Don't wander if following player or being transported
    if followStates[animalId] or transportingAnimals[animalId] then
        return
    end

    -- Periodically sync this animal's live position back to the server/DB while it's
    -- freely wandering (following/transporting animals are covered separately by
    -- StartFollowSyncManager and the herding stop handler). Without this the DB only
    -- ever holds the animal's original spawn point, so a resource restart would always
    -- respawn it there even after it had wandered well away from it.
    do
        local currentTime = GetGameTimer()
        if currentTime - (wanderState.lastPositionSave or 0) >= (Config.WanderPositionSaveInterval or 30000) then
            wanderState.lastPositionSave = currentTime

            local pos = GetEntityCoords(entity)
            local heading = GetEntityHeading(entity)
            TriggerServerEvent('rsg-ranch:server:saveAnimalPosition', animalId, pos.x, pos.y, pos.z, heading)

            -- Keep the local cache in step too, so CheckSpawnRequests measures distance
            -- from where the animal actually is, not its original spawn point
            for _, cachedAnimal in ipairs(animalDataCache) do
                if tostring(cachedAnimal.animalid) == animalId then
                    cachedAnimal.pos_x = pos.x
                    cachedAnimal.pos_y = pos.y
                    cachedAnimal.pos_z = pos.z
                    break
                end
            end

            if Config.Debug then
                print('^3[WANDER]^7 Synced position for wandering animal ' .. animalId)
            end
        end
    end

    -- Animals are fed/watered automatically server-side (see ProcessAnimalSurvival)
    -- whenever their ranch has a stocked feed/water trough, so wandering no longer
    -- gets interrupted to walk to one.

    local currentTime = GetGameTimer()
    local timeSinceStateChange = currentTime - wanderState.stateChangeTime
    
    if wanderState.state == 'idle' then
        -- Animal is standing still
        local idleTime = math.random(Config.WanderIdleTimeMin or 10000, Config.WanderIdleTimeMax or 30000)
        
        if timeSinceStateChange >= idleTime then
            -- Time to start moving
            self:StartAnimalWander(animalId, wanderState)
        end
    elseif wanderState.state == 'moving' then
        -- Animal is moving
        local moveTime = math.random(Config.WanderMoveTimeMin or 5000, Config.WanderMoveTimeMax or 15000)
        
        -- Check if reached target or time expired
        if wanderState.targetPosition then
            local currentPos = GetEntityCoords(entity)
            local distanceToTarget = #(currentPos - wanderState.targetPosition)
            
            if distanceToTarget < 1.0 or timeSinceStateChange >= moveTime then
                -- Reached destination or timeout, stop moving
                self:StopAnimalWander(animalId, wanderState)
            end
        else
            -- No target, something went wrong, stop
            self:StopAnimalWander(animalId, wanderState)
        end
    end
end

-- Start animal wandering to a new position
function SpawnManager:StartAnimalWander(animalId, wanderState)
    local entity = wanderState.entity
    local homePos = wanderState.homePosition
    
    -- Generate random wander position within radius from home
    local wanderRadius = Config.WanderRadius or 15.0
    local minDistance = Config.WanderMinDistance or 3.0
    
    -- Random angle and distance
    local angle = math.random() * math.pi * 2
    local distance = math.random() * (wanderRadius - minDistance) + minDistance
    
    -- Calculate target position
    local targetX = homePos.x + math.cos(angle) * distance
    local targetY = homePos.y + math.sin(angle) * distance
    
    -- Get ground Z coordinate
    local foundGround, groundZ = GetGroundZFor_3dCoord(targetX, targetY, homePos.z + 10.0, false)
    local targetZ = foundGround and groundZ or homePos.z
    
    local targetPos = vector3(targetX, targetY, targetZ)
    
    -- Update state
    wanderState.state = 'moving'
    wanderState.targetPosition = targetPos
    wanderState.stateChangeTime = GetGameTimer()
    
    -- Make animal walk to target
    TaskGoToCoordAnyMeans(entity, targetX, targetY, targetZ, Config.WanderSpeed or 1.0, 0, false, 786603, 0xbf800000)
    
    if Config.Debug then
        print('^3[WANDER]^7 Animal ' .. animalId .. ' started wandering to ' .. string.format('%.1f, %.1f, %.1f', targetX, targetY, targetZ))
    end
end

-- Stop animal wandering and make it idle
function SpawnManager:StopAnimalWander(animalId, wanderState)
    local entity = wanderState.entity
    
    -- Clear tasks
    ClearPedTasks(entity)
    
    -- Update state
    wanderState.state = 'idle'
    wanderState.targetPosition = nil
    wanderState.stateChangeTime = GetGameTimer()
    
    if Config.Debug then
        print('^2[WANDER]^7 Animal ' .. animalId .. ' stopped wandering (now idle)')
    end
end

-- Pause an animal's wandering so it stands still (e.g. while a product is being
-- collected from it). Safe to call even if the animal isn't currently wandering.
-- Idempotent: calling it twice just keeps the animal paused.
function SpawnManager:PauseAnimalWander(animalId)
    local wanderState = wanderStates[animalId]
    if not wanderState then return end

    wanderState.paused = true
    wanderState.active = false
    wanderState.targetPosition = nil

    local entity = wanderState.entity
    if entity and DoesEntityExist(entity) then
        ClearPedTasks(entity)
        TaskStandStill(entity, -1)
    end

    if Config.Debug then
        print('^3[WANDER]^7 Paused wandering for animal ' .. animalId .. ' (product collection)')
    end
end

-- Resume an animal's wandering after PauseAnimalWander. Puts it back into the
-- normal idle state so the shared wander-tick thread picks it up again.
function SpawnManager:ResumeAnimalWander(animalId)
    local wanderState = wanderStates[animalId]
    if not wanderState or not wanderState.paused then return end

    wanderState.paused = nil
    wanderState.active = true
    wanderState.state = 'idle'
    wanderState.targetPosition = nil
    wanderState.stateChangeTime = GetGameTimer()

    local entity = wanderState.entity
    if entity and DoesEntityExist(entity) then
        ClearPedTasks(entity)
    end

    if Config.Debug then
        print('^2[WANDER]^7 Resumed wandering for animal ' .. animalId .. ' (product collected)')
    end
end

-- Despawn an animal
function SpawnManager:DespawnAnimal(animalId)
    local animalInfo = self.entities[animalId]
    if not animalInfo then return end
    
    -- Remove its map blip, if it had one
    self:RemoveAnimalBlip(animalId)

    local entity = animalInfo.entity
    if DoesEntityExist(entity) then
        -- Remove interaction
        exports.ox_target:removeLocalEntity(entity, {'ranch_animal'})

        -- Fade out effect
        if Config.AnimalFadeIn then
            CreateThread(function()
                for i = 255, 0, -51 do
                    if DoesEntityExist(entity) then
                        SetEntityAlpha(entity, i, false)
                        Wait(50)
                    end
                end
                if DoesEntityExist(entity) then
                    DeletePed(entity)
                end
            end)
        else
            DeletePed(entity)
        end
    end
    
    -- Clean up wander state
    if wanderStates[animalId] then
        wanderStates[animalId].active = false
        wanderStates[animalId] = nil
    end
    
    -- Report despawn to server so it can clear tracking
    TriggerServerEvent('rsg-ranch:server:reportDespawn', animalId)
    
    -- Clean up data
    self.entities[animalId] = nil
    
    if Config.Debug then
        print('^1[SPAWN MANAGER]^7 Despawned animal ' .. animalId)
    end
end

-- Periodically re-checks every spawned animal's blip against the local player's current
-- job, so blips appear/disappear on hire/fire or job switch without needing the animal
-- to despawn and respawn first.
CreateThread(function()
    while true do
        Wait(Config.AnimalBlipRefreshInterval or 5000)

        if Config.AnimalBlipsEnabled then
            for animalId in pairs(SpawnManager.entities) do
                SpawnManager:CreateOrUpdateAnimalBlip(animalId)
            end
        end
    end
end)

-- Get count of pending spawns
function SpawnManager:GetPendingCount()
    local count = 0
    for _ in pairs(self.pending) do
        count = count + 1
    end
    return count
end

-- Get animal entity by ID (for other systems)
function SpawnManager:GetEntityById(animalId)
    local animalInfo = self.entities[tostring(animalId)]
    if animalInfo and DoesEntityExist(animalInfo.entity) then
        return animalInfo.entity
    end
    return nil
end

-- Remove specific animal (for selling/deletion)
function SpawnManager:RemoveAnimal(animalId)
    local animalKey = tostring(animalId)
    
    if self.entities[animalKey] then
        self:DespawnAnimal(animalKey)
    end
    
    -- Clean up related states
    followStates[animalKey] = nil
    transportingAnimals[animalKey] = nil
    if wanderStates[animalKey] then
        wanderStates[animalKey].active = false
        wanderStates[animalKey] = nil
    end
    
    -- Remove from cache
    for i, cachedAnimal in ipairs(animalDataCache) do
        if tostring(cachedAnimal.animalid) == animalKey then
            table.remove(animalDataCache, i)
            break
        end
    end
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Removed animal ' .. animalId .. ' completely')
    end
end

-- Clear all spawned animals
function SpawnManager:ClearAll()
    for animalId in pairs(self.entities) do
        self:DespawnAnimal(animalId)
    end
    self.pending = {}
    
    -- Clean up all wander states
    for animalId in pairs(wanderStates) do
        wanderStates[animalId].active = false
        wanderStates[animalId] = nil
    end
    
    if Config.Debug then
        print('^3[SPAWN MANAGER]^7 Cleared all spawned animals')
    end
end

-- Clean up orphaned animal entities (for startup)
function SpawnManager:CleanupOrphanedEntities()
    if not cache.ped or not DoesEntityExist(cache.ped) then
        return
    end
    
    local playerCoords = GetEntityCoords(cache.ped)
    local cleanedCount = 0
    local maxRadius = 200

    -- Precompute the set of ranch animal model hashes once instead of hashing on every entity
    local ranchAnimalModels = {}
    if Config.AnimalProducts then
        for animalModel, _ in pairs(Config.AnimalProducts) do
            ranchAnimalModels[GetHashKey(animalModel)] = true
        end
    end
    for _, animalModel in ipairs({'a_c_bull_01', 'a_c_cow', 'a_c_pig_01', 'a_c_sheep_01', 'a_c_hen_01', 'a_c_rooster_01', 'a_c_goat_01'}) do
        ranchAnimalModels[GetHashKey(animalModel)] = true
    end

    -- Single pass over all world peds at the widest radius we care about
    local nearbyPeds = GetGamePool('CPed')

    for _, entity in ipairs(nearbyPeds) do
        if DoesEntityExist(entity) and entity ~= cache.ped then
            local entityCoords = GetEntityCoords(entity)
            local distance = #(playerCoords - entityCoords)

            if distance <= maxRadius then
                local model = GetEntityModel(entity)

                if ranchAnimalModels[model] then
                    -- Check if this entity is tracked by our spawn manager
                    local isTracked = false
                    for _, spawnData in pairs(self.entities) do
                        if spawnData.entity == entity then
                            isTracked = true
                            break
                        end
                    end

                    -- If it's not tracked, it's likely orphaned from a previous session
                    if not isTracked then
                        -- Remove any ox_target interactions
                        exports.ox_target:removeLocalEntity(entity, {'ranch_animal'})

                        -- Delete the orphaned entity
                        DeletePed(entity)
                        cleanedCount = cleanedCount + 1

                        if Config.Debug then
                            print('^1[SPAWN MANAGER]^7 Cleaned up orphaned animal entity: ' .. entity .. ' (model: ' .. model .. ')')
                        end
                    end
                end
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[SPAWN MANAGER]^7 Startup cleanup completed - removed ' .. cleanedCount .. ' orphaned animal entities')
    elseif Config.Debug then
        print('^2[SPAWN MANAGER]^7 Startup cleanup completed - no orphaned entities found')
    end
end

---------------------------------------------
-- Helper Functions
---------------------------------------------
-- Make isPlayerRanchStaff global so ox_target can access it
function isPlayerRanchStaff()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    if not PlayerData or not PlayerData.job then
        return false
    end
    
    local playerjob = PlayerData.job.name
    
    -- All ranch staff levels (0-2) can target animals
    -- Level 0: Trainee Rancher, Level 1: Ranch Hand, Level 2: Ranch Manager
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return true
        end
    end
    
    return false
end

local function finalizeAnimalMenu(menuOptions, freshData, animal)
    table.insert(menuOptions, {
        title = locale('cl_animals_title_18'),
        disabled = true
    })
    table.insert(menuOptions, {
        title = locale('cl_animals_title_19'),
        description = locale('cl_animals_description_20'),
        event = 'rsg-ranch:client:actionsmenu',
        args = { animalid = freshData.animalid, animal = animal },
        arrow = true
    })
    
    Menu.registerContext({
        id = 'animal_info_menu',
        title = locale('cl_animals_title_21'):format((GetAnimalDisplayName and GetAnimalDisplayName(freshData.model) or 'Ranch Animal'), freshData.animalid),
        options = menuOptions
    })
    Menu.showContext('animal_info_menu')
end

---------------------------------------------
-- Server Communication Events
---------------------------------------------

-- Player loaded - initialize system
RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    SpawnManager:Initialize()
    TriggerServerEvent('rsg-ranch:server:refreshAnimals')
end)

-- Receive animal data from server
RegisterNetEvent('rsg-ranch:client:spawnAnimals', function(animalData, isFullList)
    animalData = animalData or {}

    if isFullList then
        animalDataCache = animalData
        if Config.Debug then
            print('^2[SPAWN MANAGER]^7 Received ' .. #animalData .. ' animals from server (full refresh)')
        end
        return
    end

    -- Partial update (e.g. a newly bought animal) - merge into the cache
    for _, newAnimal in ipairs(animalData) do
        local found = false
        for i, cachedAnimal in ipairs(animalDataCache) do
            if tostring(cachedAnimal.animalid) == tostring(newAnimal.animalid) then
                animalDataCache[i] = newAnimal
                found = true
                break
            end
        end
        if not found then
            animalDataCache[#animalDataCache + 1] = newAnimal
        end
    end
end)

-- Server grants spawn permission (now includes network ID for sync and isCreator flag)
RegisterNetEvent('rsg-ranch:client:spawnAnimalGranted', function(animalId, animalData, networkId, isCreator)
    SpawnManager:SpawnAnimal(animalId, animalData, networkId, isCreator)
end)

-- Server denies spawn request
RegisterNetEvent('rsg-ranch:client:spawnAnimalDenied', function(animalId, reason)
    SpawnManager.pending[animalId] = nil
    
    if Config.Debug then
        print('^3[SPAWN MANAGER]^7 Spawn denied for animal ' .. animalId .. ': ' .. (reason or 'unknown'))
    end
end)

-- Remove specific animal
RegisterNetEvent('rsg-ranch:client:removeAnimal', function(animalid)
    SpawnManager:RemoveAnimal(animalid)
end)

-- Update single animal data
RegisterNetEvent('rsg-ranch:client:refreshSingleAnimal', function(animalid, updatedData)
    animalid = tostring(animalid)
    for i, cachedAnimal in ipairs(animalDataCache) do
        if tostring(cachedAnimal.animalid) == animalid then
            for key, value in pairs(updatedData) do
                animalDataCache[i][key] = value
            end
            break
        end
    end
end)

-- Update many animals at once (sent by the server cron jobs instead of one event per animal)
RegisterNetEvent('rsg-ranch:client:refreshAnimalsBatch', function(updates)
    if type(updates) ~= 'table' or #updates == 0 then return end
    local index = {}
    for i, cachedAnimal in ipairs(animalDataCache) do
        index[tostring(cachedAnimal.animalid)] = i
    end
    for _, update in ipairs(updates) do
        local i = index[tostring(update.animalid)]
        if i then
            for key, value in pairs(update.data) do
                animalDataCache[i][key] = value
            end
        end
    end
end)

-- Set transport mode (prevents despawning)
RegisterNetEvent('rsg-ranch:client:setAnimalTransporting', function(animalIds, transporting)
    if type(animalIds) == 'table' then
        for _, animalId in ipairs(animalIds) do
            local key = tostring(animalId)
            transportingAnimals[key] = transporting or nil
        end
    else
        local key = tostring(animalIds)
        transportingAnimals[key] = transporting or nil
    end
    
    if Config.Debug then
        local count = 0
        for _ in pairs(transportingAnimals) do count = count + 1 end
        print('^2[SPAWN MANAGER]^7 Transport mode animals: ' .. count)
    end
end)

---------------------------------------------
-- Animal Interaction Events
---------------------------------------------

-- Animal menu
RegisterNetEvent('rsg-ranch:client:animalmenu', function(animal, data)
    if not DoesEntityExist(animal) or not data or not data.animalid then
        lib.notify({ title = locale('cl_animals_title_22'), description = locale('cl_animals_description_23'), type = 'error' })
        return
    end
    
    local freshData = getFreshAnimalData(data.animalid) or data
    
    -- Ensure required fields exist
    freshData.health = freshData.health or 100
    freshData.thirst = freshData.thirst or 100
    freshData.hunger = freshData.hunger or 100
    freshData.age = freshData.age or 0
    freshData.animalid = freshData.animalid or data.animalid
    
    local actualAge = freshData.age or 0
    local genderText = (freshData.gender == 'male' or freshData.gender == 'female') and locale('ui_gender_' .. freshData.gender) or locale('cl_unknown')
    local isPregnant = (freshData.pregnant == 1 or freshData.pregnant == true)
    local pregnantStatus = isPregnant and locale('cl_pregnant') or locale('cl_not_pregnant')
    
    -- Animal age category - matches Config.PrimeAgeStart/Config.MinAgeToSell so an
    -- animal only shows as "Adult" once it's actually old enough to sell.
    local ageText = (actualAge < Config.PrimeAgeStart) and locale('cl_age_youth') or locale('cl_age_adult')

    -- Health status colors
    local healthColorScheme = 'green'
    if freshData.health > 80 then healthColorScheme = 'green'
    elseif freshData.health > 10 then healthColorScheme = 'yellow'
    else healthColorScheme = 'red' end
    freshData.health = math.min(math.max(freshData.health or 100, 0), 100)
    
    local thirstColorScheme = 'green'
    if freshData.thirst > 80 then thirstColorScheme = 'green' end
    if freshData.thirst <= 80 and freshData.thirst > 10 then thirstColorScheme = 'yellow' end
    if freshData.thirst <= 10 then thirstColorScheme = 'red' end
    freshData.thirst = math.min(math.max(freshData.thirst or 100, 0), 100)
    
    local hungerColorScheme = 'green'
    if freshData.hunger > 80 then hungerColorScheme = 'green' end
    if freshData.hunger <= 80 and freshData.hunger > 10 then hungerColorScheme = 'yellow' end
    if freshData.hunger <= 10 then hungerColorScheme = 'red' end
    freshData.hunger = math.min(math.max(freshData.hunger or 100, 0), 100)
    
    -- Build menu options
    local menuOptions = {
        {
            title = locale('cl_animals_title_24'),
            description = locale('cl_animals_description_25'),
            disabled = false
        },
        {
            title = locale('cl_animals_title_26'):format(ageText),
            description = locale('cl_animals_description_27'):format(actualAge),
            disabled = false
        },
        {
            title = locale('cl_animals_title_28'):format(genderText:gsub("^%l", string.upper)),
            description = freshData.gender == 'female' and pregnantStatus or locale('cl_male_animal'),
            disabled = false
        },
        {
            title = locale('cl_animals_title_29'):format(math.floor(freshData.health)),
            description = locale('cl_animals_description_30'),
            progress = freshData.health,
            colorScheme = healthColorScheme,
            disabled = false
        },
        {
            title = locale('cl_animals_title_31'):format(math.floor(freshData.thirst)),
            description = locale('cl_animals_description_32'),
            progress = freshData.thirst,
            colorScheme = thirstColorScheme,
            disabled = false
        },
        {
            title = locale('cl_animals_title_33'):format(math.floor(freshData.hunger)),
            description = locale('cl_animals_description_34'),
            progress = freshData.hunger,
            colorScheme = hungerColorScheme,
            disabled = false
        }
    }
    
    -- Get detailed breeding status from server (includes cooldown information)
    if Config.BreedingEnabled and (freshData.gender == 'female' or freshData.gender == 'male') then
        RSGCore.Functions.TriggerCallback('rsg-ranch:server:getBreedingStatus', function(breedingData)
            local breedingOption = nil
        
        if breedingData.status == 'pregnant' then
            -- Get pregnancy progress for pregnant animals
            RSGCore.Functions.TriggerCallback('rsg-ranch:server:getPregnancyProgress', function(progressData)
                if progressData and progressData.isPregnant then
                    breedingOption = {
                        title = locale('cl_animals_title_35'),
                        description = progressData.description,
                        progress = progressData.progressPercent,
                        colorScheme = 'blue',
                        disabled = false
                    }
                else
                    breedingOption = {
                        title = locale('cl_animals_title_36'),
                        description = locale('cl_animals_description_37'),
                        disabled = false
                    }
                end
                
                table.insert(menuOptions, breedingOption)
                
                -- Complete the menu display
                finalizeAnimalMenu(menuOptions, freshData, animal)
            end, freshData.animalid)
            return
        elseif breedingData.status == 'cooldown' then
            breedingOption = {
                title = locale('cl_animals_title_38'),
                description = breedingData.message,
                disabled = false
            }
            
            -- Add progress bar for cooldown if we have time remaining info
            if breedingData.timeRemaining and breedingData.timeRemaining > 0 then
                -- Use gender-specific cooldown for progress calculation
                local totalCooldown
                if Config.GenderSpecificCooldowns and freshData.gender then
                    totalCooldown = Config.GenderSpecificCooldowns[freshData.gender]
                end
                
                -- Fallback to default cooldown
                if not totalCooldown or totalCooldown == 0 then
                    totalCooldown = Config.BreedingCooldown or 172800 -- 2 days default
                end
                
                if totalCooldown > 0 then
                    local elapsedTime = totalCooldown - breedingData.timeRemaining
                    local progressPercent = math.max(0, math.min(100, (elapsedTime / totalCooldown) * 100))
                    
                    breedingOption.progress = progressPercent
                    breedingOption.colorScheme = 'orange'
                else
                    -- Fallback if cooldown config is invalid
                    breedingOption.progress = 50
                    breedingOption.colorScheme = 'orange'
                end
            end
        elseif breedingData.status == 'ready' then
            breedingOption = {
                title = locale('cl_animals_title_39'),
                description = breedingData.message,
                disabled = false
            }
            
            -- Add breeding partner button for ready animals
            local buttonTitle = locale('cl_find_breeding_partner')
            local buttonDesc = locale('cl_find_partner_any')
            
            if freshData.gender == 'male' then
                buttonDesc = locale('cl_find_partner_female')
            elseif freshData.gender == 'female' then
                buttonDesc = locale('cl_find_partner_male')
            end
            
            table.insert(menuOptions, breedingOption)
            table.insert(menuOptions, {
                title = locale('cl_animals_title_40'):format(buttonTitle),
                description = buttonDesc,
                event = 'rsg-ranch:client:findBreedingPartner',
                args = { animalid = freshData.animalid, animal = animal }
            })
            
            -- Complete the menu display
            finalizeAnimalMenu(menuOptions, freshData, animal)
            return
        else
            -- Handle other statuses (disabled, too_young, too_old, requirements_not_met, error)
            local statusTitles = {
                disabled = 'cl_breed_status_disabled',
                too_young = 'cl_breed_status_too_young',
                too_old = 'cl_breed_status_too_old',
                requirements_not_met = 'cl_breed_status_not_ready',
                error = 'cl_breed_status_error'
            }
            
            breedingOption = {
                title = locale('cl_animals_title_41'):format(locale(statusTitles[breedingData.status] or 'cl_unknown')),
                description = breedingData.message,
                disabled = false
            }
        end
        
        if breedingOption then
            table.insert(menuOptions, breedingOption)
        end
        
        -- Complete the menu display
        finalizeAnimalMenu(menuOptions, freshData, animal)
    end, freshData.animalid)
else
    -- Animal doesn't qualify for breeding or breeding is disabled
    finalizeAnimalMenu(menuOptions, freshData, animal)
end
end)

-- Animal actions menu
RegisterNetEvent('rsg-ranch:client:actionsmenu', function(data)
    local animalid = data.animalid
    local animal = data.animal
    
    local freshData = getFreshAnimalData(animalid)
    if not freshData then
        lib.notify({ title = locale('cl_animals_title_42'), description = locale('cl_animals_description_43'), type = 'error' })
        return
    end
    
    local hungerStatus = freshData.hunger > 80 and locale('cl_well_fed') or freshData.hunger > 50 and locale('cl_hungry') or locale('cl_starving')
    local thirstStatus = freshData.thirst > 80 and locale('cl_hydrated') or freshData.thirst > 50 and locale('cl_thirsty') or locale('cl_dehydrated')
    local followStatus = followStates[tostring(animalid)] and locale('cl_following') or locale('cl_idle')

    Menu.registerContext({
        id = 'animal_action_menu',
        title = locale('cl_animals_title_44'),
        menu = 'animal_info_menu',
        options = {
            {
                title = locale('cl_animals_title_45'):format(followStatus),
                description = locale('cl_animals_description_46'),
                event = 'rsg-ranch:client:animalfollow',
                args = { animal = animal, animalid = animalid }
            },
            {
                title = locale('cl_animals_title_47'),
                disabled = true
            },
            {
                title = locale('cl_animals_title_48'):format(hungerStatus),
                description = locale('cl_animals_description_49'):format(Config.FeedTroughItem),
                disabled = true
            },
            {
                title = locale('cl_animals_title_119'),
                description = locale('cl_animals_description_120'),
                event = 'rsg-ranch:client:animalsendfeed',
                args = { animal = animal, animalid = animalid }
            },
            {
                title = locale('cl_animals_title_50'):format(thirstStatus),
                description = locale('cl_animals_description_51'),
                disabled = true
            },
            {
                title = locale('cl_animals_title_120'),
                description = locale('cl_animals_description_121'),
                event = 'rsg-ranch:client:animalsendwater',
                args = { animal = animal, animalid = animalid }
            },
            {
                title = locale('cl_animals_title_52'),
                disabled = true
            },
            {
                title = locale('cl_animals_title_53'),
                description = locale('cl_animals_description_54'),
                event = 'rsg-ranch:client:checkProducts',
                args = { animalid = animalid, animal = animal }
            },
        }
    })
    Menu.showContext('animal_action_menu')
end)

---------------------------------------------
-- Manual "send to trough" actions
--
-- Animals are fed/watered automatically by the ranch's trough pool once
-- hunger/thirst drops to/below the configured threshold (see
-- ProcessAnimalFeedWater server-side), but a player can still send an
-- individual animal to feed/drink on demand from the action menu above -
-- useful to top an animal up early, or right before selling/breeding it.
---------------------------------------------
local sendToTroughBusy = {} -- [animalid] = true while that animal is already walking to a trough

local function SendAnimalToTrough(kind, data)
    local animal = data.animal
    local animalid = data.animalid
    local animalKey = tostring(animalid)

    if not DoesEntityExist(animal) or IsPedDeadOrDying(animal, true) then
        lib.notify({ title = locale('cl_animals_title_55'), description = locale('cl_animals_description_56'), type = 'error' })
        return
    end

    if sendToTroughBusy[animalKey] then
        return
    end

    local freshData = getFreshAnimalData(animalid)
    if not freshData then
        lib.notify({ title = locale('cl_animals_title_42'), description = locale('cl_animals_description_43'), type = 'error' })
        return
    end

    local animalPos = GetEntityCoords(animal)
    local trough
    if kind == 'feed' then
        trough = GetNearestFeedTrough and GetNearestFeedTrough(animalPos, freshData.ranchid) or nil
    else
        trough = GetNearestWaterTrough and GetNearestWaterTrough(animalPos, freshData.ranchid) or nil
    end

    if not trough then
        if kind == 'feed' then
            lib.notify({ title = locale('cl_animals_title_121'), description = locale('cl_animals_description_122'), type = 'error' })
        else
            lib.notify({ title = locale('cl_animals_title_122'), description = locale('cl_animals_description_123'), type = 'error' })
        end
        return
    end

    sendToTroughBusy[animalKey] = true

    -- Stop the animal wandering/following on its own while it's sent to the trough,
    -- so it doesn't fight the walk task; both resume automatically afterward.
    local wasFollowing = followStates[animalKey]
    followStates[animalKey] = false
    if wanderStates[animalKey] then
        wanderStates[animalKey].active = false
    end

    -- Move at a jog (not the slower passive wander pace) since this is a deliberate,
    -- player-triggered trip, and size the timeout to the actual distance being covered -
    -- troughs can be up to Config.FeedTroughSearchRadius/WaterTroughSearchRadius (100
    -- units by default) away, which a fixed short timeout couldn't reliably cover,
    -- wrongly reporting the trough as "unreachable" while the animal was still en route.
    local sendSpeed = 2.0

    if kind == 'feed' then
        lib.notify({ title = locale('cl_animals_title_123'), description = locale('cl_animals_description_124'), duration = 4000, type = 'inform' })
    else
        lib.notify({ title = locale('cl_animals_title_124'), description = locale('cl_animals_description_125'), duration = 4000, type = 'inform' })
    end

    CreateThread(function()
        local interactDistance = (kind == 'feed' and Config.FeedTroughInteractDistance or Config.WaterTroughInteractDistance) or 2.0
        -- ~1.8 m/s at a jog is a conservative estimate; add a flat buffer for pathing
        -- around obstacles (fences, other animals) plus acceleration/turning, and a
        -- floor so very close troughs still get a fair amount of time.
        local estimatedTravelTime = ((trough.distance or 0) / 1.8) * 1000
        local deadline = GetGameTimer() + math.max(15000, estimatedTravelTime + 10000)
        local arrived = false

        -- A single long-distance TaskGoToCoordAnyMeans call is not reliable on its own for
        -- these animal peds - default ambient behavior (grazing/idle) can quietly take back
        -- over partway through and stall the ped well short of the trough. Herding
        -- (herding.lua) and passive wandering both work around this the same way: keep
        -- re-issuing the move task periodically instead of firing it once and hoping it
        -- runs to completion, so the animal gets nudged back on course if it ever stalls.
        local lastTaskIssue = 0
        local retaskInterval = 2000

        -- Water troughs are frequently placed near ponds/rivers, and RedM's navmesh
        -- often doesn't extend walkable ground all the way to the water's edge - an
        -- animal can get genuinely stuck a few units short of the exact trough position
        -- with nothing left to path onto, even though it clearly "got there". A tighter
        -- exact-distance requirement works for open-ground feed troughs but is too
        -- strict for that case, so once the animal has closed most of the distance and
        -- stopped making further progress, accept a looser distance instead of failing
        -- outright.
        local closeEnoughDistance = interactDistance + 3.0
        local bestDistanceSeen = (trough.distance or 0) + 1
        local stalledSince = nil
        local stallGraceMs = 4000

        while GetGameTimer() < deadline do
            if not DoesEntityExist(animal) then
                sendToTroughBusy[animalKey] = nil
                return
            end

            local currentDistance = #(GetEntityCoords(animal) - trough.pos)
            if currentDistance <= interactDistance then
                arrived = true
                break
            end

            if currentDistance < bestDistanceSeen - 0.25 then
                -- Still making real progress toward the trough
                bestDistanceSeen = currentDistance
                stalledSince = nil
            elseif currentDistance <= closeEnoughDistance then
                -- Close, but not making further progress (likely blocked by terrain/navmesh
                -- right at the trough) - give it a short grace period, then accept it
                stalledSince = stalledSince or GetGameTimer()
                if GetGameTimer() - stalledSince >= stallGraceMs then
                    arrived = true
                    if Config.Debug then
                        print('^3[SEND TO TROUGH]^7 Animal ' .. animalKey .. ' stalled ' .. string.format('%.2f', currentDistance) .. ' units from trough - accepting as arrived')
                    end
                    break
                end
            else
                stalledSince = nil
            end

            local now = GetGameTimer()
            if now - lastTaskIssue >= retaskInterval then
                lastTaskIssue = now
                ClearPedTasks(animal)
                TaskGoToCoordAnyMeans(animal, trough.pos.x, trough.pos.y, trough.pos.z, sendSpeed, 0, false, 786603, 0xbf800000)
            end

            Wait(250)
        end

        if not arrived and Config.Debug and DoesEntityExist(animal) then
            print('^1[SEND TO TROUGH]^7 Animal ' .. animalKey .. ' gave up ' .. string.format('%.2f', #(GetEntityCoords(animal) - trough.pos)) .. ' units from trough (closeEnough=' .. closeEnoughDistance .. ')')
        end

        sendToTroughBusy[animalKey] = nil

        -- Resume normal wandering/following behavior now that the trip is over
        if wanderStates[animalKey] then
            wanderStates[animalKey].active = true
        end
        if wasFollowing and DoesEntityExist(animal) then
            followStates[animalKey] = true
            local animalOffset = vector3(0.0, 2.0, 0.0)
            ClearPedTasks(animal)
            TaskFollowToOffsetOfEntity(animal, cache.ped, animalOffset.x, animalOffset.y, animalOffset.z, 1.0, -1, 0.0, 1)
        end

        if not arrived then
            if kind == 'feed' then
                lib.notify({ title = locale('cl_animals_title_125'), description = locale('cl_animals_description_126'), type = 'error' })
            else
                lib.notify({ title = locale('cl_animals_title_126'), description = locale('cl_animals_description_127'), type = 'error' })
            end
            return
        end

        if kind == 'feed' then
            TriggerServerEvent('rsg-ranch:server:sendAnimalToFeed', animalid, trough.feedtroughid)
        else
            TriggerServerEvent('rsg-ranch:server:sendAnimalToWater', animalid, trough.watertroughid)
        end
    end)
end

RegisterNetEvent('rsg-ranch:client:animalsendfeed', function(data)
    SendAnimalToTrough('feed', data)
end)

RegisterNetEvent('rsg-ranch:client:animalsendwater', function(data)
    SendAnimalToTrough('water', data)
end)

-- Periodically sync a followed animal's live position back to the server/DB.
-- Without this, the DB (and SpawnController's server-side tracking) only ever knows the
-- animal's original spawn point, because saveAnimalPosition otherwise only fires when follow
-- is switched off. If anything forces a re-spawn while an animal is still being led around
-- (a network hiccup, entity culling, the server deciding no one's "nearby" and clearing its
-- spawn tracking) it would previously recreate the animal back at that stale spawn point -
-- i.e. teleported back to the Livestock Dealer. Keeping the DB position roughly current makes
-- that a non-event: worst case it respawns near where it actually is.
local followSyncRunning = false
local function StartFollowSyncManager()
    if followSyncRunning then return end
    followSyncRunning = true

    CreateThread(function()
        while true do
            Wait(5000)
            local stillFollowing = false

            for animalId, isFollowing in pairs(followStates) do
                if isFollowing then
                    local animalInfo = SpawnManager.entities[animalId]
                    if animalInfo and DoesEntityExist(animalInfo.entity) then
                        stillFollowing = true
                        local pos = GetEntityCoords(animalInfo.entity)
                        local heading = GetEntityHeading(animalInfo.entity)

                        TriggerServerEvent('rsg-ranch:server:saveAnimalPosition', animalId, pos.x, pos.y, pos.z, heading)

                        -- Keep the local cache in step too, so CheckSpawnRequests measures
                        -- distance from where the animal actually is, not its original spawn point
                        for _, cachedAnimal in ipairs(animalDataCache) do
                            if tostring(cachedAnimal.animalid) == animalId then
                                cachedAnimal.pos_x = pos.x
                                cachedAnimal.pos_y = pos.y
                                cachedAnimal.pos_z = pos.z
                                break
                            end
                        end
                    end
                end
            end

            if not stillFollowing then
                followSyncRunning = false
                return
            end
        end
    end)
end

-- Animal follow system
RegisterNetEvent('rsg-ranch:client:animalfollow', function(data)
    if not DoesEntityExist(data.animal) or not DoesEntityExist(cache.ped) then
        lib.notify({ title = locale('cl_animals_title_55'), description = locale('cl_animals_description_56'), type = 'error' })
        return
    end

    if IsPedDeadOrDying(data.animal, true) then
        lib.notify({ title = locale('cl_animals_title_57'), description = locale('cl_animals_description_58'), type = 'error' })
        return
    end

    -- Normalize to the same string key SpawnManager uses everywhere else (self.entities,
    -- wanderStates, transportingAnimals all key off tostring(animalid)). data.animalid comes
    -- from the DB-backed animal cache and can arrive as a number, which previously caused
    -- followStates[<number>] to be set here while CheckSpawnRequests read followStates[<string>] -
    -- the despawn guard never saw the follow flag, so followed animals got despawned once they
    -- were led far enough from their spawn point, then respawned back at that stale spawn
    -- position (the Livestock Dealer) the next time the spawn check re-evaluated.
    local animalKey = tostring(data.animalid)

    if followStates[animalKey] == nil then
        followStates[animalKey] = false
    end

    followStates[animalKey] = not followStates[animalKey]

    if followStates[animalKey] then
        local animalOffset = vector3(0.0, 2.0, 0.0)
        ClearPedTasks(data.animal)
        TaskFollowToOffsetOfEntity(data.animal, cache.ped, animalOffset.x, animalOffset.y, animalOffset.z, 1.0, -1, 0.0, 1)
        StartFollowSyncManager()
        lib.notify({ title = locale('cl_animals_title_59'), description = locale('cl_animals_description_60'), duration = 5000, type = 'inform' })
    else
        local currentPos = GetEntityCoords(data.animal)
        local heading = GetEntityHeading(data.animal)
        ClearPedTasks(data.animal)
        TriggerServerEvent('rsg-ranch:server:saveAnimalPosition', data.animalid, currentPos.x, currentPos.y, currentPos.z, heading)
        lib.notify({ title = locale('cl_animals_title_61'), description = locale('cl_animals_description_62'), duration = 5000, type = 'inform' })
    end
end)

-- Check products
RegisterNetEvent('rsg-ranch:client:checkProducts', function(data)
    local animalid = data.animalid
    local animal = data.animal
    
    if not DoesEntityExist(animal) or not animalid then
        lib.notify({ title = locale('cl_animals_title_63'), description = locale('cl_animals_description_64'), type = 'error' })
        return
    end
    
    RSGCore.Functions.TriggerCallback('rsg-ranch:server:getAnimalProductionStatus', function(productionData)
        if not productionData then
            lib.notify({ title = locale('cl_animals_title_65'), description = locale('cl_animals_description_66'), type = 'inform' })
            return
        end
        
        local timeText = ''
        if productionData.hasProduct then
            timeText = locale('cl_ready_to_collect')
        elseif productionData.canProduce then
            local hours = math.floor(productionData.timeUntilNext / 3600)
            local minutes = math.floor((productionData.timeUntilNext % 3600) / 60)
            timeText = locale('cl_next_production_in'):format(hours, minutes)
        else
            timeText = locale('cl_needs_better_care')
        end
        
        local options = {
            {
                title = locale('cl_animals_title_67'),
                description = locale('cl_animals_description_68'),
                disabled = false
            },
            {
                title = locale('cl_animals_title_69'):format(productionData.productName),
                description = locale('cl_animals_description_70'):format(productionData.productAmount, productionData.productName),
                disabled = false
            },
            {
                title = locale('cl_animals_title_71'):format(timeText),
                description = productionData.canProduce and locale('cl_meets_production') or locale('cl_improve_care'),
                disabled = false
            }
        }
        
        if productionData.hasProduct then
            table.insert(options, {
                title = locale('cl_animals_title_72'),
                disabled = true
            })
            table.insert(options, {
                title = locale('cl_animals_title_73'):format(productionData.productName),
                description = locale('cl_animals_description_74'):format(productionData.productAmount, productionData.productName),
                event = 'rsg-ranch:client:collectProduct',
                args = { animalid = animalid, animal = animal }
            })
        end
        
        Menu.registerContext({
            id = 'animal_production_menu',
            title = locale('cl_animals_title_75'),
            menu = 'animal_action_menu',
            options = options
        })
        Menu.showContext('animal_production_menu')
    end, animalid)
end)

-- Collect product
RegisterNetEvent('rsg-ranch:client:collectProduct', function(data)
    local animal = data.animal
    local animalid = data.animalid
    
    if not DoesEntityExist(cache.ped) or not DoesEntityExist(animal) then
        lib.notify({ title = locale('cl_animals_title_76'), description = locale('cl_animals_description_77'), type = 'error' })
        return
    end
    
    if not isBusy then
        isBusy = true
        LocalPlayer.state:set('inv_busy', true, true)
        -- Make the animal stand still for the duration of the collection so it
        -- doesn't wander off mid-animation, then let it resume wandering after.
        SpawnManager:PauseAnimalWander(tostring(animalid))
        TaskTurnPedToFaceEntity(cache.ped, animal, 2000)
        Wait(1500)
        FreezeEntityPosition(cache.ped, true)
        TaskStartScenarioInPlace(cache.ped, `WORLD_HUMAN_CROUCH_INSPECT`, 0, true)
        Wait(5000)
        ClearPedTasks(cache.ped)
        SetCurrentPedWeapon(cache.ped, `WEAPON_UNARMED`, true)
        FreezeEntityPosition(cache.ped, false)
        TriggerServerEvent('rsg-ranch:server:collectProduct', animalid)
        SpawnManager:ResumeAnimalWander(tostring(animalid))
        LocalPlayer.state:set('inv_busy', false, true)
        isBusy = false
    end
end)

---------------------------------------------
-- Export Functions
---------------------------------------------
function GetAnimalEntityById(animalId)
    return SpawnManager:GetEntityById(animalId)
end

exports('GetAnimalEntityById', GetAnimalEntityById)
exports('GetAnimalDataCache', function() return animalDataCache end)

---------------------------------------------
-- Debug Commands
---------------------------------------------
-- Manual cleanup command for troubleshooting
RegisterCommand('cleanupranchanimals', function()
    local Player = RSGCore.Functions.GetPlayerData()
    if not Player or not Player.job then return end
    
    local playerjob = Player.job.name
    local isRanchStaff = false
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            isRanchStaff = true
            break
        end
    end
    
    if isRanchStaff then
        lib.notify({ title = locale('cl_animals_title_78'), description = locale('cl_animals_description_79'), type = 'inform' })
        
        -- Clear current tracked animals
        SpawnManager:ClearAll()
        
        -- Clean up orphaned entities
        SpawnManager:CleanupOrphanedEntities()
        
        -- Refresh from server
        TriggerServerEvent('rsg-ranch:server:refreshAnimals')
        
        lib.notify({ title = locale('cl_animals_title_80'), description = locale('cl_animals_description_81'), type = 'success' })
    else
        lib.notify({ title = locale('cl_animals_title_82'), description = locale('cl_animals_description_83'), type = 'error' })
    end
end, false)

-- Debug command to test production system - only registered when Config.Debug is on,
-- so it isn't exposed to players on production servers.
if Config.Debug then
    RegisterCommand('testproduction', function(source, args)
        local Player = RSGCore.Functions.GetPlayerData()
        if not Player or not Player.job then return end

        local playerjob = Player.job.name
        local isRanchStaff = false

        for _, ranchData in pairs(Config.RanchLocations) do
            if playerjob == ranchData.jobaccess then
                isRanchStaff = true
                break
            end
        end

        if not isRanchStaff then
            lib.notify({ title = locale('cl_animals_title_84'), description = locale('cl_animals_description_85'), type = 'error' })
            return
        end

        local animalid = tonumber(args[1])
        if not animalid then
            lib.notify({ title = locale('cl_animals_title_86'), description = locale('cl_animals_description_87'), type = 'inform' })
            return
        end

        lib.notify({ title = locale('cl_animals_title_88'), description = locale('cl_animals_description_89'):format(animalid), type = 'inform' })

        RSGCore.Functions.TriggerCallback('rsg-ranch:server:getAnimalProductionStatus', function(productionData)
            print('^3[CLIENT PRODUCTION TEST]^7 Result for animal ' .. animalid .. ':')
            if productionData then
                print('^3[CLIENT PRODUCTION TEST]^7 - Product Name: ' .. tostring(productionData.productName))
                print('^3[CLIENT PRODUCTION TEST]^7 - Product Amount: ' .. tostring(productionData.productAmount))
                print('^3[CLIENT PRODUCTION TEST]^7 - Has Product: ' .. tostring(productionData.hasProduct))
                print('^3[CLIENT PRODUCTION TEST]^7 - Can Produce: ' .. tostring(productionData.canProduce))
                print('^3[CLIENT PRODUCTION TEST]^7 - Time Until Next: ' .. tostring(productionData.timeUntilNext))
            else
                print('^1[CLIENT PRODUCTION TEST]^7 - Result is false/nil')
            end

            if not productionData then
                lib.notify({ title = locale('cl_animals_title_90'), description = locale('cl_animals_description_91'):format(animalid), type = 'error' })
            else
                local status = productionData.hasProduct and locale('cl_ready_to_collect') or
                              productionData.canProduce and locale('cl_can_produce') or locale('cl_cannot_produce')
                lib.notify({
                    title = locale('cl_animals_title_92'),
                    description = locale('cl_animals_description_93'):format(animalid, productionData.productName, status),
                    type = 'success'
                })
            end
        end, animalid)
    end, false)
end

---------------------------------------------
-- Breeding System Events
---------------------------------------------

-- Find breeding partner (from animal info menu)
RegisterNetEvent('rsg-ranch:client:findBreedingPartner', function(data)
    local animalid = data.animalid
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local ranchid = PlayerData.job.name
    
    RSGCore.Functions.TriggerCallback('rsg-ranch:server:getAvailableAnimalsForBreeding', function(availableAnimals)
        if not availableAnimals or #availableAnimals == 0 then
            lib.notify({ 
                title = locale('cl_animals_title_94'), 
                description = locale('cl_animals_description_95'), 
                type = 'inform' 
            })
            return
        end
        
        local options = {
            {
                title = locale('cl_animals_title_96'),
                description = locale('cl_animals_description_97'):format(#availableAnimals),
                disabled = false
            },
            {
                title = locale('cl_animals_title_98'),
                disabled = false
            }
        }
        
        for _, partner in ipairs(availableAnimals) do
            local genderIcon = partner.gender == 'male' and '♂️' or '♀️'
            local healthStatus = partner.health > 80 and locale('cl_health_excellent') or partner.health > 50 and locale('cl_health_good') or locale('cl_health_poor')
            local description = locale('cl_animals_description_99'):format(partner.age, healthStatus, math.floor(partner.health))
            description = locale('cl_animals_description_100'):format(description, partner.distance)
            
            if not partner.canBreed then
                description = locale('cl_animals_description_101'):format(description, partner.breedingIssue)
            end
            
            table.insert(options, {
                title = locale('cl_animals_title_102'):format(genderIcon, partner.gender:gsub("^%l", string.upper), partner.animalid),
                description = description,
                metadata = {
                    { label = locale('cl_animals_label_103'), value = partner.canBreed and 'Ready' or 'Not Ready' },
                    { label = locale('cl_animals_label_104'), value = math.floor(partner.health) .. '%' },
                    { label = locale('cl_animals_label_105'), value = locale('cl_distance_m'):format(partner.distance) }
                },
                disabled = not partner.canBreed,
                event = partner.canBreed and 'rsg-ranch:client:confirmBreeding' or nil,
                args = partner.canBreed and { 
                    animal1id = animalid, 
                    animal2id = partner.animalid,
                    partner = partner
                } or nil
            })
        end
        
        Menu.registerContext({
            id = 'breeding_partner_menu',
            title = locale('cl_animals_title_106'),
            menu = 'animal_info_menu',
            options = options
        })
        Menu.showContext('breeding_partner_menu')
        
    end, ranchid, animalid)
end)

-- Confirm breeding (from animal info menu)
RegisterNetEvent('rsg-ranch:client:confirmBreeding', function(data)
    local animal1id = data.animal1id
    local animal2id = data.animal2id
    local partner = data.partner
    
    local alert = Menu.alertDialog({
        header = locale('cl_animals_header_107'),
        content = locale('cl_animals_content_108'):format(animal1id, animal2id),
        centered = true,
        cancel = true
    })
    
    if alert == 'confirm' then
        TriggerServerEvent('rsg-ranch:server:startBreeding', animal1id, animal2id)
    end
end)

-- Menu validation debug command - only registered when Config.Debug is on,
-- so it isn't exposed to players on production servers.
if Config.Debug then
RegisterCommand('validatemenu', function(source, args)
    local Player = RSGCore.Functions.GetPlayerData()
    if not Player or not Player.job then
        lib.notify({ title = locale('cl_animals_title_109'), description = locale('cl_animals_description_110'), type = 'error' })
        return
    end
    
    local playerjob = Player.job.name
    local isRanchStaff = false
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            isRanchStaff = true
            break
        end
    end
    
    if not isRanchStaff then
        lib.notify({ title = locale('cl_animals_title_111'), description = locale('cl_animals_description_112'), type = 'error' })
        return
    end
    
    local animalid = tonumber(args[1])
    if not animalid then
        lib.notify({ title = locale('cl_animals_title_113'), description = locale('cl_animals_description_114'), type = 'inform' })
        return
    end
    
    lib.notify({ title = locale('cl_animals_title_115'), description = locale('cl_animals_description_116'):format(animalid), type = 'inform' })
    
    local validationResults = {}
    
    -- Check 1: Animal data exists in cache
    local animalData = getFreshAnimalData(animalid)
    if animalData then
        table.insert(validationResults, '✅ Animal data found in cache')
        
        -- Check 2: Required fields exist
        local requiredFields = {'animalid', 'model', 'health', 'hunger', 'thirst', 'age', 'gender'}
        local missingFields = {}
        
        for _, field in ipairs(requiredFields) do
            if not animalData[field] then
                table.insert(missingFields, field)
            end
        end
        
        if #missingFields == 0 then
            table.insert(validationResults, '✅ All required fields present')
        else
            table.insert(validationResults, '❌ Missing fields: ' .. table.concat(missingFields, ', '))
        end
        
        -- Check 3: Model has product config
        if Config.AnimalProducts[animalData.model] then
            table.insert(validationResults, '✅ Product config found for model: ' .. animalData.model)
        else
            table.insert(validationResults, '⚠️ No product config for model: ' .. animalData.model)
        end
        
    else
        table.insert(validationResults, '❌ Animal data not found in cache')
    end
    
    -- Check 4: Entity exists in spawn manager
    local entity = SpawnManager:GetEntityById(animalid)
    if entity and DoesEntityExist(entity) then
        table.insert(validationResults, '✅ Entity exists and spawned')
        
        -- Check 5: ox_target interaction  
        local playerCoords = GetEntityCoords(cache.ped)
        local entityCoords = GetEntityCoords(entity)
        local distance = #(playerCoords - entityCoords)
        
        if distance <= 3.0 then
            table.insert(validationResults, '✅ Entity within interaction range (' .. math.floor(distance * 10) / 10 .. 'm)')
        else
            table.insert(validationResults, '⚠️ Entity outside interaction range (' .. math.floor(distance * 10) / 10 .. 'm > 3m)')
        end
        
    else
        table.insert(validationResults, '❌ Entity not found or not spawned')
    end
    
    -- Check 6: Required items in inventory
    local hasWater = RSGCore.Functions.HasItem(Config.WaterItem, 1)

    if hasWater then
        table.insert(validationResults, '✅ Has ' .. Config.WaterItem .. ' for watering')
    else
        table.insert(validationResults, '⚠️ Missing ' .. Config.WaterItem .. ' (watering will fail)')
    end
    
    -- Display results
    CreateThread(function()
        for i, result in ipairs(validationResults) do
            lib.notify({ 
                title = locale('cl_animals_title_117'):format(i, #validationResults), 
                description = result,
                type = string.find(result, '✅') and 'success' or string.find(result, '❌') and 'error' or 'info'
            })
            Wait(1500)
        end
        
        local passedChecks = 0
        for _, result in ipairs(validationResults) do
            if string.find(result, '✅') then
                passedChecks = passedChecks + 1
            end
        end
        
        lib.notify({
            title = locale('cl_animals_title_118'),
            description = locale('cl_animals_description_119'):format(passedChecks, #validationResults),
            type = passedChecks == #validationResults and 'success' or 'info'
        })
    end)
end, false)
end

---------------------------------------------
-- Cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    SpawnManager:ClearAll()
    transportingAnimals = {}
    followStates = {}
end)

-- Cleanup on resource start to remove orphaned entities
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- Wait a bit for other resources to load
    CreateThread(function()
        Wait(3000)
        
        -- Only cleanup if player is loaded
        if cache.ped and DoesEntityExist(cache.ped) then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Resource restarted - cleaning up orphaned entities')
            end
            
            -- Initialize SpawnManager if not already done
            if not SpawnManager.entities then
                SpawnManager.entities = {}
                SpawnManager.pending = {}
            end
            
            -- Clean up orphaned entities
            SpawnManager:CleanupOrphanedEntities()
        end
    end)
end)

---------------------------------------------
-- Initialize on resource start
---------------------------------------------
CreateThread(function()
    Wait(1000)
    if cache.ped and DoesEntityExist(cache.ped) then
        SpawnManager:Initialize()
    end
end)
