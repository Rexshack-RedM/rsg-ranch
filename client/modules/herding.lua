local RSGCore = exports['rsg-core']:GetCoreObject()
local herdingActive = false
local herdedAnimals = {}
local herdingTarget = nil
local herdingThreadId = nil -- Changed from boolean to thread ID
local herdingStartTime = nil
local selectedAnimals = {} -- For individual animal selection
local selectionMode = false -- Whether we're in selection mode
-- Blip tracking removed
lib.locale()

---------------------------------------------
-- herding command/keybind
---------------------------------------------
RegisterCommand('herd', function(source, args, rawCommand)
    if not Config.HerdingEnabled then
        lib.notify({ title = locale('cl_herding_title_1'), description = locale('cl_herding_description_2'), type = 'error' })
        return
    end
    
    local PlayerData = RSGCore.Functions.GetPlayerData()
    if not PlayerData or not PlayerData.job then
        return
    end
    
    -- Check if player works at a ranch
    local isRancher = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if PlayerData.job.name == ranchData.jobaccess then
            isRancher = true
            break
        end
    end
    
    if not isRancher then
        lib.notify({ title = locale('cl_herding_title_3'), description = locale('cl_herding_description_4'), type = 'error' })
        return
    end

    -- Trainees (grade 0) cannot herd - it becomes available once promoted to Ranch Hand
    if PlayerData.job.grade and PlayerData.job.grade.level < 1 then
        lib.notify({ title = locale('cl_herding_title_5'), description = locale('cl_herding_description_6'), type = 'error' })
        return
    end

    -- Check if player has required tool (if enabled)
    if Config.RequireHerdingTool then
        local hasItem = RSGCore.Functions.HasItem(Config.HerdingTool, 1)
        if not hasItem then
            lib.notify({ title = locale('cl_herding_title_7'), description = locale('cl_herding_description_8'):format(Config.HerdingTool), type = 'error' })
            return
        end
    end
    
    TriggerEvent('rsg-ranch:client:openHerdingMenu')
end, false)

