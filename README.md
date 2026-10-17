# rsg-ranch

A complete livestock ranching system for **RedM** servers running the **RSG Framework**. Buy a ranch, hire staff, raise cattle, pigs, sheep and chickens, keep them fed and watered, breed them, collect their produce, and sell or slaughter them for profit, all managed from an in-game ranch menu.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rexshack)

---

## Features

### Ranch ownership
- Six purchasable ranches out of the box (Macfarlane, Emerald, Pronghorn, Downes, Hill Haven, Hanging Dog). Add more in the config, or create them in game from the admin panel.
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

5. **Jobs.** Job definitions live in rsg-multijob's database (`multijob_jobs`). Each ranch needs a job with the same name as its `ranchid`; `installation/shared_jobs.lua` has the six default ranch jobs to add there (or to `rsg-core/shared/jobs.lua` on older setups). Ranches created in the admin panel register their own job automatically. Every ranch job has three grades:

   | Grade | Name | Can do |
   |---|---|---|
   | 0 | Trainee Rancher | Care for animals, view the herd |
   | 1 | Ranch Hand | Plus storage, market, supplies, herding, breeding and collecting produce |
   | 2 | Ranch Manager (boss) | Plus buying and selling livestock, staff management and the ranch tab |

   What each grade may do is set in `Config.StaffManagement.Permissions` and enforced on the server.

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
| **Staff** | `Config.StaffManagement` (min grade to manage, max employees, per-grade `Permissions`: `canSell`, `canBuy`, `canBreed`, `canCollectProducts`) |
| **Admin panel** | `Config.Admin` (command, permission groups, ACE, console logging) |
| **Supplies** | `Config.OrderSupplies` (catalogue, prices, delivery times, limits) |
| **Wandering and blips** | `Config.AnimalWanderingEnabled`, `Config.WanderRadius`, `Config.AnimalBlipsEnabled` |
| **Ambient clear** | `Config.RanchAmbientClear` (radius, intervals, per-ranch overrides) |

**Adding a ranch:** the easiest way is **+ New Ranch** in `/ranchadmin` (see below). To add one by hand instead, add an entry to `Config.RanchLocations` with a unique `ranchid`, add a matching job (same name as the `ranchid`), then restart.

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
| `/ranchadmin` | Open the ranch admin panel (admins only) |

---

## Ranch admin panel

Admin staff manage every ranch from one panel with **`/ranchadmin`**. Access is set in `Config.Admin`: any rsg-core permission group in `Permissions` (default `admin`, `god`), or anyone with the `command.ranchadmin` ACE.

The left side lists every ranch with its owner and counts, and can be searched by ranch name, id or owner. Wherever a player is needed (owner, new staff) you search the `players` table by name or citizen ID and pick from the results; online players are listed first with their server ID.

| Tab | What admins can do |
|---|---|
| Ownership | See the owner, assign or transfer ownership (online or offline players), remove the owner (ranch goes back on sale, assets kept), teleport to the animal spawn, or fully reset the ranch with no refund |
| Staff | Hire at any grade, change grades, fire one or all (online and offline, rsg-multijob kept in sync) |
| Livestock | Filter the herd, edit health / hunger / thirst / age / product ready, teleport to an animal, delete one or all, heal and feed everything |
| Troughs & Coops | Set trough uses, edit coop chickens / eggs / feed, teleport to or delete any of them |
| Storage | Add free storages, edit label / slots / weight / minimum grade, empty a stash, delete extra storages |
| Orders | Make a supply order ready immediately, or delete it |
| Settings | Override display name, blip name, blip visibility and purchase price. Saved to `rsg_ranch_settings`, applied live for everyone and kept across restarts. "Reset to Config" drops the override |

### Creating a ranch in game
1. Stand where the ranch NPC should be, facing the way it should face.
2. In `/ranchadmin`, click **+ New Ranch**, enter a name and price (the ranch ID / job name is filled in from the name) and click **Create Ranch**.
3. The NPC and blip appear straight away for everyone and the ranch goes on sale. The animal spawn point starts 10 m in front of you.

Panel-created ranches are marked ★. Their Ownership tab adds **Set NPC here**, **Set animal spawn here** and **Delete Ranch** (removes the ranch, everything on it, its staff and its job). They're stored in `rsg_ranch_custom` and load back after a restart. The six config ranches can't be moved or deleted from the panel.

> rsg-multijob only reads job definitions when it starts, so a new ranch's job appears in players' multijob lists after `ensure rsg-multijob` or the next server restart. Assigning the job works immediately.

Every admin action is re-checked on the server and printed to the server console when `Config.Admin.Log = true`.

---

## Support

If you enjoy this script and want to support its development:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rexshack)

☕ **https://buymeacoffee.com/rexshack**
