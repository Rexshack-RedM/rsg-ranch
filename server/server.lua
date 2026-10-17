local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

-- rsg-multijob integration (exports: AddJob / RemoveJob / GetJobs).
-- AddJob enforces rsg-multijob's own Config.MaxJobs and returns false, 'max_jobs'
-- when the player is full, so no limit is duplicated here.
local function MultijobAddJob(citizenid, job, grade)
    local ok, success, reason = pcall(function() return exports['rsg-multijob']:AddJob(citizenid, job, grade) end)
    if not ok then
        if Config.Debug then print('^1[RANCH MULTIJOB]^7 AddJob failed: ' .. tostring(success)) end
        return true -- don't block ranch actions if multijob is missing/broken
    end
    return success, reason
end

local function MultijobRemoveJob(citizenid, job)
    local ok, res = pcall(function() return exports['rsg-multijob']:RemoveJob(citizenid, job) end)
    return ok and res
end

-- Tracks consecutive ProcessAnimalSurvival cron failures (see cron job further down)
local cronFailures = 0

---------------------------------------------
-- database auto-install: run installation/rsg-ranch.sql's CREATE TABLE
-- statements on resource start so nobody has to import the .sql file by
-- hand. Uses "IF NOT EXISTS" so this is safe to run every start.
---------------------------------------------
local function InstallDatabaseTables()
    local sql = LoadResourceFile(GetCurrentResourceName(), 'installation/rsg-ranch.sql')
    if not sql then
        print('^1[RANCH DATABASE]^7 Could not read installation/rsg-ranch.sql - skipping auto-install. Import it manually instead.')
        return
    end

    local installed, failed = 0, 0

    for statement in sql:gmatch('([^;]+);') do
        -- strip line comments, then trim whitespace, so comment-only chunks
        -- (like the haybale migration note) and blank lines are skipped
        local trimmed = statement:gsub('%-%-[^\n]*', ''):gsub('^%s+', ''):gsub('%s+$', '')

        if trimmed ~= '' and trimmed:upper():find('CREATE TABLE') then
            local ok, err = pcall(function()
                MySQL.query.await(trimmed)
            end)

            if ok then
                installed = installed + 1
            else
                failed = failed + 1
                print(('^1[RANCH DATABASE]^7 Failed to run a CREATE TABLE statement: %s'):format(tostring(err)))
            end
        end
    end

    if failed > 0 then
        print('^1[RANCH DATABASE]^7 One or more tables could not be verified/created automatically. You may need to import installation/rsg-ranch.sql manually.')
    elseif Config.Debug then
        print(('^2[RANCH DATABASE]^7 Verified %d rsg-ranch table(s) exist (created if missing).'):format(installed))
    end
end

---------------------------------------------
-- ranch ownership cache: RanchOwners[ranchid] = citizenid (or nil if unowned)
---------------------------------------------
local RanchOwners = {}

-- forward-declared: real definition lives with the rest of the ranch
-- storage system further down this file, but needs to run once at startup
-- from the CreateThread block below
local EnsureAllGeneralStorages

---------------------------------------------
-- per-player in-flight lock for buyAnimal - prevents a player firing the
-- purchase event multiple times before the first request finishes and stops
-- the client-supplied "price" resolution racing the actual money deduction
-- (a spam-fired buyAnimal could otherwise buy several animals off a single
-- balance check before the first RemoveMoney call ever lands)
---------------------------------------------
local BuyAnimalLocks = {}

---------------------------------------------
-- generic in-flight lock: runs fn() only if nothing else currently holds
-- `key`. Used to stop spam-fired / simultaneous events racing each other
-- across awaited DB queries (double-collect, double-refund, etc).
-- Returns false if the lock was already held. Global so the other server
-- files in this resource (orders.lua) can share it.
---------------------------------------------
local ActionLocks = {}

function RanchWithLock(key, fn)
    if ActionLocks[key] then return false end
    ActionLocks[key] = true
    local ok, err = pcall(fn)
    ActionLocks[key] = nil
    if not ok then
        print(('^1[RSG-RANCH]^7 Error while handling %s: %s'):format(tostring(key), tostring(err)))
    end
    return true
end

---------------------------------------------
-- send the full animal list to one client (or -1 for everyone).
-- The server previously called TriggerEvent('rsg-ranch:server:refreshAnimals')
-- to "refresh all clients", but a server-side TriggerEvent has no player
-- source, so those refreshes never reached anyone. Global so exports.lua
-- can use it too.
---------------------------------------------
function RanchBroadcastAnimals(target)
    MySQL.query('SELECT * FROM `rsg_ranch_animals`', {}, function(animals)
        TriggerClientEvent('rsg-ranch:client:spawnAnimals', target or -1, animals or {}, true)
    end)
end

-- per-player cooldown on the client-triggered full refresh (it SELECTs the
-- whole animal table, so it must not be spammable)
local RefreshCooldowns = {}
local REFRESH_COOLDOWN_MS = 5000

-- true if this player fired `kind` too recently; otherwise records now and returns false
local function RefreshOnCooldown(src, kind)
    local now = GetGameTimer()
    local perPlayer = RefreshCooldowns[src]
    if not perPlayer then
        perPlayer = {}
        RefreshCooldowns[src] = perPlayer
    end
    if perPlayer[kind] and (now - perPlayer[kind]) < REFRESH_COOLDOWN_MS then return true end
    perPlayer[kind] = now
    return false
end

local function LoadRanchOwners()
    local rows = MySQL.query.await('SELECT ranchid, citizenid FROM rsg_ranch_owners', {})
    if rows then
        for _, row in ipairs(rows) do
            RanchOwners[row.ranchid] = row.citizenid
        end
    end

    -- Bridge legacy setups where an admin manually assigned a boss (grade 2)
    -- before this ownership system existed - treat that as "already owned"
    -- so the ranch can't be re-purchased out from under them.
    for _, ranchData in pairs(Config.RanchLocations) do
        if not RanchOwners[ranchData.ranchid] then
            local bossResult = MySQL.query.await('SELECT citizenid FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ? AND JSON_EXTRACT(job, "$.grade.level") = ? LIMIT 1', {ranchData.ranchid, Config.RanchBossGrade})
            if bossResult and bossResult[1] then
                RanchOwners[ranchData.ranchid] = bossResult[1].citizenid
                MySQL.insert('INSERT INTO rsg_ranch_owners (ranchid, citizenid, purchased_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE citizenid = VALUES(citizenid)', {ranchData.ranchid, bossResult[1].citizenid, 0})
                if Config.Debug then
                    print('^3[RANCH OWNERSHIP]^7 Migrated existing boss ' .. bossResult[1].citizenid .. ' as owner of ' .. ranchData.ranchid)
                end
            end
        end
    end
end

CreateThread(function()
    InstallDatabaseTables()
    LoadRanchOwners()
    EnsureAllGeneralStorages()
end)

---------------------------------------------
-- helper function to check if player is ranch staff
---------------------------------------------
local function isPlayerRanchStaff(Player)
    if not Player or not Player.PlayerData.job then
        return false
    end
    
    local playerjob = Player.PlayerData.job.name
    
    -- Check if player's job matches any ranch job access
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return true
        end
    end
    
    return false
end

---------------------------------------------
-- per-grade permission (Config.StaffManagement.Permissions), enforced server-side.
-- Previously only the client read these, so a trainee could fire the events directly.
---------------------------------------------
local function RanchCan(Player, permission)
    local grade = Player.PlayerData.job.grade.level or 0
    local perms = Config.StaffManagement.Permissions[grade]
    if not perms then
        -- grades above the configured table (e.g. a custom boss grade) inherit the highest defined set
        local best
        for g, p in pairs(Config.StaffManagement.Permissions) do
            if g <= grade and (not best or g > best) then best = g end
        end
        perms = best and Config.StaffManagement.Permissions[best]
    end
    return perms ~= nil and perms[permission] == true
end

local function DenyPermission(src)
    TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_no_grade_permission')})
end

---------------------------------------------
-- Fire every member of staff at a ranch (used when a ranch is sold outright
-- and closes for business). Handles online and offline employees, and
-- cleans up rsg-multijob for each. Pass exceptCitizenid to skip one player
-- (e.g. keep a new owner employed during a transfer-style operation).
---------------------------------------------
local function FireAllRanchStaff(ranchid, exceptCitizenid)
    local processedCitizenIds = {}

    -- Online players first
    for _, playerId in ipairs(RSGCore.Functions.GetPlayers()) do
        local targetPlayer = RSGCore.Functions.GetPlayer(playerId)
        if targetPlayer and targetPlayer.PlayerData.job.name == ranchid and targetPlayer.PlayerData.citizenid ~= exceptCitizenid then
            targetPlayer.Functions.SetJob('unemployed', 0)
            MultijobRemoveJob(targetPlayer.PlayerData.citizenid, ranchid)
            TriggerClientEvent('ox_lib:notify', playerId, {type = 'error', description = locale('sv_server_description_1')})
            processedCitizenIds[targetPlayer.PlayerData.citizenid] = true
        end
    end

    -- Then anyone offline who still has this ranch's job in the database
    local offlineRows = MySQL.query.await('SELECT citizenid FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', {ranchid})
    if offlineRows then
        for _, row in ipairs(offlineRows) do
            if row.citizenid ~= exceptCitizenid and not processedCitizenIds[row.citizenid] then
                MySQL.update('UPDATE players SET job = JSON_SET(JSON_SET(job, "$.name", "unemployed"), "$.grade", JSON_OBJECT("level", 0, "name", "Unemployed")) WHERE citizenid = ?', {row.citizenid})
                MultijobRemoveJob(row.citizenid, ranchid)
            end
        end
    end
end

---------------------------------------------
-- Authoritative sale price calculation (server-side only).
-- Never trust a client-supplied sale price - always recompute from Config + DB data.
---------------------------------------------
local function CalculateAnimalSalePrice(model, age)
    local baseSellPrice = Config.BaseSellPrices[model] or 100
    local ageMultiplier = 1.0
    local ageCategory = locale('sv_age_adult')

    if age < Config.PrimeAgeStart then
        ageMultiplier = Config.AgePricing.young
        ageCategory = locale('sv_age_young')
    elseif age >= Config.PrimeAgeStart and age <= Config.PrimeAgeEnd then
        ageMultiplier = Config.AgePricing.prime
        ageCategory = locale('sv_age_prime')
    elseif age > Config.PrimeAgeEnd and age < Config.OldAgeStart then
        ageMultiplier = Config.AgePricing.adult
        ageCategory = locale('sv_age_adult')
    elseif age >= Config.OldAgeStart then
        ageMultiplier = Config.AgePricing.old
        ageCategory = locale('sv_age_old')
    end

    return math.floor(baseSellPrice * ageMultiplier), ageCategory
end

---------------------------------------------
-- Authoritative buy price calculation (server-side only).
---------------------------------------------
local function CalculateAnimalBuyPrice(model)
    if model == 'a_c_bull_01' then
        return Config.BullBuyPrice
    elseif model == 'a_c_cow' then
        return Config.CowBuyPrice
    elseif model == 'a_c_pig_01' then
        return Config.PigBuyPrice
    elseif model == 'a_c_sheep_01' then
        return Config.SheepBuyPrice
    end
    return nil
end

---------------------------------------------
-- Are two animal models the same species? Used by breeding so a bull can't
-- pair up with a pig just because the genders happen to be opposite.
---------------------------------------------
local function IsSameSpecies(modelA, modelB)
    if not Config.AnimalSpecies then return modelA == modelB end
    local speciesA = Config.AnimalSpecies[modelA]
    local speciesB = Config.AnimalSpecies[modelB]
    if not speciesA or not speciesB then return modelA == modelB end
    return speciesA == speciesB
end

---------------------------------------------
-- Shared display label for an animal model (server-side)
---------------------------------------------
local AnimalLabelKeys = {
    ['a_c_bull_01'] = 'sv_animal_bull',
    ['a_c_cow'] = 'sv_animal_cow',
    ['a_c_pig_01'] = 'sv_animal_pig',
    ['a_c_sheep_01'] = 'sv_animal_sheep'
}

local function AnimalLabelForModel(model)
    return locale(AnimalLabelKeys[model] or 'sv_animal_generic')
end

---------------------------------------------
-- Finds the closest configured sale point to a set of coords, within maxDistance.
-- Used so we never trust client-supplied sale point coordinates.
---------------------------------------------
local function FindNearestSalePoint(coords, maxDistance)
    local closest, closestDist = nil, nil
    for _, point in ipairs(Config.SalePointLocations) do
        local dist = #(coords - point.coords)
        if dist <= maxDistance and (not closestDist or dist < closestDist) then
            closest, closestDist = point, dist
        end
    end
    return closest, closestDist
end

---------------------------------------------
-- Finds the closest configured buy point to a set of coords, within maxDistance.
---------------------------------------------
local function FindNearestBuyPoint(coords, maxDistance)
    local closest, closestDist = nil, nil
    for _, point in ipairs(Config.BuyPointLocations) do
        local dist = #(coords - point.coords)
        if dist <= maxDistance and (not closestDist or dist < closestDist) then
            closest, closestDist = point, dist
        end
    end
    return closest, closestDist
end

---------------------------------------------
-- Finds a ranch's configured data by its ranchid.
---------------------------------------------
local function GetRanchLocationData(ranchid)
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.ranchid == ranchid then
            return ranchData
        end
    end
    return nil
end

---------------------------------------------
-- Is the player standing near their ranch NPC? Every ranch-menu action is
-- re-checked with this so it can't be fired remotely from anywhere on the map
-- (remote stash access, selling/slaughtering livestock, staff changes...).
---------------------------------------------
local function IsNearRanch(src, ranchid)
    local ranchData = GetRanchLocationData(ranchid)
    if not ranchData then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local npc = ranchData.npccoords
    return #(GetEntityCoords(ped) - vector3(npc.x, npc.y, npc.z)) <= (Config.RanchMenuDistance or 15.0)
end

local function NotifyNotNearRanch(src)
    TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_not_near_ranch')})
end

---------------------------------------------
-- Ask a player to accept something (job offer / ranch transfer) and wait for
-- their answer. Returns true only on an explicit accept within the timeout.
---------------------------------------------
local function RequestConsent(targetId, header, content)
    local timeout = Config.RanchConsentTimeout or 20
    local p, settled = promise.new(), false
    local function settle(value)
        if settled then return end
        settled = true
        p:resolve(value)
    end
    lib.callback('rsg-ranch:client:requestConsent', targetId, function(accepted)
        settle(accepted == true)
    end, header, content, timeout)
    -- resolve as declined if the target never answers (closed game, disconnected...)
    SetTimeout((timeout + 2) * 1000, function() settle(false) end)
    return Citizen.Await(p)
end

---------------------------------------------
-- Spawn Management System
---------------------------------------------
local SpawnController = {
    activeSpawns = {},      -- [animalId] = {players, spawnTime, networkId, pos}
    config = {
        maxSpawnsPerPlayer = 10,    -- Max animals a single player can have spawned
        cleanupInterval = 60000,    -- Cleanup interval (1 minute)
        broadcastRadius = 150.0     -- Radius to broadcast spawns to nearby players
    }
}

---------------------------------------------
-- Helper function to get nearby players
---------------------------------------------
local function GetNearbyPlayers(coords, radius)
    local nearbyPlayers = {}
    local players = GetPlayers()
    
    for _, playerId in ipairs(players) do
        local ped = GetPlayerPed(tonumber(playerId))
        if DoesEntityExist(ped) then
            local playerCoords = GetEntityCoords(ped)
            local distance = #(playerCoords - coords)
            if distance <= radius then
                table.insert(nearbyPlayers, tonumber(playerId))
            end
        end
    end
    
    return nearbyPlayers
end

---------------------------------------------
-- Initialize spawn controller
---------------------------------------------
function SpawnController:Initialize()
    -- Start cleanup thread
    CreateThread(function()
        while true do
            self:CleanupStaleData()
            Wait(self.config.cleanupInterval)
        end
    end)
    
    if Config.Debug then
        print('^2[SPAWN CONTROLLER]^7 Initialized new server spawn management')
    end
end

---------------------------------------------
-- Check if a player can spawn an animal
---------------------------------------------
function SpawnController:CanPlayerSpawn(playerId, animalId)
    -- Check if animal is already spawned
    if self.activeSpawns[animalId] then
        local spawnData = self.activeSpawns[animalId]
        
        -- First check if this data structure is valid
        if not spawnData.players then
            -- Invalid structure, clear it
            if Config.Debug then
                print('^3[SPAWN CONTROLLER]^7 Clearing invalid spawn data for animal ' .. animalId)
            end
            self.activeSpawns[animalId] = nil
        else
            -- Check if any of the players who have spawned this animal are still online AND nearby
            local anyPlayerNearby = false
            local playersToRemove = {}
            
            for spawnedByPlayerId, _ in pairs(spawnData.players) do
                local player = RSGCore.Functions.GetPlayer(spawnedByPlayerId)
                local isPlayerValid = false
                
                if player then
                    -- Player is online, check if they're still nearby
                    local ped = GetPlayerPed(spawnedByPlayerId)
                    if DoesEntityExist(ped) then
                        local playerCoords = GetEntityCoords(ped)
                        local animalCoords = vector3(spawnData.pos_x or 0, spawnData.pos_y or 0, spawnData.pos_z or 0)
                        local distance = #(playerCoords - animalCoords)
                        
                        -- Player is nearby if within 100m
                        if distance <= 100.0 then
                            anyPlayerNearby = true
                            isPlayerValid = true
                        end
                    end
                end
                
                -- Mark for removal if player is not valid
                if not isPlayerValid then
                    table.insert(playersToRemove, spawnedByPlayerId)
                end
            end
            
            -- Remove invalid players
            for _, removeId in ipairs(playersToRemove) do
                spawnData.players[removeId] = nil
                if Config.Debug then
                    print('^3[SPAWN CONTROLLER]^7 Removed player ' .. removeId .. ' from animal ' .. animalId .. ' spawn (out of range or offline)')
                end
            end
            
            -- If no players are nearby anymore, clear the spawn completely
            if not anyPlayerNearby then
                if Config.Debug then
                    print('^3[SPAWN CONTROLLER]^7 No players nearby for animal ' .. animalId .. ', clearing spawn')
                end
                self.activeSpawns[animalId] = nil
            else
                -- Animal is already spawned by someone nearby, allow this player to join
                spawnData.players[playerId] = true
                if Config.Debug then
                    print('^2[SPAWN CONTROLLER]^7 Player ' .. playerId .. ' joined existing spawn for animal ' .. animalId)
                end
                return true, "OK"
            end
        end
    end
    
    -- At this point, either the animal wasn't spawned or we cleared it
    -- Check player spawn limit before allowing new spawn
    local playerSpawnCount = 0
    for _, spawnData in pairs(self.activeSpawns) do
        if spawnData.players and spawnData.players[playerId] then
            playerSpawnCount = playerSpawnCount + 1
        end
    end
    
    if playerSpawnCount >= self.config.maxSpawnsPerPlayer then
        return false, "Too many animals spawned"
    end
    
    if Config.Debug then
        print('^2[SPAWN CONTROLLER]^7 Allowing new spawn for animal ' .. animalId .. ' by player ' .. playerId)
    end
    
    return true, "OK"
end

---------------------------------------------
-- Register an animal spawn
---------------------------------------------
function SpawnController:RegisterSpawn(playerId, animalId, animalData, networkId)
    if not self.activeSpawns[animalId] then
        self.activeSpawns[animalId] = {
            players = {},
            spawnTime = os.time(),
            pos_x = animalData.pos_x,
            pos_y = animalData.pos_y,
            pos_z = animalData.pos_z,
            model = animalData.model,
            networkId = networkId or nil
        }
    end
    
    -- Add this player to the list of players who have spawned this animal
    self.activeSpawns[animalId].players[playerId] = true
    
    -- Update network ID if provided
    if networkId then
        self.activeSpawns[animalId].networkId = networkId
    end
    
    if Config.Debug then
        local playerCount = 0
        for _ in pairs(self.activeSpawns[animalId].players) do
            playerCount = playerCount + 1
        end
        print('^2[SPAWN CONTROLLER]^7 Registered spawn - Player: ' .. playerId .. ', Animal: ' .. animalId .. ' (Total players: ' .. playerCount .. ', netId: ' .. tostring(networkId or 'none') .. ')')
    end
end

---------------------------------------------
-- Cleanup stale data
---------------------------------------------
function SpawnController:CleanupStaleData()
    local cleanedCount = 0
    
    -- Clean up spawns for disconnected players
    local playersToCheck = {}
    for animalId, spawnData in pairs(self.activeSpawns) do
        if spawnData.players then
            local playersToRemove = {}
            
            -- Check each player who has spawned this animal
            for playerId, _ in pairs(spawnData.players) do
                if not playersToCheck[playerId] then
                    local player = RSGCore.Functions.GetPlayer(playerId)
                    playersToCheck[playerId] = player ~= nil
                end
                
                -- Mark disconnected players for removal
                if not playersToCheck[playerId] then
                    table.insert(playersToRemove, playerId)
                end
            end
            
            -- Remove disconnected players
            for _, playerId in ipairs(playersToRemove) do
                spawnData.players[playerId] = nil
                cleanedCount = cleanedCount + 1
            end
            
            -- If no players left, clear the entire spawn
            local hasPlayers = false
            for _ in pairs(spawnData.players) do
                hasPlayers = true
                break
            end
            
            if not hasPlayers then
                self.activeSpawns[animalId] = nil
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[SPAWN CONTROLLER]^7 Cleaned up ' .. cleanedCount .. ' stale spawn entries')
    end
end

---------------------------------------------
-- Clear all spawns for a player
---------------------------------------------
function SpawnController:ClearPlayerSpawns(playerId)
    local clearedCount = 0
    for animalId, spawnData in pairs(self.activeSpawns) do
        if spawnData.players and spawnData.players[playerId] then
            spawnData.players[playerId] = nil
            
            -- If no players left, clear the entire spawn
            local hasPlayers = false
            for _ in pairs(spawnData.players) do
                hasPlayers = true
                break
            end
            
            if not hasPlayers then
                self.activeSpawns[animalId] = nil
            end
            
            clearedCount = clearedCount + 1
        end
    end
    
    if Config.Debug and clearedCount > 0 then
        print('^3[SPAWN CONTROLLER]^7 Cleared ' .. clearedCount .. ' spawns for disconnected player ' .. playerId)
    end
end

---------------------------------------------
-- Initialize the spawn controller
---------------------------------------------
SpawnController:Initialize()

---------------------------------------------
-- ranch storage (multi-storage system)
---------------------------------------------
-- The 'general' storage is free and created automatically when a ranch is
-- purchased (see purchaseRanch below, and EnsureGeneralStorages() for
-- ranches that were already owned before this system existed). Its stash
-- name is kept as the bare ranchid for backwards compatibility with any
-- existing rsg-inventory data. Additional storages purchased afterwards get
-- a generated storageid of '<ranchid>_storage_<n>'.
local function GetRanchStorages(ranchid)
    local rows = MySQL.query.await('SELECT storageid, size, label, maxweight, slots, min_grade FROM rsg_ranch_storages WHERE ranchid = ? ORDER BY id ASC', { ranchid })
    return rows or {}
end

local function EnsureGeneralStorage(ranchid)
    local existing = MySQL.query.await('SELECT storageid FROM rsg_ranch_storages WHERE ranchid = ? AND size = ?', { ranchid, 'general' })
    if existing and existing[1] then return end

    MySQL.insert.await('INSERT INTO rsg_ranch_storages (storageid, ranchid, size, label, maxweight, slots, min_grade, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
        ranchid,
        ranchid,
        'general',
        locale('sv_general_storage'),
        Config.RanchStorageMaxWeight,
        Config.RanchStorageMaxSlots,
        Config.StorageMinJobGrade,
        os.time()
    })
end

-- Backfill: any ranch that already has an owner but predates this system
-- (or is missing its row for any other reason) gets its free general
-- storage created on resource start.
EnsureAllGeneralStorages = function()
    for ranchid, citizenid in pairs(RanchOwners) do
        if citizenid then
            EnsureGeneralStorage(ranchid)
        end
    end
end

local function GenerateStorageId(ranchid)
    local countResult = MySQL.query.await('SELECT COUNT(*) as count FROM rsg_ranch_storages WHERE ranchid = ?', { ranchid })
    local n = (countResult and countResult[1] and countResult[1].count or 0) + 1
    local storageid = ranchid .. '_storage_' .. n

    -- Guard against a stale/duplicate id (e.g. a previously deleted storage)
    while true do
        local clash = MySQL.query.await('SELECT storageid FROM rsg_ranch_storages WHERE storageid = ?', { storageid })
        if not clash or not clash[1] then break end
        n = n + 1
        storageid = ranchid .. '_storage_' .. n
    end

    return storageid
end

