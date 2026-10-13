local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- map blips (ranches, buy points, sale points)
---------------------------------------------
local createdBlips = {}

local function AddLocationBlips(locations)
    for _, data in pairs(locations) do
        if data.showblip == true then
            local blip = BlipAddForCoords(1664425300, data.coords)
            SetBlipSprite(blip, joaat(data.blipsprite), true)
            SetBlipScale(blip, data.blipscale)
            SetBlipName(blip, data.blipname)
            createdBlips[#createdBlips + 1] = blip
        end
    end
end

CreateThread(function()
    AddLocationBlips(Config.RanchLocations)
    AddLocationBlips(Config.BuyPointLocations)
    AddLocationBlips(Config.SalePointLocations)
end)

-- remove blips on restart so they don't stack up on the map
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for _, blip in ipairs(createdBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    createdBlips = {}
end)

---------------------------------------------
-- open the correct menu for the player's role at this ranch
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:openranch', function(ranchid, jobaccess)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerjob = PlayerData.job.name
    local playerlevel = PlayerData.job.grade.level

    -- Check ownership before gating on job: an unowned ranch has nobody
    -- employed there yet, so any player can be offered the chance to buy it.
    RSGCore.Functions.TriggerCallback('rsg-ranch:server:getranchowner', function(owner)
        if not owner then
            TriggerEvent('rsg-ranch:client:openpurchasemenu', ranchid)
            return
        end

        if playerjob ~= jobaccess then
            lib.notify({ description = locale('cl_client_not_staff'), type = 'error' })
            return
        end

        if playerlevel >= Config.RanchBossGrade then
            TriggerEvent('rsg-ranch:client:openmanagermenu', ranchid)
        elseif playerlevel >= 1 then
            TriggerEvent('rsg-ranch:client:openranchhandmenu', ranchid)
        else
            TriggerEvent('rsg-ranch:client:opentraineemenu', ranchid)
        end
    end, ranchid)
end)
