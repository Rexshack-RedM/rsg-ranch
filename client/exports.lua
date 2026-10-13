---------------------------------------------
-- Client-side exports for rsg-ranch
---------------------------------------------

---------------------------------------------
-- Check if local player is ranch staff
---------------------------------------------
exports('isLocalPlayerRanchStaff', function()
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    
    if not PlayerData or not PlayerData.job then
        return false
    end
    
    local playerjob = PlayerData.job.name
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return true, ranchData.ranchid
        end
    end
    
    return false
end)

---------------------------------------------
-- Get local player's ranch ID
---------------------------------------------
exports('getLocalPlayerRanchId', function()
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    
    if not PlayerData or not PlayerData.job then
        return nil
    end
    
    local playerjob = PlayerData.job.name
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return ranchData.ranchid
        end
    end
    
    return nil
end)

---------------------------------------------
-- Get ranch location by ranch ID
---------------------------------------------
exports('getRanchLocation', function(ranchid)
    if not ranchid then return nil end
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.ranchid == ranchid then
            return ranchData
        end
    end
    
    return nil
end)

---------------------------------------------
-- Get all ranch locations
---------------------------------------------
exports('getAllRanchLocations', function()
    return Config.RanchLocations
end)

---------------------------------------------
-- Get all sale point locations
---------------------------------------------
exports('getAllSalePointLocations', function()
    return Config.SalePointLocations
end)

---------------------------------------------
-- Get all buy point locations
---------------------------------------------
exports('getAllBuyPointLocations', function()
    return Config.BuyPointLocations
end)

---------------------------------------------
-- Get nearest ranch to player
---------------------------------------------
exports('getNearestRanch', function()
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    
    local nearestRanch = nil
    local nearestDistance = math.huge
    
    for _, ranchData in pairs(Config.RanchLocations) do
        local distance = #(playerCoords - ranchData.coords)
        
        if distance < nearestDistance then
            nearestDistance = distance
            nearestRanch = ranchData
        end
    end
    
    if nearestRanch then
        return nearestRanch, nearestDistance
    end
    
    return nil, nil
end)

---------------------------------------------
-- Check if player can interact with animal (respects staff rule)
---------------------------------------------
exports('canInteractWithAnimal', function(animalid)
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    
    if not PlayerData or not PlayerData.job then
        return false, locale('cl_not_employed_ranch')
    end
    
    local playerjob = PlayerData.job.name
    
    -- Check if player works at any ranch
    local isRanchStaff = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            isRanchStaff = true
            break
        end
    end
    
    if not isRanchStaff then
        return false, locale('cl_only_staff_interact')
    end
    
    return true, "OK"
end)

---------------------------------------------
-- Get animal product info by model
---------------------------------------------
exports('getAnimalProductInfo', function(animalModel)
    if not animalModel then return nil end
    
    return Config.AnimalProducts[animalModel]
end)

---------------------------------------------
-- Get breeding config by model
---------------------------------------------
exports('getBreedingConfig', function(animalModel)
    if not animalModel then return nil end
    
    return Config.BreedingConfig[animalModel]
end)

---------------------------------------------
-- Get player's job grade
---------------------------------------------
exports('getPlayerJobGrade', function()
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    
    if not PlayerData or not PlayerData.job then
        return 0
    end
    
    return PlayerData.job.grade.level or 0
end)

---------------------------------------------
-- Check if player has permission for action
---------------------------------------------
exports('hasPermission', function(permissionName)
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    
    if not PlayerData or not PlayerData.job then
        return false
    end
    
    local jobGrade = PlayerData.job.grade.level or 0
    local permissions = Config.StaffManagement.Permissions[jobGrade]
    
    if not permissions then
        return false
    end
    
    return permissions[permissionName] == true
end)

---------------------------------------------
-- Get nearest water source (searches world objects matching Config.WaterProps,
-- since water sources are physical props, not fixed config locations)
---------------------------------------------
exports('getNearestWaterSource', function()
    local playerCoords = GetEntityCoords(PlayerPedId())

    local nearestObject = nil
    local nearestDistance = math.huge

    for _, object in ipairs(GetGamePool('CObject')) do
        local model = GetEntityModel(object)
        for _, waterModel in ipairs(Config.WaterProps) do
            if model == waterModel then
                local distance = #(playerCoords - GetEntityCoords(object))
                if distance < nearestDistance then
                    nearestDistance = distance
                    nearestObject = object
                end
                break
            end
        end
    end

    if nearestObject then
        return nearestObject, nearestDistance
    end

    return nil, nil
end)

---------------------------------------------
-- Check if player is near ranch
---------------------------------------------
exports('isNearRanch', function(maxDistance)
    maxDistance = maxDistance or 50.0
    
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    
    for _, ranchData in pairs(Config.RanchLocations) do
        local distance = #(playerCoords - ranchData.coords)
        
        if distance <= maxDistance then
            return true, ranchData, distance
        end
    end
    
    return false, nil, nil
end)
