defmodule Scry.Engine.Exqlite.SchemaTest do
  @moduledoc """
  `Scry.Engine.Exqlite.Schema` -- the extracted schema-introspection
  internals `Scry.Engine.Exqlite`'s own per-query `NOT NULL`/type-
  affinity gate already relied on (`verify/4`, unchanged behavior,
  confirmed by `exqlite_test.exs`'s own existing schema-gate tests
  passing unmodified against this refactor), plus the new
  `describe_source/2` (`Scry.Core.EngineBehaviour`'s optional callback)
  this module adds.
  """

  use ExUnit.Case, async: true

  alias Scry.Engine.Exqlite.{Conn, Schema}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "scry_engine_exqlite_schema_test_#{System.unique_integer([:positive])}.db"
      )

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER,
        balance REAL,
        note BLOB,
        misc
      )
      """)

    on_exit(fn -> File.rm(path) end)

    {:ok, conn: %Conn{db: db}, db: db}
  end

  describe "describe_source/2" do
    test "describes every real column, nullability and scalar included", %{conn: conn} do
      assert {:ok, fields} = Schema.describe_source(conn, "users")

      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["id"] == %{name: "id", nullable: false, scalar: :integer}
      assert by_name["name"] == %{name: "name", nullable: false, scalar: :string}
      assert by_name["age"] == %{name: "age", nullable: true, scalar: :integer}
      assert by_name["balance"] == %{name: "balance", nullable: true, scalar: :float}
      assert by_name["note"] == %{name: "note", nullable: true, scalar: :unknown}
      assert by_name["misc"] == %{name: "misc", nullable: true, scalar: :unknown}
    end

    test "an INTEGER PRIMARY KEY (a real ROWID alias) is reported non-nullable despite notnull: 0",
         %{conn: conn} do
      assert {:ok, fields} = Schema.describe_source(conn, "users")
      id_field = Enum.find(fields, &(&1.name == "id"))
      assert id_field.nullable == false
    end

    test "a table that doesn't exist is {:error, :not_found}", %{conn: conn} do
      assert {:error, :not_found} = Schema.describe_source(conn, "ghost_table")
    end

    test "uses the same per-Conn ETS cache the schema gate uses, when one exists", %{db: db} do
      cache = :ets.new(:test_cache, [:set, :public])
      conn = %Conn{db: db, schema_cache: cache}

      assert {:ok, _fields} = Schema.describe_source(conn, "users")
      assert [{"users", _version, _rows}] = :ets.lookup(cache, "users")
    end

    test "a %Conn{} with no schema_cache still works, just uncached", %{db: db} do
      conn = %Conn{db: db, schema_cache: nil}
      assert {:ok, fields} = Schema.describe_source(conn, "users")
      assert length(fields) == 6
    end
  end

  describe "verify/4 (the existing per-query gate, unchanged behavior)" do
    test "passes when every not_null_columns entry is schema-guaranteed", %{conn: conn} do
      assert :ok = Schema.verify(conn, "users", ["id", "name"], [])
    end

    test "declines a nullable column claimed not-null", %{conn: conn} do
      assert {:error, {:unsupported, {:nullable_column, ["age"]}}} =
               Schema.verify(conn, "users", ["age"], [])
    end

    test "passes a type_checks entry matching the column's own affinity", %{conn: conn} do
      assert :ok = Schema.verify(conn, "users", [], [{"age", :numeric}])
    end

    test "declines a type_checks entry mismatching the column's own affinity", %{conn: conn} do
      assert {:error, {:unsupported, {:type_mismatch, [{"name", :numeric}]}}} =
               Schema.verify(conn, "users", [], [{"name", :numeric}])
    end

    test "an unknown table proceeds (:ok) rather than reporting a misleading nullable_column error",
         %{conn: conn} do
      assert :ok = Schema.verify(conn, "ghost_table", ["anything"], [])
    end
  end
end
