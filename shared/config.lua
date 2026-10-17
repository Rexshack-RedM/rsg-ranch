Config = {}
lib.locale() -- labels below are translated through locales/*.json

---------------------------------
-- debug settings
---------------------------------
Config.Debug = false

---------------------------------
-- animal id settings
---------------------------------
Config.ANIMAL_ID_MIN = 100000
Config.ANIMAL_ID_MAX = 999999
Config.FALLBACK_ID_SUFFIX_MIN = 1000
Config.FALLBACK_ID_SUFFIX_MAX = 9999
Config.MAX_ID_LENGTH = 20

---------------------------------
-- npc settings
---------------------------------
Config.DistanceSpawn = 50.0
Config.FadeIn = true

---------------------------------
-- ranch settings
---------------------------------
Config.StorageMinJobGrade = 1
Config.RanchStorageMaxWeight = 10000000
Config.RanchStorageMaxSlots = 100

---------------------------------
-- ranch storage expansion settings
---------------------------------
-- Every ranch comes with one free 'general' storage (sized above via
-- Config.RanchStorageMaxWeight / Config.RanchStorageMaxSlots). The boss can
-- unlock additional storages of these sizes for a one-time cash cost. Each
-- additional storage is its own separate stash and can be renamed by the boss.
Config.RanchStorageSizes = {
    small = {
        label = locale('cfg_storage_small'),
        price = 3000,
        slots = 25,
        maxweight = 2500000,
    },
    medium = {
        label = locale('cfg_storage_medium'),
        price = 6000,
        slots = 50,
        maxweight = 5000000,
    },
    large = {
        label = locale('cfg_storage_large'),
        price = 10000,
        slots = 100,
        maxweight = 10000000,
    },
}

-- Maximum number of ADDITIONAL storages (not counting the free general one)
-- a single ranch can purchase. Set to 0 for unlimited.
Config.MaxAdditionalStorages = 5

-- Access levels the boss can restrict a purchased storage to. 'grade' must
-- match a job grade level from installation/shared_jobs.lua (0 = Trainee
-- Rancher, 1 = Ranch Hand, 2 = Ranch Manager/boss on every ranch job).
-- Shown to the boss in the order listed here.
Config.RanchStorageAccessLevels = {
    { grade = 0, label = locale('cfg_access_everyone') },
    { grade = 1, label = locale('cfg_access_hands') },
    { grade = 2, label = locale('cfg_access_boss') },
}
Config.AnimalDistanceSpawn = 50.0
Config.AnimalFadeIn = true
Config.ServerNotify = true
Config.AnimalCronJob = '*/15 * * * *' -- every 15 minutes
Config.AnimalFeedWaterCronJob = '*/15 * * * *' -- how often troughs feed/water animals (separate from the main survival cronjob above, so you can tune feed/water consumption rate without touching health decay/regen, breeding or production timing)
Config.MaxRanchAnimals = 10
Config.UpdateClientsOnCron = true -- Update client animal data when cronjob runs
Config.RefreshAfterCron = true -- Full refresh of animal data after cronjob completion

---------------------------------
-- animal map blips (ranch staff only)
---------------------------------
-- Each animal gets its own map blip, attached to its entity so it moves as the animal
-- wanders. Every client decides for itself whether to show a given animal's blip, based
-- on whether the local player currently works at that specific ranch - so only that
-- ranch's own staff ever see its animals on the map, never other players or other ranches.
Config.AnimalBlipsEnabled = true
Config.AnimalBlipSprite = 'blip_ambient_companion' -- RDR3 blip sprite name used for animal blips
Config.AnimalBlipScale = 0.15
Config.AnimalBlipRefreshInterval = 5000 -- how often (ms) to re-check job/staff status and add/remove blips accordingly

---------------------------------
-- animal management settings
---------------------------------
Config.HungerDecayRate = 1 -- hunger reduction per cronjob run
Config.ThirstDecayRate = 1 -- thirst reduction per cronjob run
Config.HealthDecayRate = 1 -- health reduction per cronjob run when starving/dehydrated
Config.MinSurvivalStats = 0 -- minimum hunger/thirst before health starts decaying
Config.HealthRegenerationRate = 5 -- health regeneration per cronjob run when well-fed and watered
Config.MinStatsForRegeneration = 80 -- minimum hunger/thirst required for health regeneration
Config.ImmediateHealthBoost = 5 -- immediate health boost when feeding/watering an unhealthy animal

-- Automatic ranch feeding/watering: as long as a ranch has at least one feed/water
-- trough with uses remaining, its animals are fed/watered passively every cronjob run
-- (no more manually walking animals to a trough). Each animal fed/watered this way
-- consumes 1 use from its ranch's shared trough pool per cronjob run.
Config.AutoFeedRestoreAmount = 100 -- hunger restored per cronjob run while the ranch has an active feed trough
Config.AutoWaterRestoreAmount = 100 -- thirst restored per cronjob run while the ranch has an active water trough

