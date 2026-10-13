---------------------------------------------
-- Server-side exports for rsg-ranch
---------------------------------------------

---------------------------------------------
-- Check if player is ranch staff
---------------------------------------------
exports('isPlayerRanchStaff', function(playerId)
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local Player = RSGCore.Functions.GetPlayer(playerId)
    
    if not Player or not Player.PlayerData.job then
        return false
    end
    
    local playerjob = Player.PlayerData.job.name
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return true, ranchData.ranchid
        end
    end
    
    return false
end)

---------------------------------------------
-- Get player's ranch ID
---------------------------------------------
exports('getPlayerRanchId', function(playerId)
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local Player = RSGCore.Functions.GetPlayer(playerId)
    
    if not Player or not Player.PlayerData.job then
        return nil
    end
    
    local playerjob = Player.PlayerData.job.name
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return ranchData.ranchid
        end
    end
    
    return nil
end)

---------------------------------------------
-- Get ranch animal count
---------------------------------------------
exports('getRanchAnimalCount', function(ranchid)
    if not ranchid then return 0 end
    
    local success, result = pcall(function()
        return MySQL.query.await("SELECT COUNT(*) as count FROM rsg_ranch_animals WHERE ranchid = ?", { ranchid })
    end)
    
    if success and result and result[1] then
        return result[1].count or 0
    end
    
    return 0
end)

---------------------------------------------
-- Get all animals for a ranch
---------------------------------------------
exports('getRanchAnimals', function(ranchid)
    if not ranchid then return {} end
    
    local success, result = pcall(function()
        return MySQL.query.await("SELECT * FROM rsg_ranch_animals WHERE ranchid = ?", { ranchid })
    end)
    
    if success and result then
        return result
    end
    
    return {}
end)

---------------------------------------------
-- Get specific animal data
---------------------------------------------
exports('getAnimalData', function(animalid)
    if not animalid then return nil end
    
    local success, result = pcall(function()
        return MySQL.query.await("SELECT * FROM rsg_ranch_animals WHERE animalid = ?", { animalid })
    end)
    
    if success and result and #result > 0 then
        return result[1]
    end
    
    return nil
end)

---------------------------------------------
-- Add animal to ranch (respects staff rules)
---------------------------------------------
exports('addAnimalToRanch', function(ranchid, model, gender, pos_x, pos_y, pos_z, pos_w)
    if not ranchid or not model then return false end

    -- Generate unique animal ID (shared implementation lives in server.lua)
    local animalid = exports['rsg-ranch']:CreateAnimalId()
    local currentTime = os.time()
    
    -- Set default gender if not provided
    if not gender then
        local genderRatio = Config.GenderRatios[model] or 0.5
        gender = (math.random() < genderRatio) and 'male' or 'female'
    end
    
    local success, result = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO rsg_ranch_animals (animalid, ranchid, model, gender, age, health, hunger, thirst, 
                                          born, pos_x, pos_y, pos_z, pos_w, product_ready, pregnant, 
                                          breeding_ready_time, gestation_end_time, last_production)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], {
            animalid,
            ranchid,
            model,
            gender,
            0, -- age
            100, -- health
            100, -- hunger
            100, -- thirst
            currentTime, -- born
            pos_x or 0,
            pos_y or 0,
            pos_z or 0,
            pos_w or 0,
            0, -- product_ready
            0, -- pregnant
            currentTime, -- breeding_ready_time
            0, -- gestation_end_time
            currentTime -- last_production
        })
    end)
    
    if success and result then
        if Config.Debug then
            print('^2[RSG-RANCH EXPORT]^7 Added animal ' .. animalid .. ' to ranch ' .. ranchid)
        end
        
        -- Refresh all clients
        RanchBroadcastAnimals()
        
        return animalid
    end
    
    return false
end)

---------------------------------------------
-- Remove animal from ranch
---------------------------------------------
exports('removeAnimalFromRanch', function(animalid)
    if not animalid then return false end
    
    local success, result = pcall(function()
        return MySQL.update.await('DELETE FROM rsg_ranch_animals WHERE animalid = ?', { animalid })
    end)
    
    if success and result and result > 0 then
        if Config.Debug then
            print('^2[RSG-RANCH EXPORT]^7 Removed animal ' .. animalid)
        end
        
        -- Refresh all clients
        TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, animalid)
        
        return true
    end
    
    return false
