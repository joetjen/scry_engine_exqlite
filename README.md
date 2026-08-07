# scry_engine_exqlite

A real, kind-independent [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [SQLite](https://www.sqlite.org/) via
[`exqlite`](https://github.com/elixir-sqlite/exqlite)'s own low-level
`Exqlite.Sqlite3` API — `fetch/2` streams a full table in batches
(`multi_step/3`, not the one-row-per-NIF-call `step/2`); `fetch/3`
translates whatever top-level, literal-valued `WHERE` comparisons it
recognizes into a real SQL `WHERE` clause with bound parameters,
falling back to an unfiltered scan for anything it doesn't.

Kind-independent by construction, like every engine in this family: it
only ever sees the `source`/`Scry.Core.Query.t()` shapes `Scry.Core.
Executor` already produces once any kind-specific vocabulary (`LAST`,
eventually `via`/`hops`, ...) has been lowered away.

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
reused across many `fetch` calls -- opening a fresh connection per
call is wasteful and is *not* what this package does internally.
Creating tables, indexes, and schema is entirely the caller's own job;
this package is schema-agnostic and issues nothing but `SELECT`
statements.

### What gets pushed down

`fetch/3` recognizes top-level `wheres` entries (and the leaves of any
top-level `{:and, ...}` chain among them) shaped like `{:cmp, op, [field],
value}`, where `field` is a single, valid SQL identifier and `value` is
a plain string, integer, or float -- `nil`, booleans, `{:field, ...}`,
and `{:param, ...}` right-hand sides are deliberately never pushed down
(SQLite's own `NULL`/boolean-as-integer semantics don't reliably match
this project's own comparison semantics, and a `{:param, ...}` value
isn't available at translation time at all) -- each such entry becomes
its own `<field> <op> ?` fragment, AND-joined into a real `WHERE`
clause. Anything else (`:or`, `:not`, `:in`, a multi-segment field, an
untranslatable value) is simply left out of the pushed-down clause and
re-checked by `Scry.Core.Executor` afterward, exactly this family's own
"never wrong, not always complete" posture.

## Installation

```elixir
def deps do
  [
    {:scry_engine_exqlite, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_exqlite>.
