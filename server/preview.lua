-- Đưa người chơi vào một routing bucket riêng khi xem xe trong gara,
-- để không ai nhìn thấy họ và họ cũng không nhìn thấy người/xe/NPC bên ngoài.

local PREVIEW_BUCKET_BASE = 50000 -- bucket = BASE + source. Đổi nếu server đã dùng dải này.

---@type table<number, integer> [source] = bucket gốc của người chơi
local previewing = {}

---@param player table
---@param garage GarageConfig
---@return boolean
local function canAccessGarage(player, garage)
    if garage.groups and not exports.qbx_core:HasPrimaryGroup(player.PlayerData.source, garage.groups) then
        return false
    end
    if garage.canAccess ~= nil and not garage.canAccess(player.PlayerData.source) then
        return false
    end
    return true
end

---Trả người chơi về bucket gốc. Dùng được từ file server khác.
---@param source number
---@return boolean wasPreviewing
function ExitPreview(source)
    local origin = previewing[source]
    if origin == nil then return false end
    previewing[source] = nil
    SetPlayerRoutingBucket(source, origin)
    return true
end

---@param source number
---@return boolean
function IsInPreview(source)
    return previewing[source] ~= nil
end

lib.callback.register('qbx_garages:server:enterPreview', function(source, garageName, accessPointIndex)
    if previewing[source] then return true end
    if type(garageName) ~= 'string' then return false end
    if type(accessPointIndex) ~= 'number' or accessPointIndex % 1 ~= 0 then return false end

    local player = exports.qbx_core:GetPlayer(source)
    local garage = Garages[garageName]
    if not player or not garage or not canAccessGarage(player, garage) then return false end

    local accessPoint = garage.accessPoints[accessPointIndex]
    if not accessPoint then return false end

    local ped = GetPlayerPed(source)
    if ped <= 0 or GetVehiclePedIsIn(ped, false) ~= 0 then return false end
    if #(GetEntityCoords(ped) - accessPoint.coords.xyz) > 5.0 then return false end

    local bucket = PREVIEW_BUCKET_BASE + source
    previewing[source] = GetPlayerRoutingBucket(source)
    SetRoutingBucketPopulationEnabled(bucket, false) -- không NPC / traffic trong bucket xem xe
    SetPlayerRoutingBucket(source, bucket)
    return true
end)

lib.callback.register('qbx_garages:server:exitPreview', function(source)
    return ExitPreview(source)
end)

AddEventHandler('playerDropped', function()
    previewing[source] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    for src in pairs(previewing) do
        ExitPreview(src)
    end
end)
