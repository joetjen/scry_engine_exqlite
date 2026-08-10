defmodule Scry.Engine.Exqlite.SqlCompilerPropertyTest do
  @moduledoc """
  `Scry.Engine.Exqlite`'s plain `WHERE` pushdown -- proves, across
  randomly generated predicates and rows (all NOT NULL columns, so
  every generated predicate is pushdown-eligible and the property
  isolates translation correctness specifically, not the separate,
  already-covered `NOT NULL`-decline behavior), that `execute/3`'s
  compiled-SQL result is always identical to running `Scry.Core.
  QueryOps.run_flat/3` directly over the same rows -- the direct
  replacement for the automatic re-verification the old, lenient
  `fetch/3` contract used to provide for free, now this engine's own
  responsibility to prove. `execute/3`'s own rows come back as `Scry.
  Core.Row.t()` values for this direct pushdown path; normalized via
  `Row.to_map/1` before comparing against `run_flat/3`'s own plain-map
  output.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Scry.Core.{Query, QueryOps, Row}
  alias Scry.Engine.Exqlite, as: Engine
  alias Scry.Engine.Exqlite.Conn

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "scry_sql_compiler_prop_#{System.unique_integer([:positive])}.db"
      )

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE items (id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b TEXT NOT NULL)
      """)

    on_exit(fn -> File.rm(path) end)
    {:ok, conn: %Conn{db: db}, db: db}
  end

  defp comparison_generator do
    gen all(
          field <- member_of(["a", "b"]),
          op <- member_of([:eq, :not_eq, :lt, :gt, :le, :ge]),
          value <- one_of([integer(-5..5), string(:alphanumeric, max_length: 3)])
        ) do
      {:cmp, op, [field], value}
    end
  end

  defp predicate_generator(depth \\ 0)
  defp predicate_generator(depth) when depth >= 2, do: comparison_generator()

  defp predicate_generator(depth) do
    one_of([
      comparison_generator(),
      gen all(
            l <- predicate_generator(depth + 1),
            r <- predicate_generator(depth + 1),
            combinator <- member_of([:and, :or])
          ) do
        {combinator, l, r}
      end
    ])
  end

  defp insert_rows(db, rows) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO items VALUES (?, ?, ?)")

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {row, id} ->
      :ok = Exqlite.Sqlite3.bind(stmt, [id, row["a"], row["b"]])
      :done = Exqlite.Sqlite3.step(db, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    Exqlite.Sqlite3.release(db, stmt)
  end

  defp row_generator do
    gen all(a <- integer(-5..5), b <- string(:alphanumeric, max_length: 3)) do
      %{"a" => a, "b" => b}
    end
  end

  property "execute/3's compiled SQL result always matches QueryOps.run_flat/3 over the same rows",
           %{db: db} do
    check all(
            rows <- list_of(row_generator(), max_length: 6),
            predicate <- predicate_generator(),
            max_runs: 100
          ) do
      :ok = Exqlite.Sqlite3.execute(db, "DELETE FROM items")
      insert_rows(db, rows)

      query = %Query{
        source: ["items"],
        wheres: [predicate],
        # `{:field, ["id"]}` is the current `expr()`-tagged sort-key
        # shape a real parsed query now produces (scry_core's EP1(e)
        # `ORDER BY` widening) -- the older bare-list shape (`["id"]`)
        # is exercised separately, directly against `SqlCompiler`, in
        # `Scry.Engine.ExqliteTest`.
        order_bys: [{{:field, ["id"]}, :asc}],
        select: [{:field, ["a"]}, {:field, ["b"]}]
      }

      via_engine =
        case Engine.execute(%Conn{db: db}, query, %{}) do
          {:ok, sql_rows} -> {:ok, sql_rows |> Enum.to_list() |> Enum.map(&Row.to_map/1)}
          {:error, {:unsupported, _}} -> :declined
        end

      via_toolkit =
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, id} -> Map.put(row, "id", id) end)
        |> QueryOps.run_flat(query, %{})
        |> then(fn {:ok, toolkit_rows} -> {:ok, Enum.to_list(toolkit_rows)} end)

      case via_engine do
        :declined -> :ok
        {:ok, engine_rows} -> assert Enum.sort(engine_rows) == Enum.sort(elem(via_toolkit, 1))
      end
    end
  end
end