RSGCore.Functions.CreateCallback('rsg-ranch:server:getranchstorages', function(source, cb, ranchid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or type(ranchid) ~= 'string' then cb({}) return end
    if Player.PlayerData.job.name ~= ranchid then cb({}) return end
    if Player.PlayerData.job.grade.level < Config.StorageMinJobGrade then cb({}) return end

    cb(GetRanchStorages(ranchid))
end)

RegisterNetEvent('rsg-ranch:server:openranchstorage', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(data) ~= 'table' or type(data.ranchid) ~= 'string' or type(data.storageid) ~= 'string' then return end

    local playerjob = Player.PlayerData.job.name
    local playerjobgrade = Player.PlayerData.job.grade.level
    if playerjob ~= data.ranchid then return end
    if playerjobgrade < Config.StorageMinJobGrade then return end
    if not IsNearRanch(src, data.ranchid) then return NotifyNotNearRanch(src) end

    -- Confirm the storage actually belongs to this ranch before opening it
    local storage = MySQL.query.await('SELECT storageid, label, maxweight, slots, min_grade FROM rsg_ranch_storages WHERE storageid = ? AND ranchid = ?', { data.storageid, data.ranchid })
    if not storage or not storage[1] then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_2')})
        return
    end

    local row = storage[1]

    -- Per-storage access restriction set by the boss (defaults to
    -- Config.StorageMinJobGrade, already checked above for storage access
    -- in general)
    if playerjobgrade < row.min_grade then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_3')})
        return
    end

    local stashdata = { label = row.label, maxweight = row.maxweight, slots = row.slots }
    exports['rsg-inventory']:OpenInventory(src, row.storageid, stashdata)
end)

local function HandlePurchaseRanchStorage(src, data)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(data) ~= 'table' or type(data.ranchid) ~= 'string' or type(data.size) ~= 'string' then return end

    local ranchid = data.ranchid

    -- Must be the boss of this ranch to buy more storage
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.RanchBossGrade then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_4')})
        return
    end

    if RanchOwners[ranchid] ~= Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_5')})
        return
    end

    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    local sizeConfig = Config.RanchStorageSizes and Config.RanchStorageSizes[data.size]
    if not sizeConfig then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_6')})
        return
    end

    if Config.MaxAdditionalStorages and Config.MaxAdditionalStorages > 0 then
        local countResult = MySQL.query.await('SELECT COUNT(*) as count FROM rsg_ranch_storages WHERE ranchid = ? AND size != ?', { ranchid, 'general' })
        local additionalCount = countResult and countResult[1] and countResult[1].count or 0
        if additionalCount >= Config.MaxAdditionalStorages then
            TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_7')})
            return
        end
    end

    local price = sizeConfig.price
    local playerMoney = Player.PlayerData.money.cash
    if playerMoney < price then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_8'):format(price, playerMoney)})
        return
    end

    local storageid = GenerateStorageId(ranchid)

    -- Deduct money now, atomically, and check it actually succeeded before granting
    -- the storage - the balance check above can go stale across the awaited
    -- queries below, so this is the real point of no return.
    local moneyRemoved = Player.Functions.RemoveMoney('cash', price, 'rsg-ranch-storage')
    if not moneyRemoved then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_9'):format(price, Player.PlayerData.money.cash)})
        return
    end

    local success, dbError = pcall(function()
        return MySQL.insert.await('INSERT INTO rsg_ranch_storages (storageid, ranchid, size, label, maxweight, slots, min_grade, purchased_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            storageid,
            ranchid,
            data.size,
            sizeConfig.label,
            sizeConfig.maxweight,
            sizeConfig.slots,
            Config.StorageMinJobGrade,
            Player.PlayerData.citizenid,
            os.time()
        })
    end)

    if not success then
        -- The database insert failed after money was already taken - refund it
        Player.Functions.AddMoney('cash', price, 'rsg-ranch-storage-refund')
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_10')})
        if Config.Debug then
            print('^1[RANCH STORAGE PURCHASE ERROR]^7 Database insert failed: ' .. tostring(dbError))
        end
        return
    end

    TriggerClientEvent('ox_lib:notify', src, { type = 'success', description = locale('sv_server_description_11'):format(sizeConfig.label, price)})
end

RegisterNetEvent('rsg-ranch:server:purchaseranchstorage', function(data)
    local src = source
    if not RanchWithLock('storagebuy:' .. tostring(src), function() HandlePurchaseRanchStorage(src, data) end) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
    end
end)

RegisterNetEvent('rsg-ranch:server:renameranchstorage', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(data) ~= 'table' or type(data.ranchid) ~= 'string' or type(data.storageid) ~= 'string' or type(data.label) ~= 'string' then return end

    local ranchid = data.ranchid

    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.RanchBossGrade then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_12')})
        return
    end

    if RanchOwners[ranchid] ~= Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_13')})
        return
    end

    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    local label = data.label:gsub('^%s+', ''):gsub('%s+$', '')
    if label == '' or #label > 50 then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_14')})
        return
    end

    local storage = MySQL.query.await('SELECT storageid, size FROM rsg_ranch_storages WHERE storageid = ? AND ranchid = ?', { data.storageid, ranchid })
    if not storage or not storage[1] then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_15')})
        return
    end

    MySQL.update.await('UPDATE rsg_ranch_storages SET label = ? WHERE storageid = ? AND ranchid = ?', { label, data.storageid, ranchid })

    TriggerClientEvent('ox_lib:notify', src, { type = 'success', description = locale('sv_server_description_16'):format(label)})
end)

---------------------------------------------
-- restrict a purchased storage's access to a minimum job grade, set by the
-- boss (e.g. lock it to managers only, or open it back up to everyone)
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:setstorageaccess', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(data) ~= 'table' or type(data.ranchid) ~= 'string' or type(data.storageid) ~= 'string' or type(data.mingrade) ~= 'number' then return end

    local ranchid = data.ranchid

    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.RanchBossGrade then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_17')})
        return
    end

    if RanchOwners[ranchid] ~= Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_18')})
        return
    end

    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    -- Only allow one of the configured access levels - never trust a
    -- client-supplied grade outright
    local validLevel = nil
    for _, level in ipairs(Config.RanchStorageAccessLevels or {}) do
        if level.grade == data.mingrade then
            validLevel = level
            break
        end
    end

    if not validLevel then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_19')})
        return
    end

    local storage = MySQL.query.await('SELECT storageid, size FROM rsg_ranch_storages WHERE storageid = ? AND ranchid = ?', { data.storageid, ranchid })
    if not storage or not storage[1] then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_20')})
        return
    end

    if storage[1].size == 'general' then
        TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_server_description_21')})
        return
    end

    MySQL.update.await('UPDATE rsg_ranch_storages SET min_grade = ? WHERE storageid = ? AND ranchid = ?', { validLevel.grade, data.storageid, ranchid })

    TriggerClientEvent('ox_lib:notify', src, { type = 'success', description = locale('sv_server_description_22'):format(validLevel.label)})
end)

---------------------------------------------
-- get gender-specific breeding cooldown
---------------------------------------------
local function GetBreedingCooldown(gender)
    if Config.GenderSpecificCooldowns and Config.GenderSpecificCooldowns[gender] then
        return Config.GenderSpecificCooldowns[gender]
    end
    
    -- Fallback to default cooldown
    return Config.BreedingCooldown or 172800
end

---------------------------------------------
-- select offspring model based on breeding config probabilities
---------------------------------------------
local function SelectOffspringModel(parentModel)
    local breedingConfig = Config.BreedingConfig[parentModel]
    if not breedingConfig or not breedingConfig.offspringModels then
        -- Fallback: return same model as parent
        return parentModel
    end
    
    local offspringModels = breedingConfig.offspringModels
    if #offspringModels == 0 then
        return parentModel
    end
    
    -- Calculate total chance for normalization
    local totalChance = 0
    for _, offspring in ipairs(offspringModels) do
        totalChance = totalChance + offspring.chance
    end
    
    if totalChance == 0 then
        return parentModel
    end
    
    -- Generate random number and select model
    local randomValue = math.random() * totalChance
    local currentChance = 0
    
    for _, offspring in ipairs(offspringModels) do
        currentChance = currentChance + offspring.chance
        if randomValue <= currentChance then
            if Config.Debug then
                print('^3[BREEDING DEBUG]^7 Selected offspring model: ' .. offspring.model .. ' (chance: ' .. offspring.chance .. '/' .. totalChance .. ')')
            end
            return offspring.model
        end
    end
    
    -- Fallback: return the first model
    if Config.Debug then
        print('^1[BREEDING ERROR]^7 Failed to select offspring model, using first option: ' .. offspringModels[1].model)
    end
    return offspringModels[1].model
end

---------------------------------------------
-- create unique animalid
---------------------------------------------
local function CreateAnimalId()
    local UniqueFound = false
    local animalid = nil
    local maxAttempts = 50 -- Reduced attempts for better performance
    local attempts = 0
    
    while not UniqueFound and attempts < maxAttempts do
        attempts = attempts + 1
        animalid = math.random(Config.ANIMAL_ID_MIN, Config.ANIMAL_ID_MAX)
        
        local success, result = pcall(function()
            return MySQL.query.await("SELECT COUNT(*) as count FROM rsg_ranch_animals WHERE animalid = ?", { animalid })
        end)
        
        if success and result and result[1] and result[1].count == 0 then
            UniqueFound = true
        elseif not success then
            if Config.Debug then
                print("^1[ERROR]^7 Database error in CreateAnimalId: " .. tostring(result))
            end
            break
        end
    end
    
    if not UniqueFound then
        -- Better fallback: use timestamp + server ID + random for uniqueness
        local serverTime = os.time()
        local randomSuffix = math.random(Config.FALLBACK_ID_SUFFIX_MIN, Config.FALLBACK_ID_SUFFIX_MAX)
        animalid = tostring(serverTime) .. tostring(randomSuffix)
        -- Ensure it's not too long by taking last N characters
        if string.len(animalid) > Config.MAX_ID_LENGTH then
            animalid = string.sub(animalid, -Config.MAX_ID_LENGTH)
        end
        if Config.Debug then
            print("^3[WARNING]^7 Used fallback animal ID generation: " .. animalid)
        end
    end
    
    return tonumber(animalid) -- Ensure consistent numeric ID
end

exports('CreateAnimalId', CreateAnimalId)

---------------------------------------------
-- create unique feedtroughid
---------------------------------------------
local function CreateFeedTroughId()
    local UniqueFound = false
    local feedtroughid = nil
    local maxAttempts = 50
    local attempts = 0

    while not UniqueFound and attempts < maxAttempts do
        attempts = attempts + 1
        feedtroughid = math.random(Config.FEEDTROUGH_ID_MIN, Config.FEEDTROUGH_ID_MAX)

        local success, result = pcall(function()
            return MySQL.query.await("SELECT COUNT(*) as count FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?", { feedtroughid })
        end)

        if success and result and result[1] and result[1].count == 0 then
            UniqueFound = true
        elseif not success then
            if Config.Debug then
                print("^1[ERROR]^7 Database error in CreateFeedTroughId: " .. tostring(result))
            end
            break
        end
    end

    if not UniqueFound then
        local serverTime = os.time()
        local randomSuffix = math.random(1000, 9999)
        feedtroughid = tostring(serverTime) .. tostring(randomSuffix)
        if string.len(feedtroughid) > Config.MAX_ID_LENGTH then
            feedtroughid = string.sub(feedtroughid, -Config.MAX_ID_LENGTH)
        end
    end

    return tonumber(feedtroughid)
end

---------------------------------------------
-- Feed Trough System
---------------------------------------------

-- Register feedtrough as a useable item, starts client-side placement preview
RSGCore.Functions.CreateUseableItem(Config.FeedTroughItem, function(source, item)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_23')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:startFeedTroughPlacement', src)
end)

-- Confirm placement from client and persist to database
RegisterNetEvent('rsg-ranch:server:placeFeedTrough', function(pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_24')})
        return
    end

    if not pos_x or not pos_y or not pos_z then return end

    -- Never trust client-supplied coords - the player must actually be near where they claim to place it
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - vector3(pos_x, pos_y, pos_z)) > Config.PropPlacementMaxDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_25')})
        return
    end

    -- Re-check the item is still present (placement preview takes a moment client-side)
    local hasItem = Player.Functions.GetItemByName(Config.FeedTroughItem)
    if not hasItem or hasItem.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_26')})
        return
    end

    local ranchid = Player.PlayerData.job.name
    local feedtroughid = CreateFeedTroughId()
    if not feedtroughid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_27')})
        return
    end

    -- Take the item first and check it actually came off - never assume RemoveItem
    -- succeeded just because GetItemByName saw it a moment ago
    local itemRemoved = exports['rsg-inventory']:RemoveItem(src, Config.FeedTroughItem, 1, nil, 'rsg-ranch')
    if not itemRemoved then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_28')})
        return
    end

    local createdAt = os.time()
    local insertSuccess, insertResult = pcall(function()
        return MySQL.insert.await('INSERT INTO rsg_ranch_feedtroughs (feedtroughid, ranchid, pos_x, pos_y, pos_z, pos_w, uses, placed_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            feedtroughid, ranchid, pos_x, pos_y, pos_z, pos_w or 0.0, Config.FeedTroughUses, Player.PlayerData.citizenid, createdAt
        })
    end)

    if not insertSuccess or not insertResult then
        -- Insert failed after the item was already taken - give it back
        exports['rsg-inventory']:AddItem(src, Config.FeedTroughItem, 1, nil, nil, 'rsg-ranch')
        if Config.Debug then
            print('^1[ERROR]^7 Failed to insert feed trough: ' .. tostring(insertResult))
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_29')})
        return
    end

    if RSGCore.Shared.Items[Config.FeedTroughItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.FeedTroughItem], 'remove', 1)
    end

    local feedtroughData = {
        feedtroughid = feedtroughid,
        ranchid = ranchid,
        pos_x = pos_x,
        pos_y = pos_y,
        pos_z = pos_z,
        pos_w = pos_w or 0.0,
        uses = Config.FeedTroughUses
    }

    -- Broadcast to everyone so nearby clients (and animal AI) can see it immediately
    TriggerClientEvent('rsg-ranch:client:spawnFeedTrough', -1, feedtroughData)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_30')})

    if Config.Debug then
        print('^2[FEEDTROUGH]^7 Player ' .. src .. ' placed feed trough ' .. feedtroughid .. ' at ranch ' .. ranchid)
    end
end)

-- Send current feed troughs to a (re)connecting/refreshing client
RegisterNetEvent('rsg-ranch:server:refreshFeedTroughs', function()
    local src = source
    if RefreshOnCooldown(src, 'feed') then return end
    local success, error = pcall(function()
        MySQL.query('SELECT feedtroughid, ranchid, pos_x, pos_y, pos_z, pos_w, uses FROM rsg_ranch_feedtroughs', {}, function(feedtroughs, err)
            if err then
                print('^1[ERROR]^7 Database query failed in refreshFeedTroughs: ' .. tostring(err))
                return
            end

            TriggerClientEvent('rsg-ranch:client:spawnFeedTroughs', src, feedtroughs or {})
        end)
    end)

    if not success then
        if Config.Debug then
            print('^1[ERROR]^7 Critical error in refreshFeedTroughs: ' .. tostring(error))
        end
    end
end)

-- Refill a feed trough using a feed bag
RegisterNetEvent('rsg-ranch:server:refillFeedTrough', function(feedtroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_31')})
        return
    end

    if not feedtroughid then return end

    local hasItem = Player.Functions.GetItemByName(Config.FeedBagItem)
    if not hasItem or hasItem.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_32')})
        return
    end

    local feedtroughRows = MySQL.query.await('SELECT feedtroughid, ranchid, pos_x, pos_y, pos_z, uses FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?', {feedtroughid})
    if not feedtroughRows or #feedtroughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_33')})
        return
    end
    local feedtrough = feedtroughRows[1]

    if feedtrough.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_34')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local feedtroughVec = vector3(feedtrough.pos_x, feedtrough.pos_y, feedtrough.pos_z)
    if #(playerCoords - feedtroughVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_35')})
        return
    end

    if (feedtrough.uses or 0) >= Config.FeedTroughUses then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_36')})
        return
    end

    local addedUses = Config.FeedTroughRefillPerBagUse or 5
    local newUses = math.min(Config.FeedTroughUses, (feedtrough.uses or 0) + addedUses)

    -- take the feed bag first - if it's already gone, no free refill
    if not exports['rsg-inventory']:RemoveItem(src, Config.FeedBagItem, 1, nil, 'rsg-ranch') then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_32')})
        return
    end

    local updateSuccess, rowsAffected = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_feedtroughs SET uses = ? WHERE feedtroughid = ?', {newUses, feedtroughid})
    end)

    if not updateSuccess or not rowsAffected or rowsAffected <= 0 then
        exports['rsg-inventory']:AddItem(src, Config.FeedBagItem, 1, nil, nil, 'rsg-ranch')
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_37')})
        return
    end

    if RSGCore.Shared.Items[Config.FeedBagItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.FeedBagItem], 'remove', 1)
    end

    TriggerClientEvent('rsg-ranch:client:updateFeedTroughUses', -1, feedtroughid, newUses)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_38'):format(newUses, Config.FeedTroughUses)})

    if Config.Debug then
        print('^2[FEEDTROUGH]^7 Player ' .. src .. ' refilled feed trough ' .. feedtroughid .. ' to ' .. newUses .. ' uses')
    end
end)

-- Ranch staff wants to reposition an existing feed trough - validate ownership/distance,
-- then hand control to the client to run the same placement preview used when first placing one.
RegisterNetEvent('rsg-ranch:server:requestMoveFeedTrough', function(feedtroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_39')})
        return
    end

    if not feedtroughid then return end

    local feedtroughRows = MySQL.query.await('SELECT feedtroughid, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?', {feedtroughid})
    if not feedtroughRows or #feedtroughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_40')})
        return
    end
    local feedtrough = feedtroughRows[1]

    if feedtrough.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_41')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local feedtroughVec = vector3(feedtrough.pos_x, feedtrough.pos_y, feedtrough.pos_z)
    if #(playerCoords - feedtroughVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_42')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:startFeedTroughMove', src, feedtroughid)
end)

-- Confirm a feed trough's new position after the move preview
RegisterNetEvent('rsg-ranch:server:confirmMoveFeedTrough', function(feedtroughid, pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then return end
    if not feedtroughid or not pos_x or not pos_y or not pos_z then return end

    local feedtroughRows = MySQL.query.await('SELECT feedtroughid, ranchid FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?', {feedtroughid})
    if not feedtroughRows or #feedtroughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_43')})
        return
    end

    if feedtroughRows[1].ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_44')})
        return
    end

    -- Never trust client-supplied coords - the player must actually be near where they claim to move it to
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - vector3(pos_x, pos_y, pos_z)) > Config.PropPlacementMaxDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_45')})
        return
    end

    local updateSuccess, rowsAffected = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_feedtroughs SET pos_x = ?, pos_y = ?, pos_z = ?, pos_w = ? WHERE feedtroughid = ?', {
            pos_x, pos_y, pos_z, pos_w or 0.0, feedtroughid
        })
    end)

    if not updateSuccess or not rowsAffected or rowsAffected <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_46')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:moveFeedTrough', -1, feedtroughid, pos_x, pos_y, pos_z, pos_w or 0.0)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_47')})

    if Config.Debug then
        print('^2[FEEDTROUGH]^7 Player ' .. src .. ' moved feed trough ' .. feedtroughid)
    end
end)

-- Ranch staff wants to permanently remove a placed feed trough
RegisterNetEvent('rsg-ranch:server:deleteFeedTrough', function(feedtroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_48')})
        return
    end

    if not feedtroughid then return end

    local feedtroughRows = MySQL.query.await('SELECT feedtroughid, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?', {feedtroughid})
    if not feedtroughRows or #feedtroughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_49')})
        return
    end
    local feedtrough = feedtroughRows[1]

    if feedtrough.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_50')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local feedtroughVec = vector3(feedtrough.pos_x, feedtrough.pos_y, feedtrough.pos_z)
    if #(playerCoords - feedtroughVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_51')})
        return
    end

    MySQL.query.await('DELETE FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?', {feedtroughid})
    TriggerClientEvent('rsg-ranch:client:removeFeedTrough', -1, feedtroughid)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_52')})

    if Config.Debug then
        print('^2[FEEDTROUGH]^7 Player ' .. src .. ' deleted feed trough ' .. feedtroughid)
    end
end)

---------------------------------------------
-- create unique watertroughid
---------------------------------------------
local function CreateWaterTroughId()
    local UniqueFound = false
    local watertroughid = nil
    local maxAttempts = 50
    local attempts = 0

    while not UniqueFound and attempts < maxAttempts do
        attempts = attempts + 1
        watertroughid = math.random(Config.WATERTROUGH_ID_MIN, Config.WATERTROUGH_ID_MAX)

        local success, result = pcall(function()
            return MySQL.query.await("SELECT COUNT(*) as count FROM rsg_ranch_watertroughs WHERE watertroughid = ?", { watertroughid })
        end)

        if success and result and result[1] and result[1].count == 0 then
            UniqueFound = true
        elseif not success then
            if Config.Debug then
                print("^1[ERROR]^7 Database error in CreateWaterTroughId: " .. tostring(result))
            end
            break
        end
    end

    if not UniqueFound then
        local serverTime = os.time()
        local randomSuffix = math.random(1000, 9999)
        watertroughid = tostring(serverTime) .. tostring(randomSuffix)
        if string.len(watertroughid) > Config.MAX_ID_LENGTH then
            watertroughid = string.sub(watertroughid, -Config.MAX_ID_LENGTH)
        end
    end

    return tonumber(watertroughid)
end

---------------------------------------------
-- Water Trough System
---------------------------------------------

-- Register watertrough as a useable item, starts client-side placement preview
RSGCore.Functions.CreateUseableItem(Config.WaterTroughItem, function(source, item)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_53')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:startWaterTroughPlacement', src)
end)

-- Confirm placement from client and persist to database
RegisterNetEvent('rsg-ranch:server:placeWaterTrough', function(pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_54')})
        return
    end

    if not pos_x or not pos_y or not pos_z then return end

    -- Never trust client-supplied coords - the player must actually be near where they claim to place it
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - vector3(pos_x, pos_y, pos_z)) > Config.PropPlacementMaxDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_55')})
        return
    end

    -- Re-check the item is still present (placement preview takes a moment client-side)
    local hasItem = Player.Functions.GetItemByName(Config.WaterTroughItem)
    if not hasItem or hasItem.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_56')})
        return
    end

    local ranchid = Player.PlayerData.job.name
    local watertroughid = CreateWaterTroughId()
    if not watertroughid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_57')})
        return
    end

    -- Take the item first and check it actually came off
    local itemRemoved = exports['rsg-inventory']:RemoveItem(src, Config.WaterTroughItem, 1, nil, 'rsg-ranch')
    if not itemRemoved then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_58')})
        return
    end

    local createdAt = os.time()
    local insertSuccess, insertResult = pcall(function()
        return MySQL.insert.await('INSERT INTO rsg_ranch_watertroughs (watertroughid, ranchid, pos_x, pos_y, pos_z, pos_w, uses, placed_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            watertroughid, ranchid, pos_x, pos_y, pos_z, pos_w or 0.0, Config.WaterTroughUses, Player.PlayerData.citizenid, createdAt
        })
    end)

    if not insertSuccess or not insertResult then
        exports['rsg-inventory']:AddItem(src, Config.WaterTroughItem, 1, nil, nil, 'rsg-ranch')
        if Config.Debug then
            print('^1[ERROR]^7 Failed to insert water trough: ' .. tostring(insertResult))
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_59')})
        return
    end

    if RSGCore.Shared.Items[Config.WaterTroughItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.WaterTroughItem], 'remove', 1)
    end

    local watertroughData = {
        watertroughid = watertroughid,
        ranchid = ranchid,
        pos_x = pos_x,
        pos_y = pos_y,
        pos_z = pos_z,
        pos_w = pos_w or 0.0,
        uses = Config.WaterTroughUses
    }

    -- Broadcast to everyone so nearby clients (and animal AI) can see it immediately
    TriggerClientEvent('rsg-ranch:client:spawnWaterTrough', -1, watertroughData)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_60')})

    if Config.Debug then
        print('^2[WATERTROUGH]^7 Player ' .. src .. ' placed water trough ' .. watertroughid .. ' at ranch ' .. ranchid)
    end
end)

-- Send current water troughs to a (re)connecting/refreshing client
RegisterNetEvent('rsg-ranch:server:refreshWaterTroughs', function()
    local src = source
    if RefreshOnCooldown(src, 'water') then return end
    local success, error = pcall(function()
        MySQL.query('SELECT watertroughid, ranchid, pos_x, pos_y, pos_z, pos_w, uses FROM rsg_ranch_watertroughs', {}, function(watertroughs, err)
            if err then
                print('^1[ERROR]^7 Database query failed in refreshWaterTroughs: ' .. tostring(err))
                return
            end

            TriggerClientEvent('rsg-ranch:client:spawnWaterTroughs', src, watertroughs or {})
        end)
    end)

    if not success then
        if Config.Debug then
            print('^1[ERROR]^7 Critical error in refreshWaterTroughs: ' .. tostring(error))
        end
    end
end)

-- Refill a water trough using a full water bucket (fullbucket, uses stored in item metadata)
RegisterNetEvent('rsg-ranch:server:refillWaterTrough', function(watertroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_61')})
        return
    end

    if not watertroughid then return end

    local bucket = Player.Functions.GetItemByName(Config.WaterItem)
    if not bucket then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_62')})
        return
    end

    local troughRows = MySQL.query.await('SELECT watertroughid, ranchid, pos_x, pos_y, pos_z, uses FROM rsg_ranch_watertroughs WHERE watertroughid = ?', {watertroughid})
    if not troughRows or #troughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_64')})
        return
    end
    local trough = troughRows[1]

    if trough.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_65')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local troughVec = vector3(trough.pos_x, trough.pos_y, trough.pos_z)
    if #(playerCoords - troughVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_66')})
        return
    end

    if (trough.uses or 0) >= Config.WaterTroughUses then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_67')})
        return
    end

    local addedUses = Config.WaterTroughRefillPerBucketUse or 5
    local newUses = math.min(Config.WaterTroughUses, (trough.uses or 0) + addedUses)

    -- Take the bucket use FIRST and only refill if it actually came off. The old
    -- order refilled the trough and then removed the bucket without checking,
    -- so spam-firing the event with one bucket gave several free refills.
    local maxUses = Config.BucketUses or 5
    local info = bucket.info or {}
    local bucketUses = tonumber(info.uses) or maxUses
    if not exports['rsg-inventory']:RemoveItem(src, Config.WaterItem, 1, bucket.slot, 'rsg-ranch:trough-refill') then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_62')})
        return
    end

    local updateSuccess, rowsAffected = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_watertroughs SET uses = ? WHERE watertroughid = ?', {newUses, watertroughid})
    end)

    if not updateSuccess or not rowsAffected or rowsAffected <= 0 then
        -- give the bucket back exactly as it was
        exports['rsg-inventory']:AddItem(src, Config.WaterItem, 1, bucket.slot, info, 'rsg-ranch:trough-refill-refund')
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_68')})
        return
    end

    if RSGCore.Shared.Items[Config.WaterItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.WaterItem], 'remove', 1)
    end
    if bucketUses <= 1 then
        if Config.WaterReturnItem then
            exports['rsg-inventory']:AddItem(src, Config.WaterReturnItem, 1, nil, nil, 'rsg-ranch:trough-refill-empty')
            if RSGCore.Shared.Items[Config.WaterReturnItem] then
                TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.WaterReturnItem], 'add', 1)
            end
        end
    else
        local newInfo = {}
        for k, v in pairs(info) do newInfo[k] = v end
        newInfo.uses = bucketUses - 1
        newInfo.description = locale('sv_bucket_uses'):format(newInfo.uses, maxUses)
        exports['rsg-inventory']:AddItem(src, Config.WaterItem, 1, bucket.slot, newInfo, 'rsg-ranch:trough-refill-use')
    end

    TriggerClientEvent('rsg-ranch:client:updateWaterTroughUses', -1, watertroughid, newUses)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_69'):format(newUses, Config.WaterTroughUses)})

    if Config.Debug then
        print('^2[WATERTROUGH]^7 Player ' .. src .. ' refilled water trough ' .. watertroughid .. ' to ' .. newUses .. ' uses')
    end
