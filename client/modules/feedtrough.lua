local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Core Variables
---------------------------------------------
local feedTroughCache = {} -- [feedtroughid] = { data = {...}, entity = objectHandle }

---------------------------------------------
-- Helper: distance-safe entity check
---------------------------------------------
local function feedTroughExists(feedtroughid)
    local entry = feedTroughCache[tostring(feedtroughid)]
    return entry ~= nil and entry.entity ~= nil and DoesEntityExist(entry.entity)
end

---------------------------------------------
-- Spawn a feed trough prop locally
-- (static feed prop - spawned locally per-client rather than networked, similar
-- to other decorative/interactive stash-style props, to avoid network entity overhead)
---------------------------------------------
local function SpawnFeedTrough(data)
    local key = tostring(data.feedtroughid)

    if feedTroughExists(key) then
        -- Already spawned, just make sure cached data (uses) is current
        feedTroughCache[key].data = data
        return
    end

    local model = Config.FeedTroughModel
    lib.requestModel(model, 5000)
    if not HasModelLoaded(model) then
        if Config.Debug then
            print('^1[FEEDTROUGH]^7 Failed to load model for feed trough ' .. key)
        end
        return
    end

    local entity = CreateObject(model, data.pos_x, data.pos_y, data.pos_z, false, false, false)
    if not DoesEntityExist(entity) then
        return
    end

    -- A heading set in the same tick an object is created can silently fail to fully
    -- apply on some props (the entity isn't done initializing yet) - give it a frame
    -- and re-assert to make sure it actually sticks. Config.FeedTroughHeadingOffset also
    -- corrects for the model's default pivot facing, if needed.
    local finalHeading = ((data.pos_w or 0.0) + (Config.FeedTroughHeadingOffset or 0.0)) % 360.0
    SetEntityHeading(entity, finalHeading)
    Wait(0)
    if DoesEntityExist(entity) then
        SetEntityHeading(entity, finalHeading)
    end

    FreezeEntityPosition(entity, true)
    SetEntityInvincible(entity, true)
    SetModelAsNoLongerNeeded(model)

    feedTroughCache[key] = {
        data = data,
        entity = entity
    }

    exports.ox_target:addLocalEntity(entity, {
        {
            name = 'ranch_feedtrough',
            label = locale('cl_feedtrough_label_1'),
            onSelect = function()
                local entry = feedTroughCache[key]
                local uses = entry and entry.data and entry.data.uses or 0
                local maxUses = Config.FeedTroughUses or 10
                local pct = maxUses > 0 and math.floor((uses / maxUses) * 100) or 0
                lib.notify({ title = locale('cl_feedtrough_title_2'), description = locale('cl_feedtrough_description_3'):format(uses, maxUses, pct), type = 'inform' })
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        },
        {
            name = 'ranch_feedtrough_refill',
            label = locale('cl_feedtrough_label_4'),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:refillFeedTrough', data.feedtroughid)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        },
        {
            name = 'ranch_feedtrough_move',
            label = locale('cl_feedtrough_label_5'),
            onSelect = function()
                TriggerServerEvent('rsg-ranch:server:requestMoveFeedTrough', data.feedtroughid)
            end,
            canInteract = function()
                return isPlayerRanchStaff() and not IsPropPlacementActive()
            end,
            distance = 2.0
        },
        {
            name = 'ranch_feedtrough_delete',
            label = locale('cl_feedtrough_label_6'),
            onSelect = function()
                local alert = Menu.alertDialog({
                    header = locale('cl_feedtrough_header_7'),
                    content = locale('cl_feedtrough_content_8'),
                    centered = true,
                    cancel = true
                })
                if alert == 'confirm' then
                    TriggerServerEvent('rsg-ranch:server:deleteFeedTrough', data.feedtroughid)
                end
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        }
    })

    if Config.Debug then
        print('^2[FEEDTROUGH]^7 Spawned feed trough ' .. key .. ' (uses: ' .. tostring(data.uses) .. ')')
    end
end

---------------------------------------------
-- Remove a feed trough prop locally
---------------------------------------------
local function DespawnFeedTrough(feedtroughid)
    local key = tostring(feedtroughid)
    local entry = feedTroughCache[key]
    if not entry then return end

    if entry.entity and DoesEntityExist(entry.entity) then
        exports.ox_target:removeLocalEntity(entry.entity, {'ranch_feedtrough', 'ranch_feedtrough_refill', 'ranch_feedtrough_move', 'ranch_feedtrough_delete'})
        DeleteObject(entry.entity)
    end

    feedTroughCache[key] = nil

    if Config.Debug then
        print('^1[FEEDTROUGH]^7 Removed feed trough ' .. key)
    end
end

---------------------------------------------
-- Find the nearest usable feed trough to a set of coords, for a given ranch
-- Exported so animals.lua can pull an animal towards a bale when hungry
---------------------------------------------
-- Intentionally global (not local) so animals.lua can call it directly within
-- the same resource's Lua state without going through the exports table.
function GetNearestFeedTrough(coords, ranchid)
    local nearestKey, nearestData, nearestDist = nil, nil, nil

    for key, entry in pairs(feedTroughCache) do
        local data = entry.data
        if data and data.uses and data.uses > 0 and data.ranchid == ranchid then
            local pos = vector3(data.pos_x, data.pos_y, data.pos_z)
            local distance = #(coords - pos)
            if distance <= (Config.FeedTroughSearchRadius or 30.0) and (not nearestDist or distance < nearestDist) then
                nearestKey, nearestData, nearestDist = key, data, distance
            end
        end
    end

    if nearestData then
        return { feedtroughid = nearestData.feedtroughid, pos = vector3(nearestData.pos_x, nearestData.pos_y, nearestData.pos_z), distance = nearestDist }
    end

    return nil
end

exports('GetNearestFeedTrough', GetNearestFeedTrough)

---------------------------------------------
-- Placement preview flow (triggered by using the feedtrough item)
-- Uses the shared raycast/native-prompt placer in propplacer.lua.
---------------------------------------------
local function StartFeedTroughPlacement()
    StartPropPlacement(Config.FeedTroughModel, {
        maxDistance = Config.FeedTroughPlaceDistance or 5.0,
        onConfirm = function(coords, heading)
            TriggerServerEvent('rsg-ranch:server:placeFeedTrough', coords.x, coords.y, coords.z, heading)
        end,
        onCancel = function()
            lib.notify({ title = locale('cl_feedtrough_title_9'), description = locale('cl_feedtrough_description_10'), type = 'inform' })
        end
    })
end

RegisterNetEvent('rsg-ranch:client:startFeedTroughPlacement', function()
    StartFeedTroughPlacement()
end)

---------------------------------------------
-- Move preview flow (triggered by "Move Feed Trough" via ox_target, once the
-- server has confirmed the player owns/is near the trough). The existing local
-- prop is hidden for the mover during the preview and restored on cancel; on
-- confirm every client (including this one) relocates their local prop once the
-- server broadcasts the new position.
---------------------------------------------
local function StartFeedTroughMove(feedtroughid)
    local key = tostring(feedtroughid)
    local entry = feedTroughCache[key]
    if not entry then return end

    local hadEntity = entry.entity and DoesEntityExist(entry.entity)
    if hadEntity then
        exports.ox_target:removeLocalEntity(entry.entity, {'ranch_feedtrough', 'ranch_feedtrough_refill', 'ranch_feedtrough_move', 'ranch_feedtrough_delete'})
        DeleteObject(entry.entity)
        entry.entity = nil
    end

    local started = StartPropPlacement(Config.FeedTroughModel, {
        maxDistance = Config.FeedTroughPlaceDistance or 5.0,
        onConfirm = function(coords, heading)
            TriggerServerEvent('rsg-ranch:server:confirmMoveFeedTrough', feedtroughid, coords.x, coords.y, coords.z, heading)
        end,
        onCancel = function()
            lib.notify({ title = locale('cl_feedtrough_title_11'), description = locale('cl_feedtrough_description_12'), type = 'inform' })
            if feedTroughCache[key] then
                SpawnFeedTrough(feedTroughCache[key].data)
            end
        end
    })

    if not started and feedTroughCache[key] then
        SpawnFeedTrough(feedTroughCache[key].data)
    end
end

RegisterNetEvent('rsg-ranch:client:startFeedTroughMove', function(feedtroughid)
    StartFeedTroughMove(feedtroughid)
end)

-- Broadcast after a move is confirmed server-side - every client relocates (or spawns,
-- if they didn't have it cached for some reason) their own local prop.
RegisterNetEvent('rsg-ranch:client:moveFeedTrough', function(feedtroughid, pos_x, pos_y, pos_z, pos_w)
    local key = tostring(feedtroughid)
    local entry = feedTroughCache[key]

    if entry then
        entry.data.pos_x = pos_x
        entry.data.pos_y = pos_y
        entry.data.pos_z = pos_z
        entry.data.pos_w = pos_w

        if entry.entity and DoesEntityExist(entry.entity) then
            SetEntityCoords(entry.entity, pos_x, pos_y, pos_z, false, false, false, false)
            SetEntityHeading(entry.entity, ((pos_w or 0.0) + (Config.FeedTroughHeadingOffset or 0.0)) % 360.0)
        else
            SpawnFeedTrough(entry.data)
        end
    else
        SpawnFeedTrough({ feedtroughid = feedtroughid, pos_x = pos_x, pos_y = pos_y, pos_z = pos_z, pos_w = pos_w, ranchid = nil, uses = Config.FeedTroughUses })
    end
end)

---------------------------------------------
-- Server Communication Events
---------------------------------------------

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('rsg-ranch:server:refreshFeedTroughs')
end)

-- Full list (on load/refresh)
RegisterNetEvent('rsg-ranch:client:spawnFeedTroughs', function(feedtroughList)
    for _, data in ipairs(feedtroughList or {}) do
        SpawnFeedTrough(data)
    end
end)

-- Single new feed trough (just placed by someone)
RegisterNetEvent('rsg-ranch:client:spawnFeedTrough', function(data)
    SpawnFeedTrough(data)
end)

-- Feed trough was manually removed by ranch staff
RegisterNetEvent('rsg-ranch:client:removeFeedTrough', function(feedtroughid)
    DespawnFeedTrough(feedtroughid)
end)

-- Feed trough uses updated after a feed
RegisterNetEvent('rsg-ranch:client:updateFeedTroughUses', function(feedtroughid, uses)
    local entry = feedTroughCache[tostring(feedtroughid)]
    if entry and entry.data then
        entry.data.uses = uses
    end
end)

---------------------------------------------
-- Cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for key in pairs(feedTroughCache) do
        DespawnFeedTrough(key)
    end
end)

---------------------------------------------
-- Initialize on resource start (in case player is already loaded, e.g. resource restart)
---------------------------------------------
CreateThread(function()
    Wait(2000)
    if cache.ped and DoesEntityExist(cache.ped) then
        TriggerServerEvent('rsg-ranch:server:refreshFeedTroughs')
    end
end)
