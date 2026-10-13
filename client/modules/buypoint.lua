local RSGCore = exports['rsg-core']:GetCoreObject()
local buyPointNPCs = {} -- Track spawned buy point NPCs
local buyPointBlips = {} -- Track spawned buy point blips
lib.locale()

---------------------------------------------
-- confirm animal purchase
-- (plain local function, not a net event - this is a UI-only confirmation step,
-- keeping it as a local call removes it as remotely-triggerable attack surface.
-- The server independently re-validates price, ranch ownership, and spawn point regardless.)
---------------------------------------------
local function ConfirmBuyAnimal(data)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerMoney = PlayerData.money.cash
    local totalPrice = data.price + (data.delivery and Config.LivestockDeliveryPrice or 0)

    -- Check if player has enough money
    if playerMoney < totalPrice then
        lib.notify({
            title = locale('cl_buypoint_title_1'),
            description = locale('cl_buypoint_description_2'):format(totalPrice, playerMoney),
            type = 'error'
        })
        return
    end

    -- Show confirmation dialog
    local animalDescriptor = data.animalName
    if data.gender == 'male' or data.gender == 'female' then
        animalDescriptor = locale('cl_gender_animal'):format(locale('ui_gender_' .. data.gender), data.animalName)
    end

    local content
    if data.delivery then
        content = locale('cl_buypoint_content_3'):format(animalDescriptor, data.price, Config.LivestockDeliveryPrice, totalPrice, data.ranchData.name)
    else
        content = locale('cl_buypoint_content_4'):format(animalDescriptor, totalPrice, data.buyPointData.name)
    end

    local alert = Menu.alertDialog({
        header = locale('cl_buypoint_header_5'),
        content = content,
        centered = true,
        cancel = true
    })

    if alert == 'confirm' then
        -- Process the purchase
        lib.notify({ title = locale('cl_buypoint_title_6'), description = locale('cl_buypoint_description_7'):format(data.animalName), type = 'inform' })

        TriggerServerEvent('rsg-ranch:server:buyAnimal', {
            animalType = data.animalType,
            animalName = data.animalName,
            price = data.price,
            ranchid = data.ranchData.ranchid,
            spawnpoint = data.buyPointData.spawnpoint,
            buyPointName = data.buyPointData.name,
            delivery = data.delivery == true,
            gender = data.gender
        })
    end
end

---------------------------------------------
-- gender choice
-- lets the player pick which gender to buy, for animal types where that's
-- configurable (currently only pigs - cattle come as separate bull/cow
-- purchase options already)
---------------------------------------------
local function OpenGenderChoice(data)
    Menu.registerContext({
        id = 'buy_point_gender_menu',
        title = locale('cl_buypoint_title_8'),
        menu = 'buy_point_menu',
        options = {
            {
                title = locale('cl_buypoint_title_9'),
                description = locale('cl_buypoint_description_10'):format(data.animalName),
                onSelect = function()
                    data.gender = 'male'
                    ConfirmBuyAnimal(data)
                end
            },
            {
                title = locale('cl_buypoint_title_11'),
                description = locale('cl_buypoint_description_12'):format(data.animalName),
                onSelect = function()
                    data.gender = 'female'
                    ConfirmBuyAnimal(data)
                end
            }
        }
    })
    Menu.showContext('buy_point_gender_menu')
end

---------------------------------------------
-- delivery option choice
-- lets the player pick between driving/herding the animal from the buy
-- point themselves (free) or paying to have it delivered to their ranch
---------------------------------------------
local function OpenDeliveryChoice(data)
    Menu.registerContext({
        id = 'buy_point_delivery_menu',
        title = locale('cl_buypoint_title_13'),
        menu = 'buy_point_menu',
        options = {
            {
                title = locale('cl_buypoint_title_14'),
                description = locale('cl_buypoint_description_15'):format(data.animalName, data.buyPointData.name),
                onSelect = function()
                    data.delivery = false
                    ConfirmBuyAnimal(data)
                end
            },
            {
                title = locale('cl_buypoint_title_16'):format(Config.LivestockDeliveryPrice),
                description = locale('cl_buypoint_description_17'):format(data.animalName),
                onSelect = function()
                    data.delivery = true
                    ConfirmBuyAnimal(data)
                end
            }
        }
    })
    Menu.showContext('buy_point_delivery_menu')
end