---------------------------------------------
-- herding menu
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:openHerdingMenu', function()
    -- Debug: Check for nearby animals
    if Config.Debug then
        local nearbyAnimals = GetNearbyAnimals()
        print('^3[HERDING DEBUG]^7 Found ' .. #nearbyAnimals .. ' nearby animals')
        for i, animal in ipairs(nearbyAnimals) do
            print('^3[HERDING DEBUG]^7 Animal ' .. i .. ': ID=' .. tostring(animal.id) .. ', Model=' .. tostring(animal.model) .. ', Distance=' .. tostring(math.floor(animal.distance * 10) / 10) .. 'm')
        end
    end
    
    if herdingActive then
        Menu.registerContext({
            id = 'herding_active_menu',
            title = locale('cl_herding_title_9'),
            options = {
                {
                    title = locale('cl_herding_title_10'),
                    description = locale('cl_herding_description_11'):format(#herdedAnimals),
                    event = 'rsg-ranch:client:stopHerding'
                },
                {
                    title = locale('cl_herding_title_12'),
                    description = locale('cl_herding_description_13'):format(#herdedAnimals),
                    disabled = true
                }
            }
        })
        Menu.showContext('herding_active_menu')
    else
        local options = {
            {
                title = locale('cl_herding_title_14'),
                description = locale('cl_herding_description_15'):format(Config.HerdingDistance),
                event = 'rsg-ranch:client:startDistanceHerding'
            },
            {
                title = locale('cl_herding_title_16'),
                description = locale('cl_herding_description_17'),
                event = 'rsg-ranch:client:showTypeMenu',
                arrow = true
            }
        }
        
        -- Add individual selection option if enabled
        if Config.IndividualSelectionEnabled then
            table.insert(options, {
                title = locale('cl_herding_title_18'),
                description = locale('cl_herding_description_19'),
                event = 'rsg-ranch:client:showIndividualSelectionMenu',
                arrow = true
            })
        end
        
        Menu.registerContext({
            id = 'herding_menu',
            title = locale('cl_herding_title_20'),
            options = options
        })
        Menu.showContext('herding_menu')
    end
end)

---------------------------------------------
-- animal type selection menu
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:showTypeMenu', function()
    local nearbyAnimals = GetNearbyAnimals()
    local animalTypes = {}
    local typeCounts = {}
    
    -- Count animals by type
    for _, animalData in pairs(nearbyAnimals) do
        local model = animalData.model
        if not animalTypes[model] then
            animalTypes[model] = true
            typeCounts[model] = 0
        end
        typeCounts[model] = typeCounts[model] + 1
    end
    
    local options = {}
    for model, _ in pairs(animalTypes) do
        local displayName = GetAnimalDisplayName(model)
        table.insert(options, {
            title = locale('cl_herding_title_21'):format(displayName),
            description = locale('cl_herding_description_22'):format(typeCounts[model], displayName),
            event = 'rsg-ranch:client:startTypeHerding',
            args = { animalType = model }
        })
    end
    
    if #options == 0 then
        table.insert(options, {
            title = locale('cl_herding_title_23'),
            description = locale('cl_herding_description_24'),
            disabled = true
        })
    end
    
    Menu.registerContext({
        id = 'herding_type_menu',
        title = locale('cl_herding_title_25'),
        menu = 'herding_menu',
        options = options
    })
    Menu.showContext('herding_type_menu')
end)

---------------------------------------------
-- individual animal selection menu
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:showIndividualSelectionMenu', function()
    local nearbyAnimals = GetNearbyAnimals()
    
    if #nearbyAnimals == 0 then
        lib.notify({ title = locale('cl_herding_title_26'), description = locale('cl_herding_description_27'), type = 'error' })
        return
    end
    
    local options = {}
    
    -- Add header option showing current selection
    local selectedCount = 0
    for _ in pairs(selectedAnimals) do
        selectedCount = selectedCount + 1
    end
    
    table.insert(options, {
        title = locale('cl_herding_title_28'):format(selectedCount),
        description = locale('cl_herding_description_29'):format(selectedCount),
        disabled = true
    })
    
    if selectedCount > 0 then
        table.insert(options, {
            title = locale('cl_herding_title_30'),
            description = locale('cl_herding_description_31'):format(selectedCount),
            event = 'rsg-ranch:client:startSelectedHerding'
        })
        
        table.insert(options, {
            title = locale('cl_herding_title_32'),
            description = locale('cl_herding_description_33'),
            event = 'rsg-ranch:client:clearAnimalSelection'
        })
        
        table.insert(options, {
            title = locale('cl_herding_title_34'),
            disabled = true
        })
    end
    
    -- Add individual animals
    for i, animalData in ipairs(nearbyAnimals) do
        local isSelected = selectedAnimals[animalData.id] ~= nil
        local displayName = GetAnimalDisplayName(animalData.model)
        local distance = math.floor(animalData.distance * 10) / 10
        
        local statusIcon = isSelected and '✅' or '⬜'
        local statusText = isSelected and '[SELECTED]' or '[NOT SELECTED]'
        
        -- Build description based on config
        local description = locale('cl_herding_description_35')
        if Config.ShowAnimalDistance then
            description = locale('cl_herding_description_36'):format(distance, description)
        end
        
        table.insert(options, {
            title = locale('cl_herding_title_37'):format(statusIcon, displayName, i, statusText),
            description = description,
            event = 'rsg-ranch:client:toggleAnimalSelection',
            args = { 
                animalData = animalData,
                animalIndex = i
            }
        })
    end
    
    Menu.registerContext({
        id = 'herding_individual_menu',
        title = locale('cl_herding_title_38'),
        menu = 'herding_menu',
        options = options
    })
    Menu.showContext('herding_individual_menu')
end)