end)

---------------------------------------------
-- Update animal stats
---------------------------------------------
exports('updateAnimalStats', function(animalid, stats)
    if not animalid or not stats then return false end
    
    local updates = {}
    local values = {}
    
    if stats.health then
        table.insert(updates, 'health = ?')
        table.insert(values, math.max(0, math.min(100, stats.health)))
    end
    
    if stats.hunger then
        table.insert(updates, 'hunger = ?')
        table.insert(values, math.max(0, math.min(100, stats.hunger)))
    end
    
    if stats.thirst then
        table.insert(updates, 'thirst = ?')
        table.insert(values, math.max(0, math.min(100, stats.thirst)))
    end
    
    if stats.age then
        table.insert(updates, 'age = ?')
        table.insert(values, math.max(0, stats.age))
    end
    
    if #updates == 0 then
        return false
    end
    
    table.insert(values, animalid)
    
    local query = 'UPDATE rsg_ranch_animals SET ' .. table.concat(updates, ', ') .. ' WHERE animalid = ?'
    
    local success, result = pcall(function()
        return MySQL.update.await(query, values)
    end)
    
    if success and result and result > 0 then
        -- Notify all clients about the update
        TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, animalid, stats)
        return true
    end
    
    return false
end)

---------------------------------------------
-- Get amount of ranch staff hired
---------------------------------------------
exports('getStaffCount', function(ranchid)
    if not ranchid then return 0 end
    
    local RSGCore = exports['rsg-core']:GetCoreObject()
    local staffCount = 0
    local online = {}

    -- Online players are authoritative (their DB row may not be saved yet)...
    for _, playerId in ipairs(RSGCore.Functions.GetPlayers()) do
        local Player = RSGCore.Functions.GetPlayer(playerId)
        if Player and Player.PlayerData.job then
            online[Player.PlayerData.citizenid] = true
            if Player.PlayerData.job.name == ranchid then
                staffCount = staffCount + 1
            end
        end
    end

    -- ...plus everyone offline who still holds the job. Counting online staff
    -- only let a ranch go over MaxEmployeesPerRanch whenever staff were offline.
    local rows = MySQL.query.await('SELECT citizenid FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', { ranchid }) or {}
    for _, row in ipairs(rows) do
        if not online[row.citizenid] then
            staffCount = staffCount + 1
        end
    end
    
    if Config.Debug then
        print('^2[RSG-RANCH EXPORT]^7 Staff count for ' .. ranchid .. ': ' .. staffCount)
    end
    
    return staffCount
end)

---------------------------------------------
-- Get ranch statistics
---------------------------------------------
exports('getRanchStatistics', function(ranchid)
    if not ranchid then return nil end
    
    local success, animals = pcall(function()
        return MySQL.query.await("SELECT * FROM rsg_ranch_animals WHERE ranchid = ?", { ranchid })
    end)
    
    if not success or not animals then
        return nil
    end
    
    local stats = {
        total = #animals,
        byType = {},
        byGender = { male = 0, female = 0 },
        pregnant = 0,
        unhealthy = 0,
        needsFood = 0,
        needsWater = 0,
        producing = 0
    }
    
    for _, animal in ipairs(animals) do
        -- Count by type
        stats.byType[animal.model] = (stats.byType[animal.model] or 0) + 1
        
        -- Count by gender
        if animal.gender then
            stats.byGender[animal.gender] = (stats.byGender[animal.gender] or 0) + 1
        end
        
        -- Count pregnant
        if animal.pregnant == 1 then
            stats.pregnant = stats.pregnant + 1
        end
        
        -- Count unhealthy
        if (animal.health or 100) < 70 then
            stats.unhealthy = stats.unhealthy + 1
        end
        
        -- Count needing food
        if (animal.hunger or 100) < 50 then
            stats.needsFood = stats.needsFood + 1
        end
        
        -- Count needing water
        if (animal.thirst or 100) < 50 then
            stats.needsWater = stats.needsWater + 1
        end
        
        -- Count producing
        if animal.product_ready == 1 then
            stats.producing = stats.producing + 1
        end
    end
    
    return stats
end)
