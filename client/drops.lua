HoldingDrop = false
local bagObject = nil
local heldDrop = nil
local carryRequestPending = false
local releaseRequestPending = false
local lastCarryHeartbeat = 0
CurrentDrop = nil

-- Functions

function GetDrops()
    QBCore.Functions.TriggerCallback('qb-inventory:server:GetCurrentDrops', function(drops)
        if not drops then return end
        for k, v in pairs(drops) do
            local bag = NetworkGetEntityFromNetworkId(v.entityId)
            if DoesEntityExist(bag) then
                exports['qb-target']:AddTargetEntity(bag, {
                    options = {
                        {
                            icon = 'fas fa-backpack',
                            label = Lang:t('menu.o_bag'),
                            action = function()
                                TriggerServerEvent('qb-inventory:server:openDrop', k)
                                CurrentDrop = k
                            end,
                        },
                    },
                    distance = 2.5,
                })
            end
        end
    end)
end

-- Events

RegisterNetEvent('qb-inventory:client:removeDropTarget', function(dropId)
    while not NetworkDoesNetworkIdExist(dropId) do Wait(10) end
    local bag = NetworkGetEntityFromNetworkId(dropId)
    while not DoesEntityExist(bag) do Wait(10) end
    exports['qb-target']:RemoveTargetEntity(bag)
end)

RegisterNetEvent('qb-inventory:client:placeDrop', function(entityId, coords, dropId)
    local bag = NetworkGetEntityFromNetworkId(entityId)
    if bag and bag ~= 0 and DoesEntityExist(bag) then
        DetachEntity(bag, true, true)
        SetEntityCoords(bag, coords.x, coords.y, coords.z, false, false, false, false)
        FreezeEntityPosition(bag, true)
    end
    if heldDrop == dropId then
        exports['qb-core']:HideText()
        HoldingDrop = false
        bagObject = nil
        heldDrop = nil
        releaseRequestPending = false
        lastCarryHeartbeat = 0
    end
end)

RegisterNetEvent('qb-inventory:client:setupDropTarget', function(dropId)
    while not NetworkDoesNetworkIdExist(dropId) do Wait(10) end
    local bag = NetworkGetEntityFromNetworkId(dropId)
    while not DoesEntityExist(bag) do Wait(10) end
    local newDropId = 'drop-' .. dropId
    exports['qb-target']:AddTargetEntity(bag, {
        options = {
            {
                icon = 'fa-solid fa-suitcase',
                label = Lang:t('menu.o_bag'),
                action = function()
                    TriggerServerEvent('qb-inventory:server:openDrop', newDropId)
                    CurrentDrop = newDropId
                end,
            },
            {
                icon = 'fas fa-hand-pointer',
                label = Lang:t('menu.p_bag'),
                action = function()
                    if IsPedArmed(PlayerPedId(), 4) then
                        return QBCore.Functions.Notify(Lang:t('notify.nogunbag'), "error", 5500)
                    end
                    if HoldingDrop then
                        return QBCore.Functions.Notify(Lang:t('notify.hasbag'), "error", 5500)
                    end
                    if carryRequestPending then return end
                    carryRequestPending = true
                    QBCore.Functions.TriggerCallback('qb-inventory:server:beginDropCarry', function(authorized)
                        carryRequestPending = false
                        if not authorized then
                            QBCore.Functions.Notify('Unable to carry this bag.', 'error', 3500)
                            return
                        end
                        if not DoesEntityExist(bag) then
                            QBCore.Functions.TriggerCallback('qb-inventory:server:releaseDropCarry', function() end, newDropId)
                            return
                        end
                        AttachEntityToEntity(
                            bag,
                            PlayerPedId(),
                            GetPedBoneIndex(PlayerPedId(), Config.ItemDropObjectBone),
                            Config.ItemDropObjectOffset[1].x,
                            Config.ItemDropObjectOffset[1].y,
                            Config.ItemDropObjectOffset[1].z,
                            Config.ItemDropObjectOffset[2].x,
                            Config.ItemDropObjectOffset[2].y,
                            Config.ItemDropObjectOffset[2].z,
                            true, true, false, true, 1, true
                        )
                        bagObject = bag
                        HoldingDrop = true
                        heldDrop = newDropId
                        lastCarryHeartbeat = GetGameTimer()
                        exports['qb-core']:DrawText(Lang:t('interaction.drop_bag'))
                    end, newDropId)
                end,
            }
        },
        distance = 2.5,
    })
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

-- Thread

CreateThread(function()
    while true do
        if HoldingDrop then
            local now = GetGameTimer()
            if now - lastCarryHeartbeat >= (Config.DropCarryUpdateInterval or 250) then
                lastCarryHeartbeat = now
                TriggerServerEvent('qb-inventory:server:updateDrop', heldDrop)
            end
            if IsControlJustPressed(0, 47) and not releaseRequestPending then
                releaseRequestPending = true
                QBCore.Functions.TriggerCallback('qb-inventory:server:releaseDropCarry', function(released)
                    if not released then
                        releaseRequestPending = false
                        QBCore.Functions.Notify('Unable to place this bag.', 'error', 3500)
                    end
                end, heldDrop)
            end
        end
        Wait(0)
    end
end)