end)

-- Ranch staff wants to reposition an existing water trough - validate ownership/distance,
-- then hand control to the client to run the same placement preview used when first placing one.
RegisterNetEvent('rsg-ranch:server:requestMoveWaterTrough', function(watertroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_70')})
        return
    end

    if not watertroughid then return end

    local troughRows = MySQL.query.await('SELECT watertroughid, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_watertroughs WHERE watertroughid = ?', {watertroughid})
    if not troughRows or #troughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_71')})
        return
    end
    local trough = troughRows[1]

    if trough.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_72')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local troughVec = vector3(trough.pos_x, trough.pos_y, trough.pos_z)
    if #(playerCoords - troughVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_73')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:startWaterTroughMove', src, watertroughid)
end)

-- Confirm a water trough's new position after the move preview
RegisterNetEvent('rsg-ranch:server:confirmMoveWaterTrough', function(watertroughid, pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then return end
    if not watertroughid or not pos_x or not pos_y or not pos_z then return end

    local troughRows = MySQL.query.await('SELECT watertroughid, ranchid FROM rsg_ranch_watertroughs WHERE watertroughid = ?', {watertroughid})
    if not troughRows or #troughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_74')})
        return
    end

    if troughRows[1].ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_75')})
        return
    end

    -- Never trust client-supplied coords - the player must actually be near where they claim to move it to
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - vector3(pos_x, pos_y, pos_z)) > Config.PropPlacementMaxDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_76')})
        return
    end

    local updateSuccess, rowsAffected = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_watertroughs SET pos_x = ?, pos_y = ?, pos_z = ?, pos_w = ? WHERE watertroughid = ?', {
            pos_x, pos_y, pos_z, pos_w or 0.0, watertroughid
        })
    end)

    if not updateSuccess or not rowsAffected or rowsAffected <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_77')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:moveWaterTrough', -1, watertroughid, pos_x, pos_y, pos_z, pos_w or 0.0)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_78')})

    if Config.Debug then
        print('^2[WATERTROUGH]^7 Player ' .. src .. ' moved water trough ' .. watertroughid)
    end
end)

-- Ranch staff wants to permanently remove a placed water trough
RegisterNetEvent('rsg-ranch:server:deleteWaterTrough', function(watertroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_79')})
        return
    end

    if not watertroughid then return end

    local troughRows = MySQL.query.await('SELECT watertroughid, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_watertroughs WHERE watertroughid = ?', {watertroughid})
    if not troughRows or #troughRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_80')})
        return
    end
    local trough = troughRows[1]

    if trough.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_81')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local troughVec = vector3(trough.pos_x, trough.pos_y, trough.pos_z)
    if #(playerCoords - troughVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_82')})
        return
    end

    MySQL.query.await('DELETE FROM rsg_ranch_watertroughs WHERE watertroughid = ?', {watertroughid})
    TriggerClientEvent('rsg-ranch:client:removeWaterTrough', -1, watertroughid)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_83')})

    if Config.Debug then
        print('^2[WATERTROUGH]^7 Player ' .. src .. ' deleted water trough ' .. watertroughid)
    end
end)

---------------------------------------------
-- create unique coopid
---------------------------------------------
local function CreateChickenCoopId()
    local UniqueFound = false
    local coopid = nil
    local maxAttempts = 50
    local attempts = 0

    while not UniqueFound and attempts < maxAttempts do
        attempts = attempts + 1
        coopid = math.random(Config.CHICKENCOOP_ID_MIN, Config.CHICKENCOOP_ID_MAX)

        local success, result = pcall(function()
            return MySQL.query.await("SELECT COUNT(*) as count FROM rsg_ranch_chickencoops WHERE coopid = ?", { coopid })
        end)

        if success and result and result[1] and result[1].count == 0 then
            UniqueFound = true
        elseif not success then
            if Config.Debug then
                print("^1[ERROR]^7 Database error in CreateChickenCoopId: " .. tostring(result))
            end
            break
        end
    end

    if not UniqueFound then
        local serverTime = os.time()
        local randomSuffix = math.random(1000, 9999)
        coopid = tostring(serverTime) .. tostring(randomSuffix)
        if string.len(coopid) > Config.MAX_ID_LENGTH then
            coopid = string.sub(coopid, -Config.MAX_ID_LENGTH)
        end
    end

    return tonumber(coopid)
end

---------------------------------------------
-- Chicken Coop System
---------------------------------------------

-- Estimate how many eggs a coop currently has ready, accounting for elapsed production
-- cycles since last_production, without mutating the row and without rolling any random
-- numbers (used by the status callback for a stable preview - actual amounts are only
-- rolled/committed by RollChickenCoopEggs at buy/collect time).
local function CalculateChickenCoopEggs(coop)
    local interval = Config.EggProductionInterval or 1800
    local elapsed = os.time() - (coop.last_production or os.time())
    local cycles = math.floor(elapsed / interval)
    local expected = math.floor(cycles * (coop.chickens or 0) * (Config.EggsPerChickenPerCycle or 1) * (Config.ChickenEggChance or 1))
    local total = math.min(Config.MaxEggsStored or 100, (coop.eggs_stored or 0) + expected)
    return total, cycles
end

-- Roll how many eggs a coop has actually produced, accounting for elapsed production
-- cycles since last_production. Each chicken gets an independent chance
-- (Config.ChickenEggChance) to lay its eggs on each cycle, rather than a guaranteed
-- fixed output, so production is randomized rather than perfectly predictable.
-- This is the version that should be used whenever eggs_stored is actually committed
-- (buying a chicken, collecting eggs).
local function RollChickenCoopEggs(coop)
    local interval = Config.EggProductionInterval or 1800
    local elapsed = os.time() - (coop.last_production or os.time())
    local cycles = math.floor(elapsed / interval)
    local chance = Config.ChickenEggChance or 1
    local perLay = Config.EggsPerChickenPerCycle or 1

    local produced = 0
    for _ = 1, cycles do
        for _ = 1, (coop.chickens or 0) do
            if math.random() <= chance then
                produced = produced + perLay
            end
        end
    end

    local total = math.min(Config.MaxEggsStored or 100, (coop.eggs_stored or 0) + produced)
    return total, cycles
end

-- Estimate a coop's current feed level, accounting for elapsed decay cycles since
-- last_feed_update, without mutating the row (used for a stable preview in the
-- status check). A missing/zero last_feed_update (e.g. a coop from before this
-- feature existed, or one just placed) is treated as "fed just now" rather than
-- "not fed since 1970", so it doesn't get instantly starved out.
local function CalculateChickenCoopFeedLevel(coop)
    local interval = Config.ChickenCoopFeedDecayInterval or 3600
    local maxFeed = Config.ChickenCoopMaxFeedLevel or 100
    local lastFeedUpdate = coop.last_feed_update
    if not lastFeedUpdate or lastFeedUpdate <= 0 then
        return coop.feed_level or maxFeed, 0
    end

    local elapsed = os.time() - lastFeedUpdate
    local cycles = math.floor(elapsed / interval)
    local decayed = math.max(0, (coop.feed_level or maxFeed) - (cycles * (Config.ChickenCoopFeedDecayAmount or 10)))
    return decayed, cycles
end

-- Roll (and mark for commit) a coop's feed decay since last_feed_update. Returns the
-- new feed level, how many decay cycles were applied, and whether the coop's chickens
-- just starved to death as a result (feed level reached 0 while it still had chickens).
-- This is the version that should be used whenever feed_level is actually committed
-- (feeding the coop, or the periodic starvation check).
local function RollChickenCoopFeedLevel(coop)
    local newFeedLevel, cycles = CalculateChickenCoopFeedLevel(coop)
    local diedOut = (coop.chickens or 0) > 0 and newFeedLevel <= 0
    return newFeedLevel, cycles, diedOut
end

-- Register chickencoop as a useable item, starts client-side placement preview
RSGCore.Functions.CreateUseableItem(Config.ChickenCoopItem, function(source, item)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_84')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:startChickenCoopPlacement', src)
end)

-- Confirm placement from client and persist to database
RegisterNetEvent('rsg-ranch:server:placeChickenCoop', function(pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_85')})
        return
    end

    if not pos_x or not pos_y or not pos_z then return end

    -- Never trust client-supplied coords - the player must actually be near where they claim to place it
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - vector3(pos_x, pos_y, pos_z)) > Config.PropPlacementMaxDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_86')})
        return
    end

    -- Re-check the item is still present (placement preview takes a moment client-side)
    local hasItem = Player.Functions.GetItemByName(Config.ChickenCoopItem)
    if not hasItem or hasItem.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_87')})
        return
    end

    local ranchid = Player.PlayerData.job.name
    local coopid = CreateChickenCoopId()
    if not coopid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_88')})
        return
    end

    -- Take the item first and check it actually came off
    local itemRemoved = exports['rsg-inventory']:RemoveItem(src, Config.ChickenCoopItem, 1, nil, 'rsg-ranch')
    if not itemRemoved then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_89')})
        return
    end

    local createdAt = os.time()
    local insertSuccess, insertResult = pcall(function()
        return MySQL.insert.await('INSERT INTO rsg_ranch_chickencoops (coopid, ranchid, pos_x, pos_y, pos_z, pos_w, chickens, eggs_stored, feed_level, last_feed_update, last_production, placed_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            coopid, ranchid, pos_x, pos_y, pos_z, pos_w or 0.0, 0, 0, Config.ChickenCoopMaxFeedLevel or 100, createdAt, createdAt, Player.PlayerData.citizenid, createdAt
        })
    end)

    if not insertSuccess or not insertResult then
        exports['rsg-inventory']:AddItem(src, Config.ChickenCoopItem, 1, nil, nil, 'rsg-ranch')
        if Config.Debug then
            print('^1[ERROR]^7 Failed to insert chicken coop: ' .. tostring(insertResult))
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_90')})
        return
    end

    if RSGCore.Shared.Items[Config.ChickenCoopItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.ChickenCoopItem], 'remove', 1)
    end

    local coopData = {
        coopid = coopid,
        ranchid = ranchid,
        pos_x = pos_x,
        pos_y = pos_y,
        pos_z = pos_z,
        pos_w = pos_w or 0.0,
        chickens = 0
    }

    -- Broadcast to everyone so nearby clients can see it immediately
    TriggerClientEvent('rsg-ranch:client:spawnChickenCoop', -1, coopData)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_91')})

    if Config.Debug then
        print('^2[CHICKENCOOP]^7 Player ' .. src .. ' placed chicken coop ' .. coopid .. ' at ranch ' .. ranchid)
    end
end)

-- Send current chicken coops to a (re)connecting/refreshing client
RegisterNetEvent('rsg-ranch:server:refreshChickenCoops', function()
    local src = source
    if RefreshOnCooldown(src, 'coops') then return end
    local success, error = pcall(function()
        MySQL.query('SELECT coopid, ranchid, pos_x, pos_y, pos_z, pos_w, chickens FROM rsg_ranch_chickencoops', {}, function(coops, err)
            if err then
                print('^1[ERROR]^7 Database query failed in refreshChickenCoops: ' .. tostring(err))
                return
            end

            TriggerClientEvent('rsg-ranch:client:spawnChickenCoops', src, coops or {})
        end)
    end)

    if not success then
        if Config.Debug then
            print('^1[ERROR]^7 Critical error in refreshChickenCoops: ' .. tostring(error))
        end
    end
end)

-- Live status for the "Check Coop" ox_target option
RSGCore.Functions.CreateCallback('rsg-ranch:server:getChickenCoopStatus', function(source, cb, coopid)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player or not isPlayerRanchStaff(Player) then cb(nil) return end

    local coopRows = MySQL.query.await('SELECT coopid, ranchid, chickens, eggs_stored, feed_level, last_feed_update, last_production FROM rsg_ranch_chickencoops WHERE coopid = ?', {coopid})
    if not coopRows or #coopRows == 0 then
        cb(nil)
        return
    end

    local coop = coopRows[1]
    if coop.ranchid ~= Player.PlayerData.job.name then cb(nil) return end

    local eggsReady = CalculateChickenCoopEggs(coop)
    local feedLevel = CalculateChickenCoopFeedLevel(coop)

    cb({ chickens = coop.chickens or 0, eggsReady = eggsReady, feedLevel = feedLevel, maxFeedLevel = Config.ChickenCoopMaxFeedLevel or 100 })
end)

-- Ranch staff buys a chicken for a coop
RegisterNetEvent('rsg-ranch:server:buyChicken', function(coopid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_92')})
        return
    end
    if not RanchCan(Player, 'canBuy') then return DenyPermission(src) end

    if not coopid then return end

    local coopRows = MySQL.query.await('SELECT coopid, ranchid, pos_x, pos_y, pos_z, chickens, eggs_stored, last_production FROM rsg_ranch_chickencoops WHERE coopid = ?', {coopid})
    if not coopRows or #coopRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_93')})
        return
    end
    local coop = coopRows[1]

    if coop.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_94')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local coopVec = vector3(coop.pos_x, coop.pos_y, coop.pos_z)
    if #(playerCoords - coopVec) > (Config.ChickenCoopInteractDistance + 3.0) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_95')})
        return
    end

    if (coop.chickens or 0) >= (Config.MaxChickensPerCoop or 20) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_96')})
        return
    end

    local price = Config.ChickenBuyPrice or 15
    if (Player.PlayerData.money.cash or 0) < price then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_97')})
        return
    end

    -- Bank any eggs already earned before the chicken count changes, so the
    -- new chicken only starts contributing from this point forward.
    local eggsReady, cycles = RollChickenCoopEggs(coop)
    local newLastProduction = (coop.last_production or os.time()) + (cycles * (Config.EggProductionInterval or 1800))

    local moneyRemoved = Player.Functions.RemoveMoney('cash', price, 'bought-chicken')
    if not moneyRemoved then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_98')})
        return
    end

    local newChickenCount = (coop.chickens or 0) + 1
    -- only applies if the coop hasn't changed since we read it (stops two
    -- simultaneous purchases both passing the max-chickens check)
    local updated = MySQL.update.await('UPDATE rsg_ranch_chickencoops SET chickens = ?, eggs_stored = ?, last_production = ? WHERE coopid = ? AND chickens = ? AND last_production = ?', {
        newChickenCount, eggsReady, newLastProduction, coopid, coop.chickens or 0, coop.last_production
    })
    if not updated or updated <= 0 then
        Player.Functions.AddMoney('cash', price, 'bought-chicken-refund')
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:updateChickenCoop', -1, coopid, newChickenCount)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_99'):format(newChickenCount, Config.MaxChickensPerCoop)})

    if Config.Debug then
        print('^2[CHICKENCOOP]^7 Player ' .. src .. ' bought a chicken for coop ' .. coopid .. ' (now ' .. newChickenCount .. ')')
    end
end)

-- Ranch staff collects eggs produced by a coop's chickens
RegisterNetEvent('rsg-ranch:server:collectEggs', function(coopid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_100')})
        return
    end
    if not RanchCan(Player, 'canCollectProducts') then return DenyPermission(src) end

    if not coopid then return end

    local coopRows = MySQL.query.await('SELECT coopid, ranchid, pos_x, pos_y, pos_z, chickens, eggs_stored, last_production FROM rsg_ranch_chickencoops WHERE coopid = ?', {coopid})
    if not coopRows or #coopRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_101')})
        return
    end
    local coop = coopRows[1]

    if coop.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_102')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local coopVec = vector3(coop.pos_x, coop.pos_y, coop.pos_z)
    if #(playerCoords - coopVec) > (Config.ChickenCoopInteractDistance + 3.0) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_103')})
        return
    end

    local eggsReady = RollChickenCoopEggs(coop)
    if eggsReady <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'inform', description = locale('sv_server_description_104')})
        return
    end

    if not exports['rsg-inventory']:CanAddItem(src, Config.EggItem, eggsReady) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_105')})
        return
    end

    -- Claim the eggs atomically: the row only updates if nobody else collected
    -- (or bought a chicken) since we read it, so spam-firing can't pay out twice.
    local claimed = MySQL.update.await('UPDATE rsg_ranch_chickencoops SET eggs_stored = 0, last_production = ? WHERE coopid = ? AND last_production = ? AND eggs_stored = ?', {
        os.time(), coopid, coop.last_production, coop.eggs_stored or 0
    })
    if not claimed or claimed <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'inform', description = locale('sv_server_description_104')})
        return
    end

    if not exports['rsg-inventory']:AddItem(src, Config.EggItem, eggsReady, nil, nil, 'rsg-ranch') then
        MySQL.update('UPDATE rsg_ranch_chickencoops SET eggs_stored = ? WHERE coopid = ?', {eggsReady, coopid})
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_105')})
        return
    end

    if RSGCore.Shared.Items[Config.EggItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.EggItem], 'add', eggsReady)
    end

    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_106'):format(eggsReady)})

    if Config.Debug then
        print('^2[CHICKENCOOP]^7 Player ' .. src .. ' collected ' .. eggsReady .. ' egg(s) from coop ' .. coopid)
    end
end)

-- Ranch staff wants to permanently remove a placed chicken coop
RegisterNetEvent('rsg-ranch:server:deleteChickenCoop', function(coopid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_107')})
        return
    end

    if not coopid then return end

    local coopRows = MySQL.query.await('SELECT coopid, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_chickencoops WHERE coopid = ?', {coopid})
    if not coopRows or #coopRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_108')})
        return
    end
    local coop = coopRows[1]

    if coop.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_109')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local coopVec = vector3(coop.pos_x, coop.pos_y, coop.pos_z)
    if #(playerCoords - coopVec) > (Config.ChickenCoopInteractDistance + 3.0) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_110')})
        return
    end

    MySQL.query.await('DELETE FROM rsg_ranch_chickencoops WHERE coopid = ?', {coopid})
    TriggerClientEvent('rsg-ranch:client:removeChickenCoop', -1, coopid)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_111')})

    if Config.Debug then
        print('^2[CHICKENCOOP]^7 Player ' .. src .. ' deleted chicken coop ' .. coopid)
    end
end)

-- Ranch staff feeds a coop using a feed bag, topping up feed_level (and applying any
-- decay that had built up since it was last checked/fed first - feeding late doesn't
-- retroactively save chickens that already starved out)
RegisterNetEvent('rsg-ranch:server:feedChickenCoop', function(coopid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_112')})
        return
    end

    if not coopid then return end

    local hasItem = Player.Functions.GetItemByName(Config.FeedBagItem)
    if not hasItem or hasItem.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_113')})
        return
    end

    local coopRows = MySQL.query.await('SELECT coopid, ranchid, pos_x, pos_y, pos_z, chickens, eggs_stored, feed_level, last_feed_update FROM rsg_ranch_chickencoops WHERE coopid = ?', {coopid})
    if not coopRows or #coopRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_114')})
        return
    end
    local coop = coopRows[1]

    if coop.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_115')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local coopVec = vector3(coop.pos_x, coop.pos_y, coop.pos_z)
    if #(playerCoords - coopVec) > (Config.ChickenCoopInteractDistance + 3.0) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_116')})
        return
    end

    if (coop.chickens or 0) <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_117')})
        return
    end

    -- Apply any feed decay that had built up since it was last checked/fed
    local rolledFeedLevel, cycles, diedOut = RollChickenCoopFeedLevel(coop)
    local maxFeed = Config.ChickenCoopMaxFeedLevel or 100

    if diedOut then
        local updateSuccess, rowsAffected = pcall(function()
            return MySQL.update.await('UPDATE rsg_ranch_chickencoops SET chickens = 0, eggs_stored = 0, feed_level = 0, last_feed_update = ? WHERE coopid = ?', {os.time(), coopid})
        end)

        if updateSuccess and rowsAffected and rowsAffected > 0 then
            TriggerClientEvent('rsg-ranch:client:updateChickenCoop', -1, coopid, 0)
        end

        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = locale('sv_server_description_118')
        })

        if Config.Debug then
            print('^1[CHICKENCOOP]^7 Coop ' .. coopid .. ' chickens starved to death before being fed (elapsed cycles: ' .. cycles .. ')')
        end
        return
    end

    if rolledFeedLevel >= maxFeed then
        -- Persist the decay roll even though we're not adding feed, so the clock
        -- doesn't run further behind next time this coop is checked
        MySQL.update('UPDATE rsg_ranch_chickencoops SET feed_level = ?, last_feed_update = ? WHERE coopid = ?', {rolledFeedLevel, os.time(), coopid})
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_119')})
        return
    end

    local newFeedLevel = math.min(maxFeed, rolledFeedLevel + (Config.ChickenCoopFeedPerBag or 50))

    if not exports['rsg-inventory']:RemoveItem(src, Config.FeedBagItem, 1, nil, 'rsg-ranch') then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_113')})
        return
    end

    local updateSuccess, rowsAffected = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_chickencoops SET feed_level = ?, last_feed_update = ? WHERE coopid = ?', {newFeedLevel, os.time(), coopid})
    end)

    if not updateSuccess or not rowsAffected or rowsAffected <= 0 then
        exports['rsg-inventory']:AddItem(src, Config.FeedBagItem, 1, nil, nil, 'rsg-ranch')
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_120')})
        return
    end

    if RSGCore.Shared.Items[Config.FeedBagItem] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.FeedBagItem], 'remove', 1)
    end

    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = locale('sv_server_description_121'):format(newFeedLevel, maxFeed)
    })

    if Config.Debug then
        print('^2[CHICKENCOOP]^7 Player ' .. src .. ' fed chicken coop ' .. coopid .. ' (feed level now ' .. newFeedLevel .. '/' .. maxFeed .. ')')
    end
end)

---------------------------------------------
-- Spawn Event Handlers
---------------------------------------------

-- Handle spawn requests from clients
RegisterNetEvent('rsg-ranch:server:requestAnimalSpawn', function(animalId, animalData)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    -- Allow everyone to spawn/see animals, but interactions are still restricted client-side
    if not Player or not animalId or type(animalData) ~= 'table' then
        TriggerClientEvent('rsg-ranch:client:spawnAnimalDenied', src, animalId, 'Invalid request')
        return
    end
    animalId = tostring(animalId)
    
    -- Check if spawn is allowed
    local canSpawn, reason = SpawnController:CanPlayerSpawn(src, animalId)
    if not canSpawn then
        TriggerClientEvent('rsg-ranch:client:spawnAnimalDenied', src, animalId, reason)
        return
    end
    
    -- Someone else is creating this animal right now - wait for their network id
    -- (it is broadcast to nearby players on registration) instead of creating a
    -- duplicate entity. Take over if the creator hasn't registered within 10s.
    local existing = SpawnController.activeSpawns[animalId]
    if existing and not existing.networkId and existing.creator and existing.creator ~= src
        and existing.creatorAt and (os.time() - existing.creatorAt) < 10 then
        TriggerClientEvent('rsg-ranch:client:spawnAnimalDenied', src, animalId, 'Creation in progress')
        return
    end

    -- Check if this animal already has a network ID (spawned by another player)
    local existingNetworkId = SpawnController.activeSpawns[animalId] and SpawnController.activeSpawns[animalId].networkId
    
    -- Register the spawn
    SpawnController:RegisterSpawn(src, animalId, animalData, existingNetworkId)
    
    if existingNetworkId then
        -- Entity already exists, just tell this player to use it
        TriggerClientEvent('rsg-ranch:client:spawnAnimalGranted', src, animalId, animalData, existingNetworkId)
        if Config.Debug then
            print('^2[SPAWN CONTROLLER]^7 Player ' .. src .. ' using existing entity for animal ' .. animalId .. ' (netId: ' .. existingNetworkId .. ')')
        end
    else
        -- No entity exists yet - only requesting player creates it, and only that
        -- player may register its network id (see registerAnimalNetworkId)
        SpawnController.activeSpawns[animalId].creator = src
        SpawnController.activeSpawns[animalId].creatorAt = os.time()
        -- isCreator = true means this client should create the networked entity
        TriggerClientEvent('rsg-ranch:client:spawnAnimalGranted', src, animalId, animalData, nil, true)
        
        if Config.Debug then
            print('^2[SPAWN CONTROLLER]^7 Player ' .. src .. ' granted creation rights for animal ' .. animalId)
        end
    end
end)

-- Handle network ID registration from clients (when a client creates a networked entity)
RegisterNetEvent('rsg-ranch:server:registerAnimalNetworkId', function(animalId, networkId)
    local src = source

    if not animalId or type(networkId) ~= 'number' or networkId <= 0 then
        if Config.Debug then
            print('^1[SPAWN CONTROLLER]^7 Invalid network ID received for animal ' .. tostring(animalId))
        end
        return
    end
    animalId = tostring(animalId)

    -- Only the player who was granted creation rights may register the entity.
    -- Previously anyone could point any animal at any network id (e.g. their own
    -- horse), which also let them steer the server-side position checks.
    local pending = SpawnController.activeSpawns[animalId]
    if not pending or pending.creator ~= src then return end

    -- Update the spawn data with the network ID
    if pending then
        SpawnController.activeSpawns[animalId].networkId = networkId
        
        if Config.Debug then
            print('^2[SPAWN CONTROLLER]^7 Registered network ID ' .. networkId .. ' for animal ' .. animalId .. ' from player ' .. src)
        end
        
        -- Broadcast the network ID to other nearby players so they can sync
        local spawnData = SpawnController.activeSpawns[animalId]
        if spawnData.pos_x and spawnData.pos_y and spawnData.pos_z then
            local animalCoords = vector3(spawnData.pos_x, spawnData.pos_y, spawnData.pos_z)
            local nearbyPlayers = GetNearbyPlayers(animalCoords, SpawnController.config.broadcastRadius)
            
            for _, playerId in ipairs(nearbyPlayers) do
                if playerId ~= src then
                    -- Get animal data from the spawn
                    local animalData = {
                        pos_x = spawnData.pos_x,
                        pos_y = spawnData.pos_y,
                        pos_z = spawnData.pos_z,
                        model = spawnData.model
                    }
                    TriggerClientEvent('rsg-ranch:client:spawnAnimalGranted', playerId, animalId, animalData, networkId)
                end
            end
        end
    end
end)

