defmodule Scry.Engine.Exqlite.Conn do
  @moduledoc """
  Wraps an already-open `Exqlite.Sqlite3.db()` connection -- opened
  once via `open/2` and meant to be reused across many
  `Scry.Engine.Exqlite.fetch/2,3` calls, unlike an ad-hoc adapter that
  opens (and closes) a fresh connection on every single fetch. Matches
  the connection/config struct every real adapter exposes
  (impl_spec.md §2).

  `close/1` releases the underlying connection explicitly when the
  caller is done with it -- nothing about this struct closes it on its
  own (no finalizer, no linked process); the caller owns its own
  connection lifecycle, same as any other database client library.
  """

  @type t :: %__MODULE__{db: Exqlite.Sqlite3.db()}

  defstruct [:db]

  @doc """
  Opens `path` (an existing SQLite database file) and wraps the
  resulting connection. `opts` is passed straight through to
  `Exqlite.Sqlite3.open/2` (e.g. `mode: :readonly`).
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ []) do
    with {:ok, db} <- Exqlite.Sqlite3.open(path, opts) do
      {:ok, %__MODULE__{db: db}}
    end
  end

  @doc "Closes the wrapped connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{db: db}), do: Exqlite.Sqlite3.close(db)
end