---------------------------------------------
-- toggle animal selection
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:toggleAnimalSelection', function(data)
    local animalData = data.animalData
    local animalId = animalData.id
    
    if selectedAnimals[animalId] then
        -- Deselect animal
        selectedAnimals[animalId] = nil
        lib.notify({ 
            title = locale('cl_herding_title_39'), 
            description = locale('cl_herding_description_40'):format(GetAnimalDisplayName(animalData.model)),
            type = 'inform'
        })
    else
        -- Check if we've reached the maximum
        local selectedCount = 0
        for _ in pairs(selectedAnimals) do
            selectedCount = selectedCount + 1
        end
        
        if selectedCount >= Config.HerdingMaxAnimals then
            lib.notify({ 
                title = locale('cl_herding_title_41'), 
                description = locale('cl_herding_description_42'):format(Config.HerdingMaxAnimals),
                type = 'error'
            })
            TriggerEvent('rsg-ranch:client:showIndividualSelectionMenu') -- Refresh menu
            return
        end
        
        -- Select animal
        selectedAnimals[animalId] = animalData
        lib.notify({ 
            title = locale('cl_herding_title_43'), 
            description = locale('cl_herding_description_44'):format(GetAnimalDisplayName(animalData.model)),
            type = 'success'
        })
    end
    
    -- Refresh the menu to show updated selection
    TriggerEvent('rsg-ranch:client:showIndividualSelectionMenu')
end)

---------------------------------------------
-- clear animal selection
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:clearAnimalSelection', function()
    local clearedCount = 0
    for _ in pairs(selectedAnimals) do
        clearedCount = clearedCount + 1
    end
    
    selectedAnimals = {}
    
    lib.notify({ 
        title = locale('cl_herding_title_45'), 
        description = locale('cl_herding_description_46'):format(clearedCount),
        type = 'inform'
    })
    
    -- Refresh the menu
    TriggerEvent('rsg-ranch:client:showIndividualSelectionMenu')
end)

---------------------------------------------
-- start herding selected animals
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:startSelectedHerding', function()
    if herdingActive then
        lib.notify({ title = locale('cl_herding_title_47'), description = locale('cl_herding_description_48'), type = 'error' })
        return
    end
    
    local selectedCount = 0
    local selectedList = {}
    for animalId, animalData in pairs(selectedAnimals) do
        -- Verify animal still exists and is nearby
        if DoesEntityExist(animalData.entity) then
            local playerPos = GetEntityCoords(cache.ped)
            local animalPos = GetEntityCoords(animalData.entity)
            local distance = #(playerPos - animalPos)
            
            if distance <= Config.HerdingDistance * Config.SelectionRangeMultiplier then
                table.insert(selectedList, animalData)
                selectedCount = selectedCount + 1
            end
        end
    end
    
    if selectedCount == 0 then
        lib.notify({ title = locale('cl_herding_title_49'), description = locale('cl_herding_description_50'), type = 'error' })
        selectedAnimals = {} -- Clear invalid selections
        return
    end
    
    -- Clear selection after starting herding
    selectedAnimals = {}
    
    StartHerding(selectedList, 'selected')
end)

