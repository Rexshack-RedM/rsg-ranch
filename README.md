# rsg-ranch

A complete livestock ranching system for **RedM** servers running the **RSG Framework**. Buy a ranch, hire staff, raise cattle, pigs, sheep and chickens, keep them fed and watered, breed them, collect their produce, and sell or slaughter them for profit, all managed from an in-game ranch menu.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rexshack)

---

## Features

### Ranch ownership
- Six purchasable ranches out of the box (Macfarlane, Emerald, Pronghorn, Downes, Hill Haven, Hanging Dog). Add or remove them in the config.
- Buy an unowned ranch from its ranch NPC and become its boss.
- Hand the ranch to another nearby player (they must accept), or sell it back for a configurable refund.
- One ranch per character.

### Ranch management menu
A full NUI dashboard opened at the ranch NPC, with tabs for:
- **Herd:** every animal with its health, hunger, thirst, age, breeding and product status. You can filter it (pregnant, ready to breed, needs care…).
- **Storage:** a free general storage plus extra storages you can buy (small, medium, large). The boss can rename them and restrict who can open each one.
- **Market:** sell pigs, cows and sheep for cash, or slaughter them for joints of meat, right at the ranch.
- **Supplies:** order troughs, coops, feed bags, buckets and well pumps. They're ready to collect after a delivery time.
- **Staff:** hire nearby players (they must accept), and promote, demote or fire them. Offline staff are included.
- **Ranch:** transfer or sell the ranch.
- **Guide:** a built-in how-to for new ranchers.

### Livestock
- Bulls, cows, pigs and sheep, bought from Livestock Dealers. Animals are either spawned at the dealer for you to herd home, or delivered straight to your ranch for a fee.
- You can choose the gender when buying pigs and sheep.
- Hunger, thirst, health and ageing are handled server-side on a timer, so animals keep living while players are offline.
- Animals wander naturally around the ranch and remember where they were after a restart.
- Map blips for your own ranch's animals, coloured by health.

### Feeding and watering
- Place **feed troughs** and **water troughs** anywhere on the ranch. Animals feed and drink from them automatically when they get hungry or thirsty.
- Refill feed troughs with **feed bags** and water troughs with a **full water bucket**.
- Move or remove troughs at any time.
- Deployable **well pumps** for filling empty buckets.
- You can also send an individual animal to the nearest trough from its action menu.

### Breeding and produce
- A healthy male and female of the same species can breed, with gender-specific cooldowns and a gestation period.
- Offspring are born automatically when the time is up.
- Optional automatic breeding between nearby animals.
- Animals produce goods over time while healthy: cows give milk, sheep give wool, and bulls and pigs give fertiliser.

### Chickens
- Place a **chicken coop**, buy chickens for it, and collect eggs.
- Coops need feeding with feed bags. Leave them unfed too long and the chickens starve.

### Herding and selling
- `/herd` opens the herding menu. You can herd by distance, by animal type, or pick individual animals.
- Herd cattle to a **Livestock Market** sale point to sell them, one at a time or all at once.
- Prices depend on age: young, prime, adult or old. Prime-age animals fetch the most.

### Also included
- Clears ambient NPCs and wildlife from ranches so your own herd isn't mixed with game animals.
- Fully translatable through ox_lib locales. It ships with **English, German, Greek, Spanish, French, Japanese, Dutch, Polish, Brazilian Portuguese and Romanian**.
- Every purchase, sale, payout and item change is validated on the server.

---

## Dependencies

