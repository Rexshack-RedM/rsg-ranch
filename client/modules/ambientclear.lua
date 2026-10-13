---------------------------------------------
-- Clears the game's ambient NPCs and animals (scenario/population peds) from each ranch.
-- 1) a scenario blocking area stops new scenario peds (ranch hands, livestock, etc.) spawning
-- 2) a light loop deletes any ambient peds that still wander or spawn inside the radius
-- Only ambient peds are touched: anything created by a script (ranch animals, ranch NPCs,
-- player horses, other resources' peds) is a mission entity and is always left alone.
---------------------------------------------
local AC = Config.RanchAmbientClear
if not AC or not AC.enabled then return end

local zones = {}       -- { center = vector3, radius = number }
local blockAreas = {}

local function addBlockingArea(c, r)
    -- ADD_SCENARIO_BLOCKING_AREA(x1, y1, z1, x2, y2, z2, network, flags)
    return Citizen.InvokeNative(0x1B5C85C612E5256E, c.x - r, c.y - r, c.z - 50.0, c.x + r, c.y + r, c.z + 50.0, false, 15)
end

local function removeBlockingArea(id)
    -- REMOVE_SCENARIO_BLOCKING_AREA(id, network)
    Citizen.InvokeNative(0x31D16B74C6E29D66, id, false)
end

local function isAmbientPed(ped)
    if not DoesEntityExist(ped) then return false end
    if IsPedAPlayer(ped) then return false end
    if IsEntityAMissionEntity(ped) then return false end   -- script-spawned (ours or another resource's)
    -- don't delete a ped someone is riding, or the mount/cart a player is using
    local mount = GetMount(ped)
    if mount ~= 0 and IsPedAPlayer(mount) then return false end
    if IsPedOnMount(ped) and IsPedAPlayer(GetMount(ped)) then return false end
    local rider = GetRiderOfMount(ped, true)
    if rider ~= 0 and IsPedAPlayer(rider) then return false end
    if AC.keepHumans and IsPedHuman(ped) then return false end
    if AC.keepAnimals and not IsPedHuman(ped) then return false end
    return true
end

local function deletePed(ped)
    if NetworkGetEntityIsNetworked(ped) and not NetworkHasControlOfEntity(ped) then
        NetworkRequestControlOfEntity(ped)
        local t = GetGameTimer() + 500
        while not NetworkHasControlOfEntity(ped) and GetGameTimer() < t do Wait(0) end
        if not NetworkHasControlOfEntity(ped) then return end
    end
    SetEntityAsMissionEntity(ped, true, true)
    DeletePed(ped)
    if DoesEntityExist(ped) then DeleteEntity(ped) end
end

CreateThread(function()
    for _, ranch in pairs(Config.RanchLocations) do
        if ranch.clearambient ~= false then
            local center = ranch.clearcenter or ranch.coords
            local radius = ranch.clearradius or AC.radius
            zones[#zones + 1] = { center = vector3(center.x, center.y, center.z), radius = radius }
            if AC.blockScenarios then
                blockAreas[#blockAreas + 1] = addBlockingArea(center, radius)
            end
        end
    end

    while true do
        local sleep = AC.idleInterval
        local pc = GetEntityCoords(PlayerPedId())
        for _, z in ipairs(zones) do
            -- only work when the player is near enough for peds there to be streamed in
            if #(pc - z.center) < z.radius + AC.activeDistance then
                sleep = AC.checkInterval
                for _, ped in ipairs(GetGamePool('CPed')) do
                    if #(GetEntityCoords(ped) - z.center) <= z.radius and isAmbientPed(ped) then
                        deletePed(ped)
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, id in ipairs(blockAreas) do removeBlockingArea(id) end
end)
