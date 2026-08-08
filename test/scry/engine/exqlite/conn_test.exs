defmodule Scry.Engine.Exqlite.ConnTest do
  @moduledoc """
  `Scry.Engine.Exqlite.Conn` -- confirms `open/2` wraps a real SQLite
  connection (creating the file if it doesn't exist, per SQLite's own
  default behavior), passes an error through unchanged (opening in
  `:readonly` mode against a nonexistent file, which SQLite itself
  refuses), and `close/1` actually releases the connection.
  """

  use ExUnit.Case, async: true

  alias Scry.Engine.Exqlite.Conn

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "scry_engine_exqlite_conn_test_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "open/2 creates and wraps a fresh SQLite connection", %{path: path} do
    assert {:ok, %Conn{db: db}} = Conn.open(path)
    assert db != nil
    assert File.exists?(path)
  end

  test "open/2 also creates a schema cache, used to avoid a fresh PRAGMA table_info on every call",
       %{path: path} do
    assert {:ok, %Conn{schema_cache: schema_cache}} = Conn.open(path)
    assert :ets.info(schema_cache) != :undefined
  end

  test "open/2 passes through an error unchanged", %{path: path} do
    assert {:error, _reason} = Conn.open(path, mode: :readonly)
  end

  test "close/1 releases the connection and its schema cache", %{path: path} do
    assert {:ok, %Conn{schema_cache: schema_cache} = conn} = Conn.open(path)
    assert Conn.close(conn) == :ok
    assert :ets.info(schema_cache) == :undefined
  end

  test "a hand-built %Conn{db: db} (no schema_cache) still closes fine", %{path: path} do
    {:ok, %Conn{db: db}} = Conn.open(path)
    assert Conn.close(%Conn{db: db}) == :ok
  end
end