---------------------------------------------
-- count amount of animals the ranch owns
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:countanimals', function(src, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not ranchid then 
        cb(0)
        return 
    end
    
    local success, result = pcall(function()
        return MySQL.query.await("SELECT COUNT(*) as count FROM rsg_ranch_animals WHERE ranchid = ?", { ranchid })
    end)
    
        if success and result and result[1] then
            cb(result[1].count or 0)
        else
            cb(0)
            if Config.Debug then
                print("^1[ERROR]^7 Failed to query animal count for ranchid: " .. tostring(ranchid))
            end
        end
end)

---------------------------------------------
-- send animals to client side from database
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:refreshAnimals', function()
    local src = source
    if not src or src == '' then return end

    if RefreshOnCooldown(src, 'animals') then return end

    RanchBroadcastAnimals(src)
end)

---------------------------------------------
-- Resolve the networked entity for an animal server-side, but only if it
-- really is that animal (a ped of the model stored in the database).
---------------------------------------------
local function GetVerifiedAnimalEntity(animalid, model)
    local tracked = SpawnController.activeSpawns[tostring(animalid)]
    local netId = tracked and tracked.networkId
    if not netId then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 1 then return nil end
    -- compare as unsigned 32-bit: natives and joaat can disagree on sign
    if model and (GetEntityModel(entity) & 0xFFFFFFFF) ~= (joaat(model) & 0xFFFFFFFF) then return nil end
    return entity
end

-- how far an animal with no server-visible entity may "move" in a single save
local MAX_UNTRACKED_MOVE = 25.0

---------------------------------------------
-- save animal position to database
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:saveAnimalPosition', function(animalid, pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        return
    end

    if not animalid or type(pos_x) ~= 'number' or type(pos_y) ~= 'number' or type(pos_z) ~= 'number' then
        return
    end

    if type(pos_w) ~= 'number' then pos_w = 0.0 end

    -- Verify the animal exists and belongs to the player's own ranch
    local animalData = MySQL.query.await('SELECT ranchid, model, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
    if not animalData or #animalData == 0 then
        return
    end
    local dbAnimal = animalData[1]

    if dbAnimal.ranchid ~= Player.PlayerData.job.name then
        return
    end

    -- Never trust the client's coords for where the animal is. Sale points and
    -- breeding/collect checks use this stored position, so a spoofed save let
    -- staff "teleport" the whole herd to a sale point without ever herding it.
    -- Prefer the server's own view of the networked entity; without one, only
    -- accept a small step from the last stored position.
    local entity = GetVerifiedAnimalEntity(animalid, dbAnimal.model)
    if entity then
        local c = GetEntityCoords(entity)
        pos_x, pos_y, pos_z, pos_w = c.x, c.y, c.z, GetEntityHeading(entity)
    elseif #(vector3(pos_x, pos_y, pos_z) - vector3(dbAnimal.pos_x, dbAnimal.pos_y, dbAnimal.pos_z)) > MAX_UNTRACKED_MOVE then
        if Config.Debug then
            print('^1[DEBUG]^7 Player ' .. src .. ' tried to move untracked animal ' .. animalid .. ' too far in one save')
        end
        return
    end

    -- The new position must be within a sane distance of the player's own coords,
    -- since this event is only ever fired as a result of an animal following/being placed near them
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local newPos = vector3(pos_x, pos_y, pos_z)
    -- (a verified entity position can't be faked, so allow the whole herd radius there)
    local maxSaveDistance = entity and ((Config.HerdingDistance or 25.0) + 10.0) or ((Config.AnimalInteractionDistance or 3.0) + 5.0)
    if #(playerCoords - newPos) > maxSaveDistance then
        if Config.Debug then
            print('^1[DEBUG]^7 Player ' .. src .. ' tried to save an out-of-range position for animal ' .. animalid)
        end
        return
    end

    -- update the animal's position in the database
    MySQL.update.await('UPDATE rsg_ranch_animals SET pos_x = ?, pos_y = ?, pos_z = ?, pos_w = ? WHERE animalid = ?', {
        pos_x,
        pos_y,
        pos_z,
        pos_w,
        animalid
    })

    -- Also keep SpawnController's own tracking current. It records pos_x/y/z once at the
    -- moment an animal is first spawned and otherwise never updates it - CanPlayerSpawn uses
    -- that position to decide whether anyone is "nearby enough" to keep the spawn alive, so
    -- without this it keeps judging distance against the animal's original spawn point (the
    -- Livestock Dealer) for as long as it's being followed, instead of where it actually is.
    local tracked = SpawnController.activeSpawns[tostring(animalid)]
    if tracked then
        tracked.pos_x = pos_x
        tracked.pos_y = pos_y
        tracked.pos_z = pos_z
    end

    -- Update only the specific client with position change
    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', src, animalid, {pos_x = pos_x, pos_y = pos_y, pos_z = pos_z, pos_w = pos_w})
end)

---------------------------------------------
-- on restart send animals to client from database
---------------------------------------------
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        Wait(5000)
        RanchBroadcastAnimals(-1)
    end
end)

---------------------------------------------
-- Handle client reporting animal despawn
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:reportDespawn', function(animalId)
    local src = source
    if not animalId then return end
    animalId = tostring(animalId)
    
    if SpawnController.activeSpawns[animalId] then
        local spawnData = SpawnController.activeSpawns[animalId]
        
        if spawnData.players and spawnData.players[src] then
            spawnData.players[src] = nil
            
            if Config.Debug then
                print('^3[SPAWN CONTROLLER]^7 Player ' .. src .. ' despawned animal ' .. animalId)
            end
            
            -- Check if any players are still tracking this animal
            local hasPlayers = false
            for _ in pairs(spawnData.players) do
                hasPlayers = true
                break
            end
            
            -- If no players left, clear the spawn
            if not hasPlayers then
                SpawnController.activeSpawns[animalId] = nil
                if Config.Debug then
                    print('^3[SPAWN CONTROLLER]^7 All players despawned animal ' .. animalId .. ', clearing server tracking')
                end
            end
        end
    end
end)

---------------------------------------------
-- Handle player disconnects
---------------------------------------------
AddEventHandler('playerDropped', function(reason)
    local src = source
    SpawnController:ClearPlayerSpawns(src)
    RefreshCooldowns[src] = nil
    BuyAnimalLocks[src] = nil
end)

---------------------------------------------
-- collect animal product system
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:collectProduct', function(animalid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    -- Validate player is ranch staff
    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_122')})
        return
    end
    if not RanchCan(Player, 'canCollectProducts') then return DenyPermission(src) end

    if not animalid then
        if Config.Debug then
            print('^1[COLLECT ERROR]^7 Missing animalid - AnimalID: ' .. tostring(animalid))
        end
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))

    local result = MySQL.query.await('SELECT model, product_ready, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
    if not result or #result == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_123')})
        return
    end

    local animal = result[1]

    if animal.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_124')})
        return
    end

    local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
    if #(playerCoords - animalVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_125')})
        return
    end

    if not animal.product_ready or animal.product_ready == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_126')})
        return
    end

    local productConfig = Config.AnimalProducts[animal.model]
    if not productConfig then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_127')})
        return
    end

    if not exports['rsg-inventory']:CanAddItem(src, productConfig.product, productConfig.amount) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_130')})
        return
    end

    -- Claim the product atomically BEFORE giving anything: only one of several
    -- simultaneous/spam-fired requests can flip product_ready 1 -> 0, so only
    -- that one gets paid (the old flow added the item first, then reset the flag,
    -- letting a spammed event collect the same product several times).
    local claimed = MySQL.update.await('UPDATE rsg_ranch_animals SET product_ready = 0 WHERE animalid = ? AND product_ready = 1', {animalid})
    if not claimed or claimed <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_126')})
        return
    end

    if not exports['rsg-inventory']:AddItem(src, productConfig.product, productConfig.amount, nil, nil, 'rsg-ranch') then
        -- give the product back to the animal rather than losing it
        MySQL.update('UPDATE rsg_ranch_animals SET product_ready = 1 WHERE animalid = ?', {animalid})
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_130')})
        return
    end

    local itemData = RSGCore.Shared.Items[productConfig.product]
    if itemData then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, itemData, 'add', productConfig.amount)
    end

    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_128'):format(productConfig.amount, itemData and itemData.label or productConfig.product)})
    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animalid, {product_ready = 0})

    if Config.Debug then
        print('^2[COLLECT SUCCESS]^7 Player ' .. src .. ' collected ' .. productConfig.amount .. 'x ' .. productConfig.product .. ' from animal ' .. animalid)
    end
end)

---------------------------------------------
-- manual "send to trough" actions
--
-- Animals are fed/watered automatically by the ranch's trough pool once
-- hunger/thirst drops to/below Config.FeedTroughHungerThreshold /
-- Config.WaterTroughThirstThreshold (see ProcessAnimalFeedWater), but a player
-- can still send an individual animal to a specific trough on demand from the
-- action menu. The client walks the animal there and only fires this once it
-- has actually arrived; this still re-validates everything server-side.
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:sendAnimalToFeed', function(animalid, feedtroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_301')})
        return
    end

    if not animalid or not feedtroughid then return end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))

    local animalRows = MySQL.query.await('SELECT animalid, hunger, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
    if not animalRows or #animalRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_302')})
        return
    end
    local animal = animalRows[1]

    if animal.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_303')})
        return
    end

    local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
    if #(playerCoords - animalVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_304')})
        return
    end

    local troughRows = MySQL.query.await('SELECT feedtroughid, ranchid, uses FROM rsg_ranch_feedtroughs WHERE feedtroughid = ?', {feedtroughid})
    if not troughRows or #troughRows == 0 or troughRows[1].ranchid ~= animal.ranchid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_305')})
        return
    end
    local trough = troughRows[1]

    if (trough.uses or 0) <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_306')})
        return
    end

    local newUses = trough.uses - 1
    local newHunger = math.min(100, (animal.hunger or 100) + (Config.FeedTroughFeedAmount or Config.AutoFeedRestoreAmount or 100))

    -- take the use atomically so two requests can't both spend the last one
    local updateSuccess, taken = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_feedtroughs SET uses = uses - 1 WHERE feedtroughid = ? AND uses > 0', {feedtroughid})
    end)
    if updateSuccess and taken and taken > 0 then
        updateSuccess = pcall(function()
            MySQL.update.await('UPDATE rsg_ranch_animals SET hunger = ? WHERE animalid = ?', {newHunger, animalid})
        end)
    else
        updateSuccess = false
    end

    if not updateSuccess then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_305')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:updateFeedTroughUses', -1, feedtroughid, newUses)
    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animalid, { hunger = newHunger })
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_307'):format(newHunger)})

    if Config.Debug then
        print('^2[FEEDTROUGH]^7 Player ' .. src .. ' sent animal ' .. animalid .. ' to feed trough ' .. feedtroughid .. ' - hunger now ' .. newHunger)
    end
end)

RegisterNetEvent('rsg-ranch:server:sendAnimalToWater', function(animalid, watertroughid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_301')})
        return
    end

    if not animalid or not watertroughid then return end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))

    local animalRows = MySQL.query.await('SELECT animalid, thirst, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
    if not animalRows or #animalRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_302')})
        return
    end
    local animal = animalRows[1]

    if animal.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_303')})
        return
    end

    local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
    if #(playerCoords - animalVec) > Config.AnimalInteractionDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_304')})
        return
    end

    local troughRows = MySQL.query.await('SELECT watertroughid, ranchid, uses FROM rsg_ranch_watertroughs WHERE watertroughid = ?', {watertroughid})
    if not troughRows or #troughRows == 0 or troughRows[1].ranchid ~= animal.ranchid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_308')})
        return
    end
    local trough = troughRows[1]

    if (trough.uses or 0) <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_309')})
        return
    end

    local newUses = trough.uses - 1
    local newThirst = math.min(100, (animal.thirst or 100) + (Config.WaterTroughDrinkAmount or Config.AutoWaterRestoreAmount or 100))

    -- take the use atomically so two requests can't both spend the last one
    local updateSuccess, taken = pcall(function()
        return MySQL.update.await('UPDATE rsg_ranch_watertroughs SET uses = uses - 1 WHERE watertroughid = ? AND uses > 0', {watertroughid})
    end)
    if updateSuccess and taken and taken > 0 then
        updateSuccess = pcall(function()
            MySQL.update.await('UPDATE rsg_ranch_animals SET thirst = ? WHERE animalid = ?', {newThirst, animalid})
        end)
    else
        updateSuccess = false
    end

    if not updateSuccess then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_308')})
        return
    end

    TriggerClientEvent('rsg-ranch:client:updateWaterTroughUses', -1, watertroughid, newUses)
    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animalid, { thirst = newThirst })
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_310'):format(newThirst)})

    if Config.Debug then
        print('^2[WATERTROUGH]^7 Player ' .. src .. ' sent animal ' .. animalid .. ' to water trough ' .. watertroughid .. ' - thirst now ' .. newThirst)
    end
end)

---------------------------------------------
-- animal production status callback
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getAnimalProductionStatus', function(src, cb, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if Config.Debug then
        print('^3[PRODUCTION DEBUG]^7 Production status request for animal ' .. tostring(animalid) .. ' from player ' .. src)
    end
    
    if not Player or not animalid or not isPlayerRanchStaff(Player) then
        if Config.Debug then
            print('^1[PRODUCTION DEBUG]^7 Request denied - Player: ' .. tostring(Player ~= nil) .. ', AnimalID: ' .. tostring(animalid) .. ', IsStaff: ' .. tostring(Player and isPlayerRanchStaff(Player)))
        end
        cb(false)
        return 
    end
    
    MySQL.query('SELECT model, product_ready, health, hunger, thirst, last_production, age, born FROM rsg_ranch_animals WHERE animalid = ?', {animalid}, function(result)
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Database query result for animal ' .. animalid .. ': ' .. (result and #result or 'nil/0') .. ' rows')
        end
        
        if not result or #result == 0 then
            if Config.Debug then
                print('^1[PRODUCTION DEBUG]^7 No animal found with ID: ' .. animalid)
            end
            cb(false)
            return
        end
        
        local animal = result[1]
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Found animal - Model: ' .. tostring(animal.model) .. ', Product Ready: ' .. tostring(animal.product_ready))
        end
        
        local productConfig = Config.AnimalProducts[animal.model]
        if not productConfig then
            if Config.Debug then
                print('^1[PRODUCTION DEBUG]^7 No product config found for model: ' .. tostring(animal.model))
            end
            cb(false)
            return
        end
        
        if Config.Debug then
            print('^2[PRODUCTION DEBUG]^7 Product config found - Product: ' .. productConfig.product .. ', Amount: ' .. productConfig.amount)
        end
        
        local hasProduct = (animal.product_ready == 1 or animal.product_ready == true)
        
        -- Check production requirements using Config values
        local meetsHealthReq = (animal.health or 0) >= (productConfig.requiresHealth or 60)
        local meetsHungerReq = (animal.hunger or 0) >= (productConfig.requiresHunger or 40)
        local meetsThirstReq = (animal.thirst or 0) >= (productConfig.requiresThirst or 40)
        local canProduce = meetsHealthReq and meetsHungerReq and meetsThirstReq
        
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animalid .. ' production check:')
            print('^3[PRODUCTION DEBUG]^7 - Health: ' .. (animal.health or 0) .. '/' .. (productConfig.requiresHealth or 60) .. ' (meets: ' .. tostring(meetsHealthReq) .. ')')
            print('^3[PRODUCTION DEBUG]^7 - Hunger: ' .. (animal.hunger or 0) .. '/' .. (productConfig.requiresHunger or 40) .. ' (meets: ' .. tostring(meetsHungerReq) .. ')')
            print('^3[PRODUCTION DEBUG]^7 - Thirst: ' .. (animal.thirst or 0) .. '/' .. (productConfig.requiresThirst or 40) .. ' (meets: ' .. tostring(meetsThirstReq) .. ')')
            print('^3[PRODUCTION DEBUG]^7 - Can Produce: ' .. tostring(canProduce) .. ', Has Product: ' .. tostring(hasProduct))
        end
        
        local currentTime = os.time()
        local lastProduction = animal.last_production or 0
        local productionInterval = productConfig.productionTime or 3600
        local timeSinceLastProduction = currentTime - lastProduction
        local timeUntilNext = math.max(0, productionInterval - timeSinceLastProduction)
        
        -- Calculate animal age
        local animalAge = animal.age or 0
        if animal.born and animal.born > 0 then
            animalAge = math.floor((currentTime - animal.born) / 86400)
        end
        
        -- Check if animal meets minimum age for production
        local meetsAgeReq = animalAge >= (Config.MinAgeForProduction or 5)
        canProduce = canProduce and meetsAgeReq
        
        local productionData = {
            hasProduct = hasProduct and meetsAgeReq,
            canProduce = canProduce,
            productName = productConfig.product,
            productAmount = productConfig.amount,
            timeUntilNext = hasProduct and 0 or timeUntilNext
        }
        
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Age check: ' .. animalAge .. 'd (min: ' .. (Config.MinAgeForProduction or 5) .. 'd) - Meets age: ' .. tostring(meetsAgeReq))
            print('^3[PRODUCTION DEBUG]^7 Timer calculation - Last production: ' .. lastProduction .. ', Current time: ' .. currentTime .. ', Time until next: ' .. timeUntilNext .. 's')
        end
        
        cb(productionData)
    end)
end)

---------------------------------------------
-- Helper function to process animal overview data
---------------------------------------------
local function processAnimalOverviewData(animals)
    local overview = {
        animals = {},
        summary = {
            total = #animals,
            byType = {},
            byGender = {male = 0, female = 0},
            pregnant = 0,
            ready_for_breeding = 0,
            unhealthy = 0,
            hungry = 0,
            thirsty = 0
        }
    }
    
    local currentTime = os.time()
    
    for _, animal in ipairs(animals) do
        -- Basic animal info
        local animalInfo = {
            animalid = animal.animalid,
            ranchid = animal.ranchid,
            model = animal.model,
            gender = animal.gender,
            age = animal.age or 0,
            health = animal.health or 100,
            hunger = animal.hunger or 100,
            thirst = animal.thirst or 100,
            pregnant = (animal.pregnant == 1 or animal.pregnant == true),
            breeding_ready_time = animal.breeding_ready_time,
            gestation_end_time = animal.gestation_end_time,
            product_ready = (animal.product_ready == 1 or animal.product_ready == true),
            dueIn = (animal.pregnant == 1 and animal.gestation_end_time) and math.max(0, animal.gestation_end_time - currentTime) or nil,
            breedingCooldown = (animal.breeding_ready_time and animal.breeding_ready_time > currentTime) and (animal.breeding_ready_time - currentTime) or 0
        }
        
        -- Calculate status flags
        animalInfo.is_unhealthy = (animalInfo.health < 70)
        animalInfo.is_hungry = (animalInfo.hunger < 50)
        animalInfo.is_thirsty = (animalInfo.thirst < 50)
        
        -- Check basic breeding readiness (age, pregnancy, cooldown)
        local basicBreedingReady = not animalInfo.pregnant and 
                                  (not animal.breeding_ready_time or animal.breeding_ready_time <= currentTime) and
                                  animalInfo.age >= (Config.MinAgeForBreeding or 5)
        
        -- For males, also check if there are already pregnant females in the ranch (if enabled)
        if basicBreedingReady and animalInfo.gender == 'male' and Config.RestrictMaleBreedingWhenFemalesPregnant then
            -- Count pregnant females in the same ranch
            local pregnantFemales = 0
            for _, otherAnimal in ipairs(animals) do
                if otherAnimal.ranchid == animalInfo.ranchid and 
                   otherAnimal.gender == 'female' and 
                   (otherAnimal.pregnant == 1 or otherAnimal.pregnant == true) then
                    pregnantFemales = pregnantFemales + 1
                end
            end
            animalInfo.breeding_ready = pregnantFemales == 0
        else
            animalInfo.breeding_ready = basicBreedingReady
        end
        
        table.insert(overview.animals, animalInfo)
        
        -- Update summary statistics
        overview.summary.byType[animal.model] = (overview.summary.byType[animal.model] or 0) + 1
        overview.summary.byGender[animal.gender] = (overview.summary.byGender[animal.gender] or 0) + 1
        
        if animalInfo.pregnant then
            overview.summary.pregnant = overview.summary.pregnant + 1
        end
        
        if animalInfo.breeding_ready then
            overview.summary.ready_for_breeding = overview.summary.ready_for_breeding + 1
        end
        
        if animalInfo.is_unhealthy then
            overview.summary.unhealthy = overview.summary.unhealthy + 1
        end
        
        if animalInfo.is_hungry then
            overview.summary.hungry = overview.summary.hungry + 1
        end
        
        if animalInfo.is_thirsty then
            overview.summary.thirsty = overview.summary.thirsty + 1
        end
    end
    
    return overview
end

---------------------------------------------
-- Animal Overview Callback
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getAnimalOverview', function(src, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)
    -- Staff can only ever see their own ranch's herd (previously any player
    -- could pull every ranch's animals, positions included, by omitting ranchid)
    if not Player or not isPlayerRanchStaff(Player) then
        cb({animals = {}, summary = {}})
        return
    end

    local result = MySQL.query.await('SELECT * FROM rsg_ranch_animals WHERE ranchid = ? ORDER BY model', {Player.PlayerData.job.name})
    cb(processAnimalOverviewData(result or {}))
end)

---------------------------------------------
-- Breeding System Callbacks
---------------------------------------------

-- Get detailed breeding status including cooldowns
RSGCore.Functions.CreateCallback('rsg-ranch:server:getBreedingStatus', function(src, cb, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not animalid or not isPlayerRanchStaff(Player) then 
        cb({status = 'error', message = locale('sv_breed_invalid_request')})
        return 
    end
    
    MySQL.query('SELECT model, gender, age, pregnant, breeding_ready_time, health, hunger, thirst, born FROM rsg_ranch_animals WHERE animalid = ?', {animalid}, function(result)
        if not result or #result == 0 then
            cb({status = 'error', message = locale('sv_breed_animal_not_found')})
            return
        end
        
        local animal = result[1]
        local currentTime = os.time()
        local animalAge = animal.age or math.floor((currentTime - (animal.born or currentTime)) / (24 * 60 * 60))
        
        if Config.Debug then
            print('^3[BREEDING DEBUG]^7 Breeding status check for animal ' .. animalid .. ' - Age: ' .. animalAge .. ', Gender: ' .. tostring(animal.gender))
        end
        
        -- Check if breeding is enabled
        if not Config.BreedingEnabled then
            cb({status = 'disabled', message = locale('sv_breed_disabled')})
            return
        end
        
        -- Check pregnancy status
        local isPregnant = (animal.pregnant == 1 or animal.pregnant == true or animal.pregnant == 'true')
        if isPregnant then
            cb({status = 'pregnant', message = locale('sv_breed_is_pregnant')})
            return
        end
        
        -- Check age requirements
        if Config.MinAgeForBreeding and animalAge < Config.MinAgeForBreeding then
            cb({status = 'too_young', message = locale('sv_breed_too_young'):format(Config.MinAgeForBreeding, animalAge)})
            return
        end
        
        if Config.MaxBreedingAge and animalAge > Config.MaxBreedingAge then
            cb({status = 'too_old', message = locale('sv_breed_too_old'):format(Config.MaxBreedingAge, animalAge)})
            return
        end
        
        -- Check health requirements
        local healthReq = Config.RequireHealthForBreeding or 70
        local hungerReq = Config.RequireHungerForBreeding or 50
        local thirstReq = Config.RequireThirstForBreeding or 50
        
        if (animal.health or 100) < healthReq or (animal.hunger or 100) < hungerReq or (animal.thirst or 100) < thirstReq then
            local issues = {}
            if (animal.health or 100) < healthReq then table.insert(issues, locale('sv_breed_health_low')) end
            if (animal.hunger or 100) < hungerReq then table.insert(issues, locale('sv_breed_hunger_low')) end
            if (animal.thirst or 100) < thirstReq then table.insert(issues, locale('sv_breed_thirst_low')) end
            
            cb({status = 'requirements_not_met', message = locale('sv_breed_requirements'):format(table.concat(issues, ', '))})
            return
        end
        
        -- Check breeding cooldown
        if animal.breeding_ready_time and animal.breeding_ready_time > currentTime then
            local timeRemaining = animal.breeding_ready_time - currentTime
            local hoursRemaining = math.ceil(timeRemaining / 3600)
            cb({
                status = 'cooldown', 
                message = locale('sv_breed_cooldown'):format(hoursRemaining),
                timeRemaining = timeRemaining
            })
            return
        end
        
        -- Check if male and there are already pregnant females in the ranch (if enabled)
        if animal.gender == 'male' and Config.RestrictMaleBreedingWhenFemalesPregnant then
            -- Get ranch ID from the animal
            MySQL.query('SELECT ranchid FROM rsg_ranch_animals WHERE animalid = ?', {animalid}, function(ranchResult)
                if ranchResult and #ranchResult > 0 then
                    local ranchid = ranchResult[1].ranchid
                    
                    -- Check for pregnant females in the same ranch
                    MySQL.query('SELECT COUNT(*) as pregnant_count FROM rsg_ranch_animals WHERE ranchid = ? AND gender = ? AND pregnant = 1', 
                                {ranchid, 'female'}, function(pregnantResult)
                        if pregnantResult and #pregnantResult > 0 and pregnantResult[1].pregnant_count > 0 then
                            cb({
                                status = 'restricted', 
                                message = locale('sv_breed_restricted'):format(pregnantResult[1].pregnant_count)
                            })
                            return
                        else
                            -- Animal is ready to breed
                            cb({status = 'ready', message = locale('sv_breed_ready')})
                            return
                        end
                    end)
                else
                    -- Animal is ready to breed (fallback if ranch not found)
                    cb({status = 'ready', message = locale('sv_breed_ready')})
                    return
                end
            end)
        else
            -- Female animals don't have this restriction
            cb({status = 'ready', message = locale('sv_breed_ready')})
        end
    end)
end)

---------------------------------------------
-- Get pregnancy progress
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getPregnancyProgress', function(src, cb, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not animalid or not isPlayerRanchStaff(Player) then 
        cb({isPregnant = false})
        return 
    end
    
    MySQL.query('SELECT pregnant, gestation_end_time, born, model FROM rsg_ranch_animals WHERE animalid = ?', {animalid}, function(result)
        if not result or #result == 0 then
            cb({isPregnant = false})
            return
        end
        
        local animal = result[1]
        
        -- Check if animal is actually pregnant
        if not (animal.pregnant == 1 or animal.pregnant == true) or not animal.gestation_end_time then
            cb({isPregnant = false})
            return
        end
        
        local currentTime = os.time()
        local gestationEndTime = animal.gestation_end_time
        
        -- Get gestation period from config
        local breedingConfig = Config.BreedingConfig[animal.model]
        if not breedingConfig then
            cb({isPregnant = false})
            return
        end
        
        local gestationPeriod = breedingConfig.gestationPeriod
        local gestationStartTime = gestationEndTime - gestationPeriod
        
        -- Calculate progress
        local timeElapsed = currentTime - gestationStartTime
        local progressPercent = math.max(0, math.min(100, (timeElapsed / gestationPeriod) * 100))
        
        -- Calculate time remaining
        local timeRemaining = gestationEndTime - currentTime
        local description = ''
        
        if timeRemaining > 0 then
            local hoursRemaining = math.floor(timeRemaining / 3600)
            local daysRemaining = math.floor(hoursRemaining / 24)
            local remainingHours = hoursRemaining % 24
            
            if daysRemaining > 0 then
                description = locale('sv_server_description_132'):format(daysRemaining, remainingHours, math.floor(progressPercent))
            else
                description = locale('sv_server_description_133'):format(hoursRemaining, math.floor(progressPercent))
            end
        else
            description = locale('sv_server_description_134')
            progressPercent = 100
        end
        
        cb({
            isPregnant = true,
            progressPercent = progressPercent,
            description = description,
            timeRemaining = timeRemaining,
            daysRemaining = math.floor(timeRemaining / (24 * 3600)),
            hoursRemaining = math.floor(timeRemaining / 3600)
        })
    end)
end)

