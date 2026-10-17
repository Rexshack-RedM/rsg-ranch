local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Ranch admin panel (client) - /ranchadmin
-- All data and actions go through server callbacks that re-check admin
-- permission, so this file only shuttles data between the NUI and server.
---------------------------------------------

local adminOpen = false
local function CloseAdmin()
    adminOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'admin:close' })
end

CreateThread(function()
    TriggerEvent('chat:addSuggestion', '/' .. ((Config.Admin and Config.Admin.Command) or 'ranchadmin'), locale('cl_adm_command_help'))
end)

RegisterNetEvent('rsg-ranch:client:openAdmin', function()
    if adminOpen then return end
    local overview = lib.callback.await('rsg-ranch:admin:getOverview', false)
    if not overview then return end
    adminOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'admin:open', locales = GetUiLocales(), data = overview })
end)

RegisterNUICallback('admin:close', function(_, cb)
    CloseAdmin()
    cb('ok')
end)

RegisterNUICallback('admin:overview', function(_, cb)
    cb(lib.callback.await('rsg-ranch:admin:getOverview', false) or {})
end)

RegisterNUICallback('admin:getRanch', function(data, cb)
    cb(lib.callback.await('rsg-ranch:admin:getRanch', false, data.ranchid) or {})
end)

RegisterNUICallback('admin:action', function(data, cb)
    if not adminOpen or type(data) ~= 'table' then return cb({ ok = false }) end
    cb(lib.callback.await('rsg-ranch:admin:action', false, data.ranchid, data.kind, data.data or {}) or { ok = false })
end)

RegisterNUICallback('admin:createRanch', function(data, cb)
    cb(lib.callback.await('rsg-ranch:admin:createRanch', false, data or {}) or { ok = false })
end)

RegisterNUICallback('admin:searchPlayers', function(data, cb)
    cb(lib.callback.await('rsg-ranch:admin:searchPlayers', false, data and data.query or '') or {})
end)

-- teleport: same logic as rsg-core's /tp command (RSGCore:Command:TeleportToCoords)
local function SafeTeleport(x, y, z, heading)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    if IsScreenFadedOut() or IsScreenFadingOut() then DoScreenFadeIn(0) end -- clear any black screen left by the old teleport
    SetEntityCoords(ped, x, y, z + 1.0) -- +1 so we land on top of the floor, not inside it
    if heading then SetEntityHeading(ped, heading + 0.0) end
end

RegisterNUICallback('admin:teleport', function(data, cb)
    cb('ok')
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if not x or not y or not z then return end
    local w = tonumber(data.w)
    CloseAdmin()
    CreateThread(function() SafeTeleport(x, y, z, w) end)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName and adminOpen then
        SetNuiFocus(false, false)
    end
end)
