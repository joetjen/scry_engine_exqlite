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

  Index creation, schema, and connection lifecycle are deliberately not
  this module's job: `Scry.Engine.Exqlite.Conn.open/2` opens a
  connection once, reused across as many `fetch` calls as the caller
  likes; creating tables/indexes against it is entirely up to the
  caller (this package is schema-agnostic, issuing nothing but
  `SELECT` statements).
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
end
