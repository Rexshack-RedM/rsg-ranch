local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Core Variables
---------------------------------------------
local waterTroughCache = {} -- [watertroughid] = { data = {...}, entity = objectHandle }

---------------------------------------------
-- Helper: distance-safe entity check
---------------------------------------------
local function waterTroughExists(watertroughid)
    local entry = waterTroughCache[tostring(watertroughid)]
    return entry ~= nil and entry.entity ~= nil and DoesEntityExist(entry.entity)
end

---------------------------------------------
-- Spawn a water trough prop locally
-- (static feed prop - spawned locally per-client rather than networked, similar
-- to other decorative/interactive stash-style props, to avoid network entity overhead)
---------------------------------------------
local function SpawnWaterTrough(data)
    local key = tostring(data.watertroughid)

    if waterTroughExists(key) then
        -- Already spawned, just make sure cached data (uses) is current
        waterTroughCache[key].data = data
        return
    end

    local model = Config.WaterTroughModel
    lib.requestModel(model, 5000)
    if not HasModelLoaded(model) then
        if Config.Debug then
            print('^1[WATERTROUGH]^7 Failed to load model for water trough ' .. key)
        end
        return
    end

    local entity = CreateObject(model, data.pos_x, data.pos_y, data.pos_z, false, false, false)
    if not DoesEntityExist(entity) then
        return
    end

    -- A heading set in the same tick an object is created can silently fail to fully
    -- apply on some props (the entity isn't done initializing yet) - give it a frame
    -- and re-assert to make sure it actually sticks. Config.WaterTroughHeadingOffset also
    -- corrects for the model's default pivot facing, if needed.
    local finalHeading = ((data.pos_w or 0.0) + (Config.WaterTroughHeadingOffset or 0.0)) % 360.0
    SetEntityHeading(entity, finalHeading)
    Wait(0)
    if DoesEntityExist(entity) then
        SetEntityHeading(entity, finalHeading)
    end

    FreezeEntityPosition(entity, true)
    SetEntityInvincible(entity, true)
    SetModelAsNoLongerNeeded(model)

    waterTroughCache[key] = {
        data = data,
        entity = entity
    }

    exports.ox_target:addLocalEntity(entity, {
        {
            name = 'ranch_watertrough',
            label = locale('cl_watertroughs_label_1'),
            onSelect = function()
                local entry = waterTroughCache[key]
                local uses = entry and entry.data and entry.data.uses or 0
                local maxUses = Config.WaterTroughUses or 10
                local pct = maxUses > 0 and math.floor((uses / maxUses) * 100) or 0
                lib.notify({ title = locale('cl_watertroughs_title_2'), description = locale('cl_watertroughs_description_3'):format(uses, maxUses, pct), type = 'inform' })
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        },
        {
            name = 'ranch_watertrough_refill',
            label = locale('cl_watertroughs_label_4'),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:refillWaterTrough', data.watertroughid)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        },
        {
            name = 'ranch_watertrough_move',
            label = locale('cl_watertroughs_label_5'),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:requestMoveWaterTrough', data.watertroughid)
            end,
            canInteract = function()
                return isPlayerRanchStaff() and not IsPropPlacementActive()
            end,
            distance = 2.0
        },
        {
            name = 'ranch_watertrough_delete',
            label = locale('cl_watertroughs_label_6'),
            onSelect = function()
                local alert = Menu.alertDialog({
                    header = locale('cl_watertroughs_header_7'),
                    content = locale('cl_watertroughs_content_8'),
                    centered = true,
                    cancel = true
                })
                if alert == 'confirm' then
                    TriggerServerEvent('rsg-ranch:server:deleteWaterTrough', data.watertroughid)
                end
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        }
    })

    if Config.Debug then
        print('^2[WATERTROUGH]^7 Spawned water trough ' .. key .. ' (uses: ' .. tostring(data.uses) .. ')')
    end
end

---------------------------------------------
-- Remove a water trough prop locally
---------------------------------------------
local function DespawnWaterTrough(watertroughid)
    local key = tostring(watertroughid)
    local entry = waterTroughCache[key]
    if not entry then return end

    if entry.entity and DoesEntityExist(entry.entity) then
        exports.ox_target:removeLocalEntity(entry.entity, {'ranch_watertrough', 'ranch_watertrough_refill', 'ranch_watertrough_move', 'ranch_watertrough_delete'})
        DeleteObject(entry.entity)
    end

    waterTroughCache[key] = nil

    if Config.Debug then
        print('^1[WATERTROUGH]^7 Removed water trough ' .. key)
    end
end

---------------------------------------------
-- Find the nearest usable water trough to a set of coords, for a given ranch
-- Exported so animals.lua can pull an animal towards a trough when thirsty
---------------------------------------------
-- Intentionally global (not local) so animals.lua can call it directly within
-- the same resource's Lua state without going through the exports table.
function GetNearestWaterTrough(coords, ranchid)
    local nearestKey, nearestData, nearestDist = nil, nil, nil

    for key, entry in pairs(waterTroughCache) do
        local data = entry.data
        if data and data.uses and data.uses > 0 and data.ranchid == ranchid then
            local pos = vector3(data.pos_x, data.pos_y, data.pos_z)
            local distance = #(coords - pos)
            if distance <= (Config.WaterTroughSearchRadius or 30.0) and (not nearestDist or distance < nearestDist) then
                nearestKey, nearestData, nearestDist = key, data, distance
            end
        end
    end

    if nearestData then
        return { watertroughid = nearestData.watertroughid, pos = vector3(nearestData.pos_x, nearestData.pos_y, nearestData.pos_z), distance = nearestDist }
    end

    return nil
end

exports('GetNearestWaterTrough', GetNearestWaterTrough)

---------------------------------------------
-- Placement preview flow (triggered by using the watertrough item)
-- Uses the shared raycast/native-prompt placer in propplacer.lua.
---------------------------------------------
local function StartWaterTroughPlacement()
    StartPropPlacement(Config.WaterTroughModel, {
        maxDistance = Config.WaterTroughPlaceDistance or 5.0,
        onConfirm = function(coords, heading)
            TriggerServerEvent('rsg-ranch:server:placeWaterTrough', coords.x, coords.y, coords.z, heading)
        end,
        onCancel = function()
            lib.notify({ title = locale('cl_watertroughs_title_9'), description = locale('cl_watertroughs_description_10'), type = 'inform' })
        end
    })
end

RegisterNetEvent('rsg-ranch:client:startWaterTroughPlacement', function()
    StartWaterTroughPlacement()
end)

---------------------------------------------
-- Move preview flow (triggered by "Move Water Trough" via ox_target, once the
-- server has confirmed the player owns/is near the trough). The existing local
-- prop is hidden for the mover during the preview and restored on cancel; on
-- confirm every client (including this one) relocates their local prop once the
-- server broadcasts the new position.
---------------------------------------------
local function StartWaterTroughMove(watertroughid)
    local key = tostring(watertroughid)
    local entry = waterTroughCache[key]
    if not entry then return end

    local hadEntity = entry.entity and DoesEntityExist(entry.entity)
    if hadEntity then
        exports.ox_target:removeLocalEntity(entry.entity, {'ranch_watertrough', 'ranch_watertrough_refill', 'ranch_watertrough_move', 'ranch_watertrough_delete'})
        DeleteObject(entry.entity)
        entry.entity = nil
    end

    local started = StartPropPlacement(Config.WaterTroughModel, {
        maxDistance = Config.WaterTroughPlaceDistance or 5.0,
        onConfirm = function(coords, heading)
            TriggerServerEvent('rsg-ranch:server:confirmMoveWaterTrough', watertroughid, coords.x, coords.y, coords.z, heading)
        end,
        onCancel = function()
            lib.notify({ title = locale('cl_watertroughs_title_11'), description = locale('cl_watertroughs_description_12'), type = 'inform' })
            -- Respawn the prop where it still is according to our cached data
            if waterTroughCache[key] then
                SpawnWaterTrough(waterTroughCache[key].data)
            end
        end
    })

    -- Another placement was already active (shouldn't normally happen since the ox_target
    -- option is hidden while placing) - restore the prop we just hid rather than lose it.
    if not started and waterTroughCache[key] then
        SpawnWaterTrough(waterTroughCache[key].data)
    end
end

RegisterNetEvent('rsg-ranch:client:startWaterTroughMove', function(watertroughid)
    StartWaterTroughMove(watertroughid)
end)

-- Broadcast after a move is confirmed server-side - every client relocates (or spawns,
-- if they didn't have it cached for some reason) their own local prop.
RegisterNetEvent('rsg-ranch:client:moveWaterTrough', function(watertroughid, pos_x, pos_y, pos_z, pos_w)
    local key = tostring(watertroughid)
    local entry = waterTroughCache[key]

    if entry then
        entry.data.pos_x = pos_x
        entry.data.pos_y = pos_y
        entry.data.pos_z = pos_z
        entry.data.pos_w = pos_w

        if entry.entity and DoesEntityExist(entry.entity) then
            SetEntityCoords(entry.entity, pos_x, pos_y, pos_z, false, false, false, false)
            SetEntityHeading(entry.entity, ((pos_w or 0.0) + (Config.WaterTroughHeadingOffset or 0.0)) % 360.0)
        else
            SpawnWaterTrough(entry.data)
        end
    else
        SpawnWaterTrough({ watertroughid = watertroughid, pos_x = pos_x, pos_y = pos_y, pos_z = pos_z, pos_w = pos_w, ranchid = nil, uses = Config.WaterTroughUses })
    end
end)

---------------------------------------------
-- Server Communication Events
---------------------------------------------

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('rsg-ranch:server:refreshWaterTroughs')
end)

-- Full list (on load/refresh)
RegisterNetEvent('rsg-ranch:client:spawnWaterTroughs', function(watertroughList)
    for _, data in ipairs(watertroughList or {}) do
        SpawnWaterTrough(data)
    end
end)

-- Single new water trough (just placed by someone)
RegisterNetEvent('rsg-ranch:client:spawnWaterTrough', function(data)
    SpawnWaterTrough(data)
end)

-- Water trough ran out of uses and was removed
RegisterNetEvent('rsg-ranch:client:removeWaterTrough', function(watertroughid)
    DespawnWaterTrough(watertroughid)
end)

-- Water trough uses updated after a drink or refill
RegisterNetEvent('rsg-ranch:client:updateWaterTroughUses', function(watertroughid, uses)
    local entry = waterTroughCache[tostring(watertroughid)]
    if entry and entry.data then
        entry.data.uses = uses
    end
end)

---------------------------------------------
-- Cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for key in pairs(waterTroughCache) do
        DespawnWaterTrough(key)
    end
end)

---------------------------------------------
-- Initialize on resource start (in case player is already loaded, e.g. resource restart)
---------------------------------------------
CreateThread(function()
    Wait(2000)
    if cache.ped and DoesEntityExist(cache.ped) then
        TriggerServerEvent('rsg-ranch:server:refreshWaterTroughs')
    end
end)