| Resource | Notes |
|---|---|
| [rsg-core](https://github.com/Rexshack-RedM/rsg-core) | Framework |
| [rsg-inventory](https://github.com/Rexshack-RedM/rsg-inventory) | Items and stashes |
| [rsg-multijob](https://github.com/Rexshack-RedM/rsg-multijob) | Ranch jobs alongside other jobs |
| [ox_lib](https://github.com/overextended/ox_lib) | Locales, callbacks, notifications, cron |
| [ox_target](https://github.com/overextended/ox_target) | NPC, animal and prop interactions |
| [oxmysql](https://github.com/overextended/oxmysql) | Database |

---

## Installation

1. **Add the resource.** Put the `rsg-ranch` folder in your resources folder, then add it to `server.cfg` after its dependencies:
   ```cfg
   ensure ox_lib
   ensure oxmysql
   ensure ox_target
   ensure rsg-core
   ensure rsg-inventory
   ensure rsg-multijob
   ensure rsg-ranch
   ```

2. **Database.** The tables are created automatically the first time the resource starts. If you'd rather do it yourself, import `installation/rsg-ranch.sql`.

3. **Items.** Copy the entries from `installation/shared_items.lua` into `rsg-core/shared/items.lua`. The script also uses these items, which most RSG servers already have. Add any that are missing:
   `bucket`, `fullbucket`, `milk`, `egg`, `fertilizer`.

4. **Images.** Add a PNG for each new item to `rsg-inventory/html/images/`, named after the item (for example `feedtrough.png`). The ranch menu uses these images too.

5. **Jobs.** Copy the jobs from `installation/shared_jobs.lua` into `rsg-core/shared/jobs.lua`. Every ranch job has three grades:

   | Grade | Name | Can do |
   |---|---|---|
   | 0 | Trainee Rancher | Care for animals, view the herd |
   | 1 | Ranch Hand | Plus storage, market, supplies, herding and selling |
   | 2 | Ranch Manager (boss) | Plus staff management and the ranch tab |

6. **Language** (optional). Set your language in `server.cfg`:
   ```cfg
   setr ox:locale "en"   # en, de, el, es, fr, ja, nl, pl, pt-br, ro
   ```

7. Restart the server.

---

## Configuration

Everything is in `shared/config.lua`, and each option has a comment explaining it. These are the main sections:

| Section | Key options |
|---|---|
| **General** | `Config.Debug`, `Config.ServerNotify`, `Config.MaxRanchAnimals` |
| **Ranches** | `Config.RanchLocations` (name, NPC, blip, spawnpoint, price), `Config.RanchBossGrade`, `Config.RanchSellRefundPercentage`, `Config.RanchMenuDistance`, `Config.RanchConsentTimeout` |
| **Storage** | `Config.RanchStorageSizes`, `Config.MaxAdditionalStorages`, `Config.RanchStorageAccessLevels`, `Config.StorageMinJobGrade` |
| **Survival** | `Config.AnimalCronJob`, `Config.AnimalFeedWaterCronJob`, `Config.HungerDecayRate`, `Config.ThirstDecayRate`, `Config.HealthDecayRate`, `Config.HealthRegenerationRate` |
| **Troughs** | `Config.FeedTroughUses`, `Config.FeedTroughRefillPerBagUse`, `Config.FeedTroughHungerThreshold`, the matching `Config.WaterTrough*` options, `Config.BucketUses` |
| **Well pump** | `Config.WellPump` (items, timings, max per player, owner-only packing) |
| **Chickens** | `Config.ChickenBuyPrice`, `Config.MaxChickensPerCoop`, `Config.EggProductionInterval`, `Config.ChickenEggChance`, `Config.ChickenCoopFeedDecayInterval` |
| **Buying** | `Config.BullBuyPrice` / `CowBuyPrice` / `PigBuyPrice` / `SheepBuyPrice`, `Config.LivestockDeliveryPrice`, `Config.PigDeliveryOnly`, `Config.PigChooseGenderOnBuy`, `Config.BuyPointLocations` |
| **Selling** | `Config.BaseSellPrices`, `Config.AgePricing`, `Config.MinAgeToSell`, `Config.PrimeAgeStart` / `PrimeAgeEnd` / `OldAgeStart`, `Config.SalePointLocations`, `Config.RequireAnimalPresent` |
| **Slaughter** | `Config.PigSlaughterYield`, `Config.CowSlaughterYield`, `Config.SheepSlaughterYield` and the joint item names |
| **Breeding** | `Config.BreedingEnabled`, `Config.BreedingConfig`, `Config.GenderSpecificCooldowns`, `Config.MinAgeForBreeding`, health/hunger/thirst requirements, automatic breeding options |
| **Produce** | `Config.AnimalProducts` (item, amount, production time and requirements per animal) |
| **Herding** | `Config.HerdingEnabled`, `Config.HerdingDistance`, `Config.HerdingMaxAnimals`, `Config.HerdingTimeout`, `Config.RequireHerdingTool` |
| **Staff** | `Config.StaffManagement` (min grade to manage, max employees) |
| **Supplies** | `Config.OrderSupplies` (catalogue, prices, delivery times, limits) |
| **Wandering and blips** | `Config.AnimalWanderingEnabled`, `Config.WanderRadius`, `Config.AnimalBlipsEnabled` |
| **Ambient clear** | `Config.RanchAmbientClear` (radius, intervals, per-ranch overrides) |

**Adding a ranch:** add an entry to `Config.RanchLocations` with a unique `ranchid`, add a matching job (same name as the `ranchid`) to `rsg-core/shared/jobs.lua`, then restart.

**Translations:** all text lives in `locales/*.json`. Edit those files to change any wording, or copy `en.json` to add a new language.

---

## How to use

### Getting started
1. Go to a ranch (look for the herd blip) and talk to the ranch NPC.
2. If the ranch is unowned, you'll see the **For Sale** screen. Buy it to become the boss.
3. Talk to the NPC again at any time to open the ranch menu.

### Getting animals
1. Visit a **Livestock Dealer** and choose an animal.
2. Choose **Drive It Yourself** (free; the animal spawns at the dealer) or **Pay for Delivery** (it appears at your ranch). Pigs and sheep are delivery-only by default.
3. If you picked it up yourself, lead it home with **Follow** in the animal's menu, or use `/herd`.

### Day-to-day care
- Order **feed troughs**, **water troughs** and **feed bags** from the Supplies tab, then use the items to place them. Rotate with the arrow keys, confirm with **E** and cancel with **Backspace**.
- Keep troughs topped up. Look at a trough to refill, move or remove it.
- Fill buckets at a **well pump** (place one with the `ranch_wellpump` item), then use the full bucket on a water trough.
- Look at an animal to check its stats, make it follow you, send it to a trough, collect its produce, or find a breeding partner.

### Chickens
Place a **chicken coop**, buy chickens from it, feed it with feed bags, and collect eggs when they're ready.

### Selling
- **Cattle:** herd them to a **Livestock Market**, talk to the dealer, and sell one animal or the whole herd that's present.
- **Pigs, cows and sheep:** use the **Market** tab in the ranch menu to sell for cash or slaughter for meat.
- Prime-age animals sell for the highest price.

### Staff (boss)
Open the **Staff** tab to hire a nearby player (they get an accept/decline prompt), or to promote, demote or fire staff.

### Commands
| Command | Description |
|---|---|
| `/herd` | Open the herding menu (Ranch Hand and above) |
| `/herdselectstatus` | Show how many animals you have selected for herding |
| `/herdclear` | Clear your herding selection |
| `/cleanupranchanimals` | Respawn your local ranch animals if any get stuck or duplicated |

---

## Support

If you enjoy this script and want to support its development:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rexshack)

☕ **https://buymeacoffee.com/rexshack**
