-- Deployable well pumps (ported from rsg-farming)
local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local WP       = Config.WellPump
local Pumps    = {}   -- [id] = { id, citizenid, x, y, z, h }
local Reserved = {}   -- [src] = vector3 while a placement insert is awaiting the DB
local Pending  = {}   -- [src] = action timer
local Loaded   = false

---------------------------------
-- helpers
---------------------------------
local function notify(src, desc, ntype)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('cl_wellpump_title'), description = desc, type = ntype or 'inform', duration = 4000 })
end

local function distanceTo(src, x, y, z)
    return #(GetEntityCoords(GetPlayerPed(src)) - vector3(x, y, z))
end

local function toCoords(c)
    if type(c) ~= 'vector3' and type(c) ~= 'table' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    for _, v in ipairs({ x, y, z }) do
        if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    end
    return vector3(x, y, z)
end

local function toHeading(h)
    h = tonumber(h)
    if not h or h ~= h or h == math.huge or h == -math.huge then return 0.0 end
    return h % 360
end

local function hasItem(Player, item)
    local it = Player.Functions.GetItemByName(item)
    return it ~= nil and (it.amount or 0) > 0
end

local function itemBox(src, item, mode, amount)
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[item], mode, amount)
end

local function canAdd(src, item, amount)
    if not RSGCore.Shared.Items[item] then return false end
    local ok, res = pcall(function() return exports['rsg-inventory']:CanAddItem(src, item, amount or 1) end)
    return not ok or res ~= false
end

local function removeItem(src, item, amount, slot, reason)
    amount = amount or 1
    if not exports['rsg-inventory']:RemoveItem(src, item, amount, slot, reason) then return false end
    itemBox(src, item, 'remove', amount)
    return true
end

local function addItem(src, item, amount, info, reason)
    amount = amount or 1
    if amount <= 0 or not canAdd(src, item, amount) then return false end
    if not exports['rsg-inventory']:AddItem(src, item, amount, nil, info, reason) then return false end
    itemBox(src, item, 'add', amount)
    return true
end

-- action tokens: the server starts a timer at the pre-check and only accepts the
-- action once the progress bar could really have finished (stops anim skipping)
local function startAction(src, key, durationMs)
    Pending[src] = { key = key, t = GetGameTimer(), min = math.floor((durationMs or 0) * 0.8) }
end

local function finishAction(src, key)
    local p = Pending[src]
    Pending[src] = nil
    return p ~= nil and p.key == key and (GetGameTimer() - p.t) >= p.min
end

AddEventHandler('playerDropped', function()
    Pending[source] = nil
    Reserved[source] = nil
end)

