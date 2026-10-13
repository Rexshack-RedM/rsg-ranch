local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Core Variables
---------------------------------------------
local chickenCoopCache = {} -- [coopid] = { data = {...}, entity = objectHandle, chickens = { [ped] = true } }

---------------------------------------------
-- Helper: distance-safe entity check
---------------------------------------------
local function chickenCoopExists(coopid)
    local entry = chickenCoopCache[tostring(coopid)]
    return entry ~= nil and entry.entity ~= nil and DoesEntityExist(entry.entity)
end

---------------------------------------------
-- Chicken wander behaviour - keeps a spawned chicken ped roaming close to its
-- coop rather than wandering off across the map (leash distance from Config.ChickenWanderRadius)
---------------------------------------------
local function StartChickenWander(ped, coopVec)
    CreateThread(function()
        while DoesEntityExist(ped) do
            local radius = Config.ChickenWanderRadius or 8.0
            local angle = math.random() * 2 * math.pi
            local dist = math.random() * radius
            local targetX = coopVec.x + (math.cos(angle) * dist)
            local targetY = coopVec.y + (math.sin(angle) * dist)
            local foundGround, groundZ = GetGroundZFor_3dCoord(targetX, targetY, coopVec.z + 5.0, false)
            local targetZ = foundGround and groundZ or coopVec.z

            if DoesEntityExist(ped) and not IsEntityDead(ped) then
                TaskGoStraightToCoord(ped, targetX, targetY, targetZ, 0.5, 8000, 0.0, 0.0)
            end

            Wait(Config.ChickenWanderCheckInterval or 4000)

            -- Pull the chicken back if it somehow drifted beyond the leash (e.g. pushed by a player/horse)
            if DoesEntityExist(ped) then
                local pedCoords = GetEntityCoords(ped)
                if #(pedCoords - coopVec) > radius * 1.5 then
                    local foundGround2, groundZ2 = GetGroundZFor_3dCoord(coopVec.x, coopVec.y, coopVec.z + 5.0, false)
                    ClearPedTasksImmediately(ped)
                    SetEntityCoords(ped, coopVec.x, coopVec.y, foundGround2 and groundZ2 or coopVec.z, false, false, false, false)
                end
            end
        end
    end)
end

---------------------------------------------
-- Spawn/despawn the ambient chicken peds for a coop (decorative, local per-client,
-- matching the number of chickens the coop actually owns server-side)
---------------------------------------------
local function SetChickenPedCount(key, targetCount)
    local entry = chickenCoopCache[key]
    if not entry then return end

    entry.chickens = entry.chickens or {}
    local coopVec = vector3(entry.data.pos_x, entry.data.pos_y, entry.data.pos_z)

    local currentCount = #entry.chickens
    targetCount = math.max(0, math.min(targetCount or 0, Config.MaxChickensPerCoop or 20))

    if targetCount > currentCount then
        local model = Config.ChickenModel
        lib.requestModel(model, 5000)
        if not HasModelLoaded(model) then
            lib.notify({ title = locale('cl_chickencoop_title_1'), description = locale('cl_chickencoop_description_2'), type = 'error' })
            if Config.Debug then
                print('^1[CHICKENCOOP]^7 Failed to load chicken model for coop ' .. key)
            end
            return
        end

        for _ = currentCount + 1, targetCount do
            local radius = Config.ChickenWanderRadius or 8.0
            local angle = math.random() * 2 * math.pi
            local dist = math.random() * radius
            local spawnX = coopVec.x + (math.cos(angle) * dist)
            local spawnY = coopVec.y + (math.sin(angle) * dist)
            local foundGround, groundZ = GetGroundZFor_3dCoord(spawnX, spawnY, coopVec.z + 5.0, false)
            local spawnZ = foundGround and groundZ or coopVec.z

            local ped = CreatePed(model, spawnX, spawnY, spawnZ, math.random(0, 359) + 0.0, false, false, 0, 0)
            if DoesEntityExist(ped) then
                SetRandomOutfitVariation(ped, true)
                SetEntityAsMissionEntity(ped, true, true)
                SetPedCanBeTargetted(ped, false)
                SetBlockingOfNonTemporaryEvents(ped, true)
                SetEntityInvincible(ped, true)
                SetPedFleeAttributes(ped, 0, false)
                SetModelAsNoLongerNeeded(model)

                table.insert(entry.chickens, ped)
                StartChickenWander(ped, coopVec)
            end
        end
    elseif targetCount < currentCount then
        for i = currentCount, targetCount + 1, -1 do
            local ped = entry.chickens[i]
            if ped and DoesEntityExist(ped) then
                DeletePed(ped)
            end
            table.remove(entry.chickens, i)
        end
    end
