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
