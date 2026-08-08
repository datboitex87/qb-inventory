QBCore = exports['qb-core']:GetCoreObject()
Inventories = {}
Drops = {}
RegisteredShops = {}
ActiveInventorySessions = {}
OtherPlayerInventoryViewers = {}
ActiveDropCarries = {}

local dropCarryUpdateTimes = {}
local dropSecurityLogTimes = {}

local function dropSecurityLog(source, dropId, action, reason)
    local now = GetGameTimer()
    local key = ('%s:%s:%s'):format(tostring(source), tostring(action), tostring(reason))
    if dropSecurityLogTimes[key] and now - dropSecurityLogTimes[key] < 1000 then return end
    dropSecurityLogTimes[key] = now
    print(('[qb-inventory security] source=%s drop=%s action=%s reason=%s'):format(
        tostring(source), tostring(dropId), tostring(action), tostring(reason)
    ))
end

local function getServerPlayerCoords(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil, nil end
    return GetEntityCoords(ped), ped
end

local function getEntityForwardFromHeading(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return vector3(0.0, 1.0, 0.0)
    end
    local heading = math.rad(GetEntityHeading(entity))
    return vector3(-math.sin(heading), math.cos(heading), 0.0)
end

local function setDropEntityPosition(drop, coords)
    if not drop or not drop.entityId then return false end
    local entity = NetworkGetEntityFromNetworkId(drop.entityId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    SetEntityCoords(entity, coords.x, coords.y, coords.z, false, false, false, false)
    FreezeEntityPosition(entity, true)
    return true
end

local function clearDropCarry(source, dropId, updatePosition)
    source = tonumber(source) or source
    local ownedDropId = ActiveDropCarries[source]
    if not ownedDropId or (dropId and ownedDropId ~= dropId) then return false end
    local drop = Drops[ownedDropId]
    if drop and drop.carriedBy == source then
        if updatePosition then
            local coords, ped = getServerPlayerCoords(source)
            if coords then
                local forward = getEntityForwardFromHeading(ped)
                drop.coords = vector3(coords.x + forward.x * 0.57, coords.y + forward.y * 0.57, coords.z - 0.9)
                setDropEntityPosition(drop, drop.coords)
            end
        end
        drop.carriedBy = nil
        drop.carryStartedAt = nil
    end
    ActiveDropCarries[source] = nil
    dropCarryUpdateTimes[source] = nil
    return true, drop
end

local function clearStaleDropCarry(dropId, drop)
    if not drop or not drop.carriedBy then return end
    local carrier = drop.carriedBy
    if QBCore.Functions.GetPlayer(carrier) and ActiveDropCarries[carrier] == dropId then return end
    if ActiveDropCarries[carrier] == dropId then ActiveDropCarries[carrier] = nil end
    dropCarryUpdateTimes[carrier] = nil
    drop.carriedBy = nil
    drop.carryStartedAt = nil
end

local function inventorySecurityLog(source, fromInventory, toInventory, reason)
    local session = ActiveInventorySessions[tonumber(source) or source]
    print(('[qb-inventory security] source=%s from=%s to=%s authorized=%s reason=%s'):format(
        tostring(source), tostring(fromInventory), tostring(toInventory),
        session and tostring(session.inventoryId) or 'none', reason
    ))
end

local function isDropInRange(source, drop)
    if not drop or not drop.coords then return false end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - drop.coords) <= (Config.DropAccessDistance or 3.0)
end

function GetInventorySession(source)
    return ActiveInventorySessions[tonumber(source) or source]
end

function ClearInventorySession(source, expectedInventoryId)
    source = tonumber(source) or source
    local session = ActiveInventorySessions[source]
    if not session or (expectedInventoryId and session.inventoryId ~= expectedInventoryId) then return false end

    if session.kind == 'inventory' then
        local inventory = Inventories[session.inventoryId]
        if inventory and inventory.isOpen == source then
            inventory.isOpen = false
            MySQL.prepare('INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?', { session.inventoryId, json.encode(inventory.items), json.encode(inventory.items) })
        end
    elseif session.kind == 'drop' then
        local drop = Drops[session.inventoryId]
        if drop and drop.isOpen == source then drop.isOpen = false end
    elseif session.kind == 'otherplayer' then
        if OtherPlayerInventoryViewers[session.targetId] == source then
            OtherPlayerInventoryViewers[session.targetId] = nil
            local target = QBCore.Functions.GetPlayer(session.targetId)
            if target then Player(session.targetId).state.inv_busy = false end
        end
    end

    ActiveInventorySessions[source] = nil
    return true, session
end

function BeginInventorySession(source, kind, inventoryId, context)
    source = tonumber(source) or source
    local targetId = context and tonumber(context.targetId) or nil
    if kind == 'otherplayer' then
        local viewer = targetId and OtherPlayerInventoryViewers[targetId] or nil
        if not targetId or (viewer and viewer ~= source) then return false end
    end
    ClearInventorySession(source)
    ActiveInventorySessions[source] = {
        kind = kind,
        inventoryId = inventoryId,
        targetId = targetId,
        shopName = context and context.shopName or nil,
        openedAt = os.time()
    }
    if kind == 'otherplayer' then OtherPlayerInventoryViewers[targetId] = source end
    return ActiveInventorySessions[source]
end

function CanClaimOtherPlayerInventory(source, targetId)
    source = tonumber(source) or source
    targetId = tonumber(targetId)
    if not targetId then return false end
    local viewer = OtherPlayerInventoryViewers[targetId]
    if not viewer then return true end

    local viewerSession = GetInventorySession(viewer)
    local viewerIsActive = QBCore.Functions.GetPlayer(viewer)
        and viewerSession
        and viewerSession.kind == 'otherplayer'
        and viewerSession.targetId == targetId
        and viewerSession.inventoryId == 'otherplayer-' .. targetId
    if viewerIsActive then return false end

    if viewerSession and viewerSession.kind == 'otherplayer' and viewerSession.targetId == targetId then
        ClearInventorySession(viewer)
    elseif OtherPlayerInventoryViewers[targetId] == viewer then
        OtherPlayerInventoryViewers[targetId] = nil
        local target = QBCore.Functions.GetPlayer(targetId)
        if target then Player(targetId).state.inv_busy = false end
    end
    return true
end

function CanAccessInventory(source, inventoryId)
    if inventoryId == 'player' then return true end
    local session = GetInventorySession(source)
    if not session or session.inventoryId ~= inventoryId then return false, 'inventory does not match active session' end

    if session.kind == 'inventory' then
        local inventory = Inventories[inventoryId]
        if not inventory then return false, 'inventory no longer exists' end
        if inventory.isOpen ~= source then return false, 'inventory lock is not owned by source' end
        return true
    elseif session.kind == 'drop' then
        local drop = Drops[inventoryId]
        if not drop then return false, 'drop no longer exists' end
        if drop.isOpen ~= source then return false, 'drop lock is not owned by source' end
        if not isDropInRange(source, drop) then return false, 'source is too far from drop' end
        return true
    elseif session.kind == 'otherplayer' then
        local targetId = tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
        if not targetId or targetId ~= session.targetId then return false, 'other-player target mismatch' end
        if not QBCore.Functions.GetPlayer(targetId) then return false, 'other-player target is unavailable' end
        if OtherPlayerInventoryViewers[targetId] ~= (tonumber(source) or source) then return false, 'other-player viewer ownership mismatch' end
        return true
    end

    return false, 'active session kind cannot move items'
end

function CanMoveBetweenInventories(source, fromInventory, toInventory)
    if fromInventory:find('^shop%-') or toInventory:find('^shop%-') then return false, 'shop movement event rejected' end
    if fromInventory ~= 'player' and toInventory ~= 'player' and fromInventory ~= toInventory then
        return false, 'cross-external movement rejected'
    end
    local allowed, reason = CanAccessInventory(source, fromInventory)
    if not allowed then return false, reason end
    return CanAccessInventory(source, toInventory)
end

local function copyTable(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, entry in pairs(value) do
        copy[copyTable(key)] = copyTable(entry)
    end
    return copy
end

CreateThread(function()
    MySQL.query('SELECT * FROM inventories', {}, function(result)
        if result and #result > 0 then
            for i = 1, #result do
                local inventory = result[i]
                local cacheKey = inventory.identifier
                Inventories[cacheKey] = {
                    items = json.decode(inventory.items) or {},
                    isOpen = false
                }
            end
            print(#result .. ' inventories successfully loaded')
        end
    end)
end)

CreateThread(function()
    while true do
        for k, v in pairs(Drops) do
            if v and (v.createdTime + (Config.CleanupDropTime * 60) < os.time()) and not v.isOpen and not v.carriedBy then
                local entity = NetworkGetEntityFromNetworkId(v.entityId)
                if DoesEntityExist(entity) then DeleteEntity(entity) end
                Drops[k] = nil
            end
        end
        Wait(Config.CleanupDropInterval * 60000)
    end
end)

-- Handlers

AddEventHandler('playerDropped', function()
    local src = tonumber(source) or source
    local carriedDropId = ActiveDropCarries[src]
    if carriedDropId then
        local _, carriedDrop = clearDropCarry(src, carriedDropId, true)
        if carriedDrop then
            TriggerClientEvent('qb-inventory:client:placeDrop', -1, carriedDrop.entityId, carriedDrop.coords, carriedDropId)
        end
    end
    for dropId, drop in pairs(Drops) do
        if drop.carriedBy == src then
            local coords, ped = getServerPlayerCoords(src)
            if coords then
                local forward = getEntityForwardFromHeading(ped)
                drop.coords = vector3(coords.x + forward.x * 0.57, coords.y + forward.y * 0.57, coords.z - 0.9)
                setDropEntityPosition(drop, drop.coords)
            end
            drop.carriedBy = nil
            drop.carryStartedAt = nil
            TriggerClientEvent('qb-inventory:client:placeDrop', -1, drop.entityId, drop.coords, dropId)
        end
    end
    ActiveDropCarries[src] = nil
    dropCarryUpdateTimes[src] = nil
    ClearInventorySession(src)
    for targetId, viewer in pairs(OtherPlayerInventoryViewers) do
        if viewer == src then
            OtherPlayerInventoryViewers[targetId] = nil
            local target = QBCore.Functions.GetPlayer(targetId)
            if target then Player(targetId).state.inv_busy = false end
        end
    end
    for _, inventory in pairs(Inventories) do
        if inventory.isOpen == src then inventory.isOpen = false end
    end
    for _, drop in pairs(Drops) do
        if drop.isOpen == src then drop.isOpen = false end
    end
    local affectedViewers = {}
    local mappedViewer = OtherPlayerInventoryViewers[src]
    if mappedViewer then affectedViewers[#affectedViewers + 1] = mappedViewer end
    for viewer, session in pairs(ActiveInventorySessions) do
        if session.kind == 'otherplayer' and session.targetId == src and viewer ~= mappedViewer then
            affectedViewers[#affectedViewers + 1] = viewer
        end
    end
    for i = 1, #affectedViewers do
        local viewer = affectedViewers[i]
        local viewerSession = GetInventorySession(viewer)
        local shouldCloseViewer = false
        if viewerSession and viewerSession.kind == 'otherplayer' and viewerSession.targetId == src then
            ClearInventorySession(viewer)
            shouldCloseViewer = true
        elseif OtherPlayerInventoryViewers[src] == viewer then
            OtherPlayerInventoryViewers[src] = nil
        end
        if shouldCloseViewer and QBCore.Functions.GetPlayer(viewer) then
            Player(viewer).state.inv_busy = false
            TriggerClientEvent('qb-inventory:client:closeInv', viewer)
        end
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    for inventory, data in pairs(Inventories) do
        if data.isOpen then
            MySQL.prepare('INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?', { inventory, json.encode(data.items), json.encode(data.items) })
        end
    end
end)

RegisterNetEvent('QBCore:Server:UpdateObject', function()
    if source ~= '' then return end
    QBCore = exports['qb-core']:GetCoreObject()
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'AddItem', function(item, amount, slot, info, reason)
        return AddItem(Player.PlayerData.source, item, amount, slot, info, reason)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'RemoveItem', function(item, amount, slot, reason)
        return RemoveItem(Player.PlayerData.source, item, amount, slot, reason)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemBySlot', function(slot)
        return GetItemBySlot(Player.PlayerData.source, slot)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemByName', function(item)
        return GetItemByName(Player.PlayerData.source, item)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemsByName', function(item)
        return GetItemsByName(Player.PlayerData.source, item)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'ClearInventory', function(filterItems)
        ClearInventory(Player.PlayerData.source, filterItems)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'SetInventory', function(items)
        SetInventory(Player.PlayerData.source, items)
    end)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    local Players = QBCore.Functions.GetQBPlayers()
    for k in pairs(Players) do
        QBCore.Functions.AddPlayerMethod(k, 'AddItem', function(item, amount, slot, info)
            return AddItem(k, item, amount, slot, info)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'RemoveItem', function(item, amount, slot)
            return RemoveItem(k, item, amount, slot)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'GetItemBySlot', function(slot)
            return GetItemBySlot(k, slot)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'GetItemByName', function(item)
            return GetItemByName(k, item)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'GetItemsByName', function(item)
            return GetItemsByName(k, item)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'ClearInventory', function(filterItems)
            ClearInventory(k, filterItems)
        end)

        QBCore.Functions.AddPlayerMethod(k, 'SetInventory', function(items)
            SetInventory(k, items)
        end)

        Player(k).state.inv_busy = false
    end
end)

-- Functions

function checkWeapon(source, item)
    local currentWeapon = item
    local ped = GetPlayerPed(source)
    local weapon = GetSelectedPedWeapon(ped)
    local weaponInfo = QBCore.Shared.Weapons[weapon]
    local info = {}

    if type(item) == 'table' then
        currentWeapon = item.name
        info = item.info or {}
    end

    if weaponInfo and weaponInfo.name == currentWeapon then
        RemoveWeaponFromPed(ped, weapon)
        TriggerClientEvent('qb-weapons:client:UseWeapon', source, { name = currentWeapon, info = info }, false)
    end
end

-- Events

RegisterNetEvent('qb-inventory:server:openVending', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    CreateShop({
        name = 'vending',
        label = 'Vending Machine',
        coords = data.coords,
        slots = #Config.VendingItems,
        items = Config.VendingItems
    })
    OpenShop(src, 'vending')
end)

RegisterNetEvent('qb-inventory:server:closeInventory', function(inventory)
    local src = source
    local QBPlayer = QBCore.Functions.GetPlayer(src)
    if not QBPlayer then return end
    if type(inventory) ~= 'string' then return end
    local session = GetInventorySession(src)
    if inventory == '' and session and session.kind == 'player' then inventory = 'player' end
    if not session or session.inventoryId ~= inventory then
        inventorySecurityLog(src, inventory, inventory, 'close does not match active session')
        return
    end

    local drop = session.kind == 'drop' and Drops[inventory] or nil
    ClearInventorySession(src, inventory)
    Player(src).state.inv_busy = false
    if drop then
        if #drop.items == 0 and not drop.isOpen then -- if no listed items in the drop on close
            TriggerClientEvent('qb-inventory:client:removeDropTarget', -1, Drops[inventory].entityId)
            Wait(500)
            local entity = NetworkGetEntityFromNetworkId(Drops[inventory].entityId)
            if DoesEntityExist(entity) then DeleteEntity(entity) end
            Drops[inventory] = nil
        end
    end
end)

RegisterNetEvent('qb-inventory:server:useItem', function(item)
    local src = source
    local itemData = GetItemBySlot(src, item.slot)
    if not itemData then return end
    local itemInfo = QBCore.Shared.Items[itemData.name]
    if itemData.type == 'weapon' then
        TriggerClientEvent('qb-weapons:client:UseWeapon', src, itemData, itemData.info.quality and itemData.info.quality > 0)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
    elseif itemData.name == 'id_card' then
        UseItem(itemData.name, src, itemData)
        TriggerClientEvent('qb-inventory:client:ItemBox', source, itemInfo, 'use')
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local players = QBCore.Functions.GetPlayers()
        local info = itemData.info or item.info or {}
        local gender = info.gender == 0 and 'Male' or 'Female'
        for _, v in pairs(players) do
            local targetPed = GetPlayerPed(v)
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist < 3.0 then
                TriggerClientEvent('chat:addMessage', v, {
                    template = '<div class="chat-message advert" style="background: linear-gradient(to right, rgba(5, 5, 5, 0.6), #74807c); display: flex;"><div style="margin-right: 10px;"><i class="far fa-id-card" style="height: 100%;"></i><strong> {0}</strong><br> <strong>Civ ID:</strong> {1} <br><strong>First Name:</strong> {2} <br><strong>Last Name:</strong> {3} <br><strong>Birthdate:</strong> {4} <br><strong>Gender:</strong> {5} <br><strong>Nationality:</strong> {6}</div></div>',
                    args = {
                        'ID Card',
                        info.citizenid,
                        info.firstname,
                        info.lastname,
                        info.birthdate,
                        gender,
                        info.nationality
                    }
                })
            end
        end
    elseif itemData.name == 'driver_license' then
        UseItem(itemData.name, src, itemData)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local players = QBCore.Functions.GetPlayers()
        local info = itemData.info or item.info or {}
        for _, v in pairs(players) do
            local targetPed = GetPlayerPed(v)
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist < 3.0 then
                TriggerClientEvent('chat:addMessage', v, {
                    template = '<div class="chat-message advert" style="background: linear-gradient(to right, rgba(5, 5, 5, 0.6), #657175); display: flex;"><div style="margin-right: 10px;"><i class="far fa-id-card" style="height: 100%;"></i><strong> {0}</strong><br> <strong>First Name:</strong> {1} <br><strong>Last Name:</strong> {2} <br><strong>Birth Date:</strong> {3} <br><strong>Licenses:</strong> {4}</div></div>',
                    args = {
                        'Drivers License',
                        info.firstname,
                        info.lastname,
                        info.birthdate,
                        info.type
                    }
                }
                )
            end
        end
    else
        UseItem(itemData.name, src, itemData)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
    end
end)

RegisterNetEvent('qb-inventory:server:openDrop', function(dropId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(dropId) ~= 'string' then
        dropSecurityLog(src, dropId, 'open', 'invalid drop identifier')
        return
    end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local drop = Drops[dropId]
    if not drop then
        dropSecurityLog(src, dropId, 'open', 'unknown drop')
        return
    end
    clearStaleDropCarry(dropId, drop)
    if drop.carriedBy then
        dropSecurityLog(src, dropId, 'open', 'drop is currently carried')
        return
    end
    if drop.isOpen then return end
    local distance = #(playerCoords - drop.coords)
    if distance > 2.5 then return end
    local formattedInventory = {
        name = dropId,
        label = dropId,
        maxweight = drop.maxweight,
        slots = drop.slots,
        inventory = drop.items
    }
    BeginInventorySession(src, 'drop', dropId)
    drop.isOpen = src
    TriggerClientEvent('qb-inventory:client:openInventory', source, Player.PlayerData.items, formattedInventory)
end)

RegisterNetEvent('qb-inventory:server:updateDrop', function(dropId, _)
    local src = source
    if type(dropId) ~= 'string' then
        dropSecurityLog(src, dropId, 'update', 'invalid drop identifier')
        return
    end
    local drop = Drops[dropId]
    if not drop then
        dropSecurityLog(src, dropId, 'update', 'unknown drop')
        return
    end
    if ActiveDropCarries[src] ~= dropId or drop.carriedBy ~= src then
        dropSecurityLog(src, dropId, 'update', 'source is not the authorized carrier')
        return
    end
    local now = GetGameTimer()
    if dropCarryUpdateTimes[src] and now - dropCarryUpdateTimes[src] < (Config.DropCarryUpdateInterval or 250) then return end
    local coords = getServerPlayerCoords(src)
    if not coords then
        dropSecurityLog(src, dropId, 'update', 'carrier ped is unavailable')
        return
    end
    dropCarryUpdateTimes[src] = now
    drop.coords = coords
end)

RegisterNetEvent('qb-inventory:server:snowball', function(action)
    if action == 'add' then
        AddItem(source, 'weapon_snowball', 1, false, false, 'qb-inventory:server:snowball')
    elseif action == 'remove' then
        RemoveItem(source, 'weapon_snowball', 1, false, 'qb-inventory:server:snowball')
    end
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-inventory:server:beginDropCarry', function(source, cb, dropId)
    local src = tonumber(source) or source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(dropId) ~= 'string' then
        dropSecurityLog(src, dropId, 'carry-start', 'invalid player or drop identifier')
        cb(false)
        return
    end
    local drop = Drops[dropId]
    if not drop then
        dropSecurityLog(src, dropId, 'carry-start', 'unknown drop')
        cb(false)
        return
    end
    clearStaleDropCarry(dropId, drop)
    local activeDropId = ActiveDropCarries[src]
    if activeDropId then
        local activeDrop = Drops[activeDropId]
        if not activeDrop or activeDrop.carriedBy ~= src then
            ActiveDropCarries[src] = nil
            dropCarryUpdateTimes[src] = nil
            activeDropId = nil
        end
    end
    if activeDropId and activeDropId ~= dropId then
        dropSecurityLog(src, dropId, 'carry-start', 'source already carries a different drop')
        cb(false)
        return
    end
    if drop.carriedBy and drop.carriedBy ~= src then
        dropSecurityLog(src, dropId, 'carry-start', 'drop is carried by another source')
        cb(false)
        return
    end
    if activeDropId == dropId or drop.carriedBy == src then
        dropSecurityLog(src, dropId, 'carry-start', 'drop is already carried by source')
        cb(false)
        return
    end
    if drop.isOpen then
        dropSecurityLog(src, dropId, 'carry-start', 'drop inventory is open')
        cb(false)
        return
    end
    local coords = getServerPlayerCoords(src)
    if not coords or not drop.coords or #(coords - drop.coords) > (Config.DropCarryPickupDistance or Config.DropAccessDistance or 3.0) then
        dropSecurityLog(src, dropId, 'carry-start', 'source is too far from drop')
        cb(false)
        return
    end
    local entity = drop.entityId and NetworkGetEntityFromNetworkId(drop.entityId) or 0
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        dropSecurityLog(src, dropId, 'carry-start', 'authoritative drop entity is unavailable')
        cb(false)
        return
    end

    drop.carriedBy = src
    drop.carryStartedAt = os.time()
    ActiveDropCarries[src] = dropId
    dropCarryUpdateTimes[src] = GetGameTimer()
    TriggerClientEvent('qb-inventory:client:dropCarryStarted', -1, dropId, drop.entityId, src)
    cb(true)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:releaseDropCarry', function(source, cb, dropId)
    local src = tonumber(source) or source
    if type(dropId) ~= 'string' then
        dropSecurityLog(src, dropId, 'carry-release', 'invalid drop identifier')
        cb(false)
        return
    end
    local drop = Drops[dropId]
    if not drop then
        dropSecurityLog(src, dropId, 'carry-release', 'unknown drop')
        cb(false)
        return
    end
    if ActiveDropCarries[src] ~= dropId or drop.carriedBy ~= src then
        dropSecurityLog(src, dropId, 'carry-release', 'source is not the authorized carrier')
        cb(false)
        return
    end
    local coords = getServerPlayerCoords(src)
    if not coords then
        dropSecurityLog(src, dropId, 'carry-release', 'carrier ped is unavailable')
        cb(false)
        return
    end
    local released, releasedDrop = clearDropCarry(src, dropId, true)
    if not released or not releasedDrop then cb(false) return end
    TriggerClientEvent('qb-inventory:client:placeDrop', -1, releasedDrop.entityId, releasedDrop.coords, dropId)
    cb(true)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:GetCurrentDrops', function(_, cb)
    cb(Drops)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:GetCurrentDropVisualStates', function(_, cb)
    local visualStates = {}
    for dropId, drop in pairs(Drops) do
        if drop.carriedBy then
            visualStates[#visualStates + 1] = {
                dropId = dropId,
                entityId = drop.entityId,
                carrierServerId = drop.carriedBy
            }
        end
    end
    cb(visualStates)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:createDrop', function(source, cb, item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(item) ~= 'table' then
        cb(false)
        return
    end

    local fromSlot = tonumber(item.fromSlot)
    local amount = tonumber(item.amount)
    if not fromSlot or fromSlot % 1 ~= 0 or fromSlot < 1 or fromSlot > Config.MaxSlots or not amount or amount % 1 ~= 0 or amount <= 0 then
        cb(false)
        return
    end

    local sourceItem = GetItemBySlot(src, fromSlot)
    if not sourceItem or amount > sourceItem.amount then
        cb(false)
        return
    end

    local sourceSnapshot = copyTable(sourceItem)
    local dropItem = copyTable(sourceItem)
    dropItem.amount = amount
    dropItem.slot = 1

    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    if not RemoveItem(src, sourceSnapshot.name, amount, fromSlot, 'dropped item') then
        cb(false)
        return
    end

    local bag
    local dropKey
    local createdNewDrop = false
    local insertedSlot
    local created, dropId = pcall(function()
        bag = CreateObjectNoOffset(Config.ItemDropObject, playerCoords.x + 0.5, playerCoords.y + 0.5, playerCoords.z, true, true, false)
        if not bag or bag == 0 or not DoesEntityExist(bag) then return nil end
        local networkId = NetworkGetNetworkIdFromEntity(bag)
        if not networkId or networkId == 0 then return nil end
        local newDropId = 'drop-' .. networkId
        dropKey = newDropId
        local itemsTable = setmetatable({ dropItem }, {
            __len = function(t)
                local length = 0
                for _ in pairs(t) do length += 1 end
                return length
            end
        })
        if not Drops[newDropId] then
            createdNewDrop = true
            Drops[newDropId] = {
                name = newDropId,
                label = 'Drop',
                items = itemsTable,
                entityId = networkId,
                createdTime = os.time(),
                coords = playerCoords,
                maxweight = Config.DropSize.maxweight,
                slots = Config.DropSize.slots,
                isOpen = src,
                carriedBy = nil,
                carryStartedAt = nil
            }
        else
            dropItem.slot = #Drops[newDropId].items + 1
            insertedSlot = dropItem.slot
            table.insert(Drops[newDropId].items, dropItem)
        end
        return networkId
    end)

    if not created or not dropId then
        if createdNewDrop and dropKey then
            Drops[dropKey] = nil
        elseif dropKey and insertedSlot and Drops[dropKey] then
            table.remove(Drops[dropKey].items, insertedSlot)
        end
        Player.PlayerData.items[fromSlot] = sourceSnapshot
        local restored = pcall(function() Player.SetPlayerData('items', Player.PlayerData.items) end)
        if bag and DoesEntityExist(bag) then DeleteEntity(bag) end
        if restored then
            print(('createDrop: Drop creation failed; restored %s x%d to player %s slot %d'):format(sourceSnapshot.name, sourceSnapshot.amount, src, fromSlot))
        else
            print(('createDrop: CRITICAL rollback sync failed for player %s slot %d; in-memory slot was restored'):format(src, fromSlot))
        end
        cb(false)
        return
    end

    if sourceSnapshot.type == 'weapon' then checkWeapon(src, sourceSnapshot) end
    BeginInventorySession(src, 'drop', dropKey)
    Drops[dropKey].isOpen = src
    TaskPlayAnim(playerPed, 'pickup_object', 'pickup_low', 8.0, -8.0, 2000, 0, 0, false, false, false)
    TriggerClientEvent('qb-inventory:client:setupDropTarget', -1, dropId)
    cb(dropId)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:attemptPurchase', function(source, cb, data)
    if type(data) ~= 'table' or type(data.shop) ~= 'string' then cb(false) return end
    local amount = tonumber(data.amount)
    local requestedSlot = tonumber(data.slot or (type(data.item) == 'table' and data.item.slot))
    if not amount or amount % 1 ~= 0 or amount <= 0 or not requestedSlot or requestedSlot % 1 ~= 0 then cb(false) return end
    local shop = string.gsub(data.shop, 'shop%-', '')
    local Player = QBCore.Functions.GetPlayer(source)

    if not Player then
        cb(false)
        return
    end

    local shopInfo = RegisteredShops[shop]
    if not shopInfo then
        cb(false)
        return
    end

    local session = GetInventorySession(source)
    if not session or session.kind ~= 'shop' or session.inventoryId ~= data.shop or session.shopName ~= shop then
        inventorySecurityLog(source, 'player', data.shop, 'purchase does not match active shop session')
        cb(false)
        return
    end

    local shopItem = shopInfo.items[requestedSlot]
    if not shopItem then cb(false) return end

    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    if shopInfo.coords then
        local shopCoords = vector3(shopInfo.coords.x, shopInfo.coords.y, shopInfo.coords.z)
        if #(playerCoords - shopCoords) > 10 then
            cb(false)
            return
        end
    end

    if amount > shopItem.amount or shopItem.amount <= 0 then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notify.notenoughstock'), 'error')
        cb(false)
        return
    end

    if not CanAddItem(source, shopItem.name, amount, shopItem.info) then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notify.canthold'), 'error')
        cb(false)
        return
    end

    local price = shopItem.price * amount
    if Player.PlayerData.money.cash >= price then
        Player.Functions.RemoveMoney('cash', price, 'shop-purchase')
        if not AddItem(source, shopItem.name, amount, nil, shopItem.info, 'shop-purchase') then
            Player.Functions.AddMoney('cash', price, 'shop-purchase-refund')
            cb(false)
            return
        end
        shopItem.amount -= amount
        TriggerEvent('qb-shops:server:UpdateShopItems', shop, shopItem, amount)
        cb(true)
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notify.notencash'), 'error')
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-inventory:server:giveItem', function(source, cb, target, item, amount, slot, info)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or player.PlayerData.metadata['isdead'] or player.PlayerData.metadata['inlaststand'] or player.PlayerData.metadata['ishandcuffed'] then
        cb(false)
        return
    end
    local playerPed = GetPlayerPed(source)

    local Target = QBCore.Functions.GetPlayer(target)
    if not Target or Target.PlayerData.metadata['isdead'] or Target.PlayerData.metadata['inlaststand'] or Target.PlayerData.metadata['ishandcuffed'] then
        cb(false)
        return
    end
    local targetPed = GetPlayerPed(target)

    local pCoords = GetEntityCoords(playerPed)
    local tCoords = GetEntityCoords(targetPed)
    if #(pCoords - tCoords) > 5 then
        cb(false)
        return
    end

    local itemInfo = QBCore.Shared.Items[item:lower()]
    if not itemInfo then
        cb(false)
        return
    end

    local hasItem = HasItem(source, item)
    if not hasItem then
        cb(false)
        return
    end

    slot = tonumber(slot)
    local sourceItem = slot and GetItemBySlot(source, slot)
    if not sourceItem or sourceItem.name:lower() ~= item:lower() then
        cb(false)
        return
    end

    local giveAmount = tonumber(amount)
    if not giveAmount or giveAmount <= 0 or giveAmount % 1 ~= 0 or giveAmount > sourceItem.amount then
        cb(false)
        return
    end

    if not CanAddItem(target, sourceItem.name, giveAmount, sourceItem.info) then
        cb(false)
        return
    end

    local sourceSnapshot = copyTable(sourceItem)

    local removeItem = RemoveItem(source, sourceItem.name, giveAmount, slot, 'Item given to ID #' .. target)
    if not removeItem then
        cb(false)
        return
    end

    local giveItem = AddItem(target, sourceItem.name, giveAmount, false, sourceItem.info, 'Item given from ID #' .. source)
    if not giveItem then
        player.PlayerData.items[slot] = sourceSnapshot
        local restored = pcall(function() player.SetPlayerData('items', player.PlayerData.items) end)
        if restored then
            print(('giveItem: Target add failed; restored %s x%d to player %s slot %d'):format(sourceSnapshot.name, sourceSnapshot.amount, source, slot))
        else
            print(('giveItem: CRITICAL rollback sync failed for player %s slot %d; in-memory slot was restored'):format(source, slot))
        end
        cb(false)
        return
    end

    if itemInfo.type == 'weapon' then checkWeapon(source, item) end
    TriggerClientEvent('qb-inventory:client:giveAnim', source)
    TriggerClientEvent('qb-inventory:client:ItemBox', source, itemInfo, 'remove', giveAmount)
    TriggerClientEvent('qb-inventory:client:giveAnim', target)
    TriggerClientEvent('qb-inventory:client:ItemBox', target, itemInfo, 'add', giveAmount)
    if Player(target).state.inv_busy then TriggerClientEvent('qb-inventory:client:updateInventory', target) end
    cb(true)
end)

-- Item move logic

local function getItem(inventoryId, src, slot)
    local items = {}
    if inventoryId == 'player' then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData.items then
            items = Player.PlayerData.items
        end
    elseif inventoryId:find('^otherplayer%-') then
        local targetId = tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
        local targetPlayer = QBCore.Functions.GetPlayer(targetId)
        if targetPlayer and targetPlayer.PlayerData.items then
            items = targetPlayer.PlayerData.items
        end
    elseif inventoryId:find('drop-') == 1 then
        if Drops[inventoryId] and Drops[inventoryId]['items'] then
            items = Drops[inventoryId]['items']
        end
    else
        if Inventories[inventoryId] and Inventories[inventoryId]['items'] then
            items = Inventories[inventoryId]['items']
        end
    end

    for _, item in pairs(items) do
        if item.slot == slot then
            return item
        end
    end
    return nil
end

local function getIdentifier(inventoryId, src)
    if inventoryId == 'player' then
        return src
    elseif inventoryId:find('^otherplayer%-') then
        return tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
    else
        return inventoryId
    end
end

local function getInventoryLimits(inventoryId, src)
    if inventoryId == 'player' then
        local player = QBCore.Functions.GetPlayer(src)
        return player and player.PlayerData.items, Config.MaxWeight, Config.MaxSlots
    elseif inventoryId:find('otherplayer-') == 1 then
        local targetId = tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
        local player = targetId and QBCore.Functions.GetPlayer(targetId)
        return player and player.PlayerData.items, Config.MaxWeight, Config.MaxSlots
    elseif inventoryId:find('drop-') == 1 then
        local inventory = Drops[inventoryId]
        return inventory and inventory.items, inventory and inventory.maxweight, inventory and inventory.slots
    end
    local inventory = Inventories[inventoryId]
    return inventory and inventory.items, inventory and inventory.maxweight, inventory and inventory.slots
end

local function syncPlayerInventory(inventoryId, src, items)
    local playerId
    if inventoryId == 'player' then
        playerId = src
    elseif inventoryId:find('otherplayer-') == 1 then
        playerId = tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
    end
    if not playerId then return true end
    local player = QBCore.Functions.GetPlayer(playerId)
    if not player then return false end
    return pcall(function() player.SetPlayerData('items', items) end)
end

local function restoreMoveState(fromInventory, toInventory, src, fromItems, toItems, fromSlot, toSlot, fromSnapshot, toSnapshot, reason)
    fromItems[fromSlot] = copyTable(fromSnapshot)
    toItems[toSlot] = copyTable(toSnapshot)
    local sourceSynced = syncPlayerInventory(fromInventory, src, fromItems)
    local destinationSynced = toItems == fromItems or syncPlayerInventory(toInventory, src, toItems)
    if sourceSynced and destinationSynced then
        print(('SetInventoryData: %s failed; authoritative source and destination slots restored'):format(reason))
    else
        print(('SetInventoryData: CRITICAL %s rollback sync failed; in-memory slots were restored'):format(reason))
    end
end

RegisterNetEvent('qb-inventory:server:SetInventoryData', function(fromInventory, toInventory, fromSlot, toSlot, fromAmount, toAmount)
    local src = source
    if type(fromInventory) ~= 'string' or type(toInventory) ~= 'string' then
        inventorySecurityLog(src, fromInventory, toInventory, 'inventory identifiers must be strings')
        return
    end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local authorized, authorizationReason = CanMoveBetweenInventories(src, fromInventory, toInventory)
    if not authorized then
        inventorySecurityLog(src, fromInventory, toInventory, authorizationReason)
        return
    end

    fromSlot, toSlot, toAmount = tonumber(fromSlot), tonumber(toSlot), tonumber(toAmount)
    if not fromSlot or not toSlot or not toAmount or fromSlot % 1 ~= 0 or toSlot % 1 ~= 0 or toAmount % 1 ~= 0 or toAmount <= 0 then return end
    if fromInventory == toInventory and fromSlot == toSlot then return end

    local fromItem = getItem(fromInventory, src, fromSlot)
    local toItem = getItem(toInventory, src, toSlot)
    local fromItems, fromMaxWeight, fromMaxSlots = getInventoryLimits(fromInventory, src)
    local toItems, toMaxWeight, toMaxSlots = getInventoryLimits(toInventory, src)
    if not fromItems or not toItems or not fromMaxWeight or not toMaxWeight or not fromMaxSlots or not toMaxSlots then return end
    if fromSlot < 1 or fromSlot > fromMaxSlots or toSlot < 1 or toSlot > toMaxSlots then return end

    if fromItem then
        if toAmount > fromItem.amount then return end
        if fromInventory == 'player' and toInventory ~= 'player' then checkWeapon(src, fromItem) end

        local fromId = getIdentifier(fromInventory, src)
        local toId = getIdentifier(toInventory, src)
        local fromSnapshot = copyTable(fromItem)
        local toSnapshot = copyTable(toItem)

        if fromInventory ~= toInventory then
            local isSwap = toItem and not CanStackItems(fromItem, toItem)
            local movedAmount = isSwap and fromItem.amount or toAmount
            local destinationWeight = GetTotalWeight(toItems) + (fromItem.weight * movedAmount)
            if isSwap then destinationWeight = destinationWeight - (toItem.weight * toItem.amount) end
            if destinationWeight > toMaxWeight then return end

            if isSwap then
                local sourceWeight = GetTotalWeight(fromItems) - (fromItem.weight * fromItem.amount) + (toItem.weight * toItem.amount)
                if sourceWeight > fromMaxWeight then return end
            end
        end

        if toItem and CanStackItems(fromItem, toItem) then
            if RemoveItem(fromId, fromItem.name, toAmount, fromSlot, 'stacked item') then
                if not AddItem(toId, toSnapshot.name, toAmount, toSlot, toSnapshot.info, 'stacked item') then
                    restoreMoveState(fromInventory, toInventory, src, fromItems, toItems, fromSlot, toSlot, fromSnapshot, toSnapshot, 'stack')
                end
            end
        elseif not toItem and toAmount < fromItem.amount then
            if RemoveItem(fromId, fromItem.name, toAmount, fromSlot, 'split item') then
                if not AddItem(toId, fromSnapshot.name, toAmount, toSlot, fromSnapshot.info, 'split item') then
                    restoreMoveState(fromInventory, toInventory, src, fromItems, toItems, fromSlot, toSlot, fromSnapshot, toSnapshot, 'split')
                end
            end
        else
            if toItem then
                local removedSource = RemoveItem(fromId, fromSnapshot.name, fromSnapshot.amount, fromSlot, 'swapped item')
                local removedDestination = removedSource and RemoveItem(toId, toSnapshot.name, toSnapshot.amount, toSlot, 'swapped item')
                local addedSourceToDestination = removedDestination and AddItem(toId, fromSnapshot.name, fromSnapshot.amount, toSlot, fromSnapshot.info, 'swapped item')
                local addedDestinationToSource = addedSourceToDestination and AddItem(fromId, toSnapshot.name, toSnapshot.amount, fromSlot, toSnapshot.info, 'swapped item')
                if not (removedSource and removedDestination and addedSourceToDestination and addedDestinationToSource) then
                    restoreMoveState(fromInventory, toInventory, src, fromItems, toItems, fromSlot, toSlot, fromSnapshot, toSnapshot, 'swap')
                end
            else
                if RemoveItem(fromId, fromItem.name, toAmount, fromSlot, 'moved item') then
                    if not AddItem(toId, fromSnapshot.name, toAmount, toSlot, fromSnapshot.info, 'moved item') then
                        restoreMoveState(fromInventory, toInventory, src, fromItems, toItems, fromSlot, toSlot, fromSnapshot, toSnapshot, 'move')
                    end
                end
            end
        end
    end
end)
