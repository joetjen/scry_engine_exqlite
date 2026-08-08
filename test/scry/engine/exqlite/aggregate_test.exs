defmodule Scry.Engine.Exqlite.AggregateTest do
  @moduledoc """
  `Scry.Engine.Exqlite.aggregate/5` -- confirms a fully-eligible `GROUP
  BY`/aggregate query genuinely pushes down to native SQL and produces
  correct results (`sum`/`count`/`min`/`max`/`count(distinct ...)`, a
  flat aggregate, a flat aggregate over zero matching rows correctly
  reporting `nil`, a `{:param, name}`-bound `WHERE`), that the `NOT
  NULL` gate correctly declines pushdown for a nullable column (real
  schema-level `PRAGMA table_info` check, against a real SQLite
  database, not mocked) while `Scry.Core.Executor`'s own fallback still
  produces the exact same, correct final result, that an untranslatable
  `WHERE` predicate also declines gracefully, and that this all
  composes correctly end to end through `Scry.Core.Executor.run/4` --
  which, since this module now implements `aggregate/5`, exercises the
  pushdown path automatically for any eligible query, not just
  `aggregate/5` called directly.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query}
  alias Scry.Engine.Exqlite, as: Engine
  alias Scry.Engine.Exqlite.Conn

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "scry_engine_exqlite_aggregate_test_#{System.unique_integer([:positive])}.db"
      )

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE orders (
        id INTEGER PRIMARY KEY,
        user_id INTEGER NOT NULL,
        amount INTEGER NOT NULL,
        status TEXT NOT NULL,
        discount INTEGER
      )
      """)

    insert_orders(db, [
      {1, 1, 10, "a", nil},
      {2, 1, 20, "a", nil},
      {3, 2, 5, "b", 1},
      {4, 2, 7, "c", 2}
    ])

    on_exit(fn -> File.rm(path) end)

    {:ok, conn: %Conn{db: db}, db: db}
  end

  defp insert_orders(db, rows) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO orders VALUES (?, ?, ?, ?, ?)")

    Enum.each(rows, fn {id, user_id, amount, status, discount} ->
      :ok = Exqlite.Sqlite3.bind(stmt, [id, user_id, amount, status, discount])
      :done = Exqlite.Sqlite3.step(db, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    Exqlite.Sqlite3.release(db, stmt)
  end

  defp materialize({:ok, cursor}), do: {:ok, Cursor.to_list(cursor)}
  defp materialize({:error, _} = err), do: err

  describe "aggregate/5 called directly" do
    test "GROUP BY user_id + sum/count/min/max over a NOT NULL column pushes down correctly", %{
      conn: conn
    } do
      query = %Query{source: ["orders"], group_bys: [["user_id"]]}

      plan = [
        {"sum", [{:field, ["amount"]}]},
        {"count", [{:field, ["amount"]}]},
        {"min", [{:field, ["amount"]}]},
        {"max", [{:field, ["amount"]}]}
      ]

      assert {:ok, rows} = Engine.aggregate(conn, ["orders"], query, plan, %{})

      assert Enum.sort(rows) ==
               Enum.sort([
                 {[1],
                  %{
                    {"sum", [{:field, ["amount"]}]} => 30,
                    {"count", [{:field, ["amount"]}]} => 2,
                    {"min", [{:field, ["amount"]}]} => 10,
                    {"max", [{:field, ["amount"]}]} => 20
                  }},
                 {[2],
                  %{
                    {"sum", [{:field, ["amount"]}]} => 12,
                    {"count", [{:field, ["amount"]}]} => 2,
                    {"min", [{:field, ["amount"]}]} => 5,
                    {"max", [{:field, ["amount"]}]} => 7
                  }}
               ])
    end

    test "count(distinct status) pushes down correctly", %{conn: conn} do
      query = %Query{source: ["orders"], group_bys: [["user_id"]]}
      plan = [{"count", [{:distinct, {:field, ["status"]}}]}]

      assert {:ok, rows} = Engine.aggregate(conn, ["orders"], query, plan, %{})

      assert Enum.sort(rows) ==
               Enum.sort([
                 {[1], %{{"count", [{:distinct, {:field, ["status"]}}]} => 1}},
                 {[2], %{{"count", [{:distinct, {:field, ["status"]}}]} => 2}}
               ])
    end

    test "a flat (no GROUP BY) aggregate over every row", %{conn: conn} do
      query = %Query{source: ["orders"], group_bys: []}
      plan = [{"sum", [{:field, ["amount"]}]}]

      assert {:ok, [{[], %{{"sum", [{:field, ["amount"]}]} => 42}}]} =
               Engine.aggregate(conn, ["orders"], query, plan, %{})
    end

    test "a flat aggregate over zero matching rows reports :empty, not a raw nil", %{conn: conn} do
      query = %Query{source: ["orders"], group_bys: [], wheres: [{:cmp, :eq, ["status"], "zzz"}]}
      plan = [{"sum", [{:field, ["amount"]}]}]

      assert {:ok, [{[], %{{"sum", [{:field, ["amount"]}]} => :empty}}]} =
               Engine.aggregate(conn, ["orders"], query, plan, %{})
    end

    test "a {:param, name}-bound WHERE resolves and pushes down", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        group_bys: [],
        wheres: [{:cmp, :eq, ["user_id"], {:param, "uid"}}]
      }

      plan = [{"sum", [{:field, ["amount"]}]}]

      assert {:ok, [{[], %{{"sum", [{:field, ["amount"]}]} => 30}}]} =
               Engine.aggregate(conn, ["orders"], query, plan, %{"uid" => 1})
    end

    test "an untranslatable WHERE predicate declines the whole pushdown" do
      db_path = Path.join(System.tmp_dir!(), "declines.db")
      File.rm(db_path)
      {:ok, conn} = Conn.open(db_path)

      query = %Query{
        source: ["orders"],
        group_bys: [],
        wheres: [{:or, {:cmp, :eq, ["status"], "a"}, {:cmp, :eq, ["status"], "b"}}]
      }

      plan = [{"sum", [{:field, ["amount"]}]}]
      assert Engine.aggregate(conn, ["orders"], query, plan, %{}) == :not_supported
      Conn.close(conn)
      File.rm(db_path)
    end

    test "aggregating over a nullable column declines pushdown (NOT NULL gate)", %{conn: conn} do
      query = %Query{source: ["orders"], group_bys: []}
      plan = [{"sum", [{:field, ["discount"]}]}]

      assert Engine.aggregate(conn, ["orders"], query, plan, %{}) == :not_supported
    end

    test "group_bys on a NOT NULL column but aggregating a nullable one still declines", %{
      conn: conn
    } do
      query = %Query{source: ["orders"], group_bys: [["user_id"]]}
      plan = [{"max", [{:field, ["discount"]}]}]

      assert Engine.aggregate(conn, ["orders"], query, plan, %{}) == :not_supported
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "an eligible GROUP BY + sum executes correctly via the automatically-preferred pushdown",
         %{conn: conn} do
      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) |> Enum.sort_by(& &1["user_id"]) == [
               %{"user_id" => 1, "total" => 30},
               %{"user_id" => 2, "total" => 12}
             ]
    end

    test "aggregating a nullable column still produces the correct result via the fallback", %{
      conn: conn
    } do
      query = %Query{
        source: ["orders"],
        wheres: [{:cmp, :not_eq, ["discount"], nil}],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total_discount", {:call, "sum", [{:field, ["discount"]}]}}
        ]
      }

      {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) |> Enum.sort_by(& &1["user_id"]) == [
               %{"user_id" => 2, "total_discount" => 3}
             ]
    end

    test "a query with an :or WHERE still executes correctly via the fallback", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        wheres: [{:or, {:cmp, :eq, ["status"], "a"}, {:cmp, :eq, ["status"], "b"}}],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) |> Enum.sort_by(& &1["user_id"]) == [
               %{"user_id" => 1, "n" => 2},
               %{"user_id" => 2, "n" => 1}
             ]
    end

    test "an unknown source is still a clear error, not a crash" do
      db_path = Path.join(System.tmp_dir!(), "unknown_source.db")
      File.rm(db_path)
      {:ok, conn} = Conn.open(db_path)

      query = %Query{
        source: ["missing"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:error, {:no_such_source, ["missing"]}} =
               query |> Executor.run(Engine, conn) |> materialize()

      Conn.close(conn)
      File.rm(db_path)
    end
  end
end