end

---------------------------------------------
-- Spawn a chicken coop prop locally
-- (static prop - spawned locally per-client rather than networked, same approach
-- used for feed troughs and water troughs, to avoid network entity overhead)
---------------------------------------------
local function SpawnChickenCoop(data)
    local key = tostring(data.coopid)

    if chickenCoopExists(key) then
        chickenCoopCache[key].data = data
        SetChickenPedCount(key, data.chickens or 0)
        return
    end

    local model = Config.ChickenCoopModel
    lib.requestModel(model, 5000)
    if not HasModelLoaded(model) then
        if Config.Debug then
            print('^1[CHICKENCOOP]^7 Failed to load model for chicken coop ' .. key)
        end
        return
    end

    local entity = CreateObject(model, data.pos_x, data.pos_y, data.pos_z, false, false, false)
    if not DoesEntityExist(entity) then
        return
    end

    -- A heading set in the same tick an object is created can silently fail to fully
    -- apply on some props (the entity isn't done initializing yet) - give it a frame
    -- and re-assert to make sure it actually sticks. Config.ChickenCoopHeadingOffset also
    -- corrects for this cart model's default pivot facing being ~90 degrees off.
    local finalHeading = ((data.pos_w or 0.0) + (Config.ChickenCoopHeadingOffset or 0.0)) % 360.0
    SetEntityHeading(entity, finalHeading)
    Wait(0)
    if DoesEntityExist(entity) then
        SetEntityHeading(entity, finalHeading)
    end

    FreezeEntityPosition(entity, true)
    SetEntityInvincible(entity, true)
    SetModelAsNoLongerNeeded(model)

    chickenCoopCache[key] = {
        data = data,
        entity = entity,
        chickens = {}
    }

    exports.ox_target:addLocalEntity(entity, {
        {
            name = 'ranch_chickencoop_check',
            label = locale('cl_chickencoop_label_3'),
            onSelect = function()
                RSGCore.Functions.TriggerCallback('rsg-ranch:server:getChickenCoopStatus', function(status)
                    if not status then
                        lib.notify({ title = locale('cl_chickencoop_title_4'), description = locale('cl_chickencoop_description_5'), type = 'error' })
                        return
                    end
                    lib.notify({
                        title = locale('cl_chickencoop_title_6'),
                        description = locale('cl_chickencoop_description_7'):format(status.chickens, Config.MaxChickensPerCoop, status.eggsReady,
                            status.feedLevel, status.maxFeedLevel or Config.ChickenCoopMaxFeedLevel or 100),
                        type = 'inform'
                    })
                end, data.coopid)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = Config.ChickenCoopInteractDistance or 2.5
        },
        {
            name = 'ranch_chickencoop_feed',
            label = locale('cl_chickencoop_label_8'),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:feedChickenCoop', data.coopid)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = Config.ChickenCoopInteractDistance or 2.5
        },
        {
            name = 'ranch_chickencoop_buy',
            label = locale('cl_chickencoop_label_9'):format(Config.ChickenBuyPrice),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:buyChicken', data.coopid)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = Config.ChickenCoopInteractDistance or 2.5
        },
        {
            name = 'ranch_chickencoop_collect',
            label = locale('cl_chickencoop_label_10'),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:collectEggs', data.coopid)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = Config.ChickenCoopInteractDistance or 2.5
        },
        {
            name = 'ranch_chickencoop_delete',
            label = locale('cl_chickencoop_label_11'),
            onSelect = function()
                local alert = Menu.alertDialog({
                    header = locale('cl_chickencoop_header_12'),
                    content = locale('cl_chickencoop_content_13'),
                    centered = true,
                    cancel = true
                })
                if alert == 'confirm' then
                    TriggerServerEvent('rsg-ranch:server:deleteChickenCoop', data.coopid)
                end
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = Config.ChickenCoopInteractDistance or 2.5
        }
    })

    SetChickenPedCount(key, data.chickens or 0)

    if Config.Debug then
        print('^2[CHICKENCOOP]^7 Spawned chicken coop ' .. key .. ' (chickens: ' .. tostring(data.chickens) .. ')')
    end
end

---------------------------------------------
-- Remove a chicken coop prop (and its chickens) locally
---------------------------------------------
local function DespawnChickenCoop(coopid)
    local key = tostring(coopid)
    local entry = chickenCoopCache[key]
    if not entry then return end

    if entry.entity and DoesEntityExist(entry.entity) then
        exports.ox_target:removeLocalEntity(entry.entity, {'ranch_chickencoop_check', 'ranch_chickencoop_feed', 'ranch_chickencoop_buy', 'ranch_chickencoop_collect', 'ranch_chickencoop_delete'})
        DeleteObject(entry.entity)
    end

    for _, ped in ipairs(entry.chickens or {}) do
        if DoesEntityExist(ped) then
            DeletePed(ped)
        end
    end

    chickenCoopCache[key] = nil

    if Config.Debug then
        print('^1[CHICKENCOOP]^7 Removed chicken coop ' .. key)
    end
end

---------------------------------------------
-- Placement preview flow (triggered by using the chickencoop item)
-- Uses the shared raycast/native-prompt placer in propplacer.lua.
---------------------------------------------
local function StartChickenCoopPlacement()
    StartPropPlacement(Config.ChickenCoopModel, {
        maxDistance = Config.ChickenCoopPlaceDistance or 5.0,
        onConfirm = function(coords, heading)
            TriggerServerEvent('rsg-ranch:server:placeChickenCoop', coords.x, coords.y, coords.z, heading)
        end,
        onCancel = function()
            lib.notify({ title = locale('cl_chickencoop_title_14'), description = locale('cl_chickencoop_description_15'), type = 'inform' })
        end
    })
end

RegisterNetEvent('rsg-ranch:client:startChickenCoopPlacement', function()
    StartChickenCoopPlacement()
end)

---------------------------------------------
-- Server Communication Events
---------------------------------------------

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('rsg-ranch:server:refreshChickenCoops')
end)

