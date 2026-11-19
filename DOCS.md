# rsg-ranch — Developer Docs

## Dependencies
`rsg-core`, `rsg-inventory`, `rsg-target`, `oxmysql`. **No ox_lib or rsg-multijob** (removed in 3.2.0; multijob is built into rsg-core).

## Framework APIs used (rsg-core replacements for ox_lib)
| Purpose | Used in rsg-ranch |
|---|---|
| Locales | `@rsg-core/shared/locale.lua` in `shared_scripts`, `locale('key')`. Language: `setr rsg:locale <code>` (falls back to `ox:locale`, then `en`). NUI strings read `locales/<lang>.json` with the same convar order (`GetUiLocales` in `client/modules/ranchui.lua`). |
| Notify (client) | `RSGCore.Functions.Notify({ title, description, type, duration })` (`exports['rsg-core']:Notify` where RSGCore isn't loaded) |
| Notify (server) | `TriggerClientEvent('RSGCore:Client:Notify', src, data)` |
| Server callbacks | Local `RegisterCallback(name, fn)` wrapper in each server file → `RSGCore.Functions.CreateCallback`; handlers simply `return` their values. Client side: `RSGCore.Functions.AwaitCallback(name, nil, ...)` |
| Client callback | `rsg-ranch:client:requestConsent` via `RSGCore.Functions.CreateClientCallback`, called with `RSGCore.Functions.TriggerClientCallback` |
| Cron | `RSGCore.Functions.CreateCron(Config.AnimalCronJob / AnimalFeedWaterCronJob / ChickenCoopFeedCronJob, job)` |
| Models | `RSGCore.Functions.RequestModel(model, timeout)` |
| Progress | `RSGCore.Functions.ProgressBar({...})` (well pump) |
| Text UI | `exports['rsg-core']:DrawText(text, 'left-center')` / `HideText()` (well pump placement) |
| Targeting | `exports['rsg-target']:addLocalEntity / removeLocalEntity` |
| Multijob | `RSGCore.Functions.AddPlayerJob(citizenid, job, grade)` / `RemovePlayerJob(citizenid, job)` (wrapped as `MultijobAddJob`/`MultijobRemoveJob` in `server/server.lua`); ranch job definitions created/removed live with `RSGCore.Functions.SaveJobDefinition` / `DeleteJobDefinition` (rsg-core 3.1.6+, SQL fallback for older cores) |
| Player ped | `PlayerPedId()` (replaces `cache.ped`) |

## Menus / dialogs
Context menus and alert dialogs are this resource's own NUI (`client/menu.lua` → `Menu.registerContext/showContext/hideContext/alertDialog`, `html/app.js`).

## Changelog
- **3.2.0** — Migrated off ox_lib to rsg-core (locales, notify, callbacks, cron, progress bar, text UI, model loading); ox_target → rsg-target; rsg-multijob exports → rsg-core multijob functions.

## rsg-skills integration

`Config.Skills = { Enabled, Skill, SellXP, SellBonus }`. The global table `RanchSkills` (top of `server/server.lua`, a table because the file is close to Lua's local-variable limit) has `Active()`, `Price(src, price)` and `SoldXP(src, count)`. `Price` multiplies the server-computed price by `1 + GetPerk(src, 'ranching', 'sell_bonus') / 100`, rounded to the cent, before the money is paid and shown. `SoldXP` calls `AddXP(src, 'ranching', SellXP * count, 'ranch animal sale')`. The `extra_yield` perk is not applied by this script. Skipped when rsg-skills is not started.

<!-- BEGIN AUTO-REFERENCE (generated from the code; re-run the generator instead of editing by hand) -->

## Technical reference

Generated from the source of **rsg-ranch 3.3.0**. Names, arguments and defaults below are read straight from the code.

### Dependencies

`rsg-core`, `rsg-inventory`, `rsg-target`, `oxmysql`

### Database

Tables: `rsg_ranch_wellpumps`, `rsg_ranch_animals`, `rsg_ranch_feedtroughs`, `rsg_ranch_storages`, `rsg_ranch_owners`, `rsg_ranch_watertroughs`, `rsg_ranch_orders`, `rsg_ranch_chickencoops`, `rsg_ranch_settings`, `rsg_ranch_custom`.

Tables are created automatically on start while `Config.AutoDatabase = true` (default). Nothing is ever dropped or overwritten.
For a manual install set `Config.AutoDatabase = false` and import `installation/rsg-ranch.sql` once.

```lua
-- shared/config.lua
Config.AutoDatabase = true -- false = import the SQL file yourself
```

### Configuration

| Option | Default | Notes |
|---|---|---|
| `Config.AutoDatabase` | `true` | build the database tables automatically on start (set false and import the SQL file for a manual install) |
| `Config.Debug` | `false` |  |
| `Config.ANIMAL_ID_MIN` | `100000` |  |
| `Config.ANIMAL_ID_MAX` | `999999` |  |
| `Config.FALLBACK_ID_SUFFIX_MIN` | `1000` |  |
| `Config.FALLBACK_ID_SUFFIX_MAX` | `9999` |  |
| `Config.MAX_ID_LENGTH` | `20` |  |
| `Config.DistanceSpawn` | `50.0` |  |
| `Config.FadeIn` | `true` |  |
| `Config.StorageMinJobGrade` | `1` |  |
| `Config.RanchStorageMaxWeight` | `10000000` |  |
| `Config.RanchStorageMaxSlots` | `100` |  |
| `Config.RanchStorageSizes` | `table` | additional storage is its own separate stash and can be renamed by the boss. |
| `Config.MaxAdditionalStorages` | `5` | a single ranch can purchase. Set to 0 for unlimited. |
| `Config.RanchStorageAccessLevels` | `table` | Shown to the boss in the order listed here. |
| `Config.AnimalFadeIn` | `true` |  |
| `Config.ServerNotify` | `true` |  |
| `Config.AnimalCronJob` | `'*/15 * * * *'` | every 15 minutes |
| `Config.AnimalFeedWaterCronJob` | `'*/15 * * * *'` | how often troughs feed/water animals (separate from the main survival cronjob above, so you can tune feed/wate |
| `Config.MaxRanchAnimals` | `10` |  |
| `Config.UpdateClientsOnCron` | `true` | Update client animal data when cronjob runs |
| `Config.RefreshAfterCron` | `true` | Full refresh of animal data after cronjob completion |
| `Config.AnimalBlipsEnabled` | `true` | ranch's own staff ever see its animals on the map, never other players or other ranches. |
| `Config.AnimalBlipSprite` | `'blip_ambient_companion'` | RDR3 blip sprite name used for animal blips |
| `Config.AnimalBlipScale` | `0.15` |  |
| `Config.AnimalBlipRefreshInterval` | `5000` | how often (ms) to re-check job/staff status and add/remove blips accordingly |
| `Config.HungerDecayRate` | `1` | hunger reduction per cronjob run |
| `Config.ThirstDecayRate` | `1` | thirst reduction per cronjob run |
| `Config.HealthDecayRate` | `1` | health reduction per cronjob run when starving/dehydrated |
| `Config.MinSurvivalStats` | `0` | minimum hunger/thirst before health starts decaying |
| `Config.HealthRegenerationRate` | `5` | health regeneration per cronjob run when well-fed and watered |
| `Config.MinStatsForRegeneration` | `80` | minimum hunger/thirst required for health regeneration |
| `Config.AutoFeedRestoreAmount` | `100` | hunger restored per cronjob run while the ranch has an active feed trough |
| `Config.AutoWaterRestoreAmount` | `100` | thirst restored per cronjob run while the ranch has an active water trough |
| `Config.AnimalWanderingEnabled` | `true` | Enable animals to wander naturally |
| `Config.WanderRadius` | `30.0` | Maximum distance animals can wander from spawn point |
| `Config.WanderMinDistance` | `3.0` | Minimum distance for a wander movement |
| `Config.WanderSpeed` | `1.0` | Movement speed while wandering (1.0 = walk, 2.0 = jog) |
| `Config.WanderIdleTimeMin` | `10000` | Minimum time (ms) standing still before wandering |
| `Config.WanderIdleTimeMax` | `30000` | Maximum time (ms) standing still before wandering |
| `Config.WanderMoveTimeMin` | `5000` | Minimum time (ms) spent moving |
| `Config.WanderMoveTimeMax` | `15000` | Maximum time (ms) spent moving |
| `Config.WanderCheckInterval` | `2000` | How often to update wander behavior (ms) |
| `Config.WanderPositionSaveInterval` | `30000` | How often (ms) a freely wandering animal's position is synced back to the database, so a script/server restart |
| `Config.WaterItem` | `'fullbucket'` | full water bucket used to refill water troughs (filled at a well pump, e.g. rsg-farming) |
| `Config.WaterReturnItem` | `'bucket'` | empty bucket given back when a full bucket runs out of uses (false to disable) |
| `Config.BucketUses` | `5` | uses a full bucket gets when filled at a well pump (each trough refill uses one) |
| `Config.WellPump` | `table` | Deployable well pump (same as rsg-farming): place it, fill empty buckets, pack it up later |
| `Config.FeedTroughItem` | `'feedtrough'` | item used to place a feed trough |
| `Config.FeedTroughModel` | ``p_feedtroughsml01x`` | prop model used for placed feed troughs |
| `Config.FeedTroughUses` | `100` | number of times a feed trough can be fed from before it is removed |
| `Config.FeedTroughFeedAmount` | `100` | hunger restored (up to 100) each time an animal feeds from a feed trough |
| `Config.FeedTroughHungerThreshold` | `10` | animals will only seek out a feed trough once hunger drops below this |
| `Config.FeedTroughSearchRadius` | `100.0` | radius (from an animal's position) to search for a usable feed trough |
| `Config.FeedTroughInteractDistance` | `2.0` | distance an animal must reach before it can feed from a feed trough |
| `Config.FeedTroughPlaceDistance` | `2.5` | distance in front of the player where a feed trough is placed |
| `Config.FeedTroughHeadingOffset` | `0.0` | degrees added to the stored heading when (re)spawning the prop, to correct for the model's default pivot facin |
| `Config.FeedBagItem` | `'feedbag'` | item used to refill a feed trough (consumed like the water bucket is for water troughs, minus the fill-up step |
| `Config.FeedTroughRefillPerBagUse` | `100` | uses added to a feed trough per feedbag consumed when refilling |
| `Config.FEEDTROUGH_ID_MIN` | `100000` |  |
| `Config.FEEDTROUGH_ID_MAX` | `999999` |  |
| `Config.WaterTroughItem` | `'watertrough'` | item used to place a water trough |
| `Config.WaterTroughModel` | ``p_watertrough01x`` | prop model used for placed water troughs |
| `Config.WaterTroughUses` | `100` | number of times a water trough can be drunk from before it runs dry |
| `Config.WaterTroughDrinkAmount` | `100` | thirst restored (up to 100) each time an animal drinks from a trough |
| `Config.WaterTroughThirstThreshold` | `10` | animals will only seek out a water trough once thirst drops below this |
| `Config.WaterTroughSearchRadius` | `100.0` | radius (from an animal's position) to search for a usable water trough |
| `Config.WaterTroughInteractDistance` | `2.0` | distance an animal must reach before it can drink from a water trough |
| `Config.WaterTroughPlaceDistance` | `2.5` | distance in front of the player where a water trough is placed |
| `Config.WaterTroughRefillPerBucketUse` | `100` | uses added to a trough per water bucket use consumed when refilling |
| `Config.WaterTroughHeadingOffset` | `0.0` | degrees added to the stored heading when (re)spawning the prop, to correct for the model's default pivot facin |
| `Config.WATERTROUGH_ID_MIN` | `100000` |  |
| `Config.WATERTROUGH_ID_MAX` | `999999` |  |
| `Config.ChickenCoopItem` | `'chickencoop'` | item used to place a chicken coop cart |
| `Config.ChickenCoopModel` | ``p_chickencoopcart01x`` | prop model used for placed chicken coops |
| `Config.ChickenModel` | ``A_C_Chicken_01`` | ped model spawned for each chicken owned by a coop |
| `Config.ChickenCoopPlaceDistance` | `2.5` | distance in front of the player where a chicken coop is placed |
| `Config.ChickenCoopInteractDistance` | `2.5` | distance a player must be within to interact with a chicken coop |
| `Config.ChickenBuyPrice` | `15` | cash cost to buy a single chicken for a coop |
| `Config.MaxChickensPerCoop` | `20` | maximum number of chickens a single coop can hold |
| `Config.ChickenWanderRadius` | `10.0` | maximum distance chicken peds will wander from their coop |
| `Config.ChickenWanderCheckInterval` | `4000` | ms between wander decisions per chicken |
| `Config.EggProductionInterval` | `1800` | seconds per egg production cycle (30 minutes) |
| `Config.EggsPerChickenPerCycle` | `1` | eggs produced per chicken, per production cycle, if it successfully lays |
| `Config.ChickenEggChance` | `0.75` | probability (0.0-1.0) that a given chicken lays eggs on a given production cycle |
| `Config.MaxEggsStored` | `100` | cap on eggs a coop can bank before it needs collecting |
| `Config.EggItem` | `'egg'` | item given to players when collecting eggs |
| `Config.ChickenCoopHeadingOffset` | `0.0` | degrees added to the stored heading when (re)spawning the coop prop, to correct for the model's default pivot  |
| `Config.CHICKENCOOP_ID_MIN` | `100000` |  |
| `Config.CHICKENCOOP_ID_MAX` | `999999` |  |
| `Config.ChickenCoopMaxFeedLevel` | `100` | feed level a coop starts at / tops out at |
| `Config.ChickenCoopFeedDecayInterval` | `2592` | seconds per feed decay cycle (43.2 minutes) |
| `Config.ChickenCoopFeedDecayAmount` | `1` | feed level lost per decay cycle - at the defaults (100 feed, 1 point every 2592s) a full coop takes exactly 3  |
| `Config.ChickenCoopFeedPerBag` | `100` | feed level restored per feed bag used to feed the coop |
| `Config.ChickenCoopFeedCronJob` | `'*/15 * * * *'` | how often the server checks coops for feed decay/starvation (every 15 minutes) - decay itself is time-based (s |
| `Config.HerdingEnabled` | `true` |  |
| `Config.HerdingDistance` | `25.0` | maximum distance to detect animals for herding |
| `Config.HerdingMaxAnimals` | `10` | maximum number of animals that can be herded at once |
| `Config.HerdingFollowDistance` | `3.0` | distance animals maintain while following during herding |
| `Config.HerdingSpeed` | `1.5` | movement speed when herding animals |
| `Config.HerdingTimeout` | `300` | seconds before herding automatically stops (5 minutes) |
| `Config.RequireHerdingTool` | `false` | set to true if you want to require a specific item to herd |
| `Config.HerdingTool` | `'weapon_lasso'` | item required for herding (if RequireHerdingTool is true) |
| `Config.IndividualSelectionEnabled` | `true` | enable individual animal selection for herding |
| `Config.ShowAnimalDistance` | `true` | show distance to animals in selection menu |
| `Config.SelectionRangeMultiplier` | `1.5` | multiplier for selection range vs herding distance |
| `Config.BullBuyPrice` | `100` |  |
| `Config.CowBuyPrice` | `50` |  |
| `Config.PigBuyPrice` | `40` |  |
| `Config.PigDeliveryOnly` | `true` | pigs can only be bought with delivery to the ranch, no drive-yourself pickup option |
| `Config.PigChooseGenderOnBuy` | `true` | let the buyer pick male/female when purchasing a pig, instead of it being randomized |
| `Config.SheepBuyPrice` | `35` |  |
| `Config.SheepDeliveryOnly` | `true` | sheep follow the same buy rules as pigs: delivery to the ranch only, no drive-yourself pickup option |
| `Config.SheepChooseGenderOnBuy` | `true` | let the buyer pick male/female when purchasing a sheep, instead of it being randomized |
| `Config.LivestockDeliveryPrice` | `10` | extra cost charged when the player pays to have a purchased animal delivered straight to their ranch spawnpoin |
| `Config.AnimalSpecies` | `table` |  |
| `Config.PigSlaughterYield` | `{ min = 2, max = 4 }` | joints of pork produced when a pig is sent for slaughter |
| `Config.PorkJointItem` | `'porkjoint'` | item given for each joint of pork produced |
| `Config.CowSlaughterYield` | `{ min = 3, max = 6 }` | joints of beef produced when a cow is sent for slaughter |
| `Config.BullSlaughterYield` | `{ min = 4, max = 8 }` | joints of beef produced when a bull is sent for slaughter |
| ... | | 70 more options in the config files |

### Exports

**Server**

| Export | Arguments | File |
|---|---|---|
| `isPlayerRanchStaff` | `playerId` | `server/exports.lua` |
| `getPlayerRanchId` | `playerId` | `server/exports.lua` |
| `getRanchAnimalCount` | `ranchid` | `server/exports.lua` |
| `getRanchAnimals` | `ranchid` | `server/exports.lua` |
| `getAnimalData` | `animalid` | `server/exports.lua` |
| `addAnimalToRanch` | `ranchid, model, gender, pos_x, pos_y, pos_z, pos_w` | `server/exports.lua` |
| `removeAnimalFromRanch` | `animalid` | `server/exports.lua` |
| `updateAnimalStats` | `animalid, stats` | `server/exports.lua` |
| `getStaffCount` | `ranchid` | `server/exports.lua` |
| `getRanchStatistics` | `ranchid` | `server/exports.lua` |
| `CreateAnimalId` | `` | `server/server.lua` |

**Client**

| Export | Arguments | File |
|---|---|---|
| `isLocalPlayerRanchStaff` | `` | `client/exports.lua` |
| `getLocalPlayerRanchId` | `` | `client/exports.lua` |
| `getRanchLocation` | `ranchid` | `client/exports.lua` |
| `getAllRanchLocations` | `` | `client/exports.lua` |
| `getAllSalePointLocations` | `` | `client/exports.lua` |
| `getAllBuyPointLocations` | `` | `client/exports.lua` |
| `getNearestRanch` | `` | `client/exports.lua` |
| `canInteractWithAnimal` | `animalid` | `client/exports.lua` |
| `getAnimalProductInfo` | `animalModel` | `client/exports.lua` |
| `getBreedingConfig` | `animalModel` | `client/exports.lua` |
| `getPlayerJobGrade` | `` | `client/exports.lua` |
| `hasPermission` | `permissionName` | `client/exports.lua` |
| `getNearestWaterSource` | `` | `client/exports.lua` |
| `isNearRanch` | `maxDistance` | `client/exports.lua` |
| `GetAnimalEntityById` | `` | `client/modules/animals.lua` |
| `GetAnimalDataCache` | `` | `client/modules/animals.lua` |
| `GetNearestFeedTrough` | `` | `client/modules/feedtrough.lua` |
| `StartPropPlacement` | `` | `client/modules/propplacer.lua` |
| `IsPropPlacementActive` | `` | `client/modules/propplacer.lua` |
| `GetNearestWaterTrough` | `` | `client/modules/watertroughs.lua` |

```lua
-- example
local result = exports['rsg-ranch']:isPlayerRanchStaff(playerId)
```

### Callbacks

| Callback | Side | Arguments | File |
|---|---|---|---|
| `rsg-ranch:client:requestConsent` | client | `cb, header, content, timeout` | `client/modules/ranchui.lua` |
| `rsg-ranch:server:getRanchSettings` | server | `` | `server/modules/admin.lua` |
| `rsg-ranch:admin:getOverview` | server | `src` | `server/modules/admin.lua` |
| `rsg-ranch:admin:getRanch` | server | `src, ranchid` | `server/modules/admin.lua` |
| `rsg-ranch:admin:createRanch` | server | `src, data` | `server/modules/admin.lua` |
| `rsg-ranch:admin:action` | server | `src, ranchid, kind, data` | `server/modules/admin.lua` |
| `rsg-ranch:admin:searchPlayers` | server | `src, query` | `server/modules/admin.lua` |
| `rsg-ranch:server:getSupplyOrders` | server | `source, cb, ranchid` | `server/modules/orders.lua` |
| `rsg-ranch:server:getPumps` | server | `` | `server/modules/wellpump.lua` |
| `rsg-ranch:server:placePump` | server | `source, coords, heading` | `server/modules/wellpump.lua` |
| `rsg-ranch:server:pumpPrecheck` | server | `source, action, pumpId` | `server/modules/wellpump.lua` |
| `rsg-ranch:server:fillBucket` | server | `source, pumpId` | `server/modules/wellpump.lua` |
| `rsg-ranch:server:packPump` | server | `source, pumpId` | `server/modules/wellpump.lua` |
| `rsg-ranch:server:getranchstorages` | server | `source, cb, ranchid` | `server/server.lua` |
| `rsg-ranch:server:getChickenCoopStatus` | server | `source, cb, coopid` | `server/server.lua` |
| `rsg-ranch:server:countanimals` | server | `src, cb, ranchid` | `server/server.lua` |
| `rsg-ranch:server:getAnimalProductionStatus` | server | `src, cb, animalid` | `server/server.lua` |
| `rsg-ranch:server:getAnimalOverview` | server | `src, cb, ranchid` | `server/server.lua` |
| `rsg-ranch:server:getBreedingStatus` | server | `src, cb, animalid` | `server/server.lua` |
| `rsg-ranch:server:getPregnancyProgress` | server | `src, cb, animalid` | `server/server.lua` |
| `rsg-ranch:server:getAvailableAnimalsForBreeding` | server | `src, cb, ranchid, animalid` | `server/server.lua` |
| `rsg-ranch:server:getNearbyAnimalsForSale` | server | `src, cb, ranchid, salePointCoords` | `server/server.lua` |
| `rsg-ranch:server:getranchowner` | server | `source, cb, ranchid` | `server/server.lua` |
| `rsg-ranch:server:getRanchSellQuote` | server | `source, cb, ranchid` | `server/server.lua` |
| `rsg-ranch:server:getStaffList` | server | `source, cb, ranchid` | `server/server.lua` |
| `rsg-ranch:server:getNearbyPlayers` | server | `src, cb` | `server/server.lua` |
| `rsg-ranch:server:getRanchMarket` | server | `src, cb, ranchid` | `server/server.lua` |

```lua
-- client side
RSGCore.Functions.TriggerCallback('rsg-ranch:client:requestConsent', function(result)
    -- use result
end)
```

### Events

Server events can be fired by any client, so every handler re-validates the player, the arguments and any permission, distance or cooldown on the server. Never add a reward to a handler without those checks.

| Event | Side | Arguments | File |
|---|---|---|---|
| `rsg-ranch:client:applyRanchSettings` | client | `settings` | `client/client.lua` |
| `rsg-ranch:client:openranch` | client | `ranchid, jobaccess` | `client/client.lua` |
| `rsg-ranch:client:openAdmin` | client | `` | `client/modules/admin.lua` |
| `rsg-ranch:client:forceRespawnAnimal` | client | `animalId` | `client/modules/animals.lua` |
| `RSGCore:Client:OnPlayerLoaded` | client | `` | `client/modules/animals.lua` |
| `rsg-ranch:client:spawnAnimals` | client | `animalData, isFullList` | `client/modules/animals.lua` |
| `rsg-ranch:client:spawnAnimalGranted` | client | `animalId, animalData, networkId, isCreator` | `client/modules/animals.lua` |
| `rsg-ranch:client:spawnAnimalDenied` | client | `animalId, reason` | `client/modules/animals.lua` |
| `rsg-ranch:client:removeAnimal` | client | `animalid` | `client/modules/animals.lua` |
| `rsg-ranch:client:refreshSingleAnimal` | client | `animalid, updatedData` | `client/modules/animals.lua` |
| `rsg-ranch:client:refreshAnimalsBatch` | client | `updates` | `client/modules/animals.lua` |
| `rsg-ranch:client:setAnimalTransporting` | client | `animalIds, transporting` | `client/modules/animals.lua` |
| `rsg-ranch:client:animalmenu` | client | `animal, data` | `client/modules/animals.lua` |
| `rsg-ranch:client:actionsmenu` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:animalsendfeed` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:animalsendwater` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:animalfollow` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:checkProducts` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:collectProduct` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:findBreedingPartner` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:confirmBreeding` | client | `data` | `client/modules/animals.lua` |
| `rsg-ranch:client:startChickenCoopPlacement` | client | `` | `client/modules/chickencoop.lua` |
| `rsg-ranch:client:spawnChickenCoops` | client | `coopList` | `client/modules/chickencoop.lua` |
| `rsg-ranch:client:spawnChickenCoop` | client | `data` | `client/modules/chickencoop.lua` |
| `rsg-ranch:client:removeChickenCoop` | client | `coopid` | `client/modules/chickencoop.lua` |
| `rsg-ranch:client:updateChickenCoop` | client | `coopid, chickens` | `client/modules/chickencoop.lua` |
| `rsg-ranch:client:startFeedTroughPlacement` | client | `` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:startFeedTroughMove` | client | `feedtroughid` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:moveFeedTrough` | client | `feedtroughid, pos_x, pos_y, pos_z, pos_w` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:spawnFeedTroughs` | client | `feedtroughList` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:spawnFeedTrough` | client | `data` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:removeFeedTrough` | client | `feedtroughid` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:updateFeedTroughUses` | client | `feedtroughid, uses` | `client/modules/feedtrough.lua` |
| `rsg-ranch:client:openHerdingMenu` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:showTypeMenu` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:showIndividualSelectionMenu` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:toggleAnimalSelection` | client | `data` | `client/modules/herding.lua` |
| `rsg-ranch:client:clearAnimalSelection` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:startSelectedHerding` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:startDistanceHerding` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:startTypeHerding` | client | `data` | `client/modules/herding.lua` |
| `rsg-ranch:client:stopHerding` | client | `` | `client/modules/herding.lua` |
| `rsg-ranch:client:openmanagermenu` | client | `ranchid` | `client/modules/ranchui.lua` |
| `rsg-ranch:client:openranchhandmenu` | client | `ranchid` | `client/modules/ranchui.lua` |
| `rsg-ranch:client:opentraineemenu` | client | `ranchid` | `client/modules/ranchui.lua` |
| `rsg-ranch:client:openpurchasemenu` | client | `ranchid` | `client/modules/ranchui.lua` |
| `rsg-ranch:client:openSaleMenu` | client | `salePointData` | `client/modules/salepoint.lua` |
| `rsg-ranch:client:startWaterTroughPlacement` | client | `` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:startWaterTroughMove` | client | `watertroughid` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:moveWaterTrough` | client | `watertroughid, pos_x, pos_y, pos_z, pos_w` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:spawnWaterTroughs` | client | `watertroughList` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:spawnWaterTrough` | client | `data` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:removeWaterTrough` | client | `watertroughid` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:updateWaterTroughUses` | client | `watertroughid, uses` | `client/modules/watertroughs.lua` |
| `rsg-ranch:client:syncPumps` | client | `` | `client/modules/wellpump.lua` |
| `rsg-ranch:client:placePump` | client | `` | `client/modules/wellpump.lua` |
| `rsg-ranch:server:placeSupplyOrder` | server | `itemName, amount` | `server/modules/orders.lua` |
| `rsg-ranch:server:collectSupplyOrder` | server | `orderid` | `server/modules/orders.lua` |
| `rsg-ranch:server:openranchstorage` | server | `data` | `server/server.lua` |
| `rsg-ranch:server:purchaseranchstorage` | server | `data` | `server/server.lua` |
| `rsg-ranch:server:renameranchstorage` | server | `data` | `server/server.lua` |
| `rsg-ranch:server:setstorageaccess` | server | `data` | `server/server.lua` |
| `rsg-ranch:server:placeFeedTrough` | server | `pos_x, pos_y, pos_z, pos_w` | `server/server.lua` |
| `rsg-ranch:server:refreshFeedTroughs` | server | `` | `server/server.lua` |
| `rsg-ranch:server:refillFeedTrough` | server | `feedtroughid` | `server/server.lua` |
| `rsg-ranch:server:requestMoveFeedTrough` | server | `feedtroughid` | `server/server.lua` |
| `rsg-ranch:server:confirmMoveFeedTrough` | server | `feedtroughid, pos_x, pos_y, pos_z, pos_w` | `server/server.lua` |
| `rsg-ranch:server:deleteFeedTrough` | server | `feedtroughid` | `server/server.lua` |
| `rsg-ranch:server:placeWaterTrough` | server | `pos_x, pos_y, pos_z, pos_w` | `server/server.lua` |
| `rsg-ranch:server:refreshWaterTroughs` | server | `` | `server/server.lua` |
| `rsg-ranch:server:refillWaterTrough` | server | `watertroughid` | `server/server.lua` |
| `rsg-ranch:server:requestMoveWaterTrough` | server | `watertroughid` | `server/server.lua` |
| `rsg-ranch:server:confirmMoveWaterTrough` | server | `watertroughid, pos_x, pos_y, pos_z, pos_w` | `server/server.lua` |
| `rsg-ranch:server:deleteWaterTrough` | server | `watertroughid` | `server/server.lua` |
| `rsg-ranch:server:placeChickenCoop` | server | `pos_x, pos_y, pos_z, pos_w` | `server/server.lua` |
| `rsg-ranch:server:refreshChickenCoops` | server | `` | `server/server.lua` |
| `rsg-ranch:server:buyChicken` | server | `coopid` | `server/server.lua` |
| `rsg-ranch:server:collectEggs` | server | `coopid` | `server/server.lua` |
| `rsg-ranch:server:deleteChickenCoop` | server | `coopid` | `server/server.lua` |
| `rsg-ranch:server:feedChickenCoop` | server | `coopid` | `server/server.lua` |
| `rsg-ranch:server:requestAnimalSpawn` | server | `animalId, animalData` | `server/server.lua` |
| `rsg-ranch:server:registerAnimalNetworkId` | server | `animalId, networkId` | `server/server.lua` |
| `rsg-ranch:server:refreshAnimals` | server | `` | `server/server.lua` |
| `rsg-ranch:server:saveAnimalPosition` | server | `animalid, pos_x, pos_y, pos_z, pos_w` | `server/server.lua` |
| `rsg-ranch:server:respawnAnimal` | server | `animalId` | `server/server.lua` |
| `rsg-ranch:server:reportDespawn` | server | `animalId` | `server/server.lua` |
| `rsg-ranch:server:collectProduct` | server | `animalid` | `server/server.lua` |
| `rsg-ranch:server:sendAnimalToFeed` | server | `animalid, feedtroughid` | `server/server.lua` |
| `rsg-ranch:server:sendAnimalToWater` | server | `animalid, watertroughid` | `server/server.lua` |
| `rsg-ranch:server:sellAnimal` | server | `animalid` | `server/server.lua` |
| `rsg-ranch:server:sellAllAnimals` | server | `animalIds` | `server/server.lua` |
| `rsg-ranch:server:buyAnimal` | server | `purchaseData` | `server/server.lua` |
| `rsg-ranch:server:purchaseRanch` | server | `ranchid` | `server/server.lua` |
| `rsg-ranch:server:transferRanchOwnership` | server | `ranchid, targetId` | `server/server.lua` |
| `rsg-ranch:server:sellRanch` | server | `ranchid` | `server/server.lua` |
| `rsg-ranch:server:startBreeding` | server | `animal1id, animal2id` | `server/server.lua` |
| `rsg-ranch:server:hireEmployee` | server | `ranchid, targetId, grade` | `server/server.lua` |
| `rsg-ranch:server:fireEmployee` | server | `ranchid, targetCitizenid` | `server/server.lua` |
| `rsg-ranch:server:promoteEmployee` | server | `ranchid, targetCitizenid` | `server/server.lua` |
| `rsg-ranch:server:demoteEmployee` | server | `ranchid, targetCitizenid` | `server/server.lua` |
| `rsg-ranch:server:sellAtRanch` | server | `animalid` | `server/server.lua` |
| `rsg-ranch:server:slaughterAtRanch` | server | `animalid` | `server/server.lua` |

```lua
-- from a client script
TriggerServerEvent('rsg-ranch:server:placeSupplyOrder', itemName, amount)
-- from a server script
TriggerClientEvent('rsg-ranch:client:applyRanchSettings', source, settings)
```

### Commands

| Command | Notes | File |
|---|---|---|
| `/cleanupranchanimals` |  | `client/modules/animals.lua` |
| `/testproduction` |  | `client/modules/animals.lua` |
| `/validatemenu` |  | `client/modules/animals.lua` |
| `/herd` |  | `client/modules/herding.lua` |
| `/herdselectstatus` |  | `client/modules/herding.lua` |
| `/herdclear` |  | `client/modules/herding.lua` |

### Locales

Language files in `locales/`: `de`, `el`, `en`, `es`, `fr`, `ja`, `nl`, `pl`, `pt-br`, `ro`, `ru`. Set the language with `setr rsg:locale "en"`.

<!-- END AUTO-REFERENCE -->