---------------------------------
-- pumps
---------------------------------
local function list()
    local out = {}
    for _, p in pairs(Pumps) do out[#out + 1] = p end
    return out
end

local function syncAll()
    TriggerClientEvent('rsg-ranch:client:syncPumps', -1, list())
end

local function countPumps(cid)
    local n = 0
    for _, p in pairs(Pumps) do if p.citizenid == cid then n = n + 1 end end
    return n
end

local function validate(src, pumpId)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return nil, nil, locale('sv_wellpump_action_invalid') end
    local pump = Pumps[tonumber(pumpId)]
    if not pump then return nil, nil, locale('sv_wellpump_missing') end
    if distanceTo(src, pump.x, pump.y, pump.z) > WP.interactDist + 2.0 then
        return nil, nil, locale('cl_wellpump_too_far')
    end
    return Player, pump
end

local Rules = {
    fill = function(src, Player)
        if not hasItem(Player, WP.emptyItem) then return locale('sv_wellpump_no_bucket') end
        if not canAdd(src, WP.fullItem, 1) then return locale('sv_wellpump_inv_full') end
    end,
    pack = function(src, Player, pump)
        if WP.ownerOnlyPackup and pump.citizenid ~= Player.PlayerData.citizenid then return locale('sv_wellpump_not_owner') end
        if not canAdd(src, WP.item, 1) then return locale('sv_wellpump_inv_full') end
    end,
}
local Durations = { fill = WP.fillTime, pack = WP.packTime }

local function checkAction(src, action, pumpId)
    local Player, pump, err = validate(src, pumpId)
    if not Player then return nil, nil, err end
    if not finishAction(src, ('pump_%s:%s'):format(action, pump.id)) then return nil, nil, locale('sv_wellpump_action_invalid') end
    err = Rules[action](src, Player, pump)
    if err then return nil, nil, err end
    return Player, pump
end

---------------------------------
-- database
---------------------------------
CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rsg_ranch_wellpumps` (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `citizenid` VARCHAR(50) NOT NULL,
            `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `h` FLOAT NOT NULL DEFAULT 0,
            `placed_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    local rows = MySQL.query.await('SELECT * FROM rsg_ranch_wellpumps') or {}
    for _, r in ipairs(rows) do
        Pumps[r.id] = { id = r.id, citizenid = r.citizenid, x = r.x, y = r.y, z = r.z, h = r.h }
    end
    Loaded = true
    if Config.Debug then print(('[rsg-ranch] loaded %d well pumps'):format(#rows)) end
    syncAll()
end)

lib.callback.register('rsg-ranch:server:getPumps', function()
    while not Loaded do Wait(100) end
    return list()
end)

---------------------------------
-- usable item
---------------------------------
RSGCore.Functions.CreateUseableItem(WP.item, function(source)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return end
    if countPumps(Player.PlayerData.citizenid) >= WP.maxPerPlayer then
        return notify(source, locale('sv_wellpump_max'):format(WP.maxPerPlayer), 'error')
    end
    TriggerClientEvent('rsg-ranch:client:placePump', source)
end)

---------------------------------
-- place
---------------------------------
lib.callback.register('rsg-ranch:server:placePump', function(source, coords, heading)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    coords = toCoords(coords)
    if not Player or not coords then return false, locale('sv_wellpump_place_invalid') end
    if Reserved[src] then return false, locale('sv_wellpump_action_invalid') end

    if distanceTo(src, coords.x, coords.y, coords.z) > WP.placeMaxDistance + 2.0 then
        return false, locale('cl_wellpump_too_far')
    end
    local cid = Player.PlayerData.citizenid
    if countPumps(cid) >= WP.maxPerPlayer then return false, locale('sv_wellpump_max'):format(WP.maxPerPlayer) end
    for _, p in pairs(Pumps) do
        if #(vector3(p.x, p.y, p.z) - coords) < WP.minDistance then return false, locale('sv_wellpump_too_close') end
    end
    for _, r in pairs(Reserved) do
        if #(r - coords) < WP.minDistance then return false, locale('sv_wellpump_too_close') end
    end
    if not removeItem(src, WP.item, 1, nil, 'rsg-ranch:pump-place') then return false, locale('sv_wellpump_no_item') end

    local h = toHeading(heading)
    Reserved[src] = coords
    local id = MySQL.insert.await('INSERT INTO rsg_ranch_wellpumps (citizenid, x, y, z, h) VALUES (?, ?, ?, ?, ?)',
        { cid, coords.x, coords.y, coords.z, h })
    Reserved[src] = nil

    if not id then
        addItem(src, WP.item, 1, nil, 'rsg-ranch:pump-refund')
        return false, locale('sv_wellpump_place_invalid')
    end
    Pumps[id] = { id = id, citizenid = cid, x = coords.x, y = coords.y, z = coords.z, h = h }
    syncAll()
    return true, locale('sv_wellpump_placed')
end)

---------------------------------
-- pre-check (starts the action timer)
---------------------------------
lib.callback.register('rsg-ranch:server:pumpPrecheck', function(source, action, pumpId)
    if not Rules[action] then return false, locale('sv_wellpump_action_invalid') end
    local Player, pump, err = validate(source, pumpId)
    if not Player then return false, err end
    err = Rules[action](source, Player, pump)
    if err then return false, err end
    startAction(source, ('pump_%s:%s'):format(action, pump.id), Durations[action])
    return true
end)

---------------------------------
-- fill bucket
---------------------------------
lib.callback.register('rsg-ranch:server:fillBucket', function(source, pumpId)
    local Player, _, err = checkAction(source, 'fill', pumpId)
    if not Player then return false, err end
    if not removeItem(source, WP.emptyItem, 1, nil, 'rsg-ranch:fill') then return false, locale('sv_wellpump_no_bucket') end

    local uses = Config.BucketUses or 5
    if not addItem(source, WP.fullItem, 1, { uses = uses, description = locale('sv_bucket_uses'):format(uses, uses) }, 'rsg-ranch:fill') then
        addItem(source, WP.emptyItem, 1, nil, 'rsg-ranch:fill-refund')
        return false, locale('sv_wellpump_inv_full')
    end
    return true, locale('sv_wellpump_filled')
end)

---------------------------------
-- pack up
---------------------------------
lib.callback.register('rsg-ranch:server:packPump', function(source, pumpId)
    local Player, pump, err = checkAction(source, 'pack', pumpId)
    if not Player then return false, err end

    Pumps[pump.id] = nil
    MySQL.query('DELETE FROM rsg_ranch_wellpumps WHERE id = ?', { pump.id })
    addItem(source, WP.item, 1, nil, 'rsg-ranch:pump-pack')
    syncAll()
    return true, locale('sv_wellpump_packed')
end)