-- Full list (on load/refresh)
RegisterNetEvent('rsg-ranch:client:spawnChickenCoops', function(coopList)
    for _, data in ipairs(coopList or {}) do
        SpawnChickenCoop(data)
    end
end)

-- Single new chicken coop (just placed by someone)
RegisterNetEvent('rsg-ranch:client:spawnChickenCoop', function(data)
    SpawnChickenCoop(data)
end)

-- Chicken coop was deleted
RegisterNetEvent('rsg-ranch:client:removeChickenCoop', function(coopid)
    DespawnChickenCoop(coopid)
end)

-- Chicken count changed (bought a chicken, or eggs collected doesn't change count but resyncs anyway)
RegisterNetEvent('rsg-ranch:client:updateChickenCoop', function(coopid, chickens)
    local key = tostring(coopid)
    local entry = chickenCoopCache[key]
    if entry and entry.data then
        entry.data.chickens = chickens
        SetChickenPedCount(key, chickens)
    end
end)

---------------------------------------------
-- Cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for key in pairs(chickenCoopCache) do
        DespawnChickenCoop(key)
    end
end)

---------------------------------------------
-- Initialize on resource start (in case player is already loaded, e.g. resource restart)
---------------------------------------------
CreateThread(function()
    Wait(2000)
    if cache.ped and DoesEntityExist(cache.ped) then
        TriggerServerEvent('rsg-ranch:server:refreshChickenCoops')
    end
end)
