lib.locale()

---------------------------------------------
-- Shared prop placement system
---------------------------------------------
-- Every placeable ranch prop (feed troughs, water troughs, chicken coops, etc) used
-- to duplicate its own "offset in front of the player + text UI" placement loop.
-- This module centralises a single, nicer placement flow instead: the prop follows
-- a camera raycast (so you aim it like a scope rather than shuffling your character
-- around), rotates with the arrow keys, draws an axis gizmo for orientation, and
-- uses native RedM hold-prompts (with proper on-screen prompt UI) to confirm/cancel
-- instead of a floating text box.
--
-- Usage (from any other client module in this resource):
--   StartPropPlacement(Config.SomeModel, {
--       maxDistance = 5.0,                         -- how far from the player the prop may be placed
--       onConfirm = function(coords, heading) ... end,
--       onCancel = function() ... end,              -- optional
--   })
---------------------------------------------

local placementActive = false
local CancelPrompt, SetPrompt, RotateLeftPrompt, RotateRightPrompt
local PropPlacerGroup = GetRandomIntInRange(0, 0xffffff)

CreateThread(function()
    CancelPrompt = PromptRegisterBegin()
    PromptSetControlAction(CancelPrompt, 0xF84FA74F) -- INPUT_FRONTEND_DELETE (Backspace)
    PromptSetText(CancelPrompt, CreateVarString(10, 'LITERAL_STRING', locale('cl_prop_cancel')))
    PromptSetEnabled(CancelPrompt, true)
    PromptSetVisible(CancelPrompt, true)
    PromptSetHoldMode(CancelPrompt, true)
    PromptSetGroup(CancelPrompt, PropPlacerGroup)
    PromptRegisterEnd(CancelPrompt)

    SetPrompt = PromptRegisterBegin()
    PromptSetControlAction(SetPrompt, 0xC7B5340A) -- INPUT_FRONTEND_ACCEPT (E)
    PromptSetText(SetPrompt, CreateVarString(10, 'LITERAL_STRING', locale('cl_prop_confirm')))
    PromptSetEnabled(SetPrompt, true)
    PromptSetVisible(SetPrompt, true)
    PromptSetHoldMode(SetPrompt, true)
    PromptSetGroup(SetPrompt, PropPlacerGroup)
    PromptRegisterEnd(SetPrompt)

    RotateLeftPrompt = PromptRegisterBegin()
    PromptSetControlAction(RotateLeftPrompt, 0xA65EBAB4) -- Left Arrow
    PromptSetText(RotateLeftPrompt, CreateVarString(10, 'LITERAL_STRING', locale('cl_prop_rotleft')))
    PromptSetEnabled(RotateLeftPrompt, true)
    PromptSetVisible(RotateLeftPrompt, true)
    PromptSetStandardMode(RotateLeftPrompt, true)
    PromptSetGroup(RotateLeftPrompt, PropPlacerGroup)
    PromptRegisterEnd(RotateLeftPrompt)

    RotateRightPrompt = PromptRegisterBegin()
    PromptSetControlAction(RotateRightPrompt, 0xDEB34313) -- Right Arrow
    PromptSetText(RotateRightPrompt, CreateVarString(10, 'LITERAL_STRING', locale('cl_prop_rotright')))
    PromptSetEnabled(RotateRightPrompt, true)
    PromptSetVisible(RotateRightPrompt, true)
    PromptSetStandardMode(RotateRightPrompt, true)
    PromptSetGroup(RotateRightPrompt, PropPlacerGroup)
    PromptRegisterEnd(RotateRightPrompt)
end)

local function RotationToDirection(rotation)
    local adjustedRotation = {
        x = (math.pi / 180) * rotation.x,
        y = (math.pi / 180) * rotation.y,
        z = (math.pi / 180) * rotation.z
    }
    return {
        x = -math.sin(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)),
        y = math.cos(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)),
        z = math.sin(adjustedRotation.x)
    }
end

local function DrawPropAxes(prop)
    local propForward, propRight, propUp, propCoords = GetEntityMatrix(prop)

    local propXAxisEnd = propCoords + propRight * 0.20
    local propYAxisEnd = propCoords + propForward * 0.20
    local propZAxisEnd = propCoords + propUp * 0.20

    DrawLine(propCoords.x, propCoords.y, propCoords.z + 0.1, propXAxisEnd.x, propXAxisEnd.y, propXAxisEnd.z, 255, 0, 0, 255)
    DrawLine(propCoords.x, propCoords.y, propCoords.z + 0.1, propYAxisEnd.x, propYAxisEnd.y, propYAxisEnd.z, 0, 255, 0, 255)
    DrawLine(propCoords.x, propCoords.y, propCoords.z + 0.1, propZAxisEnd.x, propZAxisEnd.y, propZAxisEnd.z, 0, 0, 255, 255)
end