---------------------------------
-- animal wandering settings
---------------------------------
Config.AnimalWanderingEnabled = true -- Enable animals to wander naturally
Config.WanderRadius = 30.0 -- Maximum distance animals can wander from spawn point
Config.WanderMinDistance = 3.0 -- Minimum distance for a wander movement
Config.WanderSpeed = 1.0 -- Movement speed while wandering (1.0 = walk, 2.0 = jog)
Config.WanderIdleTimeMin = 10000 -- Minimum time (ms) standing still before wandering
Config.WanderIdleTimeMax = 30000 -- Maximum time (ms) standing still before wandering
Config.WanderMoveTimeMin = 5000 -- Minimum time (ms) spent moving
Config.WanderMoveTimeMax = 15000 -- Maximum time (ms) spent moving
Config.WanderCheckInterval = 2000 -- How often to update wander behavior (ms)
Config.WanderPositionSaveInterval = 30000 -- How often (ms) a freely wandering animal's position is synced back to the database, so a script/server restart resumes it near where it actually wandered to instead of snapping back to its spawn point

---------------------------------
-- keybinds (prop placement)
---------------------------------
Config.Keybinds = {
    PlaceConfirm = 'ENTER', -- confirm placement (looked up via RSGCore.Shared.Keybinds)
    PlaceCancel = 'BACKSPACE', -- cancel placement (looked up via RSGCore.Shared.Keybinds)
    RotateLeft = 174, -- INPUT_FRONTEND_LEFT (Left Arrow / DPad Left) - rotate prop left while placing
    RotateRight = 175, -- INPUT_FRONTEND_RIGHT (Right Arrow / DPad Right) - rotate prop right while placing
}
Config.PlacementRotationStep = 5.0 -- degrees to rotate the prop per key press while placing

---------------------------------
-- animal feed/water settings
---------------------------------
Config.WaterItem = 'fullbucket' -- full water bucket used to refill water troughs (filled at a well pump, e.g. rsg-farming)
Config.WaterReturnItem = 'bucket' -- empty bucket given back when a full bucket runs out of uses (false to disable)
Config.BucketUses = 5 -- uses a full bucket gets when filled at a well pump (each trough refill uses one)

-- Deployable well pump (same as rsg-farming): place it, fill empty buckets, pack it up later
Config.WellPump = {
    item             = 'ranch_wellpump',     -- usable item that places the pump (own name so it doesn't clash with rsg-farming's tool_wellpump)
    prop             = 'p_wellpumpnbx01x',
    emptyItem        = 'bucket',             -- required to fill
    fullItem         = 'fullbucket',         -- given after filling (Config.BucketUses uses)
    fillTime         = 6000,                 -- ms
    packTime         = 4000,                 -- ms
    fillScenario     = 'WORLD_HUMAN_BUCKET_FILL',
    packScenario     = 'WORLD_HUMAN_CROUCH_INSPECT',
    maxPerPlayer     = 2,
    minDistance      = 2.0,                  -- min distance between two pumps
    interactDist     = 2.0,
    placeMaxDistance = 6.0,                  -- how far from the player the gizmo can place
    renderDistance   = 60.0,                 -- prop spawn / despawn distance
    ownerOnlyPackup  = true,                 -- only the placer can pack it up
}

