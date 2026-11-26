# Changelog

All notable changes to rsg-ranch. Newest first.

## 3.7.1

### Fixed
- Replaced the last native `<select>` dropdowns (hire player and grade, ownership transfer, storage access), which can crash RedM, with the custom dropdown.

## 3.7.0

### Changed
- rsg-ranch now works fully with **rsg-society** (new required dependency, rsg-society 3.2.1+). Boss-only actions (storage, staff, ownership transfer) check `exports['rsg-society']:IsBoss`, and every ranch, config or admin-created, gets its own society on start. rsg-bossmenu and rsg-gangmenu are not used.
- Removed the `RSGCore.Shared.Jobs` and direct `multijob_jobs` fallbacks. Ranch jobs are read, created and deleted only through rsg-core's job definition functions.

## 3.6.0

### Added
- Optional rsg-economy integration: animal sales (sale point, bulk herd, direct ranch) are quoted with town tax and the standing price modifier (no market multiplier) and recorded after payout. `Config.Economy.Enabled`.

## 3.5.0

### Added
- **Herding key:** optional rebindable key that opens the herding menu (runs `/herd`, so job and ranch checks still apply) through rsg-core `RegisterKey`. New `Config.HerdingKey` (empty by default = unbound until the player binds it in the game's key settings; `nil` disables it) and locale key `cl_herding_key` in all 11 languages. Requires rsg-core 3.5.0 or newer.

### Fixed
- Removed the outdated "RegisterKeyMapping is not available in RedM" comment.

## 3.4.0

### Changed
- Well pumps moved to the standalone **rsg-wellpump** resource (now a required dependency). rsg-ranch no longer places pumps, fills buckets or stores pumps. Water trough refills take a bucket use through `exports['rsg-wellpump']:TakeBucketUse`, then commit it, or refund it if the trough update fails.
- Removed `Config.WellPump`, `Config.WaterReturnItem`, `Config.BucketUses`, the `*_wellpump_*` and `sv_bucket_uses` locale keys, and the `rsg_ranch_wellpumps` table from `installation/rsg-ranch.sql`. Existing pumps are imported by rsg-wellpump on its first start (the old table is left untouched). The `ranch_wellpump` item still places a pump through rsg-wellpump.

## 3.3.1

### Added
- `Config.AutoDatabase` (default `true`): the database tables are built automatically on start. Set it to `false` to skip the auto-build and import the bundled SQL file manually instead.

### Fixed
- `installation/rsg-ranch.sql` now includes the `rsg_ranch_wellpumps` table, so manual installs get every table.

### Documentation
- `DOCS.md`: added a generated technical reference (dependencies, database, configuration, exports, callbacks, events, commands, items, locales) with code examples, read straight from the source.
