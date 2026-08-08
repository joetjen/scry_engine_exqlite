defmodule Scry.Engine.Exqlite.Schema do
  @moduledoc """
  SQLite schema introspection (`PRAGMA table_info`/`PRAGMA
  schema_version`), extracted out of `Scry.Engine.Exqlite` itself so it
  can be reused by two independent consumers with two different
  freshness needs: `Scry.Engine.Exqlite`'s own per-query, transaction-
  scoped `NOT NULL`/type-affinity gate (`Scry.Engine.Exqlite.execute/3`,
  re-checked on every call specifically because a concurrent schema
  change mid-query must still be caught) and this module's own
  `describe_source/3` (`Scry.Core.EngineBehaviour`'s optional
  `describe_source/2` callback, consumed by `Scry.Core.TypeCheck.
  Introspection` -- a much less frequent, connection-level check, not a
  per-query one). Both share the exact same underlying facts and the
  exact same per-`Conn` ETS cache (`Scry.Engine.Exqlite.Conn`'s own
  moduledoc has the full caching/freshness mechanics) -- this module is
  a pure extraction, byte-for-byte identical behavior to what
  `Scry.Engine.Exqlite` had inline before it existed.
  """

  alias Scry.Core.EngineBehaviour
  alias Scry.Engine.Exqlite.Conn

  @doc """
  Fetches `table`'s own `PRAGMA table_info` rows against `conn`,
  through its per-`Conn` ETS cache when one exists (`schema_cache:
  nil` -- a `%Conn{}` built by hand, common in tests -- always re-fetches).
  """
  @spec table_info(Conn.t(), String.t()) :: {:ok, [list()]} | {:error, term()}
  def table_info(%Conn{schema_cache: nil} = conn, table), do: fetch_table_info(conn.db, table)

  def table_info(%Conn{db: db, schema_cache: cache}, table),
    do: cached_table_info(db, cache, table)

  @doc """
  Verifies `not_null_columns` are all schema-guaranteed `NOT NULL` and
  every `{column, class}` in `type_checks` matches its own declared
  type affinity, against `table`'s own real schema via `conn`. Returns
  `:ok` for a table with zero columns (SQLite's own `PRAGMA table_info`
  return for a table that doesn't exist at all, indistinguishable from
  a real zero-column table, which never happens in practice) -- letting
  whatever real query runs next surface the genuine `{:query_error,
  ...}` for an actually-missing table, rather than a misleading
  `{:unsupported, _}` from this check.
  """
  @spec verify(Conn.t(), String.t(), [String.t()], [{String.t(), atom()}]) ::
          :ok | {:error, term()}
  def verify(conn, table, not_null_columns, type_checks) do
    with {:ok, rows} <- table_info(conn, table) do
      verify_schema(rows, not_null_columns, type_checks)
    end
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback,
  proper -- converts `source`'s own real `PRAGMA table_info` rows (via
  the same cache `verify/4` uses) into `Scry.Core.EngineBehaviour.
  introspected_field()`s. `{:error, :not_found}` for a source with no
  such table (mirrors `verify/4`'s own "empty result set" case, but
  `describe_source/2`'s own contract calls for a real "absent" answer
  here rather than an on-purpose "proceed" one -- there's no compiled
  query about to surface a more specific error the way `execute/3`'s
  own callers have).
  """
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(conn, source) do
    case table_info(conn, source) do
      {:ok, []} -> {:error, :not_found}
      {:ok, rows} -> {:ok, Enum.map(rows, &introspected_field(&1, rows))}
      {:error, reason} -> {:error, {:introspection_error, reason}}
    end
  end

  defp introspected_field([_cid, name, type, _notnull, _dflt, _pk] = row, all_rows) do
    %{
      name: to_string(name),
      nullable: not column_guaranteed_not_null?(row, all_rows),
      scalar: introspected_scalar(type)
    }
  end

  # A deliberately honest translation of SQLite's own 5-rule type
  # affinity algorithm (https://www.sqlite.org/datatype3.html#type_affinity)
  # into `introspected_field()`'s own scalar vocabulary -- distinguishes
  # `:integer` from `:float` where SQLite's own rules genuinely do (an
  # "INT"-containing declared type is unambiguously INTEGER affinity, a
  # "REAL"/"FLOA"/"DOUB"-containing one unambiguously REAL affinity),
  # but reports `:unknown` rather than guessing for the two cases SQLite
  # itself can't pin down from the declared type text alone: `BLOB`/no
  # declared type at all, and the default `NUMERIC`-affinity catch-all
  # (a column genuinely free to hold either an integer or a real value
  # from row to row). No `BOOLEAN`/`JSON`-flavored text-hint special
  # casing -- SQLite's own affinity rules don't have one either, and
  # inventing one here would be a guess this module isn't in a position
  # to honestly make.
  defp introspected_scalar(declared_type) do
    type = declared_type |> to_string() |> String.upcase()

    cond do
      String.contains?(type, "INT") ->
        :integer

      String.contains?(type, "CHAR") or String.contains?(type, "CLOB") or
          String.contains?(type, "TEXT") ->
        :string

      String.contains?(type, "REAL") or String.contains?(type, "FLOA") or
          String.contains?(type, "DOUB") ->
        :float

      true ->
        :unknown
    end
  end

  # `PRAGMA table_info` is re-fetched only when SQLite's own `PRAGMA
  # schema_version` (a single, cheap integer read -- bumped by *any*
  # schema-altering statement against this database file, from any
  # connection, not just this one) disagrees with what's cached. Both
  # still run inside the same transaction `Scry.Engine.Exqlite`'s own
  # per-query gate already opens when called from there, so a schema
  # change between the version check and the compiled query itself is
  # still caught, exactly as if caching didn't exist -- this only ever
  # skips the (comparatively expensive) `table_info` round trip, never
  # the freshness guarantee itself.
  defp cached_table_info(db, cache, table) do
    with {:ok, version} <- schema_version(db) do
      case :ets.lookup(cache, table) do
        [{^table, ^version, rows}] ->
          {:ok, rows}

        _stale_or_missing ->
          with {:ok, rows} <- fetch_table_info(db, table) do
            :ets.insert(cache, {table, version, rows})
            {:ok, rows}
          end
      end
    end
  end

  defp schema_version(db) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA schema_version"),
         {:ok, [[version]]} <- Exqlite.Sqlite3.fetch_all(db, stmt) do
      Exqlite.Sqlite3.release(db, stmt)
      {:ok, version}
    else
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  defp fetch_table_info(db, table) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA table_info(#{table})"),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt) do
      Exqlite.Sqlite3.release(db, stmt)
      {:ok, rows}
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
end
