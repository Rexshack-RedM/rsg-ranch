local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Ranch management NUI
-- Replaces the old ox_lib context menus (manager / ranch hand / trainee /
-- storage / staff / supplies / slaughter house / ownership / overview).
-- All actions still go through the existing, server-validated events.
---------------------------------------------

local uiOpen = false
local currentRanchId = nil

local ModelLabels = {
    ['a_c_bull_01'] = 'sv_animal_bull',
    ['a_c_cow'] = 'sv_animal_cow',
    ['a_c_pig_01'] = 'sv_animal_pig',
    ['a_c_sheep_01'] = 'sv_animal_sheep',
}

local function ModelLabel(model)
    return locale(ModelLabels[model] or 'sv_animal_generic')
end

local function Await(name, ...)
    local p = promise.new()
    RSGCore.Functions.TriggerCallback(name, function(result) p:resolve(result) end, ...)
    return Citizen.Await(p)
end

local function GetRanchData(ranchid)
    for _, r in pairs(Config.RanchLocations) do
        if r.ranchid == ranchid then return r end
    end
end

-- every locale key starting with ui_ is handed to the NUI so all of its text is translatable
local uiLocales

function GetUiLocales()
    if uiLocales then return uiLocales end

    local all
    local ok, result = pcall(lib.getLocales)
    if ok and type(result) == 'table' and next(result) then
        all = result
    else
        -- fallback: read the locale file directly
        local lang = GetConvar('ox:locale', 'en')
        local raw = LoadResourceFile(GetCurrentResourceName(), ('locales/%s.json'):format(lang))
            or LoadResourceFile(GetCurrentResourceName(), 'locales/en.json')
        all = raw and json.decode(raw) or {}
    end

    uiLocales = {}
    for k, v in pairs(all) do
        if k:sub(1, 3) == 'ui_' or k:sub(1, 10) == 'sv_animal_' then uiLocales[k] = v end
    end
    return uiLocales
end

---------------------------------------------
-- build the full payload for the dashboard
---------------------------------------------
local function BuildRanchPayload(ranchid)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local ranch = GetRanchData(ranchid)
    local grade = PlayerData.job.grade.level
    local owner = Await('rsg-ranch:server:getranchowner', ranchid)
    local isBoss = grade >= Config.RanchBossGrade
    local canManageStaff = grade >= Config.StaffManagement.MinGradeToManage

    local payload = {
        ranchid = ranchid,
        name = ranch and ranch.name or ranchid,
        grade = grade,
        gradeLabel = PlayerData.job.grade.name,
        isOwner = owner == PlayerData.citizenid,
        isBoss = isBoss,
        canManageStaff = canManageStaff,
        isTrainee = grade == 0,
        herdingEnabled = Config.HerdingEnabled == true,
        cash = PlayerData.money.cash or 0,
        maxAnimals = Config.MaxRanchAnimals,
        sellRefundPct = math.floor(math.max(0.0, math.min(1.0, tonumber(Config.RanchSellRefundPercentage) or 0.8)) * 100 + 0.5),
        ranchPrice = ranch and ranch.price or 0,
    }

    -- live sell-back quote (100% inside the cooling-off period, Config % after)
    if payload.isOwner then
        local quote = Await('rsg-ranch:server:getRanchSellQuote', ranchid)
        if quote then
            payload.sellRefund = quote.refund
            payload.sellRefundPct = quote.pct
            payload.sellGraceLeft = quote.graceLeft
        end
    end

    -- herd overview (all staff)
    local overview = Await('rsg-ranch:server:getAnimalOverview', ranchid) or {}
    payload.animals = {}
    for _, a in ipairs(overview.animals or {}) do
        a.label = ModelLabel(a.model)
        payload.animals[#payload.animals + 1] = a
    end
    payload.summary = overview.summary or {}

    if grade >= 1 then
        payload.storages = Await('rsg-ranch:server:getranchstorages', ranchid) or {}

        payload.market = Await('rsg-ranch:server:getRanchMarket', ranchid) or {}
        for _, row in ipairs(payload.market) do
            row.label = ModelLabel(row.model)
        end

        if Config.OrderSupplies.Enabled then
            payload.orders = Await('rsg-ranch:server:getSupplyOrders', ranchid) or {}
            payload.catalog = Config.OrderSupplies.Items
            payload.maxPerOrder = Config.OrderSupplies.MaxAmountPerOrder or 10
        end
    end

    if canManageStaff then
        local staff = Await('rsg-ranch:server:getStaffList', ranchid) or {}
        payload.staff = staff.employees or {}
        payload.maxStaff = Config.StaffManagement.MaxEmployeesPerRanch
    end

    if isBoss then
        local sizes = {}
        for key, s in pairs(Config.RanchStorageSizes or {}) do
            sizes[#sizes + 1] = { key = key, label = s.label, price = s.price, slots = s.slots, maxweight = s.maxweight }
        end
        table.sort(sizes, function(a, b) return a.price < b.price end)
        payload.storageSizes = sizes
        payload.accessLevels = Config.RanchStorageAccessLevels or {}
    end

    return payload
end

local function SendDashboard(ranchid)
    SendNUIMessage({ action = 'update', data = BuildRanchPayload(ranchid) })
end

local function RefreshSoon()
    if not uiOpen or not currentRanchId then return end
    SetTimeout(700, function()
        if uiOpen and currentRanchId then SendDashboard(currentRanchId) end
    end)
end

local function CloseUI()
    uiOpen = false
    currentRanchId = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

---------------------------------------------
-- open
---------------------------------------------
function OpenRanchUI(ranchid)
    if uiOpen then return end
    uiOpen = true
    currentRanchId = ranchid
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', mode = 'manage', locales = GetUiLocales(), data = BuildRanchPayload(ranchid) })
end

function OpenRanchPurchaseUI(ranchid)
    local ranch = GetRanchData(ranchid)
    if not ranch or uiOpen then return end
    uiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        mode = 'purchase',
        locales = GetUiLocales(),
        data = {
            ranchid = ranchid,
            name = ranch.name,
            price = ranch.price,
            cash = RSGCore.Functions.GetPlayerData().money.cash or 0,
        }
    })
