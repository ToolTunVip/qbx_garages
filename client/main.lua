local config = require 'config.client'
if not config.enableClient then return end
local VEHICLES = exports.qbx_core:GetVehiclesByName()

local previewConfig = config.preview or {}
local CAMERA_FOV = previewConfig.fov or 40.0
local AUTO_ROTATE_SPEED = previewConfig.autoRotateSpeed or 12.0 -- độ / giây
local AUTO_ROTATE_DELAY = previewConfig.autoRotateDelay or 2500 -- ms không thao tác thì tự xoay
local DRAG_SENSITIVITY = previewConfig.dragSensitivity or 0.35

local VehicleCategory = {
	all = {
		[0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
		[6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true,
		[12] = true, [13] = true, [14] = true, [15] = true, [16] = true, [17] = true,
		[18] = true, [19] = true, [20] = true, [21] = true, [22] = true,
	},
	car = {
		[0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
		[6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true,
		[12] = true, [13] = true, [17] = true, [18] = true, [19] = true, [20] = true,
		[22] = true,
	},
	air = { [15] = true, [16] = true },
	sea = { [14] = true },
}

---@param category VehicleType
---@param vehicle number
---@return boolean
local function isOfType(category, vehicle)
	local classes = VehicleCategory[category]
	return classes ~= nil and classes[GetVehicleClass(vehicle)] == true
end

---@param vehicle number
local function kickOutPeds(vehicle)
    for i = -1, 5, 1 do
        local seat = GetPedInVehicleSeat(vehicle, i)
        if seat then
            TaskLeaveVehicle(seat, vehicle, 0)
        end
    end
end

local spawnLock = false

---@param vehicleId number
---@param garageName string
---@param accessPoint integer
local function takeOutOfGarage(vehicleId, garageName, accessPoint)
    if spawnLock then
        exports.qbx_core:Notify(locale('error.spawn_in_progress'), 'error')
        return
    end
    spawnLock = true

    local success, result = pcall(function()
        if cache.vehicle then
            exports.qbx_core:Notify(locale('error.in_vehicle'), 'error')
            return
        end

        local netId = lib.callback.await('qbx_garages:server:spawnVehicle', false, vehicleId, garageName, accessPoint)
        if not netId then return end

        local veh = lib.waitFor(function()
            if NetworkDoesEntityExistWithNetworkId(netId) then
                return NetToVeh(netId)
            end
        end)

        if veh == 0 then
            exports.qbx_core:Notify(locale('error.spawn_failed'), 'error')
            return
        end

        if config.engineOn then
            SetVehicleEngineOn(veh, true, true, false)
        end
    end)
    spawnLock = false
    assert(success, result)
end

-- ============================================================================
--  PREVIEW (NUI + camera xoay quanh xe, chạy trong routing bucket riêng)
-- ============================================================================

local preview = {
    active = false,   -- đang trong chế độ xem (đã vào bucket riêng)
    opening = false,  -- đang trong quá trình mở
    token = 0,        -- chống race khi bấm đổi xe liên tục
    session = nil,
    vehicle = nil,    -- xe LOCAL dùng để xem (không network)
    cam = nil,
    radar = true,
    coords = vec3(0.0, 0.0, 0.0),
    heading = 0.0,
    lastInput = 0,
}

-- tăng lên mỗi lần đóng preview để các zone vẽ lại TextUI / radial
local interactionVersion = 0

local function isPreviewBusy()
    return preview.active or preview.opening
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function toPercent(value, default)
    value = tonumber(value) or default
    return clamp(math.floor(value + 0.5), 0, 100)
end

---@param vehicle PlayerVehicle
---@return string
local function getVehicleLabel(vehicle)
    local info = VEHICLES[vehicle.modelName]
    if not info then return vehicle.modelName:upper() end
    return ((info.brand and (info.brand .. ' ') or '') .. (info.name or vehicle.modelName))
end

---@param vehicle PlayerVehicle
---@param garageInfo GarageConfig
---@return boolean canTakeOut, string? message
local function getTakeOutState(vehicle, garageInfo)
    if vehicle.state == VehicleState.GARAGED then
        return true
    elseif vehicle.state == VehicleState.OUT then
        if garageInfo.type == GarageType.DEPOT then return true end
        return false, locale('menu.already_out')
    elseif vehicle.state == VehicleState.IMPOUNDED then
        return false, locale('menu.veh_impounded')
    end
    return false
end

local function getUiStrings()
    return {
        inspection = locale('ui.inspection'),
        selectVehicle = locale('ui.select_vehicle'),
        placeholder = locale('ui.placeholder'),
        body = locale('ui.body'),
        engine = locale('ui.engine'),
        fuel = locale('ui.fuel'),
        takeOut = locale('ui.take_out'),
        payDepot = locale('ui.pay_depot'),
        vehiclesFound = locale('ui.vehicles_found'),
        noVehicles = locale('ui.no_vehicles'),
        statusGaraged = locale('ui.status_garaged'),
        statusOut = locale('ui.status_out'),
        statusImpounded = locale('ui.status_impounded'),
        description = locale('menu.description'),
        keyNavigate = locale('ui.key_navigate'),
        hintNavigate = locale('ui.hint_navigate'),
        keySelect = locale('ui.key_select'),
        hintSelect = locale('ui.hint_select'),
        keyDrag = locale('ui.key_drag'),
        hintDrag = locale('ui.hint_drag'),
        keyZoom = locale('ui.key_zoom'),
        hintZoom = locale('ui.hint_zoom'),
        keyClose = locale('ui.key_close'),
        hintClose = locale('ui.hint_close'),
    }
end

-- ---------------------------------------------------------------- camera ----

local function updateCamera(dt)
    local c = preview.cam
    if not c then return end

    local k = math.min(1.0, dt * 8.0)
    c.theta = c.theta + (c.targetTheta - c.theta) * k
    c.phi = c.phi + (c.targetPhi - c.phi) * k
    c.dist = c.dist + (c.targetDist - c.dist) * k

    local rt, rp = math.rad(c.theta), math.rad(c.phi)
    local dir = vec3(math.cos(rp) * math.cos(rt), math.cos(rp) * math.sin(rt), math.sin(rp))
    local from = c.center
    local to = from + dir * c.dist

    -- không cho camera xuyên tường / mặt đất
    local wanted = c.dist
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1, 0, 4)
    local _, hit, endCoords = GetShapeTestResult(ray)
    if hit == 1 or hit == true then
        wanted = math.max(1.5, #(endCoords - from) - 0.3)
    end
    c.clipDist = c.clipDist + (wanted - c.clipDist) * math.min(1.0, dt * 10.0)

    local pos = from + dir * c.clipDist
    SetCamCoord(c.handle, pos.x, pos.y, pos.z)
    PointCamAtCoord(c.handle, from.x, from.y, from.z)
end

local function createPreviewCamera(coords, heading)
    local startTheta = heading + 90.0 + 35.0 -- góc 3/4 phía trước xe
    local handle = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(handle, CAMERA_FOV)

    preview.cam = {
        handle = handle,
        center = coords + vec3(0.0, 0.0, 0.8),
        theta = startTheta, targetTheta = startTheta,
        phi = 12.0, targetPhi = 12.0,
        dist = 7.0, targetDist = 7.0, clipDist = 7.0,
        minDist = 3.5, maxDist = 14.0,
    }
    updateCamera(1.0)
    SetCamActive(handle, true)
    RenderScriptCams(true, false, 0, true, true)
end

local function destroyPreviewCamera()
    if not preview.cam then return end
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(preview.cam.handle, false)
    preview.cam = nil
end

-- ------------------------------------------------------- preview vehicle ----

local function clearPreviewVehicle()
    if preview.vehicle and DoesEntityExist(preview.vehicle) then
        DeleteEntity(preview.vehicle)
    end
    preview.vehicle = nil
end

---@param vehicle PlayerVehicle
local function showPreviewVehicle(vehicle)
    preview.token = preview.token + 1
    local token = preview.token
    clearPreviewVehicle()

    local props = vehicle.props
    local model = type(props) == 'table' and props.model
    if type(model) ~= 'number' or not IsModelInCdimage(model) or not IsModelAVehicle(model) then return end

    if not pcall(lib.requestModel, model, 5000) then return end
    if token ~= preview.token or not preview.active then
        SetModelAsNoLongerNeeded(model)
        return
    end

    local coords = preview.coords
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    -- isNetwork = false -> xe chỉ tồn tại ở client này
    local veh = CreateVehicle(model, coords.x, coords.y, coords.z, preview.heading, false, false)
    SetModelAsNoLongerNeeded(model)
    if not veh or veh == 0 then return end

    local timeout = GetGameTimer() + 1500
    while not HasCollisionLoadedAroundEntity(veh) and GetGameTimer() < timeout do
        Wait(0)
    end

    if token ~= preview.token or not preview.active then
        DeleteEntity(veh)
        return
    end

    preview.vehicle = veh
    SetVehicleOnGroundProperly(veh)
    lib.setVehicleProperties(veh, props)
    SetVehicleEngineOn(veh, false, true, true)
    SetVehicleDoorsLocked(veh, 2)
    SetEntityInvincible(veh, true)
    FreezeEntityPosition(veh, true)

    -- căn camera theo kích thước xe
    local min, max = GetModelDimensions(model)
    local length = math.max(max.x - min.x, max.y - min.y)
    local mid = (min + max) * 0.5
    local c = preview.cam
    if c then
        c.center = GetOffsetFromEntityInWorldCoords(veh, mid.x, mid.y, mid.z)
        c.minDist = length * 0.8
        c.maxDist = length * 3.0
        c.targetDist = length * 1.5
    end
end

-- ---------------------------------------------------------------- session ----

local function restorePlayer()
    local ped = cache.ped
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    DisplayRadar(preview.radar)
end

local function startPreviewThread()
    CreateThread(function()
        while preview.active do
            local dt = GetFrameTime()
            local c = preview.cam
            if c and GetGameTimer() - preview.lastInput > AUTO_ROTATE_DELAY then
                c.targetTheta = c.targetTheta + AUTO_ROTATE_SPEED * dt
            end
            updateCamera(dt)
            DisableControlAction(0, 200, true) -- chặn pause menu

            if IsEntityDead(cache.ped) then
                CreateThread(function() closePreview() end)
                break
            end
            Wait(0)
        end
    end)
end

function closePreview()
    if not preview.active then return end
    preview.active = false
    preview.token = preview.token + 1

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeGarage' })

    DoScreenFadeOut(200)
    Wait(250)
    clearPreviewVehicle()
    destroyPreviewCamera()
    restorePlayer()
    lib.callback.await('qbx_garages:server:exitPreview', false) -- trả về bucket cũ
    preview.session = nil
    interactionVersion = interactionVersion + 1
    DoScreenFadeIn(300)
end

local function forceCleanupPreview()
    if not preview.active and not preview.cam and not preview.vehicle then return end
    preview.active = false
    preview.opening = false
    SetNuiFocus(false, false)
    clearPreviewVehicle()
    destroyPreviewCamera()
    restorePlayer()
    DoScreenFadeIn(0)
end

---@param garageName string
---@param garageInfo GarageConfig
---@param accessPointIndex integer
local function startPreview(garageName, garageInfo, accessPointIndex)
    ---@type PlayerVehicle[]?
    local vehicles = lib.callback.await('qbx_garages:server:getGarageVehicles', false, garageName)
    if not vehicles or #vehicles == 0 then
        exports.qbx_core:Notify(locale('error.no_vehicles'), 'error')
        return
    end

    table.sort(vehicles, function(a, b) return a.modelName < b.modelName end)

    local accessPoint = garageInfo.accessPoints[accessPointIndex]
    if not accessPoint then return end

    if not lib.callback.await('qbx_garages:server:enterPreview', false, garageName, accessPointIndex) then
        exports.qbx_core:Notify(locale('error.no_access'), 'error')
        return
    end

    -- Từ đây trở đi player đã ở bucket riêng: mọi lỗi đều phải đi qua closePreview
    preview.active = true
    lib.hideTextUI()

    DoScreenFadeOut(200)
    Wait(250)

    local session = { garageName = garageName, garageInfo = garageInfo, accessPointIndex = accessPointIndex, vehicles = {}, canTakeOut = {} }
    local nuiVehicles = {}
    for i = 1, #vehicles do
        local v = vehicles[i]
        local canTakeOut, message = getTakeOutState(v, garageInfo)
        session.vehicles[v.id] = v
        session.canTakeOut[v.id] = canTakeOut
        nuiVehicles[i] = {
            id = v.id,
            modelName = v.modelName,
            label = getVehicleLabel(v),
            plate = v.props.plate,
            state = v.state,
            depotPrice = v.depotPrice or 0,
            body = toPercent((v.props.bodyHealth or 1000) / 10, 100),
            engine = toPercent((v.props.engineHealth or 1000) / 10, 100),
            fuel = toPercent(v.props.fuelLevel, 100),
            canTakeOut = canTakeOut,
            message = message,
        }
    end
    preview.session = session

    preview.radar = IsRadarEnabled()
    DisplayRadar(false)
    FreezeEntityPosition(cache.ped, true)
    SetEntityVisible(cache.ped, false, false)

    -- vị trí đặt xe xem: previewCoords (nếu cấu hình) > spawn > coords
    local c = accessPoint.previewCoords or accessPoint.spawn or accessPoint.coords
    preview.coords = vec3(c.x, c.y, c.z)
    preview.heading = type(c) == 'vector4' and c.w or GetEntityHeading(cache.ped)
    preview.lastInput = GetGameTimer()

    createPreviewCamera(preview.coords, preview.heading)

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openGarage',
        garageName = garageName,
        garageLabel = garageInfo.label,
        garageType = garageInfo.type,
        vehicles = nuiVehicles,
        strings = getUiStrings(),
    })

    startPreviewThread()
    Wait(100)
    DoScreenFadeIn(300)
end

---@param garageName string
---@param garageInfo GarageConfig
---@param accessPointIndex integer
local function openGarageMenu(garageName, garageInfo, accessPointIndex)
    if isPreviewBusy() then return end
    if cache.vehicle then
        exports.qbx_core:Notify(locale('error.in_vehicle'), 'error')
        return
    end

    preview.opening = true
    local ok, err = pcall(startPreview, garageName, garageInfo, accessPointIndex)
    preview.opening = false

    if not ok then
        lib.print.error(err)
        if preview.active then
            closePreview()
        else
            DoScreenFadeIn(300)
        end
    end
end

-- ---------------------------------------------------------- NUI callbacks ----

RegisterNUICallback('previewVehicle', function(data, cb)
    cb(1)
    if not preview.active or not preview.session then return end
    local vehicle = preview.session.vehicles[tonumber(data and data.id)]
    if vehicle then showPreviewVehicle(vehicle) end
end)

RegisterNUICallback('cameraMove', function(data, cb)
    cb(1)
    local c = preview.cam
    if not preview.active or not c then return end
    local dx, dy = tonumber(data.dx) or 0.0, tonumber(data.dy) or 0.0
    c.targetTheta = c.targetTheta - dx * DRAG_SENSITIVITY
    c.targetPhi = clamp(c.targetPhi + dy * DRAG_SENSITIVITY * 0.7, -5.0, 70.0)
    preview.lastInput = GetGameTimer()
end)

RegisterNUICallback('cameraZoom', function(data, cb)
    cb(1)
    local c = preview.cam
    if not preview.active or not c then return end
    local delta = clamp(tonumber(data.delta) or 0.0, -1.0, 1.0)
    c.targetDist = clamp(c.targetDist + delta * 0.6, c.minDist, c.maxDist)
    preview.lastInput = GetGameTimer()
end)

RegisterNUICallback('closeGarage', function(_, cb)
    cb(1)
    closePreview()
end)

RegisterNUICallback('takeOutVehicle', function(data, cb)
    cb(1)
    if not preview.active or not preview.session then return end

    local session = preview.session
    local vehicleId = tonumber(data and data.vehicleId)
    local vehicle = vehicleId and session.vehicles[vehicleId]
    if not vehicle or not session.canTakeOut[vehicleId] then return end

    closePreview() -- phải về bucket cũ TRƯỚC khi server spawn xe
    takeOutOfGarage(vehicle.id, session.garageName, session.accessPointIndex)
end)

-- ============================================================================

---@param vehicle number
---@param garageName string
local function parkVehicle(vehicle, garageName)
    if GetVehicleNumberOfPassengers(vehicle) ~= 1 then
        local isParkable = lib.callback.await('qbx_garages:server:isParkable', false, garageName, NetworkGetNetworkIdFromEntity(vehicle))

        if not isParkable then
            exports.qbx_core:Notify(locale('error.not_owned'), 'error', 5000)
            return
        end

        kickOutPeds(vehicle)
        SetVehicleDoorsLocked(vehicle, 2)
        Wait(1500)
        local parked = lib.callback.await('qbx_garages:server:parkVehicle', false, NetworkGetNetworkIdFromEntity(vehicle), lib.getVehicleProperties(vehicle), garageName)
        if parked then
            exports.qbx_core:Notify(locale('success.vehicle_parked'), 'primary', 4500)
        end
    else
        exports.qbx_core:Notify(locale('error.vehicle_occupied'), 'error', 3500)
    end
end

---@param garage GarageConfig
---@return boolean
local function checkCanAccess(garage)
    if garage.groups and not exports.qbx_core:HasPrimaryGroup(garage.groups, QBX.PlayerData) then
        exports.qbx_core:Notify(locale('error.no_access'), 'error')
        return false
    end
    if cache.vehicle and not isOfType(garage.vehicleType, cache.vehicle) then
        exports.qbx_core:Notify(locale('error.not_correct_type'), 'error')
        return false
    end
    return true
end

local activeRadialItems = {}

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for id in pairs(activeRadialItems) do lib.removeRadialItem(id) end
    forceCleanupPreview()
end)

---@param garageName string
---@param garage GarageConfig
---@param accessPoint AccessPoint
---@param accessPointIndex integer
local function createZones(garageName, garage, accessPoint, accessPointIndex)
    CreateThread(function()
        accessPoint.dropPoint = accessPoint.dropPoint or accessPoint.spawn
        local drawRadius = accessPoint.drawRadius or 60
        local dropDrawRadius = accessPoint.dropDrawRadius or 60
        local useRadius = accessPoint.useRadius or 1
        local dropUseRadius = accessPoint.dropUseRadius or 1.5
        local dropZone, coordsZone
        local useRadial = config.interact == 'radialmenu'

        local function createInteractionZone(coords, radius, isDrop)
            local id = ('qbx_garages:%s:%s:%s'):format(garageName, accessPointIndex, isDrop and 'drop' or 'menu')
            local shownAction
            local seenVersion = interactionVersion

            local function getAction()
                if useRadial and not LocalPlayer.state.isLoggedIn then return end
                if isDrop then return cache.vehicle and 'park' or nil end
                if accessPoint.dropPoint and cache.vehicle then return end
                return garage.type == GarageType.DEPOT and 'impound' or cache.vehicle and 'park' or 'car'
            end

            local function selectAction()
                if isPreviewBusy() then return end
                if #(GetEntityCoords(cache.ped) - vec3(coords.x, coords.y, coords.z)) > radius then return end
                local action = getAction()
                if not action or not checkCanAccess(garage) then return end
                if action == 'park' then
                    parkVehicle(cache.vehicle, garageName)
                else
                    openGarageMenu(garageName, garage, accessPointIndex)
                end
            end

            local function clearInteraction()
                if useRadial then
                    lib.removeRadialItem(id)
                    activeRadialItems[id] = nil
                elseif shownAction then
                    lib.hideTextUI()
                end
                shownAction = nil
            end

            local function updateInteraction()
                if isPreviewBusy() then return end
                local action = getAction()
                if action == shownAction and seenVersion == interactionVersion then return end
                seenVersion = interactionVersion
                clearInteraction()
                shownAction = action
                if not action then return end
                if useRadial then
                    activeRadialItems[id] = true
                    lib.addRadialItem({
                        id = id,
                        label = locale('info.' .. action .. '_radial'),
                        icon = action == 'park' and 'square-parking' or 'warehouse',
                        onSelect = selectAction,
                    })
                else
                    lib.showTextUI(locale('info.' .. action .. '_e'))
                end
            end

            return lib.zones.sphere({
                coords = coords,
                radius = radius,
                onEnter = updateInteraction,
                onExit = clearInteraction,
                inside = function()
                    updateInteraction()
                    if not useRadial and IsControlJustReleased(0, 38) then selectAction() end
                end,
                debug = config.debugPoly,
            })
        end

        local function createDropZone()
            if dropZone then return end
            dropZone = createInteractionZone(accessPoint.dropPoint, dropUseRadius, true)
        end

        local function createCoordsZone()
            if coordsZone then return end
            coordsZone = createInteractionZone(accessPoint.coords, useRadius, false)
        end
        lib.zones.sphere({
            coords = accessPoint.coords,
            radius = drawRadius,
            onEnter = function()
                createCoordsZone()
            end,
            onExit = function()
                if coordsZone then
                    coordsZone.onExit()
                    coordsZone:remove()
                    coordsZone = nil
                end
            end,
            inside = function()
                config.drawGarageMarker(accessPoint.coords.xyz, useRadius)
            end,
            debug = config.debugPoly,
        })

        if accessPoint.dropPoint and garage.type ~= GarageType.DEPOT then
            lib.zones.sphere({
                coords = accessPoint.dropPoint,
                radius = dropDrawRadius,
                onEnter = function()
                    createDropZone()
                end,
                onExit = function()
                    if dropZone then
                        dropZone.onExit()
                        dropZone:remove()
                        dropZone = nil
                    end
                end,
                inside = function()
                    config.drawDropOffMarker(accessPoint.dropPoint, dropUseRadius)
                end,
                debug = config.debugPoly,
            })
        end
    end)
end

---@param garageInfo GarageConfig
---@param accessPoint AccessPoint
local function createBlips(garageInfo, accessPoint)
    local blip = AddBlipForCoord(accessPoint.coords.x, accessPoint.coords.y, accessPoint.coords.z)
    SetBlipSprite(blip, accessPoint.blip.sprite or 357)
    SetBlipDisplay(blip, 4)
    SetBlipScale(blip, 0.60)
    SetBlipAsShortRange(blip, true)
    SetBlipColour(blip, accessPoint.blip.color or 3)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(accessPoint.blip.name or garageInfo.label)
    EndTextCommandSetBlipName(blip)
end

local function createGarage(name, garage)
    local accessPoints = garage.accessPoints
    for i = 1, #accessPoints do
        local accessPoint = accessPoints[i]

        if accessPoint.blip then
            createBlips(garage, accessPoint)
        end

        createZones(name, garage, accessPoint, i)
    end
end

local function createGarages()
    local garages = lib.callback.await('qbx_garages:server:getGarages')
    for name, garage in pairs(garages) do
        createGarage(name, garage)
    end
end

RegisterNetEvent('qbx_garages:client:garageRegistered', function(name, garage)
    createGarage(name, garage)
end)

CreateThread(function()
    createGarages()
end)
