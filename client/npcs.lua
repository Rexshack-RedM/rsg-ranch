local spawnedPeds = {}

local function FadePed(ped, from, to, step)
    for alpha = from, to, step do
        if not DoesEntityExist(ped) then return end
        SetEntityAlpha(ped, alpha, false)
        Wait(50)
    end
end

local function SpawnRanchPed(npcData)
    lib.requestModel(npcData.npcmodel, 10000)

    local ped = CreatePed(npcData.npcmodel, npcData.npccoords.x, npcData.npccoords.y, npcData.npccoords.z - 1.0, npcData.npccoords.w, false, false, 0, 0)
    SetModelAsNoLongerNeeded(npcData.npcmodel)
    SetEntityAlpha(ped, 0, false)
    SetRandomOutfitVariation(ped, true)
    SetEntityCanBeDamaged(ped, false)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanBeTargetted(ped, false)
    SetPedFleeAttributes(ped, 0, false)

    if Config.FadeIn then
        FadePed(ped, 0, 255, 51)
    else
        SetEntityAlpha(ped, 255, false)
    end

    exports.ox_target:addLocalEntity(ped, {
        {
            name = 'npc_ranch',
            icon = 'far fa-eye',
            label = locale('cl_npcs_label_1'),
            onSelect = function()
                TriggerEvent('rsg-ranch:client:openranch', npcData.ranchid, npcData.jobaccess)
            end,
            distance = 2.0
        }
    })

    return ped
end

local function DespawnRanchPed(ped)
    if not DoesEntityExist(ped) then return end
    if Config.FadeIn then
        FadePed(ped, 255, 0, -51)
    end
    DeletePed(ped)
end

-- peds are keyed by ranchid (not list index) so admin-created ranches can be
-- added, moved or deleted at runtime without leaving orphaned NPCs behind
local spawnedAt = {}

CreateThread(function()
    while true do
        local playerCoords = GetEntityCoords(cache.ped)
        local present = {}

        for _, npcData in pairs(Config.RanchLocations) do
            local k = npcData.ranchid
            present[k] = true
            local npcCoords = vector3(npcData.npccoords.x, npcData.npccoords.y, npcData.npccoords.z)
            local distance = #(playerCoords - npcCoords)

            -- NPC was moved by an admin: respawn it at the new spot
            if spawnedPeds[k] and spawnedAt[k] and #(spawnedAt[k] - npcCoords) > 0.5 then
                DespawnRanchPed(spawnedPeds[k])
                spawnedPeds[k], spawnedAt[k] = nil, nil
            end

            if distance < Config.DistanceSpawn and not spawnedPeds[k] then
                spawnedPeds[k] = SpawnRanchPed(npcData)
                spawnedAt[k] = npcCoords
            elseif distance >= Config.DistanceSpawn and spawnedPeds[k] then
                DespawnRanchPed(spawnedPeds[k])
                spawnedPeds[k], spawnedAt[k] = nil, nil
            end
        end

        -- ranch deleted by an admin
        for k, ped in pairs(spawnedPeds) do
            if not present[k] then
                DespawnRanchPed(ped)
                spawnedPeds[k], spawnedAt[k] = nil, nil
            end
        end

        Wait(1000)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for k, ped in pairs(spawnedPeds) do
        if DoesEntityExist(ped) then
            DeletePed(ped)
        end
        spawnedPeds[k] = nil
    end
end)
