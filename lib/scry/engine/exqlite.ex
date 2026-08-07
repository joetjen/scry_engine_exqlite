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

  Table (and column) names are validated against a plain SQL-identifier
  pattern before ever being interpolated into a SQL string -- `source`
  is a query-supplied value, not a hardcoded string, so it's treated as
  untrusted input, never spliced in unchecked.

  Index creation, schema, and connection lifecycle are deliberately not
  this module's job: `Scry.Engine.Exqlite.Conn.open/2` opens a
  connection once, reused across as many `fetch` calls as the caller
  likes; creating tables/indexes against it is entirely up to the
  caller (this package is schema-agnostic, issuing nothing but
  `SELECT` statements).
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.Query
  alias Scry.Engine.Exqlite.Conn
  alias Scry.Engine.Exqlite.WhereTranslator

  @default_chunk_size 2_000
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  def fetch(%Conn{} = conn, source), do: do_fetch(conn, source, "", [])

  @impl true
  def fetch(%Conn{} = conn, source, %Query{wheres: wheres}) do
    {where_sql, params} = WhereTranslator.translate(wheres)
    do_fetch(conn, source, where_sql, params)
  end

  defp do_fetch(%Conn{db: db}, source, where_sql, params) do
    with {:ok, table} <- table_name(source),
         sql = "SELECT * FROM " <> table <> where_sql,
         {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params),
         {:ok, columns} <- Exqlite.Sqlite3.columns(db, stmt) do
      {:ok, rows_stream(db, stmt, Enum.map(columns, &to_string/1))}
    else
      {:error, {:invalid_source, _}} = error -> error
      {:error, _reason} -> {:error, {:no_such_source, source}}
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

  defp rows_stream(db, stmt, columns) do
    Stream.resource(
      fn -> :more end,
      fn
        :done ->
          {:halt, :done}

        :more ->
          case Exqlite.Sqlite3.multi_step(db, stmt, chunk_size()) do
            {:rows, rows} -> {to_rows(rows, columns), :more}
            {:done, rows} -> {to_rows(rows, columns), :done}
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

  defp to_rows(rows, columns) do
    Enum.map(rows, fn values -> columns |> Enum.zip(values) |> Map.new() end)
  end
end