end

-- keep the old event names working for anything else that triggers them
RegisterNetEvent('rsg-ranch:client:openmanagermenu', function(ranchid) OpenRanchUI(ranchid) end)
RegisterNetEvent('rsg-ranch:client:openranchhandmenu', function(ranchid) OpenRanchUI(ranchid) end)
RegisterNetEvent('rsg-ranch:client:opentraineemenu', function(ranchid) OpenRanchUI(ranchid) end)
RegisterNetEvent('rsg-ranch:client:openpurchasemenu', function(ranchid) OpenRanchPurchaseUI(ranchid) end)

---------------------------------------------
-- NUI callbacks
---------------------------------------------
RegisterNUICallback('close', function(_, cb)
    CloseUI()
    cb('ok')
end)

RegisterNUICallback('refresh', function(_, cb)
    if currentRanchId then SendDashboard(currentRanchId) end
    cb('ok')
end)

-- simple fire-and-forget actions: action name -> server event + argument builder
local Actions = {
    sellAnimal     = function(d) TriggerServerEvent('rsg-ranch:server:sellAtRanch', d.animalid) end,
    slaughter      = function(d) TriggerServerEvent('rsg-ranch:server:slaughterAtRanch', d.animalid) end,
    orderSupply    = function(d) TriggerServerEvent('rsg-ranch:server:placeSupplyOrder', d.item, tonumber(d.amount) or 1) end,
    collectOrder   = function(d) TriggerServerEvent('rsg-ranch:server:collectSupplyOrder', d.orderid) end,
    renameStorage  = function(d) TriggerServerEvent('rsg-ranch:server:renameranchstorage', { ranchid = currentRanchId, storageid = d.storageid, label = tostring(d.label or '') }) end,
    storageAccess  = function(d) TriggerServerEvent('rsg-ranch:server:setstorageaccess', { ranchid = currentRanchId, storageid = d.storageid, mingrade = tonumber(d.mingrade) }) end,
    buyStorage     = function(d) TriggerServerEvent('rsg-ranch:server:purchaseranchstorage', { ranchid = currentRanchId, size = d.size }) end,
    promote        = function(d) TriggerServerEvent('rsg-ranch:server:promoteEmployee', currentRanchId, d.citizenid) end,
    demote         = function(d) TriggerServerEvent('rsg-ranch:server:demoteEmployee', currentRanchId, d.citizenid) end,
    fire           = function(d) TriggerServerEvent('rsg-ranch:server:fireEmployee', currentRanchId, d.citizenid) end,
    hire           = function(d) TriggerServerEvent('rsg-ranch:server:hireEmployee', currentRanchId, tonumber(d.id), tonumber(d.grade)) end,
}

RegisterNUICallback('action', function(data, cb)
    cb('ok')
    if not uiOpen or type(data) ~= 'table' then return end
    local fn = Actions[data.type]
    if fn then
        fn(data)
        RefreshSoon()
    end
end)

-- actions that hand off to the game world close the UI first
RegisterNUICallback('openStorage', function(data, cb)
    cb('ok')
    local ranchid = currentRanchId
    CloseUI()
    TriggerServerEvent('rsg-ranch:server:openranchstorage', { ranchid = ranchid, storageid = data.storageid })
end)

RegisterNUICallback('openHerding', function(_, cb)
    cb('ok')
    CloseUI()
    TriggerEvent('rsg-ranch:client:openHerdingMenu')
end)

RegisterNUICallback('transferRanch', function(data, cb)
    cb('ok')
    local ranchid = currentRanchId
    CloseUI()
    TriggerServerEvent('rsg-ranch:server:transferRanchOwnership', ranchid, tonumber(data.id))
end)

RegisterNUICallback('sellRanch', function(_, cb)
    cb('ok')
    local ranchid = currentRanchId
    CloseUI()
    TriggerServerEvent('rsg-ranch:server:sellRanch', ranchid)
end)

RegisterNUICallback('purchaseRanch', function(data, cb)
    cb('ok')
    CloseUI()
    TriggerServerEvent('rsg-ranch:server:purchaseRanch', data.ranchid)
end)

RegisterNUICallback('getNearbyPlayers', function(_, cb)
    cb(Await('rsg-ranch:server:getNearbyPlayers') or {})
end)

---------------------------------------------
-- server asks this player to accept a job offer / ranch transfer
---------------------------------------------
lib.callback.register('rsg-ranch:client:requestConsent', function(header, content, timeout)
    if uiOpen then CloseUI() end
    local answered = false
    SetTimeout((tonumber(timeout) or 20) * 1000, function()
        if not answered then Menu.closeAlert() end
    end)
    local result = Menu.alertDialog({
        header = header,
        content = content,
        cancel = true,
        labels = { confirm = locale('cl_consent_accept'), cancel = locale('cl_consent_decline') },
    })
    answered = true
    return result == 'confirm'
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName and uiOpen then
        SetNuiFocus(false, false)
    end
end)
