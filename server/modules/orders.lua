local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- helper: is this player ranch staff for a given ranchid (or any ranch if ranchid omitted)
---------------------------------------------
local function isPlayerRanchStaffFor(Player, ranchid)
    if not Player or not Player.PlayerData.job then
        return false
    end

    local playerjob = Player.PlayerData.job.name

    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.jobaccess == playerjob and (not ranchid or ranchid == ranchData.jobaccess) then
            return true
        end
    end

    return false
end

---------------------------------------------
-- helper: is the player standing at their ranch NPC (server-side check)
---------------------------------------------
local function isNearOwnRanch(src, ranchid)
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.ranchid == ranchid then
            local npc = ranchData.npccoords
            return #(GetEntityCoords(GetPlayerPed(src)) - vector3(npc.x, npc.y, npc.z)) <= (Config.RanchMenuDistance or 15.0)
        end
    end
    return false
end

---------------------------------------------
-- helper: look up an order supplies item config entry by item name
---------------------------------------------
local function GetOrderSupplyItem(itemName)
    for _, entry in ipairs(Config.OrderSupplies.Items) do
        if entry.item == itemName then
            return entry
        end
    end
    return nil
end

---------------------------------------------
-- create a unique orderid
---------------------------------------------
local function CreateOrderId()
    local UniqueFound = false
    local orderid = nil
    local maxAttempts = 50
    local attempts = 0

    while not UniqueFound and attempts < maxAttempts do
        attempts = attempts + 1
        orderid = math.random(Config.OrderSupplies.ORDER_ID_MIN, Config.OrderSupplies.ORDER_ID_MAX)

        local success, result = pcall(function()
            return MySQL.query.await('SELECT COUNT(*) as count FROM rsg_ranch_orders WHERE orderid = ?', { orderid })
        end)

        if success and result and result[1] and result[1].count == 0 then
            UniqueFound = true
        elseif not success then
            if Config.Debug then
                print('^1[ERROR]^7 Database error in CreateOrderId: ' .. tostring(result))
            end
            break
        end
    end

    if not UniqueFound then
        local serverTime = os.time()
        local randomSuffix = math.random(1000, 9999)
        orderid = tostring(serverTime) .. tostring(randomSuffix)
        if string.len(orderid) > (Config.MAX_ID_LENGTH or 20) then
            orderid = string.sub(orderid, -(Config.MAX_ID_LENGTH or 20))
        end
    end

    return tonumber(orderid)
end

---------------------------------------------
-- place a supply order
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:placeSupplyOrder', function(itemName, amount)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Config.OrderSupplies.Enabled then return end
    if not Player or not isPlayerRanchStaffFor(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_1')})
        return
    end

    -- trainees can't spend ranch money on supplies (the menu hides it, enforce it here)
    if Player.PlayerData.job.grade.level < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_1')})
        return
    end

    local ranchid = Player.PlayerData.job.name
    if not isNearOwnRanch(src, ranchid) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_not_near_ranch')})
        return
    end

    local supplyItem = GetOrderSupplyItem(itemName)
    if not supplyItem or not RSGCore.Shared.Items[supplyItem.item] then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_2')})
        return
    end

    amount = math.floor(tonumber(amount) or 1)
    if amount < 1 then amount = 1 end
    if amount > (Config.OrderSupplies.MaxAmountPerOrder or 10) then
        amount = Config.OrderSupplies.MaxAmountPerOrder or 10
    end

    -- Cap total queued orders per ranch so the order book can't grow unbounded
    local pendingCount = MySQL.query.await('SELECT COUNT(*) as count FROM rsg_ranch_orders WHERE ranchid = ?', {ranchid})
    if pendingCount and pendingCount[1] and pendingCount[1].count >= (Config.OrderSupplies.MaxPendingOrdersPerRanch or 30) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_3')})
        return
    end

    local totalPrice = supplyItem.price * amount

    if not Player.Functions.RemoveMoney('cash', totalPrice, 'ranch-supply-order') then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_4'):format(totalPrice)})
        return
    end

    local orderid = CreateOrderId()
    if not orderid then
        -- refund since the order failed to be created
        Player.Functions.AddMoney('cash', totalPrice, 'ranch-supply-order-refund')
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_5')})
        return
    end

    local orderedAt = os.time()
    local readyAt = orderedAt + (supplyItem.deliveryTime or 300)

    local insertSuccess, insertResult = pcall(function()
        return MySQL.insert.await('INSERT INTO rsg_ranch_orders (orderid, ranchid, citizenid, item, amount, price, ordered_at, ready_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            orderid, ranchid, Player.PlayerData.citizenid, supplyItem.item, amount, totalPrice, orderedAt, readyAt
        })
    end)

    if not insertSuccess or not insertResult then
        if Config.Debug then
            print('^1[ERROR]^7 Failed to insert supply order: ' .. tostring(insertResult))
        end
        Player.Functions.AddMoney('cash', totalPrice, 'ranch-supply-order-refund')
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_6')})
        return
    end

    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_orders_description_7'):format(amount, supplyItem.label, totalPrice)})

    if Config.Debug then
        print('^2[ORDERS]^7 Player ' .. src .. ' ordered ' .. amount .. 'x ' .. supplyItem.item .. ' for ranch ' .. ranchid .. ' (order ' .. orderid .. ')')
    end