---------------------------------------------
-- Get available animals for breeding
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getAvailableAnimalsForBreeding', function(src, cb, ranchid, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not ranchid or not animalid or not isPlayerRanchStaff(Player) then 
        cb(false)
        return 
    end
    
    -- Get the animal we want to breed
    MySQL.query('SELECT model, gender, age, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ? AND ranchid = ?', {animalid, ranchid}, function(mainResult)
        if not mainResult or #mainResult == 0 then
            cb(false)
            return
        end
        
        local mainAnimal = mainResult[1]
        local targetGender = mainAnimal.gender == 'male' and 'female' or 'male'

        -- Declared as a local function *before* it's called below, otherwise the female
        -- branch (which calls it immediately/synchronously) would try to call a nil value
        local function findBreedingPartners()
            -- Find compatible animals of opposite gender
            MySQL.query('SELECT animalid, model, gender, age, health, hunger, thirst, pregnant, breeding_ready_time, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE ranchid = ? AND gender = ? AND animalid != ?', 
                        {ranchid, targetGender, animalid}, function(result)
                if not result or #result == 0 then
                    cb({})
                    return
                end
                
                local availableAnimals = {}
                local currentTime = os.time()
                
                for _, animal in ipairs(result) do
                    -- Skip animals that aren't the same species (e.g. don't offer a pig
                    -- as a breeding partner for a cow just because it's the opposite gender)
                    if IsSameSpecies(mainAnimal.model, animal.model) then
                        local canBreed = true
                        local breedingIssue = ''
                    
                        -- Check pregnancy
                        if animal.pregnant == 1 then
                            canBreed = false
                            breedingIssue = locale('cl_pregnant')
                        end
                    
                        -- Check breeding cooldown
                        if canBreed and animal.breeding_ready_time and animal.breeding_ready_time > currentTime then
                            canBreed = false
                            local hoursRemaining = math.ceil((animal.breeding_ready_time - currentTime) / 3600)
                            breedingIssue = locale('sv_issue_cooldown'):format(hoursRemaining)
                        end
                    
                        -- Check age requirements
                        if canBreed then
                            local animalAge = animal.age or 0
                            if Config.MinAgeForBreeding and animalAge < Config.MinAgeForBreeding then
                                canBreed = false
                                breedingIssue = locale('sv_issue_too_young')
                            elseif Config.MaxBreedingAge and animalAge > Config.MaxBreedingAge then
                                canBreed = false
                                breedingIssue = locale('sv_issue_too_old')
                            end
                        end
                    
                        -- Check health/hunger/thirst requirements
                        if canBreed then
                            local healthReq = Config.RequireHealthForBreeding or 70
                            local hungerReq = Config.RequireHungerForBreeding or 50
                            local thirstReq = Config.RequireThirstForBreeding or 50
                        
                            if (animal.health or 100) < healthReq or (animal.hunger or 100) < hungerReq or (animal.thirst or 100) < thirstReq then
                                canBreed = false
                                breedingIssue = locale('sv_issue_poor_condition')
                            end
                        end
                    
                        -- Calculate real distance between this animal and the animal being bred
                        local distance = 0
                        if animal.pos_x and animal.pos_y and animal.pos_z and mainAnimal.pos_x and mainAnimal.pos_y and mainAnimal.pos_z then
                            local mainVec = vector3(mainAnimal.pos_x, mainAnimal.pos_y, mainAnimal.pos_z)
                            local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
                            distance = math.floor(#(mainVec - animalVec))
                        end
                    
                        table.insert(availableAnimals, {
                            animalid = animal.animalid,
                            gender = animal.gender,
                            age = animal.age or 0,
                            health = animal.health or 100,
                            canBreed = canBreed,
                            breedingIssue = breedingIssue,
                            distance = distance
                        })
                    end
                end
                
                cb(availableAnimals)
            end)
        end

        -- Check if the main animal is male and there are already pregnant females (if enabled)
        if mainAnimal.gender == 'male' and Config.RestrictMaleBreedingWhenFemalesPregnant then
            MySQL.query('SELECT COUNT(*) as pregnant_count FROM rsg_ranch_animals WHERE ranchid = ? AND gender = ? AND pregnant = 1',
                        {ranchid, 'female'}, function(pregnantCheck)
                if pregnantCheck and #pregnantCheck > 0 and pregnantCheck[1].pregnant_count > 0 then
                    -- Return empty list - male cannot breed when females are already pregnant
                    cb({})
                    return
                end

                -- Continue with normal breeding partner search
                findBreedingPartners()
            end)
        else
            -- Female animals can breed normally
            findBreedingPartners()
        end
    end)
end)

---------------------------------------------
-- get nearby animals for sale
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getNearbyAnimalsForSale', function(src, cb, ranchid, salePointCoords)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or ranchid ~= Player.PlayerData.job.name or not isPlayerRanchStaff(Player) then
        cb({})
        return
    end

    -- Use the sale point the player is actually standing at, not client coords
    local salePoint = FindNearestSalePoint(GetEntityCoords(GetPlayerPed(src)), Config.SalePointInteractionDistance + 5.0)
    if not salePoint then
        cb({})
        return
    end
    salePointCoords = salePoint.coords

    -- Get all animals from this ranch that are old enough to sell
    local success, result = pcall(function()
        return MySQL.query.await(
            'SELECT animalid, model, gender, age, health, hunger, thirst, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE ranchid = ? AND age >= ?',
            { ranchid, Config.MinAgeToSell }
        )
    end)
    
    if not success or not result then
        cb({})
        return
    end
    
    local animals = {}
    local salePointVec = vector3(salePointCoords.x, salePointCoords.y, salePointCoords.z)
    
    for _, animal in ipairs(result) do
        -- Calculate sale price based on age
        local salePrice, ageCategory = CalculateAnimalSalePrice(animal.model, animal.age)

        -- Check if animal is nearby
        local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
        local distance = #(salePointVec - animalVec)
        local isNearby = distance <= Config.AnimalSaleDistance
        
        table.insert(animals, {
            animalid = animal.animalid,
            model = animal.model,
            gender = animal.gender,
            age = animal.age,
            ageCategory = ageCategory,
            health = animal.health,
            hunger = animal.hunger,
            thirst = animal.thirst,
            salePrice = salePrice,
            distance = math.floor(distance),
            isNearby = isNearby
        })
    end
    
    cb(animals)
end)

---------------------------------------------
-- sell single animal
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:sellAnimal', function(animalid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_135')})
        return
    end

    -- Verify player is ranch staff
    if not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_136')})
        return
    end
    if not RanchCan(Player, 'canSell') then return DenyPermission(src) end

    if not animalid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_137')})
        return
    end

    -- Get animal data from database
    local animalResult = MySQL.query.await('SELECT animalid, ranchid, age, model, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ?', {animalid})

    if not animalResult or #animalResult == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_138')})
        if Config.Debug then
            print('^1[SELL ANIMAL ERROR]^7 Animal ' .. animalid .. ' not found in database')
        end
        return
    end

    local animal = animalResult[1]

    -- Verify the animal actually belongs to the ranch the player works for
    if animal.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_139')})
        if Config.Debug then
            print('^1[SELL ANIMAL EXPLOIT?]^7 Player ' .. src .. ' (' .. Player.PlayerData.job.name .. ') tried to sell animal ' .. animalid .. ' belonging to ranch ' .. tostring(animal.ranchid))
        end
        return
    end

    -- Verify animal is old enough to sell
    if animal.age < Config.MinAgeToSell then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = locale('sv_server_description_140'):format(Config.MinAgeToSell)
        })
        return
    end

    -- Verify the player is actually standing at a sale point (never trust client-supplied coords)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local salePoint = FindNearestSalePoint(playerCoords, Config.SalePointInteractionDistance)
    if not salePoint then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_141')})
        return
    end

    -- Verify proximity of the animal itself if required
    if Config.RequireAnimalPresent then
        local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
        local distance = #(salePoint.coords - animalVec)
        if distance > Config.AnimalSaleDistance then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_142')})
            return
        end
    end

    -- Recompute the sale price server-side - never trust a client-supplied price
    local salePrice = CalculateAnimalSalePrice(animal.model, animal.age)

    -- Delete animal from database
    local deleteSuccess, deleteError = pcall(function()
        return MySQL.update.await('DELETE FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
    end)
    
    if not deleteSuccess or not deleteError or deleteError == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_143')})
        if Config.Debug then
            print('^1[SELL ANIMAL ERROR]^7 Failed to delete animal ' .. animalid .. ' from database')
        end
        return
    end
    
    -- Give money to player
    Player.Functions.AddMoney('cash', salePrice, 'rsg-ranch-animal-sale')
    
    -- Notify player
    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = locale('sv_server_description_144'):format(AnimalLabelForModel(animal.model), salePrice)
    })
    
    -- Remove from clients and refresh
    TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, animalid)
    
    if Config.Debug then
        print('^2[SELL ANIMAL SUCCESS]^7 Player ' .. src .. ' sold animal ' .. animalid .. ' for $' .. salePrice)
    end
end)

---------------------------------------------
-- sell all animals
---------------------------------------------
local function HandleSellAllAnimals(src, animalIds)
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_145')})
        return
    end

    -- Verify player is ranch staff
    if not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_146')})
        return
    end
    if not RanchCan(Player, 'canSell') then return DenyPermission(src) end

    if type(animalIds) ~= 'table' or #animalIds == 0 or #animalIds > (Config.MaxRanchAnimals or 100) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_147')})
        return
    end

    -- Verify the player is actually standing at a sale point (never trust client-supplied coords)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local salePoint = FindNearestSalePoint(playerCoords, Config.SalePointInteractionDistance)
    if not salePoint then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_148')})
        return
    end

    local totalValue = 0
    local successCount = 0
    local failedAnimals = {}

    -- Process each animal - the client only ever sends animal ids, every other
    -- fact (ownership, age, price) is recomputed here from the database.
    for _, animalid in ipairs(animalIds) do
        local animalResult = MySQL.query.await('SELECT animalid, ranchid, age, model, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid = ?', {animalid})

        if animalResult and #animalResult > 0 then
            local dbAnimal = animalResult[1]
            local animalVec = vector3(dbAnimal.pos_x, dbAnimal.pos_y, dbAnimal.pos_z)
            local isPresent = not Config.RequireAnimalPresent or (#(salePoint.coords - animalVec) <= Config.AnimalSaleDistance)

            -- Verify ownership, age, and physical presence at the sale point
            if dbAnimal.ranchid == Player.PlayerData.job.name and dbAnimal.age >= Config.MinAgeToSell and isPresent then
                local deleteSuccess, deleteError = pcall(function()
                    return MySQL.update.await('DELETE FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
                end)

                if deleteSuccess and deleteError and deleteError > 0 then
                    totalValue = totalValue + CalculateAnimalSalePrice(dbAnimal.model, dbAnimal.age)
                    successCount = successCount + 1
                    TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, animalid)
                else
                    table.insert(failedAnimals, animalid)
                end
            else
                table.insert(failedAnimals, animalid)
            end
        else
            table.insert(failedAnimals, animalid)
        end
    end

    -- Give total money to player
    if totalValue > 0 then
        Player.Functions.AddMoney('cash', totalValue, 'rsg-ranch-animal-sale')
    end
    
    -- Notify player
    if successCount == #animalIds then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'success',
            description = locale('sv_server_description_149'):format(successCount, totalValue)
        })
    elseif successCount > 0 then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'warning',
            description = locale('sv_server_description_150'):format(successCount, #animalIds, totalValue)
        })
    else
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = locale('sv_server_description_151')
        })
    end
    
    
    if Config.Debug then
        print('^2[SELL ANIMALS SUCCESS]^7 Player ' .. src .. ' sold ' .. successCount .. ' animals for $' .. totalValue)
        if #failedAnimals > 0 then
            print('^3[SELL ANIMALS WARNING]^7 Failed to sell ' .. #failedAnimals .. ' animals')
        end
    end
end

RegisterNetEvent('rsg-ranch:server:sellAllAnimals', function(animalIds)
    local src = source
    if not RanchWithLock('sellall:' .. tostring(src), function() HandleSellAllAnimals(src, animalIds) end) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
    end
end)

---------------------------------------------
-- buy animal system
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:buyAnimal', function(purchaseData)
    local src = source

    -- Reject a re-fire while a purchase for this player is still being processed.
    -- Without this, spam-firing the event lets several requests race through the
    -- checks below on the same starting balance before any of them actually
    -- deducts money (classic time-of-check/time-of-use dupe).
    if BuyAnimalLocks[src] then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
        return
    end
    BuyAnimalLocks[src] = true

    local ok, handlerError = pcall(function()
        local Player = RSGCore.Functions.GetPlayer(src)

        if not Player then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_153')})
            return
        end

        -- Verify player is ranch staff
        if not isPlayerRanchStaff(Player) then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_154')})
            return
        end
        if not RanchCan(Player, 'canBuy') then return DenyPermission(src) end

        -- Validate purchase data
        if not purchaseData or not purchaseData.animalType or not purchaseData.ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_155')})
            if Config.Debug then
                print('^1[BUY ANIMAL ERROR]^7 Invalid purchase data from player ' .. src)
            end
            return
        end

        -- A player can only buy animals for the ranch they actually work for
        if purchaseData.ranchid ~= Player.PlayerData.job.name then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_156')})
            return
        end

        -- Verify the player is actually standing at a buy point (never trust client-supplied coords)
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local buyPoint = FindNearestBuyPoint(playerCoords, Config.BuyPointInteractionDistance)
        if not buyPoint then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_157')})
            return
        end

        -- Recompute the purchase price server-side - never trust a client-supplied price
        local price = CalculateAnimalBuyPrice(purchaseData.animalType)
        if not price then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_158')})
            return
        end

        -- Only trust the delivery flag as a boolean; the actual surcharge amount is always
        -- read from the server-side config, never from the client
        local wantsDelivery = purchaseData.delivery == true
        local ranchLocationData = nil

        -- Some animal types (e.g. pigs, sheep) have no pickup option at all - delivery is
        -- mandatory and is enforced here server-side regardless of what the client sent.
        if purchaseData.animalType == 'a_c_pig_01' and Config.PigDeliveryOnly then
            wantsDelivery = true
        end
        if purchaseData.animalType == 'a_c_sheep_01' and Config.SheepDeliveryOnly then
            wantsDelivery = true
        end

        if wantsDelivery then
            ranchLocationData = GetRanchLocationData(purchaseData.ranchid)
            if not ranchLocationData or not ranchLocationData.spawnpoint then
                TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_159')})
                return
            end
            price = price + (Config.LivestockDeliveryPrice or 0)
        end

        purchaseData.price = price

        -- Cheap early rejection with a friendly message. This is NOT the source of truth -
        -- Player.Functions.RemoveMoney below re-checks and deducts atomically, since this
        -- read can go stale across the awaited queries further down.
        local playerMoney = Player.PlayerData.money.cash
        if playerMoney < purchaseData.price then
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'error',
                description = locale('sv_server_description_160'):format(purchaseData.price, playerMoney)
            })
            return
        end

        -- Check animal count for the ranch
        local countResult = MySQL.query.await('SELECT COUNT(*) as count FROM rsg_ranch_animals WHERE ranchid = ?', {purchaseData.ranchid})
        if not countResult or not countResult[1] then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_161')})
            if Config.Debug then
                print('^1[BUY ANIMAL ERROR]^7 Failed to count animals for ranch ' .. purchaseData.ranchid)
            end
            return
        end

        local currentCount = countResult[1].count or 0
        if currentCount >= Config.MaxRanchAnimals then
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'error',
                description = locale('sv_server_description_162'):format(Config.MaxRanchAnimals)
            })
            return
        end

        -- Create unique animal ID
        local animalid = CreateAnimalId()
        if not animalid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_163')})
            if Config.Debug then
                print('^1[BUY ANIMAL ERROR]^7 Failed to create unique animal ID for player ' .. src)
            end
            return
        end

        -- Determine gender. For pig/sheep purchases the player picks the gender client-side;
        -- we just validate it here rather than trusting it blindly. Every other animal
        -- type keeps the existing randomized-by-config behavior.
        local gender = 'female'
        if purchaseData.animalType == 'a_c_pig_01' and Config.PigChooseGenderOnBuy and
           (purchaseData.gender == 'male' or purchaseData.gender == 'female') then
            gender = purchaseData.gender
        elseif purchaseData.animalType == 'a_c_sheep_01' and Config.SheepChooseGenderOnBuy and
           (purchaseData.gender == 'male' or purchaseData.gender == 'female') then
            gender = purchaseData.gender
        elseif Config.GenderRatios and Config.GenderRatios[purchaseData.animalType] then
            local maleChance = Config.GenderRatios[purchaseData.animalType]
            gender = (math.random() < maleChance) and 'male' or 'female'
        end

        -- Get spawn point for the animal - always use a server-verified location, never a
        -- client-supplied one, to prevent spawning animals anywhere on the map.
        -- If the player paid for delivery, spawn at their ranch's configured spawnpoint;
        -- otherwise spawn at the buy point as normal, for the player to drive/herd home.
        local spawnPos
        if wantsDelivery and ranchLocationData then
            spawnPos = ranchLocationData.spawnpoint
        else
            spawnPos = buyPoint.spawnpoint or vector4(playerCoords.x, playerCoords.y, playerCoords.z, 0.0)
        end

        -- Deduct money now, atomically, immediately before committing the purchase to the
        -- database. RemoveMoney does its own check-and-subtract with no yield in between,
        -- so - combined with the per-player lock above - this is the actual point the sale
        -- becomes final; nothing between here and the insert below can race it.
        local moneyRemoved = Player.Functions.RemoveMoney('cash', purchaseData.price, 'rsg-ranch-buy-animal')
        if not moneyRemoved then
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'error',
                description = locale('sv_server_description_164'):format(purchaseData.price, Player.PlayerData.money.cash)
            })
            return
        end

        -- Current time for database
        local currentTime = os.time()

        -- Insert animal into database
        local success, insertResult = pcall(function()
            return MySQL.insert.await('INSERT INTO rsg_ranch_animals (animalid, ranchid, model, gender, age, health, hunger, thirst, pos_x, pos_y, pos_z, pos_w, pregnant, born) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
                animalid,
                purchaseData.ranchid,
                purchaseData.animalType,
                gender,
                0,  -- age starts at 0
                100,  -- health
                100,  -- hunger
                100,  -- thirst
                spawnPos.x,
                spawnPos.y,
                spawnPos.z,
                spawnPos.w or 0,
                0,  -- not pregnant
                currentTime  -- born timestamp
            })
        end)

        if not success or not insertResult or insertResult == 0 then
            -- The database insert failed after money was already taken - refund it
            -- rather than leaving the player out of pocket with nothing to show for it.
            Player.Functions.AddMoney('cash', purchaseData.price, 'rsg-ranch-buy-animal-refund')
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_165')})
            if Config.Debug then
                print('^1[BUY ANIMAL ERROR]^7 Database insert failed: ' .. tostring(insertResult))
            end
            return
        end

        -- Notify player of successful purchase
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'success',
            description = locale('sv_server_description_166'):format(AnimalLabelForModel(purchaseData.animalType), purchaseData.price, (wantsDelivery and locale('sv_server_delivered_suffix') or '!'))
        })

        if Config.ServerNotify then
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'inform',
                description = locale('sv_server_description_167'):format(buyPoint.blipname or locale('sv_server_livestock_dealer'))
            })
        end

        -- Push just the new animal to every client (merged into their caches)
        local newAnimalData = MySQL.query.await('SELECT * FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
        if newAnimalData and newAnimalData[1] then
            TriggerClientEvent('rsg-ranch:client:spawnAnimals', -1, {newAnimalData[1]}, false)
        end

        if Config.Debug then
            print('^2[BUY ANIMAL SUCCESS]^7 Player ' .. src .. ' purchased ' .. purchaseData.animalType .. ' (ID: ' .. animalid .. ') for $' .. purchaseData.price)
        end
    end)

    BuyAnimalLocks[src] = nil

    if not ok then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_168')})
        if Config.Debug then
            print('^1[BUY ANIMAL ERROR]^7 Unhandled error: ' .. tostring(handlerError))
        end
    end
end)

---------------------------------------------
-- ranch purchase system
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getranchowner', function(source, cb, ranchid)
    cb(RanchOwners[ranchid])
end)

---------------------------------------------
-- Ranch sell-back quote. Within Config.RanchSellGracePeriodHours of buying the
-- ranch the owner gets Config.RanchSellGraceRefundPercentage (100%) back; after
-- that it's Config.RanchSellRefundPercentage (80%). purchased_at = 0 (transferred
-- or legacy-migrated ranches) never qualifies for the cooling-off refund.
-- Returns refund, percentage (0-1), seconds of cooling-off remaining.
---------------------------------------------
local function GetRanchSellQuote(ranchid, price)
    local row = MySQL.single.await('SELECT purchased_at FROM rsg_ranch_owners WHERE ranchid = ?', {ranchid})
    local purchasedAt = row and tonumber(row.purchased_at) or 0
    local graceSeconds = math.floor((Config.RanchSellGracePeriodHours or 24) * 3600)
    local graceLeft = 0
    if purchasedAt > 0 and graceSeconds > 0 then
        graceLeft = math.max(0, (purchasedAt + graceSeconds) - os.time())
    end
    local pct = graceLeft > 0 and (Config.RanchSellGraceRefundPercentage or 1.0) or (Config.RanchSellRefundPercentage or 0.8)
    -- clamp to 0-1 so a config typo (e.g. 80 instead of 0.8) can never pay out more than the buy price
    pct = math.max(0.0, math.min(1.0, tonumber(pct) or 0.0))
    return math.floor(price * pct), pct, graceLeft
end

RSGCore.Functions.CreateCallback('rsg-ranch:server:getRanchSellQuote', function(source, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player or type(ranchid) ~= 'string' or RanchOwners[ranchid] ~= Player.PlayerData.citizenid then return cb(nil) end
    local price
    for _, r in pairs(Config.RanchLocations) do
        if r.ranchid == ranchid then price = r.price break end
    end
    if not price then return cb(nil) end
    local refund, pct, graceLeft = GetRanchSellQuote(ranchid, price)
    cb({ refund = refund, pct = math.floor(pct * 100 + 0.5), graceLeft = graceLeft })
end)

local function HandlePurchaseRanch(src, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_169')})
        return
    end

    if type(ranchid) ~= 'string' then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_170')})
        return
    end

    -- Look up the ranch server-side - never trust anything else the client sent
    local ranchData = nil
    for _, r in pairs(Config.RanchLocations) do
        if r.ranchid == ranchid then
            ranchData = r
            break
        end
    end

    if not ranchData then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_171')})
        return
    end

    -- Anyone can buy an unowned ranch and become its boss - SetJob below
    -- assigns them the ranch's job role as part of the purchase, so we only
    -- need to guard against someone who is already this ranch's boss buying
    -- it again.
    if Player.PlayerData.job.name == ranchData.jobaccess and Player.PlayerData.job.grade.level >= Config.RanchBossGrade then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_172')})
        return
    end

    if RanchOwners[ranchid] then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_173')})
        return
    end

    -- One ranch per character - buying a second one would silently replace the
    -- job for the first and leave it owned but unmanageable
    for _, ownerCid in pairs(RanchOwners) do
        if ownerCid == Player.PlayerData.citizenid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_already_own_ranch')})
            return
        end
    end

    -- Verify the player is actually standing at the ranch (never trust client-supplied coords)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local npcCoords = vector3(ranchData.npccoords.x, ranchData.npccoords.y, ranchData.npccoords.z)
    if #(playerCoords - npcCoords) > Config.RanchPurchaseDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_174')})
        return
    end

    -- Recompute price server-side - never trust a client-supplied price
    local price = ranchData.price
    if not price then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_175')})
        return
    end

    local playerMoney = Player.PlayerData.money.cash
    if playerMoney < price then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = locale('sv_server_description_176'):format(price, playerMoney)
        })
        return
    end

    -- Re-check for a race between two players buying at the same instant
    if RanchOwners[ranchid] then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_177')})
        return
    end

    -- Deduct money now, atomically, and check it actually succeeded before granting
    -- the ranch - the balance check above can go stale across the awaited
    -- queries here, so this is the real point of no return.
    -- Register the ranch job with rsg-multijob first; it refuses if the player
    -- already holds the maximum number of jobs.
    local jobAdded, jobReason = MultijobAddJob(Player.PlayerData.citizenid, ranchid, Config.RanchBossGrade)
    if not jobAdded then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_213')})
        if Config.Debug then print('^1[RANCH PURCHASE]^7 multijob AddJob refused: ' .. tostring(jobReason)) end
        return
    end

    local moneyRemoved = Player.Functions.RemoveMoney('cash', price, 'rsg-ranch-purchase')
    if not moneyRemoved then
        MultijobRemoveJob(Player.PlayerData.citizenid, ranchid)
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = locale('sv_server_description_178'):format(price, Player.PlayerData.money.cash)
        })
        return
    end

    local success, dbError = pcall(function()
        return MySQL.insert.await('INSERT INTO rsg_ranch_owners (ranchid, citizenid, purchased_at) VALUES (?, ?, ?)', {
            ranchid,
            Player.PlayerData.citizenid,
            os.time()
        })
    end)

    if not success then
        -- The database insert failed after money was already taken - refund it
        Player.Functions.AddMoney('cash', price, 'rsg-ranch-purchase-refund')
        MultijobRemoveJob(Player.PlayerData.citizenid, ranchid)
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_179')})
        if Config.Debug then
            print('^1[RANCH PURCHASE ERROR]^7 Database insert failed: ' .. tostring(dbError))
        end
        return
    end

    -- Mark as owned immediately so a second purchase attempt can't slip through
    RanchOwners[ranchid] = Player.PlayerData.citizenid

    Player.Functions.SetJob(ranchid, Config.RanchBossGrade)

    EnsureGeneralStorage(ranchid)

    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = locale('sv_server_description_180'):format(ranchData.name, price)
    })

    if Config.ServerNotify then
        TriggerClientEvent('ox_lib:notify', -1, {
            type = 'inform',
            description = locale('sv_server_description_181'):format(ranchData.name)
        })
    end

    if Config.Debug then
        print('^2[RANCH PURCHASE SUCCESS]^7 Player ' .. src .. ' (' .. Player.PlayerData.citizenid .. ') purchased ' .. ranchid .. ' for $' .. price)
    end
