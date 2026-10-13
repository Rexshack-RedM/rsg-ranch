---------------------------------------------
-- NUI menu layer: drop-in replacement for ox_lib context menus and alert dialogs,
-- rendered in this resource's own NUI so they match the ranch UI.
--   Menu.registerContext(def)  Menu.showContext(id)  Menu.hideContext(onExit)
--   Menu.getOpenContextMenu()  Menu.alertDialog(opts) -> 'confirm' | 'cancel'
---------------------------------------------
lib.locale()

Menu = {}

local contexts = {}
local openId = nil
local alertPromise = nil

local colorMap = { green = 'good', teal = 'good', lime = 'good', yellow = 'warn', orange = 'warn', red = 'bad', blue = 'info', cyan = 'info' }

local function toList(options)
    if not options then return {} end
    if options[1] ~= nil or next(options) == nil then return options end
    -- keyed table form: { ['Title'] = { ... } }
    local list = {}
    for title, opt in pairs(options) do
        opt.title = opt.title or title
        list[#list + 1] = opt
    end
    return list
end

local function serialize(def)
    local out = {}
    for i, o in ipairs(def.options) do
        local meta
        if o.metadata then
            meta = {}
            for k, v in pairs(o.metadata) do
                if type(v) == 'table' then
                    meta[#meta + 1] = { label = tostring(v.label or ''), value = v.value ~= nil and tostring(v.value) or nil, progress = v.progress }
                else
                    meta[#meta + 1] = { label = type(k) == 'number' and tostring(v) or tostring(k), value = type(k) ~= 'number' and tostring(v) or nil }
                end
            end
        end
        local clickable = not o.disabled and not o.readOnly and (o.onSelect or o.event or o.serverEvent or o.menu) ~= nil
        out[i] = {
            index = i,
            title = o.title and tostring(o.title) or '',
            description = o.description and tostring(o.description) or nil,
            disabled = o.disabled == true,
            clickable = clickable,
            header = (o.disabled == true or o.readOnly == true) and not o.description and not o.progress and not o.metadata,
            arrow = o.arrow == true or o.menu ~= nil,
            progress = tonumber(o.progress),
            color = colorMap[o.colorScheme or ''] or nil,
            metadata = meta,
        }
    end
    return out
end

function Menu.registerContext(def)
    if def.id then
        def.options = toList(def.options)
        contexts[def.id] = def
        return
    end
    -- array of contexts
    for _, d in ipairs(def) do Menu.registerContext(d) end
end

function Menu.showContext(id)
    local def = contexts[id]
    if not def then
        print(('^1[rsg-ranch]^7 menu "%s" is not registered'):format(tostring(id)))
        return
    end
    openId = id
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'menu:open',
        menu = { id = id, title = def.title and tostring(def.title) or '', back = def.menu ~= nil, canClose = def.canClose ~= false, options = serialize(def) },
    })
end

local function closeMenu(runExit)
    local def = openId and contexts[openId]
    openId = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'menu:close' })
    if runExit and def and def.onExit then def.onExit() end
end

function Menu.hideContext(onExit)
    if openId then closeMenu(onExit) end
end

function Menu.getOpenContextMenu()
    return openId
end

RegisterNUICallback('menu:select', function(data, cb)
    cb('ok')
    local def = openId and contexts[openId]
    if not def or data.id ~= openId then return end
    local opt = def.options[tonumber(data.index)]
    if not opt or opt.disabled or opt.readOnly then return end

    if opt.menu then
        Menu.showContext(opt.menu)
    else
        closeMenu(false)
    end
    if opt.onSelect then opt.onSelect(opt.args) end
    if opt.event then TriggerEvent(opt.event, opt.args) end
    if opt.serverEvent then TriggerServerEvent(opt.serverEvent, opt.args) end
end)

RegisterNUICallback('menu:back', function(_, cb)
    cb('ok')
    local def = openId and contexts[openId]
    if not def then return end
    if def.onBack then def.onBack() end
    if def.menu then Menu.showContext(def.menu) else closeMenu(true) end
end)

RegisterNUICallback('menu:close', function(_, cb)
    cb('ok')
    if openId then closeMenu(true) end
end)

---------------------------------------------
-- alert dialog (blocking, like Menu.alertDialog)
---------------------------------------------
function Menu.alertDialog(opts)
    if alertPromise then return 'cancel' end
    if openId then closeMenu(false) end
    alertPromise = promise.new()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'alert:open',
        alert = {
            header = opts.header and tostring(opts.header) or '',
            content = opts.content and tostring(opts.content) or '',
            cancel = opts.cancel == true,
            confirmLabel = opts.labels and opts.labels.confirm or locale('ui_confirm'),
            cancelLabel = opts.labels and opts.labels.cancel or locale('ui_cancel'),
        },
    })
    local result = Citizen.Await(alertPromise)
    alertPromise = nil
    return result
end

-- dismiss an open alert from Lua (e.g. a timed-out offer) - resolves as 'cancel'
function Menu.closeAlert()
    if not alertPromise then return end
    SendNUIMessage({ action = 'alert:close' })
    SetNuiFocus(false, false)
    alertPromise:resolve('cancel')
end

RegisterNUICallback('alert:result', function(data, cb)
    cb('ok')
    SetNuiFocus(false, false)
    if alertPromise then alertPromise:resolve(data.result == 'confirm' and 'confirm' or 'cancel') end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if openId or alertPromise then SetNuiFocus(false, false) end
end)
