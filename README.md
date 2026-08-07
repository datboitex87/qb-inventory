# qb-inventory

## Dependencies
- [qb-core](https://github.com/qbcore-framework/qb-core)
- [qb-smallresources](https://github.com/qbcore-framework/qb-smallresources) - For logging transfer and other history

## Features
- Stashes (Personal and/or Shared)
- Vehicle Trunk & Glovebox
- Weapon Attachments
- Shops
- Item Drops

## Documentation
https://docs.qbcore.org/qbcore-documentation/qbcore-resources/qb-inventory

### Metadata-aware stacking

Stackable items may opt into metadata-based stack identity by setting `info.stack_key` when calling `AddItem`. Two non-unique items with the same name stack when both keys are absent (the legacy behaviour), or when both keys are present and exactly equal. A keyed item never stacks with an unkeyed item or a differently keyed item.

```lua
exports['qb-inventory']:AddItem(source, 'example_item', 10, false, {
    stack_key = 'batch-a',
    quality = 90,
    origin = 'example'
}, 'example resource')
```

Splitting and recombining a compatible stack preserves the complete `info` table. `stack_key` controls only stack compatibility; it does not replace, filter, or make the rest of the metadata unique.

## Changelog

### Unreleased

- Add optional `info.stack_key` stack identity while preserving legacy stacking for items without a key.
- Enforce stack compatibility on the server for adds, splits, transfers, swaps, and recombination.

## Installation
### Manual
- Download the script and put it in the `[qb]` directory.
- Import `qb-inventory.sql` in your database
- Add the following code to your server.cfg/resouces.cfg

# Migrating from old qb-inventory

## Database
### Upload the new `inventory.sql` file to create the new `inventories` table
### Use the provided `migrate.sql` file to migrate all of your saved inventory data from stashes, trunks, etc
### Once complete, you can delete `gloveboxitems` `stashitems` and `trunkitems` tables from your database
```sql
CREATE TABLE IF NOT EXISTS `inventories` (
  `id` INT(11) NOT NULL AUTO_INCREMENT,
  `identifier` VARCHAR(50) NOT NULL,
  `items` LONGTEXT DEFAULT ('[]'),
  PRIMARY KEY (`identifier`),
  KEY `id` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4;
```

# License

    QBCore Framework
    Copyright (C) 2021 Joshua Eger

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>
