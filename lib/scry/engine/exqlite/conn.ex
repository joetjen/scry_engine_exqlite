defmodule Scry.Engine.Exqlite.Conn do
  @moduledoc """
  Wraps an already-open `Exqlite.Sqlite3.db()` connection -- opened
  once via `open/2` and meant to be reused across many
  `Scry.Engine.Exqlite.execute/3` calls, unlike an ad-hoc adapter that
  opens (and closes) a fresh connection on every single call. Matches
  the connection/config struct every real adapter exposes
  (impl_spec.md §2).

  `schema_cache` is an ETS table `open/2` creates alongside the
  connection -- `Scry.Engine.Exqlite`'s own per-query `NOT NULL`/type-
  affinity schema check (that module's own moduledoc has the full
  correctness reasoning) uses it to avoid re-running `PRAGMA
  table_info` on every single call when the schema hasn't actually
  changed since the last check, verified cheaply via SQLite's own
  `PRAGMA schema_version` (a single integer, bumped by *any* schema-
  altering statement against this database file, from any connection
  -- not just this one) rather than trusted indefinitely. A `%Conn{}`
  built by hand (`%Conn{db: db}`, common in tests) has `schema_cache:
  nil` and simply skips caching -- always correct, just not optimized.

  `close/1` releases the underlying connection *and* the schema cache
  explicitly when the caller is done with it -- nothing about this
  struct closes either on its own (no finalizer, no linked process);
  the caller owns its own connection lifecycle, same as any other
  database client library.
  """

  @type t :: %__MODULE__{db: Exqlite.Sqlite3.db(), schema_cache: :ets.table() | nil}

  defstruct db: nil, schema_cache: nil

  @doc """
  Opens `path` (an existing SQLite database file) and wraps the
  resulting connection. `opts` is passed straight through to
  `Exqlite.Sqlite3.open/2` (e.g. `mode: :readonly`).
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ []) do
    with {:ok, db} <- Exqlite.Sqlite3.open(path, opts) do
      schema_cache = :ets.new(:scry_exqlite_schema_cache, [:set, :public])
      {:ok, %__MODULE__{db: db, schema_cache: schema_cache}}
    end
  end

  @doc "Closes the wrapped connection and its schema cache."
  @spec close(t()) :: :ok
  def close(%__MODULE__{db: db, schema_cache: schema_cache}) do
    if schema_cache, do: :ets.delete(schema_cache)
    Exqlite.Sqlite3.close(db)
  end
end
