defmodule Scry.Engine.Exqlite.WhereTranslatorTest do
  @moduledoc """
  `Scry.Engine.Exqlite.WhereTranslator` -- confirms exactly which
  predicate shapes get pushed into real SQL (every `:cmp` op but
  `:match`, a single-segment identifier-safe field, a plain
  string/integer/float value) and which are deliberately left out
  (`:match`, a multi-segment or unsafe field, `nil`/booleans/
  `{:field, _}`/`{:param, _}`, `:or`/`:not`), plus a property test
  proving the translator never raises and always binds exactly one
  param per `?` placeholder, across an arbitrary predicate list.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Engine.Exqlite.WhereTranslator

  describe "translatable shapes" do
    test "an empty wheres list produces no clause at all" do
      assert WhereTranslator.translate([]) == {"", []}
    end

    test "every supported comparison operator translates" do
      for {op, sql_op} <- [eq: "=", not_eq: "!=", lt: "<", gt: ">", le: "<=", ge: ">="] do
        assert WhereTranslator.translate([{:cmp, op, ["age"], 18}]) ==
                 {" WHERE age #{sql_op} ?", [18]}
      end
    end

    test "string, integer, and float values are all translatable" do
      assert WhereTranslator.translate([{:cmp, :eq, ["name"], "Alice"}]) ==
               {" WHERE name = ?", ["Alice"]}

      assert WhereTranslator.translate([{:cmp, :eq, ["age"], 30}]) ==
               {" WHERE age = ?", [30]}

      assert WhereTranslator.translate([{:cmp, :ge, ["score"], 1.5}]) ==
               {" WHERE score >= ?", [1.5]}
    end

    test "multiple wheres entries are AND-joined, in order" do
      wheres = [{:cmp, :eq, ["status"], "active"}, {:cmp, :gt, ["age"], 18}]

      assert WhereTranslator.translate(wheres) ==
               {" WHERE status = ? AND age > ?", ["active", 18]}
    end

    test "a top-level {:and, ...} chain is flattened and both legs pushed down" do
      wheres = [{:and, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["status"], "active"}}]

      assert WhereTranslator.translate(wheres) ==
               {" WHERE id = ? AND status = ?", [1, "active"]}
    end
  end

  describe "predicates that are never translated" do
    test ":match has no direct SQL equivalent" do
      assert WhereTranslator.translate([{:cmp, :match, ["name"], "Ali.*"}]) == {"", []}
    end

    test "a multi-segment field path is left untranslated" do
      assert WhereTranslator.translate([{:cmp, :eq, ["metadata", "color"], "red"}]) == {"", []}
    end

    test "a field that isn't a safe SQL identifier is left untranslated" do
      assert WhereTranslator.translate([{:cmp, :eq, ["bad; DROP TABLE users;--"], 1}]) ==
               {"", []}
    end

    test "nil is never translated (SQL's own NULL semantics don't match ours)" do
      assert WhereTranslator.translate([{:cmp, :eq, ["deleted_at"], nil}]) == {"", []}
    end

    test "a boolean is never translated (ambiguous SQLite storage encoding)" do
      assert WhereTranslator.translate([{:cmp, :eq, ["active"], true}]) == {"", []}
    end

    test "a {:field, ...} right-hand side is never translated" do
      assert WhereTranslator.translate([{:cmp, :eq, ["age"], {:field, ["min_age"]}}]) == {"", []}
    end

    test "a {:param, ...} right-hand side is never translated" do
      assert WhereTranslator.translate([{:cmp, :eq, ["age"], {:param, "min_age"}}]) == {"", []}
    end

    test "an :or predicate is left out entirely, not partially translated" do
      wheres = [{:or, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["id"], 2}}]

      assert WhereTranslator.translate(wheres) == {"", []}
    end

    test "a :not predicate is left out entirely" do
      assert WhereTranslator.translate([{:not, {:cmp, :eq, ["id"], 1}}]) == {"", []}
    end

    test "an untranslatable predicate alongside a translatable one still pushes the latter" do
      wheres = [
        {:or, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["id"], 2}},
        {:cmp, :eq, ["status"], "active"}
      ]

      assert WhereTranslator.translate(wheres) == {" WHERE status = ?", ["active"]}
    end
  end

  describe "translate_strict/2" do
    test "an empty wheres list translates trivially" do
      assert WhereTranslator.translate_strict([], %{}) == {:ok, "", []}
    end

    test "a fully-translatable wheres list succeeds, same shape as translate/1" do
      wheres = [{:cmp, :eq, ["status"], "active"}, {:cmp, :gt, ["age"], 18}]

      assert WhereTranslator.translate_strict(wheres, %{}) ==
               {:ok, " WHERE status = ? AND age > ?", ["active", 18]}
    end

    test "a top-level {:and, ...} chain is flattened, same as translate/1" do
      wheres = [{:and, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["status"], "active"}}]

      assert WhereTranslator.translate_strict(wheres, %{}) ==
               {:ok, " WHERE id = ? AND status = ?", [1, "active"]}
    end

    test "a {:param, name} resolves against bound_params and binds like a literal" do
      wheres = [{:cmp, :eq, ["tenant_id"], {:param, "tenant"}}]

      assert WhereTranslator.translate_strict(wheres, %{"tenant" => 42}) ==
               {:ok, " WHERE tenant_id = ?", [42]}
    end

    test "a missing param resolution declines the whole translation" do
      wheres = [{:cmp, :eq, ["tenant_id"], {:param, "tenant"}}]
      assert WhereTranslator.translate_strict(wheres, %{}) == :error
    end

    test "a param resolving to a non-literal (e.g. a list) declines the whole translation" do
      wheres = [{:cmp, :eq, ["tenant_id"], {:param, "tenant"}}]
      assert WhereTranslator.translate_strict(wheres, %{"tenant" => [1, 2]}) == :error
    end

    test "any single untranslatable predicate declines the WHOLE translation, unlike translate/1's own leniency" do
      wheres = [
        {:cmp, :eq, ["status"], "active"},
        {:or, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["id"], 2}}
      ]

      assert WhereTranslator.translate_strict(wheres, %{}) == :error
    end

    test "an untranslatable field (multi-segment, or unsafe identifier) declines the whole translation" do
      assert WhereTranslator.translate_strict([{:cmp, :eq, ["a", "b"], 1}], %{}) == :error

      assert WhereTranslator.translate_strict(
               [{:cmp, :eq, ["bad; DROP TABLE users;--"], 1}],
               %{}
             ) == :error
    end

    test "nil/boolean/{:field, ...} right-hand sides still decline, same as translate/1" do
      assert WhereTranslator.translate_strict([{:cmp, :eq, ["x"], nil}], %{}) == :error
      assert WhereTranslator.translate_strict([{:cmp, :eq, ["x"], true}], %{}) == :error

      assert WhereTranslator.translate_strict([{:cmp, :eq, ["x"], {:field, ["y"]}}], %{}) ==
               :error
    end

    property "whenever it succeeds, the placeholder count always matches the bound param count" do
      check all(wheres <- list_of(predicate_generator())) do
        case WhereTranslator.translate_strict(wheres, %{"x" => 1}) do
          {:ok, sql, params} ->
            placeholder_count = sql |> String.graphemes() |> Enum.count(&(&1 == "?"))
            assert placeholder_count == length(params)

          :error ->
            :ok
        end
      end
    end
  end

  describe "property: never raises, params always match placeholders" do
    property "the number of '?' placeholders always equals the number of bound params" do
      check all(wheres <- list_of(predicate_generator())) do
        {sql, params} = WhereTranslator.translate(wheres)
        placeholder_count = sql |> String.graphemes() |> Enum.count(&(&1 == "?"))

        assert placeholder_count == length(params)
      end
    end
  end

  defp predicate_generator do
    gen all(
          field <- field_generator(),
          op <- member_of([:eq, :not_eq, :lt, :gt, :le, :ge, :match]),
          value <- value_generator()
        ) do
      {:cmp, op, [field], value}
    end
  end

  defp field_generator do
    one_of([
      map(string(:alphanumeric, min_length: 1), &("f_" <> &1)),
      constant("not an identifier!")
    ])
  end

  defp value_generator do
    one_of([
      string(:printable),
      integer(),
      float(),
      constant(nil),
      boolean(),
      constant({:field, ["other"]}),
      constant({:param, "x"})
    ])
  end
end
