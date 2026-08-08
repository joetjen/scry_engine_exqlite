defmodule Scry.Engine.ExqliteTest do
  @moduledoc """
  `Scry.Engine.Exqlite` -- confirms `execute/3` compiles a plain
  `WHERE`/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET` query into one real
  SQL statement (including across the multi-chunk `multi_step/3`
  accumulation path, forced via a small `chunk_size` override), that
  an unknown or unsafe (would-be SQL-injecting) source is a clear,
  tagged error rather than a crash or an executed statement, that a
  `WHERE`/`ORDER BY`/`select` shape this module can't translate is a
  clean `{:error, {:unsupported, ...}}` (no silent fallback exists any
  more -- `Scry.Engine.Exqlite.SqlCompiler`'s own moduledoc has the
  full eligible-shape list), that a `WHERE` predicate against a
  nullable column correctly declines (the real correctness concern
  `SqlCompiler`'s own moduledoc documents) while the same predicate
  against a schema-`NOT NULL` column pushes down fine, and that a
  nested/correlated `SELECT` or a `WITH`-bound source is delegated
  whole to `Scry.Core.QueryOps.run_document/4` rather than attempted
  natively -- all composing correctly end to end through a real
  `Scry.Core.Executor.run/4` call.
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
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER NOT NULL,
        status TEXT
      )
      """)

    insert_users(db, [{1, "Alice", 30, "active"}, {2, "Bob", 17, nil}])

    on_exit(fn -> File.rm(path) end)

    {:ok, conn: %Conn{db: db}, db: db}
  end

  defp insert_users(db, rows) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO users VALUES (?, ?, ?, ?)")

    Enum.each(rows, fn {id, name, age, status} ->
      :ok = Exqlite.Sqlite3.bind(stmt, [id, name, age, status])
      :done = Exqlite.Sqlite3.step(db, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    Exqlite.Sqlite3.release(db, stmt)
  end

  defp materialize({:ok, rows}), do: {:ok, Enum.to_list(rows)}
  defp materialize(other), do: other

  describe "execute/3 -- plain queries" do
    test "no wheres at all returns every row", %{conn: conn} do
      query = %Query{source: ["users"], select: [{:field, ["id"]}, {:field, ["name"]}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))

      assert Enum.sort_by(rows, & &1["id"]) == [
               %{"id" => 1, "name" => "Alice"},
               %{"id" => 2, "name" => "Bob"}
             ]
    end

    test "a bare field under an explicit alias (as Scry.Core.Query.from/2's map select: always produces) still pushes down",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        select: [{:computed, "n", {:field, ["name"]}}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.sort(rows) == Enum.sort([%{"n" => "Alice"}, %{"n" => "Bob"}])
    end

    test "a WHERE on a schema-NOT-NULL column pushes down and narrows correctly", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "a WHERE on a nullable column declines -- the real correctness concern this compiler exists for",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["name"]}]
      }

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:nullable_column, ["status"]}}}
    end

    test "the explicit field = nil null-check idiom works fine even on a nullable column", %{
      conn: conn
    } do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["status"], nil}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Bob"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "ORDER BY + LIMIT + OFFSET compiles and executes correctly", %{conn: conn} do
      query = %Query{
        source: ["users"],
        order_bys: [{["age"], :asc}],
        limit: 1,
        offset: 1,
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "DISTINCT compiles and executes correctly", %{conn: conn} do
      query = %Query{source: ["users"], distinct: true, select: [{:field, ["age"]}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.sort_by(rows, & &1["age"]) == [%{"age" => 17}, %{"age" => 30}]
    end

    test "a computed (non-bare-field) select item declines -- no cast/arithmetic translation this increment",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        select: [{:computed, "n", {:call, "string", [{:field, ["age"]}]}}]
      }

      assert {:error, {:unsupported, {:select, _}}} = Engine.execute(conn, query, %{})
    end

    test "an unknown source is a clear, tagged query_error, never a crash", %{conn: conn} do
      query = %Query{source: ["orders"], select: [{:field, ["id"]}]}
      assert {:error, {:query_error, _}} = Engine.execute(conn, query, %{})
    end

    test "a source that isn't a safe SQL identifier is rejected before ever touching SQL", %{
      conn: conn,
      db: db
    } do
      malicious = ["users; DROP TABLE users;--"]
      query = %Query{source: malicious, select: []}

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:source, hd(malicious)}}}

      # The table must still be there -- confirms the rejection
      # happened before any SQL was ever built from the source.
      still_there = %Query{source: ["users"], select: [{:field, ["id"]}]}
      assert {:ok, [_ | _]} = materialize(Engine.execute(%Conn{db: db}, still_there, %{}))
    end

    test "correctly accumulates across multiple multi_step/3 chunks", %{conn: conn} do
      Application.put_env(:scry_engine_exqlite, :chunk_size, 1)
      on_exit(fn -> Application.delete_env(:scry_engine_exqlite, :chunk_size) end)

      query = %Query{source: ["users"], select: [{:field, ["id"]}, {:field, ["name"]}]}
      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert length(rows) == 2
      assert rows |> Enum.sort_by(& &1["id"]) |> Enum.map(& &1["name"]) == ["Alice", "Bob"]
    end
  end

  describe "execute/3 -- delegated to Scry.Core.QueryOps.run_document/4" do
    test "a correlated nested SELECT is delegated and produces correct results", %{
      conn: conn,
      db: db
    } do
      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, total INTEGER NOT NULL)
        """)

      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO orders VALUES (?, ?, ?)")

      Enum.each([{1, 1, 50}, {2, 1, 75}, {3, 2, 20}], fn {id, user_id, total} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [id, user_id, total])
        :done = Exqlite.Sqlite3.step(db, stmt)
      end)

      Exqlite.Sqlite3.release(db, stmt)

      query = %Query{
        source: ["users"],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: ["orders"],
            wheres: [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}],
            select: [{:field, ["total"]}]
          }
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) == [
               %{"name" => "Alice", "orders" => [%{"total" => 50}, %{"total" => 75}]},
               %{"name" => "Bob", "orders" => [%{"total" => 20}]}
             ]
    end

    test "a WITH-bound source is delegated and produces correct results", %{conn: conn} do
      query = %Query{
        source: ["adults"],
        select: [{:field, ["name"]}],
        with_bindings: %{
          "adults" => %Query{
            source: ["users"],
            wheres: [{:cmp, :gt, ["age"], 18}],
            select: [{:field, ["name"]}]
          }
        }
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "a key-equality filter executes correctly through the SQL pushdown path", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end

    test "GROUP BY + count executes correctly via native SQL pushdown", %{conn: conn} do
      query = %Query{
        source: ["users"],
        group_bys: [["age"]],
        select: [
          {:field, ["age"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) |> Enum.sort_by(& &1["age"]) == [
               %{"age" => 17, "n" => 1},
               %{"age" => 30, "n" => 1}
             ]
    end
  end
end
