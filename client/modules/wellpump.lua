-- Deployable well pumps (ported from rsg-farming): place a pump, fill an empty
-- 'bucket' into a 'fullbucket' (limited uses), pack it back up later.
local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local WP      = Config.WellPump
local Pumps   = {}   -- [id] = data
local Spawned = {}   -- [id] = entity
local busy    = false
local ownProps = {}  -- [entity] = true for props we spawned

local CONTROLS = {
    place   = 0xC7B5340A, -- ENTER
    cancel  = 0xF84FA74F, -- RMB
    cancel2 = 0x156F7119, -- Backspace
    rotL    = 0xA65EBAB4, -- Arrow Left
    rotR    = 0xDEB34313, -- Arrow Right
    up      = 0x6319DB71, -- Arrow Up
    down    = 0x05CA7C52, -- Arrow Down
}

---------------------------------
-- helpers
---------------------------------
local function notify(desc, ntype)
    if not desc then return end
    lib.notify({ title = locale('cl_wellpump_title'), description = desc, type = ntype or 'inform', duration = 4000 })
end

local function canAct()
    local ped = PlayerPedId()
    return not busy and not IsEntityDead(ped) and not IsPedInAnyVehicle(ped, false) and not IsPedOnMount(ped)
end

local function face(x, y)
    TaskTurnPedToFaceCoord(PlayerPedId(), x, y, 0.0, 800)
    Wait(800)
end

local function getCid()
    local pd = RSGCore.Functions.GetPlayerData()
    return pd and pd.citizenid
end

local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash, false)
    local t = GetGameTimer()
    while not HasModelLoaded(hash) do
        if GetGameTimer() - t > 5000 then return nil end
        Wait(10)
    end
    return hash
end

local function snapshotObjects()
    local set = {}
    for _, obj in ipairs(GetGamePool('CObject')) do set[obj] = true end
    return set
end

-- removes props a scenario spawned (the bucket etc.) whether still held or dropped
local function cleanupScenarioProps(ped, before)
    local myId = PlayerId()
    local pedPos = GetEntityCoords(ped)
    for _, obj in ipairs(GetGamePool('CObject')) do
        if not before[obj] and not ownProps[obj] and DoesEntityExist(obj) then
            local attached = IsEntityAttachedToEntity(obj, ped)
            local nearMine = #(GetEntityCoords(obj) - pedPos) < 3.0
                and (not NetworkGetEntityIsNetworked(obj) or NetworkGetEntityOwner(obj) == myId)
            if attached or nearMine then
                if attached then DetachEntity(obj, true, true) end
                SetEntityAsMissionEntity(obj, true, true)
                DeleteObject(obj)
                if DoesEntityExist(obj) then DeleteEntity(obj) end
            end
        end
    end
end

local function playScenario(scenario, duration, label)
    local ped = PlayerPedId()
    local before = snapshotObjects()
    TaskStartScenarioInPlaceHash(ped, joaat(scenario), -1, true, false, false, false)
    local ok = lib.progressBar({
        duration = duration, label = label, useWhileDead = false, canCancel = true,
        disable = { move = true, combat = true, car = true, mount = true },
    })
    ClearPedTasks(ped, true, true)
    Wait(1500)
    ClearPedTasksImmediately(ped)
    cleanupScenarioProps(ped, before)
    Wait(500)
    cleanupScenarioProps(ped, before)
    return ok
end

local function spawnProp(model, x, y, z, heading)
    local hash = loadModel(model)
    if not hash then return nil end
    local obj = CreateObject(hash, x, y, z, false, false, false)
    SetEntityHeading(obj, heading or 0.0)
    FreezeEntityPosition(obj, true)
    SetModelAsNoLongerNeeded(hash)
    ownProps[obj] = true
    return obj
end

local function deleteProp(obj)
    if not obj then return end
    ownProps[obj] = nil
    if DoesEntityExist(obj) then DeleteObject(obj) end
end

---------------------------------
-- placement gizmo
---------------------------------
local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end

