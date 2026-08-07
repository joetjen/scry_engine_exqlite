defmodule Scry.Engine.ExqliteTest do
  @moduledoc """
  `Scry.Engine.Exqlite` -- confirms `fetch/2` streams a real table
  correctly (including across the multi-chunk `multi_step/3`
  accumulation path, forced via a small `chunk_size` override so the
  test doesn't need thousands of rows), `fetch/3` agrees with `fetch/2`
  whenever both apply and genuinely narrows results when it can,
  unknown and unsafe (would-be SQL-injecting) sources are both clear
  errors rather than a crash or, worse, an executed statement, and
  this all composes end to end through a real `Scry.Core.Executor.run/4`
  call.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query}
  alias Scry.Engine.Exqlite, as: Engine
  alias Scry.Engine.Exqlite.Conn

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "scry_engine_exqlite_test_#{System.unique_integer([:positive])}.db"
      )

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)
      """)

    insert_users(db, [{1, "Alice", 30}, {2, "Bob", 17}])

    on_exit(fn -> File.rm(path) end)

    {:ok, conn: %Conn{db: db}, db: db}
  end

  defp insert_users(db, rows) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO users VALUES (?, ?, ?)")

    Enum.each(rows, fn {id, name, age} ->
      :ok = Exqlite.Sqlite3.bind(stmt, [id, name, age])
      :done = Exqlite.Sqlite3.step(db, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    Exqlite.Sqlite3.release(db, stmt)
  end

  describe "fetch/2" do
    test "returns every row for a known source", %{conn: conn} do
      assert {:ok, stream} = Engine.fetch(conn, ["users"])

      assert stream |> Enum.to_list() |> Enum.sort_by(& &1["id"]) == [
               %{"id" => 1, "name" => "Alice", "age" => 30},
               %{"id" => 2, "name" => "Bob", "age" => 17}
             ]
    end

    test "returns a clear error for an unknown source, never raises", %{conn: conn} do
      assert Engine.fetch(conn, ["orders"]) == {:error, {:no_such_source, ["orders"]}}
    end

    test "a source that isn't a safe SQL identifier is rejected before ever touching SQL", %{
      conn: conn,
      db: db
    } do
      malicious = ["users; DROP TABLE users;--"]

      assert Engine.fetch(conn, malicious) == {:error, {:invalid_source, malicious}}

      # The table must still be there -- confirms the rejection happened
      # before any SQL was ever built from the source, not just that a
      # `DROP TABLE` happened to fail.
      assert {:ok, stream} = Engine.fetch(%Conn{db: db}, ["users"])
      assert [_ | _] = Enum.to_list(stream)
    end

    test "correctly accumulates across multiple multi_step/3 chunks", %{conn: conn} do
      Application.put_env(:scry_engine_exqlite, :chunk_size, 1)
      on_exit(fn -> Application.delete_env(:scry_engine_exqlite, :chunk_size) end)

      assert {:ok, stream} = Engine.fetch(conn, ["users"])
      rows = Enum.to_list(stream)
      assert length(rows) == 2
      assert rows |> Enum.sort_by(& &1["id"]) |> Enum.map(& &1["name"]) == ["Alice", "Bob"]
    end
  end

  describe "fetch/3" do
    test "a translatable predicate narrows results and agrees with a manually-filtered fetch/2",
         %{
           conn: conn
         } do
      query = %Query{source: ["users"], wheres: [{:cmp, :eq, ["id"], 1}]}

      assert {:ok, stream} = Engine.fetch(conn, ["users"], query)
      rows = Enum.to_list(stream)
      assert rows == [%{"id" => 1, "name" => "Alice", "age" => 30}]

      {:ok, all_stream} = Engine.fetch(conn, ["users"])
      all_rows = Enum.to_list(all_stream)
      assert rows == Enum.filter(all_rows, &(&1["id"] == 1))
    end

    test "an untranslatable predicate falls back to the same rows fetch/2 returns", %{
      conn: conn
    } do
      query = %Query{
        source: ["users"],
        wheres: [{:or, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["id"], 2}}]
      }

      assert {:ok, stream} = Engine.fetch(conn, ["users"], query)
      rows = Enum.to_list(stream)
      {:ok, all_stream} = Engine.fetch(conn, ["users"])
      all_rows = Enum.to_list(all_stream)
      assert Enum.sort_by(rows, & &1["id"]) == Enum.sort_by(all_rows, & &1["id"])
    end

    test "an unknown source is still a clear error", %{conn: conn} do
      query = %Query{source: ["orders"], wheres: []}

      assert Engine.fetch(conn, ["orders"], query) == {:error, {:no_such_source, ["orders"]}}
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "a key-equality filter executes correctly through the pushdown path", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end

    test "a non-pushdown-able filter still executes correctly through the full-scan fallback", %{
      conn: conn
    } do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end
  end
end
