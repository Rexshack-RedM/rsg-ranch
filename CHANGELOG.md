# Changelog

All notable changes to rsg-ranch. Newest first.

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
