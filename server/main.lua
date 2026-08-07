QBCore = exports['qb-core']:GetCoreObject()
Inventories = {}
Drops = {}
RegisteredShops = {}

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
            if v and (v.createdTime + (Config.CleanupDropTime * 60) < os.time()) and not Drops[k].isOpen then
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
    for _, inv in pairs(Inventories) do
        if inv.isOpen == source then
            inv.isOpen = false
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
    Player(source).state.inv_busy = false
    if inventory:find('shop%-') then return end
    if inventory:find('otherplayer%-') then
        local targetId = tonumber(inventory:match('otherplayer%-(.+)'))
        Player(targetId).state.inv_busy = false
        return
    end
    if Drops[inventory] then
        Drops[inventory].isOpen = false
        if #Drops[inventory].items == 0 and not Drops[inventory].isOpen then -- if no listeed items in the drop on close
            TriggerClientEvent('qb-inventory:client:removeDropTarget', -1, Drops[inventory].entityId)
            Wait(500)
            local entity = NetworkGetEntityFromNetworkId(Drops[inventory].entityId)
            if DoesEntityExist(entity) then DeleteEntity(entity) end
            Drops[inventory] = nil
        end
        return
    end
    if not Inventories[inventory] then return end
    Inventories[inventory].isOpen = false
    MySQL.prepare('INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?', { inventory, json.encode(Inventories[inventory].items), json.encode(Inventories[inventory].items) })
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
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local drop = Drops[dropId]
    if not drop then return end
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
    drop.isOpen = true
    TriggerClientEvent('qb-inventory:client:openInventory', source, Player.PlayerData.items, formattedInventory)
end)

RegisterNetEvent('qb-inventory:server:updateDrop', function(dropId, coords)
    Drops[dropId].coords = coords
end)

RegisterNetEvent('qb-inventory:server:snowball', function(action)
    if action == 'add' then
        AddItem(source, 'weapon_snowball', 1, false, false, 'qb-inventory:server:snowball')
    elseif action == 'remove' then
        RemoveItem(source, 'weapon_snowball', 1, false, 'qb-inventory:server:snowball')
    end
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-inventory:server:GetCurrentDrops', function(_, cb)
    cb(Drops)
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
                isOpen = true
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
    elseif inventoryId:find('otherplayer-') then
        local targetId = tonumber(inventoryId:match('otherplayer%-(.+)'))
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
    elseif inventoryId:find('otherplayer-') then
        return tonumber(inventoryId:match('otherplayer%-(.+)'))
    else
        return inventoryId
    end
end

local function getInventoryLimits(inventoryId, src)
    if inventoryId == 'player' then
        local player = QBCore.Functions.GetPlayer(src)
        return player and player.PlayerData.items, Config.MaxWeight, Config.MaxSlots
    elseif inventoryId:find('otherplayer-') == 1 then
        local targetId = tonumber(inventoryId:match('otherplayer%-(.+)'))
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
        playerId = tonumber(inventoryId:match('otherplayer%-(.+)'))
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
    if type(fromInventory) ~= 'string' or type(toInventory) ~= 'string' then return end
    if toInventory:find('shop%-') then return end
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

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