local function RayCastGamePlayCamera(distance)
    local cameraRotation = GetGameplayCamRot()
    local cameraCoord = GetGameplayCamCoord()
    local direction = RotationToDirection(cameraRotation)
    local destination = {
        x = cameraCoord.x + direction.x * distance,
        y = cameraCoord.y + direction.y * distance,
        z = cameraCoord.z + direction.z * distance
    }
    local _, hit, coords, _, entity = GetShapeTestResult(StartShapeTestRay(cameraCoord.x, cameraCoord.y, cameraCoord.z, destination.x, destination.y, destination.z, -1, PlayerPedId(), 0))
    return hit, coords, entity
end

-- Keeps the placement point tethered to the player - stops someone "placing" a prop
-- across the map just by aiming the camera at distant terrain.
local function ClampToPlayer(coords, maxDistance)
    local playerCoords = GetEntityCoords(cache.ped)
    local flat = vector3(coords.x, coords.y, playerCoords.z)
    local dist = #(flat - playerCoords)
    if dist <= maxDistance or dist <= 0.0 then return coords end

    local dirX = (flat.x - playerCoords.x) / dist
    local dirY = (flat.y - playerCoords.y) / dist
    local clampedX = playerCoords.x + dirX * maxDistance
    local clampedY = playerCoords.y + dirY * maxDistance
    local foundGround, groundZ = GetGroundZFor_3dCoord(clampedX, clampedY, playerCoords.z + 5.0, false)
    return vector3(clampedX, clampedY, foundGround and groundZ or coords.z)
end

---------------------------------------------
-- StartPropPlacement(propmodel, opts)
-- Intentionally global (not local) so every other client module in this resource
-- can call it directly. Returns false immediately if a placement is already active
-- or required options are missing, true once the placement loop has started.
---------------------------------------------
function StartPropPlacement(propmodel, opts)
    if placementActive then return false end
    if not DoesEntityExist(cache.ped) then return false end

    opts = opts or {}
    if type(opts.onConfirm) ~= 'function' then return false end

    local propModel = type(propmodel) == 'string' and joaat(propmodel) or propmodel
    local maxDistance = opts.maxDistance or 5.0

    placementActive = true

    lib.requestModel(propModel, 5000)
    if not HasModelLoaded(propModel) then
        placementActive = false
        lib.notify({ title = locale('cl_propplacer_title_1'), description = locale('cl_propplacer_description_2'), type = 'error' })
        return false
    end

    local heading = 0.0
    local confirmed = false
    local cancelled = false
    local coords

    local attempts = 0
    local hit
    while not hit and attempts < 100 do
        hit, coords = RayCastGamePlayCamera(1000.0)
        attempts = attempts + 1
        Wait(0)
    end

    if not hit then
        placementActive = false
        SetModelAsNoLongerNeeded(propModel)
        lib.notify({ title = locale('cl_propplacer_title_3'), description = locale('cl_propplacer_description_4'), type = 'error' })
        return false
    end

    coords = ClampToPlayer(coords, maxDistance)
    local propObj = CreateObject(propModel, coords.x, coords.y, coords.z, true, false, true)

    CreateThread(function()
        while not confirmed and not cancelled do
            local rayHit, rayCoords = RayCastGamePlayCamera(1000.0)
            if rayHit then
                coords = ClampToPlayer(rayCoords, maxDistance)
            end

            SetEntityCoordsNoOffset(propObj, coords.x, coords.y, coords.z, false, false, false, true)
            FreezeEntityPosition(propObj, true)
            SetEntityCollision(propObj, false, false)
            SetEntityAlpha(propObj, 150, false)
            DrawPropAxes(propObj)

            PromptSetActiveGroupThisFrame(PropPlacerGroup, CreateVarString(10, 'LITERAL_STRING', locale('cl_prop_group')))

            if IsControlPressed(1, 0xA65EBAB4) then -- Left Arrow
                heading = heading + 1.0
            elseif IsControlPressed(1, 0xDEB34313) then -- Right Arrow
                heading = heading - 1.0
            end

            if heading > 360.0 then
                heading = 0.0
            elseif heading < 0.0 then
                heading = 360.0
            end

            SetEntityHeading(propObj, heading)

            if PromptHasHoldModeCompleted(SetPrompt) then
                confirmed = true
            elseif PromptHasHoldModeCompleted(CancelPrompt) then
                cancelled = true
            end

            Wait(0)
        end

        local finalCoords, finalHeading = coords, heading

        if DoesEntityExist(propObj) then
            DeleteObject(propObj)
        end
        SetModelAsNoLongerNeeded(propModel)
        placementActive = false

        if confirmed then
            opts.onConfirm(finalCoords, finalHeading)
        elseif cancelled and opts.onCancel then
            opts.onCancel()
        end
    end)

    return true
end

exports('StartPropPlacement', StartPropPlacement)

-- Lets other modules (e.g. to disable a "Move" ox_target option while a placement
-- of any kind is already in progress) check placer state without their own flag.
function IsPropPlacementActive()
    return placementActive
end

exports('IsPropPlacementActive', IsPropPlacementActive)

---------------------------------------------
-- Cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    placementActive = false
end)