---------------------------------------------
-- start distance-based herding
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:startDistanceHerding', function()
    if herdingActive then
        lib.notify({ title = locale('cl_herding_title_51'), description = locale('cl_herding_description_52'), type = 'error' })
        return
    end
    
    local nearbyAnimals = GetNearbyAnimals()
    if #nearbyAnimals == 0 then
        lib.notify({ title = locale('cl_herding_title_53'), description = locale('cl_herding_description_54'), type = 'error' })
        return
    end
    
    if #nearbyAnimals > Config.HerdingMaxAnimals then
        lib.notify({ title = locale('cl_herding_title_55'), description = locale('cl_herding_description_56'):format(#nearbyAnimals, Config.HerdingMaxAnimals), type = 'error' })
        return
    end
    
    StartHerding(nearbyAnimals, 'distance')
end)

---------------------------------------------
-- start type-based herding
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:startTypeHerding', function(data)
    if herdingActive then
        lib.notify({ title = locale('cl_herding_title_57'), description = locale('cl_herding_description_58'), type = 'error' })
        return
    end
    
    local nearbyAnimals = GetNearbyAnimals()
    local filteredAnimals = {}
    
    for _, animalData in pairs(nearbyAnimals) do
        if animalData.model == data.animalType then
            table.insert(filteredAnimals, animalData)
        end
    end
    
    if #filteredAnimals == 0 then
        lib.notify({ title = locale('cl_herding_title_59'), description = locale('cl_herding_description_60'), type = 'error' })
        return
    end
    
    if #filteredAnimals > Config.HerdingMaxAnimals then
        lib.notify({ title = locale('cl_herding_title_61'), description = locale('cl_herding_description_62'):format(#filteredAnimals, Config.HerdingMaxAnimals), type = 'error' })
        return
    end
    
    StartHerding(filteredAnimals, 'type')
end)

---------------------------------------------
-- stop herding
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:stopHerding', function()
    if not herdingActive then return end
    
    herdingActive = false
    
    -- Stop herding thread
    if herdingThreadId then
        herdingThreadId = nil
    end
    
    -- Collect animal IDs and clear tasks
    local animalIds = {}
    for animalId, animalInfo in pairs(herdedAnimals) do
        table.insert(animalIds, animalId)
        if DoesEntityExist(animalInfo.entity) then
            ClearPedTasks(animalInfo.entity)
            local pos = GetEntityCoords(animalInfo.entity)
            local heading = GetEntityHeading(animalInfo.entity)
            TriggerServerEvent('rsg-ranch:server:saveAnimalPosition', animalId, pos.x, pos.y, pos.z, heading)
        end
    end
    
    -- Disable transport mode
    if Config.TransportMode then
        TriggerEvent('rsg-ranch:client:setAnimalTransporting', animalIds, false)
        if Config.Debug then
            print('^2[HERDING DEBUG]^7 Disabled transport mode for ' .. #animalIds .. ' animals')
        end
    end
    
    -- Blip removal no longer needed
    
    local animalCount = #herdedAnimals
    herdedAnimals = {}
    herdingTarget = nil
    herdingStartTime = nil
    
    -- Clear any pending selections
    selectedAnimals = {}
    
    lib.notify({ 
        title = locale('cl_herding_title_63'), 
        description = locale('cl_herding_description_64'):format(animalCount), 
        type = 'success' 
    })
end)

---------------------------------------------
-- core herding functions
---------------------------------------------
function GetNearbyAnimals()
    local playerPos = GetEntityCoords(cache.ped)
    local nearbyAnimals = {}
    
    -- Try to get animal data cache, fall back to entity scanning if not available
    local animalDataCache = nil
    local success, result = pcall(function()
        return exports['rsg-ranch']:GetAnimalDataCache()
    end)
    
    if success and result then
        animalDataCache = result
    end
    
    -- Method 1: Use animal data cache (preferred)
    if animalDataCache and type(animalDataCache) == 'table' then
        if Config.Debug then
            print('^3[HERDING DEBUG]^7 Using animal data cache method, found ' .. #animalDataCache .. ' animals in cache')
        end
        for i, animalData in ipairs(animalDataCache) do
            if Config.Debug then
                print('^3[HERDING DEBUG]^7 Checking animal ' .. i .. ': ID=' .. tostring(animalData.animalid or 'nil') .. ', Model=' .. tostring(animalData.model or 'nil'))
            end
            
            if animalData and animalData.pos_x and animalData.pos_y and animalData.pos_z and animalData.animalid then
                local animalPos = vector3(animalData.pos_x, animalData.pos_y, animalData.pos_z)
                local distance = #(playerPos - animalPos)
                
                if Config.Debug then
                    print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' DB position: ' .. tostring(animalPos) .. ', Distance: ' .. tostring(math.floor(distance * 10) / 10) .. 'm')
                end
                
                if distance <= Config.HerdingDistance then
                    if Config.Debug then
                        print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' is within herding distance, checking for spawned entity')
                    end
                    
                    -- Try to get the actual spawned entity
                    local animalEntity = nil
                    pcall(function()
                        animalEntity = exports['rsg-ranch']:GetAnimalEntityById(animalData.animalid)
                    end)
                    
                    if Config.Debug then
                        print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' entity: ' .. tostring(animalEntity) .. ', exists: ' .. tostring(animalEntity and DoesEntityExist(animalEntity)))
                    end
                    
                    if animalEntity and DoesEntityExist(animalEntity) then
                        -- Update position to current entity position (more accurate)
                        animalPos = GetEntityCoords(animalEntity)
                        distance = #(playerPos - animalPos)
                        
                        if Config.Debug then
                            print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' actual position: ' .. tostring(animalPos) .. ', Distance: ' .. tostring(math.floor(distance * 10) / 10) .. 'm')
                        end
                        
                        if distance <= Config.HerdingDistance then
                            table.insert(nearbyAnimals, {
                                id = animalData.animalid,
                                entity = animalEntity,
                                model = animalData.model,
                                position = animalPos,
                                distance = distance
                            })
                            
                            if Config.Debug then
                                print('^2[HERDING DEBUG]^7 Added animal ' .. animalData.animalid .. ' to nearby list')
                            end
                        else
                            if Config.Debug then
                                print('^1[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' entity too far: ' .. tostring(math.floor(distance * 10) / 10) .. 'm')
                            end
                        end
                    else
                        if Config.Debug then
                            print('^1[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' has no spawned entity or entity does not exist')
                        end
                    end
                else
                    if Config.Debug then
                        print('^1[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' DB position too far: ' .. tostring(math.floor(distance * 10) / 10) .. 'm (max: ' .. Config.HerdingDistance .. 'm)')
                    end
                end
            else
                if Config.Debug then
                    print('^1[HERDING DEBUG]^7 Animal ' .. i .. ' has invalid data: pos_x=' .. tostring(animalData and animalData.pos_x) .. ', pos_y=' .. tostring(animalData and animalData.pos_y) .. ', pos_z=' .. tostring(animalData and animalData.pos_z) .. ', animalid=' .. tostring(animalData and animalData.animalid))
                end
            end
        end
    else
        -- Method 2: Fallback to entity scanning
        if Config.Debug then
            print('^3[HERDING DEBUG]^7 Using fallback entity scanning method')
        end
        local nearbyEntities = GetGamePool('CPed')
        
        for _, entity in ipairs(nearbyEntities) do
            if DoesEntityExist(entity) and entity ~= cache.ped then
                local entityModel = GetEntityModel(entity)
                local modelName = nil
                
                -- Check if this is a ranch animal by model
                if Config.AnimalProducts then
                    for model, _ in pairs(Config.AnimalProducts) do
                        if GetHashKey(model) == entityModel then
                            modelName = model
                            break
                        end
                    end
                end
                
                -- Also check for models that might not be in products config
                if not modelName then
                    local commonModels = {
                        [GetHashKey('a_c_cow')] = 'a_c_cow',
                        [GetHashKey('a_c_bull_01')] = 'a_c_bull_01'
                    }
                    modelName = commonModels[entityModel]
                end
                
                if modelName then
                    local animalPos = GetEntityCoords(entity)
                    local distance = #(playerPos - animalPos)
                    
                    if distance <= Config.HerdingDistance then
                        -- Use entity handle as ID for fallback method
                        table.insert(nearbyAnimals, {
                            id = entity,
                            entity = entity,
                            model = modelName,
                            position = animalPos,
                            distance = distance
                        })
                    end
                end
            end
        end
    end
    
    return nearbyAnimals
end

-- Note: GetAnimalDisplayName is defined once, in client/modules/salepoint.lua,
-- and shared globally across client modules.

function StartHerding(animals, herdType)
    herdingActive = true
    herdingStartTime = GetGameTimer()
    herdedAnimals = {}
    
    -- Convert animals to herded format
    local animalIds = {}
    for _, animalData in pairs(animals) do
        herdedAnimals[animalData.id] = {
            entity = animalData.entity,
            model = animalData.model,
            originalPos = animalData.position
        }
        table.insert(animalIds, animalData.id)
    end
    
    -- Enable transport mode to prevent despawning
    if Config.TransportMode then
        TriggerEvent('rsg-ranch:client:setAnimalTransporting', animalIds, true)
        if Config.Debug then
            print('^2[HERDING DEBUG]^7 Enabled transport mode for ' .. #animalIds .. ' animals')
        end
    end
    
    local animalCount = #animals
    local typeText
    if herdType == 'distance' then
        typeText = 'nearby'
    elseif herdType == 'selected' then
        typeText = 'selected'
    else
        typeText = 'selected type'
    end
    
    lib.notify({ 
        title = locale('cl_herding_title_65'), 
        description = locale('cl_herding_description_66'):format(animalCount, typeText), 
        type = 'success',
        duration = 5000
    })
    
    -- Start herding control thread
    herdingThreadId = CreateThread(function()
        local threadActive = true
        while herdingActive and threadActive do
            Wait(100)
            
            -- Check if we should still be running (thread wasn't cancelled)
            if not herdingActive or not herdingThreadId then
                threadActive = false
                break
            end
            
            -- Check timeout
            if herdingStartTime and (GetGameTimer() - herdingStartTime) > (Config.HerdingTimeout * 1000) then
                TriggerEvent('rsg-ranch:client:stopHerding')
                lib.notify({ title = locale('cl_herding_title_67'), description = locale('cl_herding_description_68'), type = 'inform' })
                break
            end
            
            -- Update animal following
            UpdateHerdingMovement()
        end
        
        -- Thread cleanup
        if Config.Debug then
            print('^3[HERDING DEBUG]^7 Herding thread ended')
        end
    end)
    
    -- Show herding instructions
    lib.notify({
        title = locale('cl_herding_title_69'),
        description = locale('cl_herding_description_70'),
        type = 'inform',
        duration = 8000
    })
end

function UpdateHerdingMovement()
    if not herdingActive or not cache.ped then return end
    
    local playerPos = GetEntityCoords(cache.ped)
    local playerSpeed = GetEntitySpeed(cache.ped)
    
    -- Update animal movement
    local animalIndex = 0
    for animalId, animalInfo in pairs(herdedAnimals) do
        if DoesEntityExist(animalInfo.entity) and not IsPedDeadOrDying(animalInfo.entity, true) then
            animalIndex = animalIndex + 1
            
            -- Only move animals if player is moving
            if playerSpeed > 0.1 then
                -- Calculate follow position (spread animals around player)
                local angle = (animalIndex * 60) * (math.pi / 180) -- Convert to radians
                local followDistance = Config.HerdingFollowDistance + (animalIndex * 0.5)
                local followPos = vector3(
                    playerPos.x + math.cos(angle) * followDistance,
                    playerPos.y + math.sin(angle) * followDistance,
                    playerPos.z
                )
                
                -- Set animal to follow to position
                ClearPedTasks(animalInfo.entity)
                TaskGoToCoordAnyMeans(animalInfo.entity, followPos.x, followPos.y, followPos.z, Config.HerdingSpeed, 0, false, 786603, 0xbf800000)
            end
        else
            -- Remove dead or non-existent animals
            herdedAnimals[animalId] = nil
        end
    end
    
    -- Check if all animals are gone
    local remainingAnimals = 0
    for _ in pairs(herdedAnimals) do
        remainingAnimals = remainingAnimals + 1
    end
    
    if remainingAnimals == 0 then
        TriggerEvent('rsg-ranch:client:stopHerding')
        lib.notify({ title = locale('cl_herding_title_71'), description = locale('cl_herding_description_72'), type = 'inform' })
    end
end

---------------------------------------------
-- cleanup on resource stop
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if herdingActive then
        TriggerEvent('rsg-ranch:client:stopHerding')
    end
    -- Clear any pending selections
    selectedAnimals = {}
end)

-- Additional selection management commands
RegisterCommand('herdselectstatus', function()
    if not Config.HerdingEnabled or not Config.IndividualSelectionEnabled then return end
    
    local selectedCount = 0
    for _ in pairs(selectedAnimals) do
        selectedCount = selectedCount + 1
    end
    
    if selectedCount == 0 then
        lib.notify({ title = locale('cl_herding_title_73'), description = locale('cl_herding_description_74'), type = 'inform' })
    else
        lib.notify({ 
            title = locale('cl_herding_title_75'), 
            description = locale('cl_herding_description_76'):format(selectedCount),
            type = 'inform',
            duration = 3000
        })
    end
end, false)

RegisterCommand('herdclear', function()
    if not Config.HerdingEnabled or not Config.IndividualSelectionEnabled then return end
    
    local clearedCount = 0
    for _ in pairs(selectedAnimals) do
        clearedCount = clearedCount + 1
    end
    
    if clearedCount > 0 then
        selectedAnimals = {}
        lib.notify({ 
            title = locale('cl_herding_title_77'), 
            description = locale('cl_herding_description_78'):format(clearedCount),
            type = 'success'
        })
    else
        lib.notify({ title = locale('cl_herding_title_79'), description = locale('cl_herding_description_80'), type = 'inform' })
    end
end, false)

-- herdblipstatus command removed

-- Note: Use /herd command to access herding menu
-- RegisterKeyMapping is not available in RedM
