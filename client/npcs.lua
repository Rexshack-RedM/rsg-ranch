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

CreateThread(function()
    while true do
        local playerCoords = GetEntityCoords(cache.ped)

        for k, npcData in pairs(Config.RanchLocations) do
            local npcCoords = vector3(npcData.npccoords.x, npcData.npccoords.y, npcData.npccoords.z)
            local distance = #(playerCoords - npcCoords)

            if distance < Config.DistanceSpawn and not spawnedPeds[k] then
                spawnedPeds[k] = SpawnRanchPed(npcData)
            elseif distance >= Config.DistanceSpawn and spawnedPeds[k] then
                DespawnRanchPed(spawnedPeds[k])
                spawnedPeds[k] = nil
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
