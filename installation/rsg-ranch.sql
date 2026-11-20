-- ----------------------------------------------------------------------------
-- Upgrading from an older install that still has `rsg_ranch_haybales`?
-- Hay bales were renamed to feed troughs. Run this ONCE to migrate existing
-- data instead of losing it, then re-run the rest of this file as normal
-- (the CREATE TABLE below will just be skipped since the table now exists):
--
--   RENAME TABLE `rsg_ranch_haybales` TO `rsg_ranch_feedtroughs`;
--   ALTER TABLE `rsg_ranch_feedtroughs` CHANGE `haybaleid` `feedtroughid` varchar(50) DEFAULT NULL;
--   ALTER TABLE `rsg_ranch_feedtroughs` RENAME INDEX `unique_haybaleid` TO `unique_feedtroughid`;
--
-- You'll also need to give players holding the old `haybale` item the new
-- `feedtrough` item instead (inventory item names weren't auto-migrated).
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Upgrading an existing install to add chicken coop feeding? Run this ONCE to
-- add the new columns to your existing `rsg_ranch_chickencoops` table instead
-- of losing your existing coops (the CREATE TABLE below only applies to a
-- fresh install, since the table already exists on an upgrade):
--
--   ALTER TABLE `rsg_ranch_chickencoops` ADD COLUMN `feed_level` tinyint(3) unsigned DEFAULT 100 AFTER `eggs_stored`;
--   ALTER TABLE `rsg_ranch_chickencoops` ADD COLUMN `last_feed_update` int(10) unsigned DEFAULT 0 AFTER `feed_level`;
--   UPDATE `rsg_ranch_chickencoops` SET `last_feed_update` = UNIX_TIMESTAMP() WHERE `last_feed_update` = 0;
--
-- The final UPDATE matters: without it every existing coop looks like it
-- hasn't been fed since 1970 and will starve out the moment the feed decay
-- check next runs.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `rsg_ranch_animals` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `ranchid` varchar(50) DEFAULT NULL,
  `animalid` varchar(50) DEFAULT NULL,
  `model` varchar(50) NOT NULL,
  `pos_x` float NOT NULL,
  `pos_y` float NOT NULL,
  `pos_z` float NOT NULL,
  `pos_w` float NOT NULL,
  `age` smallint(5) unsigned DEFAULT 0,
  `health` tinyint(3) unsigned DEFAULT 100,
  `thirst` tinyint(3) unsigned DEFAULT 100,
  `hunger` tinyint(3) unsigned DEFAULT 100,
  `born` int(10) unsigned NOT NULL,
  `scale` decimal(4,2) DEFAULT 0.50,
  `last_production` int(10) unsigned DEFAULT 0,
  `product_ready` tinyint(1) DEFAULT 0,
  `gender` enum('male','female') DEFAULT 'female',
  `pregnant` tinyint(1) DEFAULT 0,
  `gestation_end_time` int(10) unsigned DEFAULT NULL,
  `breeding_ready_time` int(10) unsigned DEFAULT 0,
  `breeding_attempts` int(10) unsigned DEFAULT 0,
  `mother_id` varchar(50) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_animalid` (`animalid`),
  KEY `idx_ranchid` (`ranchid`),
  KEY `idx_animalid` (`animalid`),
  KEY `idx_product_ready` (`product_ready`),
  KEY `idx_ranchid_product` (`ranchid`,`product_ready`),
  KEY `idx_pregnant` (`pregnant`),
  KEY `idx_gender` (`gender`),
  KEY `idx_breeding_ready` (`breeding_ready_time`),
  KEY `idx_mother_id` (`mother_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_feedtroughs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `feedtroughid` varchar(50) DEFAULT NULL,
  `ranchid` varchar(50) DEFAULT NULL,
  `pos_x` float NOT NULL,
  `pos_y` float NOT NULL,
  `pos_z` float NOT NULL,
  `pos_w` float NOT NULL,
  `uses` tinyint(3) unsigned DEFAULT 10,
  `placed_by` varchar(50) DEFAULT NULL,
  `created_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_feedtroughid` (`feedtroughid`),
  KEY `idx_ranchid` (`ranchid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_storages` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `storageid` varchar(50) NOT NULL,
  `ranchid` varchar(50) NOT NULL,
  `size` varchar(20) NOT NULL DEFAULT 'general',
  `label` varchar(50) NOT NULL DEFAULT 'General Storage',
  `maxweight` int(10) unsigned NOT NULL DEFAULT 10000000,
  `slots` smallint(5) unsigned NOT NULL DEFAULT 100,
  `min_grade` tinyint(3) unsigned NOT NULL DEFAULT 1,
  `purchased_by` varchar(50) DEFAULT NULL,
  `created_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_storageid` (`storageid`),
  KEY `idx_ranchid` (`ranchid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_owners` (
  `ranchid` varchar(50) NOT NULL,
  `citizenid` varchar(50) NOT NULL,
  `purchased_at` int(10) unsigned NOT NULL,
  PRIMARY KEY (`ranchid`),
  KEY `idx_citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_watertroughs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `watertroughid` varchar(50) DEFAULT NULL,
  `ranchid` varchar(50) DEFAULT NULL,
  `pos_x` float NOT NULL,
  `pos_y` float NOT NULL,
  `pos_z` float NOT NULL,
  `pos_w` float NOT NULL,
  `uses` tinyint(3) unsigned DEFAULT 10,
  `placed_by` varchar(50) DEFAULT NULL,
  `created_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_watertroughid` (`watertroughid`),
  KEY `idx_ranchid` (`ranchid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_orders` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `orderid` varchar(50) DEFAULT NULL,
  `ranchid` varchar(50) DEFAULT NULL,
  `citizenid` varchar(50) DEFAULT NULL,
  `item` varchar(50) NOT NULL,
  `amount` smallint(5) unsigned DEFAULT 1,
  `price` int(10) unsigned DEFAULT 0,
  `ordered_at` int(10) unsigned DEFAULT NULL,
  `ready_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_orderid` (`orderid`),
  KEY `idx_ranchid` (`ranchid`),
  KEY `idx_ready_at` (`ready_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_chickencoops` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `coopid` varchar(50) DEFAULT NULL,
  `ranchid` varchar(50) DEFAULT NULL,
  `pos_x` float NOT NULL,
  `pos_y` float NOT NULL,
  `pos_z` float NOT NULL,
  `pos_w` float NOT NULL,
  `chickens` smallint(5) unsigned DEFAULT 0,
  `eggs_stored` smallint(5) unsigned DEFAULT 0,
  `feed_level` tinyint(3) unsigned DEFAULT 100,
  `last_feed_update` int(10) unsigned DEFAULT 0,
  `last_production` int(10) unsigned DEFAULT 0,
  `placed_by` varchar(50) DEFAULT NULL,
  `created_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_coopid` (`coopid`),
  KEY `idx_ranchid` (`ranchid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS `rsg_ranch_settings` (
  `ranchid` varchar(50) NOT NULL,
  `name` varchar(100) DEFAULT NULL,
  `blipname` varchar(100) DEFAULT NULL,
  `price` int(10) unsigned DEFAULT NULL,
  `showblip` tinyint(1) DEFAULT NULL,
  `updated_by` varchar(50) DEFAULT NULL,
  `updated_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`ranchid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `rsg_ranch_custom` (
  `ranchid` varchar(50) NOT NULL,
  `name` varchar(100) NOT NULL,
  `price` int(10) unsigned NOT NULL DEFAULT 5000,
  `npcmodel` varchar(60) NOT NULL DEFAULT 'g_m_m_uniranchers_01',
  `npc_x` float NOT NULL,
  `npc_y` float NOT NULL,
  `npc_z` float NOT NULL,
  `npc_w` float NOT NULL DEFAULT 0,
  `spawn_x` float NOT NULL,
  `spawn_y` float NOT NULL,
  `spawn_z` float NOT NULL,
  `spawn_w` float NOT NULL DEFAULT 0,
  `blipsprite` varchar(60) NOT NULL DEFAULT 'blip_ambient_herd',
  `blipscale` float NOT NULL DEFAULT 0.2,
  `created_by` varchar(50) DEFAULT NULL,
  `created_at` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`ranchid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