---------------------------------
-- feed trough settings (animal feeding)
---------------------------------
Config.FeedTroughItem = 'feedtrough' -- item used to place a feed trough
Config.FeedTroughModel = `p_feedtroughsml01x` -- prop model used for placed feed troughs
Config.FeedTroughUses = 100 -- number of times a feed trough can be fed from before it is removed
Config.FeedTroughFeedAmount = 100 -- hunger restored (up to 100) each time an animal feeds from a feed trough
Config.FeedTroughHungerThreshold = 10 -- animals will only seek out a feed trough once hunger drops below this
Config.FeedTroughSearchRadius = 100.0 -- radius (from an animal's position) to search for a usable feed trough
Config.FeedTroughInteractDistance = 2.0 -- distance an animal must reach before it can feed from a feed trough
Config.FeedTroughPlaceDistance = 2.5 -- distance in front of the player where a feed trough is placed
Config.FeedTroughFeedCooldown = 60000 -- ms an animal waits after feeding (or failing to find a bale) before trying again
Config.FeedTroughHeadingOffset = 0.0 -- degrees added to the stored heading when (re)spawning the prop, to correct for the model's default pivot facing
Config.FeedBagItem = 'feedbag' -- item used to refill a feed trough (consumed like the water bucket is for water troughs, minus the fill-up step)
Config.FeedTroughRefillPerBagUse = 100 -- uses added to a feed trough per feedbag consumed when refilling
Config.FEEDTROUGH_ID_MIN = 100000
Config.FEEDTROUGH_ID_MAX = 999999

---------------------------------
-- water trough settings (animal watering)
---------------------------------
Config.WaterTroughItem = 'watertrough' -- item used to place a water trough
Config.WaterTroughModel = `p_watertrough01x` -- prop model used for placed water troughs
Config.WaterTroughUses = 100 -- number of times a water trough can be drunk from before it runs dry
Config.WaterTroughDrinkAmount = 100 -- thirst restored (up to 100) each time an animal drinks from a trough
Config.WaterTroughThirstThreshold = 10 -- animals will only seek out a water trough once thirst drops below this
Config.WaterTroughSearchRadius = 100.0 -- radius (from an animal's position) to search for a usable water trough
Config.WaterTroughInteractDistance = 2.0 -- distance an animal must reach before it can drink from a water trough
Config.WaterTroughPlaceDistance = 2.5 -- distance in front of the player where a water trough is placed
Config.WaterTroughDrinkCooldown = 60000 -- ms an animal waits after drinking (or failing to find a trough) before trying again
Config.WaterTroughRefillPerBucketUse = 100 -- uses added to a trough per water bucket use consumed when refilling
Config.WaterTroughHeadingOffset = 0.0 -- degrees added to the stored heading when (re)spawning the prop, to correct for the model's default pivot facing
Config.WATERTROUGH_ID_MIN = 100000
Config.WATERTROUGH_ID_MAX = 999999

---------------------------------
-- chicken coop settings
---------------------------------
Config.ChickenCoopItem = 'chickencoop' -- item used to place a chicken coop cart
Config.ChickenCoopModel = `p_chickencoopcart01x` -- prop model used for placed chicken coops
Config.ChickenModel = `A_C_Chicken_01` -- ped model spawned for each chicken owned by a coop
Config.ChickenCoopPlaceDistance = 2.5 -- distance in front of the player where a chicken coop is placed
Config.ChickenCoopInteractDistance = 2.5 -- distance a player must be within to interact with a chicken coop
Config.ChickenBuyPrice = 15 -- cash cost to buy a single chicken for a coop
Config.MaxChickensPerCoop = 20 -- maximum number of chickens a single coop can hold
Config.ChickenWanderRadius = 10.0 -- maximum distance chicken peds will wander from their coop
Config.ChickenWanderCheckInterval = 4000 -- ms between wander decisions per chicken
Config.EggProductionInterval = 1800 -- seconds per egg production cycle (30 minutes)
Config.EggsPerChickenPerCycle = 1 -- eggs produced per chicken, per production cycle, if it successfully lays
Config.ChickenEggChance = 0.75 -- probability (0.0-1.0) that a given chicken lays eggs on a given production cycle
Config.MaxEggsStored = 100 -- cap on eggs a coop can bank before it needs collecting
Config.EggItem = 'egg' -- item given to players when collecting eggs
Config.ChickenCoopHeadingOffset = 0.0 -- degrees added to the stored heading when (re)spawning the coop prop, to correct for the model's default pivot facing being ~90 degrees off
Config.CHICKENCOOP_ID_MIN = 100000
Config.CHICKENCOOP_ID_MAX = 999999

---------------------------------
-- chicken coop feeding (keeps the chickens alive)
---------------------------------
Config.ChickenCoopMaxFeedLevel = 100 -- feed level a coop starts at / tops out at
Config.ChickenCoopFeedDecayInterval = 2592 -- seconds per feed decay cycle (43.2 minutes)
Config.ChickenCoopFeedDecayAmount = 1 -- feed level lost per decay cycle - at the defaults (100 feed, 1 point every 2592s) a full coop takes exactly 3 days (259200s) to starve out if left unfed
Config.ChickenCoopFeedPerBag = 100 -- feed level restored per feed bag used to feed the coop
Config.ChickenCoopFeedCronJob = '*/15 * * * *' -- how often the server checks coops for feed decay/starvation (every 15 minutes) - decay itself is time-based (see above), this just controls how often that gets checked/applied

---------------------------------
-- herding system settings
---------------------------------
Config.HerdingEnabled = true
Config.HerdingDistance = 25.0 -- maximum distance to detect animals for herding
Config.HerdingMaxAnimals = 10 -- maximum number of animals that can be herded at once
Config.HerdingFollowDistance = 3.0 -- distance animals maintain while following during herding
Config.HerdingSpeed = 1.5 -- movement speed when herding animals
Config.HerdingTimeout = 300 -- seconds before herding automatically stops (5 minutes)
Config.RequireHerdingTool = false -- set to true if you want to require a specific item to herd
Config.HerdingTool = 'weapon_lasso' -- item required for herding (if RequireHerdingTool is true)
Config.IndividualSelectionEnabled = true -- enable individual animal selection for herding
Config.ShowAnimalDistance = true -- show distance to animals in selection menu
Config.SelectionRangeMultiplier = 1.5 -- multiplier for selection range vs herding distance

---------------------------------
-- animal buy/sell settings
---------------------------------
Config.BullBuyPrice = 100
Config.BullSellPrice = 1
---------------------------------
Config.CowBuyPrice = 50
Config.CowSellPrice = 1
---------------------------------
Config.PigBuyPrice = 40
Config.PigSellPrice = 1
Config.PigDeliveryOnly = true -- pigs can only be bought with delivery to the ranch, no drive-yourself pickup option
Config.PigChooseGenderOnBuy = true -- let the buyer pick male/female when purchasing a pig, instead of it being randomized
---------------------------------
Config.SheepBuyPrice = 35
Config.SheepSellPrice = 1
Config.SheepDeliveryOnly = true -- sheep follow the same buy rules as pigs: delivery to the ranch only, no drive-yourself pickup option
Config.SheepChooseGenderOnBuy = true -- let the buyer pick male/female when purchasing a sheep, instead of it being randomized
---------------------------------
Config.LivestockDeliveryPrice = 10 -- extra cost charged when the player pays to have a purchased animal delivered straight to their ranch spawnpoint instead of driving/herding it from the buy point
---------------------------------

---------------------------------
-- animal species grouping (used so breeding never pairs up unrelated
-- animals - e.g. a bull and a pig - just because they happen to have
-- opposite genders)
---------------------------------
Config.AnimalSpecies = {
    ['a_c_bull_01'] = 'cattle',
    ['a_c_cow'] = 'cattle',
    ['a_c_pig_01'] = 'pig',
    ['a_c_sheep_01'] = 'sheep'
}

---------------------------------
-- pig slaughter settings
---------------------------------
Config.PigSlaughterYield = { min = 2, max = 4 } -- joints of pork produced when a pig is sent for slaughter
Config.PorkJointItem = 'porkjoint' -- item given for each joint of pork produced
---------------------------------

---------------------------------
-- cow slaughter settings
---------------------------------
Config.CowSlaughterYield = { min = 3, max = 6 } -- joints of beef produced when a cow is sent for slaughter
Config.BullSlaughterYield = { min = 4, max = 8 } -- joints of beef produced when a bull is sent for slaughter
Config.BeefJointItem = 'beefjoint' -- item given for each joint of beef produced
---------------------------------

---------------------------------
-- sheep slaughter settings
---------------------------------
Config.SheepSlaughterYield = { min = 2, max = 4 } -- joints of mutton produced when a sheep is sent for slaughter (same yield as pigs)
Config.MuttonJointItem = 'muttonjoint' -- item given for each joint of mutton produced
---------------------------------

---------------------------------
-- animal sale point settings
---------------------------------
Config.MinAgeToSell = 6 -- minimum age in days to sell animals (set to 0 for testing)
Config.PrimeAgeStart = 6 -- age when animals are considered prime
Config.PrimeAgeEnd = 30 -- age when animals are no longer prime
Config.OldAgeStart = 31 -- age when animals are considered old

---------------------------------
-- Age-based pricing multipliers
---------------------------------
Config.AgePricing = {
    young = 0.5,     -- animals below prime age (50% of base price)
    prime = 1.5,     -- animals in prime age (150% of base price)
    adult = 1.0,     -- animals between prime and old (100% of base price)
    old   = 0.7      -- old animals (70% of base price)
}

---------------------------------
-- Base selling prices (will be modified by age multipliers)
---------------------------------
Config.BaseSellPrices = {
    ['a_c_bull_01'] = 400,
    ['a_c_cow'] = 150,
    ['a_c_pig_01'] = 120,
    ['a_c_sheep_01'] = 110
}

---------------------------------
-- Direct sale from the ranch menu (cows & bulls)
---------------------------------
-- Cows and bulls can be sold straight from the ranch menu instead of being herded
-- to a sale point. Because nobody is driving them to market, they fetch a reduced price.
Config.DirectSalePercentage = 0.8 -- percentage of the normal sale price paid for a direct sale (0.8 = 80%, capped 0.0 - 1.0)
Config.DirectSaleModels = {       -- models the reduced direct-sale price applies to (pigs & sheep keep full price)
    ['a_c_cow'] = true,
    ['a_c_bull_01'] = true,
}

---------------------------------
-- Sale point settings
---------------------------------
Config.AnimalSaleDistance = 15.0 -- Distance animal must be within sale point to sell
Config.RequireAnimalPresent = true -- Set to false to disable physical animal requirement (temporarily disabled for testing)
Config.TransportMode = true -- Keep animals spawned when being herded, regardless of distance
Config.SalePointInteractionDistance = 20.0 -- Max distance a player can be from a sale point NPC and still sell

---------------------------------
-- animal interaction settings
---------------------------------
Config.AnimalInteractionDistance = 6.0 -- Max distance a player can be from an animal to feed/water/collect from it

---------------------------------
-- Buy point settings
---------------------------------
Config.BuyPointSpawnDistance = 8.0 -- Distance from buy point where animals can spawn
Config.BuyPointInteractionDistance = 20.0 -- Max distance a player can be from a buy point NPC and still buy

---------------------------------
-- animal production settings
---------------------------------
Config.ProductionEnabled = true
Config.ProductionCheckInterval = 3600 -- seconds (1 hour)
Config.MinAgeForProduction = 5 -- days old before animals can produce (set to 0 for testing)

---------------------------------
-- animal breeding settings
---------------------------------
Config.BreedingEnabled = true
Config.MinAgeForBreeding = 5 -- days old before animals can breed (more realistic)
Config.MaxBreedingAge = 30 -- days old after which animals can't breed (extended for more breeding time)
Config.BreedingDistance = 10.0 -- maximum distance between animals to breed
Config.BreedingCooldown = 86400 -- 1 days in seconds before animal can breed again (default for cows)
Config.RequireHealthForBreeding = 70 -- minimum health required for breeding
Config.RestrictMaleBreedingWhenFemalesPregnant = true -- prevent males from breeding when females are already pregnant

---------------------------------
-- Gender-specific breeding cooldowns
---------------------------------
Config.GenderSpecificCooldowns = {
    male = 3600,    -- 1 hour cooldown for males (bulls can breed more frequently)
    female = 86400 -- 24 hours (1 days) cooldown for females (cows need more recovery time)
}
Config.RequireHungerForBreeding = 50 -- minimum hunger required for breeding
Config.RequireThirstForBreeding = 50 -- minimum thirst required for breeding

---------------------------------
-- Automatic breeding settings
---------------------------------
Config.AutomaticBreedingEnabled = true -- Enable automatic breeding between compatible animals
Config.AutomaticBreedingCheckInterval = 60 -- Check interval in seconds (1 minute for testing)
Config.AutomaticBreedingMaxDistance = 5.0 -- Maximum distance for automatic breeding (shorter than manual)
Config.AutomaticBreedingNotifications = true -- Send notifications to ranch owners when automatic breeding occurs

---------------------------------
-- Prop placement validation
---------------------------------
-- Server-side sanity check for feed troughs, water troughs and chicken coops:
-- the client sends the coords it chose during placement/move preview, and this
-- is the max distance the player's actual position is allowed to be from those
-- coords. Prevents placing/moving props anywhere on the map by calling the
-- server event directly with arbitrary coordinates.
Config.PropPlacementMaxDistance = 10.0

---------------------------------
-- Gender ratios when buying animals (chance of male)
---------------------------------
Config.GenderRatios = {
    ['a_c_bull_01'] = 1.0, -- 100% chance of male (it's specifically a bull)
    ['a_c_cow'] = 0.0,     -- 0% chance of male, 100% chance of female (cows are always female)
    ['a_c_pig_01'] = 0.5,     -- 50/50 chance of male/female
    ['a_c_sheep_01'] = 0.5    -- 50/50 chance of male/female (same as pigs)
}

---------------------------------
-- Breeding configurations per animal type
---------------------------------
Config.BreedingConfig = {
    ['a_c_bull_01'] = {
        gestationPeriod = 259200,    -- 3 days in seconds (same as cows, represents 9 months)
        offspringCount = { min = 1, max = 1 }, -- always 1 calf
        breedingSeasonStart = 1,     -- year-round breeding
        breedingSeasonEnd = 365,
        enabled = true,
        -- Bulls can't give birth, but if they somehow did, offspring would be cows
        offspringModels = {
            { model = 'a_c_cow', chance = 100 } -- 100% chance of cow offspring
        }
    },
    ['a_c_cow'] = {
        gestationPeriod = 259200,    -- 3 days in seconds (represents 9 months)
        offspringCount = { min = 1, max = 1 }, -- always 1 calf
        breedingSeasonStart = 1,     -- day of year (1-365)
        breedingSeasonEnd = 365,     -- year-round breeding
        enabled = true,
        -- Cows can give birth to either female calves (cows) or male calves (bulls)
        offspringModels = {
            { model = 'a_c_cow', chance = 50 },     -- 50% chance of female calf
            { model = 'a_c_bull_01', chance = 50 }  -- 50% chance of male calf
        }
    },
    ['a_c_pig_01'] = {
        gestationPeriod = 172800,    -- 2 days in seconds (shorter than cattle - pigs farrow quickly)
        offspringCount = { min = 2, max = 4 }, -- pigs have litters, not single births
        breedingSeasonStart = 1,     -- year-round breeding
        breedingSeasonEnd = 365,
        enabled = true,
        -- Both genders use the same model - actual gender is randomized per piglet
        offspringModels = {
            { model = 'a_c_pig_01', chance = 100 }
        }
    },
    ['a_c_sheep_01'] = {
        gestationPeriod = 172800,    -- 2 days in seconds (same as pigs)
        offspringCount = { min = 2, max = 4 }, -- sheep have litters too, same as pigs
        breedingSeasonStart = 1,     -- year-round breeding
        breedingSeasonEnd = 365,
        enabled = true,
        -- Both genders use the same model - actual gender is randomized per lamb
        offspringModels = {
            { model = 'a_c_sheep_01', chance = 100 }
        }
    },
}

---------------------------------
-- Animal Products
---------------------------------
Config.AnimalProducts = {
    ['a_c_bull_01'] = {
        product = 'fertilizer',
        productionTime = 3600, -- every 1 hour in seconds
        amount = 5,
        requiresHealth = 60, -- minimum health to produce
        requiresHunger = 40, -- minimum hunger to produce
        requiresThirst = 40  -- minimum thirst to produce
    },
    ['a_c_cow'] = {
        product = 'milk',
        productionTime = 3600, -- every 1 hour in seconds
        amount = 5,
        requiresHealth = 60, -- minimum health to produce
        requiresHunger = 40, -- minimum hunger to produce
        requiresThirst = 40  -- minimum thirst to produce
    },
    ['a_c_pig_01'] = {
        product = 'fertilizer',
        productionTime = 3600, -- every 1 hour in seconds
        amount = 5,
        requiresHealth = 60, -- minimum health to produce
        requiresHunger = 40, -- minimum hunger to produce
        requiresThirst = 40  -- minimum thirst to produce
    },
    ['a_c_sheep_01'] = {
        product = 'wool',
        productionTime = 3600, -- every 1 hour in seconds
        amount = 5,
        requiresHealth = 60, -- minimum health to produce
        requiresHunger = 40, -- minimum hunger to produce
        requiresThirst = 40  -- minimum thirst to produce
    }
}

---------------------------------
-- staff management settings
---------------------------------
Config.StaffManagement = {
    MinGradeToManage = 2, -- Minimum grade required to manage staff
    MaxEmployeesPerRanch = 20, -- Maximum number of employees per ranch
    EnableSalarySystem = false, -- Enable/disable salary payments
    Permissions = {
        [0] = { -- Trainee
            canCollectProducts = false,
            canBreed = false,
            canSell = false,
            canBuy = false,
            canManageStaff = false,
        },
        [1] = { -- Ranch Hand
            canCollectProducts = true,
            canBreed = true,
            canSell = false,
            canBuy = false,
            canManageStaff = false,
        },
        [2] = { -- Manager/Boss (ranch jobs only define grades 0-2, see installation/shared_jobs.lua)
            canCollectProducts = true,
            canBreed = true,
            canSell = true,
            canBuy = true,
            canManageStaff = true,
        },
    }
}

---------------------------------
-- ranch ownership / purchase settings
---------------------------------
Config.RanchBossGrade = 2 -- the job grade level a player is set to once they purchase/own a ranch
Config.RanchPurchaseDistance = 3.0 -- how close (in the world) a player must be to the ranch NPC to purchase it
Config.RanchTransferDistance = 5.0 -- how close the current owner must be to the target player to transfer ownership
Config.RanchMenuDistance = 15.0 -- server-enforced: how close a player must be to their ranch NPC to use the ranch menu (storage, market, orders, staff, sell/transfer)
Config.RanchConsentTimeout = 20 -- seconds a player has to accept a job offer or ranch transfer before it is cancelled
Config.RanchSellGracePeriodHours = 24 -- cooling-off period (hours) after buying a ranch; selling within it refunds Config.RanchSellGraceRefundPercentage (0 = disable)
-- Refund percentages are capped between 0.0 and 1.0 - anything above 1.0 is treated as 1.0 (100%)
Config.RanchSellGraceRefundPercentage = 1.0 -- refund when sold within the cooling-off period (1.0 = 100% of the buy price)
Config.RanchSellRefundPercentage = 0.8 -- refund when sold after the cooling-off period has passed (0.8 = 80% of the buy price)
-- Note: selling a ranch resets it to default - all livestock, feed/water troughs, chicken coops,
-- storages, supply orders and staff are removed. Ranches received by transfer never get the
-- cooling-off refund, only Config.RanchSellRefundPercentage.

---------------------------------
-- ranch locations
---------------------------------
-- Remove the game's ambient NPCs and animals (scenario ranch hands, livestock, wildlife) from ranches.
-- Script-spawned peds (ranch animals, ranch NPCs, player horses, other resources' peds) are never touched.
-- Per ranch you can add: clearambient = false (skip this ranch), clearradius = 80.0, clearcenter = vector3(...)
Config.RanchAmbientClear = {
    enabled        = true,
    radius         = 60.0,   -- default clear radius around each ranch's coords
    blockScenarios = true,   -- stop scenario peds spawning inside the radius
    keepHumans     = false,  -- true = only remove ambient animals
    keepAnimals    = false,  -- true = only remove ambient NPCs
    checkInterval  = 2000,   -- ms between sweeps while a player is near a ranch
    activeDistance = 150.0,  -- start sweeping when this far outside the radius
    idleInterval   = 5000,   -- ms between distance checks when no ranch is near
}

---------------------------------
-- ranch admin panel (/ranchadmin)
---------------------------------
-- Lets admin staff view and manage every ranch from one NUI: ownership,
-- staff, livestock, troughs, coops, storages, supply orders and per-ranch
-- settings (display name, blip, purchase price). Settings changed in the
-- panel are saved to `rsg_ranch_settings` and override the values below.
Config.Admin = {
    Command = 'ranchadmin',               -- chat command that opens the panel
    Permissions = { 'admin', 'god' },     -- rsg-core permission groups allowed to use it
    AcePermission = 'command.ranchadmin', -- also allowed: players with this ACE
    Log = true,                           -- print every admin action to the server console
}

Config.RanchLocations = {
    {
        name = 'Macfarlane Ranch',
        ranchid = 'macfarranch',
        coords = vector3(-2405.00, -2381.53, 61.18),
        npcmodel = `g_m_m_uniranchers_01`,
        npccoords = vector4(-2405.00, -2381.53, 61.18, 71.45),
        jobaccess = 'macfarranch',
        blipname = 'Macfarlane Ranch',
        blipsprite = 'blip_ambient_herd',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(-2425.51, -2367.51, 61.18, 82.40),
        price = 5000
    },
    {
        name = 'Emerald Ranch',
        ranchid = 'emeraldranch',
        coords = vector3(1403.50, 280.42, 89.25),
        npcmodel = `g_m_m_uniranchers_01`,
        npccoords = vector4(1403.50, 280.42, 89.25, 19.85),
        jobaccess = 'emeraldranch',
        blipname = 'Emerald Ranch',
        blipsprite = 'blip_ambient_herd',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(1400.58, 290.48, 88.57, 19.79),
        price = 5000
    },
    {
        name = 'Pronghorn Ranch',
        ranchid = 'pronghornranch',
        coords = vector3(-2561.00, 403.92, 148.23),
        npcmodel = `g_m_m_uniranchers_01`,
        npccoords = vector4(-2561.00, 403.92, 148.23, 97.99),
        jobaccess = 'pronghornranch',
        blipname = 'Pronghorn Ranch',
        blipsprite = 'blip_ambient_herd',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(-2545.45, 421.62, 148.24, 190.00),
        price = 5000
    },
    {
        name = 'Downes Ranch',
        ranchid = 'downesranch',
        coords = vector3(-853.86, 339.76, 96.39),
        npcmodel = `g_m_m_uniranchers_01`,
        npccoords = vector4(-853.86, 339.76, 96.39, 262.57),
        jobaccess = 'downesranch',
        blipname = 'Downes Ranch',
        blipsprite = 'blip_ambient_herd',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(-854.62, 319.46, 95.67, 351.60),
        price = 5000
    },
    {
        name = 'Hill Haven Ranch',
        ranchid = 'hillhavenranch',
        coords = vector3(1367.14, -848.88, 70.85),
        npcmodel = `g_m_m_uniranchers_01`,
        npccoords = vector4(1367.14, -848.88, 70.85, 297.43),
        jobaccess = 'hillhavenranch',
        blipname = 'Hill Haven Ranch',
        blipsprite = 'blip_ambient_herd',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(1373.20, -845.12, 70.56, 301.98),
        price = 5000
    },
    {
        name = 'Hanging Dog Ranch',
        ranchid = 'hangingdogranch',
        coords = vector3(-2207.69, 726.97, 122.82),
        npcmodel = `g_m_m_uniranchers_01`,
        npccoords = vector4(-2207.69, 726.97, 122.82, 213.49),
        jobaccess = 'hangingdogranch',
        blipname = 'Hanging Dog Ranch',
        blipsprite = 'blip_ambient_herd',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(-2243.28, 717.42, 122.48, 296.03),
        price = 5000
    }
}

---------------------------------
-- order supplies settings
---------------------------------
Config.OrderSupplies = {
    Enabled = true,
    MaxAmountPerOrder = 10, -- max quantity of a single item a staff member can order at once
    MaxPendingOrdersPerRanch = 30, -- max total order rows (across all items/staff) a ranch can have queued/awaiting collection
    Items = {
        { item = 'ranch_wellpump', label = locale('cfg_supply_wellpump'),    price = 50,  deliveryTime = 1800 },  -- 30 minutes
        { item = 'watertrough',    label = locale('cfg_supply_watertrough'), price = 50,  deliveryTime = 1800 },  -- 30 minutes
        { item = 'feedtrough',     label = locale('cfg_supply_feedtrough'),  price = 50,  deliveryTime = 1800 },  -- 30 minutes
        { item = 'chickencoop',    label = locale('cfg_supply_chickencoop'), price = 100, deliveryTime = 1800 },  -- 30 minutes
        { item = 'feedbag',        label = locale('cfg_supply_feedbag'),     price = 5,   deliveryTime = 600 },   -- 10 minutes
        { item = 'bucket',         label = locale('cfg_supply_bucket'),       price = 10,  deliveryTime = 600 },   -- 10 minutes
    },
    ORDER_ID_MIN = 100000,
    ORDER_ID_MAX = 999999,
}

---------------------------------
-- water props
---------------------------------
Config.WaterProps = {
    `p_wellpumpnbx01x`,
    `p_watertrough01x`,
    `p_watertroughsml01x`,
    `p_watertrough01x_new`,
    `p_watertrough02x`,
    `p_watertrough03x`,
}

---------------------------------
-- buy point locations
---------------------------------
Config.BuyPointLocations = {
    {
        name = locale('cfg_buypoint_name'), -- valentine
        coords = vector3(-218.78, 652.80, 113.27),
        npcmodel = `mp_u_m_m_trader_01`,
        npccoords = vec4(-218.78, 652.80, 113.27, 241.67),
        blipname = locale('cfg_livestock_dealer'),
        blipsprite = 'blip_shop_horse',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vec4(-217.61, 649.48, 113.10, 195.09)
    },
    {
        name = locale('cfg_buypoint_name'), -- near strawberry
        coords = vector3(-1834.75, -578.28, 155.97),
        npcmodel = `mp_u_m_m_trader_01`,
        npccoords = vector4(-1834.75, -578.28, 155.97, 304.67),
        blipname = locale('cfg_livestock_dealer'),
        blipsprite = 'blip_shop_horse',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vector4(-1830.77, -576.25, 155.97, 291.70)
    },
    {
        name = locale('cfg_buypoint_name'), -- wallace station
        coords = vector3(-1309.82, 387.21, 95.35),
        npcmodel = `mp_u_m_m_trader_01`,
        npccoords = vector4(-1309.82, 387.21, 95.35, 167.82),
        blipname = locale('cfg_livestock_dealer'),
        blipsprite = 'blip_shop_horse',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vec4(-1311.06, 385.14, 95.51, 95.24)
    },
	--[[
    {
        name = locale('cfg_buypoint_test_name'), -- for testing
        coords = vector3(1343.50, 291.81, 87.94),
        npcmodel = `mp_u_m_m_trader_01`,
        npccoords = vector4(1343.50, 291.81, 87.94, 281.24),
        blipname = locale('cfg_livestock_dealer'),
        blipsprite = 'blip_shop_horse',
        blipscale = 0.2,
        showblip = true,
        spawnpoint = vec4(1345.95, 289.59, 87.97, 229.44)
    },
	--]]

}

---------------------------------
-- sale point locations
---------------------------------
Config.SalePointLocations = {
    { 
        name = locale('cfg_salepoint_name'), -- valentine
        coords = vector3(-230.28, 637.59, 113.38),
        npcmodel = `cs_valauctionboss_01`,
        npccoords = vec4(-230.28, 637.59, 113.38, 243.69),
        blipname = locale('cfg_livestock_market'),
        blipsprite = 'blip_shop_store',
        blipscale = 0.2,
        showblip = true
    },
    { 
        name = locale('cfg_salepoint_name'), -- near strawberry
        coords = vector3(-1791.83, -579.00, 155.95),
        npcmodel = `cs_valauctionboss_01`,
        npccoords = vector4(-1791.83, -579.00, 155.95, 28.21),
        blipname = locale('cfg_livestock_market'),
        blipsprite = 'blip_shop_store',
        blipscale = 0.2,
        showblip = true
    },
    { 
        name = locale('cfg_salepoint_name'), -- wallace station
        coords = vector3(-1308.77, 375.84, 96.4),
        npcmodel = `cs_valauctionboss_01`,
        npccoords = vec4(-1308.77, 375.84, 96.46, 90.13),
        blipname = locale('cfg_livestock_market'),
        blipsprite = 'blip_shop_store',
        blipscale = 0.2,
        showblip = true
    },
	--[[
    { 
        name = locale('cfg_salepoint_test_name'), -- for testing
        coords = vector3(1338.39, 315.53, 87.48),
        npcmodel = `cs_valauctionboss_01`,
        npccoords = vec4(1338.39, 315.53, 87.48, 196.12),
        blipname = locale('cfg_livestock_market'),
        blipsprite = 'blip_shop_store',
        blipscale = 0.2,
        showblip = true
    },
	--]]

}
