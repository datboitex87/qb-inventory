HoldingDrop = false
local bagObject = nil
local heldDrop = nil
local carryRequestPending = false
local releaseRequestPending = false
local lastCarryHeartbeat = 0
local CarryVisuals = {}
local DropTargets = {}
local DropEntityIds = {}
local PendingDropPlacements = {}
local HiddenDropEntities = {}
local CurrentDropBucket = nil
local dropVisualSyncPending = false
local lastDropVisualSync = 0
CurrentDrop = nil

-- Functions

local function requestDropRelease()
    if not HoldingDrop or not heldDrop or releaseRequestPending then return end

    releaseRequestPending = true
    QBCore.Functions.TriggerCallback('qb-inventory:server:releaseDropCarry', function(released)
        if not released then
            releaseRequestPending = false
            QBCore.Functions.Notify('Unable to place this bag.', 'error', 3500)
        end
    end, heldDrop)
end

local function getDropEntity(entityId)
    if not entityId or not NetworkDoesNetworkIdExist(entityId) then return nil end
    local entity = NetworkGetEntityFromNetworkId(entityId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return entity
end

local function removeDropTarget(dropId)
    local target = DropTargets[dropId]
    if not target or not target.active or not target.entity or not DoesEntityExist(target.entity) then
        if target then target.active = false end
        return
    end
    exports['qb-target']:RemoveTargetEntity(target.entity)
    target.active = false
end

local function hideAuthoritativeDrop(dropId, entityId)
    DropEntityIds[dropId] = entityId or DropEntityIds[dropId]
    local entity = getDropEntity(DropEntityIds[dropId])
    if not entity then return end
    SetEntityVisible(entity, false, false)
    SetEntityAlpha(entity, 0, false)
    SetEntityCollision(entity, false, false)
    FreezeEntityPosition(entity, true)
    HiddenDropEntities[dropId] = entityId or DropEntityIds[dropId]
end

local function clearCarryProxyObject(visual)
    if not visual then return end
    if visual.object and DoesEntityExist(visual.object) then
        DetachEntity(visual.object, true, true)
        DeleteEntity(visual.object)
    end
    if bagObject == visual.object then bagObject = nil end
    visual.object = nil
    visual.carrierPed = nil
end

local function deleteCarryProxy(dropId)
    local visual = CarryVisuals[dropId]
    if not visual then return end
    clearCarryProxyObject(visual)
    CarryVisuals[dropId] = nil
end

local function clearLocalCarrierState(dropId)
    if heldDrop ~= dropId then return end
    exports['qb-core']:HideText()
    HoldingDrop = false
    bagObject = nil
    heldDrop = nil
    releaseRequestPending = false
    lastCarryHeartbeat = 0
end

local function ensureCarryProxy(dropId)
    local visual = CarryVisuals[dropId]
    if not visual then return end
    hideAuthoritativeDrop(dropId, visual.entityId)
    removeDropTarget(dropId)

    local player = GetPlayerFromServerId(visual.carrierServerId)
    if player == -1 then
        clearCarryProxyObject(visual)
        return
    end
    local carrierPed = GetPlayerPed(player)
    if not carrierPed or carrierPed == 0 or not DoesEntityExist(carrierPed) then
        clearCarryProxyObject(visual)
        return
    end

    if visual.object and DoesEntityExist(visual.object) and visual.carrierPed == carrierPed and IsEntityAttachedToEntity(visual.object, carrierPed) then
        if heldDrop == dropId then bagObject = visual.object end
        return
    end
    clearCarryProxyObject(visual)

    local model = Config.ItemDropObject
    if not HasModelLoaded(model) then
        RequestModel(model)
        return
    end
    local proxy = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
    if not proxy or proxy == 0 or not DoesEntityExist(proxy) then return end
    SetEntityCollision(proxy, false, false)
    AttachEntityToEntity(
        proxy,
        carrierPed,
        GetPedBoneIndex(carrierPed, Config.ItemDropObjectBone),
        Config.ItemDropObjectOffset[1].x,
        Config.ItemDropObjectOffset[1].y,
        Config.ItemDropObjectOffset[1].z,
        Config.ItemDropObjectOffset[2].x,
        Config.ItemDropObjectOffset[2].y,
        Config.ItemDropObjectOffset[2].z,
        true, true, false, true, 1, true
    )
    visual.object = proxy
    visual.carrierPed = carrierPed
    SetModelAsNoLongerNeeded(model)
    if heldDrop == dropId then bagObject = proxy end
end

local function startCarryVisual(dropId, entityId, carrierServerId)
    if type(dropId) ~= 'string' or not entityId or not carrierServerId then return end
    local existing = CarryVisuals[dropId]
    if existing and existing.entityId == entityId and existing.carrierServerId == carrierServerId then
        ensureCarryProxy(dropId)
        return
    end
    deleteCarryProxy(dropId)
    DropEntityIds[dropId] = entityId
    CarryVisuals[dropId] = {
        object = nil,
        entityId = entityId,
        carrierServerId = carrierServerId,
        carrierPed = nil
    }
    removeDropTarget(dropId)
    hideAuthoritativeDrop(dropId, entityId)
    ensureCarryProxy(dropId)
end

local function registerDropTarget(dropId, entityId)
    if type(dropId) ~= 'string' or not entityId then return end
    DropEntityIds[dropId] = entityId
    if CarryVisuals[dropId] then return end
    local entity = getDropEntity(entityId)
    if not entity then
        DropTargets[dropId] = DropTargets[dropId] or { entityId = entityId, active = false }
        return
    end

    local placement = PendingDropPlacements[dropId]
    if placement then
        SetEntityCoords(entity, placement.x, placement.y, placement.z, false, false, false, false)
        PendingDropPlacements[dropId] = nil
    end
    ResetEntityAlpha(entity)
    SetEntityVisible(entity, true, false)
    SetEntityCollision(entity, true, true)
    FreezeEntityPosition(entity, true)
    HiddenDropEntities[dropId] = nil

    local current = DropTargets[dropId]
    if current and current.active and current.entity == entity then return end
    if current and current.active and current.entity and DoesEntityExist(current.entity) then
        exports['qb-target']:RemoveTargetEntity(current.entity)
    end
    exports['qb-target']:AddTargetEntity(entity, {
        options = {
            {
                icon = 'fa-solid fa-suitcase',
                label = Lang:t('menu.o_bag'),
                action = function()
                    TriggerServerEvent('qb-inventory:server:openDrop', dropId)
                    CurrentDrop = dropId
                end,
            },
            {
                icon = 'fas fa-hand-pointer',
                label = Lang:t('menu.p_bag'),
                action = function()
                    if IsPedArmed(PlayerPedId(), 4) then
                        return QBCore.Functions.Notify(Lang:t('notify.nogunbag'), 'error', 5500)
                    end
                    if HoldingDrop then
                        return QBCore.Functions.Notify(Lang:t('notify.hasbag'), 'error', 5500)
                    end
                    if carryRequestPending then return end
                    carryRequestPending = true
                    QBCore.Functions.TriggerCallback('qb-inventory:server:beginDropCarry', function(authorized)
                        carryRequestPending = false
                        if not authorized then
                            QBCore.Functions.Notify('Unable to carry this bag.', 'error', 3500)
                            return
                        end
                        HoldingDrop = true
                        heldDrop = dropId
                        releaseRequestPending = false
                        startCarryVisual(dropId, entityId, GetPlayerServerId(PlayerId()))
                        lastCarryHeartbeat = GetGameTimer()
                        exports['qb-core']:DrawText('Press your Drop Bag key to place the bag')
                    end, dropId)
                end,
            }
        },
        distance = 2.5,
    })
    DropTargets[dropId] = { entityId = entityId, entity = entity, active = true }
end

function CleanupDropVisualState()
    for _, visual in pairs(CarryVisuals) do
        clearCarryProxyObject(visual)
    end
    for _, target in pairs(DropTargets) do
        if target.active and target.entity and DoesEntityExist(target.entity) then
            pcall(function() exports['qb-target']:RemoveTargetEntity(target.entity) end)
        end
    end
    for _, entityId in pairs(HiddenDropEntities) do
        local entity = getDropEntity(entityId)
        if entity then
            ResetEntityAlpha(entity)
            SetEntityVisible(entity, true, false)
            SetEntityCollision(entity, true, true)
            FreezeEntityPosition(entity, true)
        end
    end

    CarryVisuals = {}
    DropTargets = {}
    DropEntityIds = {}
    PendingDropPlacements = {}
    HiddenDropEntities = {}
    HoldingDrop = false
    heldDrop = nil
    bagObject = nil
    carryRequestPending = false
    releaseRequestPending = false
    lastCarryHeartbeat = 0
    CurrentDropBucket = nil
    dropVisualSyncPending = false
    lastDropVisualSync = 0
    CurrentDrop = nil
    exports['qb-core']:HideText()
end

function GetDrops()
    if dropVisualSyncPending then return end
    dropVisualSyncPending = true
    QBCore.Functions.TriggerCallback('qb-inventory:server:GetCurrentDrops', function(response)
        dropVisualSyncPending = false
        lastDropVisualSync = GetGameTimer()
        if type(response) ~= 'table' or type(response.drops) ~= 'table' or type(response.bucket) ~= 'number' then return end

        if CurrentDropBucket ~= nil and CurrentDropBucket ~= response.bucket then
            CleanupDropVisualState()
        end
        CurrentDropBucket = response.bucket
        lastDropVisualSync = GetGameTimer()

        local synchronizedDrops = {}
        for dropId, state in pairs(response.drops) do
            if type(dropId) == 'string' and type(state) == 'table' and state.bucket == response.bucket and state.entityId then
                synchronizedDrops[dropId] = true
                DropEntityIds[dropId] = state.entityId
                if state.carriedBy then
                    startCarryVisual(dropId, state.entityId, state.carriedBy)
                else
                    deleteCarryProxy(dropId)
                    clearLocalCarrierState(dropId)
                    registerDropTarget(dropId, state.entityId)
                end
            end
        end

        local staleDrops = {}
        for dropId in pairs(DropEntityIds) do
            if not synchronizedDrops[dropId] then staleDrops[#staleDrops + 1] = dropId end
        end
        for i = 1, #staleDrops do
            local dropId = staleDrops[i]
            removeDropTarget(dropId)
            deleteCarryProxy(dropId)
            clearLocalCarrierState(dropId)
            DropTargets[dropId] = nil
            DropEntityIds[dropId] = nil
            PendingDropPlacements[dropId] = nil
            HiddenDropEntities[dropId] = nil
        end
    end)
end

-- Events

RegisterNetEvent('qb-inventory:client:removeDropTarget', function(dropId, inventoryId)
    inventoryId = inventoryId or ('drop-' .. dropId)
    removeDropTarget(inventoryId)
    deleteCarryProxy(inventoryId)
    DropTargets[inventoryId] = nil
    DropEntityIds[inventoryId] = nil
    PendingDropPlacements[inventoryId] = nil
    HiddenDropEntities[inventoryId] = nil
end)

RegisterNetEvent('qb-inventory:client:dropCarryStarted', function(dropId, entityId, carrierServerId)
    startCarryVisual(dropId, entityId, carrierServerId)
end)

RegisterNetEvent('qb-inventory:client:clearDropCarryVisual', function(dropId)
    deleteCarryProxy(dropId)
    clearLocalCarrierState(dropId)
    removeDropTarget(dropId)
    DropTargets[dropId] = nil
    DropEntityIds[dropId] = nil
    PendingDropPlacements[dropId] = nil
    HiddenDropEntities[dropId] = nil
end)

RegisterNetEvent('qb-inventory:client:placeDrop', function(entityId, coords, dropId)
    deleteCarryProxy(dropId)
    DropEntityIds[dropId] = entityId
    local bag = getDropEntity(entityId)
    if bag then
        SetEntityCoords(bag, coords.x, coords.y, coords.z, false, false, false, false)
        ResetEntityAlpha(bag)
        SetEntityVisible(bag, true, false)
        SetEntityCollision(bag, true, true)
        FreezeEntityPosition(bag, true)
    else
        PendingDropPlacements[dropId] = coords
    end
    registerDropTarget(dropId, entityId)
    clearLocalCarrierState(dropId)
end)

RegisterNetEvent('qb-inventory:client:setupDropTarget', function(dropId, inventoryId)
    local newDropId = inventoryId or ('drop-' .. dropId)
    registerDropTarget(newDropId, dropId)
end)

-- NUI Callbacks

RegisterNUICallback('DropItem', function(item, cb)
    QBCore.Functions.TriggerCallback('qb-inventory:server:createDrop', function(dropId)
        if dropId then
            while not NetworkDoesNetworkIdExist(dropId) do Wait(10) end
            local bag = NetworkGetEntityFromNetworkId(dropId)
            SetModelAsNoLongerNeeded(bag)
            PlaceObjectOnGroundProperly(bag)
            FreezeEntityPosition(bag, true)
            local newDropId = 'drop-' .. dropId
            cb(newDropId)
        else
            cb(false)
        end
    end, item)
end)

RegisterCommand('+qbInventoryDropBag', function()
    requestDropRelease()
end, false)

RegisterCommand('-qbInventoryDropBag', function()
end, false)

RegisterKeyMapping('+qbInventoryDropBag', 'Release carried inventory bag', 'keyboard', 'G')

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CleanupDropVisualState()
end)

CreateThread(function()
    while true do
        for dropId in pairs(CarryVisuals) do
            ensureCarryProxy(dropId)
        end
        for dropId, target in pairs(DropTargets) do
            if not CarryVisuals[dropId] and not target.active then
                registerDropTarget(dropId, target.entityId or DropEntityIds[dropId])
            end
        end
        if GetGameTimer() - lastDropVisualSync >= 3000 then GetDrops() end
        Wait(500)
    end
end)

-- Thread

CreateThread(function()
    while true do
        if HoldingDrop then
            local now = GetGameTimer()
            if now - lastCarryHeartbeat >= (Config.DropCarryUpdateInterval or 250) then
                lastCarryHeartbeat = now
                TriggerServerEvent('qb-inventory:server:updateDrop', heldDrop)
            end
            if IsControlJustPressed(0, 47) or IsDisabledControlJustPressed(0, 47) then
                requestDropRelease()
            end
        end
        Wait(0)
    end
end)
