# Changelog

## [Unreleased]

### Added

- Initial release: `Scry.Engine.Exqlite` -- a real, kind-independent `Scry.Core.EngineBehaviour` implementation over SQLite via `exqlite`'s own low-level `Exqlite.Sqlite3` API. `fetch/2` streams a full table in batches via `Exqlite.Sqlite3.multi_step/3` (2,000 rows/NIF call by default, `config :scry_engine_exqlite, chunk_size: n` to override) rather than one-row-per-NIF-call `step/2`. `fetch/3` additionally runs `query.wheres` through `Scry.Engine.Exqlite.WhereTranslator` and appends whatever real SQL `WHERE` clause it can build (bound `?` parameters, never string-interpolated values), falling back to `fetch/2`'s own unfiltered scan for anything it can't translate.
- `Scry.Engine.Exqlite.Conn` -- wraps an already-open `Exqlite.Sqlite3.db()` connection (`open/2`, `close/1`), meant to be opened once and reused across many `fetch` calls rather than reopened per call.
- `Scry.Engine.Exqlite.WhereTranslator` -- translates top-level `{:cmp, op, [field], value}` predicates (and the leaves of a top-level `{:and, ...}` chain among them) into SQL, for every comparison operator but `:match`, only when `field` is a single-segment, SQL-identifier-safe path and `value` is a plain string/integer/float. `nil`, booleans, `{:field, ...}`, and `{:param, ...}` right-hand sides are deliberately never translated, to avoid the one direction (silently dropping a row a correct fetch would have returned) `Scry.Core.Executor`'s own re-verification can never catch.
- Table and field names are validated against a plain SQL-identifier pattern before ever being interpolated into a SQL string -- both are query-supplied values, treated as untrusted input.