local function camRaycast(dist, ignore)
    local camPos = GetGameplayCamCoord()
    local dest = camPos + rotToDir(GetGameplayCamRot(2)) * dist
    local handle = StartShapeTestRay(camPos.x, camPos.y, camPos.z, dest.x, dest.y, dest.z, 1, ignore, 0)
    local status, hit, endCoords = 1, false, vector3(0, 0, 0)
    repeat
        status, hit, endCoords = GetShapeTestResult(handle)
        if status == 1 then Wait(0) end
    until status ~= 1
    return hit == 1 or hit == true, endCoords
end

local function drawAxis(origin, heading)
    local r = math.rad(heading)
    local fwd   = vector3(-math.sin(r), math.cos(r), 0.0)
    local right = vector3(math.cos(r), math.sin(r), 0.0)
    local len = 0.8
    local o = origin + vector3(0, 0, 0.05)
    DrawLine(o.x, o.y, o.z, o.x + right.x * len, o.y + right.y * len, o.z, 230, 70, 70, 255)
    DrawLine(o.x, o.y, o.z, o.x + fwd.x * len,   o.y + fwd.y * len,   o.z, 90, 210, 90, 255)
    DrawLine(o.x, o.y, o.z, o.x, o.y, o.z + len, 80, 140, 240, 255)
end

local function drawRing(origin, radius, valid)
    local cr, cg, cb = 111, 191, 115
    if not valid then cr, cg, cb = 224, 85, 79 end
    local seg = 24
    for i = 0, seg - 1 do
        local a1, a2 = (i / seg) * math.pi * 2, ((i + 1) / seg) * math.pi * 2
        DrawLine(origin.x + math.cos(a1) * radius, origin.y + math.sin(a1) * radius, origin.z + 0.03,
                 origin.x + math.cos(a2) * radius, origin.y + math.sin(a2) * radius, origin.z + 0.03, cr, cg, cb, 220)
    end
end