end)

---------------------------------------------
-- fetch all pending/ready orders for a ranch
---------------------------------------------
RSGCore.Functions.CreateCallback('rsg-ranch:server:getSupplyOrders', function(source, cb, ranchid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaffFor(Player, ranchid) then
        cb(nil)
        return
    end

    local rows = MySQL.query.await('SELECT orderid, ranchid, citizenid, item, amount, price, ordered_at, ready_at FROM rsg_ranch_orders WHERE ranchid = ? ORDER BY ready_at ASC', {ranchid})
    if not rows then
        cb({})
        return
    end

    local now = os.time()
    for _, row in ipairs(rows) do
        row.ready = (row.ready_at <= now)
        row.secondsLeft = math.max(0, row.ready_at - now)
        local supplyItem = GetOrderSupplyItem(row.item)
        row.label = supplyItem and supplyItem.label or row.item
    end

    cb(rows)
end)

---------------------------------------------
-- collect a ready order - delivers the item(s) to the collecting staff member's
-- inventory and removes the order from the queue
---------------------------------------------
RegisterNetEvent('rsg-ranch:server:collectSupplyOrder', function(orderid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)

    if not Player or not isPlayerRanchStaffFor(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_8')})
        return
    end

    if not orderid then return end

    local orderRows = MySQL.query.await('SELECT orderid, ranchid, item, amount, ready_at FROM rsg_ranch_orders WHERE orderid = ?', {orderid})
    if not orderRows or #orderRows == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_9')})
        return
    end
    local order = orderRows[1]

    if order.ranchid ~= Player.PlayerData.job.name then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_10')})
        return
    end

    if not isNearOwnRanch(src, order.ranchid) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_not_near_ranch')})
        return
    end

    if order.ready_at > os.time() then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_11')})
        return
    end

    if not exports['rsg-inventory']:CanAddItem(src, order.item, order.amount) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_12')})
        return
    end

    -- Delete first and only deliver if THIS request removed the order, so two
    -- staff (or a spam-fired event) can't both collect it
    local deleted = MySQL.update.await('DELETE FROM rsg_ranch_orders WHERE orderid = ?', {orderid})
    if not deleted or deleted <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_9')})
        return
    end

    if not exports['rsg-inventory']:AddItem(src, order.item, order.amount, nil, nil, 'rsg-ranch-supply-order') then
        -- put the order back rather than losing it
        MySQL.insert('INSERT INTO rsg_ranch_orders (orderid, ranchid, citizenid, item, amount, price, ordered_at, ready_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?)', {
            order.orderid, order.ranchid, Player.PlayerData.citizenid, order.item, order.amount, os.time(), order.ready_at
        })
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = locale('sv_orders_description_12')})
        return
    end

    if RSGCore.Shared.Items[order.item] then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[order.item], 'add', order.amount)
    end

    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = locale('sv_orders_description_13'):format(order.amount, RSGCore.Shared.Items[order.item] and RSGCore.Shared.Items[order.item].label or order.item)})

    if Config.Debug then
        print('^2[ORDERS]^7 Player ' .. src .. ' collected order ' .. orderid .. ' (' .. order.amount .. 'x ' .. order.item .. ') for ranch ' .. order.ranchid)
    end
end)
