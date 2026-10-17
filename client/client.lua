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

local function ClearLocationBlips()
    for _, blip in ipairs(createdBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    createdBlips = {}
end

function RebuildRanchBlips()
    ClearLocationBlips()
    AddLocationBlips(Config.RanchLocations)
    AddLocationBlips(Config.BuyPointLocations)
    AddLocationBlips(Config.SalePointLocations)
end

-- admin-panel overrides (name / blip / price) and admin-created ranches pushed by the server
RegisterNetEvent('rsg-ranch:client:applyRanchSettings', function(settings)
    if type(settings) ~= 'table' then return end

    -- drop admin-created ranches that no longer exist
    for i = #Config.RanchLocations, 1, -1 do
        local r = Config.RanchLocations[i]
        if r.custom and not settings[r.ranchid] then table.remove(Config.RanchLocations, i) end
    end

    local known = {}
    for _, r in ipairs(Config.RanchLocations) do known[r.ranchid] = r end

    for ranchid, s in pairs(settings) do
        local r = known[ranchid]
        if s.custom and s.npc and s.spawn then
            if not r then
                r = { custom = true, ranchid = ranchid }
                Config.RanchLocations[#Config.RanchLocations + 1] = r
            end
            r.npcmodel = s.npcmodel
            r.jobaccess = s.jobaccess or ranchid
            r.blipsprite = s.blipsprite or 'blip_ambient_herd'
            r.blipscale = s.blipscale or 0.2
            r.npccoords = vector4(s.npc.x, s.npc.y, s.npc.z, s.npc.w or 0.0)
            r.coords = vector3(s.npc.x, s.npc.y, s.npc.z)
            r.spawnpoint = vector4(s.spawn.x, s.spawn.y, s.spawn.z, s.spawn.w or 0.0)
        end
        if r then
            r.name, r.blipname, r.price, r.showblip = s.name, s.blipname, s.price, s.showblip
        end
    end
    RebuildRanchBlips()
    TriggerEvent('rsg-ranch:client:ranchListChanged')
end)

CreateThread(function()
    local ok, settings = pcall(lib.callback.await, 'rsg-ranch:server:getRanchSettings', false)
    if ok and type(settings) == 'table' then
        TriggerEvent('rsg-ranch:client:applyRanchSettings', settings)
    else
        RebuildRanchBlips()
    end
end)

-- remove blips on restart so they don't stack up on the map
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    ClearLocationBlips()
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
