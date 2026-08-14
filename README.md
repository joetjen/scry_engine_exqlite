# scry_engine_exqlite

A real, kind-independent [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [SQLite](https://www.sqlite.org/) via
[`exqlite`](https://github.com/elixir-sqlite/exqlite)'s own low-level
`Exqlite.Sqlite3` API. A single authoritative `execute/3` compiles the
*entire* flat query — `WHERE`/`GROUP BY`/aggregates/`ORDER BY`/
`DISTINCT`/`LIMIT`/`OFFSET`/projection — into one native SQL statement,
all or nothing: either the whole query is genuinely correct as native
SQL, or `execute/3` declines it with a clean `{:error, {:unsupported,
detail}}` and no attempt is made. There is no downstream fallback or
re-verification anywhere in this pipeline any more — an engine that
accepts a query fully owns its correctness.

Kind-independent by construction, like every engine in this family: it
only ever sees the `source`/`Scry.Core.Query.t()` shapes already
produced once any kind-specific vocabulary (`LAST`, eventually `via`/
`hops`, ...) has been lowered away.

Source: <https://github.com/joetjen/scry_engine_exqlite>. Specs live in
the separate [`scry`](https://github.com/joetjen/scry) repository; the
behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.Exqlite.Conn.open("path/to/app.db")

{:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 1 { name }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.Exqlite, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice"}]

Scry.Engine.Exqlite.Conn.close(conn)
```

`Conn.open/2` is meant to be called once and the resulting connection
reused across many `execute/3` calls -- opening a fresh connection per
call is wasteful and is *not* what this package does internally.
Creating tables, indexes, and schema is entirely the caller's own job;
this package is schema-agnostic and issues nothing but `SELECT`/
`PRAGMA table_info` statements.

### What gets pushed down

`Scry.Engine.Exqlite.SqlCompiler` translates a flat query into SQL only
when it can do so *completely* — every `select` item is a bare field
(or, for a `GROUP BY` query, one of `sum`/`avg`/`count`/`min`/`max`/
`count(distinct ...)` over a bare field), `wheres` translates fully
(recursive `:cmp`/`:in`/`:and`/`:or`/`:not`, `Scry.Engine.Exqlite.
WhereTranslator`), and there is no `HAVING`/`ROLLUP`/`CUBE`/window
function/nested `SELECT`/`WITH`-bound source anywhere in the query.
Anything that doesn't fully qualify is a clean `{:error, {:unsupported,
detail}}` — never a partial pushdown silently finished off in Elixir.

A nested/correlated `SELECT` body item, or a `WITH`-bound source, is
delegated whole to `Scry.Core.QueryOps.run_document/4` instead —
recursing back into this same module's `execute/3` for each flat leaf
it resolves, so native pushdown still applies to those leaves.

### Two schema-level correctness checks, run in one transaction with the query itself

SQL's own `WHERE`/aggregate semantics silently skip/exclude `NULL`
values with no way to raise — Scry's own language spec requires a hard
null-safety error instead. Every column compared against a non-`nil`
literal in `wheres`, and every aggregated column, must be schema-level
`NOT NULL` (`PRAGMA table_info`, an `INTEGER PRIMARY KEY`/`ROWID` alias
counting as guaranteed-not-null too, despite `notnull: 0` in its own
schema row) or the whole query is declined with `{:error, {:unsupported,
{:nullable_column, columns}}}`.

Found by property testing, not assumed: SQLite's type-affinity-based
comparison rules can disagree with this project's own Erlang-term-order/
`Kernel.==/2` comparison semantics across mismatched column/literal
types (e.g. a `TEXT` column compared against an integer literal via
`<`, or — found after first assuming equality was safe from this —
an `INTEGER` column genuinely `= "2"` the string in SQLite thanks to
its own affinity-coercion rule) — every comparison's own column,
`=`/`!=`/`IN` included, not just ordering, is checked against its own
real SQLite type affinity (the same 5-rule algorithm SQLite itself
uses), declining with `{:error, {:unsupported, {:type_mismatch,
checks}}}` rather than risk a silently wrong result.

`avg` is pushdown-eligible and returns a native, inexact SQL float —
`scry_core`'s own `CHANGELOG.md` has the full reasoning for relaxing
the "exact rational arithmetic regardless of backend" guarantee to a
per-engine capability. Relaxing exactness never meant relaxing the
null-safety guarantee too — `avg`'s own target column is checked
exactly like every other aggregate's.

## Installation

```elixir
def deps do
  [
    {:scry_engine_exqlite, "~> 2.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_exqlite>.