---------------------------------------------
-- open buy menu
---------------------------------------------
local function OpenBuyMenu(buyPointData)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerjob = PlayerData.job.name

    -- Check if player works at a ranch
    local playerRanchData = nil
    local isRancher = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.jobaccess == playerjob then
            isRancher = true
            playerRanchData = ranchData
            break
        end
    end

    if not isRancher then
        lib.notify({ title = locale('cl_buypoint_title_18'), description = locale('cl_buypoint_description_19'), type = 'error' })
        return
    end

    -- Check current animal count
    RSGCore.Functions.TriggerCallback('rsg-ranch:server:countanimals', function(animalCount)
        local options = {}

        -- Header showing capacity
        table.insert(options, {
            title = locale('cl_buypoint_title_20'):format(animalCount, Config.MaxRanchAnimals),
            description = locale('cl_buypoint_description_21'):format(playerRanchData.name),
            disabled = true
        })

        if animalCount >= Config.MaxRanchAnimals then
            table.insert(options, {
                title = locale('cl_buypoint_title_22'),
                description = locale('cl_buypoint_description_23'),
                disabled = true
            })
        else
            table.insert(options, {
                title = locale('cl_buypoint_title_24'),
                disabled = true
            })

            -- Available animals to buy
            local availableSlots = Config.MaxRanchAnimals - animalCount

            -- Bull option
            table.insert(options, {
                title = locale('cl_buypoint_title_25'),
                description = locale('cl_buypoint_description_26'):format(Config.BullBuyPrice),
                onSelect = function()
                    OpenDeliveryChoice({
                        animalType = 'a_c_bull_01',
                        animalName = locale('sv_animal_bull'),
                        price = Config.BullBuyPrice,
                        ranchData = playerRanchData,
                        buyPointData = buyPointData
                    })
                end,
                arrow = true
            })

            -- Cow option
            table.insert(options, {
                title = locale('cl_buypoint_title_27'),
                description = locale('cl_buypoint_description_28'):format(Config.CowBuyPrice),
                onSelect = function()
                    OpenDeliveryChoice({
                        animalType = 'a_c_cow',
                        animalName = locale('sv_animal_cow'),
                        price = Config.CowBuyPrice,
                        ranchData = playerRanchData,
                        buyPointData = buyPointData
                    })
                end,
                arrow = true
            })

            -- Pig option
            -- Pigs are delivery-only: no "drive it yourself" option, so we skip the
            -- delivery choice menu entirely and go straight to a delivery purchase.
            table.insert(options, {
                title = locale('cl_buypoint_title_29'),
                description = locale('cl_buypoint_description_30'):format(Config.PigBuyPrice, Config.LivestockDeliveryPrice),
                onSelect = function()
                    local pigData = {
                        animalType = 'a_c_pig_01',
                        animalName = locale('sv_animal_pig'),
                        price = Config.PigBuyPrice,
                        ranchData = playerRanchData,
                        buyPointData = buyPointData,
                        delivery = true
                    }

                    if Config.PigChooseGenderOnBuy then
                        OpenGenderChoice(pigData)
                    else
                        ConfirmBuyAnimal(pigData)
                    end
                end,
                arrow = true
            })

            -- Sheep option
            -- Sheep follow the same rules as pigs: delivery-only, no "drive it yourself"
            -- option, so we skip the delivery choice menu entirely.
            table.insert(options, {
                title = locale('cl_buypoint_title_31'),
                description = locale('cl_buypoint_description_32'):format(Config.SheepBuyPrice, Config.LivestockDeliveryPrice),
                onSelect = function()
                    local sheepData = {
                        animalType = 'a_c_sheep_01',
                        animalName = locale('sv_animal_sheep'),
                        price = Config.SheepBuyPrice,
                        ranchData = playerRanchData,
                        buyPointData = buyPointData,
                        delivery = true
                    }

                    if Config.SheepChooseGenderOnBuy then
                        OpenGenderChoice(sheepData)
                    else
                        ConfirmBuyAnimal(sheepData)
                    end
                end,
                arrow = true
            })

            table.insert(options, {
                title = locale('cl_buypoint_title_33'),
                disabled = true
            })

            table.insert(options, {
                title = locale('cl_buypoint_title_34'):format(availableSlots),
                description = locale('cl_buypoint_description_35'):format(availableSlots),
                disabled = true
            })
        end

        Menu.registerContext({
            id = 'buy_point_menu',
            title = buyPointData.name,
            options = options
        })
        Menu.showContext('buy_point_menu')

    end, playerRanchData.ranchid)
end

