local RSGCore = exports['rsg-core']:GetCoreObject()
local salePointNPCs = {} -- Track spawned sale point NPCs
local salePointBlips = {} -- Track spawned sale point blips
lib.locale()

---------------------------------------------
-- sale point blips
---------------------------------------------
CreateThread(function()
    for i, salePointData in pairs(Config.SalePointLocations) do
        if salePointData.showblip == true then
            local SaleBlip = Citizen.InvokeNative(0x5A039BB0BCA604B6, joaat(salePointData.blipsprite), salePointData.coords.x, salePointData.coords.y, salePointData.coords.z)
            SetBlipSprite(SaleBlip, joaat(salePointData.blipsprite), true)
            SetBlipScale(SaleBlip, salePointData.blipscale)
            Citizen.InvokeNative(0x9CB1A1623062F402, SaleBlip, salePointData.blipname)
            salePointBlips[i] = SaleBlip -- Track the blip for cleanup
        end
    end
end)

---------------------------------------------
-- sale point npcs
---------------------------------------------
-- Function to clean up any existing sale point NPCs (in case of improper restart)
local function CleanupExistingSalePointNPCs()
    -- Get all peds in the world
    local allPeds = GetGamePool('CPed')
    local cleanedCount = 0
    
    for _, ped in ipairs(allPeds) do
        if DoesEntityExist(ped) and ped ~= cache.ped then
            -- Check if this ped is at a sale point location
            local pedCoords = GetEntityCoords(ped)
            for _, salePointData in pairs(Config.SalePointLocations) do
                local npcCoords = vector3(salePointData.npccoords.x, salePointData.npccoords.y, salePointData.npccoords.z)
                local distance = #(pedCoords - npcCoords)
                if distance < 2.0 and GetEntityModel(ped) == salePointData.npcmodel then
                    DeletePed(ped)
                    cleanedCount = cleanedCount + 1
                    break
                end
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[SALEPOINT DEBUG]^7 Cleaned up ' .. cleanedCount .. ' existing sale point NPCs before creating new ones')
    end
end

CreateThread(function()
    -- Clean up any existing NPCs first
    CleanupExistingSalePointNPCs()
    
    -- Wait a moment for cleanup to complete
    Wait(500)
    
    for i, salePointData in pairs(Config.SalePointLocations) do
        lib.requestModel(salePointData.npcmodel, 10000)
        
        local salePointNPC = CreatePed(salePointData.npcmodel, salePointData.npccoords.x, salePointData.npccoords.y, salePointData.npccoords.z - 1, salePointData.npccoords.w, false, true, 0, 0)
        Citizen.InvokeNative(0x283978A15512B2FE, salePointNPC, true)
        SetRandomOutfitVariation(salePointNPC, true)
        SetModelAsNoLongerNeeded(salePointData.npcmodel)
        SetPedCanBeTargetted(salePointNPC, false)
        SetEntityInvincible(salePointNPC, true)
        FreezeEntityPosition(salePointNPC, true)
        SetBlockingOfNonTemporaryEvents(salePointNPC, true)
        
        -- Track the NPC for cleanup
        salePointNPCs[i] = salePointNPC
        
        -- target interaction
        exports.ox_target:addLocalEntity(salePointNPC, {
            {
                name = 'sale_point_npc',
                label = locale('cl_salepoint_label_1'),
                onSelect = function()
                    TriggerEvent('rsg-ranch:client:openSaleMenu', salePointData)
                end,
                distance = 3.0
            }
        })
        
        if Config.Debug then
            print('^2[SALEPOINT DEBUG]^7 Created sale point NPC ' .. i .. ' (entity: ' .. salePointNPC .. ') at ' .. salePointData.name)
        end
    end
end)

---------------------------------------------
-- confirm sale
-- (plain local function, not a net event - this is a UI-only confirmation step,
-- keeping it as a local call removes it as remotely-triggerable attack surface)
---------------------------------------------
local function ConfirmSale(animal)
    local animalName = GetAnimalDisplayName(animal.model)

    -- Check if animal is nearby before showing confirmation (only if proximity is required)
    if Config.RequireAnimalPresent and not animal.isNearby then
        lib.notify({
            title = locale('cl_salepoint_title_5'),
            description = locale('cl_salepoint_description_6'):format((animal.distance or 'unknown')),
            type = 'error'
        })
        return
    end

    local alert = Menu.alertDialog({
        header = locale('cl_salepoint_header_7'),
        content = locale('cl_salepoint_content_8'):format(animal.ageCategory, animalName, animal.salePrice),
        centered = true,
        cancel = true
    })

    if alert == 'confirm' then
        -- Server recomputes the price and validates ownership/proximity itself;
        -- we only need to tell it which animal to sell.
        TriggerServerEvent('rsg-ranch:server:sellAnimal', animal.animalid)
        lib.notify({ title = locale('cl_salepoint_title_9'), description = locale('cl_salepoint_description_10'), type = 'inform' })
    end
