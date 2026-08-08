defmodule Scry.Engine.Exqlite do
  @moduledoc """
  A real, kind-independent `Scry.Core.EngineBehaviour` implementation
  over SQLite, via `exqlite`'s own low-level `Exqlite.Sqlite3` API
  (not `DBConnection.stream/4`, whose own cursor is scoped to the
  transaction that created it and therefore unusable across a
  `fetch/2` call boundary).

  `fetch/2` issues an unfiltered `SELECT * FROM <table>` and streams
  results in batches via `Exqlite.Sqlite3.multi_step/3` (2,000 rows per
  NIF call by default, `config :scry_engine_exqlite, chunk_size: n` to
  override) rather than `step/2` (one row per NIF call) -- this
  batching is just how a well-written adapter is implemented, not a
  separate architecture decision. `fetch/3` additionally runs
  `query.wheres` through `Scry.Engine.ETS`'s sibling here,
  `Scry.Engine.Exqlite.WhereTranslator`, appending whatever real SQL
  `WHERE` clause it can build (with bound `?` parameters, never
  string-interpolated values) before issuing the same batched fetch --
  falling back to `fetch/2`'s own unfiltered scan for a source with no
  translatable predicates at all. `Scry.Core.Executor` re-applies the
  query's full semantics to whatever either callback returns
  regardless, so any partial/absent translation only ever costs speed,
  never correctness (`Scry.Core.EngineBehaviour`'s own moduledoc has
  the complete safety-invariant reasoning).

  **`fetch/4` -- column pruning + compact rows, on top of the same
  `WHERE` translation `fetch/3` already does.** `opts.columns`
  (`Scry.Core.Executor.referenced_top_level_fields/2`'s own output) is
  either `{:ok, columns}` -- issues `SELECT <columns> FROM <table>`
  instead of `SELECT *`, real, measured motivation: a `GROUP BY`/`WHERE`
  scan needing 2-3 of a table's many columns was paying for every one
  of them, every row, for nothing -- or `:unknown`, which falls back to
  `SELECT *`, byte-identical to `fetch/2`/`fetch/3`'s own behavior.
  Either way, `fetch/4` returns `Scry.Core.Row` values (a shared
  column-index map built once per fetch, paired with each row's own
  positional values tuple) instead of building a brand-new map for
  every single row -- the other real cost `fetch/2`/`fetch/3` always
  pay, regardless of how few columns come back. `Scry.Core.Executor`
  re-applies the query's full semantics to this too, unconditionally,
  the same as every other `fetch` arity here -- if `opts.columns`
  somehow under-collected a column a downstream predicate/projection
  step still tries to read, `Scry.Core.Row.fetch!/2` raises loudly
  rather than silently resolving to `nil` (`Scry.Core.Row`'s own
  moduledoc has the complete reasoning for why that asymmetry from a
  plain map's `Map.get/2` is deliberate).

  Table (and column) names are validated against a plain SQL-identifier
  pattern before ever being interpolated into a SQL string -- `source`
  and `opts.columns` are both query-supplied values, not hardcoded
  strings, so both are treated as untrusted input, never spliced in
  unchecked.

  **`aggregate/5` -- real, native `GROUP BY`/aggregate pushdown, a
  genuinely stricter contract than `fetch/3`/`fetch/4`'s own** (`Scry.
  Core.EngineBehaviour.aggregate/5`'s own moduledoc has the full
  "authoritative, not lenient" reasoning). Three things have to hold
  before this ever issues a native `SUM`/`COUNT`/`MIN`/`MAX`/`COUNT(
  DISTINCT ...)`, checked in order, declining (`:not_supported`, a
  graceful fall-back to `Scry.Core.Executor`'s own row-by-row
  computation, never an error) the moment any one doesn't:

  1. Every `group_bys`/aggregate-target column name is a safe SQL
     identifier (same pattern `fetch/4`'s own column pruning already
     uses).
  2. `query.wheres` is **fully** translatable (`WhereTranslator.
     translate_strict/2`, resolving `{:param, name}` against `params`
     too) -- unlike `fetch/3`'s own lenient, partial translation, since
     there's no way to apply a leftover predicate *after* SQL has
     already aggregated rows away.
  3. Every aggregated column is schema-level `NOT NULL`
     (`PRAGMA table_info`, checked in the *same transaction* as the
     aggregate query itself, closing a real TOCTOU gap a first draft of
     this had -- another connection altering the schema between an
     isolated check and the query could otherwise let a `NULL` slip
     through none of Scry's own nil-checks would have missed).
     SQL's own `SUM`/`COUNT(col)`/`MIN`/`MAX`/`COUNT(DISTINCT col)` all
     silently skip `NULL` values (confirmed empirically against a real
     SQLite database) where lang_spec §7 requires "no silent
     nil-skipping" -- this is the one check standing in for that hard
     error. This is also the one place this module stops being
     schema-agnostic (unlike every other callback here, which only
     ever issues `SELECT` against whatever `source` names) -- a
     deliberate, narrow, documented exception for this one capability,
     not a broader policy change.

  A `NULL` `SUM`/`MIN`/`MAX` result (only possible for a `group_bys ==
  []` flat aggregate over zero matching rows -- SQL still returns
  exactly one row in that case, confirmed empirically) is translated
  into `Scry.Core.Executor`'s own `:empty` sentinel before returning,
  never a raw `nil` it has no clause for. Every other raw value flows
  straight through into `Scry.Core.Executor.finalize_agg/2`
  unmodified -- this module never itself computes `avg` (excluded from
  pushdown eligibility entirely, `EngineBehaviour.aggregate/5`'s own
  moduledoc has the exactness reasoning) or finalizes a `count(
  distinct)` accumulator (already a plain integer here, no `MapSet`
  needed, since pushdown never merges across chunks the way the
  row-by-row streaming path does).

  Index creation, schema, and connection lifecycle are deliberately not
  this module's job: `Scry.Engine.Exqlite.Conn.open/2` opens a
  connection once, reused across as many `fetch` calls as the caller
  likes; creating tables/indexes against it is entirely up to the
  caller (this package is schema-agnostic, issuing nothing but
  `SELECT` statements, `aggregate/5`'s own narrow exception above
  aside).
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.Query
  alias Scry.Core.Row
  alias Scry.Engine.Exqlite.Conn
  alias Scry.Engine.Exqlite.WhereTranslator

  @default_chunk_size 2_000
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  def fetch(%Conn{} = conn, source), do: do_fetch(conn, source, "", [], "*", false)

  @impl true
  def fetch(%Conn{} = conn, source, %Query{wheres: wheres}) do
    {where_sql, params} = WhereTranslator.translate(wheres)
    do_fetch(conn, source, where_sql, params, "*", false)
  end

  @impl true
  def fetch(%Conn{} = conn, source, %Query{wheres: wheres}, opts) do
    {where_sql, params} = WhereTranslator.translate(wheres)

    with {:ok, select_sql} <- select_clause(opts[:columns] || :unknown) do
      do_fetch(conn, source, where_sql, params, select_sql, true)
    end
  end

  defp do_fetch(%Conn{db: db}, source, where_sql, params, select_sql, compact?) do
    with {:ok, table} <- table_name(source),
         sql = "SELECT " <> select_sql <> " FROM " <> table <> where_sql,
         {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params),
         {:ok, raw_columns} <- Exqlite.Sqlite3.columns(db, stmt) do
      columns = Enum.map(raw_columns, &to_string/1)
      {:ok, rows_stream(db, stmt, row_builder(columns, compact?))}
    else
      {:error, {:invalid_source, _}} = error -> error
      {:error, _reason} -> {:error, {:no_such_source, source}}
    end
  end

  # `:unknown` -- fetch every column, byte-identical to `fetch/2`/
  # `fetch/3`'s own `SELECT *`. An empty (but known) column set also
  # falls back to `*` rather than emitting `SELECT FROM table` (invalid
  # SQL) -- a real, if unusual, shape (e.g. every `select` item a bare
  # literal, nothing referencing this source's own fields at all).
  # Every column name is validated against the exact same identifier
  # pattern `table_name/1` already applies to `source` -- both are
  # query-supplied, untrusted input, never spliced into SQL unchecked.
  defp select_clause(:unknown), do: {:ok, "*"}

  defp select_clause({:ok, columns}) do
    case columns |> MapSet.to_list() |> Enum.sort() do
      [] ->
        {:ok, "*"}

      sorted ->
        case Enum.find(sorted, &(not Regex.match?(@identifier, &1))) do
          nil -> {:ok, Enum.join(sorted, ", ")}
          invalid -> {:error, {:invalid_column, invalid}}
        end
    end
  end

  defp table_name([table]) when is_binary(table) do
    if Regex.match?(@identifier, table) do
      {:ok, table}
    else
      {:error, {:invalid_source, [table]}}
    end
  end

  defp table_name(source), do: {:error, {:invalid_source, source}}

  defp rows_stream(db, stmt, row_builder) do
    Stream.resource(
      fn -> :more end,
      fn
        :done ->
          {:halt, :done}

        :more ->
          case Exqlite.Sqlite3.multi_step(db, stmt, chunk_size()) do
            {:rows, rows} -> {Enum.map(rows, row_builder), :more}
            {:done, rows} -> {Enum.map(rows, row_builder), :done}
          end
      end,
      fn _state -> Exqlite.Sqlite3.release(db, stmt) end
    )
  end

  # Overridable via `config :scry_engine_exqlite, chunk_size: n` -- exists
  # so tests can force the multi-chunk accumulation path (`{:rows, ...}`
  # followed by at least one more `multi_step/3` call) without needing
  # thousands of rows to exceed the real-world default.
  defp chunk_size, do: Application.get_env(:scry_engine_exqlite, :chunk_size, @default_chunk_size)

  # The shared column index (`compact?`) is built exactly once per
  # fetch, here -- never per row, never per batch -- and reused by
  # reference across every `Scry.Core.Row` this fetch produces.
  defp row_builder(columns, false), do: fn values -> columns |> Enum.zip(values) |> Map.new() end

  defp row_builder(columns, true) do
    index = Row.build_index(columns)
    fn values -> Row.new(index, values) end
  end

  @impl true
  def aggregate(%Conn{db: db}, source, %Query{wheres: wheres, group_bys: group_bys}, plan, params) do
    with {:ok, table} <- table_name(source),
         {:ok, group_by_cols} <- validate_group_by_columns(group_bys),
         {:ok, agg_exprs} <- validate_agg_specs(plan) do
      case WhereTranslator.translate_strict(wheres, params) do
        {:ok, where_sql, where_params} ->
          run_pushdown(db, table, group_by_cols, agg_exprs, plan, where_sql, where_params)

        :error ->
          :not_supported
      end
    else
      {:error, {:invalid_source, _}} = error -> error
      :invalid_column -> :not_supported
    end
  end

  # `group_bys` is always `[[String.t()]]` with every entry a
  # single-segment path by the time `Scry.Core.Executor` ever calls
  # this -- its own eligibility check (`aggregate_pushdown_plan/3`)
  # guarantees it, so `hd/1` here is trusting an already-established
  # contract, not defensive coding against a shape that can't occur.
  defp validate_group_by_columns(group_bys) do
    columns = Enum.map(group_bys, &hd/1)

    if Enum.all?(columns, &valid_identifier?/1) do
      {:ok, columns}
    else
      :invalid_column
    end
  end

  defp valid_identifier?(name), do: is_binary(name) and Regex.match?(@identifier, name)

  # One `%{sql: ..., not_null_column: column}` per `plan` entry --
  # `sql` is the rendered `SELECT`-list fragment (a positional `AS
  # agg_N` alias, purely for SQL readability; results are read back
  # positionally, never by name), `not_null_column` the one real column
  # `aggregate/5`'s own `NOT NULL` gate must confirm before trusting
  # this expression's result.
  defp validate_agg_specs(plan) do
    plan
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{name, args}, index}, {:ok, acc} ->
      case agg_expr(name, args, index) do
        {:ok, expr} -> {:cont, {:ok, [expr | acc]}}
        :invalid_column -> {:halt, :invalid_column}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :invalid_column -> :invalid_column
    end
  end

  defp agg_expr("sum", [{:field, [col]}], index), do: sql_agg_expr("SUM", col, index)
  defp agg_expr("min", [{:field, [col]}], index), do: sql_agg_expr("MIN", col, index)
  defp agg_expr("max", [{:field, [col]}], index), do: sql_agg_expr("MAX", col, index)
  defp agg_expr("count", [{:field, [col]}], index), do: sql_agg_expr("COUNT", col, index)

  defp agg_expr("count", [{:distinct, {:field, [col]}}], index) do
    if valid_identifier?(col) do
      {:ok, %{sql: "COUNT(DISTINCT #{col}) AS agg_#{index}", not_null_column: col}}
    else
      :invalid_column
    end
  end

  defp agg_expr(_name, _args, _index), do: :invalid_column

  defp sql_agg_expr(sql_fn, col, index) do
    if valid_identifier?(col) do
      {:ok, %{sql: "#{sql_fn}(#{col}) AS agg_#{index}", not_null_column: col}}
    else
      :invalid_column
    end
  end

  # `PRAGMA table_info` + the aggregate query itself run inside one
  # transaction -- otherwise a schema change on another connection
  # (e.g. dropping a `NOT NULL` constraint via SQLite's own table-
  # rebuild `ALTER` pattern) between an isolated check and the query
  # could let a real `NULL` slip through none of `Scry.Core.Executor`'s
  # own nil-checks would ever see, silently producing a wrong `SUM`/
  # `AVG` instead of the hard error lang_spec §7 mandates.
  # Read-only for its entire duration (`all_not_null?/3`'s own `PRAGMA`
  # and the aggregate `SELECT` itself, nothing else) -- always `COMMIT`,
  # never `ROLLBACK`, regardless of outcome: there's nothing to undo
  # either way, and `run_pushdown_in_transaction/7` itself never fails
  # in a way that needs a real rollback (any unexpected failure inside
  # it -- SQL-level, not "declined because ineligible" -- degrades to
  # `:not_supported`, a graceful fall-back, not an error to recover
  # from).
  defp run_pushdown(db, table, group_by_cols, agg_exprs, plan, where_sql, where_params) do
    case Exqlite.Sqlite3.execute(db, "BEGIN DEFERRED") do
      :ok ->
        result =
          run_pushdown_in_transaction(
            db,
            table,
            group_by_cols,
            agg_exprs,
            plan,
            where_sql,
            where_params
          )

        Exqlite.Sqlite3.execute(db, "COMMIT")
        result

      {:error, _reason} ->
        :not_supported
    end
  end

  defp run_pushdown_in_transaction(
         db,
         table,
         group_by_cols,
         agg_exprs,
         plan,
         where_sql,
         where_params
       ) do
    not_null_columns = agg_exprs |> Enum.map(& &1.not_null_column) |> Enum.uniq()

    if all_not_null?(db, table, not_null_columns) do
      sql = build_pushdown_sql(table, group_by_cols, agg_exprs, where_sql)

      with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
           :ok <- Exqlite.Sqlite3.bind(stmt, where_params),
           {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt) do
        Exqlite.Sqlite3.release(db, stmt)
        {:ok, to_pushdown_rows(rows, length(group_by_cols), plan)}
      else
        {:error, _reason} -> :not_supported
      end
    else
      :not_supported
    end
  end

  defp all_not_null?(_db, _table, []), do: true

  defp all_not_null?(db, table, columns) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA table_info(#{table})"),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt) do
      Exqlite.Sqlite3.release(db, stmt)

      not_null_columns =
        rows
        |> Enum.filter(fn [_cid, _name, _type, notnull, _dflt, _pk] -> notnull == 1 end)
        |> MapSet.new(fn [_cid, name, _type, _notnull, _dflt, _pk] -> name end)

      Enum.all?(columns, &MapSet.member?(not_null_columns, &1))
    else
      {:error, _reason} -> false
    end
  end

  defp build_pushdown_sql(table, [], agg_exprs, where_sql) do
    "SELECT " <> Enum.map_join(agg_exprs, ", ", & &1.sql) <> " FROM " <> table <> where_sql
  end

  defp build_pushdown_sql(table, group_by_cols, agg_exprs, where_sql) do
    group_by_list = Enum.join(group_by_cols, ", ")
    select_list = group_by_list <> ", " <> Enum.map_join(agg_exprs, ", ", & &1.sql)

    "SELECT " <>
      select_list <> " FROM " <> table <> where_sql <> " GROUP BY " <> group_by_list
  end

  defp to_pushdown_rows(rows, group_by_count, plan) do
    Enum.map(rows, fn values ->
      {group_by_values, agg_raw_values} = Enum.split(values, group_by_count)

      agg_values =
        plan
        |> Enum.zip(agg_raw_values)
        |> Map.new(fn {spec, raw} -> {spec, translate_agg_value(raw)} end)

      {group_by_values, agg_values}
    end)
  end

  defp translate_agg_value(nil), do: :empty
  defp translate_agg_value(value), do: value
end
