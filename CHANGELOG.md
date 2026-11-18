# Changelog

All notable changes to rsg-ranch. Newest first.

## 3.3.1

### Added
- `Config.AutoDatabase` (default `true`): the database tables are built automatically on start. Set it to `false` to skip the auto-build and import the bundled SQL file manually instead.

### Fixed
- `installation/rsg-ranch.sql` now includes the `rsg_ranch_wellpumps` table, so manual installs get every table.

### Documentation
- `DOCS.md`: added a generated technical reference (dependencies, database, configuration, exports, callbacks, events, commands, items, locales) with code examples, read straight from the source.