end

RegisterNetEvent('rsg-ranch:server:purchaseRanch', function(ranchid)
    local src = source
    if not RanchWithLock('ranch:' .. tostring(ranchid), function() HandlePurchaseRanch(src, ranchid) end) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
    end
end)

---------------------------------------------
-- transfer ranch ownership to another player
---------------------------------------------
local function HandleTransferRanch(src, ranchid, targetId)
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_182')})
        return
    end

    if type(ranchid) ~= 'string' then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_183')})
        return
    end

    -- Look up the ranch server-side - never trust anything else the client sent
    local ranchData = nil
    for _, r in pairs(Config.RanchLocations) do
        if r.ranchid == ranchid then
            ranchData = r
            break
        end
    end

    if not ranchData then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_184')})
        return
    end

    -- Must be the current boss of this ranch
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.RanchBossGrade then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_185')})
        return
    end

    if RanchOwners[ranchid] ~= Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_186')})
        return
    end

    targetId = tonumber(targetId)
    local Target = targetId and RSGCore.Functions.GetPlayer(targetId)
    if not Target then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_187')})
        return
    end

    if Target.PlayerData.citizenid == Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_188')})
        return
    end

    -- Never trust client-supplied distance - the target must actually be near the current owner
    local ownerPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)
    if not ownerPed or not targetPed or ownerPed == 0 or targetPed == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_189')})
        return
    end

    local ownerCoords = GetEntityCoords(ownerPed)
    local targetCoords = GetEntityCoords(targetPed)
    if #(ownerCoords - targetCoords) > Config.RanchTransferDistance then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_190')})
        return
    end

    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    for _, ownerCid in pairs(RanchOwners) do
        if ownerCid == Target.PlayerData.citizenid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_target_owns_ranch')})
            return
        end
    end

    -- The new owner has to agree - ownership (and a job) was previously forced on them
    TriggerClientEvent('ox_lib:notify', src, {type = 'inform', description = locale('sv_waiting_for_answer')})
    if not RequestConsent(targetId, ranchData.name, locale('sv_transfer_offer'):format(Player.PlayerData.charinfo.firstname, Player.PlayerData.charinfo.lastname, ranchData.name)) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_offer_declined')})
        return
    end

    -- things may have changed while we waited for an answer
    if RanchOwners[ranchid] ~= Player.PlayerData.citizenid or not RSGCore.Functions.GetPlayer(targetId) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_192')})
        return
    end

    -- Give the new owner the job in rsg-multijob (refused if they're at their job limit)
    local targetHadJob = Target.PlayerData.job.name == ranchid
    local jobAdded, jobReason = MultijobAddJob(Target.PlayerData.citizenid, ranchid, Config.RanchBossGrade)
    if not jobAdded then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_191')})
        if Config.Debug then print('^1[RANCH TRANSFER]^7 multijob AddJob refused: ' .. tostring(jobReason)) end
        return
    end

    local success, dbError = pcall(function()
        -- purchased_at = 0: a transferred ranch wasn't paid for by the new owner,
        -- so it never qualifies for the cooling-off (full) refund when sold
        return MySQL.update.await('UPDATE rsg_ranch_owners SET citizenid = ?, purchased_at = 0 WHERE ranchid = ?', {
            Target.PlayerData.citizenid, ranchid
        })
    end)

    if not success then
        if not targetHadJob then MultijobRemoveJob(Target.PlayerData.citizenid, ranchid) end
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_192')})
        if Config.Debug then
            print('^1[RANCH TRANSFER ERROR]^7 Database update failed: ' .. tostring(dbError))
        end
        return
    end

    RanchOwners[ranchid] = Target.PlayerData.citizenid

    -- Move the job across: drop it from the old owner (and their multijob record),
    -- then hand it to the new owner at boss grade
    MultijobRemoveJob(Player.PlayerData.citizenid, ranchid)
    Player.Functions.SetJob('unemployed', 0)
    Target.Functions.SetJob(ranchid, Config.RanchBossGrade)

    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = locale('sv_server_description_193'):format(ranchData.name, Target.PlayerData.charinfo.firstname, Target.PlayerData.charinfo.lastname)
    })
    TriggerClientEvent('ox_lib:notify', targetId, {
        type = 'success',
        description = locale('sv_server_description_194'):format(ranchData.name)
    })

    if Config.ServerNotify then
        TriggerClientEvent('ox_lib:notify', -1, {
            type = 'inform',
            description = locale('sv_server_description_195'):format(ranchData.name)
        })
    end

    if Config.Debug then
        print('^2[RANCH TRANSFER]^7 ' .. ranchid .. ' transferred from ' .. Player.PlayerData.citizenid .. ' to ' .. Target.PlayerData.citizenid)
    end
end

RegisterNetEvent('rsg-ranch:server:transferRanchOwnership', function(ranchid, targetId)
    local src = source
    if not RanchWithLock('ranch:' .. tostring(ranchid), function() HandleTransferRanch(src, ranchid, targetId) end) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
    end
end)

---------------------------------------------
-- sell a ranch outright - closes it down, fires all staff, refunds the
-- boss a percentage of the original purchase price, and makes the ranch
-- available for anyone to purchase again
---------------------------------------------
local function HandleSellRanch(src, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_196')})
        return
    end

    if type(ranchid) ~= 'string' then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_197')})
        return
    end

    -- Look up the ranch server-side - never trust anything else the client sent
    local ranchData = nil
    for _, r in pairs(Config.RanchLocations) do
        if r.ranchid == ranchid then
            ranchData = r
            break
        end
    end

    if not ranchData then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_198')})
        return
    end

    -- Must be the current boss of this ranch
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.RanchBossGrade then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_199')})
        return
    end

    if RanchOwners[ranchid] ~= Player.PlayerData.citizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_200')})
        return
    end

    -- Recompute the refund server-side - never trust a client-supplied amount
    local price = ranchData.price
    if not price then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_201')})
        return
    end

    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    -- 100% inside the cooling-off period after purchase, Config.RanchSellRefundPercentage after
    local refund, refundPercentage, graceLeft = GetRanchSellQuote(ranchid, price)

    -- Empty every storage first. Only the storage rows used to be deleted, so the
    -- stash contents stayed in rsg-inventory and reappeared for whoever bought
    -- the ranch next (including the seller buying it straight back).
    for _, storage in ipairs(GetRanchStorages(ranchid)) do
        pcall(function() exports['rsg-inventory']:ClearStash(storage.storageid) end)
    end

    -- Reset the ranch to default: grab the ids of everything placed/kept on it so
    -- clients can despawn them, then wipe livestock, props, orders, storages and ownership
    local removed = { animals = {}, feedtroughs = {}, watertroughs = {}, coops = {} }
    local success, dbError = pcall(function()
        removed.animals      = MySQL.query.await('SELECT animalid FROM rsg_ranch_animals WHERE ranchid = ?', {ranchid}) or {}
        removed.feedtroughs  = MySQL.query.await('SELECT feedtroughid FROM rsg_ranch_feedtroughs WHERE ranchid = ?', {ranchid}) or {}
        removed.watertroughs = MySQL.query.await('SELECT watertroughid FROM rsg_ranch_watertroughs WHERE ranchid = ?', {ranchid}) or {}
        removed.coops        = MySQL.query.await('SELECT coopid FROM rsg_ranch_chickencoops WHERE ranchid = ?', {ranchid}) or {}

        MySQL.query.await('DELETE FROM rsg_ranch_animals WHERE ranchid = ?', {ranchid})
        MySQL.query.await('DELETE FROM rsg_ranch_feedtroughs WHERE ranchid = ?', {ranchid})
        MySQL.query.await('DELETE FROM rsg_ranch_watertroughs WHERE ranchid = ?', {ranchid})
        MySQL.query.await('DELETE FROM rsg_ranch_chickencoops WHERE ranchid = ?', {ranchid})
        MySQL.query.await('DELETE FROM rsg_ranch_orders WHERE ranchid = ?', {ranchid})
        MySQL.query.await('DELETE FROM rsg_ranch_storages WHERE ranchid = ?', {ranchid})
        return MySQL.query.await('DELETE FROM rsg_ranch_owners WHERE ranchid = ?', {ranchid})
    end)

    if not success then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_202')})
        if Config.Debug then
            print('^1[RANCH SELL ERROR]^7 Database delete failed: ' .. tostring(dbError))
        end
        return
    end

    -- Mark as unowned immediately so the ranch can be re-purchased right away
    RanchOwners[ranchid] = nil

    -- Despawn everything that was on the ranch for every client
    for _, r in ipairs(removed.animals) do TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, r.animalid) end
    for _, r in ipairs(removed.feedtroughs) do TriggerClientEvent('rsg-ranch:client:removeFeedTrough', -1, r.feedtroughid) end
    for _, r in ipairs(removed.watertroughs) do TriggerClientEvent('rsg-ranch:client:removeWaterTrough', -1, r.watertroughid) end
    for _, r in ipairs(removed.coops) do TriggerClientEvent('rsg-ranch:client:removeChickenCoop', -1, r.coopid) end

    -- Fire every member of staff, including the selling boss - the ranch is closing entirely
    FireAllRanchStaff(ranchid, nil)

    Player.Functions.AddMoney('cash', refund, 'rsg-ranch-sell')

    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = graceLeft > 0
            and locale('sv_sell_ranch_grace'):format(ranchData.name, refund, math.floor(refundPercentage * 100 + 0.5))
            or locale('sv_server_description_203'):format(ranchData.name, refund, math.floor(refundPercentage * 100 + 0.5))
    })

    if Config.ServerNotify then
        TriggerClientEvent('ox_lib:notify', -1, {
            type = 'inform',
            description = locale('sv_server_description_204'):format(ranchData.name)
        })
    end

    if Config.Debug then
        print('^2[RANCH SELL SUCCESS]^7 Player ' .. src .. ' (' .. Player.PlayerData.citizenid .. ') sold ' .. ranchid .. ' for $' .. refund)
    end
end

RegisterNetEvent('rsg-ranch:server:sellRanch', function(ranchid)
    local src = source
    if not RanchWithLock('ranch:' .. tostring(ranchid), function() HandleSellRanch(src, ranchid) end) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_152')})
    end
end)

---------------------------------------------
-- Helper function to start breeding between two animals
---------------------------------------------
local function StartBreeding(animal1id, animal2id, isAutomatic)
    local result = MySQL.query.await('SELECT animalid, model, gender, pregnant, breeding_ready_time, health, hunger, thirst, ranchid FROM rsg_ranch_animals WHERE animalid IN (?, ?)', {animal1id, animal2id})
    if not result or #result ~= 2 then return false, 'not_found' end

    local male, female
    if result[1].gender == 'male' and result[2].gender == 'female' then
        male, female = result[1], result[2]
    elseif result[1].gender == 'female' and result[2].gender == 'male' then
        male, female = result[2], result[1]
    else
        return false, 'gender'
    end

    if male.ranchid ~= female.ranchid then return false, 'ranch' end
    if not IsSameSpecies(male.model, female.model) then return false, 'species' end

    local currentTime = os.time()
    local healthReq = Config.RequireHealthForBreeding or 70
    local hungerReq = Config.RequireHungerForBreeding or 50
    local thirstReq = Config.RequireThirstForBreeding or 50

    if female.pregnant == 1 or female.pregnant == true then return false, 'pregnant' end

    for _, a in ipairs({male, female}) do
        if a.breeding_ready_time and a.breeding_ready_time > currentTime then return false, 'cooldown' end
        if (a.health or 100) < healthReq or (a.hunger or 100) < hungerReq or (a.thirst or 100) < thirstReq then
            return false, 'condition'
        end
    end

    local breedingConfig = Config.BreedingConfig[female.model]
    if not breedingConfig or not breedingConfig.enabled then return false, 'disabled' end

    local gestationEndTime = currentTime + breedingConfig.gestationPeriod
    local femaleCooldownTime = currentTime + GetBreedingCooldown('female')
    local maleCooldownTime = currentTime + GetBreedingCooldown('male')

    -- conditional on "not already pregnant" so two simultaneous requests can't both succeed
    local updated = MySQL.update.await('UPDATE rsg_ranch_animals SET pregnant = 1, gestation_end_time = ?, breeding_ready_time = ? WHERE animalid = ? AND pregnant = 0', {gestationEndTime, femaleCooldownTime, female.animalid})
    if not updated or updated <= 0 then return false, 'pregnant' end

    MySQL.update.await('UPDATE rsg_ranch_animals SET breeding_ready_time = ? WHERE animalid = ?', {maleCooldownTime, male.animalid})

    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, female.animalid, {pregnant = 1, gestation_end_time = gestationEndTime, breeding_ready_time = femaleCooldownTime})
    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, male.animalid, {breeding_ready_time = maleCooldownTime})

    if Config.Debug or (isAutomatic and Config.AutomaticBreedingNotifications) then
        print(('^2[RSG-RANCH BREEDING]^7 %s and %s bred at %s (%s), due in %d day(s)'):format(female.animalid, male.animalid, female.ranchid, isAutomatic and 'automatic' or 'manual', math.floor(breedingConfig.gestationPeriod / 86400)))
    end

    return true
end

---------------------------------------------
-- Start breeding process (manual trigger from players)
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:startBreeding', function(animal1id, animal2id)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_205')})
        return
    end
    if not RanchCan(Player, 'canBreed') then return DenyPermission(src) end

    if not animal1id or not animal2id or animal1id == animal2id then return end

    -- Verify both animals belong to the player's own ranch and the player is near both
    local pairResult = MySQL.query.await('SELECT animalid, ranchid, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE animalid IN (?, ?)', {animal1id, animal2id})
    if not pairResult or #pairResult ~= 2 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_206')})
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    for _, a in ipairs(pairResult) do
        if a.ranchid ~= Player.PlayerData.job.name then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_207')})
            return
        end
        local animalVec = vector3(a.pos_x, a.pos_y, a.pos_z)
        if #(playerCoords - animalVec) > Config.BreedingDistance then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_208')})
            return
        end
    end

    if Config.Debug then
        print('^3[BREEDING DEBUG]^7 Manual breeding request from player ' .. src .. ' for animals ' .. animal1id .. ' and ' .. animal2id)
    end

    local ok, reason = StartBreeding(animal1id, animal2id, false)
    if ok then
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_209')})
    else
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_breeding_failed_' .. reason)})
    end
end)

---------------------------------------------
-- Helper function to process breeding pairs
---------------------------------------------
local function ProcessBreedingPairs(males, females, maxDistance, ranchid)
    for _, male in ipairs(males) do
        for _, female in ipairs(females) do
            -- Only pair up animals of the same species
            if IsSameSpecies(male.model, female.model) then
            -- Check distance between animals
            local malePos = vector3(male.pos_x, male.pos_y, male.pos_z)
            local femalePos = vector3(female.pos_x, female.pos_y, female.pos_z)
            local distance = #(malePos - femalePos)
            
            if distance <= maxDistance then
                if Config.Debug then
                    print('^2[AUTO-BREEDING]^7 Found breeding pair at ranch ' .. ranchid .. ': Male ' .. male.animalid .. ' and Female ' .. female.animalid .. ' (distance: ' .. string.format('%.2f', distance) .. 'm)')
                end
                
                -- Start breeding for this pair
                -- one successful pairing per ranch per check
                if StartBreeding(male.animalid, female.animalid, true) then
                    return
                end
            end
            end
        end
    end
end