local function startPlacement(model, checkFn)
    local hash = loadModel(model)
    if not hash then return nil end

    local ped = PlayerPedId()
    local start = GetEntityCoords(ped)
    local ghost = CreateObject(hash, start.x, start.y, start.z - 5.0, false, false, false)
    SetEntityAlpha(ghost, 170, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(hash)

    local heading, heightOffset = GetEntityHeading(ped), 0.0
    local result, resultHeading = nil, nil
    lib.showTextUI(locale('cl_wellpump_place_help'), { position = 'left-center' })

    while true do
        Wait(0)
        for _, c in pairs(CONTROLS) do DisableControlAction(0, c, true) end
        DisableControlAction(0, 0xB2F377E8, true) -- melee attack
        DisableControlAction(0, 0x8FFC75D6, true) -- sprint

        local hit, coords = camRaycast(WP.placeMaxDistance + 6.0, ghost)
        local pedPos = GetEntityCoords(ped)
        local valid, reason = false, nil

        if hit then
            local pos = coords + vector3(0, 0, heightOffset)
            SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
            SetEntityHeading(ghost, heading)

            if #(pedPos - coords) > WP.placeMaxDistance then
                reason = locale('cl_wellpump_too_far')
            else
                valid, reason = true, nil
                if checkFn then valid, reason = checkFn(pos) end
            end

            drawAxis(pos, heading)
            drawRing(pos, 0.45, valid)
        end

        local dt = GetFrameTime()
        if IsDisabledControlPressed(0, CONTROLS.rotL) then heading = (heading + 90.0 * dt) % 360 end
        if IsDisabledControlPressed(0, CONTROLS.rotR) then heading = (heading - 90.0 * dt) % 360 end
        if IsDisabledControlPressed(0, CONTROLS.up)   then heightOffset = math.min(heightOffset + 0.3 * dt, 0.5) end
        if IsDisabledControlPressed(0, CONTROLS.down) then heightOffset = math.max(heightOffset - 0.3 * dt, -0.5) end

        if IsDisabledControlJustPressed(0, CONTROLS.place) then
            if hit and valid then
                result, resultHeading = GetEntityCoords(ghost), heading
                break
            else
                notify(reason or locale('sv_wellpump_place_invalid'), 'error')
            end
        end

        if IsDisabledControlJustPressed(0, CONTROLS.cancel) or IsDisabledControlJustPressed(0, CONTROLS.cancel2)
            or IsEntityDead(ped) then
            break
        end
    end

    lib.hideTextUI()
    if DoesEntityExist(ghost) then DeleteObject(ghost) end
    return result, resultHeading
end

---------------------------------
-- actions ('fill' | 'pack')
---------------------------------
local function pumpAction(action, id, cb, scenario, duration, label)
    local p = Pumps[id]
    if not p or not canAct() then return end
    busy = true
    local can, reason = lib.callback.await('rsg-ranch:server:pumpPrecheck', false, action, id)
    if not can then
        notify(reason, 'error')
        busy = false
        return
    end
    face(p.x, p.y)
    if playScenario(scenario, duration, label) then
        local ok, msg = lib.callback.await(cb, false, id)
        notify(msg, ok and 'success' or 'error')
    else
        notify(locale('cl_wellpump_cancelled'), 'error')
    end
    busy = false
end

---------------------------------
-- spawning
---------------------------------
local function despawn(id)
    local ent = Spawned[id]
    if ent then
        exports.ox_target:removeLocalEntity(ent)
        deleteProp(ent)
    end
    Spawned[id] = nil
end

local function spawn(p)
    local ent = spawnProp(WP.prop, p.x, p.y, p.z, p.h + 0.0)
    if not ent then return end
    Spawned[p.id] = ent

    exports.ox_target:addLocalEntity(ent, {
        {
            name = ('rsg_ranch_wellpump_fill_%s'):format(p.id),
            label = locale('cl_wellpump_fill_target'),
            icon = 'fa-solid fa-bucket',
            distance = WP.interactDist,
            canInteract = function() return not busy end,
            onSelect = function()
                pumpAction('fill', p.id, 'rsg-ranch:server:fillBucket', WP.fillScenario, WP.fillTime, locale('cl_wellpump_filling'))
            end,
        },
        {
            name = ('rsg_ranch_wellpump_pack_%s'):format(p.id),
            label = locale('cl_wellpump_pack_target'),
            icon = 'fa-solid fa-box',
            distance = WP.interactDist,
            canInteract = function()
                return not busy and (not WP.ownerOnlyPackup or (Pumps[p.id] and Pumps[p.id].citizenid == getCid()))
            end,
            onSelect = function()
                pumpAction('pack', p.id, 'rsg-ranch:server:packPump', WP.packScenario, WP.packTime, locale('cl_wellpump_packing'))
            end,
        },
    })
end

local function applySync(list)
    local fresh = {}
    for _, p in ipairs(list or {}) do fresh[p.id] = p end
    for id in pairs(Spawned) do
        if not fresh[id] then despawn(id) end
    end
    Pumps = fresh
end

RegisterNetEvent('rsg-ranch:client:syncPumps', applySync)

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    applySync(lib.callback.await('rsg-ranch:server:getPumps', false))
end)

CreateThread(function()
    Wait(1000)
    applySync(lib.callback.await('rsg-ranch:server:getPumps', false))
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(Spawned) do despawn(id) end
end)

-- distance streaming
CreateThread(function()
    while true do
        local pc = GetEntityCoords(PlayerPedId())
        for id, p in pairs(Pumps) do
            local near = #(pc - vector3(p.x, p.y, p.z)) < WP.renderDistance
            if near and not Spawned[id] then spawn(p)
            elseif not near and Spawned[id] then despawn(id) end
        end
        Wait(1000)
    end
end)

---------------------------------
-- placement
---------------------------------
RegisterNetEvent('rsg-ranch:client:placePump', function()
    if not canAct() then return end
    busy = true
    local coords, heading = startPlacement(WP.prop, function(pos)
        for _, p in pairs(Pumps) do
            if #(vector3(p.x, p.y, p.z) - pos) < WP.minDistance then
                return false, locale('sv_wellpump_too_close')
            end
        end
        return true
    end)
    if coords then
        face(coords.x, coords.y)
        if playScenario(WP.packScenario, WP.packTime, locale('cl_wellpump_placing')) then
            local ok, msg = lib.callback.await('rsg-ranch:server:placePump', false, coords, heading)
            notify(msg, ok and 'success' or 'error')
        else
            notify(locale('cl_wellpump_cancelled'), 'error')
        end
    end
    busy = false
end)
