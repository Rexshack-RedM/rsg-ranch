local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Ranch admin panel (server)
-- Every callback re-checks admin permission server-side; nothing the NUI
-- sends is trusted beyond the ids it names.
---------------------------------------------

local AdminCfg = Config.Admin or {}
local B = function() return RanchAdminBridge end -- set at the end of server.lua

local DefaultGradeNames = { [0] = 'Trainee Rancher', [1] = 'Ranch Hand', [2] = 'Ranch Manager' }
local BaseRanch = {} -- original config values, so a setting can be cleared back to default

for _, r in ipairs(Config.RanchLocations) do
    BaseRanch[r.ranchid] = { name = r.name, blipname = r.blipname, price = r.price, showblip = r.showblip }
end

local function IsAdmin(src)
    if src == 0 then return true end
    for _, perm in ipairs(AdminCfg.Permissions or { 'admin' }) do
        local ok, allowed = pcall(RSGCore.Functions.HasPermission, src, perm)
        if ok and allowed then return true end
    end
    return AdminCfg.AcePermission and IsPlayerAceAllowed(src, AdminCfg.AcePermission) or false
end

local function GetRanch(ranchid)
    if type(ranchid) ~= 'string' then return nil end
    for _, r in ipairs(Config.RanchLocations) do
        if r.ranchid == ranchid then return r end
    end
end

local function Log(src, ranchid, text)
    if not AdminCfg.Log then return end
    local who = src == 0 and 'console' or (GetPlayerName(src) or ('#' .. src))
    print(('^3[RANCH ADMIN]^7 %s @ %s: %s'):format(who, tostring(ranchid), text))
end

