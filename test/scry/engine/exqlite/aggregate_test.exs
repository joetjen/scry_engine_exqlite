defmodule Scry.Engine.Exqlite.AggregateTest do
  @moduledoc """
  `Scry.Engine.Exqlite`'s `GROUP BY`/aggregate pushdown (part of the
  same `execute/3` compiler as everything else, not a separate
  callback any more) -- confirms a fully-eligible `GROUP BY`/aggregate
  query genuinely pushes down to native SQL and produces correct
  results (`sum`/`avg`/`count`/`min`/`max`/`count(distinct ...)`, a
  flat aggregate, a flat aggregate over zero matching rows correctly
  reporting `nil`, a `{:param, name}`-bound `WHERE`), that `avg` is
  eligible now and returns a native (inexact) float -- `scry_core`'s
  own `CHANGELOG.md` has the full exactness-relaxation reasoning --
  while still requiring the *same* schema-level `NOT NULL` guarantee
  every other aggregate needs (relaxing exactness never meant relaxing
  "no silent null-skipping" too), that the `NOT NULL` gate correctly
  declines the *entire* query for a nullable aggregated or `WHERE`-
  filtered column (a real schema-level `PRAGMA table_info` check,
  against a real SQLite database, not mocked) -- with **no fallback**,
  unlike the old `aggregate/5`-era contract this replaces, and that a
  real `INTEGER PRIMARY KEY` column (a SQLite `ROWID` alias, `notnull:
  0` in the schema despite never actually being `NULL` for a stored
  row) still gets treated as trustworthy for aggregation, confirmed
  directly against `PRAGMA table_info`'s own real output, not assumed.
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

  defp run(query, conn), do: query |> Executor.run(Engine, conn) |> materialize()

  describe "GROUP BY + aggregate pushdown, over NOT NULL columns" do
    test "sum/count/min/max all push down and produce correct results", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}},
          {:computed, "n", {:call, "count", [{:field, ["amount"]}]}},
          {:computed, "lo", {:call, "min", [{:field, ["amount"]}]}},
          {:computed, "hi", {:call, "max", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      assert Enum.sort_by(rows, & &1["user_id"]) == [
               %{"user_id" => 1, "total" => 30, "n" => 2, "lo" => 10, "hi" => 20},
               %{"user_id" => 2, "total" => 12, "n" => 2, "lo" => 5, "hi" => 7}
             ]
    end

    test "avg pushes down now, returning a native (inexact) float -- the deliberate exactness relaxation",
         %{conn: conn} do
      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "avg_amount", {:call, "avg", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      assert Enum.sort_by(rows, & &1["user_id"]) == [
               %{"user_id" => 1, "avg_amount" => 15.0},
               %{"user_id" => 2, "avg_amount" => 6.0}
             ]

      assert Enum.all?(rows, &is_float(&1["avg_amount"]))
    end

    test "count(distinct status) pushes down correctly", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "distinct_statuses", {:call, "count", [{:distinct, {:field, ["status"]}}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      assert Enum.sort_by(rows, & &1["user_id"]) == [
               %{"user_id" => 1, "distinct_statuses" => 1},
               %{"user_id" => 2, "distinct_statuses" => 2}
             ]
    end

    test "a flat (no GROUP BY) aggregate over every row", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        select: [{:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"total" => 42}]} = run(query, conn)
    end

    test "a flat aggregate over zero matching rows reports nil, not a crash", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        wheres: [{:cmp, :eq, ["status"], "zzz"}],
        select: [{:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"total" => nil}]} = run(query, conn)
    end

    test "a {:param, name}-bound WHERE resolves and pushes down", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        wheres: [{:cmp, :eq, ["user_id"], {:param, "uid"}}],
        select: [{:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"total" => 30}]} =
               query |> Executor.run(Engine, conn, %{"uid" => 1}) |> materialize()
    end

    test "count(id) -- an INTEGER PRIMARY KEY (ROWID alias) -- still pushes down despite notnull: 0 in the schema",
         %{conn: conn, db: db} do
      # Confirmed directly, not assumed: PRAGMA table_info reports
      # `notnull: 0` for `id` even though no persisted row can ever
      # read back a real NULL there (it *is* the rowid).
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "PRAGMA table_info(orders)")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)
      assert Enum.find(rows, &(Enum.at(&1, 1) == "id")) |> Enum.at(3) == 0

      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:ok, result} = run(query, conn)

      assert Enum.sort_by(result, & &1["user_id"]) == [
               %{"user_id" => 1, "n" => 2},
               %{"user_id" => 2, "n" => 2}
             ]
    end
  end

  describe "no fallback exists any more -- a query the compiler declines is a clean error, not a slower correct answer" do
    test "an untranslatable (:match) WHERE predicate declines the whole query -- unlike :or/:and/:not, which now translate" do
      db_path = Path.join(System.tmp_dir!(), "declines_#{System.unique_integer([:positive])}.db")
      File.rm(db_path)
      {:ok, conn} = Conn.open(db_path)

      :ok =
        Exqlite.Sqlite3.execute(conn.db, """
        CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT NOT NULL, amount INTEGER NOT NULL)
        """)

      query = %Query{
        source: ["orders"],
        wheres: [{:cmp, :match, ["status"], "^a"}],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:error, {:unsupported, _}} = run(query, conn)
      Conn.close(conn)
      File.rm(db_path)
    end

    test "aggregating over a nullable column declines the whole query", %{conn: conn} do
      query = %Query{
        source: ["orders"],
        select: [{:computed, "total_discount", {:call, "sum", [{:field, ["discount"]}]}}]
      }

      assert run(query, conn) == {:error, {:unsupported, {:nullable_column, ["discount"]}}}
    end

    test "grouping on a NOT NULL column but aggregating a nullable one still declines", %{
      conn: conn
    } do
      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "max_discount", {:call, "max", [{:field, ["discount"]}]}}
        ]
      }

      assert run(query, conn) == {:error, {:unsupported, {:nullable_column, ["discount"]}}}
    end

    test "filtering by a nullable column (not the null-check idiom) declines the whole query", %{
      conn: conn
    } do
      query = %Query{
        source: ["orders"],
        wheres: [{:cmp, :not_eq, ["discount"], 0}],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total_discount", {:call, "sum", [{:field, ["discount"]}]}}
        ]
      }

      assert run(query, conn) == {:error, {:unsupported, {:nullable_column, ["discount"]}}}
    end

    test "a real HAVING clause declines the whole query -- not attempted this increment", %{
      conn: conn
    } do
      query = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        havings: [{:cmp, :gt, {:call, "sum", [{:field, ["amount"]}]}, 15}],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:error, {:unsupported, {:construct, :having}}} = run(query, conn)
    end

    test "ROLLUP/CUBE decline the whole query -- not attempted this increment", %{conn: conn} do
      for group_mode <- [:rollup, :cube] do
        query = %Query{
          source: ["orders"],
          group_bys: [["user_id"]],
          group_mode: group_mode,
          select: [
            {:field, ["user_id"]},
            {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
          ]
        }

        assert {:error, {:unsupported, {:construct, ^group_mode}}} = run(query, conn)
      end
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
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

      assert {:error, {:query_error, _}} = run(query, conn)

      Conn.close(conn)
      File.rm(db_path)
    end
  end
end
