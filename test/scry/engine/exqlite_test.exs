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

  Rows come back as `Scry.Core.Row.t()` values for this module's own
  direct (non-delegated) path -- `materialize/1` below converts every
  row to a plain map via `Scry.Core.Row.to_map/1` so the rest of this
  suite can keep asserting on ordinary `%{...}` shapes without needing
  to care; "rows are genuinely Row, not just plain maps" gets its own
  explicit, dedicated test instead of being implicit everywhere.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query, Row}
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

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list() |> Enum.map(&to_plain/1)}
  defp materialize(other), do: other

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  describe "execute/3 -- plain queries" do
    test "rows genuinely come back as Scry.Core.Row values, not plain maps, for this direct pushdown path",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = Engine.execute(conn, query, %{})
      assert [%Row{} = row] = Enum.to_list(rows)
      assert Row.fetch!(row, "name") == "Alice"
      assert Row.to_map(row) == %{"name" => "Alice"}
    end

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

    test "the schema-checked (eager) path also accumulates correctly across multiple chunks, using this module's own configured chunk size, not exqlite's own 50-row default",
         %{conn: conn} do
      Application.put_env(:scry_engine_exqlite, :chunk_size, 1)
      on_exit(fn -> Application.delete_env(:scry_engine_exqlite, :chunk_size) end)

      # `age > 0` forces the schema-checked (eager `fetch_all/3`) path,
      # not the plain streamed `rows_stream/3` path the test above
      # already covers.
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 0}],
        select: [{:field, ["id"]}, {:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert length(rows) == 2
      assert rows |> Enum.sort_by(& &1["id"]) |> Enum.map(& &1["name"]) == ["Alice", "Bob"]
    end
  end

  describe "a type-affinity mismatch declines rather than risk a wrong result" do
    test "an ordering comparison against a mismatched-affinity literal declines", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], "not a number"}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:unsupported, {:type_mismatch, _}}} = Engine.execute(conn, query, %{})
    end

    test "an equality comparison against a mismatched-affinity literal also declines -- found by property testing, not assumed",
         %{conn: conn} do
      # `age` is INTEGER; SQLite's own affinity-coercion rule (applies
      # to every comparison operator, `=` included -- confirmed
      # directly, not assumed from the ordering-operator case alone)
      # would otherwise treat `age = "30"` as true for the row where
      # age is the integer 30, while the interpreter's own `=` never
      # considers a string and a number equal.
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["age"], "30"}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:unsupported, {:type_mismatch, _}}} = Engine.execute(conn, query, %{})
    end

    test "an IN list mixing types against one field declines", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:in, ["age"], [30, "thirty"]}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:unsupported, {:type_mismatch, _}}} = Engine.execute(conn, query, %{})
    end
  end

  describe "the schema check is cached per Conn, but a real schema change is still detected" do
    test "repeated queries against the same table reuse one cache entry, not a fresh table_info per call" do
      path = Path.join(System.tmp_dir!(), "cache_reuse_#{System.unique_integer([:positive])}.db")
      File.rm(path)
      {:ok, conn} = Conn.open(path)

      :ok =
        Exqlite.Sqlite3.execute(conn.db, """
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER NOT NULL)
        """)

      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 0}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, []} = materialize(Engine.execute(conn, query, %{}))
      assert :ets.info(conn.schema_cache, :size) == 1

      assert {:ok, []} = materialize(Engine.execute(conn, query, %{}))
      # Still exactly one entry -- the second call reused it rather
      # than inserting a duplicate or bypassing the cache.
      assert :ets.info(conn.schema_cache, :size) == 1

      Conn.close(conn)
      File.rm(path)
    end

    test "caching never lets a stale NOT NULL check through" do
      path = Path.join(System.tmp_dir!(), "schema_cache_#{System.unique_integer([:positive])}.db")
      File.rm(path)
      {:ok, conn} = Conn.open(path)

      :ok =
        Exqlite.Sqlite3.execute(conn.db, """
        CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT)
        """)

      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn.db, "INSERT INTO widgets VALUES (?, ?, ?)")
      :ok = Exqlite.Sqlite3.bind(stmt, [1, "sprocket", "active"])
      :done = Exqlite.Sqlite3.step(conn.db, stmt)
      Exqlite.Sqlite3.release(conn.db, stmt)

      query = %Query{
        source: ["widgets"],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["name"]}]
      }

      # `status` starts nullable -- declines, and populates the cache
      # with that schema.
      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:nullable_column, ["status"]}}}

      # A real schema change: SQLite has no direct "make a column NOT
      # NULL" statement, so this is the standard rebuild idiom --
      # bumps `PRAGMA schema_version` regardless.
      :ok =
        Exqlite.Sqlite3.execute(conn.db, """
        CREATE TABLE widgets_new (id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL)
        """)

      :ok = Exqlite.Sqlite3.execute(conn.db, "INSERT INTO widgets_new SELECT * FROM widgets")
      :ok = Exqlite.Sqlite3.execute(conn.db, "DROP TABLE widgets")
      :ok = Exqlite.Sqlite3.execute(conn.db, "ALTER TABLE widgets_new RENAME TO widgets")

      # Same conn, same schema_cache -- must genuinely re-check, not
      # trust the stale "status is nullable" result forever.
      assert {:ok, [%{"name" => "sprocket"}]} = materialize(Engine.execute(conn, query, %{}))

      Conn.close(conn)
      File.rm(path)
    end
  end

  describe "execute/3 -- a DateTime literal WHERE against an epoch-microseconds-encoded column" do
    test "pushes down and narrows correctly, matching the same comparison in Elixir term order",
         %{
           db: db
         } do
      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE events (id INTEGER PRIMARY KEY, logged_at INTEGER NOT NULL)
        """)

      base = ~U[2026-01-01 00:00:00Z]

      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO events VALUES (?, ?)")

      Enum.each([{1, base}, {2, DateTime.add(base, 300, :second)}], fn {id, dt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [id, DateTime.to_unix(dt, :microsecond)])
        :done = Exqlite.Sqlite3.step(db, stmt)
      end)

      Exqlite.Sqlite3.release(db, stmt)

      query = %Query{
        source: ["events"],
        wheres: [{:cmp, :ge, ["logged_at"], DateTime.add(base, 60, :second)}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(%Conn{db: db}, query, %{}))
      assert rows == [%{"id" => 2}]
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
      assert cursor |> Cursor.to_list() |> Enum.map(&to_plain/1) == [%{"name" => "Alice"}]
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

      assert cursor |> Cursor.to_list() |> Enum.map(&to_plain/1) |> Enum.sort_by(& &1["age"]) == [
               %{"age" => 17, "n" => 1},
               %{"age" => 30, "n" => 1}
             ]
    end
  end
end