local function decodeName(charinfo)
    local ok, ci = pcall(json.decode, charinfo or '{}')
    if ok and type(ci) == 'table' then
        return ((ci.firstname or '') .. ' ' .. (ci.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
    end
    return nil
end

local function CharName(citizenid)
    if not citizenid then return nil end
    local P = RSGCore.Functions.GetPlayerByCitizenId(citizenid)
    if P then return P.PlayerData.charinfo.firstname .. ' ' .. P.PlayerData.charinfo.lastname, true end
    local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
    return row and decodeName(row.charinfo) or nil, false
end

local function GradeName(ranchid, grade)
    local job = RSGCore.Shared.Jobs and RSGCore.Shared.Jobs[ranchid]
    local g = job and job.grades and (job.grades[tostring(grade)] or job.grades[grade])
    return (g and g.name) or DefaultGradeNames[grade] or ('Grade ' .. grade)
end

local function clampInt(v, lo, hi)
    v = math.floor(tonumber(v) or lo)
    if v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

---------------------------------------------
-- settings overrides (name / blip / price)
---------------------------------------------
local function ApplySettingsRow(row)
    local r = GetRanch(row.ranchid)
    local base = BaseRanch[row.ranchid]
    if not r or not base then return end
    r.name = (row.name and row.name ~= '') and row.name or base.name
    r.blipname = (row.blipname and row.blipname ~= '') and row.blipname or base.blipname
    r.price = row.price or base.price
    if row.showblip == nil then r.showblip = base.showblip else r.showblip = (row.showblip == 1 or row.showblip == true) end
end

local function SettingsSnapshot()
    local out = {}
    for _, r in ipairs(Config.RanchLocations) do
        local e = { name = r.name, blipname = r.blipname, price = r.price, showblip = r.showblip }
        if r.custom then
            -- admin-created ranch: clients need the full definition to spawn its NPC / blip
            e.custom = true
            e.npcmodel = r.npcmodel
            e.jobaccess = r.jobaccess
            e.blipsprite = r.blipsprite
            e.blipscale = r.blipscale
            e.npc = { x = r.npccoords.x, y = r.npccoords.y, z = r.npccoords.z, w = r.npccoords.w }
            e.spawn = { x = r.spawnpoint.x, y = r.spawnpoint.y, z = r.spawnpoint.z, w = r.spawnpoint.w }
        end
        out[r.ranchid] = e
    end
    return out
end

---------------------------------------------
-- admin-created ranches (rsg_ranch_custom)
---------------------------------------------
local DefaultRanchGrades = {
    ['0'] = { name = 'Trainee Rancher', payment = 3 },
    ['1'] = { name = 'Ranch Hand', payment = 5 },
    ['2'] = { name = 'Ranch Manager', isboss = true, payment = 0 },
}

local function CoreJobs()
    local ok, core = pcall(function() return exports['rsg-core']:GetCoreObject() end)
    return ok and core and core.Shared and core.Shared.Jobs or {}
end

-- registers the ranch's job with rsg-core (live) and rsg-multijob's table (persistent)
local function EnsureRanchJob(ranchid, label)
    local job = { label = label, type = 'rancher', defaultDuty = true, offDutyPay = false, grades = DefaultRanchGrades }
    pcall(MySQL.query.await, [[INSERT IGNORE INTO multijob_jobs (name, label, type, icon, default_duty, off_duty_pay, grades) VALUES (?, ?, 'rancher', NULL, 1, 0, ?)]],
        { ranchid, label, json.encode(DefaultRanchGrades) })
    if not CoreJobs()[ranchid] then
        local ok, res, err = pcall(function() return exports['rsg-core']:AddJob(ranchid, job) end)
        if not ok or res == false then print(('^1[RANCH ADMIN]^7 rsg-core AddJob(%s) failed: %s'):format(ranchid, tostring(ok and err or res))) end
    end
    RSGCore.Shared.Jobs[ranchid] = RSGCore.Shared.Jobs[ranchid] or job
end

local function CustomRowToRanch(row)
    return {
        custom = true,
        name = row.name,
        ranchid = row.ranchid,
        coords = vector3(row.npc_x, row.npc_y, row.npc_z),
        npcmodel = joaat(row.npcmodel),
        npccoords = vector4(row.npc_x, row.npc_y, row.npc_z, row.npc_w),
        jobaccess = row.ranchid,
        blipname = row.name,
        blipsprite = row.blipsprite,
        blipscale = row.blipscale,
        showblip = true,
        spawnpoint = vector4(row.spawn_x, row.spawn_y, row.spawn_z, row.spawn_w),
        price = row.price,
    }
end

local function AddCustomRanch(row)
    if GetRanch(row.ranchid) then return end
    local r = CustomRowToRanch(row)
    Config.RanchLocations[#Config.RanchLocations + 1] = r
    BaseRanch[r.ranchid] = { name = r.name, blipname = r.blipname, price = r.price, showblip = r.showblip }
    EnsureRanchJob(r.ranchid, r.name .. ' Rancher')
end

local function BroadcastRanches()
    TriggerClientEvent('rsg-ranch:client:applyRanchSettings', -1, SettingsSnapshot())
end

CreateThread(function()
    Wait(1500) -- let server.lua's table auto-install run first
    local okc, customs = pcall(MySQL.query.await, 'SELECT * FROM rsg_ranch_custom', {})
    if okc and customs then
        for _, row in ipairs(customs) do AddCustomRanch(row) end
    end
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM rsg_ranch_settings', {})
    if ok and rows then
        for _, row in ipairs(rows) do ApplySettingsRow(row) end
    end
    TriggerClientEvent('rsg-ranch:client:applyRanchSettings', -1, SettingsSnapshot())
end)

lib.callback.register('rsg-ranch:server:getRanchSettings', function()
    return SettingsSnapshot()
end)

---------------------------------------------
-- staff helpers (online + offline)
---------------------------------------------
local function GetStaff(ranchid)
    local list, seen = {}, {}
    for _, id in ipairs(RSGCore.Functions.GetPlayers()) do
        local P = RSGCore.Functions.GetPlayer(id)
        if P and P.PlayerData.job.name == ranchid then
            seen[P.PlayerData.citizenid] = true
            list[#list + 1] = {
                citizenid = P.PlayerData.citizenid,
                name = P.PlayerData.charinfo.firstname .. ' ' .. P.PlayerData.charinfo.lastname,
                grade = P.PlayerData.job.grade.level,
                gradeLabel = P.PlayerData.job.grade.name,
                online = true,
                serverId = id,
            }
        end
    end
    local rows = MySQL.query.await('SELECT citizenid, charinfo, job FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', { ranchid }) or {}
    for _, row in ipairs(rows) do
        if not seen[row.citizenid] then
            local ok, job = pcall(json.decode, row.job or '{}')
            local grade = ok and job and job.grade and tonumber(job.grade.level) or 0
            list[#list + 1] = {
                citizenid = row.citizenid,
                name = decodeName(row.charinfo) or row.citizenid,
                grade = grade,
                gradeLabel = ok and job and job.grade and job.grade.name or GradeName(ranchid, grade),
                online = false,
            }
        end
    end
    table.sort(list, function(a, b) if a.grade ~= b.grade then return a.grade > b.grade end return a.name < b.name end)
    return list
end

local function SetStaffJob(ranchid, citizenid, grade)
    local P = RSGCore.Functions.GetPlayerByCitizenId(citizenid)
    if P then
        local added, reason = B().MultijobAddJob(citizenid, ranchid, grade)
        if not added and reason == 'max_jobs' and P.PlayerData.job.name ~= ranchid then return false, 'sv_adm_max_jobs' end
        P.Functions.SetJob(ranchid, grade)
        return true
    end
    local exists = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ?', { citizenid })
    if not exists then return false, 'sv_adm_no_player' end
    local added, reason = B().MultijobAddJob(citizenid, ranchid, grade)
    if not added and reason == 'max_jobs' then return false, 'sv_adm_max_jobs' end
    MySQL.update.await('UPDATE players SET job = JSON_SET(JSON_SET(job, "$.name", ?), "$.grade", JSON_OBJECT("level", ?, "name", ?)) WHERE citizenid = ?',
        { ranchid, grade, GradeName(ranchid, grade), citizenid })
    return true
end

local function RemoveStaffJob(ranchid, citizenid)
    local P = RSGCore.Functions.GetPlayerByCitizenId(citizenid)
    if P then
        if P.PlayerData.job.name == ranchid then P.Functions.SetJob('unemployed', 0) end
        TriggerClientEvent('ox_lib:notify', P.PlayerData.source, { type = 'error', description = locale('sv_adm_removed_from_ranch'):format((GetRanch(ranchid) or {}).name or ranchid) })
    else
        MySQL.update.await('UPDATE players SET job = JSON_SET(JSON_SET(job, "$.name", "unemployed"), "$.grade", JSON_OBJECT("level", 0, "name", "Unemployed")) WHERE citizenid = ? AND JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', { citizenid, ranchid })
    end
    B().MultijobRemoveJob(citizenid, ranchid)
end

-- resolve "a server id or a citizenid" typed by the admin
local function ResolveCitizen(value)
    local id = tonumber(value)
    if id then
        local P = RSGCore.Functions.GetPlayer(id)
        if P then return P.PlayerData.citizenid end
    end
    if type(value) == 'string' and value ~= '' then
        local row = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ?', { value })
        if row then return row.citizenid end
    end
    return nil
end

---------------------------------------------
-- reset a ranch to default (same wipe as selling it, without a refund)
---------------------------------------------
local function WipeRanch(ranchid)
    for _, storage in ipairs(B().GetRanchStorages(ranchid)) do
        pcall(function() exports['rsg-inventory']:ClearStash(storage.storageid) end)
    end
    local animals = MySQL.query.await('SELECT animalid FROM rsg_ranch_animals WHERE ranchid = ?', { ranchid }) or {}
    local feed = MySQL.query.await('SELECT feedtroughid FROM rsg_ranch_feedtroughs WHERE ranchid = ?', { ranchid }) or {}
    local water = MySQL.query.await('SELECT watertroughid FROM rsg_ranch_watertroughs WHERE ranchid = ?', { ranchid }) or {}
    local coops = MySQL.query.await('SELECT coopid FROM rsg_ranch_chickencoops WHERE ranchid = ?', { ranchid }) or {}

    for _, t in ipairs({ 'rsg_ranch_animals', 'rsg_ranch_feedtroughs', 'rsg_ranch_watertroughs', 'rsg_ranch_chickencoops', 'rsg_ranch_orders', 'rsg_ranch_storages', 'rsg_ranch_owners' }) do
        MySQL.query.await(('DELETE FROM `%s` WHERE ranchid = ?'):format(t), { ranchid })
    end
    B().Owners[ranchid] = nil

    for _, r in ipairs(animals) do TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, r.animalid) end
    for _, r in ipairs(feed) do TriggerClientEvent('rsg-ranch:client:removeFeedTrough', -1, r.feedtroughid) end
    for _, r in ipairs(water) do TriggerClientEvent('rsg-ranch:client:removeWaterTrough', -1, r.watertroughid) end
    for _, r in ipairs(coops) do TriggerClientEvent('rsg-ranch:client:removeChickenCoop', -1, r.coopid) end

    B().FireAllRanchStaff(ranchid, nil)
end

---------------------------------------------
-- data for the panel
---------------------------------------------
local function CountBy(tbl)
    local out = {}
    for _, row in ipairs(MySQL.query.await(('SELECT ranchid, COUNT(*) AS c FROM `%s` GROUP BY ranchid'):format(tbl), {}) or {}) do
        out[row.ranchid] = row.c
    end
    return out
end

lib.callback.register('rsg-ranch:admin:getOverview', function(src)
    if not IsAdmin(src) then return nil end
    local animals, feed, water = CountBy('rsg_ranch_animals'), CountBy('rsg_ranch_feedtroughs'), CountBy('rsg_ranch_watertroughs')
    local coops, storages, orders = CountBy('rsg_ranch_chickencoops'), CountBy('rsg_ranch_storages'), CountBy('rsg_ranch_orders')

    local staff = {}
    for _, row in ipairs(MySQL.query.await('SELECT JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) AS j, COUNT(*) AS c FROM players GROUP BY j', {}) or {}) do
        if row.j then staff[row.j] = row.c end
    end

    local list = {}
    for _, r in ipairs(Config.RanchLocations) do
        local owner = B().Owners[r.ranchid]
        local ownerName, online = nil, false
        if owner then ownerName, online = CharName(owner) end
        list[#list + 1] = {
            ranchid = r.ranchid, name = r.name, price = r.price, showblip = r.showblip, custom = r.custom == true,
            owner = owner, ownerName = ownerName, ownerOnline = online,
            animals = animals[r.ranchid] or 0, staff = staff[r.ranchid] or 0,
            feedtroughs = feed[r.ranchid] or 0, watertroughs = water[r.ranchid] or 0,
            coops = coops[r.ranchid] or 0, storages = storages[r.ranchid] or 0, orders = orders[r.ranchid] or 0,
        }
    end
    return {
        ranches = list,
        maxAnimals = Config.MaxRanchAnimals,
        bossGrade = Config.RanchBossGrade,
    }
end)

lib.callback.register('rsg-ranch:admin:getRanch', function(src, ranchid)
    if not IsAdmin(src) then return nil end
    local r = GetRanch(ranchid)
    if not r then return nil end

    local ownerCid = B().Owners[ranchid]
    local owner = nil
    if ownerCid then
        local name, online = CharName(ownerCid)
        local row = MySQL.single.await('SELECT purchased_at FROM rsg_ranch_owners WHERE ranchid = ?', { ranchid })
        owner = { citizenid = ownerCid, name = name or ownerCid, online = online, purchased_at = row and row.purchased_at or 0 }
    end

    local grades = {}
    for g = 0, Config.RanchBossGrade do grades[#grades + 1] = { grade = g, label = GradeName(ranchid, g) } end

    local sizes = {}
    for key, s in pairs(Config.RanchStorageSizes or {}) do
        sizes[#sizes + 1] = { key = key, label = s.label, slots = s.slots, maxweight = s.maxweight, price = s.price }
    end
    table.sort(sizes, function(a, b) return a.price < b.price end)

    local base = BaseRanch[ranchid] or {}
    return {
        now = os.time(),
        ranch = {
            ranchid = r.ranchid, name = r.name, blipname = r.blipname, price = r.price, showblip = r.showblip,
            jobaccess = r.jobaccess,
            custom = r.custom == true,
            coords = { x = r.coords.x, y = r.coords.y, z = r.coords.z },
            spawn = r.spawnpoint and { x = r.spawnpoint.x, y = r.spawnpoint.y, z = r.spawnpoint.z, w = r.spawnpoint.w } or nil,
            defaults = base,
        },
        owner = owner,
        staff = GetStaff(ranchid),
        grades = grades,
        maxAnimals = Config.MaxRanchAnimals,
        animals = MySQL.query.await('SELECT animalid, model, gender, age, health, hunger, thirst, product_ready, pregnant, gestation_end_time, born, pos_x, pos_y, pos_z FROM rsg_ranch_animals WHERE ranchid = ? ORDER BY model, animalid', { ranchid }) or {},
        feedtroughs = MySQL.query.await('SELECT feedtroughid AS id, uses, placed_by, created_at, pos_x, pos_y, pos_z FROM rsg_ranch_feedtroughs WHERE ranchid = ?', { ranchid }) or {},
        watertroughs = MySQL.query.await('SELECT watertroughid AS id, uses, placed_by, created_at, pos_x, pos_y, pos_z FROM rsg_ranch_watertroughs WHERE ranchid = ?', { ranchid }) or {},
        coops = MySQL.query.await('SELECT coopid, chickens, eggs_stored, feed_level, placed_by, created_at, pos_x, pos_y, pos_z FROM rsg_ranch_chickencoops WHERE ranchid = ?', { ranchid }) or {},
        storages = MySQL.query.await('SELECT storageid, size, label, maxweight, slots, min_grade, purchased_by, created_at FROM rsg_ranch_storages WHERE ranchid = ? ORDER BY id ASC', { ranchid }) or {},
        storageSizes = sizes,
        orders = MySQL.query.await('SELECT orderid, citizenid, item, amount, price, ordered_at, ready_at FROM rsg_ranch_orders WHERE ranchid = ? ORDER BY ordered_at DESC', { ranchid }) or {},
    }
end)

---------------------------------------------
-- actions
---------------------------------------------
local Actions = {}

Actions.setOwner = function(src, ranchid, d)
    local cid = ResolveCitizen(d.target)
    if not cid then return false, 'sv_adm_no_player' end
    local old = B().Owners[ranchid]
    if old == cid then return false, 'sv_adm_already_owner' end

    local ok, err = SetStaffJob(ranchid, cid, Config.RanchBossGrade)
    if not ok then return false, err end
    if old then RemoveStaffJob(ranchid, old) end

    MySQL.query.await('INSERT INTO rsg_ranch_owners (ranchid, citizenid, purchased_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE citizenid = VALUES(citizenid), purchased_at = VALUES(purchased_at)', { ranchid, cid, os.time() })
    B().Owners[ranchid] = cid
    B().EnsureGeneralStorage(ranchid)

    local P = RSGCore.Functions.GetPlayerByCitizenId(cid)
    if P then TriggerClientEvent('ox_lib:notify', P.PlayerData.source, { type = 'success', description = locale('sv_adm_given_ranch'):format(GetRanch(ranchid).name) }) end
    Log(src, ranchid, ('owner set to %s (was %s)'):format(cid, tostring(old)))
    return true, 'sv_adm_owner_set'
end

Actions.removeOwner = function(src, ranchid)
    local old = B().Owners[ranchid]
    if not old then return false, 'sv_adm_no_owner' end
    MySQL.query.await('DELETE FROM rsg_ranch_owners WHERE ranchid = ?', { ranchid })
    B().Owners[ranchid] = nil
    RemoveStaffJob(ranchid, old)
    Log(src, ranchid, 'owner removed: ' .. old)
    return true, 'sv_adm_owner_removed'
end

Actions.resetRanch = function(src, ranchid)
    WipeRanch(ranchid)
    Log(src, ranchid, 'ranch reset to default')
    return true, 'sv_adm_ranch_reset'
end

Actions.hire = function(src, ranchid, d)
    local cid = ResolveCitizen(d.target)
    if not cid then return false, 'sv_adm_no_player' end
    local grade = clampInt(d.grade, 0, Config.RanchBossGrade)
    local ok, err = SetStaffJob(ranchid, cid, grade)
    if not ok then return false, err end
    Log(src, ranchid, ('hired %s at grade %d'):format(cid, grade))
    return true, 'sv_adm_staff_updated'
end

Actions.setGrade = function(src, ranchid, d)
    if type(d.citizenid) ~= 'string' then return false end
    local grade = clampInt(d.grade, 0, Config.RanchBossGrade)
    local ok, err = SetStaffJob(ranchid, d.citizenid, grade)
    if not ok then return false, err end
    Log(src, ranchid, ('set %s to grade %d'):format(d.citizenid, grade))
    return true, 'sv_adm_staff_updated'
end

Actions.fire = function(src, ranchid, d)
    if type(d.citizenid) ~= 'string' then return false end
    if B().Owners[ranchid] == d.citizenid then return false, 'sv_adm_fire_owner' end
    RemoveStaffJob(ranchid, d.citizenid)
    Log(src, ranchid, 'fired ' .. d.citizenid)
    return true, 'sv_adm_staff_fired'
end

Actions.fireAll = function(src, ranchid)
    B().FireAllRanchStaff(ranchid, B().Owners[ranchid])
    Log(src, ranchid, 'fired all staff (owner kept)')
    return true, 'sv_adm_staff_fired'
end

Actions.updateAnimal = function(src, ranchid, d)
    local stats = {
        health = clampInt(d.health, 0, 100),
        hunger = clampInt(d.hunger, 0, 100),
        thirst = clampInt(d.thirst, 0, 100),
        age = clampInt(d.age, 0, 65535),
        product_ready = d.product_ready and 1 or 0,
    }
    local n = MySQL.update.await('UPDATE rsg_ranch_animals SET health = ?, hunger = ?, thirst = ?, age = ?, product_ready = ? WHERE animalid = ? AND ranchid = ?',
        { stats.health, stats.hunger, stats.thirst, stats.age, stats.product_ready, tostring(d.animalid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    TriggerClientEvent('rsg-ranch:client:refreshSingleAnimal', -1, tostring(d.animalid), stats)
    Log(src, ranchid, 'edited animal ' .. tostring(d.animalid))
    return true, 'sv_adm_saved'
end

Actions.healAll = function(src, ranchid)
    MySQL.update.await('UPDATE rsg_ranch_animals SET health = 100, hunger = 100, thirst = 100 WHERE ranchid = ?', { ranchid })
    RanchBroadcastAnimals(-1)
    Log(src, ranchid, 'healed / fed / watered all animals')
    return true, 'sv_adm_saved'
end

Actions.deleteAnimal = function(src, ranchid, d)
    local n = MySQL.update.await('DELETE FROM rsg_ranch_animals WHERE animalid = ? AND ranchid = ?', { tostring(d.animalid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, tostring(d.animalid))
    Log(src, ranchid, 'deleted animal ' .. tostring(d.animalid))
    return true, 'sv_adm_deleted'
end

Actions.deleteAllAnimals = function(src, ranchid)
    local rows = MySQL.query.await('SELECT animalid FROM rsg_ranch_animals WHERE ranchid = ?', { ranchid }) or {}
    MySQL.query.await('DELETE FROM rsg_ranch_animals WHERE ranchid = ?', { ranchid })
    for _, r in ipairs(rows) do TriggerClientEvent('rsg-ranch:client:removeAnimal', -1, r.animalid) end
    Log(src, ranchid, ('deleted all %d animals'):format(#rows))
    return true, 'sv_adm_deleted'
end

local Troughs = {
    feed = { tbl = 'rsg_ranch_feedtroughs', col = 'feedtroughid', update = 'rsg-ranch:client:updateFeedTroughUses', remove = 'rsg-ranch:client:removeFeedTrough' },
    water = { tbl = 'rsg_ranch_watertroughs', col = 'watertroughid', update = 'rsg-ranch:client:updateWaterTroughUses', remove = 'rsg-ranch:client:removeWaterTrough' },
}

Actions.troughUses = function(src, ranchid, d)
    local t = Troughs[d.kind]
    if not t then return false end
    local uses = clampInt(d.uses, 0, 255)
    local n = MySQL.update.await(('UPDATE `%s` SET uses = ? WHERE `%s` = ? AND ranchid = ?'):format(t.tbl, t.col), { uses, tostring(d.id), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    TriggerClientEvent(t.update, -1, tostring(d.id), uses)
    Log(src, ranchid, ('%s trough %s uses -> %d'):format(d.kind, tostring(d.id), uses))
    return true, 'sv_adm_saved'
end

Actions.troughDelete = function(src, ranchid, d)
    local t = Troughs[d.kind]
    if not t then return false end
    local n = MySQL.update.await(('DELETE FROM `%s` WHERE `%s` = ? AND ranchid = ?'):format(t.tbl, t.col), { tostring(d.id), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    TriggerClientEvent(t.remove, -1, tostring(d.id))
    Log(src, ranchid, ('deleted %s trough %s'):format(d.kind, tostring(d.id)))
    return true, 'sv_adm_deleted'
end

Actions.coopUpdate = function(src, ranchid, d)
    local chickens = clampInt(d.chickens, 0, 65535)
    local n = MySQL.update.await('UPDATE rsg_ranch_chickencoops SET chickens = ?, eggs_stored = ?, feed_level = ?, last_feed_update = ? WHERE coopid = ? AND ranchid = ?',
        { chickens, clampInt(d.eggs_stored, 0, 65535), clampInt(d.feed_level, 0, 100), os.time(), tostring(d.coopid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    TriggerClientEvent('rsg-ranch:client:updateChickenCoop', -1, tostring(d.coopid), chickens)
    Log(src, ranchid, 'edited coop ' .. tostring(d.coopid))
    return true, 'sv_adm_saved'
end

Actions.coopDelete = function(src, ranchid, d)
    local n = MySQL.update.await('DELETE FROM rsg_ranch_chickencoops WHERE coopid = ? AND ranchid = ?', { tostring(d.coopid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    TriggerClientEvent('rsg-ranch:client:removeChickenCoop', -1, tostring(d.coopid))
    Log(src, ranchid, 'deleted coop ' .. tostring(d.coopid))
    return true, 'sv_adm_deleted'
end

Actions.storageUpdate = function(src, ranchid, d)
    local label = tostring(d.label or ''):sub(1, 50)
    if label:gsub('%s', '') == '' then return false, 'sv_adm_bad_label' end
    local n = MySQL.update.await('UPDATE rsg_ranch_storages SET label = ?, slots = ?, maxweight = ?, min_grade = ? WHERE storageid = ? AND ranchid = ?',
        { label, clampInt(d.slots, 1, 1000), clampInt(d.maxweight, 1000, 4000000000), clampInt(d.min_grade, 0, Config.RanchBossGrade), tostring(d.storageid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    Log(src, ranchid, 'edited storage ' .. tostring(d.storageid))
    return true, 'sv_adm_saved'
end

Actions.storageClear = function(src, ranchid, d)
    local row = MySQL.single.await('SELECT storageid FROM rsg_ranch_storages WHERE storageid = ? AND ranchid = ?', { tostring(d.storageid), ranchid })
    if not row then return false, 'sv_adm_not_found' end
    pcall(function() exports['rsg-inventory']:ClearStash(row.storageid) end)
    Log(src, ranchid, 'emptied storage ' .. row.storageid)
    return true, 'sv_adm_storage_cleared'
end

Actions.storageDelete = function(src, ranchid, d)
    local row = MySQL.single.await('SELECT storageid, size FROM rsg_ranch_storages WHERE storageid = ? AND ranchid = ?', { tostring(d.storageid), ranchid })
    if not row then return false, 'sv_adm_not_found' end
    if row.size == 'general' then return false, 'sv_adm_general_storage' end
    pcall(function() exports['rsg-inventory']:ClearStash(row.storageid) end)
    MySQL.query.await('DELETE FROM rsg_ranch_storages WHERE storageid = ?', { row.storageid })
    Log(src, ranchid, 'deleted storage ' .. row.storageid)
    return true, 'sv_adm_deleted'
end

Actions.storageAdd = function(src, ranchid, d)
    local size = Config.RanchStorageSizes and Config.RanchStorageSizes[d.size]
    if not size then return false end
    local id = B().GenerateStorageId(ranchid)
    MySQL.insert.await('INSERT INTO rsg_ranch_storages (storageid, ranchid, size, label, maxweight, slots, min_grade, purchased_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { id, ranchid, d.size, size.label, size.maxweight, size.slots, Config.StorageMinJobGrade, 'admin', os.time() })
    Log(src, ranchid, ('added %s storage %s'):format(d.size, id))
    return true, 'sv_adm_saved'
end

Actions.orderReady = function(src, ranchid, d)
    local n = MySQL.update.await('UPDATE rsg_ranch_orders SET ready_at = ? WHERE orderid = ? AND ranchid = ?', { os.time(), tostring(d.orderid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    Log(src, ranchid, 'marked order ready ' .. tostring(d.orderid))
    return true, 'sv_adm_saved'
end

Actions.orderDelete = function(src, ranchid, d)
    local n = MySQL.update.await('DELETE FROM rsg_ranch_orders WHERE orderid = ? AND ranchid = ?', { tostring(d.orderid), ranchid })
    if not n or n < 1 then return false, 'sv_adm_not_found' end
    Log(src, ranchid, 'deleted order ' .. tostring(d.orderid))
    return true, 'sv_adm_deleted'
end

Actions.saveSettings = function(src, ranchid, d)
    local base = BaseRanch[ranchid]
    local name = tostring(d.name or ''):sub(1, 100)
    local blipname = tostring(d.blipname or ''):sub(1, 100)
    local row = {
        ranchid = ranchid,
        name = (name ~= '' and name ~= base.name) and name or nil,
        blipname = (blipname ~= '' and blipname ~= base.blipname) and blipname or nil,
        price = tonumber(d.price) and clampInt(d.price, 0, 100000000) or nil,
        showblip = d.showblip and 1 or 0,
    }
    if row.price == base.price then row.price = nil end
    if (row.showblip == 1) == (base.showblip == true) then row.showblip = nil end

    MySQL.query.await('INSERT INTO rsg_ranch_settings (ranchid, name, blipname, price, showblip, updated_by, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), blipname = VALUES(blipname), price = VALUES(price), showblip = VALUES(showblip), updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)',
        { ranchid, row.name, row.blipname, row.price, row.showblip, src == 0 and 'console' or (RSGCore.Functions.GetPlayer(src) or { PlayerData = {} }).PlayerData.citizenid, os.time() })
    ApplySettingsRow(row)
    TriggerClientEvent('rsg-ranch:client:applyRanchSettings', -1, SettingsSnapshot())
    Log(src, ranchid, 'settings saved')
    return true, 'sv_adm_saved'
end

Actions.resetSettings = function(src, ranchid)
    MySQL.query.await('DELETE FROM rsg_ranch_settings WHERE ranchid = ?', { ranchid })
    ApplySettingsRow({ ranchid = ranchid })
    TriggerClientEvent('rsg-ranch:client:applyRanchSettings', -1, SettingsSnapshot())
    Log(src, ranchid, 'settings reset to config defaults')
    return true, 'sv_adm_saved'
end

local function AdminPos(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z, w = GetEntityHeading(ped) }
end

Actions.setNpcHere = function(src, ranchid)
    local r = GetRanch(ranchid)
    if not r.custom then return false, 'sv_adm_custom_only' end
    local p = AdminPos(src)
    if not p then return false end
    MySQL.update.await('UPDATE rsg_ranch_custom SET npc_x = ?, npc_y = ?, npc_z = ?, npc_w = ? WHERE ranchid = ?', { p.x, p.y, p.z, p.w, ranchid })
    r.npccoords = vector4(p.x, p.y, p.z, p.w)
    r.coords = vector3(p.x, p.y, p.z)
    BroadcastRanches()
    Log(src, ranchid, 'moved NPC')
    return true, 'sv_adm_saved'
end

Actions.setSpawnHere = function(src, ranchid)
    local r = GetRanch(ranchid)
    if not r.custom then return false, 'sv_adm_custom_only' end
    local p = AdminPos(src)
    if not p then return false end
    MySQL.update.await('UPDATE rsg_ranch_custom SET spawn_x = ?, spawn_y = ?, spawn_z = ?, spawn_w = ? WHERE ranchid = ?', { p.x, p.y, p.z, p.w, ranchid })
    r.spawnpoint = vector4(p.x, p.y, p.z, p.w)
    BroadcastRanches()
    Log(src, ranchid, 'moved animal spawn point')
    return true, 'sv_adm_saved'
end

Actions.deleteRanch = function(src, ranchid)
    local r = GetRanch(ranchid)
    if not r.custom then return false, 'sv_adm_custom_only' end
    WipeRanch(ranchid)
    MySQL.query.await('DELETE FROM rsg_ranch_custom WHERE ranchid = ?', { ranchid })
    MySQL.query.await('DELETE FROM rsg_ranch_settings WHERE ranchid = ?', { ranchid })
    pcall(MySQL.query.await, 'DELETE FROM multijob_jobs WHERE name = ?', { ranchid })
    pcall(MySQL.query.await, 'DELETE FROM player_jobs WHERE job = ?', { ranchid })
    pcall(function() exports['rsg-core']:RemoveJob(ranchid) end)
    for i, x in ipairs(Config.RanchLocations) do
        if x.ranchid == ranchid then table.remove(Config.RanchLocations, i) break end
    end
    BaseRanch[ranchid] = nil
    BroadcastRanches()
    Log(src, ranchid, 'deleted custom ranch')
    return true, 'sv_adm_ranch_deleted'
end

lib.callback.register('rsg-ranch:admin:createRanch', function(src, data)
    if not IsAdmin(src) then return { ok = false, msg = locale('sv_adm_no_permission') } end
    if type(data) ~= 'table' then return { ok = false, msg = locale('sv_adm_invalid') } end

    local name = tostring(data.name or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 100)
    local ranchid = tostring(data.ranchid or ''):lower()
    if name == '' then return { ok = false, msg = locale('sv_adm_bad_name') } end
    if not ranchid:match('^[a-z0-9_]+$') or #ranchid < 3 or #ranchid > 40 then return { ok = false, msg = locale('sv_adm_bad_id') } end
    if GetRanch(ranchid) or CoreJobs()[ranchid] then return { ok = false, msg = locale('sv_adm_id_taken') } end

    local p = AdminPos(src)
    if not p then return { ok = false, msg = locale('sv_adm_failed') } end
    local h = math.rad(p.w)
    local row = {
        ranchid = ranchid, name = name, price = clampInt(data.price, 0, 100000000), npcmodel = 'g_m_m_uniranchers_01',
        npc_x = p.x, npc_y = p.y, npc_z = p.z, npc_w = p.w,
        -- default animal spawn: 10m in front of where the admin is facing (move it later with "Set animal spawn here")
        spawn_x = p.x - math.sin(h) * 10.0, spawn_y = p.y + math.cos(h) * 10.0, spawn_z = p.z, spawn_w = p.w,
        blipsprite = 'blip_ambient_herd', blipscale = 0.2,
    }
    local Player = RSGCore.Functions.GetPlayer(src)
    MySQL.insert.await([[INSERT INTO rsg_ranch_custom (ranchid, name, price, npcmodel, npc_x, npc_y, npc_z, npc_w, spawn_x, spawn_y, spawn_z, spawn_w, blipsprite, blipscale, created_by, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        { row.ranchid, row.name, row.price, row.npcmodel, row.npc_x, row.npc_y, row.npc_z, row.npc_w, row.spawn_x, row.spawn_y, row.spawn_z, row.spawn_w,
          row.blipsprite, row.blipscale, Player and Player.PlayerData.citizenid or 'console', os.time() })

    AddCustomRanch(row)
    BroadcastRanches()
    Log(src, ranchid, ('created ranch "%s" at %.1f, %.1f, %.1f'):format(name, p.x, p.y, p.z))
    return { ok = true, ranchid = ranchid, msg = locale('sv_adm_ranch_created'):format(name) }
end)

local busy = {}

lib.callback.register('rsg-ranch:admin:action', function(src, ranchid, kind, data)
    if not IsAdmin(src) then return { ok = false, msg = locale('sv_adm_no_permission') } end
    if not GetRanch(ranchid) or type(kind) ~= 'string' or not Actions[kind] then return { ok = false, msg = locale('sv_adm_invalid') } end
    if busy[ranchid] then return { ok = false, msg = locale('sv_adm_busy') } end
    busy[ranchid] = true
    local ok, success, key = pcall(Actions[kind], src, ranchid, type(data) == 'table' and data or {})
    busy[ranchid] = nil
    if not ok then
        print(('^1[RANCH ADMIN]^7 action %s failed: %s'):format(kind, tostring(success)))
        return { ok = false, msg = locale('sv_adm_failed') }
    end
    return { ok = success == true, msg = key and locale(key) or (success and locale('sv_adm_saved') or locale('sv_adm_failed')) }
end)

---------------------------------------------
-- player search (database + online), used by every player picker in the panel
---------------------------------------------
lib.callback.register('rsg-ranch:admin:searchPlayers', function(src, query)
    if not IsAdmin(src) then return {} end
    query = tostring(query or ''):sub(1, 50):gsub('^%s+', ''):gsub('%s+$', '')

    local online = {}
    for _, id in ipairs(RSGCore.Functions.GetPlayers()) do
        local P = RSGCore.Functions.GetPlayer(id)
        if P then online[P.PlayerData.citizenid] = id end
    end

    local rows
    if query == '' then
        -- no search text: list everyone currently online
        local cids = {}
        for cid in pairs(online) do cids[#cids + 1] = cid end
        if #cids == 0 then return {} end
        rows = MySQL.query.await('SELECT citizenid, charinfo, job FROM players WHERE citizenid IN (?) LIMIT 50', { cids }) or {}
    else
        local like = '%' .. query:gsub('[%%_\\]', '\\%0') .. '%'
        rows = MySQL.query.await([[
            SELECT citizenid, charinfo, job FROM players
            WHERE citizenid LIKE ?
               OR CONCAT(JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.firstname')), ' ', JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.lastname'))) LIKE ?
            LIMIT 25]], { like, like }) or {}
    end

    local out = {}
    for _, row in ipairs(rows) do
        local ok, job = pcall(json.decode, row.job or '{}')
        job = ok and type(job) == 'table' and job or {}
        out[#out + 1] = {
            citizenid = row.citizenid,
            name = decodeName(row.charinfo) or row.citizenid,
            job = job.label or job.name or 'unemployed',
            grade = job.grade and job.grade.name or nil,
            online = online[row.citizenid] ~= nil,
            serverId = online[row.citizenid],
        }
    end
    table.sort(out, function(a, b) if a.online ~= b.online then return a.online end return a.name < b.name end)
    return out
end)

---------------------------------------------
-- command
---------------------------------------------
RegisterCommand(AdminCfg.Command or 'ranchadmin', function(src)
    if src == 0 then return print('[RANCH ADMIN] use this in game') end
    if not IsAdmin(src) then
        return TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = locale('sv_adm_no_permission') })
    end
    TriggerClientEvent('rsg-ranch:client:openAdmin', src)
end, false)
