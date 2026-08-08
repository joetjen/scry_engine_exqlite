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

  alias Scry.Core.{CombinedQuery, Query, QueryOps}
  alias Scry.Engine.Exqlite.{Conn, SqlCompiler}

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
          run_sql_with_schema_check(db, table, compiled)

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
      columns = Enum.map(raw_columns, &to_string/1)
      {:ok, rows_stream(db, stmt, columns)}
    else
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  # `Scry.Engine.Exqlite.SqlCompiler`'s own moduledoc has the full
  # reasoning for both checks this makes: `PRAGMA table_info` and the
  # compiled query itself run inside one transaction, so a schema
  # change on another connection between an isolated check and the
  # query can't let a real `NULL` (or a type-affinity mismatch)
  # slip through none of Scry's own guarantees would have caught.
  # Always `COMMIT`, never `ROLLBACK` -- read-only for its entire
  # duration, nothing to undo either way.
  defp run_sql_with_schema_check(db, table, compiled) do
    case Exqlite.Sqlite3.execute(db, "BEGIN DEFERRED") do
      :ok ->
        result =
          case schema_check(db, table, compiled.not_null_columns, compiled.type_checks) do
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
  # `COMMIT` runs.
  defp run_sql_eager(db, %{sql: sql, bind_params: bind_params}) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, bind_params),
         {:ok, raw_columns} <- Exqlite.Sqlite3.columns(db, stmt),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt) do
      Exqlite.Sqlite3.release(db, stmt)
      columns = Enum.map(raw_columns, &to_string/1)
      {:ok, Enum.map(rows, &row_map(columns, &1))}
    else
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  defp schema_check(db, table, not_null_columns, type_checks) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA table_info(#{table})"),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt) do
      Exqlite.Sqlite3.release(db, stmt)
      verify_schema(rows, not_null_columns, type_checks)
    else
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  # `PRAGMA table_info` for a table that doesn't exist returns an
  # empty result set, not an error -- indistinguishable, from this
  # query alone, from "a real table with zero columns" (which never
  # happens in practice). Found directly (not assumed): without this
  # clause, an unknown-source aggregate query reported a misleading
  # `{:unsupported, {:nullable_column, ...}}}` instead of the real
  # "no such table" error -- `[]` here means "proceed", letting the
  # compiled query itself surface the genuine `{:query_error, ...}`
  # once it actually runs.
  defp verify_schema([], _not_null_columns, _type_checks), do: :ok

  defp verify_schema(rows, not_null_columns, type_checks) do
    guaranteed_not_null =
      rows
      |> Enum.filter(&column_guaranteed_not_null?(&1, rows))
      |> MapSet.new(fn [_cid, name, _type, _notnull, _dflt, _pk] -> name end)

    affinities =
      Map.new(rows, fn [_cid, name, type, _notnull, _dflt, _pk] ->
        {name, column_affinity(type)}
      end)

    cond do
      not Enum.all?(not_null_columns, &MapSet.member?(guaranteed_not_null, &1)) ->
        {:error, {:unsupported, {:nullable_column, not_null_columns}}}

      not Enum.all?(type_checks, fn {column, class} -> Map.get(affinities, column) == class end) ->
        {:error, {:unsupported, {:type_mismatch, type_checks}}}

      true ->
        :ok
    end
  end

  # A schema-declared `NOT NULL` is the ordinary case. The one
  # deliberate exception: a single-column `INTEGER PRIMARY KEY` is a
  # real SQLite `ROWID` alias -- confirmed directly (not assumed),
  # `PRAGMA table_info` reports `notnull: 0` for one even though no
  # persisted row can ever actually read back a `NULL` there (it *is*
  # the row's own rowid). Narrow on purpose: a `TEXT`/composite
  # primary key gets no such exception -- SQLite has never guaranteed
  # `NOT NULL` for those the way it does for this one specific,
  # documented rowid-alias shape.
  defp column_guaranteed_not_null?([_cid, _name, _type, 1, _dflt, _pk], _all_rows), do: true

  defp column_guaranteed_not_null?([_cid, _name, type, 0, _dflt, pk], all_rows) do
    pk == 1 and String.upcase(to_string(type)) == "INTEGER" and
      Enum.count(all_rows, fn [_, _, _, _, _, pk] -> pk != 0 end) == 1
  end

  # SQLite's own 5-rule type affinity algorithm
  # (https://www.sqlite.org/datatype3.html#type_affinity), simplified
  # to the two classes `Scry.Engine.Exqlite.SqlCompiler`'s own
  # `type_checks` ever asks about -- a column whose declared type
  # doesn't clearly fall into either is treated as incompatible with
  # both (never assumed safe).
  defp column_affinity(declared_type) do
    type = declared_type |> to_string() |> String.upcase()

    cond do
      String.contains?(type, "INT") ->
        :numeric

      String.contains?(type, "CHAR") or String.contains?(type, "CLOB") or
          String.contains?(type, "TEXT") ->
        :text

      String.contains?(type, "REAL") or String.contains?(type, "FLOA") or
          String.contains?(type, "DOUB") ->
        :numeric

      type == "" or String.contains?(type, "BLOB") ->
        nil

      true ->
        :numeric
    end
  end

  defp rows_stream(db, stmt, columns) do
    Stream.resource(
      fn -> :more end,
      fn
        :done ->
          {:halt, :done}

        :more ->
          case Exqlite.Sqlite3.multi_step(db, stmt, chunk_size()) do
            {:rows, rows} -> {Enum.map(rows, &row_map(columns, &1)), :more}
            {:done, rows} -> {Enum.map(rows, &row_map(columns, &1)), :done}
          end
      end,
      fn _state -> Exqlite.Sqlite3.release(db, stmt) end
    )
  end

  # Overridable via `config :scry_engine_exqlite, chunk_size: n` -- lets
  # tests force the multi-chunk accumulation path without needing
  # thousands of rows to exceed the real-world default.
  defp chunk_size, do: Application.get_env(:scry_engine_exqlite, :chunk_size, @default_chunk_size)

  defp row_map(columns, values), do: columns |> Enum.zip(values) |> Map.new()
end