---------------------------------------------
-- buy point blips
---------------------------------------------
CreateThread(function()
    for i, buyPointData in pairs(Config.BuyPointLocations) do
        if buyPointData.showblip == true then
            local BuyBlip = Citizen.InvokeNative(0x5A039BB0BCA604B6, joaat(buyPointData.blipsprite), buyPointData.coords.x, buyPointData.coords.y, buyPointData.coords.z)
            SetBlipSprite(BuyBlip, joaat(buyPointData.blipsprite), true)
            SetBlipScale(BuyBlip, buyPointData.blipscale)
            Citizen.InvokeNative(0x9CB1A1623062F402, BuyBlip, buyPointData.blipname)
            buyPointBlips[i] = BuyBlip -- Track the blip for cleanup
        end
    end
end)

---------------------------------------------
-- buy point npcs
---------------------------------------------
-- Function to clean up any existing buy point NPCs (in case of improper restart)
local function CleanupExistingBuyPointNPCs()
    -- Get all peds in the world
    local allPeds = GetGamePool('CPed')
    local cleanedCount = 0
    
    for _, ped in ipairs(allPeds) do
        if DoesEntityExist(ped) and ped ~= cache.ped then
            -- Check if this ped is at a buy point location
            local pedCoords = GetEntityCoords(ped)
            for _, buyPointData in pairs(Config.BuyPointLocations) do
                local npcCoords = vector3(buyPointData.npccoords.x, buyPointData.npccoords.y, buyPointData.npccoords.z)
                local distance = #(pedCoords - npcCoords)
                if distance < 2.0 and GetEntityModel(ped) == buyPointData.npcmodel then
                    DeletePed(ped)
                    cleanedCount = cleanedCount + 1
                    break
                end
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[BUYPOINT DEBUG]^7 Cleaned up ' .. cleanedCount .. ' existing buy point NPCs before creating new ones')
    end
end

CreateThread(function()
    -- Clean up any existing NPCs first
    CleanupExistingBuyPointNPCs()
    
    -- Wait a moment for cleanup to complete
    Wait(500)
    
    for i, buyPointData in pairs(Config.BuyPointLocations) do
        lib.requestModel(buyPointData.npcmodel, 10000)
        
        local buyPointNPC = CreatePed(buyPointData.npcmodel, buyPointData.npccoords.x, buyPointData.npccoords.y, buyPointData.npccoords.z - 1, buyPointData.npccoords.w, false, true, 0, 0)
        Citizen.InvokeNative(0x283978A15512B2FE, buyPointNPC, true)
        SetRandomOutfitVariation(buyPointNPC, true)
        SetModelAsNoLongerNeeded(buyPointData.npcmodel)
        SetPedCanBeTargetted(buyPointNPC, false)
        SetEntityInvincible(buyPointNPC, true)
        FreezeEntityPosition(buyPointNPC, true)
        SetBlockingOfNonTemporaryEvents(buyPointNPC, true)
        
        -- Track the NPC for cleanup
        buyPointNPCs[i] = buyPointNPC
        
        -- target interaction
        exports.ox_target:addLocalEntity(buyPointNPC, {
            {
                name = 'buy_point_npc',
                label = locale('cl_buypoint_label_36'),
                onSelect = function()
                    OpenBuyMenu(buyPointData)
                end,
                distance = 3.0
            }
        })
        
        if Config.Debug then
            print('^2[BUYPOINT DEBUG]^7 Created buy point NPC ' .. i .. ' (entity: ' .. buyPointNPC .. ') at ' .. buyPointData.name)
        end
    end
end)

---------------------------------------------
-- cleanup on resource stop
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- Clean up buy point NPCs
    for i, npc in pairs(buyPointNPCs) do
        if DoesEntityExist(npc) then
            exports.ox_target:removeLocalEntity(npc, 'buy_point_npc')
            DeletePed(npc)
            if Config.Debug then
                print('^1[BUYPOINT DEBUG]^7 Cleaned up buy point NPC ' .. i .. ' (entity: ' .. npc .. ')')
            end
        end
        buyPointNPCs[i] = nil
    end
    
    -- Clean up buy point blips
    for i, blip in pairs(buyPointBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
            if Config.Debug then
                print('^1[BUYPOINT DEBUG]^7 Cleaned up buy point blip ' .. i .. ' (blip: ' .. blip .. ')')
            end
        end
        buyPointBlips[i] = nil
    end
    
    if Config.Debug then
        print('^2[BUYPOINT DEBUG]^7 All buy point NPCs and blips cleaned up')
    end
end)
