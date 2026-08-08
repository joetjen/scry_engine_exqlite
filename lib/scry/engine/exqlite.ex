defmodule Scry.Engine.Exqlite do
  @moduledoc """
  A real, kind-independent `Scry.Core.EngineBehaviour` implementation
  over SQLite, via `exqlite`'s own low-level `Exqlite.Sqlite3` API (not
  `DBConnection.stream/4`, whose own cursor is scoped to the
  transaction that created it and therefore unusable across an
  `execute/3` call boundary).

  `execute/3` compiles the *entire* flat query -- `WHERE`/`GROUP BY`/
  aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`/projection -- into
  one native SQL statement via `Scry.Engine.Exqlite.SqlCompiler`, all
  or nothing: that module's own moduledoc has the exact eligible query
  shapes and, just as importantly, the real correctness work behind
  declining anything it can't (a schema-level `NOT NULL` check, run in
  the same transaction as the compiled query itself, for every column
  a nullable value could otherwise make SQL's own three-valued
  `WHERE`/aggregate semantics silently diverge from `Scry.Core.
  QueryOps.eval_predicate/4`'s own null-safety hard error). `avg` is
  eligible for pushdown now, deliberately -- `scry_core`'s own
  `CHANGELOG.md` has the full reasoning for relaxing *exactness*
  (SQLite's native `AVG()` is always an inexact float) while still
  requiring the *same* `NOT NULL` guarantee every other aggregate
  needs (relaxing exactness never meant relaxing "no silent
  null-skipping" too -- those are separate concerns).

  **Rows come back as `Scry.Core.Row.t()` values, not plain maps**,
  for this direct, wholly-pushed-down path (a nested/correlated
  `SELECT`/`WITH`-bound source still returns plain maps -- delegated to
  `Scry.Core.QueryOps.run_document/4`, whose own final projection step
  always builds one). Building a brand-new string-keyed map for every
  single row is real, measured cost at scale that a caller who doesn't
  need every field of every row (counting, pagination, streaming a
  handful of fields onward) shouldn't have to pay for -- `Scry.Core.
  Row`'s own moduledoc has the full reasoning. A caller wanting a
  plain map calls `Scry.Core.Row.to_map/1`; `Scry.Core.QueryOps` itself
  already treats a `Row` as a first-class row shape throughout.

  **The schema check itself is cached per `Scry.Engine.Exqlite.Conn`**,
  not re-run from scratch on every single call -- a real, measured cost
  for a small/point-lookup query, where the check's own `PRAGMA
  table_info` round trip dwarfed the actual query. Verified cheaply via
  SQLite's own `PRAGMA schema_version` (a single integer, bumped by any
  schema-altering statement against the database file, from any
  connection) before trusting a cached `table_info` result -- so a real
  schema change is still detected, not silently missed; `Scry.Engine.
  Exqlite.Conn`'s own moduledoc has the full mechanics. A `%Conn{}`
  built by hand rather than via `Conn.open/2` has no cache and simply
  re-checks every time -- always correct, just not optimized.

  A query `SqlCompiler` declines (a window function, `ROLLUP`/`CUBE`,
  a real `HAVING` clause, `json(...)`/other casts or arithmetic in
  `select`, a `WHERE` predicate wider than it translates) is a real,
  clean `{:error, {:unsupported, detail}}` -- no fallback exists here
  to fully interpret it in Elixir instead; a caller wanting that
  construct against a SQL-backed connection needs a future increment
  of this compiler, or a different engine.

  A query containing a nested/correlated `SELECT` body item, or whose
  own `source` names a declared `WITH` binding, is delegated whole to
  `Scry.Core.QueryOps.run_document/4` instead of attempted here --
  this module doesn't (yet) translate either into a native `JOIN`/CTE,
  though a future increment legitimately could; `run_document/4`
  recurses back into this same module's `execute/3` for each flat leaf
  it resolves, so whatever native pushdown *does* apply to those leaves
  still does.

  Table (and column) names are validated against a plain SQL-identifier
  pattern before ever being interpolated into a SQL string -- `source`
  and every field/alias `SqlCompiler` renders are query-supplied
  values, not hardcoded strings, so all are treated as untrusted input,
  never spliced in unchecked (`WhereTranslator.identifier?/1`, reused
  by `SqlCompiler` directly). Every *value* is always bound via a real
  `?` placeholder, never string-interpolated.

  Index creation, schema, and connection lifecycle are deliberately not
  this module's job: `Scry.Engine.Exqlite.Conn.open/2` opens a
  connection once, reused across as many `execute/3` calls as the
  caller likes; creating tables/indexes against it is entirely up to
  the caller (this package is schema-agnostic, issuing nothing but
  `SELECT`/`PRAGMA table_info` statements).
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, EngineBehaviour, Query, QueryOps, Row}
  alias Scry.Engine.Exqlite.{Conn, Schema, SqlCompiler}

  @default_chunk_size 2_000

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{db: db} = conn, %Query{source: source} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      case SqlCompiler.compile(query, params) do
        {:ok, %{not_null_columns: [], type_checks: []} = compiled} ->
          run_sql(db, compiled)

        {:ok, compiled} ->
          [table] = source
          run_sql_with_schema_check(conn, table, compiled)

        {:error, _} = error ->
          error
      end
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp run_sql(db, %{sql: sql, bind_params: bind_params}) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, bind_params),
         {:ok, raw_columns} <- Exqlite.Sqlite3.columns(db, stmt) do
      index = raw_columns |> Enum.map(&to_string/1) |> Row.build_index()
      {:ok, rows_stream(db, stmt, index)}
    else
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  # `Scry.Engine.Exqlite.SqlCompiler`'s own moduledoc has the full
  # reasoning for both checks this makes: the schema check and the
  # compiled query itself run inside one transaction, so a schema
  # change on another connection between an isolated check and the
  # query can't let a real `NULL` (or a type-affinity mismatch)
  # slip through none of Scry's own guarantees would have caught.
  # Always `COMMIT`, never `ROLLBACK` -- read-only for its entire
  # duration, nothing to undo either way.
  defp run_sql_with_schema_check(%Conn{db: db} = conn, table, compiled) do
    case Exqlite.Sqlite3.execute(db, "BEGIN DEFERRED") do
      :ok ->
        result =
          case Schema.verify(conn, table, compiled.not_null_columns, compiled.type_checks) do
            :ok -> run_sql_eager(db, compiled)
            {:error, _} = error -> error
          end

        Exqlite.Sqlite3.execute(db, "COMMIT")
        result

      {:error, reason} ->
        {:error, {:query_error, reason}}
    end
  end

  # Eager, not the lazy `rows_stream/3` used elsewhere -- the
  # surrounding transaction must not still be open by the time this
  # returns, so every row is drained and the statement released before
  # `COMMIT` runs. `fetch_all/3`, with this module's own `chunk_size/0`
  # explicit -- `fetch_all/2` defaults to *exqlite's own* chunk size
  # (50 rows/NIF call), a real, measured cost found reasoning through
  # `exqlite`'s own source after the schema-check/Row-output fixes
  # alone barely moved a large (1,000,000-row) `GROUP BY`'s own
  # duration: 50 rows/call means 20,000 NIF round trips for a result
  # this size, 40x more than the 2,000-row chunking `rows_stream/3`
  # (and raw SQL's own benchmark comparison) already use.
  defp run_sql_eager(db, %{sql: sql, bind_params: bind_params}) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, bind_params),
         {:ok, raw_columns} <- Exqlite.Sqlite3.columns(db, stmt),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt, chunk_size()) do
      Exqlite.Sqlite3.release(db, stmt)
      index = raw_columns |> Enum.map(&to_string/1) |> Row.build_index()
      {:ok, Enum.map(rows, &Row.new(index, &1))}
    else
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback --
  delegates straight to `Scry.Engine.Exqlite.Schema.describe_source/2`,
  which routes through the exact same per-`Conn` ETS cache the schema
  check above already uses (that module's own moduledoc has the full
  reasoning for sharing it).
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(conn, source), do: Schema.describe_source(conn, source)

  defp rows_stream(db, stmt, index) do
    Stream.resource(
      fn -> :more end,
      fn
        :done ->
          {:halt, :done}

        :more ->
          case Exqlite.Sqlite3.multi_step(db, stmt, chunk_size()) do
            {:rows, rows} -> {Enum.map(rows, &Row.new(index, &1)), :more}
            {:done, rows} -> {Enum.map(rows, &Row.new(index, &1)), :done}
          end
      end,
      fn _state -> Exqlite.Sqlite3.release(db, stmt) end
    )
  end

  # Overridable via `config :scry_engine_exqlite, chunk_size: n` -- lets
  # tests force the multi-chunk accumulation path without needing
  # thousands of rows to exceed the real-world default.
  defp chunk_size, do: Application.get_env(:scry_engine_exqlite, :chunk_size, @default_chunk_size)
end