end

---------------------------------------------
-- confirm sell all animals
---------------------------------------------
local function ConfirmSellAll(animals)
    if not animals or #animals == 0 then
        lib.notify({ title = locale('cl_salepoint_title_11'), description = locale('cl_salepoint_description_12'), type = 'error' })
        return
    end

    -- Calculate totals
    local totalValue = 0
    local animalCounts = {}

    for _, animal in ipairs(animals) do
        totalValue = totalValue + animal.salePrice
        local animalName = GetAnimalDisplayName(animal.model)
        animalCounts[animalName] = (animalCounts[animalName] or 0) + 1
    end

    -- Build summary string
    local summaryParts = {}
    for animalName, count in pairs(animalCounts) do
        table.insert(summaryParts, locale('cl_animal_count'):format(count, animalName))
    end
    local summary = table.concat(summaryParts, ', ')

    -- Show confirmation dialog
    local alert = Menu.alertDialog({
        header = locale('cl_salepoint_header_13'),
        content = locale('cl_salepoint_content_14'):format(summary, totalValue),
        centered = true,
        cancel = true
    })

    if alert == 'confirm' then
        -- Start selling process
        lib.notify({ title = locale('cl_salepoint_title_15'), description = locale('cl_salepoint_description_16'):format(#animals), type = 'inform' })

        -- Server recomputes prices and validates ownership/proximity for each animal;
        -- we only need to send the list of animal ids to sell.
        local animalIds = {}
        for _, animal in ipairs(animals) do
            table.insert(animalIds, animal.animalid)
        end
        TriggerServerEvent('rsg-ranch:server:sellAllAnimals', animalIds)
    end
end

---------------------------------------------
-- open sale menu
---------------------------------------------
RegisterNetEvent('rsg-ranch:client:openSaleMenu', function(salePointData)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerjob = PlayerData.job.name
    local joblevel = PlayerData.job.grade and PlayerData.job.grade.level or 0
    
    -- Check if player works at a ranch
    local isRancher = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.jobaccess == playerjob then
            isRancher = true
            break
        end
    end
    
    if not isRancher then
        lib.notify({ title = locale('cl_salepoint_title_17'), description = locale('cl_salepoint_description_18'), type = 'error' })
        return
    end
    
    -- Trainee Ranchers (level 0) cannot sell animals
    if joblevel < 1 then
        lib.notify({ title = locale('cl_salepoint_title_19'), description = locale('cl_salepoint_description_20'), type = 'error' })
        return
    end
    
    -- Get animals available for sale at this location
    RSGCore.Functions.TriggerCallback('rsg-ranch:server:getNearbyAnimalsForSale', function(animals)
        if not animals or #animals == 0 then
            if Config.RequireAnimalPresent then
                lib.notify({ title = locale('cl_salepoint_title_21'), description = locale('cl_salepoint_description_22'), type = 'inform' })
            else
                lib.notify({ title = locale('cl_salepoint_title_23'), description = locale('cl_salepoint_description_24'), type = 'inform' })
            end
            return
        end
        
        -- Separate nearby and distant animals
        local nearbyAnimals = {}
        local distantAnimals = {}
        
        for _, animal in ipairs(animals) do
            if animal.isNearby then
                table.insert(nearbyAnimals, animal)
            else
                table.insert(distantAnimals, animal)
            end
        end
        
        -- Create menu options
        local options = {}
        
        -- Add header showing nearby count
        if Config.RequireAnimalPresent then
            table.insert(options, {
                title = locale('cl_salepoint_title_25'):format(#nearbyAnimals),
                description = locale('cl_salepoint_description_26'):format(#distantAnimals, Config.AnimalSaleDistance),
                disabled = true
            })
            
            if #nearbyAnimals == 0 and #distantAnimals > 0 then
                table.insert(options, {
                    title = locale('cl_salepoint_title_27'),
                    description = locale('cl_salepoint_description_28'),
                    disabled = true
                })
            end
            
            -- Add sell all option if there are nearby animals
            if #nearbyAnimals > 1 then
                local totalValue = 0
                for _, animal in ipairs(nearbyAnimals) do
                    totalValue = totalValue + animal.salePrice
                end
                
                table.insert(options, {
                    title = locale('cl_salepoint_title_29'):format(#nearbyAnimals),
                    description = locale('cl_salepoint_description_30'):format(totalValue),
                    onSelect = function()
                        ConfirmSellAll(nearbyAnimals)
                    end,
                    arrow = true
                })
            end
            
            table.insert(options, {
                title = locale('cl_salepoint_title_31'),
                disabled = true
            })
        else
            -- For non-proximity mode, add sell all option if there are animals
            if #animals > 1 then
                local totalValue = 0
                for _, animal in ipairs(animals) do
                    totalValue = totalValue + animal.salePrice
                end
                
                table.insert(options, {
                    title = locale('cl_salepoint_title_32'):format(#animals),
                    description = locale('cl_salepoint_description_33'):format(totalValue),
                    onSelect = function()
                        ConfirmSellAll(animals)
                    end,
                    arrow = true
                })
                
                table.insert(options, {
                    title = locale('cl_salepoint_title_34'),
                    disabled = true
                })
            end
        end
        
        -- Add animals (sellable)
        local animalsToShow = nearbyAnimals
        if not Config.RequireAnimalPresent then
            -- When proximity is not required, show all animals as sellable
            animalsToShow = animals
        end
        
        for _, animal in ipairs(animalsToShow) do
            local animalName = GetAnimalDisplayName(animal.model)
            
            -- Health status indicator
            local healthStatus = ''
            if animal.health >= 80 then
                healthStatus = '🟢 Healthy'
            elseif animal.health >= 50 then
                healthStatus = '🟡 Fair'
            else
                healthStatus = '🔴 Poor'
            end
            
            local description = locale('cl_salepoint_description_35'):format(animal.age, healthStatus, animal.salePrice)
            if Config.RequireAnimalPresent and animal.distance then
                description = locale('cl_salepoint_description_36'):format(description, animal.distance)
            end
            
            table.insert(options, {
                title = locale('cl_salepoint_title_37'):format(animalName, animal.ageCategory),
                description = description,
                onSelect = function()
                    ConfirmSale(animal)
                end,
                arrow = true
            })
        end
        
        -- Add distant animals (not sellable) if proximity is required
        if Config.RequireAnimalPresent and #distantAnimals > 0 then
            table.insert(options, {
                title = locale('cl_salepoint_title_38'),
                disabled = true
            })
            
            for _, animal in ipairs(distantAnimals) do
                local animalName = GetAnimalDisplayName(animal.model)
                
                local healthStatus = ''
                if animal.health >= 80 then
                    healthStatus = '🟢 Healthy'
                elseif animal.health >= 50 then
                    healthStatus = '🟡 Fair'
                else
                    healthStatus = '🔴 Poor'
                end
                
                table.insert(options, {
                    title = locale('cl_salepoint_title_39'):format(animalName, animal.ageCategory),
                    description = locale('cl_salepoint_description_40'):format(animal.distance, Config.AnimalSaleDistance, animal.salePrice),
                    disabled = true
                })
            end
        end
        
        Menu.registerContext({
            id = 'sale_point_menu',
            title = salePointData.name,
            options = options
        })
        Menu.showContext('sale_point_menu')
        
    end, playerjob, salePointData.coords)
end)

---------------------------------------------
-- helper function to get animal display names
---------------------------------------------
function GetAnimalDisplayName(model)
    local displayNames = {
        ['a_c_bull_01'] = 'sv_animal_bull',
        ['a_c_cow'] = 'sv_animal_cow',
        ['a_c_pig_01'] = 'sv_animal_pig',
        ['a_c_sheep_01'] = 'sv_animal_sheep'
    }
    return locale(displayNames[model] or 'sv_animal_generic')
end

---------------------------------------------
-- cleanup on resource stop
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- Clean up sale point NPCs
    for i, npc in pairs(salePointNPCs) do
        if DoesEntityExist(npc) then
            exports.ox_target:removeLocalEntity(npc, 'sale_point_npc')
            DeletePed(npc)
        end
        salePointNPCs[i] = nil
    end
    
    -- Clean up sale point blips
    for i, blip in pairs(salePointBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        salePointBlips[i] = nil
    end
end)