---------------------------------------------
-- automatic breeding system
---------------------------------------------
CreateThread(function()
    -- Wait for server to be fully loaded
    Wait(10000)
    
    if not Config.AutomaticBreedingEnabled then
        if Config.Debug then
            print('^3[AUTO-BREEDING]^7 Automatic breeding is disabled in config')
        end
        return
    end
    
    print('^2[RSG-RANCH]^7 Initializing automatic breeding system (check interval: ' .. Config.AutomaticBreedingCheckInterval .. 's, max distance: ' .. Config.AutomaticBreedingMaxDistance .. 'm)')
    
    -- Run automatic breeding checks
    while true do
        Wait(Config.AutomaticBreedingCheckInterval * 1000)
        
        if Config.Debug then
            print('^3[AUTO-BREEDING]^7 Running automatic breeding check at ' .. os.date('%Y-%m-%d %H:%M:%S'))
        end
        
        -- Get all animals that could potentially breed
        MySQL.query('SELECT animalid, model, gender, age, pregnant, breeding_ready_time, health, hunger, thirst, ranchid, pos_x, pos_y, pos_z, born FROM rsg_ranch_animals WHERE pregnant = 0', {}, function(animals)
            if not animals or #animals < 2 then
                if Config.Debug then
                    print('^3[AUTO-BREEDING]^7 Not enough animals for breeding (need at least 2 non-pregnant animals)')
                end
                return
            end
            
            local currentTime = os.time()
            local healthReq = Config.RequireHealthForBreeding or 70
            local hungerReq = Config.RequireHungerForBreeding or 50
            local thirstReq = Config.RequireThirstForBreeding or 50
            local minAge = Config.MinAgeForBreeding or 5
            local maxAge = Config.MaxBreedingAge or 30
            local maxDistance = Config.AutomaticBreedingMaxDistance or 5.0
            
            -- Separate animals by ranch and gender
            local ranchAnimals = {}
            
            for _, animal in ipairs(animals) do
                -- Calculate age
                local animalAge = animal.age or 0
                if animal.born and animal.born > 0 then
                    animalAge = math.floor((currentTime - animal.born) / (24 * 60 * 60))
                end
                
                -- Check if animal meets breeding requirements
                local isEligible = true
                
                -- Age check
                if animalAge < minAge or animalAge > maxAge then
                    isEligible = false
                end
                
                -- Cooldown check
                if animal.breeding_ready_time and animal.breeding_ready_time > currentTime then
                    isEligible = false
                end
                
                -- Health/hunger/thirst check
                if (animal.health or 100) < healthReq or (animal.hunger or 100) < hungerReq or (animal.thirst or 100) < thirstReq then
                    isEligible = false
                end
                
                -- Breeding config check
                local breedingConfig = Config.BreedingConfig[animal.model]
                if not breedingConfig or not breedingConfig.enabled then
                    isEligible = false
                end
                
                if isEligible then
                    if not ranchAnimals[animal.ranchid] then
                        ranchAnimals[animal.ranchid] = {males = {}, females = {}}
                    end
                    
                    if animal.gender == 'male' then
                        table.insert(ranchAnimals[animal.ranchid].males, animal)
                    elseif animal.gender == 'female' then
                        table.insert(ranchAnimals[animal.ranchid].females, animal)
                    end
                end
            end
            
            -- Check for breeding opportunities in each ranch
            local breedingPairs = 0
            
            for ranchid, genderGroups in pairs(ranchAnimals) do
                local males = genderGroups.males
                local females = genderGroups.females
                
                if Config.Debug then
                    print('^3[AUTO-BREEDING]^7 Ranch ' .. ranchid .. ' has ' .. #males .. ' eligible males and ' .. #females .. ' eligible females')
                end
                
                -- Check male restriction if enabled
                if Config.RestrictMaleBreedingWhenFemalesPregnant then
                    -- Check if there are any pregnant females in this ranch
                    local hasPregnantFemales = false
                    MySQL.query('SELECT COUNT(*) as count FROM rsg_ranch_animals WHERE ranchid = ? AND gender = ? AND pregnant = 1', 
                                {ranchid, 'female'}, function(pregnantResult)
                        if pregnantResult and #pregnantResult > 0 and pregnantResult[1].count > 0 then
                            hasPregnantFemales = true
                        end
                        
                        if hasPregnantFemales then
                            if Config.Debug then
                                print('^3[AUTO-BREEDING]^7 Ranch ' .. ranchid .. ' has pregnant females - males cannot breed')
                            end
                            return
                        end
                        
                        -- Try to find breeding pairs
                        ProcessBreedingPairs(males, females, maxDistance, ranchid)
                    end)
                else
                    -- No restriction, proceed with breeding
                    ProcessBreedingPairs(males, females, maxDistance, ranchid)
                end
            end
        end)
    end
end)

---------------------------------------------
-- animal cronjob
---------------------------------------------
-- Initialize cron job with better error handling
CreateThread(function()
    -- Wait for server to be fully loaded
    Wait(5000)
    
    if not lib or not lib.cron then
        print('^1[RSG-RANCH ERROR]^7 ox_lib cron not available! Make sure ox_lib is started before rsg-ranch.')
        return
    end
    
    print('^2[RSG-RANCH]^7 Initializing animal survival cronjob with schedule: ' .. Config.AnimalCronJob)
    
    lib.cron.new(Config.AnimalCronJob, function ()
        if Config.Debug then
            print('^2[RSG-RANCH CRON]^7 Starting animal update cycle at ' .. os.date('%Y-%m-%d %H:%M:%S'))
        end
        
        -- Run in separate thread to avoid blocking cron
        CreateThread(function()
            ProcessAnimalSurvival()
        end)
    end)
end)

---------------------------------------------
-- chicken coop feed cronjob
---------------------------------------------
---------------------------------------------
-- animal feed/water cronjob (trough consumption)
---------------------------------------------
-- Runs on its own schedule, separate from the main survival cronjob above, so
-- feed/water consumption speed can be tuned independently of health decay/regen,
-- breeding and production timing.
CreateThread(function()
    Wait(5500)

    if not lib or not lib.cron then
        print('^1[RSG-RANCH ERROR]^7 ox_lib cron not available! Make sure ox_lib is started before rsg-ranch.')
        return
    end

    print('^2[RSG-RANCH]^7 Initializing animal feed/water cronjob with schedule: ' .. (Config.AnimalFeedWaterCronJob or Config.AnimalCronJob))

    lib.cron.new(Config.AnimalFeedWaterCronJob or Config.AnimalCronJob, function ()
        if Config.Debug then
            print('^2[RSG-RANCH CRON]^7 Starting animal feed/water cycle at ' .. os.date('%Y-%m-%d %H:%M:%S'))
        end

        -- Run in separate thread to avoid blocking cron
        CreateThread(function()
            ProcessAnimalFeedWater()
        end)
    end)
end)

---------------------------------------------
-- chicken coop feed cronjob
---------------------------------------------
CreateThread(function()
    Wait(6000)

    if not lib or not lib.cron then
        print('^1[RSG-RANCH ERROR]^7 ox_lib cron not available! Make sure ox_lib is started before rsg-ranch.')
        return
    end

    print('^2[RSG-RANCH]^7 Initializing chicken coop feed cronjob with schedule: ' .. (Config.ChickenCoopFeedCronJob or Config.AnimalCronJob))

    lib.cron.new(Config.ChickenCoopFeedCronJob or Config.AnimalCronJob, function()
        if Config.Debug then
            print('^2[RSG-RANCH CRON]^7 Starting chicken coop feed check at ' .. os.date('%Y-%m-%d %H:%M:%S'))
        end

        CreateThread(function()
            ProcessChickenCoopFeed()
        end)
    end)
end)

---------------------------------------------
-- chicken coop feed decay/starvation processing
---------------------------------------------
function ProcessChickenCoopFeed()
    local success, cronError = pcall(function()
        MySQL.query('SELECT coopid, ranchid, chickens, eggs_stored, feed_level, last_feed_update FROM rsg_ranch_chickencoops WHERE chickens > 0', {}, function(coops)
            if not coops or #coops == 0 then
                if Config.Debug then
                    print('^3[CHICKENCOOP CRON]^7 No coops with chickens to check')
                end
                return
            end

            for _, coop in ipairs(coops) do
                local newFeedLevel, cycles, diedOut = RollChickenCoopFeedLevel(coop)

                if cycles > 0 then
                    if diedOut then
                        MySQL.update('UPDATE rsg_ranch_chickencoops SET chickens = 0, eggs_stored = 0, feed_level = 0, last_feed_update = ? WHERE coopid = ?', {os.time(), coop.coopid})
                        TriggerClientEvent('rsg-ranch:client:updateChickenCoop', -1, coop.coopid, 0)

                        if Config.ServerNotify then
                            TriggerClientEvent('ox_lib:notify', -1, {
                                type = 'error',
                                description = locale('sv_server_description_210'):format(coop.ranchid)
                            })
                        end

                        if Config.Debug then
                            print('^1[CHICKENCOOP CRON]^7 Coop ' .. coop.coopid .. ' (ranch ' .. coop.ranchid .. ') starved out - chickens removed')
                        end
                    else
                        MySQL.update('UPDATE rsg_ranch_chickencoops SET feed_level = ?, last_feed_update = ? WHERE coopid = ?', {newFeedLevel, os.time(), coop.coopid})

                        if Config.Debug then
                            print('^3[CHICKENCOOP CRON]^7 Coop ' .. coop.coopid .. ' feed level decayed to ' .. newFeedLevel .. '/' .. (Config.ChickenCoopMaxFeedLevel or 100))
                        end
                    end
                end
            end
        end)
    end)

    if not success then
        if Config.Debug then
            print('^1[CHICKENCOOP CRON ERROR]^7 ' .. tostring(cronError))
        end
    end
end

---------------------------------------------
-- Automatic ranch feeding/watering pools
--
-- Instead of animals walking to a trough and triggering a per-animal feed/drink
-- event, each ranch's feed/water troughs are pooled: as long as a ranch has any
-- uses left across its troughs, every animal on that ranch is fed/watered directly
-- in the survival cronjob below, consuming 1 use per animal per run from the pool.
---------------------------------------------
local function BuildRanchTroughPools()
    local feedPools = {} -- [ranchid] = { totalUses = n, troughs = { {id=.., uses=..}, ... } }
    local waterPools = {}

    local feedSuccess, feedRows = pcall(function()
        return MySQL.query.await('SELECT feedtroughid, ranchid, uses FROM rsg_ranch_feedtroughs WHERE uses > 0', {})
    end)
    if feedSuccess and feedRows then
        for _, row in ipairs(feedRows) do
            local pool = feedPools[row.ranchid]
            if not pool then
                pool = { totalUses = 0, troughs = {} }
                feedPools[row.ranchid] = pool
            end
            pool.totalUses = pool.totalUses + (row.uses or 0)
            table.insert(pool.troughs, { id = row.feedtroughid, uses = row.uses or 0 })
        end
    end

    local waterSuccess, waterRows = pcall(function()
        return MySQL.query.await('SELECT watertroughid, ranchid, uses FROM rsg_ranch_watertroughs WHERE uses > 0', {})
    end)
    if waterSuccess and waterRows then
        for _, row in ipairs(waterRows) do
            local pool = waterPools[row.ranchid]
            if not pool then
                pool = { totalUses = 0, troughs = {} }
                waterPools[row.ranchid] = pool
            end
            pool.totalUses = pool.totalUses + (row.uses or 0)
            table.insert(pool.troughs, { id = row.watertroughid, uses = row.uses or 0 })
        end
    end

    return feedPools, waterPools
end

-- Consumes up to `amount` uses from a ranch's pool, spending from its troughs in
-- order and marking each affected trough dirty so the caller can persist the new
-- counts afterwards. Returns how much was actually consumed (0 if the pool is empty).
local function ConsumePoolUses(pool, amount, dirtyTroughs)
    if not pool or amount <= 0 or pool.totalUses <= 0 then return 0 end

    local consumed = 0
    for _, trough in ipairs(pool.troughs) do
        if consumed >= amount then break end
        if trough.uses > 0 then
            local take = math.min(trough.uses, amount - consumed)
            trough.uses = trough.uses - take
            consumed = consumed + take
            dirtyTroughs[trough.id] = trough.uses
        end
    end

    pool.totalUses = pool.totalUses - consumed
    return consumed
end

---------------------------------------------
-- animal feed/water processing (trough consumption)
--
-- Split out from animal survival processing so feed/water consumption runs on
-- its own cronjob (Config.AnimalFeedWaterCronJob) and can be tuned without
-- touching health decay/regen, breeding or production timing.
---------------------------------------------
function ProcessAnimalFeedWater()
    local success, cronError = pcall(function()
        MySQL.query('SELECT animalid, hunger, thirst, ranchid FROM rsg_ranch_animals', {}, function(animals)
            if not animals or #animals == 0 then
                if Config.Debug then
                    print('^3[RSG-RANCH CRON]^7 No animals found in database or query returned empty (feed/water cycle)')
                end
                return
            end

            if Config.Debug then
                print('^2[RSG-RANCH CRON]^7 Feeding/watering ' .. #animals .. ' animals')
            end

            local feedPools, waterPools = BuildRanchTroughPools()
            local dirtyFeedTroughs, dirtyWaterTroughs = {}, {}
            local batchUpdates = {}

            for _, animal in ipairs(animals) do
                if not animal.animalid then
                    goto continue
                end

                -- Only draw from the trough pool once the animal actually needs it
                -- (hunger/thirst has dropped to/below its threshold), instead of every
                -- animal spending a use on every run regardless of how full it already is.
                local currentHunger = animal.hunger or 100
                local newHunger
                local feedPool = feedPools[animal.ranchid]
                if currentHunger <= Config.FeedTroughHungerThreshold and feedPool and ConsumePoolUses(feedPool, 1, dirtyFeedTroughs) > 0 then
                    newHunger = math.min(100, currentHunger + (Config.AutoFeedRestoreAmount or Config.HungerDecayRate))
                else
                    newHunger = math.max(0, currentHunger - Config.HungerDecayRate)
                end

                local currentThirst = animal.thirst or 100
                local newThirst
                local waterPool = waterPools[animal.ranchid]
                if currentThirst <= Config.WaterTroughThirstThreshold and waterPool and ConsumePoolUses(waterPool, 1, dirtyWaterTroughs) > 0 then
                    newThirst = math.min(100, currentThirst + (Config.AutoWaterRestoreAmount or Config.ThirstDecayRate))
                else
                    newThirst = math.max(0, currentThirst - Config.ThirstDecayRate)
                end

                table.insert(batchUpdates, {
                    animalid = animal.animalid,
                    hunger = newHunger,
                    thirst = newThirst
                })

                ::continue::
            end

            if #batchUpdates > 0 then
                local hungerCase, thirstCase = {}, {}
                local idPlaceholders, idParams = {}, {}
                local params = {}

                for _, update in ipairs(batchUpdates) do
                    table.insert(hungerCase, 'WHEN ? THEN ?')
                    table.insert(thirstCase, 'WHEN ? THEN ?')
                    table.insert(idPlaceholders, '?')
                    table.insert(idParams, update.animalid)
                end

                for _, update in ipairs(batchUpdates) do
                    table.insert(params, update.animalid)
                    table.insert(params, update.hunger or 0)
                end
                for _, update in ipairs(batchUpdates) do
                    table.insert(params, update.animalid)
                    table.insert(params, update.thirst or 0)
                end
                for _, id in ipairs(idParams) do
                    table.insert(params, id)
                end

                local query = string.format(
                    'UPDATE rsg_ranch_animals SET hunger = CASE animalid %s END, thirst = CASE animalid %s END WHERE animalid IN (%s)',
                    table.concat(hungerCase, ' '), table.concat(thirstCase, ' '), table.concat(idPlaceholders, ', ')
                )

                local batchSuccess, batchResult = pcall(function()
                    return MySQL.update.await(query, params)
                end)

                if batchSuccess then
                    if Config.Debug then
                        print('^2[DEBUG]^7 Batched feed/water update for ' .. #batchUpdates .. ' animals in a single query')
                    end

                    if Config.UpdateClientsOnCron then
                        local clientUpdates = {}
                        for i, update in ipairs(batchUpdates) do
                            clientUpdates[i] = { animalid = update.animalid, data = { hunger = update.hunger, thirst = update.thirst } }
                        end
                        TriggerClientEvent('rsg-ranch:client:refreshAnimalsBatch', -1, clientUpdates)
                    end
                else
                    print('^1[ERROR]^7 Batched animal feed/water update failed: ' .. tostring(batchResult))
                end
            end

            -- Persist the feed/water trough uses consumed by automatic feeding/watering above
            for feedtroughid, newUses in pairs(dirtyFeedTroughs) do
                MySQL.update('UPDATE rsg_ranch_feedtroughs SET uses = ? WHERE feedtroughid = ?', {newUses, feedtroughid})
                TriggerClientEvent('rsg-ranch:client:updateFeedTroughUses', -1, feedtroughid, newUses)
            end
            for watertroughid, newUses in pairs(dirtyWaterTroughs) do
                MySQL.update('UPDATE rsg_ranch_watertroughs SET uses = ? WHERE watertroughid = ?', {newUses, watertroughid})
                TriggerClientEvent('rsg-ranch:client:updateWaterTroughUses', -1, watertroughid, newUses)
            end

            if Config.Debug then
                print('^2[RSG-RANCH CRON]^7 Animal feed/water cycle completed successfully')
            end
        end)
    end)

    if not success then
        print('^1[RSG-RANCH CRON ERROR]^7 Animal feed/water cron job failed: ' .. tostring(cronError))
    end
end

---------------------------------------------
-- animal survival processing
---------------------------------------------
function ProcessAnimalSurvival()  
    local success, cronError = pcall(function()
        MySQL.query('SELECT animalid, model, born, health, thirst, hunger, last_production, product_ready, gender, pregnant, gestation_end_time, ranchid, pos_x, pos_y, pos_z, pos_w FROM rsg_ranch_animals', {}, function(animals)
            if not animals or #animals == 0 then
                if Config.Debug then
                    print('^3[RSG-RANCH CRON]^7 No animals found in database or query returned empty')
                end
                return
            end
            
            if Config.Debug then
                print('^2[RSG-RANCH CRON]^7 Processing ' .. #animals .. ' animals')
            end

        local scaleTable = {
            [0] = 0.50,
            [1] = 0.60,
            [2] = 0.70,
            [3] = 0.80,
            [4] = 0.90,
            [5] = 1.00
        }

        local animalsToRemove = {}
        local batchUpdates = {} -- Collect updates for batch processing

        for _, animal in ipairs(animals) do
            -- Comprehensive validation of animal data
            if not animal.animalid or not animal.born or not animal.pos_x or not animal.pos_y or not animal.pos_z then
                if Config.Debug then
                    print('^1[ERROR]^7 Invalid animal data: missing critical fields for animalid ' .. (animal.animalid or 'unknown'))
                    print('^1[ERROR]^7 Fields: born=' .. tostring(animal.born) .. ', pos_x=' .. tostring(animal.pos_x) .. ', pos_y=' .. tostring(animal.pos_y) .. ', pos_z=' .. tostring(animal.pos_z))
                end
                goto continue
            end

            local animalAge = math.floor((os.time() - animal.born) / (24 * 60 * 60))
            if animalAge < 0 then
                if Config.Debug then
                    print('^1[ERROR]^7 Invalid birth date for animalid ' .. animal.animalid)
                end
                goto continue
            end

            -- Prepare batch update data instead of individual queries
            local scale = scaleTable[math.min(animalAge, 5)] or 1.00
            
            -- Check for breeding/pregnancy events if enabled
            -- Handle both boolean and integer pregnancy values from database
            local isPregnant = (animal.pregnant == 1 or animal.pregnant == true or animal.pregnant == 'true')
            if Config.BreedingEnabled and isPregnant and animal.gestation_end_time then
                local currentTime = os.time()
                
                if Config.Debug then
                    print('^3[PREGNANCY DEBUG]^7 Found pregnant animal ' .. animal.animalid .. ':')
                    print('^3[PREGNANCY DEBUG]^7 - Current time: ' .. currentTime .. ' (' .. os.date('%Y-%m-%d %H:%M:%S', currentTime) .. ')')
                    print('^3[PREGNANCY DEBUG]^7 - Gestation end: ' .. animal.gestation_end_time .. ' (' .. os.date('%Y-%m-%d %H:%M:%S', animal.gestation_end_time) .. ')')
                    print('^3[PREGNANCY DEBUG]^7 - Time remaining: ' .. (animal.gestation_end_time - currentTime) .. ' seconds')
                    print('^3[PREGNANCY DEBUG]^7 - Ready to give birth: ' .. tostring(currentTime >= animal.gestation_end_time))
                end
                
                -- Check if gestation period is complete
                if currentTime >= animal.gestation_end_time then
                    local breedingConfig = Config.BreedingConfig[animal.model]
                    
                    if Config.Debug then
                        print('^3[PREGNANCY DEBUG]^7 Animal ' .. animal.animalid .. ' is ready to give birth!')
                        print('^3[PREGNANCY DEBUG]^7 - Model: ' .. tostring(animal.model))
                        print('^3[PREGNANCY DEBUG]^7 - Breeding config exists: ' .. tostring(breedingConfig ~= nil))
                        if breedingConfig then
                            print('^3[PREGNANCY DEBUG]^7 - Offspring count: ' .. breedingConfig.offspringCount.min .. '-' .. breedingConfig.offspringCount.max)
                        end
                    end
                    
                    if breedingConfig then
                        local success, breedingError = pcall(function()
                        -- Determine number of offspring
                        local offspringCount = math.random(breedingConfig.offspringCount.min, breedingConfig.offspringCount.max)
                        
                        -- Spawn offspring near the mother
                        for i = 1, offspringCount do
                            local offspringId = CreateAnimalId()
                            if not offspringId then
                                print('^1[BREEDING ERROR]^7 Failed to generate offspring ID for mother ' .. animal.animalid)
                                goto skipOffspring
                            end
                            
                            -- Select offspring model based on breeding config probabilities
                            local offspringModel = SelectOffspringModel(animal.model)
                            
                            -- Set appropriate gender based on offspring model
                            local offspringGender
                            if offspringModel == 'a_c_bull_01' then
                                offspringGender = 'male'  -- Bulls are always male
                            elseif offspringModel == 'a_c_cow' then
                                offspringGender = 'female'  -- Cows are always female
                            else
                                -- For other models, use random gender
                                offspringGender = math.random() < 0.5 and 'male' or 'female'
                            end
                            
                            if Config.Debug then
                                print('^2[BREEDING DEBUG]^7 Creating offspring ' .. offspringId .. ': model=' .. offspringModel .. ', gender=' .. offspringGender)
                            end
                            
                            -- Validate parent position data
                            if not animal.pos_x or not animal.pos_y or not animal.pos_z or
                               type(animal.pos_x) ~= 'number' or type(animal.pos_y) ~= 'number' or type(animal.pos_z) ~= 'number' then
                                if Config.Debug then
                                    print('^1[BREEDING ERROR]^7 Invalid position data for mother ' .. animal.animalid)
                                    print('^1[BREEDING ERROR]^7 Position: x=' .. tostring(animal.pos_x) .. ', y=' .. tostring(animal.pos_y) .. ', z=' .. tostring(animal.pos_z))
                                end
                                goto skipOffspring
                            end
                            
                            -- Add some random variation to spawn position
                            local spawnVariation = 5.0
                            local randomX = animal.pos_x + math.random(-spawnVariation, spawnVariation)
                            local randomY = animal.pos_y + math.random(-spawnVariation, spawnVariation)
                            
                            -- Insert offspring into database with error handling (non-blocking)
                            MySQL.insert('INSERT INTO rsg_ranch_animals (ranchid, animalid, model, pos_x, pos_y, pos_z, pos_w, health, hunger, thirst, scale, age, born, gender, pregnant, breeding_ready_time, mother_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
                                animal.ranchid,
                                offspringId,
                                offspringModel,
                                randomX,
                                randomY,
                                animal.pos_z,
                                animal.pos_w or 0,
                                100, -- health
                                100, -- hunger
                                100, -- thirst
                                0.5, -- scale (young animal)
                                0,   -- age
                                currentTime, -- born
                                offspringGender,
                                0,   -- not pregnant
                                0,   -- can breed when old enough
                                animal.animalid -- mother_id
                            }, function(insertResult)
                                -- insertResult can be a table with insertId or a number
                                local success = false
                                if type(insertResult) == 'table' then
                                    success = insertResult.insertId ~= nil or insertResult.affectedRows > 0
                                elseif type(insertResult) == 'number' then
                                    success = insertResult > 0
                                end
                                
                                if not success then
                                    if Config.Debug then
                                        print('^1[BREEDING ERROR]^7 Failed to insert offspring ' .. offspringId .. ' for mother ' .. animal.animalid)
                                    end
                                else
                                    if Config.Debug then
                                        print('^2[BREEDING SUCCESS]^7 Successfully inserted offspring ' .. offspringId .. ' (' .. offspringModel .. ', ' .. offspringGender .. ') for mother ' .. animal.animalid)
                                    end

                                end
                            end)
                            
                            ::skipOffspring::
                        end
                        
                        -- Reset mother's pregnancy status and apply post-birth cooldown
                        local postBirthCooldown = GetBreedingCooldown('female')
                        local postBirthCooldownTime = currentTime + postBirthCooldown
                        
                        MySQL.update('UPDATE rsg_ranch_animals SET pregnant = 0, gestation_end_time = NULL, breeding_ready_time = ? WHERE animalid = ?', 
                                     {postBirthCooldownTime, animal.animalid}, function(updateResult)
                            -- updateResult can be a table with affectedRows or a number
                            local rowsAffected = 0
                            if type(updateResult) == 'table' then
                                rowsAffected = updateResult.affectedRows or updateResult.changedRows or 0
                            elseif type(updateResult) == 'number' then
                                rowsAffected = updateResult
                            end
                            
                            if rowsAffected > 0 then
                                if Config.Debug then
                                    print('^2[BREEDING]^7 Applied post-birth cooldown to mother ' .. animal.animalid .. ': ' .. math.floor(postBirthCooldown / 3600) .. ' hours')
                                end
                                
                                -- Update client-side pregnancy data
                                if Config.UpdateClientsOnCron then
                                    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animal.animalid, {
                                        pregnant = 0,
                                        gestation_end_time = nil,
                                        breeding_ready_time = postBirthCooldownTime
                                    })
                                end
                            end
                        end)
                        
                        if Config.Debug then
                            print('^2[BREEDING]^7 Animal ' .. animal.animalid .. ' gave birth to ' .. offspringCount .. ' offspring')
                        end
                        
                        if Config.ServerNotify then
                            print(('^2[RSG-RANCH BREEDING]^7 %d offspring born at %s (mother: %s)'):format(offspringCount, animal.ranchid, animal.animalid))
                        end

                        -- Refresh animals after breeding to show new offspring
                        SetTimeout(2000, function()
                            RanchBroadcastAnimals()
                        end)
                        end)
                        
                        if not success then
                            if Config.Debug then
                                print('^1[BREEDING ERROR]^7 Error during offspring creation for animal ' .. animal.animalid .. ': ' .. tostring(breedingError))
                            end
                        end
                    else
                        if Config.Debug then
                            print('^1[BREEDING ERROR]^7 No breeding config found for model: ' .. tostring(animal.model))
                            print('^1[BREEDING ERROR]^7 Available breeding configs:')
                            for model, config in pairs(Config.BreedingConfig) do
                                print('^1[BREEDING ERROR]^7 - ' .. model)
                            end
                        end
                    end
                else
                    if Config.Debug and isPregnant then
                        print('^3[PREGNANCY DEBUG]^7 Animal ' .. animal.animalid .. ' is pregnant but not ready to give birth yet (time remaining: ' .. (animal.gestation_end_time - currentTime) .. ' seconds)')
                    end
                end
            else
                -- Debug when breeding conditions are not met
                local debugIsPregnant = (animal.pregnant == 1 or animal.pregnant == true or animal.pregnant == 'true')
                if Config.Debug and debugIsPregnant then
                    local reasons = {}
                    if not Config.BreedingEnabled then
                        table.insert(reasons, 'Breeding disabled')
                    end
                    if not debugIsPregnant then
                        table.insert(reasons, 'Not pregnant')
                    end
                    if not animal.gestation_end_time then
                        table.insert(reasons, 'No gestation end time')
                    end
                    if #reasons > 0 then
                        print('^3[PREGNANCY DEBUG]^7 Animal ' .. animal.animalid .. ' breeding skipped: ' .. table.concat(reasons, ', '))
                    end
                end
            end
            
            -- Check for production if enabled
            if Config.ProductionEnabled and Config.AnimalProducts[animal.model] then
                local productConfig = Config.AnimalProducts[animal.model]
                local currentTime = os.time()
                local lastProduction = animal.last_production or 0
                
                -- Check if animal is old enough and meets requirements
                if animalAge >= Config.MinAgeForProduction and
                   (animal.health or 100) >= productConfig.requiresHealth and
                   (animal.hunger or 100) >= productConfig.requiresHunger and
                   (animal.thirst or 100) >= productConfig.requiresThirst then
                    
                    -- Check if enough time has passed for production
                    if (currentTime - lastProduction) >= productConfig.productionTime then
                        if Config.Debug then
                            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animal.animalid .. ' meets production requirements:')
                            print('^3[PRODUCTION DEBUG]^7 Age: ' .. animalAge .. ' (min: ' .. Config.MinAgeForProduction .. ')')
                            print('^3[PRODUCTION DEBUG]^7 Health: ' .. (animal.health or 100) .. '% (min: ' .. productConfig.requiresHealth .. '%)')
                            print('^3[PRODUCTION DEBUG]^7 Hunger: ' .. (animal.hunger or 100) .. '% (min: ' .. productConfig.requiresHunger .. '%)')
                            print('^3[PRODUCTION DEBUG]^7 Thirst: ' .. (animal.thirst or 100) .. '% (min: ' .. productConfig.requiresThirst .. '%)')
                            print('^3[PRODUCTION DEBUG]^7 Time since last production: ' .. (currentTime - lastProduction) .. 's (required: ' .. productConfig.productionTime .. 's)')
                        end
                        
                        -- Use a more reliable update with better error handling
                        local success, updateError = pcall(function()
                            return MySQL.update.await('UPDATE rsg_ranch_animals SET last_production = ?, product_ready = 1 WHERE animalid = ?', {
                                currentTime, animal.animalid
                            })
                        end)
                        
                        if success and updateError and updateError > 0 then
                            if Config.Debug then
                                print('^2[PRODUCTION SUCCESS]^7 Animal ' .. animal.animalid .. ' (' .. animal.model .. ') produced ' .. productConfig.product .. ' (ready for collection)')
                            end
                            
                            -- Update client-side production data immediately
                            if Config.UpdateClientsOnCron then
                                TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animal.animalid, {
                                    last_production = currentTime,
                                    product_ready = 1
                                })
                            end
                            
                            if Config.ServerNotify then
                                print('^2[RSG-RANCH PRODUCTION]^7 ' .. productConfig.product .. ' ready for collection from animal ' .. animal.animalid .. ' at ranch ' .. animal.ranchid)
                            end
                        else
                            if Config.Debug then
                                print('^1[PRODUCTION ERROR]^7 Failed to update production status for animal ' .. animal.animalid .. ' - Success: ' .. tostring(success) .. ', Result: ' .. tostring(updateError))
                            end
                        end
                    else
                        if Config.Debug then
                            local remainingTime = productConfig.productionTime - (currentTime - lastProduction)
                            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animal.animalid .. ' not ready for production. Time remaining: ' .. remainingTime .. 's')
                        end
                    end
                else
                    if Config.Debug then
                        local issues = {}
                        if animalAge < Config.MinAgeForProduction then
                            table.insert(issues, 'Too young (' .. animalAge .. 'd, need ' .. Config.MinAgeForProduction .. 'd)')
                        end
                        if (animal.health or 100) < productConfig.requiresHealth then
                            table.insert(issues, 'Low health (' .. (animal.health or 100) .. '%, need ' .. productConfig.requiresHealth .. '%)')
                        end
                        if (animal.hunger or 100) < productConfig.requiresHunger then
                            table.insert(issues, 'Low hunger (' .. (animal.hunger or 100) .. '%, need ' .. productConfig.requiresHunger .. '%)')
                        end
                        if (animal.thirst or 100) < productConfig.requiresThirst then
                            table.insert(issues, 'Low thirst (' .. (animal.thirst or 100) .. '%, need ' .. productConfig.requiresThirst .. '%)')
                        end
                        
                        if #issues > 0 then
                            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animal.animalid .. ' cannot produce: ' .. table.concat(issues, ', '))
                        end
                    end
                end
            end
            
            -- Feed/water consumption is handled by the separate animal feed/water
            -- cronjob (ProcessAnimalFeedWater); health here reacts to whatever the
            -- animal's current hunger/thirst levels are as of the last feed/water run.
            local newHunger = animal.hunger or 100
            local newThirst = animal.thirst or 100
            local currentHealth = animal.health or 100
            local newHealth = currentHealth
            
            -- Check if animal is starving or dehydrated
            if newHunger <= Config.MinSurvivalStats or newThirst <= Config.MinSurvivalStats then
                newHealth = math.max(0, currentHealth - Config.HealthDecayRate)
                if Config.Debug then
                    print('^3[DEBUG]^7 Animal ' .. animal.animalid .. ' is starving/dehydrated. Health: ' .. newHealth)
                end
            -- Check if animal is well-fed and watered for health regeneration
            elseif currentHealth < 100 and Config.HealthRegenerationRate and Config.MinStatsForRegeneration then
                if newHunger >= Config.MinStatsForRegeneration and newThirst >= Config.MinStatsForRegeneration then
                    newHealth = math.min(100, currentHealth + Config.HealthRegenerationRate)
                    if Config.Debug then
                        print('^2[DEBUG]^7 Animal ' .. animal.animalid .. ' is regenerating health. Health: ' .. currentHealth .. ' -> ' .. newHealth)
                    end
                end
            end
            
            -- Mark animal for removal if health reaches zero
            if newHealth <= 0 then
                table.insert(animalsToRemove, animal.animalid)
                if Config.ServerNotify then
                    print('^1[RSG-RANCH]^7 Animal ' .. animal.animalid .. ' has died and will be removed from the database.')
                end
            else
                -- Collect updates for batch processing including scale and age
                table.insert(batchUpdates, {
                    animalid = animal.animalid,
                    hunger = newHunger,
                    thirst = newThirst,
                    health = newHealth,
                    scale = scale,
                    age = animalAge
                })
                if Config.Debug then
                    print('^2[DEBUG]^7 Prepared update for animal ' .. animal.animalid .. ' - Hunger: ' .. newHunger .. ', Thirst: ' .. newThirst .. ', Health: ' .. newHealth)
                end
            end
            
            ::continue::
        end
        
        -- Process batch updates for living animals in a single query using CASE/WHEN,
        -- instead of one round-trip per animal, to keep the cron job cheap as ranches grow.
        if #batchUpdates > 0 then
            local validUpdates = {}
            for _, update in ipairs(batchUpdates) do
                if update.animalid then
                    table.insert(validUpdates, update)
                elseif Config.Debug then
                    print('^1[ERROR]^7 Skipping update with missing animalid')
                end
            end

            if #validUpdates > 0 then
                local healthCase, scaleCase, ageCase = {}, {}, {}
                local idPlaceholders, idParams = {}, {}
                local params = {}

                for _, update in ipairs(validUpdates) do
                    table.insert(healthCase, 'WHEN ? THEN ?')
                    table.insert(scaleCase, 'WHEN ? THEN ?')
                    table.insert(ageCase, 'WHEN ? THEN ?')
                    table.insert(idPlaceholders, '?')
                    table.insert(idParams, update.animalid)
                end

                -- Build the WHEN/THEN param list in column order (health, scale, age).
                -- hunger/thirst are no longer written here: they're owned by the separate
                -- animal feed/water cronjob (ProcessAnimalFeedWater), so this survival
                -- cronjob doesn't race it or overwrite fresher values with stale ones.
                for _, update in ipairs(validUpdates) do
                    table.insert(params, update.animalid)
                    table.insert(params, update.health or 0)
                end
                for _, update in ipairs(validUpdates) do
                    table.insert(params, update.animalid)
                    table.insert(params, update.scale or 1.00)
                end
                for _, update in ipairs(validUpdates) do
                    table.insert(params, update.animalid)
                    table.insert(params, update.age or 0)
                end
                for _, id in ipairs(idParams) do
                    table.insert(params, id)
                end

                local query = string.format(
                    'UPDATE rsg_ranch_animals SET health = CASE animalid %s END, scale = CASE animalid %s END, age = CASE animalid %s END WHERE animalid IN (%s)',
                    table.concat(healthCase, ' '), table.concat(scaleCase, ' '), table.concat(ageCase, ' '), table.concat(idPlaceholders, ', ')
                )

                local batchSuccess, batchResult = pcall(function()
                    return MySQL.update.await(query, params)
                end)

                if batchSuccess then
                    if Config.Debug then
                        print('^2[DEBUG]^7 Batched update for ' .. #validUpdates .. ' animals in a single query')
                    end

                    if Config.UpdateClientsOnCron then
                        local clientUpdates = {}
                        for _, update in ipairs(validUpdates) do
                            clientUpdates[#clientUpdates + 1] = { animalid = update.animalid, data = { health = update.health, scale = update.scale, age = update.age } }
                        end
                        TriggerClientEvent('rsg-ranch:client:refreshAnimalsBatch', -1, clientUpdates)
                    end
                else
                    print('^1[ERROR]^7 Batched animal update failed: ' .. tostring(batchResult))
                end
            end
        end

        -- Clean up expired breeding cooldowns (separate simple query)
        local currentTime = os.time()
        MySQL.query('SELECT animalid FROM rsg_ranch_animals WHERE breeding_ready_time > 0 AND breeding_ready_time <= ?', {currentTime}, function(expiredAnimals)
            if expiredAnimals and #expiredAnimals > 0 then
                -- Clear the cooldowns in database
                MySQL.execute('UPDATE rsg_ranch_animals SET breeding_ready_time = 0 WHERE breeding_ready_time > 0 AND breeding_ready_time <= ?', {currentTime})
                
                -- Update client cache for each expired animal
                if Config.UpdateClientsOnCron then
                    for _, animal in ipairs(expiredAnimals) do
                        TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animal.animalid, {
                            breeding_ready_time = 0
                        })
                        
                        if Config.Debug then
                            print('^2[DEBUG]^7 Cleared breeding cooldown for animal ' .. animal.animalid)
                        end
                    end
                end
            end
        end)
        
        -- Remove dead animals from database and client
        if #animalsToRemove > 0 then
            if Config.Debug then
                print('^1[RSG-RANCH]^7 Removing ' .. #animalsToRemove .. ' dead animals from database and game world')
                for _, id in ipairs(animalsToRemove) do
                    print('^1[RSG-RANCH DEBUG]^7 Dead animal ID: ' .. tostring(id))
                end
            end
            
            -- Immediately remove animals from clients (don't wait for database)
            for _, animalid in ipairs(animalsToRemove) do
                if Config.Debug then
                    print('^1[RSG-RANCH]^7 Immediately removing animal ' .. animalid .. ' from all clients')
                end
                TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, animalid)
            end
            
            -- Then remove from database - batched into a single DELETE ... WHERE animalid IN (...)
            -- instead of one round-trip per dead animal
            local idPlaceholders = {}
            for _, animalid in ipairs(animalsToRemove) do
                table.insert(idPlaceholders, '?')
            end

            MySQL.execute(
                'DELETE FROM rsg_ranch_animals WHERE animalid IN (' .. table.concat(idPlaceholders, ', ') .. ')',
                animalsToRemove,
                function(deleteResult)
                    local rowsAffected = 0
                    if type(deleteResult) == 'table' then
                        rowsAffected = deleteResult.affectedRows or deleteResult.changedRows or 0
                    elseif type(deleteResult) == 'number' then
                        rowsAffected = deleteResult
                    end

                    if Config.Debug then
                        if rowsAffected > 0 then
                            print('^2[RSG-RANCH]^7 Successfully removed ' .. rowsAffected .. '/' .. #animalsToRemove .. ' dead animals from database')
                        else
                            print('^1[RSG-RANCH ERROR]^7 Failed to remove dead animals from database')
                        end
                    end
                    -- If database removal fails, the animals are already gone client-side;
                    -- database cleanup can be retried on the next survival tick
                end
            )
            
            
            if Config.ServerNotify then
                print('^1[RSG-RANCH]^7 Removed ' .. #animalsToRemove .. ' dead animals from the game world')
            end
        end
        
        -- Print completion summary
        if Config.Debug then
            if #animalsToRemove > 0 then
                print('^2[RSG-RANCH]^7 Animal survival check completed. ' .. #animals .. ' animals processed, ' .. #animalsToRemove .. ' animals died.')
            else
                print('^2[RSG-RANCH]^7 Animal survival check completed. ' .. #animals .. ' animals updated.')
            end
            
            if #batchUpdates > 0 and Config.UpdateClientsOnCron then
                print('^2[RSG-RANCH]^7 Updated client data for ' .. #batchUpdates .. ' animals')
            end
        end
        
        if Config.Debug then
            print('^2[RSG-RANCH CRON]^7 Animal update cycle completed successfully')
        end
        
        -- Refresh all animal data on clients after cronjob completion
        -- This ensures any missed individual updates are caught
        if Config.RefreshAfterCron then
            SetTimeout(500, function()
                if Config.Debug then
                    print('^2[RSG-RANCH CRON]^7 Refreshing all animal data on clients')
                end
                RanchBroadcastAnimals()
            end)
        end
    end) -- Close MySQL.query callback
    end) -- Close pcall function
    
    if not success then
        cronFailures = cronFailures + 1
        print('^1[RSG-RANCH CRON ERROR]^7 Animal cron job failed (failure #' .. cronFailures .. '): ' .. tostring(cronError))
        
        -- If we have too many failures, something is seriously wrong
        if cronFailures >= 5 then
            print('^1[RSG-RANCH CRITICAL]^7 Animal survival cronjob has failed ' .. cronFailures .. ' times!')
            print('^1[RSG-RANCH CRITICAL]^7 This may indicate a database connection issue or resource conflict.')
        end
    else
        cronFailures = 0 -- Reset failure counter on success
    end
end

---------------------------------------------
-- Staff Management System
---------------------------------------------

-- Get staff list for a ranch
RSGCore.Functions.CreateCallback('rsg-ranch:server:getStaffList', function(source, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player or not ranchid then 
        cb({employees = {}})
        return 
    end
    
    -- Check if player has permission to manage staff
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        cb({employees = {}})
        return
    end
    
    -- Get all players with this job
    local employees = {}
    local players = RSGCore.Functions.GetPlayers()
    
    for _, playerId in ipairs(players) do
        local targetPlayer = RSGCore.Functions.GetPlayer(playerId)
        if targetPlayer and targetPlayer.PlayerData.job.name == ranchid then
            table.insert(employees, {
                citizenid = targetPlayer.PlayerData.citizenid,
                name = targetPlayer.PlayerData.charinfo.firstname .. ' ' .. targetPlayer.PlayerData.charinfo.lastname,
                grade = targetPlayer.PlayerData.job.grade.level,
                grade_label = targetPlayer.PlayerData.job.grade.name,
                is_online = true
            })
        end
    end
    
    -- Also get offline employees from database
    MySQL.query('SELECT citizenid, charinfo, job FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', {ranchid}, function(result)
        if result then
            for _, row in ipairs(result) do
                local alreadyAdded = false
                for _, emp in ipairs(employees) do
                    if emp.citizenid == row.citizenid then
                        alreadyAdded = true
                        break
                    end
                end
                
                if not alreadyAdded then
                    local charinfo = json.decode(row.charinfo)
                    local job = json.decode(row.job)
                    
                    table.insert(employees, {
                        citizenid = row.citizenid,
                        name = charinfo.firstname .. ' ' .. charinfo.lastname,
                        grade = job.grade.level,
                        grade_label = job.grade.name,
                        is_online = false
                    })
                end
            end
        end
        
        cb({employees = employees})
    end)
end)

-- Get nearby players
RSGCore.Functions.CreateCallback('rsg-ranch:server:getNearbyPlayers', function(src, cb)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then 
        cb({})
        return 
    end
    
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local players = {}
    
    for _, playerId in ipairs(RSGCore.Functions.GetPlayers()) do
        if playerId ~= src then
            local targetPed = GetPlayerPed(playerId)
            local targetCoords = GetEntityCoords(targetPed)
            local distance = #(coords - targetCoords)
            
            if distance < 10.0 then -- Within 10 meters
                local targetPlayer = RSGCore.Functions.GetPlayer(playerId)
                if targetPlayer then
                    table.insert(players, {
                        id = playerId,
                        name = targetPlayer.PlayerData.charinfo.firstname .. ' ' .. targetPlayer.PlayerData.charinfo.lastname,
                        distance = distance
                    })
                end
            end
        end
    end
    
    cb(players)
end)

-- Hire employee
RegisterNetEvent('rsg-ranch:server:hireEmployee', function(ranchid, targetId, grade)

    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    targetId = tonumber(targetId)
    local Target = targetId and RSGCore.Functions.GetPlayer(targetId)

    if not Player or not Target then return end

    -- The hire menu only lists nearby players - enforce that server-side so a
    -- manager can't force a ranch job onto any player on the server by ID
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(targetId))) > 10.0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_190')})
        return
    end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_211')})
        return
    end
    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    -- Check if target player is already employed at this ranch
    if Target.PlayerData.job.name == ranchid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_212')})
        if Config.Debug then
            print('^3[STAFF MANAGEMENT]^7 Attempted to hire ' .. Target.PlayerData.charinfo.firstname .. ' who is already employed at ' .. ranchid)
        end
        return
    end

	local staffCount = exports['rsg-ranch']:getStaffCount(ranchid)
	if staffCount >= Config.StaffManagement.MaxEmployeesPerRanch then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_214')})
        return
	end

	-- Validate hire grade: must be a real grade defined for this job, and the hiring
	-- manager can never hire someone at or above their own grade (prevents a Manager
	-- promoting a hire straight to Boss).
	grade = tonumber(grade)
	local hirerGrade = Player.PlayerData.job.grade.level
	if not grade or grade < 0 or grade >= hirerGrade or not Config.StaffManagement.Permissions[grade] then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_215')})
        if Config.Debug then
            print('^1[STAFF MANAGEMENT ERROR]^7 Player ' .. src .. ' attempted to hire with invalid grade ' .. tostring(grade) .. ' (hirer grade: ' .. tostring(hirerGrade) .. ')')
        end
        return
    end

    -- The player being hired has to accept - jobs used to be forced on anyone nearby
    local ranchName = (GetRanchLocationData(ranchid) or {}).name or ranchid
    TriggerClientEvent('ox_lib:notify', src, {type = 'inform', description = locale('sv_waiting_for_answer')})
    if not RequestConsent(targetId, ranchName, locale('sv_job_offer'):format(ranchName)) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_offer_declined')})
        return
    end
    Target = RSGCore.Functions.GetPlayer(targetId)
    if not Target or Target.PlayerData.job.name == ranchid then return end
    if exports['rsg-ranch']:getStaffCount(ranchid) >= Config.StaffManagement.MaxEmployeesPerRanch then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_214')})
        return
    end

    -- Register with rsg-multijob; it refuses if they already hold the maximum number of jobs
    local jobAdded, jobReason = MultijobAddJob(Target.PlayerData.citizenid, ranchid, grade)
    if not jobAdded then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_213')})
        if Config.Debug then print('^1[STAFF MANAGEMENT]^7 multijob AddJob refused: ' .. tostring(jobReason)) end
        return
    end

    Target.Functions.SetJob(ranchid, grade)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_216')})
    TriggerClientEvent('ox_lib:notify', targetId, {type = 'success', description = locale('sv_server_description_217'):format((GetRanchLocationData(ranchid) or {}).name or ranchid)})

end)

-- Fire employee
RegisterNetEvent('rsg-ranch:server:fireEmployee', function(ranchid, targetCitizenid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_218')})
        return
    end
    
    -- Prevent manager from firing themselves
    if Player.PlayerData.citizenid == targetCitizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_219')})
        return
    end
    if type(targetCitizenid) ~= 'string' then return end
    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    -- The owner can never be fired, and only the owner can fire someone of
    -- equal or higher grade (stops a manager locking the owner out of their ranch)
    if RanchOwners[ranchid] == targetCitizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_cannot_target_owner')})
        return
    end
    local isOwner = RanchOwners[ranchid] == Player.PlayerData.citizenid
    
    -- Get target player
    local Target = RSGCore.Functions.GetPlayerByCitizenId(targetCitizenid)
    
    if Target then
        -- Verify the target is actually employed at this ranch
        if Target.PlayerData.job.name ~= ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_220')})
            return
        end
        if not isOwner and Target.PlayerData.job.grade.level >= Player.PlayerData.job.grade.level then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_239')})
            return
        end
        
        -- Player is online
        Target.Functions.SetJob('unemployed', 0)
		-- update multijob
        MultijobRemoveJob(targetCitizenid, ranchid)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_228')})
        TriggerClientEvent('ox_lib:notify', Target.PlayerData.source, {type = 'error', description = locale('sv_server_description_223'):format((GetRanchLocationData(ranchid) or {}).name or ranchid)})
    else
        -- Player is offline, verify they work at this ranch first
        local checkResult = MySQL.query.await('SELECT job FROM players WHERE citizenid = ?', {targetCitizenid})
        if checkResult and #checkResult > 0 then
            local jobData = json.decode(checkResult[1].job) or {}
            if jobData.name ~= ranchid then
                TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_224')})
                return
            end
            local offlineGrade = jobData.grade and jobData.grade.level or 0
            if not isOwner and offlineGrade >= Player.PlayerData.job.grade.level then
                TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_239')})
                return
            end
        else
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_225')})
            return
        end
        
        -- update database
        MySQL.update('UPDATE players SET job = JSON_SET(JSON_SET(job, "$.name", "unemployed"), "$.grade", JSON_OBJECT("level", 0, "name", "Unemployed")) WHERE citizenid = ?', {targetCitizenid})
		-- update multijob
        MultijobRemoveJob(targetCitizenid, ranchid)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_228')})

    end

    if Config.Debug then
        print('^3[STAFF MANAGEMENT]^7 ' .. Player.PlayerData.charinfo.firstname .. ' fired employee ' .. targetCitizenid .. ' from ' .. ranchid)
    end
end)

-- Promote employee
RegisterNetEvent('rsg-ranch:server:promoteEmployee', function(ranchid, targetCitizenid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_229')})
        return
    end
    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end
    
    local Target = RSGCore.Functions.GetPlayerByCitizenId(targetCitizenid)
    
    if Target then
        -- Verify the target is actually employed at this ranch
        if Target.PlayerData.job.name ~= ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_230')})
            return
        end
        
        local currentGrade = Target.PlayerData.job.grade.level
        local maxGrade = Config.RanchBossGrade -- ranch jobs only define grades 0-2 (see installation/shared_jobs.lua)
        
        -- Prevent promoting to same or higher grade than manager
        if currentGrade + 1 >= Player.PlayerData.job.grade.level and Player.PlayerData.job.grade.level < maxGrade then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_231')})
            return
        end
        
        if currentGrade >= maxGrade then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_232')})
            return
        end
        
        Target.Functions.SetJob(ranchid, currentGrade + 1)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_233')})
        TriggerClientEvent('ox_lib:notify', Target.PlayerData.source, {type = 'success', description = locale('sv_server_description_234')})
        
        if Config.Debug then
            print('^2[STAFF MANAGEMENT]^7 ' .. Player.PlayerData.charinfo.firstname .. ' promoted ' .. Target.PlayerData.charinfo.firstname .. ' to grade ' .. (currentGrade + 1))
        end
    else
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_235')})
    end
end)

-- Demote employee
RegisterNetEvent('rsg-ranch:server:demoteEmployee', function(ranchid, targetCitizenid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_236')})
        return
    end
    
    -- Prevent manager from demoting themselves
    if Player.PlayerData.citizenid == targetCitizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_237')})
        return
    end
    if RanchOwners[ranchid] == targetCitizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_cannot_target_owner')})
        return
    end
    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end
    
    local Target = RSGCore.Functions.GetPlayerByCitizenId(targetCitizenid)
    
    if Target then
        -- Verify the target is actually employed at this ranch
        if Target.PlayerData.job.name ~= ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_238')})
            return
        end
        
        local currentGrade = Target.PlayerData.job.grade.level
        
        -- Prevent demoting someone at same or higher rank (unless you're boss)
        if currentGrade >= Player.PlayerData.job.grade.level and Player.PlayerData.job.grade.level < Config.RanchBossGrade then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_239')})
            return
        end
        
        if currentGrade <= 0 then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_240')})
            return
        end
        
        Target.Functions.SetJob(ranchid, currentGrade - 1)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_server_description_241')})
        TriggerClientEvent('ox_lib:notify', Target.PlayerData.source, {type = 'inform', description = locale('sv_server_description_242')})
        
        if Config.Debug then
            print('^3[STAFF MANAGEMENT]^7 ' .. Player.PlayerData.charinfo.firstname .. ' demoted ' .. Target.PlayerData.charinfo.firstname .. ' to grade ' .. (currentGrade - 1))
        end
    else
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_server_description_243')})
    end
end)


---------------------------------------------
-- At-ranch livestock market (pigs, cows, sheep)
-- Unlike cattle sold at a sale point, these can be sold for cash or sent for
-- slaughter (joints of meat) straight from the ranch menu. One handler serves
-- every species; the species always comes from the database, never the client.
---------------------------------------------
local MarketSpecies = {
    a_c_pig_01 = {
        key = 'pig', yield = function() return Config.PigSlaughterYield or { min = 2, max = 4 } end,
        item = function() return Config.PorkJointItem or 'porkjoint' end,
        msg = { tooYoungSell = 250, sold = 252, tooYoungSlaughter = 259, noSpace = 260, slaughtered = 262 },
    },
    a_c_cow = {
        key = 'cow', yield = function() return Config.CowSlaughterYield or { min = 3, max = 6 } end,
        item = function() return Config.BeefJointItem or 'beefjoint' end,
        msg = { tooYoungSell = 269, sold = 271, tooYoungSlaughter = 278, noSpace = 279, slaughtered = 281 },
    },
    a_c_bull_01 = {
        key = 'bull', yield = function() return Config.BullSlaughterYield or { min = 4, max = 8 } end,
        item = function() return Config.BeefJointItem or 'beefjoint' end,
        msg = { tooYoungSell = 'sv_bull_too_young_sell', sold = 'sv_bull_sold', tooYoungSlaughter = 'sv_bull_too_young_slaughter', noSpace = 279, slaughtered = 'sv_bull_slaughtered' },
    },
    a_c_sheep_01 = {
        key = 'sheep', yield = function() return Config.SheepSlaughterYield or { min = 2, max = 4 } end,
        item = function() return Config.MuttonJointItem or 'muttonjoint' end,
        msg = { tooYoungSell = 288, sold = 290, tooYoungSlaughter = 297, noSpace = 298, slaughtered = 300 },
    },
}

local function MarketMsg(n)
    if type(n) == 'string' then return locale(n) end
    return locale('sv_server_description_' .. n)
end

-- Direct-sale price from the ranch menu. Cows & bulls (Config.DirectSaleModels) get
-- Config.DirectSalePercentage of the normal price, since they aren't driven to market.
local function RanchDirectSalePrice(model, ageDays)
    local price, ageCategory = CalculateAnimalSalePrice(model, ageDays)
    local direct = Config.DirectSaleModels and Config.DirectSaleModels[model] == true
    if direct then
        local pct = math.max(0.0, math.min(1.0, tonumber(Config.DirectSalePercentage) or 0.8))
        price = math.floor(price * pct)
    end
    return price, ageCategory, direct
end
local function NotifyError(src, text) TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = text}) end

local function AnimalAgeDays(row)
    if row.born and row.born > 0 then
        return math.floor((os.time() - row.born) / 86400)
    end
    return row.age or 0
end

---------------------------------------------
-- every market animal this ranch owns, in a single query
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getRanchMarket', function(src, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not ranchid or ranchid ~= Player.PlayerData.job.name or not isPlayerRanchStaff(Player) then
        cb({})
        return
    end

    local rows = MySQL.query.await('SELECT animalid, model, gender, age, born, health FROM rsg_ranch_animals WHERE ranchid = ? AND model IN (?, ?, ?, ?)', {
        ranchid, 'a_c_pig_01', 'a_c_cow', 'a_c_bull_01', 'a_c_sheep_01'
    }) or {}

    local list = {}
    for _, row in ipairs(rows) do
        local age = AnimalAgeDays(row)
        local salePrice, ageCategory, direct = RanchDirectSalePrice(row.model, age)
        list[#list + 1] = {
            animalid = row.animalid,
            model = row.model,
            species = MarketSpecies[row.model].key,
            gender = row.gender,
            age = age,
            ageCategory = ageCategory,
            health = row.health or 100,
            salePrice = salePrice,
            canSell = age >= Config.MinAgeToSell,
            canSlaughter = not MarketSpecies[row.model].noSlaughter,
            directSalePct = direct and math.floor(math.max(0.0, math.min(1.0, tonumber(Config.DirectSalePercentage) or 0.8)) * 100 + 0.5) or nil,
        }
    end
    cb(list)
end)

---------------------------------------------
-- shared validation for selling / slaughtering one market animal
-- returns Player, animal, species (or nil after notifying the player)
---------------------------------------------
local function ValidateMarketAnimal(src, animalid, tooYoungKey)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if not isPlayerRanchStaff(Player) or Player.PlayerData.job.grade.level < 1 then
        return NotifyError(src, MarketMsg(245))
    end
    if not animalid then return NotifyError(src, MarketMsg(246)) end

    local ranchid = Player.PlayerData.job.name
    if not IsNearRanch(src, ranchid) then return NotifyNotNearRanch(src) end

    local rows = MySQL.query.await('SELECT animalid, ranchid, model, age, born FROM rsg_ranch_animals WHERE animalid = ?', {animalid})
    local animal = rows and rows[1]
    if not animal then return NotifyError(src, MarketMsg(247)) end

    local species = MarketSpecies[animal.model]
    if not species then return NotifyError(src, MarketMsg(248)) end

    if animal.ranchid ~= ranchid then
        if Config.Debug then
            print(('^1[RANCH MARKET EXPLOIT?]^7 Player %s (%s) targeted animal %s of ranch %s'):format(src, ranchid, animalid, tostring(animal.ranchid)))
        end
        return NotifyError(src, MarketMsg(249))
    end

    if tooYoungKey == 'tooYoungSlaughter' and species.noSlaughter then
        return NotifyError(src, MarketMsg(248))
    end

    animal.ageDays = AnimalAgeDays(animal)
    if animal.ageDays < Config.MinAgeToSell then
        return NotifyError(src, MarketMsg(species.msg[tooYoungKey]):format(Config.MinAgeToSell))
    end

    return Player, animal, species
end

---------------------------------------------
-- sell a market animal directly from the ranch (no sale point / herding)
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:sellAtRanch', function(animalid)
    local src = source
    local Player, animal, species = ValidateMarketAnimal(src, animalid, 'tooYoungSell')
    if not Player then return end

    -- Price is always recomputed server-side (cows & bulls get the reduced direct-sale price)
    local salePrice = RanchDirectSalePrice(animal.model, animal.ageDays)

    -- Only pay out if THIS request deleted the animal (stops spam double-sells)
    local deleted = MySQL.update.await('DELETE FROM rsg_ranch_animals WHERE animalid = ?', {animal.animalid})
    if not deleted or deleted <= 0 then return NotifyError(src, MarketMsg(251)) end

    Player.Functions.AddMoney('cash', salePrice, 'rsg-ranch-market-sale')
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = MarketMsg(species.msg.sold):format(salePrice)})
    TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, animal.animalid)

    if Config.Debug then
        print(('^2[RANCH MARKET]^7 Player %s sold %s %s for $%s'):format(src, species.key, animal.animalid, salePrice))
    end
end)

---------------------------------------------
-- send a market animal for slaughter - joints of meat instead of cash
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:slaughterAtRanch', function(animalid)
    local src = source
    local Player, animal, species = ValidateMarketAnimal(src, animalid, 'tooYoungSlaughter')
    if not Player then return end

    local yield = species.yield()
    local jointCount = math.random(yield.min, yield.max)
    local jointItem = species.item()

    if not RSGCore.Shared.Items[jointItem] then
        print(('^1[RSG-RANCH]^7 Slaughter item "%s" is not in rsg-core shared items'):format(jointItem))
        return NotifyError(src, MarketMsg(261))
    end

    if not exports['rsg-inventory']:CanAddItem(src, jointItem, jointCount) then
        return NotifyError(src, MarketMsg(species.msg.noSpace))
    end

    local deleted = MySQL.update.await('DELETE FROM rsg_ranch_animals WHERE animalid = ?', {animal.animalid})
    if not deleted or deleted <= 0 then return NotifyError(src, MarketMsg(261)) end

    exports['rsg-inventory']:AddItem(src, jointItem, jointCount, nil, nil, 'rsg-ranch-slaughter')
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[jointItem], 'add', jointCount)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = MarketMsg(species.msg.slaughtered):format(jointCount)})
    TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, animal.animalid)

    if Config.Debug then
        print(('^2[RANCH MARKET]^7 Player %s slaughtered %s %s for %sx %s'):format(src, species.key, animal.animalid, jointCount, jointItem))
    end
end)

---------------------------------------------
-- shared handles for server/modules/admin.lua (ranch admin panel).
-- Exposed as one global table so admin tools work on the same ownership
-- cache and helpers as the rest of the resource.
---------------------------------------------
RanchAdminBridge = {
    Owners = RanchOwners,
    FireAllRanchStaff = FireAllRanchStaff,
    EnsureGeneralStorage = EnsureGeneralStorage,
    GetRanchStorages = GetRanchStorages,
    GenerateStorageId = GenerateStorageId,
    MultijobAddJob = MultijobAddJob,
    MultijobRemoveJob = MultijobRemoveJob,
}
